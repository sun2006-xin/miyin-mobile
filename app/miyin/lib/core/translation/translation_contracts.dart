/// A user-facing language with a stable BCP-47 identifier.
///
/// The UI may localize [displayName]; storage and engine adapters should use
/// [tag]. Language support is determined by the selected engine, not by this
/// value object, so adding a future locale does not require changing this
/// contract.
final class TranslationLanguage {
  const TranslationLanguage._(this.tag, this.displayName);

  static const simplifiedChinese = TranslationLanguage._('zh-Hans', '简体中文');
  static const english = TranslationLanguage._('en', 'English');

  factory TranslationLanguage.fromTag(
    String rawTag, {
    required String displayName,
  }) {
    final tag = _canonicalizeTag(rawTag);
    return TranslationLanguage._(tag, displayName);
  }

  final String tag;
  final String displayName;

  static String _canonicalizeTag(String value) {
    final input = value.trim();
    final parts = input.split('-');
    if (parts.isEmpty ||
        !RegExp(r'^[A-Za-z]{2,8}$').hasMatch(parts.first) ||
        parts
            .skip(1)
            .any((part) => !RegExp(r'^[A-Za-z0-9]{1,8}$').hasMatch(part))) {
      throw ArgumentError.value(value, 'tag', 'Must be a valid BCP-47 tag.');
    }

    return parts
        .asMap()
        .entries
        .map((entry) {
          final index = entry.key;
          final part = entry.value;
          if (index == 0) return part.toLowerCase();
          if (part.length == 4 && RegExp(r'^[A-Za-z]+$').hasMatch(part)) {
            return '${part[0].toUpperCase()}${part.substring(1).toLowerCase()}';
          }
          if ((part.length == 2 && RegExp(r'^[A-Za-z]+$').hasMatch(part)) ||
              (part.length == 3 && RegExp(r'^\d{3}$').hasMatch(part))) {
            return part.toUpperCase();
          }
          return part.toLowerCase();
        })
        .join('-');
  }

  @override
  bool operator ==(Object other) =>
      other is TranslationLanguage && other.tag == tag;

  @override
  int get hashCode => tag.hashCode;

  @override
  String toString() => '$displayName ($tag)';
}

/// A directed source/target language pair used for translation requests.
final class TranslationLanguagePair {
  TranslationLanguagePair({
    required this.sourceLanguage,
    required this.targetLanguage,
  }) {
    if (sourceLanguage == targetLanguage) {
      throw ArgumentError('A language pair must contain different languages.');
    }
  }

  final TranslationLanguage sourceLanguage;
  final TranslationLanguage targetLanguage;

  TranslationLanguagePair reversed() => TranslationLanguagePair(
    sourceLanguage: targetLanguage,
    targetLanguage: sourceLanguage,
  );

  String get id => '${sourceLanguage.tag}--${targetLanguage.tag}';

  @override
  bool operator ==(Object other) =>
      other is TranslationLanguagePair &&
      other.sourceLanguage == sourceLanguage &&
      other.targetLanguage == targetLanguage;

  @override
  int get hashCode => Object.hash(sourceLanguage, targetLanguage);
}

final class TranslationRequest {
  TranslationRequest({
    required this.sourceLanguage,
    required this.targetLanguage,
    required this.text,
  }) {
    if (text.trim().isEmpty) {
      throw ArgumentError.value(text, 'text', 'Text must not be blank.');
    }
    if (sourceLanguage == targetLanguage) {
      throw ArgumentError.value(
        targetLanguage.tag,
        'targetLanguage',
        'Source and target languages must differ.',
      );
    }
  }

  final TranslationLanguage sourceLanguage;
  final TranslationLanguage targetLanguage;
  final String text;

  TranslationLanguagePair get languagePair => TranslationLanguagePair(
    sourceLanguage: sourceLanguage,
    targetLanguage: targetLanguage,
  );

  TranslationRequest swapLanguages() => TranslationRequest(
    sourceLanguage: targetLanguage,
    targetLanguage: sourceLanguage,
    text: text,
  );
}

enum TranslationModelStatus {
  unsupported,
  notDownloaded,
  downloading,
  downloaded,
  failed,
}

final class TranslationModelInfo {
  const TranslationModelInfo({
    required this.status,
    this.downloadedBytes,
    this.totalBytes,
    this.version,
  });

  final TranslationModelStatus status;
  final int? downloadedBytes;
  final int? totalBytes;
  final String? version;
}

final class TranslationResult {
  const TranslationResult({
    required this.request,
    required this.translatedText,
    required this.engineId,
    this.modelVersion,
  });

  final TranslationRequest request;
  final String translatedText;
  final String engineId;
  final String? modelVersion;
}

abstract interface class TranslationEngine {
  String get engineId;

  Future<Set<TranslationLanguagePair>> getSupportedLanguagePairs();

  Future<TranslationModelInfo> getModelInfo(TranslationLanguagePair pair);

  /// Downloads the package required for [pair].
  ///
  /// `wifiOnly` is true by default at the call site; callers must obtain an
  /// explicit user choice before passing false.
  Future<void> downloadModel(
    TranslationLanguagePair pair, {
    required bool wifiOnly,
  });

  Future<void> deleteModel(TranslationLanguagePair pair);

  /// Translates only with already installed local model data.
  Future<TranslationResult> translate(TranslationRequest request);
}

/// Optional catalog for engines where supported languages are larger than a
/// small fixed list of language pairs (for example, ML Kit's on-device set).
abstract interface class TranslationLanguageCatalog {
  Future<Set<TranslationLanguage>> getSupportedLanguages();
}

final class TranslationFailure implements Exception {
  const TranslationFailure(this.code, this.message, {this.cause});

  final String code;
  final String message;
  final Object? cause;

  @override
  String toString() => 'TranslationFailure($code): $message';
}
