import unittest
from build_matcha_english_lexicon import convert, pronunciation


class LexiconTests(unittest.TestCase):
    def test_stress_and_reduced_vowels(self):
        self.assertEqual(pronunciation(['HH', 'AH0', 'L', 'OW1']), list('həlˈoʊ'))
        self.assertEqual(pronunciation(['ER0']), ['ɚ'])

    def test_first_pronunciation_and_contractions(self):
        result = convert("hello HH AH0 L OW1\nhello(2) HH EH0 L OW1\nisn't IH1 Z AH0 N T\n", set('həlˈoʊɛɪzənt'))
        self.assertEqual(result.count('hello '), 1)
        self.assertIn("isn't ˈ ɪ z ə n t", result)

    def test_reject_unsupported_model_token(self):
        with self.assertRaises(ValueError):
            convert('hello HH AH0 L OW1', set('helow'))

    def test_reject_unknown_cmu_phone(self):
        with self.assertRaises(ValueError):
            pronunciation(['INVALID'])


if __name__ == '__main__':
    unittest.main()
