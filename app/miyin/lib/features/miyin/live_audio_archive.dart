import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// App-private, on-device WAV clips linked to saved live subtitle entries.
final class LiveAudioArchive {
  LiveAudioArchive._();

  static final instance = LiveAudioArchive._();
  static const _channel = MethodChannel('com.miyin.app/live-audio');
  static final _validId = RegExp(r'^[0-9a-f]{24}$');
  final _random = Random.secure();
  int _playbackGeneration = 0;

  Future<Directory> _directory() async {
    final root = await getApplicationSupportDirectory();
    return Directory('${root.path}${Platform.pathSeparator}live-audio')
      ..createSync(recursive: true);
  }

  Future<Directory> _pendingDirectory() async {
    final root = await getApplicationSupportDirectory();
    return Directory('${root.path}${Platform.pathSeparator}live-audio-pending')
      ..createSync(recursive: true);
  }

  String _nextId() {
    final bytes = List<int>.generate(12, (_) => _random.nextInt(256));
    return bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  }

  Future<String> retainPlaybackFile(String sourcePath) async {
    final cache = await getTemporaryDirectory();
    final allowed = Directory(
      '${cache.path}${Platform.pathSeparator}live-playback',
    ).absolute.path;
    final source = File(sourcePath).absolute;
    if (!source.path.startsWith('$allowed${Platform.pathSeparator}') ||
        !source.path.endsWith('.wav') ||
        !await source.exists()) {
      throw const FormatException('无效的同传音频片段。');
    }
    final id = _nextId();
    final target = File(
      '${(await _pendingDirectory()).path}${Platform.pathSeparator}$id.wav',
    );
    await source.copy(target.path);
    return id;
  }

  Future<String> retainMicrophoneSamples(Float32List samples) async {
    if (samples.isEmpty) throw const FormatException('空音频无法保存。');
    final id = _nextId();
    final target = File(
      '${(await _pendingDirectory()).path}${Platform.pathSeparator}$id.wav',
    );
    final header = ByteData(44);
    void ascii(int offset, String value) {
      for (var i = 0; i < value.length; i++) {
        header.setUint8(offset + i, value.codeUnitAt(i));
      }
    }

    final byteCount = samples.length * 2;
    ascii(0, 'RIFF');
    header.setUint32(4, 36 + byteCount, Endian.little);
    ascii(8, 'WAVE');
    ascii(12, 'fmt ');
    header.setUint32(16, 16, Endian.little);
    header.setUint16(20, 1, Endian.little);
    header.setUint16(22, 1, Endian.little);
    header.setUint32(24, 16000, Endian.little);
    header.setUint32(28, 32000, Endian.little);
    header.setUint16(32, 2, Endian.little);
    header.setUint16(34, 16, Endian.little);
    ascii(36, 'data');
    header.setUint32(40, byteCount, Endian.little);
    final pcm = ByteData(byteCount);
    for (var i = 0; i < samples.length; i++) {
      final sample = (samples[i].clamp(-1.0, 1.0) * 32767).round();
      pcm.setInt16(i * 2, sample, Endian.little);
    }
    final sink = target.openWrite();
    sink.add(header.buffer.asUint8List());
    sink.add(pcm.buffer.asUint8List());
    await sink.flush();
    await sink.close();
    return id;
  }

  Future<Map<String, Object?>> play(String audioId) async {
    final generation = ++_playbackGeneration;
    final file = await _file(audioId);
    if (!await file.exists()) throw const FormatException('这段本机音频已不存在。');
    if (generation != _playbackGeneration) return {'status': 'stopped'};
    final result = await _channel.invokeMapMethod<String, Object?>('play', {
      'path': file.path,
    });
    return result ?? {'status': 'playing'};
  }

  Future<void> stop() {
    _playbackGeneration++;
    return _channel.invokeMethod<void>('stop');
  }

  Future<void> commit(Iterable<String> audioIds) async {
    final directory = await _directory();
    for (final id in audioIds.toSet()) {
      if (!_validId.hasMatch(id)) continue;
      final pending = File(
        '${(await _pendingDirectory()).path}${Platform.pathSeparator}$id.wav',
      );
      if (!await pending.exists()) continue;
      await pending.rename('${directory.path}${Platform.pathSeparator}$id.wav');
    }
  }

  Future<void> delete(Iterable<String> audioIds) async {
    for (final id in audioIds.toSet()) {
      if (!_validId.hasMatch(id)) continue;
      for (final directory in <Directory>[
        await _directory(),
        await _pendingDirectory(),
      ]) {
        final file = File('${directory.path}${Platform.pathSeparator}$id.wav');
        if (await file.exists()) await file.delete();
      }
    }
  }

  /// Incomplete sessions were never committed to a history record.
  Future<void> purgePending() async {
    final directory = await _pendingDirectory();
    await for (final entry in directory.list(followLinks: false)) {
      if (entry is File &&
          _validId.hasMatch(
            entry.uri.pathSegments.last.replaceFirst('.wav', ''),
          ) &&
          entry.path.endsWith('.wav')) {
        try {
          await entry.delete();
        } catch (_) {
          /* a recording may still be open */
        }
      }
    }
  }

  Future<File> _file(String audioId) async {
    if (!_validId.hasMatch(audioId)) {
      throw const FormatException('无效的本机音频编号。');
    }
    final archived = File(
      '${(await _directory()).path}${Platform.pathSeparator}$audioId.wav',
    );
    if (await archived.exists()) return archived;
    return File(
      '${(await _pendingDirectory()).path}${Platform.pathSeparator}$audioId.wav',
    );
  }
}
