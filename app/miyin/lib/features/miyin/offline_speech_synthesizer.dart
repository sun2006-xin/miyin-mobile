import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'multilingual_tts_model_store.dart';
import 'speech_audio_cache.dart';

/// Tracks latest-only asynchronous voice requests without depending on timers.
@visibleForTesting
final class MiyinSpeechRequestGate {
  int _generation = 0;

  int get generation => _generation;

  int next() => ++_generation;

  int invalidate() => ++_generation;

  bool isCurrent(int generation) => generation == _generation;
}

/// Creates Chinese and English speech locally using the model bundled in the APK.
final class MiyinOfflineSpeechSynthesizer {
  MiyinOfflineSpeechSynthesizer._() : _audioCache = MiyinSpeechAudioCache();

  @visibleForTesting
  MiyinOfflineSpeechSynthesizer.forTesting({
    required MiyinSpeechAudioCache cache,
    Future<void>? workerBusy,
    SendPort? coreCommands,
    SendPort? multilingualCommands,
  }) : _audioCache = cache {
    _workerOperationTail = workerBusy ?? Future<void>.value();
    _commands = coreCommands;
    _multilingualCommands = multilingualCommands;
    _speechInitializationReady.complete();
  }

  @visibleForTesting
  bool get hasScheduledCoreIdleRelease =>
      _coreWorkerIdleTimer?.isActive == true;

  @visibleForTesting
  bool get hasScheduledMultilingualIdleRelease =>
      _multilingualWorkerIdleTimer?.isActive == true;

  static final MiyinOfflineSpeechSynthesizer instance =
      MiyinOfflineSpeechSynthesizer._();

  static const _assetDirectory = 'assets/voice/tts-melo-zh-en';
  static const _manifestAsset = '$_assetDirectory/asset-manifest.json';
  static const _manifestVersion = 'melo-vits-zh-en-myshell-mit-r1';
  static const _legacyKokoroVersion = 'kokoro-v1.1-int8-zh-en-r1';
  static const _modelBytes = 177392565;
  static const _sampleRate = 44100;
  static const _supportedLanguages = {'zh-Hans', 'en'};
  @visibleForTesting
  static const prewarmMaxAttempts = 2;
  @visibleForTesting
  static const prewarmRetryDelay = Duration(milliseconds: 250);
  static const _multilingualLanguages =
      MiyinMultilingualTtsModelStore.supportedLanguageTags;
  static const _coreWorkerIdleLifetime = Duration(minutes: 8);
  static const _multilingualWorkerIdleLifetime = Duration(minutes: 8);
  static const _maxPlaybackGain = 8.0;
  static const _targetPeak = 0.8;
  static const _minimumNormalizationPeak = 0.001;

  Future<Directory>? _assetCopy;
  Future<void>? _workerStart;
  Isolate? _worker;
  SendPort? _commands;
  Isolate? _multilingualWorker;
  SendPort? _multilingualCommands;
  Future<void>? _multilingualWorkerStart;
  Timer? _coreWorkerIdleTimer;
  Timer? _multilingualWorkerIdleTimer;
  int _multilingualIdleReleaseVersion = 0;
  Future<void> _workerOperationTail = Future<void>.value();
  Future<void>? _prewarmDrain;
  int _completedPrewarmGeneration = 0;
  final MiyinSpeechRequestGate _prewarmRequests = MiyinSpeechRequestGate();
  final MiyinSpeechRequestGate _speechRequests = MiyinSpeechRequestGate();
  final MiyinSpeechRequestGate _utterancePreparationRequests =
      MiyinSpeechRequestGate();
  final MiyinSpeechAudioCache _audioCache;
  String? _preparingAudioKey;
  String _preferredTtsProvider = 'melo';
  String _preferredTtsLanguage = 'zh-Hans';
  final Completer<void> _speechInitializationReady = Completer<void>();
  int _activeCoreSyntheses = 0;
  bool _disposed = false;

