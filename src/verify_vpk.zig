const std = @import("std");
const vrf = @import("valve-resource-format");
const math = std.math;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        const stderr = std.io.getStdErr().writer();
        try stderr.writeAll("Usage: verify-vpk <map.vpk>\n");
        try stderr.writeAll("\nDecodes every vmdl_c in a VPK and checks vertex data for corruption.\n");
        std.process.exit(1);
    }

    const vpk_path = args[1];
    const stdout = std.io.getStdOut().writer();

    var pkg = vrf.vpk.Package.init(allocator);
    defer pkg.deinit();
    pkg.readFile(vpk_path) catch |err| {
        try std.io.getStdErr().writer().print("Error reading VPK: {}\n", .{err});
        std.process.exit(1);
    };

    try stdout.print("VPK v{d}, {d} entries\n\n", .{ pkg.version, pkg.entryCount() });

    var total_models: u32 = 0;
    var ok_models: u32 = 0;
    var failed_parse: u32 = 0;
    var failed_mesh: u32 = 0;
    var corrupt_verts: u32 = 0;
    var total_verts: u64 = 0;
    var total_indices: u64 = 0;
    var total_bad_verts: u64 = 0;

    var it = pkg.iterateAll();
    while (it.next()) |entry| {
        if (!std.mem.eql(u8, entry.type_name, "vmdl_c")) continue;
        total_models += 1;

        const entry_path = entry.getFullPath(allocator) catch continue;
        defer allocator.free(entry_path);

        const entry_data = pkg.readEntry(entry) catch |err| {
            try stdout.print("FAIL read {s}: {}\n", .{ entry_path, err });
            failed_parse += 1;
            continue;
        };
        defer allocator.free(entry_data);

        // Parse resource
        var resource = vrf.Resource.init(allocator);
        defer resource.deinit();
        resource.resource_type = .model;
        resource.read(entry_data) catch |err| {
            try stdout.print("FAIL parse {s}: {}\n", .{ entry_path, err });
            failed_parse += 1;
            continue;
        };

        // Find CTRL block with embedded meshes
        const ctrl_block = resource.getBlockByType(.ctrl) orelse {
            // No CTRL = no embedded mesh (physics-only etc), skip silently
            continue;
        };
        const ctrl_raw = switch (ctrl_block.data) {
            .kv3_block => |kb| kb.raw_data orelse continue,
            else => continue,
        };

        var ctrl_doc = vrf.binary_kv3.decode(allocator, ctrl_raw) catch {
            try stdout.print("FAIL CTRL decode {s}\n", .{entry_path});
            failed_parse += 1;
            continue;
        };
        defer ctrl_doc.deinit();
        const ctrl_root = ctrl_doc.root.asObject() orelse continue;

        const em_arr = ctrl_root.getArray("embedded_meshes") orelse continue;
        if (em_arr.count() == 0) continue;

        const em_obj = em_arr.items.items[0].asObject() orelse continue;

        // Build VBIB
        var vbib = vrf.VBIB.readFromEmbeddedMesh(allocator, em_obj, &resource) catch |err| {
            try stdout.print("FAIL VBIB {s}: {}\n", .{ entry_path, err });
            failed_mesh += 1;
            continue;
        };
        defer vbib.deinit();

        if (vbib.vertex_buffers.len == 0 or vbib.index_buffers.len == 0) {
            failed_mesh += 1;
            continue;
        }

        // Check vertex data
        const vb = &vbib.vertex_buffers[0];
        const ib = &vbib.index_buffers[0];
        var bad_verts: u64 = 0;
        var min_pos = [3]f32{ math.inf(f32), math.inf(f32), math.inf(f32) };
        var max_pos = [3]f32{ -math.inf(f32), -math.inf(f32), -math.inf(f32) };

        for (0..vb.element_count) |i| {
            const pos = vb.getPosition(@intCast(i));
            var bad = false;
            for (pos) |v| {
                if (math.isNan(v) or math.isInf(v) or @abs(v) > 100_000.0) {
                    bad = true;
                    break;
                }
            }
            if (bad) {
                bad_verts += 1;
                if (bad_verts <= 3) {
                    try stdout.print("  BAD vert[{d}] pos=({d:.2},{d:.2},{d:.2}) in {s}\n", .{
                        i, pos[0], pos[1], pos[2], entry_path,
                    });
                }
            } else {
                for (0..3) |c| {
                    min_pos[c] = @min(min_pos[c], pos[c]);
                    max_pos[c] = @max(max_pos[c], pos[c]);
                }
            }
        }

        // Check index data
        var bad_indices: u64 = 0;
        for (0..ib.element_count) |i| {
            const idx = ib.getIndex(@intCast(i));
            if (idx >= vb.element_count) {
                bad_indices += 1;
            }
        }

        total_verts += vb.element_count;
        total_indices += ib.element_count;
        total_bad_verts += bad_verts;

        if (bad_verts > 0 or bad_indices > 0) {
            corrupt_verts += 1;
            try stdout.print("CORRUPT {s}: {d}/{d} bad verts, {d}/{d} bad indices\n", .{
                entry_path, bad_verts, vb.element_count, bad_indices, ib.element_count,
            });
        } else {
            ok_models += 1;
            // Print bounds for interesting models (>100 verts)
            if (vb.element_count > 100) {
                try stdout.print("  OK {s}: {d} verts, {d} indices, bounds=({d:.0}..{d:.0}, {d:.0}..{d:.0}, {d:.0}..{d:.0})\n", .{
                    entry_path,
                    vb.element_count,
                    ib.element_count,
                    min_pos[0],
                    max_pos[0],
                    min_pos[1],
                    max_pos[1],
                    min_pos[2],
                    max_pos[2],
                });
            }
        }
    }

    try stdout.print("\n═══ Verification Summary ═══\n", .{});
    try stdout.print("  Total vmdl_c:     {d}\n", .{total_models});
    try stdout.print("  OK (mesh valid):  {d}\n", .{ok_models});
    try stdout.print("  Failed parse:     {d}\n", .{failed_parse});
    try stdout.print("  Failed mesh:      {d}\n", .{failed_mesh});
    try stdout.print("  Corrupt verts:    {d}\n", .{corrupt_verts});
    try stdout.print("  Total vertices:   {d} ({d} bad = {d:.1}%)\n", .{
        total_verts,
        total_bad_verts,
        if (total_verts > 0) @as(f64, @floatFromInt(total_bad_verts)) / @as(f64, @floatFromInt(total_verts)) * 100.0 else 0.0,
    });
    try stdout.print("  Total indices:    {d}\n", .{total_indices});
    try stdout.print("  ═══════════════\n", .{});
}
