import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:miyin_app/features/miyin/offline_english_chinese_dictionary.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('OfflineEnglishChineseDictionary', () {
    test(
      'normalizes case, surrounding whitespace, and repeated spaces',
      () async {
        final dictionary = OfflineEnglishChineseDictionary(
          loadAsset: () async => _fixture([
            _entry('New York', [
              _sense(
                synsetId: '09091790-n',
                partOfSpeech: 'noun',
                definition: 'the largest city in New York State',
                translations: ['纽约'],
              ),
            ]),
          ]),
        );

        final result = await dictionary.lookup('  NEW   YORK  ');

        expect(result.query, '  NEW   YORK  ');
        expect(result.entry?.word, 'New York');
        expect(result.senses.single.translations, ['纽约']);
        expect(result.matchedByNormalization, isTrue);
      },
    );

    test(
      'adds only matched US IPA and leaves unmatched headwords explicit',
      () async {
        final dictionary = OfflineEnglishChineseDictionary(
          loadAsset: () async => _fixture([
            _entry('Apple', [
              _sense(
                synsetId: '07739125-n',
                partOfSpeech: 'noun',
                definition: 'a fruit',
                translations: ['苹果'],
              ),
            ]),
            _entry('apricot', [
              _sense(
                synsetId: '07758680-n',
                partOfSpeech: 'noun',
                definition: 'a small orange fruit',
                translations: ['杏'],
              ),
            ]),
          ]),
          loadIpaAsset: () async => _ipaFixture([
            {'word': 'apple', 'ipa': '/ˈæp.əl/'},
          ]),
        );

        final matched = await dictionary.lookup('APPLE');
        final unmatched = await dictionary.lookup('apricot');
        final browse = await dictionary.browseByInitial('A', limit: 10);

        expect(matched.entry?.ipa, '/ˈæp.əl/');
        expect(unmatched.entry?.ipa, isNull);
        expect(browse.ipaByWord, {'Apple': '/ˈæp.əl/'});
      },
    );

    test(
      'retains separate senses, parts of speech, translations, and examples',
      () async {
        final dictionary = OfflineEnglishChineseDictionary(
          loadAsset: () async => _fixture([
            _entry('run', [
              _sense(
                synsetId: '01926366-v',
                partOfSpeech: 'verb',
                definition: 'move fast by using one\'s feet',
                translations: ['跑', '奔跑'],
                examples: ['Don\'t run — you\'ll be out of breath.'],
              ),
              _sense(
                synsetId: '07458407-n',
                partOfSpeech: 'noun',
                definition: 'a race run on foot',
                translations: ['跑步', '赛跑'],
              ),
            ]),
          ]),
        );

        final result = await dictionary.lookup('run');

        expect(result.isFound, isTrue);
        expect(result.senses, hasLength(2));
        expect(result.senses.map((sense) => sense.partOfSpeech), [
          'verb',
          'noun',
        ]);
        expect(result.senses.first.translations, ['跑', '奔跑']);
        expect(result.senses.first.examples, [
          'Don\'t run — you\'ll be out of breath.',
        ]);
        expect(result.senses.last.examples, isEmpty);
      },
    );

    test('returns a clear miss for unknown and empty input', () async {
      final dictionary = OfflineEnglishChineseDictionary(
        loadAsset: () async => _fixture([
          _entry('book', [
            _sense(
              synsetId: '06410904-n',
              partOfSpeech: 'noun',
              definition: 'a written work',
              translations: ['书'],
            ),
          ]),
        ]),
      );

      final unknown = await dictionary.lookup('moonwalking');
      final empty = await dictionary.lookup('   ');

      expect(unknown.isFound, isFalse);
      expect(unknown.entry, isNull);
      expect(empty.isFound, isFalse);
      expect(empty.normalizedQuery, isEmpty);
    });

    test(
      'supports exact Chinese lookup and returns grouped headword entries',
      () async {
        final dictionary = OfflineEnglishChineseDictionary(
          loadAsset: () async => _fixture([
            _entry('bank', [
              _sense(
                synsetId: '09213565-n',
                partOfSpeech: 'noun',
                definition: 'a financial institution',
                translations: ['银行'],
                examples: ['the bank is open'],
              ),
              _sense(
                synsetId: '08613683-n',
                partOfSpeech: 'noun',
                definition: 'sloping land beside a body of water',
                translations: ['河岸'],
              ),
            ]),
            _entry('banker', [
              _sense(
                synsetId: '09813696-n',
                partOfSpeech: 'noun',
                definition: 'a financial institution employee',
                translations: ['银行家'],
              ),
            ]),
          ]),
        );

        final result = await dictionary.lookupChinese(' 银行 ');

        expect(result.isFound, isTrue);
        expect(result.entries.map((entry) => entry.word), ['bank']);
        expect(result.entries.single.senses, hasLength(2));
      },
    );

    test(
      'loads and indexes the bundled dataset for real English-Chinese terms',
      () async {
        final sourceFile = File(OfflineEnglishChineseDictionary.assetPath);
        final dictionary = OfflineEnglishChineseDictionary(
          loadAsset: () => sourceFile.readAsString(),
        );

        final bank = await dictionary.lookup('bank');
        final child = await dictionary.lookup('child');

        expect(bank.isFound, isTrue);
        expect(bank.senses, isNotEmpty);
        expect(
          bank.senses.every((sense) => sense.translations.isNotEmpty),
          isTrue,
        );
        expect(
          bank.senses.expand((sense) => sense.translations).contains('银行'),
          isTrue,
        );
        expect(child.isFound, isTrue);
        expect(
          child.senses.expand((sense) => sense.translations).contains('孩子'),
          isTrue,
        );
      },
    );

    test('loads the data only once, even when lookups overlap', () async {
      var loadCount = 0;
      final dictionary = OfflineEnglishChineseDictionary(
        loadAsset: () async {
          loadCount++;
          await Future<void>.delayed(Duration.zero);
          return _fixture([
            _entry('book', [
              _sense(
                synsetId: '06410904-n',
                partOfSpeech: 'noun',
                definition: 'a written work',
                translations: ['书'],
              ),
            ]),
          ]);
        },
      );

      await Future.wait([dictionary.lookup('book'), dictionary.lookup('BOOK')]);

      expect(loadCount, 1);
    });

    test('browses headwords alphabetically with a bounded page', () async {
      final dictionary = OfflineEnglishChineseDictionary(
        loadAsset: () async => _fixture([
          _entry('banana', [
            _sense(
              synsetId: '07775375-n',
              partOfSpeech: 'noun',
              definition: 'an edible fruit',
              translations: ['香蕉'],
            ),
          ]),
          _entry('apricot', [
            _sense(
              synsetId: '07758680-n',
              partOfSpeech: 'noun',
              definition: 'a small orange fruit',
              translations: ['杏'],
            ),
          ]),
          _entry('apple', [
            _sense(
              synsetId: '07739125-n',
              partOfSpeech: 'noun',
              definition: 'a fruit',
              translations: ['苹果'],
            ),
          ]),
          _entry('boat', [
            _sense(
              synsetId: '02951358-n',
              partOfSpeech: 'noun',
              definition: 'a small vessel',
              translations: ['船'],
            ),
          ]),
        ]),
      );

      final firstPage = await dictionary.browseByInitial('a', limit: 1);
      final secondPage = await dictionary.browseByInitial(
        'A',
        offset: 1,
        limit: 1,
      );

      expect(firstPage.letter, 'A');
      expect(firstPage.total, 2);
      expect(firstPage.words, ['apple']);
      expect(firstPage.hasMore, isTrue);
      expect(secondPage.words, ['apricot']);
      expect(secondPage.hasMore, isFalse);
    });

    test('rejects invalid alphabet index and unsafe page sizes', () async {
      final dictionary = OfflineEnglishChineseDictionary(
        loadAsset: () async => _fixture([
          _entry('apple', [
            _sense(
              synsetId: '07739125-n',
              partOfSpeech: 'noun',
              definition: 'a fruit',
              translations: ['苹果'],
            ),
          ]),
        ]),
      );

      await expectLater(dictionary.browseByInitial('1'), throwsArgumentError);
      await expectLater(
        dictionary.browseByInitial('A', limit: 101),
        throwsArgumentError,
      );
    });

    test('rejects malformed packaged records with the source line number', () async {
      final dictionary = OfflineEnglishChineseDictionary(
        loadAsset: () async =>
            '${_fixture([
              _entry('ok', [
                _sense(synsetId: '06410904-n', partOfSpeech: 'noun', definition: 'a correct response', translations: ['好']),
              ]),
            ])}\n{broken\n',
      );

      await expectLater(
        dictionary.lookup('ok'),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('line 2'),
          ),
        ),
      );
    });
  });
}

String _fixture(List<Map<String, Object?>> entries) =>
    entries.map(jsonEncode).join('\n');

String _ipaFixture(List<Map<String, Object?>> entries) =>
    entries.map(jsonEncode).join('\n');

Map<String, Object?> _entry(String word, List<Map<String, Object?>> senses) => {
  'word': word,
  'senses': senses,
};

Map<String, Object?> _sense({
  required String synsetId,
  required String partOfSpeech,
  required String definition,
  required List<String> translations,
  List<String> examples = const [],
}) => {
  'synsetId': synsetId,
  'partOfSpeech': partOfSpeech,
  'definition': definition,
  'translations': translations,
  'examples': examples,
};