  /// Prepares the bundled model files in the background during app startup.
  /// The multilingual TTS worker stays lazy. The smaller core Chinese/English
  /// worker is warmed after ASR finishes initialization, then released when it
  /// has been idle so the
  /// first playback is faster without keeping every model resident forever.
  Future<void> prepare() async {
    if (defaultTargetPlatform != TargetPlatform.android || _disposed) return;
    try {
      await MiyinMultilingualTtsModelStore.instance.prepare();
      await _ensureAssets();
    } catch (error, stackTrace) {
      debugPrint('Could not prepare the bundled speech models: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  Future<Map<String, Object?>> status() async {
    var assetsReady = false;
    if (defaultTargetPlatform == TargetPlatform.android && !_disposed) {
      try {
        // A bundled APK asset is not ready merely because it exists in the
        // package: validate the prepared local copy before advertising it.
        await _ensureAssets();
        assetsReady = true;
      } catch (error, stackTrace) {
        debugPrint('Core offline TTS assets are not ready: $error');
        debugPrintStack(stackTrace: stackTrace);
      }
    }

    Map<String, Object?> multilingual = const {};
    try {
      multilingual = await MiyinMultilingualTtsModelStore.instance.status();
    } catch (error, stackTrace) {
      debugPrint('Multilingual offline TTS status is unavailable: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
    return {
      ...coreResourceStatus(
        assetsReady: assetsReady,
        initialized: _commands != null,
      ),
      'modelBytes': _modelBytes,
      'sampleRate': _sampleRate,
      'multilingualAvailable': multilingual['installed'] == true,
      'multilingualLanguages': _multilingualLanguages.toList()..sort(),
      'multilingualSpeakerCount': 10,
      'multilingualInstalled': multilingual['installed'] == true,
      'multilingualBundled': multilingual['bundled'] == true,
      'multilingualSource': multilingual['source'],
    };
  }

  @visibleForTesting
  static Map<String, Object?> coreResourceStatus({
    required bool assetsReady,
    required bool initialized,
  }) => {
    'status': assetsReady ? 'bundled' : 'unavailable',
    'ready': assetsReady,
    'assetsReady': assetsReady,
    'bundled': assetsReady,
    'chineseReady': assetsReady,
    'englishReady': assetsReady,
    'initialized': initialized,
  };

  Future<Map<String, Object?>> synthesize({
    required String sessionId,
    required String languageTag,
    required String text,
    required double speed,
    int speakerId = 0,
    String provider = 'melo',
    Future<void> Function(Uint8List pcm, int sampleRate, int generation)?
    onAudio,
  }) {
    // A newer speak request supersedes an older synthesis that has not reached
    // the native player yet. stopSpeaking invalidates this same gate.
    final requestGeneration = _speechRequests.next();
    // Actual speech outranks an older preference-only model warmup. Otherwise
    // that queued warmup can unload the worker required by the next segment.
    _completedPrewarmGeneration = _prewarmRequests.next();
    // A tap is higher priority than background sentence preparation. A queued
    // preparation checks this generation before entering the worker, and the
    // spoken request must not wait for ASR warmup to finish first.
    // A matching in-flight preparation should finish once and feed this tap.
    // Unrelated speculative work remains lower priority than a spoken request.
    final key = _utteranceKey(languageTag, text, speed, speakerId, provider);
    final cachedWave = _disposed ? null : _audioCache.get(key);
    if (cachedWave == null && _preparingAudioKey != key) {
      _utterancePreparationRequests.invalidate();
      _preparingAudioKey = null;
    }
    if (!_speechInitializationReady.isCompleted) {
      _speechInitializationReady.complete();
    }
    final requestClock = Stopwatch()..start();
    if (usesMultilingualWorker(languageTag: languageTag, provider: provider)) {
      _cancelMultilingualWorkerIdleRelease();
    } else {
      _coreWorkerIdleTimer?.cancel();
      _coreWorkerIdleTimer = null;
    }
    if (cachedWave != null) {
      return _playCachedWave(
        cachedWave,
        requestGeneration,
        requestClock,
        onAudio,
      );
    }
    return _runWorkerExclusive(
      () => _synthesizeExclusive(
        sessionId: sessionId,
        languageTag: languageTag,
        text: text,
        speed: speed,
        speakerId: speakerId,
        provider: provider,
        requestGeneration: requestGeneration,
        requestClock: requestClock,
        onAudio: onAudio,
      ),
    );
  }

  String _utteranceKey(
    String languageTag,
    String text,
    double speed,
    int speakerId,
    String provider,
  ) => MiyinSpeechAudioCache.key(languageTag, text, speed, speakerId, provider);

  /// Prepares the latest translated sentence without starting playback.
  Future<Map<String, Object?>> prepareUtterance({
    required String languageTag,
    required String text,
    required double speed,
    required int speakerId,
    required String provider,
  }) {
    final key = _utteranceKey(languageTag, text, speed, speakerId, provider);
    if (!_disposed && _audioCache.get(key) != null) {
      return Future.value({'status': 'ready'});
    }
    final generation = _utterancePreparationRequests.next();
    _completedPrewarmGeneration = _prewarmRequests.next();
    _preparingAudioKey = key;
    return _runWorkerExclusive(
      () => _synthesizeExclusive(
        sessionId: 'prepared',
        languageTag: languageTag,
        text: text,
        speed: speed,
        speakerId: speakerId,
        provider: provider,
        requestGeneration: _speechRequests.generation,
        requestClock: Stopwatch()..start(),
        prepareOnly: true,
        prepareGeneration: generation,
      ),
    ).whenComplete(() {
      if (_utterancePreparationRequests.isCurrent(generation)) {
        _preparingAudioKey = null;
      }
    });
  }

  Future<Map<String, Object?>> _synthesizeExclusive({
    required String sessionId,
    required String languageTag,
    required String text,
    required double speed,
    required int speakerId,
    required String provider,
    required int requestGeneration,
    required Stopwatch requestClock,
    bool prepareOnly = false,
    int? prepareGeneration,
    Future<void> Function(Uint8List pcm, int sampleRate, int generation)?
    onAudio,
  }) async {
    await _speechInitializationReady.future;
    if (prepareOnly &&
        !_utterancePreparationRequests.isCurrent(prepareGeneration!)) {
      return {'status': 'superseded'};
    }
    if (!prepareOnly && !_speechRequests.isCurrent(requestGeneration)) {
      throw PlatformException(
        code: 'tts_synthesis_cancelled',
        message: '朗读已取消。',
      );
    }
    if (defaultTargetPlatform != TargetPlatform.android) {
      throw PlatformException(
        code: 'voice_unavailable',
        message: '觅音内置离线语音目前仅支持安卓应用。',
      );
    }
    if (_disposed) {
      throw PlatformException(
        code: 'tts_unavailable',
        message: '离线语音服务已关闭，请重新打开觅音。',
      );
    }
    final useMultilingual = usesMultilingualWorker(
      languageTag: languageTag,
      provider: provider,
    );
    if (!_supportedLanguages.contains(languageTag) &&
        !_multilingualLanguages.contains(languageTag)) {
      throw ArgumentError.value(languageTag, 'languageTag', '不支持的朗读语言。');
    }
    if (speakerId < 0 || speakerId > 9) {
      throw ArgumentError.value(speakerId, 'speakerId', '音色编号超出范围。');
    }
    if (speed < 0.75 || speed > 1.25) {
      throw ArgumentError.value(speed, 'speed', '播报速度超出范围。');
    }

    final key = _utteranceKey(languageTag, text, speed, speakerId, provider);
    final cachedWave = _audioCache.get(key);
    if (cachedWave != null) {
      if (prepareOnly) return {'status': 'ready'};
      return _playCachedWave(
        cachedWave,
        requestGeneration,
        requestClock,
        onAudio,
      );
    }

    if (!useMultilingual) {
      _activeCoreSyntheses++;
      _coreWorkerIdleTimer?.cancel();
      _coreWorkerIdleTimer = null;
    }

    try {
      final workerReadyClock = Stopwatch()..start();
      final SendPort commands;
      if (useMultilingual) {
        await _stopCoreWorker();
        final modelDirectory = await MiyinMultilingualTtsModelStore.instance
            .installedModelDirectory();
        if (modelDirectory == null) {
          throw PlatformException(
            code: 'multilingual_tts_not_installed',
            message: '觅音内置的多语言语音资源尚未准备好，请稍后重试或重新打开应用。',
          );
        }
        await _ensureMultilingualWorker(modelDirectory, languageTag);
        commands = _multilingualCommands!;
        _scheduleMultilingualWorkerIdleRelease();
      } else {
        await _unloadMultilingualWorker();
        final modelDirectory = await _ensureAssets();
        await _ensureWorker(modelDirectory);
        commands = _commands!;
      }
      workerReadyClock.stop();
      final temporaryDirectory = await getTemporaryDirectory();
      final safeSessionId = sessionId.replaceAll(
        RegExp(r'[^A-Za-z0-9_.-]'),
        '_',
      );
      final output = File(
        '${temporaryDirectory.path}${Platform.pathSeparator}'
        'miyin-tts-$safeSessionId-${DateTime.now().microsecondsSinceEpoch}.wav',
      );
      final reply = ReceivePort();
      try {
        commands.send({
          'replyTo': reply.sendPort,
          'path': output.path,
          'text': text,
          'speed': speed,
          if (useMultilingual) 'speakerId': speakerId,
          if (useMultilingual) 'language': languageTag,
          'streamAudio': onAudio != null,
        });
        Object? response;
        var streamedChunks = 0;
        final pcmCollector = MiyinBoundedPcmCollector(
          maxWaveBytes: _audioCache.maxBytes,
        );
        await for (final message in reply.timeout(const Duration(minutes: 4))) {
          if (message is Map && message['type'] == 'audio' && onAudio != null) {
            if (!_speechRequests.isCurrent(requestGeneration)) continue;
            final pcm = message['pcm'];
            final sampleRate = message['sampleRate'];
            if (pcm is TransferableTypedData && sampleRate is int) {
              final bytes = pcm.materialize().asUint8List();
              pcmCollector.add(bytes, sampleRate);
              await onAudio(bytes, sampleRate, requestGeneration);
              streamedChunks++;
            }
          } else {
            response = message;
            break;
          }
        }
        if (response is! Map || response['ok'] != true) {
          throw PlatformException(
            code: 'tts_synthesis_failed',
            message: '觅音离线语音合成失败，请稍后重试。',
            details: response is Map ? response['details'] : null,
          );
        }
        if (!prepareOnly && !_speechRequests.isCurrent(requestGeneration)) {
          await _deleteOutput(output);
          throw PlatformException(
            code: 'tts_synthesis_cancelled',
            message: '朗读已取消。',
          );
        }
        requestClock.stop();
        debugPrint(
          '[MiyinTTS] provider=${useMultilingual ? 'supertonic' : 'melo'} '
          'sessionId=$sessionId '
          'requestedProvider=$provider language=$languageTag textChars=${text.runes.length} '
          'workerReadyMs=${workerReadyClock.elapsedMilliseconds} '
          'synthesisMs=${response['synthesisMs'] ?? 'n/a'} '
          'audioDurationMs=${response['audioDurationMs'] ?? 'n/a'} '
          'rtf=${response['synthesisMs'] is num && response['audioDurationMs'] is num && (response['audioDurationMs'] as num) > 0 ? ((response['synthesisMs'] as num) / (response['audioDurationMs'] as num)).toStringAsFixed(3) : 'n/a'} '
          'wavWriteMs=${response['wavWriteMs'] ?? 'n/a'} '
          'requestToWavReadyMs=${requestClock.elapsedMilliseconds}',
        );
        if (prepareOnly) {
          if (!_utterancePreparationRequests.isCurrent(prepareGeneration!)) {
            await _deleteOutput(output);
            return {'status': 'superseded'};
          }
          await _cacheWaveFile(key, output);
          await _deleteOutput(output);
          return {'status': 'ready'};
        }
        if (streamedChunks > 0) {
          final wave = pcmCollector.finish();
          if (wave != null) _audioCache.put(key, wave);
        } else {
          await _cacheWaveFile(key, output);
        }
        _checkSpeechRequest(requestGeneration);
        return {
          'status': 'ready',
          'path': output.path,
          'requestGeneration': requestGeneration,
          'streamed': streamedChunks > 0,
          'sampleRate': response['sampleRate'] is int
              ? response['sampleRate'] as int
              : _sampleRate,
          'synthesisMs': response['synthesisMs'],
          'wavWriteMs': response['wavWriteMs'],
        };
      } on TimeoutException {
        await _deleteOutput(output);
        throw PlatformException(
          code: 'tts_synthesis_timeout',
          message: '离线语音准备时间过长，请缩短文字后重试。',
        );
      } catch (_) {
        await _deleteOutput(output);
        rethrow;
      } finally {
        reply.close();
      }
    } finally {
      if (!useMultilingual) {
        _activeCoreSyntheses--;
        _scheduleCoreWorkerIdleRelease();
      } else {
        _scheduleMultilingualWorkerIdleRelease();
      }
    }
  }

  void _checkSpeechRequest(int generation) {
    if (_disposed || !_speechRequests.isCurrent(generation)) {
      throw PlatformException(
        code: 'tts_synthesis_cancelled',
        message: '朗读已取消。',
      );
    }
  }

  Future<void> _cacheWaveFile(String key, File output) async {
    try {
      if (await output.length() > _audioCache.maxBytes) return;
      final wave = await output.readAsBytes();
      if (!_disposed) _audioCache.put(key, wave);
    } catch (_) {
      // Cache I/O is optional and must never fail a successfully generated utterance.
    }
  }

  Future<Map<String, Object?>> _playCachedWave(
    Uint8List wave,
    int generation,
    Stopwatch clock,
    Future<void> Function(Uint8List, int, int)? onAudio,
  ) => _deliverCachedWave(wave, generation, clock, onAudio).whenComplete(() {
    // A cache hit bypasses the worker queue but the request may already have
    // cancelled its idle timer. Rearm whichever worker is actually resident,
    // including after cancellation; these helpers preserve active/dispose gates.
    _scheduleCoreWorkerIdleRelease();
    _scheduleMultilingualWorkerIdleRelease();
  });

  Future<Map<String, Object?>> _deliverCachedWave(
    Uint8List wave,
    int generation,
    Stopwatch clock,
    Future<void> Function(Uint8List, int, int)? onAudio,
  ) async {
    _checkSpeechRequest(generation);
    final rate = ByteData.sublistView(wave).getUint32(24, Endian.little);
    if (onAudio != null) {
      final firstCachedPcmMs = clock.elapsedMilliseconds;
      for (var offset = 44; offset < wave.length; offset += 65536) {
        _checkSpeechRequest(generation);
        await onAudio(
          Uint8List.sublistView(
            wave,
            offset,
            math.min(offset + 65536, wave.length),
          ),
          rate,
          generation,
        );
        _checkSpeechRequest(generation);
      }
      debugPrint(
        '[MiyinTTS] generatedAudioCacheHit requestToFirstCachedPcmMs=$firstCachedPcmMs cachedPcmDeliveryMs=${clock.elapsedMilliseconds} audioDurationMs=${(wave.length - 44) * 1000 ~/ (rate * 2)} cacheEntries=${_audioCache.length} cacheBytes=${_audioCache.byteLength}',
      );
      return {
        'status': 'ready',
        'streamed': true,
        'requestGeneration': generation,
        'cacheHit': true,
        'sampleRate': rate,
      };
    }
    final directory = await getTemporaryDirectory();
    _checkSpeechRequest(generation);
    final output = File(
      '${directory.path}${Platform.pathSeparator}miyin-tts-${DateTime.now().microsecondsSinceEpoch}.wav',
    );
    try {
      await output.writeAsBytes(wave, flush: true);
      _checkSpeechRequest(generation);
      return {
        'status': 'ready',
        'path': output.path,
        'requestGeneration': generation,
        'cacheHit': true,
      };
    } catch (_) {
      await _deleteOutput(output);
      rethrow;
    }
  }

  @visibleForTesting
  static bool usesMultilingualWorker({
    required String languageTag,
    required String provider,
  }) =>
      _multilingualLanguages.contains(languageTag) &&
      languageTag != 'zh-Hans' &&
      (languageTag != 'en' || provider == 'supertonic');

  /// Starts the selected TTS model in the background so voice playback does
  /// not pay ONNX initialization on the first tap. Only one TTS worker remains
  /// resident at a time; switching providers releases the previous worker.
  Future<Map<String, Object?>> prewarmVoice({
    required String languageTag,
    required String provider,
    int speakerId = 0,
  }) async {
    _prewarmRequests.next();
    _preferredTtsLanguage = languageTag;
    _preferredTtsProvider = provider;
    if (usesMultilingualWorker(languageTag: languageTag, provider: provider)) {
      _cancelMultilingualWorkerIdleRelease();
    } else {
      _coreWorkerIdleTimer?.cancel();
      _coreWorkerIdleTimer = null;
    }
    if (_speechInitializationReady.isCompleted) {
      _scheduleLatestPrewarm();
    }
    return {
      'status': 'preparing',
      'languageTag': languageTag,
      'provider': provider,
    };
  }

  @visibleForTesting
  static bool shouldRetryPrewarm({
    required int attempt,
    required int requestGeneration,
    required int currentGeneration,
  }) => attempt < prewarmMaxAttempts && requestGeneration == currentGeneration;

  /// Checked by the router immediately before handing synthesized audio to
  /// the native player. No await may occur between this check and playAudio.
  bool isCurrentSynthesisRequest(Object? generation) =>
      generation is int && _speechRequests.isCurrent(generation);

  void cancelPending() {
    _speechRequests.invalidate();
    _utterancePreparationRequests.invalidate();
    _completedPrewarmGeneration = _prewarmRequests.next();
    _preparingAudioKey = null;
  }

  Future<void> discardAudioFile(Object? path) async {
    if (path is! String || path.isEmpty) return;
    await _deleteOutput(File(path));
  }

  Future<void> dispose() async {
    _disposed = true;
    _prewarmRequests.invalidate();
    _speechRequests.invalidate();
    _utterancePreparationRequests.invalidate();
    _audioCache.clear();
    if (!_speechInitializationReady.isCompleted) {
      _speechInitializationReady.complete();
    }
    _coreWorkerIdleTimer?.cancel();
    _coreWorkerIdleTimer = null;
    _cancelMultilingualWorkerIdleRelease();
    await _runWorkerExclusive(() async {
      await _stopCoreWorker();
      await _unloadMultilingualWorker();
    });
  }

  Future<void> unloadMultilingualModel() =>
      _runWorkerExclusive(_unloadMultilingualWorker);

  Future<void> _unloadMultilingualWorker() async {
    _cancelMultilingualWorkerIdleRelease();
    final multilingualCommands = _multilingualCommands;
    _multilingualCommands = null;
    if (multilingualCommands != null) {
      final reply = ReceivePort();
      multilingualCommands.send({
        'type': 'shutdown',
        'replyTo': reply.sendPort,
      });
      try {
        await reply.first.timeout(const Duration(seconds: 3));
      } on TimeoutException {
        _multilingualWorker?.kill(priority: Isolate.immediate);
      } finally {
        reply.close();
      }
    }
    _multilingualWorker = null;
  }

  @visibleForTesting
  static Float32List normalizeSamplesForPlayback(Float32List samples) {
    var peak = 0.0;
    for (final sample in samples) {
      if (!sample.isFinite) continue;
      peak = math.max(peak, sample.abs());
    }
    if (peak < _minimumNormalizationPeak) {
      return Float32List.fromList([
        for (final sample in samples) sample.isFinite ? sample : 0.0,
      ]);
    }

    final gain = math.min(_targetPeak / peak, _maxPlaybackGain);
    return Float32List.fromList([
      for (final sample in samples)
        sample.isFinite
            ? (sample * gain).clamp(-_targetPeak, _targetPeak).toDouble()
            : 0.0,
    ]);
  }

  @visibleForTesting
  static Uint8List encodePcm16Wave(Float32List samples, int sampleRate) {
    if (sampleRate <= 0) {
      throw ArgumentError.value(sampleRate, 'sampleRate', '采样率必须大于零。');
    }
    final normalized = normalizeSamplesForPlayback(samples);
    final dataLength = normalized.length * 2;
    final bytes = Uint8List(44 + dataLength);
    void writeText(int offset, String value) {
      for (var index = 0; index < value.length; index++) {
        bytes[offset + index] = value.codeUnitAt(index);
      }
    }

    final header = ByteData.sublistView(bytes);
    writeText(0, 'RIFF');
    header.setUint32(4, 36 + dataLength, Endian.little);
    writeText(8, 'WAVE');
    writeText(12, 'fmt ');
    header.setUint32(16, 16, Endian.little);
    header.setUint16(20, 1, Endian.little);
    header.setUint16(22, 1, Endian.little);
    header.setUint32(24, sampleRate, Endian.little);
    header.setUint32(28, sampleRate * 2, Endian.little);
    header.setUint16(32, 2, Endian.little);
    header.setUint16(34, 16, Endian.little);
    writeText(36, 'data');
    header.setUint32(40, dataLength, Endian.little);
    for (var index = 0; index < normalized.length; index++) {
      final value = (normalized[index] * 32767).round();
      header.setInt16(44 + index * 2, value, Endian.little);
    }
    return bytes;
  }

  /// Called after ASR initialization to avoid overlapping model-startup peaks.
  /// ASR remains available afterwards, so the selected TTS worker adds memory
  /// alongside it until TTS has been idle for two minutes. Only one TTS worker
  /// is kept; the actual combined memory cost still needs device validation.
  void prewarmCoreWorker() {
    if (_disposed) return;
    if (!_speechInitializationReady.isCompleted) {
      _speechInitializationReady.complete();
    }
    _prewarmRequests.next();
    _scheduleLatestPrewarm();
  }

  void _scheduleLatestPrewarm() {
    if (_disposed ||
        !_speechInitializationReady.isCompleted ||
        _prewarmDrain != null) {
      return;
    }
    final drain = _drainLatestPrewarmRequests();
    _prewarmDrain = drain;
    unawaited(
      drain.whenComplete(() {
        if (!identical(_prewarmDrain, drain)) return;
        _prewarmDrain = null;
        if (!_disposed &&
            _completedPrewarmGeneration != _prewarmRequests.generation) {
          _scheduleLatestPrewarm();
        }
      }),
    );
  }

  Future<void> _drainLatestPrewarmRequests() async {
    try {
      while (!_disposed) {
        final requestGeneration = _prewarmRequests.generation;
        if (_completedPrewarmGeneration == requestGeneration) return;

        final languageTag = _preferredTtsLanguage;
        final provider = _preferredTtsProvider;
        for (var attempt = 1; attempt <= prewarmMaxAttempts; attempt++) {
          if (_disposed || !_prewarmRequests.isCurrent(requestGeneration)) {
            break;
          }
          try {
            await _runWorkerExclusive(() async {
              // A speak request or a newer voice selection may have entered
              // the worker queue while this prewarm was waiting for the lock.
              if (_disposed || !_prewarmRequests.isCurrent(requestGeneration)) {
                return;
              }
              if (usesMultilingualWorker(
                languageTag: languageTag,
                provider: provider,
              )) {
                await _prepareMultilingualWorker(languageTag);
              } else {
                await _prepareCoreWorker();
              }
            });
            break;
          } catch (error, stackTrace) {
            debugPrint(
              'Could not prewarm the selected offline TTS voice '
              '(attempt $attempt/$prewarmMaxAttempts): $error',
            );
            debugPrintStack(stackTrace: stackTrace);
            if (!shouldRetryPrewarm(
              attempt: attempt,
              requestGeneration: requestGeneration,
              currentGeneration: _prewarmRequests.generation,
            )) {
              break;
            }
            // Do not hold the single-worker lock while backing off. If a
            // newer voice is chosen during this delay, its generation makes
            // this retry stale and the outer loop immediately uses the latest.
            await Future<void>.delayed(prewarmRetryDelay);
          }
        }
        if (_prewarmRequests.isCurrent(requestGeneration)) {
          _completedPrewarmGeneration = requestGeneration;
        }
      }
    } catch (error, stackTrace) {
      debugPrint('Could not drain offline TTS prewarm requests: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  Future<void> _prepareCoreWorker() async {
    if (_disposed) return;
    await _unloadMultilingualWorker();
    final modelDirectory = await _ensureAssets();
    await _ensureWorker(modelDirectory);
    _scheduleCoreWorkerIdleRelease();
  }

  Future<void> _prepareMultilingualWorker(String languageTag) async {
    if (_disposed) return;
    await _stopCoreWorker();
    final modelDirectory = await MiyinMultilingualTtsModelStore.instance
        .installedModelDirectory();
    if (modelDirectory == null) {
      throw PlatformException(
        code: 'multilingual_tts_not_installed',
        message: '觅音内置的多语言语音资源尚未准备好，请稍后重试或重新打开应用。',
      );
    }
    await _ensureMultilingualWorker(modelDirectory, languageTag);
    _scheduleMultilingualWorkerIdleRelease();
  }

  void _scheduleCoreWorkerIdleRelease() {
    if (_disposed || _activeCoreSyntheses > 0 || _commands == null) return;
    _coreWorkerIdleTimer?.cancel();
    _coreWorkerIdleTimer = Timer(_coreWorkerIdleLifetime, () {
      _coreWorkerIdleTimer = null;
      unawaited(
        _runWorkerExclusive(() async {
          if (_activeCoreSyntheses > 0) {
            _scheduleCoreWorkerIdleRelease();
            return;
          }
          await _stopCoreWorker();
        }),
      );
    });
  }

  void _scheduleMultilingualWorkerIdleRelease() {
    if (_disposed || _multilingualCommands == null) return;
    _multilingualWorkerIdleTimer?.cancel();
    final releaseVersion = ++_multilingualIdleReleaseVersion;
    _multilingualWorkerIdleTimer = Timer(_multilingualWorkerIdleLifetime, () {
      _multilingualWorkerIdleTimer = null;
      unawaited(
        _runWorkerExclusive(() async {
          if (_disposed ||
              releaseVersion != _multilingualIdleReleaseVersion ||
              _multilingualCommands == null) {
            return;
          }
          await _unloadMultilingualWorker();
        }),
      );
    });
  }

  void _cancelMultilingualWorkerIdleRelease() {
    _multilingualIdleReleaseVersion++;
    _multilingualWorkerIdleTimer?.cancel();
    _multilingualWorkerIdleTimer = null;
  }

  Future<void> _stopCoreWorker() async {
    _coreWorkerIdleTimer?.cancel();
    _coreWorkerIdleTimer = null;
    final commands = _commands;
    _commands = null;
    final worker = _worker;
    if (commands != null) {
      final reply = ReceivePort();
      commands.send({'type': 'shutdown', 'replyTo': reply.sendPort});
      try {
        await reply.first.timeout(const Duration(seconds: 3));
      } on TimeoutException {
        worker?.kill(priority: Isolate.immediate);
      } finally {
        reply.close();
      }
    } else {
      worker?.kill(priority: Isolate.immediate);
    }
    _worker = null;
  }

  Future<Directory> _ensureAssets() async {
    final pending = _assetCopy;
    if (pending != null) return pending;
    final copy = _copyAssets();
    _assetCopy = copy;
    try {
      return await copy;
    } finally {
      if (identical(_assetCopy, copy)) _assetCopy = null;
    }
  }

  Future<Directory> _copyAssets() async {
    final support = await getApplicationSupportDirectory();
    final modelDirectory = Directory(
      '${support.path}${Platform.pathSeparator}miyin'
      '${Platform.pathSeparator}tts-zh-en',
    );
    await modelDirectory.create(recursive: true);
    final marker = File(
      '${modelDirectory.path}${Platform.pathSeparator}.bundle-version',
    );
    final previousVersion = await marker.exists()
        ? await marker.readAsString()
        : '';
    final decodedManifest = jsonDecode(
      await rootBundle.loadString(_manifestAsset),
    );
    if (decodedManifest is! List) {
      throw const FormatException('Bundled TTS asset manifest is invalid.');
    }
    final manifest = <({String path, int size})>[];
    for (final entry in decodedManifest) {
      if (entry is! Map || entry['path'] is! String || entry['size'] is! int) {
        throw const FormatException('Bundled TTS asset entry is invalid.');
      }
      final assetPath = entry['path'] as String;
      if (!RegExp(r'^[A-Za-z0-9._/-]+$').hasMatch(assetPath) ||
          assetPath.startsWith('/') ||
          assetPath.split('/').contains('..')) {
        throw const FormatException('Bundled TTS asset path is invalid.');
      }
      manifest.add((path: assetPath, size: entry['size'] as int));
    }
    if (manifest.isEmpty) {
      throw const FormatException('Bundled TTS asset manifest is empty.');
    }

    if (previousVersion == _manifestVersion &&
        await _manifestFilesAreValid(modelDirectory, manifest)) {
      return modelDirectory;
    }

    for (final entry in manifest) {
      final relativePath = entry.path.replaceAll('/', Platform.pathSeparator);
      final destination = File(
        '${modelDirectory.path}${Platform.pathSeparator}$relativePath',
      );
      if (await destination.exists() &&
          await destination.length() == entry.size) {
        continue;
      }
      await destination.parent.create(recursive: true);
      final asset = await rootBundle.load('$_assetDirectory/${entry.path}');
      if (asset.lengthInBytes != entry.size) {
        throw const FormatException('Bundled TTS asset has an invalid size.');
      }
      final bytes = asset.buffer.asUint8List(
        asset.offsetInBytes,
        asset.lengthInBytes,
      );
      final partial = File('${destination.path}.part');
      await partial.writeAsBytes(bytes, flush: true);
      if (await destination.exists()) await destination.delete();
      await partial.rename(destination.path);
    }
    if (!await _manifestFilesAreValid(modelDirectory, manifest)) {
      throw const FormatException('Prepared TTS assets failed validation.');
    }
    if (previousVersion == _legacyKokoroVersion) {
      await _removeLegacyKokoroAssets(modelDirectory);
    }
    await marker.writeAsString(_manifestVersion, flush: true);
    return modelDirectory;
  }

  Future<bool> _manifestFilesAreValid(
    Directory directory,
    List<({String path, int size})> manifest,
  ) async {
    for (final entry in manifest) {
      final file = File(
        '${directory.path}${Platform.pathSeparator}'
        '${entry.path.replaceAll('/', Platform.pathSeparator)}',
      );
      if (!await file.exists() || await file.length() != entry.size) {
        return false;
      }
    }
    return true;
  }

  Future<void> _removeLegacyKokoroAssets(Directory modelDirectory) async {
    for (final name in [
      'model.int8.onnx',
      'voices.bin',
      'lexicon-us-en.txt',
      'lexicon-zh.txt',
      'LICENSE.txt',
    ]) {
      final oldFile = File(
        '${modelDirectory.path}${Platform.pathSeparator}$name',
      );
      if (await oldFile.exists()) await oldFile.delete();
    }

    final oldData = Directory(
      '${modelDirectory.path}${Platform.pathSeparator}espeak-ng-data',
    );
    if (await FileSystemEntity.type(oldData.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      return;
    }
    final parentPath = await modelDirectory.resolveSymbolicLinks();
    final dataPath = await oldData.resolveSymbolicLinks();
    final expectedPath = '$parentPath${Platform.pathSeparator}espeak-ng-data';
    final isExpectedPath = Platform.isWindows
        ? dataPath.toLowerCase() == expectedPath.toLowerCase()
        : dataPath == expectedPath;
    if (isExpectedPath) await oldData.delete(recursive: true);
  }

  Future<void> _ensureWorker(Directory modelDirectory) async {
    if (_commands != null) return;
    final pending = _workerStart;
    if (pending != null) {
      await pending;
      return;
    }
    final start = _startWorker(modelDirectory);
    _workerStart = start;
    try {
      await start;
    } finally {
      if (identical(_workerStart, start)) _workerStart = null;
    }
  }

  Future<void> _startWorker(Directory modelDirectory) async {
    final ready = ReceivePort();
    try {
      _worker = await Isolate.spawn<Map<String, Object?>>(_ttsWorkerMain, {
        'replyTo': ready.sendPort,
        'modelDirectory': modelDirectory.path,
      }, debugName: 'miyin-offline-tts');
      final message = await ready.first.timeout(const Duration(minutes: 3));
      if (message is! Map ||
          message['type'] != 'ready' ||
          message['port'] is! SendPort) {
        throw StateError('Offline TTS worker did not become ready.');
      }
      debugPrint(
        '[MiyinTTS] provider=melo modelWarmupMs=${message['warmupMs'] ?? 'n/a'}',
      );
      if (_disposed) {
        _worker?.kill(priority: Isolate.immediate);
        _worker = null;
        return;
      }
      _commands = message['port'] as SendPort;
    } on TimeoutException {
      _worker?.kill(priority: Isolate.immediate);
      _worker = null;
      throw PlatformException(
        code: 'tts_initialization_timeout',
        message: '离线语音模型加载时间过长，请稍后重试。',
      );
    } catch (error) {
      _worker?.kill(priority: Isolate.immediate);
      _worker = null;
      throw PlatformException(
        code: 'tts_initialization_failed',
        message: '觅音内置离线语音模型无法加载。',
        details: error.toString(),
      );
    } finally {
      ready.close();
    }
  }

  Future<void> _ensureMultilingualWorker(
    Directory modelDirectory,
    String languageTag,
  ) async {
    if (_multilingualCommands != null) return;
    final pending = _multilingualWorkerStart;
    if (pending != null) {
      await pending;
      return;
    }
    final start = _startMultilingualWorker(modelDirectory, languageTag);
    _multilingualWorkerStart = start;
    try {
      await start;
    } finally {
      if (identical(_multilingualWorkerStart, start)) {
        _multilingualWorkerStart = null;
      }
    }
  }

  Future<void> _startMultilingualWorker(
    Directory modelDirectory,
    String languageTag,
  ) async {
    final ready = ReceivePort();
    try {
      _multilingualWorker = await Isolate.spawn<Map<String, Object?>>(
        _supertonicTtsWorkerMain,
        {
          'replyTo': ready.sendPort,
          'modelDirectory': modelDirectory.path,
          'language': languageTag,
        },
        debugName: 'miyin-supertonic-tts',
      );
      final message = await ready.first.timeout(const Duration(minutes: 3));
      if (message is! Map ||
          message['type'] != 'ready' ||
          message['port'] is! SendPort) {
        throw StateError('Multilingual TTS worker did not become ready.');
      }
      debugPrint(
        '[MiyinTTS] provider=supertonic modelWarmupMs=${message['warmupMs'] ?? 'n/a'}',
      );
      _multilingualCommands = message['port'] as SendPort;
    } on TimeoutException {
      _multilingualWorker?.kill(priority: Isolate.immediate);
      _multilingualWorker = null;
      throw PlatformException(
        code: 'multilingual_tts_initialization_timeout',
        message: '多语言语音模型加载时间过长，请稍后重试。',
      );
    } catch (error) {
      _multilingualWorker?.kill(priority: Isolate.immediate);
      _multilingualWorker = null;
      throw PlatformException(
        code: 'multilingual_tts_initialization_failed',
        message: '多语言语音模型无法加载。',
        details: error.toString(),
      );
    } finally {
      ready.close();
    }
  }

  Future<T> _runWorkerExclusive<T>(Future<T> Function() operation) async {
    final previous = _workerOperationTail;
    final release = Completer<void>();
    _workerOperationTail = release.future;
    await previous;
    try {
      return await operation();
    } finally {
      release.complete();
    }
  }

  Future<void> _deleteOutput(File output) async {
    try {
      if (await output.exists()) await output.delete();
    } catch (_) {
      // The cache can be cleaned by Android after the app exits.
    }
  }
}

void _supertonicTtsWorkerMain(Map<String, Object?> initialization) {
  final startupPort = initialization['replyTo'] as SendPort;
  final modelDirectory = initialization['modelDirectory'] as String;
  final separator = Platform.pathSeparator;
  final directory = '$modelDirectory$separator';
  final commands = ReceivePort();
  sherpa.initBindings();
  final tts = sherpa.OfflineTts(
    sherpa.OfflineTtsConfig(
      model: sherpa.OfflineTtsModelConfig(
        supertonic: sherpa.OfflineTtsSupertonicModelConfig(
          durationPredictor: '${directory}duration_predictor.int8.onnx',
          textEncoder: '${directory}text_encoder.int8.onnx',
          vectorEstimator: '${directory}vector_estimator.int8.onnx',
          vocoder: '${directory}vocoder.int8.onnx',
          ttsJson: '${directory}tts.json',
          unicodeIndexer: '${directory}unicode_indexer.bin',
          voiceStyle: '${directory}voice.bin',
        ),
        numThreads: 2,
        debug: false,
        provider: 'cpu',
      ),
    ),
  );
  final warmupLanguage = initialization['language'] is String
      ? initialization['language'] as String
      : 'en';
  final warmup = Stopwatch()..start();
  try {
    tts.generateWithConfig(
      text: 'Hi.',
      config: sherpa.OfflineTtsGenerationConfig(
        sid: 0,
        speed: 1.0,
        numSteps: 5,
        extra: {'lang': warmupLanguage},
      ),
    );
  } catch (error) {
    debugPrint('Multilingual TTS warmup inference failed: $error');
  }
  warmup.stop();
  startupPort.send({
    'type': 'ready',
    'port': commands.sendPort,
    'warmupMs': warmup.elapsedMilliseconds,
  });
  commands.listen((dynamic raw) {
    if (raw is! Map) return;
    final replyTo = raw['replyTo'];
    if (raw['type'] == 'shutdown') {
      tts.free();
      commands.close();
      if (replyTo is SendPort) replyTo.send({'ok': true});
      Isolate.exit();
    }
    if (replyTo is! SendPort ||
        raw['path'] is! String ||
        raw['text'] is! String ||
        raw['speed'] is! double ||
        raw['speakerId'] is! int ||
        raw['language'] is! String) {
      if (replyTo is SendPort) replyTo.send({'ok': false});
      return;
    }
    try {
      final synthesisClock = Stopwatch()..start();
      var streamedBytes = 0;
      var streamOverflow = false;
      final audio = tts.generateWithConfig(
        text: raw['text'] as String,
        config: sherpa.OfflineTtsGenerationConfig(
          sid: raw['speakerId'] as int,
          speed: raw['speed'] as double,
          numSteps: 5,
          extra: {'lang': raw['language'] as String},
        ),
        onProgress: raw['streamAudio'] == true
            ? (samples, progress) {
                streamedBytes += samples.length * 2;
                if (streamedBytes > 16 * 1024 * 1024) {
                  streamOverflow = true;
                  return 0;
                }
                _sendAudioChunk(replyTo, samples, tts.sampleRate);
                return 1;
              }
            : null,
      );
      if (streamOverflow) {
        throw StateError('Streaming speech exceeded the bounded PCM buffer.');
      }
      if (audio.samples.isEmpty || audio.sampleRate <= 0) {
        throw StateError('The multilingual TTS model returned no audio.');
      }
      synthesisClock.stop();
      final writeClock = Stopwatch()..start();
      if (raw['streamAudio'] != true || streamedBytes == 0) {
        _writePcm16Wave(raw['path'] as String, audio.samples, audio.sampleRate);
      }
      writeClock.stop();
      replyTo.send({
        'ok': true,
        'sampleRate': audio.sampleRate,
        'audioDurationMs': audio.samples.length * 1000 ~/ audio.sampleRate,
        'synthesisMs': synthesisClock.elapsedMilliseconds,
        'wavWriteMs': writeClock.elapsedMilliseconds,
      });
    } catch (error) {
      try {
        final output = File(raw['path'] as String);
        if (output.existsSync()) output.deleteSync();
      } catch (_) {}
      replyTo.send({'ok': false, 'details': error.toString()});
    }
  });
}

void _ttsWorkerMain(Map<String, Object?> initialization) {
  final startupPort = initialization['replyTo'] as SendPort;
  final modelDirectory = initialization['modelDirectory'] as String;
  final commands = ReceivePort();
  sherpa.initBindings();
  final separator = Platform.pathSeparator;
  final tts = sherpa.OfflineTts(
    sherpa.OfflineTtsConfig(
      model: sherpa.OfflineTtsModelConfig(
        vits: sherpa.OfflineTtsVitsModelConfig(
          model: '$modelDirectory${separator}model.onnx',
          lexicon: '$modelDirectory${separator}lexicon.txt',
          tokens: '$modelDirectory${separator}tokens.txt',
        ),
        numThreads: 2,
        debug: false,
        provider: 'cpu',
      ),
      ruleFsts: [
        '$modelDirectory${separator}date.fst',
        '$modelDirectory${separator}number.fst',
      ].join(','),
    ),
  );
  final warmup = Stopwatch()..start();
  try {
    tts.generate(text: '你好。', sid: 0, speed: 1.0);
  } catch (error) {
    debugPrint('Core TTS warmup inference failed: $error');
  }
  warmup.stop();
  startupPort.send({
    'type': 'ready',
    'port': commands.sendPort,
    'warmupMs': warmup.elapsedMilliseconds,
  });
  commands.listen((dynamic raw) {
    if (raw is! Map) return;
    final replyTo = raw['replyTo'];
    if (raw['type'] == 'shutdown') {
      tts.free();
      commands.close();
      if (replyTo is SendPort) replyTo.send({'ok': true});
      Isolate.exit();
    }
    if (replyTo is! SendPort ||
        raw['path'] is! String ||
        raw['text'] is! String ||
        raw['speed'] is! double) {
      replyTo is SendPort ? replyTo.send({'ok': false}) : null;
      return;
    }
    try {
      final synthesisClock = Stopwatch()..start();
      var streamedBytes = 0;
      var streamOverflow = false;
      final audio = tts.generateWithConfig(
        text: raw['text'] as String,
        config: sherpa.OfflineTtsGenerationConfig(
          sid: 0,
          speed: raw['speed'] as double,
        ),
        onProgress: raw['streamAudio'] == true
            ? (samples, progress) {
                streamedBytes += samples.length * 2;
                if (streamedBytes > 16 * 1024 * 1024) {
                  streamOverflow = true;
                  return 0;
                }
                _sendAudioChunk(replyTo, samples, tts.sampleRate);
                return 1;
              }
            : null,
      );
      if (streamOverflow) {
        throw StateError('Streaming speech exceeded the bounded PCM buffer.');
      }
      if (audio.samples.isEmpty || audio.sampleRate <= 0) {
        throw StateError('The TTS model returned no audio samples.');
      }
      synthesisClock.stop();
      final writeClock = Stopwatch()..start();
      if (raw['streamAudio'] != true || streamedBytes == 0) {
        _writePcm16Wave(raw['path'] as String, audio.samples, audio.sampleRate);
      }
      writeClock.stop();
      replyTo.send({
        'ok': true,
        'synthesisMs': synthesisClock.elapsedMilliseconds,
        'audioDurationMs': audio.samples.length * 1000 ~/ audio.sampleRate,
        'wavWriteMs': writeClock.elapsedMilliseconds,
      });
    } catch (error) {
      try {
        final output = File(raw['path'] as String);
        if (output.existsSync()) output.deleteSync();
      } catch (_) {}
      replyTo.send({'ok': false, 'details': error.toString()});
    }
  });
}

void _writePcm16Wave(String path, Float32List samples, int sampleRate) {
  File(path).writeAsBytesSync(
    MiyinOfflineSpeechSynthesizer.encodePcm16Wave(samples, sampleRate),
    flush: true,
  );
}

void _sendAudioChunk(SendPort reply, Float32List samples, int sampleRate) {
  if (samples.isEmpty) return;
  final wave = MiyinOfflineSpeechSynthesizer.encodePcm16Wave(
    samples,
    sampleRate,
  );
  for (var offset = 44; offset < wave.length; offset += 65536) {
    reply.send({
      'type': 'audio',
      'sampleRate': sampleRate,
      'pcm': TransferableTypedData.fromList([
        Uint8List.sublistView(
          wave,
          offset,
          math.min(offset + 65536, wave.length),
        ),
      ]),
    });
  }
}
