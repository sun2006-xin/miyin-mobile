"""Local, redacted public-content audit of reachable Git objects.

This is a bounded pattern scanner, not a substitute for a complete security audit.
It never contacts a service, reads untracked files, or prints matched secret values.
"""
from __future__ import annotations

import argparse
import hashlib
import io
import json
import math
import re
import subprocess
import tarfile
from collections import Counter, defaultdict
from pathlib import Path


RULES = {
    "private-key": re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH |DSA |ENCRYPTED )?PRIVATE KEY-----"),
    "github-token": re.compile(r"\b(?:gh[pousr]_[A-Za-z0-9_]{30,255}|github_pat_[A-Za-z0-9_]{40,255})\b"),
    "aws-access-key": re.compile(r"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b"),
    "google-api-key": re.compile(r"\bAIza[A-Za-z0-9_-]{35}\b"),
    "provider-sk-key": re.compile(r"\bsk-(?:proj-|ant-api\d+-)?[A-Za-z0-9_-]{20,255}\b"),
    "slack-token": re.compile(r"\bxox[baprs]-[A-Za-z0-9-]{20,255}\b"),
    "jwt": re.compile(r"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{16,}\b"),
    "credentialed-url": re.compile(r"(?i)\b(?:https?|ftp)://[^\s/'\"<>:]+:[^\s/'\"<>@]{3,}@"),
    "literal-credential": re.compile(
        r"(?i)(?:api[_-]?key|access[_-]?token|auth[_-]?token|client[_-]?secret|"
        r"secret[_-]?key|password|passwd|bearer)\s*['\"]?\s*(?:=|:)\s*['\"]([^'\"\r\n]{6,512})['\"]"
    ),
}
EMAIL = re.compile(r"(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b")
PRIVATE_NETWORK = re.compile(r"\b(?:10(?:\.\d{1,3}){3}|192\.168(?:\.\d{1,3}){2}|172\.(?:1[6-9]|2\d|3[01])(?:\.\d{1,3}){2})\b")
SENSITIVE_PATH = re.compile(r"(?i)(?:^|/)(?:\.env(?:\..*)?|key\.properties|auth\.json|credentials?(?:\.[^/]*)?|id_rsa|id_ed25519)$|\.(?:jks|keystore|p12|pfx|pem|key)$")
MEDIA_EXT = {".png", ".jpg", ".jpeg", ".webp", ".wav", ".mp3", ".mp4", ".m4a", ".ogg", ".sqlite", ".db", ".log"}


def entropy(value: str) -> float:
    counts = Counter(value)
    return -sum(n / len(value) * math.log2(n / len(value)) for n in counts.values()) if value else 0


def placeholder(value: str) -> bool:
    value = value.lower()
    return bool(re.search(r"(?:example|placeholder|dummy|fake|test[-_]|[-_]test|your[-_]|replace[-_]|redacted|changeme|mock|fixture)", value)) or len(set(value)) <= 3


