///! Example: Extract mesh geometry from a Source 2 VPK archive.
///!
///! This demonstrates the full pipeline:
///!   VPK -> Resource -> KV3 -> Model -> Mesh -> VBIB -> vertex/index data
///!
///! The extracted positions, normals, texcoords, and indices can be fed
///! directly into Forge's mesh/model system or used to build a glTF.
const std = @import("std");

const vrf = @import("valve-resource-format");

const vpk_mod = vrf.vpk;
const binary_kv3 = vrf.binary_kv3;
const material_mod = vrf.material;
const texture_mod = vrf.texture;
const model_mod = vrf.model;
const mesh_mod = vrf.mesh_mod;
const meshopt = vrf.meshopt;

const Resource = vrf.Resource;
const BinaryReader = vrf.BinaryReader;
const BlockType = vrf.BlockType;

// ============================================================
// Extracted mesh data — ready for Forge
// ============================================================

const ExtractedVertex = struct {
    position: [3]f32,
    normal: [3]f32,
    texcoord: [2]f32,
};

const ExtractedMesh = struct {
    name: []const u8,
    vertices: []ExtractedVertex,
    indices: []u32,
    material_path: []const u8,
};

const ExtractedModel = struct {
    name: []const u8,
    meshes: []ExtractedMesh,
    material_groups: []model_mod.MaterialGroup,
};

// ============================================================
// VBIB binary block parser
// ============================================================

/// Parse a binary VBIB block into vertex and index buffers.
/// This reads the on-disk format directly (not KV3).
const VBIBBufferData = struct {
    element_count: u32,
    element_size: u32,
    attributes: []VBIBAttribute,
    data: []const u8,
};

const VBIBAttribute = struct {
    name: [32]u8,
    name_len: u8,
    semantic_index: i32,
    format: mesh_mod.DxgiFormat,
    offset: u32,
    slot: i32,
};

fn parseVBIBBlock(allocator: std.mem.Allocator, block_data: []const u8, block_offset: u32) !struct {
    vertex_buffers: []VBIBBufferData,
    index_buffers: []VBIBBufferData,
} {
    // The VBIB block starts at block_offset in the file, but we have
    // just the block's bytes here, so offsets are relative to start.
    var r = BinaryReader.fromSlice(block_data, allocator);

    const vertex_buffer_offset = try r.readU32();
    const vertex_buffer_count = try r.readU32();
    const index_buffer_offset = try r.readU32();
    const index_buffer_count = try r.readU32();
    _ = block_offset;

    // Parse vertex buffers
    var vertex_buffers = try allocator.alloc(VBIBBufferData, vertex_buffer_count);
    r.setPosition(vertex_buffer_offset);
    for (0..vertex_buffer_count) |i| {
        vertex_buffers[i] = try readOnDiskBuffer(&r, allocator, true);
    }

    // Parse index buffers
    var index_buffers = try allocator.alloc(VBIBBufferData, index_buffer_count);
    r.setPosition(8 + index_buffer_offset); // +8 for the vertex offset/count fields
    for (0..index_buffer_count) |i| {
        index_buffers[i] = try readOnDiskBuffer(&r, allocator, false);
    }

    return .{ .vertex_buffers = vertex_buffers, .index_buffers = index_buffers };
}

