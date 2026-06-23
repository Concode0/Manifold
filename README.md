# basin

<video controls src="viz/potential_field_oscillation.mp4"></video>

An investigation into whether autonomous load balancing is possible in a
distributed environment, using wedges derived from the algebraic properties
of Clifford algebra as the routing signal.

The animation above is the **oscillation** regime
(`MigrationHysteresis = 0.15`). The **convergence** regime
(`MigrationHysteresis = 0.5`) is shown at
<video controls src="viz/potential_field_convergence.mp4"></video>.

This is not an architecture for production, and not a rigorous academic
result. It is a sandbox: deploy a few nodes, let them generate and forward
work, and watch whether coherent global allocation patterns emerge from
purely local rules. The framing is phenomenological.

## Motivation

Can nodes that know nothing about global topology or aggregate capacity
still coordinate resource allocation through local interaction alone? Each
node sees only its neighbours' last-gossiped state, picks at most two of
them at random, and forwards work if one looks less loaded. No central
scheduler, no all-to-all communication, no global optimisation.

The bet being tested: if the routing metric captures **shape mismatch**
between a task's requirement vector and a node's available capacity — not
just scalar load — then heterogeneous nodes should naturally sort tasks
by fit, and the system should drift toward an allocation pattern that
respects each node's strengths.

## Resource model

Each node's compute, memory, and network capacities are encoded as a
grade-1 multivector in Cl(3,0) — a vector in the $e_1, e_2, e_3$ basis.
A task carries a requirement multivector of the same grade. The shape
mismatch between a candidate's available capacity $a$ and a task's
requirement $r$ is measured by the normalised wedge magnitude:

$$
\phi = \frac{\|a \wedge r\|}{\|a\| \, \|r\|} \in [0, 1]
$$

$\phi = 0$ means the vectors are parallel (same shape), $\phi = 1$ means
they are orthogonal (totally mismatched). This is scale-free: a node with
capacity 100 and a task requiring 10 has the same $\phi$ as a node with
capacity 10 and a task requiring 1, provided the ratios match.

Routing potential combines $\phi$ with load, queue pressure, and trust:

$$
V = \frac{m + \phi}{e^{-\alpha L - \beta Q} \cdot \tau}
$$

Lower $V$ is more attractive. The best of 2 randomly sampled neighbours
is chosen (Power-of-Two-Choices, Po2C) — not the global optimum. This
deliberate limitation forces the system to rely on emergent coordination
rather than exhaustive search.

## Interaction primitives

| Primitive | Period | Description |
|---|---|---|
| Heartbeat | 200ms | Presence probe; drives trust recovery (+0.05 per receipt, capped at 1.0) |
| State Gossip | 500ms | Broadcast of capacity multivector, load, queue pressure to all neighbours |
| Task Migrate | on demand | Forwarding of unexecuted work to a neighbour with lower $V$ |

Trust starts at 1.0 on neighbour discovery, decays by $-0.2$ on any wire
failure, and recovers by $+0.05$ per heartbeat. The asymmetry between
harsh penalty and gradual rehabilitation produces observable oscillations
in peer relationships under sustained packet loss. In a stable network
(such as a Docker bridge) trust stays pinned at 1.0 and the trust
dynamics are inert if want to study them, introduce lossy links.

## Running locally

Requires Go 1.21+. Build produces a single binary with no external
dependencies.

```bash
go build -o basin .
./basin -id node_01 -addr 127.0.0.1:8001
```

Launch a second node in another terminal, joining the first:

```bash
./basin -id node_02 -addr 127.0.0.1:8002 -join 127.0.0.1:8001 -task
```

### Flags

| Flag | Default | Description |
|---|---|---|
| `-id` | `node_01` | Node identifier |
| `-addr` | `127.0.0.1:8001` | Advertised address (shared with peers) |
| `-bind` | (same as `-addr`) | TCP bind target. Use `0.0.0.0:PORT` in Docker |
| `-join` | (empty) | Comma-separated seed addresses to bootstrap from |
| `-c` `-m` `-n` | `10 10 5` | Compute / memory / network capacity ($e_1, e_2, e_3$) |
| `-latency` | `300ms` | Simulated task execution time |
| `-task` | `false` | Enable continuous task generation on this node |
| `-task-comp` `-task-mem` `-task-net` | `4 0.8 2` | Task requirement vector |
| `-task-mass` | `1.0` | Task mass (numerator in $V$) |
| `-task-interval` | `1500ms` | Interval between spawned tasks |
| `-hysteresis` | `0.15` | Min relative $V$ improvement to justify a hop. Below $1-e^{-\beta}\approx 0.39$ the system oscillates by design; above it, it converges. |

## Docker cluster

