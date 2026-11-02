import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// This adapter targets Qwen-TTS-Realtime, not the distinct Qwen-Audio-TTS /
/// CosyVoice task protocol. Official references checked on 2026-11-02:
/// https://help.aliyun.com/en/model-studio/interactive-process-of-qwen-tts-realtime-synthesis
/// https://help.aliyun.com/en/model-studio/qwen-tts-realtime-client-events
/// https://help.aliyun.com/en/model-studio/qwen-tts-realtime-server-events
enum QwenTtsRegion { beijing, singapore }

final class QwenRealtimeTtsConfig {
  QwenRealtimeTtsConfig({
    required this.region,
    required this.model,
    required this.voice,
    this.language = 'Auto',
  }) {
    // Keep protocol families explicit. Do not accept an arbitrary chat model ID.
    if (!RegExp(r'^qwen3-tts-flash-realtime(?:-\d{4}-\d{2}-\d{2})?$')
        .hasMatch(model)) {
      throw const QwenTtsFailure('invalid_model', '请选择支持的实时语音模型。');
    }
    if (!RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(voice) ||
        !languages.contains(language)) {
      throw const QwenTtsFailure('invalid_voice', '朗读音色或语言无效。');
    }
  }

  final QwenTtsRegion region;
  final String model, voice, language;
  static const sampleRate = 24000;
  static const languages = {
    'Auto',
    'Chinese',
    'English',
    'German',
    'Italian',
    'Portuguese',
    'Spanish',
    'Japanese',
    'Korean',
    'French',
    'Russian',
  };

  Uri get endpoint => Uri(
    scheme: 'wss',
    host: region == QwenTtsRegion.beijing
        ? 'dashscope.aliyuncs.com'
        : 'dashscope-intl.aliyuncs.com',
    path: '/api-ws/v1/realtime',
    queryParameters: {'model': model},
  );
}

/// Safe for UI/logging. Never wrap a raw handshake exception or server message:
/// those may contain headers, submitted text, or echoed credential values.
final class QwenTtsFailure implements Exception {
  const QwenTtsFailure(this.code, this.message);
  final String code, message;
  @override
  String toString() => 'QwenTtsFailure($code): $message';
}

/// The caller owns a token for each answer, independent of the chat provider.
/// Cancel it on stop, navigation, app pause, or a service/configuration change.
final class SpeechCancellationToken {
  bool _cancelled = false;
  final Set<void Function()> _listeners = {};
  bool get isCancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final listener in List.of(_listeners)) listener();
    _listeners.clear();
  }

  void Function() listen(void Function() listener) {
    if (_cancelled) {
      listener();
      return () {};
    }
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }
}

/// Narrow transport seam for deterministic local tests; production uses only
/// the fixed official WSS endpoints derived by [QwenRealtimeTtsConfig].
abstract interface class QwenTtsSocket {
  Stream<Object?> get messages;
  void send(String event);
  Future<void> close();
}

typedef QwenTtsConnector = Future<QwenTtsSocket> Function(
  Uri endpoint,
  Map<String, String> headers,
);

final class _IoQwenTtsSocket implements QwenTtsSocket {
  _IoQwenTtsSocket(this.socket);
  final WebSocket socket;
  @override
  Stream<Object?> get messages => socket;
  @override
  void send(String event) => socket.add(event);
  @override
  Future<void> close() async {
    await socket.close(WebSocketStatus.normalClosure);
  }
}

/// Opens one answer-long synthesis session. It does not load or infer a key,
/// persist configuration, request consent, or select a chat model. The native
/// caller must gate cloud speech consent before invoking this client.
final class QwenRealtimeTtsClient {
  QwenRealtimeTtsClient({
    QwenTtsConnector? connector,
    this.connectTimeout = const Duration(seconds: 10),
    this.idleTimeout = const Duration(seconds: 30),
    this.finishTimeout = const Duration(seconds: 45),
    this.playbackTimeout = const Duration(seconds: 15),
    this.sessionTimeout = const Duration(minutes: 5),
    this.maxQueuedPcmBytes = 512 * 1024,
  }) : _connector = connector ?? _connect {
    if ([
          connectTimeout,
          idleTimeout,
          finishTimeout,
          playbackTimeout,
          sessionTimeout,
        ].any((value) => value <= Duration.zero) ||
        maxQueuedPcmBytes < 2) {
      throw ArgumentError('Invalid speech timeout or buffer bound.');
    }
  }

