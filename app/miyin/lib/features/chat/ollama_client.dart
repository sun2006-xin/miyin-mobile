import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'deepseek_client.dart';
import 'chat_prompts.dart';

/// USB reverse maps this loopback port to the computer. No cloud fallback.
final class OllamaClient implements ChatClient {
  OllamaClient({this.thinking = false, this.windowTokens = contextTokens});
  static final endpoint = Uri.parse('http://127.0.0.1:11435');
  final bool thinking;
  final int windowTokens;
  final HttpClient _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 8);
  bool _canceled = false;

  static const contextTokens = 8192;
  static const outputTokens = 2048;

  static String instructions(String model) =>
      ChatPrompts.identity(model, runtime: '电脑本地 Ollama');

  /// UTF-8 byte count is deliberately conservative for the Qwen byte-level
  /// tokenizer, with additional room for chat framing. Not an exact token count.
  static ({List<Map<String, String>> messages, int omitted}) prepareContext(
    String model,
    List<Map<String, String>> messages, {
    int windowTokens = contextTokens,
    int reservedOutputTokens = outputTokens,
    String? systemPrompt,
  }) {
    if (reservedOutputTokens <= 0 || reservedOutputTokens >= windowTokens) {
      throw const ChatFailure('local_context_limit', '模型上下文配置无效，请重新选择模型。');
    }
    if (messages.isEmpty || messages.last['role'] != 'user') {
      throw const ChatFailure('invalid_request', '请先输入本轮问题。');
    }
    final base = utf8.encode(systemPrompt ?? instructions(model)).length + 256;
    final budget = windowTokens - reservedOutputTokens;
    int cost(Map<String, String> item) =>
        utf8.encode(item['content'] ?? '').length + 64;
    final retained = List<Map<String, String>>.of(messages);
    var total = retained.fold<int>(base, (sum, item) => sum + cost(item));
    var omitted = 0;
    while (total > budget && retained.length > 1) {
      // Drop complete older turns, never start with an orphan assistant reply.
      do {
        total -= cost(retained.removeAt(0));
        omitted++;
      } while (retained.length > 1 && retained.first['role'] != 'user');
    }
    if (total > budget) {
      throw const ChatFailure(
        'local_context_limit',
        '本轮问题或附加资料超过当前模型的可发送容量，请缩短内容或分段提问；原文不会自动截断。',
      );
    }
    return (messages: retained, omitted: omitted);
  }

  @override
  void cancel() {
    _canceled = true;
    _http.close(force: true);
  }

  Future<HttpClientResponse> _request(String path, [Object? body]) async {
    final request = await _http
        .openUrl(body == null ? 'GET' : 'POST', endpoint.resolve(path))
        .timeout(const Duration(seconds: 10));
    request.followRedirects = false;
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
    }
    final response = await request.close().timeout(const Duration(seconds: 90));
    if (response.statusCode != 200) {
      throw const ChatFailure('local_service', '电脑模型未能处理请求，请检查模型是否已安装及服务状态。');
    }
    return response;
  }

  Future<List<String>> models() async {
    try {
      final response = await _request('/api/tags');
      final bytes = <int>[];
      await for (final chunk in response.timeout(const Duration(seconds: 10))) {
        bytes.addAll(chunk);
        if (bytes.length > 512 * 1024) throw const FormatException();
      }
      final value = jsonDecode(utf8.decode(bytes)) as Map;
      final ids = (value['models'] as List)
          .whereType<Map>()
          .map((row) => row['name'])
          .whereType<String>()
          .where(
            (id) =>
                id.isNotEmpty &&
                id.length <= 128 &&
                !id.contains('embedding') &&
                !id.contains('ov_intent'),
          )
          .toSet()
          .toList();
      if (ids.isEmpty) throw const ChatFailure('no_models', '电脑没有可用的聊天模型。');
      return ids;
    } on ChatFailure {
      rethrow;
    } catch (_) {
      throw const ChatFailure(
        'local_connection',
        '连接不到电脑模型。请连接 USB 调试，并确认电脑 Ollama 正在运行。',
      );
    } finally {
      _http.close(force: true);
    }
  }

  @override
  Stream<String> complete(
    String model,
    List<Map<String, String>> messages, {
    String? systemPrompt,
    int maxOutput = outputTokens,
  }) async* {
    try {
      final context = systemPrompt == null
          ? prepareContext(model, messages, windowTokens: windowTokens).messages
          : messages;
      if (systemPrompt != null &&
          messages.fold<int>(
                utf8.encode(systemPrompt).length + 256,
                (sum, row) =>
                    sum + utf8.encode(row['content'] ?? '').length + 64,
              ) >
              windowTokens - maxOutput) {
        throw const ChatFailure('memory_limit', '待整理的记忆片段过长，原文已保留。');
      }
      if (_canceled) throw const ChatFailure('canceled', '已停止生成。');
      final response = await _request('/api/chat', {
        'model': model,
        'stream': true,
        'think': systemPrompt == null && thinking,
        'messages': [
          {'role': 'system', 'content': systemPrompt ?? instructions(model)},
          ...context,
        ],
        'options': {'num_ctx': windowTokens, 'num_predict': maxOutput},
        'keep_alive': '5m',
      });
      var buffer = '';
      var total = 0;
      await for (final chunk
          in response
              .timeout(const Duration(seconds: 120))
              .transform(utf8.decoder)) {
        buffer += chunk;
        while (buffer.contains('\n')) {
          final end = buffer.indexOf('\n');
          final line = buffer.substring(0, end).trim();
          buffer = buffer.substring(end + 1);
          if (line.length > 256 * 1024) throw const FormatException();
          if (line.isEmpty) continue;
          final event = jsonDecode(line) as Map;
          if (event['error'] != null)
            throw const ChatFailure('local_generation', '电脑模型生成失败，请重试或换一个模型。');
          final message = event['message'];
          final text = message is Map ? message['content'] : null;
          if (text is String && text.isNotEmpty) {
            total += text.length;
            if (total > 128 * 1024)
              throw const ChatFailure('output_limit', '回答过长，已保留收到的内容。');
            yield text;
          }
          if (event['done'] == true) {
            if (total == 0)
              throw const ChatFailure('empty_response', '模型未返回文字，请重试。');
            if (event['done_reason'] == 'length')
              throw const ChatFailure('output_limit', '回答达到长度上限，可继续提问。');
            return;
          }
        }
        if (buffer.length > 256 * 1024) throw const FormatException();
      }
      throw const ChatFailure('interrupted', '电脑连接提前结束，已保留收到的回答。');
    } on ChatFailure {
      rethrow;
    } catch (_) {
      throw ChatFailure(
        _canceled ? 'canceled' : 'local_connection',
        _canceled ? '已停止生成。' : '电脑模型连接中断，请检查 USB 和 Ollama；已保留收到的回答。',
      );
    } finally {
      _http.close(force: true);
    }
  }
}
