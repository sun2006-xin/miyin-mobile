import 'dart:convert';

import '../../core/storage/translation_history_repository.dart';
import '../../core/translation/translation_contracts.dart';
import '../../core/translation/translation_service.dart';
import 'attachment_source_picker.dart';
import 'avatar_image_picker.dart';

/// Validates and routes the narrow JSON protocol used by the local V5 page.
final class TranslationRpcRouter {
  const TranslationRpcRouter(
    this._service, {
    this.attachmentSourcePicker,
    this.avatarImagePicker,
  });

  Future<void> close() => _service.close();

  static const maxTextLength = 10000;
  static const _allowedMethods = <String>{
    'translation.supportedPairs',
    'translation.modelInfo',
    'translation.downloadModel',
    'translation.deleteModel',
    'translation.translate',
    'attachment.pickSource',
    'profile.pickAvatar',
    'history.list',
    'history.count',
    'history.get',
    'history.delete',
    'history.deleteMany',
    'history.clear',
  };

  final TranslationService _service;
  final AttachmentSourcePicker? attachmentSourcePicker;
  final AvatarImagePicker? avatarImagePicker;

  Future<Map<String, Object?>> handle(String rawMessage) async {
    Object? decoded;
    try {
      decoded = jsonDecode(rawMessage);
    } on FormatException {
      return _error(null, 'invalid_request', 'Invalid request.');
    }
    if (decoded is! Map) {
      return _error(null, 'invalid_request', 'Invalid request.');
    }

    final idValue = decoded['id'];
    final id = idValue is String && idValue.isNotEmpty && idValue.length <= 96
        ? idValue
        : null;
    if (decoded['version'] != 1 || id == null) {
      return _error(id, 'invalid_request', 'Invalid request envelope.');
    }
    final method = decoded['method'];
    if (method is! String || !_allowedMethods.contains(method)) {
      return _error(
        id,
        'method_not_allowed',
        'This operation is not available.',
      );
    }
    final rawParams = decoded['params'];
    if (rawParams != null && rawParams is! Map) {
      return _error(id, 'invalid_parameters', 'Invalid request parameters.');
    }
    final params = rawParams == null
        ? <String, Object?>{}
        : Map<String, Object?>.from(rawParams as Map);

    try {
      final result = await _dispatch(method, params);
      return {'version': 1, 'id': id, 'ok': true, 'result': result};
    } on TranslationFailure catch (error) {
      return _error(id, error.code, error.message);
    } on ArgumentError catch (error) {
      return _error(id, 'invalid_parameters', error.message.toString());
    } catch (_) {
      return _error(
        id,
        'operation_failed',
        'The operation could not be completed.',
      );
    }
  }

  Future<Object?> _dispatch(String method, Map<String, Object?> params) async {
    switch (method) {
      case 'translation.supportedPairs':
        final pairs = await _service.getSupportedLanguagePairs();
        return pairs.map(_pairToMap).toList(growable: false);
      case 'translation.modelInfo':
        final pair = _readPair(params);
        final info = await _service.getModelInfo(pair);
        return {
          'status': info.status.name,
          'downloadedBytes': info.downloadedBytes,
          'totalBytes': info.totalBytes,
          'version': info.version,
        };
      case 'translation.downloadModel':
        final pair = _readPair(params);
        final wifiOnly = params['wifiOnly'];
        await _service.downloadModel(
          pair,
          wifiOnly: wifiOnly is bool ? wifiOnly : true,
        );
        return {'status': 'downloaded'};
      case 'translation.deleteModel':
        await _service.deleteModel(_readPair(params));
        return {'status': 'deleted'};
      case 'translation.translate':
        final text = params['text'];
        if (text is! String || text.trim().isEmpty) {
          throw ArgumentError.value(
            text,
            'text',
            'Please enter text to translate.',
          );
        }
        if (text.length > maxTextLength) {
          throw const TranslationFailure(
            'text_too_long',
            'Text is too long. Keep it under 10,000 characters.',
          );
        }
        final outcome = await _service.translateAndSave(
          TranslationRequest(
            sourceLanguage: _readLanguage(params['sourceTag']),
            targetLanguage: _readLanguage(params['targetTag']),
            text: text,
          ),
        );
        final translation = outcome.translation;
        return {
          'sourceText': translation.request.text,
          'translatedText': translation.translatedText,
          'sourceTag': translation.request.sourceLanguage.tag,
          'targetTag': translation.request.targetLanguage.tag,
          'engineId': translation.engineId,
          'modelVersion': translation.modelVersion,
          'createdAt': DateTime.now().toUtc().toIso8601String(),
          'historySaved': outcome.historySaved,
          if (outcome.historyEntryId != null)
            'historyEntryId': outcome.historyEntryId,
        };
      case 'attachment.pickSource':
        final kind = _readAttachmentSourceKind(params['kind']);
        final picker = attachmentSourcePicker;
        if (picker == null) {
          throw const TranslationFailure(
            'source_picker_unavailable',
            '本机文件选择暂时不可用。',
          );
        }
        final PickedAttachmentSource? selected;
        try {
          selected = await picker.pick(kind);
        } on TranslationFailure {
          rethrow;
        } catch (_) {
          throw const TranslationFailure(
            'attachment_picker_failed',
            '系统文件选择器暂时无法打开。',
          );
        }
        return selected?.toRpcMap() ?? {'canceled': true};
      case 'profile.pickAvatar':
        final source = _readAvatarImageSource(params['source']);
        final picker = avatarImagePicker;
        if (picker == null) {
          throw const TranslationFailure(
            'avatar_picker_unavailable',
            '头像选择暂时不可用。',
          );
        }
        try {
          final selected = await picker.pick(source);
          return selected?.toRpcMap() ?? {'canceled': true};
        } on AvatarImagePickerException catch (error) {
          throw TranslationFailure('avatar_image_invalid', error.message);
        } catch (_) {
          throw const TranslationFailure(
            'avatar_picker_failed',
            '头像选择器暂时无法打开。',
          );
        }
      case 'history.list':
        final limit = _readOptionalInt(params, 'limit', fallback: 30);
        final offset = _readOptionalInt(params, 'offset', fallback: 0);
        final entries = await _service.listHistory(
          limit: limit,
          offset: offset,
        );
        return entries.map(_historyToMap).toList(growable: false);
      case 'history.count':
        return {'count': await _service.countHistory()};
      case 'history.get':
        final id = _readPositiveInt(params, 'id');
        final entry = await _service.getHistoryEntry(id);
        return entry == null ? null : _historyToMap(entry);
      case 'history.delete':
        final id = _readPositiveInt(params, 'id');
        return {'deleted': await _service.deleteHistoryEntry(id)};
      case 'history.deleteMany':
        final ids = _readPositiveIntList(params, 'ids');
        return {'deletedCount': await _service.deleteHistoryEntries(ids)};
      case 'history.clear':
        return {'deletedCount': await _service.clearHistory()};
      default:
        throw const TranslationFailure(
          'method_not_allowed',
          'This operation is not available.',
        );
    }
  }

