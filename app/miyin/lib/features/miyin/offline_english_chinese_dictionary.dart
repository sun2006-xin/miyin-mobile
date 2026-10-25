import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

/// Exact-match, offline English-to-Chinese lookup over the bundled COW/WordNet
/// synset data. This is a lexical reference, not a sentence translator.
class OfflineEnglishChineseDictionary {
  static const assetPath = 'assets/dictionary/en-zh-cow-wordnet-3.0.jsonl';
  static const ipaAssetPath = 'assets/dictionary/en-us-ipa.jsonl';

  OfflineEnglishChineseDictionary({
    Future<String> Function()? loadAsset,
    Future<String> Function()? loadIpaAsset,
  }) : _loadAsset = loadAsset ?? (() => rootBundle.loadString(assetPath)),
       _loadIpaAsset =
           loadIpaAsset ?? (() => rootBundle.loadString(ipaAssetPath));

  final Future<String> Function() _loadAsset;
  final Future<String> Function() _loadIpaAsset;
  Future<Map<String, EnglishChineseDictionaryEntry>>? _entriesFuture;
  Future<Map<String, String>>? _ipaEntriesFuture;
  Future<Map<String, List<EnglishChineseDictionaryEntry>>>? _chineseIndexFuture;
  Future<Map<String, List<String>>>? _initialIndexFuture;

  /// Finds an exact normalized headword. Matching ignores case, repeated
  /// whitespace, and whether WordNet's `_` or a space separates a phrase.
  Future<EnglishChineseDictionaryLookup> lookup(String query) async {
    final normalizedQuery = normalizeHeadword(query);
    if (normalizedQuery.isEmpty) {
      return EnglishChineseDictionaryLookup(
        query: query,
        normalizedQuery: normalizedQuery,
      );
    }

    final entries = await (_entriesFuture ??= _loadAndParse());
    final entry = entries[normalizedQuery];
    return EnglishChineseDictionaryLookup(
      query: query,
      normalizedQuery: normalizedQuery,
      entry: entry == null ? null : await _withIpa(entry),
    );
  }

  /// Returns a bounded, alphabetically sorted page of English headwords.
  /// The complete index is built once from the bundled data and reused.
  Future<EnglishChineseDictionaryBrowsePage> browseByInitial(
    String initial, {
    int offset = 0,
    int limit = 24,
  }) async {
    final normalizedInitial = initial.trim().toUpperCase();
    if (!RegExp(r'^[A-Z]$').hasMatch(normalizedInitial)) {
      throw ArgumentError.value(
        initial,
        'initial',
        'Use one letter from A to Z.',
      );
    }
    if (offset < 0) {
      throw ArgumentError.value(
        offset,
        'offset',
        'Offset must not be negative.',
      );
    }
    if (limit < 1 || limit > 100) {
      throw ArgumentError.value(
        limit,
        'limit',
        'Limit must be between 1 and 100.',
      );
    }

    final byInitial = await (_initialIndexFuture ??= _loadInitialIndex());
    final words = byInitial[normalizedInitial] ?? const <String>[];
    final page = words.skip(offset).take(limit).toList(growable: false);
    final ipaEntries = await (_ipaEntriesFuture ??= _loadIpaIndex());
    return EnglishChineseDictionaryBrowsePage(
      letter: normalizedInitial,
      offset: offset,
      limit: limit,
      total: words.length,
      words: page,
      ipaByWord: {
        for (final word in page)
          if (ipaEntries[normalizeHeadword(word)] case final String ipa)
            word: ipa,
      },
    );
  }

  /// Searches the Chinese translation side of the local bilingual word list.
  /// Results contain full headword entries so all senses stay grouped.
  Future<EnglishChineseDictionaryChineseLookup> lookupChinese(
    String query, {
    int limit = 30,
  }) async {
    final normalizedQuery = normalizeHeadword(query);
    if (normalizedQuery.isEmpty) {
      return EnglishChineseDictionaryChineseLookup(
        query: query,
        normalizedQuery: normalizedQuery,
      );
    }
    if (limit < 1 || limit > 100) {
      throw ArgumentError.value(
        limit,
        'limit',
        'Limit must be between 1 and 100.',
      );
    }
    final index = await (_chineseIndexFuture ??= _loadChineseIndex());
    final matches =
        (index[normalizedQuery] ?? const <EnglishChineseDictionaryEntry>[])
            .take(limit)
            .toList(growable: false);
    final entriesWithIpa = await Future.wait(matches.map(_withIpa));
    return EnglishChineseDictionaryChineseLookup(
      query: query,
      normalizedQuery: normalizedQuery,
      entries: entriesWithIpa,
    );
  }

