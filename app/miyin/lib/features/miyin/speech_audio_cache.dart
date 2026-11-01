import 'dart:convert';
import 'dart:typed_data';

/// Process-local generated audio only. Entries own their immutable WAV bytes.
final class MiyinSpeechAudioCache {
  MiyinSpeechAudioCache({this.maxEntries = 4, this.maxBytes = 8 * 1024 * 1024});
  final int maxEntries;
  final int maxBytes;
  final _entries = <String, Uint8List>{};
  int _bytes = 0;
  int get byteLength => _bytes;
  int get length => _entries.length;

  static String key(
    String language,
    String text,
    double speed,
    int speaker,
    String provider,
  ) => jsonEncode([language, provider, speaker, speed, text]);

  Uint8List? get(String key) {
    final wave = _entries.remove(key);
    if (wave != null) _entries[key] = wave;
    return wave;
  }

  bool put(String key, Uint8List wave) {
    if (maxEntries <= 0 || wave.length > maxBytes) return false;
    final previous = _entries.remove(key);
    if (previous != null) _bytes -= previous.length;
    while (_entries.isNotEmpty &&
        (_entries.length >= maxEntries || _bytes + wave.length > maxBytes)) {
      _bytes -= _entries.remove(_entries.keys.first)!.length;
    }
    _entries[key] = Uint8List.fromList(wave).asUnmodifiableView();
    _bytes += wave.length;
    return true;
  }

  void clear() {
    _entries.clear();
    _bytes = 0;
  }
}

/// Collects PCM already normalized by the worker; never changes playback bytes.
/// Oversized/inconsistent audio disables caching without failing playback.
final class MiyinBoundedPcmCollector {
  MiyinBoundedPcmCollector({this.maxWaveBytes = 8 * 1024 * 1024});
  final int maxWaveBytes;
  final _chunks = <Uint8List>[];
  int _length = 0;
  int? _rate;
  bool _abandoned = false;
  void add(Uint8List pcm, int sampleRate) {
    if (_abandoned) return;
    if (sampleRate <= 0 ||
        pcm.length.isOdd ||
        (_rate != null && _rate != sampleRate) ||
        _length + pcm.length + 44 > maxWaveBytes) {
      _abandoned = true;
      _chunks.clear();
      _length = 0;
      return;
    }
    _rate = sampleRate;
    _chunks.add(pcm);
    _length += pcm.length;
  }

  Uint8List? finish() {
    if (_abandoned || _rate == null || _length == 0) return null;
    final wave = Uint8List(44 + _length);
    final header = ByteData.sublistView(wave);
    void label(int offset, String text) =>
        wave.setRange(offset, offset + text.length, text.codeUnits);
    label(0, 'RIFF');
    header.setUint32(4, 36 + _length, Endian.little);
    label(8, 'WAVE');
    label(12, 'fmt ');
    header.setUint32(16, 16, Endian.little);
    header.setUint16(20, 1, Endian.little);
    header.setUint16(22, 1, Endian.little);
    header.setUint32(24, _rate!, Endian.little);
    header.setUint32(28, _rate! * 2, Endian.little);
    header.setUint16(32, 2, Endian.little);
    header.setUint16(34, 16, Endian.little);
    label(36, 'data');
    header.setUint32(40, _length, Endian.little);
    var offset = 44;
    for (final chunk in _chunks) {
      wave.setRange(offset, offset + chunk.length, chunk);
      offset += chunk.length;
    }
    return wave;
  }
}
