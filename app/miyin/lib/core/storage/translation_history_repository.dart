import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite/sqflite.dart'
    show ConflictAlgorithm, Database, DatabaseFactory, OpenDatabaseOptions;

import '../translation/translation_contracts.dart';

final class TranslationHistoryEntry {
  const TranslationHistoryEntry({
    required this.id,
    required this.sourceText,
    required this.translatedText,
    required this.sourceLanguageTag,
    required this.targetLanguageTag,
    required this.engineId,
    required this.createdAt,
    this.modelVersion,
  });

  final int id;
  final String sourceText;
  final String translatedText;
  final String sourceLanguageTag;
  final String targetLanguageTag;
  final String engineId;
  final String? modelVersion;
  final DateTime createdAt;

  factory TranslationHistoryEntry.fromMap(Map<String, Object?> map) =>
      TranslationHistoryEntry(
        id: map['id']! as int,
        sourceText: map['source_text']! as String,
        translatedText: map['translated_text']! as String,
        sourceLanguageTag: map['source_language_tag']! as String,
        targetLanguageTag: map['target_language_tag']! as String,
        engineId: map['engine_id']! as String,
        modelVersion: map['model_version'] as String?,
        createdAt: DateTime.fromMillisecondsSinceEpoch(
          map['created_at']! as int,
          isUtc: true,
        ),
      );
}

final class TranslationModelPackageMetadata {
  const TranslationModelPackageMetadata({
    required this.packageId,
    required this.version,
    required this.sourceLanguageTag,
    required this.targetLanguageTag,
    required this.engineId,
    required this.status,
    this.checksum,
  });

  final String packageId;
  final String version;
  final String sourceLanguageTag;
  final String targetLanguageTag;
  final String engineId;
  final String status;
  final String? checksum;

  factory TranslationModelPackageMetadata.fromMap(Map<String, Object?> map) =>
      TranslationModelPackageMetadata(
        packageId: map['package_id']! as String,
        version: map['version']! as String,
        sourceLanguageTag: map['source_language_tag']! as String,
        targetLanguageTag: map['target_language_tag']! as String,
        engineId: map['engine_id']! as String,
        status: map['status']! as String,
        checksum: map['checksum'] as String?,
      );
}

/// SQLite-backed translation history and a small metadata catalogue.
///
/// The actual model files stay with the translation engine. This table stores
/// identifiers and compatibility metadata only, so self-hosted package
/// adapters can be added without putting model weights into the database.
final class SqliteTranslationHistoryRepository {
  SqliteTranslationHistoryRepository._(this._database);

  static const _databaseVersion = 1;
  static const _deleteBatchSize = 900;
  static const databaseName = 'miyin_translation.db';

  final Database _database;

  static Future<SqliteTranslationHistoryRepository> open({
    String? path,
    DatabaseFactory? databaseFactory,
  }) async {
    final factory = databaseFactory ?? sqflite.databaseFactory;
    final database = await factory.openDatabase(
      path ?? databaseName,
      options: OpenDatabaseOptions(
        version: _databaseVersion,
        onCreate: (db, version) async {
          await _createSchema(db);
        },
        onUpgrade: (db, oldVersion, newVersion) async {
          if (oldVersion < 1) await _createSchema(db);
        },
      ),
    );
    return SqliteTranslationHistoryRepository._(database);
  }

  static Future<void> _createSchema(Database db) async {
    await db.execute('''
      CREATE TABLE translation_history (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        source_text TEXT NOT NULL,
        translated_text TEXT NOT NULL,
        source_language_tag TEXT NOT NULL,
        target_language_tag TEXT NOT NULL,
        engine_id TEXT NOT NULL,
        model_version TEXT,
        created_at INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE INDEX translation_history_created_at
      ON translation_history(created_at DESC, id DESC)
    ''');
    await db.execute('''
      CREATE TABLE translation_model_packages (
        package_id TEXT PRIMARY KEY,
        version TEXT NOT NULL,
        source_language_tag TEXT NOT NULL,
        target_language_tag TEXT NOT NULL,
        engine_id TEXT NOT NULL,
        status TEXT NOT NULL,
        checksum TEXT,
        updated_at INTEGER NOT NULL
      )
    ''');
  }

