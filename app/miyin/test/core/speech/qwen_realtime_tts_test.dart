import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:miyin_app/core/speech/qwen_realtime_tts.dart';

final class FakeSocket implements QwenTtsSocket {
  FakeSocket() {
    input = StreamController<Object?>(
      onPause: () => pauses++,
      onResume: () => resumes++,
    );
  }
  late final StreamController<Object?> input;
  int pauses = 0, resumes = 0;
  final sent = <Map<String, dynamic>>[];
  bool closed = false;
  @override
  Stream<Object?> get messages => input.stream;
  @override
  void send(String event) =>
      sent.add(jsonDecode(event) as Map<String, dynamic>);
  @override
  Future<void> close() async {
    closed = true;
  }

  void emit(String type, [Map<String, Object?> rest = const {}]) =>
      input.add(jsonEncode({'type': type, ...rest}));
  Future<void> dispose() async {
    // A connection cancelled before listen has no stream consumer to complete
    // StreamController.close's future. Closing it is still sufficient cleanup.
    unawaited(input.close());
  }
}

QwenRealtimeTtsConfig config({QwenTtsRegion region = QwenTtsRegion.beijing}) =>
    QwenRealtimeTtsConfig(
      region: region,
      model: 'qwen3-tts-flash-realtime',
      voice: 'Cherry',
      language: 'Chinese',
    );

Future<void> tick() => Future<void>.delayed(Duration.zero);

Matcher failure(String code) =>
    isA<QwenTtsFailure>().having((error) => error.code, 'code', code);

Future<QwenRealtimeTtsSession> open(
  FakeSocket socket, {
  SpeechCancellationToken? token,
  Future<void> Function(Uint8List, int)? onAudio,
  QwenRealtimeTtsClient? client,
}) async {
  final pending =
      (client ?? QwenRealtimeTtsClient(connector: (_, _) async => socket)).open(
        config: config(),
        apiKey: 'tts-only-test-key',
        cancellation: token ?? SpeechCancellationToken(),
        onAudio: onAudio ?? (_, _) async {},
      );
  await tick();
  socket.emit('session.created');
  await tick();
  socket.emit('session.updated', {
    'session': {
      'response_format': 'pcm',
      'sample_rate': 24000,
      'mode': 'server_commit',
    },
  });
  return pending;
}

