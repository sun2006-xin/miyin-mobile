import 'package:flutter_test/flutter_test.dart';
import 'package:miyin_app/features/chat/web_search.dart';
import 'package:miyin_app/features/chat/ollama_client.dart';
import 'package:miyin_app/features/chat/deepseek_client.dart';

void main() {
  test('search documents above two MiB are rejected before HTML parsing', () {
    expect(
      () => WebSearch.parseResults('x' * (2 * 1024 * 1024 + 1)),
      throwsA(
        isA<ChatFailure>().having(
          (error) => error.code,
          'code',
          'search_limit',
        ),
      ),
    );
  });
  test('ordinary translation and device date do not trigger automatic web restrictions', () {
    for (final query in [
      '你现在作为我的翻译助手，我现在在俄国旅游',
      '我只是让你翻译俄文，我喜欢你',
      '把“今天最新消息”翻译成俄文',
      '今天是几月几号？',
      'What is the date today?',
      '你现在是什么模型？',
    ]) {
      expect(WebSearch.needed('auto', query), false, reason: query);
    }
    expect(WebSearch.needed('auto', '请搜索今天的新闻'), true);
    expect(WebSearch.needed('auto', '今天有什么新闻？'), true);
    expect(WebSearch.needed('auto', '今天上海天气怎么样？'), true);
    expect(WebSearch.needed('always', '请翻译你好'), true);
  });
  test('phone excerpt retains a fact after a long heading and introduction', () {
    final text =
        '${List.filled(180, 'A').join()}\nThe mission has already returned safely.\nOctober 15, 2026';
    final material = WebSearch.material([
      {
        'title': 'Source',
        'body': text,
        'publishedAt': '',
        'kind': 'pageExcerpt',
      },
    ], phone: true);
    expect(material, contains('already returned safely'));
    expect(material, contains('October 15, 2026'));
  });
  test(
    'question removes search instructions; result titles preserve target links',
    () {
      expect(
        WebSearch.queryTerms('Search NASA Artemis II mission. List sources.'),
        'NASA Artemis II mission',
      );
      expect(WebSearch.queryTerms('请帮我搜索嫦娥六号'), '嫦娥六号');
      final rows = WebSearch.parseResults(
        '<div class="vrwrap"><h3 class="vr-title"><a href="/link?url=abc">NASA Artemis II</a></h3><div class="fz-mid">Mission information</div></div>',
      );
      expect(rows.single['url'], 'https://www.sogou.com/link?url=abc');
      expect(rows.single['snippet'], 'Mission information');
    },
  );
  test(
    'search mode requires intent or explicit always; off never searches',
    () {
      expect(WebSearch.needed('auto', '帮我搜索今天新闻'), isTrue);
      expect(WebSearch.needed('auto', '你好'), isFalse);
      expect(WebSearch.needed('off', '今天新闻'), isFalse);
      expect(WebSearch.needed('always', '你好'), isTrue);
    },
  );
  test('feed removes duplicates, unsafe links and HTML from snippets', () {
    final rows = WebSearch.parseFeed('''<rss><channel>
      <item><title>来源</title><link>https://example.com/a</link><description>&lt;b&gt;正文&lt;/b&gt;</description></item>
      <item><title>重复</title><link>https://example.com/a</link></item>
      <item><title>危险</title><link>javascript:alert(1)</link></item>
      </channel></rss>''');
    expect(rows, hasLength(1));
    expect(rows.first['snippet'], '正文');
    expect(rows.first['publishedAt'], '');
    expect(WebSearch.material(rows, phone: true), contains('仅搜索摘要'));
  });
  test(
    'phone source material fits conservative context without cutting query',
    () {
      final rows = List.generate(
        2,
        (i) => {
          'title': '来源标题',
          'publishedAt': '',
          'kind': 'pageExcerpt',
          'body': List.filled(1200, '文').join(),
        },
      );
      final text = '请总结最新消息' + WebSearch.material(rows, phone: true);
      final result = OllamaClient.prepareContext('Qwen3.5-2B', [
        {'role': 'user', 'content': text},
      ], windowTokens: 5120);
      expect(result.messages.single['content'], text);
    },
  );
}
