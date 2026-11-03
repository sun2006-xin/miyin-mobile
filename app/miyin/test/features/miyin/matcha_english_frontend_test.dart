import 'package:flutter_test/flutter_test.dart';
import 'package:miyin_app/features/miyin/matcha_english_frontend.dart';

void main() {
  final frontend = MiyinMatchaEnglishFrontend(['hello', "isn't", 'good']);
  test('preserves Chinese and known English including contractions', () {
    expect(frontend.prepare('你好Hello，isn’t。'), "你好 hello ， isn't 。");
  });
  test('unknown names are spelled instead of disappearing', () {
    expect(frontend.prepare('Qwen'),
        ' miyinletterq miyinletterw miyinlettere miyinlettern ');
  });
  test('does not change numeric or non Latin text', () {
    expect(frontend.prepare('2026年，ありがとう。'), '2026年，ありがとう。');
  });
}
