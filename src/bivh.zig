// BIVH — Bounding Interval Volume Hierarchy
//
// Fast spatial acceleration structure for CPU ray tracing, ported from
// Foundation42.Geometry.BIVH (C#/XNA).  Blends attributes of
// BVH and BIH for fast build and traversal with low memory overhead.
//
// Works with any PrimitiveSet that provides bounds, swap, and ray
// intersection.  A ready-made TriangleMeshSet adapter wraps raw
// position/index arrays.

const std = @import("std");
const Allocator = std.mem.Allocator;

// ── Traversal counters (diagnostic) ──────────────────────────────────
//
// File-scope counters incremented during trace.  Reset via
// `resetStats()` before a measurement and read afterwards.  The
// overhead is ~1-2% on a hot loop — small enough to keep on during
// benchmarks but not something the production path should care about.
pub var stat_nodes_visited: u64 = 0;
pub var stat_leaves_visited: u64 = 0;
pub var stat_tris_tested: u64 = 0;

pub fn resetStats() void {
    stat_nodes_visited = 0;
    stat_leaves_visited = 0;
    stat_tris_tested = 0;
}

// ── Axis ─────────────────────────────────────────────────────────────

pub const Axis = enum(u8) {
    x = 0,
    y = 1,
    z = 2,
    none = 3, // leaf sentinel
};

// ── BIH Node ─────────────────────────────────────────────────────────
//
// 32 bytes per node.  The first u32 packs the split axis (low 8 bits)
// and either the right-child node index or the leaf start-prim index
// (upper 24 bits), matching the original C# FieldOffset layout.

pub const BihNode = struct {
    axis_and_index: u32 = 0,
    end_prim: i32 = 0,
    min: [3]f32 = .{ 0, 0, 0 },
    max: [3]f32 = .{ 0, 0, 0 },

    pub fn initLeaf(start_prim: i32, end_prim: i32, box_min: [3]f32, box_max: [3]f32) BihNode {
        return .{
            .axis_and_index = (@as(u32, @bitCast(start_prim)) << 8) | @intFromEnum(Axis.none),
            .end_prim = end_prim,
            .min = box_min,
            .max = box_max,
        };
    }

    pub fn initInterior(axis: Axis, box_min: [3]f32, box_max: [3]f32) BihNode {
        return .{
            .axis_and_index = @intFromEnum(axis),
            .end_prim = 0,
            .min = box_min,
            .max = box_max,
        };
    }

    pub inline fn isLeaf(self: BihNode) bool {
        return self.splitAxis() == .none;
    }

    pub inline fn splitAxis(self: BihNode) Axis {
        return @enumFromInt(self.axis_and_index & 0xFF);
    }

    pub inline fn startPrim(self: BihNode) i32 {
        return @bitCast(self.axis_and_index >> 8);
    }

    pub inline fn rightNodeIndex(self: BihNode) u32 {
        return self.axis_and_index >> 8;
    }

    pub fn setRightNodeIndex(self: *BihNode, index: u32) void {
        self.axis_and_index = (self.axis_and_index & 0xFF) | (index << 8);
    }

    pub inline fn axisMin(self: BihNode, axis: Axis) f32 {
        return self.min[@intFromEnum(axis)];
    }

    pub inline fn axisMax(self: BihNode, axis: Axis) f32 {
        return self.max[@intFromEnum(axis)];
    }
};

// ── Trace Ray ────────────────────────────────────────────────────────
//
// Compact f32 ray with origin + inverse direction.  The slab-based
// AABB test below needs nothing else — fits in ~40 bytes and lives
// entirely in registers during a trace.