  final QwenTtsConnector _connector;
  final Duration connectTimeout,
      idleTimeout,
      finishTimeout,
      playbackTimeout,
      sessionTimeout;
  final int maxQueuedPcmBytes;

  static Future<QwenTtsSocket> _connect(
    Uri endpoint,
    Map<String, String> headers,
  ) async {
    final socket = await WebSocket.connect(
      endpoint.toString(),
      headers: headers,
    );
    socket.pingInterval = const Duration(seconds: 15);
    return _IoQwenTtsSocket(socket);
  }

  Future<QwenRealtimeTtsSession> open({
    required QwenRealtimeTtsConfig config,
    required String apiKey,
    required SpeechCancellationToken cancellation,
    required Future<void> Function(Uint8List pcm, int sampleRate) onAudio,
  }) async {
    if (cancellation.isCancelled) throw _cancelled;
    if (!RegExp(r'^[\x21-\x7e]{8,512}$').hasMatch(apiKey)) {
      throw const QwenTtsFailure('invalid_key', '请配置这个语音服务的专用密钥。');
    }
    final session = QwenRealtimeTtsSession._(
      this,
      config,
      cancellation,
      onAudio,
    );
    session._begin(apiKey);
    await session._ready.future;
    return session;
  }

  static const _cancelled = QwenTtsFailure('cancelled', '语音播放已停止。');
}

final class QwenRealtimeTtsSession {
  QwenRealtimeTtsSession._(
    this._client,
    this.config,
    this._token,
    this._onAudio,
  ) {
    // Consumers may only await ready, or only await done after open succeeds.
    // Observe both early without changing the failure returned to their awaits.
    unawaited(_ready.future.then<void>((_) {}, onError: (Object _) {}));
    unawaited(_done.future.then<void>((_) {}, onError: (Object _) {}));
  }

  final QwenRealtimeTtsClient _client;
  final QwenRealtimeTtsConfig config;
  final SpeechCancellationToken _token;
  final Future<void> Function(Uint8List pcm, int sampleRate) _onAudio;
  final _ready = Completer<void>(), _done = Completer<void>();
  QwenTtsSocket? _socket;
  StreamSubscription<Object?>? _subscription;
  void Function()? _unlisten;
  Timer? _idleTimer, _finishTimer, _sessionTimer, _connectTimer;
  Future<void> _audioTail = Future<void>.value();
  bool _configured = false,
      _updateSent = false,
      _finishing = false,
      _terminal = false,
      _aborted = false,
      _readPaused = false;
  int _eventId = 0, _textChars = 0, _queuedPcmBytes = 0, _audioBytes = 0;
  int? _oddByte;
  static const maxTextChars = 32000;
  static const maxTextChunkChars = 2048;
  static const maxEventChars = 128 * 1024;
  static const maxPcmChunkBytes = 64 * 1024;
  static const maxSessionPcmBytes = 32 * 1024 * 1024;

  /// Completes after session.finished and all accepted PCM callbacks have drained.
  /// It means synthesis delivery completed, not that the speaker has finished.
  Future<void> get done => _done.future;

  void _begin(String apiKey) {
    _unlisten = _token.listen(cancel);
    if (_terminal) return;
    _connectTimer = Timer(
      _client.connectTimeout,
      () => _fail(const QwenTtsFailure('connect_timeout', '语音服务连接超时，请重试。')),
    );
    _sessionTimer = Timer(
      _client.sessionTimeout,
      () => _fail(const QwenTtsFailure('session_timeout', '本次语音会话已超时。')),
    );
    unawaited(() async {
      try {
        final socket = await _client._connector(config.endpoint, {
          'Authorization': 'Bearer $apiKey',
        });
        if (_terminal) {
          unawaited(_quietClose(socket));
          return;
        }
        _socket = socket;
        _subscription = socket.messages.listen(
          _message,
          onError: (Object _) => _fail(
            const QwenTtsFailure('connection_failed', '语音服务连接中断，请重新朗读。'),
          ),
          onDone: () {
            if (!_terminal)
              _fail(
                const QwenTtsFailure('connection_closed', '语音服务提前结束，请重新朗读。'),
              );
          },
        );
      } catch (_) {
        _fail(const QwenTtsFailure('connection_failed', '无法连接语音服务，请检查配置。'));
      }
    }());
  }

