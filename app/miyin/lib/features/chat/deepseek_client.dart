import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'chat_prompts.dart';

final class ChatFailure implements Exception {
  const ChatFailure(this.code, this.message);
  final String code;
  final String message;
}

/// A dedicated connection per operation makes stop close the actual request.
/// Credentials and server error bodies never cross the WebView bridge.
abstract interface class ChatClient {
  void cancel();
  Stream<String> complete(String model, List<Map<String, String>> messages);
}

final class DeepSeekClient implements ChatClient {
  DeepSeekClient({
    required this.apiKey,
    HttpClient? client,
    this.baseUrl = 'https://api.deepseek.com',
    this.serviceName = 'DeepSeek',
    this.deepSeekOptions = true,
    this.anthropic = false,
    this.maxOutputTokens = 4096,
    this.templateThinking,
    this.temperature,
    this.systemPrompt,
  }) : _http = client ?? HttpClient() {
    _http.connectionTimeout = const Duration(seconds: 20);
  }
  final String apiKey;
  final String baseUrl, serviceName;
  final bool deepSeekOptions;
  final bool anthropic;
  final int maxOutputTokens;
  final bool? templateThinking;
  final double? temperature;
  final String? systemPrompt;
  final HttpClient _http;
  bool _canceled = false;

  @override
  void cancel() {
    _canceled = true;
    _http.close(force: true);
  }