pub const TraceRay = struct {
    // Origin
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,

    // Inverse direction (1/d)
    ii: f32 = 0,
    ij: f32 = 0,
    ik: f32 = 0,

    hit_distance: f32 = std.math.floatMax(f32),
    hit_primitive: i32 = -1,
    hit_cell: i32 = -1,

    /// Build a ray from origin + direction + max distance.
    pub fn make(ox: f32, oy: f32, oz: f32, dx: f32, dy: f32, dz: f32, max_dist: f32) TraceRay {
        return .{
            .x = ox,
            .y = oy,
            .z = oz,
            .ii = 1.0 / dx,
            .ij = 1.0 / dy,
            .ik = 1.0 / dz,
            .hit_distance = max_dist,
            .hit_primitive = -1,
            .hit_cell = -1,
        };
    }

    /// Build a ray from start point to end point.
    pub fn fromEndpoints(start: [3]f32, end: [3]f32) TraceRay {
        const dx = end[0] - start[0];
        const dy = end[1] - start[1];
        const dz = end[2] - start[2];
        const len = @sqrt(dx * dx + dy * dy + dz * dz);
        if (len < 1e-12) return TraceRay{};
        const inv = 1.0 / len;
        return make(start[0], start[1], start[2], dx * inv, dy * inv, dz * inv, len + 0.1);
    }

    /// Build a ray from origin + direction + max distance (array form).
    pub fn fromOriginDir(origin: [3]f32, dir: [3]f32, max_dist: f32) TraceRay {
        return make(origin[0], origin[1], origin[2], dir[0], dir[1], dir[2], max_dist);
    }

    /// Plain slab-based ray/AABB test (Kay-Kajiya, branchless).
    /// 6 subs + 6 muls + 6 mins/maxes, all in f32.
    pub inline fn intersectsAABB(self: *const TraceRay, box_min: [3]f32, box_max: [3]f32) bool {
        const t1x = (box_min[0] - self.x) * self.ii;
        const t2x = (box_max[0] - self.x) * self.ii;
        const t1y = (box_min[1] - self.y) * self.ij;
        const t2y = (box_max[1] - self.y) * self.ij;
        const t1z = (box_min[2] - self.z) * self.ik;
        const t2z = (box_max[2] - self.z) * self.ik;

        const tmin_x = @min(t1x, t2x);
        const tmax_x = @max(t1x, t2x);
        const tmin_y = @min(t1y, t2y);
        const tmax_y = @max(t1y, t2y);
        const tmin_z = @min(t1z, t2z);
        const tmax_z = @max(t1z, t2z);

        const tmin = @max(tmin_x, @max(tmin_y, tmin_z));
        const tmax = @min(tmax_x, @min(tmax_y, tmax_z));

        return tmax >= @max(tmin, 0.0) and tmin <= self.hit_distance;
    }

};

// ── Triangle Mesh Primitive Set ──────────────────────────────────────
//
// Adapts mesh.Mesh (interleaved Vertex + u32 indices) for BIVH.
// Also supports raw position/index slices for non-GPU meshes.

/// Pre-baked triangle layout — v0 and the two edge vectors used by
/// Möller-Trumbore, in the final (BIVH-reordered) triangle order.
/// Populated by `TriangleMeshSet.bake` after `Bivh.build` has settled
/// the index layout.  Keeping the tri test on this contiguous buffer
/// turns leaf testing into a linear cache-friendly scan instead of
/// chasing indices into the scattered `positions` array.
pub const Tri = extern struct {
    v0: [3]f32,
    e1: [3]f32, // v2 - v0 (matches C# winding)
    e2: [3]f32, // v1 - v0

    /// Möller-Trumbore ray/triangle intersection (f32, no backface cull).
    pub inline fn intersect(self: *const Tri, ray: *const TraceRay) f32 {
        const e1x = self.e1[0];
        const e1y = self.e1[1];
        const e1z = self.e1[2];

        const e2x = self.e2[0];
        const e2y = self.e2[1];
        const e2z = self.e2[2];

        // Recover direction from inverses.
        const ri = 1.0 / ray.ii;
        const rj = 1.0 / ray.ij;
        const rk = 1.0 / ray.ik;

        // P = D x E2
        const px = rj * e2z - rk * e2y;
        const py = rk * e2x - ri * e2z;
        const pz = ri * e2y - rj * e2x;

        const det = e1x * px + e1y * py + e1z * pz;
        if (det > -1e-6 and det < 1e-6) return std.math.floatMax(f32);

        const inv_det = 1.0 / det;

        const tx = ray.x - self.v0[0];
        const ty = ray.y - self.v0[1];
        const tz = ray.z - self.v0[2];

        const u = (tx * px + ty * py + tz * pz) * inv_det;
        if (u < -1e-5 or u > 1.0 + 1e-5) return std.math.floatMax(f32);

        const qx = ty * e1z - tz * e1y;
        const qy = tz * e1x - tx * e1z;
        const qz = tx * e1y - ty * e1x;

        const v = (ri * qx + rj * qy + rk * qz) * inv_det;
        if (v < -1e-5 or u + v > 1.0 + 1e-5) return std.math.floatMax(f32);

        const t = (e2x * qx + e2y * qy + e2z * qz) * inv_det;
        if (t <= 0.0) return std.math.floatMax(f32);

        return t;
    }
};

