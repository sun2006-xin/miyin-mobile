import 'phone_llm_client.dart';
import 'web_search.dart';

/// Add the bounded search excerpts before reporting the final history budget.
abstract final class ChatSearchContext {
  static ({
    List<Map<String, String>> messages,
    int omitted,
    int additionalOmitted,
    String notice,
  })
  preparePhone(
    String model,
    List<Map<String, String>> messages,
    List<Map<String, Object?>> sources, {
    int previouslyOmitted = 0,
  }) {
    final expanded = messages.map(Map<String, String>.of).toList();
    // Validate the current turn before accessing or modifying its content.
    PhoneLlmClient.prepareContext(model, expanded);
    expanded.last['content'] =
        '${expanded.last['content']}${WebSearch.material(sources, phone: true)}';
    final prepared = PhoneLlmClient.prepareContext(model, expanded);
    final omitted = previouslyOmitted + prepared.omitted;
    return (
      messages: prepared.messages,
      omitted: omitted,
      additionalOmitted: prepared.omitted,
      notice: '本轮加入联网资料后，较早的 $omitted 条消息未发送；完整记录仍保留。',
    );
  }
}
