import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'multilingual_asr_model_store.dart';
import 'multilingual_asr_worker.dart';
import 'live_audio_archive.dart';
import 'offline_speech_synthesizer.dart';

/// Runs local Whisper ASR for supported translation languages, with a
/// Chinese-English Zipformer fallback if the bundled model cannot initialize.
final class MiyinOfflineSpeechRecognizer {
  MiyinOfflineSpeechRecognizer._();

  static final MiyinOfflineSpeechRecognizer instance =
      MiyinOfflineSpeechRecognizer._();

  static const _assetDirectory = 'assets/voice/asr-zh-en';
  static const _modelFiles = <String, int>{
    'encoder-epoch-99-avg-1.int8.onnx': 42980793,
    'decoder-epoch-99-avg-1.onnx': 13877276,
    'joiner-epoch-99-avg-1.int8.onnx': 3228485,
    'tokens.txt': 56317,
  };
  static const _recognitionLimit = Duration(seconds: 60);

  final AudioRecorder _recorder = AudioRecorder();
  final MiyinMultilingualAsrModelStore _multilingualModelStore =
      MiyinMultilingualAsrModelStore.instance;
  final MiyinMultilingualAsrWorker _multilingualWorker =
      MiyinMultilingualAsrWorker();
  final StreamController<Map<String, Object?>> _events =
      StreamController<Map<String, Object?>>.broadcast();

  Future<void>? _modelLoad;
  sherpa.OnlineRecognizer? _recognizer;
  sherpa.OnlineStream? _stream;
  sherpa.OnlineStream? _playbackPreviewStream;
  bool _playbackPreviewActive = false;
  int? _playbackPreviewSegmentId;
  int _playbackPreviewVoicedSamples = 0;
  String? _playbackPreviewLastPartial;
  StreamSubscription<Uint8List>? _audioSubscription;
  Completer<void>? _audioStreamClosed;
  Timer? _recognitionTimer;
  String? _sessionId;
  String? _lastPartial;
  List<Float32List> _multilingualAudioChunks = <Float32List>[];
  int _multilingualSampleCount = 0;
  int? _pendingPcmByte;
  bool _stopping = false;
  bool _usesMultilingualAsr = false;
  String? _multilingualModelPath;
  bool _videoMode = false;
  bool _chatMode = false;
  int _chatVoicedSamples = 0;
  int _chatSilenceSamples = 0;
  bool _retainLiveAudio = false;
  bool _bilingualPreviewActive = false;
  int _liveSegmentSamples = 0;
  int _liveVoicedSamples = 0;
  int _liveTrailingSilenceSamples = 0;
  int _liveSessionStartedAtMs = 0;
  int _liveSegmentIndex = 0;
  bool _bindingsInitialized = false;
  bool _disposed = false;

  Stream<Map<String, Object?>> get events => _events.stream;
  int get currentLiveSegmentIndex => _liveSegmentIndex;

  /// Uses a separate online stream for permitted app audio, leaving the
  /// microphone stream and multilingual final recognizer untouched.
  Future<bool> startPlaybackPreview({
    required String sourceTag,
    required String targetTag,
  }) async {
    stopPlaybackPreview();
    final bilingual =
        (sourceTag == 'zh-Hans' && targetTag == 'en') ||
        (sourceTag == 'en' && targetTag == 'zh-Hans');
    if (!bilingual || _disposed) return false;
    _playbackPreviewActive = true;
    try {
      await _ensureRecognizer();
      if (!_playbackPreviewActive || _disposed) return false;
      _playbackPreviewStream = _recognizer!.createStream();
      return true;
    } catch (error) {
      debugPrint('Playback streaming preview unavailable: $error');
      stopPlaybackPreview();
      return false;
    }
  }

  String? acceptPlaybackPreview(Uint8List pcm, int segmentId) {
    final recognizer = _recognizer;
    if (!_playbackPreviewActive || recognizer == null || pcm.length < 2) {
      return null;
    }
    try {
      if (_playbackPreviewSegmentId != segmentId) {
        _resetPlaybackPreviewStream(segmentId);
      }
      final stream = _playbackPreviewStream;
      if (stream == null) return null;
      final samples = Float32List(pcm.length ~/ 2);
      for (var i = 0; i < samples.length; i++) {
        final value = pcm[i * 2] | (pcm[i * 2 + 1] << 8);
        samples[i] = _toFloatSample(value);
        if (samples[i].abs() >= 0.018) _playbackPreviewVoicedSamples++;
      }
      stream.acceptWaveform(samples: samples, sampleRate: 16000);
      while (recognizer.isReady(stream)) {
        recognizer.decode(stream);
      }
      if (_playbackPreviewVoicedSamples < 160) return null;
      final text = recognizer.getResult(stream).text.trim();
      if (text.isEmpty || text == _playbackPreviewLastPartial) return null;
      _playbackPreviewLastPartial = text;
      return text;
    } catch (error) {
      debugPrint('Playback streaming preview failed: $error');
      stopPlaybackPreview();
      return null;
    }
  }