  static TranslationLanguagePair _readPair(Map<String, Object?> params) =>
      TranslationLanguagePair(
        sourceLanguage: _readLanguage(params['sourceTag']),
        targetLanguage: _readLanguage(params['targetTag']),
      );

  static AttachmentSourceKind _readAttachmentSourceKind(Object? value) {
    if (value is! String) {
      throw ArgumentError.value(
        value,
        'kind',
        'Choose camera, image, or document.',
      );
    }
    return switch (value) {
      'camera' => AttachmentSourceKind.camera,
      'image' => AttachmentSourceKind.image,
      'document' => AttachmentSourceKind.document,
      _ => throw ArgumentError.value(
        value,
        'kind',
        'Choose camera, image, or document.',
      ),
    };
  }

  static AvatarImageSource _readAvatarImageSource(Object? value) {
    if (value is! String) {
      throw ArgumentError.value(value, 'source', 'Choose camera or gallery.');
    }
    return switch (value) {
      'camera' => AvatarImageSource.camera,
      'gallery' => AvatarImageSource.gallery,
      _ => throw ArgumentError.value(
        value,
        'source',
        'Choose camera or gallery.',
      ),
    };
  }

  static TranslationLanguage _readLanguage(Object? value) {
    if (value is! String || value.length > 64) {
      throw ArgumentError.value(value, 'languageTag', 'Invalid language tag.');
    }
    if (value == TranslationLanguage.simplifiedChinese.tag) {
      return TranslationLanguage.simplifiedChinese;
    }
    if (value == TranslationLanguage.english.tag) {
      return TranslationLanguage.english;
    }
    return TranslationLanguage.fromTag(value, displayName: value);
  }

  static int _readPositiveInt(Map<String, Object?> params, String key) {
    final value = params[key];
    if (value is! int || value < 1) {
      throw ArgumentError.value(value, key, 'Must be a positive integer.');
    }
    return value;
  }

  static List<int> _readPositiveIntList(
    Map<String, Object?> params,
    String key,
  ) {
    final value = params[key];
    if (value is! List) {
      throw ArgumentError.value(
        value,
        key,
        'Must be an array of positive integers.',
      );
    }
    final ids = <int>[];
    for (final id in value) {
      if (id is! int || id < 1) {
        throw ArgumentError.value(
          id,
          key,
          'Every ID must be a positive integer.',
        );
      }
      ids.add(id);
    }
    return ids;
  }

  static int _readOptionalInt(
    Map<String, Object?> params,
    String key, {
    required int fallback,
  }) {
    final value = params[key];
    if (value == null) return fallback;
    if (value is! int || value < 0) {
      throw ArgumentError.value(value, key, 'Must be a non-negative integer.');
    }
    return value;
  }

  static Map<String, Object?> _pairToMap(TranslationLanguagePair pair) => {
    'sourceTag': pair.sourceLanguage.tag,
    'sourceName': pair.sourceLanguage.displayName,
    'targetTag': pair.targetLanguage.tag,
    'targetName': pair.targetLanguage.displayName,
  };

  static Map<String, Object?> _historyToMap(TranslationHistoryEntry entry) => {
    'id': entry.id,
    'sourceText': entry.sourceText,
    'translatedText': entry.translatedText,
    'sourceTag': entry.sourceLanguageTag,
    'targetTag': entry.targetLanguageTag,
    'engineId': entry.engineId,
    'modelVersion': entry.modelVersion,
    'createdAt': entry.createdAt.toIso8601String(),
  };

  static Map<String, Object?> _error(String? id, String code, String message) =>
      {
        'version': 1,
        'id': id,
        'ok': false,
        'error': {'code': code, 'message': message},
      };
}
