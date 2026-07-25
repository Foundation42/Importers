const std = @import("std");
const vrf = @import("valve-resource-format");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        const stderr = std.io.getStdErr().writer();
        try stderr.writeAll("Usage: dump-world <map.vpk> [resource-path | submeshes]\n");
        try stderr.writeAll("\nExtracts and parses Source 2 world/model data from a map VPK.\n");
        try stderr.writeAll("  (no second arg)     list all entries\n");
        try stderr.writeAll("  <resource-path>     dump that resource\n");
        try stderr.writeAll("  submeshes           tally draw-call (sub-mesh) counts across all vmdl_c\n");
        std.process.exit(1);
    }

    const vpk_path = args[1];
    const resource_path = if (args.len >= 3) args[2] else null;
    const stdout = std.io.getStdOut().writer();

    if (resource_path != null and std.mem.eql(u8, resource_path.?, "submeshes")) {
        try submeshStats(allocator, vpk_path, stdout);
        return;
    }

    if (resource_path != null and std.mem.eql(u8, resource_path.?, "transforms")) {
        try transformStats(allocator, vpk_path, stdout);
        return;
    }

    if (resource_path != null and std.mem.eql(u8, resource_path.?, "entities")) {
        try entityStats(allocator, vpk_path, stdout);
        return;
    }

    if (resource_path != null and std.mem.eql(u8, resource_path.?, "texavg")) {
        if (args.len < 4) {
            try std.io.getStdErr().writer().writeAll("Usage: dump-world <content.vpk> texavg <vtex-path>\n");
            std.process.exit(1);
        }
        try texAvg(allocator, vpk_path, args[3], stdout);
        return;
    }

    if (resource_path != null and std.mem.eql(u8, resource_path.?, "vbuf")) {
        if (args.len < 4) {
            try std.io.getStdErr().writer().writeAll("Usage: dump-world <map.vpk> vbuf <model-path>\n");
            std.process.exit(1);
        }
        try vbufDump(allocator, vpk_path, args[3], stdout);
        return;
    }

    if (resource_path != null and std.mem.eql(u8, resource_path.?, "list")) {
        var pkg2 = vrf.vpk.Package.init(allocator);
        defer pkg2.deinit();
        pkg2.readFile(vpk_path) catch |err| {
            try std.io.getStdErr().writer().print("Error reading VPK: {}\n", .{err});
            std.process.exit(1);
        };
        var it2 = pkg2.iterateAll();
        while (it2.next()) |entry| {
            const p = try entry.getFullPath(allocator);
            defer allocator.free(p);
            try stdout.print("{s}\t{d}\n", .{ p, entry.totalLength() });
        }
        return;
    }

    // Open VPK
    var pkg = vrf.vpk.Package.init(allocator);
    defer pkg.deinit();

    pkg.readFile(vpk_path) catch |err| {
        try std.io.getStdErr().writer().print("Error reading VPK: {}\n", .{err});
        std.process.exit(1);
    };

    try stdout.print("VPK v{d}, {d} entries\n\n", .{ pkg.version, pkg.entryCount() });

    if (resource_path) |rpath| {
        // Extract and parse a specific resource
        const entry = pkg.findEntry(rpath) orelse {
            try stdout.print("Entry not found: {s}\n", .{rpath});
            std.process.exit(1);
        };

        try stdout.print("Found: {s} ({d} bytes, archive={d})\n", .{ rpath, entry.totalLength(), entry.archive_index });

        const data = try pkg.readEntry(entry);
        defer allocator.free(data);

        // Parse as a Source 2 resource
        var resource = vrf.Resource.init(allocator);
        defer resource.deinit();

        resource.read(data) catch |err| {
            try stdout.print("Error parsing resource: {}\n", .{err});

            // Dump raw header bytes for debugging
            try stdout.writeAll("\nFirst 64 bytes (hex):\n");
            for (data[0..@min(64, data.len)], 0..) |b, i| {
                try stdout.print("{x:0>2} ", .{b});
                if ((i + 1) % 16 == 0) try stdout.writeAll("\n");
            }
            try stdout.writeAll("\n");
            std.process.exit(1);
        };

        try stdout.print("Header version: {d}\n", .{resource.header_version});
        try stdout.print("Version: {d}\n", .{resource.version});
        if (resource.resource_type.extension()) |ext| {
            try stdout.print("Resource type: .{s}\n", .{ext});
        }

        try stdout.print("Blocks ({d}):\n", .{resource.blocks.items.len});
        for (resource.blocks.items, 0..) |blk, bi| {
            const tag = blk.block_type.toTag();
            try stdout.print("  [{d}] {s}  offset={d}  size={d}\n", .{ bi, tag, blk.offset, blk.size });
        }

        // Try to decode MDAT block as KV3 (mesh metadata)
        for (resource.blocks.items) |blk| {
            if (blk.block_type == .mdat) {
                try stdout.print("\nMDAT block: offset={d} size={d}\n", .{ blk.offset, blk.size });
                // Read raw bytes from the original data
                const mdat_raw = data[blk.offset..][0..blk.size];
                var mdat_doc = vrf.binary_kv3.decode(allocator, mdat_raw) catch |err| {
                    try stdout.print("MDAT KV3 decode error: {}\n", .{err});
                    try stdout.writeAll("MDAT first 64 bytes (hex):\n");
                    for (mdat_raw[0..@min(64, mdat_raw.len)], 0..) |b, bi| {
                        try stdout.print("{x:0>2} ", .{b});
                        if ((bi + 1) % 16 == 0) try stdout.writeAll("\n");
                    }
                    continue;
                };
                defer mdat_doc.deinit();

                const mdat_root = mdat_doc.root.asObject() orelse continue;
                try stdout.print("MDAT root ({d} keys):\n", .{mdat_root.keys.items.len});
                for (mdat_root.keys.items, mdat_root.values.items) |k, *v| {
                    const vs = formatKVValue(allocator, v) catch "(err)";
                    defer if (!std.mem.eql(u8, vs, "(err)")) allocator.free(vs);
                    try stdout.print("  {s} = {s}\n", .{ k, vs });
                }

                // Drill into first sceneObject / drawCall if present
                if (mdat_root.getArray("m_sceneObjects")) |so_arr| {
                    for (so_arr.items.items, 0..) |*so_val, si| {
                        if (si >= 2) break;
                        if (so_val.asObject()) |so| {
                            try stdout.print("\n  m_sceneObjects[{d}]:\n", .{si});
                            for (so.keys.items, so.values.items) |k, *v| {
                                const vs = formatKVValue(allocator, v) catch "(err)";
                                defer if (!std.mem.eql(u8, vs, "(err)")) allocator.free(vs);
                                try stdout.print("    {s} = {s}\n", .{ k, vs });
                            }
                            // Drill into drawCalls
                            if (so.getArray("m_drawCalls")) |dc_arr| {
                                for (dc_arr.items.items, 0..) |*dc_val, di| {
                                    if (di >= 2) break;
                                    if (dc_val.asObject()) |dc| {
                                        try stdout.print("\n    m_drawCalls[{d}]:\n", .{di});
                                        for (dc.keys.items, dc.values.items) |k, *v| {
                                            const vs = formatKVValue(allocator, v) catch "(err)";
                                            defer if (!std.mem.eql(u8, vs, "(err)")) allocator.free(vs);
                                            try stdout.print("      {s} = {s}\n", .{ k, vs });
                                        }
                                        // Drill into vertex buffers
                                        if (dc.getArray("m_vertexBuffers")) |vb_arr| {
                                            for (vb_arr.items.items, 0..) |*vb_val, vi| {
                                                if (vb_val.asObject()) |vb| {
                                                    try stdout.print("\n      m_vertexBuffers[{d}]:\n", .{vi});
                                                    for (vb.keys.items, vb.values.items) |k, *v| {
                                                        const vs = formatKVValue(allocator, v) catch "(err)";
                                                        defer if (!std.mem.eql(u8, vs, "(err)")) allocator.free(vs);
                                                        try stdout.print("        {s} = {s}\n", .{ k, vs });
                                                    }
                                                }
                                            }
                                        }
                                        // Drill into index buffer
                                        if (dc.getSubCollection("m_indexBuffer")) |ib| {
                                            try stdout.writeAll("\n      m_indexBuffer:\n");
                                            for (ib.keys.items, ib.values.items) |k, *v| {
                                                const vs = formatKVValue(allocator, v) catch "(err)";
                                                defer if (!std.mem.eql(u8, vs, "(err)")) allocator.free(vs);
                                                try stdout.print("        {s} = {s}\n", .{ k, vs });
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // Show MVTX/MIDX block sizes
            if (blk.block_type == .mvtx or blk.block_type == .midx) {
                try stdout.print("\n{s} block: offset={d} size={d}\n", .{ blk.block_type.toTag(), blk.offset, blk.size });
                // Show first 32 bytes
                const block_raw = data[blk.offset..][0..@min(32, blk.size)];
                try stdout.writeAll("  Header: ");
                for (block_raw) |b| try stdout.print("{x:0>2} ", .{b});
                try stdout.writeAll("\n");
            }

            // Decode CTRL block
            if (blk.block_type == .ctrl) {
                try stdout.print("\nCTRL block: offset={d} size={d}\n", .{ blk.offset, blk.size });
                const ctrl_raw = data[blk.offset..][0..blk.size];
                var ctrl_doc = vrf.binary_kv3.decode(allocator, ctrl_raw) catch |err| {
                    try stdout.print("CTRL KV3 decode error: {}\n", .{err});
                    continue;
                };
                defer ctrl_doc.deinit();
                const ctrl_root = ctrl_doc.root.asObject() orelse continue;
                try stdout.print("CTRL root ({d} keys):\n", .{ctrl_root.keys.items.len});
                for (ctrl_root.keys.items, ctrl_root.values.items) |k, *v| {
                    const vs = formatKVValue(allocator, v) catch "(err)";
                    defer if (!std.mem.eql(u8, vs, "(err)")) allocator.free(vs);
                    try stdout.print("  {s} = {s}\n", .{ k, vs });
                }

                // Drill into embedded_meshes
                if (ctrl_root.getArray("embedded_meshes")) |em_arr| {
                    try stdout.print("\n  embedded_meshes ({d}):\n", .{em_arr.count()});
                    for (em_arr.items.items, 0..) |*em_val, ei| {
                        if (em_val.asObject()) |em| {
                            try stdout.print("    Mesh [{d}]:\n", .{ei});
                            for (em.keys.items, em.values.items) |k, *v| {
                                const vs = formatKVValue(allocator, v) catch "(err)";
                                defer if (!std.mem.eql(u8, vs, "(err)")) allocator.free(vs);
                                try stdout.print("      {s} = {s}\n", .{ k, vs });
                            }
                            // Drill into vertex buffers
                            if (em.getArray("m_vertexBuffers")) |vb_arr2| {
                                try stdout.print("      m_vertexBuffers ({d}):\n", .{vb_arr2.count()});
                                for (vb_arr2.items.items, 0..) |*vb_val2, vi2| {
                                    if (vb_val2.asObject()) |vb2| {
                                        try stdout.print("        [{d}]:\n", .{vi2});
                                        for (vb2.keys.items, vb2.values.items) |k, *v| {
                                            const vs = formatKVValue(allocator, v) catch "(err)";
                                            defer if (!std.mem.eql(u8, vs, "(err)")) allocator.free(vs);
                                            try stdout.print("          {s} = {s}\n", .{ k, vs });
                                        }
                                        // Input layout fields
                                        if (vb2.getArray("m_inputLayoutFields")) |ilf| {
                                            try stdout.print("          m_inputLayoutFields ({d}):\n", .{ilf.count()});
                                            for (ilf.items.items) |*fv| {
                                                if (fv.asObject()) |fo| {
                                                    var line2 = std.ArrayList(u8).init(allocator);
                                                    defer line2.deinit();
                                                    for (fo.keys.items, fo.values.items) |fk, *ffv| {
                                                        const fvs = formatKVValue(allocator, ffv) catch "?";
                                                        defer if (!std.mem.eql(u8, fvs, "?")) allocator.free(fvs);
                                                        if (line2.items.len > 0) line2.appendSlice(", ") catch {};
                                                        line2.appendSlice(fk) catch {};
                                                        line2.append('=') catch {};
                                                        line2.appendSlice(fvs) catch {};
                                                    }
                                                    try stdout.print("            {{ {s} }}\n", .{line2.items});
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                            if (em.getArray("m_indexBuffers")) |ib_arr2| {
                                try stdout.print("      m_indexBuffers ({d}):\n", .{ib_arr2.count()});
                                for (ib_arr2.items.items, 0..) |*ib_val2, ii2| {
                                    if (ib_val2.asObject()) |ib2| {
                                        try stdout.print("        [{d}]:\n", .{ii2});
                                        for (ib2.keys.items, ib2.values.items) |k, *v| {
                                            const vs = formatKVValue(allocator, v) catch "(err)";
                                            defer if (!std.mem.eql(u8, vs, "(err)")) allocator.free(vs);
                                            try stdout.print("          {s} = {s}\n", .{ k, vs });
                                        }
                                    }
                                }
                            }
                            if (em.getArray("vbib")) |vbib_arr| {
                                try stdout.print("      vbib ({d}):\n", .{vbib_arr.count()});
                                for (vbib_arr.items.items, 0..) |*vb_val, vi| {
                                    if (vb_val.asObject()) |vb| {
                                        try stdout.print("        [{d}]:\n", .{vi});
                                        for (vb.keys.items, vb.values.items) |k, *v| {
                                            const vs = formatKVValue(allocator, v) catch "(err)";
                                            defer if (!std.mem.eql(u8, vs, "(err)")) allocator.free(vs);
                                            try stdout.print("          {s} = {s}\n", .{ k, vs });
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // Drill into embedded buffers
                if (ctrl_root.getArray("m_embeddedVertexBuffers")) |evb_arr| {
                    try stdout.print("\n  m_embeddedVertexBuffers ({d}):\n", .{evb_arr.count()});
                    for (evb_arr.items.items, 0..) |*evb_val, ei| {
                        if (evb_val.asObject()) |evb| {
                            try stdout.print("    Buffer [{d}]:\n", .{ei});
                            for (evb.keys.items, evb.values.items) |k, *v| {
                                const vs = formatKVValue(allocator, v) catch "(err)";
                                defer if (!std.mem.eql(u8, vs, "(err)")) allocator.free(vs);
                                try stdout.print("      {s} = {s}\n", .{ k, vs });
                            }
                            // Drill into layout fields
                            if (evb.getArray("m_inputLayoutFields")) |ilf| {
                                try stdout.print("      m_inputLayoutFields ({d}):\n", .{ilf.count()});
                                for (ilf.items.items) |*field_val| {
                                    if (field_val.asObject()) |field| {
                                        var line = std.ArrayList(u8).init(allocator);
                                        defer line.deinit();
                                        for (field.keys.items, field.values.items) |fk, *fv| {
                                            const fvs = formatKVValue(allocator, fv) catch "?";
                                            defer if (!std.mem.eql(u8, fvs, "?")) allocator.free(fvs);
                                            if (line.items.len > 0) line.appendSlice(", ") catch {};
                                            line.appendSlice(fk) catch {};
                                            line.append('=') catch {};
                                            line.appendSlice(fvs) catch {};
                                        }
                                        try stdout.print("        {{ {s} }}\n", .{line.items});
                                    }
                                }
                            }
                        }
                    }
                }
                if (ctrl_root.getArray("m_embeddedIndexBuffers")) |eib_arr| {
                    try stdout.print("\n  m_embeddedIndexBuffers ({d}):\n", .{eib_arr.count()});
                    for (eib_arr.items.items, 0..) |*eib_val, ei| {
                        if (eib_val.asObject()) |eib| {
                            try stdout.print("    Buffer [{d}]:\n", .{ei});
                            for (eib.keys.items, eib.values.items) |k, *v| {
                                const vs = formatKVValue(allocator, v) catch "(err)";
                                defer if (!std.mem.eql(u8, vs, "(err)")) allocator.free(vs);
                                try stdout.print("      {s} = {s}\n", .{ k, vs });
                            }
                        }
                    }
                }
            }
        }

        // Try to build VBIB from embedded mesh
        for (resource.blocks.items) |blk| {
            if (blk.block_type == .ctrl) {
                const ctrl_raw2 = data[blk.offset..][0..blk.size];
                var ctrl_doc2 = vrf.binary_kv3.decode(allocator, ctrl_raw2) catch continue;
                defer ctrl_doc2.deinit();
                const ctrl_root2 = ctrl_doc2.root.asObject() orelse continue;

                if (ctrl_root2.getArray("embedded_meshes")) |em_arr| {
                    for (em_arr.items.items, 0..) |*em_val, ei| {
                        const em_obj = em_val.asObject() orelse continue;
                        var vbib = vrf.VBIB.readFromEmbeddedMesh(allocator, em_obj, &resource) catch |err| {
                            try stdout.print("\nFailed to build VBIB from embedded mesh [{d}]: {}\n", .{ ei, err });
                            continue;
                        };
                        defer vbib.deinit();

                        try stdout.print("\nEmbedded mesh [{d}] → VBIB (OK!):\n", .{ei});
                        try stdout.print("  Vertex buffers: {d}\n", .{vbib.vertex_buffers.len});
                        for (vbib.vertex_buffers, 0..) |vb, vi| {
                            try stdout.print("    [{d}] {d} verts × {d} bytes", .{ vi, vb.element_count, vb.element_size_in_bytes });
                            if (vb.data.len > 0) {
                                try stdout.print(" ({d} bytes data)", .{vb.data.len});
                            }
                            try stdout.writeAll("\n");
                            for (vb.input_layout) |attr| {
                                try stdout.print("      {s}[{d}] format={d} offset={d}\n", .{ attr.semantic_name, attr.semantic_index, @intFromEnum(attr.format), attr.offset });
                            }
                            // Sample first vertex
                            if (vb.element_count > 0 and vb.data.len > 0) {
                                const pos = vb.getPosition(0);
                                try stdout.print("      vertex[0] pos=({d:.2}, {d:.2}, {d:.2})\n", .{ pos[0], pos[1], pos[2] });
                                const normal = vb.getNormal(0);
                                try stdout.print("      vertex[0] normal=({d:.3}, {d:.3}, {d:.3})\n", .{ normal[0], normal[1], normal[2] });
                                const uv = vb.getTexcoord(0);
                                try stdout.print("      vertex[0] uv=({d:.4}, {d:.4})\n", .{ uv[0], uv[1] });
                            }
                        }
                        try stdout.print("  Index buffers: {d}\n", .{vbib.index_buffers.len});
                        for (vbib.index_buffers, 0..) |ib, ii| {
                            try stdout.print("    [{d}] {d} indices × {d} bytes", .{ ii, ib.element_count, ib.element_size_in_bytes });
                            if (ib.data.len > 0) {
                                try stdout.print(" ({d} bytes data)", .{ib.data.len});
                                // Sample first 6 indices
                                const n = @min(6, ib.element_count);
                                try stdout.writeAll(" first: ");
                                for (0..n) |idx| {
                                    try stdout.print("{d} ", .{ib.getIndex(@intCast(idx))});
                                }
                            }
                            try stdout.writeAll("\n");
                        }
                    }
                }
            }
        }

        // Try to decode DATA block as KV3
        const data_block = resource.dataBlock() orelse {
            try stdout.writeAll("\nNo DATA block found.\n");
            return;
        };
        const raw = switch (data_block.data) {
            .data_block => |db| db.raw_data orelse {
                try stdout.writeAll("\nDATA block has no raw data.\n");
                return;
            },
            else => {
                try stdout.writeAll("\nUnexpected block data type.\n");
                return;
            },
        };

        try stdout.print("\nDATA block: {d} bytes\n", .{raw.len});

        // Try KV3 decode
        var doc = vrf.binary_kv3.decode(allocator, raw) catch |err| {
            try stdout.print("KV3 decode error: {}\n", .{err});

            // Show raw DATA header
            try stdout.writeAll("\nDATA first 128 bytes (hex):\n");
            for (raw[0..@min(128, raw.len)], 0..) |b, i| {
                try stdout.print("{x:0>2} ", .{b});
                if ((i + 1) % 16 == 0) try stdout.writeAll("\n");
            }
            try stdout.writeAll("\n");
            return;
        };
        defer doc.deinit();

        const root_obj = doc.root.asObject() orelse {
            try stdout.writeAll("\nKV3 root is not an object\n");
            return;
        };
        try stdout.print("\nKV3 root ({d} keys):\n", .{root_obj.keys.items.len});
        for (root_obj.keys.items, root_obj.values.items) |key, *val| {
            const val_str = formatKVValue(allocator, val) catch "(format error)";
            defer if (!std.mem.eql(u8, val_str, "(format error)")) allocator.free(val_str);
            try stdout.print("  {s} = {s}\n", .{ key, val_str });
        }

        // If this looks like a material, dump its parameter tables.
        const param_tables = [_][]const u8{ "m_intParams", "m_floatParams", "m_vectorParams", "m_textureParams", "m_intAttributes", "m_stringAttributes" };
        for (param_tables) |table| {
            if (root_obj.getArray(table)) |pa| {
                if (pa.count() == 0) continue;
                try stdout.print("\n{s} ({d}):\n", .{ table, pa.count() });
                for (pa.items.items) |*pv| {
                    if (pv.asObject()) |po| {
                        var line = std.ArrayList(u8).init(allocator);
                        defer line.deinit();
                        for (po.keys.items, po.values.items) |pk, *pvv| {
                            const pvs = formatKVValue(allocator, pvv) catch "?";
                            defer if (!std.mem.eql(u8, pvs, "?")) allocator.free(pvs);
                            if (line.items.len > 0) line.appendSlice("  ") catch {};
                            line.appendSlice(pk) catch {};
                            line.append('=') catch {};
                            line.appendSlice(pvs) catch {};
                        }
                        try stdout.print("  {s}\n", .{line.items});
                    }
                }
            }
        }

        // If this looks like a world node, dump scene objects
        if (root_obj.getArray("m_sceneObjects")) |so_arr| {
            try stdout.print("\nScene objects ({d}):\n", .{so_arr.count()});
            // Show first 3 in detail
            for (so_arr.items.items, 0..) |*so_val, i| {
                if (i >= 3) {
                    try stdout.print("  ... ({d} more)\n", .{so_arr.count() - i});
                    break;
                }
                if (so_val.asObject()) |so_obj| {
                    try stdout.print("  SceneObject [{d}]:\n", .{i});
                    for (so_obj.keys.items, so_obj.values.items) |k, *v| {
                        const vs = formatKVValue(allocator, v) catch "(err)";
                        defer if (!std.mem.eql(u8, vs, "(err)")) allocator.free(vs);
                        try stdout.print("    {s} = {s}\n", .{ k, vs });
                    }
                }
            }
        }

        // Dump aggregate scene objects
        if (root_obj.getArray("m_aggregateSceneObjects")) |agg_arr| {
            try stdout.print("\nAggregate scene objects ({d}):\n", .{agg_arr.count()});
            for (agg_arr.items.items, 0..) |*agg_val, i| {
                if (i >= 3) {
                    try stdout.print("  ... ({d} more)\n", .{agg_arr.count() - i});
                    break;
                }
                if (agg_val.asObject()) |agg_obj| {
                    try stdout.print("  AggregateObject [{d}]:\n", .{i});
                    for (agg_obj.keys.items, agg_obj.values.items) |k, *v| {
                        const vs = formatKVValue(allocator, v) catch "(err)";
                        defer if (!std.mem.eql(u8, vs, "(err)")) allocator.free(vs);
                        try stdout.print("    {s} = {s}\n", .{ k, vs });
                    }
                }
            }
        }

        // Drill into world nodes
        if (root_obj.getArray("m_worldNodes")) |wn_arr| {
            try stdout.print("\nWorld nodes ({d}):\n", .{wn_arr.count()});
            for (wn_arr.items.items, 0..) |*wn_val, i| {
                if (wn_val.asObject()) |wn_obj| {
                    try stdout.print("  Node [{d}]:\n", .{i});
                    for (wn_obj.keys.items, wn_obj.values.items) |k, *v| {
                        const vs = formatKVValue(allocator, v) catch "(err)";
                        defer if (!std.mem.eql(u8, vs, "(err)")) allocator.free(vs);
                        try stdout.print("    {s} = {s}\n", .{ k, vs });
                    }
                }
            }
        }

        // Drill into entity lumps
        if (root_obj.getArray("m_entityLumps")) |el_arr| {
            try stdout.print("\nEntity lumps ({d}):\n", .{el_arr.count()});
            for (el_arr.items.items) |*el_val| {
                if (el_val.asString()) |s| {
                    try stdout.print("  {s}\n", .{s});
                }
            }
        }

        // Drill into builder params
        if (root_obj.getSubCollection("m_builderParams")) |bp| {
            try stdout.writeAll("\nBuilder params:\n");
            for (bp.keys.items, bp.values.items) |k, *v| {
                const vs = formatKVValue(allocator, v) catch "(err)";
                defer if (!std.mem.eql(u8, vs, "(err)")) allocator.free(vs);
                try stdout.print("  {s} = {s}\n", .{ k, vs });
            }
        }

        // Drill into lighting info
        if (root_obj.getSubCollection("m_worldLightingInfo")) |li| {
            try stdout.writeAll("\nLighting info:\n");
            for (li.keys.items, li.values.items) |k, *v| {
                const vs = formatKVValue(allocator, v) catch "(err)";
                defer if (!std.mem.eql(u8, vs, "(err)")) allocator.free(vs);
                try stdout.print("  {s} = {s}\n", .{ k, vs });
            }
        }

        // RERL — external references
        for (resource.blocks.items) |blk| {
            switch (blk.data) {
                .rerl => |rerl| {
                    try stdout.print("\nExternal references ({d}):\n", .{rerl.resource_ref_info_list.len});
                    for (rerl.resource_ref_info_list, 0..) |ref, i| {
                        try stdout.print("  [{d}] id={d} name={s}\n", .{ i, ref.id, ref.name });
                        if (i >= 30) {
                            try stdout.print("  ... ({d} more)\n", .{rerl.resource_ref_info_list.len - i - 1});
                            break;
                        }
                    }
                },
                else => {},
            }
        }
    } else {
        // List all entries with sizes
        var ext_iter = pkg.entries.iterator();
        while (ext_iter.next()) |kv| {
            try stdout.print(".{s} ({d} files):\n", .{ kv.key_ptr.*, kv.value_ptr.items.len });
            for (kv.value_ptr.items, 0..) |*entry, i| {
                const full_path = try entry.getFullPath(allocator);
                defer allocator.free(full_path);
                try stdout.print("  {s} ({d} bytes)\n", .{ full_path, entry.totalLength() });
                if (i >= 10) {
                    try stdout.print("  ... ({d} more)\n", .{kv.value_ptr.items.len - i - 1});
                    break;
                }
            }
        }
    }
}

/// Count draw calls (= sub-meshes) for one vmdl_c. Mirrors the logic in
/// pvs_baker's extractModelGeometry — first checks legacy VBIB/MBUF (always
/// 1 sub-mesh), then walks the embedded mesh's MDAT block for m_drawCalls.
fn countSubMeshes(allocator: std.mem.Allocator, data: []const u8) !u32 {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    _ = allocator;

    var resource = vrf.Resource.init(arena);
    defer resource.deinit();
    resource.resource_type = .model;
    resource.read(data) catch return error.ParseFailed;

    // Legacy VBIB/MBUF: one big buffer, treated as a single sub-mesh.
    for (resource.blocks.items) |blk| {
        if (blk.block_type == .vbib or blk.block_type == .mbuf) {
            if (blk.size > 0) return 1;
        }
    }

    // CTRL embedded-mesh path: count m_drawCalls inside the MDAT block.
    const ctrl_block = resource.getBlockByType(.ctrl) orelse return error.ParseFailed;
    const ctrl_raw = switch (ctrl_block.data) {
        .kv3_block => |kb| kb.raw_data orelse return error.ParseFailed,
        else => return error.ParseFailed,
    };

    var ctrl_doc = vrf.binary_kv3.decode(arena, ctrl_raw) catch return error.ParseFailed;
    defer ctrl_doc.deinit();
    const ctrl_root = ctrl_doc.root.asObject() orelse return error.ParseFailed;

    const em_arr = ctrl_root.getArray("embedded_meshes") orelse return error.ParseFailed;
    if (em_arr.count() == 0) return error.ParseFailed;
    const em_obj = em_arr.items.items[0].asObject() orelse return error.ParseFailed;

    const data_block_index = em_obj.get("m_nDataBlock") orelse return 1;
    const dbi = data_block_index.asU32() orelse return 1;
    const mdat_block = resource.getBlockByIndex(@intCast(dbi)) orelse return 1;
    const mdat_raw = switch (mdat_block.data) {
        .data_block => |db| db.raw_data orelse return 1,
        else => return 1,
    };

    var mdat_doc = vrf.binary_kv3.decode(arena, mdat_raw) catch return 1;
    defer mdat_doc.deinit();
    const mdat_root = mdat_doc.root.asObject() orelse return 1;
    const so_arr = mdat_root.getArray("m_sceneObjects") orelse return 1;

    var dc_count: u32 = 0;
    for (so_arr.items.items) |*so_val| {
        const so_obj = so_val.asObject() orelse continue;
        const dc_arr = so_obj.getArray("m_drawCalls") orelse continue;
        for (dc_arr.items.items) |*dc_val| {
            const dc_obj = dc_val.asObject() orelse continue;
            const idx_count = dc_obj.getU32Property("m_nIndexCount") orelse continue;
            if (idx_count == 0) continue;
            dc_count += 1;
        }
    }

    if (dc_count == 0) return 1; // fallback: one whole-buffer draw call
    return dc_count;
}

/// Decode a vtex_c and print its dimensions, format, and average RGBA.
fn texAvg(allocator: std.mem.Allocator, vpk_path: []const u8, tex_path: []const u8, stdout: anytype) !void {
    var pkg = vrf.vpk.Package.init(allocator);
    defer pkg.deinit();
    try pkg.readFile(vpk_path);

    const entry = pkg.findEntry(tex_path) orelse {
        try stdout.print("Entry not found: {s}\n", .{tex_path});
        std.process.exit(1);
    };
    const tex_data = try pkg.readEntry(entry);
    defer pkg.allocator.free(tex_data);

    var resource = vrf.Resource.init(allocator);
    defer resource.deinit();
    resource.resource_type = .texture;
    try resource.read(tex_data);

    const tex_block = resource.dataBlock() orelse return error.NoTexture;
    const header = tex_data[tex_block.offset..][0..tex_block.size];
    const pixel_start = tex_block.offset + tex_block.size;

    var tex = vrf.Texture.init(allocator);
    defer tex.deinit();
    try tex.readHeader(header);
    tex.data = if (pixel_start < tex_data.len) tex_data[pixel_start..] else null;

    const rgba = try tex.decodeRGBA();
    defer allocator.free(rgba);

    var sums = [4]u64{ 0, 0, 0, 0 };
    const px_count = @as(u64, tex.width) * tex.height;
    var i: usize = 0;
    while (i + 4 <= rgba.len) : (i += 4) {
        for (0..4) |c| sums[c] += rgba[i + c];
    }
    try stdout.print("{s}\n  {d}x{d} fmt={s}\n  avg RGBA = ({d:.1}, {d:.1}, {d:.1}, {d:.1})\n", .{
        tex_path,                                                     tex.width, tex.height, @tagName(tex.format),
        @as(f64, @floatFromInt(sums[0])) / @as(f64, @floatFromInt(px_count)),
        @as(f64, @floatFromInt(sums[1])) / @as(f64, @floatFromInt(px_count)),
        @as(f64, @floatFromInt(sums[2])) / @as(f64, @floatFromInt(px_count)),
        @as(f64, @floatFromInt(sums[3])) / @as(f64, @floatFromInt(px_count)),
    });
}

/// Dump vertex buffer layouts and per-attribute value stats for one vmdl_c.
/// Shows which buffer/attribute carries blend-paint data for 2-layer materials.
fn vbufDump(allocator: std.mem.Allocator, vpk_path: []const u8, model_path: []const u8, stdout: anytype) !void {
    var pkg = vrf.vpk.Package.init(allocator);
    defer pkg.deinit();
    try pkg.readFile(vpk_path);

    const entry = pkg.findEntry(model_path) orelse {
        try stdout.print("Entry not found: {s}\n", .{model_path});
        std.process.exit(1);
    };
    const data = try pkg.readEntry(entry);
    defer pkg.allocator.free(data);

    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var resource = vrf.Resource.init(arena);
    defer resource.deinit();
    resource.resource_type = .model;
    try resource.read(data);

    // Get VBIB: legacy block or CS2 embedded mesh
    var vbib: vrf.VBIB = blk: {
        for (resource.blocks.items) |b| {
            if ((b.block_type == .vbib or b.block_type == .mbuf) and b.size > 0) {
                break :blk try vrf.VBIB.readFromBinaryBlock(arena, data[b.offset..][0..b.size]);
            }
        }
        const ctrl_block = resource.getBlockByType(.ctrl) orelse return error.NoMeshData;
        const ctrl_raw = switch (ctrl_block.data) {
            .kv3_block => |kb| kb.raw_data orelse return error.NoMeshData,
            else => return error.NoMeshData,
        };
        var ctrl_doc = try vrf.binary_kv3.decode(arena, ctrl_raw);
        const ctrl_root = ctrl_doc.root.asObject() orelse return error.NoMeshData;
        const em_arr = ctrl_root.getArray("embedded_meshes") orelse return error.NoMeshData;
        if (em_arr.count() == 0) return error.NoMeshData;
        const em_obj = em_arr.items.items[0].asObject() orelse return error.NoMeshData;
        break :blk try vrf.VBIB.readFromEmbeddedMesh(arena, em_obj, &resource);
    };
    defer vbib.deinit();

    try stdout.print("{s}\n{d} vertex buffer(s), {d} index buffer(s)\n\n", .{ model_path, vbib.vertex_buffers.len, vbib.index_buffers.len });

    for (vbib.vertex_buffers, 0..) |*vb, bi| {
        try stdout.print("VB[{d}]: {d} elements x {d} bytes ({d} KB)\n", .{ bi, vb.element_count, vb.element_size_in_bytes, vb.data.len / 1024 });
        for (vb.input_layout) |*f| {
            try stdout.print("  {s}[{d}] fmt={s} offset={d} slot={d}\n", .{ f.semantic_name, f.semantic_index, @tagName(f.format), f.offset, f.slot });
        }
        // Per-attribute value stats
        for (vb.input_layout) |*f| {
            const fsize = f.format.byteSize();
            if (fsize == 0 or vb.element_count == 0) continue;
            try stdout.print("  --- {s}[{d}] samples:", .{ f.semantic_name, f.semantic_index });
            var vi: u32 = 0;
            while (vi < @min(vb.element_count, 6)) : (vi += 1) {
                const o = @as(usize, vi) * vb.element_size_in_bytes + f.offset;
                if (o + fsize > vb.data.len) break;
                try stdout.writeAll(" [");
                for (vb.data[o .. o + fsize], 0..) |byte, k| {
                    if (k > 0) try stdout.writeAll(" ");
                    try stdout.print("{x:0>2}", .{byte});
                }
                try stdout.writeAll("]");
            }
            try stdout.writeAll("\n");
            // Channel stats for byte-per-channel formats
            if (f.format == .r8g8b8a8_unorm or f.format == .r8g8b8a8_uint) {
                var mins = [4]u8{ 255, 255, 255, 255 };
                var maxs = [4]u8{ 0, 0, 0, 0 };
                var sums = [4]u64{ 0, 0, 0, 0 };
                var nonzero: u32 = 0;
                var count: u32 = 0;
                vi = 0;
                while (vi < vb.element_count) : (vi += 1) {
                    const o = @as(usize, vi) * vb.element_size_in_bytes + f.offset;
                    if (o + 4 > vb.data.len) break;
                    var any = false;
                    for (0..4) |c| {
                        const b = vb.data[o + c];
                        mins[c] = @min(mins[c], b);
                        maxs[c] = @max(maxs[c], b);
                        sums[c] += b;
                        if (b != 0) any = true;
                    }
                    if (any) nonzero += 1;
                    count += 1;
                }
                if (count > 0) {
                    try stdout.print("      channel min=({d},{d},{d},{d}) max=({d},{d},{d},{d}) mean=({d:.1},{d:.1},{d:.1},{d:.1}) nonzero={d}/{d}\n", .{
                        mins[0], mins[1], mins[2], mins[3],
                        maxs[0], maxs[1], maxs[2], maxs[3],
                        @as(f64, @floatFromInt(sums[0])) / @as(f64, @floatFromInt(count)),
                        @as(f64, @floatFromInt(sums[1])) / @as(f64, @floatFromInt(count)),
                        @as(f64, @floatFromInt(sums[2])) / @as(f64, @floatFromInt(count)),
                        @as(f64, @floatFromInt(sums[3])) / @as(f64, @floatFromInt(count)),
                        nonzero, count,
                    });
                }
            }
        }
        try stdout.writeAll("\n");
    }
}

/// Extract an f64 from any numeric KV3 value.
fn kvFloat(v: *const vrf.kv3.KVValue) ?f64 {
    return switch (v.*) {
        .float32 => |f| f,
        .float64 => |f| f,
        .int32 => |i| @floatFromInt(i),
        .uint32 => |i| @floatFromInt(i),
        .int64 => |i| @floatFromInt(i),
        .uint64 => |i| @floatFromInt(i),
        else => null,
    };
}

/// Parse a KV3 3x4 row-major transform (array of 3 rows × 4 floats).
/// Returns null if the shape doesn't match.
fn kvTransform(v: *const vrf.kv3.KVValue) ?[3][4]f64 {
    const arr = switch (v.*) {
        .array => |a| a,
        else => return null,
    };
    var m: [3][4]f64 = undefined;
    // Flat row-major 12-float form (m_fragmentTransforms uses this).
    if (arr.items.items.len == 12) {
        for (arr.items.items, 0..) |*cell, i| {
            m[i / 4][i % 4] = kvFloat(cell) orelse return null;
        }
        return m;
    }
    if (arr.items.items.len != 3) return null;
    for (arr.items.items, 0..) |*row_val, r| {
        const row = switch (row_val.*) {
            .array => |a| a,
            else => return null,
        };
        if (row.items.items.len != 4) return null;
        for (row.items.items, 0..) |*cell, c| {
            m[r][c] = kvFloat(cell) orelse return null;
        }
    }
    return m;
}

fn det3(m: [3][4]f64) f64 {
    return m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1]) -
        m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0]) +
        m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0]);
}

fn isIdentity(m: [3][4]f64) bool {
    const eps = 1e-6;
    for (0..3) |r| {
        for (0..4) |c| {
            const want: f64 = if (r == c) 1.0 else 0.0;
            if (@abs(m[r][c] - want) > eps) return false;
        }
    }
    return true;
}

/// Survey every scene object / aggregate in all world nodes of a map:
/// which carry real transforms, and which of those are mirrored
/// (negative determinant)?
fn transformStats(allocator: std.mem.Allocator, vpk_path: []const u8, stdout: anytype) !void {
    var pkg = vrf.vpk.Package.init(allocator);
    defer pkg.deinit();
    pkg.readFile(vpk_path) catch |err| {
        try std.io.getStdErr().writer().print("Error reading VPK: {}\n", .{err});
        std.process.exit(1);
    };

    var it = pkg.iterateAll();
    while (it.next()) |entry| {
        if (!std.mem.eql(u8, entry.type_name, "vwnod_c")) continue;
        const full_path = try entry.getFullPath(allocator);
        defer allocator.free(full_path);
        try stdout.print("══ {s} ══\n", .{full_path});

        const data = try pkg.readEntry(entry);
        defer allocator.free(data);

        var resource = vrf.Resource.init(allocator);
        defer resource.deinit();
        resource.read(data) catch |err| {
            try stdout.print("  parse error: {}\n", .{err});
            continue;
        };

        const data_block = resource.dataBlock() orelse continue;
        const raw = switch (data_block.data) {
            .data_block => |db| db.raw_data orelse continue,
            else => continue,
        };
        var doc = vrf.binary_kv3.decode(allocator, raw) catch continue;
        defer doc.deinit();
        const root = doc.root.asObject() orelse continue;

        // ── Plain scene objects: per-object m_vTransform ──
        if (root.getArray("m_sceneObjects")) |so_arr| {
            var n_identity: u32 = 0;
            var n_transformed: u32 = 0;
            var n_mirrored: u32 = 0;
            for (so_arr.items.items, 0..) |*so_val, i| {
                const so = so_val.asObject() orelse continue;
                const model = so.getStringProperty("m_renderableModel") orelse "?";
                const tv = so.get("m_vTransform") orelse continue;
                const m = kvTransform(tv) orelse {
                    try stdout.print("  scene[{d}] UNPARSEABLE m_vTransform ({s})\n", .{ i, model });
                    continue;
                };
                if (isIdentity(m)) {
                    n_identity += 1;
                } else {
                    n_transformed += 1;
                    const d = det3(m);
                    if (d < 0) n_mirrored += 1;
                    try stdout.print("  scene[{d}] det={d:.3} t=({d:.1},{d:.1},{d:.1}) {s}\n", .{ i, d, m[0][3], m[1][3], m[2][3], model });
                }
            }
            try stdout.print("  scene objects: {d} total, {d} identity, {d} transformed, {d} MIRRORED\n", .{ so_arr.count(), n_identity, n_transformed, n_mirrored });
        }

        // ── Aggregate scene objects: per-fragment transforms ──
        if (root.getArray("m_aggregateSceneObjects")) |agg_arr| {
            var n_no_frags: u32 = 0;
            var n_with_frags: u32 = 0;
            var total_frags: u32 = 0;
            var total_mirrored: u32 = 0;
            var dumped_mesh_keys = false;
            for (agg_arr.items.items, 0..) |*agg_val, i| {
                const agg = agg_val.asObject() orelse continue;
                const model = agg.getStringProperty("m_renderableModel") orelse "?";
                const frags = agg.getArray("m_fragmentTransforms") orelse continue;
                const mesh_count: u32 = if (agg.getArray("m_aggregateMeshes")) |am| @intCast(am.count()) else 0;
                // Non-white per-mesh tints exist on baked aggregates too.
                if (agg.getArray("m_aggregateMeshes")) |am_t| {
                    for (am_t.items.items, 0..) |*mv_t, mi_t| {
                        const mo_t = mv_t.asObject() orelse continue;
                        const tv_t = mo_t.get("m_vTintColor") orelse continue;
                        const tarr = switch (tv_t.*) {
                            .array => |a| a,
                            else => continue,
                        };
                        if (tarr.items.items.len < 3) continue;
                        var tc: [3]f64 = undefined;
                        var ok = true;
                        for (0..3) |ci| {
                            tc[ci] = kvFloat(&tarr.items.items[ci]) orelse {
                                ok = false;
                                break;
                            };
                        }
                        if (!ok) continue;
                        if (@abs(tc[0] - 1.0) > 0.01 or @abs(tc[1] - 1.0) > 0.01 or @abs(tc[2] - 1.0) > 0.01) {
                            try stdout.print("  TINT mesh[{d}] = ({d:.3},{d:.3},{d:.3}) dc={d} {s}\n", .{ mi_t, tc[0], tc[1], tc[2], mo_t.getU32Property("m_nDrawCallIndex") orelse 999, model });
                        }
                    }
                }
                if (frags.count() == 0) {
                    n_no_frags += 1;
                    continue;
                }
                n_with_frags += 1;
                total_frags += @intCast(frags.count());
                var mirrored: u32 = 0;
                var min_det: f64 = std.math.inf(f64);
                var max_det: f64 = -std.math.inf(f64);
                for (frags.items.items) |*fv| {
                    const m = kvTransform(fv) orelse {
                        const vs = formatKVValue(allocator, fv) catch "(err)";
                        defer if (!std.mem.eql(u8, vs, "(err)")) allocator.free(vs);
                        try stdout.print("    frag shape: {s}\n", .{vs});
                        if (fv.* == .array) {
                            const inner = fv.array;
                            if (inner.items.items.len > 0) {
                                const ivs = formatKVValue(allocator, &inner.items.items[0]) catch "(err)";
                                defer if (!std.mem.eql(u8, ivs, "(err)")) allocator.free(ivs);
                                try stdout.print("    frag[0][0] shape: {s}\n", .{ivs});
                            }
                        }
                        continue;
                    };
                    const d = det3(m);
                    if (d < 0) mirrored += 1;
                    min_det = @min(min_det, d);
                    max_det = @max(max_det, d);
                }
                total_mirrored += mirrored;
                try stdout.print("  agg[{d}] frags={d} meshes={d} mirrored={d} det=[{d:.3},{d:.3}] {s}\n", .{ i, frags.count(), mesh_count, mirrored, min_det, max_det, model });
                // Per-mesh-entry draw-call index + transform flag, and the
                // paired fragment translation (world inches if this is a
                // real placement).
                if (agg.getArray("m_aggregateMeshes")) |am| {
                    for (am.items.items, 0..) |*mv, mi| {
                        const mo = mv.asObject() orelse continue;
                        const dci = mo.getU32Property("m_nDrawCallIndex") orelse 999;
                        const has_t = if (mo.get("m_bHasTransform")) |ht| switch (ht.*) {
                            .boolean => |b| b,
                            else => false,
                        } else false;
                        var tx: f64 = 0;
                        var ty: f64 = 0;
                        var tz: f64 = 0;
                        var rot0: f64 = 1;
                        if (mi < frags.items.items.len) {
                            if (kvTransform(&frags.items.items[mi])) |fm| {
                                tx = fm[0][3];
                                ty = fm[1][3];
                                tz = fm[2][3];
                                rot0 = fm[0][0];
                            }
                        }
                        try stdout.print("    mesh[{d}] dc={d} hasT={} r00={d:.2} t=({d:.0},{d:.0},{d:.0})\n", .{ mi, dci, has_t, rot0, tx, ty, tz });
                    }
                }
                // Dump the schema of one aggregate-mesh entry so we know
                // which fields link draw calls to fragment transforms.
                if (!dumped_mesh_keys) {
                    if (agg.getArray("m_aggregateMeshes")) |am| {
                        if (am.count() > 0) {
                            if (am.items.items[0].asObject()) |mo| {
                                try stdout.writeAll("    m_aggregateMeshes[0] keys:\n");
                                for (mo.keys.items, mo.values.items) |k, *v| {
                                    const vs = formatKVValue(allocator, v) catch "(err)";
                                    defer if (!std.mem.eql(u8, vs, "(err)")) allocator.free(vs);
                                    try stdout.print("      {s} = {s}\n", .{ k, vs });
                                }
                                dumped_mesh_keys = true;
                            }
                        }
                    }
                }
            }
            try stdout.print("  aggregates: {d} total, {d} baked (no frags), {d} instanced ({d} frags, {d} MIRRORED)\n", .{ agg_arr.count(), n_no_frags, n_with_frags, total_frags, total_mirrored });
        }
    }
}

/// Decode every entity lump (vents_c) in a map VPK and dump each
/// entity's key-values — first few in full, then a classname tally.
fn entityStats(allocator: std.mem.Allocator, vpk_path: []const u8, stdout: anytype) !void {
    var pkg = vrf.vpk.Package.init(allocator);
    defer pkg.deinit();
    pkg.readFile(vpk_path) catch |err| {
        try std.io.getStdErr().writer().print("Error reading VPK: {}\n", .{err});
        std.process.exit(1);
    };

    var it = pkg.iterateAll();
    while (it.next()) |entry| {
        if (!std.mem.eql(u8, entry.type_name, "vents_c")) continue;
        const full_path = try entry.getFullPath(allocator);
        defer allocator.free(full_path);
        try stdout.print("══ {s} ══\n", .{full_path});

        const data = pkg.readEntry(entry) catch continue;
        defer pkg.allocator.free(data);

        var resource = vrf.Resource.init(allocator);
        defer resource.deinit();
        resource.read(data) catch continue;

        const data_block = resource.dataBlock() orelse continue;
        const raw = switch (data_block.data) {
            .data_block => |db| db.raw_data orelse continue,
            else => continue,
        };
        var doc = vrf.binary_kv3.decode(allocator, raw) catch |err| {
            try stdout.print("  KV3 decode error: {}\n", .{err});
            continue;
        };
        defer doc.deinit();
        const root = doc.root.asObject() orelse continue;
        const ekv = root.getArray("m_entityKeyValues") orelse continue;
        try stdout.print("  {d} entities\n", .{ekv.count()});

        // Tally classnames; list every entity that references a model.
        var tally = std.StringHashMap(u32).init(allocator);
        defer {
            var ki = tally.keyIterator();
            while (ki.next()) |k| allocator.free(k.*);
            tally.deinit();
        }
        for (ekv.items.items) |*ev| {
            const eo = ev.asObject() orelse continue;
            const kv3d = eo.getSubCollection("keyValues3Data") orelse continue;
            const values = kv3d.getSubCollection("values") orelse continue;
            const classname = values.getStringProperty("classname") orelse "?";
            const gop = try tally.getOrPut(classname);
            if (!gop.found_existing) {
                gop.key_ptr.* = try allocator.dupe(u8, classname);
                gop.value_ptr.* = 0;
            }
            gop.value_ptr.* += 1;
            if (std.mem.eql(u8, classname, "sky_camera") or std.mem.eql(u8, classname, "worldspawn") or std.mem.eql(u8, classname, "env_sky") or std.mem.eql(u8, classname, "light_environment")) {
                try stdout.print("  ── {s} ──\n", .{classname});
                try dumpObjectDeep(allocator, values, stdout, 4, 0);
            }
            if (std.mem.eql(u8, classname, "skybox_reference")) {
                try stdout.writeAll("  ── skybox_reference ──\n");
                try dumpObjectDeep(allocator, values, stdout, 4, 0);
            }
            if (values.getStringProperty("model")) |model| {
                const origin = values.getStringProperty("origin") orelse "?";
                const angles = values.getStringProperty("angles") orelse "?";
                const scales = values.getStringProperty("scales") orelse "?";
                try stdout.print("  MODEL {s} | {s} | o=({s}) a=({s}) s=({s})\n", .{ classname, model, origin, angles, scales });
            }
        }
        try stdout.writeAll("\n  classname tally:\n");
        var ti = tally.iterator();
        while (ti.next()) |kv| {
            try stdout.print("    {d:>4}  {s}\n", .{ kv.value_ptr.*, kv.key_ptr.* });
        }
    }
}

/// Recursively print an object's keys/values up to `depth` levels.
fn dumpObjectDeep(allocator: std.mem.Allocator, obj: anytype, stdout: anytype, indent: usize, depth: usize) !void {
    for (obj.keys.items, obj.values.items) |k, *v| {
        for (0..indent) |_| try stdout.writeAll(" ");
        const vs = formatKVValue(allocator, v) catch "(err)";
        defer if (!std.mem.eql(u8, vs, "(err)")) allocator.free(vs);
        try stdout.print("{s} = {s}\n", .{ k, vs });
        if (depth > 0) {
            switch (v.*) {
                .object => |o| try dumpObjectDeep(allocator, o, stdout, indent + 2, depth - 1),
                .array => |a| {
                    for (a.items.items, 0..) |*av, ai| {
                        if (ai >= 4) break;
                        for (0..indent + 2) |_| try stdout.writeAll(" ");
                        const avs = formatKVValue(allocator, av) catch "(err)";
                        defer if (!std.mem.eql(u8, avs, "(err)")) allocator.free(avs);
                        try stdout.print("[{d}] = {s}\n", .{ ai, avs });
                        if (av.* == .object) try dumpObjectDeep(allocator, av.object, stdout, indent + 4, depth - 1);
                    }
                },
                else => {},
            }
        }
    }
}

const SubmeshTally = struct {
    name: []const u8,
    count: u32,
};

fn submeshStats(allocator: std.mem.Allocator, vpk_path: []const u8, stdout: anytype) !void {
    var pkg = vrf.vpk.Package.init(allocator);
    defer pkg.deinit();
    pkg.readFile(vpk_path) catch |err| {
        try std.io.getStdErr().writer().print("Error reading VPK: {}\n", .{err});
        std.process.exit(1);
    };

    try stdout.print("Scanning {d} entries for vmdl_c...\n\n", .{pkg.entryCount()});

    var tallies = std.ArrayList(SubmeshTally).init(allocator);
    defer {
        for (tallies.items) |t| allocator.free(t.name);
        tallies.deinit();
    }

    var total_models: u32 = 0;
    var total_submeshes: u64 = 0;
    var failed: u32 = 0;

    var it = pkg.iterateAll();
    while (it.next()) |entry| {
        if (!std.mem.eql(u8, entry.type_name, "vmdl_c")) continue;
        const entry_data = pkg.readEntry(entry) catch {
            failed += 1;
            continue;
        };
        defer allocator.free(entry_data);

        const n = countSubMeshes(allocator, entry_data) catch {
            failed += 1;
            continue;
        };

        const name = allocator.dupe(u8, entry.file_name) catch continue;
        tallies.append(.{ .name = name, .count = n }) catch {
            allocator.free(name);
            continue;
        };
        total_models += 1;
        total_submeshes += n;
    }

    // Sort descending by count so the worst offenders show first.
    std.mem.sort(SubmeshTally, tallies.items, {}, struct {
        fn lessThan(_: void, a: SubmeshTally, b: SubmeshTally) bool {
            return a.count > b.count;
        }
    }.lessThan);

    try stdout.print("══ Submesh Stats ══\n", .{});
    try stdout.print("  Models scanned:    {d}\n", .{total_models});
    try stdout.print("  Failed parses:     {d}\n", .{failed});
    try stdout.print("  Total submeshes:   {d}\n", .{total_submeshes});
    if (total_models > 0) {
        const avg = @as(f64, @floatFromInt(total_submeshes)) / @as(f64, @floatFromInt(total_models));
        try stdout.print("  Avg per model:     {d:.1}\n", .{avg});
    }

    // Distribution buckets
    var b1: u32 = 0;
    var b2_5: u32 = 0;
    var b6_20: u32 = 0;
    var b21_50: u32 = 0;
    var b51_100: u32 = 0;
    var b100p: u32 = 0;
    for (tallies.items) |t| {
        if (t.count == 1) b1 += 1
        else if (t.count <= 5) b2_5 += 1
        else if (t.count <= 20) b6_20 += 1
        else if (t.count <= 50) b21_50 += 1
        else if (t.count <= 100) b51_100 += 1
        else b100p += 1;
    }
    try stdout.print("\n  Distribution:\n", .{});
    try stdout.print("    1 submesh:        {d}\n", .{b1});
    try stdout.print("    2-5 submeshes:    {d}\n", .{b2_5});
    try stdout.print("    6-20 submeshes:   {d}\n", .{b6_20});
    try stdout.print("    21-50 submeshes:  {d}\n", .{b21_50});
    try stdout.print("    51-100 submeshes: {d}\n", .{b51_100});
    try stdout.print("    100+ submeshes:   {d}\n", .{b100p});

    // Top 20 worst offenders
    try stdout.print("\n  Top 20 by submesh count:\n", .{});
    const top_n = @min(@as(usize, 20), tallies.items.len);
    for (tallies.items[0..top_n], 0..) |t, i| {
        try stdout.print("    [{d:>2}] {d:>5}  {s}\n", .{ i + 1, t.count, t.name });
    }
}

fn formatKVValue(allocator: std.mem.Allocator, value: *const vrf.kv3.KVValue) ![]const u8 {
    return switch (value.*) {
        .string => |s| try std.fmt.allocPrint(allocator, "\"{s}\"", .{s}),
        .int32 => |v| try std.fmt.allocPrint(allocator, "{d}", .{v}),
        .uint32 => |v| try std.fmt.allocPrint(allocator, "{d}", .{v}),
        .int64 => |v| try std.fmt.allocPrint(allocator, "{d}", .{v}),
        .uint64 => |v| try std.fmt.allocPrint(allocator, "{d}", .{v}),
        .float32 => |v| try std.fmt.allocPrint(allocator, "{d:.4}", .{v}),
        .float64 => |v| try std.fmt.allocPrint(allocator, "{d:.4}", .{v}),
        .boolean => |v| try std.fmt.allocPrint(allocator, "{}", .{v}),
        .array => |arr| blk: {
            // Small all-numeric arrays (colors, vectors) print inline.
            if (arr.count() > 0 and arr.count() <= 4) {
                var vals: [4]f64 = undefined;
                var all_num = true;
                for (arr.items.items, 0..) |*item, i| {
                    switch (item.*) {
                        .float32 => |f| vals[i] = f,
                        .float64 => |f| vals[i] = f,
                        .int32 => |n| vals[i] = @floatFromInt(n),
                        .uint32 => |n| vals[i] = @floatFromInt(n),
                        .int64 => |n| vals[i] = @floatFromInt(n),
                        .uint64 => |n| vals[i] = @floatFromInt(n),
                        else => all_num = false,
                    }
                    if (!all_num) break;
                }
                if (all_num) {
                    var buf = std.ArrayList(u8).init(allocator);
                    try buf.appendSlice("(");
                    for (0..arr.count()) |i| {
                        if (i > 0) try buf.appendSlice(", ");
                        try buf.writer().print("{d:.4}", .{vals[i]});
                    }
                    try buf.appendSlice(")");
                    break :blk try buf.toOwnedSlice();
                }
            }
            break :blk try std.fmt.allocPrint(allocator, "[array: {d} items]", .{arr.count()});
        },
        .object => |obj| try std.fmt.allocPrint(allocator, "{{object: {d} keys}}", .{obj.keys.items.len}),
        .binary_blob => |b| try std.fmt.allocPrint(allocator, "[blob: {d} bytes]", .{b.len}),
        .null_value => try allocator.dupe(u8, "null"),
    };
}
