import 'dart:convert';
import 'dart:typed_data';

/// A bounded copy of selected image bytes. The picker/store must additionally
/// decode the image and bound pixel dimensions; signatures alone are not a decode.
final class ChatImage {
  ChatImage({required this.mimeType, required Uint8List bytes}) {
    if (bytes.isEmpty ||
        bytes.length > maxImageBytes ||
        !_matches(mimeType, bytes)) {
      throw ArgumentError('图片为空、格式不符或超过单张 8 MiB 限制。');
    }
    this.bytes = Uint8List.fromList(bytes).asUnmodifiableView();
  }

  static const maxImageBytes = 8 * 1024 * 1024;
  static const maxTotalBytes = 16 * 1024 * 1024;
  static const maxImages = 4;
  final String mimeType;
  late final Uint8List bytes;
  String get base64 => base64Encode(bytes);
  String get dataUrl => 'data:$mimeType;base64,$base64';

  static bool _matches(String type, Uint8List bytes) {
    bool starts(List<int> signature) =>
        bytes.length >= signature.length &&
        Iterable<int>.generate(signature.length)
            .every((i) => bytes[i] == signature[i]);
    return switch (type) {
      'image/png' => starts([137, 80, 78, 71, 13, 10, 26, 10]),
      'image/jpeg' => starts([255, 216, 255]),
      'image/webp' =>
        bytes.length >= 12 &&
            starts([82, 73, 70, 70]) &&
            bytes[8] == 87 &&
            bytes[9] == 69 &&
            bytes[10] == 66 &&
            bytes[11] == 80,
      _ => false,
    };
  }
}

/// Snapshots the binding containers so later UI edits cannot change a request.
Map<int, List<ChatImage>> snapshotChatImages(
  Map<int, List<ChatImage>> images,
) => Map<int, List<ChatImage>>.unmodifiable({
  for (final entry in images.entries)
    if (entry.value.isNotEmpty)
      entry.key: List<ChatImage>.unmodifiable(entry.value),
});

/// Indices refer to the original messages passed to complete(), excluding its
/// injected system prompt. This validates structure, not model capability.
void validateChatImages(
  Map<int, List<ChatImage>> images,
  List<Map<String, String>> messages,
) {
  var count = 0, bytes = 0;
  for (final entry in images.entries) {
    if (entry.key < 0 ||
        entry.key >= messages.length ||
        messages[entry.key]['role'] != 'user') {
      throw ArgumentError('原图只能绑定到有效的用户消息。');
    }
    count += entry.value.length;
    for (final image in entry.value) {
      bytes += image.bytes.length;
    }
  }
  if (count > ChatImage.maxImages || bytes > ChatImage.maxTotalBytes) {
    throw ArgumentError('一次最多 4 张原图，合计不超过 16 MiB。');
  }
}