fn readOnDiskBuffer(r: *BinaryReader, allocator: std.mem.Allocator, is_vertex: bool) !VBIBBufferData {
    const element_count = try r.readU32();
    const size_raw = try r.readI32();
    const element_size: u32 = @intCast(size_raw & 0x3FFFFFF);
    const is_compressed = size_raw < 0 or (size_raw & 0x8000000) != 0;
    _ = is_compressed;

    // Attribute offset/count (relative to refA)
    const ref_a = r.position();
    const attr_offset = try r.readU32();
    const attr_count = try r.readU32();

    // Data offset/size (relative to refB)
    const ref_b = r.position();
    const data_offset = try r.readU32();
    _ = try r.readI32(); // total_size (compressed size)

    // Read attributes
    var attrs = try allocator.alloc(VBIBAttribute, attr_count);
    r.setPosition(ref_a + attr_offset);
    for (0..attr_count) |i| {
        const name_start = r.position();
        var name_buf: [32]u8 = .{0} ** 32;
        _ = try r.readBytes(&name_buf);
        r.setPosition(name_start + 32); // fixed 32-byte field

        // Find null terminator for name length
        var name_len: u8 = 0;
        for (name_buf) |c| {
            if (c == 0) break;
            name_len += 1;
        }

        attrs[i] = .{
            .name = name_buf,
            .name_len = name_len,
            .semantic_index = try r.readI32(),
            .format = @enumFromInt(try r.readU32()),
            .offset = try r.readU32(),
            .slot = try r.readI32(),
        };
        _ = try r.readU32(); // slot_type
        _ = try r.readI32(); // instance_step_rate
    }

    // Read raw vertex/index data
    r.setPosition(ref_b + data_offset);
    const decompressed_size = element_count * element_size;
    const total_size_raw = try r.readI32();
    _ = total_size_raw;
    // Re-read: we already read total_size above, go back
    r.setPosition(ref_b + data_offset);

    // Read the compressed (or raw) buffer
    const on_disk_bytes = try r.readBytesAlloc(decompressed_size);

    // Try meshopt decompression if the data looks compressed
    var data: []const u8 = undefined;
    if (on_disk_bytes.len > 0 and (on_disk_bytes[0] & 0xF0) == 0xa0 and is_vertex) {
        // Meshopt vertex compressed
        data = meshopt.decodeVertexBuffer(allocator, element_count, element_size, on_disk_bytes) catch on_disk_bytes;
    } else if (on_disk_bytes.len > 0 and (on_disk_bytes[0] & 0xF0) == 0xe0 and !is_vertex) {
        // Meshopt index compressed
        data = meshopt.decodeIndexBuffer(allocator, element_count, element_size, on_disk_bytes) catch on_disk_bytes;
    } else {
        data = on_disk_bytes;
    }

    return .{
        .element_count = element_count,
        .element_size = element_size,
        .attributes = attrs,
        .data = data,
    };
}

// ============================================================
// Vertex extraction helpers
// ============================================================

fn extractVertices(allocator: std.mem.Allocator, vb: *const VBIBBufferData) ![]ExtractedVertex {
    var vertices = try allocator.alloc(ExtractedVertex, vb.element_count);

    // Find attribute offsets
    var pos_offset: ?u32 = null;
    var pos_format: mesh_mod.DxgiFormat = .unknown;
    var normal_offset: ?u32 = null;
    var normal_format: mesh_mod.DxgiFormat = .unknown;
    var texcoord_offset: ?u32 = null;
    var texcoord_format: mesh_mod.DxgiFormat = .unknown;

    for (vb.attributes) |attr| {
        const name = attr.name[0..attr.name_len];
        if (std.ascii.eqlIgnoreCase(name, "POSITION")) {
            pos_offset = attr.offset;
            pos_format = attr.format;
        } else if (std.ascii.eqlIgnoreCase(name, "NORMAL")) {
            normal_offset = attr.offset;
            normal_format = attr.format;
        } else if (std.ascii.eqlIgnoreCase(name, "TEXCOORD")) {
            texcoord_offset = attr.offset;
            texcoord_format = attr.format;
        }
    }

    const stride = vb.element_size;

    for (0..vb.element_count) |i| {
        const base = i * stride;
        var vert = ExtractedVertex{
            .position = .{ 0, 0, 0 },
            .normal = .{ 0, 0, 1 },
            .texcoord = .{ 0, 0 },
        };

        // Position (typically R32G32B32_FLOAT)
        if (pos_offset) |off| {
            const o = base + off;
            if (pos_format == .r32g32b32_float and o + 12 <= vb.data.len) {
                vert.position[0] = @bitCast(std.mem.readInt(u32, vb.data[o..][0..4], .little));
                vert.position[1] = @bitCast(std.mem.readInt(u32, vb.data[o + 4 ..][0..4], .little));
                vert.position[2] = @bitCast(std.mem.readInt(u32, vb.data[o + 8 ..][0..4], .little));
            }
        }

        // Normal (R32G32B32_FLOAT, R32_UINT compressed, or R8G8B8A8_UNORM)
        if (normal_offset) |off| {
            const o = base + off;
            if (normal_format == .r32g32b32_float and o + 12 <= vb.data.len) {
                vert.normal[0] = @bitCast(std.mem.readInt(u32, vb.data[o..][0..4], .little));
                vert.normal[1] = @bitCast(std.mem.readInt(u32, vb.data[o + 4 ..][0..4], .little));
                vert.normal[2] = @bitCast(std.mem.readInt(u32, vb.data[o + 8 ..][0..4], .little));
            } else if (normal_format == .r32_uint and o + 4 <= vb.data.len) {
                // CS2 compressed normal+tangent packed into a single u32
                const normal_raw = std.mem.readInt(u32, vb.data[o..][0..4], .little);
                vert.normal = meshopt.decompressNormal(normal_raw);
            } else if (normal_format == .r8g8b8a8_unorm and o + 4 <= vb.data.len) {
                // Unpack unsigned byte normal: [0,255] -> [-1,1]
                vert.normal[0] = @as(f32, @floatFromInt(vb.data[o])) / 127.5 - 1.0;
                vert.normal[1] = @as(f32, @floatFromInt(vb.data[o + 1])) / 127.5 - 1.0;
                vert.normal[2] = @as(f32, @floatFromInt(vb.data[o + 2])) / 127.5 - 1.0;
            }
        }

        // Texcoord (R16G16_FLOAT or R32G32_FLOAT)
        if (texcoord_offset) |off| {
            const o = base + off;
            if (texcoord_format == .r32g32_float and o + 8 <= vb.data.len) {
                vert.texcoord[0] = @bitCast(std.mem.readInt(u32, vb.data[o..][0..4], .little));
                vert.texcoord[1] = @bitCast(std.mem.readInt(u32, vb.data[o + 4 ..][0..4], .little));
            } else if (texcoord_format == .r16g16_float and o + 4 <= vb.data.len) {
                vert.texcoord[0] = halfToFloat(std.mem.readInt(u16, vb.data[o..][0..2], .little));
                vert.texcoord[1] = halfToFloat(std.mem.readInt(u16, vb.data[o + 2 ..][0..2], .little));
            }
        }

        vertices[i] = vert;
    }

    return vertices;
}

