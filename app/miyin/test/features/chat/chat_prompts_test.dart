import 'package:flutter_test/flutter_test.dart';
import 'package:miyin_app/features/chat/chat_prompts.dart';

void main() {
  test('identity reflects the actual configured model and runtime', () {
    final prompt = ChatPrompts.identity(
      'model-example-v2',
      runtime: '手机本地',
      now: DateTime(2026, 10, 26),
    );
    expect(
      prompt,
      '你是觅音 AI 助手。当前配置的模型 ID：model-example-v2。运行方式：手机本地。当前设备日期：2026-10-26。',
    );
    expect(prompt, isNot(contains('Qwen')));
    expect(prompt, isNot(contains('翻译任务')));
    expect(prompt, isNot(contains('只给译文')));
  });
  test('different providers get their own runtime identity', () {
    final prompt = ChatPrompts.identity('cloud-model', runtime: '云端服务');
    expect(prompt, contains('cloud-model'));
    expect(prompt, contains('云端服务'));
    expect(prompt, isNot(contains('手机本地')));
  });
}
