// PVS — Potentially Visible Set solver
//
// Full spatial PVS solve using stochastic ray sampling through a BIVH.
// No camera paths — shoots rays between all triangle pairs until convergence.
//
// Ported from Foundation42.PVS (C#/XNA) with significant changes:
//   - Full solve (no camera path bias)
//   - Per-thread arenas instead of GPA (avoids mutex contention)
//   - Atomic bit-set operations instead of locks where possible
//   - Bidirectional rays with 6-probe geometric mutations per hit

const std = @import("std");
const Allocator = std.mem.Allocator;
const Thread = std.Thread;
const Atomic = std.atomic.Value;

// ── Bitmap1D ────────────────────────────────────────────────────────────
//
// Bit-packed visibility storage using 64-bit words.  O(1) set/test,
// hardware popcount for fast counting.  Thread-safe via atomic OR.

pub const Bitmap1D = struct {
    bits: []Atomic(u64),
    bit_count: u32,
    allocator: Allocator,

    pub fn init(allocator: Allocator, count: u32) !Bitmap1D {
        const longs = longsNeeded(count);
        const bits = try allocator.alloc(Atomic(u64), longs);
        for (bits) |*b| b.raw = 0;
        return .{
            .bits = bits,
            .bit_count = count,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Bitmap1D) void {
        if (self.bits.len > 0) {
            self.allocator.free(self.bits);
            self.bits = &.{};
        }
    }

    /// Set a single bit.  Thread-safe (atomic OR).
    /// Returns true if the bit was newly set (was 0 before).
    pub fn set(self: *Bitmap1D, index: u32) bool {
        const long_index = index >> 6;
        const mask: u64 = @as(u64, 1) << @intCast(index & 63);
        const old = self.bits[long_index].fetchOr(mask, .monotonic);
        return (old & mask) == 0;
    }

    /// Test whether a bit is set.
    pub fn isSet(self: *const Bitmap1D, index: u32) bool {
        const long_index = index >> 6;
        const mask: u64 = @as(u64, 1) << @intCast(index & 63);
        return (self.bits[long_index].load(.monotonic) & mask) != 0;
    }

    /// Count of set bits (population count).
    pub fn countSet(self: *const Bitmap1D) u32 {
        var total: u32 = 0;
        for (self.bits) |*b| {
            total += @popCount(b.load(.monotonic));
        }
        return total;
    }

    /// Clear all bits.
    pub fn clear(self: *Bitmap1D) void {
        for (self.bits) |*b| b.store(0, .monotonic);
    }

    /// Extract all set bit indices into a caller-provided buffer.
    /// Returns the number of indices written.
    pub fn getSetBits(self: *const Bitmap1D, out: []u32) u32 {
        var count: u32 = 0;
        for (self.bits, 0..) |*b, long_idx| {
            var word = b.load(.monotonic);
            while (word != 0) {
                const bit: u6 = @intCast(@ctz(word));
                const global_bit: u32 = @as(u32, @intCast(long_idx)) * 64 + bit;
                if (global_bit >= self.bit_count) break;
                if (count < out.len) {
                    out[count] = global_bit;
                    count += 1;
                }
                word &= word - 1; // clear lowest set bit
            }
        }
        return count;
    }

    /// OR another bitmap into this one.  Returns count of newly set bits.
    pub fn merge(self: *Bitmap1D, other: *const Bitmap1D) u32 {
        var added: u32 = 0;
        const len = @min(self.bits.len, other.bits.len);
        for (0..len) |i| {
            const other_word = other.bits[i].load(.monotonic);
            if (other_word == 0) continue;
            const old = self.bits[i].fetchOr(other_word, .monotonic);
            added += @popCount(other_word & ~old);
        }
        return added;
    }

    fn longsNeeded(count: u32) u32 {
        return (count + 63) >> 6;
    }
};

// ── VisibilitySet ───────────────────────────────────────────────────────
//
// Per-cell visibility bitmaps.  Each view cell (identified by index) has
// a Bitmap1D tracking which primitives are visible from that cell.
// Thread-safe: the underlying Bitmap1D uses atomic bit-set.

pub const VisibilitySet = struct {
    cells: []?Bitmap1D,
    primitive_count: u32,
    allocator: Allocator,
    total_added: Atomic(u64),

    pub fn init(allocator: Allocator, cell_count: u32, primitive_count: u32) !VisibilitySet {
        const cells = try allocator.alloc(?Bitmap1D, cell_count);
        @memset(cells, null);
        return .{
            .cells = cells,
            .primitive_count = primitive_count,
            .allocator = allocator,
            .total_added = Atomic(u64).init(0),
        };
    }

    pub fn deinit(self: *VisibilitySet) void {
        for (self.cells) |*cell| {
            if (cell.*) |*bm| bm.deinit();
        }
        self.allocator.free(self.cells);
    }

    /// Ensure cell has an allocated bitmap.  Must be called before
    /// concurrent add() — typically during single-threaded setup.
    pub fn activateCell(self: *VisibilitySet, cell_index: u32) !void {
        if (self.cells[cell_index] == null) {
            self.cells[cell_index] = try Bitmap1D.init(self.allocator, self.primitive_count);
        }
    }

    /// Record that primitive is visible from cell.  Thread-safe.
    /// Returns 1 if newly added, 0 if already known.
    pub fn add(self: *VisibilitySet, cell_index: u32, prim_index: u32) u32 {
        if (self.cells[cell_index]) |*bm| {
            if (bm.set(prim_index)) {
                _ = self.total_added.fetchAdd(1, .monotonic);
                return 1;
            }
        }
        return 0;
    }

    /// Check if primitive is visible from cell.
    pub fn canSee(self: *const VisibilitySet, cell_index: u32, prim_index: u32) bool {
        if (self.cells[cell_index]) |*bm| {
            return bm.isSet(prim_index);
        }
        return false;
    }

    /// Get visible primitive count for a cell.
    pub fn visibleCount(self: *const VisibilitySet, cell_index: u32) u32 {
        if (self.cells[cell_index]) |*bm| {
            return bm.countSet();
        }
        return 0;
    }

    /// Get total added across all cells.
    pub fn totalAdded(self: *const VisibilitySet) u64 {
        return self.total_added.load(.monotonic);
    }
};

// ── Triangle utilities ──────────────────────────────────────────────────

const Vec3 = [3]f32;

fn vec3Sub(a: Vec3, b: Vec3) Vec3 {
    return .{ a[0] - b[0], a[1] - b[1], a[2] - b[2] };
}

fn vec3Add(a: Vec3, b: Vec3) Vec3 {
    return .{ a[0] + b[0], a[1] + b[1], a[2] + b[2] };
}

fn vec3Scale(v: Vec3, s: f32) Vec3 {
    return .{ v[0] * s, v[1] * s, v[2] * s };
}

fn vec3Cross(a: Vec3, b: Vec3) Vec3 {
    return .{
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    };
}

fn vec3Dot(a: Vec3, b: Vec3) f32 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

fn vec3Length(v: Vec3) f32 {
    return @sqrt(vec3Dot(v, v));
}

fn vec3Normalize(v: Vec3) Vec3 {
    const len = vec3Length(v);
    if (len < 1e-12) return .{ 0, 0, 0 };
    const inv = 1.0 / len;
    return .{ v[0] * inv, v[1] * inv, v[2] * inv };
}

/// Compute face normal for triangle (non-unit, caller normalizes if needed).
fn faceNormal(positions: []const Vec3, indices: []const u32, tri_index: u32) Vec3 {
    const base = tri_index * 3;
    const a = positions[indices[base]];
    const b = positions[indices[base + 1]];
    const c = positions[indices[base + 2]];
    return vec3Cross(vec3Sub(b, a), vec3Sub(c, a));
}

/// Random point on a triangle using barycentric coordinates.
pub fn randomPointOnTriangle(positions: []const Vec3, indices: []const u32, tri_index: u32, rng: std.Random) Vec3 {
    const base = tri_index * 3;
    const a = positions[indices[base]];
    const b = positions[indices[base + 1]];
    const c = positions[indices[base + 2]];

    var u = rng.float(f32);
    var v = rng.float(f32);
    if (u + v > 1.0) {
        u = 1.0 - u;
        v = 1.0 - v;
    }
    const w = 1.0 - u - v;
    return .{
        a[0] * w + b[0] * u + c[0] * v,
        a[1] * w + b[1] * u + c[1] * v,
        a[2] * w + b[2] * u + c[2] * v,
    };
}

/// Centroid of a triangle.
fn triangleCentroid(positions: []const Vec3, indices: []const u32, tri_index: u32) Vec3 {
    const base = tri_index * 3;
    const a = positions[indices[base]];
    const b = positions[indices[base + 1]];
    const c = positions[indices[base + 2]];
    return .{
        (a[0] + b[0] + c[0]) / 3.0,
        (a[1] + b[1] + c[1]) / 3.0,
        (a[2] + b[2] + c[2]) / 3.0,
    };
}

// ── Ray tracing interface ───────────────────────────────────────────────
//
// The PVS solver needs two BIVH trees:
//   1. World tree — ray intersection against scene geometry
//   2. View tree  — spatial lookup for view cell assignment
//
// Rather than importing bivh.zig directly (which lives in a separate
// project), we define a minimal interface here.  The caller wires up
// the real BIVH at init time.

/// Result of a ray trace against the world.
pub const TraceResult = struct {
    hit: bool = false,
    distance: f32 = std.math.floatMax(f32),
    primitive: i32 = -1,
    cell: i32 = -1,
};

/// Function pointer type for tracing a ray against the world BIVH.
/// (origin, direction, max_distance) -> TraceResult
pub const TraceFn = *const fn (ctx: *anyopaque, origin: Vec3, dir: Vec3, max_dist: f32) TraceResult;

/// Function pointer type for finding which view cell leaf contains a point.
/// Returns cell index or null.
pub const FindLeafFn = *const fn (ctx: *anyopaque, pos: Vec3) ?u32;

// ── Probe mutations ─────────────────────────────────────────────────────
//
// When a ray hits a triangle, we spawn 6 secondary probe rays from
// geometric features of the hit triangle:
//   - 3 vertices (a, b, c)
//   - 3 edge midpoints (midAB, midAC, midBC)
// Each probe is offset slightly along the direction from centroid to
// the feature point (0.001 units), preventing self-intersection.

const PROBE_COUNT = 6;
const PROBE_OFFSET = 0.001;

fn computeProbes(positions: []const Vec3, indices: []const u32, tri_index: u32) [PROBE_COUNT]Vec3 {
    const base = tri_index * 3;
    const a = positions[indices[base]];
    const b = positions[indices[base + 1]];
    const c = positions[indices[base + 2]];

    const centroid = Vec3{
        (a[0] + b[0] + c[0]) / 3.0,
        (a[1] + b[1] + c[1]) / 3.0,
        (a[2] + b[2] + c[2]) / 3.0,
    };

    const mid_ab = vec3Scale(vec3Add(a, b), 0.5);
    const mid_ac = vec3Scale(vec3Add(a, c), 0.5);
    const mid_bc = vec3Scale(vec3Add(b, c), 0.5);

    const features = [PROBE_COUNT]Vec3{ a, b, c, mid_ab, mid_ac, mid_bc };
    var probes: [PROBE_COUNT]Vec3 = undefined;

    for (features, 0..) |feat, i| {
        const dir = vec3Normalize(vec3Sub(feat, centroid));
        probes[i] = vec3Add(feat, vec3Scale(dir, PROBE_OFFSET));
    }

    return probes;
}

// ── Transport Graph ─────────────────────────────────────────────────────
//
// Sparse cell-to-cell connectivity with (casts, hits) per edge.
// Probability of visibility: P(A→B) = hits / casts.
// This IS the GI transport graph — it records how likely light can
// travel between any two cells in the scene.
// Thread-safe: uses atomic increments.

pub const TransportEdge = struct {
    casts: Atomic(u32),
    hits: Atomic(u32),

    fn probability(self: *const TransportEdge) f32 {
        const c = self.casts.load(.monotonic);
        if (c == 0) return 0.5; // uninformed prior
        const h = self.hits.load(.monotonic);
        // Bayesian: (hits + 1) / (casts + 2) — Laplace smoothing
        return @as(f32, @floatFromInt(h + 1)) / @as(f32, @floatFromInt(c + 2));
    }
};

pub const TransportGraph = struct {
    /// Flat array indexed by [cell_a * cell_count + cell_b].
    /// Only the upper triangle is used (cell_a < cell_b); accessor handles symmetry.
    edges: []TransportEdge,
    cell_count: u32,
    allocator: Allocator,

    pub fn init(allocator: Allocator, cell_count: u32) !TransportGraph {
        const n: u64 = cell_count;
        const edge_count = n * (n - 1) / 2; // upper triangle only
        const edges = try allocator.alloc(TransportEdge, edge_count);
        for (edges) |*e| {
            e.casts = Atomic(u32).init(0);
            e.hits = Atomic(u32).init(0);
        }
        return .{
            .edges = edges,
            .cell_count = cell_count,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TransportGraph) void {
        self.allocator.free(self.edges);
    }

    /// Index into the upper-triangle array.
    inline fn edgeIndex(self: *const TransportGraph, a: u32, b: u32) usize {
        const lo = @min(a, b);
        const hi = @max(a, b);
        // Row-major upper triangle: sum(cell_count-1 .. cell_count-lo) + (hi - lo - 1)
        const n = self.cell_count;
        return @as(usize, lo) * n - (@as(usize, lo) * (@as(usize, lo) + 1)) / 2 + hi - lo - 1;
    }

    pub fn recordCast(self: *TransportGraph, cell_a: u32, cell_b: u32) void {
        if (cell_a == cell_b) return;
        const idx = self.edgeIndex(cell_a, cell_b);
        _ = self.edges[idx].casts.fetchAdd(1, .monotonic);
    }

    pub fn recordHit(self: *TransportGraph, cell_a: u32, cell_b: u32) void {
        if (cell_a == cell_b) return;
        const idx = self.edgeIndex(cell_a, cell_b);
        _ = self.edges[idx].hits.fetchAdd(1, .monotonic);
    }

    pub fn getEdge(self: *const TransportGraph, cell_a: u32, cell_b: u32) *const TransportEdge {
        return &self.edges[self.edgeIndex(cell_a, cell_b)];
    }

    /// Total rays cast across all edges.
    pub fn totalCasts(self: *const TransportGraph) u64 {
        var total: u64 = 0;
        for (self.edges) |*e| total += e.casts.load(.monotonic);
        return total;
    }

    /// Count of edges with at least one hit.
    pub fn connectedEdges(self: *const TransportGraph) u64 {
        var count: u64 = 0;
        for (self.edges) |*e| {
            if (e.hits.load(.monotonic) > 0) count += 1;
        }
        return count;
    }

    /// Count of dead edges (many casts, zero hits).
    pub fn deadEdges(self: *const TransportGraph, min_casts: u32) u64 {
        var count: u64 = 0;
        for (self.edges) |*e| {
            if (e.casts.load(.monotonic) >= min_casts and e.hits.load(.monotonic) == 0) count += 1;
        }
        return count;
    }

    /// Check if a cell pair is confirmed dead (many casts, zero hits).
    pub fn isDead(self: *const TransportGraph, cell_a: u32, cell_b: u32, min_casts: u32) bool {
        if (cell_a == cell_b) return false;
        const edge = self.getEdge(cell_a, cell_b);
        return edge.casts.load(.monotonic) >= min_casts and edge.hits.load(.monotonic) == 0;
    }

    /// Seed this graph from a coarser graph using a cell mapping.
    /// `fine_to_coarse[i]` maps fine cell i → coarse cell index.
    /// Edges where the coarse pair is dead get pre-seeded with high
    /// cast count and zero hits (blacklisted).
    pub fn seedFromCoarse(
        self: *TransportGraph,
        coarse: *const TransportGraph,
        fine_to_coarse: []const u32,
        dead_threshold: u32,
    ) void {
        for (0..self.cell_count) |i| {
            for (i + 1..self.cell_count) |j| {
                const ci = fine_to_coarse[i];
                const cj = fine_to_coarse[j];
                if (ci == cj) continue; // same coarse cell — no prior

                const coarse_edge = coarse.getEdge(ci, cj);
                const coarse_casts = coarse_edge.casts.load(.monotonic);

                if (coarse_casts >= dead_threshold and coarse_edge.hits.load(.monotonic) == 0) {
                    // Blacklist: seed with high casts, zero hits
                    const idx = self.edgeIndex(@intCast(i), @intCast(j));
                    self.edges[idx].casts = Atomic(u32).init(dead_threshold);
                    self.edges[idx].hits = Atomic(u32).init(0);
                }
            }
        }
    }
};

// ── Visibility Islands & Probe Placement ────────────────────────────────
//
// Cluster cells into "visibility islands" — groups of cells that are
// mutually well-connected.  The boundaries between islands are where
// the visible environment changes most — doorways, windows, corners.
// GI probes should be placed at these transitions.

pub const IslandResult = struct {
    /// Island ID per cell (0..num_islands-1).
    island_ids: []u32,
    num_islands: u32,
    /// Cells that border multiple islands.
    boundary_cells: []u32,
    num_boundary: u32,
    allocator: Allocator,

    pub fn deinit(self: *IslandResult) void {
        self.allocator.free(self.island_ids);
        self.allocator.free(self.boundary_cells);
    }
};

/// Find visibility islands via flood-fill on the thresholded transport graph.
/// Two cells are "connected" if their transport probability > threshold.
pub fn findIslands(
    allocator: Allocator,
    transport: *const TransportGraph,
    num_cells: u32,
    prob_threshold: f32,
    min_casts: u32,
) !IslandResult {
    const island_ids = try allocator.alloc(u32, num_cells);
    @memset(island_ids, std.math.maxInt(u32)); // unvisited sentinel

    var current_island: u32 = 0;
    var queue = std.ArrayList(u32).init(allocator);
    defer queue.deinit();

    // Flood-fill connected components
    for (0..num_cells) |start| {
        if (island_ids[start] != std.math.maxInt(u32)) continue;

        // BFS from this unvisited cell
        island_ids[start] = current_island;
        queue.clearRetainingCapacity();
        try queue.append(@intCast(start));

        while (queue.items.len > 0) {
            const cell = queue.orderedRemove(0);

            // Visit all neighbors with P > threshold
            for (0..num_cells) |j| {
                if (j == cell) continue;
                if (island_ids[j] != std.math.maxInt(u32)) continue;

                const edge = transport.getEdge(cell, @intCast(j));
                const casts = edge.casts.load(.monotonic);
                if (casts < min_casts) continue;
                const hits = edge.hits.load(.monotonic);
                const prob = @as(f32, @floatFromInt(hits)) / @as(f32, @floatFromInt(casts));
                if (prob >= prob_threshold) {
                    island_ids[j] = current_island;
                    try queue.append(@intCast(j));
                }
            }
        }

        current_island += 1;
    }

    // Find boundary cells — cells that have transport edges to cells in different islands
    var boundary = std.ArrayList(u32).init(allocator);
    errdefer boundary.deinit();

    for (0..num_cells) |i| {
        const my_island = island_ids[i];
        var is_boundary = false;

        for (0..num_cells) |j| {
            if (i == j) continue;
            if (island_ids[j] == my_island) continue;

            // Check if there's ANY visibility between these cells
            const edge = transport.getEdge(@intCast(i), @intCast(j));
            if (edge.hits.load(.monotonic) > 0) {
                is_boundary = true;
                break;
            }
        }

        if (is_boundary) try boundary.append(@intCast(i));
    }

    return .{
        .island_ids = island_ids,
        .num_islands = current_island,
        .boundary_cells = try boundary.toOwnedSlice(),
        .num_boundary = @intCast(boundary.items.len),
        .allocator = allocator,
    };
}

pub const Probe = struct {
    position: [3]f32,
    island_id: u32,
    is_boundary: bool,
};

/// Place GI probes based on island analysis.
/// - One probe at each boundary cell (lighting transitions)
/// - One probe at the highest-connectivity cell per island (interior)
pub fn placeProbes(
    allocator: Allocator,
    islands: *const IslandResult,
    transport: *const TransportGraph,
    cell_centroids: []const [3]f32,
    num_cells: u32,
) ![]Probe {
    var probes = std.ArrayList(Probe).init(allocator);
    errdefer probes.deinit();

    // Boundary probes — one per boundary cell
    for (islands.boundary_cells[0..islands.num_boundary]) |cell| {
        probes.append(.{
            .position = cell_centroids[cell],
            .island_id = islands.island_ids[cell],
            .is_boundary = true,
        }) catch continue;
    }

    // Interior probes — find the best-connected cell per island
    for (0..islands.num_islands) |island| {
        var best_cell: u32 = 0;
        var best_connectivity: u64 = 0;
        var found = false;

        for (0..num_cells) |ci| {
            if (islands.island_ids[ci] != island) continue;

            // Sum hit counts to all cells in the same island
            var connectivity: u64 = 0;
            for (0..num_cells) |cj| {
                if (ci == cj) continue;
                if (islands.island_ids[cj] != island) continue;
                const edge = transport.getEdge(@intCast(ci), @intCast(cj));
                connectivity += edge.hits.load(.monotonic);
            }

            if (connectivity > best_connectivity or !found) {
                best_cell = @intCast(ci);
                best_connectivity = connectivity;
                found = true;
            }
        }

        if (found) {
            probes.append(.{
                .position = cell_centroids[best_cell],
                .island_id = @intCast(island),
                .is_boundary = false,
            }) catch continue;
        }
    }

    return probes.toOwnedSlice();
}

/// Find probes at transport gradient peaks — where connectivity changes
/// sharply between spatial neighbors.  These are doorways, windows,
/// corners where the visible environment transitions.
pub fn findGradientProbes(
    allocator: Allocator,
    transport: *const TransportGraph,
    cell_centroids: []const [3]f32,
    num_cells: u32,
    gradient_threshold: f32,
) ![]Probe {
    // Step 1: Compute per-cell "openness" = total transport flow
    const openness = try allocator.alloc(f32, num_cells);
    defer allocator.free(openness);

    for (0..num_cells) |i| {
        var total: f64 = 0;
        for (0..num_cells) |j| {
            if (i == j) continue;
            const edge = transport.getEdge(@intCast(i), @intCast(j));
            total += @floatFromInt(edge.hits.load(.monotonic));
        }
        openness[i] = @floatCast(total);
    }

    // Normalize openness to [0, 1]
    var max_open: f32 = 1.0;
    for (openness) |v| max_open = @max(max_open, v);
    for (openness) |*v| v.* /= max_open;

    // Step 2: For each cell, compute gradient = max difference in openness
    // to any spatially-connected neighbor (has transport > 0)
    const gradient = try allocator.alloc(f32, num_cells);
    defer allocator.free(gradient);

    for (0..num_cells) |i| {
        var max_diff: f32 = 0;
        for (0..num_cells) |j| {
            if (i == j) continue;
            const edge = transport.getEdge(@intCast(i), @intCast(j));
            if (edge.hits.load(.monotonic) == 0) continue;

            // Only consider spatial neighbors (within reasonable distance)
            const dx = cell_centroids[i][0] - cell_centroids[j][0];
            const dy = cell_centroids[i][1] - cell_centroids[j][1];
            const dz = cell_centroids[i][2] - cell_centroids[j][2];
            const dist_sq = dx * dx + dy * dy + dz * dz;
            // Skip very distant pairs — we want local gradient
            if (dist_sq > 400.0) continue; // ~20m radius

            const diff = @abs(openness[i] - openness[j]);
            max_diff = @max(max_diff, diff);
        }
        gradient[i] = max_diff;
    }

    // Step 3: Find local maxima of the gradient above threshold
    var probes = std.ArrayList(Probe).init(allocator);
    errdefer probes.deinit();

    for (0..num_cells) |i| {
        if (gradient[i] < gradient_threshold) continue;

        // Check if this is a local maximum (higher gradient than all
        // nearby cells) — prevents clustering probes at the same doorway
        var is_peak = true;
        for (0..num_cells) |j| {
            if (i == j) continue;
            const dx = cell_centroids[i][0] - cell_centroids[j][0];
            const dy = cell_centroids[i][1] - cell_centroids[j][1];
            const dz = cell_centroids[i][2] - cell_centroids[j][2];
            if (dx * dx + dy * dy + dz * dz > 100.0) continue; // ~10m radius
            if (gradient[j] > gradient[i]) {
                is_peak = false;
                break;
            }
        }

        if (is_peak) {
            try probes.append(.{
                .position = cell_centroids[i],
                .island_id = 0,
                .is_boundary = true,
            });
        }
    }

    return probes.toOwnedSlice();
}

// ── PVS Solver ──────────────────────────────────────────────────────────
//
// Importance-sampled PVS solver.  Instead of picking random triangles
// from the full scene, we:
//   1. Pick a source cell (round-robin or weighted by under-sampling)
//   2. Pick a target cell weighted by learned P(visible) from the
//      transport graph, with exploration for unsampled pairs
//   3. Pick random triangles within those cells
//   4. Trace and update the graph + visibility bitmaps
//
// The transport graph converges as we sample — high-connectivity edges
// (doorways, open sightlines) get reinforced, occluded pairs get
// starved of budget.  The graph itself is the GI transport matrix.

pub const SolverConfig = struct {
    /// Number of worker threads (0 = auto-detect).
    thread_count: u32 = 0,
    /// Maximum ray distance.
    max_ray_distance: f32 = 2000.0,
    /// Number of consecutive zero-contribution passes before declaring convergence.
    convergence_threshold: u32 = 120,
    /// Number of ray samples per pass.
    samples_per_pass: u32 = 100_000,
    /// Maximum number of passes (safety limit).
    max_passes: u32 = 10_000,
    /// Callback for progress reporting (pass_number, new_additions, total_visible).
    progress_fn: ?*const fn (pass: u32, added: u64, total: u64) void = null,
    /// Cluster size as a power-of-2 shift for visibility bitmaps.
    /// 0 = per-triangle, 8 = clusters of 256.
    cluster_shift: u5 = 0,
    /// Exploration rate: probability of picking an unsampled/low-sample
    /// cell pair instead of importance-sampling.  Decays over time.
    exploration_rate: f32 = 0.3,
    /// Maximum solve time in seconds (0 = unlimited).
    max_time_seconds: u32 = 0,
};

/// Describes a cell's triangle range in the BIVH-sorted index buffer.
pub const CellRange = struct {
    start_tri: u32,
    end_tri: u32, // exclusive
};

pub const PvsSolver = struct {
    // Scene data
    positions: []const Vec3,
    indices: []const u32,
    tri_count: u32,
    cluster_count: u32,

    // Cell triangle ranges (which tris belong to which cell)
    cell_ranges: []const CellRange,
    cell_indices: []const u32, // active cell node indices (for BIVH leaf lookup)
    num_cells: u32,

    // BIVH interface
    trace_fn: TraceFn,
    trace_ctx: *anyopaque,
    find_leaf_fn: FindLeafFn,
    find_leaf_ctx: *anyopaque,

    // Outputs
    visibility: VisibilitySet,
    transport: TransportGraph,

    // Config
    config: SolverConfig,
    allocator: Allocator,

    // Solver state
    pass_count: u32 = 0,
    running: Atomic(bool),

    /// Map a triangle index to its cluster index.
    inline fn toCluster(self: *const PvsSolver, tri_index: u32) u32 {
        return tri_index >> self.config.cluster_shift;
    }

    pub fn init(
        allocator: Allocator,
        positions: []const Vec3,
        indices: []const u32,
        cell_count: u32,
        cell_node_indices: []const u32,
        cell_ranges: []const CellRange,
        trace_fn: TraceFn,
        trace_ctx: *anyopaque,
        find_leaf_fn: FindLeafFn,
        find_leaf_ctx: *anyopaque,
        config: SolverConfig,
    ) !PvsSolver {
        const tri_count: u32 = @intCast(indices.len / 3);
        const cluster_count = (tri_count >> config.cluster_shift) +
            @as(u32, if (tri_count & ((@as(u32, 1) << config.cluster_shift) - 1) != 0) 1 else 0);

        var vis = try VisibilitySet.init(allocator, cell_count, cluster_count);
        errdefer vis.deinit();
        for (cell_node_indices) |idx| try vis.activateCell(idx);

        var transport = try TransportGraph.init(allocator, @intCast(cell_ranges.len));
        errdefer transport.deinit();

        return .{
            .positions = positions,
            .indices = indices,
            .tri_count = tri_count,
            .cluster_count = cluster_count,
            .cell_ranges = cell_ranges,
            .cell_indices = cell_node_indices,
            .num_cells = @intCast(cell_ranges.len),
            .trace_fn = trace_fn,
            .trace_ctx = trace_ctx,
            .find_leaf_fn = find_leaf_fn,
            .find_leaf_ctx = find_leaf_ctx,
            .visibility = vis,
            .transport = transport,
            .config = config,
            .allocator = allocator,
            .running = Atomic(bool).init(false),
        };
    }

    pub fn deinit(self: *PvsSolver) void {
        self.visibility.deinit();
        self.transport.deinit();
    }

    pub fn solve(self: *PvsSolver) !void {
        self.running.store(true, .release);
        defer self.running.store(false, .release);

        const num_threads = if (self.config.thread_count > 0)
            self.config.thread_count
        else
            @as(u32, @intCast(Thread.getCpuCount() catch 4));

        const threads = try self.allocator.alloc(Thread, num_threads);
        defer self.allocator.free(threads);

        var current_pass = Atomic(u32).init(0);

        for (threads, 0..) |*t, i| {
            t.* = try Thread.spawn(.{}, workerMain, .{ self, &current_pass, @as(u32, @intCast(i)) });
        }
        for (threads) |t| t.join();

        self.pass_count = current_pass.load(.acquire);
    }

    pub fn stop(self: *PvsSolver) void {
        self.running.store(false, .release);
    }

    pub fn stats(self: *const PvsSolver) SolveStats {
        var active_cells: u32 = 0;
        var total_visible: u64 = 0;
        var min_visible: u32 = std.math.maxInt(u32);
        var max_visible: u32 = 0;

        for (self.visibility.cells) |cell| {
            if (cell) |bm| {
                active_cells += 1;
                const count = bm.countSet();
                total_visible += count;
                min_visible = @min(min_visible, count);
                max_visible = @max(max_visible, count);
            }
        }

        return .{
            .passes = self.pass_count,
            .active_cells = active_cells,
            .total_visible = total_visible,
            .avg_visible = if (active_cells > 0) total_visible / active_cells else 0,
            .min_visible = if (active_cells > 0) min_visible else 0,
            .max_visible = max_visible,
            .transport_casts = self.transport.totalCasts(),
            .transport_edges = self.transport.connectedEdges(),
        };
    }

    fn workerMain(self: *PvsSolver, current_pass: *Atomic(u32), thread_id: u32) void {
        var seed: u64 = @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())));
        seed ^= @as(u64, thread_id) * 0x9E3779B97F4A7C15;
        var prng = std.Random.DefaultPrng.init(seed);
        const rng = prng.random();

        const start_time: i128 = std.time.nanoTimestamp();
        const time_limit: i128 = if (self.config.max_time_seconds > 0)
            @as(i128, self.config.max_time_seconds) * 1_000_000_000
        else
            std.math.maxInt(i128);

        var consecutive_zero: u32 = 0;

        while (self.running.load(.acquire)) {
            const pass = current_pass.fetchAdd(1, .acq_rel);
            if (pass >= self.config.max_passes) break;

            // Time limit check
            if (std.time.nanoTimestamp() - start_time > time_limit) {
                self.running.store(false, .release);
                break;
            }

            const added = self.runPass(rng, pass);

            if (added == 0) {
                consecutive_zero += 1;
                if (consecutive_zero >= self.config.convergence_threshold) {
                    self.running.store(false, .release);
                    break;
                }
            } else {
                consecutive_zero = 0;
            }

            if (self.config.progress_fn) |progress| {
                progress(pass, added, self.visibility.totalAdded());
            }
        }
    }

    fn runPass(self: *PvsSolver, rng: std.Random, pass: u32) u64 {
        var added: u64 = 0;
        const n = self.num_cells;
        if (n < 2) return 0;

        // Decay exploration rate over time
        const decay = @max(0.05, self.config.exploration_rate * (1.0 - @as(f32, @floatFromInt(@min(pass, 5000))) / 5000.0));

        var i: u32 = 0;
        while (i < self.config.samples_per_pass) : (i += 1) {
            if (!self.running.load(.acquire)) break;

            // 1. Pick source cell (round-robin with jitter for load balance)
            const cell_a = rng.intRangeLessThan(u32, 0, n);

            // 2. Pick target cell: explore or exploit
            const cell_b = if (rng.float(f32) < decay)
                self.pickExploreTarget(rng, cell_a, n)
            else
                self.pickExploitTarget(rng, cell_a, n);

            if (cell_a == cell_b) continue;

            // Skip dead edges (seeded from coarser epoch or confirmed dead here)
            if (self.transport.isDead(cell_a, cell_b, 50)) continue;

            // 3. Pick random triangles within those cells
            const range_a = self.cell_ranges[cell_a];
            const range_b = self.cell_ranges[cell_b];
            if (range_a.start_tri >= range_a.end_tri) continue;
            if (range_b.start_tri >= range_b.end_tri) continue;

            const tri_a = rng.intRangeLessThan(u32, range_a.start_tri, range_a.end_tri);
            const tri_b = rng.intRangeLessThan(u32, range_b.start_tri, range_b.end_tri);

            const p1 = randomPointOnTriangle(self.positions, self.indices, tri_a, rng);
            const p2 = randomPointOnTriangle(self.positions, self.indices, tri_b, rng);

            // 4. Trace and update
            added += self.traceAndRecord(p1, p2, tri_a, tri_b, cell_a, cell_b, rng);
        }

        return added;
    }

    /// Pick a target cell for exploration — prefer under-sampled, non-dead pairs.
    fn pickExploreTarget(self: *PvsSolver, rng: std.Random, source: u32, n: u32) u32 {
        var best: u32 = rng.intRangeLessThan(u32, 0, n);
        var best_casts: u32 = std.math.maxInt(u32);

        for (0..12) |_| {
            const candidate = rng.intRangeLessThan(u32, 0, n);
            if (candidate == source) continue;
            if (self.transport.isDead(source, candidate, 50)) continue;
            const edge = self.transport.getEdge(source, candidate);
            const casts = edge.casts.load(.monotonic);
            if (casts < best_casts) {
                best = candidate;
                best_casts = casts;
                if (casts == 0) break;
            }
        }
        return best;
    }

    /// Pick a target cell by importance — weighted by P(visible).
    fn pickExploitTarget(self: *PvsSolver, rng: std.Random, source: u32, n: u32) u32 {
        // Stochastic acceptance: pick random candidate, accept with P(visible),
        // reject and retry.  Bounded attempts to avoid spinning.
        for (0..16) |_| {
            const candidate = rng.intRangeLessThan(u32, 0, n);
            if (candidate == source) continue;
            const edge = self.transport.getEdge(source, candidate);
            const p = edge.probability();
            if (rng.float(f32) < p) return candidate;
        }
        // Fallback: random
        return rng.intRangeLessThan(u32, 0, n);
    }

    fn traceAndRecord(
        self: *PvsSolver,
        p1: Vec3,
        p2: Vec3,
        tri_a: u32,
        tri_b: u32,
        cell_a: u32,
        cell_b: u32,
        rng: std.Random,
    ) u64 {
        const dir = vec3Sub(p2, p1);
        const dist = vec3Length(dir);
        if (dist < 1e-6) return 0;
        if (dist > self.config.max_ray_distance) return 0;

        const norm_dir = vec3Scale(dir, 1.0 / dist);
        const result = self.trace_fn(self.trace_ctx, p1, norm_dir, dist + 0.01);

        // Always record the cast
        self.transport.recordCast(cell_a, cell_b);

        // Check if ray reaches target
        const reached = !result.hit or
            result.primitive == @as(i32, @intCast(tri_b)) or
            result.distance >= dist - 0.01;

        if (!reached) {
            // Occluded — but the occluder is visible from source cell
            if (result.primitive >= 0) {
                const occ: u32 = @intCast(result.primitive);
                const node_a = self.cell_indices[cell_a];
                _ = self.visibility.add(node_a, self.toCluster(occ));
            }
            return 0;
        }

        // Hit! Update transport graph
        self.transport.recordHit(cell_a, cell_b);

        var added: u64 = 0;
        const cluster_a = self.toCluster(tri_a);
        const cluster_b = self.toCluster(tri_b);
        const node_a = self.cell_indices[cell_a];
        const node_b = self.cell_indices[cell_b];

        // Record cluster visibility in both cells
        added += self.visibility.add(node_a, cluster_a);
        added += self.visibility.add(node_a, cluster_b);
        added += self.visibility.add(node_b, cluster_a);
        added += self.visibility.add(node_b, cluster_b);

        // Sample intermediate cells along the ray
        const step_count: u32 = @max(2, @as(u32, @intFromFloat(dist / 5.0)));
        const inv_steps = 1.0 / @as(f32, @floatFromInt(step_count));
        for (1..step_count) |s| {
            const t = @as(f32, @floatFromInt(s)) * inv_steps;
            const mid = vec3Add(p1, vec3Scale(dir, t));
            if (self.find_leaf_fn(self.find_leaf_ctx, mid)) |cell_mid| {
                added += self.visibility.add(cell_mid, cluster_a);
                added += self.visibility.add(cell_mid, cluster_b);
            }
        }

        // Spawn mutation probes on successful hits
        if (added > 0) {
            self.spawnMutations(p1, tri_a, rng);
            self.spawnMutations(p2, tri_b, rng);
        }

        return added;
    }

    fn spawnMutations(self: *PvsSolver, origin: Vec3, tri_index: u32, rng: std.Random) void {
        const probes = computeProbes(self.positions, self.indices, tri_index);

        for (probes) |probe| {
            const probe_dir = vec3Sub(probe, origin);
            if (vec3Length(probe_dir) < 1e-8) continue;
            const norm_probe = vec3Normalize(probe_dir);

            const result = self.trace_fn(self.trace_ctx, probe, norm_probe, self.config.max_ray_distance);
            if (!result.hit or result.primitive < 0) continue;

            const hit_prim: u32 = @intCast(result.primitive);
            const n = vec3Normalize(faceNormal(self.positions, self.indices, hit_prim));
            if (vec3Dot(n, norm_probe) >= 0.0) continue;

            if (self.find_leaf_fn(self.find_leaf_ctx, probe)) |cell| {
                _ = self.visibility.add(cell, self.toCluster(hit_prim));
                _ = self.visibility.add(cell, self.toCluster(tri_index));
            }

            // Probabilistic secondary bounce
            if (rng.float(f32) < 0.3) {
                const new_point = randomPointOnTriangle(self.positions, self.indices, hit_prim, rng);
                const new_dir = vec3Normalize(vec3Sub(new_point, probe));
                const new_result = self.trace_fn(self.trace_ctx, probe, new_dir, self.config.max_ray_distance);
                if (new_result.hit and new_result.primitive >= 0) {
                    if (self.find_leaf_fn(self.find_leaf_ctx, probe)) |cell2| {
                        _ = self.visibility.add(cell2, self.toCluster(@intCast(new_result.primitive)));
                    }
                }
            }
        }
    }
};

