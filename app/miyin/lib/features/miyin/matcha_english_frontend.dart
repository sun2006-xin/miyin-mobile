/// Matcha 2 uses a lexicon instead of an embedded English phonemizer.
/// Preserve known words; spell unknown names rather than silently dropping them.
final class MiyinMatchaEnglishFrontend {
  MiyinMatchaEnglishFrontend(Iterable<String> words)
    : _words = words.map((word) => word.toLowerCase()).toSet();

  final Set<String> _words;
  static final _english = RegExp(r"[A-Za-z]+(?:['’][A-Za-z]+)*");

  String prepare(String text) => text.replaceAllMapped(_english, (match) {
    final word = match[0]!.toLowerCase().replaceAll('’', "'");
    if (_words.contains(word)) return ' $word ';
    return ' ${word.replaceAll("'", '').split('').map((letter) => 'miyinletter$letter').join(' ')} ';
  });
}