pub const TriangleMeshSet = struct {
    positions: []const [3]f32,
    indices: []u32, // mutable — BIVH reorders during build
    tri_count: u32,
    perm: ?[]u32 = null, // optional: tracks original triangle index through BIVH reordering
    perm_allocator: ?std.mem.Allocator = null,
    baked_tris: ?[]Tri = null, // populated by bake() after BIVH index reorder
    baked_allocator: ?std.mem.Allocator = null,

    /// Wrap raw position + index arrays.
    pub fn fromArrays(positions: []const [3]f32, indices: []u32) TriangleMeshSet {
        return .{
            .positions = positions,
            .indices = indices,
            .tri_count = @intCast(indices.len / 3),
        };
    }

    /// Wrap raw arrays and track permutation (perm[sorted_idx] = original_idx).
    pub fn fromArraysWithPerm(positions: []const [3]f32, indices: []u32, allocator: std.mem.Allocator) !TriangleMeshSet {
        const tc: u32 = @intCast(indices.len / 3);
        const perm = try allocator.alloc(u32, tc);
        for (0..tc) |i| perm[i] = @intCast(i);
        return .{
            .positions = positions,
            .indices = indices,
            .tri_count = tc,
            .perm = perm,
            .perm_allocator = allocator,
        };
    }

    /// Free per-set allocations (perm tracking + baked triangle buffer).
    pub fn deinit(self: *TriangleMeshSet) void {
        if (self.perm) |p| {
            if (self.perm_allocator) |a| a.free(p);
            self.perm = null;
        }
        if (self.baked_tris) |t| {
            if (self.baked_allocator) |a| a.free(t);
            self.baked_tris = null;
        }
    }

    /// Bake a contiguous `[]Tri` in the current triangle order.
    /// Call after `Bivh.build` so the baked layout follows the reorder.
    pub fn bake(self: *TriangleMeshSet, allocator: std.mem.Allocator) !void {
        if (self.baked_tris) |t| {
            if (self.baked_allocator) |a| a.free(t);
            self.baked_tris = null;
        }
        const tris = try allocator.alloc(Tri, self.tri_count);
        var i: u32 = 0;
        while (i < self.tri_count) : (i += 1) {
            const base = i * 3;
            const a = self.positions[self.indices[base]];
            const b = self.positions[self.indices[base + 1]];
            const c = self.positions[self.indices[base + 2]];
            tris[i] = .{
                .v0 = a,
                .e1 = .{ c[0] - a[0], c[1] - a[1], c[2] - a[2] },
                .e2 = .{ b[0] - a[0], b[1] - a[1], b[2] - a[2] },
            };
        }
        self.baked_tris = tris;
        self.baked_allocator = allocator;
    }

    pub fn count(self: *const TriangleMeshSet) u32 {
        return self.tri_count;
    }

    pub fn getBounds(self: *const TriangleMeshSet, tri_index: u32, out_min: *[3]f32, out_max: *[3]f32, out_center: *[3]f32) void {
        const base = tri_index * 3;
        const idx0 = self.indices[base];
        const idx1 = self.indices[base + 1];
        const idx2 = self.indices[base + 2];

        const a = self.positions[idx0];
        const b = self.positions[idx1];
        const c = self.positions[idx2];

        out_min.* = .{
            @min(a[0], @min(b[0], c[0])),
            @min(a[1], @min(b[1], c[1])),
            @min(a[2], @min(b[2], c[2])),
        };
        out_max.* = .{
            @max(a[0], @max(b[0], c[0])),
            @max(a[1], @max(b[1], c[1])),
            @max(a[2], @max(b[2], c[2])),
        };
        out_center.* = .{
            (a[0] + b[0] + c[0]) / 3.0,
            (a[1] + b[1] + c[1]) / 3.0,
            (a[2] + b[2] + c[2]) / 3.0,
        };
    }

    /// Swap two triangles (3 indices each) in the index buffer.
    pub fn swap(self: *TriangleMeshSet, a: u32, b: u32) void {
        if (a == b) return;
        const ba = a * 3;
        const bb = b * 3;
        var i: u32 = 0;
        while (i < 3) : (i += 1) {
            const tmp = self.indices[ba + i];
            self.indices[ba + i] = self.indices[bb + i];
            self.indices[bb + i] = tmp;
        }
        if (self.perm) |p| {
            const tmp = p[a];
            p[a] = p[b];
            p[b] = tmp;
        }
    }

    /// Moller-Trumbore ray/triangle intersection (double precision, no backface cull).
    /// Legacy index/position path — kept for callers that use a
    /// TriangleMeshSet without baking.  The BIVH traversal prefers
    /// the baked `Tri` buffer.  f32 math, matching `Tri.intersect`.
    pub fn rayIntersectNoCull(self: *const TriangleMeshSet, tri_index: u32, ray: *const TraceRay) f32 {
        const base = tri_index * 3;
        const vert0 = self.positions[self.indices[base]];
        const vert1 = self.positions[self.indices[base + 1]];
        const vert2 = self.positions[self.indices[base + 2]];

        const e1x = vert2[0] - vert0[0];
        const e1y = vert2[1] - vert0[1];
        const e1z = vert2[2] - vert0[2];

        const e2x = vert1[0] - vert0[0];
        const e2y = vert1[1] - vert0[1];
        const e2z = vert1[2] - vert0[2];

        const ri = 1.0 / ray.ii;
        const rj = 1.0 / ray.ij;
        const rk = 1.0 / ray.ik;

        const px = rj * e2z - rk * e2y;
        const py = rk * e2x - ri * e2z;
        const pz = ri * e2y - rj * e2x;

        const det = e1x * px + e1y * py + e1z * pz;
        if (det > -1e-6 and det < 1e-6) return std.math.floatMax(f32);

        const inv_det = 1.0 / det;

        const tx = ray.x - vert0[0];
        const ty = ray.y - vert0[1];
        const tz = ray.z - vert0[2];

        const u = (tx * px + ty * py + tz * pz) * inv_det;
        if (u < -1e-5 or u > 1.0 + 1e-5) return std.math.floatMax(f32);

        const qx = ty * e1z - tz * e1y;
        const qy = tz * e1x - tx * e1z;
        const qz = tx * e1y - ty * e1x;

        const v = (ri * qx + rj * qy + rk * qz) * inv_det;
        if (v < -1e-5 or u + v > 1.0 + 1e-5) return std.math.floatMax(f32);

        const t = (e2x * qx + e2y * qy + e2z * qz) * inv_det;
        if (t <= 0.0) return std.math.floatMax(f32);

        return t;
    }
};

