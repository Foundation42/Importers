# Cluster→Model Mapping — Integration Guide

## Overview

The PVS baker now outputs cluster→model mapping for runtime culling. This bridges the gap between
baked cluster-level visibility (PVS transport graph) and the scene's model instances.

## Baker Changes (pvs_baker.zig)

### 1. Model Range Tracking During VPK Load

```zig
const ModelRange = struct {
    tri_start: u32,    // First triangle in flat array (pre-BIVH sort)
    tri_end: u32,      // One past last triangle
    name: []const u8,  // Model filename for debugging/matching
};

var model_ranges = std.ArrayList(ModelRange).init(allocator);
```

**When loading each vmdl_c entry:**
- Record `tri_start` = current triangle count
- Extract geometry (appends to flat triangle array)
- Record `tri_end` = new triangle count
- Store model name for runtime matching

### 2. Cluster→Model Mapping Computation

After clusters are built (BIVH-sorted triangle ranges):

```zig
// Build reverse mapping: original_tri_idx → model_id
const tri_to_model = try allocator.alloc(u32, tri_count);
for (model_ranges.items, 0..) |mr, model_id| {
    for (mr.tri_start..mr.tri_end) |ti| {
        tri_to_model[ti] = @intCast(model_id);
    }
}

// For each cluster (256 BIVH-sorted triangles), collect overlapping models
for (0..cluster_count) |ci| {
    const start_sorted = ci * cluster_size;
    const end_sorted = @min(start_sorted + cluster_size, tri_count);
    
    for (start_sorted..end_sorted) |sorted_idx| {
        const original_idx = world_bivh.triangle_indices[sorted_idx];
        const model_id = tri_to_model[original_idx];
        cluster_models[ci].insert(model_id);
    }
}
```

**Key insight:** BIVH reorders triangles for cache locality. We track the original→sorted
mapping via `bivh.triangle_indices[]`, then use the reverse tri_to_model map to find which
models contribute to each cluster.

### 3. Binary Output Format

**File:** `<map>_cluster_models.bin`

```
Magic:         "CMOD" (4 bytes)
num_clusters:  u32
num_models:    u32

For each cluster (0..num_clusters):
  cluster_id:  u32
  num_models:  u32
  model_ids:   u32[num_models]
```

**Also outputs:** `<map>_models.txt` — human-readable list of model_id → name mapping
for cross-referencing with runtime VPK load order.

## Runtime Integration (Forge/ac project)

### File Structure

```
pvs_runtime_loader.zig — standalone loader with three data structures:
  - PVSData:          cell → visible_clusters[] (from existing _pvs.bin)
  - ClusterModels:    cluster → model_ids[]     (from new _cluster_models.bin)
  - ProbeAssignment:  cluster → probe_id        (from existing _probe_assign.bin)
```

### Render Loop Workflow

```zig
// ── Initialization (map load) ────────────────────────────────────────

var pvs_renderer = try PVSRenderer.init(allocator, "de_dust2");
defer pvs_renderer.deinit();

// Load scene models in SAME ORDER as baker's VPK iteration
var scene_models = std.ArrayList(SceneModel).init(allocator);
// ... iterate VPK same way as baker, append models ...

// ── Per-Frame (render loop) ──────────────────────────────────────────

// 1. Update visibility based on camera position
pvs_renderer.updateVisibility(camera.position, cluster_bivh);

// 2. Render only visible models
for (scene_models.items, 0..) |model, model_id| {
    if (!pvs_renderer.isModelVisible(@intCast(model_id))) continue;
    
    // Model is visible — draw it
    renderer.drawModel(model);
    
    // Optional: Apply GI from assigned probe
    const cluster_id = model.cluster_id; // Precomputed during load
    if (pvs_renderer.probe_assignment.getProbeId(cluster_id)) |probe_id| {
        shader.setUniform("u_probe_sh", probe_sh_buffer[probe_id]);
    }
}
```

### Critical Requirements

**1. Deterministic Model Load Order**

The baker iterates VPK entries in whatever order the package returns them. Runtime MUST
use the same iteration order, or model_ids won't match.

**Solution:** If VPK iteration is non-deterministic:
- Sort models by name/path before processing (both baker and runtime)
- Or: Store model names in `_models.txt`, match by name at runtime

**2. Model→Cluster Assignment**

