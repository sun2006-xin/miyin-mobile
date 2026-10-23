import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// Makes the pinned Supertonic multilingual voice available from APK assets.
///
/// Chinese keeps using the bundled Melo voice. The compressed Supertonic 3
/// package is unpacked to application support on first launch, so speech does
/// not depend on GitHub or a user-started download.
final class MiyinMultilingualTtsModelStore {
  MiyinMultilingualTtsModelStore._({
    this._supportDirectory,
    AssetBundle? bundle,
    String? archiveAsset,
    int? archiveBytes,
    String? archiveSha256,
  }) : _bundle = bundle ?? rootBundle,
       _archiveAsset = archiveAsset ?? defaultArchiveAsset,
       _archiveBytes = archiveBytes ?? totalBytes,
       _archiveSha256 = archiveSha256 ?? _sha256;

  static final MiyinMultilingualTtsModelStore instance =
      MiyinMultilingualTtsModelStore._();

  @visibleForTesting
  MiyinMultilingualTtsModelStore.forTesting({
    required Directory supportDirectory,
    required AssetBundle bundle,
    required String archiveAsset,
    required int archiveBytes,
    required String archiveSha256,
  }) : this._(
         supportDirectory: supportDirectory,
         bundle: bundle,
         archiveAsset: archiveAsset,
         archiveBytes: archiveBytes,
         archiveSha256: archiveSha256,
       );

  static const modelId = 'supertonic-3-int8-2026-05-11';
  static const archiveName =
      'sherpa-onnx-supertonic-3-tts-int8-2026-05-11.tar.bz2';
  static const totalBytes = 128774318;
  static const defaultArchiveAsset =
      'assets/voice/tts-supertonic3/$archiveName';
  static const modelDirectoryName =
      'sherpa-onnx-supertonic-3-tts-int8-2026-05-11';
  static const _sha256 =
      '82fa96f91c4ef8abaae3a14a3f4153facf88bed821d1f7331cec2700f432c427';
  static const supportedLanguageTags = <String>{
    'ar',
    'bg',
    'hr',
    'cs',
    'da',
    'nl',
    'en',
    'et',
    'fi',
    'fr',
    'de',
    'el',
    'hi',
    'hu',
    'id',
    'it',
    'ja',
    'ko',
    'lv',
    'lt',
    'pl',
    'pt',
    'ro',
    'ru',
    'sk',
    'sl',
    'es',
    'sv',
    'tr',
    'uk',
    'vi',
  };
  static const _requiredFiles = <String>{
    'duration_predictor.int8.onnx',
    'text_encoder.int8.onnx',
    'vector_estimator.int8.onnx',
    'vocoder.int8.onnx',
    'tts.json',
    'unicode_indexer.bin',
    'voice.bin',
  };

  final Directory? _supportDirectory;
  final AssetBundle _bundle;
  final String _archiveAsset;
  final int _archiveBytes;
  final String _archiveSha256;
  Future<Directory>? _installation;

  /// Prepare the bundled files without initializing the inference runtime.
  /// This can run during startup without blocking the first screen.
  Future<Directory> prepare() => installBundled();

