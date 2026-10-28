import 'package:flutter_test/flutter_test.dart';
import 'package:miyin_app/features/chat/chat_search_context.dart';
import 'package:miyin_app/features/chat/deepseek_client.dart';
import 'package:miyin_app/features/chat/phone_llm_client.dart';
import 'package:miyin_app/features/chat/web_search.dart';

void main() {
  List<Map<String, Object?>> sources() => [
    {
      'title': 'Test source',
      'body': 'x' * 650,
      'kind': 'pageExcerpt',
      'publishedAt': '',
    },
  ];
  test('search preparation reports total omissions and keeps final question and material', () {
    final input = <Map<String, String>>[];
    for (var i = 0; i < 3; i++) {
      input.add({'role': 'user', 'content': 'a' * 300});
      input.add({'role': 'assistant', 'content': 'b' * 300});
    }
    input.add({'role': 'user', 'content': '最新的问题'});
    final before = PhoneLlmClient.prepareContext('Qwen3.5-2B', input);
    expect(before.omitted, 0);
    final rows = sources();
    final prepared = ChatSearchContext.preparePhone(
      'Qwen3.5-2B',
      input,
      rows,
      previouslyOmitted: 8,
    );
    expect(prepared.omitted, greaterThan(8));
    expect((prepared.omitted - 8).isEven, isTrue);
    expect(prepared.messages.first['role'], 'user');
    expect(
      prepared.messages.last['content'],
      '最新的问题${WebSearch.material(rows, phone: true)}',
    );
    expect(input.last['content'], '最新的问题');
    expect(input.length, 7);
    expect(
      PhoneLlmClient.prepareContext('Qwen3.5-2B', prepared.messages).omitted,
      0,
    );
    expect(prepared.notice, contains('${prepared.omitted} 条消息'));
  });
  test('short search keeps prior omission count and no extra drops', () {
    final prepared = ChatSearchContext.preparePhone(
      'Qwen3.5-2B',
      [
        {'role': 'user', 'content': 'search this'},
      ],
      sources(),
      previouslyOmitted: 2,
    );
    expect(prepared.omitted, 2);
    expect(prepared.additionalOmitted, 0);
    expect(prepared.messages, hasLength(1));
  });
  test(
    'question plus search exceeding capacity fails without truncating question',
    () {
      final input = [
        {'role': 'user', 'content': 'a' * 2300},
      ];
      expect(PhoneLlmClient.prepareContext('Qwen3.5-2B', input).omitted, 0);
      expect(
        () => ChatSearchContext.preparePhone('Qwen3.5-2B', input, sources()),
        throwsA(
          isA<ChatFailure>().having(
            (e) => e.code,
            'code',
            'local_context_limit',
          ),
        ),
      );
      expect(input.single['content'], 'a' * 2300);
    },
  );
}
