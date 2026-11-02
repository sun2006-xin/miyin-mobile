import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:miyin_app/core/speech/qwen_realtime_tts.dart';
import 'package:miyin_app/features/miyin/voice_service_host.dart';

final class MemorySecrets implements VoiceSecretStore {
  String? value;
  Completer<void>? pendingWrite;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String next) async {
    await pendingWrite?.future;
    value = next;
  }
}

final class FakeSocket implements QwenTtsSocket {
  FakeSocket() {
    input = StreamController<Object?>(
      onListen: () {
        emit({'type': 'session.created'});
      },
    );
  }
  late final StreamController<Object?> input;
  final sent = <Map<String, Object?>>[];
  bool closed = false;
  void emit(Map<String, Object?> event) => input.add(jsonEncode(event));
  @override
  Stream<Object?> get messages => input.stream;
  @override
  void send(String raw) {
    final event = Map<String, Object?>.from(jsonDecode(raw) as Map);
    sent.add(event);
    if (event['type'] == 'session.update') {
      emit({'type': 'session.updated', 'session': event['session']});
    }
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

final class Fixture {
  Fixture({QwenTtsConnector? connector}) {
    host = VoiceServiceHost(
      secretStore: secrets,
      client: QwenRealtimeTtsClient(
        connector:
            connector ??
            (uri, headers) async {
              connections++;
              endpoints.add(uri);
              socket = FakeSocket();
              return socket!;
            },
      ),
      invokePlayback: (method, args) async {
        calls.add(method);
        if (method == 'appendAudioStream') audio.add(args['pcm'] as Uint8List);
        return {'status': method == 'beginAudioStream' ? 'ready' : 'speaking'};
      },
      onEvent: (event) async {
        events.add(event);
      },
    );
  }
  final secrets = MemorySecrets();
  late final VoiceServiceHost host;
  FakeSocket? socket;
  final calls = <String>[];
  final events = <Map<String, Object?>>[];
  final endpoints = <Uri>[];
  final audio = BytesBuilder();
  int connections = 0;
  Future<void> configure() async {
    await host.saveSettings({'mode': 'qwen', 'allowCloud': true});
    await host.saveCredential('test-voice-secret-123');
  }
}

Future<void> settle() async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  test(
    'local default and missing consent or key never open a connection',
    () async {
      final f = Fixture();
      addTearDown(f.host.dispose);
      await f.host.load();
      expect(f.host.status, containsPair('mode', 'local'));
      expect(f.host.status, containsPair('allowCloud', false));
      await expectLater(
        f.host.open('answer'),
        throwsA(isA<VoiceServiceFailure>()),
      );
      await f.host.saveSettings({'mode': 'qwen'});
      await f.host.saveCredential('test-voice-secret-123');
      await expectLater(
        f.host.open('answer'),
        throwsA(isA<VoiceServiceFailure>()),
      );
      await f.host.saveSettings({'allowCloud': true, 'region': 'singapore'});
      await expectLater(
        f.host.open('answer'),
        throwsA(isA<VoiceServiceFailure>()),
      );
      expect(f.connections, 0);
      expect(f.calls, isEmpty);
    },
  );

  test(
    'voice keys stay in their region and never enter public status',
    () async {
      final f = Fixture();
      addTearDown(f.host.dispose);
      await f.configure();
      expect(f.host.status['hasKey'], true);
      expect(jsonEncode(f.host.status), isNot(contains('test-voice-secret')));
      await f.host.saveSettings({'region': 'singapore'});
      expect(f.host.status['hasKey'], false);
      await f.host.saveCredential('singapore-secret-123');
      await f.host.saveSettings({'region': 'beijing'});
      expect(f.host.status['hasKey'], true);
      final restored = VoiceServiceHost(
        secretStore: f.secrets,
        invokePlayback: (_, _) async => null,
        onEvent: (_) async {},
      );
      addTearDown(restored.dispose);
      await restored.load();
      expect(restored.status, f.host.status);
      await f.host.saveCredential('');
      expect(f.host.status['hasKey'], false);
      final raw = jsonDecode(f.secrets.value!) as Map;
      expect((raw['credentials'] as Map)['singapore'], 'singapore-secret-123');
    },
  );

  test('one answer shares one socket; network finish waits for native playback completion', () async {
    final f = Fixture();
    addTearDown(f.host.dispose);
    await f.configure();
    expect((await f.host.open('answer'))['status'], 'ready');
    await f.host.append('answer', '你好，');
    await f.host.append('answer', '继续说话。');
    expect(f.connections, 1);
    f.socket!.emit({
      'type': 'response.audio.delta',
      'delta': base64Encode(Uint8List(32)),
    });
    await settle();
    expect(
      f.calls,
      containsAllInOrder(['beginAudioStream', 'appendAudioStream']),
    );
    expect((await f.host.finish('answer'))['status'], 'finishing');
    f.socket!.emit({'type': 'session.finished'});
    await settle();
    expect(f.calls.last, 'finishAudioStream');
    expect(f.events, isEmpty); // Native AudioTrack owns tts_done.
    final before = f.calls.length;
    f.host.onNativeEvent({'type': 'tts_done', 'sessionId': 'answer'});
    await f.host.cancel();
    expect(f.calls.length, before); // A stale cancel cannot stop another sound.
  });

  test('cancel drops late PCM and does not reopen a stopped player', () async {
    final f = Fixture();
    addTearDown(f.host.dispose);
    await f.configure();
    await f.host.open('answer');
    await f.host.cancel();
    f.socket!.emit({
      'type': 'response.audio.delta',
      'delta': base64Encode(Uint8List(32)),
    });
    await settle();
    expect(f.calls, ['abortAudioStream']);
    expect(f.events, isEmpty);
    expect(f.socket!.closed, true);
  });

  test(
    'cancel during handshake closes the late socket without native playback',
    () async {
      final connection = Completer<QwenTtsSocket>();
      final f = Fixture(connector: (_, _) => connection.future);
      addTearDown(f.host.dispose);
      await f.configure();
      final opening = f.host.open('pending');
      await settle();
      await f.host.cancel();
      expect((await opening)['status'], 'cancelled');
      final late = FakeSocket();
      connection.complete(late);
      await settle();
      expect(late.closed, true);
      expect(f.calls, ['abortAudioStream']);
    },
  );

  test(
    'changing settings cancels old synthesis and cannot play its callbacks',
    () async {
      final f = Fixture();
      addTearDown(f.host.dispose);
      await f.configure();
      await f.host.open('old');
      await f.host.saveSettings({'voice': 'Serena'});
      f.socket!.emit({
        'type': 'response.audio.delta',
        'delta': base64Encode(Uint8List(32)),
      });
      await settle();
      expect(f.calls, ['abortAudioStream']);
      expect(f.host.status['voice'], 'Serena');
      await expectLater(
        f.host.append('old', '迟到文字'),
        throwsA(isA<VoiceServiceFailure>()),
      );
    },
  );

  test(
    'server errors become safe UI errors without echoing key or message text',
    () async {
      final f = Fixture();
      addTearDown(f.host.dispose);
      await f.configure();
      await f.host.open('failed');
      f.socket!.emit({
        'type': 'error',
        'message': 'test-voice-secret-123 private sentence',
      });
      await settle();
      expect(f.events.single['type'], 'tts_error');
      expect(jsonEncode(f.events), isNot(contains('test-voice-secret')));
      expect(jsonEncode(f.events), isNot(contains('private sentence')));
    },
  );

  test(
    'cancel with no owned online session leaves local playback alone',
    () async {
      final f = Fixture();
      await f.host.cancel();
      await f.host.dispose();
      expect(f.calls, isEmpty);
    },
  );

  test('open waits for pending consent revocation before considering network access', () async {
    final f = Fixture();
    addTearDown(f.host.dispose);
    await f.configure();
    f.secrets.pendingWrite = Completer<void>();
    final saving = f.host.saveSettings({'allowCloud': false});
    await settle();
    final opening = f.host.open('during-save');
    final denied = expectLater(opening, throwsA(isA<VoiceServiceFailure>()));
    await settle();
    expect(f.connections, 0);
    f.secrets.pendingWrite!.complete();
    await saving;
    await denied;
    expect(f.connections, 0);
  });

  test(
    'large appends preserve emoji code points at chunk boundaries',
    () async {
      final f = Fixture();
      addTearDown(f.host.dispose);
      await f.configure();
      await f.host.open('unicode');
      final text = '${'中' * 1023}😀继续';
      await f.host.append('unicode', text);
      final parts = f.socket!.sent
          .where((event) => event['type'] == 'input_text_buffer.append')
          .map((event) => event['text'] as String)
          .toList();
      expect(parts.join(), text);
      expect(parts.first.endsWith('😀'), true);
    },
  );

  test('unreadable storage is preserved until explicit voice reset', () async {
    final f = Fixture();
    addTearDown(f.host.dispose);
    f.secrets.value = 'unreadable';
    await expectLater(f.host.load(), throwsA(isA<VoiceServiceFailure>()));
    expect(f.secrets.value, 'unreadable');
    await f.host.resetConfiguration();
    await f.host.load();
    expect(f.host.status['mode'], 'local');
    expect(f.host.status['allowCloud'], false);
    expect(f.host.status['hasKey'], false);
  });

  test('selected AI speech language reaches the voice service and unsupported languages never connect', () async {
    final f = Fixture();
    addTearDown(f.host.dispose);
    await f.configure();
    await expectLater(
      f.host.open('unsupported', languageTag: 'ar'),
      throwsA(isA<VoiceServiceFailure>()),
    );
    expect(f.connections, 0);
    await f.host.open('russian', languageTag: 'ru');
    final update = f.socket!.sent.firstWhere(
      (event) => event['type'] == 'session.update',
    );
    expect((update['session'] as Map)['language_type'], 'Russian');
    await f.host.cancel();
    await f.host.open('automatic');
    final automatic = f.socket!.sent.firstWhere(
      (event) => event['type'] == 'session.update',
    );
    expect((automatic['session'] as Map)['language_type'], 'Auto');
  });
}
