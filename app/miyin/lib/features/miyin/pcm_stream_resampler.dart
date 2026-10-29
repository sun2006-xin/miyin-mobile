import 'dart:typed_data';

/// Linear PCM16 resampler with an absolute phase and one-sample lookbehind.
/// Chunk boundaries therefore have exactly the same samples as one full input.
final class MiyinPcmStreamResampler {
  MiyinPcmStreamResampler({required this.inputRate, this.outputRate = 44100}) {
    if (inputRate <= 0 || outputRate <= 0) {
      throw ArgumentError('Invalid PCM rate.');
    }
  }
  final int inputRate;
  final int outputRate;
  int _inputSamples = 0;
  int _outputFrames = 0;
  int _lastSample = 0;
  bool _finished = false;

  Uint8List add(Uint8List bytes) {
    if (_finished) throw StateError('PCM stream has ended.');
    if (bytes.length.isOdd) {
      throw ArgumentError('PCM16 requires complete samples.');
    }
    if (bytes.isEmpty) return Uint8List(0);
    final data = ByteData.sublistView(bytes), start = _inputSamples;
    _inputSamples += bytes.length ~/ 2;
    final samples = <int>[];
    while (true) {
      final position = _outputFrames * inputRate;
      final left = position ~/ outputRate;
      if (left + 1 >= _inputSamples) break;
      final a = left < start
          ? _lastSample
          : data.getInt16((left - start) * 2, Endian.little);
      final b = data.getInt16((left + 1 - start) * 2, Endian.little);
      final fraction = position % outputRate;
      samples.add(
        ((a * (outputRate - fraction) + b * fraction) / outputRate)
            .round()
            .clamp(-32768, 32767),
      );
      _outputFrames++;
    }
    _lastSample = data.getInt16(bytes.length - 2, Endian.little);
    return _encode(samples);
  }

  Uint8List finish() {
    if (_finished) return Uint8List(0);
    _finished = true;
    final target = _inputSamples * outputRate ~/ inputRate;
    final tail = <int>[];
    while (_outputFrames < target) {
      _outputFrames++;
      tail.add(_lastSample);
    }
    return _encode(tail);
  }

  Uint8List _encode(List<int> samples) {
    final bytes = Uint8List(samples.length * 2);
    final data = ByteData.sublistView(bytes);
    for (var i = 0; i < samples.length; i++) {
      data.setInt16(i * 2, samples[i], Endian.little);
    }
    return bytes;
  }
}
