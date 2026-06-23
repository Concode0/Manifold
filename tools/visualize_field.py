"""
Potential-field visualization for a basin cluster run.
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import subprocess
import sys
from collections import defaultdict

import numpy as np
from scipy.interpolate import RBFInterpolator

LOG_PATH = "logs/cluster_merged.jsonl"
VIDEO_PATH = "viz/potential_field.mp4"

POT_CAP = 8.0           # Clip extreme values for display
CLOTH_RES = 24          # Field grid resolution
FPS = 5                # Output video framerate

# Fixed 2D layout: 3x3 grid (8 nodes, one slot empty).
NODE_GRID = {
    "node_01": (0.0, 0.0), "node_02": (1.0, 0.0), "node_03": (2.0, 0.0),
    "node_04": (0.0, 1.0), "node_05": (1.0, 1.0), "node_06": (2.0, 1.0),
    "node_07": (0.0, 2.0), "node_08": (1.0, 2.0),
}
ADDR_TO_NODE = {f"{n}:8001": n for n in NODE_GRID}


def ensure_merged_log(path: str) -> None:
    """Run tools/merge_logs.py if the merged log is missing or older than
    any per-node log. Keeps visualization a single entry point."""
    if os.path.exists(path):
        newest_input = max(
            (os.path.getmtime(p) for p in glob.glob("logs/node_*.log")),
            default=0,
        )
        if os.path.getmtime(path) >= newest_input:
            return
    print("Merged log missing or stale — running merge_logs.py...")
    cmd = [sys.executable, os.path.join("tools", "merge_logs.py")]
    if subprocess.call(cmd) != 0:
        print("merge_logs.py failed", file=sys.stderr)
        sys.exit(1)


def load_events(path: str) -> list[dict]:
    records = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or not line.startswith("{"):
                continue
            try:
                records.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    records.sort(key=lambda r: r.get("ts_unix", 0))
    return records


def build_potential_timeline(records: list[dict]) -> list[tuple[int, dict]]:
    """Per-node potential snapshots grouped by ~500ms windows."""
    slices: list[tuple[int, dict]] = []
    current_ts = None
    current_nodes: dict[str, dict] = {}

    for rec in records:
        if rec["event"] != "POTENTIAL":
            continue
        ts = rec["ts_unix"]
        node = rec["node"]
        f = rec["fields"]

        pot = f.get("self_potential", 0)
        if pot > POT_CAP:
            pot = POT_CAP

        node_state = {
            "comp": f.get("self_comp", 0),
            "mem": f.get("self_mem", 0),
            "net": f.get("self_net", 0),
            "potential": pot,
            "load": f.get("self_load", 0),
            "queue": f.get("self_queue", 0),
        }

        window = ts // 500_000
        if current_ts is None:
            current_ts = window
        if window != current_ts:
            if current_nodes:
                slices.append((current_ts * 500_000, dict(current_nodes)))
            current_ts = window
            current_nodes = {}
        current_nodes[node] = node_state

    if current_nodes:
        slices.append((current_ts * 500_000, dict(current_nodes)))
    return slices


def build_task_timeline(records: list[dict]) -> dict[str, list]:
    tasks = defaultdict(list)
    for rec in records:
        ev = rec["event"]
        if ev not in ("TASK_MIGRATE", "TASK_ACCEPT", "TASK_COMPLETE"):
            continue
        f = rec["fields"]
        tid = f.get("task", "")
        if not tid:
            continue
        ts = rec["ts_unix"]
        if ev == "TASK_MIGRATE":
            target_addr = f.get("target", "")
            node = ADDR_TO_NODE.get(target_addr, target_addr)
            tasks[tid].append((ts, node, "migrate"))
        elif ev == "TASK_ACCEPT":
            tasks[tid].append((ts, rec["node"], "accept"))
        elif ev == "TASK_COMPLETE":
            tasks[tid].append((ts, rec["node"], "complete"))
    return tasks


def active_tasks_at(tasks: dict, ts: int) -> dict[str, int]:
    """Return {node_id: count} of in-flight tasks at time `ts`."""
    counts: dict[str, int] = defaultdict(int)
    for tid, events in tasks.items():
        latest_node = None
        latest_status = None
        for ets, node, status in events:
            if ets > ts:
                break
            latest_node = node
            latest_status = status
        if latest_node and latest_status in ("migrate", "accept"):
            counts[latest_node] += 1
    return counts


def build_cloth_surface(node_states: dict) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """Thin-plate spline interpolation: field passes exactly through control
    points. Returns (grid_x, grid_y, z_surface) arrays."""
    gx = np.linspace(-0.3, 2.3, CLOTH_RES)
    gy = np.linspace(-0.3, 2.3, CLOTH_RES)
    grid_x, grid_y = np.meshgrid(gx, gy)

    nodes_present = [n for n in node_states if n in NODE_GRID]
    if len(nodes_present) < 3:
        return grid_x, grid_y, np.zeros_like(grid_x)

    ctrl_pts = np.array([[NODE_GRID[n][0], NODE_GRID[n][1]] for n in nodes_present])
    ctrl_vals = np.array([node_states[n]["potential"] for n in nodes_present])

    rbf = RBFInterpolator(ctrl_pts, ctrl_vals, kernel="thin_plate_spline",
                          smoothing=0.0, neighbors=8)
    query = np.column_stack([grid_x.ravel(), grid_y.ravel()])
    z = rbf(query).reshape(grid_x.shape)
    z = np.clip(z, 0, POT_CAP)
    return grid_x, grid_y, z


def render_video(pot_slices, task_timeline, out_path):
    """Render the MP4 with one matplotlib figure and FuncAnimation. Each
    frame's field is computed on demand and streamed to disk by the ffmpeg
    writer — no frame buffers held in memory."""
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib.animation import FuncAnimation
    from matplotlib.cm import ScalarMappable
    from matplotlib.colors import Normalize

    os.makedirs(os.path.dirname(out_path) or ".", exist_ok=True)

    t0 = pot_slices[0][0]
    total = len(pot_slices)
    print(f"Rendering {total} frames via FuncAnimation...")

    fig, ax = plt.subplots(figsize=(8, 7), dpi=110)

    # Persistent colorbar tied to a fixed mappable; survives ax.cla() so the
    # figure layout does not shift between frames.
    sm = ScalarMappable(norm=Normalize(0, POT_CAP), cmap="coolwarm")
    fig.colorbar(sm, ax=ax, label="Potential V")

    def update(frame_idx: int):
        ts, states = pot_slices[frame_idx]
        elapsed = (ts - t0) / 1e6
        gx, gy, z = build_cloth_surface(states)
        active = active_tasks_at(task_timeline, ts)

        ax.cla()
        ax.set_xlim(-0.3, 2.3)
        ax.set_ylim(-0.3, 2.3)
        ax.set_aspect("equal")
        ax.set_xlabel("Grid X")
        ax.set_ylabel("Grid Y")

        ax.contourf(gx, gy, z, levels=20, cmap="coolwarm", vmin=0, vmax=POT_CAP)

        for n, (nx, ny) in NODE_GRID.items():
            if n not in states:
                continue
            nz = states[n]["potential"]
            load = states.get(n, {}).get("load", 0)
            cp_color = plt.cm.YlOrRd(min(load / 1.0, 1.0))
            ax.scatter(nx, ny, c=[cp_color], s=140, zorder=5,
                       edgecolors="black", linewidth=0.8)
            ax.text(nx, ny + 0.08, n.split("_")[1], fontsize=8, ha="center",
                    color="black", fontweight="bold")

        for node, count in active.items():
            if node not in NODE_GRID:
                continue
            nx, ny = NODE_GRID[node]
            ax.scatter(nx, ny, s=30 + 25 * min(count, 8), c="#FF1744",
                       zorder=10, edgecolors="darkred", linewidth=0.5,
                       alpha=0.85)

        ax.set_title(f"basin Potential Field  |  t={elapsed:.1f}s  |  "
                     f"frame {frame_idx + 1}/{total}", fontsize=10)

    anim = FuncAnimation(
        fig, update, frames=total, blit=False, repeat=False,
    )
    anim.save(out_path, writer="ffmpeg", fps=FPS)
    plt.close(fig)

    size_mb = os.path.getsize(out_path) / (1024 * 1024)
    print(f"MP4 saved to {out_path} ({total} frames, {size_mb:.1f} MB)")


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--out", default=VIDEO_PATH,
                   help="output MP4 path")
    p.add_argument("--log", default=LOG_PATH,
                   help="merged log file to visualize")
    args = p.parse_args()

    ensure_merged_log(args.log)

    print("Loading events...")
    records = load_events(args.log)
    print(f"  {len(records)} total records")

    print("Building potential timeline...")
    pot_slices = build_potential_timeline(records)
    print(f"  {len(pot_slices)} potential time slices")

    print("Building task timeline...")
    task_timeline = build_task_timeline(records)
    print(f"  {len(task_timeline)} unique tasks tracked")

    if len(pot_slices) < 2:
        print("Not enough data!", file=sys.stderr)
        sys.exit(1)

    print("Rendering video (2D contourf, FuncAnimation)...")
    render_video(pot_slices, task_timeline, args.out)


if __name__ == "__main__":
    main()
