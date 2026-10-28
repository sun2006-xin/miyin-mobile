import 'dart:async';

import 'package:flutter/services.dart';

import 'deepseek_client.dart';
import 'ollama_client.dart';
import 'chat_prompts.dart';

final class PhoneLlmClient implements ChatClient {
  PhoneLlmClient({this.thinking = false});
  static const channel = MethodChannel('com.miyin.app/chat-local');
  static const contextTokens = 4096;
  static const outputTokens = 1024;

  static ({List<Map<String, String>> messages, int omitted}) prepareContext(
    String model,
    List<Map<String, String>> messages,
  ) => OllamaClient.prepareContext(
    model,
    messages,
    windowTokens: contextTokens,
    reservedOutputTokens: outputTokens,
    systemPrompt: ChatPrompts.identity(model, runtime: '手机本地'),
  );
  final bool thinking;
  DeepSeekClient? _client;
  bool _canceled = false;
  @override
  void cancel() {
    _canceled = true;
    _client?.cancel();
    // The HTTP operation owns generation, not the shared loaded model.
    // A canceled preparation may still finish warming it for the next turn.
  }

  @override
  Stream<String> complete(
    String model,
    List<Map<String, String>> messages,
  ) async* {
    try {
      if (_canceled) throw const ChatFailure('canceled', '已停止生成。');
      final system = ChatPrompts.identity(model, runtime: '手机本地');
      final prepared = prepareContext(model, messages);
      final runtime = await channel.invokeMapMethod<String, Object?>('prepare');
      if (_canceled) throw const ChatFailure('canceled', '已停止生成。');
      if (runtime?['endpoint'] != 'http://127.0.0.1:11438/v1' ||
          runtime?['key'] is! String ||
          (runtime?['contextTokens'] != null &&
              runtime?['contextTokens'] != contextTokens))
        throw const ChatFailure('local_model', '本机模型尚未准备完成。');
      final client = DeepSeekClient(
        apiKey: runtime!['key'] as String,
        baseUrl: 'http://127.0.0.1:11438/v1',
        serviceName: '手机内置模型',
        deepSeekOptions: false,
        maxOutputTokens: outputTokens,
        templateThinking: thinking,
        systemPrompt: system,
      );
      _client = client;
      yield* client.complete(model, prepared.messages);
    } on PlatformException catch (error) {
      throw ChatFailure('local_model', error.message ?? '本机模型未能准备。');
    } on MissingPluginException {
      throw const ChatFailure('local_model', '当前安装包不支持本机聊天模型。');
    }
  }
}
