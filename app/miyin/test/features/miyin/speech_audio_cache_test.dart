import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miyin_app/features/miyin/offline_speech_synthesizer.dart';
import 'package:miyin_app/features/miyin/speech_audio_cache.dart';

void main() {
  test(
    'cache owns bytes independently of the input and exposes read-only data',
    () {
      final cache = MiyinSpeechAudioCache();
      final input = Uint8List.fromList([1, 2, 3]);
      cache.put('speech', input);
      input[0] = 9;
      expect(cache.get('speech'), [1, 2, 3]);
      expect(() => cache.get('speech')![0] = 9, throwsUnsupportedError);
    },
  );
  test(
    'cached playback rearms resident core and multilingual idle release',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      for (final multilingual in [false, true]) {
        final commands = ReceivePort();
        commands.listen((dynamic request) {
          ((request as Map)['replyTo'] as SendPort).send({'ok': true});
        });
        final cache = MiyinSpeechAudioCache();
        final pcm = MiyinBoundedPcmCollector()..add(Uint8List(4), 44100);
        cache.put(
          MiyinSpeechAudioCache.key('zh-Hans', 'hello', 1, 0, 'melo'),
          pcm.finish()!,
        );
        final synth = MiyinOfflineSpeechSynthesizer.forTesting(
          cache: cache,
          coreCommands: multilingual ? null : commands.sendPort,
          multilingualCommands: multilingual ? commands.sendPort : null,
        );
        await synth.synthesize(
          sessionId: 'test',
          languageTag: 'zh-Hans',
          text: 'hello',
          speed: 1,
          onAudio: (_, _, _) async {},
        );
        expect(synth.hasScheduledCoreIdleRelease, !multilingual);
        expect(synth.hasScheduledMultilingualIdleRelease, multilingual);
        await synth.dispose();
        expect(synth.hasScheduledCoreIdleRelease, isFalse);
        expect(synth.hasScheduledMultilingualIdleRelease, isFalse);
        commands.close();
      }
    },
  );
  test(
    'byte budget evicts even before entry limit, replacement counts once',
    () {
      final cache = MiyinSpeechAudioCache(maxEntries: 4, maxBytes: 100);
      cache.put('a', Uint8List(60));
      cache.put('b', Uint8List(60));
      expect(cache.get('a'), isNull);
      cache.put('b', Uint8List(80));
      expect(cache.byteLength, 80);
      expect(cache.length, 1);
    },
  );
  test(
    'cached first segment preserves pending preparation of next segment',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final cache = MiyinSpeechAudioCache();
      final collector = MiyinBoundedPcmCollector();
      collector.add(Uint8List(8), 44100);
      final wave = collector.finish()!;
      cache.put(
        MiyinSpeechAudioCache.key('zh-Hans', 'first', 1, 0, 'melo'),
        wave,
      );
      final busy = Completer<void>();
      final synth = MiyinOfflineSpeechSynthesizer.forTesting(
        cache: cache,
        workerBusy: busy.future,
      );
      final preparing = synth.prepareUtterance(
        languageTag: 'zh-Hans',
        text: 'second',
        speed: 1,
        speakerId: 0,
        provider: 'melo',
      );
      await synth.synthesize(
        sessionId: 'test',
        languageTag: 'zh-Hans',
        text: 'first',
        speed: 1,
        onAudio: (_, _, _) async {},
      );
      // Stand in for completion of an already-running worker before this queued
      // preparation enters; it must remain current and reuse the ready segment.
      cache.put(
        MiyinSpeechAudioCache.key('zh-Hans', 'second', 1, 0, 'melo'),
        wave,
      );
      busy.complete();
      expect((await preparing)['status'], 'ready');
      final second = await synth.synthesize(
        sessionId: 'test',
        languageTag: 'zh-Hans',
        text: 'second',
        speed: 1,
        onAudio: (_, _, _) async {},
      );
      expect(second['cacheHit'], isTrue);
      await expectLater(
        synth.synthesize(
          sessionId: 'disposed',
          languageTag: 'zh-Hans',
          text: 'second',
          speed: 1,
          onAudio: (_, _, _) async {
            await synth.dispose();
          },
        ),
        throwsA(
          isA<PlatformException>().having(
            (e) => e.code,
            'code',
            'tts_synthesis_cancelled',
          ),
        ),
      );
      expect(synth.hasScheduledCoreIdleRelease, isFalse);
      expect(synth.hasScheduledMultilingualIdleRelease, isFalse);
    },
  );
  test('LRU retains segments and evicts by recency and bytes', () {
    final cache = MiyinSpeechAudioCache(maxEntries: 2, maxBytes: 100);
    cache.put('a', Uint8List(48));
    cache.put('b', Uint8List(48));
    expect(cache.get('a'), isNotNull);
    cache.put('c', Uint8List(48));
    expect(cache.get('b'), isNull);
    expect(cache.get('a'), isNotNull);
    expect(cache.put('large', Uint8List(101)), isFalse);
    expect(cache.byteLength, 96);
    cache.clear();
    expect(cache.byteLength, 0);
  });
  test('keys include each voice dimension without delimiter collisions', () {
    String key({
      String language = 'zh-Hans',
      String provider = 'melo',
      int speaker = 0,
      double speed = 1,
      String text = '你好',
    }) => MiyinSpeechAudioCache.key(language, text, speed, speaker, provider);
    expect(
      {
        key(),
        key(language: 'en'),
        key(provider: 'supertonic'),
        key(speaker: 1),
        key(speed: 1.1),
        key(text: '你好。'),
      }.length,
      6,
    );
    expect(
      key(language: 'a|b', provider: 'c'),
      isNot(key(language: 'a', provider: 'b|c')),
    );
  });
  test('PCM collector writes canonical WAV and abandons oversized audio', () {
    final collector = MiyinBoundedPcmCollector(maxWaveBytes: 50);
    collector.add(Uint8List.fromList([1, 2]), 22050);
    collector.add(Uint8List.fromList([3, 4]), 22050);
    final wave = collector.finish()!;
    final header = ByteData.sublistView(wave);
    expect(String.fromCharCodes(wave.sublist(0, 4)), 'RIFF');
    expect(header.getUint32(24, Endian.little), 22050);
    expect(header.getUint32(40, Endian.little), 4);
    expect(wave.sublist(44), [1, 2, 3, 4]);
    collector.add(Uint8List(4), 22050);
    expect(collector.finish(), isNull);
  });
  test(
    'cache bypasses busy worker, repeats without inference and cancels',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final cache = MiyinSpeechAudioCache();
      final collector = MiyinBoundedPcmCollector();
      collector.add(Uint8List(70000), 44100);
      cache.put(
        MiyinSpeechAudioCache.key('zh-Hans', '你好', 1, 0, 'melo'),
        collector.finish()!,
      );
      final busy = Completer<void>();
      final synth = MiyinOfflineSpeechSynthesizer.forTesting(
        cache: cache,
        workerBusy: busy.future,
      );
      var chunks = 0;
      for (var attempt = 0; attempt < 2; attempt++) {
        final result = await synth
            .synthesize(
              sessionId: 'test',
              languageTag: 'zh-Hans',
              text: '你好',
              speed: 1,
              onAudio: (pcm, rate, generation) async {
                chunks++;
              },
            )
            .timeout(const Duration(seconds: 1));
        expect(result['cacheHit'], isTrue);
      }
      expect(chunks, 4);
      chunks = 0;
      await expectLater(
        synth.synthesize(
          sessionId: 'test',
          languageTag: 'zh-Hans',
          text: '你好',
          speed: 1,
          onAudio: (pcm, rate, generation) async {
            chunks++;
            synth.cancelPending();
          },
        ),
        throwsA(
          isA<PlatformException>().having(
            (e) => e.code,
            'code',
            'tts_synthesis_cancelled',
          ),
        ),
      );
      expect(chunks, 1);
      busy.complete();
      await synth.dispose();
      expect(cache.byteLength, 0);
    },
  );
}
