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

## Session 3: Runtime Integration (2025-04-09 → 2026-04-09)

### Forge Renderer Wired Up
Full runtime pipeline from baked data to draw calls:

1. **Baker outputs** `_pvs_runtime.bin` (PVR2 format): cell centroids + per-cell model bitsets + probe SH
2. **Runtime** (`source2_pvs.zig`): loads PVR2, nearest-centroid cell lookup, per-model visibility flags
3. **Draw loop** (`main.zig`): Source 2 PVS branch — camera→cell→model bitset→frustum cull→draw
4. **HUD**: S2 PVS stats (drawn/culled/cell), `pvs_freeze` command for debugging
5. **Model name matching**: baker outputs `_models.txt`, runtime matches by VPK entry name

### Key Bugs Fixed
- **Cluster BIVH permutation**: the cluster BIVH reorders clusters during build, but cell_ranges
  treated sorted positions as original cluster IDs. Fixed by adding `perm[]` tracking to
  `TriangleMeshSet` (opt-in via `fromArraysWithPerm()`). Both world BIVH and cluster BIVH
  now track their permutations.
- **Cell lookup**: AABB containment failed because BIH cells overlap. Switched to nearest-centroid.
- **PVS file paths**: `std.fs.path.stem()` strips directory — fixed to strip only `.vpk` extension.

### Architecture Simplification
- Removed intermediate cluster→model mapping. Cells now directly know which models they contain
  (via world BIVH perm → original triangle → model range lookup).
- Per-cell visible model bitsets precomputed at bake time: expand through transport graph,
  OR model bitsets from all connected cells. Runtime is a single bitset lookup.
- Viz code extracted to `pvs_viz.zig` (~500 lines).

### Two Graphs Insight
The omnidirectional transport graph is correct for **light transport** (photons bounce from
any surface in any direction) but wrong for **player visibility** (eyes at player height,
forward-facing ~100° cone). The current system over-estimates visibility because rooftop
cells connect to distant buildings via sky sight lines that a ground-level player would never see.

**Solution (next session)**: camera-based ray strategy for PVS, inspired by Christian's
original C# PVS from Foundation42:
- Rays from camera positions (player height), not random surface points
- Forward-facing cone constraint (~50° half-angle)
- Target only unseen geometry (skip already-confirmed)
- Adaptive refinement: 6 child rays on hit (triangle verts + edge midpoints)
- Multi-pass convergence

Keep the current omnidirectional graph for GI probe transport — it's correct for light.

### Files Changed/Added

| File | Change |
|------|--------|
| `importers/src/bivh.zig` | Added `perm`, `fromArraysWithPerm()`, `deinitPerm()` to TriangleMeshSet |
| `importers/src/pvs.zig` | Removed backward prune (skip-already-confirmed) from walker |
| `importers/src/pvs_baker.zig` | Model tracking, cluster BIVH perm, per-cell model bitsets, PVR2 output |
| `importers/src/pvs_viz.zig` | **NEW** — extracted visualization code (~500 lines) |
| `importers/build.zig` | Added pvs_viz module |
| `ac/src/source2_pvs.zig` | **NEW** — runtime PVS loader (PVR2 format, nearest-centroid lookup) |
| `ac/src/source2_import.zig` | `tryLoadPVS()`, model name recording in both load paths |
| `ac/src/gltf_import.zig` | Added `s2_pvs` field to ImportedScene |
| `ac/src/main.zig` | S2 PVS draw loop branch, freeze state, HUD overlay |
| `ac/src/perf.zig` | S2 PVS counters |
| `ac/src/commands.zig` | `pvs_freeze` toggles both Q3 and S2 |

### Current Numbers (Dust II, no backward prune)
- 518 models, 3485 cells, 17651 clusters, 3567 probes
- 871K transport edges, 72M rays, 185s solve time
- Visible models/cell: min=22, max=457, avg=292 (56% — too high, needs camera-based rays)
- Runtime file: 482KB (`_pvs_runtime.bin`)

## Session 4: Neural PVS (2026-04-09)

### The Idea

Christian proposed replacing the cell-based bitset PVS with a neural learned visibility
model — a small MLP that predicts which models are visible from any camera state. The key
insight: instead of engineering the perfect ray heuristic, *learn* the visibility function
directly from ray-traced ground truth. "Like a neural, spatially aware bloom filter."

### Evolution (4 iterations in one session)

**v1 — Position-only (3 inputs), online SGD**: Collapsed immediately. Loss diverged,
network died from ReLU death + online SGD noise with 518 outputs. The class imbalance
(~42/518 models visible per sample) overwhelmed the gradient signal.

**v2 — Direction-aware (5 inputs: x,y,z,sin_yaw,cos_yaw)**: Christian's suggestion to add
yaw as sin/cos encoding (avoids 0/360 wrap discontinuity). Cone sampling (~100 FOV) instead
of omnidirectional rays. Loss decreased initially but oscillated — online SGD still too noisy
with 518 outputs.

**v3 — Mini-batch Adam (batch=32)**: The fix. Accumulate gradients over 32 samples before
applying Adam update. Smooth monotonic convergence: loss 214→91, FN 16.6%→5.1%, FP 11.2%→7.2%.
89% of models culled. First working neural PVS — 60 FPS in debug build.

**v4 — Frustum-integrated (9 inputs: +pitch, vfov, aspect)**: Christian's next insight: if
the network knows the frustum shape, it can learn BOTH occlusion AND frustum culling. No more
per-model AABB loop. Added spatial + distance weighted loss (Christian's idea: center/near
geometry penalized more for false negatives than distant/peripheral). Result: O(1) combined
PVS + frustum visibility. 0 frustum culled in HUD — the MLP IS the draw list.

