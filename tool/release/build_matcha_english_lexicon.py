"""Convert a separately supplied CMUdict into Matcha's IPA lexicon format.

CMUdict retains its BSD license. No network access or model mutation occurs.
Pass the model's tokens.txt to reject pronunciations it cannot represent.
"""
import argparse
from pathlib import Path
import re

PHONES = dict(zip(
    'AA AE AH AO AW AY B CH D DH EH ER EY F G HH IH IY JH K L M N NG OW OY P R S SH T TH UH UW V W Y Z ZH'.split(),
    'ɑ æ ʌ ɔ aʊ aɪ b ʧ d ð ɛ ɜɹ eɪ f ɡ h ɪ iː ʤ k l m n ŋ oʊ ɔɪ p ɹ s ʃ t θ ʊ uː v w j z ʒ'.split(),
))


def pronunciation(phones):
    result = []
    for phone in phones:
        match = re.fullmatch(r'([A-Z]+)([012]?)', phone)
        if not match or match[1] not in PHONES:
            raise ValueError(f'Unsupported CMU phoneme: {phone}')
        base, stress = match.groups()
        ipa = 'ə' if base == 'AH' and stress == '0' else 'ɚ' if base == 'ER' and stress == '0' else PHONES[base]
        if stress in ('1', '2'):
            result.append('ˈ' if stress == '1' else 'ˌ')
        result.extend(ipa)
    return result


def convert(source, tokens):
    entries = {}
    for line in source.splitlines():
        fields = line.split('#', 1)[0].split()
        if len(fields) < 2:
            continue
        word = re.sub(r'\(\d+\)$', '', fields[0]).lower()
        if word in entries or not re.fullmatch(r"[a-z]+(?:'[a-z]+)*", word):
            continue
        phones = pronunciation(fields[1:])
        missing = set(phones) - tokens
        if missing:
            raise ValueError(f'Model cannot represent pronunciation of {word}: {missing}')
        entries[word] = phones
    return '\n'.join(word + ' ' + ' '.join(entries[word]) for word in sorted(entries)) + '\n'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cmudict', type=Path, required=True)
    parser.add_argument('--tokens', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    tokens = {line.rsplit(' ', 1)[0] for line in args.tokens.read_text(encoding='utf-8').splitlines()}
    result = convert(args.cmudict.read_text(encoding='utf-8'), tokens)
    args.output.write_text(result, encoding='utf-8', newline='\n')
    print(f'Wrote {len(result.splitlines())} pronunciations to {args.output}')


if __name__ == '__main__':
    main()
