# General Transport System — Development Journal

## Overview

A unified visibility and transport system built over two sessions (2025-04-09 / 2025-04-10).
Starting point: Christian's 16-year-old C# PVS system from Foundation42 and a conversation
with Gemini about GI architecture (Baker.md). End result: a complete 4-phase GI pipeline
running on CS2 Dust II in ~2 minutes.

The system is **general-purpose** — the transport graph captures spatial connectivity
probabilities between cells. Light is the first application, but the same graph can carry
sound, AI awareness, network relevancy, particle propagation, or anything else that flows
through a scene.

## Architecture

```
VPK Map File
    │
    ▼
┌──────────────┐     ┌───────────────┐
│ Geometry Load │────▶│ World BIVH    │  (ray tracing — 4.5M tris, 2µs/ray)
│ (importers)   │     │ (bivh.zig)    │
└──────────────┘     └───────┬───────┘
                              │
                     ┌────────▼────────┐
                     │ Cluster BIVH     │  (view cells — 17K clusters, 3.5K cells)
                     │ (spatial groups) │
                     └────────┬────────┘
                              │
                     ┌────────▼────────┐
                     │ BFS Walker       │  (connectivity — 582K edges, 136s)
                     │ Solve            │
                     └────────┬────────┘
                              │
                     ┌────────▼────────┐
                     │ Transport Graph  │  (cell-to-cell hits/casts + graph distance)
                     │                  │
                     └──┬─────┬─────┬──┘
                        │     │     │
              ┌─────────┘     │     └─────────┐
              ▼               ▼               ▼
     ┌──────────────┐ ┌──────────────┐ ┌──────────────┐
     │ Island       │ │ Gradient     │ │ Visibility-  │
     │ Detection    │ │ Probes       │ │ Gated Assign │
     │ (clustering) │ │ (transitions)│ │ (no leaks)   │
     └──────┬───────┘ └──────┬───────┘ └──────┬───────┘
            │                │                │
            └────────┬───────┘                │
                     ▼                        │
            ┌──────────────┐                  │
            │ Probe        │◀─────────────────┘
            │ Placement    │
            └──────┬───────┘
                   │
            ┌──────▼───────┐
            │ SH Light     │  (4 bounces, energy-conserving)
            │ Propagation  │
            └──────┬───────┘
                   │
                   ▼
            Output files + visualizations
```

## Files

All in `~/dev/importers/src/`:

| File | Lines | Purpose |
|------|-------|---------|
| `bivh.zig` | ~960 | Bounding Interval Volume Hierarchy — CPU ray tracing. Self-contained (no raylib). Ported from Foundation42 C#/XNA via ac project. |
| `pvs.zig` | ~1200 | Core data structures and algorithms: Bitmap1D, VisibilitySet, TransportGraph, WalkerSolver, island detection, probe placement, gradient probes, visibility-gated assignment, SH coefficients, light propagation. |
| `pvs_baker.zig` | ~1400 | Standalone tool: loads Source 2 map from VPK, runs full pipeline, outputs binary data + PPM visualizations. No raylib dependency. |
| `build.zig` | (modified) | Added pvs-baker executable target with bivh + pvs modules, all ReleaseFast. |

Also in `~/dev/Blade3DPort/src/`:
- `pvs.zig` — Original copy with Bitmap1D, VisibilitySet (first session). The importers copy diverged significantly with walker solver etc.

## Key Data Structures

### Bitmap1D (`pvs.zig`)
- 64-bit packed bitfield, `Atomic(u64)` words for lock-free thread-safe `set()`
- Hardware `@popCount` for counting, CTZ-based extraction for `getSetBits()`
- Merge operation (atomic OR) returns count of newly set bits

### TransportGraph (`pvs.zig`)
- Upper-triangle flat array of `(casts: Atomic(u32), hits: Atomic(u32))` per cell pair
- `P(visible) = (hits + 1) / (casts + 2)` — Laplace-smoothed Bayesian probability
- `isDead(min_casts)` — confirmed non-visible (many casts, zero hits)
- `seedFromCoarse()` — maps fine cells to coarse cells via spatial containment, blacklists dead pairs
- Lock-free: all updates via atomic fetch-add

### BIVH (`bivh.zig`)
- BIH/BVH hybrid with 32-byte packed nodes
- Eisemann slope-classified TraceRay (26 octants, f64 precision)
- Moller-Trumbore triangle intersection (no backface cull)
- `findLeaf()` with coherent hint acceleration
- Two instances at runtime: world BIVH (ray tracing), cluster BIVH (cell lookup)

### SHCoeffs (`pvs.zig`)
- Order-1 spherical harmonics: L0 (ambient) + L1 (directional) = 4 coefficients per RGB = 12 floats
- `fromDirectional()`, `fromAmbient()`, `evaluate(dir)`, `intensity()`
- Energy-conserving propagation: normalized by neighbor weight sum per bounce

## Algorithms