fn extractIndices(allocator: std.mem.Allocator, ib: *const VBIBBufferData) ![]u32 {
    var indices = try allocator.alloc(u32, ib.element_count);

    for (0..ib.element_count) |i| {
        if (ib.element_size == 2) {
            // 16-bit indices
            const o = i * 2;
            indices[i] = std.mem.readInt(u16, ib.data[o..][0..2], .little);
        } else if (ib.element_size == 4) {
            // 32-bit indices
            const o = i * 4;
            indices[i] = std.mem.readInt(u32, ib.data[o..][0..4], .little);
        }
    }

    return indices;
}

/// Convert IEEE 754 half-precision float to single-precision.
fn halfToFloat(h: u16) f32 {
    const sign: u32 = @as(u32, h >> 15) << 31;
    const exp: u32 = (h >> 10) & 0x1F;
    const mant: u32 = h & 0x3FF;

    if (exp == 0) {
        if (mant == 0) return @bitCast(sign); // +/- zero
        // Denormalized
        var m = mant;
        var e: u32 = 113;
        while (m & 0x400 == 0) {
            m <<= 1;
            e -= 1;
        }
        return @bitCast(sign | (e << 23) | ((m & 0x3FF) << 13));
    } else if (exp == 31) {
        // Inf / NaN
        return @bitCast(sign | 0x7F800000 | (mant << 13));
    }

    return @bitCast(sign | ((exp + 112) << 23) | (mant << 13));
}