```bash
docker compose up -d          # launch 8 heterogeneous nodes (5 generate tasks)
docker compose logs -f        # stream structured NDJSON logs
docker compose down           # stop
```

The compose file defaults to the **oscillation** regime
(`MigrationHysteresis = 0.15`). To run the **convergence** regime, set the
`HYSTERESIS` env var above the queue-pressure threshold ($\approx 0.39$):

```bash
HYSTERESIS=0.5 docker compose up -d   # convergence regime
```

The compose file defines 8 nodes with deliberately mismatched capacity
profiles (e.g. `node_02` is memory-heavy, `node_06` is compute-heavy,
`node_07` is network-heavy). Five of them generate tasks at different
rates and with different requirement shapes.

Each node emits NDJSON records on stdout — one JSON object per line with
UTC microsecond timestamps, event type, node ID, per-node sequence
number, and event-specific fields.

## Logs & visualization

### Collecting and merging logs

```bash
# After a cluster run, dump each node's stdout to a per-node log file.
for n in node_0{1..8}; do docker logs $n > logs/$n.log 2>&1; done

# Merge into a single time-sorted file with verification.
uv run tools/merge_logs.py
```

### Visualization

```bash
uv run tools/visualize_field.py            # -> viz/potential_field.mp4
```

The output is an **MP4 video** rendered by a matplotlib `FuncAnimation`
pipeline. Each node is a control point on a fixed 3×3 XY grid; the scalar
potential $V$ is reconstructed by a thin-plate spline and drawn as a filled
contour heatmap — the conventional representation of a scalar potential
field. Active in-flight tasks appear as red dots on their hosting node,
size-scaled by in-flight count.

To render a specific case, point the script at that case's merged log and
output path:

```bash
uv run tools/visualize_field.py \
    --log logs/oscillation/cluster_merged.jsonl \
    --out viz/potential_field_oscillation.mp4

uv run tools/visualize_field.py \
    --log logs/convergence/cluster_merged.jsonl \
    --out viz/potential_field_convergence.mp4
```

### Principle

Each node is a **control point** on a fixed 3×3 XY grid; its scalar
potential $V$ is the field value. A thin-plate spline interpolates the
field through all control points, producing realistic
draping/sagging between them. As tasks arrive and consume resources, $V$
rises and the field pushes upward; as tasks complete and resources are
restored, $V$ falls and the field sinks. Active in-flight tasks appear as
red dots on their hosting node, size-scaled by in-flight count.

## Observed behaviour

Two regimes are contrasted below. Both are single Docker cluster runs (8
nodes, 5 generating tasks) on a lossless bridge.
The regime is selected by a single knob, `MigrationHysteresis` (the
`-hysteresis` flag / `HYSTERESIS` compose var), relative to the
queue-pressure contribution to $V$ at queue $= 1$, which is
$1 - e^{-\beta} \approx 0.39$. Below that threshold the system oscillates
by design; above it, it converges. Each case is presented the same way:
volume, routing, timing, allocation.

The queue-pressure asymmetry that drives the regime change: the holder of
a task always sees its own queue bump as $+1$ versus a peer's $0$, so its
$V$ rises by a relative $\approx 0.39$. If the hysteresis gate is below
that, the holder always migrates; the receiver then sees the mirror image
and migrates back, until `MaxHops` force-accepts. If the gate is above it,
the asymmetry can never clear the bar and the task is accepted at origin.

---

### Case A — Oscillation (`hysteresis = 0.15`, below $0.39$)

<video controls src="viz/potential_field_oscillation.mp4"></video>

#### Volume

- **3,632** tasks tracked, **3,629** accepted, **3,628** completed
- **26,289** migration events across the mesh
- **12** LINK_ADD events (peer discovery), **0** TRUST_UPDATE events
 ( docker is stable enough )

#### Routing — dominated by the `MaxHops` ceiling

| Hops to accept | Tasks | Fraction |
|---|---|---|
| 0 (accepted at origin) | 178 | 4.9% |
| 1–7 | 293 | 8.1% |
| 8 (hit `MaxHops` ceiling, force-accepted) | 3,158 | 87.0% |

The vast majority of tasks bounce between two or three peers until the
`MaxHops` ceiling force-accepts them — exactly the behaviour predicted
when the hysteresis gate sits below the queue-pressure asymmetry.

The most frequent back-and-forth pairs:

| Pair | Migrations |
|---|---|
| `node_05 ↔ node_08` | 3,752 |
| `node_01 ↔ node_05` | 3,416 |
| `node_01 ↔ node_03` | 2,610 |
| `node_05 ↔ node_06` | 2,498 |
| `node_07 ↔ node_08` | 2,321 |

These are pairs with similar capacity profiles — the wedge $\phi$ between
them is small, so the potential difference is dominated by queue pressure,
which oscillates.

