import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// Makes the pinned multilingual Whisper model available from APK assets.
///
/// The app never downloads this model at runtime. The first prepare copies the
/// packaged files to application support, where sherpa-onnx can open them.
final class MiyinMultilingualAsrModelStore {
  MiyinMultilingualAsrModelStore._({
    this._supportDirectory,
    AssetBundle? bundle,
    List<_AsrModelFile>? files,
  }) : _bundle = bundle ?? rootBundle,
       _files = files ?? _defaultFiles;

  static final MiyinMultilingualAsrModelStore instance =
      MiyinMultilingualAsrModelStore._();

  @visibleForTesting
  MiyinMultilingualAsrModelStore.forTesting({
    required Directory supportDirectory,
    required AssetBundle bundle,
    required Map<String, ({int size, String sha256})> files,
  }) : this._(
         supportDirectory: supportDirectory,
         bundle: bundle,
         files: files.entries
             .map(
               (entry) => _AsrModelFile(
                 entry.key,
                 entry.value.size,
                 entry.value.sha256,
               ),
             )
             .toList(growable: false),
       );

  static const modelId = 'whisper-base-multilingual-int8-trial-v1';
  static const totalBytes = 160609290;
  static const assetDirectory = 'assets/voice/asr-whisper-base';

  /// Language tags that overlap the current translation catalog and Whisper's
  /// multilingual tokenizer. These are languages the model can attempt; this
  /// list does not claim equal recognition accuracy or device-level QA.
  static const supportedLanguageTags = <String>{
    'af',
    'ar',
    'be',
    'bg',
    'bn',
    'ca',
    'cs',
    'cy',
    'da',
    'de',
    'el',
    'en',
    'es',
    'et',
    'fa',
    'fi',
    'fr',
    'gl',
    'gu',
    'he',
    'hi',
    'hr',
    'ht',
    'hu',
    'id',
    'is',
    'it',
    'ja',
    'ka',
    'kn',
    'ko',
    'lt',
    'lv',
    'mk',
    'mr',
    'ms',
    'mt',
    'nl',
    'no',
    'pl',
    'pt',
    'ro',
    'ru',
    'sk',
    'sl',
    'sq',
    'sv',
    'sw',
    'ta',
    'te',
    'th',
    'tl',
    'tr',
    'uk',
    'ur',
    'vi',
    'zh-Hans',
  };

  static const _defaultFiles = <_AsrModelFile>[
    _AsrModelFile(
      'base-encoder.int8.onnx',
      29120534,
      '0b8fb1304b6109976038efff5ace81720e00386f3ff6b54ee8c75291ca0a1e11',
    ),
    _AsrModelFile(
      'base-decoder.int8.onnx',
      130672026,
      '9759d217388a01b3a4c7c15533201067b48ae819c4daafc8624e64b9409dc02d',
    ),
    _AsrModelFile(
      'base-tokens.txt',
      816730,
      'b34b360dbb493e781e479794586d661700670d65564001f23024971d1f2fa126',
    ),
  ];

  final Directory? _supportDirectory;
  final AssetBundle _bundle;
  final List<_AsrModelFile> _files;
  final StreamController<Map<String, Object?>> _events =
      StreamController<Map<String, Object?>>.broadcast();
  Future<Directory>? _installation;

  Stream<Map<String, Object?>> get events => _events.stream;

  int get _modelBytes => _files.fold(0, (sum, file) => sum + file.size);

