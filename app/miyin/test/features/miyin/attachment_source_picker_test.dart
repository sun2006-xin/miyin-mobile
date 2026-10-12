import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:miyin_app/features/miyin/attachment_source_picker.dart';

void main() {
  late Directory tempDirectory;

  setUp(() async {
    tempDirectory = await Directory.systemTemp.createTemp('miyin-lost-image-');
  });

  tearDown(() async {
    if (await tempDirectory.exists()) {
      await tempDirectory.delete(recursive: true);
    }
  });

  test(
    'restores a single Android image result from LostDataResponse.file',
    () async {
      final imagePath =
          '${tempDirectory.path}${Platform.pathSeparator}restored.png';
      await File(imagePath).writeAsBytes([1, 2, 3]);
      final picker = PlatformAttachmentSourcePicker(
        lostDataRecovery: () async => LostDataResponse(
          file: XFile(imagePath, name: 'restored.png', mimeType: 'image/png'),
        ),
      );

      final recovered = await picker.retrieveLostData();

      expect(recovered?.kind, AttachmentSourceKind.image);
      expect(recovered?.name, 'restored.png');
      expect(recovered?.mimeType, 'image/png');
      expect(await File(imagePath).exists(), isFalse);
    },
  );

  test(
    'reports a lost-data exception instead of treating it as no result',
    () async {
      final picker = PlatformAttachmentSourcePicker(
        lostDataRecovery: () async => LostDataResponse(
          exception: PlatformException(
            code: 'lost-image',
            message: 'picker failed',
          ),
        ),
      );

      await expectLater(
        picker.retrieveLostData(),
        throwsA(isA<PlatformException>()),
      );
    },
  );
}