  void finishPlaybackPreviewSegment(int segmentId) {
    if (_playbackPreviewSegmentId == segmentId) {
      _resetPlaybackPreviewStream(segmentId + 1);
    }
  }

  void stopPlaybackPreview() {
    _playbackPreviewActive = false;
    _playbackPreviewStream?.free();
    _playbackPreviewStream = null;
    _playbackPreviewSegmentId = null;
    _playbackPreviewVoicedSamples = 0;
    _playbackPreviewLastPartial = null;
  }

  void _resetPlaybackPreviewStream(int segmentId) {
    _playbackPreviewStream?.free();
    _playbackPreviewStream = _recognizer?.createStream();
    _playbackPreviewSegmentId = segmentId;
    _playbackPreviewVoicedSamples = 0;
    _playbackPreviewLastPartial = null;
  }

  /// Decode a short 16 kHz, mono PCM16 WAV captured from permitted app playback.
  /// The caller owns and deletes the temporary recording after recognition.
  Future<Map<String, String>> transcribePlaybackSegment(String path) async {
    final modelDirectory = await _multilingualModelStore
        .installedModelDirectory();
    if (modelDirectory == null) {
      throw PlatformException(
        code: 'multilingual_asr_not_installed',
        message: '本机多语言识别资源尚未准备好。',
      );
    }
    final bytes = await File(path).readAsBytes();
    if (bytes.length < 44 ||
        bytes.length > 20 * 1024 * 1024 ||
        String.fromCharCodes(bytes.sublist(0, 4)) != 'RIFF' ||
        String.fromCharCodes(bytes.sublist(8, 12)) != 'WAVE') {
      throw const FormatException('Invalid playback WAV file.');
    }
    final header = ByteData.sublistView(bytes);
    var offset = 12;
    var dataOffset = -1;
    var dataLength = 0;
    while (offset + 8 <= bytes.length) {
      final chunkName = String.fromCharCodes(bytes.sublist(offset, offset + 4));
      final chunkLength = header.getUint32(offset + 4, Endian.little);
      final next = offset + 8 + chunkLength;
      if (next > bytes.length) break;
      if (chunkName == 'data') {
        dataOffset = offset + 8;
        dataLength = chunkLength;
        break;
      }
      offset = next + (chunkLength & 1);
    }
    if (dataOffset < 0 || dataLength < 2 || dataLength.isOdd) {
      throw const FormatException('Playback WAV contains no PCM samples.');
    }
    final samples = Float32List(dataLength ~/ 2);
    for (var i = 0; i < samples.length; i++) {
      samples[i] = header.getInt16(dataOffset + i * 2, Endian.little) / 32768.0;
    }
    final raw = await _multilingualWorker.transcribe(
      modelDirectory: modelDirectory.path,
      samples: samples,
    );
    return {
      'text': (raw['text'] as String? ?? '').trim(),
      'languageTag':
          normalizeWhisperLanguageTag(raw['language'] as String? ?? '') ?? '',
    };
  }

  /// Warm the primary multilingual model during app startup instead of waiting for the
  /// first microphone press to copy assets and initialize ONNX. The bundled
  /// multilingual Whisper model is the primary recognizer for the supported
  /// translation languages; Zipformer remains a Chinese-English fallback if
  /// the local Whisper runtime cannot initialize on a device.
  Future<void> prepare() async {
    if (defaultTargetPlatform != TargetPlatform.android || _disposed) return;
    var multilingualReady = false;
    try {
      final modelDirectory = await _multilingualModelStore
          .installedModelDirectory();
      if (modelDirectory != null) {
        await _multilingualWorker.prepare(modelDirectory: modelDirectory.path);
        multilingualReady = true;
      }
    } catch (error, stackTrace) {
      debugPrint(
        'Could not prepare the bundled multilingual ASR model: $error',
      );
      debugPrintStack(stackTrace: stackTrace);
    }
    if (!multilingualReady) {
      try {
        await _ensureRecognizer();
      } catch (error, stackTrace) {
        debugPrint(
          'Could not prepare the Chinese-English ASR fallback: $error',
        );
        debugPrintStack(stackTrace: stackTrace);
      }
    }
    MiyinOfflineSpeechSynthesizer.instance.prewarmCoreWorker();
  }