// ── BIVH ─────────────────────────────────────────────────────────────

pub const Bivh = struct {
    const max_depth: u32 = 32;
    const max_prims: u32 = 8;

    nodes: []BihNode,
    node_count: u32 = 0,
    tree_depth: u32 = 0,
    allocator: Allocator,

    const BuildInfo = struct {
        center: [3]f32,
        min: [3]f32,
        max: [3]f32,
    };

    pub fn init(allocator: Allocator) Bivh {
        return .{
            .nodes = &.{},
            .node_count = 0,
            .tree_depth = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Bivh) void {
        if (self.nodes.len > 0) {
            self.allocator.free(self.nodes);
        }
    }

    /// Build the hierarchy from a triangle mesh set.
    /// This reorders the primitives (indices) in-place for spatial locality.
    pub fn build(self: *Bivh, prims: *TriangleMeshSet) !void {
        if (self.nodes.len > 0) {
            self.allocator.free(self.nodes);
        }

        self.node_count = 0;
        self.tree_depth = 0;

        const prim_count = prims.count();
        if (prim_count == 0) {
            self.nodes = &.{};
            return;
        }

        // Compute per-primitive bounds
        var build_infos = try self.allocator.alloc(BuildInfo, prim_count);
        defer self.allocator.free(build_infos);

        var scene_min = [3]f32{ std.math.floatMax(f32), std.math.floatMax(f32), std.math.floatMax(f32) };
        var scene_max = [3]f32{ -std.math.floatMax(f32), -std.math.floatMax(f32), -std.math.floatMax(f32) };

        for (0..prim_count) |i| {
            prims.getBounds(@intCast(i), &build_infos[i].min, &build_infos[i].max, &build_infos[i].center);
            for (0..3) |a| {
                scene_min[a] = @min(scene_min[a], build_infos[i].min[a]);
                scene_max[a] = @max(scene_max[a], build_infos[i].max[a]);
            }
        }

        // Allocate nodes (generous initial size, grows if needed)
        var initial_cap: u32 = @max(1024, prim_count * 2);
        if (initial_cap > 1 << 20) initial_cap = 1 << 20;
        self.nodes = try self.allocator.alloc(BihNode, initial_cap);

        self.buildTree(prims, build_infos, 0, 0, scene_min, scene_max, 0, @as(i32, @intCast(prim_count)) - 1);

        // Bake a contiguous tri buffer in the final (post-reorder) order
        // so leaf testing reads sequential memory instead of chasing the
        // index→position gather.  Uses the BIVH's own allocator.
        try prims.bake(self.allocator);
    }

    fn buildTree(
        self: *Bivh,
        prims: *TriangleMeshSet,
        infos: []BuildInfo,
        current_node: u32,
        depth: u32,
        bounds_min: [3]f32,
        bounds_max: [3]f32,
        start_prim: i32,
        end_prim: i32,
    ) void {
        // Tail-call optimization variables
        var cur_node = current_node;
        var cur_depth = depth;
        var cur_min = bounds_min;
        var cur_max = bounds_max;
        var cur_start = start_prim;
        const cur_end = end_prim;

        while (true) {
            if (self.tree_depth < cur_depth)
                self.tree_depth = cur_depth;

            const prim_count = cur_end - cur_start + 1;
            self.node_count += 1;

            // Grow node array if needed
            if (self.node_count > self.nodes.len) {
                self.nodes = self.allocator.realloc(self.nodes, self.nodes.len * 2) catch return;
            }

            // Leaf node
            if (cur_depth == max_depth or prim_count <= @as(i32, max_prims)) {
                self.nodes[cur_node] = BihNode.initLeaf(cur_start, cur_end, cur_min, cur_max);
                return;
            }

            // Find tight bounds of actual primitives (not parent bounds)
            var box_min = [3]f32{ std.math.floatMax(f32), std.math.floatMax(f32), std.math.floatMax(f32) };
            var box_max = [3]f32{ -std.math.floatMax(f32), -std.math.floatMax(f32), -std.math.floatMax(f32) };

            const s: u32 = @intCast(cur_start);
            const e: u32 = @intCast(cur_end);
            for (s..e + 1) |i| {
                for (0..3) |a| {
                    box_min[a] = @min(box_min[a], infos[i].min[a]);
                    box_max[a] = @max(box_max[a], infos[i].max[a]);
                }
            }

            // Pick longest axis
            const dx = box_max[0] - box_min[0];
            const dy = box_max[1] - box_min[1];
            const dz = box_max[2] - box_min[2];
            const split_axis: Axis = if (dx > dy)
                (if (dx > dz) .x else .z)
            else
                (if (dy > dz) .y else .z);

            const axis_idx = @intFromEnum(split_axis);
            const split_point = (cur_min[axis_idx] + cur_max[axis_idx]) * 0.5;

            // Partition primitives around split point
            var pivot: u32 = s;
            for (s..e + 1) |i| {
                const ii: u32 = @intCast(i);
                if (infos[ii].center[axis_idx] < split_point) {
                    if (ii > pivot) {
                        prims.swap(ii, pivot);
                        const tmp = infos[ii];
                        infos[ii] = infos[pivot];
                        infos[pivot] = tmp;
                    }
                    pivot += 1;
                }
            }

            // Prevent empty partitions
            if (pivot == s or pivot > e)
                pivot = s + @as(u32, @intCast(prim_count)) / 2;

            // Create interior node
            self.nodes[cur_node] = BihNode.initInterior(split_axis, cur_min, cur_max);

            // Compute left child bounds
            var left_min = [3]f32{ std.math.floatMax(f32), std.math.floatMax(f32), std.math.floatMax(f32) };
            var left_max = [3]f32{ -std.math.floatMax(f32), -std.math.floatMax(f32), -std.math.floatMax(f32) };
            for (s..pivot) |i| {
                for (0..3) |a| {
                    left_min[a] = @min(left_min[a], infos[i].min[a]);
                    left_max[a] = @max(left_max[a], infos[i].max[a]);
                }
            }

            // Compute right child bounds
            var right_min = [3]f32{ std.math.floatMax(f32), std.math.floatMax(f32), std.math.floatMax(f32) };
            var right_max = [3]f32{ -std.math.floatMax(f32), -std.math.floatMax(f32), -std.math.floatMax(f32) };
            for (pivot..e + 1) |i| {
                for (0..3) |a| {
                    right_min[a] = @min(right_min[a], infos[i].min[a]);
                    right_max[a] = @max(right_max[a], infos[i].max[a]);
                }
            }

            // Recurse left child (at node_index + 1)
            const left_node = cur_node + 1;
            self.buildTree(prims, infos, left_node, cur_depth + 1, left_min, left_max, cur_start, @as(i32, @intCast(pivot)) - 1);

            // Right child goes at current node_count (after left subtree)
            self.nodes[cur_node].setRightNodeIndex(self.node_count);

            // Tail-recurse into right child
            cur_node = self.node_count;
            cur_depth += 1;
            cur_min = right_min;
            cur_max = right_max;
            cur_start = @intCast(pivot);
            // cur_end stays the same
        }
    }

    /// Trace a single ray against the hierarchy.
    /// Returns true if the ray hit a primitive (result stored in ray).
    pub fn trace(self: *const Bivh, prims: *const TriangleMeshSet, ray: *TraceRay, min_dist: f32, max_dist: f32) bool {
        if (self.node_count == 0) return false;
        return self.intersectTree(prims, ray, 0, min_dist, max_dist);
    }

    fn intersectTree(self: *const Bivh, prims: *const TriangleMeshSet, ray: *TraceRay, start_node: u32, start_min: f32, start_max: f32) bool {
        var node_index = start_node;
        var min_distance = start_min;
        var max_distance = start_max;

        while (true) {
            const node = self.nodes[node_index];
            stat_nodes_visited += 1;

            if (node.isLeaf()) {
                // Test each primitive in the leaf.  Prefer the baked tri
                // buffer — contiguous sequential loads — over the legacy
                // index→position gather path.
                const start: u32 = @intCast(node.startPrim());
                const end: u32 = @intCast(node.end_prim);
                stat_leaves_visited += 1;
                stat_tris_tested += @as(u64, end - start + 1);
                var hit = false;

                if (prims.baked_tris) |tris| {
                    for (start..end + 1) |i| {
                        const dist = tris[i].intersect(ray);
                        if (dist < ray.hit_distance) {
                            ray.hit_distance = dist;
                            ray.hit_primitive = @intCast(i);
                            ray.hit_cell = @intCast(node_index);
                            hit = true;
                        }
                    }
                } else {
                    for (start..end + 1) |i| {
                        const dist = prims.rayIntersectNoCull(@intCast(i), ray);
                        if (dist < ray.hit_distance) {
                            ray.hit_distance = dist;
                            ray.hit_primitive = @intCast(i);
                            ray.hit_cell = @intCast(node_index);
                            hit = true;
                        }
                    }
                }
                return hit;
            }

            // Interior node — test AABB
            if (!ray.intersectsAABB(node.min, node.max))
                return false;

            const left_idx = node_index + 1;
            const right_idx = node.rightNodeIndex();

            const axis = node.splitAxis();
            const axis_int = @intFromEnum(axis);

            const ray_origin: f32 = switch (axis) {
                .x => ray.x,
                .y => ray.y,
                .z => ray.z,
                .none => unreachable,
            };
            const inv_dir: f32 = switch (axis) {
                .x => ray.ii,
                .y => ray.ij,
                .z => ray.ik,
                .none => unreachable,
            };

            var near_idx = left_idx;
            var far_idx = right_idx;

            const left_split: f32 = self.nodes[left_idx].max[axis_int];
            const right_split: f32 = self.nodes[right_idx].min[axis_int];

            var left_plane: f32 = undefined;
            var right_plane: f32 = undefined;

            if (inv_dir >= 0.0) {
                left_plane = (left_split - ray_origin) * inv_dir;
                right_plane = (right_split - ray_origin) * inv_dir;
            } else {
                right_plane = (left_split - ray_origin) * inv_dir;
                left_plane = (right_split - ray_origin) * inv_dir;
                near_idx = right_idx;
                far_idx = left_idx;
            }

            const above_left = min_distance > left_plane;
            const below_right = max_distance < right_plane;

            if (above_left and below_right)
                return false; // ray in empty space between planes

            if (above_left) {
                // Skip near, go to far
                if (min_distance < right_plane) min_distance = right_plane;
                if (max_distance > ray.hit_distance) max_distance = ray.hit_distance;
                node_index = far_idx;
                continue;
            }

            if (below_right) {
                // Only near
                max_distance = left_plane;
                node_index = near_idx;
                continue;
            }

            // Both children — recurse near, then tail-call far
            if (self.intersectTree(prims, ray, near_idx, min_distance, left_plane))
                return true;

            if (ray.hit_distance > right_plane) {
                if (max_distance > ray.hit_distance) max_distance = ray.hit_distance;
                node_index = far_idx;
                min_distance = right_plane;
                continue;
            }

            return false;
        }
    }

    /// Find which leaf node contains a point.  Returns the node index,
    /// or null if the point is outside the tree.
    /// Pass a hint (previous result) to accelerate coherent queries.
    pub fn findLeaf(self: *const Bivh, pos: [3]f32, hint: ?u32) ?u32 {
        // Check hint first (coherent queries)
        if (hint) |h| {
            if (h < self.node_count) {
                const node = self.nodes[h];
                if (pos[0] >= node.min[0] and pos[0] <= node.max[0] and
                    pos[1] >= node.min[1] and pos[1] <= node.max[1] and
                    pos[2] >= node.min[2] and pos[2] <= node.max[2])
                    return h;
            }
        }

        var idx: u32 = 0;
        while (idx < self.node_count) {
            const node = self.nodes[idx];

            // Point outside this node's bounds?
            if (pos[0] < node.min[0] or pos[0] > node.max[0] or
                pos[1] < node.min[1] or pos[1] > node.max[1] or
                pos[2] < node.min[2] or pos[2] > node.max[2])
                return null;

            if (node.isLeaf()) return idx;

            const axis_idx = @intFromEnum(node.splitAxis());
            const split = (node.min[axis_idx] + node.max[axis_idx]) * 0.5;

            if (pos[axis_idx] >= split) {
                idx = node.rightNodeIndex();
            } else {
                idx = idx + 1;
            }
        }

        return null;
    }

    /// Count leaf nodes in the tree.
    pub fn leafCount(self: *const Bivh) u32 {
        var count: u32 = 0;
        for (0..self.node_count) |i| {
            if (self.nodes[i].isLeaf()) count += 1;
        }
        return count;
    }

    pub const AABB = struct { min: [3]f32, max: [3]f32 };

    /// Get the AABB of the root node.
    pub fn rootBounds(self: *const Bivh) ?AABB {
        if (self.node_count == 0) return null;
        const root = self.nodes[0];
        return .{ .min = root.min, .max = root.max };
    }
};

// ── Tests ────────────────────────────────────────────────────────────

test "TraceRay AABB intersection" {
    // Ray along +X from origin should hit unit box at origin
    const ray = TraceRay.make(-2, 0.5, 0.5, 1, 0, 0, 100);
    try std.testing.expect(ray.intersectsAABB(.{ 0, 0, 0 }, .{ 1, 1, 1 }));

    // Ray going away should miss
    const ray2 = TraceRay.make(-2, 0.5, 0.5, -1, 0, 0, 100);
    try std.testing.expect(!ray2.intersectsAABB(.{ 0, 0, 0 }, .{ 1, 1, 1 }));

    // Ray missing above should miss
    const ray3 = TraceRay.make(-2, 5, 0.5, 1, 0, 0, 100);
    try std.testing.expect(!ray3.intersectsAABB(.{ 0, 0, 0 }, .{ 1, 1, 1 }));
}

test "BIVH build and trace triangle" {
    const allocator = std.testing.allocator;

    // Two triangles forming a quad at z=5
    var positions = [_][3]f32{
        .{ -1, -1, 5 },
        .{ 1, -1, 5 },
        .{ 1, 1, 5 },
        .{ -1, 1, 5 },
    };
    var indices = [_]u32{ 0, 1, 2, 0, 2, 3 };

    var prims = TriangleMeshSet.fromArrays(&positions, &indices);
    var tree = Bivh.init(allocator);
    defer tree.deinit();

    try tree.build(&prims);

    try std.testing.expect(tree.node_count > 0);

    // Ray towards quad should hit
    var ray = TraceRay.make(0, 0, 0, 0, 0, 1, 100);
    const hit = tree.trace(&prims, &ray, 0.0001, 100.0);
    try std.testing.expect(hit);
    try std.testing.expect(ray.hit_distance < 6.0);
    try std.testing.expect(ray.hit_distance > 4.0);

    // Ray away from quad should miss
    var ray2 = TraceRay.make(0, 0, 0, 0, 0, -1, 100);
    const miss = tree.trace(&prims, &ray2, 0.0001, 100.0);
    try std.testing.expect(!miss);
}

test "BIVH findLeaf" {
    const allocator = std.testing.allocator;

    // Spread triangles across space to force multiple leaves
    var positions = [_][3]f32{
        .{ -10, -10, -10 }, .{ -9, -10, -10 }, .{ -10, -9, -10 },
        .{ 10, 10, 10 },   .{ 11, 10, 10 },   .{ 10, 11, 10 },
    };
    var indices = [_]u32{ 0, 1, 2, 3, 4, 5 };

    var prims = TriangleMeshSet.fromArrays(&positions, &indices);
    var tree = Bivh.init(allocator);
    defer tree.deinit();

    try tree.build(&prims);

    // Point near first triangle should find a leaf
    const leaf1 = tree.findLeaf(.{ -9.5, -9.5, -10 }, null);
    try std.testing.expect(leaf1 != null);

    // Point far outside should return null
    const outside = tree.findLeaf(.{ 100, 100, 100 }, null);
    try std.testing.expect(outside == null);
}
