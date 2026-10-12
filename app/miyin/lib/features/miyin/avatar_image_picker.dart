import 'dart:convert';
import 'dart:io';

import 'package:image_picker/image_picker.dart';

enum AvatarImageSource { camera, gallery }

typedef AvatarFileSelection = Future<XFile?> Function(AvatarImageSource source);

final class PickedAvatarImage {
  const PickedAvatarImage({required this.dataUrl});

  final String dataUrl;

  Map<String, Object?> toRpcMap() => {'dataUrl': dataUrl};
}

abstract interface class AvatarImagePicker {
  Future<PickedAvatarImage?> pick(AvatarImageSource source);
}

final class AvatarImagePickerException implements Exception {
  const AvatarImagePickerException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Selects a small image and returns its contents without exposing a path.
///
/// The WebView stores the bounded data URL locally. Only JPEG, PNG, and WebP
/// bytes are allowed, and the platform picker is asked to downsize photos
/// before they cross the native bridge.
final class PlatformAvatarImagePicker implements AvatarImagePicker {
  PlatformAvatarImagePicker({
    ImagePicker? imagePicker,
    this.fileSelection,
    this.maxBytes = 256 * 1024,
  }) : _imagePicker = imagePicker ?? ImagePicker();

  static const maxImageDimension = 512.0;
  static const imageQuality = 72;

  final ImagePicker _imagePicker;
  final AvatarFileSelection? fileSelection;
  final int maxBytes;

  @override
  Future<PickedAvatarImage?> pick(AvatarImageSource source) async {
    final image = await _select(source);
    if (image == null) return null;

    try {
      final bytes = await image.readAsBytes();
      if (bytes.isEmpty) {
        throw const AvatarImagePickerException('没有读取到图片，请重新选择。');
      }
      if (bytes.length > maxBytes) {
        throw const AvatarImagePickerException('头像图片仍然太大，请选择尺寸较小的照片。');
      }

      final mimeType = _mimeType(bytes);
      if (mimeType == null) {
        throw const AvatarImagePickerException(
          '暂不支持这种图片格式，请选择 JPG、PNG 或 WebP。',
        );
      }
      return PickedAvatarImage(
        dataUrl: 'data:$mimeType;base64,${base64Encode(bytes)}',
      );
    } finally {
      await _deleteTemporaryCopy(image);
    }
  }

  Future<XFile?> _select(AvatarImageSource source) {
    final selection = fileSelection;
    if (selection != null) return selection(source);
    return _imagePicker.pickImage(
      source: source == AvatarImageSource.camera
          ? ImageSource.camera
          : ImageSource.gallery,
      maxWidth: maxImageDimension,
      maxHeight: maxImageDimension,
      imageQuality: imageQuality,
    );
  }

  static String? _mimeType(List<int> bytes) {
    if (bytes.length >= 3 &&
        bytes[0] == 0xff &&
        bytes[1] == 0xd8 &&
        bytes[2] == 0xff) {
      return 'image/jpeg';
    }
    if (bytes.length >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4e &&
        bytes[3] == 0x47 &&
        bytes[4] == 0x0d &&
        bytes[5] == 0x0a &&
        bytes[6] == 0x1a &&
        bytes[7] == 0x0a) {
      return 'image/png';
    }
    if (bytes.length >= 12 &&
        _ascii(bytes, 0, 4) == 'RIFF' &&
        _ascii(bytes, 8, 12) == 'WEBP') {
      return 'image/webp';
    }
    return null;
  }

  static String _ascii(List<int> bytes, int start, int end) =>
      String.fromCharCodes(bytes.sublist(start, end));

  static Future<void> _deleteTemporaryCopy(XFile image) async {
    try {
      await File(image.path).delete();
    } catch (_) {
      // The platform picker owns cache cleanup when deletion is unavailable.
    }
  }
}
