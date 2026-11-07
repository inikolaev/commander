#!/usr/bin/env python3
"""Create one small, deterministic mixed-text search corpus if it is missing."""

import argparse
import json
from pathlib import Path


SIZE = 16 * 1024 * 1024
BLOCK = 1024 * 1024
MARKER = b"SEARCH_SENTINEL_7qZ_2026"
MARKER_OFFSET = SIZE - 128
LINES = (
    b'2026-11-07T10:42:12Z INFO request path=/api/files status=200 bytes=8192\n',
    b'2026-11-07T10:42:13Z WARN cache miss key=preview-42 duration_ms=18\n',
    b'{"event":"open","path":"src/search/core.swift","count":17,"ok":true}\n',
    b'func search(in bytes: Data, from offset: Int) -> Range<Int>? { return nil }\n',
    b'let result = input.map { value in value.lowercased() }.joined()\n',
    b'The editor keeps a snapshot while the viewer reads the file in blocks.\n',
    b'GET /documents/report-2026.txt HTTP/1.1 host=localhost user=operator\n',
    b'{"level":"debug","message":"loading a text block","elapsed":4.25}\n',
)


def make_block() -> bytes:
    data = bytearray()
    state = 0x51A1C0DE
    while len(data) < BLOCK:
        state = (1664525 * state + 1013904223) & 0xFFFFFFFF
        data.extend(LINES[state % len(LINES)])
        data.extend(f"id={state:08x} offset={len(data):08x}\n".encode("ascii"))
    return bytes(data[:BLOCK])


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--periodic-output", type=Path,
                        help="Also create an all-'ab' adversarial corpus if missing")
    args = parser.parse_args()
    path = args.output.resolve()
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        if path.stat().st_size != SIZE:
            parser.error(f"Existing corpus has the wrong size: {path}")
        reused = True
    else:
        block = make_block()
        with path.open("xb") as output:
            for _ in range(SIZE // BLOCK - 1):
                output.write(block)
            final = bytearray(block)
            final[BLOCK - 128:BLOCK - 128 + len(MARKER)] = MARKER
            output.write(final)
        reused = False
    print(json.dumps({"file": str(path), "bytes": SIZE, "marker": MARKER.decode("ascii"),
                      "markerOffset": MARKER_OFFSET, "reused": reused}, sort_keys=True))
    if args.periodic_output is not None:
        periodic = args.periodic_output.resolve()
        periodic.parent.mkdir(parents=True, exist_ok=True)
        if periodic.exists():
            if periodic.stat().st_size != SIZE:
                parser.error(f"Existing periodic corpus has the wrong size: {periodic}")
            expected = b"ab" * (BLOCK // 2)
            with periodic.open("rb") as source:
                for offset in range(0, SIZE, BLOCK):
                    if source.read(BLOCK) != expected:
                        parser.error(f"Existing periodic corpus content differs at byte {offset}: {periodic}")
            periodic_reused = True
        else:
            with periodic.open("xb") as output:
                block = b"ab" * (BLOCK // 2)
                for _ in range(SIZE // BLOCK):
                    output.write(block)
            periodic_reused = False
        print(json.dumps({"file": str(periodic), "bytes": SIZE,
                          "reused": periodic_reused}, sort_keys=True))


if __name__ == "__main__":
    main()
