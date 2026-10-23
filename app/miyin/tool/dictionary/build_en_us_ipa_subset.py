#!/usr/bin/env python3
"""Build an English-US IPA index joined to existing Miyin dictionary words.

The only accepted upstream source is ipa-dict's pinned data/en_US.txt at the
commit and SHA-256 below. The script keeps exact normalized headword overlaps
with the bundled COW/WordNet dictionary; it does not generate pronunciations.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path
from typing import Any


SOURCE_COMMIT = "43c3570eb3553bdd19fccd2bd0091534889af023"
SOURCE_SHA256 = "2AF6F154A5C363275F052D1F85ACedef38ed185ca9745aa4314be77f6b70de67".upper()
SOURCE_URL = (
    "https://github.com/open-dict-data/ipa-dict/blob/"
    f"{SOURCE_COMMIT}/data/en_US.txt"
)
DEFAULT_DICTIONARY = Path("assets/dictionary/en-zh-cow-wordnet-3.0.jsonl")
DEFAULT_OUTPUT = Path("assets/dictionary/en-us-ipa.jsonl")
DEFAULT_METADATA = Path("assets/dictionary/en-us-ipa.metadata.json")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest().upper()


def normalize_headword(value: str) -> str:
    return " ".join(value.replace("_", " ").split()).lower()


def read_dictionary(path: Path) -> dict[str, str]:
    words: dict[str, str] = {}
    with path.open("r", encoding="utf-8") as source:
        for line_number, line in enumerate(source, 1):
            if not line.strip():
                continue
            try:
                record: Any = json.loads(line)
            except json.JSONDecodeError as error:
                raise ValueError(
                    f"Malformed dictionary JSON at line {line_number}: {error}"
                ) from error
            if not isinstance(record, dict) or not isinstance(record.get("word"), str):
                raise ValueError(f"Dictionary row {line_number} has no string word")
            word = record["word"]
            key = normalize_headword(word)
            if not key:
                raise ValueError(f"Dictionary row {line_number} has an empty word")
            if key in words:
                raise ValueError(f"Duplicate normalized dictionary headword: {word}")
            words[key] = word
    return words


def read_ipa_source(path: Path) -> tuple[dict[str, str], int, int]:
    pronunciations: dict[str, str] = {}
    source_rows = 0
    collision_rows = 0
    with path.open("r", encoding="utf-8", newline="") as source:
        for line_number, line in enumerate(source, 1):
            row = line.rstrip("\r\n")
            if not row:
                continue
            columns = row.split("\t")
            if len(columns) != 2 or not columns[0] or not columns[1]:
                raise ValueError(f"Malformed en_US IPA row at line {line_number}")
            headword, ipa = columns
            key = normalize_headword(headword)
            if not key:
                raise ValueError(f"Empty IPA headword at line {line_number}")
            source_rows += 1
            previous = pronunciations.get(key)
            if previous is not None:
                if previous != ipa:
                    collision_rows += 1
                    pronunciations[key] = ", ".join(dict.fromkeys((previous, ipa)))
                continue
            pronunciations[key] = ipa
    return pronunciations, source_rows, collision_rows


def build(
    source_path: Path,
    dictionary_path: Path,
    output_path: Path,
    metadata_path: Path,
) -> dict[str, Any]:
    source_hash = sha256(source_path)
    if source_hash != SOURCE_SHA256:
        raise ValueError(
            "Unexpected IPA source SHA-256. Expected the pinned "
            f"ipa-dict commit {SOURCE_COMMIT}: {SOURCE_SHA256}; got {source_hash}"
        )

    dictionary = read_dictionary(dictionary_path)
    pronunciations, source_rows, collision_rows = read_ipa_source(source_path)
    matched_keys = sorted(dictionary.keys() & pronunciations.keys())
    output_path.parent.mkdir(parents=True, exist_ok=True)
    with output_path.open("w", encoding="utf-8", newline="\n") as output:
        for key in matched_keys:
            output.write(
                json.dumps(
                    {"word": dictionary[key], "ipa": pronunciations[key]},
                    ensure_ascii=False,
                    separators=(",", ":"),
                )
            )
            output.write("\n")

    matched = len(matched_keys)
    metadata: dict[str, Any] = {
        "language": "English (General American)",
        "languageCode": "en_US",
        "sourceProject": "open-dict-data/ipa-dict",
        "sourceCommit": SOURCE_COMMIT,
        "sourceFile": "data/en_US.txt",
        "sourceUrl": SOURCE_URL,
        "sourceSha256": source_hash,
        "sourceRows": source_rows,
        "dictionaryFile": dictionary_path.as_posix(),
        "dictionarySha256": sha256(dictionary_path),
        "dictionaryHeadwords": len(dictionary),
        "exactNormalizedMatches": matched,
        "dictionaryCoveragePercent": round(matched * 100 / len(dictionary), 2)
        if dictionary
        else 0,
        "unmatchedHeadwords": len(dictionary) - matched,
        "normalizedSourceCollisionRows": collision_rows,
        "ipaSources": [
            {
                "project": "lingz/cmudict-ipa",
                "url": "https://github.com/lingz/cmudict-ipa",
                "license": "MIT",
            },
            {
                "project": "kylebgorman/syllabify",
                "url": "https://github.com/kylebgorman/syllabify",
                "license": "MIT",
            },
        ],
        "license": "MIT (en_US subset only; see SOURCES.md)",
        "derivedRows": matched,
        "derivedBytes": output_path.stat().st_size,
        "derivedSha256": sha256(output_path),
    }
    metadata_path.parent.mkdir(parents=True, exist_ok=True)
    metadata_path.write_text(
        json.dumps(metadata, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
        newline="\n",
    )
    return metadata


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--dictionary", type=Path, default=DEFAULT_DICTIONARY)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--metadata", type=Path, default=DEFAULT_METADATA)
    args = parser.parse_args()
    try:
        stats = build(args.source, args.dictionary, args.output, args.metadata)
    except (OSError, UnicodeError, ValueError) as error:
        print(f"Error: {error}", file=sys.stderr)
        return 1
    print(json.dumps(stats, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