  /// Preserves every text delta, including spaces between English words. The
  /// caller may send a larger phrase in multiple bounded appends, on one socket.
  void append(String text) {
    _requireInput();
    if (text.isEmpty) return;
    if (text.length > maxTextChunkChars ||
        _textChars + text.length > maxTextChars) {
      final error = const QwenTtsFailure('text_limit', '本次语音内容过长，请分次朗读。');
      _fail(error);
      throw error;
    }
    _textChars += text.length;
    _send('input_text_buffer.append', {'text': text});
    _touch();
  }

  /// In server_commit mode the server performs phrase boundaries. Finishing
  /// flushes its remaining text; no response.create or empty commit is sent.
  Future<void> finish() {
    if (_finishing || _terminal) return done;
    _requireInput();
    _finishing = true;
    _send('session.finish');
    _touch();
    return done;
  }

  void cancel() => _fail(QwenRealtimeTtsClient._cancelled);

  void _requireInput() {
    if (_token.isCancelled || _aborted) throw QwenRealtimeTtsClient._cancelled;
    if (!_configured || _terminal || _finishing) {
      throw const QwenTtsFailure('invalid_state', '语音会话尚未就绪或已结束。');
    }
  }

  void _send(String type, [Map<String, Object?> payload = const {}]) {
    if (_terminal) return;
    try {
      _socket!.send(
        jsonEncode({
          'event_id': 'miyin_${++_eventId}',
          'type': type,
          ...payload,
        }),
      );
    } catch (_) {
      _fail(const QwenTtsFailure('connection_failed', '语音服务连接中断，请重新朗读。'));
    }
  }

  void _message(Object? raw) {
    if (_terminal) return;
    try {
      if (raw is! String || raw.length > maxEventChars)
        throw const FormatException();
      final event = jsonDecode(raw);
      if (event is! Map || event['type'] is! String)
        throw const FormatException();
      final type = event['type'];
      if (type == 'error') {
        _fail(const QwenTtsFailure('service_error', '语音服务返回错误，请检查模型、音色及服务额度。'));
        return;
      }
      if (type == 'session.created') {
        if (_updateSent) throw const FormatException();
        _updateSent = true;
        _send('session.update', {
          'session': {
            'mode': 'server_commit',
            'voice': config.voice,
            'language_type': config.language,
            'response_format': 'pcm',
            'sample_rate': QwenRealtimeTtsConfig.sampleRate,
          },
        });
      } else if (type == 'session.updated') {
        final session = event['session'];
        if (!_updateSent ||
            _configured ||
            session is! Map ||
            session['response_format'] != 'pcm' ||
            session['sample_rate'] != QwenRealtimeTtsConfig.sampleRate ||
            session['mode'] != 'server_commit')
          throw const FormatException();
        _configured = true;
        _connectTimer?.cancel();
        _ready.complete();
      } else if (type == 'response.audio.delta') {
        if (!_configured) throw const FormatException();
        _audio(event['delta']);
      } else if (type == 'response.audio.done') {
        if (_oddByte != null) throw const FormatException();
      } else if (type == 'response.done') {
        final response = event['response'];
        if (response is! Map || response['status'] != 'completed') {
          _fail(const QwenTtsFailure('incomplete_audio', '本次语音生成未完成，请重新朗读。'));
          return;
        }
      } else if (type == 'session.finished') {
        if (!_configured ||
            !_finishing ||
            _oddByte != null ||
            (_textChars > 0 && _audioBytes == 0))
          throw const FormatException();
        _complete();
        return;
      }
      if (_configured) _touch();
    } catch (_) {
      _fail(const QwenTtsFailure('invalid_response', '语音服务返回的音频格式无效。'));
    }
  }