pub const SolveStats = struct {
    passes: u32,
    active_cells: u32,
    total_visible: u64,
    avg_visible: u64,
    min_visible: u32,
    max_visible: u32,
    transport_casts: u64,
    transport_edges: u64,
};

// ── Tests ───────────────────────────────────────────────────────────────

test "Bitmap1D set and test" {
    var bm = try Bitmap1D.init(std.testing.allocator, 256);
    defer bm.deinit();

    try std.testing.expect(!bm.isSet(0));
    try std.testing.expect(!bm.isSet(100));
    try std.testing.expect(!bm.isSet(255));

    try std.testing.expect(bm.set(0)); // newly set
    try std.testing.expect(!bm.set(0)); // already set
    try std.testing.expect(bm.isSet(0));

    try std.testing.expect(bm.set(100));
    try std.testing.expect(bm.isSet(100));

    try std.testing.expect(bm.set(255));
    try std.testing.expect(bm.isSet(255));

    try std.testing.expectEqual(@as(u32, 3), bm.countSet());
}

test "Bitmap1D getSetBits" {
    var bm = try Bitmap1D.init(std.testing.allocator, 128);
    defer bm.deinit();

    _ = bm.set(5);
    _ = bm.set(63);
    _ = bm.set(64);
    _ = bm.set(127);

    var buf: [128]u32 = undefined;
    const count = bm.getSetBits(&buf);

    try std.testing.expectEqual(@as(u32, 4), count);
    try std.testing.expectEqual(@as(u32, 5), buf[0]);
    try std.testing.expectEqual(@as(u32, 63), buf[1]);
    try std.testing.expectEqual(@as(u32, 64), buf[2]);
    try std.testing.expectEqual(@as(u32, 127), buf[3]);
}

