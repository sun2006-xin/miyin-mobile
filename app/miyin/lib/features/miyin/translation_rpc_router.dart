import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

import '../../core/storage/translation_history_repository.dart';
import '../../core/translation/translation_contracts.dart';
import '../../core/translation/translation_service.dart';
import 'attachment_source_picker.dart';
import 'avatar_image_picker.dart';
import 'multilingual_asr_model_store.dart';
import 'multilingual_tts_model_store.dart';
import 'offline_english_chinese_dictionary.dart';
import 'offline_speech_recognizer.dart';
import 'offline_speech_synthesizer.dart';
import 'streaming_speech_playback.dart';
import 'translation_attachment_ocr.dart';

const _voiceChannel = MethodChannel('com.miyin.app/voice');
const _translationChannel = MethodChannel('com.miyin.app/translation');
const _attachmentOcrChannel = MethodChannel('com.miyin.app/attachment-ocr');
const _floatingChannel = MethodChannel('com.miyin.app/floating');

/// Validates and routes the narrow JSON protocol used by the local V5 page.
final class TranslationRpcRouter {
  const TranslationRpcRouter(
    this._service, {
    this.attachmentSourcePicker,
    this.translationImageSourcePicker,
    this.translationArticleSourcePicker,
    this.translationImageTextRecognizer,
    this.avatarImagePicker,
    this.englishChineseDictionary,
    this.installedTranslationModels,
    this.deleteTranslationLanguageModel,
    this.multilingualTtsStatusProvider,
    this.deleteMultilingualTtsModel,
  });

  Future<void> close() => _service.close();

  static const maxTextLength = 10000;
  static const maxDictionaryQueryLength = 128;
  static const _allowedMethods = <String>{
    'translation.supportedPairs',
    'translation.supportedLanguages',
    'translation.modelInfo',
    'translation.installedModels',
    'translation.downloadModel',
    'translation.deleteModel',
    'translation.deleteLanguageModel',
    'translation.preview',
    'translation.translate',
    'dictionary.lookup',
    'dictionary.lookupChinese',
    'dictionary.browse',
    'voice.startListening',
    'voice.stopListening',
    'voice.cancelListening',
    'voice.prepare',
    'voice.prepareUtterance',
    'voice.speak',
    'voice.stopSpeaking',
    'voice.offlineTtsStatus',
    'voice.multilingualTtsStatus',
    'voice.downloadMultilingualTts',
    'voice.deleteMultilingualTts',
    'voice.multilingualAsrStatus',
    'voice.downloadMultilingualAsr',
    'voice.deleteMultilingualAsr',
    'attachment.pickSource',
    'attachment.recognizeImage',
    'attachment.saveTranslatedImage',
    'attachment.pickArticle',
    'profile.pickAvatar',
    'floating.status',
    'floating.setEnabled',
    'history.list',
    'history.saveAttachment',
    'history.count',
    'history.get',
    'history.delete',
    'history.deleteMany',
    'history.clear',
  };

  final TranslationService _service;
  final AttachmentSourcePicker? attachmentSourcePicker;
  final TranslationImageSourcePicker? translationImageSourcePicker;
  final TranslationArticleSourcePicker? translationArticleSourcePicker;
  final TranslationImageTextRecognizer? translationImageTextRecognizer;
  final AvatarImagePicker? avatarImagePicker;
  final OfflineEnglishChineseDictionary? englishChineseDictionary;
  final Future<List<Map<String, Object?>>> Function()?
  installedTranslationModels;
  final Future<void> Function(String languageTag)?
  deleteTranslationLanguageModel;
  final Future<Map<String, Object?>> Function()? multilingualTtsStatusProvider;
  final Future<void> Function()? deleteMultilingualTtsModel;

