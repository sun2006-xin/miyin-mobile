import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:miyin_app/features/chat/public_page_reader.dart';
import 'package:miyin_app/features/chat/deepseek_client.dart';

void main() {
  test('same-site HTTP redirect is upgraded while external downgrade stays blocked', () {
    expect(
      PublicPageReader.redirectTarget(
        Uri.parse('https://example.com/a'),
        'http://example.com/b',
      ).toString(),
      'https://example.com/b',
    );
    expect(
      () => PublicPageReader.redirectTarget(
        Uri.parse('https://example.com'),
        'http://other.example/b',
      ),
      throwsA(isA<ChatFailure>()),
    );
  });
  test('immediate HTML refresh resolves without running scripts; private target still validated on connect', () {
    final doc = html.parse(
      '<meta content="always" name="referrer"><script>window.location.replace("https://wrong.example/")</script><noscript><META http-equiv="refresh" content="0;URL=\'https://www.nasa.gov/artemis/\'"></noscript>',
    );
    expect(
      PublicPageReader.refreshTarget(
        doc,
        Uri.parse('https://www.sogou.com/link'),
      )?.toString(),
      'https://www.nasa.gov/artemis/',
    );
    expect(
      () => PublicPageReader.refreshTarget(
        html.parse(
          '<meta http-equiv="refresh" content="0;url=http://127.0.0.1">',
        ),
        Uri.parse('https://www.sogou.com/link'),
      ),
      throwsA(isA<ChatFailure>()),
    );
  });
  test('HTTP byte input is decoded and parsed with UTF-8 charset', () {
    final doc = html.parse(
      utf8.encode(
        '<meta charset="utf-8"><title>中文网页</title><article>${'这是测试正文。' * 20}</article>',
      ),
      encoding: 'utf-8',
    );
    final result = PublicPageReader.extract(
      doc,
      Uri.parse('https://example.com'),
      DateTime.utc(2026),
    );
    expect(result['title'], '中文网页');
    expect(result['text'], contains('这是测试正文'));
  });
  test('only ordinary HTTPS urls are accepted', () {
    for (final value in [
      'http://example.com',
      'file:///etc/passwd',
      'https://user:secret@example.com',
      'https://example.com:8443/a',
      'https://example.com/\nheader',
      'https://example.com\\evil',
    ]) {
      expect(
        () => PublicPageReader.validateUrl(value),
        throwsA(isA<ChatFailure>()),
      );
    }
    expect(
      PublicPageReader.validateUrl('https://example.com/a?q=1#part').toString(),
      'https://example.com/a?q=1',
    );
  });
  test(
    'private, mapped, transition and documentation addresses are blocked',
    () {
      for (final value in [
        '0.0.0.0',
        '10.1.2.3',
        '127.0.0.1',
        '100.64.0.1',
        '169.254.169.254',
        '172.16.1.2',
        '192.168.1.1',
        '192.0.2.1',
        '198.18.0.1',
        '198.51.100.1',
        '203.0.113.2',
        '224.0.0.1',
        '::1',
        'fc00::1',
        'fe80::1',
        '::ffff:127.0.0.1',
        '2001:db8::1',
        '2002:7f00:1::1',
      ]) {
        expect(
          PublicPageReader.isPublicAddress(InternetAddress(value)),
          false,
          reason: value,
        );
      }
      for (final value in ['8.8.8.8', '1.1.1.1', '2001:4860:4860::8888']) {
        expect(
          PublicPageReader.isPublicAddress(InternetAddress(value)),
          true,
          reason: value,
        );
      }
    },
  );
  test('static text preserves provenance and removes executable and navigation content', () {
    final result = PublicPageReader.extract(
      html.parse('''
      <title>Example &amp; Report</title><meta property="article:published_time" content="2026-10-26">
      <nav>Menu never included</nav><script>steal()</script><style>.bad{}</style>
      <main><h1>Public report</h1><p>This public article contains enough useful original text to be read as a source.</p>
      <p>Second paragraph with an <a href="https://example.org">ordinary link</a>.</p>
      <p hidden>Hidden secret</p></main><footer>Footer omitted</footer>'''),
      Uri.parse('https://example.com/report'),
      DateTime.utc(2026, 10, 26),
    );
    expect(result['title'], 'Example & Report');
    expect(result['url'], 'https://example.com/report');
    expect(result['publishedAt'], '2026-10-26');
    expect(result['text'], contains('Second paragraph'));
    expect(result['text'], isNot(contains('steal')));
    expect(result['text'], isNot(contains('Menu')));
    expect(result['text'], isNot(contains('Hidden')));
    expect(result['truncated'], false);
  });
  test(
    'long pages are explicitly partial and missing dates remain unknown',
    () {
      final result = PublicPageReader.extract(
        html.parse('<article>${'正文内容' * 3000}</article>'),
        Uri.parse('https://example.com'),
        DateTime.utc(2026),
      );
      expect((result['text'] as String).runes.length, PublicPageReader.maxText);
      expect(result['truncated'], true);
      expect(result['publishedAt'], '');
    },
  );
  test(
    'empty or login/script shells fail instead of claiming complete reading',
    () {
      expect(
        () => PublicPageReader.extract(
          html.parse('<script>dynamic()</script><p>Login</p>'),
          Uri.parse('https://example.com'),
          DateTime.utc(2026),
        ),
        throwsA(isA<ChatFailure>()),
      );
    },
  );
  test('cancel before reading prevents any connection', () async {
    final reader = PublicPageReader()..cancel();
    await expectLater(
      reader.read('https://example.com'),
      throwsA(isA<ChatFailure>().having((e) => e.code, 'code', 'canceled')),
    );
  });
}
