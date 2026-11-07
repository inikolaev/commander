#!/usr/bin/env python3
"""Compare selectable literal matchers on mixed and adversarial text files."""

import argparse
import json
import statistics
import subprocess
from pathlib import Path


MIXED_SIZE = 16 * 1024 * 1024
MARKER = "SEARCH_SENTINEL_7qZ_2026"
CASES = (
    ("mixed-end", "mixed", MARKER, MIXED_SIZE - 128, len(MARKER)),
    ("mixed-short-end", "mixed", "7qZ_2026",
     MIXED_SIZE - 128 + MARKER.index("7qZ_2026"), len("7qZ_2026")),
    ("mixed-absent", "mixed", "ABSENT_9xQ_LITERAL", None, 0),
    ("mixed-short-absent", "mixed", "NOHIT9!", None, 0),
    ("mixed-byte-absent", "mixed", "~", None, 0),
    ("mixed-common-miss", "mixed", "status=500", None, 0),
    ("mixed-long-miss", "mixed", "Z" * 64, None, 0),
    ("repeated-near-miss", "repeated", "xxxyxx", None, 0),
    ("repeated-short-miss", "repeated", "@", None, 0),
    ("periodic-near-miss", "periodic", "ababacab", None, 0),
    ("periodic-long-near-miss", "periodic", "ababababababacab", None, 0),
)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--fixtures", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--matchers", nargs="+", default=["foundation", "darwin-memmem"])
    parser.add_argument("--iterations", type=int, default=8)
    args = parser.parse_args()
    if args.iterations < 2:
        parser.error("--iterations must include a warmup and at least one timed run")
    files = {
        "mixed": args.fixtures / "search-mixed-16mib.txt",
        "repeated": args.fixtures / "search-100mib.txt",
        "periodic": args.fixtures / "search-periodic-16mib.txt",
    }
    for file in files.values():
        if not file.is_file():
            parser.error(f"Missing {file}; generate the corpus before running benchmarks")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w") as output:
        for name, corpus, query, expected_offset, expected_length in CASES:
            for surface in ("viewer", "editor"):
                for direction in ("forward", "backward"):
                    for matcher in args.matchers:
                        command = [str(args.binary), "--file", str(files[corpus]),
                                   "--surface", surface, "--operation", "search", "--query", query,
                                   "--direction", direction, "--matcher", matcher,
                                   "--iterations", str(args.iterations),
                                   "--expect-length", str(expected_length)]
                        if expected_offset is not None:
                            command += ["--expect-offset", str(expected_offset)]
                        result = subprocess.run(command, capture_output=True, text=True)
                        if result.returncode:
                            raise RuntimeError(f"{' '.join(command)}\n{result.stderr}")
                        rows = [json.loads(line) for line in result.stdout.splitlines()]
                        if (len(rows) != args.iterations + 1
                                or any(row.get("correct") is False or row.get("matcher") != matcher
                                       for row in rows)):
                            raise RuntimeError(f"Invalid benchmark output: {' '.join(command)}")
                        for row in rows:
                            row["matcherCase"] = name
                            output.write(json.dumps(row, sort_keys=True) + "\n")
                        output.flush()
                        median = statistics.median(row["elapsedNs"] for row in rows[2:]) / 1e6
                        print(f"{name} {surface} {direction} {matcher}: {median:.3f} ms", flush=True)


if __name__ == "__main__":
    main()
