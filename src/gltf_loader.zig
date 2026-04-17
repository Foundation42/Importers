// glTF geometry loader for the PVS baker.
//
// Mirrors matryoshka/src/gltf_loader.zig's scene-graph walking: each
// (node, primitive) pair becomes one SubmeshRange with node world-transform
// applied to positions. This keeps the baker's submesh indices aligned with
// Matryoshka's LEAF_MESH indices — the contract that lets a baked bit map
// directly to a runtime BVH leaf.

const std = @import("std");
const Allocator = std.mem.Allocator;
const baker_types = @import("baker_types.zig");
const SubmeshRange = baker_types.SubmeshRange;
const ModelRange = baker_types.ModelRange;

const cgltf = @cImport({
    @cInclude("cgltf.h");
});

const Vec3 = [3]f32;

/// Load a glTF/GLB file into the baker's flat triangle soup.
/// Allocates model_name buffers that the caller owns (freed via ModelRange.name).
pub fn loadGltf(
    allocator: Allocator,
    path: []const u8,
    positions: *std.ArrayList(Vec3),
    indices: *std.ArrayList(u32),
    model_ranges: *std.ArrayList(ModelRange),
    submesh_ranges: *std.ArrayList(SubmeshRange),
) !void {
    const cpath = try allocator.dupeZ(u8, path);
    defer allocator.free(cpath);

    var opts = std.mem.zeroes(cgltf.cgltf_options);
    var data: ?*cgltf.cgltf_data = null;
    if (cgltf.cgltf_parse_file(&opts, cpath.ptr, &data) != cgltf.cgltf_result_success)
        return error.GltfParseFailed;
    defer cgltf.cgltf_free(data);

    const gltf = data.?;
    if (cgltf.cgltf_load_buffers(&opts, gltf, cpath.ptr) != cgltf.cgltf_result_success)
        return error.GltfBufferLoadFailed;

    // One "model" per node-with-mesh — keeps the tri_start/tri_end bookkeeping
    // equivalent to how VPK models work (one model = one contiguous tri range).
    var submesh_idx_for_model: u32 = 0;
    _ = &submesh_idx_for_model; // per-model counter, reset each iteration

    for (0..gltf.nodes_count) |ni| {
        const node = &gltf.nodes[ni];
        const mesh_ptr = node.mesh orelse continue;

        var m: [16]f32 = undefined;
        cgltf.cgltf_node_transform_world(node, &m);

        // Build a stable model name. Prefer the node name, fall back to an index.
        const name: []u8 = blk: {
            if (node.name) |n_ptr| {
                const slice = std.mem.span(@as([*c]const u8, @ptrCast(n_ptr)));
                if (slice.len > 0) break :blk try allocator.dupe(u8, slice);
            }
            break :blk try std.fmt.allocPrint(allocator, "gltf_node_{d}", .{ni});
        };
        errdefer allocator.free(name);

        const model_tri_start: u32 = @intCast(indices.items.len / 3);
        var local_submesh_idx: u32 = 0;

        for (0..mesh_ptr.*.primitives_count) |pi| {
            const prim = &mesh_ptr.*.primitives[pi];
            if (prim.type != cgltf.cgltf_primitive_type_triangles) continue;

            var pos_acc: ?*const cgltf.cgltf_accessor = null;
            for (0..prim.attributes_count) |ai| {
                const attr = &prim.attributes[ai];
                if (attr.type == cgltf.cgltf_attribute_type_position) pos_acc = attr.data;
            }
            const positions_acc = pos_acc orelse continue;
            const vert_count = positions_acc.count;
            if (vert_count == 0) continue;

            // Base vertex offset: all primitive vertices appended to the global
            // positions list, then indices offset by this base.
            const base_vert: u32 = @intCast(positions.items.len);

            try positions.ensureUnusedCapacity(vert_count);
            for (0..vert_count) |vi| {
                var pos: [3]f32 = .{ 0, 0, 0 };
                _ = cgltf.cgltf_accessor_read_float(positions_acc, vi, &pos, 3);
                const px = m[0] * pos[0] + m[4] * pos[1] + m[8] * pos[2] + m[12];
                const py = m[1] * pos[0] + m[5] * pos[1] + m[9] * pos[2] + m[13];
                const pz = m[2] * pos[0] + m[6] * pos[1] + m[10] * pos[2] + m[14];
                positions.appendAssumeCapacity(.{ px, py, pz });
            }

            const tri_before: u32 = @intCast(indices.items.len / 3);

            if (prim.indices) |idx_acc| {
                const n = idx_acc.*.count;
                try indices.ensureUnusedCapacity(n);
                var i: usize = 0;
                while (i < n) : (i += 1) {
                    const idx = cgltf.cgltf_accessor_read_index(idx_acc, i);
                    indices.appendAssumeCapacity(base_vert + @as(u32, @intCast(idx)));
                }
            } else {
                try indices.ensureUnusedCapacity(vert_count);
                for (0..vert_count) |i| {
                    indices.appendAssumeCapacity(base_vert + @as(u32, @intCast(i)));
                }
            }

            const tri_after: u32 = @intCast(indices.items.len / 3);
            if (tri_after > tri_before) {
                try submesh_ranges.append(.{
                    .tri_start = tri_before,
                    .tri_end = tri_after,
                    .model_name = name, // borrowed — lives as long as the model_ranges entry
                    .submesh_idx = local_submesh_idx,
                });
                local_submesh_idx += 1;
            }
        }

        const model_tri_end: u32 = @intCast(indices.items.len / 3);
        if (model_tri_end > model_tri_start) {
            try model_ranges.append(.{
                .tri_start = model_tri_start,
                .tri_end = model_tri_end,
                .name = name,
            });
        } else {
            allocator.free(name);
        }
    }
}
