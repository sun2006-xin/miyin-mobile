/// Product identity and runtime facts, independent of the user's topic.
abstract final class ChatPrompts {
  static String identity(
    String model, {
    required String runtime,
    DateTime? now,
  }) {
    final date = now ?? DateTime.now();
    final day =
        '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    return '你是觅音 AI 助手。当前配置的模型 ID：$model。运行方式：$runtime。当前设备日期：$day。';
  }
}