def git(repo: Path, *args: str) -> bytes:
    return subprocess.check_output(["git", "-c", "core.quotepath=false", *args], cwd=repo)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=Path.cwd())
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--max-lfs-member-bytes", type=int, default=8 * 1024 * 1024)
    args = parser.parse_args()
    repo = args.repo.resolve()
    args.output.mkdir(parents=True, exist_ok=True)
    head = git(repo, "rev-parse", "HEAD").decode().strip()
    objects = git(repo, "rev-list", "--objects", "--all").decode("utf-8").splitlines()
    object_paths: dict[str, set[str]] = defaultdict(set)
    for row in objects:
        oid, _, path = row.partition(" ")
        if path:
            object_paths[oid].add(path)
    commits = git(repo, "rev-list", "--all").decode().splitlines()
    current = git(repo, "ls-files", "-s", "-z").split(b"\0")
    current_paths = {}
    for row in current:
        if not row:
            continue
        meta, path = row.split(b"\t", 1)
        oid = meta.split()[1].decode()
        decoded = path.decode("utf-8")
        current_paths[decoded] = oid
        object_paths[oid].add(decoded)
    all_oids = list(dict.fromkeys(row.split(" ", 1)[0] for row in objects))
    process = subprocess.Popen(["git", "cat-file", "--batch"], cwd=repo, stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    findings = []
    email_hits = defaultdict(lambda: {"count": 0, "locations": []})
    networks = defaultdict(lambda: {"count": 0, "locations": []})
    stats = Counter()
    lfs_pointers = {}
    media = []
    path_flags = []
    archive_inventory = []

    def scan(data: bytes, oid: str, location: str, kind: str):
        stats[kind + "_bytes"] += len(data)
        # Binary strings receive signature scans too; no entropy-only binary scan.
        binary = b"\0" in data[:8192]
        text = data.decode("utf-8", errors="replace")
        stats[kind + "_objects"] += 1
        if binary:
            stats["binary_objects_signature_scanned"] += 1
        for rule, pattern in RULES.items():
            for match in pattern.finditer(text):
                value = match.group(1) if rule == "literal-credential" else match.group()
                if rule == "literal-credential" and (entropy(value) < 3.1 or not re.fullmatch(r"[A-Za-z0-9_./+=:@-]+", value)):
                    continue
                line = text.count("\n", 0, match.start()) + 1
                findings.append({"rule": rule, "oid": oid, "location": location, "line": line,
                                 "sha256Prefix": hashlib.sha256(value.encode()).hexdigest()[:16],
                                 "length": len(value), "placeholderMarker": placeholder(value),
                                 "binary": binary})
        if not binary:
            for pattern, target in [(EMAIL, email_hits), (PRIVATE_NETWORK, networks)]:
                for match in pattern.finditer(text):
                    value = match.group()
                    fingerprint = hashlib.sha256(value.lower().encode()).hexdigest()[:16]
                    target[fingerprint]["count"] += 1
                    if len(target[fingerprint]["locations"]) < 6:
                        target[fingerprint]["locations"].append({"location": location, "line": text.count("\n", 0, match.start()) + 1, "oid": oid})
        return text

    for oid in all_oids:
        process.stdin.write((oid + "\n").encode()); process.stdin.flush()
        header = process.stdout.readline().decode().strip().split()
        if len(header) != 3:
            raise RuntimeError("Invalid Git batch object header")
        _, kind, length = header
        data = process.stdout.read(int(length)); process.stdout.read(1)
        stats["git_" + kind + "_objects"] += 1
        if kind == "tree":
            continue
        paths = sorted(object_paths.get(oid, []))
        location = paths[0] if paths else ("commit:" + oid if kind == "commit" else "object:" + oid)
        if kind == "blob":
            for path in paths:
                if SENSITIVE_PATH.search(path):
                    path_flags.append({"oid": oid, "path": path})
                if Path(path).suffix.lower() in MEDIA_EXT:
                    media.append({"oid": oid, "path": path, "bytes": len(data), "current": current_paths.get(path) == oid})
        text = scan(data, oid, location, kind)
        if kind == "blob" and text.startswith("version https://git-lfs.github.com/spec/v1\n"):
            match = re.search(r"oid sha256:([0-9a-f]{64})\nsize (\d+)", text)
            if match:
                lfs_pointers[match.group(1)] = {"paths": paths, "bytes": int(match.group(2)), "pointerOid": oid}
    process.stdin.close(); process.wait()
    git_dir = Path(git(repo, "rev-parse", "--absolute-git-dir").decode().strip())
    for oid, item in lfs_pointers.items():
        path = git_dir / "lfs/objects" / oid[:2] / oid[2:4] / oid
        item["availableLocally"] = path.is_file()
        if not path.is_file():
            continue
        item["sizeMatches"] = path.stat().st_size == item["bytes"]
        # Full binary weights are not ingested or decoded by this audit.
        display = item["paths"][0] if item["paths"] else "lfs:" + oid
        if display.endswith((".tar.gz", ".tar.bz2")):
            with tarfile.open(path, "r|*") as archive:
                for member in archive:
                    stats["lfs_archive_members"] += 1
                    name = display + "!" + member.name
                    if SENSITIVE_PATH.search(member.name):
                        path_flags.append({"oid": oid, "path": name})
                    if not member.isfile():
                        continue
                    if member.size > args.max_lfs_member_bytes or Path(member.name).suffix.lower() in {".onnx", ".gguf", ".bin", ".fst"}:
                        stats["lfs_archive_binary_or_large_members_skipped"] += 1
                        continue
                    data = archive.extractfile(member).read()
                    scan(data, oid, name, "lfs_archive_text")
                    archive_inventory.append({"archiveOid": oid, "member": member.name, "bytes": member.size})
        elif item["bytes"] <= args.max_lfs_member_bytes and Path(display).suffix.lower() in {".txt", ".json", ".jsonl", ".md", ".yaml", ".toml"}:
            scan(path.read_bytes(), oid, display, "lfs_text")
        else:
            stats["lfs_binary_weights_skipped"] += 1
    report = {"head": head, "reachableCommits": len(commits), "trackedPaths": len(current_paths),
              "stats": dict(stats), "secretCandidates": findings, "sensitivePaths": path_flags,
              "emailFingerprints": dict(email_hits), "privateNetworkFingerprints": dict(networks),
              "mediaAndDataPaths": media, "lfsObjects": lfs_pointers,
              "archiveTextMembers": archive_inventory,
              "limits": ["No untracked files, reflog-only/unreachable objects, remote-only branches, or private user directories read.",
                         "Large LFS model weights skipped; text model metadata and bounded archive text members scanned.",
                         "Binary Git blobs scanned for structured secret signatures, not OCR, private speech, or binary entropy extraction.",
                         "Pattern scans cannot prove absence of all credentials or personal data."]}
    (args.output / "public-content-scan.json").write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps({"head": head, "reachableCommits": len(commits), "trackedPaths": len(current_paths),
                      "stats": dict(stats), "secretCandidateCount": len(findings), "sensitivePathCount": len(path_flags),
                      "emailFingerprints": len(email_hits), "privateNetworkFingerprints": len(networks),
                      "mediaDataObjectPaths": len(media), "lfsObjects": len(lfs_pointers)}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
