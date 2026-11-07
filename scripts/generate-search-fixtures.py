#!/usr/bin/env python3
"""Write deterministic ASCII search fixtures with bounded memory.

The corpus is 127 `x` bytes then LF, repeated. Six unique tokens replace
filler bytes (never LF) near BOF, the midpoint, and EOF. A JSON manifest
records exact byte offsets; ASCII makes them UTF-16 offsets in the editor.
"""

import argparse
import hashlib
import json
from pathlib import Path

MIB = 1024 * 1024
SIZES = {"100MiB": 100 * MIB, "1GiB": 1024 * MIB, "10GiB": 10 * 1024 * MIB}
BLOCK = (b"x" * 127 + b"\n") * (MIB // 128)


def tokens(size):
    locations = {
        "begin": 32,
        "middle": (size // 2 // 128) * 128 + 32,
        "end": size - 256 + 32,
    }
    inserts = []
    cases = []
    for position, base in locations.items():
        for kind, displacement in (("short", 0), ("long", 16)):
            name = f"{position}-{kind}"
            if kind == "short":
                token = {"begin": "Q7zB0!", "middle": "Q7zM1!", "end": "Q7zE2!"}[position]
            else:
                token = ("SIMD_SEARCH_" + position.upper() + "_" + "0123456789ABCDEF" * 4)[:64]
            offset = base + displacement
            assert offset % 128 + len(token) < 127
            inserts.append((offset, token.encode("ascii")))
            cases.append({"name": name, "query": token, "expectedByteOffset": offset,
                          "expectedLength": len(token)})
    cases.append({"name": "absent", "query": "Z9_NOT_IN_FIXTURE!",
                  "expectedByteOffset": None, "expectedLength": 0})
    return inserts, cases


def expected_manifest(label, path, digest):
    _, cases = tokens(SIZES[label])
    return {"formatVersion": 1, "file": str(path.resolve()), "sizeBytes": SIZES[label],
            "sha256": digest, "cases": cases}


def validate_existing(label, path, manifest_path):
    size = SIZES[label]
    if path.stat().st_size != size:
        raise ValueError(f"{path}: expected {size} bytes, found {path.stat().st_size}")
    manifest = json.loads(manifest_path.read_text())
    if not isinstance(manifest.get("sha256"), str) or len(manifest["sha256"]) != 64:
        raise ValueError(f"{manifest_path}: invalid SHA-256 field")
    if manifest != expected_manifest(label, path, manifest["sha256"]):
        raise ValueError(f"{manifest_path}: metadata or cases differ from generator definition")


def blocks(size, inserts):
    for start in range(0, size, len(BLOCK)):
        block = bytearray(BLOCK[:min(len(BLOCK), size - start)])
        for offset, token in inserts:
            if start <= offset < start + len(block):
                relative = offset - start
                block[relative:relative + len(token)] = token
        yield block


def generate(label, output_dir, force):
    size = SIZES[label]
    path = output_dir / f"search-{label.lower()}.txt"
    manifest_path = output_dir / f"search-{label.lower()}.json"
    if not force and path.exists() and manifest_path.exists():
        validate_existing(label, path, manifest_path)
        print(f"{label}: reused {path} and {manifest_path}")
        return
    inserts, _ = tokens(size)
    digest = hashlib.sha256()
    if path.exists() and not force:
        if path.stat().st_size != size:
            raise ValueError(f"{path}: wrong size; use --force to replace it")
        with path.open("rb") as file:
            for expected in blocks(size, inserts):
                actual = file.read(len(expected))
                if actual != expected:
                    raise ValueError(f"{path}: content differs from deterministic fixture; use --force")
                digest.update(actual)
        print(f"{label}: verified existing file; writing missing manifest")
    else:
        with path.open("wb") as file:
            for block in blocks(size, inserts):
                file.write(block)
                digest.update(block)
    manifest = expected_manifest(label, path, digest.hexdigest())
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"{label}: {path} ({size} bytes), {manifest_path}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--sizes", nargs="+", choices=SIZES, default=list(SIZES))
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=True)
    for label in args.sizes:
        generate(label, args.output_dir, args.force)


if __name__ == "__main__":
    main()
