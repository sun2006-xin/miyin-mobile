import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:miyin_app/core/storage/translation_history_repository.dart';
import 'package:miyin_app/core/translation/translation_contracts.dart';
import 'package:miyin_app/core/translation/translation_service.dart';
import 'package:miyin_app/features/miyin/attachment_source_picker.dart';
import 'package:miyin_app/features/miyin/translation_attachment_ocr.dart';
import 'package:miyin_app/features/miyin/translation_rpc_router.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tempDirectory;
  late SqliteTranslationHistoryRepository history;
  late _FakeImagePicker imagePicker;
  late _FakeArticlePicker articlePicker;
  late _FakeImageTextRecognizer recognizer;
  late TranslationRpcRouter router;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    tempDirectory = await Directory.systemTemp.createTemp('miyin-attachments-');
    history = await SqliteTranslationHistoryRepository.open(
      path: '${tempDirectory.path}${Platform.pathSeparator}history.db',
      databaseFactory: databaseFactoryFfi,
    );
    imagePicker = _FakeImagePicker();
    articlePicker = _FakeArticlePicker();
    recognizer = _FakeImageTextRecognizer();
    router = TranslationRpcRouter(
      TranslationService(engine: _UnusedTranslationEngine(), history: history),
      translationImageSourcePicker: imagePicker,
      translationArticleSourcePicker: articlePicker,
      translationImageTextRecognizer: recognizer,
    );
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('com.miyin.app/attachment-ocr'),
          null,
        );
    await history.close();
    await tempDirectory.delete(recursive: true);
  });

  test('camera and gallery OCR return preview geometry without leaking local paths', () async {
    imagePicker.nextResult = const PickedTranslationImage(
      path: r'C:\private-cache\picked-image.jpg',
      name: 'station.jpg',
    );
    recognizer.result = const TranslationImageRecognition(
      recognizedText: '地铁站',
      previewDataUrl: 'data:image/jpeg;base64,AA==',
      width: 100,
      height: 80,
      blocks: [
        TranslationImageTextBlock(
          text: '地铁站',
          left: 0.1,
          top: 0.2,
          right: 0.8,
          bottom: 0.5,
        ),
      ],
    );

    final response = await _request(router, 'attachment.recognizeImage', {
      'kind': 'camera',
    });

    expect(response['ok'], isTrue);
    expect(imagePicker.requestedKinds, [AttachmentSourceKind.camera]);
    expect(recognizer.paths, [r'C:\private-cache\picked-image.jpg']);
    expect(imagePicker.disposedPaths, [r'C:\private-cache\picked-image.jpg']);
    final result = response['result'] as Map;
    expect(result['name'], 'station.jpg');
    expect(result['recognizedText'], '地铁站');
    expect(result['previewDataUrl'], 'data:image/jpeg;base64,AA==');
    expect(result['width'], 100);
    expect(result['height'], 80);
    expect(result['blocks'], [
      {'text': '地铁站', 'left': 0.1, 'top': 0.2, 'right': 0.8, 'bottom': 0.5},
    ]);
    expect(result.containsKey('path'), isFalse);
    expect(result.containsKey('uri'), isFalse);
    expect(result.containsKey('bytes'), isFalse);
    expect(jsonEncode(response).length, lessThan(1000));
    expect(jsonEncode(response), isNot(contains(r'C:\private-cache')));
  });

  test('bundled OCR validates and parses normalized image geometry', () async {
    const channel = MethodChannel('com.miyin.app/attachment-ocr');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'recognizeText');
          return {
            'recognizedText': 'Hello\n世界',
            'previewDataUrl': 'data:image/jpeg;base64,AA==',
            'width': 640,
            'height': 480,
            'blocks': [
              {
                'text': 'Hello',
                'left': 0.1,
                'top': 0.2,
                'right': 0.7,
                'bottom': 0.3,
              },
              {
                'text': 'invalid rectangle',
                'left': 0.8,
                'top': 0.1,
                'right': 0.2,
                'bottom': 0.3,
              },
            ],
          };
        });

    final result = await const BundledMlKitImageTextRecognizer().recognize(
      '/private/picker/image.jpg',
    );

    expect(result.recognizedText, 'Hello');
    expect(result.width, 640);
    expect(result.height, 480);
    expect(result.blocks, hasLength(1));
    expect(result.blocks.single.text, 'Hello');
    expect(result.blocks.single.left, 0.1);
    expect(result.blocks.single.bottom, 0.3);
  });

  test(
    'bundled OCR caps renderable blocks and reports the omitted count',
    () async {
      const channel = MethodChannel('com.miyin.app/attachment-ocr');
      final rawBlocks = List.generate(
      1000,
        (index) => _rpcBlock('line $index'),
      )..add(_rpcBlock('overflow line'));
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            return {
              'recognizedText': rawBlocks
                  .map((block) => block['text'])
                  .join('\n'),
              'previewDataUrl': 'data:image/jpeg;base64,AA==',
              'width': 640,
              'height': 480,
              'totalBlockCount': rawBlocks.length,
              'omittedBlockCount': 0,
              'blocks': rawBlocks,
            };
          });

      final result = await const BundledMlKitImageTextRecognizer().recognize(
        '/private/picker/image.jpg',
      );

      expect(result.blocks, hasLength(TranslationImageRecognition.maxBlocks));
      expect(
        result.blocks.last.text,
        'line ${TranslationImageRecognition.maxBlocks - 1}',
      );
      expect(
        result.recognizedText,
        result.blocks.map((block) => block.text).join('\n'),
      );
      expect(result.recognizedText, isNot(contains('overflow line')));
      expect(
        result.recognizedText,
        isNot(contains('line ${TranslationImageRecognition.maxBlocks}\n')),
      );
      expect(result.totalBlockCount, rawBlocks.length);
      expect(
        result.omittedBlockCount,
        rawBlocks.length - TranslationImageRecognition.maxBlocks,
      );
      expect(result.truncated, isTrue);
      expect(result.toRpcMap()['truncated'], isTrue);
    },
  );

  test(
    'attachment RPC caps custom recognizers before returning text and overlays',
    () async {
      imagePicker.nextResult = const PickedTranslationImage(
        path: r'C:\private-cache\many-blocks.jpg',
        name: 'many-blocks.jpg',
      );
      final rawBlocks = List.generate(
        TranslationImageRecognition.maxBlocks + 3,
        (index) => TranslationImageTextBlock(
          text: 'line $index',
          left: 0,
          top: 0,
          right: 1,
          bottom: 1,
        ),
      );
      recognizer.result = TranslationImageRecognition(
        recognizedText: rawBlocks.map((block) => block.text).join('\n'),
        previewDataUrl: 'data:image/jpeg;base64,AA==',
        width: 1,
        height: 1,
        blocks: rawBlocks,
      );

      final response = await _request(router, 'attachment.recognizeImage', {
        'kind': 'image',
      });

      final result = response['result'] as Map;
      final blocks = result['blocks'] as List;
      expect(blocks, hasLength(TranslationImageRecognition.maxBlocks));
      expect(
        result['recognizedText'],
        (blocks.map((block) => block['text'])).join('\n'),
      );
      expect(
        result['recognizedText'],
        isNot(contains('line ${TranslationImageRecognition.maxBlocks}')),
      );
      expect(
        result['totalBlockCount'],
        TranslationImageRecognition.maxBlocks + 3,
      );
      expect(result['omittedBlockCount'], 3);
      expect(result['truncated'], isTrue);
    },
  );

  test(
    'image picker cancellation is successful and does not invoke OCR',
    () async {
      imagePicker.nextResult = null;

      final response = await _request(router, 'attachment.recognizeImage', {
        'kind': 'image',
      });

      expect(response['ok'], isTrue);
      expect((response['result'] as Map)['canceled'], isTrue);
      expect(recognizer.paths, isEmpty);
      expect(imagePicker.disposedPaths, isEmpty);
    },
  );

  test(
    'article import returns UTF-8 text for local translation only',
    () async {
      articlePicker.nextResult = const PickedArticleText(
        name: 'directions.md',
        text: '一直往前走。',
      );

      final response = await _request(router, 'attachment.pickArticle', {});

      expect(response['ok'], isTrue);
      final result = response['result'] as Map;
      expect(result['name'], 'directions.md');
      expect(result['text'], '一直往前走。');
      expect(result.containsKey('path'), isFalse);
      expect(result.containsKey('uri'), isFalse);
    },
  );

  test(
    'article picker cancellation does not return a replacement draft',
    () async {
      articlePicker.nextResult = null;

      final response = await _request(router, 'attachment.pickArticle', {});

      expect(response['ok'], isTrue);
      expect((response['result'] as Map)['canceled'], isTrue);
    },
  );

  test(
    'article decoding accepts UTF-8 TXT and Markdown with an optional BOM',
    () {
      final article = decodeTranslationArticle('note.md', [
        0xef,
        0xbb,
        0xbf,
        ...utf8.encode('Hello\n你好'),
      ]);

      expect(article.name, 'note.md');
      expect(article.text, 'Hello\n你好');
    },
  );

  test('article decoding rejects unsupported formats and malformed UTF-8', () {
    expect(
      () => decodeTranslationArticle('scan.pdf', utf8.encode('text')),
      throwsA(isA<TranslationAttachmentException>()),
    );
    expect(
      () => decodeTranslationArticle('broken.txt', [0xff, 0xfe]),
      throwsA(isA<TranslationAttachmentException>()),
    );
  });

  test('image OCR text is capped at the translation limit and still cleans its temp file', () async {
    imagePicker.nextResult = const PickedTranslationImage(
      path: r'C:\private-cache\large.jpg',
      name: 'large.jpg',
    );
    recognizer.result = TranslationImageRecognition(
      recognizedText: 'x' * (TranslationRpcRouter.maxTextLength + 1),
      previewDataUrl: 'data:image/jpeg;base64,AA==',
      width: 1,
      height: 1,
      blocks: [
        TranslationImageTextBlock(
          text: 'x' * (TranslationRpcRouter.maxTextLength + 1),
          left: 0,
          top: 0,
          right: 1,
          bottom: 1,
        ),
      ],
    );

    final response = await _request(router, 'attachment.recognizeImage', {
      'kind': 'image',
    });

    expect(response['ok'], isFalse);
    expect((response['error'] as Map)['code'], 'text_too_long');
    expect(imagePicker.disposedPaths, [r'C:\private-cache\large.jpg']);
  });
}

