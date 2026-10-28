import 'package:flutter_test/flutter_test.dart';
import 'package:miyin_app/features/chat/conversation_memory.dart';
import 'package:miyin_app/features/chat/deepseek_client.dart';

List<ChatMessage> history([int count = 24]) => [
  for (var i = 0; i < count; i++) ...[
    {
      'role': 'user',
      'content': i == 0
          ? '用户项目代号：海棠；截止日期11月8日。${'旧信息' * 60}'
          : '问题$i${'占位内容' * 60}',
    },
    {'role': 'assistant', 'content': '建议$i${'旧回答' * 60}'},
  ],
  {'role': 'user', 'content': '项目代号和截止日期是什么？'},
];

Future<MemoryContext> compact(
  List<ChatMessage> rows, {
  MemorySnapshot? cached,
  Future<String> Function(String, List<ChatMessage>)? summarize,
  Future<void> Function(MemorySnapshot)? checkpoint,
  void Function()? ensure,
}) => ConversationMemory.prepare(
  model: 'qwen3.5:4b',
  messages: rows,
  cached: cached,
  summarize: summarize ?? (_, __) async => '用户项目代号海棠，截止日期11月8日。',
  checkpoint: checkpoint ?? (_) async {},
  progress: (_, __) async {},
  ensureActive: ensure ?? () {},
);

void main() {
  test('short conversation uses original text without model summary', () async {
    final rows = [
      {'role': 'user', 'content': '你好'},
    ];
    var calls = 0;
    final result = await compact(
      rows,
      summarize: (_, __) async {
        calls++;
        return '不应调用';
      },
    );
    expect(calls, 0);
    expect(result.messages, rows);
    expect(result.snapshot, isNull);
  });
  test('long conversation includes summary plus recent originals; originals survive', () async {
    final rows = history(),
        original = rows.map((row) => Map<String, String>.from(row)).toList();
    final seen = <ChatMessage>[];
    final result = await compact(
      rows,
      summarize: (_, chunk) async {
        seen.addAll(chunk);
        return '用户项目代号海棠，截止日期11月8日。';
      },
    );
    expect(result.snapshot, isNotNull);
    expect(result.snapshot!.sourceQuotes, contains('截止日期11月8日'));
    expect(result.messages.first['content'], contains('海棠'));
    expect(result.messages.last, rows.last);
    expect(seen.first['content'], contains('11月8日'));
    expect(rows, original);
    expect(result.recentCount, lessThan(rows.length));
  });
  test('matching prefix reuses checkpoint without resummarizing', () async {
    final rows = history();
    final first = await compact(rows);
    var calls = 0;
    final next = await compact(
      rows,
      cached: first.snapshot,
      summarize: (_, __) async {
        calls++;
        return '不应调用';
      },
    );
    expect(calls, 0);
    expect(next.snapshot!.summary, first.snapshot!.summary);
  });
  test('editing older messages invalidates the cached summary', () async {
    final rows = history();
    final first = await compact(rows);
    rows.first['content'] = '已更正：项目改名梧桐，日期12月9日。${'新信息' * 60}';
    String? previous;
    final next = await compact(
      rows,
      cached: first.snapshot,
      summarize: (old, __) async {
        previous ??= old;
        return '用户项目已改为梧桐，日期12月9日。';
      },
    );
    expect(previous, contains('梧桐'));
    expect(previous, isNot(contains('海棠')));
    expect(next.snapshot!.summary, contains('梧桐'));
    expect(next.snapshot!.digest, isNot(first.snapshot!.digest));
  });
  test('stop during summary does not persist a late result', () async {
    var canceled = false, writes = 0;
    await expectLater(
      compact(
        history(),
        ensure: () {
          if (canceled) throw const ChatFailure('canceled', '已停止');
        },
        summarize: (_, __) async {
          canceled = true;
          return '迟到结果';
        },
        checkpoint: (_) async {
          writes++;
        },
      ),
      throwsA(isA<ChatFailure>()),
    );
    expect(writes, 0);
  });
  test(
    'oversized latest message is rejected rather than silently truncated',
    () async {
      await expectLater(
        compact([
          {'role': 'user', 'content': '当前问题' * 10000},
        ]),
        throwsA(isA<ChatFailure>()),
      );
    },
  );
  test('oversized summary is rejected without checkpoint', () async {
    var writes = 0;
    await expectLater(
      compact(
        history(),
        summarize: (_, __) async => '超长' * 1000,
        checkpoint: (_) async {
          writes++;
        },
      ),
      throwsA(isA<ChatFailure>()),
    );
    expect(writes, 0);
  });
}
