import 'package:flutter_test/flutter_test.dart';
import 'package:miyin_app/features/chat/deepseek_client.dart';
import 'package:miyin_app/features/chat/ollama_client.dart';

void main() {
  test('short complete dialogue is preserved without mutating input', () {
    final input = [
      {'role': 'user', 'content': '你好'},
      {'role': 'assistant', 'content': '你好，有什么可以帮你？'},
      {'role': 'user', 'content': '我上一句说了什么？'},
    ];
    final result = OllamaClient.prepareContext('qwen3.5:4b', input);
    expect(result.messages, input);
    expect(result.omitted, 0);
    expect(identical(result.messages, input), isFalse);
  });
  test('oversized dialogue drops whole older turns, keeping latest user', () {
    final input = <Map<String, String>>[];
    for (var i = 0; i < 40; i++) {
      input.add({'role': 'user', 'content': '旧问题$i${'中' * 200}'});
      input.add({'role': 'assistant', 'content': '旧回答$i${'文' * 200}'});
    }
    input.add({'role': 'user', 'content': '最后的问题'});
    final result = OllamaClient.prepareContext('qwen3.5:4b', input);
    expect(result.omitted, greaterThan(0));
    expect(result.omitted.isEven, isTrue);
    expect(result.messages.first['role'], 'user');
    expect(result.messages.last['content'], '最后的问题');
    expect(input, hasLength(81));
  });
  test('a large current question fails instead of truncating', () {
    expect(
      () => OllamaClient.prepareContext('qwen3.5:4b', [
        {'role': 'user', 'content': '内容' * 5000},
      ]),
      throwsA(
        isA<ChatFailure>().having((e) => e.code, 'code', 'local_context_limit'),
      ),
    );
  });
  test('empty input and orphan assistant tail fail explicitly', () {
    expect(
      () => OllamaClient.prepareContext('qwen3.5:4b', []),
      throwsA(isA<ChatFailure>()),
    );
    expect(
      () => OllamaClient.prepareContext('qwen3.5:4b', [
        {'role': 'assistant', 'content': '没有用户问题'},
      ]),
      throwsA(isA<ChatFailure>()),
    );
  });
}