void main() {
  test(
    'only explicit TTS configuration chooses fixed official regional endpoints',
    () {
      expect(
        config().endpoint.toString(),
        'wss://dashscope.aliyuncs.com/api-ws/v1/realtime?model=qwen3-tts-flash-realtime',
      );
      expect(
        config(region: QwenTtsRegion.singapore).endpoint.host,
        'dashscope-intl.aliyuncs.com',
      );
      expect(
        () => QwenRealtimeTtsConfig(
          region: QwenTtsRegion.beijing,
          model: 'deepseek-chat',
          voice: 'Cherry',
        ),
        throwsA(failure('invalid_model')),
      );
      expect(
        () => QwenRealtimeTtsConfig(
          region: QwenTtsRegion.beijing,
          model: 'qwen-audio-3.1-tts-flash',
          voice: 'Cherry',
        ),
        throwsA(failure('invalid_model')),
      );
      expect(
        () => QwenRealtimeTtsConfig(
          region: QwenTtsRegion.beijing,
          model: 'qwen3-tts-flash-realtime',
          voice: 'bad\nvoice',
        ),
        throwsA(failure('invalid_voice')),
      );
    },
  );

  test('invalid or cancelled credentials never connect', () async {
    var calls = 0;
    final client = QwenRealtimeTtsClient(
      connector: (_, _) async {
        calls++;
        return FakeSocket();
      },
    );
    await expectLater(
      client.open(
        config: config(),
        apiKey: 'bad\nkey',
        cancellation: SpeechCancellationToken(),
        onAudio: (_, _) async {},
      ),
      throwsA(failure('invalid_key')),
    );
    final token = SpeechCancellationToken()..cancel();
    await expectLater(
      client.open(
        config: config(),
        apiKey: 'tts-only-key',
        cancellation: token,
        onAudio: (_, _) async {},
      ),
      throwsA(failure('cancelled')),
    );
    expect(calls, 0);
  });

  test(
    'waits for configured PCM, preserves text deltas and uses one socket',
    () async {
      final socket = FakeSocket();
      addTearDown(socket.dispose);
      final output = <int>[];
      var calls = 0;
      final client = QwenRealtimeTtsClient(
        connector: (uri, headers) async {
          calls++;
          expect(uri, config().endpoint);
          expect(headers, {'Authorization': 'Bearer tts-only-test-key'});
          return socket;
        },
      );
      final session = await open(
        socket,
        client: client,
        onAudio: (bytes, rate) async {
          expect(rate, 24000);
          expect(bytes.length.isEven, true);
          output.addAll(bytes);
        },
      );
      expect(socket.sent.single['type'], 'session.update');
      expect((socket.sent.single['session'] as Map)['mode'], 'server_commit');
      session.append('Hello');
      session.append(' ');
      session.append('觅音。');
      socket.emit('response.audio.delta', {
        'delta': base64Encode([1]),
      });
      socket.emit('response.audio.delta', {
        'delta': base64Encode([2, 3, 4]),
      });
      socket.emit('response.audio.done');
      socket.emit('response.done', {
        'response': {'status': 'completed'},
      });
      await tick();
      expect(output, [1, 2, 3, 4]);
      final done = session.finish();
      socket.emit('session.finished');
      await done;
      expect(socket.sent.map((e) => e['type']), [
        'session.update',
        'input_text_buffer.append',
        'input_text_buffer.append',
        'input_text_buffer.append',
        'session.finish',
      ]);
      expect(
        socket.sent
            .where((e) => e['type'] == 'input_text_buffer.append')
            .map((e) => e['text'])
            .join(),
        'Hello 觅音。',
      );
      expect(socket.sent.map((e) => e['event_id']).toSet().length, 5);
      expect(calls, 1);
      expect(socket.closed, true);
    },
  );

  test(
    'finish waits for accepted PCM delivery and keeps cancellation active',
    () async {
      final socket = FakeSocket();
      addTearDown(socket.dispose);
      final release = Completer<void>();
      final token = SpeechCancellationToken();
      var callbacks = 0;
      final session = await open(
        socket,
        token: token,
        onAudio: (_, _) async {
          callbacks++;
          await release.future;
        },
      );
      session.append('你好。');
      socket.emit('response.audio.delta', {
        'delta': base64Encode([1, 2]),
      });
      socket.emit('response.audio.delta', {
        'delta': base64Encode([3, 4]),
      });
      await tick();
      final done = session.finish();
      final expectation = expectLater(done, throwsA(failure('cancelled')));
      socket.emit('session.finished');
      await tick();
      token.cancel();
      await expectation;
      release.complete();
      await tick();
      expect(callbacks, 1);
    },
  );

  test('normal finish drains the final callback before completing', () async {
    final socket = FakeSocket();
    addTearDown(socket.dispose);
    final release = Completer<void>();
    final session = await open(socket, onAudio: (_, _) => release.future);
    session.append('你好。');
    socket.emit('response.audio.delta', {
      'delta': base64Encode([1, 2]),
    });
    await tick();
    var completed = false;
    final finished = session.finish().then((_) => completed = true);
    socket.emit('session.finished');
    await tick();
    expect(completed, false);
    release.complete();
    await finished;
    expect(completed, true);
  });

  test(
    'cancellation during handshake rejects promptly and closes late socket',
    () async {
      final socket = FakeSocket();
      addTearDown(socket.dispose);
      final connected = Completer<QwenTtsSocket>();
      final token = SpeechCancellationToken();
      final pending =
          QwenRealtimeTtsClient(connector: (_, _) => connected.future).open(
            config: config(),
            apiKey: 'test-tts-key',
            cancellation: token,
            onAudio: (_, _) async {},
          );
      final expectation = expectLater(pending, throwsA(failure('cancelled')));
      token.cancel();
      await expectation;
      connected.complete(socket);
      await tick();
      expect(socket.closed, true);
      expect(socket.sent, isEmpty);
    },
  );

  test('handshake timeout also closes a late successful connection', () async {
    final socket = FakeSocket();
    addTearDown(socket.dispose);
    final connected = Completer<QwenTtsSocket>();
    final pending =
        QwenRealtimeTtsClient(
          connector: (_, _) => connected.future,
          connectTimeout: const Duration(milliseconds: 20),
        ).open(
          config: config(),
          apiKey: 'test-tts-key',
          cancellation: SpeechCancellationToken(),
          onAudio: (_, _) async {},
        );
    await expectLater(pending, throwsA(failure('connect_timeout')));
    connected.complete(socket);
    await tick();
    expect(socket.closed, true);
  });

  test(
    'unsupported returned sample format fails before accepting text',
    () async {
      final socket = FakeSocket();
      addTearDown(socket.dispose);
      final pending = QwenRealtimeTtsClient(connector: (_, _) async => socket)
          .open(
            config: config(),
            apiKey: 'test-tts-key',
            cancellation: SpeechCancellationToken(),
            onAudio: (_, _) async {},
          );
      await tick();
      socket.emit('session.created');
      await tick();
      socket.emit('session.updated', {
        'session': {
          'response_format': 'pcm',
          'sample_rate': 16000,
          'mode': 'server_commit',
        },
      });
      await expectLater(pending, throwsA(failure('invalid_response')));
      expect(socket.closed, true);
    },
  );

  test(
    'service failures are sanitized and never expose echoed key or text',
    () async {
      final socket = FakeSocket();
      addTearDown(socket.dispose);
      final session = await open(socket);
      socket.emit('error', {
        'error': {'message': 'tts-only-test-key private text'},
      });
      try {
        await session.done;
        fail('must fail');
      } on QwenTtsFailure catch (error) {
        expect(error.code, 'service_error');
        expect(error.toString(), isNot(contains('tts-only-test-key')));
        expect(error.toString(), isNot(contains('private text')));
      }
    },
  );

  test(
    'an oversized PCM packet fails without silently dropping audio',
    () async {
      final socket = FakeSocket();
      addTearDown(socket.dispose);
      final release = Completer<void>();
      var callbacks = 0;
      final session = await open(
        socket,
        client: QwenRealtimeTtsClient(
          connector: (_, _) async => socket,
          maxQueuedPcmBytes: 4,
        ),
        onAudio: (_, _) async {
          callbacks++;
          await release.future;
        },
      );
      session.append('你好。');
      socket.emit('response.audio.delta', {
        'delta': base64Encode([1, 2, 3, 4, 5, 6]),
      });
      await expectLater(session.done, throwsA(failure('buffer_full')));
      release.complete();
      await tick();
      expect(callbacks, 0);
    },
  );

  test(
    'a fast audio burst pauses reads and drains normally with slow playback',
    () async {
      final socket = FakeSocket();
      addTearDown(socket.dispose);
      final release = Completer<void>();
      final output = <int>[];
      var callbacks = 0;
      final session = await open(
        socket,
        client: QwenRealtimeTtsClient(
          connector: (_, _) async => socket,
          maxQueuedPcmBytes: 12,
          idleTimeout: const Duration(milliseconds: 30),
          finishTimeout: const Duration(milliseconds: 50),
          playbackTimeout: const Duration(seconds: 1),
        ),
        onAudio: (bytes, _) async {
          callbacks++;
          if (callbacks == 1) await release.future;
          await Future<void>.delayed(const Duration(milliseconds: 5));
          output.addAll(bytes);
        },
      );
      session.append('你好。');
      for (var i = 0; i < 6; i++) {
        socket.emit('response.audio.delta', {
          'delta': base64Encode([i, i, i, i]),
        });
      }
      await tick();
      expect(socket.pauses, 1);
      final finished = session.finish();
      socket.emit('session.finished');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(socket.closed, false);
      release.complete();
      await finished;
      expect(callbacks, 6);
      expect(output, [
        for (var i = 0; i < 6; i++) ...[i, i, i, i],
      ]);
      // Delivery of all six chunks proves reads resumed. A controller's
      // onResume notification may be coalesced with another pause or cancel.
      expect(socket.pauses, greaterThan(0));
    },
  );

  test(
    'cancelling a paused stream never resumes it or plays queued chunks',
    () async {
      final socket = FakeSocket();
      addTearDown(socket.dispose);
      final release = Completer<void>();
      final token = SpeechCancellationToken();
      var callbacks = 0;
      final session = await open(
        socket,
        token: token,
        client: QwenRealtimeTtsClient(
          connector: (_, _) async => socket,
          maxQueuedPcmBytes: 12,
        ),
        onAudio: (_, _) async {
          callbacks++;
          await release.future;
        },
      );
      session.append('你好。');
      for (var i = 0; i < 6; i++) {
        socket.emit('response.audio.delta', {
          'delta': base64Encode([1, 2, 3, 4]),
        });
      }
      await tick();
      expect(socket.pauses, 1);
      token.cancel();
      await expectLater(session.done, throwsA(failure('cancelled')));
      release.complete();
      await tick();
      expect(socket.resumes, 0);
      expect(callbacks, 1);
    },
  );

  test('finish deadline is reset by ongoing server progress', () async {
    final socket = FakeSocket();
    addTearDown(socket.dispose);
    var callbacks = 0;
    final session = await open(
      socket,
      client: QwenRealtimeTtsClient(
        connector: (_, _) async => socket,
        finishTimeout: const Duration(milliseconds: 100),
      ),
      onAudio: (_, _) async {
        callbacks++;
      },
    );
    session.append('你好。');
    final finished = session.finish();
    for (var i = 0; i < 4; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 40));
      socket.emit('response.audio.delta', {
        'delta': base64Encode([1, 2]),
      });
    }
    socket.emit('session.finished');
    await finished;
    expect(callbacks, 4);
  });

  test('invalid base64 and odd tail are rejected instead of dropped', () async {
    for (final bad in [
      '%%%',
      base64Encode([1]),
    ]) {
      final socket = FakeSocket();
      addTearDown(socket.dispose);
      final session = await open(socket);
      socket.emit('response.audio.delta', {'delta': bad});
      socket.emit('response.audio.done');
      await expectLater(session.done, throwsA(failure('invalid_response')));
    }
  });

  test(
    'text bounds terminate instead of silently truncating a reply',
    () async {
      final socket = FakeSocket();
      addTearDown(socket.dispose);
      final session = await open(socket);
      expect(() => session.append('a' * 2049), throwsA(failure('text_limit')));
      await expectLater(session.done, throwsA(failure('text_limit')));
      expect(
        socket.sent.where((e) => e['type'] == 'input_text_buffer.append'),
        isEmpty,
      );
    },
  );

  test(
    'unexpected close, missing audio and incomplete response fail explicitly',
    () async {
      for (final scenario in ['close', 'empty', 'incomplete']) {
        final socket = FakeSocket();
        addTearDown(socket.dispose);
        final session = await open(socket);
        session.append('你好。');
        if (scenario == 'close') {
          await socket.input.close();
        }
        if (scenario == 'empty') {
          unawaited(session.finish().catchError((Object _) {}));
          socket.emit('session.finished');
        }
        if (scenario == 'incomplete') {
          socket.emit('response.done', {
            'response': {'status': 'incomplete'},
          });
        }
        await expectLater(
          session.done,
          throwsA(
            failure(
              scenario == 'close'
                  ? 'connection_closed'
                  : scenario == 'empty'
                  ? 'invalid_response'
                  : 'incomplete_audio',
            ),
          ),
        );
      }
    },
  );

  test(
    'idle, finish and stalled playback deadlines terminate the session',
    () async {
      for (final scenario in ['idle', 'finish', 'playback']) {
        final socket = FakeSocket();
        addTearDown(socket.dispose);
        final stalled = Completer<void>();
        final session = await open(
          socket,
          client: QwenRealtimeTtsClient(
            connector: (_, _) async => socket,
            idleTimeout: Duration(milliseconds: scenario == 'idle' ? 20 : 500),
            finishTimeout: const Duration(milliseconds: 20),
            playbackTimeout: const Duration(milliseconds: 20),
          ),
          onAudio: (_, _) => stalled.future,
        );
        session.append('你好。');
        if (scenario == 'finish')
          unawaited(session.finish().catchError((Object _) {}));
        if (scenario == 'playback') {
          socket.emit('response.audio.delta', {
            'delta': base64Encode([1, 2]),
          });
        }
        await expectLater(
          session.done,
          throwsA(
            failure(
              scenario == 'idle'
                  ? 'idle_timeout'
                  : scenario == 'finish'
                  ? 'finish_timeout'
                  : 'playback_failed',
            ),
          ),
        );
        stalled.complete();
        expect(socket.closed, true);
      }
    },
  );
}
