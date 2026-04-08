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
        try stderr.writeAll("Usage: verify-vpk <map.vpk> [content_dir.vpk]\n");
        try stderr.writeAll("\nDecodes every vmdl_c in a map VPK and checks:\n");
        try stderr.writeAll("  - Vertex data for NaN/garbage\n");
        try stderr.writeAll("  - Index buffer bounds\n");
        try stderr.writeAll("  - Material references resolve in content VPK\n");
        try stderr.writeAll("  - Texture decoding (vtex_c header + pixel data)\n");
        std.process.exit(1);
    }

    const vpk_path = args[1];
    const content_vpk_path: ?[]const u8 = if (args.len >= 3) args[2] else null;
    const stdout = std.io.getStdOut().writer();

    // Open map VPK
    var map_pkg = vrf.vpk.Package.init(allocator);
    defer map_pkg.deinit();
    map_pkg.readFile(vpk_path) catch |err| {
        try std.io.getStdErr().writer().print("Error reading map VPK: {}\n", .{err});
        std.process.exit(1);
    };
    try stdout.print("Map VPK v{d}, {d} entries\n", .{ map_pkg.version, map_pkg.entryCount() });

    // Open content VPK if provided
    var content_pkg: ?vrf.vpk.Package = null;
    defer if (content_pkg) |*cp| cp.deinit();
    if (content_vpk_path) |cp| {
        var pkg = vrf.vpk.Package.init(allocator);
        pkg.readFile(cp) catch |err| {
            try stdout.print("Warning: could not open content VPK: {}\n", .{err});
        };
        if (pkg.entryCount() > 0) {
            try stdout.print("Content VPK: {d} entries\n", .{pkg.entryCount()});
            content_pkg = pkg;
        } else {
            pkg.deinit();
        }
    }

    try stdout.writeAll("\n");

    // Counters
    var mesh_total: u32 = 0;
    var mesh_ok: u32 = 0;
    var mesh_physics: u32 = 0;
    var mesh_corrupt: u32 = 0;
    var total_verts: u64 = 0;
    var total_indices: u64 = 0;
    var total_bad_verts: u64 = 0;

    var mat_total: u32 = 0;
    var mat_found: u32 = 0;
    var mat_not_found: u32 = 0;
    var mat_parse_ok: u32 = 0;
    var mat_parse_fail: u32 = 0;

    var tex_total: u32 = 0;
    var tex_found: u32 = 0;
    var tex_not_found: u32 = 0;
    var tex_decode_ok: u32 = 0;
    var tex_decode_fail: u32 = 0;

    // Track unique materials and textures to avoid re-checking
    var checked_mats = std.StringHashMap(bool).init(allocator);
    defer {
        var kit = checked_mats.keyIterator();
        while (kit.next()) |k| allocator.free(k.*);
        checked_mats.deinit();
    }
    var checked_textures = std.StringHashMap(bool).init(allocator);
    defer {
        var kit = checked_textures.keyIterator();
        while (kit.next()) |k| allocator.free(k.*);
        checked_textures.deinit();
    }

    var it = map_pkg.iterateAll();
    while (it.next()) |entry| {
        if (!std.mem.eql(u8, entry.type_name, "vmdl_c")) continue;
        mesh_total += 1;

        const entry_path = entry.getFullPath(allocator) catch continue;
        defer allocator.free(entry_path);

        const entry_data = map_pkg.readEntry(entry) catch continue;
        defer allocator.free(entry_data);

        // Parse resource
        var resource = vrf.Resource.init(allocator);
        defer resource.deinit();
        resource.resource_type = .model;
        resource.read(entry_data) catch continue;

        // Check CTRL for embedded meshes
        const ctrl_block = resource.getBlockByType(.ctrl) orelse {
            mesh_physics += 1;
            continue;
        };
        const ctrl_raw = switch (ctrl_block.data) {
            .kv3_block => |kb| kb.raw_data orelse {
                mesh_physics += 1;
                continue;
            },
            else => {
                mesh_physics += 1;
                continue;
            },
        };

        var ctrl_doc = vrf.binary_kv3.decode(allocator, ctrl_raw) catch {
            mesh_physics += 1;
            continue;
        };
        defer ctrl_doc.deinit();
        const ctrl_root = ctrl_doc.root.asObject() orelse {
            mesh_physics += 1;
            continue;
        };

        const em_arr = ctrl_root.getArray("embedded_meshes") orelse {
            mesh_physics += 1;
            continue;
        };
        if (em_arr.count() == 0) {
            mesh_physics += 1;
            continue;
        }

        const em_obj = em_arr.items.items[0].asObject() orelse continue;

        // Build VBIB
        var vbib = vrf.VBIB.readFromEmbeddedMesh(allocator, em_obj, &resource) catch continue;
        defer vbib.deinit();

        if (vbib.vertex_buffers.len == 0 or vbib.index_buffers.len == 0) continue;

        // Check vertex data
        const vb = &vbib.vertex_buffers[0];
        const ib = &vbib.index_buffers[0];
        var bad_verts: u64 = 0;

        for (0..vb.element_count) |i| {
            const pos = vb.getPosition(@intCast(i));
            for (pos) |v| {
                if (math.isNan(v) or math.isInf(v) or @abs(v) > 100_000.0) {
                    bad_verts += 1;
                    break;
                }
            }
        }

        var bad_indices: u64 = 0;
        for (0..ib.element_count) |i| {
            if (ib.getIndex(@intCast(i)) >= vb.element_count) bad_indices += 1;
        }

        total_verts += vb.element_count;
        total_indices += ib.element_count;
        total_bad_verts += bad_verts;

        if (bad_verts > 0 or bad_indices > 0) {
            mesh_corrupt += 1;
            try stdout.print("MESH CORRUPT {s}: {d}/{d} bad verts, {d}/{d} bad indices\n", .{
                entry_path, bad_verts, vb.element_count, bad_indices, ib.element_count,
            });
        } else {
            mesh_ok += 1;
        }

        // Check materials from MDAT draw calls
        const data_block_index = if (em_obj.get("m_nDataBlock")) |v| v.asU32() else null;
        if (data_block_index) |dbi| {
            if (resource.getBlockByIndex(@intCast(dbi))) |mdat_block| {
                const mdat_raw = switch (mdat_block.data) {
                    .data_block => |db| db.raw_data,
                    else => null,
                };
                if (mdat_raw) |raw| {
                    var mdat_doc = vrf.binary_kv3.decode(allocator, raw) catch null;
                    if (mdat_doc) |*doc| {
                        defer doc.deinit();
                        if (doc.root.asObject()) |mdat_root| {
                            if (mdat_root.getArray("m_sceneObjects")) |so_arr| {
                                for (so_arr.items.items) |*so_val| {
                                    const so_obj = so_val.asObject() orelse continue;
                                    if (so_obj.getArray("m_drawCalls")) |dc_arr| {
                                        for (dc_arr.items.items) |*dc_val| {
                                            const dc_obj = dc_val.asObject() orelse continue;
                                            const mat_path = dc_obj.getStringProperty("m_material") orelse continue;
                                            if (mat_path.len == 0) continue;

                                            // Skip if already checked
                                            if (checked_mats.contains(mat_path)) continue;
                                            const mat_key = allocator.dupe(u8, mat_path) catch continue;
                                            checked_mats.put(mat_key, true) catch continue;

                                            mat_total += 1;
                                            checkMaterial(mat_path, &content_pkg, &map_pkg, allocator, stdout, &mat_found, &mat_not_found, &mat_parse_ok, &mat_parse_fail, &tex_total, &tex_found, &tex_not_found, &tex_decode_ok, &tex_decode_fail, &checked_textures) catch {};
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // Summary
    try stdout.print("\n═══ Verification Summary ═══\n", .{});
    try stdout.print("  ─── Meshes ───\n", .{});
    try stdout.print("  Total vmdl_c:     {d}\n", .{mesh_total});
    try stdout.print("  OK:               {d}\n", .{mesh_ok});
    try stdout.print("  Physics-only:     {d}\n", .{mesh_physics});
    try stdout.print("  Corrupt:          {d}\n", .{mesh_corrupt});
    try stdout.print("  Vertices:         {d} ({d} bad)\n", .{ total_verts, total_bad_verts });
    try stdout.print("  Indices:          {d}\n", .{total_indices});
    try stdout.print("  ─── Materials ───\n", .{});
    try stdout.print("  Unique materials: {d}\n", .{mat_total});
    try stdout.print("  Found in VPK:    {d}\n", .{mat_found});
    try stdout.print("  Not found:        {d}\n", .{mat_not_found});
    try stdout.print("  Parse OK:         {d}\n", .{mat_parse_ok});
    try stdout.print("  Parse fail:       {d}\n", .{mat_parse_fail});
    try stdout.print("  ─── Textures ───\n", .{});
    try stdout.print("  Unique textures:  {d}\n", .{tex_total});
    try stdout.print("  Found in VPK:    {d}\n", .{tex_found});
    try stdout.print("  Not found:        {d}\n", .{tex_not_found});
    try stdout.print("  Decode OK:        {d}\n", .{tex_decode_ok});
    try stdout.print("  Decode fail:      {d}\n", .{tex_decode_fail});
    try stdout.print("  ═══════════════\n", .{});
}

fn checkMaterial(
    mat_path: []const u8,
    content_pkg: *?vrf.vpk.Package,
    map_pkg: *vrf.vpk.Package,
    allocator: std.mem.Allocator,
    stdout: anytype,
    mat_found: *u32,
    mat_not_found: *u32,
    mat_parse_ok: *u32,
    mat_parse_fail: *u32,
    tex_total: *u32,
    tex_found: *u32,
    tex_not_found: *u32,
    tex_decode_ok: *u32,
    tex_decode_fail: *u32,
    checked_textures: *std.StringHashMap(bool),
) !void {
    // Try to find material with _c suffix
    var path_buf: [512]u8 = undefined;
    const compiled_path = std.fmt.bufPrint(&path_buf, "{s}_c", .{mat_path}) catch return;

    const mat_data = findInVPKs(compiled_path, content_pkg, map_pkg, allocator) orelse
        findInVPKs(mat_path, content_pkg, map_pkg, allocator) orelse {
        mat_not_found.* += 1;
        try stdout.print("  MAT NOT FOUND: {s}\n", .{mat_path});
        return;
    };
    defer allocator.free(mat_data);
    mat_found.* += 1;

    // Parse material resource
    var resource = vrf.Resource.init(allocator);
    defer resource.deinit();
    resource.resource_type = .material;
    resource.read(mat_data) catch {
        mat_parse_fail.* += 1;
        try stdout.print("  MAT PARSE FAIL: {s}\n", .{mat_path});
        return;
    };

    // Decode KV3 DATA block
    const data_block = resource.dataBlock() orelse {
        mat_parse_fail.* += 1;
        return;
    };
    const raw = switch (data_block.data) {
        .data_block => |db| db.raw_data orelse {
            mat_parse_fail.* += 1;
            return;
        },
        else => {
            mat_parse_fail.* += 1;
            return;
        },
    };

    var doc = vrf.binary_kv3.decode(allocator, raw) catch {
        mat_parse_fail.* += 1;
        try stdout.print("  MAT KV3 FAIL: {s}\n", .{mat_path});
        return;
    };
    defer doc.deinit();

    const root = doc.root.asObject() orelse {
        mat_parse_fail.* += 1;
        return;
    };

    var mat = vrf.Material.init(allocator);
    defer mat.deinit();
    mat.readFromKV3(root) catch {
        mat_parse_fail.* += 1;
        return;
    };
    mat_parse_ok.* += 1;

    // Check each texture param
    const tex_keys = [_][]const u8{ "g_tColor", "g_tColor1", "g_tColor2", "g_tDiffuse", "g_tNormal", "g_tNormal1", "g_tBumpMap" };
    for (tex_keys) |key| {
        if (mat.getTexture(key)) |tex_path| {
            if (checked_textures.contains(tex_path)) continue;
            const tex_key = allocator.dupe(u8, tex_path) catch continue;
            checked_textures.put(tex_key, true) catch continue;

            tex_total.* += 1;

            // Try to find and decode texture
            var tex_path_buf: [512]u8 = undefined;
            const tex_compiled = std.fmt.bufPrint(&tex_path_buf, "{s}_c", .{tex_path}) catch continue;

            const tex_data = findInVPKs(tex_compiled, content_pkg, map_pkg, allocator) orelse
                findInVPKs(tex_path, content_pkg, map_pkg, allocator) orelse {
                tex_not_found.* += 1;
                try stdout.print("  TEX NOT FOUND: {s}\n", .{tex_path});
                continue;
            };
            defer allocator.free(tex_data);
            tex_found.* += 1;

            // Parse texture resource and try to read header
            var tex_resource = vrf.Resource.init(allocator);
            defer tex_resource.deinit();
            tex_resource.resource_type = .texture;
            tex_resource.read(tex_data) catch {
                tex_decode_fail.* += 1;
                try stdout.print("  TEX PARSE FAIL: {s}\n", .{tex_path});
                continue;
            };

            const tex_data_block = tex_resource.dataBlock() orelse {
                tex_decode_fail.* += 1;
                continue;
            };

            // Header is in DATA block; pixel data starts right after it
            const tex_header = tex_data[tex_data_block.offset..][0..tex_data_block.size];
            const tex_pixel_start = tex_data_block.offset + tex_data_block.size;
            const tex_pixels: ?[]const u8 = if (tex_pixel_start < tex_data.len) tex_data[tex_pixel_start..] else null;

            var tex = vrf.Texture.init(allocator);
            defer tex.deinit();
            tex.readHeader(tex_header) catch {
                tex_decode_fail.* += 1;
                try stdout.print("  TEX HEADER FAIL: {s}\n", .{tex_path});
                continue;
            };

            tex.data = tex_pixels;

            // Try to decode to RGBA
            const rgba = tex.decodeRGBA() catch |err| {
                tex_decode_fail.* += 1;
                try stdout.print("  TEX DECODE FAIL: {s} ({d}x{d} {s}): {}\n", .{
                    tex_path, tex.width, tex.height, @tagName(tex.format), err,
                });
                continue;
            };
            allocator.free(rgba);
            tex_decode_ok.* += 1;
        }
    }
}

fn findInVPKs(path: []const u8, content_pkg: *?vrf.vpk.Package, map_pkg: *vrf.vpk.Package, _: std.mem.Allocator) ?[]const u8 {
    // Try content VPK first
    if (content_pkg.*) |*cp| {
        if (cp.findEntry(path)) |entry| {
            return cp.readEntry(entry) catch null;
        }
    }
    // Try map VPK
    if (map_pkg.findEntry(path)) |entry| {
        return map_pkg.readEntry(entry) catch null;
    }
    return null;
}
