import 'dart:convert';
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

final class PickedTranslationImage {
  const PickedTranslationImage({
    required this.path,
    required this.name,
    this.mimeType,
  });

  /// A private local temporary path. It is only passed to the Android OCR
  /// channel and is never serialized into an RPC response.
  final String path;
  final String name;
  final String? mimeType;
}

final class PickedArticleText {
  const PickedArticleText({required this.name, required this.text});

  final String name;
  final String text;
}

abstract interface class TranslationImageSourcePicker {
  Future<PickedTranslationImage?> pickTranslationImage(
    AttachmentSourceKind kind,
  );

  Future<void> disposeTranslationImage(PickedTranslationImage image);
}

abstract interface class TranslationArticleSourcePicker {
  Future<PickedArticleText?> pickArticleText();
}

final class TranslationAttachmentException implements Exception {
  const TranslationAttachmentException(this.code, this.message);

  final String code;
  final String message;
}

const maxTranslationAttachmentTextLength = 10000;
const maxTranslationArticleBytes = maxTranslationAttachmentTextLength * 4 + 3;

/// Uses the system camera, image picker, and document picker.
///
/// Only a selected item's display name and inferred MIME type cross the WebView
/// bridge. A local path, URI, or file contents are never returned to JavaScript.
final class PlatformAttachmentSourcePicker
    implements
        AttachmentSourcePicker,
        TranslationImageSourcePicker,
        TranslationArticleSourcePicker {
  PlatformAttachmentSourcePicker({
    ImagePicker? imagePicker,
    this._articleFilePicker,
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
  final Future<PlatformFile?> Function()? _articleFilePicker;
  final Future<LostDataResponse> Function()? lostDataRecovery;

  @override
  Future<PickedTranslationImage?> pickTranslationImage(
    AttachmentSourceKind kind,
  ) async {
    if (kind != AttachmentSourceKind.camera &&
        kind != AttachmentSourceKind.image) {
      throw ArgumentError.value(kind, 'kind', 'Choose camera or image.');
    }
    final image = await _imagePicker.pickImage(
      source: kind == AttachmentSourceKind.camera
          ? ImageSource.camera
          : ImageSource.gallery,
      maxWidth: 4096,
      maxHeight: 4096,
      imageQuality: 90,
    );
    if (image == null) return null;
    return PickedTranslationImage(
      path: image.path,
      name: _safeName(image.name),
      mimeType: image.mimeType ?? _mimeForExtension(_extension(image.name)),
    );
  }

  @override
  Future<void> disposeTranslationImage(PickedTranslationImage image) async {
    try {
      await File(image.path).delete();
    } catch (_) {
      // The platform picker owns temporary-file cleanup if deletion is denied.
    }
  }

  @override
  Future<PickedArticleText?> pickArticleText() async {
    final file =
        await (_articleFilePicker?.call() ??
            FilePicker.pickFile(
              type: FileType.custom,
              allowedExtensions: const ['txt', 'md'],
            ));
    if (file == null) return null;
    final size = await file.length();
    if (size != null && size > maxTranslationArticleBytes) {
      throw const TranslationAttachmentException(
        'article_too_long',
        '文章超过 10,000 个字符，请选择较短的 TXT 或 Markdown 文件。',
      );
    }
    final bytes = await file.readAsBytes();
    return decodeTranslationArticle(file.name, bytes);
  }

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

PickedArticleText decodeTranslationArticle(String name, List<int> bytes) {
  final extension = name.contains('.')
      ? name.substring(name.lastIndexOf('.') + 1).toLowerCase()
      : '';
  if (extension != 'txt' && extension != 'md') {
    throw const TranslationAttachmentException(
      'article_format_unsupported',
      '只支持 UTF-8 编码的 .txt 和 .md 文件。',
    );
  }
  if (bytes.length > maxTranslationArticleBytes) {
    throw const TranslationAttachmentException(
      'article_too_long',
      '文章超过 10,000 个字符，请选择较短的 TXT 或 Markdown 文件。',
    );
  }

  String text;
  try {
    text = utf8.decode(bytes, allowMalformed: false);
  } on FormatException {
    throw const TranslationAttachmentException(
      'article_not_utf8',
      '文件不是有效的 UTF-8 文本，请另存为 UTF-8 后重试。',
    );
  }
  if (text.startsWith('\uFEFF')) text = text.substring(1);
  if (text.trim().isEmpty) {
    throw const TranslationAttachmentException(
      'article_empty',
      '所选文件没有可翻译的文字。',
    );
  }
  if (text.length > maxTranslationAttachmentTextLength) {
    throw const TranslationAttachmentException(
      'article_too_long',
      '文章超过 10,000 个字符，请选择较短的 TXT 或 Markdown 文件。',
    );
  }
  return PickedArticleText(
    name: PlatformAttachmentSourcePicker._safeName(name),
    text: text,
  );
}
