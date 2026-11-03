import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// Prepares the bundled AI speech candidate without downloading or starting TTS.
final class MiyinMatchaTtsModelStore {
  MiyinMatchaTtsModelStore._({this.supportDirectory, AssetBundle? bundle})
    : _bundle = bundle ?? rootBundle;

  @visibleForTesting
  MiyinMatchaTtsModelStore.forTesting({
    required Directory supportDirectory,
    required AssetBundle bundle,
  }) : this._(supportDirectory: supportDirectory, bundle: bundle);

  static final instance = MiyinMatchaTtsModelStore._();
  static const assetDirectory = 'assets/voice/tts-matcha-zh-en';
  static const modelId = 'matcha-zh-en-20251010-vocos16k-r3-cmu';
  static const archiveName = 'matcha-zh-en.tar.gz';
  static const manifestAsset = '$assetDirectory/asset-manifest.json';
  static const supportedLanguageTags = {'zh-Hans', 'en'};

  final Directory? supportDirectory;
  final AssetBundle _bundle;
  Future<Directory>? _preparation;

  /// Concurrent calls share preparation. Failed preparation can be retried.
  Future<Directory> prepare() {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return Future.error(
        PlatformException(
          code: 'matcha_tts_unavailable',
          message: 'AI 快速离线语音目前仅支持觅音 Android 应用。',
        ),
      );
    }
    final current = _preparation;
    if (current != null) return current;
    final preparation = _prepare();
    _preparation = preparation;
    _resetWhenComplete(preparation);
    return preparation;
  }

  Future<void> _resetWhenComplete(Future<Directory> preparation) async {
    try {
      await preparation;
    } catch (_) {
      // The caller receives the original error; the next call may retry.
    } finally {
      if (identical(_preparation, preparation)) _preparation = null;
    }
  }

  Future<Directory> _prepare() async {
    final support = supportDirectory ?? await getApplicationSupportDirectory();
    final parent = Directory('${support.path}/miyin');
    final installed = Directory('${parent.path}/tts-ai-matcha-zh-en');
    final staging = Directory('${parent.path}/.tts-ai-matcha-zh-en.part');
    final backup = Directory('${parent.path}/.tts-ai-matcha-zh-en.old');
    try {
      final manifest = _Manifest.parse(
        jsonDecode(await _bundle.loadString(manifestAsset)),
      );
      final marker = File('${installed.path}/.model-version');
      if (await marker.exists() &&
          await marker.readAsString() == modelId &&
          await _filesValid(installed, manifest.files)) {
        return installed;
      }
      await parent.create(recursive: true);
      await _removeOwnedDirectory(staging);
      await staging.create();
      final asset = await _bundle.load('$assetDirectory/$archiveName');
      final bytes = asset.buffer.asUint8List(
        asset.offsetInBytes,
        asset.lengthInBytes,
      );
      if (bytes.length != manifest.archiveBytes ||
          sha256.convert(bytes).toString() != manifest.archiveSha256) {
        throw const FormatException(
          'Bundled Matcha archive failed verification.',
        );
      }
      final archive = File('${staging.path}/$archiveName');
      await archive.writeAsBytes(bytes, flush: true);
      final extracted = Directory('${staging.path}/extracted');
      await extracted.create();
      await Isolate.run(
        () => _extract(archive.path, extracted.path, manifest.files),
      );
      if (!await _filesValid(extracted, manifest.files)) {
        throw const FormatException('Prepared Matcha files are incomplete.');
      }
      await File('${extracted.path}/.model-version')
          .writeAsString(modelId, flush: true);
      await _removeOwnedDirectory(backup);
      if (await installed.exists()) await installed.rename(backup.path);
      try {
        await extracted.rename(installed.path);
      } catch (_) {
        if (await backup.exists() && !await installed.exists()) {
          await backup.rename(installed.path);
        }
        rethrow;
      }
      await _removeOwnedDirectory(backup);
      await _removeOwnedDirectory(staging);
      return installed;
    } catch (error, stack) {
      debugPrint('[MiyinTTS] Matcha resource preparation failed: $error');
      await _removeOwnedDirectory(staging);
      Error.throwWithStackTrace(
        error is PlatformException
            ? error
            : PlatformException(
                code: error is FileSystemException
                    ? 'matcha_tts_storage_error'
                    : 'matcha_tts_integrity_error',
                message: error is FileSystemException
                    ? '无法准备 AI 离线语音，请检查手机可用空间。'
                    : 'AI 离线语音资源校验失败，请重新安装觅音。',
                details: error.toString(),
              ),
        stack,
      );
    }
  }
}

final class _Manifest {
  _Manifest(this.archiveBytes, this.archiveSha256, this.files);
  final int archiveBytes;
  final String archiveSha256;
  final Map<String, int> files;

  static _Manifest parse(Object? raw) {
    if (raw is! Map ||
        raw['version'] != MiyinMatchaTtsModelStore.modelId ||
        raw['archiveBytes'] is! int ||
        (raw['archiveBytes'] as int) <= 0 ||
        raw['archiveSha256'] is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(raw['archiveSha256'] as String) ||
        raw['files'] is! List) {
      throw const FormatException('Invalid Matcha manifest.');
    }
    final files = <String, int>{};
    for (final entry in raw['files'] as List) {
      if (entry is! Map ||
          entry['path'] is! String ||
          entry['size'] is! int ||
          (entry['size'] as int) <= 0 ||
          !_safePath(entry['path'] as String) ||
          files.containsKey(entry['path'])) {
        throw const FormatException('Invalid Matcha manifest entry.');
      }
      files[entry['path'] as String] = entry['size'] as int;
    }
    if (files.isEmpty) throw const FormatException('Empty Matcha manifest.');
    return _Manifest(
      raw['archiveBytes'] as int,
      raw['archiveSha256'] as String,
      files,
    );
  }
}

bool _safePath(String path) =>
    RegExp(r'^[A-Za-z0-9._/! -]+$').hasMatch(path) &&
    !path.startsWith('/') &&
    path
        .split('/')
        .every((part) => part.isNotEmpty && part != '.' && part != '..');

Future<bool> _filesValid(Directory root, Map<String, int> files) async {
  for (final entry in files.entries) {
    final file = File('${root.path}/${entry.key}');
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
            FileSystemEntityType.file ||
        await file.length() != entry.value) {
      return false;
    }
  }
  return true;
}

Future<void> _removeOwnedDirectory(Directory directory) async {
  final type = await FileSystemEntity.type(directory.path, followLinks: false);
  if (type == FileSystemEntityType.notFound) return;
  if (type != FileSystemEntityType.directory) {
    throw const FormatException('Unexpected Matcha installation path.');
  }
  await directory.delete(recursive: true);
}

Future<void> _extract(
  String archive,
  String target,
  Map<String, int> files,
) async {
  final seen = <String>{};
  await extractFileToDisk(
    archive,
    target,
    maxSize: files.values.fold<int>(0, (sum, size) => sum + size),
    callback: (entry) {
      if (!entry.isFile ||
          entry.isSymbolicLink ||
          !_safePath(entry.name) ||
          files[entry.name] != entry.size ||
          !seen.add(entry.name)) {
        throw const FormatException('Unexpected Matcha archive entry.');
      }
    },
  );
  if (seen.length != files.length) {
    throw const FormatException('Missing Matcha archive entry.');
  }
}
