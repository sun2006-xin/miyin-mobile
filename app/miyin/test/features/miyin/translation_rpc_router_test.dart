import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:miyin_app/core/storage/translation_history_repository.dart';
import 'package:miyin_app/core/translation/translation_contracts.dart';
import 'package:miyin_app/core/translation/translation_service.dart';
import 'package:miyin_app/features/miyin/attachment_source_picker.dart';
import 'package:miyin_app/features/miyin/avatar_image_picker.dart';
import 'package:miyin_app/features/miyin/offline_english_chinese_dictionary.dart';
import 'package:miyin_app/features/miyin/translation_rpc_router.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory tempDirectory;
  late SqliteTranslationHistoryRepository history;
  late _FakeTranslationEngine engine;
  late _FakeAttachmentSourcePicker attachmentPicker;
  late _FakeAvatarImagePicker avatarImagePicker;
  late List<Map<String, Object?>> installedTranslationModels;
  late List<String> deletedTranslationLanguageTags;
  late Map<String, Object?> multilingualTtsStatus;
  late bool multilingualTtsDeleteCalled;
  late TranslationRpcRouter router;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    tempDirectory = await Directory.systemTemp.createTemp('miyin-rpc-');
    history = await SqliteTranslationHistoryRepository.open(
      path: '${tempDirectory.path}${Platform.pathSeparator}history.db',
      databaseFactory: databaseFactoryFfi,
    );
    engine = _FakeTranslationEngine();
    attachmentPicker = _FakeAttachmentSourcePicker();
    avatarImagePicker = _FakeAvatarImagePicker();
    installedTranslationModels = [
      {'tag': 'ja', 'name': '日语'},
      {'tag': 'fr', 'name': '法语'},
    ];
    deletedTranslationLanguageTags = [];
    multilingualTtsStatus = {
      'status': 'bundled',
      'installed': true,
      'bundled': true,
      'source': 'apk',
      'deletable': false,
    };
    multilingualTtsDeleteCalled = false;
    router = TranslationRpcRouter(
      TranslationService(engine: engine, history: history),
      attachmentSourcePicker: attachmentPicker,
      avatarImagePicker: avatarImagePicker,
      installedTranslationModels: () async => installedTranslationModels,
      deleteTranslationLanguageModel: (tag) async {
        deletedTranslationLanguageTags.add(tag);
      },
      multilingualTtsStatusProvider: () async => multilingualTtsStatus,
      deleteMultilingualTtsModel: () async {
        multilingualTtsDeleteCalled = true;
        multilingualTtsStatus = {
          'status': 'unavailable',
          'installed': false,
          'bundled': false,
          'deleted': true,
        };
      },
      englishChineseDictionary: OfflineEnglishChineseDictionary(
        loadAsset: () async => jsonEncode({
          'word': 'bank',
          'senses': [
            {
              'synsetId': '09213565-n',
              'partOfSpeech': 'noun',
              'definition': 'a financial institution',
              'translations': ['银行'],
              'examples': ['the bank is open'],
            },
          ],
        }),
        loadIpaAsset: () async => jsonEncode({'word': 'bank', 'ipa': '/bæŋk/'}),
      ),
    );
  });

  tearDown(() async {
    await history.close();
    await tempDirectory.delete(recursive: true);
  });

  Future<int> addHistoryEntry(String source) => history.saveTranslation(
    TranslationResult(
      request: TranslationRequest(
        sourceLanguage: TranslationLanguage.simplifiedChinese,
        targetLanguage: TranslationLanguage.english,
        text: source,
      ),
      translatedText: 'translated $source',
      engineId: 'rpc-test-engine',
    ),
  );

  test(
    'returns request IDs with successful translation and database result',
    () async {
      final response = await router.handle(
        jsonEncode({
          'version': 1,
          'id': 'request-1',
          'method': 'translation.translate',
          'params': {'sourceTag': 'zh-Hans', 'targetTag': 'en', 'text': '你好'},
        }),
      );

      expect(response['id'], 'request-1');
      expect(response['ok'], isTrue);
      expect((response['result'] as Map)['translatedText'], 'Hello');
      expect((response['result'] as Map)['historySaved'], isTrue);
      expect((response['result'] as Map)['historyEntryId'], isA<int>());
      expect(await history.countTranslations(), 1);
    },
  );

  test('supports the reverse language direction', () async {
    final response = await router.handle(
      jsonEncode({
        'version': 1,
        'id': 'request-reverse',
        'method': 'translation.translate',
        'params': {'sourceTag': 'en', 'targetTag': 'zh-Hans', 'text': 'Hello'},
      }),
    );

    expect(response['ok'], isTrue);
    final entry = (response['result'] as Map);
    expect(entry['translatedText'], '你好');
    expect(entry['sourceTag'], 'en');
    expect(entry['targetTag'], 'zh-Hans');
    expect(await history.countTranslations(), 1);
  });

  test(
    'accepts AI fast speech preparation and preserves existing providers',
    () async {
      for (final provider in ['matcha', 'melo', 'supertonic']) {
        final response = await router.handle(
          jsonEncode({
            'version': 1,
            'id': 'prepare-$provider',
            'method': 'voice.prepare',
            'params': {
              'languageTag': 'zh-Hans',
              'provider': provider,
              'speakerId': 0,
            },
          }),
        );
        expect(response['ok'], isTrue);
        expect((response['result'] as Map)['provider'], provider);
        expect((response['result'] as Map)['status'], 'preparing');
      }
    },
  );

  test(
    'rejects an unknown speech provider before preparing any model',
    () async {
      final response = await router.handle(
        jsonEncode({
          'version': 1,
          'id': 'invalid-voice-provider',
          'method': 'voice.prepare',
          'params': {'languageTag': 'zh-Hans', 'provider': 'unknown'},
        }),
      );
      expect(response['ok'], isFalse);
      expect((response['error'] as Map)['code'], 'invalid_parameters');
    },
  );

  test(
    'translation preview returns local text without saving history',
    () async {
      final response = await router.handle(
        jsonEncode({
          'version': 1,
          'id': 'preview-translation',
          'method': 'translation.preview',
          'params': {
            'sourceTag': 'en',
            'targetTag': 'zh-Hans',
            'text': 'Hello',
          },
        }),
      );

      expect(response['ok'], isTrue);
      expect((response['result'] as Map)['translatedText'], '你好');
      expect((response['result'] as Map)['sourceTag'], 'en');
      expect((response['result'] as Map)['targetTag'], 'zh-Hans');
      expect(engine.translateCalls, 1);
      expect(await history.countTranslations(), 0);
    },
  );

  test('bundled multilingual TTS delete RPC is a successful no-op', () async {
    final response = await router.handle(
      jsonEncode({
        'version': 1,
        'id': 'delete-bundled-tts',
        'method': 'voice.deleteMultilingualTts',
      }),
    );

    expect(response['ok'], isTrue);
    expect((response['result'] as Map)['bundled'], isTrue);
    expect((response['result'] as Map)['deleted'], isFalse);
    expect((response['result'] as Map)['deleteReason'], 'bundled_in_apk');
    expect(multilingualTtsDeleteCalled, isFalse);
  });

  test(
    'TTS delete RPC deletes only an explicitly deletable download',
    () async {
      multilingualTtsStatus = {
        'status': 'downloaded',
        'installed': true,
        'bundled': false,
        'source': 'downloaded',
        'deletable': true,
      };

      final response = await router.handle(
        jsonEncode({
          'version': 1,
          'id': 'delete-downloaded-tts',
          'method': 'voice.deleteMultilingualTts',
        }),
      );

      expect(response['ok'], isTrue);
      expect(multilingualTtsDeleteCalled, isTrue);
      expect((response['result'] as Map)['deleted'], isTrue);
    },
  );

  test(
    'dictionary RPC returns an exact local entry and source senses',
    () async {
      final response = await router.handle(
        jsonEncode({
          'version': 1,
          'id': 'dictionary-bank',
          'method': 'dictionary.lookup',
          'params': {'query': ' BANK '},
        }),
      );

      expect(response['ok'], isTrue);
      final result = response['result'] as Map;
      expect(result['found'], isTrue);
      expect(result['normalizedQuery'], 'bank');
      final entry = result['entry'] as Map;
      expect(entry['word'], 'bank');
      expect(entry['ipa'], '/bæŋk/');
      final sense = (entry['senses'] as List).single as Map;
      expect(sense['translations'], ['银行']);
      expect(sense['definition'], 'a financial institution');
      expect(sense['synsetId'], '09213565-n');
      expect(await history.countTranslations(), 0);
      expect(engine.translateCalls, 0);
    },
  );

  test(
    'dictionary RPC supports the reverse Chinese-to-English direction',
    () async {
      final response = await router.handle(
        jsonEncode({
          'version': 1,
          'id': 'dictionary-bank-reverse',
          'method': 'dictionary.lookupChinese',
          'params': {'query': '银行'},
        }),
      );

      expect(response['ok'], isTrue);
      final result = response['result'] as Map;
      expect(result['direction'], 'zh-en');
      final entry = (result['entries'] as List).single as Map;
      expect(entry['word'], 'bank');
      expect(entry['ipa'], '/bæŋk/');
      expect((entry['senses'] as List).single['translations'], ['银行']);
    },
  );

  test('dictionary browse RPC returns one bounded initial page', () async {
    final response = await router.handle(
      jsonEncode({
        'version': 1,
        'id': 'dictionary-browse-b',
        'method': 'dictionary.browse',
        'params': {'letter': 'b', 'offset': 0, 'limit': 8},
      }),
    );

    expect(response['ok'], isTrue);
    final result = response['result'] as Map;
    expect(result['letter'], 'B');
    expect(result['total'], 1);
    expect(result['words'], ['bank']);
    expect(result['ipaByWord'], {'bank': '/bæŋk/'});
    expect(result['hasMore'], isFalse);
  });

  test(
    'dictionary browse RPC rejects invalid letters and page sizes',
    () async {
      final response = await router.handle(
        jsonEncode({
          'version': 1,
          'id': 'dictionary-browse-invalid',
          'method': 'dictionary.browse',
          'params': {'letter': '1', 'limit': 999},
        }),
      );

      expect(response['ok'], isFalse);
      expect((response['error'] as Map)['code'], 'invalid_parameters');
    },
  );

  test(
    'translation resource RPC lists all installed ML Kit language models',
    () async {
      final response = await router.handle(
        jsonEncode({
          'version': 1,
          'id': 'translation-installed-models',
          'method': 'translation.installedModels',
          'params': {},
        }),
      );

      expect(response['ok'], isTrue);
      expect(response['result'], installedTranslationModels);
    },
  );

  test('translation resource RPC deletes only the explicitly selected language model', () async {
    final response = await router.handle(
      jsonEncode({
        'version': 1,
        'id': 'translation-delete-ja',
        'method': 'translation.deleteLanguageModel',
        'params': {'languageTag': 'ja'},
      }),
    );

    expect(response['ok'], isTrue);
    expect((response['result'] as Map)['status'], 'deleted');
    expect(deletedTranslationLanguageTags, ['ja']);
  });

  test('translation resource RPC refuses to delete built-in English', () async {
    final response = await router.handle(
      jsonEncode({
        'version': 1,
        'id': 'translation-delete-en',
        'method': 'translation.deleteLanguageModel',
        'params': {'languageTag': 'en'},
      }),
    );

    expect(response['ok'], isFalse);
    expect((response['error'] as Map)['code'], 'built_in_language_model');
    expect(deletedTranslationLanguageTags, isEmpty);
  });

  test(
    'legacy pair deletion is rejected to protect shared language models',
    () async {
      final response = await router.handle(
        jsonEncode({
          'version': 1,
          'id': 'translation-delete-pair',
          'method': 'translation.deleteModel',
          'params': {'sourceTag': 'zh-Hans', 'targetTag': 'en'},
        }),
      );

      expect(response['ok'], isFalse);
      expect(
        (response['error'] as Map)['code'],
        'language_model_requires_explicit_delete',
      );
      expect(engine.deleteModelCalls, 0);
    },
  );

  test('dictionary RPC rejects empty or oversized queries', () async {
    final empty = await router.handle(
      jsonEncode({
        'version': 1,
        'id': 'dictionary-empty',
        'method': 'dictionary.lookup',
        'params': {'query': '  '},
      }),
    );
    final oversized = await router.handle(
      jsonEncode({
        'version': 1,
        'id': 'dictionary-long',
        'method': 'dictionary.lookup',
        'params': {'query': 'x' * 129},
      }),
    );

    expect(empty['ok'], isFalse);
    expect((empty['error'] as Map)['code'], 'invalid_parameters');
    expect(oversized['ok'], isFalse);
    expect((oversized['error'] as Map)['code'], 'dictionary_query_too_long');
    expect(engine.translateCalls, 0);
  });

  test(
    'profile avatar RPC returns only a validated local image data URL',
    () async {
      avatarImagePicker.nextResult = const PickedAvatarImage(
        dataUrl: 'data:image/jpeg;base64,/9j/2Q==',
      );

      final response = await router.handle(
        jsonEncode({
          'version': 1,
          'id': 'avatar-pick',
          'method': 'profile.pickAvatar',
          'params': {'source': 'gallery'},
        }),
      );

      expect(response['ok'], isTrue);
      expect(avatarImagePicker.requestedSources, [AvatarImageSource.gallery]);
      final result = response['result'] as Map;
      expect(result['dataUrl'], 'data:image/jpeg;base64,/9j/2Q==');
      expect(result.containsKey('path'), isFalse);
      expect(result.containsKey('uri'), isFalse);
    },
  );

  test(
    'avatar RPC reports cancellation without overwriting an existing avatar',
    () async {
      avatarImagePicker.nextResult = null;

      final response = await router.handle(
        jsonEncode({
          'version': 1,
          'id': 'avatar-cancel',
          'method': 'profile.pickAvatar',
          'params': {'source': 'camera'},
        }),
      );

      expect(response['ok'], isTrue);
      expect(avatarImagePicker.requestedSources, [AvatarImageSource.camera]);
      expect((response['result'] as Map)['canceled'], isTrue);
    },
  );

  test('opens the requested local source and returns metadata only', () async {
    attachmentPicker.nextResult = const PickedAttachmentSource(
      kind: AttachmentSourceKind.image,
      name: 'station-map.png',
      mimeType: 'image/png',
    );

    final response = await router.handle(
      jsonEncode({
        'version': 1,
        'id': 'pick-image',
        'method': 'attachment.pickSource',
        'params': {'kind': 'image'},
      }),
    );

    expect(response['ok'], isTrue);
    expect(attachmentPicker.requestedKinds, [AttachmentSourceKind.image]);
    expect(
      (response['result'] as Map).keys,
      containsAll(['kind', 'name', 'mimeType']),
    );
    expect((response['result'] as Map)['name'], 'station-map.png');
    expect((response['result'] as Map).containsKey('path'), isFalse);
    expect((response['result'] as Map).containsKey('uri'), isFalse);
    expect((response['result'] as Map).containsKey('bytes'), isFalse);
  });

  test('reports picker cancellation without treating it as an error', () async {
    attachmentPicker.nextResult = null;

    final response = await router.handle(
      jsonEncode({
        'version': 1,
        'id': 'pick-cancel',
        'method': 'attachment.pickSource',
        'params': {'kind': 'document'},
      }),
    );

    expect(response['ok'], isTrue);
    expect((response['result'] as Map)['canceled'], isTrue);
  });

  test('rejects unknown source kinds before opening the picker', () async {
    final response = await router.handle(
      jsonEncode({
        'version': 1,
        'id': 'pick-invalid',
        'method': 'attachment.pickSource',
        'params': {'kind': 'folder'},
      }),
    );

    expect(response['ok'], isFalse);
    expect((response['error'] as Map)['code'], 'invalid_parameters');
    expect(attachmentPicker.requestedKinds, isEmpty);
  });

  test(
    'rejects unknown methods and invalid payloads with stable errors',
    () async {
      final unknown = await router.handle(
        jsonEncode({
          'version': 1,
          'id': 'request-2',
          'method': 'device.openEverything',
          'params': {},
        }),
      );
      final invalid = await router.handle('{not-json');

      expect(unknown['id'], 'request-2');
      expect(unknown['ok'], isFalse);
      expect((unknown['error'] as Map)['code'], 'method_not_allowed');
      expect(invalid['ok'], isFalse);
      expect((invalid['error'] as Map)['code'], 'invalid_request');
    },
  );

  test('rejects oversized input before calling the engine', () async {
    final response = await router.handle(
      jsonEncode({
        'version': 1,
        'id': 'request-3',
        'method': 'translation.translate',
        'params': {
          'sourceTag': 'zh-Hans',
          'targetTag': 'en',
          'text': 'x' * 10001,
        },
      }),
    );

    expect(response['ok'], isFalse);
    expect((response['error'] as Map)['code'], 'text_too_long');
    expect(engine.translateCalls, 0);
  });

  test(
    'history.deleteMany removes unique matching rows and reports actual count',
    () async {
      final firstId = await addHistoryEntry('first');
      final keptId = await addHistoryEntry('keep');
      final thirdId = await addHistoryEntry('third');

      final response = await router.handle(
        jsonEncode({
          'version': 1,
          'id': 'delete-many',
          'method': 'history.deleteMany',
          'params': {
            'ids': [firstId, thirdId, firstId, 999999],
          },
        }),
      );

      expect(response['ok'], isTrue);
      expect((response['result'] as Map)['deletedCount'], 2);
      expect(await history.countTranslations(), 1);
      expect(await history.getTranslation(keptId), isNotNull);
    },
  );

  test(
    'history.deleteMany accepts an empty ID list and returns zero',
    () async {
      final savedId = await addHistoryEntry('keep');

      final response = await router.handle(
        jsonEncode({
          'version': 1,
          'id': 'delete-many-empty',
          'method': 'history.deleteMany',
          'params': {'ids': []},
        }),
      );

      expect(response['ok'], isTrue);
      expect((response['result'] as Map)['deletedCount'], 0);
      expect(await history.getTranslation(savedId), isNotNull);
    },
  );

  test(
    'history.deleteMany rejects invalid IDs without partially deleting rows',
    () async {
      final savedId = await addHistoryEntry('must remain');
      final invalidParams = <Map<String, Object?>>[
        {},
        {'ids': null},
        {'ids': '1'},
        {
          'ids': [savedId, 0],
        },
        {
          'ids': [savedId, -1],
        },
        {
          'ids': [savedId, '2'],
        },
        {
          'ids': [savedId, 1.5],
        },
        {
          'ids': [savedId, true],
        },
      ];

      for (var index = 0; index < invalidParams.length; index++) {
        final response = await router.handle(
          jsonEncode({
            'version': 1,
            'id': 'delete-many-invalid-$index',
            'method': 'history.deleteMany',
            'params': invalidParams[index],
          }),
        );

        expect(
          response['ok'],
          isFalse,
          reason: 'case $index should be rejected',
        );
        expect((response['error'] as Map)['code'], 'invalid_parameters');
        expect(await history.countTranslations(), 1);
        expect(await history.getTranslation(savedId), isNotNull);
      }
    },
  );
}