  static final OfflineEnglishChineseDictionary _bundledDictionary =
      OfflineEnglishChineseDictionary();

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
    } on TranslationAttachmentException catch (error) {
      return _error(id, error.code, error.message);
    } on ArgumentError catch (error) {
      return _error(id, 'invalid_parameters', error.message.toString());
    } on PlatformException catch (error) {
      return _error(id, error.code, error.message ?? '本机语音功能暂时不可用。');
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
      case 'dictionary.lookup':
        final query = params['query'];
        if (query is! String || query.trim().isEmpty) {
          throw ArgumentError.value(query, 'query', '请输入要查的英语单词或短语。');
        }
        if (query.length > maxDictionaryQueryLength) {
          throw const TranslationFailure(
            'dictionary_query_too_long',
            '查词内容过长，请输入 128 个字符以内的英语词条。',
          );
        }
        final lookup = await (englishChineseDictionary ?? _bundledDictionary)
            .lookup(query);
        final entry = lookup.entry;
        return {
          'query': lookup.query,
          'normalizedQuery': lookup.normalizedQuery,
          'found': lookup.isFound,
          'matchedByNormalization': lookup.matchedByNormalization,
          if (entry != null) 'entry': _dictionaryEntryToMap(entry),
        };
      case 'dictionary.lookupChinese':
        final query = params['query'];
        if (query is! String || query.trim().isEmpty) {
          throw ArgumentError.value(query, 'query', '请输入要查的中文词条。');
        }
        if (query.length > maxDictionaryQueryLength) {
          throw const TranslationFailure(
            'dictionary_query_too_long',
            '查词内容过长，请输入 128 个字符以内的中文词条。',
          );
        }
        final lookup = await (englishChineseDictionary ?? _bundledDictionary)
            .lookupChinese(query);
        return {
          'query': lookup.query,
          'normalizedQuery': lookup.normalizedQuery,
          'found': lookup.isFound,
          'direction': 'zh-en',
          'entries': lookup.entries
              .map(_dictionaryEntryToMap)
              .toList(growable: false),
        };
      case 'dictionary.browse':
        final letter = params['letter'];
        final offset = params['offset'] ?? 0;
        final limit = params['limit'] ?? 24;
        if (letter is! String || offset is! int || limit is! int) {
          throw ArgumentError.value(params, 'params', '请输入有效的字母和分页范围。');
        }
        final page = await (englishChineseDictionary ?? _bundledDictionary)
            .browseByInitial(letter, offset: offset, limit: limit);
        return {
          'letter': page.letter,
          'offset': page.offset,
          'limit': page.limit,
          'total': page.total,
          'words': page.words,
          'ipaByWord': page.ipaByWord,
          'hasMore': page.hasMore,
        };
      case 'translation.supportedPairs':
        final pairs = await _service.getSupportedLanguagePairs();
        return pairs.map(_pairToMap).toList(growable: false);
      case 'translation.supportedLanguages':
        final languages = await _service.getSupportedLanguages();
        return languages
            .map(
              (language) => {'tag': language.tag, 'name': language.displayName},
            )
            .toList(growable: false);
      case 'translation.modelInfo':
        final pair = _readPair(params);
        final info = await _service.getModelInfo(pair);
        return {
          'status': info.status.name,
          'downloadedBytes': info.downloadedBytes,
          'totalBytes': info.totalBytes,
          'version': info.version,
        };
      case 'translation.installedModels':
        return await _readInstalledTranslationModels();
      case 'translation.downloadModel':
        final pair = _readPair(params);
        final wifiOnly = params['wifiOnly'];
        await _service.downloadModel(
          pair,
          wifiOnly: wifiOnly is bool ? wifiOnly : true,
        );
        return {'status': 'downloaded'};
      case 'translation.deleteModel':
        throw const TranslationFailure(
          'language_model_requires_explicit_delete',
          '翻译模型按语言共享。请在离线资源页选择具体语言包删除，并查看受影响的翻译方向。',
        );
      case 'translation.deleteLanguageModel':
        final rawTag = params['languageTag'];
        if (rawTag is! String || rawTag.trim().isEmpty) {
          throw ArgumentError.value(rawTag, 'languageTag', '请选择要删除的语言包。');
        }
        final language = _readLanguage(rawTag);
        if (language == TranslationLanguage.english) {
          throw const TranslationFailure(
            'built_in_language_model',
            '英语为 ML Kit 内置语言，不需要下载，也不能删除。',
          );
        }
        final delete = deleteTranslationLanguageModel;
        if (delete != null) {
          await delete(language.tag);
        } else {
          await _translationChannel.invokeMethod<void>('deleteLanguageModel', {
            'languageTag': language.tag,
          });
        }
        return {'status': 'deleted', 'languageTag': language.tag};
      case 'translation.preview':
        final text = params['text'];
        if (text is! String || text.trim().isEmpty) {
          throw ArgumentError.value(text, 'text', '请输入要翻译的文字。');
        }
        if (text.length > maxTextLength) {
          throw const TranslationFailure(
            'text_too_long',
            '翻译内容过长，请控制在 10,000 个字符以内。',
          );
        }
        final request = TranslationRequest(
          sourceLanguage: _readLanguage(params['sourceTag']),
          targetLanguage: _readLanguage(params['targetTag']),
          text: text,
        );
        final model = await _service.getModelInfo(request.languagePair);
        if (model.status != TranslationModelStatus.downloaded) {
          throw const TranslationFailure('model_missing', '请先下载当前语言组合的离线模型。');
        }
        final translation = await _service.engine.translate(request);
        if (translation.translatedText.trim().isEmpty) {
          throw const TranslationFailure('empty_translation', '本机翻译没有返回内容。');
        }
        return {
          'translatedText': translation.translatedText,
          'sourceTag': request.sourceLanguage.tag,
          'targetTag': request.targetLanguage.tag,
        };
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
      case 'voice.startListening':
        return MiyinOfflineSpeechRecognizer.instance.startListening(
          sessionId: _readSpeechSessionId(params['sessionId']),
          mode: _readSpeechMode(params['mode']),
          sourceTag: _readSpeechLanguageTag(params['sourceTag'], 'sourceTag'),
          targetTag: _readSpeechLanguageTag(params['targetTag'], 'targetTag'),
        );
      case 'voice.stopListening':
        return MiyinOfflineSpeechRecognizer.instance.stopListening(
          sessionId: _readSpeechSessionId(params['sessionId']),
        );
      case 'voice.cancelListening':
        return MiyinOfflineSpeechRecognizer.instance.cancelListening(
          sessionId: _readSpeechSessionId(params['sessionId']),
        );
      case 'voice.prepare':
        return MiyinOfflineSpeechSynthesizer.instance.prewarmVoice(
          languageTag: _readSpeechLanguage(params['languageTag']),
          provider: _readTtsProvider(params['provider']),
          speakerId: _readTtsSpeakerId(params['speakerId']),
        );
      case 'voice.prepareUtterance':
        final text = params['text'];
        if (text is! String || text.trim().isEmpty || text.length > 800) {
          throw const TranslationFailure('speech_text_invalid', '待朗读文字无效或过长。');
        }
        return MiyinOfflineSpeechSynthesizer.instance.prepareUtterance(
          languageTag: _readSpeechLanguage(params['languageTag']),
          text: text,
          speed: _readSpeechSpeed(params['speed']),
          provider: _readTtsProvider(params['provider']),
          speakerId: _readTtsSpeakerId(params['speakerId']),
        );
      case 'voice.speak':
        final text = params['text'];
        if (text is! String || text.trim().isEmpty) {
          throw ArgumentError.value(text, 'text', '没有可朗读的文字。');
        }
        if (text.length > 4000) {
          throw const TranslationFailure(
            'speech_text_too_long',
            '朗读内容过长，请选择较短的文字。',
          );
        }
        final sessionId = _readSpeechSessionId(params['sessionId']);
        final languageTag = _readSpeechLanguage(params['languageTag']);
        final speed = _readSpeechSpeed(params['speed']);
        final speakerId = _readTtsSpeakerId(params['speakerId']);
        final provider = _readTtsProvider(params['provider']);
        final synthesizer = MiyinOfflineSpeechSynthesizer.instance;
        if (params['streamAudio'] == true) {
          if (text.length > 800) {
            throw const TranslationFailure(
              'speech_text_too_long',
              '请分段朗读较长内容。',
            );
          }
          final playback = MiyinStreamingSpeechPlayback(
            sessionId: sessionId,
            invoke: (method, arguments) =>
                _voiceChannel.invokeMethod<Object?>(method, arguments),
            isCurrent: synthesizer.isCurrentSynthesisRequest,
          );
          unawaited(() async {
            try {
              final audio = await synthesizer.synthesize(
                sessionId: sessionId,
                languageTag: languageTag,
                text: text,
                speed: speed,
                speakerId: speakerId,
                provider: provider,
                onAudio: playback.add,
              );
              if (!synthesizer.isCurrentSynthesisRequest(
                audio['requestGeneration'],
              )) {
                await synthesizer.discardAudioFile(audio['path']);
                playback.completeCached({'status': 'cancelled'});
              } else if (audio['streamed'] == true) {
                await playback.finish();
              } else {
                try {
                  final result = await _voiceChannel.invokeMethod<Object?>(
                    'playAudio',
                    {'sessionId': sessionId, 'path': audio['path']},
                  );
                  playback.completeCached(result);
                } catch (_) {
                  await synthesizer.discardAudioFile(audio['path']);
                  rethrow;
                }
              }
            } catch (error, stack) {
              await playback.fail(error, stack);
            }
          }());
          return playback.started;
        }
        final audio = await synthesizer.synthesize(
          sessionId: sessionId,
          languageTag: languageTag,
          text: text,
          speed: speed,
          speakerId: speakerId,
          provider: provider,
        );
        if (!synthesizer.isCurrentSynthesisRequest(
          audio['requestGeneration'],
        )) {
          await synthesizer.discardAudioFile(audio['path']);
          return {'status': 'cancelled'};
        }
        // Keep the generation check adjacent to this call: after an `await`,
        // stopSpeaking or a newer speak request may have invalidated the WAV.
        try {
          return await _voiceChannel.invokeMethod<Object?>('playAudio', {
            'sessionId': sessionId,
            'path': audio['path'],
          });
        } catch (_) {
          await MiyinOfflineSpeechSynthesizer.instance.discardAudioFile(
            audio['path'],
          );
          rethrow;
        }
      case 'voice.stopSpeaking':
        MiyinOfflineSpeechSynthesizer.instance.cancelPending();
        return _voiceChannel.invokeMethod<Object?>('stopSpeaking');
      case 'voice.offlineTtsStatus':
        return MiyinOfflineSpeechSynthesizer.instance.status();
      case 'voice.multilingualTtsStatus':
        return _multilingualTtsStatus();
      case 'voice.downloadMultilingualTts':
        return MiyinMultilingualTtsModelStore.instance.download();
      case 'voice.deleteMultilingualTts':
        return _deleteMultilingualTts();
      case 'voice.multilingualAsrStatus':
        return MiyinMultilingualAsrModelStore.instance.status();
      case 'voice.downloadMultilingualAsr':
        return MiyinMultilingualAsrModelStore.instance.download();
      case 'voice.deleteMultilingualAsr':
        await MiyinOfflineSpeechRecognizer.instance.unloadMultilingualModel();
        await MiyinMultilingualAsrModelStore.instance.delete();
        return MiyinMultilingualAsrModelStore.instance.status();
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
      case 'attachment.saveTranslatedImage':
        final image = params['dataUrl'];
        if (image is! String ||
            !image.startsWith('data:image/jpeg;base64,') ||
            image.length > 4000000) {
          throw const TranslationFailure('image_invalid', '译图数据无效或过大。');
        }
        final saved = await _attachmentOcrChannel.invokeMethod<Object?>(
          'saveTranslatedImage',
          {'dataUrl': image},
        );
        return saved is Map
            ? Map<String, Object?>.from(saved)
            : <String, Object?>{'saved': false};
      case 'attachment.recognizeImage':
        final kind = _readAttachmentSourceKind(params['kind']);
        if (kind == AttachmentSourceKind.document) {
          throw ArgumentError.value(
            params['kind'],
            'kind',
            'Choose camera or image.',
          );
        }
        final picker = translationImageSourcePicker;
        if (picker == null) {
          throw const TranslationFailure(
            'source_picker_unavailable',
            '本机图片选择暂时不可用。',
          );
        }
        final PickedTranslationImage? selected;
        try {
          selected = await picker.pickTranslationImage(kind);
        } on TranslationAttachmentException {
          rethrow;
        } catch (_) {
          throw const TranslationFailure(
            'attachment_picker_failed',
            '系统相机或相册暂时无法打开。',
          );
        }
        if (selected == null) return {'canceled': true};
        try {
          final TranslationImageRecognition recognized;
          try {
            recognized =
                await (translationImageTextRecognizer ??
                        const BundledMlKitImageTextRecognizer())
                    .recognize(selected.path);
          } on MissingPluginException {
            throw const TranslationFailure(
              'image_ocr_unavailable',
              '本机图片文字识别暂不可用，请更新觅音应用后重试。',
            );
          } on PlatformException catch (error) {
            throw TranslationFailure(
              error.code == 'image_ocr_no_text'
                  ? 'image_ocr_no_text'
                  : error.code == 'image_invalid'
                  ? 'image_invalid'
                  : 'image_ocr_failed',
              error.message ?? '本机无法识别这张图片，请换一张清晰图片后重试。',
            );
          } catch (_) {
            throw const TranslationFailure(
              'image_ocr_failed',
              '本机无法识别这张图片，请换一张清晰图片后重试。',
            );
          }
          final boundedRecognition = recognized.limitBlocks();
          final text = boundedRecognition.recognizedText.trim();
          if (text.isEmpty) {
            throw const TranslationFailure(
              'image_ocr_no_text',
              '图片中没有识别到文字，请换一张清晰图片后重试。',
            );
          }
          if (text.length > maxTextLength) {
            throw const TranslationFailure(
              'text_too_long',
              '图片识别文字超过 10,000 字，请先编辑或缩短后重试。',
            );
          }
          return {
            'canceled': false,
            'name': selected.name,
            ...boundedRecognition.toRpcMap(),
          };
        } finally {
          await picker.disposeTranslationImage(selected);
        }
      case 'attachment.pickArticle':
        final picker = translationArticleSourcePicker;
        if (picker == null) {
          throw const TranslationFailure(
            'source_picker_unavailable',
            '本机文章选择暂时不可用。',
          );
        }
        final PickedArticleText? selected;
        try {
          selected = await picker.pickArticleText();
        } on TranslationAttachmentException {
          rethrow;
        } catch (_) {
          throw const TranslationFailure(
            'attachment_picker_failed',
            '文章选择器暂时无法打开。',
          );
        }
        if (selected == null) return {'canceled': true};
        final text = selected.text;
        if (text.trim().isEmpty) {
          throw const TranslationFailure('article_empty', '所选文件没有可翻译的文字。');
        }
        if (text.length > maxTextLength) {
          throw const TranslationFailure(
            'text_too_long',
            '文章超过 10,000 个字符，请缩短后重试。',
          );
        }
        return {'canceled': false, 'name': selected.name, 'text': text};
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
      case 'floating.status':
        return await _floatingChannel.invokeMethod<Map<Object?, Object?>>(
              'status',
            ) ??
            {'enabled': false, 'permissionGranted': false};
      case 'floating.setEnabled':
        final enabled = params['enabled'];
        if (enabled is! bool) {
          throw const TranslationFailure('invalid_parameters', '悬浮球状态无效。');
        }
        return await _floatingChannel.invokeMethod<Map<Object?, Object?>>(
              'setEnabled',
              {'enabled': enabled},
            ) ??
            {'enabled': false, 'permissionGranted': false};
      case 'history.saveAttachment':
        final kind = params['kind'];
        final name = params['name'];
        final sourceTag = params['sourceTag'];
        final targetTag = params['targetTag'];
        final rawRows = params['rows'];
        if ((kind != 'image' && kind != 'article') ||
            name is! String ||
            sourceTag is! String ||
            targetTag is! String ||
            rawRows is! List ||
            rawRows.isEmpty ||
            rawRows.length > maxTextLength) {
          throw const TranslationFailure('invalid_parameters', '图片或文章历史内容无效。');
        }
        final rows = <Map<String, String>>[];
        for (final rawRow in rawRows) {
          if (rawRow is! Map ||
              rawRow['sourceText'] is! String ||
              rawRow['translatedText'] is! String) {
            throw const TranslationFailure('invalid_parameters', '翻译对照内容无效。');
          }
          rows.add({
            'sourceText': rawRow['sourceText'] as String,
            'translatedText': rawRow['translatedText'] as String,
          });
        }
        final sourceText = rows.map((row) => row['sourceText']).join('\n\n');
        final translatedText = rows
            .map((row) => row['translatedText'])
            .join('\n\n');
        if (sourceText.length > maxTextLength ||
            translatedText.length > maxTextLength * 3) {
          throw const TranslationFailure('text_too_long', '历史内容过长，无法保存。');
        }
        final originalImage = params['originalImage'];
        final translatedImage = params['translatedImage'];
        if (kind == 'image' &&
            (originalImage is! String || translatedImage is! String)) {
          throw const TranslationFailure('invalid_parameters', '图片历史缺少原图或译图。');
        }
        final historyId = await _service.saveAttachmentHistory(
          kind: kind as String,
          name: name.length > 160 ? name.substring(0, 160) : name,
          sourceTag: sourceTag,
          targetTag: targetTag,
          rowsJson: jsonEncode(rows),
          sourceText: sourceText,
          translatedText: translatedText,
          originalImageDataUrl: originalImage as String?,
          translatedImageDataUrl: translatedImage as String?,
        );
        return {'id': historyId, 'saved': true};
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
        if (entry == null) return null;
        return {
          ..._historyToMap(entry),
          if (entry.attachmentRowsJson != null)
            'rows': jsonDecode(entry.attachmentRowsJson!),
          if (entry.attachmentKind == 'image')
            'originalImage': await _service.readHistoryImage(
              entry.originalImagePath,
            ),
          if (entry.attachmentKind == 'image')
            'translatedImage': await _service.readHistoryImage(
              entry.translatedImagePath,
            ),
        };
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

  Future<Map<String, Object?>> _multilingualTtsStatus() =>
      multilingualTtsStatusProvider?.call() ??
      MiyinMultilingualTtsModelStore.instance.status();

  Future<Map<String, Object?>> _deleteMultilingualTts() async {
    final status = await _multilingualTtsStatus();
    if (status['bundled'] == true || status['source'] == 'apk') {
      return {...status, 'deleted': false, 'deleteReason': 'bundled_in_apk'};
    }
    if (status['installed'] != true) {
      return {...status, 'deleted': false, 'deleteReason': 'not_installed'};
    }
    if (status['source'] != 'downloaded' || status['deletable'] != true) {
      return {
        ...status,
        'deleted': false,
        'deleteReason': 'resource_not_deletable',
      };
    }

    await MiyinOfflineSpeechSynthesizer.instance.unloadMultilingualModel();
    final delete = deleteMultilingualTtsModel;
    if (delete == null) {
      await MiyinMultilingualTtsModelStore.instance.delete();
    } else {
      await delete();
    }
    return {...await _multilingualTtsStatus(), 'deleted': true};
  }

  Future<List<Map<String, Object?>>> _readInstalledTranslationModels() async {
    final readModels = installedTranslationModels;
    final List<Map<String, Object?>> models;
    if (readModels != null) {
      models = await readModels();
    } else {
      final values =
          await _translationChannel.invokeMethod<List<Object?>>(
            'getDownloadedModels',
          ) ??
          const <Object?>[];
      models = values
          .map((value) {
            if (value is! Map) {
              throw const TranslationFailure(
                'invalid_engine_response',
                '本机翻译资源目录格式无效。',
              );
            }
            return Map<String, Object?>.from(value);
          })
          .toList(growable: false);
    }

    final result = <Map<String, Object?>>[];
    final seenTags = <String>{};
    for (final model in models) {
      final rawTag = model['tag'];
      final rawName = model['name'];
      if (rawTag is! String || rawName is! String) {
        throw const TranslationFailure(
          'invalid_engine_response',
          '本机翻译资源目录缺少语言标识。',
        );
      }
      final language = _readLanguage(rawTag);
      if (language == TranslationLanguage.english ||
          !seenTags.add(language.tag)) {
        continue;
      }
      result.add({'tag': language.tag, 'name': rawName});
    }
    result.sort(
      (left, right) =>
          (left['name'] as String).compareTo(right['name'] as String),
    );
    return result;
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

  static String _readSpeechSessionId(Object? value) {
    if (value is! String ||
        value.isEmpty ||
        value.length > 96 ||
        !RegExp(r'^[A-Za-z0-9_.:-]+$').hasMatch(value)) {
      throw ArgumentError.value(value, 'sessionId', 'Invalid voice session.');
    }
    return value;
  }

  static String _readSpeechMode(Object? value) {
    if (value == null || value == 'translation') return 'translation';
    if (value == 'face') return 'face';
    if (value == 'video') return 'video';
    if (value == 'chat') return 'chat';
    throw ArgumentError.value(value, 'mode', 'Invalid speech mode.');
  }

  static String? _readSpeechLanguageTag(Object? value, String key) {
    if (value == null) return null;
    if (value is String &&
        value.length <= 64 &&
        RegExp(r'^[A-Za-z0-9-]+$').hasMatch(value)) {
      return value;
    }
    throw ArgumentError.value(value, key, 'Invalid speech language tag.');
  }

  static String _readSpeechLanguage(Object? value) {
    if (value is String &&
        (value == 'zh-Hans' ||
            value == 'en' ||
            MiyinMultilingualTtsModelStore.supportedLanguageTags.contains(
              value,
            ))) {
      return value;
    }
    throw ArgumentError.value(value, 'languageTag', '当前语言暂不支持语音识别或朗读。');
  }

  static int _readTtsSpeakerId(Object? value) {
    if (value == null) return 0;
    if (value is int && value >= 0 && value <= 9) return value;
    throw ArgumentError.value(value, 'speakerId', '请选择有效的离线音色。');
  }

  static String _readTtsProvider(Object? value) {
    if (value == null || value == 'melo') return 'melo';
    if (value == 'supertonic') return 'supertonic';
    throw ArgumentError.value(value, 'provider', '请选择有效的离线语音模型。');
  }

  static double _readSpeechSpeed(Object? value) {
    if (value == null) return 1.0;
    if (value is num && value >= 0.75 && value <= 1.25) {
      return value.toDouble();
    }
    throw ArgumentError.value(value, 'speed', '播报速度超出范围。');
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

  static Map<String, Object?> _dictionaryEntryToMap(
    EnglishChineseDictionaryEntry entry,
  ) => {
    'word': entry.word,
    'ipa': entry.ipa,
    'senses': entry.senses
        .map(
          (sense) => {
            'synsetId': sense.synsetId,
            'partOfSpeech': sense.partOfSpeech,
            'definition': sense.definition,
            'translations': sense.translations,
            'examples': sense.examples,
          },
        )
        .toList(growable: false),
  };

  static Map<String, Object?> _historyToMap(TranslationHistoryEntry entry) => {
    'id': entry.id,
    'sourceText': entry.sourceText,
    'translatedText': entry.translatedText,
    'sourceTag': entry.sourceLanguageTag,
    'targetTag': entry.targetLanguageTag,
    'engineId': entry.engineId,
    'modelVersion': entry.modelVersion,
    'kind': entry.attachmentKind,
    if (entry.attachmentName != null) 'name': entry.attachmentName,
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
