import 'package:flutter/services.dart';

abstract interface class TranslationImageTextRecognizer {
  Future<TranslationImageRecognition> recognize(String localPath);
}

/// A single OCR text block and its rectangle, normalized against the preview
/// image dimensions so the WebView can place translations over the source.
final class TranslationImageTextBlock {
  const TranslationImageTextBlock({
    required this.text,
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
    this.segments = const <String>[],
  });

  final String text;
  final double left;
  final double top;
  final double right;
  final double bottom;
  /// OCR lines retained so image translation can retry a failed paragraph
  /// without discarding the geometry of the original text block.
  final List<String> segments;

  Map<String, Object?> toRpcMap() => {
    'text': text,
    'left': left,
    'top': top,
    'right': right,
    'bottom': bottom,
    if (segments.isNotEmpty) 'segments': segments,
  };
}

/// Local OCR output. The preview is a resized JPEG data URL, not the original
/// photo, which keeps the Flutter-to-WebView bridge payload bounded.
final class TranslationImageRecognition {
  const TranslationImageRecognition({
    required this.recognizedText,
    required this.previewDataUrl,
    required this.width,
    required this.height,
    required this.blocks,
    int? totalBlockCount,
    this.omittedBlockCount = 0,
  }) : _reportedTotalBlockCount = totalBlockCount;

  static const maxBlocks = 80;

  final String recognizedText;
  final String previewDataUrl;
  final int width;
  final int height;
  final List<TranslationImageTextBlock> blocks;
  final int? _reportedTotalBlockCount;
  final int omittedBlockCount;

  int get totalBlockCount {
    final reported =
        _reportedTotalBlockCount ?? blocks.length + omittedBlockCount;
    final observed = blocks.length + omittedBlockCount;
    return reported > observed ? reported : observed;
  }

  bool get truncated =>
      omittedBlockCount > 0 || totalBlockCount > blocks.length;

  /// Applies the RPC/UI block budget and keeps the text consistent with the
  /// geometry blocks that can actually be rendered and translated.
  TranslationImageRecognition limitBlocks() {
    final limitedBlocks = blocks.take(maxBlocks).toList(growable: false);
    final total = totalBlockCount > blocks.length
        ? totalBlockCount
        : blocks.length;
    final omitted = total > limitedBlocks.length
        ? total - limitedBlocks.length
        : 0;
    return TranslationImageRecognition(
      recognizedText: limitedBlocks.map((block) => block.text).join('\n'),
      previewDataUrl: previewDataUrl,
      width: width,
      height: height,
      blocks: List.unmodifiable(limitedBlocks),
      totalBlockCount: total,
      omittedBlockCount: omitted,
    );
  }

  Map<String, Object?> toRpcMap() {
    final limited = limitBlocks();
    return {
      'recognizedText': limited.recognizedText,
      'previewDataUrl': limited.previewDataUrl,
      'width': limited.width,
      'height': limited.height,
      'blocks': limited.blocks
          .map((block) => block.toRpcMap())
          .toList(growable: false),
      'totalBlockCount': limited.totalBlockCount,
      'omittedBlockCount': limited.omittedBlockCount,
      'truncated': limited.truncated,
    };
  }
}

/// Routes a picker-owned local image path to Android's bundled ML Kit OCR.
/// The path never crosses the WebView RPC boundary.
final class BundledMlKitImageTextRecognizer
    implements TranslationImageTextRecognizer {
  const BundledMlKitImageTextRecognizer({
    this._channel = const MethodChannel('com.miyin.app/attachment-ocr'),
  });

  final MethodChannel _channel;

  @override
  Future<TranslationImageRecognition> recognize(String localPath) async {
    final raw = await _channel.invokeMethod<Object?>('recognizeText', {
      'path': localPath,
    });
    if (raw is! Map) {
      throw const FormatException('Image OCR returned an invalid response.');
    }
    final map = Map<Object?, Object?>.from(raw);
    final recognizedText = map['recognizedText'];
    final previewDataUrl = map['previewDataUrl'];
    final width = map['width'];
    final height = map['height'];
    final rawBlocks = map['blocks'];
    if (recognizedText is! String ||
        previewDataUrl is! String ||
        !_jpegDataUrlPattern.hasMatch(previewDataUrl) ||
        previewDataUrl.length > 2300000 ||
        width is! int ||
        height is! int ||
        width < 1 ||
        height < 1 ||
        width > 2560 ||
        height > 2560 ||
        rawBlocks is! List) {
      throw const FormatException('Image OCR returned an invalid response.');
    }
    final blocks = <TranslationImageTextBlock>[];
    // Native normally caps this list too. Scan at most one extra block here so
    // an older or misbehaving plugin cannot make Dart parse an unbounded list.
    for (final item in rawBlocks.take(TranslationImageRecognition.maxBlocks + 1)) {
      if (item is! Map) continue;
      final block = Map<Object?, Object?>.from(item);
      final text = block['text'];
      final left = _normalizedCoordinate(block['left']);
      final top = _normalizedCoordinate(block['top']);
      final right = _normalizedCoordinate(block['right']);
      final bottom = _normalizedCoordinate(block['bottom']);
      final rawSegments = block['segments'];
      final segments = rawSegments is List
          ? rawSegments
              .whereType<String>()
              .map((segment) => segment.trim())
              .where((segment) => segment.isNotEmpty)
              .take(16)
              .toList(growable: false)
          : const <String>[];
      if (text is! String ||
          text.trim().isEmpty ||
          left == null ||
          top == null ||
          right == null ||
          bottom == null ||
          right <= left ||
          bottom <= top) {
        continue;
      }
      blocks.add(
        TranslationImageTextBlock(
          text: text.trim(),
          left: left,
          top: top,
          right: right,
          bottom: bottom,
          segments: segments,
        ),
      );
    }
    final reportedTotalBlockCount = _nonNegativeInt(map['totalBlockCount']);
    final omittedBlockCount = _nonNegativeInt(map['omittedBlockCount']) ?? 0;
    final totalBlockCount = [
      reportedTotalBlockCount ?? rawBlocks.length,
      rawBlocks.length + omittedBlockCount,
      blocks.length + omittedBlockCount,
    ].reduce((left, right) => left > right ? left : right);
    return TranslationImageRecognition(
      recognizedText: blocks.map((block) => block.text).join('\n'),
      previewDataUrl: previewDataUrl,
      width: width,
      height: height,
      blocks: List.unmodifiable(blocks),
      totalBlockCount: totalBlockCount,
      omittedBlockCount: omittedBlockCount,
    ).limitBlocks();
  }

  static int? _nonNegativeInt(Object? value) =>
      value is int && value >= 0 ? value : null;

  static double? _normalizedCoordinate(Object? value) {
    final coordinate = switch (value) {
      num number => number.toDouble(),
      _ => double.nan,
    };
    if (!coordinate.isFinite || coordinate < 0 || coordinate > 1) {
      return null;
    }
    return coordinate;
  }

  static final _jpegDataUrlPattern = RegExp(
    r'^data:image/jpeg;base64,[A-Za-z0-9+/]+={0,2}$',
  );
}
