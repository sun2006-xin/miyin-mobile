import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

import '../../core/speech/qwen_realtime_tts.dart';
import 'streaming_speech_playback.dart';

/// UI-safe errors. Never expose handshake exceptions, credentials or text.
final class VoiceServiceFailure implements Exception {
  const VoiceServiceFailure(this.code, this.message);
  final String code, message;
  @override
  String toString() => 'VoiceServiceFailure($code): $message';
}

abstract interface class VoiceSecretStore {
  Future<String?> read();
  Future<void> write(String value);
}

final class _NativeVoiceSecretStore implements VoiceSecretStore {
  static const _channel = MethodChannel('com.miyin.app/voice-secrets');
  @override
  Future<String?> read() => _channel.invokeMethod<String>('read');
  @override
  Future<void> write(String value) =>
      _channel.invokeMethod<void>('write', value);
}

/// Owns a voice service independently of the selected chat model. Public
/// settings may cross the WebView bridge; credentials only use the native store.
final class VoiceServiceHost {
  VoiceServiceHost({
    required this.invokePlayback,
    required this.onEvent,
    VoiceSecretStore? secretStore,
    QwenRealtimeTtsClient? client,
  }) : _store = secretStore ?? _NativeVoiceSecretStore(),
       _client = client ?? QwenRealtimeTtsClient();

  final Future<Object?> Function(String, Map<String, Object?>) invokePlayback;
  final Future<void> Function(Map<String, Object?>) onEvent;
  final VoiceSecretStore _store;
  final QwenRealtimeTtsClient _client;
  Future<void>? _loading;
  Future<void> _configurationTail = Future<void>.value();
  String _mode = 'local', _region = 'beijing';
  String _model = 'qwen3-tts-flash-realtime', _voice = 'Cherry';
  bool _allowCloud = false, _disposed = false;
  final Map<String, String> _credentials = {};
  int _generation = 0;
  _VoiceAnswer? _active;

  static const regions = ['beijing', 'singapore'];
  static const voices = ['Cherry', 'Serena', 'Ethan', 'Chelsie'];
  static const languages = <String, String>{
    'auto': 'Auto',
    'zh-Hans': 'Chinese',
    'en': 'English',
    'ru': 'Russian',
    'fr': 'French',
    'de': 'German',
    'es': 'Spanish',
    'it': 'Italian',
    'pt': 'Portuguese',
    'ja': 'Japanese',
    'ko': 'Korean',
  };

