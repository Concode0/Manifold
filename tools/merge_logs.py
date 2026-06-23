"""
Merge per-node NDJSON logs into a single time-sorted cluster log.
"""
from __future__ import annotations

import glob
import json
import os
import sys
from collections import Counter

DEFAULT_LOG_DIR = "logs"
DEFAULT_INPUT_GLOB = "node_*.log"
DEFAULT_OUTPUT = "logs/cluster_merged.jsonl"


def load_records(paths: list[str]) -> list[dict]:
    """Read every JSON object from the given files. Non-JSON lines are skipped."""
    records: list[dict] = []
    skipped = 0
    for path in paths:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line or not line.startswith("{"):
                    skipped += 1
                    continue
                try:
                    records.append(json.loads(line))
                except json.JSONDecodeError:
                    skipped += 1
    if skipped:
        print(f"  skipped {skipped} non-JSON / blank lines", file=sys.stderr)
    return records


def merge(records: list[dict]) -> list[dict]:
    """Sort by ts_unix (monotonic Unix microseconds)."""
    records.sort(key=lambda r: r.get("ts_unix", 0))
    return records


def write(records: list[dict], out_path: str) -> None:
    os.makedirs(os.path.dirname(out_path) or ".", exist_ok=True)
    with open(out_path, "w") as f:
        for r in records:
            f.write(json.dumps(r))
            f.write("\n")


def verify(records: list[dict]) -> bool:
    """Sanity-check the merged stream. Returns True if all checks pass."""
    ok = True

    # 1. Monotonic ts_unix
    prev = -1
    out_of_order = 0
    for r in records:
        ts = r.get("ts_unix", 0)
        if ts < prev:
            out_of_order += 1
        prev = ts
    if out_of_order:
        print(f"  FAIL: {out_of_order} records out of ts_unix order")
        ok = False
    else:
        print(f"  ok: ts_unix monotonic ({len(records)} records)")

    # 2. Every record has the canonical envelope fields
    required = {"ts", "ts_unix", "event", "node", "seq"}
    missing = sum(1 for r in records if not required.issubset(r))
    if missing:
        print(f"  FAIL: {missing} records missing canonical fields {required}")
        ok = False
    else:
        print(f"  ok: all records carry canonical envelope {sorted(required)}")

    # 3. Per-node seq is monotonic (catches mis-merges)
    seq_violations = 0
    last_seq: dict[str, int] = {}
    for r in records:
        node = r["node"]
        s = r["seq"]
        if node in last_seq and s < last_seq[node]:
            seq_violations += 1
        last_seq[node] = s
    if seq_violations:
        print(f"  warn: {seq_violations} per-node seq regressions (possible clock skew)")
    else:
        print(f"  ok: per-node seq monotonic for {len(last_seq)} nodes")

    # 4. Coverage summary
    per_node = Counter(r["node"] for r in records)
    per_event = Counter(r["event"] for r in records)
    if records:
        t0 = records[0]["ts_unix"]
        t1 = records[-1]["ts_unix"]
        span_s = (t1 - t0) / 1e6
        print(f"  span: {span_s:.2f}s  ({records[0]['ts']}  ->  {records[-1]['ts']})")
    print(f"  per-node records:")
    for n in sorted(per_node):
        print(f"    {n}: {per_node[n]}")
    print(f"  per-event records:")
    for ev in sorted(per_event):
        print(f"    {ev}: {per_event[ev]}")
    return ok


def main() -> int:
    import argparse

    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("inputs", nargs="*", help="log files to merge (default: logs/node_*.log)")
    p.add_argument("-o", "--output", default=DEFAULT_OUTPUT, help="output path")
    p.add_argument("--check", action="store_true",
                   help="only verify the existing merged file, do not re-merge")
    args = p.parse_args()

    if args.check:
        if not os.path.exists(args.output):
            print(f"error: {args.output} does not exist", file=sys.stderr)
            return 2
        print(f"Verifying {args.output}...")
        records = load_records([args.output])
        ok = verify(records)
        return 0 if ok else 1

    if args.inputs:
        paths = args.inputs
    else:
        paths = sorted(glob.glob(os.path.join(DEFAULT_LOG_DIR, DEFAULT_INPUT_GLOB)))
    if not paths:
        print("error: no input logs found", file=sys.stderr)
        return 2

    print(f"Merging {len(paths)} log files:")
    for path in paths:
        print(f"  {path}")
    records = load_records(paths)
    merge(records)
    write(records, args.output)
    print(f"\nWrote {len(records)} records to {args.output}")
    print("\nVerification:")
    ok = verify(records)
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
