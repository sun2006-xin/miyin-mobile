import 'dart:async';
import 'dart:typed_data';

import 'pcm_stream_resampler.dart';

/// Owns one native PCM stream. Late synthesis chunks cannot restart a stopped
/// stream, and completion is delegated to the native audio playback head.
final class MiyinStreamingSpeechPlayback {
  MiyinStreamingSpeechPlayback({
    required this.sessionId,
    required this.invoke,
    required this.isCurrent,
    this.groupId,
  });
  final String sessionId;
  final String? groupId;
  final Future<Object?> Function(String, Map<String, Object?>) invoke;
  final bool Function(int) isCurrent;
  final Completer<Object?> _started = Completer<Object?>();
  Future<Object?> get started => _started.future;
  bool _opened = false;
  bool _closed = false;
  int? _generation;
  int? _sampleRate;
  MiyinPcmStreamResampler? _resampler;

  Future<void> add(Uint8List pcm, int sampleRate, int generation) async {
    if (_closed || !isCurrent(generation) || pcm.isEmpty) return;
    _generation ??= generation;
    if (_generation != generation) return;
    if (_sampleRate != null && _sampleRate != sampleRate) {
      throw StateError('PCM sample rate changed during playback.');
    }
    if (_sampleRate == null) {
      _sampleRate = sampleRate;
      if (sampleRate != 44100) {
        _resampler = MiyinPcmStreamResampler(inputRate: sampleRate);
      }
    }
    pcm = _resampler?.add(pcm) ?? pcm;
    if (pcm.isEmpty) return;
    if (!_opened) {
      final beginning = await invoke('beginAudioStream', {
        'sessionId': sessionId,
        'sampleRate': 44100,
        if (groupId != null) 'groupId': groupId,
      });
      if (beginning is Map && beginning['status'] == 'cancelled') {
        completeCached({'status': 'cancelled'});
        return;
      }
      if (_closed || !isCurrent(generation)) {
        await invoke('abortAudioStream', {'sessionId': sessionId});
        return;
      }
      _opened = true;
    }
    for (var offset = 0; offset < pcm.length; offset += 65536) {
      if (_closed || !isCurrent(generation)) return;
      final result = await invoke('appendAudioStream', {
        'sessionId': sessionId,
        'pcm': Uint8List.sublistView(
          pcm,
          offset,
          (offset + 65536).clamp(0, pcm.length),
        ),
      });
      if (result is Map && result['status'] == 'cancelled') {
        completeCached({'status': 'cancelled'});
        return;
      }
      if (!_started.isCompleted && !_closed && isCurrent(generation)) {
        _started.complete(result);
      }
    }
  }

  Future<void> finish() async {
    if (_closed) return;
    if (_opened && _generation != null && isCurrent(_generation!)) {
      final tail = _resampler?.finish();
      if (tail != null && tail.isNotEmpty) {
        await invoke('appendAudioStream', {
          'sessionId': sessionId,
          'pcm': tail,
        });
      }
      await invoke('finishAudioStream', {'sessionId': sessionId});
    } else if (!_started.isCompleted) {
      _started.complete({'status': 'cancelled'});
    }
    _closed = true;
  }

  Future<void> fail(Object error, StackTrace stack) async {
    if (_closed) return;
    _closed = true;
    if (_opened) {
      try {
        await invoke('abortAudioStream', {
          'sessionId': sessionId,
          'failed': _generation != null && isCurrent(_generation!),
        });
      } catch (_) {
        // Preserve the synthesis error even if native teardown is unavailable.
      }
    }
    if (!_started.isCompleted) _started.completeError(error, stack);
  }

  void completeCached(Object? result) {
    _closed = true;
    if (!_started.isCompleted) _started.complete(result);
  }
}
