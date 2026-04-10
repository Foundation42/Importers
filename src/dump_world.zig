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
        .array => |arr| try std.fmt.allocPrint(allocator, "[array: {d} items]", .{arr.count()}),
        .object => |obj| try std.fmt.allocPrint(allocator, "{{object: {d} keys}}", .{obj.keys.items.len}),
        .binary_blob => |b| try std.fmt.allocPrint(allocator, "[blob: {d} bytes]", .{b.len}),
        .null_value => try allocator.dupe(u8, "null"),
    };
}
