import 'package:flutter_test/flutter_test.dart';
import 'package:miyin_app/core/translation/translation_contracts.dart';

void main() {
  group('TranslationLanguage', () {
    test('keeps stable BCP-47 tags and display names separate', () {
      expect(TranslationLanguage.simplifiedChinese.tag, 'zh-Hans');
      expect(TranslationLanguage.simplifiedChinese.displayName, '简体中文');
      expect(TranslationLanguage.english.tag, 'en');
      expect(TranslationLanguage.english.displayName, 'English');
    });

    test('accepts a valid future language tag and rejects malformed tags', () {
      expect(
        TranslationLanguage.fromTag('fr-CA', displayName: 'Français'),
        isA<TranslationLanguage>(),
      );
      expect(
        () => TranslationLanguage.fromTag(
          'not a language',
          displayName: 'Invalid',
        ),
        throwsArgumentError,
      );
    });
  });

  group('TranslationRequest', () {
    test('captures the selected language pair and preserves user text', () {
      final request = TranslationRequest(
        sourceLanguage: TranslationLanguage.simplifiedChinese,
        targetLanguage: TranslationLanguage.english,
        text: '  你好，觅音！\n第二行  ',
      );

      expect(request.sourceLanguage.tag, 'zh-Hans');
      expect(request.targetLanguage.tag, 'en');
      expect(request.text, '  你好，觅音！\n第二行  ');
    });

    test('rejects empty text and identical source and target languages', () {
      expect(
        () => TranslationRequest(
          sourceLanguage: TranslationLanguage.english,
          targetLanguage: TranslationLanguage.simplifiedChinese,
          text: '  \n',
        ),
        throwsArgumentError,
      );
      expect(
        () => TranslationRequest(
          sourceLanguage: TranslationLanguage.english,
          targetLanguage: TranslationLanguage.english,
          text: 'hello',
        ),
        throwsArgumentError,
      );
    });

    test('swap reverses direction without changing the text', () {
      final request = TranslationRequest(
        sourceLanguage: TranslationLanguage.simplifiedChinese,
        targetLanguage: TranslationLanguage.english,
        text: '早上好',
      );

      final reversed = request.swapLanguages();

      expect(reversed.sourceLanguage.tag, 'en');
      expect(reversed.targetLanguage.tag, 'zh-Hans');
      expect(reversed.text, request.text);
    });
  });
}
