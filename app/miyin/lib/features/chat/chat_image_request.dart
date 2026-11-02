import 'chat_image.dart';
import 'deepseek_client.dart';

/// Loads private bytes only after request validation/consent, and keeps stop
/// effective while disk reads or a provider capability check are pending.
final class ChatImageRequest implements ChatClient {
  ChatImageRequest({required this.load, required this.create});
  final Future<Map<int, List<ChatImage>>> Function() load;
  final ChatClient Function(Map<int, List<ChatImage>>) create;
  ChatClient? _client;
  bool _canceled = false;
  @override
  void cancel() {
    _canceled = true;
    _client?.cancel();
  }

  @override
  Stream<String> complete(
    String model,
    List<Map<String, String>> messages,
  ) async* {
    if (_canceled) throw const ChatFailure('canceled', '已停止生成。');
    final images = await load();
    if (_canceled) throw const ChatFailure('canceled', '已停止生成。');
    final client = create(images);
    _client = client;
    yield* client.complete(model, messages);
  }
}
