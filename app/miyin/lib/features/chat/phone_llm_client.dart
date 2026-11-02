import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';

import 'deepseek_client.dart';
import 'ollama_client.dart';
import 'chat_prompts.dart';
import 'chat_image.dart';

final class PhoneLlmClient implements ChatClient {
  PhoneLlmClient({
    this.thinking = false,
    this.onReasoning,
    Map<int, List<ChatImage>> imageMessages = const {},
  }) : imageMessages = snapshotChatImages(imageMessages);
  static const channel = MethodChannel('com.miyin.app/chat-local');
  static const contextTokens = 4096;
  static const outputTokens = 1024;
  // Matches the bounded native --image-max-tokens setting, excluding text and
  // chat framing reserved separately by prepareContext.
  static const imageTokenReserve = 768;
  static const maxImages = 2;
  final Map<int, List<ChatImage>> imageMessages;

  static ({List<Map<String, String>> messages, int omitted}) prepareContext(
    String model,
    List<Map<String, String>> messages, {
    int imageCount = 0,
  }) {
    if (imageCount < 0 || imageCount > maxImages) {
      throw const ChatFailure('image_limit', '手机本机每轮最多携带2张图片，请减少图片或新建对话。');
    }
    try {
      return OllamaClient.prepareContext(
        model,
        messages,
        windowTokens: contextTokens,
        reservedOutputTokens: outputTokens + imageCount * imageTokenReserve,
        systemPrompt: ChatPrompts.identity(model, runtime: '手机本地'),
      );
    } on ChatFailure catch (error) {
      if (imageCount == 0 || error.code != 'local_context_limit') rethrow;
      throw const ChatFailure(
        'image_context_limit',
        '问题与图片超过手机模型容量，请减少资料；原图不会自动省略。',
      );
    }
  }

  final bool thinking;
  final void Function()? onReasoning;
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
      final clock = Stopwatch()..start();
      if (_canceled) throw const ChatFailure('canceled', '已停止生成。');
      final system = ChatPrompts.identity(model, runtime: '手机本地');
      try {
        validateChatImages(imageMessages, messages);
      } on ArgumentError {
        throw const ChatFailure(
          'image_invalid',
          '原图资料不完整、超出限制或与消息不匹配，请重新附加图片。',
        );
      }
      final imageCount = imageMessages.values.fold<int>(
        0,
        (sum, images) => sum + images.length,
      );
      final prepared = prepareContext(model, messages, imageCount: imageCount);
      if (imageMessages.keys.any((index) => index < prepared.omitted)) {
        throw const ChatFailure(
          'image_context_limit',
          '较早图片已超过手机模型容量，请新建对话或关闭携带历史；原图不会自动省略。',
        );
      }
      final preparedImages = {
        for (final entry in imageMessages.entries)
          entry.key - prepared.omitted: entry.value,
      };
      final runtime = await channel.invokeMapMethod<String, Object?>(
        'prepare',
        imageCount > 0 ? {'vision': true} : null,
      );
      final readyMs = clock.elapsedMilliseconds;
      if (_canceled) throw const ChatFailure('canceled', '已停止生成。');
      if (runtime?['endpoint'] != 'http://127.0.0.1:11438/v1' ||
          runtime?['key'] is! String ||
          (runtime?['contextTokens'] != null &&
              runtime?['contextTokens'] != contextTokens))
        throw const ChatFailure('local_model', '本机模型尚未准备完成。');
      if (imageCount > 0 && runtime?['vision'] != true) {
        throw const ChatFailure(
          'image_unsupported',
          '本机看图组件未准备完成，请重试或选择支持图片的模型；原图未发送。',
        );
      }
      var reasoningStarted = false;
      final client = DeepSeekClient(
        apiKey: runtime!['key'] as String,
        baseUrl: 'http://127.0.0.1:11438/v1',
        serviceName: '手机内置模型',
        deepSeekOptions: false,
        maxOutputTokens: outputTokens,
        templateThinking: thinking,
        imageMessages: preparedImages,
        systemPrompt: system,
        onReasoning: () {
          if (_canceled || reasoningStarted) return;
          reasoningStarted = true;
          debugPrint(
            '[MiyinPhoneChat] firstReasoningMs=${clock.elapsedMilliseconds} prepareMs=$readyMs thinking=$thinking',
          );
          onReasoning?.call();
        },
      );
      _client = client;
      var first = true;
      await for (final text in client.complete(model, prepared.messages)) {
        if (first) {
          first = false;
          debugPrint(
            '[MiyinPhoneChat] firstDeltaMs=${clock.elapsedMilliseconds} '
            'prepareMs=$readyMs reused=${runtime['reused'] == true} '
            'messages=${prepared.messages.length} '
            'inputChars=${prepared.messages.fold<int>(0, (sum, row) => sum + row['content']!.length)}',
          );
        }
        yield text;
      }
    } on PlatformException catch (error) {
      throw ChatFailure('local_model', error.message ?? '本机模型未能准备。');
    } on MissingPluginException {
      throw const ChatFailure('local_model', '当前安装包不支持本机聊天模型。');
    }
  }
}
