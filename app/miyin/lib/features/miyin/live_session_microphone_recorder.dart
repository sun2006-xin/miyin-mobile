import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

/// Copies the PCM stream already used by ASR into one continuous 16 kHz WAV.
/// No second microphone is opened, so the ASR stream keeps ownership of input.
final class LiveSessionMicrophoneRecorder {
  LiveSessionMicrophoneRecorder._(this.sessionId, this._file, this._sink);

  final String sessionId;
  final File _file;
  final IOSink _sink;
  int _pcmBytes = 0;
  bool _closed = false;

  static Future<LiveSessionMicrophoneRecorder> start(String sessionId) async {
    final dir = await getTemporaryDirectory();
    final safeId = sessionId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    final file = File('${dir.path}${Platform.pathSeparator}miyin-live-mic-$safeId.wav');
    final sink = file.openWrite();
    sink.add(Uint8List(44));
    return LiveSessionMicrophoneRecorder._(sessionId, file, sink);
  }

  void add(Uint8List pcm) {
    if (_closed || pcm.isEmpty) return;
    _pcmBytes += pcm.length;
    _sink.add(pcm);
  }

  Future<File?> finish() async {
    if (_closed) return null;
    _closed = true;
    await _sink.flush();
    await _sink.close();
    if (_pcmBytes < 2) {
      await _file.delete();
      return null;
    }
    final header = ByteData(44);
    void ascii(int at, String value) {
      for (var index = 0; index < value.length; index++) {
        header.setUint8(at + index, value.codeUnitAt(index));
      }
    }
    ascii(0, 'RIFF');
    header.setUint32(4, _pcmBytes + 36, Endian.little);
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
    header.setUint32(40, _pcmBytes, Endian.little);
    // Build the final file by streaming, because Android append mode does not
    // guarantee an in-place rewrite of the RIFF header at position zero.
    final complete = File('${_file.path}.complete.wav');
    final output = complete.openWrite();
    try {
      output.add(header.buffer.asUint8List());
      await output.addStream(_file.openRead(44));
      await output.flush();
    } finally {
      await output.close();
    }
    await _file.delete();
    return complete;
  }

  Future<void> discard() async {
    final file = await finish();
    if (file != null && await file.exists()) await file.delete();
  }
}
