import 'dart:async';

import '../storage/translation_history_repository.dart';
import 'translation_contracts.dart';

final class TranslationOutcome {
  const TranslationOutcome({
    required this.translation,
    required this.historySaved,
    this.historyEntryId,
  });

  final TranslationResult translation;
  final bool historySaved;
  final int? historyEntryId;
}

/// Coordinates provider-independent translation and local history.
///
/// The service never downloads a model as a side effect of translation. A UI
/// must call [downloadModel] only after the user explicitly requests it.
final class TranslationService {
  TranslationService({required this.engine, required this.history});

  final TranslationEngine engine;
  final SqliteTranslationHistoryRepository history;
  Future<void> _historyMutationTail = Future<void>.value();
  Future<void>? _closeFuture;
  bool _closing = false;

  Future<Set<TranslationLanguagePair>> getSupportedLanguagePairs() =>
      engine.getSupportedLanguagePairs();

  Future<Set<TranslationLanguage>> getSupportedLanguages() async {
    final currentEngine = engine;
    if (currentEngine is TranslationLanguageCatalog) {
      return (currentEngine as TranslationLanguageCatalog)
          .getSupportedLanguages();
    }
    final pairs = await currentEngine.getSupportedLanguagePairs();
    return {
      for (final pair in pairs) pair.sourceLanguage,
      for (final pair in pairs) pair.targetLanguage,
    };
  }

  Future<TranslationModelInfo> getModelInfo(
    TranslationLanguagePair pair,
  ) async {
    await _requireSupportedPair(pair);
    return engine.getModelInfo(pair);
  }

  Future<void> downloadModel(
    TranslationLanguagePair pair, {
    required bool wifiOnly,
  }) async {
    await _requireSupportedPair(pair);
    return engine.downloadModel(pair, wifiOnly: wifiOnly);
  }

  Future<void> deleteModel(TranslationLanguagePair pair) async {
    await _requireSupportedPair(pair);
    return engine.deleteModel(pair);
  }

  Future<TranslationOutcome> translateAndSave(
    TranslationRequest request,
  ) => _serializeHistoryMutation(() async {
    await _requireSupportedPair(request.languagePair);

    final modelInfo = await engine.getModelInfo(request.languagePair);
    if (modelInfo.status != TranslationModelStatus.downloaded) {
      throw const TranslationFailure(
        'model_missing',
        'Download the offline translation model before translating.',
      );
    }

    final result = await engine.translate(request);
    if (result.translatedText.trim().isEmpty) {
      throw const TranslationFailure(
        'empty_translation',
        'The translation engine returned no translated text.',
      );
    }
    try {
      final id = await history.saveTranslation(result);
      return TranslationOutcome(
        translation: result,
        historySaved: true,
        historyEntryId: id,
      );
    } catch (_) {
      // Keep a valid translation visible even if local history is unavailable.
      // The caller receives historySaved=false and must explain that distinction.
      return TranslationOutcome(translation: result, historySaved: false);
    }
  });

  Future<List<TranslationHistoryEntry>> listHistory({
    int limit = 30,
    int offset = 0,
  }) => _serializeHistoryMutation(
    () => history.listTranslations(limit: limit, offset: offset),
  );

  Future<int> countHistory() =>
      _serializeHistoryMutation(history.countTranslations);

  Future<int> saveAttachmentHistory({
    required String kind,
    required String name,
    required String sourceTag,
    required String targetTag,
    required String rowsJson,
    required String sourceText,
    required String translatedText,
    String? originalImageDataUrl,
    String? translatedImageDataUrl,
  }) => _serializeHistoryMutation(
    () => history.saveAttachment(
      kind: kind,
      name: name,
      sourceTag: sourceTag,
      targetTag: targetTag,
      rowsJson: rowsJson,
      sourceText: sourceText,
      translatedText: translatedText,
      originalImageDataUrl: originalImageDataUrl,
      translatedImageDataUrl: translatedImageDataUrl,
    ),
  );

  Future<String?> readHistoryImage(String? path) =>
      _serializeHistoryMutation(() => history.readImage(path));

  Future<TranslationHistoryEntry?> getHistoryEntry(int id) =>
      _serializeHistoryMutation(() => history.getTranslation(id));

  Future<bool> deleteHistoryEntry(int id) =>
      _serializeHistoryMutation(() => history.deleteTranslation(id));

  Future<int> deleteHistoryEntries(Iterable<int> ids) =>
      _serializeHistoryMutation(() => history.deleteTranslations(ids));

  Future<int> clearHistory() =>
      _serializeHistoryMutation(history.clearTranslations);

  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    _closing = true;
    await _historyMutationTail;
    await history.close();
  }

  Future<T> _serializeHistoryMutation<T>(Future<T> Function() operation) {
    if (_closing) {
      return Future<T>.error(StateError('TranslationService is closing.'));
    }
    final result = _historyMutationTail.then((_) => operation());
    _historyMutationTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  Future<void> _requireSupportedPair(TranslationLanguagePair pair) async {
    final currentEngine = engine;
    if (currentEngine is TranslationLanguageCatalog) {
      final languages = await (currentEngine as TranslationLanguageCatalog)
          .getSupportedLanguages();
      if (languages.contains(pair.sourceLanguage) &&
          languages.contains(pair.targetLanguage)) {
        return;
      }
      throw const TranslationFailure(
        'unsupported_language_pair',
        'This translation engine does not support the selected languages.',
      );
    }
    if (!(await engine.getSupportedLanguagePairs()).contains(pair)) {
      throw const TranslationFailure(
        'unsupported_language_pair',
        'This translation engine does not support the selected languages.',
      );
    }
  }
}