test "Bitmap1D merge" {
    var a = try Bitmap1D.init(std.testing.allocator, 128);
    defer a.deinit();
    var b = try Bitmap1D.init(std.testing.allocator, 128);
    defer b.deinit();

    _ = a.set(10);
    _ = a.set(20);
    _ = b.set(20);
    _ = b.set(30);

    const newly_added = a.merge(&b);
    try std.testing.expectEqual(@as(u32, 1), newly_added); // only 30 was new
    try std.testing.expectEqual(@as(u32, 3), a.countSet()); // 10, 20, 30
    try std.testing.expect(a.isSet(30));
}

test "Bitmap1D clear" {
    var bm = try Bitmap1D.init(std.testing.allocator, 64);
    defer bm.deinit();

    _ = bm.set(0);
    _ = bm.set(63);
    try std.testing.expectEqual(@as(u32, 2), bm.countSet());

    bm.clear();
    try std.testing.expectEqual(@as(u32, 0), bm.countSet());
    try std.testing.expect(!bm.isSet(0));
    try std.testing.expect(!bm.isSet(63));
}

test "VisibilitySet add and query" {
    var vs = try VisibilitySet.init(std.testing.allocator, 4, 100);
    defer vs.deinit();

    try vs.activateCell(0);
    try vs.activateCell(2);

    // Cell 0 sees primitive 42
    try std.testing.expectEqual(@as(u32, 1), vs.add(0, 42));
    try std.testing.expect(vs.canSee(0, 42));
    try std.testing.expect(!vs.canSee(0, 43));

    // Duplicate add returns 0
    try std.testing.expectEqual(@as(u32, 0), vs.add(0, 42));

    // Cell 2 sees primitive 99
    try std.testing.expectEqual(@as(u32, 1), vs.add(2, 99));
    try std.testing.expect(vs.canSee(2, 99));

    // Cell 1 was not activated — add is a no-op
    try std.testing.expectEqual(@as(u32, 0), vs.add(1, 50));
    try std.testing.expect(!vs.canSee(1, 50));

    try std.testing.expectEqual(@as(u64, 2), vs.totalAdded());
    try std.testing.expectEqual(@as(u32, 1), vs.visibleCount(0));
    try std.testing.expectEqual(@as(u32, 1), vs.visibleCount(2));
}

test "triangle utilities" {
    // Verify centroid
    const positions = [_]Vec3{
        .{ 0, 0, 0 },
        .{ 3, 0, 0 },
        .{ 0, 3, 0 },
    };
    const indices = [_]u32{ 0, 1, 2 };

    const c = triangleCentroid(&positions, &indices, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), c[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), c[1], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), c[2], 1e-6);

    // Verify face normal points in +Z for CCW triangle in XY plane
    const n = faceNormal(&positions, &indices, 0);
    try std.testing.expect(n[2] > 0.0);
}

test "probe computation" {
    const positions = [_]Vec3{
        .{ 0, 0, 5 },
        .{ 2, 0, 5 },
        .{ 1, 2, 5 },
    };
    const indices = [_]u32{ 0, 1, 2 };

    const probes = computeProbes(&positions, &indices, 0);

    // All 6 probes should be near the triangle but slightly offset
    for (probes) |p| {
        try std.testing.expect(p[2] > 4.9 and p[2] < 5.1);
    }
}
