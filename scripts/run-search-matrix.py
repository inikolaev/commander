#!/usr/bin/env python3
"""Run the fixed search benchmark matrix and retain per-iteration JSON Lines."""

import argparse
import json
import statistics
import subprocess
import sys
from pathlib import Path


CASES = {
    "100MiB": [
        *((name, sensitive, "forward") for name in
          ("begin-short", "middle-short", "end-short", "begin-long", "middle-long", "end-long", "absent")
          for sensitive in (False, True)),
        *((name, sensitive, "backward") for name in ("begin-short", "middle-long", "absent")
          for sensitive in (False, True)),
    ],
    "1GiB": [
        ("begin-short", False, "forward"), ("middle-short", False, "forward"),
        ("end-short", False, "forward"), ("end-long", False, "forward"),
        ("end-long", True, "forward"), ("absent", False, "forward"),
        ("begin-short", False, "backward"),
    ],
    "10GiB": [
        ("begin-short", False, "forward"), ("middle-long", False, "forward"),
        ("end-short", False, "forward"), ("end-long", False, "forward"),
        ("end-long", True, "forward"),
        ("absent", False, "forward"), ("begin-short", False, "backward"),
    ],
}
ITERATIONS = {"100MiB": 8, "1GiB": 6, "10GiB": 4}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--fixtures", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--sizes", nargs="+", choices=CASES, default=list(CASES))
    parser.add_argument("--surfaces", nargs="+", choices=("viewer", "editor"), default=["viewer", "editor"])
    parser.add_argument("--matcher", choices=("foundation", "darwin-memmem"), default="foundation")
    parser.add_argument("--iterations", type=int, help="Override per-size iteration count (first is warmup)")
    args = parser.parse_args()
    if args.iterations is not None and args.iterations < 2:
        parser.error("--iterations must be at least 2")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    summaries = []
    with args.output.open("w") as output:
        for size in args.sizes:
            manifest = args.fixtures / f"search-{size.lower()}.json"
            if not manifest.is_file():
                parser.error(f"Missing {manifest}; run generate-search-fixtures.py first")
            count = args.iterations or ITERATIONS[size]
            for surface in args.surfaces:
                scenarios = [("scan", None, False, direction) for direction in ("forward", "backward")]
                scenarios += [("search", name, sensitive, direction) for name, sensitive, direction in CASES[size]]
                for operation, name, sensitive, direction in scenarios:
                    command = [str(args.binary), "--manifest", str(manifest), "--surface", surface,
                               "--operation", operation, "--direction", direction,
                               "--iterations", str(count), "--matcher", args.matcher]
                    if name is not None:
                        command += ["--case", name]
                    if sensitive:
                        command += ["--case-sensitive"]
                    result = subprocess.run(command, text=True, capture_output=True)
                    if result.returncode:
                        sys.stderr.write(result.stderr)
                        raise RuntimeError(f"Benchmark failed: {' '.join(command)}")
                    records = [json.loads(line) for line in result.stdout.splitlines()]
                    if (len(records) != count + 1
                            or any(record.get("correct") is False or record.get("matcher") != args.matcher
                                   for record in records)):
                        raise RuntimeError(f"Invalid benchmark output: {' '.join(command)}")
                    for record in records:
                        record["fixtureSize"] = size
                        output.write(json.dumps(record, sort_keys=True) + "\n")
                    output.flush()
                    times = [record["elapsedNs"] / 1e9 for record in records[2:]]
                    median = statistics.median(times)
                    scenario = f"{size} {surface} {operation} {name or '-'} {'CS' if sensitive else 'CI'} {direction}"
                    summaries.append((scenario, median))
                    print(f"{scenario}: {median:.6f} s", flush=True)
    print(f"Saved {len(summaries)} scenarios to {args.output}")


if __name__ == "__main__":
    main()