// ============================================================
// Full extraction example
// ============================================================

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const stdout = std.io.getStdOut().writer();

    // ----------------------------------------------------------
    // 1. Open VPK archive
    // ----------------------------------------------------------
    try stdout.writeAll("=== Source 2 Mesh Extraction Example ===\n\n");

    var pkg = vpk_mod.Package.init(allocator);
    defer pkg.deinit();

    const vpk_file = std.fs.cwd().openFile("test_files/small_map_with_material.vpk", .{}) catch {
        try stdout.writeAll("Put small_map_with_material.vpk in test_files/ first.\n");
        try stdout.writeAll("Download from: https://github.com/ValveResourceFormat/ValveResourceFormat/tree/master/Tests/Files\n");
        return;
    };
    defer vpk_file.close();
    const vpk_data = try vpk_file.readToEndAlloc(allocator, 1 << 24);
    defer allocator.free(vpk_data);
    try pkg.read(vpk_data);

    try stdout.print("Opened VPK: {d} entries\n\n", .{pkg.entryCount()});

    // ----------------------------------------------------------
    // 2. Find and extract the model resource
    // ----------------------------------------------------------
    // This VPK has an embedded mesh model for the nametag map
    const model_path = "maps/ui/nametag/worldnodes/node000_lr0_c2_s_cb_mesh_mat0_tile_floor_diam.vmdl_c";

    const model_entry = pkg.findEntry(model_path) orelse {
        try stdout.writeAll("Model not found in VPK. Listing available models:\n");
        var it = pkg.iterateAll();
        while (it.next()) |entry| {
            if (std.mem.endsWith(u8, entry.type_name, "vmdl_c")) {
                const p = try entry.getFullPath(allocator);
                defer allocator.free(p);
                try stdout.print("  {s}\n", .{p});
            }
        }
        return;
    };

    const model_data = try pkg.readEntry(model_entry);
    defer allocator.free(model_data);
    try stdout.print("Step 2: Extracted {s} ({d} bytes)\n", .{ model_path, model_data.len });

    // ----------------------------------------------------------
    // 3. Parse the resource file
    // ----------------------------------------------------------
    var resource = Resource.init(allocator);
    defer resource.deinit();
    resource.resource_type = .model;
    try resource.read(model_data);

    try stdout.print("Step 3: Parsed resource — {d} blocks:\n", .{resource.blocks.items.len});
    for (resource.blocks.items) |blk| {
        const tag = blk.block_type.toTag();
        try stdout.print("  {s}  offset={d}  size={d}\n", .{ tag, blk.offset, blk.size });
    }
    try stdout.writeAll("\n");

    // ----------------------------------------------------------
    // 4. Parse the DATA block as KV3 to get model metadata
    // ----------------------------------------------------------
    for (resource.blocks.items) |blk| {
        if (blk.block_type == .data) {
            const raw = switch (blk.data) {
                .data_block => |db| db.raw_data orelse continue,
                else => continue,
            };

            if (raw.len >= 4 and binary_kv3.isBinaryKV3(std.mem.readInt(u32, raw[0..4], .little))) {
                var doc = binary_kv3.decode(allocator, raw) catch |err| {
                    try stdout.print("KV3 decode error: {}\n", .{err});
                    continue;
                };
                defer doc.deinit();

                if (doc.root.asObject()) |root| {
                    // Parse as model
                    var model = model_mod.Model.init(allocator);
                    defer model.deinit();
                    model.readFromKV3(root) catch {};

                    try stdout.print("Step 4: Model name: {s}\n", .{model.name orelse "(embedded)"});
                    try stdout.print("  Referenced meshes: {d}\n", .{model.ref_meshes.len});
                    for (model.ref_meshes) |m| try stdout.print("    {s}\n", .{m});
                    try stdout.print("  Material groups: {d}\n", .{model.material_groups.len});
                    for (model.material_groups) |mg| {
                        try stdout.print("    {s}: {d} materials\n", .{ mg.name, mg.materials.len });
                        for (mg.materials) |mat| try stdout.print("      {s}\n", .{mat});
                    }
                    try stdout.print("  Mesh groups: {d}\n", .{model.mesh_groups.len});
                    for (model.mesh_groups) |g| try stdout.print("    {s}\n", .{g});
                }
            }
        }
    }

    // ----------------------------------------------------------
    // 5. Find and parse VBIB block (raw vertex/index data)
    // ----------------------------------------------------------
    // The VBIB block contains the actual geometry. In this embedded
    // model, it's stored in the MBUF block (same binary format).
    for (resource.blocks.items) |blk| {
        const is_vbib = blk.block_type == .vbib;
        const is_mbuf = blk.block_type == .mbuf;
        if (!is_vbib and !is_mbuf) continue;

        // Read the raw block data from the resource
        if (blk.size == 0) continue;
        const block_data = model_data[blk.offset..][0..blk.size];

        const tag = blk.block_type.toTag();
        try stdout.print("\nStep 5: Parsing {s} block ({d} bytes)\n", .{ tag, blk.size });

        const parsed = parseVBIBBlock(allocator, block_data, blk.offset) catch |err| {
            try stdout.print("  VBIB parse error: {}\n", .{err});
            continue;
        };
        defer {
            for (parsed.vertex_buffers) |vb| {
                allocator.free(vb.attributes);
                allocator.free(vb.data);
            }
            allocator.free(parsed.vertex_buffers);
            for (parsed.index_buffers) |ib| {
                allocator.free(ib.attributes);
                allocator.free(ib.data);
            }
            allocator.free(parsed.index_buffers);
        }

        try stdout.print("  Vertex buffers: {d}\n", .{parsed.vertex_buffers.len});
        for (parsed.vertex_buffers, 0..) |vb, vi| {
            try stdout.print("  VB[{d}]: {d} vertices, stride={d}\n", .{ vi, vb.element_count, vb.element_size });
            for (vb.attributes) |attr| {
                const n = attr.name[0..attr.name_len];
                try stdout.print("    {s}[{d}]  format={d}  offset={d}\n", .{ n, attr.semantic_index, @intFromEnum(attr.format), attr.offset });
            }

            // Extract actual vertex data
            const vertices = try extractVertices(allocator, &vb);
            defer allocator.free(vertices);

            // Print first few vertices
            const show = @min(vertices.len, 5);
            try stdout.print("  First {d} vertices:\n", .{show});
            for (vertices[0..show]) |v| {
                try stdout.print("    pos=({d:.3}, {d:.3}, {d:.3})  normal=({d:.2}, {d:.2}, {d:.2})  uv=({d:.3}, {d:.3})\n", .{
                    v.position[0], v.position[1], v.position[2],
                    v.normal[0],   v.normal[1],   v.normal[2],
                    v.texcoord[0], v.texcoord[1],
                });
            }
        }

        try stdout.print("  Index buffers: {d}\n", .{parsed.index_buffers.len});
        for (parsed.index_buffers, 0..) |ib, ii| {
            try stdout.print("  IB[{d}]: {d} indices, size={d} bytes/index\n", .{ ii, ib.element_count, ib.element_size });

            const indices = try extractIndices(allocator, &ib);
            defer allocator.free(indices);

            const show = @min(indices.len, 12);
            try stdout.print("  First {d} indices: ", .{show});
            for (indices[0..show]) |idx| {
                try stdout.print("{d} ", .{idx});
            }
            try stdout.writeAll("\n");

            // Triangle count
            if (indices.len >= 3) {
                try stdout.print("  Triangles: {d}\n", .{indices.len / 3});
            }
        }
    }

    // ----------------------------------------------------------
    // 6. Extract the material for this mesh
    // ----------------------------------------------------------
    try stdout.writeAll("\nStep 6: Material lookup\n");
    if (pkg.findEntry("materials/cs_italy/ground/tile_floor_diamond_1.vmat_c")) |mat_entry| {
        const mat_data = try pkg.readEntry(mat_entry);
        defer allocator.free(mat_data);

        var mat_resource = Resource.init(allocator);
        defer mat_resource.deinit();
        mat_resource.resource_type = .material;
        try mat_resource.read(mat_data);

        for (mat_resource.blocks.items) |blk| {
            if (blk.block_type != .data) continue;
            const raw = switch (blk.data) {
                .data_block => |db| db.raw_data orelse continue,
                else => continue,
            };
            if (raw.len < 4) continue;
            if (!binary_kv3.isBinaryKV3(std.mem.readInt(u32, raw[0..4], .little))) continue;

            var doc = binary_kv3.decode(allocator, raw) catch continue;
            defer doc.deinit();

            var mat = material_mod.Material.init(allocator);
            defer mat.deinit();
            mat.readFromKV3(doc.root.asObject().?) catch continue;

            try stdout.print("  Shader: {s}\n", .{mat.shader_name orelse "(none)"});
            var tex_it = mat.texture_params.iterator();
            while (tex_it.next()) |entry| {
                try stdout.print("  {s} -> {s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
            }
        }
    }

    // ----------------------------------------------------------
    // 7. Decode a texture to pixels
    // ----------------------------------------------------------
    try stdout.writeAll("\nStep 7: Texture decode\n");
    if (pkg.findEntry("materials/cs_italy/ground/tile_floor_diamond_1_color_psd_87178d3c.vtex_c")) |tex_entry| {
        const tex_data = try pkg.readEntry(tex_entry);
        defer allocator.free(tex_data);

        var tex_resource = Resource.init(allocator);
        defer tex_resource.deinit();
        tex_resource.resource_type = .texture;
        try tex_resource.read(tex_data);

        for (tex_resource.blocks.items) |blk| {
            if (blk.block_type != .data) continue;
            const raw = switch (blk.data) {
                .data_block => |db| db.raw_data orelse continue,
                else => continue,
            };

            var tex = texture_mod.Texture.init(allocator);
            defer tex.deinit();
            tex.readHeader(raw) catch continue;

            try stdout.print("  Format: {}, Size: {d}x{d}, Mips: {d}\n", .{
                tex.format, tex.width, tex.height, tex.num_mip_levels,
            });

            if (tex.decodeRGBA()) |rgba| {
                defer allocator.free(rgba);
                try stdout.print("  Decoded to RGBA: {d} bytes ({d}x{d})\n", .{
                    rgba.len, tex.actualWidth(), tex.actualHeight(),
                });
                // In Forge, you'd now do:
                //   const rl_image = rl.Image{ .data = rgba.ptr, .width = ..., ... };
                //   const gpu_tex = rl.LoadTextureFromImage(rl_image);
            } else |err| {
                try stdout.print("  Decode error: {}\n", .{err});
            }
        }
    }

    try stdout.writeAll("\n=== Done! All data extracted and ready for Forge. ===\n");
}