  static String normalizeHeadword(String value) => value
      .trim()
      .replaceAll('_', ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .toLowerCase();

  Future<Map<String, EnglishChineseDictionaryEntry>> _loadAndParse() async {
    final contents = await _loadAsset();
    final entries = <String, EnglishChineseDictionaryEntry>{};
    final lines = const LineSplitter().convert(contents);
    for (var index = 0; index < lines.length; index++) {
      final line = lines[index].trim();
      if (line.isEmpty) continue;

      try {
        final decoded = jsonDecode(line);
        if (decoded is! Map<String, dynamic>) {
          throw const FormatException('record must be a JSON object');
        }
        final entry = EnglishChineseDictionaryEntry.fromJson(decoded);
        final key = normalizeHeadword(entry.word);
        if (key.isEmpty) {
          throw const FormatException('headword must not be empty');
        }
        if (entry.senses.isEmpty) {
          throw const FormatException(
            'headword must contain at least one sense',
          );
        }
        if (entries.containsKey(key)) {
          throw FormatException('duplicate headword "${entry.word}"');
        }
        entries[key] = entry;
      } on FormatException catch (error) {
        throw FormatException(
          'Dictionary data line ${index + 1}: ${error.message}',
        );
      } on TypeError catch (error) {
        throw FormatException('Dictionary data line ${index + 1}: $error');
      }
    }
    return Map.unmodifiable(entries);
  }

  Future<EnglishChineseDictionaryEntry> _withIpa(
    EnglishChineseDictionaryEntry entry,
  ) async {
    final ipaEntries = await (_ipaEntriesFuture ??= _loadIpaIndex());
    final ipa = ipaEntries[normalizeHeadword(entry.word)];
    return entry.withIpa(ipa);
  }

  Future<Map<String, String>> _loadIpaIndex() async {
    final contents = await _loadIpaAsset();
    final entries = <String, String>{};
    final lines = const LineSplitter().convert(contents);
    for (var index = 0; index < lines.length; index++) {
      final line = lines[index].trim();
      if (line.isEmpty) continue;
      try {
        final decoded = jsonDecode(line);
        if (decoded is! Map<String, dynamic>) {
          throw const FormatException('record must be a JSON object');
        }
        final word = decoded['word'];
        final ipa = decoded['ipa'];
        if (word is! String || ipa is! String || ipa.trim().isEmpty) {
          throw const FormatException('record requires word and non-empty ipa');
        }
        final key = normalizeHeadword(word);
        if (key.isEmpty) {
          throw const FormatException('headword must not be empty');
        }
        if (entries.containsKey(key)) {
          throw FormatException('duplicate normalized headword "$word"');
        }
        entries[key] = ipa;
      } on FormatException catch (error) {
        throw FormatException('IPA data line ${index + 1}: ${error.message}');
      } on TypeError catch (error) {
        throw FormatException('IPA data line ${index + 1}: $error');
      }
    }
    return Map.unmodifiable(entries);
  }

  Future<Map<String, List<String>>> _loadInitialIndex() async {
    final entries = await (_entriesFuture ??= _loadAndParse());
    final index = <String, List<String>>{};
    for (final entry in entries.values) {
      final word = entry.word;
      final normalized = normalizeHeadword(word);
      if (normalized.isEmpty) continue;
      final initial = normalized[0].toUpperCase();
      if (!RegExp(r'^[A-Z]$').hasMatch(initial)) continue;
      (index[initial] ??= <String>[]).add(word);
    }
    for (final words in index.values) {
      words.sort(
        (left, right) =>
            normalizeHeadword(left).compareTo(normalizeHeadword(right)),
      );
    }
    return Map.unmodifiable({
      for (final entry in index.entries)
        entry.key: List<String>.unmodifiable(entry.value),
    });
  }

  Future<Map<String, List<EnglishChineseDictionaryEntry>>>
  _loadChineseIndex() async {
    final entries = await (_entriesFuture ??= _loadAndParse());
    final index = <String, List<EnglishChineseDictionaryEntry>>{};
    for (final entry in entries.values) {
      final seenForEntry = <String>{};
      for (final sense in entry.senses) {
        for (final translation in sense.translations) {
          final key = normalizeHeadword(translation);
          if (key.isEmpty || !seenForEntry.add(key)) continue;
          (index[key] ??= <EnglishChineseDictionaryEntry>[]).add(entry);
        }
      }
    }
    for (final matches in index.values) {
      matches.sort(
        (left, right) =>
            normalizeHeadword(left.word)
                .compareTo(normalizeHeadword(right.word)),
      );
    }
    return Map.unmodifiable({
      for (final entry in index.entries)
        entry.key: List<EnglishChineseDictionaryEntry>.unmodifiable(
          entry.value,
        ),
    });
  }
}

class EnglishChineseDictionaryBrowsePage {
  const EnglishChineseDictionaryBrowsePage({
    required this.letter,
    required this.offset,
    required this.limit,
    required this.total,
    required this.words,
    this.ipaByWord = const <String, String>{},
  });

