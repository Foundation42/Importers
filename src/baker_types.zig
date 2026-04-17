// Shared types for the PVS baker. Kept in their own module so geometry
// loaders (glTF, VPK) can reference the same concrete types without creating
// import cycles back to pvs_baker.zig.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Vec3 = [3]f32;

/// Per-draw-call triangle range inside the global flat triangle array.
/// Sub-mesh granularity prevents aggregate world geometry from all sharing
/// a single PVS bit.
pub const SubmeshRange = struct {
    tri_start: u32,
    tri_end: u32,
    model_name: []const u8, // borrowed (lives as long as the caller's name buffer)
    submesh_idx: u32,
};

/// Per-model triangle range — one contiguous span per source asset (.vmdl_c
/// or glTF node).
pub const ModelRange = struct {
    tri_start: u32,
    tri_end: u32,
    name: []const u8,
};

// ── Spatial split (matches matryoshka/src/source2_loader.zig) ──────────
//
// Contract: triangles in [range.tri_start, range.tri_end) are partitioned
// into `cell_size`-sized bins by centroid. Within each range, indices are
// reordered in-place so each bin's triangles are contiguous, then one new
// SubmeshRange is emitted per non-empty bin. After all ranges are processed,
// the output list is Morton-sorted by bin centroid.
//
// This must stay bit-identical to Matryoshka's rule: same threshold, same
// centroid rule `floor((c - aabb_min) / cell_size)`, same bin order
// `x + y*nx + z*nx*ny`, same Morton quantizer (10 bits per axis at 200m
// span). Any divergence invalidates the runtime bit → LEAF_MESH mapping.

fn triCentroid(positions: []const Vec3, indices: []const u32, tri: u32) Vec3 {
    const a = indices[tri * 3];
    const b = indices[tri * 3 + 1];
    const c = indices[tri * 3 + 2];
    return .{
        (positions[a][0] + positions[b][0] + positions[c][0]) / 3.0,
        (positions[a][1] + positions[b][1] + positions[c][1]) / 3.0,
        (positions[a][2] + positions[b][2] + positions[c][2]) / 3.0,
    };
}

fn triAabb(positions: []const Vec3, indices: []const u32, tri_start: u32, tri_end: u32) struct { min: Vec3, max: Vec3 } {
    var bmin = Vec3{ std.math.inf(f32), std.math.inf(f32), std.math.inf(f32) };
    var bmax = Vec3{ -std.math.inf(f32), -std.math.inf(f32), -std.math.inf(f32) };
    var t: u32 = tri_start;
    while (t < tri_end) : (t += 1) {
        for (0..3) |k| {
            const vi = indices[t * 3 + k];
            const p = positions[vi];
            for (0..3) |a| {
                bmin[a] = @min(bmin[a], p[a]);
                bmax[a] = @max(bmax[a], p[a]);
            }
        }
    }
    return .{ .min = bmin, .max = bmax };
}