  void _audio(Object? delta) {
    if (delta is! String ||
        delta.length > (maxPcmChunkBytes + 2) ~/ 3 * 4 ||
        !RegExp(r'^[A-Za-z0-9+/]*={0,2}$').hasMatch(delta)) {
      throw const FormatException();
    }
    final decoded = base64Decode(delta);
    if (decoded.isEmpty) return;
    _audioBytes += decoded.length;
    if (decoded.length > maxPcmChunkBytes || _audioBytes > maxSessionPcmBytes) {
      _fail(const QwenTtsFailure('audio_limit', '本次语音音频过长。'));
      return;
    }
    final bytes = Uint8List(decoded.length + (_oddByte == null ? 0 : 1));
    final start = _oddByte == null ? 0 : 1;
    if (start == 1) bytes[0] = _oddByte!;
    bytes.setRange(start, bytes.length, decoded);
    _oddByte = bytes.length.isOdd ? bytes.last : null;
    final aligned = Uint8List.sublistView(bytes, 0, bytes.length & ~1);
    if (aligned.isEmpty) return;
    if (_queuedPcmBytes + aligned.length > _client.maxQueuedPcmBytes) {
      _fail(const QwenTtsFailure('buffer_full', '语音播放缓冲已满，请重新朗读。'));
      return;
    }
    _queuedPcmBytes += aligned.length;
    // Cloud synthesis may run many times faster than the speaker. Apply stream
    // backpressure instead of rejecting an ordinary long answer at 512 KiB.
    if (_queuedPcmBytes >= _client.maxQueuedPcmBytes ~/ 2 && !_readPaused) {
      _readPaused = true;
      _subscription?.pause();
      _idleTimer?.cancel();
      _finishTimer?.cancel();
    }
    _audioTail = _audioTail.then((_) async {
      try {
        if (_aborted || _token.isCancelled) return;
        await _onAudio(
          aligned,
          QwenRealtimeTtsConfig.sampleRate,
        ).timeout(_client.playbackTimeout);
      } catch (_) {
        _fail(const QwenTtsFailure('playback_failed', '音频播放未能继续，请重新朗读。'));
      } finally {
        _queuedPcmBytes -= aligned.length;
        if (_readPaused &&
            !_terminal &&
            _queuedPcmBytes <= _client.maxQueuedPcmBytes ~/ 4) {
          _readPaused = false;
          _subscription?.resume();
        }
        // Playback consumption is progress too. A long but advancing answer
        // must not hit an absolute finish deadline or an idle-network timeout
        // while the read side is deliberately paused.
        _touch();
      }
    });
  }

  void _touch() {
    if (_terminal) return;
    _idleTimer?.cancel();
    _finishTimer?.cancel();
    if (_readPaused) return;
    if (_finishing) {
      _finishTimer = Timer(
        _client.finishTimeout,
        () => _fail(const QwenTtsFailure('finish_timeout', '语音服务未能完成朗读，请重试。')),
      );
    } else {
      _idleTimer = Timer(
        _client.idleTimeout,
        () => _fail(const QwenTtsFailure('idle_timeout', '语音服务等待超时，请重试。')),
      );
    }
  }

  void _complete() {
    _terminal = true;
    _cleanup(keepCancellation: true);
    unawaited(
      _audioTail.then((_) {
        _unlisten?.call();
        _sessionTimer?.cancel();
        if (_token.isCancelled && !_done.isCompleted) {
          _fail(QwenRealtimeTtsClient._cancelled);
          return;
        }
        if (!_done.isCompleted) _done.complete();
      }),
    );
  }

  void _fail(QwenTtsFailure error) {
    if (_aborted || _done.isCompleted) return;
    _terminal = true;
    _aborted = true;
    _cleanup();
    if (!_ready.isCompleted) _ready.completeError(error);
    if (!_done.isCompleted) _done.completeError(error);
  }

  void _cleanup({bool keepCancellation = false}) {
    _connectTimer?.cancel();
    _idleTimer?.cancel();
    _finishTimer?.cancel();
    if (!keepCancellation) _sessionTimer?.cancel();
    if (!keepCancellation) _unlisten?.call();
    unawaited(_subscription?.cancel());
    final socket = _socket;
    if (socket != null) unawaited(_quietClose(socket));
  }

  static Future<void> _quietClose(QwenTtsSocket socket) async {
    try {
      await socket.close().timeout(const Duration(seconds: 2));
    } catch (_) {}
  }
}
