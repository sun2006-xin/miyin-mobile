import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miyin_app/features/miyin/multilingual_asr_model_store.dart';
import 'package:miyin_app/features/miyin/multilingual_tts_model_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.android);
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  group('MiyinMultilingualAsrModelStore', () {
    test(
      'installs pinned model assets locally without a network download',
      () async {
        final support = await Directory.systemTemp.createTemp('miyin-asr-');
        addTearDown(() => support.delete(recursive: true));
        final files = <String, Uint8List>{
          'base-encoder.int8.onnx': Uint8List.fromList([1, 2, 3]),
          'base-decoder.int8.onnx': Uint8List.fromList([4, 5, 6, 7]),
          'base-tokens.txt': Uint8List.fromList(utf8.encode('en zh ru fr ja')),
        };
        final store = MiyinMultilingualAsrModelStore.forTesting(
          supportDirectory: support,
          bundle: _MemoryAssetBundle({
            for (final entry in files.entries)
              'assets/voice/asr-whisper-base/${entry.key}': entry.value,
          }),
          files: {
            for (final entry in files.entries)
              entry.key: (
                size: entry.value.length,
                sha256: sha256.convert(entry.value).toString(),
              ),
          },
        );
        final events = <Map<String, Object?>>[];
        final installComplete = Completer<void>();
        final eventSubscription = store.events.listen((event) {
          events.add(event);
          if (event['type'] == 'asr_model_install_complete' &&
              !installComplete.isCompleted) {
            installComplete.complete();
          }
        });

        final status = await store.status();
        await installComplete.future.timeout(const Duration(seconds: 1));

        expect(status['status'], 'bundled');
        expect(status['installed'], isTrue);
        expect(status['bundled'], isTrue);
        expect(status['source'], 'apk');
        expect(
          status['languageTags'],
          containsAll(['zh-Hans', 'en', 'ru', 'fr', 'ja']),
        );
        expect((status['languageTags'] as List).length, 57);
        expect(status['languageTags'], isNot(contains('eo')));
        expect(status['languageTags'], isNot(contains('ga')));
        expect(
          events.map((event) => event['type']),
          containsAll([
            'asr_model_install_progress',
            'asr_model_install_complete',
          ]),
        );
        expect(
          events
              .where((event) => event['type'] == 'asr_model_install_progress')
              .every((event) => event.containsKey('copiedBytes')),
          isTrue,
        );
        expect(
          events.any((event) => event['type'] == 'asr_model_download_progress'),
          isFalse,
        );
        final installed = Directory(
          '${support.path}${Platform.pathSeparator}miyin'
          '${Platform.pathSeparator}asr-multilingual-whisper-base',
        );
        for (final entry in files.entries) {
          expect(
            await File('${installed.path}${Platform.pathSeparator}${entry.key}')
                .readAsBytes(),
            orderedEquals(entry.value),
          );
        }
        expect(
          await File('${installed.path}${Platform.pathSeparator}.model-version')
              .readAsString(),
          MiyinMultilingualAsrModelStore.modelId,
        );
        await expectLater(store.delete(), throwsA(isA<PlatformException>()));
        await eventSubscription.cancel();
        await store.close();
      },
    );

    test(
      'rejects corrupt bundled bytes and leaves no partial installation',
      () async {
        final support = await Directory.systemTemp.createTemp('miyin-asr-bad-');
        addTearDown(() => support.delete(recursive: true));
        final store = MiyinMultilingualAsrModelStore.forTesting(
          supportDirectory: support,
          bundle: _MemoryAssetBundle({
            'assets/voice/asr-whisper-base/base-encoder.int8.onnx':
                Uint8List.fromList([1, 2, 3]),
          }),
          files: {'base-encoder.int8.onnx': (size: 3, sha256: '0' * 64)},
        );

        await expectLater(
          store.installBundled(),
          throwsA(
            isA<PlatformException>().having(
              (error) => error.code,
              'code',
              'multilingual_asr_integrity_error',
            ),
          ),
        );
        expect(
          Directory(
            '${support.path}${Platform.pathSeparator}miyin'
            '${Platform.pathSeparator}asr-multilingual-whisper-base',
          ).existsSync(),
          isFalse,
        );
        await store.close();
      },
    );
  });

  group('MiyinMultilingualTtsModelStore', () {
    test(
      'extracts the bundled model and reports an offline-ready status',
      () async {
        final support = await Directory.systemTemp.createTemp('miyin-tts-');
        addTearDown(() => support.delete(recursive: true));
        final archiveBytes = _supertonicFixtureArchive();
        final assetPath = 'test/tts/supertonic.tar.bz2';
        final store = MiyinMultilingualTtsModelStore.forTesting(
          supportDirectory: support,
          bundle: _MemoryAssetBundle({
            assetPath: Uint8List.fromList(archiveBytes),
          }),
          archiveAsset: assetPath,
          archiveBytes: archiveBytes.length,
          archiveSha256: sha256.convert(archiveBytes).toString(),
        );

        final status = await store.status();

        expect(status['status'], 'bundled');
        expect(status['installed'], isTrue);
        expect(status['bundled'], isTrue);
        expect(status['source'], 'apk');
        expect(status['speakerCount'], 10);
        expect(status['languageTags'], containsAll(['en', 'fr', 'ja', 'ru']));
        final installed = Directory(
          '${support.path}${Platform.pathSeparator}miyin'
          '${Platform.pathSeparator}tts-multilingual-supertonic3',
        );
        for (final name in const [
          'duration_predictor.int8.onnx',
          'text_encoder.int8.onnx',
          'vector_estimator.int8.onnx',
          'vocoder.int8.onnx',
          'tts.json',
          'unicode_indexer.bin',
          'voice.bin',
        ]) {
          expect(
            await File('${installed.path}${Platform.pathSeparator}$name')
                .exists(),
            isTrue,
          );
        }
        await expectLater(store.delete(), throwsA(isA<PlatformException>()));
      },
    );

    test('rejects a bundled archive with a mismatched checksum', () async {
      final support = await Directory.systemTemp.createTemp('miyin-tts-bad-');
      addTearDown(() => support.delete(recursive: true));
      final archiveBytes = _supertonicFixtureArchive();
      final store = MiyinMultilingualTtsModelStore.forTesting(
        supportDirectory: support,
        bundle: _MemoryAssetBundle({
          'test/tts/supertonic.tar.bz2': Uint8List.fromList(archiveBytes),
        }),
        archiveAsset: 'test/tts/supertonic.tar.bz2',
        archiveBytes: archiveBytes.length,
        archiveSha256: '0' * 64,
      );

      await expectLater(
        store.installBundled(),
        throwsA(
          isA<PlatformException>().having(
            (error) => error.code,
            'code',
            'multilingual_tts_integrity_error',
          ),
        ),
      );
      expect(
        Directory(
          '${support.path}${Platform.pathSeparator}miyin'
          '${Platform.pathSeparator}tts-multilingual-supertonic3',
        ).existsSync(),
        isFalse,
      );
    });
  });
}

List<int> _supertonicFixtureArchive() {
  final archive = Archive();
  final directory = MiyinMultilingualTtsModelStore.modelDirectoryName;
  for (final file in [
    'duration_predictor.int8.onnx',
    'text_encoder.int8.onnx',
    'vector_estimator.int8.onnx',
    'vocoder.int8.onnx',
    'tts.json',
    'unicode_indexer.bin',
    'voice.bin',
  ]) {
    archive.addFile(ArchiveFile.bytes('$directory/$file', [1, 2, 3]));
  }
  return BZip2Encoder().encode(TarEncoder().encode(archive));
}

final class _MemoryAssetBundle extends CachingAssetBundle {
  _MemoryAssetBundle(this._assets);

  final Map<String, Uint8List> _assets;

  @override
  Future<ByteData> load(String key) async {
    final bytes = _assets[key];
    if (bytes == null) throw FlutterError('No test asset registered for $key');
    return ByteData.view(
      bytes.buffer,
      bytes.offsetInBytes,
      bytes.lengthInBytes,
    );
  }
}