/// Run the 4m-bin spatial split over all submesh ranges. Reorders triangle
/// indices in-place and returns a new owned list of ranges (caller frees).
pub fn spatialSplitAll(
    allocator: Allocator,
    positions: []const Vec3,
    indices: []u32,
    in_ranges: []const SubmeshRange,
    cell_size: f32,
) !std.ArrayList(SubmeshRange) {
    var out = std.ArrayList(SubmeshRange).init(allocator);
    errdefer out.deinit();

    for (in_ranges) |range| {
        const tri_count = range.tri_end - range.tri_start;
        if (tri_count == 0) continue;

        const aabb = triAabb(positions, indices, range.tri_start, range.tri_end);
        const ex = aabb.max[0] - aabb.min[0];
        const ey = aabb.max[1] - aabb.min[1];
        const ez = aabb.max[2] - aabb.min[2];
        const max_extent = @max(ex, @max(ey, ez));

        if (max_extent <= cell_size or tri_count < 2) {
            try out.append(range);
            continue;
        }

        const nx: u32 = @max(1, @as(u32, @intFromFloat(@ceil(ex / cell_size))));
        const ny: u32 = @max(1, @as(u32, @intFromFloat(@ceil(ey / cell_size))));
        const nz: u32 = @max(1, @as(u32, @intFromFloat(@ceil(ez / cell_size))));
        const total_bins = nx * ny * nz;

        var bins = try allocator.alloc(std.ArrayList(u32), total_bins);
        defer {
            for (bins) |*b| b.deinit();
            allocator.free(bins);
        }
        for (bins) |*b| b.* = std.ArrayList(u32).init(allocator);

        var t: u32 = range.tri_start;
        while (t < range.tri_end) : (t += 1) {
            const c = triCentroid(positions, indices, t);
            const bx = @min(nx - 1, @as(u32, @intFromFloat(@max(0.0, (c[0] - aabb.min[0]) / cell_size))));
            const by = @min(ny - 1, @as(u32, @intFromFloat(@max(0.0, (c[1] - aabb.min[1]) / cell_size))));
            const bz = @min(nz - 1, @as(u32, @intFromFloat(@max(0.0, (c[2] - aabb.min[2]) / cell_size))));
            try bins[bx + by * nx + bz * nx * ny].append(t);
        }

        // Reorder triangles in-place within this range so each bin is contiguous.
        // Copy original (i0,i1,i2) triples into a temp, then write back bin by bin.
        const tri_bytes = tri_count * 3;
        const tmp = try allocator.alloc(u32, tri_bytes);
        defer allocator.free(tmp);
        @memcpy(tmp, indices[range.tri_start * 3 .. range.tri_end * 3]);

        var cursor = range.tri_start;
        for (bins) |bin| {
            if (bin.items.len == 0) continue;
            const bin_start = cursor;
            for (bin.items) |src_tri| {
                const src_off = (src_tri - range.tri_start) * 3;
                const dst_off = cursor * 3;
                indices[dst_off + 0] = tmp[src_off + 0];
                indices[dst_off + 1] = tmp[src_off + 1];
                indices[dst_off + 2] = tmp[src_off + 2];
                cursor += 1;
            }
            try out.append(.{
                .tri_start = bin_start,
                .tri_end = cursor,
                .model_name = range.model_name,
                .submesh_idx = @intCast(out.items.len),
            });
        }
    }

    return out;
}

// ── Morton sort (matches matryoshka) ────────────────────────────────────

fn expandBits(v: u32) u32 {
    var x = v & 0x3FF;
    x = (x | (x << 16)) & 0x030000FF;
    x = (x | (x << 8)) & 0x0300F00F;
    x = (x | (x << 4)) & 0x030C30C3;
    x = (x | (x << 2)) & 0x09249249;
    return x;
}

/// Morton code from a range's centroid, quantized to a 1024³ grid over
/// [-100m, +100m]. Must match matryoshka/src/source2_loader.zig:mortonCode.
pub fn rangeMortonCode(positions: []const Vec3, indices: []const u32, range: SubmeshRange) u32 {
    const aabb = triAabb(positions, indices, range.tri_start, range.tri_end);
    const scale: f32 = 1023.0 / 200.0;
    const cx = (aabb.min[0] + aabb.max[0]) * 0.5;
    const cy = (aabb.min[1] + aabb.max[1]) * 0.5;
    const cz = (aabb.min[2] + aabb.max[2]) * 0.5;
    const ix: u32 = @intFromFloat(std.math.clamp((cx + 100.0) * scale, 0, 1023));
    const iy: u32 = @intFromFloat(std.math.clamp((cy + 100.0) * scale, 0, 1023));
    const iz: u32 = @intFromFloat(std.math.clamp((cz + 100.0) * scale, 0, 1023));
    return expandBits(ix) | (expandBits(iy) << 1) | (expandBits(iz) << 2);
}

