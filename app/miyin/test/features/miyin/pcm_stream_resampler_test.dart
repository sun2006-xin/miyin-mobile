import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:miyin_app/features/miyin/pcm_stream_resampler.dart';

Uint8List encode(List<int> samples) {
  final bytes = Uint8List(samples.length * 2),
      data = ByteData(samples.length * 2);
  for (var i = 0; i < samples.length; i++) {
    data.setInt16(i * 2, samples[i], Endian.little);
  }
  bytes.setAll(0, data.buffer.asUint8List());
  return bytes;
}

Uint8List resample(Uint8List input, int rate, int chunkSamples) {
  final resampler = MiyinPcmStreamResampler(inputRate: rate),
      out = BytesBuilder();
  for (var offset = 0; offset < input.length; offset += chunkSamples * 2) {
    out.add(
      resampler.add(
        Uint8List.sublistView(
          input,
          offset,
          (offset + chunkSamples * 2).clamp(0, input.length),
        ),
      ),
    );
  }
  out.add(resampler.finish());
  expect(resampler.finish(), isEmpty);
  return out.toBytes();
}

void main() {
  test('24k upsampling is independent of arbitrary PCM chunk boundaries', () {
    final input = encode(
      List.generate(50003, (i) => ((i * 137) % 60001) - 30000),
    );
    final whole = resample(input, 24000, 50003);
    for (final chunk in [1, 7, 83, 32768]) {
      expect(resample(input, 24000, chunk), whole);
    }
    expect(whole.length ~/ 2, 50003 * 44100 ~/ 24000);
  });
  test('44100 PCM is unchanged including its drained final frame', () {
    final input = encode([-32768, -12000, 0, 32767, 20]);
    expect(resample(input, 44100, 1), input);
  });
  test(
    'independent rates preserve each segment duration to within one frame',
    () {
      for (final rate in [16000, 24000, 44100, 48000]) {
        final input = encode(List.filled(rate + 7, 4000)),
            output = resample(input, rate, 257);
        expect(output.length ~/ 2, (rate + 7) * 44100 ~/ rate);
        final data = ByteData.sublistView(output);
        for (var i = 0; i < output.length; i += 2) {
          expect(data.getInt16(i, Endian.little), 4000);
        }
      }
    },
  );
  test(
    'partial PCM sample is rejected rather than shifting every following frame',
    () {
      final r = MiyinPcmStreamResampler(inputRate: 24000);
      expect(() => r.add(Uint8List(3)), throwsArgumentError);
    },
  );
}
