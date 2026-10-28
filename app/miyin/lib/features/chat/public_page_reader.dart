import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;

import 'deepseek_client.dart';

/// Explicit public-page import; never runs scripts, sends credentials or loads
/// subresources. DNS is checked once and the connection is pinned to that IP.
final class PublicPageReader {
  final HttpClient _client = HttpClient();
  bool _canceled = false;
  static const maxBytes = 512 * 1024;
  static const maxText = 7000;

  static Uri validateUrl(String raw) {
    final uri = raw.length <= 2048 ? Uri.tryParse(raw) : null;
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.port != 443 ||
        uri.userInfo.isNotEmpty ||
        RegExp(r'[\x00-\x20\\]').hasMatch(raw)) {
      throw const ChatFailure('web_url', '请填写公开网页的完整 HTTPS 链接。');
    }
    return uri.removeFragment();
  }

  static bool isPublicAddress(InternetAddress address) {
    final b = address.rawAddress;
    if (address.type == InternetAddressType.IPv6) {
      // Only native global unicast; reject mapped, transition and reserved IPs.
      if ((b[0] & 0xe0) != 0x20) return false;
      if (b[0] == 0x20 &&
          b[1] == 0x01 &&
          ((b[2] < 2) || (b[2] == 0x0d && b[3] == 0xb8)))
        return false;
      if (b[0] == 0x20 && b[1] == 0x02) return false;
      if (b[0] == 0x3f && b[1] == 0xff && (b[2] & 0xf0) == 0) return false;
      return true;
    }
    if (b[0] == 0 || b[0] == 10 || b[0] == 127 || b[0] >= 224) return false;
    if (b[0] == 100 && b[1] >= 64 && b[1] <= 127) return false;
    if (b[0] == 169 && b[1] == 254) return false;
    if (b[0] == 172 && b[1] >= 16 && b[1] <= 31) return false;
    if (b[0] == 192 &&
        (b[1] == 168 ||
            (b[1] == 0 && (b[2] == 0 || b[2] == 2)) ||
            (b[1] == 88 && b[2] == 99)))
      return false;
    if (b[0] == 198 &&
        (b[1] == 18 || b[1] == 19 || (b[1] == 51 && b[2] == 100)))
      return false;
    if (b[0] == 203 && b[1] == 0 && b[2] == 113) return false;
    return true;
  }

  void cancel() {
    _canceled = true;
    _client.close(force: true);
  }

  void _ensureActive() {
    if (_canceled) throw const ChatFailure('canceled', '已停止读取网页。');
  }

  Future<Map<String, Object?>> read(String raw, {bool feed = false}) async {
    try {
      return await _read(
        validateUrl(raw),
        feed: feed,
      ).timeout(const Duration(seconds: 20));
    } on ChatFailure {
      rethrow;
    } on TimeoutException {
      throw const ChatFailure('web_timeout', '网页读取超时，可以重试或直接打开原网页。');
    } on HandshakeException {
      throw const ChatFailure('web_tls', '网站的安全连接未能建立，请更换网络或打开原网页。');
    } on SocketException {
      _ensureActive();
      throw const ChatFailure('web_network', '网络未能连接到网站，请更换网络或打开原网页。');
    } on FormatException {
      throw const ChatFailure('web_decode', '网页文字未能正确解析，请打开原网页后复制正文。');
    } catch (_) {
      _ensureActive();
      throw const ChatFailure('web_failed', '无法读取这个网页，可以打开原网页，或复制正文后发送。');
    } finally {
      _client.close(force: true);
    }
  }

  Future<Map<String, Object?>> _read(Uri uri, {bool feed = false}) async {
    _client
      ..findProxy = ((_) => 'DIRECT')
      ..connectionTimeout = const Duration(seconds: 8)
      ..userAgent = 'Miyin/1.6 PublicPageReader'
      ..connectionFactory = (target, proxyHost, proxyPort) async {
        _ensureActive();
        final literal = InternetAddress.tryParse(target.host);
        final addresses = literal == null
            ? await InternetAddress.lookup(target.host)
            : [literal];
        _ensureActive();
        if (addresses.isEmpty || addresses.any((a) => !isPublicAddress(a))) {
          throw const ChatFailure('web_private', '只能读取公开网页，不能访问本机或局域网地址。');
        }
        // Keep DNS pinned, but do not lose address fallback on IPv6-only or
        // partially reachable mobile networks when replacing HttpClient DNS.
        addresses.sort(
          (a, b) => a.type == b.type
              ? 0
              : a.type == InternetAddressType.IPv4
              ? -1
              : 1,
        );
        ConnectionTask<Socket>? attempt;
        Socket? connected;
        var stopped = false;
        final socket = () async {
          for (final address in addresses.take(6)) {
            _ensureActive();
            if (stopped) throw const ChatFailure('canceled', '已停止读取网页。');
            try {
              attempt = await Socket.startConnect(address, target.port);
              connected = await attempt!.socket.timeout(
                const Duration(seconds: 5),
                onTimeout: () {
                  attempt?.cancel();
                  throw const SocketException('Connection timeout');
                },
              );
              // A custom connectionFactory must supply TLS itself. Keep the
              // validated IP pinned, but authenticate/SNI against the URL host.
              return await SecureSocket.secure(
                connected!,
                host: target.host,
              ).timeout(
                const Duration(seconds: 5),
                onTimeout: () {
                  connected?.destroy();
                  throw const SocketException('TLS connection timeout');
                },
              );
            } on SocketException {
              attempt?.cancel();
            }
          }
          throw const SocketException('No public address reachable');
        }();
        return ConnectionTask.fromSocket(socket, () {
          stopped = true;
          connected?.destroy();
          attempt?.cancel();
        });
      };
    for (var redirects = 0; redirects <= 3; redirects++) {
      _ensureActive();
      final request = await _client.getUrl(uri);
      request.followRedirects = false;
      request.persistentConnection = false;
      request.headers.set(HttpHeaders.acceptHeader, 'text/html, text/plain');
      final response = await request.close();
      if ([301, 302, 303, 307, 308].contains(response.statusCode)) {
        final location = response.headers.value(HttpHeaders.locationHeader);
        if (location == null || redirects == 3) {
          throw const ChatFailure('web_redirect', '网页跳转过多或地址不完整，请使用最终网页链接。');
        }
        uri = redirectTarget(uri, location);
        // No cookies or authorization are carried across redirects.
        await response.listen((_) {}).cancel();
        continue;
      }
      if (response.statusCode != 200) {
        throw const ChatFailure('web_status', '网站未提供可读取的正文，可能需要登录或暂时不可访问。');
      }
      final type = response.headers.contentType;
      if (!(feed
              ? [
                  'text/xml',
                  'application/xml',
                  'application/rss+xml',
                  'text/html',
                ]
              : ['text/html', 'application/xhtml+xml', 'text/plain'])
          .contains(type?.mimeType)) {
        throw const ChatFailure(
          'web_type',
          '当前支持普通网页和纯文本链接，不支持直接读取 PDF 或下载文件。',
        );
      }
      final bytes = <int>[];
      await for (final chunk in response) {
        _ensureActive();
        if (bytes.length + chunk.length > maxBytes) {
          throw const ChatFailure('web_size', '网页内容过大，请复制需要的段落后发送。');
        }
        bytes.addAll(chunk);
      }
      _ensureActive();
      if (feed) return {'body': utf8.decode(bytes), 'url': uri.toString()};
      final encoding = type?.charset;
      if (encoding != null &&
          ![
            'utf-8',
            'utf8',
            'us-ascii',
            'iso-8859-1',
          ].contains(encoding.toLowerCase())) {
        throw const ChatFailure('web_encoding', '这个网页使用较旧的文字编码，请打开原网页后复制正文。');
      }
      // HTML parser handles BOM and meta charset detection for unspecified HTML.
      final document = type?.mimeType == 'text/plain'
          ? html.parse('<body></body>')
          : html.parse(bytes, encoding: encoding);
      if (type?.mimeType == 'text/plain') {
        document.body!.text =
            (encoding?.toLowerCase() == 'iso-8859-1' ? latin1 : utf8).decode(
              bytes,
            );
      }
      final refresh = refreshTarget(document, uri);
      if (refresh != null) {
        if (redirects == 3)
          throw const ChatFailure('web_redirect', '网页跳转过多，请打开原网页。');
        uri = refresh;
        continue;
      }
      return extract(document, uri, DateTime.now().toUtc());
    }
    throw const ChatFailure('web_redirect', '网页跳转未完成。');
  }

  static Uri redirectTarget(Uri base, String location) {
    var target = base.resolve(location);
    // Some public sites redirect HTTPS to their own HTTP spelling. Keep the
    // request encrypted instead of downgrading it; external HTTP stays blocked.
    if (target.scheme == 'http' &&
        target.host == base.host &&
        target.port == 80)
      target = target.replace(scheme: 'https', port: 443);
    return validateUrl(target.toString());
  }

  /// Follow an explicit immediate HTML refresh, never execute page scripts.
  static Uri? refreshTarget(dom.Document document, Uri base) {
    final metas = [...document.querySelectorAll('meta[http-equiv]')];
    for (final fallback in document.querySelectorAll('noscript')) {
      metas.addAll(
        html.parseFragment(fallback.text).querySelectorAll('meta[http-equiv]'),
      );
    }
    for (final meta in metas) {
      if (meta.attributes['http-equiv']?.toLowerCase() != 'refresh') continue;
      final content = meta.attributes['content'] ?? '';
      final match = RegExp(
        r'''^\s*0\s*;\s*url\s*=\s*["']?([^"']+)["']?\s*$''',
        caseSensitive: false,
      ).firstMatch(content);
      if (match != null)
        return validateUrl(base.resolve(match.group(1)!.trim()).toString());
    }
    return null;
  }

  static Map<String, Object?> extract(
    dom.Document document,
    Uri uri,
    DateTime fetchedAt,
  ) {
    String compact(String value) =>
        value.replaceAll(RegExp(r'\s+'), ' ').trim();
    String bounded(String value, int limit) =>
        String.fromCharCodes(value.runes.take(limit));
    final title = bounded(
      compact(document.querySelector('title')?.text ?? uri.host),
      180,
    );
    final published = bounded(
      compact(
        document
                .querySelector(
                  'meta[property="article:published_time"],meta[name="datePublished"]',
                )
                ?.attributes['content'] ??
            '',
      ),
      100,
    );
    for (final node in document.querySelectorAll(
      'script,style,noscript,template,nav,footer,aside,header,form,svg,iframe,[hidden],[aria-hidden="true"]',
    )) {
      node.remove();
    }
    final candidates = document.querySelectorAll('article,main,[role="main"]');
    final root = candidates.isEmpty
        ? document.body
        : candidates.reduce((a, b) => a.text.length >= b.text.length ? a : b);
    final paragraphs = <String>[];
    final stack = <dom.Node>[if (root != null) root];
    var nodes = 0;
    final buffer = StringBuffer();
    while (stack.isNotEmpty) {
      if (++nodes > 20000)
        throw const ChatFailure('web_complex', '网页结构过于复杂，请复制需要的段落后发送。');
      final node = stack.removeLast();
      if (node is dom.Text) {
        buffer.write(node.text);
      } else {
        if (node is dom.Element &&
            [
              'p',
              'div',
              'h1',
              'h2',
              'h3',
              'li',
              'tr',
              'br',
              'section',
            ].contains(node.localName)) {
          buffer.write('\n');
        }
        stack.addAll(node.nodes.reversed);
      }
    }
    for (final line in buffer.toString().split('\n')) {
      final text = compact(line);
      if (text.isNotEmpty) paragraphs.add(text);
    }
    final full = paragraphs.join('\n');
    if (full.runes.length < 40)
      throw const ChatFailure('web_empty', '没有提取到足够的正文；网站可能需要登录或运行脚本。');
    final truncated = full.runes.length > maxText;
    return {
      'title': title,
      'url': uri.toString(),
      'publishedAt': published,
      'fetchedAt': fetchedAt.toIso8601String(),
      'text': bounded(full, maxText),
      'truncated': truncated,
    };
  }
}
