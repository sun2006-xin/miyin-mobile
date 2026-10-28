import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:miyin_app/features/chat/deepseek_client.dart';
import 'package:miyin_app/features/chat/phone_llm_client.dart';
import 'package:miyin_app/features/chat/chat_prompts.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('cancel request does not unload shared warmed model', () async {
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(PhoneLlmClient.channel, (call) async {
          calls.add(call.method);
          return null;
        });
    PhoneLlmClient().cancel();
    await Future<void>.delayed(Duration.zero);
    expect(calls, isEmpty);
  });
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(PhoneLlmClient.channel, null),
  );
  test(
    'phone retains complete turns within actual runtime and output budget',
    () {
      final input = <Map<String, String>>[];
      for (var i = 0; i < 15; i++) {
        input.add({'role': 'user', 'content': '旧问题$i${'中' * 90}'});
        input.add({'role': 'assistant', 'content': '旧回答$i${'文' * 90}'});
      }
      input.add({'role': 'user', 'content': '请继续上次的讨论'});
      final prepared = PhoneLlmClient.prepareContext('Qwen3.5-2B', input);
      final cost = prepared.messages.fold<int>(
        utf8
                .encode(ChatPrompts.identity('Qwen3.5-2B', runtime: '手机本地'))
                .length +
            256,
        (sum, row) => sum + utf8.encode(row['content']!).length + 64,
      );
      expect(
        cost + PhoneLlmClient.outputTokens,
        lessThanOrEqualTo(PhoneLlmClient.contextTokens),
      );
      expect(PhoneLlmClient.contextTokens, 4096);
      expect(PhoneLlmClient.outputTokens, 1024);
      expect(prepared.omitted, greaterThan(0));
      expect(prepared.omitted.isEven, isTrue);
      expect(prepared.messages.first['role'], 'user');
      expect(prepared.messages.last, input.last);
      expect(input.length, 31);
    },
  );
  test(
    'oversized latest phone question is rejected without loading model',
    () async {
      final calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(PhoneLlmClient.channel, (call) async {
            calls.add(call.method);
            return null;
          });
      await expectLater(
        PhoneLlmClient().complete('Qwen3.5-2B', [
          {'role': 'user', 'content': '内容' * 1000},
        ]).toList(),
        throwsA(
          isA<ChatFailure>().having(
            (e) => e.code,
            'code',
            'local_context_limit',
          ),
        ),
      );
      expect(calls, isEmpty);
    },
  );
  test('cancel while preparing ignores late ready result', () async {
    final ready = Completer<Map<String, Object?>>();
    final entered = Completer<void>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(PhoneLlmClient.channel, (call) async {
          if (call.method == 'prepare') {
            entered.complete();
            return ready.future;
          }
          return null;
        });
    final client = PhoneLlmClient();
    final response = client.complete('Qwen3.5-2B', [
      {'role': 'user', 'content': 'hello'},
    ]).toList();
    final assertion = expectLater(
      response,
      throwsA(isA<ChatFailure>().having((e) => e.code, 'code', 'canceled')),
    );
    await entered.future;
    client.cancel();
    ready.complete({
      'endpoint': 'http://127.0.0.1:11438/v1',
      'key': 'test-only',
      'contextTokens': 4096,
    });
    await assertion;
  });
  test(
    'mismatched native context is rejected before sending messages',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            PhoneLlmClient.channel,
            (call) async => {
              'endpoint': 'http://127.0.0.1:11438/v1',
              'key': 'test-only',
              'contextTokens': 2048,
            },
          );
      await expectLater(
        PhoneLlmClient().complete('Qwen3.5-2B', [
          {'role': 'user', 'content': 'hello'},
        ]).toList(),
        throwsA(
          isA<ChatFailure>().having((e) => e.code, 'code', 'local_model'),
        ),
      );
    },
  );
  test('cancel before listening never prepares or loads phone model', () async {
    final methods = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(PhoneLlmClient.channel, (call) async {
          methods.add(call.method);
          return {'endpoint': 'http://127.0.0.1:11438/v1', 'key': 'test-only'};
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(PhoneLlmClient.channel, null),
    );
    final client = PhoneLlmClient();
    client.cancel();
    await expectLater(
      client.complete('Qwen3.5-2B', [
        {'role': 'user', 'content': 'hello'},
      ]).toList(),
      throwsA(isA<ChatFailure>().having((e) => e.code, 'code', 'canceled')),
    );
    expect(methods, isNot(contains('prepare')));
  });
}