Each SceneModel needs to know its cluster_id for probe lookup. Two approaches:

**A. Precompute during model load** (recommended):
```zig
const SceneModel = struct {
    mesh: Mesh,
    cluster_id: u32,  // Computed via cluster_bivh.findLeaf(model.centroid)
    // ...
};
```

**B. Runtime lookup per model**:
```zig
// Inside render loop:
const cluster_id = cluster_bivh.findLeaf(model.bounds.center, null);
```

### Performance Notes

**Visibility update cost:**
- Camera cell lookup: ~0.1µs (BIVH findLeaf)
- PVS cluster fetch: ~1µs (array lookup, ~3K clusters visible on average)
- Model flag marking: ~5µs (iterate visible clusters × models/cluster, write bool array)
- **Total: <10µs per frame**

**Compared to alternatives:**
- Frustum culling: ~20-50µs (AABB tests for all models)
- Occlusion queries: ~100-500µs (GPU roundtrip)
- Combined (PVS + frustum): PVS prunes 90%+ models, frustum refines the remainder

**Memory:**
- PVS data: ~200KB (3K cells × ~60 visible clusters/cell × 4 bytes)
- Cluster→model: ~140KB (17K clusters × 2 models/cluster × 4 bytes)
- Probe assignment: ~70KB (17K clusters × 4 bytes)
- **Total: ~400KB for Dust II**

## Multi-Resolution Strategy (Optional)

If cluster granularity is too coarse (large models spanning many clusters → poor culling),
or too fine (many single-triangle models → overhead), use two-level PVS:

1. **Coarse PVS** (cluster_shift=10, 1024 tris/cell): Fast camera→visible_regions
2. **Fine PVS** (cluster_shift=8, 256 tris/cell): Precise model→cluster assignment

Baker runs twice at different shifts, runtime uses coarse for broad culling + fine for GI.

## Alternative: Model-Level PVS (Not Recommended)

Instead of cluster→model, bake model→visible_models[] directly:

**Pros:**
- Exact per-model visibility (no cluster granularity issues)
- Simpler runtime (just array lookup)

**Cons:**
- Combinatorial explosion: 518 models × 518 models = 268K pairs to test
- Baker runtime: ~10× slower (must test all pairs via transport graph)
- Output size: ~2MB vs 140KB

**Verdict:** Only viable for small scenes (<100 models). For CS2-scale maps, cluster-level
wins on both bake time and runtime performance.

## Testing Checklist

- [ ] Baker compiles with model tracking added
- [ ] `_cluster_models.bin` and `_models.txt` are generated
- [ ] Runtime loader parses binary format correctly
- [ ] Model load order matches baker (check model_id alignment via _models.txt)
- [ ] PVS culling reduces draw calls (compare with/without)
- [ ] No visual artifacts (light leaks, missing geometry)
- [ ] Performance: <10µs visibility update, 90%+ models culled

## Next Steps

1. **Wire cluster BIVH into Forge** — you already have world BIVH for ray tracing,
   cluster BIVH is the same structure, just different triangle grouping

2. **Model load order verification** — log first 10 model names from both baker and runtime,
   ensure they match

3. **Benchmark visibility update** — measure camera cell lookup + PVS fetch + model marking

4. **Combine with frustum culling** — PVS first (coarse), frustum second (fine), then draw

5. **GI probe integration** — cluster→probe lookup already baked, just need to load probe
   SH coefficients and bind to shader uniforms

6. **Dynamic objects** — static PVS for world geometry, runtime frustum/distance for entities

## File Locations

After running the baker on `de_dust2.vpk`:

```
de_dust2_pvs.bin              — Cell visibility sets (existing)
de_dust2_probe_assign.bin     — Cluster→probe mapping (existing)
de_dust2_cluster_models.bin   — Cluster→model mapping (NEW)
de_dust2_models.txt           — Model ID reference (NEW)
de_dust2_probes.txt           — Probe positions (existing)
de_dust2_transport.ppm        — Transport graph viz (existing)
de_dust2_islands.ppm          — Island detection viz (existing)
de_dust2_lighting.ppm         — SH propagation viz (existing)
```

Runtime needs:
- `_pvs.bin` (PVS culling)
- `_cluster_models.bin` (model mapping)
- `_probe_assign.bin` (GI probe lookup)
- Cluster BIVH (cell lookup — bake separately or inline at load)
