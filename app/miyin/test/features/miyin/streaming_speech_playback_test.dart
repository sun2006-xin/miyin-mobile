import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:miyin_app/features/miyin/streaming_speech_playback.dart';

void main() {
  test(
    'one group forwards 24k PCM as bounded 44100 chunks and drains its tail',
    () async {
      final calls = <String>[], output = BytesBuilder();
      final player = MiyinStreamingSpeechPlayback(
        sessionId: 'segment',
        groupId: 'answer',
        isCurrent: (_) => true,
        invoke: (method, args) async {
          calls.add(method);
          if (method == 'beginAudioStream') {
            expect(args['groupId'], 'answer');
            expect(args['sampleRate'], 44100);
          }
          if (method == 'appendAudioStream') {
            final pcm = args['pcm'] as Uint8List;
            expect(pcm.length, lessThanOrEqualTo(65536));
            output.add(pcm);
          }
          return {'status': 'speaking'};
        },
      );
      final input = Uint8List(100006);
      await player.add(Uint8List.sublistView(input, 0, 64000), 24000, 1);
      await player.add(Uint8List.sublistView(input, 64000), 24000, 1);
      await player.finish();
      expect(output.length ~/ 2, 50003 * 44100 ~/ 24000);
      expect(calls.where((m) => m == 'beginAudioStream').length, 1);
      expect(calls.last, 'finishAudioStream');
    },
  );
  test(
    'native paused cancellation on begin never appends or reopens late audio',
    () async {
      final calls = <String>[];
      final player = MiyinStreamingSpeechPlayback(
        sessionId: 'paused',
        isCurrent: (_) => true,
        invoke: (method, args) async {
          calls.add(method);
          return {'status': 'cancelled'};
        },
      );
      await player.add(Uint8List(32), 44100, 1);
      expect(await player.started, {'status': 'cancelled'});
      await player.add(Uint8List(32), 44100, 1);
      await player.finish();
      expect(calls, ['beginAudioStream']);
    },
  );
  test('native paused cancellation while appending is terminal', () async {
    final calls = <String>[];
    final player = MiyinStreamingSpeechPlayback(
      sessionId: 'paused',
      isCurrent: (_) => true,
      invoke: (method, args) async {
        calls.add(method);
        return {'status': method == 'beginAudioStream' ? 'ready' : 'cancelled'};
      },
    );
    await player.add(Uint8List(32), 44100, 1);
    expect(await player.started, {'status': 'cancelled'});
    await player.add(Uint8List(32), 44100, 1);
    await player.finish();
    expect(calls, ['beginAudioStream', 'appendAudioStream']);
  });
  test(
    'first PCM is accepted before synthesis completes, with one native stream',
    () async {
      final calls = <String>[];
      final player = MiyinStreamingSpeechPlayback(
        sessionId: 's',
        isCurrent: (_) => true,
        invoke: (method, args) async {
          calls.add(method);
          return {'status': 'speaking'};
        },
      );
      await player.add(Uint8List(32), 44100, 1);
      expect(await player.started, {'status': 'speaking'});
      expect(calls, ['beginAudioStream', 'appendAudioStream']);
      await player.add(Uint8List(16), 44100, 1);
      await player.finish();
      expect(calls, [
        'beginAudioStream',
        'appendAudioStream',
        'appendAudioStream',
        'finishAudioStream',
      ]);
    },
  );
  test('late chunks after cancellation cannot restart playback', () async {
    var current = true;
    final calls = <String>[];
    final player = MiyinStreamingSpeechPlayback(
      sessionId: 's',
      isCurrent: (_) => current,
      invoke: (method, args) async {
        calls.add(method);
        return null;
      },
    );
    current = false;
    await player.add(Uint8List(32), 44100, 1);
    await player.finish();
    expect(calls, isEmpty);
    expect(await player.started, {'status': 'cancelled'});
  });
  test('cancellation during native start aborts the exact stream without appending', () async {
    var current = true;
    final gate = Completer<Object?>();
    final calls = <String>[];
    final player = MiyinStreamingSpeechPlayback(
      sessionId: 's',
      isCurrent: (_) => current,
      invoke: (method, args) async {
        calls.add(method);
        return method == 'beginAudioStream' ? gate.future : null;
      },
    );
    final adding = player.add(Uint8List(32), 44100, 1);
    await Future<void>.delayed(Duration.zero);
    current = false;
    gate.complete(null);
    await adding;
    await player.finish();
    expect(calls, ['beginAudioStream', 'abortAudioStream']);
    expect(await player.started, {'status': 'cancelled'});
  });
  test(
    'failure after first audio aborts playback; late chunks are ignored',
    () async {
      final calls = <String>[];
      final player = MiyinStreamingSpeechPlayback(
        sessionId: 's',
        isCurrent: (_) => true,
        invoke: (method, args) async {
          calls.add(method);
          return null;
        },
      );
      await player.add(Uint8List(32), 44100, 1);
      await player.started;
      await player.fail(StateError('generation failed'), StackTrace.current);
      await player.add(Uint8List(32), 44100, 1);
      await player.finish();
      expect(calls, [
        'beginAudioStream',
        'appendAudioStream',
        'abortAudioStream',
      ]);
    },
  );
  test('cached WAV playback does not create a PCM stream', () async {
    final player = MiyinStreamingSpeechPlayback(
      sessionId: 's',
      isCurrent: (_) => true,
      invoke: (method, args) async => fail('No stream call expected'),
    );
    player.completeCached({'status': 'speaking'});
    expect(await player.started, {'status': 'speaking'});
  });
}