  Future<int> saveTranslation(TranslationResult result, {DateTime? createdAt}) {
    if (result.translatedText.trim().isEmpty) {
      throw ArgumentError.value(
        result.translatedText,
        'translatedText',
        'A successful translation must contain text.',
      );
    }
    return _database.insert('translation_history', {
      'source_text': result.request.text,
      'translated_text': result.translatedText,
      'source_language_tag': result.request.sourceLanguage.tag,
      'target_language_tag': result.request.targetLanguage.tag,
      'engine_id': result.engineId,
      'model_version': result.modelVersion,
      'created_at': (createdAt ?? DateTime.now().toUtc())
          .toUtc()
          .millisecondsSinceEpoch,
    });
  }

  Future<List<TranslationHistoryEntry>> listTranslations({
    int limit = 30,
    int offset = 0,
  }) async {
    if (limit < 1 || limit > 100) {
      throw ArgumentError.value(limit, 'limit', 'Must be between 1 and 100.');
    }
    if (offset < 0) {
      throw ArgumentError.value(offset, 'offset', 'Must be >= 0.');
    }
    final rows = await _database.query(
      'translation_history',
      orderBy: 'created_at DESC, id DESC',
      limit: limit,
      offset: offset,
    );
    return rows.map(TranslationHistoryEntry.fromMap).toList(growable: false);
  }

  Future<TranslationHistoryEntry?> getTranslation(int id) async {
    final rows = await _database.query(
      'translation_history',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isEmpty ? null : TranslationHistoryEntry.fromMap(rows.single);
  }

  Future<bool> deleteTranslation(int id) async =>
      await _database.delete(
        'translation_history',
        where: 'id = ?',
        whereArgs: [id],
      ) >
      0;

  /// Deletes the requested history rows atomically and returns the number of
  /// rows that existed and were removed. Duplicate IDs are ignored.
  Future<int> deleteTranslations(Iterable<int> ids) async {
    final uniqueIds = <int>{};
    for (final id in ids) {
      if (id <= 0) {
        throw ArgumentError.value(
          id,
          'ids',
          'Every ID must be a positive integer.',
        );
      }
      uniqueIds.add(id);
    }
    if (uniqueIds.isEmpty) {
      return 0;
    }

    final idList = uniqueIds.toList(growable: false);
    return _database.transaction<int>((transaction) async {
      var deletedCount = 0;
      for (var start = 0; start < idList.length; start += _deleteBatchSize) {
        final nextStart = start + _deleteBatchSize;
        final end = nextStart < idList.length ? nextStart : idList.length;
        final batch = idList.sublist(start, end);
        final placeholders = List<String>.filled(batch.length, '?').join(',');
        deletedCount += await transaction.delete(
          'translation_history',
          where: 'id IN ($placeholders)',
          whereArgs: batch,
        );
      }
      return deletedCount;
    });
  }

  Future<int> clearTranslations() => _database.delete('translation_history');

  Future<int> countTranslations() async =>
      sqflite.Sqflite.firstIntValue(
        await _database.rawQuery('SELECT COUNT(*) FROM translation_history'),
      ) ??
      0;

  Future<void> saveModelPackage(TranslationModelPackageMetadata package) async {
    await _database.insert('translation_model_packages', {
      'package_id': package.packageId,
      'version': package.version,
      'source_language_tag': package.sourceLanguageTag,
      'target_language_tag': package.targetLanguageTag,
      'engine_id': package.engineId,
      'status': package.status,
      'checksum': package.checksum,
      'updated_at': DateTime.now().toUtc().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<TranslationModelPackageMetadata>> listModelPackages() async {
    final rows = await _database.query(
      'translation_model_packages',
      orderBy: 'package_id ASC',
    );
    return rows
        .map(TranslationModelPackageMetadata.fromMap)
        .toList(growable: false);
  }

  Future<void> close() => _database.close();
}
