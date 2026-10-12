import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';

enum AttachmentSourceKind { camera, image, document }

extension AttachmentSourceKindWireName on AttachmentSourceKind {
  String get wireName => switch (this) {
    AttachmentSourceKind.camera => 'camera',
    AttachmentSourceKind.image => 'image',
    AttachmentSourceKind.document => 'document',
  };
}

final class PickedAttachmentSource {
  const PickedAttachmentSource({
    required this.kind,
    required this.name,
    this.mimeType,
  });

  final AttachmentSourceKind kind;
  final String name;
  final String? mimeType;

  Map<String, Object?> toRpcMap() => {
    'canceled': false,
    'kind': kind.wireName,
    'name': name,
    if (mimeType != null) 'mimeType': mimeType,
  };
}

abstract interface class AttachmentSourcePicker {
  Future<PickedAttachmentSource?> pick(AttachmentSourceKind kind);
}

/// Uses the system camera, image picker, and document picker.
///
/// Only a selected item's display name and inferred MIME type cross the WebView
/// bridge. A local path, URI, or file contents are never returned to JavaScript.
final class PlatformAttachmentSourcePicker implements AttachmentSourcePicker {
  PlatformAttachmentSourcePicker({
    ImagePicker? imagePicker,
    this.lostDataRecovery,
  }) : _imagePicker = imagePicker ?? ImagePicker();

  static const _documentExtensions = <String>[
    'txt',
    'md',
    'pdf',
    'rtf',
    'doc',
    'docx',
  ];

  final ImagePicker _imagePicker;
  final Future<LostDataResponse> Function()? lostDataRecovery;

  @override
  Future<PickedAttachmentSource?> pick(AttachmentSourceKind kind) async {
    switch (kind) {
      case AttachmentSourceKind.camera:
      case AttachmentSourceKind.image:
        final image = await _imagePicker.pickImage(
          source: kind == AttachmentSourceKind.camera
              ? ImageSource.camera
              : ImageSource.gallery,
        );
        if (image == null) return null;
        try {
          return PickedAttachmentSource(
            kind: kind,
            name: _safeName(image.name),
            mimeType:
                image.mimeType ?? _mimeForExtension(_extension(image.name)),
          );
        } finally {
          await _deleteTemporaryImage(image);
        }
      case AttachmentSourceKind.document:
        final file = await FilePicker.pickFile(
          type: FileType.custom,
          allowedExtensions: _documentExtensions,
        );
        if (file == null) return null;
        return PickedAttachmentSource(
          kind: kind,
          name: _safeName(file.name),
          mimeType: _mimeForExtension(file.extension),
        );
    }
  }

  /// Returns a camera/gallery selection that Android restored after reclaiming
  /// the activity, then removes its temporary copy because this version only
  /// reports metadata and does not consume image bytes.
  Future<PickedAttachmentSource?> retrieveLostData() async {
    final lostData =
        await (lostDataRecovery?.call() ?? _imagePicker.retrieveLostData());
    final exception = lostData.exception;
    if (exception != null) {
      Error.throwWithStackTrace(exception, StackTrace.current);
    }

    final image =
        lostData.file ??
        (lostData.files?.isNotEmpty == true ? lostData.files!.first : null);
    if (image == null) return null;

    final recovered = PickedAttachmentSource(
      kind: AttachmentSourceKind.image,
      name: _safeName(image.name),
      mimeType: image.mimeType ?? _mimeForExtension(_extension(image.name)),
    );
    final temporaryImages = <XFile>{
      ...?lostData.files,
      if (lostData.file != null) lostData.file!,
    };
    await Future.wait(temporaryImages.map(_deleteTemporaryImage));
    return recovered;
  }

  static Future<void> _deleteTemporaryImage(XFile image) async {
    try {
      await File(image.path).delete();
    } catch (_) {
      // The picker owns temporary-file cleanup if deletion is not permitted.
    }
  }

  static String _safeName(String name) {
    final cleaned = name.replaceAll(RegExp(r'[\\/\u0000-\u001f]'), '').trim();
    if (cleaned.isEmpty) return '已选择文件';
    return cleaned.length <= 180 ? cleaned : '${cleaned.substring(0, 177)}…';
  }

  static String? _extension(String name) {
    final dot = name.lastIndexOf('.');
    if (dot < 0 || dot == name.length - 1) return null;
    return name.substring(dot + 1).toLowerCase();
  }

  static String? _mimeForExtension(String? extension) => switch (extension
      ?.toLowerCase()) {
    'jpg' || 'jpeg' => 'image/jpeg',
    'png' => 'image/png',
    'webp' => 'image/webp',
    'heic' => 'image/heic',
    'gif' => 'image/gif',
    'txt' => 'text/plain',
    'md' => 'text/markdown',
    'pdf' => 'application/pdf',
    'rtf' => 'application/rtf',
    'doc' => 'application/msword',
    'docx' =>
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    _ => null,
  };
}