  Future<Map<String, Object?>> status() async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return {
        'status': 'unavailable',
        'installed': false,
        'bundled': false,
        'supported': false,
        'modelId': modelId,
        'totalBytes': _modelBytes,
      };
    }
    await installBundled();
    return {
      'status': 'bundled',
      'installed': true,
      'bundled': true,
      'source': 'apk',
      'supported': true,
      'modelId': modelId,
      'totalBytes': _modelBytes,
      'languageTags': supportedLanguageTags.toList()..sort(),
    };
  }

  Future<Directory?> installedModelDirectory() async {
    if (defaultTargetPlatform != TargetPlatform.android) return null;
    return installBundled();
  }

  /// Copies and validates the APK model assets once, without a network request.
  Future<Directory> installBundled() async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      throw PlatformException(
        code: 'multilingual_asr_unavailable',
        message: '多语言离线识别目前仅支持觅音 Android 应用。',
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

  /// Compatibility entry point for older bridge clients. This is a local asset
  /// install, not a download.
  Future<Map<String, Object?>> download() async {
    await installBundled();
    return status();
  }

  Future<void> delete() async {
    throw PlatformException(
      code: 'bundled_asr_cannot_delete',
      message: '多语言识别模型随觅音安装包提供，无需下载，也不能单独删除。',
    );
  }

  Future<void> close() async {
    await _events.close();
  }

  Future<Directory> _installBundled() async {
    final installed = await _modelDirectory();
    if (await _isInstalled(installed)) return installed;

    final parent = installed.parent;
    await parent.create(recursive: true);
    final staging = Directory(
      '${parent.path}${Platform.pathSeparator}.$modelId.part',
    );
    final backup = Directory(
      '${parent.path}${Platform.pathSeparator}.$modelId.old',
    );
    if (await staging.exists()) await staging.delete(recursive: true);
    await staging.create(recursive: true);

    try {
      var copied = 0;
      for (final modelFile in _files) {
        final assetPath = '$assetDirectory/${modelFile.name}';
        final asset = await _bundle.load(assetPath);
        final bytes = asset.buffer.asUint8List(
          asset.offsetInBytes,
          asset.lengthInBytes,
        );
        if (bytes.length != modelFile.size ||
            sha256.convert(bytes).toString() != modelFile.sha256) {
          throw const FormatException(
            'Bundled ASR model failed size or SHA-256 verification.',
          );
        }
        await File('${staging.path}${Platform.pathSeparator}${modelFile.name}')
            .writeAsBytes(bytes, flush: true);
        copied += modelFile.size;
        _emit({
          'type': 'asr_model_install_progress',
          'modelId': modelId,
          'file': modelFile.name,
          'copiedBytes': copied,
          'totalBytes': _modelBytes,
        });
      }
      await File('${staging.path}${Platform.pathSeparator}.model-version')
          .writeAsString(modelId, flush: true);

      if (await backup.exists()) await backup.delete(recursive: true);
      if (await installed.exists()) await installed.rename(backup.path);
      try {
        await staging.rename(installed.path);
      } catch (_) {
        if (await backup.exists() && !await installed.exists()) {
          await backup.rename(installed.path);
        }
        rethrow;
      }
      if (await backup.exists()) await backup.delete(recursive: true);
      _emit({
        'type': 'asr_model_install_complete',
        'modelId': modelId,
        'copiedBytes': _modelBytes,
        'totalBytes': _modelBytes,
      });
      return installed;
    } catch (error, stackTrace) {
      if (await staging.exists()) await staging.delete(recursive: true);
      final failure = _installationFailure(error);
      _emit({
        'type': 'asr_model_install_failed',
        'modelId': modelId,
        'code': failure.code,
        'message': failure.message,
      });
      Error.throwWithStackTrace(failure, stackTrace);
    }
  }

  Future<Directory> _modelDirectory() async {
    final support = _supportDirectory ?? await getApplicationSupportDirectory();
    return Directory(
      '${support.path}${Platform.pathSeparator}miyin'
      '${Platform.pathSeparator}asr-multilingual-whisper-base',
    );
  }

  Future<bool> _isInstalled(Directory directory) async {
    try {
      final marker = File(
        '${directory.path}${Platform.pathSeparator}.model-version',
      );
      if (!await marker.exists() || await marker.readAsString() != modelId) {
        return false;
      }
      for (final modelFile in _files) {
        final file = File(
          '${directory.path}${Platform.pathSeparator}${modelFile.name}',
        );
        if (!await file.exists() || await file.length() != modelFile.size) {
          return false;
        }
      }
      return true;
    } on FileSystemException {
      return false;
    }
  }

  PlatformException _installationFailure(Object error) {
    if (error is PlatformException) return error;
    if (error is FormatException) {
      return PlatformException(
        code: 'multilingual_asr_integrity_error',
        message: '安装包中的多语言识别资源校验失败，请重新安装觅音。',
        details: error.message,
      );
    }
    if (error is FileSystemException) {
      return PlatformException(
        code: 'multilingual_asr_storage_error',
        message: '无法准备多语言识别资源，请检查设备可用空间。',
        details: error.message,
      );
    }
    return PlatformException(
      code: 'multilingual_asr_install_failed',
      message: '无法准备觅音内置的多语言识别资源。',
      details: error.toString(),
    );
  }

  void _emit(Map<String, Object?> event) {
    if (!_events.isClosed) _events.add(event);
  }
}

final class _AsrModelFile {
  const _AsrModelFile(this.name, this.size, this.sha256);

  final String name;
  final int size;
  final String sha256;
}