final class _FakeTranslationEngine implements TranslationEngine {
  int translateCalls = 0;
  int deleteModelCalls = 0;

  @override
  String get engineId => 'rpc-test-engine';

  @override
  Future<void> deleteModel(TranslationLanguagePair pair) async {
    deleteModelCalls++;
  }

  @override
  Future<void> downloadModel(
    TranslationLanguagePair pair, {
    required bool wifiOnly,
  }) async {}

  @override
  Future<TranslationModelInfo> getModelInfo(
    TranslationLanguagePair pair,
  ) async =>
      const TranslationModelInfo(status: TranslationModelStatus.downloaded);

  @override
  Future<Set<TranslationLanguagePair>> getSupportedLanguagePairs() async => {
    TranslationLanguagePair(
      sourceLanguage: TranslationLanguage.simplifiedChinese,
      targetLanguage: TranslationLanguage.english,
    ),
    TranslationLanguagePair(
      sourceLanguage: TranslationLanguage.english,
      targetLanguage: TranslationLanguage.simplifiedChinese,
    ),
  };

  @override
  Future<TranslationResult> translate(TranslationRequest request) async {
    translateCalls++;
    return TranslationResult(
      request: request,
      translatedText: request.sourceLanguage == TranslationLanguage.english
          ? '你好'
          : 'Hello',
      engineId: engineId,
    );
  }
}

final class _FakeAttachmentSourcePicker implements AttachmentSourcePicker {
  final requestedKinds = <AttachmentSourceKind>[];
  PickedAttachmentSource? nextResult;

  @override
  Future<PickedAttachmentSource?> pick(AttachmentSourceKind kind) async {
    requestedKinds.add(kind);
    return nextResult;
  }
}

final class _FakeAvatarImagePicker implements AvatarImagePicker {
  final requestedSources = <AvatarImageSource>[];
  PickedAvatarImage? nextResult;

  @override
  Future<PickedAvatarImage?> pick(AvatarImageSource source) async {
    requestedSources.add(source);
    return nextResult;
  }
}
