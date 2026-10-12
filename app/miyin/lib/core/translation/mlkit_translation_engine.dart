import 'package:flutter/services.dart';

import 'translation_contracts.dart';

/// Dart adapter for the Android ML Kit implementation.
///
/// The UI and database keep BCP-47 identifiers. The native adapter maps those
/// identifiers to the provider's own model codes; for example, `zh-Hans` maps
/// to ML Kit's `zh` model.
final class MlKitTranslationEngine implements TranslationEngine {
  MlKitTranslationEngine({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('com.miyin.app/translation');

  final MethodChannel _channel;

  @override
  String get engineId => 'google-mlkit-translation';

  @override
  Future<Set<TranslationLanguagePair>> getSupportedLanguagePairs() async {
    final values = await _invoke<List<Object?>>('supportedLanguagePairs');
    return values.map((value) {
      if (value is! Map) {
        throw const TranslationFailure(
          'invalid_engine_response',
          'The translation engine returned an invalid language list.',
        );
      }
      final sourceTag = value['sourceTag'];
      final targetTag = value['targetTag'];
      if (sourceTag is! String || targetTag is! String) {
        throw const TranslationFailure(
          'invalid_engine_response',
          'The translation engine returned an invalid language pair.',
        );
      }
      return TranslationLanguagePair(
        sourceLanguage: _language(sourceTag),
        targetLanguage: _language(targetTag),
      );
    }).toSet();
  }

  @override
  Future<TranslationModelInfo> getModelInfo(
    TranslationLanguagePair pair,
  ) async {
    final value = await _invoke<Map<Object?, Object?>>('getModelInfo', {
      'sourceTag': pair.sourceLanguage.tag,
      'targetTag': pair.targetLanguage.tag,
    });
    final statusName = value['status'];
    if (statusName is! String) {
      throw const TranslationFailure(
        'invalid_engine_response',
        'The translation engine returned an invalid model status.',
      );
    }
    final status = TranslationModelStatus.values.firstWhere(
      (candidate) => candidate.name == statusName,
      orElse: () => TranslationModelStatus.failed,
    );
    return TranslationModelInfo(
      status: status,
      downloadedBytes: _asInt(value['downloadedBytes']),
      totalBytes: _asInt(value['totalBytes']),
      version: value['version'] as String?,
    );
  }

  @override
  Future<void> downloadModel(
    TranslationLanguagePair pair, {
    required bool wifiOnly,
  }) async {
    await _invoke<void>('downloadModel', {
      'sourceTag': pair.sourceLanguage.tag,
      'targetTag': pair.targetLanguage.tag,
      'wifiOnly': wifiOnly,
    });
  }

  @override
  Future<void> deleteModel(TranslationLanguagePair pair) async {
    await _invoke<void>('deleteModel', {
      'sourceTag': pair.sourceLanguage.tag,
      'targetTag': pair.targetLanguage.tag,
    });
  }

  @override
  Future<TranslationResult> translate(TranslationRequest request) async {
    final value = await _invoke<Map<Object?, Object?>>('translate', {
      'sourceTag': request.sourceLanguage.tag,
      'targetTag': request.targetLanguage.tag,
      'text': request.text,
    });
    final translatedText = value['translatedText'];
    if (translatedText is! String || translatedText.trim().isEmpty) {
      throw const TranslationFailure(
        'empty_translation',
        'The translation engine returned no translated text.',
      );
    }
    return TranslationResult(
      request: request,
      translatedText: translatedText,
      engineId: engineId,
      modelVersion: value['modelVersion'] as String?,
    );
  }

  Future<T> _invoke<T>(String method, [Map<String, Object?>? arguments]) async {
    try {
      return await _channel.invokeMethod<T>(method, arguments) as T;
    } on PlatformException catch (error) {
      throw TranslationFailure(
        error.code,
        error.message ??
            'The translation engine could not complete the request.',
        cause: error.details,
      );
    } on MissingPluginException catch (error) {
      throw TranslationFailure(
        'translation_unavailable',
        'On-device translation is unavailable on this platform.',
        cause: error,
      );
    }
  }

  static int? _asInt(Object? value) => value is num ? value.toInt() : null;

  static TranslationLanguage _language(String tag) {
    if (tag == TranslationLanguage.simplifiedChinese.tag) {
      return TranslationLanguage.simplifiedChinese;
    }
    if (tag == TranslationLanguage.english.tag) {
      return TranslationLanguage.english;
    }
    return TranslationLanguage.fromTag(tag, displayName: tag);
  }
}
