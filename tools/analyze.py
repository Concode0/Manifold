"""Analyze a merged cluster log: hop distribution, acceptor distribution,
self-acceptance, timing, and the top back-and-forth migration pairs.
"""
from __future__ import annotations

import json
import sys
from collections import Counter, defaultdict


def load(path: str) -> list[dict]:
    out = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line.startswith("{"):
                try:
                    out.append(json.loads(line))
                except json.JSONDecodeError:
                    pass
    return out


ADDR_TO_NODE = {f"node_0{i}:8001": f"node_0{i}" for i in range(1, 9)}


def main() -> int:
    path = sys.argv[1] if len(sys.argv) > 1 else "logs/cluster_merged.jsonl"
    recs = load(path)
    print(f"# Analysis: {path}")
    print(f"records: {len(recs)}")

    accepts = [r for r in recs if r["event"] == "TASK_ACCEPT"]
    migrates = [r for r in recs if r["event"] == "TASK_MIGRATE"]
    spawns = [r for r in recs if r["event"] == "TASK_SPAWN"]
    completes = [r for r in recs if r["event"] == "TASK_COMPLETE"]

    # Spawn count fallback: tasks are identified by UUID. Count unique tasks
    # seen across migrate+accept events if no explicit spawn event.
    all_tasks = set()
    for r in accepts + migrates:
        tid = r["fields"].get("task", "")
        if tid:
            all_tasks.add(tid)
    spawned = len(spawns) if spawns else len(all_tasks)
    print(f"\n## Volume")
    print(f"- tasks tracked: {len(all_tasks)} (spawn events: {len(spawns)})")
    print(f"- accepts: {len(accepts)}")
    print(f"- completes: {len(completes)}")
    print(f"- migrations: {len(migrates)}")

    # Hop distribution from accept events.
    hop_buckets = Counter()
    for r in accepts:
        h = r["fields"].get("hops", 0)
        if h == 0:
            hop_buckets["0 (origin)"] += 1
        elif h >= 8:
            hop_buckets[f"{h} (MaxHops)"] += 1
        else:
            hop_buckets[str(h)] += 1
    # Collapse 1-7 bucket
    one_seven = sum(v for k, v in hop_buckets.items() if k.isdigit() and 1 <= int(k) <= 7)
    eight = hop_buckets.get("8 (MaxHops)", 0)
    zero = hop_buckets.get("0 (origin)", 0)
    total = len(accepts) or 1
    print(f"\n## Hop distribution (at accept)")
    print(f"| Hops | Tasks | Fraction |")
    print(f"|---|---|---|")
    print(f"| 0 (accepted at origin) | {zero} | {zero/total:.1%} |")
    print(f"| 1-7 | {one_seven} | {one_seven/total:.1%} |")
    print(f"| 8 (MaxHops ceiling) | {eight} | {eight/total:.1%} |")

    # Self-acceptance: accept at origin => hops==0. Also compute origin node
    # by finding first event for the task (the spawn/migrate source).
    self_accept = zero
    print(f"\n## Self-acceptance: {self_accept}/{len(accepts)} = {self_accept/total:.1%}")

    # Acceptor distribution.
    acc_by_node = Counter(r["node"] for r in accepts)
    print(f"\n## Acceptor distribution")
    print(f"| Node | Accepts |")
    print(f"|---|---|")
    for n, c in acc_by_node.most_common():
        print(f"| `{n}` | {c} |")

    # Top back-and-forth pairs: for each task, look at the sequence of
    # (sender, target) migrate edges and count undirected pairs.
    task_edges: dict[str, list] = defaultdict(list)
    for r in migrates:
        tid = r["fields"].get("task", "")
        tgt = ADDR_TO_NODE.get(r["fields"].get("target", ""), r["fields"].get("target", ""))
        src = r["node"]
        if tid:
            task_edges[tid].append((src, tgt))
    pair_counts = Counter()
    for tid, edges in task_edges.items():
        for a, b in edges:
            pair = tuple(sorted((a, b)))
            pair_counts[pair] += 1
    print(f"\n## Top migration pairs (back-and-forth edges)")
    print(f"| Pair | Migrations |")
    print(f"|---|---|")
    for (a, b), c in pair_counts.most_common(8):
        print(f"| `{a} ↔ {b}` | {c} |")

    # Flight time: spawn -> accept. We don't have spawn events with ts, so
    # use first-seen -> accept per task.
    first_seen: dict[str, int] = {}
    accept_ts: dict[str, int] = {}
    for r in recs:
        f = r.get("fields", {})
        tid = f.get("task", "")
        if not tid:
            continue
        ts = r["ts_unix"]
        if r["event"] in ("TASK_MIGRATE", "TASK_ACCEPT"):
            if tid not in first_seen:
                first_seen[tid] = ts
        if r["event"] == "TASK_ACCEPT":
            accept_ts[tid] = ts
    flights = []
    for tid, t0 in first_seen.items():
        if tid in accept_ts:
            flights.append((accept_ts[tid] - t0) / 1000.0)  # ms
    if flights:
        flights.sort()
        n = len(flights)
        med = flights[n // 2]
        mean = sum(flights) / n
        print(f"\n## Flight time (first-seen -> accept), ms")
        print(f"- median: {med:.0f}ms, mean: {mean:.0f}ms, max: {max(flights):.0f}ms, n={n}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
