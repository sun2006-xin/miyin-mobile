import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

/// Keeps the non-streaming Whisper decoder off Flutter's UI isolate.
final class MiyinMultilingualAsrWorker {
  Isolate? _isolate;
  SendPort? _commands;
  Future<void>? _starting;

  /// Loads the bundled model in the worker isolate before the first recording.
  Future<void> prepare({required String modelDirectory}) =>
      _ensureStarted(modelDirectory);

  Future<Map<String, Object?>> transcribe({
    required String modelDirectory,
    required Float32List samples,
  }) async {
    await _ensureStarted(modelDirectory);
    final commands = _commands;
    if (commands == null) {
      throw PlatformException(
        code: 'multilingual_asr_unavailable',
        message: '多语言识别模型没有准备好，请稍后重试。',
      );
    }
    final reply = ReceivePort();
    try {
      final bytes = Uint8List.view(
        samples.buffer,
        samples.offsetInBytes,
        samples.lengthInBytes,
      );
      commands.send({
        'replyTo': reply.sendPort,
        'audio': TransferableTypedData.fromList([bytes]),
      });
      final raw = await reply.first.timeout(const Duration(minutes: 4));
      if (raw is! Map || raw['ok'] != true) {
        throw PlatformException(
          code: 'multilingual_asr_failed',
          message: '多语言离线识别失败，请重试。',
          details: raw is Map ? raw['details'] : null,
        );
      }
      return {
        'text': raw['text'] is String ? raw['text'] as String : '',
        'language': raw['language'] is String ? raw['language'] as String : '',
      };
    } on TimeoutException {
      await close();
      throw PlatformException(
        code: 'multilingual_asr_timeout',
        message: '多语言识别时间过长，请缩短语音后重试。',
      );
    } finally {
      reply.close();
    }
  }

  Future<void> close() async {
    final commands = _commands;
    _commands = null;
    final isolate = _isolate;
    if (commands != null && isolate != null) {
      final reply = ReceivePort();
      commands.send({'type': 'shutdown', 'replyTo': reply.sendPort});
      try {
        await reply.first.timeout(const Duration(seconds: 4));
      } on TimeoutException {
        isolate.kill(priority: Isolate.immediate);
      } finally {
        reply.close();
      }
    } else {
      isolate?.kill(priority: Isolate.immediate);
    }
    _isolate = null;
  }

  Future<void> _ensureStarted(String modelDirectory) async {
    if (_commands != null) return;
    final pending = _starting;
    if (pending != null) {
      await pending;
      return;
    }
    final start = _start(modelDirectory);
    _starting = start;
    try {
      await start;
    } finally {
      if (identical(_starting, start)) _starting = null;
    }
  }

  Future<void> _start(String modelDirectory) async {
    final ready = ReceivePort();
    try {
      _isolate = await Isolate.spawn<Map<String, Object?>>(_whisperWorkerMain, {
        'replyTo': ready.sendPort,
        'modelDirectory': modelDirectory,
      }, debugName: 'miyin-whisper-base');
      final raw = await ready.first.timeout(const Duration(minutes: 3));
      if (raw is! Map || raw['type'] != 'ready' || raw['port'] is! SendPort) {
        throw StateError(
          raw is Map ? '${raw['details'] ?? raw['type']}' : 'bad handshake',
        );
      }
      _commands = raw['port'] as SendPort;
    } on TimeoutException {
      _isolate?.kill(priority: Isolate.immediate);
      _isolate = null;
      throw PlatformException(
        code: 'multilingual_asr_initialization_timeout',
        message: '多语言模型加载时间过长，请稍后重试。',
      );
    } catch (error) {
      _isolate?.kill(priority: Isolate.immediate);
      _isolate = null;
      throw PlatformException(
        code: 'multilingual_asr_initialization_failed',
        message: '多语言离线识别模型无法加载。',
        details: error.toString(),
      );
    } finally {
      ready.close();
    }
  }
}

void _whisperWorkerMain(Map<String, Object?> initialization) {
  final startup = initialization['replyTo'] as SendPort;
  final modelDirectory = initialization['modelDirectory'] as String;
  final commands = ReceivePort();
  sherpa.OfflineRecognizer? recognizer;
  try {
    sherpa.initBindings();
    final separator = Platform.pathSeparator;
    recognizer = sherpa.OfflineRecognizer(
      sherpa.OfflineRecognizerConfig(
        feat: const sherpa.FeatureConfig(sampleRate: 16000, featureDim: 80),
        model: sherpa.OfflineModelConfig(
          whisper: sherpa.OfflineWhisperModelConfig(
            encoder: '$modelDirectory${separator}base-encoder.int8.onnx',
            decoder: '$modelDirectory${separator}base-decoder.int8.onnx',
            language: '',
            task: 'transcribe',
          ),
          tokens: '$modelDirectory${separator}base-tokens.txt',
          numThreads: 2,
          debug: false,
          provider: 'cpu',
          modelType: 'whisper',
        ),
        decodingMethod: 'greedy_search',
      ),
    );
    startup.send({'type': 'ready', 'port': commands.sendPort});
  } catch (error) {
    recognizer?.free();
    startup.send({'type': 'error', 'details': error.toString()});
    commands.close();
    return;
  }

  commands.listen((dynamic raw) {
    if (raw is! Map) return;
    final replyTo = raw['replyTo'];
    if (raw['type'] == 'shutdown') {
      recognizer?.free();
      recognizer = null;
      commands.close();
      if (replyTo is SendPort) replyTo.send({'ok': true});
      Isolate.exit();
    }
    if (replyTo is! SendPort || raw['audio'] is! TransferableTypedData) {
      if (replyTo is SendPort) {
        replyTo.send({'ok': false, 'details': 'Invalid audio request.'});
      }
      return;
    }
    sherpa.OfflineStream? stream;
    try {
      final data = (raw['audio'] as TransferableTypedData).materialize();
      if (data.lengthInBytes == 0 || data.lengthInBytes % 4 != 0) {
        throw const FormatException('Invalid PCM audio payload.');
      }
      final samples = Float32List.view(data, 0, data.lengthInBytes ~/ 4);
      stream = recognizer!.createStream();
      stream.acceptWaveform(samples: samples, sampleRate: 16000);
      recognizer!.decode(stream);
      final result = recognizer!.getResult(stream);
      replyTo.send({'ok': true, 'text': result.text, 'language': result.lang});
    } catch (error) {
      replyTo.send({'ok': false, 'details': error.toString()});
    } finally {
      stream?.free();
    }
  });
}