  Future<Map<String, Object?>> startListening({
    required String sessionId,
    String mode = 'translation',
    String? sourceTag,
    String? targetTag,
    bool retainLiveAudio = false,
    void Function(Uint8List pcm)? onLivePcm,
  }) async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      throw PlatformException(
        code: 'voice_unavailable',
        message: '本机离线语音识别目前仅支持安卓应用。',
      );
    }
    if (_sessionId != null) {
      throw PlatformException(
        code: 'speech_already_active',
        message: '已有语音识别正在进行。',
      );
    }
    if (!await _recorder.hasPermission()) {
      throw PlatformException(
        code: 'microphone_permission_denied',
        message: '未获得麦克风权限。请允许觅音使用麦克风后再试。',
      );
    }

    var useMultilingualAsr = await _shouldUseMultilingualAsr(
      sourceTag: sourceTag,
      targetTag: targetTag,
    );
    sherpa.OnlineStream? stream;
    String? multilingualModelPath;
    final bilingualVideoPreview =
        mode == 'video' &&
        ((sourceTag == 'zh-Hans' && targetTag == 'en') ||
            (sourceTag == 'en' && targetTag == 'zh-Hans'));
    if (useMultilingualAsr) {
      try {
        final modelDirectory = await _multilingualModelStore
            .installedModelDirectory();
        if (modelDirectory == null) {
          throw PlatformException(
            code: 'multilingual_asr_not_ready',
            message: '觅音内置的多语言识别资源尚未准备好，请稍后重试。',
          );
        }
        await _multilingualWorker.prepare(modelDirectory: modelDirectory.path);
        multilingualModelPath = modelDirectory.path;
        if (bilingualVideoPreview) {
          try {
            await _ensureRecognizer();
            stream = _recognizer!.createStream();
          } catch (error) {
            debugPrint('Real-time bilingual preview unavailable: $error');
            stream = null;
          }
        } else {
          if (!_playbackPreviewActive) {
            _recognizer?.free();
            _recognizer = null;
          }
        }
      } on PlatformException {
        final isChineseEnglishPair =
            (sourceTag == 'zh-Hans' && targetTag == 'en') ||
            (sourceTag == 'en' && targetTag == 'zh-Hans');
        if (!isChineseEnglishPair) rethrow;
        useMultilingualAsr = false;
      }
    }
    if (!useMultilingualAsr) {
      await _multilingualWorker.close();
      await _ensureRecognizer();
      stream = _recognizer!.createStream();
    }
    _sessionId = sessionId;
    _stream = stream;
    _usesMultilingualAsr = useMultilingualAsr;
    _multilingualModelPath = multilingualModelPath;
    _videoMode = mode == 'video';
    _chatMode = mode == 'chat';
    _chatVoicedSamples = 0;
    _chatSilenceSamples = 0;
    _retainLiveAudio = mode == 'video' && retainLiveAudio;
    _bilingualPreviewActive = useMultilingualAsr && stream != null;
    _liveSegmentSamples = 0;
    _liveVoicedSamples = 0;
    _liveTrailingSilenceSamples = 0;
    _liveSessionStartedAtMs = DateTime.now().millisecondsSinceEpoch;
    _liveSegmentIndex = 0;
    _multilingualAudioChunks = <Float32List>[];
    _multilingualSampleCount = 0;
    _lastPartial = null;
    _pendingPcmByte = null;
    _stopping = false;
    final streamClosed = Completer<void>();
    _audioStreamClosed = streamClosed;

    try {
      final audio = await _recorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: 16000,
          numChannels: 1,
        ),
      );
      _audioSubscription = audio.listen(
        (bytes) {
          if (mode == 'video') onLivePcm?.call(bytes);
          _acceptAudio(sessionId, bytes);
        },
        onError: (Object error, StackTrace stackTrace) {
          if (!streamClosed.isCompleted) streamClosed.complete();
          unawaited(_failSession(sessionId, '麦克风音频流中断，请重试。'));
        },
        onDone: () {
          if (!streamClosed.isCompleted) streamClosed.complete();
        },
      );
      if (mode != 'video') {
        _recognitionTimer = Timer(_recognitionLimit, () {
          unawaited(_failSession(sessionId, '识别时间过长，已自动停止。'));
        });
      }
      _emit('recognition_ready', sessionId);
      _emit(
        'recognition_listening',
        sessionId,
        recognitionMode: useMultilingualAsr
            ? 'multilingual'
            : 'zh-en-streaming',
      );
      return {
        'status': 'listening',
        'sessionId': sessionId,
        'recognitionMode': useMultilingualAsr
            ? 'multilingual'
            : 'zh-en-streaming',
      };
    } catch (error) {
      await _releaseSession(sessionId, cancelRecorder: true);
      if (error is PlatformException) rethrow;
      throw PlatformException(
        code: 'recognition_start_failed',
        message: '无法启动麦克风识别，请稍后重试。',
      );
    }
  }

  /// Decode a snapshot without stopping the microphone stream. Audio arriving
  /// during the decode remains in the next segment, avoiding recorder gaps in
  /// long meetings. The streaming Zipformer fallback uses the older stop path.
  Future<Map<String, Object?>> takeLiveSegment({
    required String sessionId,
  }) async {
    if (_sessionId != sessionId) return {'status': 'not_active'};
    if (!_usesMultilingualAsr) return {'status': 'unsupported'};
    if (_stopping) return {'status': 'processing'};
    final segmentIndex = _liveSegmentIndex++;
    final sampleCount = _multilingualSampleCount;
    final chunks = _multilingualAudioChunks;
    final bilingualPreview = (_lastPartial ?? '').trim();
    _multilingualAudioChunks = <Float32List>[];
    _multilingualSampleCount = 0;
    _liveSegmentSamples = 0;
    _liveVoicedSamples = 0;
    _liveTrailingSilenceSamples = 0;
    _lastPartial = null;
    if (_bilingualPreviewActive) {
      _stream?.free();
      _stream = _recognizer?.createStream();
    }
    if (sampleCount == 0) {
      return {'status': 'processed', 'text': '', 'languageTag': null,
        'liveSegmentIndex': segmentIndex};
    }
    final samples = Float32List(sampleCount);
    var offset = 0;
    for (final chunk in chunks) {
      samples.setRange(offset, offset + chunk.length, chunk);
      offset += chunk.length;
    }
    if (!_containsLikelySpeech(samples) && bilingualPreview.isEmpty) {
      return {'status': 'processed', 'text': '', 'languageTag': null,
        'liveSegmentIndex': segmentIndex};
    }
    final modelPath = _multilingualModelPath;
    if (modelPath == null) {
      throw PlatformException(
        code: 'multilingual_asr_not_ready',
        message: '多语言识别模型暂时不可用。',
      );
    }
    final result = await _multilingualWorker.transcribe(
      modelDirectory: modelPath,
      samples: samples,
    );
    var finalText = (result['text'] as String? ?? '').trim();
    var languageTag = normalizeWhisperLanguageTag(
      result['language'] as String? ?? '',
    );
    if (_bilingualPreviewActive &&
        _looksLikeEnglishSentence(bilingualPreview) &&
        (languageTag != 'en' ||
            RegExp(r'[\u4e00-\u9fff]').hasMatch(finalText))) {
      finalText = _sentenceCaseEnglish(bilingualPreview);
      languageTag = 'en';
    }
    final audioId = _retainLiveAudio && finalText.isNotEmpty
        ? await _tryRetainLiveAudio(samples)
        : null;
    return {
      'status': 'processed',
      'liveSegmentIndex': segmentIndex,
      'text': finalText,
      'languageTag': languageTag,
      'durationMs': sampleCount * 1000 ~/ 16000,
      if (audioId != null) 'audioId': audioId,
    };
  }

  bool shouldFinalizeLiveSegment({required String sessionId}) {
    if (_sessionId != sessionId || !_videoMode) {
      return false;
    }
    if (!_usesMultilingualAsr) {
      return DateTime.now().millisecondsSinceEpoch - _liveSessionStartedAtMs >=
          5000;
    }
    // The online preview supplies earlier text while a speaker keeps talking;
    // a longer safety cap avoids cutting a sentence every nine seconds.
    if (_liveSegmentSamples >= 16000 * 12) return true;
    // A short reply (for example "hi" or "好") can finish well before one
    // second. Keep a pause before translation, but do not discard the reply.
    return _liveSegmentSamples >= 16000 * 7 ~/ 10 &&
        (_liveVoicedSamples >= 16000 * 15 ~/ 100 ||
            (_lastPartial?.trim().isNotEmpty ?? false)) &&
        _liveTrailingSilenceSamples >= 16000;
  }

  static bool _looksLikeEnglishSentence(String text) {
    final words = RegExp(r'[A-Za-z]+')
        .allMatches(text)
        .map((match) => match.group(0)!.toLowerCase())
        .toList();
    if (words.length < 3 || RegExp(r'[\u4e00-\u9fff]').hasMatch(text)) {
      return false;
    }
    const common = <String>{
      'hello',
      'how',
      'are',
      'you',
      'what',
      'where',
      'when',
      'why',
      'who',
      'the',
      'is',
      'can',
      'could',
      'would',
      'please',
      'thank',
      'thanks',
      'good',
      'morning',
      'evening',
      'today',
      'tomorrow',
      'we',
      'my',
      'your',
    };
    return words.where(common.contains).length >= 2;
  }

  static String _sentenceCaseEnglish(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return trimmed;
    final normalized = trimmed == trimmed.toUpperCase()
        ? trimmed.toLowerCase()
        : trimmed;
    return normalized[0].toUpperCase() + normalized.substring(1);
  }

  Future<Map<String, Object?>> stopListening({
    required String sessionId,
  }) async {
    if (_sessionId != sessionId) return {'status': 'not_active'};
    if (_stopping) return {'status': 'processing', 'sessionId': sessionId};
    _stopping = true;
    _recognitionTimer?.cancel();
    _recognitionTimer = null;
    _emit('recognition_processing', sessionId);

    try {
      final usedMultilingualAsr = _usesMultilingualAsr;
      await _recorder.stop();
      final streamClosed = _audioStreamClosed;
      if (streamClosed != null) {
        try {
          await streamClosed.future.timeout(const Duration(seconds: 3));
        } on TimeoutException {
          debugPrint('Timed out waiting for the microphone stream to drain.');
        }
      }
      await _audioSubscription?.cancel();
      _audioSubscription = null;
      final capturedDurationMs = _multilingualSampleCount * 1000 ~/ 16000;
      String finalText;
      String? detectedLanguage;
      Float32List? audioSamples;
      if (_usesMultilingualAsr) {
        if (_multilingualSampleCount == 0) {
          finalText = '';
        } else {
          final samples = Float32List(_multilingualSampleCount);
          var offset = 0;
          for (final chunk in _multilingualAudioChunks) {
            samples.setRange(offset, offset + chunk.length, chunk);
            offset += chunk.length;
          }
          if (_retainLiveAudio) audioSamples = samples;
          if (_videoMode &&
              !_containsLikelySpeech(samples) &&
              (_lastPartial?.trim().isEmpty ?? true)) {
            finalText = '';
            detectedLanguage = null;
          } else {
            final modelPath = _multilingualModelPath;
            if (modelPath == null) {
              throw PlatformException(
                code: 'multilingual_asr_not_installed',
                message: '觅音内置的多语言识别资源暂时不可用，请重新打开应用后重试。',
              );
            }
            final result = await _multilingualWorker.transcribe(
              modelDirectory: modelPath,
              samples: samples,
            );
            finalText = (result['text'] as String).trim();
            detectedLanguage = normalizeWhisperLanguageTag(
              result['language'] as String,
            );
            final bilingualPreview = (_lastPartial ?? '').trim();
            if (_videoMode &&
                _bilingualPreviewActive &&
                _looksLikeEnglishSentence(bilingualPreview) &&
                (detectedLanguage != 'en' ||
                    RegExp(r'[\u4e00-\u9fff]').hasMatch(finalText))) {
              finalText = _sentenceCaseEnglish(bilingualPreview);
              detectedLanguage = 'en';
            }
          }
        }
      } else {
        if (_retainLiveAudio && _multilingualSampleCount > 0) {
          audioSamples = Float32List(_multilingualSampleCount);
          var offset = 0;
          for (final chunk in _multilingualAudioChunks) {
            audioSamples.setRange(offset, offset + chunk.length, chunk);
            offset += chunk.length;
          }
        }
        final recognizer = _recognizer!;
        final stream = _stream!;
        // Zipformer needs a short silent tail to flush its final acoustic frames.
        stream.acceptWaveform(samples: Float32List(4800), sampleRate: 16000);
        stream.inputFinished();
        while (recognizer.isReady(stream)) {
          recognizer.decode(stream);
        }
        finalText = recognizer.getResult(stream).text.trim();
        final lastPartial = (_lastPartial ?? '').trim();
        if (finalText.isEmpty ||
            (lastPartial.length > finalText.length &&
                lastPartial.startsWith(finalText))) {
          finalText = lastPartial;
        }
        // Zipformer is a bilingual model but does not report which language it
        // heard. Keep that uncertainty explicit instead of guessing from the
        // written script (Japanese kanji is often mistaken for Chinese).
        detectedLanguage = null;
      }
      final text = finalText;
      final audioId = text.isNotEmpty && audioSamples != null
          ? await _tryRetainLiveAudio(audioSamples)
          : null;
      await _releaseSession(sessionId, cancelRecorder: false);
      if (text.isEmpty) {
        _emit('recognition_error', sessionId, message: '没有识别到清晰语音，请按住麦克风再试一次。');
      } else {
        _emit(
          'recognition_final',
          sessionId,
          text: text,
          languageTag: detectedLanguage,
          recognitionMode: usedMultilingualAsr
              ? 'multilingual'
              : 'zh-en-streaming',
        );
      }
      return {
        'status': 'processed',
        'sessionId': sessionId,
        'liveSegmentIndex': _liveSegmentIndex,
        'text': text,
        'languageTag': detectedLanguage,
        'durationMs': capturedDurationMs,
        if (audioId != null) 'audioId': audioId,
      };
    } catch (error) {
      await _releaseSession(sessionId, cancelRecorder: true);
      _emit('recognition_error', sessionId, message: '离线语音识别失败，请重试。');
      if (error is PlatformException) rethrow;
      throw PlatformException(
        code: 'recognition_failed',
        message: '离线语音识别失败，请重试。',
      );
    }
  }

  Future<Map<String, Object?>> cancelListening({
    required String sessionId,
  }) async {
    if (_sessionId == sessionId) {
      await _releaseSession(sessionId, cancelRecorder: true);
      _emit('recognition_cancelled', sessionId);
    }
    return {'status': 'cancelled'};
  }

  Future<String?> _tryRetainLiveAudio(Float32List samples) async {
    try {
      return await LiveAudioArchive.instance.retainMicrophoneSamples(samples);
    } catch (error) {
      debugPrint('Could not retain conference microphone clip: $error');
      return null;
    }
  }

  Future<void> cancelActive() async {
    final sessionId = _sessionId;
    if (sessionId == null) return;
    await cancelListening(sessionId: sessionId);
  }

  Future<void> unloadMultilingualModel() async {
    await cancelActive();
    await _multilingualWorker.close();
  }

  Future<void> dispose() async {
    _disposed = true;
    stopPlaybackPreview();
    await cancelActive();
    await _modelLoad;
    _recognizer?.free();
    _recognizer = null;
    await _multilingualWorker.close();
    await _recorder.dispose();
    await _multilingualModelStore.close();
    await _events.close();
  }

  void _acceptAudio(String sessionId, Uint8List bytes) {
    // The recorder can emit its final PCM chunks while stop() is draining the
    // platform stream. Keep accepting those chunks after stopListening marks
    // the session as stopping, or the final words are silently discarded.
    if (_sessionId != sessionId || bytes.isEmpty) return;
    try {
      final sampleCount =
          (bytes.length + (_pendingPcmByte == null ? 0 : 1)) ~/ 2;
      if (sampleCount == 0) {
        _pendingPcmByte = bytes.first;
        return;
      }
      final samples = Float32List(sampleCount);
      var sourceIndex = 0;
      var sampleIndex = 0;
      final pending = _pendingPcmByte;
      if (pending != null) {
        final value = pending | (bytes[sourceIndex++] << 8);
        samples[sampleIndex++] = _toFloatSample(value);
        _pendingPcmByte = null;
      }
      final completeByteCount = (bytes.length - sourceIndex) & ~1;
      final completeSampleEnd = sourceIndex + completeByteCount;
      while (sourceIndex < completeSampleEnd) {
        final value = bytes[sourceIndex] | (bytes[sourceIndex + 1] << 8);
        samples[sampleIndex++] = _toFloatSample(value);
        sourceIndex += 2;
      }
      if (sourceIndex < bytes.length) _pendingPcmByte = bytes[sourceIndex];
      if (sampleIndex == 0) return;

      final samplesToKeep = sampleIndex == samples.length
          ? samples
          : Float32List.sublistView(samples, 0, sampleIndex);
      if (_chatMode && !_stopping) {
        var energy = 0.0;
        for (final sample in samplesToKeep) { energy += sample * sample; }
        if (energy / samplesToKeep.length >= 0.00012) {
          _chatVoicedSamples += samplesToKeep.length;
          _chatSilenceSamples = 0;
        } else {
          _chatSilenceSamples += samplesToKeep.length;
        }
        if (_chatVoicedSamples >= 4000 && _chatSilenceSamples >= 32000) {
          // Two seconds of silence ends this turn. TTS never records itself:
          // the next microphone turn requires an explicit user tap.
          unawaited(stopListening(sessionId: sessionId).catchError((Object _) => <String, Object?>{}));
        }
      }
      if ((_retainLiveAudio || _videoMode) && !_usesMultilingualAsr) {
        _multilingualAudioChunks.add(samplesToKeep);
        _multilingualSampleCount += sampleIndex;
      }
      if (_usesMultilingualAsr) {
        _multilingualAudioChunks.add(samplesToKeep);
        _multilingualSampleCount += sampleIndex;
        if (_videoMode) _trackLiveSpeech(samplesToKeep);
        final previewStream = _stream;
        final previewRecognizer = _recognizer;
        if (_bilingualPreviewActive &&
            previewStream != null &&
            previewRecognizer != null) {
          previewStream.acceptWaveform(
            samples: samplesToKeep,
            sampleRate: 16000,
          );
          while (previewRecognizer.isReady(previewStream)) {
            previewRecognizer.decode(previewStream);
          }
          final preview = previewRecognizer
              .getResult(previewStream)
              .text
              .trim();
          if (!_stopping && preview.isNotEmpty && preview != _lastPartial) {
            _lastPartial = preview;
            _emit(
              'recognition_partial',
              sessionId,
              text: preview,
              recognitionMode: 'zh-en-streaming-preview',
            );
          }
        }
        return;
      }

      final stream = _stream!;
      final recognizer = _recognizer!;
      stream.acceptWaveform(samples: samplesToKeep, sampleRate: 16000);
      while (recognizer.isReady(stream)) {
        recognizer.decode(stream);
      }
      final text = recognizer.getResult(stream).text.trim();
      if (!_stopping && text.isNotEmpty && text != _lastPartial) {
        _lastPartial = text;
        _emit(
          'recognition_partial',
          sessionId,
          text: text,
          recognitionMode: 'zh-en-streaming',
        );
      }
    } catch (error) {
      unawaited(_failSession(sessionId, '离线语音识别失败，请重试。'));
    }
  }

  void _trackLiveSpeech(Float32List samples) {
    _liveSegmentSamples += samples.length;
    for (var offset = 0; offset < samples.length; offset += 320) {
      final end = (offset + 320).clamp(0, samples.length);
      var energy = 0.0;
      var peaks = 0;
      for (var i = offset; i < end; i++) {
        final value = samples[i];
        energy += value * value;
        if (value.abs() >= 0.018) peaks++;
      }
      final frameLength = end - offset;
      final voiced =
          frameLength > 0 &&
          energy / frameLength >= 0.000049 &&
          peaks * 100 >= frameLength * 2;
      if (voiced) {
        _liveVoicedSamples += frameLength;
        _liveTrailingSilenceSamples = 0;
      } else {
        _liveTrailingSilenceSamples += frameLength;
      }
    }
  }

  Future<bool> _shouldUseMultilingualAsr({
    required String? sourceTag,
    required String? targetTag,
  }) async {
    final isChineseEnglishPair =
        (sourceTag == 'zh-Hans' && targetTag == 'en') ||
        (sourceTag == 'en' && targetTag == 'zh-Hans');
    Directory? multilingualModel;
    try {
      multilingualModel = await _multilingualModelStore
          .installedModelDirectory();
    } on PlatformException {
      if (isChineseEnglishPair) return false;
      rethrow;
    }
    // Use Whisper's acoustic language detection for Chinese-English too. This
    // avoids relying on partial-script heuristics to label short utterances.
    if (multilingualModel != null) return true;
    final needsMultilingual =
        !isChineseEnglishPair && sourceTag != null && targetTag != null;
    if (!needsMultilingual) return false;
    if (multilingualModel == null) {
      throw PlatformException(
        code: 'multilingual_asr_not_installed',
        message: '此版本缺少该语言的内置识别资源，请更新觅音后重试。',
      );
    }
    return true;
  }

  @visibleForTesting
  static String? normalizeWhisperLanguageTag(String language) {
    final normalized = language.trim().toLowerCase().replaceAll('_', '-');
    if (normalized.isEmpty) return null;
    if (normalized == 'zh' ||
        normalized == 'zh-cn' ||
        normalized == 'zh-hans' ||
        normalized == 'chinese') {
      return 'zh-Hans';
    }
    if (normalized == 'zh-tw' ||
        normalized == 'zh-hk' ||
        normalized == 'zh-hant') {
      return 'zh-Hant';
    }
    if (!RegExp(r'^[a-z]{2,3}(?:-[a-z0-9]{2,8})*$').hasMatch(normalized)) {
      return null;
    }
    return normalized;
  }

  static double _toFloatSample(int unsignedSample) {
    final signedSample = unsignedSample >= 0x8000
        ? unsignedSample - 0x10000
        : unsignedSample;
    return signedSample / 32768.0;
  }

  // Whisper may produce words from silence or steady room noise. This light
  // energy gate only applies to meeting snapshots, never push-to-talk speech.
  static bool _containsLikelySpeech(Float32List samples) {
    if (samples.length < 16000 * 35 ~/ 100) return false;
    var energy = 0.0;
    var voiced = 0;
    for (final sample in samples) {
      energy += sample * sample;
      if (sample.abs() > 0.018) voiced++;
    }
    return energy / samples.length >= 0.000049 &&
        voiced * 1000 >= samples.length * 18;
  }

  Future<void> _ensureRecognizer() async {
    if (_recognizer != null) return;
    final pendingLoad = _modelLoad;
    if (pendingLoad != null) {
      await pendingLoad;
      if (_recognizer != null) return;
    }

    final load = _loadRecognizer();
    _modelLoad = load;
    try {
      await load;
    } finally {
      if (identical(_modelLoad, load)) _modelLoad = null;
    }
  }

  Future<void> _loadRecognizer() async {
    try {
      final supportDirectory = await getApplicationSupportDirectory();
      final modelDirectory = Directory(
        '${supportDirectory.path}${Platform.pathSeparator}miyin${Platform.pathSeparator}asr-zh-en',
      );
      await modelDirectory.create(recursive: true);

      for (final entry in _modelFiles.entries) {
        final file = File(
          '${modelDirectory.path}${Platform.pathSeparator}${entry.key}',
        );
        if (await file.exists() && await file.length() == entry.value) continue;
        final asset = await rootBundle.load('$_assetDirectory/${entry.key}');
        final bytes = asset.buffer.asUint8List(
          asset.offsetInBytes,
          asset.lengthInBytes,
        );
        if (bytes.length != entry.value) {
          throw const FormatException('Bundled ASR model has an invalid size.');
        }
        await file.writeAsBytes(bytes, flush: true);
      }

      if (!_bindingsInitialized) {
        sherpa.initBindings();
        _bindingsInitialized = true;
      }
      final separator = Platform.pathSeparator;
      _recognizer = sherpa.OnlineRecognizer(
        sherpa.OnlineRecognizerConfig(
          feat: const sherpa.FeatureConfig(sampleRate: 16000, featureDim: 80),
          model: sherpa.OnlineModelConfig(
            transducer: sherpa.OnlineTransducerModelConfig(
              encoder:
                  '${modelDirectory.path}${separator}encoder-epoch-99-avg-1.int8.onnx',
              decoder:
                  '${modelDirectory.path}${separator}decoder-epoch-99-avg-1.onnx',
              joiner:
                  '${modelDirectory.path}${separator}joiner-epoch-99-avg-1.int8.onnx',
            ),
            tokens: '${modelDirectory.path}${separator}tokens.txt',
            numThreads: 1,
            provider: 'cpu',
            debug: false,
          ),
          enableEndpoint: true,
          decodingMethod: 'greedy_search',
        ),
      );
    } catch (error) {
      _recognizer?.free();
      _recognizer = null;
      throw PlatformException(
        code: 'offline_model_load_failed',
        message: '离线中英识别模型无法加载，请重新安装觅音后再试。',
        details: error.toString(),
      );
    }
  }

  Future<void> _failSession(String sessionId, String message) async {
    if (_sessionId != sessionId) return;
    await _releaseSession(sessionId, cancelRecorder: true);
    _emit('recognition_error', sessionId, message: message);
  }

  Future<void> _releaseSession(
    String sessionId, {
    required bool cancelRecorder,
  }) async {
    if (_sessionId != sessionId) return;
    final stream = _stream;
    final subscription = _audioSubscription;
    _recognitionTimer?.cancel();
    _recognitionTimer = null;
    _audioSubscription = null;
    _audioStreamClosed = null;
    _stream = null;
    _sessionId = null;
    _lastPartial = null;
    _multilingualAudioChunks = <Float32List>[];
    _multilingualSampleCount = 0;
    _bilingualPreviewActive = false;
    _liveSegmentSamples = 0;
    _liveVoicedSamples = 0;
    _liveTrailingSilenceSamples = 0;
    _liveSessionStartedAtMs = 0;
    _pendingPcmByte = null;
    _stopping = false;
    _usesMultilingualAsr = false;
    _multilingualModelPath = null;
    _videoMode = false;
    _chatMode = false;
    _retainLiveAudio = false;
    try {
      if (cancelRecorder) {
        await _recorder.cancel();
      }
    } catch (_) {
      // Continue releasing the stream and clear the active session.
    }
    await subscription?.cancel();
    stream?.free();
  }

  void _emit(
    String type,
    String sessionId, {
    String? text,
    String? message,
    String? languageTag,
    String? recognitionMode,
  }) {
    if (_events.isClosed) return;
    final event = <String, Object?>{'type': type, 'sessionId': sessionId};
    if (text != null) event['text'] = text;
    if (message != null) event['message'] = message;
    if (languageTag != null) event['languageTag'] = languageTag;
    if (recognitionMode != null) event['recognitionMode'] = recognitionMode;
    if (type == 'recognition_partial' && _videoMode) {
      event['liveSegmentIndex'] = _liveSegmentIndex;
    }
    _events.add(event);
  }
}