  final String letter;
  final int offset;
  final int limit;
  final int total;
  final List<String> words;
  final Map<String, String> ipaByWord;
  bool get hasMore => offset + words.length < total;
}

class EnglishChineseDictionaryChineseLookup {
  const EnglishChineseDictionaryChineseLookup({
    required this.query,
    required this.normalizedQuery,
    this.entries = const <EnglishChineseDictionaryEntry>[],
  });

  final String query;
  final String normalizedQuery;
  final List<EnglishChineseDictionaryEntry> entries;
  bool get isFound => entries.isNotEmpty;
}

class EnglishChineseDictionaryLookup {
  const EnglishChineseDictionaryLookup({
    required this.query,
    required this.normalizedQuery,
    this.entry,
  });

  final String query;
  final String normalizedQuery;
  final EnglishChineseDictionaryEntry? entry;

  bool get isFound => entry != null;
  List<EnglishChineseDictionarySense> get senses =>
      entry?.senses ?? const <EnglishChineseDictionarySense>[];
  bool get matchedByNormalization => entry != null && query != entry!.word;
}

class EnglishChineseDictionaryEntry {
  const EnglishChineseDictionaryEntry({
    required this.word,
    required this.senses,
    this.ipa,
  });

  final String word;
  final List<EnglishChineseDictionarySense> senses;
  final String? ipa;

  EnglishChineseDictionaryEntry withIpa(String? value) =>
      EnglishChineseDictionaryEntry(word: word, senses: senses, ipa: value);

  factory EnglishChineseDictionaryEntry.fromJson(Map<String, dynamic> json) {
    final word = json['word'];
    final rawSenses = json['senses'];
    final ipa = json['ipa'];
    if (word is! String ||
        rawSenses is! List ||
        (ipa != null && ipa is! String)) {
      throw const FormatException(
        'record requires string "word", list "senses", and optional string "ipa"',
      );
    }
    final senses = rawSenses
        .map((value) {
          if (value is! Map<String, dynamic>) {
            throw const FormatException('each sense must be a JSON object');
          }
          return EnglishChineseDictionarySense.fromJson(value);
        })
        .toList(growable: false);
    return EnglishChineseDictionaryEntry(
      word: word,
      senses: List.unmodifiable(senses),
      ipa: ipa as String?,
    );
  }
}

class EnglishChineseDictionarySense {
  const EnglishChineseDictionarySense({
    required this.synsetId,
    required this.partOfSpeech,
    required this.definition,
    required this.translations,
    required this.examples,
  });

  final String synsetId;
  final String partOfSpeech;
  final String definition;
  final List<String> translations;
  final List<String> examples;

  factory EnglishChineseDictionarySense.fromJson(Map<String, dynamic> json) {
    final synsetId = json['synsetId'];
    final partOfSpeech = json['partOfSpeech'];
    final definition = json['definition'];
    final rawTranslations = json['translations'];
    final rawExamples = json['examples'];
    if (synsetId is! String ||
        partOfSpeech is! String ||
        definition is! String ||
        rawTranslations is! List ||
        rawExamples is! List) {
      throw const FormatException(
        'sense requires synsetId, partOfSpeech, definition, translations, and examples',
      );
    }
    if (!RegExp(r'^\d{8}-[nvar]$').hasMatch(synsetId)) {
      throw FormatException('invalid WordNet synset ID "$synsetId"');
    }
    if (!const {'noun', 'verb', 'adjective', 'adverb'}.contains(partOfSpeech)) {
      throw FormatException('invalid part of speech "$partOfSpeech"');
    }
    final translations = _stringList(rawTranslations, 'translations');
    final examples = _stringList(rawExamples, 'examples');
    if (translations.isEmpty) {
      throw const FormatException(
        'sense must contain at least one translation',
      );
    }
    return EnglishChineseDictionarySense(
      synsetId: synsetId,
      partOfSpeech: partOfSpeech,
      definition: definition,
      translations: List.unmodifiable(translations),
      examples: List.unmodifiable(examples),
    );
  }

  static List<String> _stringList(List<dynamic> values, String field) {
    if (values.any((value) => value is! String)) {
      throw FormatException('"$field" must contain only strings');
    }
    return values.cast<String>().toList(growable: false);
  }
}
