import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:miyin_app/core/storage/translation_history_repository.dart';
import 'package:miyin_app/core/translation/translation_contracts.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory tempDirectory;
  late String databasePath;

  setUpAll(() {
    sqfliteFfiInit();
  });

  setUp(() async {
    tempDirectory = await Directory.systemTemp.createTemp('miyin-history-');
    databasePath = '${tempDirectory.path}${Platform.pathSeparator}history.db';
  });

  tearDown(() async {
    await tempDirectory.delete(recursive: true);
  });

  Future<SqliteTranslationHistoryRepository> openRepository() =>
      SqliteTranslationHistoryRepository.open(
        path: databasePath,
        databaseFactory: databaseFactoryFfi,
      );

  TranslationResult result(
    String source,
    String translation, {
    DateTime? time,
  }) => TranslationResult(
    request: TranslationRequest(
      sourceLanguage: TranslationLanguage.simplifiedChinese,
      targetLanguage: TranslationLanguage.english,
      text: source,
    ),
    translatedText: translation,
    engineId: 'test-engine',
    modelVersion: 'model-1',
  );

  test(
    'saves successful results and restores them after reopening the DB',
    () async {
      final first = await openRepository();
      final id = await first.saveTranslation(
        result('你好', 'Hello'),
        createdAt: DateTime.utc(2026, 10, 10, 12),
      );
      await first.close();

      final reopened = await openRepository();
      final entry = await reopened.getTranslation(id);

      expect(entry, isNotNull);
      expect(entry!.sourceText, '你好');
      expect(entry.translatedText, 'Hello');
      expect(entry.sourceLanguageTag, 'zh-Hans');
      expect(entry.targetLanguageTag, 'en');
      expect(entry.engineId, 'test-engine');
      expect(entry.modelVersion, 'model-1');
      expect(entry.createdAt, DateTime.utc(2026, 10, 10, 12));
      await reopened.close();
    },
  );

  test(
    'lists newest first with stable pagination and deletes a single row',
    () async {
      final repository = await openRepository();
      final firstId = await repository.saveTranslation(
        result('第一条', 'First'),
        createdAt: DateTime.utc(2026, 10, 10, 10),
      );
      final secondId = await repository.saveTranslation(
        result('第二条', 'Second'),
        createdAt: DateTime.utc(2026, 10, 10, 11),
      );

      final page = await repository.listTranslations(limit: 1, offset: 0);
      expect(page.single.id, secondId);
      expect(
        (await repository.listTranslations(limit: 1, offset: 1)).single.id,
        firstId,
      );
      expect(await repository.deleteTranslation(secondId), isTrue);
      expect(await repository.getTranslation(secondId), isNull);
      expect(await repository.countTranslations(), 1);
      await repository.close();
    },
  );

  test(
    'deletes unique matching translation IDs and returns the number deleted',
    () async {
      final repository = await openRepository();
      final firstId = await repository.saveTranslation(result('第一条', 'First'));
      final keptId = await repository.saveTranslation(result('保留', 'Keep'));
      final thirdId = await repository.saveTranslation(result('第三条', 'Third'));

      final deletedCount = await repository.deleteTranslations([
        firstId,
        thirdId,
        firstId,
        999999,
      ]);

      expect(deletedCount, 2);
      expect(await repository.countTranslations(), 1);
      expect(await repository.getTranslation(keptId), isNotNull);
      expect(await repository.getTranslation(firstId), isNull);
      expect(await repository.getTranslation(thirdId), isNull);
      await repository.close();
    },
  );

  test('an empty batch returns zero and leaves history untouched', () async {
    final repository = await openRepository();
    final id = await repository.saveTranslation(result('保留', 'Keep'));

    expect(await repository.deleteTranslations([]), 0);
    expect(await repository.countTranslations(), 1);
    expect(await repository.getTranslation(id), isNotNull);
    await repository.close();
  });

  test(
    'rejects non-positive batch IDs before deleting any translation',
    () async {
      final repository = await openRepository();
      final firstId = await repository.saveTranslation(
        result('保留一', 'Keep one'),
      );
      final secondId = await repository.saveTranslation(
        result('保留二', 'Keep two'),
      );

      await expectLater(
        repository.deleteTranslations([firstId, 0, secondId]),
        throwsArgumentError,
      );

      expect(await repository.countTranslations(), 2);
      expect(await repository.getTranslation(firstId), isNotNull);
      expect(await repository.getTranslation(secondId), isNotNull);
      await repository.close();
    },
  );

  test(
    'deletes batches larger than a SQLite variable limit in one operation',
    () async {
      final repository = await openRepository();
      final ids = <int>[];
      for (var index = 0; index < 1001; index++) {
        ids.add(
          await repository.saveTranslation(result('条目 $index', 'Entry $index')),
        );
      }

      expect(await repository.deleteTranslations(ids), 1001);
      expect(await repository.countTranslations(), 0);
      await repository.close();
    },
  );

  test('clearing history leaves model package metadata untouched', () async {
    final repository = await openRepository();
    await repository.saveTranslation(result('你好', 'Hello'));
    await repository.saveModelPackage(
      const TranslationModelPackageMetadata(
        packageId: 'mlkit-zh-en',
        version: 'managed',
        sourceLanguageTag: 'zh-Hans',
        targetLanguageTag: 'en',
        engineId: 'google-mlkit',
        status: 'downloaded',
      ),
    );

    expect(await repository.clearTranslations(), 1);
    expect(await repository.countTranslations(), 0);
    expect((await repository.listModelPackages()).single.status, 'downloaded');
    await repository.close();
  });
}
