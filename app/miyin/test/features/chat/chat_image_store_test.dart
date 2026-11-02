import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:miyin_app/features/chat/chat_image_store.dart';
import 'package:miyin_app/features/miyin/attachment_source_picker.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Uint8List png;
  late Directory temporary;
  late Directory private;
  late File source;
  late ChatImageStore store;

  setUpAll(() async {
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawColor(const ui.Color(0xff1188aa), ui.BlendMode.src);
    final picture = recorder.endRecording();
    final image = await picture.toImage(300, 200);
    png = (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer
        .asUint8List();
    image.dispose();
    picture.dispose();
  });

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('chat_image_store_test_');
    private = Directory('${temporary.path}/private');
    source = await File('${temporary.path}/chosen.png').writeAsBytes(png);
    store = ChatImageStore(directory: private);
  });
  tearDown(() async {
    await temporary.delete(recursive: true);
  });

  PickedTranslationImage selected({String name = 'chosen.png'}) =>
      PickedTranslationImage(
        path: source.path,
        name: name,
        mimeType:
            'image/jpeg', // The signature, not this hint, is authoritative.
      );

  test('copies original bytes privately, returns bounded preview and safe ID', () async {
    final metadata = await store.importImage(
      selected(name: r'C:\secret\photo.png'),
    );
    final id = metadata['id']! as String;
    expect(id, matches(RegExp(r'^[a-f0-9]{32}$')));
    expect(metadata['name'], 'photo.png');
    expect(metadata['mimeType'], 'image/png');
    expect(metadata['bytes'], png.length);
    expect(
      metadata.keys,
      unorderedEquals(['id', 'name', 'mimeType', 'bytes', 'thumbnailDataUrl']),
    );
    expect(jsonEncode(metadata), isNot(contains(temporary.path)));
    final preview = metadata['thumbnailDataUrl']! as String;
    expect(preview, startsWith('data:image/png;base64,'));
    expect(
      base64Decode(preview.split(',').last).length,
      lessThanOrEqualTo(ChatImageStore.maxThumbnailBytes),
    );
    expect(await File('${private.path}/$id.image').readAsBytes(), png);
    expect(await source.readAsBytes(), png);
    expect(
      await store.verifiedPath(id),
      '${private.path}${Platform.pathSeparator}$id.image',
    );
    final previewBuffer = await ui.ImmutableBuffer.fromUint8List(
      base64Decode(preview.split(',').last),
    );
    final previewDescriptor = await ui.ImageDescriptor.encoded(previewBuffer);
    expect(previewDescriptor.width, 128);
    expect(previewDescriptor.height, 85);
    previewDescriptor.dispose();
    previewBuffer.dispose();

    // A new store has no in-memory index and still resolves the saved original.
    final restarted = ChatImageStore(directory: private);
    final saved = await restarted.readImage(id);
    expect(saved.bytes, png);
    expect(saved.mimeType, 'image/png');
    expect(await restarted.thumbnail(id), startsWith('data:image/png;base64,'));
  });

  test('keeps actual JPEG original bytes with PNG preview', () async {
    // Synthetic 1px JPEG, generated without any user media.
    final jpeg = base64Decode(
      '/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/2wBDAQkJCQwLDBgNDRgyIRwhMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjL/wAARCAABAAEDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwDkKKKK8c+XP//Z',
    );
    await source.writeAsBytes(jpeg);
    final metadata = await store.importImage(selected());
    expect(metadata['mimeType'], 'image/jpeg');
    expect(metadata['thumbnailDataUrl'], startsWith('data:image/png;base64,'));
    expect((await store.readImage(metadata['id']! as String)).bytes, jpeg);
  });

  test(
    'rejects arbitrary paths and malformed IDs in every entry point',
    () async {
      for (final id in ['../chosen.png', source.path, '', 'A' * 32, 'a' * 33]) {
        await expectLater(store.readImage(id), throwsFormatException);
        await expectLater(store.remove(id), throwsFormatException);
        await expectLater(store.verifiedPath(id), throwsFormatException);
        await expectLater(store.pruneReferenced({id}), throwsFormatException);
      }
      expect(await source.exists(), isTrue);
    },
  );

  test(
    'rejects unsupported magic, empty and oversized files before persisting',
    () async {
      for (final bytes in [
        <int>[],
        [71, 73, 70, 56],
        Uint8List(ChatImageStore.maxImageBytes + 1),
      ]) {
        await source.writeAsBytes(bytes);
        await expectLater(store.importImage(selected()), throwsFormatException);
      }
      expect(await private.list().toList(), isEmpty);
    },
  );

  test('rejects truncated PNG even with valid magic', () async {
    await source.writeAsBytes(png.take(8).toList());
    await expectLater(store.importImage(selected()), throwsA(anything));
    expect(await private.list().toList(), isEmpty);
  });

  test(
    'rejects oversized decoded dimensions before making a preview',
    () async {
      final hugeHeader = Uint8List.fromList(png);
      final header = ByteData.sublistView(hugeHeader);
      header.setUint32(16, 20000);
      var crc = 0xffffffff;
      for (final byte in hugeHeader.sublist(12, 29)) {
        crc ^= byte;
        for (var bit = 0; bit < 8; bit++) {
          crc = (crc >> 1) ^ ((crc & 1) == 1 ? 0xedb88320 : 0);
        }
      }
      header.setUint32(29, crc ^ 0xffffffff);
      await source.writeAsBytes(hugeHeader);
      await expectLater(store.importImage(selected()), throwsFormatException);
      expect(await private.list().toList(), isEmpty);
    },
  );

  test('enforces bounded renderer output', () async {
    store = ChatImageStore(
      directory: private,
      thumbnailRenderer: (_) async =>
          Uint8List(ChatImageStore.maxThumbnailBytes + 1),
    );
    await expectLater(store.importImage(selected()), throwsFormatException);
    expect(await private.list().toList(), isEmpty);
  });

  test(
    'prune keeps references, unrelated files and directories, never source',
    () async {
      final keep = (await store.importImage(selected()))['id']! as String;
      final drop = (await store.importImage(selected()))['id']! as String;
      final unrelated = await File('${private.path}/notes.txt')
          .writeAsString('keep');
      final malformed = await File('${private.path}/other.image')
          .writeAsString('keep');
      final child = await Directory('${private.path}/${'b' * 32}.image')
          .create();
      await store.pruneReferenced({keep});
      expect((await store.readImage(keep)).bytes, png);
      await expectLater(
        store.readImage(drop),
        throwsA(isA<FileSystemException>()),
      );
      expect(await unrelated.readAsString(), 'keep');
      expect(await malformed.readAsString(), 'keep');
      expect(await child.exists(), isTrue);
      await store.remove(keep);
      await store.remove(keep); // Idempotent if history cleanup is repeated.
      expect(await source.readAsBytes(), png);
    },
  );

  test(
    'rejects symlink source, store ancestor and stored image; prune skips link',
    () async {
      final sourceLink = Link('${temporary.path}/chosen-link.png');
      try {
        await sourceLink.create(source.path);
      } on FileSystemException catch (error) {
        // Windows requires Developer Mode or the symlink privilege.
        if (Platform.isWindows && error.osError?.errorCode == 1314) {
          markTestSkipped('Windows symlink creation privilege unavailable');
          return;
        }
        rethrow;
      }
      await expectLater(
        store.importImage(
          PickedTranslationImage(path: sourceLink.path, name: 'linked.png'),
        ),
        throwsA(isA<FileSystemException>()),
      );
      await private.create();
      final id = 'a' * 32;
      final imageLink = Link('${private.path}/$id.image');
      await imageLink.create(source.path);
      await expectLater(
        store.readImage(id),
        throwsA(isA<FileSystemException>()),
      );
      await expectLater(store.remove(id), throwsA(isA<FileSystemException>()));
      await store.pruneReferenced({});
      expect(await imageLink.exists(), isTrue);
      final directoryLink = Link('${temporary.path}/linked-private');
      await directoryLink.create(private.path);
      final linkedStore = ChatImageStore(
        directory: Directory('${directoryLink.path}/child'),
      );
      await expectLater(
        linkedStore.importImage(selected()),
        throwsA(isA<FileSystemException>()),
      );
      expect(await source.readAsBytes(), png);
      await directoryLink.delete();
      await imageLink.delete();
      await sourceLink.delete();
    },
  );
}
