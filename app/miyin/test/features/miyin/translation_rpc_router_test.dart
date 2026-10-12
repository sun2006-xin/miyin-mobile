import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:miyin_app/core/storage/translation_history_repository.dart';
import 'package:miyin_app/core/translation/translation_contracts.dart';
import 'package:miyin_app/core/translation/translation_service.dart';
import 'package:miyin_app/features/miyin/attachment_source_picker.dart';
import 'package:miyin_app/features/miyin/avatar_image_picker.dart';
import 'package:miyin_app/features/miyin/translation_rpc_router.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory tempDirectory;
  late SqliteTranslationHistoryRepository history;
  late _FakeTranslationEngine engine;
  late _FakeAttachmentSourcePicker attachmentPicker;
  late _FakeAvatarImagePicker avatarImagePicker;
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
    router = TranslationRpcRouter(
      TranslationService(engine: engine, history: history),
      attachmentSourcePicker: attachmentPicker,
      avatarImagePicker: avatarImagePicker,
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

  @override
  String get engineId => 'rpc-test-engine';

  @override
  Future<void> deleteModel(TranslationLanguagePair pair) async {}

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
