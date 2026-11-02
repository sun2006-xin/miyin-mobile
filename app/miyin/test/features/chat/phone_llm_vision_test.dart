import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:miyin_app/features/chat/chat_image.dart';
import 'package:miyin_app/features/chat/chat_prompts.dart';
import 'package:miyin_app/features/chat/deepseek_client.dart';
import 'package:miyin_app/features/chat/phone_llm_client.dart';

class _Redirect extends HttpOverrides {
  _Redirect(this.port);
  final int port;
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      _Loopback(super.createHttpClient(context), port);
}

class _Loopback implements HttpClient {
  _Loopback(this.delegate, this.port);
  final HttpClient delegate;
  final int port;
  @override
  set connectionTimeout(Duration? value) => delegate.connectionTimeout = value;
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) {
    if (url.host != '127.0.0.1' || url.port != 11438) {
      throw StateError('Only authenticated phone loopback is allowed');
    }
    return delegate.openUrl(method, url.replace(port: port));
  }

  @override
  void close({bool force = false}) => delegate.close(force: force);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final image = ChatImage(
    mimeType: 'image/png',
    bytes: base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aWQAAAABJRU5ErkJggg==',
    ),
  );
  final question = <Map<String, String>>[
    {'role': 'user', 'content': 'What shape?'},
  ];
  final calls = <Object?>[];
  final received = <Map<String, dynamic>>[];
  late HttpServer server;
  HttpOverrides? previous;
  var visionReady = true;
  setUp(() async {
    calls.clear();
    received.clear();
    visionReady = true;
    previous = HttpOverrides.current;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      expect(
        request.headers.value(HttpHeaders.authorizationHeader),
        'Bearer fixture-key',
      );
      received.add(
        jsonDecode(await utf8.decoder.bind(request).join())
            as Map<String, dynamic>,
      );
      request.response.headers.contentType = ContentType(
        'text',
        'event-stream',
      );
      request.response.write(
        'data: {"choices":[{"delta":{"content":"fixture"},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n',
      );
      await request.response.close();
    });
    HttpOverrides.global = _Redirect(server.port);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(PhoneLlmClient.channel, (call) async {
          expect(call.method, 'prepare');
          calls.add(call.arguments);
          return {
            'endpoint': 'http://127.0.0.1:11438/v1',
            'key': 'fixture-key',
            'contextTokens': 4096,
            'vision': visionReady,
          };
        });
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(PhoneLlmClient.channel, null);
    HttpOverrides.global = previous;
    await server.close(force: true);
  });
  Matcher failure(String code) =>
      isA<ChatFailure>().having((e) => e.code, 'code', code);
  PhoneLlmClient withImage([int index = 0]) => PhoneLlmClient(
    imageMessages: {
      index: [image],
    },
  );

  test('phone image bindings are defensively snapshotted', () {
    final source = {
      0: [image],
    };
    final client = PhoneLlmClient(imageMessages: source);
    source[0]!.clear();
    expect(client.imageMessages[0], hasLength(1));
    expect(() => client.imageMessages[0]!.clear(), throwsUnsupportedError);
  });
  test('phone reserves native visual token budget without reducing output', () {
    final prepared = PhoneLlmClient.prepareContext(
      'Qwen3.5-2B',
      question,
      imageCount: 2,
    );
    final textCost = prepared.messages.fold<int>(
      utf8.encode(ChatPrompts.identity('Qwen3.5-2B', runtime: '手机本地')).length +
          256,
      (sum, row) => sum + utf8.encode(row['content']!).length + 64,
    );
    expect(PhoneLlmClient.imageTokenReserve, 768);
    expect(
      textCost +
          PhoneLlmClient.outputTokens +
          2 * PhoneLlmClient.imageTokenReserve,
      lessThanOrEqualTo(4096),
    );
    expect(PhoneLlmClient.outputTokens, 1024);
  });
  test(
    'phone sends real original bytes after native vision preparation',
    () async {
      expect(
        await withImage().complete('Qwen3.5-2B', question).join(),
        'fixture',
      );
      expect(calls, [
        {'vision': true},
      ]);
      final parts = received.single['messages'].last['content'] as List;
      expect(parts.first, {'type': 'text', 'text': 'What shape?'});
      expect(parts.last, {
        'type': 'image_url',
        'image_url': {'url': image.dataUrl},
      });
      expect(received.single['max_tokens'], 1024);
    },
  );
  test(
    'native text-only capability is explicit and never sends images',
    () async {
      visionReady = false;
      await expectLater(
        withImage().complete('Qwen3.5-2B', question).join(),
        throwsA(failure('image_unsupported')),
      );
      expect(calls, [
        {'vision': true},
      ]);
      expect(received, isEmpty);
    },
  );
  test('phone trims old text and remaps retained image binding', () async {
    final rows = [
      {'role': 'user', 'content': '中' * 1200},
      {'role': 'assistant', 'content': '文' * 1200},
      ...question,
    ];
    expect(await withImage(2).complete('Qwen3.5-2B', rows).join(), 'fixture');
    final sent = received.single['messages'] as List;
    expect(sent, hasLength(2));
    expect(sent.last['content'].last['image_url']['url'], image.dataUrl);
    expect(rows, hasLength(3));
  });
  test('phone never silently trims a prior image', () async {
    final rows = [
      {'role': 'user', 'content': '中' * 1200},
      {'role': 'assistant', 'content': '文' * 1200},
      ...question,
    ];
    await expectLater(
      withImage().complete('Qwen3.5-2B', rows).join(),
      throwsA(failure('image_context_limit')),
    );
    expect(calls, isEmpty);
    expect(received, isEmpty);
  });
  test(
    'invalid and assistant image bindings fail before model preparation',
    () async {
      for (final index in [-1, 1]) {
        await expectLater(
          withImage(index).complete('Qwen3.5-2B', question).join(),
          throwsA(failure('image_invalid')),
        );
      }
      await expectLater(
        withImage().complete('Qwen3.5-2B', [
          {'role': 'assistant', 'content': 'x'},
          ...question,
        ]).join(),
        throwsA(failure('image_invalid')),
      );
      expect(calls, isEmpty);
      expect(received, isEmpty);
    },
  );
  test('phone allows no more than two images per request', () async {
    final client = PhoneLlmClient(
      imageMessages: {
        0: [image, image, image],
      },
    );
    await expectLater(
      client.complete('Qwen3.5-2B', question).join(),
      throwsA(failure('image_limit')),
    );
    expect(calls, isEmpty);
    expect(received, isEmpty);
  });
  test('cancel while loading native vision ignores late readiness', () async {
    final ready = Completer<Map<String, Object?>>(),
        entered = Completer<void>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(PhoneLlmClient.channel, (call) async {
          expect(call.arguments, {'vision': true});
          entered.complete();
          return ready.future;
        });
    final client = withImage();
    final result = expectLater(
      client.complete('Qwen3.5-2B', question).join(),
      throwsA(failure('canceled')),
    );
    await entered.future;
    client.cancel();
    ready.complete({
      'endpoint': 'http://127.0.0.1:11438/v1',
      'key': 'fixture-key',
      'contextTokens': 4096,
      'vision': true,
    });
    await result;
    expect(received, isEmpty);
  });
  test('text-only phone retains old native and message wire format', () async {
    expect(
      await PhoneLlmClient().complete('Qwen3.5-2B', question).join(),
      'fixture',
    );
    expect(calls, [null]);
    expect(received.single['messages'].last, question.single);
  });
  test('image question overflow fails before preparing runtime', () async {
    await expectLater(
      withImage().complete('Qwen3.5-2B', [
        {'role': 'user', 'content': '中' * 1500},
      ]).join(),
      throwsA(failure('image_context_limit')),
    );
    expect(calls, isEmpty);
    expect(received, isEmpty);
  });
}
