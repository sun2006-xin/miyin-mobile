import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:miyin_app/features/miyin/avatar_image_picker.dart';

void main() {
  late Directory tempDirectory;
  late List<AvatarImageSource> requestedSources;
  XFile? nextImage;

  setUp(() async {
    tempDirectory = await Directory.systemTemp.createTemp('miyin-avatar-');
    requestedSources = [];
    nextImage = null;
  });

  tearDown(() async {
    if (await tempDirectory.exists()) {
      await tempDirectory.delete(recursive: true);
    }
  });

  Future<XFile> imageFile(String name, List<int> bytes) async {
    final path = '${tempDirectory.path}${Platform.pathSeparator}$name';
    await File(path).writeAsBytes(bytes);
    return XFile(path, name: name, mimeType: 'image/jpeg');
  }

  PlatformAvatarImagePicker createPicker({int maxBytes = 256 * 1024}) =>
      PlatformAvatarImagePicker(
        maxBytes: maxBytes,
        fileSelection: (source) async {
          requestedSources.add(source);
          return nextImage;
        },
      );

  test(
    'returns a bounded JPEG data URL and removes the picker temp copy',
    () async {
      final image = await imageFile('avatar.jpg', [0xff, 0xd8, 0xff, 0xd9]);
      nextImage = image;

      final selected = await createPicker().pick(AvatarImageSource.gallery);

      expect(requestedSources, [AvatarImageSource.gallery]);
      expect(selected?.dataUrl, 'data:image/jpeg;base64,/9j/2Q==');
      expect(selected?.toRpcMap().keys, ['dataUrl']);
      expect(await File(image.path).exists(), isFalse);
    },
  );

  test('preserves cancellation without producing an image', () async {
    final selected = await createPicker().pick(AvatarImageSource.camera);

    expect(requestedSources, [AvatarImageSource.camera]);
    expect(selected, isNull);
  });

  test(
    'rejects oversized images and still cleans the picker temp copy',
    () async {
      final image = await imageFile('large.jpg', [
        0xff,
        0xd8,
        0xff,
        0xd9,
        1,
        2,
      ]);
      nextImage = image;

      await expectLater(
        createPicker(maxBytes: 5).pick(AvatarImageSource.gallery),
        throwsA(
          isA<AvatarImagePickerException>().having(
            (error) => error.message,
            'message',
            contains('太大'),
          ),
        ),
      );
      expect(await File(image.path).exists(), isFalse);
    },
  );

  test('rejects bytes that are not a supported image format', () async {
    final image = await imageFile('not-image.jpg', [1, 2, 3, 4]);
    nextImage = image;

    await expectLater(
      createPicker().pick(AvatarImageSource.gallery),
      throwsA(isA<AvatarImagePickerException>()),
    );
    expect(await File(image.path).exists(), isFalse);
  });
}
