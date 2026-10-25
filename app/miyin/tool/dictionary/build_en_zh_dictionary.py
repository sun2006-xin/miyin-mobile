#!/usr/bin/env python3
"""Build the bundled English-Chinese COW/WordNet 3.0 JSONL lexicon.

Inputs are the COW tab from the pinned OMW commit and Princeton WordNet 3.0's
official archive. The script only joins exact WordNet synset offsets; it does
not infer translations or generate dictionary content.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
import tarfile
from collections import defaultdict
from pathlib import Path


COW_SHA256 = "379FD2E41D3E1395F9F27CF23A39C6181849FFB4020C14A07ED2A4D4DD651122"
WORDNET_SHA256 = "640DB279C949A88F61F851DD54EBBB22D003F8B90B85267042EF85A3781D3A52"
WORDNET_MEMBERS = {
    "n": ("noun", "WordNet-3.0/dict/data.noun", "WordNet-3.0/dict/index.noun"),
    "v": ("verb", "WordNet-3.0/dict/data.verb", "WordNet-3.0/dict/index.verb"),
    "a": ("adjective", "WordNet-3.0/dict/data.adj", "WordNet-3.0/dict/index.adj"),
    "r": ("adverb", "WordNet-3.0/dict/data.adv", "WordNet-3.0/dict/index.adv"),
}
POS_ORDER = {"noun": 0, "verb": 1, "adjective": 2, "adverb": 3}
EXAMPLE_RE = re.compile(r';\s*"([^"]+)"')


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest().upper()


def read_member(archive: tarfile.TarFile, name: str) -> str:
    member = archive.extractfile(name)
    if member is None:
        raise ValueError(f"Missing WordNet archive member: {name}")
    return member.read().decode("latin-1")


def normalize_lemma(value: str) -> str:
    return " ".join(value.replace("_", " ").split()).lower()


def load_cow(cow_path: Path) -> dict[str, list[str]]:
    translations: dict[str, list[str]] = defaultdict(list)
    with cow_path.open("r", encoding="utf-8", newline="") as source:
        for line_number, line in enumerate(source, 1):
            line = line.rstrip("\r\n")
            if not line or line.startswith("#"):
                continue
            columns = line.split("\t")
            if len(columns) != 3 or columns[1] != "cmn:lemma":
                raise ValueError(f"Unexpected COW row at line {line_number}")
            synset_id, _, chinese_lemma = columns
            if not re.fullmatch(r"\d{8}-[nvar]", synset_id):
                raise ValueError(f"Unexpected COW synset ID at line {line_number}: {synset_id}")
            chinese_lemma = chinese_lemma.strip()
            if chinese_lemma and chinese_lemma not in translations[synset_id]:
                translations[synset_id].append(chinese_lemma)
    return translations


def load_sense_order(index_text: str, wordnet_pos: str) -> dict[tuple[str, str], int]:
    order: dict[tuple[str, str], int] = {}
    for line in index_text.splitlines():
        fields = line.split()
        if len(fields) < 6 or fields[1] not in {wordnet_pos, "s"}:
            continue
        lemma, pos = fields[0], fields[1]
        try:
            synset_count = int(fields[2])
            pointer_count = int(fields[3])
        except ValueError:
            # WordNet's human-readable license preamble is not an index row.
            continue
        offset_start = 4 + pointer_count + 2
        offsets = fields[offset_start : offset_start + synset_count]
        if len(offsets) != synset_count:
            raise ValueError(f"Malformed WordNet index row for {lemma}")
        for rank, offset in enumerate(offsets):
            order[(normalize_lemma(lemma), offset)] = rank
    return order


def parse_wordnet_data(
    data_text: str,
    language_pos: str,
    part_of_speech: str,
    cow_translations: dict[str, list[str]],
    sense_order: dict[tuple[str, str], int],
    records: dict[str, list[dict[str, object]]],
) -> tuple[int, int]:
    parsed_synsets = 0
    joined_synsets = 0
    for line in data_text.splitlines():
        before_gloss, separator, gloss = line.partition("|")
        if not separator:
            continue
        fields = before_gloss.split()
        if len(fields) < 4 or not re.fullmatch(r"\d{8}", fields[0]):
            continue
        offset, synset_pos, hexadecimal_word_count = fields[0], fields[2], fields[3]
        if synset_pos not in {language_pos, "s"}:
            raise ValueError(f"Unexpected WordNet POS {synset_pos} at {offset}")
        word_count = int(hexadecimal_word_count, 16)
        words_start = 4
        words = fields[words_start : words_start + word_count * 2 : 2]
        if len(words) != word_count:
            raise ValueError(f"Malformed WordNet words for synset {offset}")
        parsed_synsets += 1

        cow_pos = "a" if synset_pos == "s" else synset_pos
        synset_id = f"{offset}-{cow_pos}"
        chinese_lemmas = cow_translations.get(synset_id)
        if not chinese_lemmas:
            continue
        joined_synsets += 1

        examples = EXAMPLE_RE.findall(gloss)
        definition = EXAMPLE_RE.sub("", gloss).strip().rstrip("; ")
        sense = {
            "synsetId": synset_id,
            "partOfSpeech": part_of_speech,
            "definition": definition,
            "translations": chinese_lemmas,
            "examples": examples,
        }
        for word in words:
            normalized_word = normalize_lemma(word)
            if not normalized_word:
                continue
            records[normalized_word].append(
                {
                    "sense": sense,
                    "senseOrder": sense_order.get((normalized_word, offset), 1_000_000),
                    "offset": offset,
                    "posOrder": POS_ORDER[part_of_speech],
                    "displayWord": word.replace("_", " "),
                }
            )
    return parsed_synsets, joined_synsets


def build(cow_path: Path, wordnet_path: Path, output_path: Path) -> dict[str, int]:
    cow_hash = sha256(cow_path)
    if cow_hash != COW_SHA256:
        raise ValueError(f"Unexpected COW source SHA-256: {cow_hash}")
    wordnet_hash = sha256(wordnet_path)
    if wordnet_hash != WORDNET_SHA256:
        raise ValueError(f"Unexpected WordNet source SHA-256: {wordnet_hash}")

    cow_translations = load_cow(cow_path)
    records: dict[str, list[dict[str, object]]] = defaultdict(list)
    stats = {"cow_synsets": len(cow_translations), "cow_lemmas": sum(map(len, cow_translations.values()))}
    with tarfile.open(wordnet_path, "r:gz") as archive:
        license_text = read_member(archive, "WordNet-3.0/LICENSE")
        if "WordNet 3.0 Copyright 2006 by Princeton University" not in license_text:
            raise ValueError("WordNet archive is missing its expected license notice")
        for pos, (part_of_speech, data_member, index_member) in WORDNET_MEMBERS.items():
            order = load_sense_order(read_member(archive, index_member), pos)
            parsed, joined = parse_wordnet_data(
                read_member(archive, data_member),
                pos,
                part_of_speech,
                cow_translations,
                order,
                records,
            )
            stats[f"wordnet_{pos}_synsets"] = parsed
            stats[f"joined_{pos}_synsets"] = joined

    joined_cow_synsets = sum(
        value for key, value in stats.items() if key.startswith("joined_")
    )
    if joined_cow_synsets != len(cow_translations):
        raise ValueError(
            f"Only {joined_cow_synsets} of {len(cow_translations)} COW synsets joined"
        )

    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_senses = 0
    with output_path.open("w", encoding="utf-8", newline="\n") as output:
        for word in sorted(records):
            candidates = records[word]
            candidates.sort(
                key=lambda record: (
                    record["posOrder"],
                    record["senseOrder"],
                    record["offset"],
                )
            )
            senses = []
            seen_synsets = set()
            for candidate in candidates:
                sense = candidate["sense"]
                synset_id = sense["synsetId"]
                if synset_id in seen_synsets:
                    continue
                seen_synsets.add(synset_id)
                senses.append(sense)
            output_senses += len(senses)
            display_word = candidates[0]["displayWord"]
            output.write(
                json.dumps(
                    {"word": display_word, "senses": senses},
                    ensure_ascii=False,
                    separators=(",", ":"),
                )
            )
            output.write("\n")

    stats["entries"] = len(records)
    stats["senses"] = output_senses
    stats["output_bytes"] = output_path.stat().st_size
    stats["output_sha256"] = sha256(output_path)
    return stats


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cow-tab", required=True, type=Path)
    parser.add_argument("--wordnet-tar", required=True, type=Path)
    parser.add_argument(
        "--output",
        type=Path,
        default=Path("assets/dictionary/en-zh-cow-wordnet-3.0.jsonl"),
    )
    args = parser.parse_args()
    try:
        stats = build(args.cow_tab, args.wordnet_tar, args.output)
    except (OSError, tarfile.TarError, UnicodeError, ValueError) as error:
        print(f"Error: {error}", file=sys.stderr)
        return 1
    print(json.dumps(stats, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