### BFS Walker Solver (v2, current)
The connectivity solver. For each cell:
1. BFS outward through precomputed spatial neighbors (AABB overlap + gap)
2. At each frontier cell: shoot 8 rays between random triangle pairs
3. **One hit = confirmed connected** — record graph distance, expand BFS frontier
4. **All miss = blocked** — don't expand (walls prune entire subtrees)
5. Already-confirmed pairs (from other walkers) skip ray testing, still expand

**Performance**: 3,485 cells, 582K connections, 59.7M rays, 136 seconds on Dust II.
Deterministic — no convergence waiting.

### Stochastic Importance-Sampled Solver (v1, preserved in git history)
The original solver with multi-resolution epochs:
1. Three epochs at decreasing cluster_shift (12→10→8)
2. Each epoch's transport graph seeds the next via `seedFromCoarse()`
3. Dead edges blacklisted: epoch 3 skipped 88% of edges
4. Importance sampling: explore/exploit target selection with decaying exploration rate
5. Convergence: 120 consecutive zero-addition passes

**Performance**: 3,485 cells, 583K connections, 100M+ rays, 210 seconds across 3 epochs.

### Probe Placement
Two complementary sources:
1. **Island interiors**: cluster cells via connected components on thresholded transport graph.
   One probe at the highest-connectivity cell per island.
2. **Gradient probes**: compute per-cell "openness" (total transport flow), find local maxima of
   the openness gradient between spatial neighbors. These are doorways/windows/transitions.

### Visibility-Gated Probe Assignment
Each cluster assigned to nearest probe that is PVS-visible from that cluster's cell:
1. Compute cluster centroids → find containing cell via cluster BIVH `findLeaf()`
2. For each cluster, find all probes whose cells are transport-connected (hits > 0)
3. Among visible probes, assign to nearest
4. Prevents light leaks: clusters behind walls never sample probes on the other side

**Result**: 17,651 clusters, 100% assigned via gating, zero fallbacks.

### SH Light Propagation
CPU simulation proving the full pipeline:
1. Inject sun (directional SH) + sky (ambient SH) at outdoor probes (median-Y heuristic)
2. 4 bounces through transport graph edges, falloff 0.4 per bounce
3. Energy conservation: incoming SH normalized by sum of edge probabilities
4. Each cluster reads assigned probe's SH → final lighting intensity
5. Adaptive exposure (90th percentile Reinhard) for visualization

## Outputs

The baker produces:
- `de_dust2_pvs.bin` — binary PVS data (cells + visible cluster lists)
- `de_dust2_probe_assign.bin` — cluster→probe_id mapping
- `de_dust2_probes.txt` — probe positions + types (human-readable)
- `de_dust2_transport.ppm` — transport graph heatmap (Reinhard tone-mapped)
- `de_dust2_islands.ppm` — cells colored by island (golden ratio hue spread)
- `de_dust2_probe_assign.ppm` — clusters colored by assigned probe
- `de_dust2_lighting.ppm` — SH propagation result (warm sun / cool shadow)

## Build & Run

```sh
cd ~/dev/importers
zig build pvs-baker
./zig-out/bin/pvs-baker ~/dev/ac/maps/de_dust2.vpk
```

Note: do NOT pass the content VPK (pak01_dir.vpk) — it loads all CS2 prop models
(124K entries, 28.6M triangles) instead of just the map geometry (518 models, 4.5M tris).

## Key Parameters (in pvs_baker.zig)

| Parameter | Current | Effect |
|-----------|---------|--------|
| `cluster_shift` | 8 | Cluster size = 256 tris. Lower = finer, more cells, slower |
| `rays_per_pair` | 8 | Rays shot per BFS candidate pair. More = fewer false negatives |
| `neighbor_gap` | 2.0 | Max AABB gap for spatial adjacency (meters after S2 scaling) |
| `max_depth` | 50 | Max BFS hops from source cell |
| `num_bounces` | 4 | SH propagation bounces |
| `bounce_falloff` | 0.4 | Energy per bounce (0 = no transfer, 1 = full) |

## Evolution / Design Decisions

1. **Started with lock-free Bitmap1D** — atomic OR instead of C#'s lock(visibleSet), no contention
2. **Random pair sampling failed at scale** — 28.6M triangles, random pairs almost never connect
3. **Clustering** — group BIVH-sorted triangles into spatial clusters, track visibility per-cluster
4. **Importance sampling** — transport graph learns connectivity, focuses rays on viable pairs
5. **Multi-resolution epochs** — coarse→fine, dead-edge blacklisting (88% pruned in epoch 3)
6. **BFS Walker** — Christian's insight: systematic expansion, one hit = done, walls block subtrees.
   40% faster than stochastic, deterministic, graph distance free
7. **Progressive pruning** (planned) — also skip confirmed-connected pairs (inverse of dead-edge)

## Next Steps

- **Wire into Forge renderer** (ac project): PVS culling + probe-based GI at runtime
- **Progressive pruning**: skip both confirmed-connected AND confirmed-dead pairs
- **Compute shader port**: SH propagation on GPU for real-time dynamic GI
- **Sound transport**: same graph, audio impulse responses instead of SH
- **Network relevancy**: transport-based PVS for multiplayer entity updates
