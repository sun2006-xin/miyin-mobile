import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:miyin_app/core/storage/translation_history_repository.dart';
import 'package:miyin_app/core/translation/translation_contracts.dart';
import 'package:miyin_app/core/translation/translation_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory tempDirectory;
  late SqliteTranslationHistoryRepository repository;
  late _FakeTranslationEngine engine;
  late TranslationService service;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    tempDirectory = await Directory.systemTemp.createTemp('miyin-service-');
    repository = await SqliteTranslationHistoryRepository.open(
      path: '${tempDirectory.path}${Platform.pathSeparator}history.db',
      databaseFactory: databaseFactoryFfi,
    );
    engine = _FakeTranslationEngine();
    service = TranslationService(engine: engine, history: repository);
  });

  tearDown(() async {
    await repository.close();
    await tempDirectory.delete(recursive: true);
  });

  TranslationRequest request() => TranslationRequest(
    sourceLanguage: TranslationLanguage.simplifiedChinese,
    targetLanguage: TranslationLanguage.english,
    text: '  你好  ',
  );

  test('translates and saves only a successful result', () async {
    final outcome = await service.translateAndSave(request());
    final saved = await repository.getTranslation(outcome.historyEntryId!);

    expect(outcome.historySaved, isTrue);
    expect(outcome.historyEntryId, isA<int>());
    expect(saved, isNotNull);
    expect(saved!.sourceText, '  你好  ');
    expect(saved.translatedText, 'Hello');
    expect(saved.sourceLanguageTag, 'zh-Hans');
    expect(saved.targetLanguageTag, 'en');
    expect(await repository.countTranslations(), 1);
  });

  test('does not translate or save when the model is missing', () async {
    engine.modelInfo = const TranslationModelInfo(
      status: TranslationModelStatus.notDownloaded,
    );

    await expectLater(
      service.translateAndSave(request()),
      throwsA(
        isA<TranslationFailure>().having(
          (e) => e.code,
          'code',
          'model_missing',
        ),
      ),
    );

    expect(engine.translateCalls, 0);
    expect(await repository.countTranslations(), 0);
  });

  test('does not save when the engine fails', () async {
    engine.failTranslation = true;

    await expectLater(
      service.translateAndSave(request()),
      throwsA(isA<TranslationFailure>()),
    );

    expect(await repository.countTranslations(), 0);
  });

  test(
    'clear history waits for an in-flight translation before deleting it',
    () async {
      final translationStarted = Completer<void>();
      final finishTranslation = Completer<void>();
      engine.translationStarted = translationStarted;
      engine.translationGate = finishTranslation;

      final translation = service.translateAndSave(request());
      await translationStarted.future;

      var clearFinished = false;
      final clear = service.clearHistory().then((deleted) {
        clearFinished = true;
        return deleted;
      });
      await Future<void>.delayed(Duration.zero);

      expect(clearFinished, isFalse);
      expect(await repository.countTranslations(), 0);

      finishTranslation.complete();
      final outcome = await translation;
      final deletedCount = await clear;

      expect(outcome.historySaved, isTrue);
      expect(deletedCount, 1);
      expect(await repository.countTranslations(), 0);
    },
  );

  test(
    'close waits for active work and rejects later history requests',
    () async {
      final translationStarted = Completer<void>();
      final finishTranslation = Completer<void>();
      engine.translationStarted = translationStarted;
      engine.translationGate = finishTranslation;

      final translation = service.translateAndSave(request());
      await translationStarted.future;

      var closeFinished = false;
      final closing = service.close().then((_) => closeFinished = true);
      await Future<void>.delayed(Duration.zero);
      expect(closeFinished, isFalse);

      finishTranslation.complete();
      await translation;
      await closing;

      expect(closeFinished, isTrue);
      await expectLater(service.countHistory(), throwsA(isA<StateError>()));
    },
  );

  test(
    'rejects unsupported model operations before calling the engine',
    () async {
      final unsupportedPair = TranslationLanguagePair(
        sourceLanguage: TranslationLanguage.fromTag('ja', displayName: '日本語'),
        targetLanguage: TranslationLanguage.english,
      );

      await expectLater(
        service.getModelInfo(unsupportedPair),
        throwsA(
          isA<TranslationFailure>().having(
            (e) => e.code,
            'code',
            'unsupported_language_pair',
          ),
        ),
      );

      expect(engine.modelInfoCalls, 0);
    },
  );

  test(
    'returns a successful translation when local history cannot be saved',
    () async {
      await repository.close();

      final outcome = await service.translateAndSave(request());

      expect(outcome.translation.translatedText, 'Hello');
      expect(outcome.historySaved, isFalse);
      expect(outcome.historyEntryId, isNull);
    },
  );
}

final class _FakeTranslationEngine implements TranslationEngine {
  TranslationModelInfo modelInfo = const TranslationModelInfo(
    status: TranslationModelStatus.downloaded,
  );
  bool failTranslation = false;
  int translateCalls = 0;
  int modelInfoCalls = 0;
  Completer<void>? translationStarted;
  Completer<void>? translationGate;

  @override
  String get engineId => 'fake-engine';

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
  ) async {
    modelInfoCalls++;
    return modelInfo;
  }

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
    final started = translationStarted;
    if (started != null && !started.isCompleted) started.complete();
    await translationGate?.future;
    if (failTranslation) {
      throw const TranslationFailure('engine_error', 'test failure');
    }
    return TranslationResult(
      request: request,
      translatedText: 'Hello',
      engineId: engineId,
      modelVersion: 'fake-v1',
    );
  }
}
