import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path_provider/path_provider.dart';
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
    this.attachmentKind = 'text',
    this.attachmentName,
    this.attachmentRowsJson,
    this.originalImagePath,
    this.translatedImagePath,
  });

  final int id;
  final String sourceText;
  final String translatedText;
  final String sourceLanguageTag;
  final String targetLanguageTag;
  final String engineId;
  final String? modelVersion;
  final String attachmentKind;
  final String? attachmentName;
  final String? attachmentRowsJson;
  final String? originalImagePath;
  final String? translatedImagePath;
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
        attachmentKind: map['attachment_kind'] as String? ?? 'text',
        attachmentName: map['attachment_name'] as String?,
        attachmentRowsJson: map['attachment_rows_json'] as String?,
        originalImagePath: map['original_image_path'] as String?,
        translatedImagePath: map['translated_image_path'] as String?,
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

  static const _databaseVersion = 2;
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
          if (oldVersion >= 1 && oldVersion < 2) {
            await _addAttachmentColumns(db);
          }
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
        attachment_kind TEXT NOT NULL DEFAULT 'text',
        attachment_name TEXT,
        attachment_rows_json TEXT,
        original_image_path TEXT,
        translated_image_path TEXT,
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

  static Future<void> _addAttachmentColumns(Database db) async {
    await db.execute(
      "ALTER TABLE translation_history ADD COLUMN attachment_kind TEXT NOT NULL DEFAULT 'text'",
    );
    await db.execute(
      'ALTER TABLE translation_history ADD COLUMN attachment_name TEXT',
    );
    await db.execute(
      'ALTER TABLE translation_history ADD COLUMN attachment_rows_json TEXT',
    );
    await db.execute(
      'ALTER TABLE translation_history ADD COLUMN original_image_path TEXT',
    );
    await db.execute(
      'ALTER TABLE translation_history ADD COLUMN translated_image_path TEXT',
    );
  }

  Future<int> saveAttachment({
    required String kind,
    required String name,
    required String sourceTag,
    required String targetTag,
    required String rowsJson,
    required String sourceText,
    required String translatedText,
    String? originalImageDataUrl,
    String? translatedImageDataUrl,
  }) async {
    if (kind != 'image' && kind != 'article') {
      throw ArgumentError.value(kind, 'kind');
    }
    String? originalPath;
    String? translatedPath;
    try {
      if (kind == 'image') {
        if (originalImageDataUrl == null || translatedImageDataUrl == null) {
          throw ArgumentError('Both images are required for image history.');
        }
        final directory = await _imageDirectory();
        final unique =
            '${DateTime.now().microsecondsSinceEpoch}_${Random.secure().nextInt(1 << 32)}';
        originalPath =
            '${directory.path}${Platform.pathSeparator}${unique}_original.jpg';
        translatedPath =
            '${directory.path}${Platform.pathSeparator}${unique}_translated.jpg';
        await File(originalPath)
            .writeAsBytes(_decodeJpeg(originalImageDataUrl), flush: true);
        await File(translatedPath)
            .writeAsBytes(_decodeJpeg(translatedImageDataUrl), flush: true);
      }
      return await _database.insert('translation_history', {
        'source_text': sourceText,
        'translated_text': translatedText,
        'source_language_tag': sourceTag,
        'target_language_tag': targetTag,
        'engine_id': 'attachment-$kind',
        'attachment_kind': kind,
        'attachment_name': name,
        'attachment_rows_json': rowsJson,
        'original_image_path': originalPath?.split(Platform.pathSeparator).last,
        'translated_image_path': translatedPath
            ?.split(Platform.pathSeparator)
            .last,
        'created_at': DateTime.now().toUtc().millisecondsSinceEpoch,
      });
    } catch (_) {
      await _removeImages([originalPath, translatedPath]);
      rethrow;
    }
  }

  static List<int> _decodeJpeg(String dataUrl) {
    const prefix = 'data:image/jpeg;base64,';
    if (!dataUrl.startsWith(prefix) || dataUrl.length > 4 * 1024 * 1024) {
      throw ArgumentError('Invalid or oversized JPEG image.');
    }
    final bytes = base64Decode(dataUrl.substring(prefix.length));
    if (bytes.length < 4 ||
        bytes.length > 3 * 1024 * 1024 ||
        bytes[0] != 0xff ||
        bytes[1] != 0xd8) {
      throw ArgumentError('Invalid JPEG image bytes.');
    }
    return bytes;
  }

  Future<Directory> _imageDirectory() async {
    final support = await getApplicationSupportDirectory();
    final directory = Directory(
      '${support.path}${Platform.pathSeparator}translation_history_images',
    );
    await directory.create(recursive: true);
    return directory;
  }

  Future<String?> readImage(String? path) async {
    if (path == null) return null;
    final directory = await _imageDirectory();
    final file = _imageFile(directory, path);
    if (file == null) return null;
    if (!await file.exists()) return null;
    return 'data:image/jpeg;base64,${base64Encode(await file.readAsBytes())}';
  }

  File? _imageFile(Directory directory, String storedPath) {
    final name = storedPath.replaceAll('\\', '/').split('/').last;
    if (!RegExp(r'^\d+_\d+_(original|translated)\.jpg$').hasMatch(name)) {
      return null;
    }
    return File('${directory.path}${Platform.pathSeparator}$name');
  }

  Future<void> _removeImages(Iterable<String?> paths) async {
    final directory = await _imageDirectory();
    for (final path in paths) {
      if (path == null) continue;
      final file = _imageFile(directory, path);
      if (file == null) continue;
      if (await file.exists()) {
        try {
          await file.delete();
        } catch (_) {
          /* History removal still succeeds. */
        }
      }
    }
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

  Future<bool> deleteTranslation(int id) async {
    final entry = await getTranslation(id);
    final deleted =
        await _database.delete(
          'translation_history',
          where: 'id = ?',
          whereArgs: [id],
        ) >
        0;
    if (deleted && entry != null && entry.attachmentKind == 'image') {
      await _removeImages([entry.originalImagePath, entry.translatedImagePath]);
    }
    return deleted;
  }

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
    final imagePaths = <String?>[];
    final deletedCount = await _database.transaction<int>((transaction) async {
      var deletedCount = 0;
      for (var start = 0; start < idList.length; start += _deleteBatchSize) {
        final nextStart = start + _deleteBatchSize;
        final end = nextStart < idList.length ? nextStart : idList.length;
        final batch = idList.sublist(start, end);
        final placeholders = List<String>.filled(batch.length, '?').join(',');
        final imageRows = await transaction.query(
          'translation_history',
          columns: ['original_image_path', 'translated_image_path'],
          where: "id IN ($placeholders) AND attachment_kind = 'image'",
          whereArgs: batch,
        );
        for (final row in imageRows) {
          imagePaths.add(row['original_image_path'] as String?);
          imagePaths.add(row['translated_image_path'] as String?);
        }
        deletedCount += await transaction.delete(
          'translation_history',
          where: 'id IN ($placeholders)',
          whereArgs: batch,
        );
      }
      return deletedCount;
    });
    if (imagePaths.isNotEmpty) await _removeImages(imagePaths);
    return deletedCount;
  }

  Future<int> clearTranslations() async {
    final rows = await _database.query(
      'translation_history',
      columns: ['original_image_path', 'translated_image_path'],
      where: "attachment_kind = 'image'",
    );
    final deleted = await _database.delete('translation_history');
    final paths = <String?>[];
    for (final row in rows) {
      paths.add(row['original_image_path'] as String?);
      paths.add(row['translated_image_path'] as String?);
    }
    if (paths.isNotEmpty) await _removeImages(paths);
    return deleted;
  }

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
