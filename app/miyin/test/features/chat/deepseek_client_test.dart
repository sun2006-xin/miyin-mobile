import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:miyin_app/features/chat/deepseek_client.dart';

class _Headers implements HttpHeaders {
  @override
  ContentType? contentType = ContentType('text', 'event-stream');
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Response extends Stream<List<int>> implements HttpClientResponse {
  _Response(this.frames, {this.statusCode = 200});
  final List<List<int>> frames;
  @override
  final int statusCode;
  @override
  final HttpHeaders headers = _Headers();
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream<List<int>>.fromIterable(frames).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Request implements HttpClientRequest {
  _Request(this.response);
  final HttpClientResponse response;
  String body = '';
  @override
  bool followRedirects = false;
  @override
  final HttpHeaders headers = _Headers();
  @override
  void write(Object? value) {
    body += value.toString();
  }

  @override
  Future<HttpClientResponse> close() async => response;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Client implements HttpClient {
  _Client(_Response response) : request = _Request(response);
  final _Request request;
  bool closed = false;
  Uri? opened;
  @override
  Duration? connectionTimeout;
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    opened = url;
    return request;
  }

  @override
  void close({bool force = false}) {
    closed = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  // Every transport is an in-memory fake. These tests cannot open a socket.
  const messages = [
    {'role': 'user', 'content': '你好'},
  ];
  String frame(String text, {String? reason}) =>
      'data: ${jsonEncode({
        'choices': [
          {
            'delta': {'content': text},
            'finish_reason': reason,
          },
        ],
      })}\r\n\r\n';
  DeepSeekClient service(_Client client) =>
      DeepSeekClient(apiKey: 'unit-test-only', client: client);
  test(
    'reasoning reports activity without becoming answer or spoken text',
    () async {
      var reasoningEvents = 0;
      final reasoning =
          'data: ${jsonEncode({
            'choices': [
              {
                'delta': {'reasoning_content': 'internal reasoning'},
              },
            ],
          })}\n\n';
      final client = _Client(
        _Response([utf8.encode('$reasoning${frame('回答')}data: [DONE]\n')]),
      );
      final adapter = DeepSeekClient(
        apiKey: 'test-only',
        client: client,
        onReasoning: () {
          reasoningEvents++;
        },
      );
      expect(await adapter.complete('local', messages).join(), '回答');
      expect(reasoningEvents, 1);
    },
  );
  test('Claude Messages stream and system field use native protocol', () async {
    final client = _Client(
      _Response([
        utf8.encode(
          'event: content_block_delta\ndata: {"type":"content_block_delta","delta":{"type":"text_delta","text":"你好"}}\n\n'
          'event: message_stop\ndata: {"type":"message_stop"}\n\n',
        ),
      ]),
    );
    final result = await DeepSeekClient(
      apiKey: 'test-only',
      client: client,
      anthropic: true,
      deepSeekOptions: false,
      baseUrl: 'https://api.anthropic.com/v1',
    ).complete('account-claude', messages).join();
    expect(result, '你好');
    expect(client.opened?.path, '/v1/messages');
    final body = jsonDecode(client.request.body) as Map;
    expect(body['messages'], messages);
    expect(body['system'], contains('account-claude'));
    expect(body.containsKey('thinking'), false);
  });
  test('default chat preserves translation questions, history and sampling defaults', () async {
    final turns = [
      {'role': 'user', 'content': '俄语我喜欢你怎么说？'},
      {'role': 'assistant', 'content': '我无法提供涉及敏感话题的翻译。'},
      {'role': 'user', 'content': '我只是让你翻译俄文，我喜欢你。请解释语气区别。'},
    ];
    final client = _Client(
      _Response([utf8.encode('${frame('ok')}data: [DONE]\n')]),
    );
    await service(client).complete('actual-model-v3', turns).join();
    final body = jsonDecode(client.request.body) as Map;
    final sent = body['messages'] as List;
    expect(sent.skip(1).toList(), turns);
    expect(sent.first['content'], contains('actual-model-v3'));
    expect(sent.first['content'], isNot(contains('只给译文')));
    expect(body.containsKey('temperature'), false);
  });
  test(
    'phone task instructions and sampling reach the inference request',
    () async {
      final client = _Client(
        _Response([utf8.encode('${frame('ok')}data: [DONE]\n')]),
      );
      await DeepSeekClient(
        apiKey: 'test-only',
        client: client,
        deepSeekOptions: false,
        systemPrompt: 'local task instructions',
        temperature: 0.2,
        templateThinking: false,
        maxOutputTokens: 512,
      ).complete('phone', messages).join();
      final body = jsonDecode(client.request.body) as Map;
      expect(body['temperature'], 0.2);
      expect(body['chat_template_kwargs'], {'enable_thinking': false});
      expect(
        (body['messages'] as List).first['content'],
        'local task instructions',
      );
      expect(body['max_tokens'], 512);
    },
  );
  test(
    'fragmented UTF-8 and heartbeats are reconstructed, then DONE closes',
    () async {
      final bytes = utf8.encode(
        ': heartbeat\n\n${frame('你好世界')}data: [DONE]\n\n',
      );
      final client = _Client(_Response(bytes.map((byte) => [byte]).toList()));
      expect(
        await service(client).complete('test-model', messages).join(),
        '你好世界',
      );
      expect(client.closed, true);
      final body = jsonDecode(client.request.body) as Map;
      expect(body['stream'], true);
      expect(body['thinking'], {'type': 'disabled'});
      expect(client.request.followRedirects, false);
    },
  );
  test('premature EOF is a failure and preserves earlier deltas', () async {
    final client = _Client(_Response([utf8.encode(frame('partial'))]));
    final seen = <String>[];
    await expectLater(
      service(client).complete('test', messages).map((text) {
        seen.add(text);
        return text;
      }).drain<void>(),
      throwsA(isA<ChatFailure>().having((e) => e.code, 'code', 'interrupted')),
    );
    expect(seen, ['partial']);
  });
  test('empty completion is not reported as a successful answer', () async {
    final client = _Client(_Response([utf8.encode('data: [DONE]\n')]));
    await expectLater(
      service(client).complete('test', messages).drain<void>(),
      throwsA(
        isA<ChatFailure>().having((e) => e.code, 'code', 'empty_response'),
      ),
    );
  });
  test('HTTP authentication errors have safe user-facing messages', () async {
    final client = _Client(_Response([], statusCode: 401));
    await expectLater(
      service(client).complete('test', messages).drain<void>(),
      throwsA(isA<ChatFailure>().having((e) => e.code, 'code', 'http_401')),
    );
    expect(client.closed, true);
  });
  test(
    'output length stop is explicit instead of silently claiming completion',
    () async {
      final client = _Client(
        _Response([utf8.encode(frame('partial', reason: 'length'))]),
      );
      await expectLater(
        service(client).complete('test', messages).drain<void>(),
        throwsA(
          isA<ChatFailure>().having((e) => e.code, 'code', 'output_limit'),
        ),
      );
    },
  );
  test('cancel closes the dedicated HTTP client', () {
    final client = _Client(_Response([]));
    service(client).cancel();
    expect(client.closed, true);
  });
  test(
    'compatible services use their own base path without DeepSeek parameters',
    () async {
      final client = _Client(
        _Response([utf8.encode('${frame('ok')}data: [DONE]\n')]),
      );
      final adapter = DeepSeekClient(
        apiKey: 'test-other-key',
        client: client,
        baseUrl: 'https://one.example/compatible-mode/v1',
        serviceName: '测试服务',
        deepSeekOptions: false,
      );
      expect(await adapter.complete('vendor/model', messages).join(), 'ok');
      expect(
        client.opened.toString(),
        'https://one.example/compatible-mode/v1/chat/completions',
      );
      expect(
        (jsonDecode(client.request.body) as Map).containsKey('thinking'),
        false,
      );
      expect(client.request.followRedirects, false);
    },
  );
}
