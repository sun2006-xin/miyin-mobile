/// Bridges UI requests that can arrive after a later answer has already opened.
/// Internal lifecycle cancellation is global; a UI cancellation is owner-scoped.
final class VoiceRequestOwnership {
  int _generation = 0;
  String? _id;
  int begin(String id) { _id = id; return ++_generation; }
  void invalidate() { _id = null; ++_generation; }
  bool owns(String id, int generation) => _id == id && _generation == generation;
  bool cancel(String id) {
    if (_id != id) return false;
    invalidate();
    return true;
  }
  void complete(String id) { if (_id == id) invalidate(); }
}
