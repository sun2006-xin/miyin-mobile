import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:miyin_app/features/chat/chat_image.dart';
import 'package:miyin_app/features/chat/deepseek_client.dart';
import 'package:miyin_app/features/chat/ollama_client.dart';

Uint8List png() => base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aWQAAAABJRU5ErkJggg==',
);

Future<void> answer(HttpRequest request, {bool anthropic = false}) async {
  request.response.headers.contentType = ContentType('text', 'event-stream');
  request.response.write(
    anthropic
        ? 'data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"ok"}}\n\ndata: {"type":"message_stop"}\n\n'
        : 'data: {"choices":[{"delta":{"content":"ok"},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n',
  );
  await request.response.close();
}

void main() {
  test('image data owns bytes and rejects invalid or unsupported payloads', () {
    final input = png();
    final image = ChatImage(mimeType: 'image/png', bytes: input);
    input[0] = 0;
    expect(image.bytes[0], 137);
    expect(() => image.bytes[0] = 0, throwsUnsupportedError);
    expect(
      () => ChatImage(mimeType: 'image/jpeg', bytes: png()),
      throwsArgumentError,
    );
    expect(
      () => ChatImage(mimeType: 'text/plain', bytes: png()),
      throwsArgumentError,
    );
    expect(
      () => ChatImage(mimeType: 'image/png', bytes: Uint8List(0)),
      throwsArgumentError,
    );
    expect(
      () => ChatImage(
        mimeType: 'image/png',
        bytes: Uint8List(8 * 1024 * 1024 + 1),
      ),
      throwsArgumentError,
    );
  });

  test('image bindings only target user messages and have a bounded count', () {
    final image = ChatImage(mimeType: 'image/png', bytes: png());
    for (final role in ['assistant', 'system']) {
      expect(
        () => validateChatImages(
          {
            0: [image],
          },
          [
            {'role': role, 'content': 'x'},
          ],
        ),
        throwsArgumentError,
      );
    }
    expect(
      () => validateChatImages(
        {0: List.filled(5, image)},
        [
          {'role': 'user', 'content': 'x'},
        ],
      ),
      throwsArgumentError,
    );
    final source = {
      0: [image],
    };
    final adapter = DeepSeekClient(apiKey: 'test', imageMessages: source);
    source[0]!.clear();
    expect(adapter.imageMessages[0], hasLength(1));
    expect(() => adapter.imageMessages[0]!.clear(), throwsUnsupportedError);
    adapter.cancel();
  });

  for (final anthropic in [false, true]) {
    test(
      'real loopback sends original image in ${anthropic ? 'Anthropic' : 'OpenAI-compatible'} format',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        final captured = Completer<Map>();
        server.listen((request) async {
          captured.complete(
            jsonDecode(await utf8.decoder.bind(request).join()) as Map,
          );
          await answer(request, anthropic: anthropic);
        });
        final adapter = DeepSeekClient(
          apiKey: 'loopback-test-only',
          baseUrl: 'http://127.0.0.1:${server.port}',
          anthropic: anthropic,
          imageMessages: {
            0: [ChatImage(mimeType: 'image/png', bytes: png())],
          },
        );
        expect(
          await adapter.complete('fixture', [
            {'role': 'user', 'content': '看图'},
          ]).join(),
          'ok',
        );
        final body = await captured.future;
        final parts = (body['messages'] as List).last['content'] as List;
        expect(parts.first, {'type': 'text', 'text': '看图'});
        if (anthropic) {
          expect(parts.last, {
            'type': 'image',
            'source': {
              'type': 'base64',
              'media_type': 'image/png',
              'data': base64Encode(png()),
            },
          });
        } else {
          expect(parts.last, {
            'type': 'image_url',
            'image_url': {
              'url': 'data:image/png;base64,${base64Encode(png())}',
            },
          });
        }
      },
    );
  }

  test('invalid image binding never sends a network request', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var requests = 0;
    server.listen((request) {
      requests++;
      request.response.close();
    });
    for (final index in [-1, 1]) {
      final adapter = DeepSeekClient(
        apiKey: 'test',
        baseUrl: 'http://127.0.0.1:${server.port}',
        imageMessages: {
          index: [ChatImage(mimeType: 'image/png', bytes: png())],
        },
      );
      await expectLater(
        adapter.complete('fixture', [
          {'role': 'user', 'content': 'text'},
        ]).join(),
        throwsA(
          isA<ChatFailure>().having((e) => e.code, 'code', 'image_invalid'),
        ),
      );
    }
    expect(requests, 0);
  });

  Future<void> ollamaCase({
    bool vision = true,
    bool images = true,
    List<Map<String, String>>? messages,
    int imageIndex = 0,
    int windowTokens = 8192,
    String? failure,
    bool expectImageAtLast = false,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final paths = <String>[];
    Map? sent;
    server.listen((request) async {
      paths.add(request.uri.path);
      final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
      request.response.headers.contentType = ContentType.json;
      if (request.uri.path == '/api/show') {
        expect(body['model'], 'fixture');
        request.response.write(
          jsonEncode({
            'capabilities': vision ? ['completion', 'vision'] : ['completion'],
          }),
        );
      } else {
        sent = body;
        request.response.write('{"message":{"content":"ok"},"done":true}\n');
      }
      await request.response.close();
    });
    final adapter = OllamaClient(
      baseUrl: Uri.parse('http://127.0.0.1:${server.port}'),
      windowTokens: windowTokens,
      imageMessages: images
          ? {
              imageIndex: [ChatImage(mimeType: 'image/png', bytes: png())],
            }
          : {},
    );
    final input =
        messages ??
        [
          {'role': 'user', 'content': '看图'},
        ];
    if (failure != null) {
      await expectLater(
        adapter.complete('fixture', input).join(),
        throwsA(isA<ChatFailure>().having((e) => e.code, 'code', failure)),
      );
      expect(paths, failure == 'image_unsupported' ? ['/api/show'] : isEmpty);
      return;
    }
    expect(await adapter.complete('fixture', input).join(), 'ok');
    expect(paths, images ? ['/api/show', '/api/chat'] : ['/api/chat']);
    final rows = sent!['messages'] as List;
    expect(sent!['think'], isFalse);
    expect((sent!['options'] as Map)['num_predict'], 2048);
    if (images) {
      expect(rows.last['images'], [base64Encode(png())]);
      if (expectImageAtLast) expect(rows, hasLength(2));
    } else {
      expect(rows.last, {'role': 'user', 'content': '看图'});
    }
    expect(input.last.containsKey('images'), isFalse);
  }

  test(
    'Ollama discovers vision and sends original base64 images',
    () => ollamaCase(),
  );
  test(
    'Ollama text-only request preserves wire format without a capability request',
    () => ollamaCase(images: false),
  );
  test(
    'non-vision model rejects images without OCR or chat request',
    () => ollamaCase(vision: false, failure: 'image_unsupported'),
  );
  test(
    'text trimming remaps image indices without mutating input',
    () => ollamaCase(
      messages: [
        {'role': 'user', 'content': '中' * 1200},
        {'role': 'assistant', 'content': '文' * 1200},
        {'role': 'user', 'content': '看图'},
      ],
      imageIndex: 2,
      expectImageAtLast: true,
    ),
  );
  test(
    'trimming never silently discards an older image',
    () => ollamaCase(
      messages: [
        {'role': 'user', 'content': '中' * 1200},
        {'role': 'assistant', 'content': '文' * 1200},
        {'role': 'user', 'content': '看图'},
      ],
      imageIndex: 0,
      failure: 'image_context_limit',
    ),
  );
  test(
    'image token reserve overflow fails before network',
    () => ollamaCase(windowTokens: 4096, failure: 'image_context_limit'),
  );

  test('cancel during Ollama capability query never starts chat', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final requested = Completer<void>(), release = Completer<void>();
    final paths = <String>[];
    server.listen((request) async {
      paths.add(request.uri.path);
      await request.drain<void>();
      requested.complete();
      await release.future;
      try {
        request.response.write('{"capabilities":["vision"]}');
        await request.response.close();
      } catch (_) {}
    });
    final adapter = OllamaClient(
      baseUrl: Uri.parse('http://127.0.0.1:${server.port}'),
      imageMessages: {
        0: [ChatImage(mimeType: 'image/png', bytes: png())],
      },
    );
    final done = expectLater(
      adapter.complete('fixture', [
        {'role': 'user', 'content': '看图'},
      ]).join(),
      throwsA(isA<ChatFailure>().having((e) => e.code, 'code', 'canceled')),
    );
    await requested.future;
    adapter.cancel();
    release.complete();
    await done;
    expect(paths, ['/api/show']);
  });
}
