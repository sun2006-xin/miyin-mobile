import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../miyin/attachment_source_picker.dart';

typedef ChatImageThumbnailRenderer = Future<Uint8List> Function(
  Uint8List bytes,
);

final class StoredChatImage {
  const StoredChatImage({required this.bytes, required this.mimeType});

  final Uint8List bytes;
  final String mimeType;
}

/// Private native storage. Only opaque IDs and bounded previews cross the bridge.
/// The owning host supplies an application-private directory and handles picker
/// temporary-file disposal. Original bytes are never changed by this store.
final class ChatImageStore {
  ChatImageStore({
    required Directory directory,
    ChatImageThumbnailRenderer? thumbnailRenderer,
  }) : _directory = directory.absolute,
       _thumbnailRenderer = thumbnailRenderer ?? _renderThumbnail;

  static const maxImageBytes = 8 * 1024 * 1024;
  static const maxThumbnailBytes = 64 * 1024;
  static final _idPattern = RegExp(r'^[a-f0-9]{32}$');
  final Directory _directory;
  final ChatImageThumbnailRenderer _thumbnailRenderer;
  final Random _random = Random.secure();

  Future<Map<String, Object?>> importImage(PickedTranslationImage image) async {
    await _prepareDirectory();
    final source = File(image.path).absolute;
    await _assertNoLinks(source.path);
    final bytes = await _readBounded(source);
    final mimeType = _mimeType(bytes);
    final preview = await _preview(bytes);
    String id;
    File destination;
    do {
      id = List.generate(
        16,
        (_) => _random.nextInt(256),
      ).map((n) => n.toRadixString(16).padLeft(2, '0')).join();
      destination = _file(id);
    } while (await FileSystemEntity.type(
          destination.path,
          followLinks: false,
        ) !=
        FileSystemEntityType.notFound);
    await _assertNoLinks(destination.path);
    await destination.writeAsBytes(bytes, flush: true);
    return {
      'id': id,
      'name': _displayName(image.name, mimeType),
      'mimeType': mimeType,
      'bytes': bytes.length,
      'thumbnailDataUrl': preview,
    };
  }

  Future<StoredChatImage> readImage(String id) async {
    final file = _file(id);
    await _assertNoLinks(file.path);
    final bytes = await _readBounded(file);
    return StoredChatImage(bytes: bytes, mimeType: _mimeType(bytes));
  }

  Future<String> thumbnail(String id) async =>
      _preview((await readImage(id)).bytes);

  /// Native-only access for an explicit OCR action. Never serialize this path
  /// into RPC data or history; only an existing opaque store ID is accepted.
  Future<String> verifiedPath(String id) async {
    await readImage(id);
    return _file(id).path;
  }

  Future<void> remove(String id) async {
    final file = _file(id);
    await _assertNoLinks(file.path);
    if (await file.exists()) await file.delete();
  }

  /// Removes only this store's unreferenced image files; never traverses folders
  /// or links, or removes unrelated application data in the supplied directory.
  Future<void> pruneReferenced(Set<String> ids) async {
    if (ids.any((id) => !_idPattern.hasMatch(id))) {
      throw const FormatException('Invalid chat image ID');
    }
    await _assertNoLinks(_directory.path);
    if (!await _directory.exists()) return;
    await for (final entity in _directory.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      if (!name.endsWith('.image')) continue;
      final id = name.substring(0, name.length - '.image'.length);
      if (_idPattern.hasMatch(id) && !ids.contains(id)) await remove(id);
    }
  }

  File _file(String id) {
    if (!_idPattern.hasMatch(id)) {
      throw const FormatException('Invalid chat image ID');
    }
    return File('${_directory.path}${Platform.pathSeparator}$id.image');
  }

  Future<void> _prepareDirectory() async {
    await _assertNoLinks(_directory.path);
    await _directory.create(recursive: true);
    await _assertNoLinks(_directory.path);
  }

  static Future<void> _assertNoLinks(String path) async {
    var current = File(path).absolute.path;
    while (true) {
      if (await FileSystemEntity.type(current, followLinks: false) ==
          FileSystemEntityType.link) {
        throw const FileSystemException('Image paths must not contain links');
      }
      final parent = Directory(current).parent.path;
      if (parent == current) return;
      current = parent;
    }
  }

  static Future<Uint8List> _readBounded(File file) async {
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw const FileSystemException('Chat image is unavailable');
    }
    final handle = await file.open();
    try {
      if (await handle.length() > maxImageBytes) {
        throw const FormatException('Images must be at most 8 MiB');
      }
      final bytes = await handle.read(maxImageBytes + 1);
      if (bytes.length > maxImageBytes) {
        throw const FormatException('Images must be at most 8 MiB');
      }
      return bytes;
    } finally {
      await handle.close();
    }
  }

  static String _mimeType(Uint8List bytes) {
    const png = [137, 80, 78, 71, 13, 10, 26, 10];
    if (bytes.length >= png.length &&
        List.generate(png.length, (i) => bytes[i] == png[i]).every((v) => v)) {
      return 'image/png';
    }
    if (bytes.length >= 3 &&
        bytes[0] == 0xff &&
        bytes[1] == 0xd8 &&
        bytes[2] == 0xff) {
      return 'image/jpeg';
    }
    throw const FormatException('Only JPEG and PNG images are supported');
  }

  Future<String> _preview(Uint8List bytes) async {
    final thumbnail = await _thumbnailRenderer(bytes);
    if (thumbnail.isEmpty ||
        thumbnail.length > maxThumbnailBytes ||
        _mimeType(thumbnail) != 'image/png') {
      throw const FormatException('Unable to create a bounded image preview');
    }
    return 'data:image/png;base64,${base64Encode(thumbnail)}';
  }

  static String _displayName(String name, String mimeType) {
    final leaf = name
        .split(RegExp(r'[/\\]'))
        .last
        .replaceAll(RegExp(r'[\x00-\x1f\x7f<>:"|?*]'), '')
        .trim();
    if (leaf.isEmpty || leaf == '.' || leaf == '..') {
      return mimeType == 'image/png' ? 'image.png' : 'image.jpg';
    }
    return String.fromCharCodes(leaf.runes.take(120));
  }

  static Future<Uint8List> _renderThumbnail(Uint8List bytes) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    ui.Image? frameImage;
    try {
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      final width = descriptor.width;
      final height = descriptor.height;
      if (width <= 0 ||
          height <= 0 ||
          width > 16384 ||
          height > 16384 ||
          width * height > 40000000) {
        throw const FormatException('Image dimensions are too large');
      }
      final scale = min(1.0, 128 / max(width, height));
      codec = await descriptor.instantiateCodec(
        targetWidth: max(1, (width * scale).round()),
        targetHeight: max(1, (height * scale).round()),
      );
      frameImage = (await codec.getNextFrame()).image;
      final data = await frameImage.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) throw const FormatException('Unable to decode image');
      return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } finally {
      frameImage?.dispose();
      codec?.dispose();
      descriptor?.dispose();
      buffer.dispose();
    }
  }
}
