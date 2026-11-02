import 'package:flutter_test/flutter_test.dart';
import 'package:miyin_app/features/miyin/voice_request_ownership.dart';

void main() {
  test('late cancel from old answer cannot cancel the new pending answer', () {
    final gate = VoiceRequestOwnership();
    gate.begin('old');
    final ticket = gate.begin('new');
    expect(gate.cancel('old'), false);
    expect(gate.owns('new', ticket), true);
  });
  test('matching cancellation invalidates a pending open before native work', () {
    final gate = VoiceRequestOwnership();
    final ticket = gate.begin('pending');
    expect(gate.cancel('pending'), true);
    expect(gate.owns('pending', ticket), false);
  });
  test('lifecycle invalidation defeats reuse of the same session id', () {
    final gate = VoiceRequestOwnership();
    final old = gate.begin('same');
    gate.invalidate();
    final fresh = gate.begin('same');
    expect(gate.owns('same', old), false);
    expect(gate.owns('same', fresh), true);
  });
  test('late terminal event does not clear a newer owner', () {
    final gate = VoiceRequestOwnership();
    gate.begin('old');
    final fresh = gate.begin('new');
    gate.complete('old');
    expect(gate.owns('new', fresh), true);
    gate.complete('new');
    expect(gate.owns('new', fresh), false);
  });
}
