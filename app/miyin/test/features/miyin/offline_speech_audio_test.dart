import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:miyin_app/features/miyin/offline_speech_recognizer.dart';
import 'package:miyin_app/features/miyin/offline_speech_synthesizer.dart';

void main() {
  group('MiyinOfflineSpeechSynthesizer audio preparation', () {
    test('only the newest queued voice prewarm request remains current', () {
      final requests = MiyinSpeechRequestGate();

      final englishVoice = requests.next();
      final frenchVoice = requests.next();
      final latestVoice = requests.next();

      expect(requests.isCurrent(englishVoice), isFalse);
      expect(requests.isCurrent(frenchVoice), isFalse);
      expect(requests.isCurrent(latestVoice), isTrue);
    });

    test('stop invalidates a synthesized request before native playback', () {
      final requests = MiyinSpeechRequestGate();
      final request = requests.next();

      expect(requests.isCurrent(request), isTrue);

      requests.invalidate();

      expect(requests.isCurrent(request), isFalse);
    });

    test(
      'TTS prewarm retries once and only while its request is still latest',
      () {
        const maxAttempts = MiyinOfflineSpeechSynthesizer.prewarmMaxAttempts;
        expect(maxAttempts, 2);
        expect(
          MiyinOfflineSpeechSynthesizer.shouldRetryPrewarm(
            attempt: 1,
            requestGeneration: 8,
            currentGeneration: 8,
          ),
          isTrue,
        );
        expect(
          MiyinOfflineSpeechSynthesizer.shouldRetryPrewarm(
            attempt: 2,
            requestGeneration: 8,
            currentGeneration: 8,
          ),
          isFalse,
        );
        expect(
          MiyinOfflineSpeechSynthesizer.shouldRetryPrewarm(
            attempt: 1,
            requestGeneration: 8,
            currentGeneration: 9,
          ),
          isFalse,
        );
      },
    );

    test('core TTS is ready only after bundled assets pass preparation', () {
      final ready = MiyinOfflineSpeechSynthesizer.coreResourceStatus(
        assetsReady: true,
        initialized: false,
      );
      final unavailable = MiyinOfflineSpeechSynthesizer.coreResourceStatus(
        assetsReady: false,
        initialized: false,
      );

      expect(ready['status'], 'bundled');
      expect(ready['bundled'], isTrue);
      expect(ready['chineseReady'], isTrue);
      expect(ready['englishReady'], isTrue);
      expect(ready['initialized'], isFalse);
      expect(unavailable['status'], 'unavailable');
      expect(unavailable['bundled'], isFalse);
      expect(unavailable['chineseReady'], isFalse);
      expect(unavailable['englishReady'], isFalse);
      expect(unavailable['initialized'], isFalse);
    });

    test('selects one TTS worker for each supported voice route', () {
      expect(
        MiyinOfflineSpeechSynthesizer.coreProviderFor(
          languageTag: 'zh-Hans',
          provider: 'matcha',
        ),
        'matcha',
      );
      for (final provider in ['melo', 'supertonic']) {
        expect(
          MiyinOfflineSpeechSynthesizer.coreProviderFor(
            languageTag: 'zh-Hans',
            provider: provider,
          ),
          'melo',
        );
      }
      for (final language in ['en', 'ja', 'ru', 'fr']) {
        expect(
          MiyinOfflineSpeechSynthesizer.usesMultilingualWorker(
            languageTag: language,
            provider: 'matcha',
          ),
          isTrue,
        );
        expect(
          MiyinOfflineSpeechSynthesizer.coreProviderFor(
            languageTag: language,
            provider: 'matcha',
          ),
          'melo',
        );
      }
      expect(
        MiyinOfflineSpeechSynthesizer.usesMultilingualWorker(
          languageTag: 'zh-Hans',
          provider: 'supertonic',
        ),
        isFalse,
      );
      expect(
        MiyinOfflineSpeechSynthesizer.usesMultilingualWorker(
          languageTag: 'en',
          provider: 'melo',
        ),
        isFalse,
      );
      expect(
        MiyinOfflineSpeechSynthesizer.usesMultilingualWorker(
          languageTag: 'en',
          provider: 'supertonic',
        ),
        isTrue,
      );
      expect(
        MiyinOfflineSpeechSynthesizer.usesMultilingualWorker(
          languageTag: 'fr',
          provider: 'melo',
        ),
        isTrue,
      );
    });

    test('raises quiet generated speech while keeping a safe peak ceiling', () {
      final normalized =
          MiyinOfflineSpeechSynthesizer.normalizeSamplesForPlayback(
            Float32List.fromList([0.1, -0.1, 0.05]),
          );

      expect(normalized[0], closeTo(0.8, 0.001));
      expect(normalized[1], closeTo(-0.8, 0.001));
      expect(normalized[2], closeTo(0.4, 0.001));
      expect(
        normalized.map((sample) => sample.abs()).reduce(_max),
        lessThanOrEqualTo(0.801),
      );
    });

    test('does not amplify digital silence and removes non-finite samples', () {
      final normalized =
          MiyinOfflineSpeechSynthesizer.normalizeSamplesForPlayback(
            Float32List.fromList([0, 0, double.nan, double.infinity]),
          );

      expect(normalized, everyElement(0));
    });

    test('encodes normalized samples as a valid mono PCM16 WAV', () {
      final wav = MiyinOfflineSpeechSynthesizer.encodePcm16Wave(
        Float32List.fromList([0.1, -0.1]),
        22050,
      );
      final header = ByteData.sublistView(wav);

      expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
      expect(String.fromCharCodes(wav.sublist(8, 12)), 'WAVE');
      expect(header.getUint16(22, Endian.little), 1);
      expect(header.getUint32(24, Endian.little), 22050);
      expect(header.getUint16(34, Endian.little), 16);
      expect(header.getUint32(40, Endian.little), 4);
      expect(header.getInt16(44, Endian.little), closeTo(26214, 2));
      expect(header.getInt16(46, Endian.little), closeTo(-26214, 2));
    });
  });

  group('MiyinOfflineSpeechRecognizer detected language labels', () {
    test('normalizes Whisper labels without guessing from transcript text', () {
      expect(
        MiyinOfflineSpeechRecognizer.normalizeWhisperLanguageTag('zh'),
        'zh-Hans',
      );
      expect(
        MiyinOfflineSpeechRecognizer.normalizeWhisperLanguageTag('JA'),
        'ja',
      );
      expect(
        MiyinOfflineSpeechRecognizer.normalizeWhisperLanguageTag('en-US'),
        'en-us',
      );
      expect(
        MiyinOfflineSpeechRecognizer.normalizeWhisperLanguageTag(''),
        isNull,
      );
    });
  });
}

double _max(double left, double right) => left > right ? left : right;