  Future<HttpClientResponse> _request(String path, [Object? body]) async {
    try {
      final request = await _http
          .openUrl(body == null ? 'GET' : 'POST', Uri.parse(baseUrl + path))
          .timeout(const Duration(seconds: 25));
      request.followRedirects = false;
      if (anthropic) {
        request.headers.set('x-api-key', apiKey);
        request.headers.set('anthropic-version', '2023-06-01');
      } else {
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $apiKey');
      }
      request.headers.set(
        HttpHeaders.acceptHeader,
        body == null ? 'application/json' : 'text/event-stream',
      );
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
      }
      final response = await request.close().timeout(
        const Duration(seconds: 60),
      );
      if (response.statusCode != 200) {
        final code = response.statusCode;
        throw ChatFailure('http_$code', switch (code) {
          401 => '$serviceName 密钥无效，请重新配置。',
          402 => '$serviceName 账户余额不足，请检查账户。',
          429 => '请求太频繁，请稍后重试。',
          400 || 404 || 422 => '模型或请求不受支持，请重新检查模型配置。',
          _ => '$serviceName 服务暂时不可用，请稍后重试。',
        });
      }
      return response;
    } on ChatFailure {
      rethrow;
    } catch (_) {
      throw ChatFailure(
        _canceled ? 'canceled' : 'network',
        _canceled ? '已停止生成。' : '无法连接 $serviceName，请检查网络后重试。',
      );
    }
  }

  Future<List<String>> models() async {
    try {
      final response = await _request('/models');
      final bytes = <int>[];
      await for (final chunk in response.timeout(const Duration(seconds: 30))) {
        bytes.addAll(chunk);
        if (bytes.length > 512 * 1024) {
          throw const ChatFailure('invalid_response', '模型列表异常。');
        }
      }
      final json = jsonDecode(utf8.decode(bytes)) as Map;
      final result = (json['data'] as List)
          .whereType<Map>()
          .where(
            (item) =>
                item['input_modalities'] is! List ||
                (item['input_modalities'] as List).contains('text'),
          )
          .map((item) => item['id'])
          .whereType<String>()
          .where((id) => id.isNotEmpty && id.length <= 128)
          .toSet()
          .toList();
      if (result.isEmpty) {
        throw const ChatFailure('no_models', '账户没有可用的文字模型。');
      }
      return result;
    } on ChatFailure {
      rethrow;
    } catch (_) {
      throw const ChatFailure('model_check_failed', '读取模型失败，请检查网络和密钥。');
    } finally {
      _http.close(force: true);
    }
  }

  @override
  Stream<String> complete(
    String model,
    List<Map<String, String>> messages,
  ) async* {
    try {
      final identity =
          systemPrompt ??
          ChatPrompts.identity(model, runtime: '$serviceName 服务');
      final response = await _request(
        anthropic ? '/messages' : '/chat/completions',
        {
          'model': model,
          if (anthropic) 'system': identity,
          'messages': [
            if (!anthropic) {'role': 'system', 'content': identity},
            ...messages,
          ],
          'stream': true,
          if (deepSeekOptions && !anthropic) 'thinking': {'type': 'disabled'},
          'max_tokens': maxOutputTokens,
          if (temperature != null) 'temperature': temperature,
          if (templateThinking != null)
            'chat_template_kwargs': {'enable_thinking': templateThinking},
        },
      );
      final type = response.headers.contentType?.mimeType;
      if (type != 'text/event-stream') {
        throw const ChatFailure('invalid_response', '服务没有返回流式回答。');
      }
      var total = 0;
      var line = StringBuffer();
      // Decode UTF-8 before splitting: a Chinese character may span TCP chunks.
      await for (final chunk
          in response
              .timeout(const Duration(seconds: 90))
              .transform(utf8.decoder)) {
        for (final unit in chunk.codeUnits) {
          if (unit != 10) {
            line.writeCharCode(unit);
            if (line.length > 256 * 1024) {
              throw const ChatFailure('response_limit', '单段回答过长，请重试。');
            }
            continue;
          }
          final value = line.toString().trimRight();
          line = StringBuffer();
          if (!value.startsWith('data:')) continue;
          final data = value.substring(5).trimLeft();
          if (data == '[DONE]') {
            if (total == 0) {
              throw const ChatFailure('empty_response', '模型未返回文字，请重试。');
            }
            return;
          }
          if (data.isEmpty) continue;
          final event = jsonDecode(data) as Map;
          if (event['error'] != null) {
            throw const ChatFailure('service_error', '服务中断了回答，请重试。');
          }
          if (anthropic) {
            if (event['type'] == 'message_stop') {
              if (total == 0)
                throw const ChatFailure('empty_response', '模型未返回文字，请重试。');
              return;
            }
            final delta = event['delta'];
            if (event['type'] == 'message_delta' &&
                delta is Map &&
                delta['stop_reason'] == 'max_tokens') {
              throw const ChatFailure('output_limit', '回答达到模型长度上限，可继续提问。');
            }
            if (event['type'] == 'content_block_delta' &&
                delta is Map &&
                delta['type'] == 'text_delta') {
              final text = delta['text'];
              if (text is String && text.isNotEmpty) {
                total += text.length;
                if (total > 128 * 1024)
                  throw const ChatFailure(
                    'response_limit',
                    '回答达到长度上限，已保留收到的内容。',
                  );
                yield text;
              }
            }
            continue;
          }
          final choices = event['choices'];
          if (choices is! List || choices.isEmpty) continue;
          final choice = choices.first as Map;
          final delta = choice['delta'];
          final text = delta is Map ? delta['content'] : null;
          if (text is String && text.isNotEmpty) {
            total += text.length;
            if (total > 128 * 1024) {
              throw const ChatFailure('response_limit', '回答达到长度上限，已保留收到的内容。');
            }
            yield text;
          }
          if (choice['finish_reason'] == 'length') {
            throw const ChatFailure('output_limit', '回答达到模型长度上限，可继续提问。');
          }
          if (choice['finish_reason'] == 'content_filter') {
            throw const ChatFailure('content_filter', '服务未能完成这条回答。');
          }
        }
      }
      throw const ChatFailure('interrupted', '连接提前结束，已保留收到的内容，请重试。');
    } on ChatFailure {
      rethrow;
    } catch (_) {
      throw ChatFailure(
        _canceled ? 'canceled' : 'interrupted',
        _canceled ? '已停止生成。' : '连接中断，已保留收到的内容，请检查网络后重试。',
      );
    } finally {
      _http.close(force: true);
    }
  }
}