  Future<Map<String, Object?>> status() async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return {
        'status': 'unavailable',
        'installed': false,
        'bundled': false,
        'supported': false,
        'deletable': false,
        'downloadable': false,
        'modelId': modelId,
        'packageBytes': _archiveBytes,
        'speakerCount': 10,
        'languageTags': supportedLanguageTags.toList()..sort(),
      };
    }
    await installBundled();
    return {
      'status': 'bundled',
      'installed': true,
      'bundled': true,
      'source': 'apk',
      'deletable': false,
      'downloadable': false,
      'supported': true,
      'modelId': modelId,
      'packageBytes': _archiveBytes,
      'speakerCount': 10,
      'languageTags': supportedLanguageTags.toList()..sort(),
    };
  }

  Future<Directory?> installedModelDirectory() async {
    if (defaultTargetPlatform != TargetPlatform.android) return null;
    return installBundled();
  }

  Future<Directory> installBundled() async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      throw PlatformException(
        code: 'multilingual_tts_unavailable',
        message: '多语言多音色离线语音目前仅支持觅音 Android 应用。',
      );
    }
    final current = _installation;
    if (current != null) return current;
    final installation = _installBundled();
    _installation = installation;
    try {
      return await installation;
    } finally {
      if (identical(_installation, installation)) _installation = null;
    }
  }

  /// Compatibility entry point for existing bridge clients. This prepares a
  /// packaged local asset and never contacts an external server.
  Future<Map<String, Object?>> download() async {
    await installBundled();
    return status();
  }

  Future<void> delete() async {
    throw PlatformException(
      code: 'bundled_tts_cannot_delete',
      message: '多语言语音模型随觅音安装包提供，无需下载，也不能单独删除。',
    );
  }

  Future<Directory> _installBundled() async {
    final installed = await _modelDirectory();
    if (await _isInstalled(installed)) return installed;

    final parent = installed.parent;
    await parent.create(recursive: true);
    final staging = Directory(
      '${parent.path}${Platform.pathSeparator}.$modelId.part',
    );
    final archiveFile = File(
      '${staging.path}${Platform.pathSeparator}$archiveName',
    );
    final extractedRoot = Directory(
      '${staging.path}${Platform.pathSeparator}extracted',
    );
    final backup = Directory(
      '${parent.path}${Platform.pathSeparator}.$modelId.old',
    );
    if (await staging.exists()) await staging.delete(recursive: true);
    await staging.create(recursive: true);

    try {
      final asset = await _bundle.load(_archiveAsset);
      final bytes = asset.buffer.asUint8List(
        asset.offsetInBytes,
        asset.lengthInBytes,
      );
      if (bytes.length != _archiveBytes ||
          sha256.convert(bytes).toString() != _archiveSha256) {
        throw const FormatException(
          'Bundled TTS model failed size or SHA-256 verification.',
        );
      }
      await archiveFile.writeAsBytes(bytes, flush: true);
      await extractedRoot.create(recursive: true);
      await Isolate.run<void>(
        () => _extractArchive(archiveFile.path, extractedRoot.path),
      );
      final modelFolder = Directory(
        '${extractedRoot.path}${Platform.pathSeparator}$modelDirectoryName',
      );
      if (!await _containsRequiredFiles(modelFolder)) {
        throw const FormatException('Bundled TTS model is incomplete.');
      }
      await File('${modelFolder.path}${Platform.pathSeparator}.model-version')
          .writeAsString(modelId, flush: true);

      if (await backup.exists()) await backup.delete(recursive: true);
      if (await installed.exists()) await installed.rename(backup.path);
      try {
        await modelFolder.rename(installed.path);
      } catch (_) {
        if (await backup.exists() && !await installed.exists()) {
          await backup.rename(installed.path);
        }
        rethrow;
      }
      if (await backup.exists()) await backup.delete(recursive: true);
      return installed;
    } catch (error, stackTrace) {
      if (await staging.exists()) await staging.delete(recursive: true);
      final failure = _installationFailure(error);
      Error.throwWithStackTrace(failure, stackTrace);
    }
  }

  Future<Directory> _modelDirectory() async {
    final support = _supportDirectory ?? await getApplicationSupportDirectory();
    return Directory(
      '${support.path}${Platform.pathSeparator}miyin'
      '${Platform.pathSeparator}tts-multilingual-supertonic3',
    );
  }

  Future<bool> _isInstalled(Directory directory) async {
    try {
      final marker = File(
        '${directory.path}${Platform.pathSeparator}.model-version',
      );
      return await marker.exists() &&
          await marker.readAsString() == modelId &&
          await _containsRequiredFiles(directory);
    } on FileSystemException {
      return false;
    }
  }

  Future<bool> _containsRequiredFiles(Directory directory) async {
    if (!await directory.exists()) return false;
    for (final name in _requiredFiles) {
      final file = File('${directory.path}${Platform.pathSeparator}$name');
      if (!await file.exists() || await file.length() == 0) return false;
    }
    return true;
  }

  PlatformException _installationFailure(Object error) {
    if (error is PlatformException) return error;
    if (error is FormatException) {
      return PlatformException(
        code: 'multilingual_tts_integrity_error',
        message: '安装包中的多语言语音资源校验失败，请重新安装觅音。',
        details: error.message,
      );
    }
    if (error is FileSystemException) {
      return PlatformException(
        code: 'multilingual_tts_storage_error',
        message: '无法准备多语言语音资源，请检查设备可用空间。',
        details: error.message,
      );
    }
    return PlatformException(
      code: 'multilingual_tts_install_failed',
      message: '无法准备觅音内置的多语言语音资源。',
      details: error.toString(),
    );
  }
}

Future<void> _extractArchive(String archivePath, String outputPath) =>
    extractFileToDisk(
      archivePath,
      outputPath,
      callback: (entry) {
        if (entry.isSymbolicLink) {
          throw const FormatException('TTS archive contains a link.');
        }
      },
    );