#### Timing

- **Flight time** (first-seen → accept): median 82ms, mean 137ms, max 1,054ms
- The long tail is tasks that exhausted all 8 hops before
  force-acceptance.

#### Allocation

Self-acceptance (task accepted at its origin node) was **4.9%** (178 of
3,629). The system almost always migrates at least once, even when the
origin could have served the task.

Final acceptor distribution:

| Node | Accepts | Capacity profile ($c/m/n$) |
|---|---|---|
| `node_01` | 738 | 12 / 8 / 6 |
| `node_05` | 615 | 10 / 10 / 5 |
| `node_03` | 510 | 8 / 6 / 10 |
| `node_08` | 404 | 9 / 11 / 3 |
| `node_06` | 393 | 14 / 4 / 7 |
| `node_07` | 373 | 5 / 8 / 12 |
| `node_04` | 324 | 4 / 12 / 8 |
| `node_02` | 272 | 6 / 14 / 4 |

Because 87% of acceptances were force-accepted at the `MaxHops` ceiling,
the distribution is more a function of topology (who is the last hop
before the ceiling) than of genuine shape-based selection.

---

### Case B — Convergence (`hysteresis = 0.5`, above $0.39$)

<video controls src="viz/potential_field_convergence.mp4"></video>

#### Volume

- **1,024** tasks tracked, **1,024** accepted, **1,021** completed
- **63** migration events across the mesh (down from 26,289)
- **13** LINK_ADD events, **0** TRUST_UPDATE events

#### Routing — oscillation suppressed

| Hops to accept | Tasks | Fraction |
|---|---|---|
| 0 (accepted at origin) | 961 | 93.8% |
| 1–7 | 63 | 6.2% |
| 8 (hit `MaxHops` ceiling, force-accepted) | 0 | 0.0% |

Raising the gate above $0.39$ collapses the oscillation: **zero** tasks
reach the `MaxHops` ceiling. The queue-pressure asymmetry can no longer
clear the bar, so the holder accepts locally instead of migrating.

The only migration pair was `node_03 ↔ node_05` (63 edges) — the pair
with the smallest $\phi$ and the closest capacity profiles, where
occasional load/queue differences are still large enough to clear a $0.5$
relative improvement.

#### Timing

- **Flight time** (first-seen → accept): median 0ms, mean 5ms, max 253ms
- The median is zero because tasks are accepted at their origin on the
  same tick they are spawned.

#### Allocation

Self-acceptance was **93.8%** (961 of 1,024). Final acceptor distribution:

| Node | Accepts | Capacity profile ($c/m/n$) |
|---|---|---|
| `node_03` | 323 | 8 / 6 / 10 |
| `node_01` | 217 | 12 / 8 / 6 |
| `node_08` | 200 | 9 / 11 / 3 |
| `node_07` | 162 | 5 / 8 / 12 |
| `node_05` | 122 | 10 / 10 / 5 |
| `node_02` | 0 | 6 / 14 / 4 |
| `node_04` | 0 | 4 / 12 / 8 |
| `node_06` | 0 | 14 / 4 / 7 |

Only the five task-generating nodes accepted work; the three idle nodes
received nothing. This is the over-damping signature: at $0.5$ the gate
is high enough that tasks almost never leave their origin, so the system
converges — but to a sticky, origin-bound allocation rather than a
shape-aware one. `node_03` accepts the most because it both generates
tasks (the fastest rate, 500ms) and is the sole receiver of the
`node_05 → node_03` migration edge.

### Genuine shape-based routing

Neither case exhibits it. At $0.15$ the queue-pressure term dominates 
$\phi$; at $0.5$ the gate is too high for $\phi$ differences to clear it.
It is expected to appear slightly above $0.39$, but since the purpose of
this sandbox is to observe the phenomenon rather than to locate that point,
it has been omitted.

## Tuning knobs

All in `basin/scheduler.go`. `MigrationHysteresis` is a package variable
set at startup by the `-hysteresis` flag (or the `HYSTERESIS` compose
var); the rest are compile-time constants.

| Knob | Default | Effect |
|---|---|---|
| `Alpha` | 1.0 | Load exponent in the potential denominator. Higher → load dominates routing. |
| `Beta` | 0.5 | Queue-pressure exponent. Higher → queue pressure dominates. |
| `MigrationHysteresis` (`-hysteresis`) | 0.15 | Minimum relative $V$ improvement to justify a hop. Below $1 - e^{-\beta} \approx 0.39$ the system oscillates by design; above it, it converges. |
| `MaxHops` | 8 | Routing diameter ceiling. Force-accepts tasks that would otherwise ping-pong forever. |

## Python environment

```bash
uv sync
uv run tools/visualize_field.py
```