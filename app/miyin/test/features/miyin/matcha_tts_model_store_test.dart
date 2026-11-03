import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miyin_app/features/miyin/matcha_tts_model_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.android);
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  Future<Directory> support() async {
    final directory = await Directory.systemTemp.createTemp('miyin-matcha-');
    addTearDown(() => directory.delete(recursive: true));
    return directory;
  }

  test('prepares bundled assets once for concurrent calls and repairs missing files', () async {
    final bundle = _Bundle();
    final store = MiyinMatchaTtsModelStore.forTesting(
      supportDirectory: await support(),
      bundle: bundle,
    );
    final directories = await Future.wait([store.prepare(), store.prepare()]);
    expect(directories[0].path, directories[1].path);
    expect(bundle.archiveLoads, 1);
    final model = File('${directories.first.path}/model-steps-3.onnx');
    expect(await model.readAsBytes(), [1, 2, 3]);
    await store.prepare();
    expect(bundle.archiveLoads, 1);
    await model.delete();
    await store.prepare();
    expect(bundle.archiveLoads, 2);
    expect(await model.readAsBytes(), [1, 2, 3]);
  });

  test(
    'rejects corrupt archive without replacing an existing model and can retry',
    () async {
      final directory = await support();
      final installed = Directory(
        '${directory.path}/miyin/tts-ai-matcha-zh-en',
      );
      await installed.create(recursive: true);
      final old = File('${installed.path}/old-model');
      await old.writeAsString('keep');
      final bundle = _Bundle()..corrupt = true;
      final store = MiyinMatchaTtsModelStore.forTesting(
        supportDirectory: directory,
        bundle: bundle,
      );
      await expectLater(
        store.prepare(),
        throwsA(
          isA<PlatformException>().having(
            (e) => e.code,
            'code',
            'matcha_tts_integrity_error',
          ),
        ),
      );
      expect(await old.readAsString(), 'keep');
      expect(
        Directory('${directory.path}/miyin/.tts-ai-matcha-zh-en.part')
            .existsSync(),
        isFalse,
      );
      bundle.corrupt = false;
      expect((await store.prepare()).path, installed.path);
    },
  );

  test('rejects unsafe manifest paths before loading archive', () async {
    final bundle = _Bundle()..unsafe = true;
    final directory = await support();
    final store = MiyinMatchaTtsModelStore.forTesting(
      supportDirectory: directory,
      bundle: bundle,
    );
    await expectLater(store.prepare(), throwsA(isA<PlatformException>()));
    expect(bundle.archiveLoads, 0);
    expect(File('${directory.path}/escape').existsSync(), isFalse);
  });

  test('accepts real eSpeak paths with exclamation marks and spaces', () async {
    final bundle = _Bundle()..entryPath = 'espeak-ng-data/voices/!v/Mr serious';
    final store = MiyinMatchaTtsModelStore.forTesting(
      supportDirectory: await support(),
      bundle: bundle,
    );
    final installed = await store.prepare();
    expect(await File('${installed.path}/${bundle.entryPath}').readAsBytes(), [
      1,
      2,
      3,
    ]);
  });

  test('accepts every path from the actual packaged manifest before checking archive', () async {
    final bundle = _PackagedManifestBundle();
    final store = MiyinMatchaTtsModelStore.forTesting(
      supportDirectory: await support(),
      bundle: bundle,
    );
    await expectLater(
      store.prepare(),
      throwsA(
        isA<PlatformException>().having(
          (error) => error.details.toString(),
          'details',
          contains('archive failed verification'),
        ),
      ),
    );
    expect(bundle.archiveLoads, 1);
  });

  test('rejects archive entries missing from the manifest', () async {
    final bundle = _Bundle()..extraEntry = true;
    final directory = await support();
    final store = MiyinMatchaTtsModelStore.forTesting(
      supportDirectory: directory,
      bundle: bundle,
    );
    await expectLater(store.prepare(), throwsA(isA<PlatformException>()));
    expect(
      Directory('${directory.path}/miyin/tts-ai-matcha-zh-en').existsSync(),
      isFalse,
    );
  });
}

final class _PackagedManifestBundle extends CachingAssetBundle {
  int archiveLoads = 0;
  @override
  Future<String> loadString(String key, {bool cache = true}) =>
      File(key).readAsString();
  @override
  Future<ByteData> load(String key) async {
    archiveLoads++;
    return ByteData(1);
  }
}

final class _Bundle extends CachingAssetBundle {
  bool corrupt = false;
  bool unsafe = false;
  bool extraEntry = false;
  String entryPath = 'model-steps-3.onnx';
  int archiveLoads = 0;

  List<int> get archive {
    final files = Archive()..addFile(ArchiveFile.bytes(entryPath, [1, 2, 3]));
    if (extraEntry) files.addFile(ArchiveFile.bytes('unexpected', [4]));
    return GZipEncoder().encode(TarEncoder().encode(files));
  }

  @override
  Future<String> loadString(String key, {bool cache = true}) async =>
      jsonEncode({
        'version': MiyinMatchaTtsModelStore.modelId,
        'archiveBytes': archive.length,
        'archiveSha256': sha256.convert(archive).toString(),
        'files': [
          {'path': unsafe ? '../escape' : entryPath, 'size': 3},
        ],
      });

  @override
  Future<ByteData> load(String key) async {
    archiveLoads++;
    final data = Uint8List.fromList(corrupt ? [0] : archive);
    return ByteData.view(data.buffer);
  }
}
