import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'deepseek_client.dart';
import 'chat_prompts.dart';
import 'chat_image.dart';

/// USB reverse maps this loopback port to the computer. No cloud fallback.
final class OllamaClient implements ChatClient {
  OllamaClient({
    this.thinking = false,
    this.windowTokens = contextTokens,
    Uri? baseUrl,
    Map<int, List<ChatImage>> imageMessages = const {},
  }) : _endpoint = baseUrl ?? endpoint,
       imageMessages = snapshotChatImages(imageMessages);
  static final endpoint = Uri.parse('http://127.0.0.1:11435');
  final Uri _endpoint;
  final Map<int, List<ChatImage>> imageMessages;

  /// Deliberately conservative extra reservation, not an exact image tokenizer.
  /// Native image preparation must separately bound resolution. A backend may
  /// still reject a request whose model-specific visual token count is larger.
  static const imageTokenReserve = 4096;
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
        .openUrl(body == null ? 'GET' : 'POST', _endpoint.resolve(path))
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

  Future<void> _requireVision(String model) async {
    final response = await _request('/api/show', {'model': model});
    final bytes = <int>[];
    await for (final chunk in response.timeout(const Duration(seconds: 10))) {
      if (_canceled) throw const ChatFailure('canceled', '已停止生成。');
      if (bytes.length + chunk.length > 512 * 1024) {
        throw const ChatFailure(
          'image_capability_unknown',
          '无法确认当前电脑模型的图片能力，请检查模型配置后重试。',
        );
      }
      bytes.addAll(chunk);
    }
    Object? value;
    try {
      value = jsonDecode(utf8.decode(bytes));
    } on FormatException {
      throw const ChatFailure(
        'image_capability_unknown',
        '无法确认当前电脑模型的图片能力，请检查模型配置后重试。',
      );
    }
    final capabilities = value is Map ? value['capabilities'] : null;
    if (capabilities is! List || !capabilities.contains('vision')) {
      throw const ChatFailure(
        'image_unsupported',
        '当前电脑模型未确认支持原图识别，请选择支持图片的模型；原图未发送。',
      );
    }
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
      if (_canceled) throw const ChatFailure('canceled', '已停止生成。');
      final hasImages = imageMessages.isNotEmpty;
      try {
        validateChatImages(imageMessages, messages);
      } on ArgumentError {
        throw const ChatFailure(
          'image_invalid',
          '原图资料不完整、超出限制或与消息不匹配，请重新附加图片。',
        );
      }
      final imageTokens = imageMessages.values.fold<int>(
        0,
        (sum, images) => sum + images.length * imageTokenReserve,
      );
      if (hasImages && imageTokens + maxOutput >= windowTokens) {
        throw const ChatFailure(
          'image_context_limit',
          '图片与输出预留超过当前模型上下文容量，请减少图片或选择更大上下文。',
        );
      }
      final List<Map<String, String>> context;
      try {
        context = systemPrompt == null
            ? (hasImages
                      ? prepareContext(
                          model,
                          messages,
                          windowTokens: windowTokens,
                          reservedOutputTokens: maxOutput + imageTokens,
                        )
                      : prepareContext(
                          model,
                          messages,
                          windowTokens: windowTokens,
                        ))
                  .messages
            : messages;
      } on ChatFailure {
        if (!hasImages) rethrow;
        throw const ChatFailure(
          'image_context_limit',
          '问题与图片超过当前上下文预算，请减少资料；原图不会自动省略。',
        );
      }
      final omitted = messages.length - context.length;
      if (hasImages && imageMessages.keys.any((index) => index < omitted)) {
        throw const ChatFailure(
          'image_context_limit',
          '较早图片已超出本轮上下文预算，请移除图片或扩大上下文后重试；原图不会自动省略。',
        );
      }
      if (systemPrompt != null &&
          messages.fold<int>(
                utf8.encode(systemPrompt).length + 256,
                (sum, row) =>
                    sum + utf8.encode(row['content'] ?? '').length + 64,
              ) >
              windowTokens - maxOutput - imageTokens) {
        if (hasImages) {
          throw const ChatFailure(
            'image_context_limit',
            '问题与图片超过当前上下文预算，请减少资料；原图不会自动省略。',
          );
        }
        throw const ChatFailure('memory_limit', '待整理的记忆片段过长，原文已保留。');
      }
      if (_canceled) throw const ChatFailure('canceled', '已停止生成。');
      if (hasImages) await _requireVision(model);
      if (_canceled) throw const ChatFailure('canceled', '已停止生成。');
      final response = await _request('/api/chat', {
        'model': model,
        'stream': true,
        'think': systemPrompt == null && thinking,
        'messages': [
          {'role': 'system', 'content': systemPrompt ?? instructions(model)},
          for (var index = 0; index < context.length; index++)
            if (imageMessages.containsKey(index + omitted))
              {
                ...context[index],
                'images': [
                  for (final image in imageMessages[index + omitted]!)
                    image.base64,
                ],
              }
            else
              context[index],
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