Map<String, Object?> _rpcBlock(String text) => {
  'text': text,
  'left': 0.1,
  'top': 0.2,
  'right': 0.7,
  'bottom': 0.3,
};

Future<Map<String, Object?>> _request(
  TranslationRpcRouter router,
  String method,
  Map<String, Object?> params,
) => router.handle(
  jsonEncode({'version': 1, 'id': method, 'method': method, 'params': params}),
);

final class _FakeImagePicker implements TranslationImageSourcePicker {
  final requestedKinds = <AttachmentSourceKind>[];
  final disposedPaths = <String>[];
  PickedTranslationImage? nextResult;

  @override
  Future<PickedTranslationImage?> pickTranslationImage(
    AttachmentSourceKind kind,
  ) async {
    requestedKinds.add(kind);
    return nextResult;
  }

  @override
  Future<void> disposeTranslationImage(PickedTranslationImage image) async {
    disposedPaths.add(image.path);
  }
}

final class _FakeArticlePicker implements TranslationArticleSourcePicker {
  PickedArticleText? nextResult;

  @override
  Future<PickedArticleText?> pickArticleText() async => nextResult;
}

final class _FakeImageTextRecognizer implements TranslationImageTextRecognizer {
  final paths = <String>[];
  TranslationImageRecognition result = const TranslationImageRecognition(
    recognizedText: 'recognized',
    previewDataUrl: 'data:image/jpeg;base64,AA==',
    width: 1,
    height: 1,
    blocks: [],
  );

  @override
  Future<TranslationImageRecognition> recognize(String localPath) async {
    paths.add(localPath);
    return result;
  }
}

final class _UnusedTranslationEngine implements TranslationEngine {
  @override
  String get engineId => 'unused';

  @override
  Future<void> deleteModel(TranslationLanguagePair pair) async {}

  @override
  Future<void> downloadModel(
    TranslationLanguagePair pair, {
    required bool wifiOnly,
  }) async {}

  @override
  Future<TranslationModelInfo> getModelInfo(
    TranslationLanguagePair pair,
  ) async =>
      const TranslationModelInfo(status: TranslationModelStatus.downloaded);

  @override
  Future<Set<TranslationLanguagePair>> getSupportedLanguagePairs() async => {};

  @override
  Future<TranslationResult> translate(TranslationRequest request) async =>
      TranslationResult(
        request: request,
        translatedText: request.text,
        engineId: engineId,
      );
}