### Architecture

```
Input (9 floats):
  x, y, z          — position (normalized to [0,1] in world AABB)
  sin_yaw, cos_yaw  — horizontal look direction
  sin_pitch, cos_pitch — vertical look direction
  vfov_norm         — vertical field of view (normalized)
  aspect_norm       — aspect ratio (normalized)

MLP:
  Layer 1: 9 → 256 (LeakyReLU)
  Layer 2: 256 → 256 (LeakyReLU)
  Layer 3: 256 → 518 (sigmoid)  — one output per model

Training:
  - 20K samples, random (position, yaw, pitch, vfov, aspect)
  - Ray bundles within frustum pyramid (not cone)
  - Adaptive refinement: 6 child rays at hit triangle verts + edge midpoints
  - Mini-batch Adam (batch=32, lr=0.001)
  - Class-balanced loss (auto-weighted from label statistics)
  - Spatial loss: FN penalty scaled by angular distance from center + distance from camera
  - 100 epochs, ~12 minutes total bake

Output:
  - NPVS v3 binary: 788KB (201K parameters)
  - Per-model visibility probability [0,1]
  - Runtime: single forward pass when camera moves/turns
```

### Key Design Decisions

1. **Sin/cos encoding for angles** — avoids discontinuity at 0/360. The network sees
   smooth inputs where similar angles produce similar encodings.

2. **Frustum as input, not assumption** — vfov and aspect are network inputs, not baked
   constants. Change FOV (zoom scope, ultrawide) at runtime and culling adapts.

3. **Spatial loss weighting** — penalize false negatives more for center-of-view and nearby
   models. Missing geometry dead center at 2m is jarring. Missing a distant building at the
   FOV edge is invisible. The network spends its capacity where it matters.

4. **Mini-batch not online SGD** — with 518 outputs, each sample's gradient is dominated by
   the ~495 negative (invisible) models. Averaging over 32 samples smooths the gradient
   direction. This was the critical fix for convergence.

5. **LeakyReLU not ReLU** — prevents dead neurons. With large gradients early in training,
   standard ReLU neurons can go permanently negative and never recover.

6. **Bloom filter bias** — false positives (drawing extra models) are safe. False negatives
   (missing visible models) cause holes. The loss asymmetry ensures the network errs toward
   over-drawing rather than under-drawing.

### Training Convergence (Dust II, v4)

```
Epoch    0: loss=230.84, FN=9.12%, FP=14.9%
Epoch   10: loss=142.13, FN=5.50%, FP=11.8%
Epoch   20: loss=131.96, FN=5.25%, FP=10.5%
Epoch   30: loss=126.51, FN=4.52%, FP=10.3%
Epoch   50: loss=120.11, FN=4.21%, FP=9.7%
Epoch   70: loss=116.13, FN=3.57%, FP=9.5%
Epoch   99: loss=112.16, FN=3.58%, FP=8.9%
```

### Runtime Performance

- **O(1) visibility**: single MLP forward pass (~50µs), no AABB iteration
- **0 frustum culled**: MLP handles frustum, not the renderer
- **12-38/518 models drawn** depending on view (vs 292/518 with cell-based)
- **60 FPS debug build** on Dust II
- **Updates only on camera movement** (>0.5 units) or turn (>~10 degrees)
- **788KB** weight file (vs 482KB for cell-based bitsets, but does far more)

### Files

| File | Purpose |
|------|---------|
| `importers/src/pvs_neural.zig` | MLP architecture, training, frustum sampling, spatial loss, NPVS format |
| `importers/src/pvs_baker.zig` | Neural training phase, model centroid computation |
| `importers/build.zig` | pvs_neural module |
| `ac/src/source2_pvs.zig` | NeuralPVS runtime inference (9-input, v3 format) |
| `ac/src/main.zig` | O(1) draw loop, camera state extraction |
| `ac/src/source2_import.zig` | NPVS file loading |
| `ac/src/gltf_import.zig` | s2_neural_pvs field |

### What Was Removed

The cell-based bitset PVS system (PVSRenderer, PVR2 format, nearest-centroid cell lookup,
per-cell model bitsets, _models.txt name matching) was fully removed from the renderer.
The transport graph and probes remain for GI.

### Future Directions

- **Expose probabilities to renderer** — raw sigmoid outputs for LOD selection, shadow map
  priority, streaming decisions, temporal smoothing (fade-in instead of pop)
- **CSM shadow network** — separate smaller MLP per cascade, inputs are light direction +
  cascade bounds, outputs are shadow-casting model set
- **More training data** — 50K-100K samples for tighter frustum boundary learning
- **Larger hidden layers** — 384 or third hidden layer for sharper frustum edges
- **Temporal coherence** — EMA smoothing of outputs across frames to eliminate popping
- **Sound transport** — same omnidirectional graph, audio impulse responses instead of SH
- **Baked GI probes** — load probe SH into ProbeManager SSBO/shader pipeline

## Next Steps

- **Probability-based rendering**: expose raw MLP outputs for LOD, priority, streaming
- **CSM shadow cascades**: separate network per cascade
- **Temporal smoothing**: EMA across frames to eliminate popping artifacts
- **Baked GI probes into ProbeManager**: load `_probes_sh.bin` into existing SSBO/shader pipeline
- **Compute shader port**: SH propagation on GPU for real-time dynamic GI