  Map<String, Object?> get status => {
    'mode': _mode,
    'allowCloud': _allowCloud,
    'region': _region,
    'model': _model,
    'voice': _voice,
    'hasKey': _credentials[_region]?.isNotEmpty == true,
  };

  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    try {
      final saved = await _store.read();
      if (saved == null || saved.isEmpty) return;
      final raw = jsonDecode(saved);
      if (raw is! Map || raw['version'] != 1) throw const FormatException();
      final settings = _validatedSettings(Map<String, Object?>.from(raw));
      final credentials = raw['credentials'];
      if (credentials is! Map) throw const FormatException();
      final restored = <String, String>{};
      for (final region in regions) {
        final key = credentials[region];
        if (key != null) {
          if (key is! String || !_validKey(key)) throw const FormatException();
          restored[region] = key;
        }
      }
      _apply(settings);
      _credentials.addAll(restored);
    } catch (_) {
      throw const VoiceServiceFailure('voice_storage', '无法读取语音服务配置，请重新配置。');
    }
  }

  static bool _validKey(String key) =>
      RegExp(r'^[\x21-\x7e]{8,512}$').hasMatch(key);

  Map<String, Object?> _validatedSettings(Map<String, Object?> raw) {
    final mode = raw['mode'] ?? _mode;
    final region = raw['region'] ?? _region;
    final model = raw['model'] ?? _model;
    final voice = raw['voice'] ?? _voice;
    final allowCloud = raw['allowCloud'] ?? _allowCloud;
    if (!['local', 'qwen'].contains(mode) ||
        !regions.contains(region) ||
        model is! String ||
        !RegExp(r'^qwen3-tts-flash-realtime(?:-\d{4}-\d{2}-\d{2})?$')
            .hasMatch(model) ||
        !voices.contains(voice) ||
        allowCloud is! bool) {
      throw const VoiceServiceFailure('voice_settings', '请选择有效的语音服务、地域和音色。');
    }
    return {
      'mode': mode,
      'region': region,
      'model': model,
      'voice': voice,
      'allowCloud': allowCloud,
    };
  }

  void _apply(Map<String, Object?> settings) {
    _mode = settings['mode'] as String;
    _region = settings['region'] as String;
    _model = settings['model'] as String;
    _voice = settings['voice'] as String;
    _allowCloud = settings['allowCloud'] as bool;
  }

  Future<T> _serialized<T>(Future<T> Function() action) async {
    final previous = _configurationTail;
    final release = Completer<void>();
    _configurationTail = release.future;
    await previous;
    try {
      return await action();
    } finally {
      release.complete();
    }
  }

  Future<void> _save(
    Map<String, Object?> settings,
    Map<String, String> keys,
  ) async {
    try {
      await _store.write(
        jsonEncode({'version': 1, ...settings, 'credentials': keys}),
      );
    } catch (_) {
      throw const VoiceServiceFailure('voice_storage', '语音服务配置未能保存，请重试。');
    }
  }

  Future<Map<String, Object?>> saveSettings(Map<String, Object?> settings) =>
      _serialized(() async {
        await load();
        _checkDisposed();
        final next = _validatedSettings(settings);
        await cancel();
        await _save(next, _credentials);
        _apply(next);
        return status;
      });

  /// The key belongs to the current voice region, never to a chat provider.
  Future<void> saveCredential(String key) => _serialized(() async {
    await load();
    _checkDisposed();
    key = key.trim();
    if (key.isNotEmpty && !_validKey(key)) {
      throw const VoiceServiceFailure('voice_key', '请填写有效的语音服务 API Key。');
    }
    await cancel();
    final next = Map<String, String>.of(_credentials);
    if (key.isEmpty) {
      next.remove(_region);
    } else {
      next[_region] = key;
    }
    await _save(status, next);
    _credentials
      ..clear()
      ..addAll(next);
  });

  /// Explicit recovery for an unreadable device credential store. Call only
  /// after the user chooses to reset voice configuration; never on load failure.
  Future<Map<String, Object?>> resetConfiguration() => _serialized(() async {
    _checkDisposed();
    await cancel();
    const defaults = <String, Object?>{
      'mode': 'local',
      'allowCloud': false,
      'region': 'beijing',
      'model': 'qwen3-tts-flash-realtime',
      'voice': 'Cherry',
    };
    await _save(defaults, const {});
    _apply(defaults);
    _credentials.clear();
    _loading = Future<void>.value();
    return status;
  });

  void _checkDisposed() {
    if (_disposed) throw const VoiceServiceFailure('voice_closed', '语音服务已关闭。');
  }

  static void _validateId(String id) {
    if (!RegExp(r'^[A-Za-z0-9_.-]{1,128}$').hasMatch(id)) {
      throw const VoiceServiceFailure('voice_session', '语音会话标识无效。');
    }
  }

  bool _owns(_VoiceAnswer answer) =>
      !_disposed &&
      identical(_active, answer) &&
      answer.generation == _generation;

  Future<Map<String, Object?>> open(
    String sessionId, {
    String languageTag = 'auto',
  }) async {
    _validateId(sessionId);
    final language = languages[languageTag];
    if (language == null) {
      throw const VoiceServiceFailure(
        'voice_language',
        '当前在线语音不支持所选朗读语言，请选择自动或其他支持的语言。',
      );
    }
    final requestGeneration = ++_generation;
    await _cancelActive();
    await _configurationTail;
    await load();
    _checkDisposed();
    if (requestGeneration != _generation) return {'status': 'cancelled'};
    if (_mode != 'qwen' || !_allowCloud) {
      throw const VoiceServiceFailure('voice_consent', '请先开启在线语音并允许发送待朗读文字。');
    }
    final key = _credentials[_region];
    if (key == null || key.isEmpty) {
      throw const VoiceServiceFailure('voice_key_missing', '请先配置当前地域的语音服务密钥。');
    }
    final token = SpeechCancellationToken();
    final player = MiyinStreamingSpeechPlayback(
      sessionId: sessionId,
      invoke: invokePlayback,
      isCurrent: (value) => !_disposed && value == _generation,
    );
    final answer = _VoiceAnswer(sessionId, requestGeneration, token, player);
    _active = answer;
    unawaited(
      player.started.then<void>((result) {
        if (_owns(answer) && result is Map && result['status'] == 'cancelled') {
          unawaited(cancel());
        }
      }, onError: (Object _) {}),
    );
    try {
      final session = await _client.open(
        config: QwenRealtimeTtsConfig(
          region: _region == 'beijing'
              ? QwenTtsRegion.beijing
              : QwenTtsRegion.singapore,
          model: _model,
          voice: _voice,
          language: language,
        ),
        apiKey: key,
        cancellation: token,
        onAudio: (pcm, rate) async {
          if (!_owns(answer)) return;
          answer.hadAudio = answer.hadAudio || pcm.isNotEmpty;
          await player.add(pcm, rate, answer.generation);
        },
      );
      if (!_owns(answer)) {
        session.cancel();
        return {'status': 'cancelled'};
      }
      answer.session = session;
      unawaited(
        session.done.then<void>(
          (_) => _synthesisComplete(answer),
          onError: (Object error, StackTrace stack) =>
              _failed(answer, error, stack),
        ),
      );
      return {'status': 'ready', 'sessionId': sessionId};
    } catch (error, stack) {
      if (!_owns(answer)) return {'status': 'cancelled'};
      await _failed(answer, error, stack, notify: false);
      throw _safeFailure(error);
    }
  }

  _VoiceAnswer _answer(String sessionId) {
    final answer = _active;
    if (answer == null ||
        answer.id != sessionId ||
        !_owns(answer) ||
        answer.session == null ||
        answer.finishing) {
      throw const VoiceServiceFailure('voice_session', '语音会话已结束，请重新开始。');
    }
    return answer;
  }

  Future<Map<String, Object?>> append(String sessionId, String text) async {
    final answer = _answer(sessionId);
    try {
      // RPC chunks may contain a pasted paragraph. Preserve its exact content
      // while retaining the transport's per-event and per-session limits.
      if (text.length > QwenRealtimeTtsSession.maxTextChars) {
        throw const VoiceServiceFailure('voice_text_limit', '本次语音内容过长，请分次朗读。');
      }
      final characters = text.runes.toList(growable: false);
      for (var offset = 0; offset < characters.length; offset += 1024) {
        answer.session!.append(
          String.fromCharCodes(
            characters.sublist(
              offset,
              (offset + 1024).clamp(0, characters.length),
            ),
          ),
        );
      }
      return {'status': 'accepted', 'sessionId': sessionId};
    } catch (error, stack) {
      await _failed(answer, error, stack, notify: false);
      throw _safeFailure(error);
    }
  }

  Future<Map<String, Object?>> finish(String sessionId) async {
    final answer = _answer(sessionId);
    answer.finishing = true;
    try {
      // Completion is observed by the session.done handler installed in open().
      unawaited(
        answer.session!.finish().then<void>((_) {}, onError: (Object _) {}),
      );
      return {'status': 'finishing', 'sessionId': sessionId};
    } catch (error, stack) {
      await _failed(answer, error, stack, notify: false);
      throw _safeFailure(error);
    }
  }

  Future<void> _synthesisComplete(_VoiceAnswer answer) async {
    if (!_owns(answer)) return;
    if (!answer.hadAudio) {
      _active = null;
      ++_generation;
      answer.player.completeCached({'status': 'cancelled'});
      await onEvent({'type': 'tts_done', 'sessionId': answer.id});
      return;
    }
    try {
      await answer.player.finish();
      // AudioTrack is still playing. Its actual completion event owns tts_done.
      if (_owns(answer)) {
        answer.drainTimer = Timer(const Duration(seconds: 60), () {
          unawaited(
            _failed(
              answer,
              const VoiceServiceFailure(
                'voice_playback_timeout',
                '语音播放未能结束，请重新朗读。',
              ),
              StackTrace.current,
            ),
          );
        });
      }
    } catch (error, stack) {
      await _failed(answer, error, stack);
    }
  }

  static VoiceServiceFailure _safeFailure(Object error) =>
      error is VoiceServiceFailure
      ? error
      : error is QwenTtsFailure
      ? VoiceServiceFailure(error.code, error.message)
      : const VoiceServiceFailure('voice_failed', '在线语音中断，文字已保留，可以重新朗读。');

  Future<void> _failed(
    _VoiceAnswer answer,
    Object error,
    StackTrace stack, {
    bool notify = true,
  }) async {
    if (!_owns(answer)) return;
    final safe = _safeFailure(error);
    _active = null;
    ++_generation;
    answer.drainTimer?.cancel();
    answer.token.cancel();
    answer.player.completeCached({'status': 'cancelled'});
    try {
      await invokePlayback('abortAudioStream', {'sessionId': answer.id});
    } catch (_) {}
    if (notify) {
      await onEvent({
        'type': 'tts_error',
        'sessionId': answer.id,
        'message': safe.message,
      });
    }
  }

  /// Called alongside forwarding native events to JS. Native playback head,
  /// rather than network completion, decides when an audible answer has ended.
  void onNativeEvent(Map<String, Object?> event) {
    final answer = _active;
    if (answer == null ||
        event['sessionId'] != answer.id ||
        !['tts_done', 'tts_error', 'tts_stopped'].contains(event['type'])) {
      return;
    }
    _active = null;
    ++_generation;
    answer.drainTimer?.cancel();
    answer.token.cancel();
    answer.player.completeCached({'status': 'cancelled'});
  }

  Future<void> _cancelActive() async {
    final old = _active;
    _active = null;
    if (old == null) return;
    old.drainTimer?.cancel();
    old.token.cancel();
    old.player.completeCached({'status': 'cancelled'});
    try {
      await invokePlayback('abortAudioStream', {'sessionId': old.id});
    } catch (_) {}
  }

  Future<void> cancel() async {
    ++_generation;
    await _cancelActive();
  }

  Future<void> dispose() async {
    _disposed = true;
    await cancel();
  }
}

final class _VoiceAnswer {
  _VoiceAnswer(this.id, this.generation, this.token, this.player);
  final String id;
  final int generation;
  final SpeechCancellationToken token;
  final MiyinStreamingSpeechPlayback player;
  QwenRealtimeTtsSession? session;
  Timer? drainTimer;
  bool hadAudio = false, finishing = false;
}
