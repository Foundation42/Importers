const std = @import("std");
const kv3 = @import("kv3.zig");
const KVObject = kv3.KVObject;
const KVArray = kv3.KVArray;
const KVValue = kv3.KVValue;
const BinaryReader = @import("binary_reader.zig").BinaryReader;
const meshopt = @import("meshopt.zig");

// ============================================================
// DXGI_FORMAT subset (common vertex attribute formats)
// ============================================================

pub const DxgiFormat = enum(u32) {
    unknown = 0,
    r32g32b32a32_float = 2,
    r32g32b32_float = 6,
    r16g16b16a16_float = 10,
    r16g16b16a16_unorm = 11,
    r16g16b16a16_sint = 14,
    r32g32_float = 16,
    r8g8b8a8_unorm = 28,
    r8g8b8a8_uint = 30,
    r16g16_float = 34,
    r16g16_unorm = 35,
    r16g16_snorm = 37,
    r16g16_sint = 38,
    r32_float = 41,
    r32_uint = 42,
    r8g8_unorm = 49,
    r16_float = 54,
    r16_unorm = 56,
    r8_unorm = 61,
    _,

    /// Byte size of this format.
    pub fn byteSize(self: DxgiFormat) u32 {
        return switch (self) {
            .r32g32b32a32_float => 16,
            .r32g32b32_float => 12,
            .r16g16b16a16_float, .r16g16b16a16_unorm, .r16g16b16a16_sint => 8,
            .r32g32_float => 8,
            .r8g8b8a8_unorm, .r8g8b8a8_uint => 4,
            .r16g16_float, .r16g16_unorm, .r16g16_snorm, .r16g16_sint => 4,
            .r32_float, .r32_uint => 4,
            .r8g8_unorm => 2,
            .r16_float, .r16_unorm => 2,
            .r8_unorm => 1,
            else => 0,
        };
    }
};

// ============================================================
// Vertex attribute layout
// ============================================================

pub const RenderInputLayoutField = struct {
    semantic_name: []const u8,
    semantic_index: i32 = 0,
    format: DxgiFormat = .unknown,
    offset: u32 = 0,
    slot: i32 = 0,
    shader_semantic: []const u8 = "",
};

// ============================================================
// Vertex / Index Buffer with typed accessors
// ============================================================

pub const BufferData = struct {
    element_count: u32 = 0,
    element_size_in_bytes: u32 = 0,
    input_layout: []RenderInputLayoutField = &.{},
    data: []const u8 = &.{},

    /// Find an attribute by semantic name (case-insensitive).
    pub fn findAttribute(self: *const BufferData, name: []const u8) ?*const RenderInputLayoutField {
        for (self.input_layout) |*field| {
            if (std.ascii.eqlIgnoreCase(field.semantic_name, name)) return field;
        }
        return null;
    }

    /// Get a vec3 float position for vertex i.
    pub fn getPosition(self: *const BufferData, i: u32) [3]f32 {
        const attr = self.findAttribute("POSITION") orelse return .{ 0, 0, 0 };
        const o = self.vertexOffset(i, attr.offset);
        if (attr.format == .r32g32b32_float and o + 12 <= self.data.len) {
            return readF32x3(self.data, o);
        }
        return .{ 0, 0, 0 };
    }

    /// Get a decoded normal for vertex i. Handles R32_UINT compressed normals.
    pub fn getNormal(self: *const BufferData, i: u32) [3]f32 {
        const attr = self.findAttribute("NORMAL") orelse return .{ 0, 0, 1 };
        const o = self.vertexOffset(i, attr.offset);

        if (attr.format == .r32_uint and o + 4 <= self.data.len) {
            // CS2 compressed normal+tangent in a single u32
            const raw = std.mem.readInt(u32, self.data[o..][0..4], .little);
            return meshopt.decompressNormal(raw);
        } else if (attr.format == .r32g32b32_float and o + 12 <= self.data.len) {
            return readF32x3(self.data, o);
        } else if (attr.format == .r8g8b8a8_unorm and o + 4 <= self.data.len) {
            return .{
                @as(f32, @floatFromInt(self.data[o])) / 127.5 - 1.0,
                @as(f32, @floatFromInt(self.data[o + 1])) / 127.5 - 1.0,
                @as(f32, @floatFromInt(self.data[o + 2])) / 127.5 - 1.0,
            };
        }
        return .{ 0, 0, 1 };
    }

    /// Get a decoded tangent for vertex i. Handles R32_UINT compressed tangents.
    pub fn getTangent(self: *const BufferData, i: u32) [4]f32 {
        const attr = self.findAttribute("NORMAL") orelse return .{ 1, 0, 0, 1 };
        const o = self.vertexOffset(i, attr.offset);

        if (attr.format == .r32_uint and o + 4 <= self.data.len) {
            const raw = std.mem.readInt(u32, self.data[o..][0..4], .little);
            return meshopt.decompressTangent(raw);
        }

        // Try separate TANGENT attribute
        const tangent_attr = self.findAttribute("TANGENT") orelse return .{ 1, 0, 0, 1 };
        const to = self.vertexOffset(i, tangent_attr.offset);
        if (tangent_attr.format == .r32g32b32a32_float and to + 16 <= self.data.len) {
            return .{
                readF32(self.data, to),
                readF32(self.data, to + 4),
                readF32(self.data, to + 8),
                readF32(self.data, to + 12),
            };
        }
        return .{ 1, 0, 0, 1 };
    }

    /// Get texcoord for vertex i. Handles R16G16_FLOAT and R32G32_FLOAT.
    pub fn getTexcoord(self: *const BufferData, i: u32) [2]f32 {
        return self.getTexcoordN(i, 0);
    }

    /// Get texcoord at semantic index N for vertex i.
    pub fn getTexcoordN(self: *const BufferData, i: u32, semantic_index: i32) [2]f32 {
        for (self.input_layout) |*field| {
            if (std.ascii.eqlIgnoreCase(field.semantic_name, "TEXCOORD") and field.semantic_index == semantic_index) {
                const o = self.vertexOffset(i, field.offset);
                if (field.format == .r32g32_float and o + 8 <= self.data.len) {
                    return .{ readF32(self.data, o), readF32(self.data, o + 4) };
                } else if (field.format == .r16g16_float and o + 4 <= self.data.len) {
                    return .{
                        halfToFloat(std.mem.readInt(u16, self.data[o..][0..2], .little)),
                        halfToFloat(std.mem.readInt(u16, self.data[o + 2 ..][0..2], .little)),
                    };
                } else if (field.format == .r16g16_snorm and o + 4 <= self.data.len) {
                    const x = std.mem.readInt(i16, self.data[o..][0..2], .little);
                    const y = std.mem.readInt(i16, self.data[o + 2 ..][0..2], .little);
                    return .{
                        @as(f32, @floatFromInt(x)) / 32767.0,
                        @as(f32, @floatFromInt(y)) / 32767.0,
                    };
                }
            }
        }
        return .{ 0, 0 };
    }

    /// Get vertex color for vertex i as RGBA floats [0..1].
    pub fn getColor(self: *const BufferData, i: u32) [4]f32 {
        const attr = self.findAttribute("COLOR") orelse return .{ 1, 1, 1, 1 };
        const o = self.vertexOffset(i, attr.offset);

        if (attr.format == .r8g8b8a8_unorm and o + 4 <= self.data.len) {
            return .{
                @as(f32, @floatFromInt(self.data[o])) / 255.0,
                @as(f32, @floatFromInt(self.data[o + 1])) / 255.0,
                @as(f32, @floatFromInt(self.data[o + 2])) / 255.0,
                @as(f32, @floatFromInt(self.data[o + 3])) / 255.0,
            };
        } else if (attr.format == .r32g32b32a32_float and o + 16 <= self.data.len) {
            return .{ readF32(self.data, o), readF32(self.data, o + 4), readF32(self.data, o + 8), readF32(self.data, o + 12) };
        }
        return .{ 1, 1, 1, 1 };
    }

    /// Get Source 2 blend paint for vertex i (TEXCOORD semantic index 4,
    /// byte-per-channel). Two-layer world materials store the layer-2 blend
    /// factor in R (G = layer-3 factor, A = softness paint). Returns null
    /// when the stream is absent.
    pub fn getBlendPaint(self: *const BufferData, i: u32) ?[4]f32 {
        for (self.input_layout) |*field| {
            if (field.semantic_index == 4 and
                (field.format == .r8g8b8a8_unorm or field.format == .r8g8b8a8_uint) and
                std.ascii.eqlIgnoreCase(field.semantic_name, "TEXCOORD"))
            {
                const o = self.vertexOffset(i, field.offset);
                if (o + 4 > self.data.len) return null;
                return .{
                    @as(f32, @floatFromInt(self.data[o])) / 255.0,
                    @as(f32, @floatFromInt(self.data[o + 1])) / 255.0,
                    @as(f32, @floatFromInt(self.data[o + 2])) / 255.0,
                    @as(f32, @floatFromInt(self.data[o + 3])) / 255.0,
                };
            }
        }
        return null;
    }

    /// Get index value at position i from an index buffer.
    pub fn getIndex(self: *const BufferData, i: u32) u32 {
        if (self.element_size_in_bytes == 2) {
            const o = @as(usize, i) * 2;
            if (o + 2 <= self.data.len) return std.mem.readInt(u16, self.data[o..][0..2], .little);
        } else if (self.element_size_in_bytes == 4) {
            const o = @as(usize, i) * 4;
            if (o + 4 <= self.data.len) return std.mem.readInt(u32, self.data[o..][0..4], .little);
        }
        return 0;
    }

    fn vertexOffset(self: *const BufferData, vertex: u32, attr_offset: u32) usize {
        return @as(usize, vertex) * @as(usize, self.element_size_in_bytes) + @as(usize, attr_offset);
    }
};

// ============================================================
// VBIB — binary block parser with meshopt decompression
// ============================================================

pub const VBIB = struct {
    allocator: std.mem.Allocator,
    vertex_buffers: []BufferData = &.{},
    index_buffers: []BufferData = &.{},

    pub fn init(allocator: std.mem.Allocator) VBIB {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *VBIB) void {
        for (self.vertex_buffers) |vb| {
            for (vb.input_layout) |field| {
                self.allocator.free(field.semantic_name);
                if (field.shader_semantic.len > 0) self.allocator.free(field.shader_semantic);
            }
            self.allocator.free(vb.input_layout);
            if (vb.data.len > 0) self.allocator.free(@constCast(vb.data));
        }
        self.allocator.free(self.vertex_buffers);

        for (self.index_buffers) |ib| {
            if (ib.data.len > 0) self.allocator.free(@constCast(ib.data));
        }
        self.allocator.free(self.index_buffers);
    }

    /// Parse a binary VBIB or MBUF block. Handles meshopt decompression.
    /// `block_data` is the raw bytes of the block (from Resource.blocks).
    pub fn readFromBinaryBlock(allocator: std.mem.Allocator, block_data: []const u8) !VBIB {
        var r = BinaryReader.fromSlice(block_data, allocator);

        const vertex_buffer_offset = try r.readU32();
        const vertex_buffer_count = try r.readU32();
        const index_buffer_offset = try r.readU32();
        const index_buffer_count = try r.readU32();

        var vbib = VBIB.init(allocator);
        errdefer vbib.deinit();

        // Parse vertex buffers
        vbib.vertex_buffers = try allocator.alloc(BufferData, vertex_buffer_count);
        r.setPosition(vertex_buffer_offset);
        for (0..vertex_buffer_count) |i| {
            vbib.vertex_buffers[i] = try readOnDiskBuffer(&r, allocator, true);
        }

        // Parse index buffers
        vbib.index_buffers = try allocator.alloc(BufferData, index_buffer_count);
        r.setPosition(8 + index_buffer_offset); // +8 for vertex offset/count fields
        for (0..index_buffer_count) |i| {
            vbib.index_buffers[i] = try readOnDiskBuffer(&r, allocator, false);
        }

        return vbib;
    }

    /// Parse VBIB from KV3 data (used by some resource types).
    pub fn readFromKV3(self: *VBIB, root: *const KVObject) !void {
        if (root.getArray("m_vertexBuffers")) |vb_arr| {
            self.vertex_buffers = try self.readKV3Buffers(vb_arr, true);
        }
        if (root.getArray("m_indexBuffers")) |ib_arr| {
            self.index_buffers = try self.readKV3Buffers(ib_arr, false);
        }
    }

    fn readKV3Buffers(self: *VBIB, arr: *const KVArray, is_vertex: bool) ![]BufferData {
        const buffers = try self.allocator.alloc(BufferData, arr.count());
        errdefer self.allocator.free(buffers);

        for (arr.items.items, 0..) |*item, i| {
            const obj = item.asObject() orelse continue;
            buffers[i] = .{
                .element_count = obj.getU32Property("m_nElementCount") orelse 0,
                .element_size_in_bytes = obj.getU32Property("m_nElementSizeInBytes") orelse 0,
            };

            if (is_vertex) {
                if (obj.getArray("m_inputLayoutFields")) |layout_arr| {
                    const fields = try self.allocator.alloc(RenderInputLayoutField, layout_arr.count());
                    for (layout_arr.items.items, 0..) |*field_val, fi| {
                        const field_obj = field_val.asObject() orelse continue;
                        fields[fi] = .{
                            .semantic_name = try self.allocator.dupe(u8, field_obj.getStringProperty("m_pSemanticName") orelse ""),
                            .semantic_index = if (field_obj.get("m_nSemanticIndex")) |v| v.asI32() orelse 0 else 0,
                            .format = @enumFromInt(field_obj.getU32Property("m_Format") orelse 0),
                            .offset = field_obj.getU32Property("m_nOffset") orelse 0,
                            .slot = if (field_obj.get("m_nSlot")) |v| v.asI32() orelse 0 else 0,
                            .shader_semantic = try self.allocator.dupe(u8, field_obj.getStringProperty("m_szShaderSemantic") orelse ""),
                        };
                    }
                    buffers[i].input_layout = fields;
                }
            }
        }

        return buffers;
    }

    /// Build VBIB from CTRL embedded mesh KV3 data.
    /// `embedded_mesh` is one entry from the `embedded_meshes` array in CTRL.
    /// `resource` is used to look up MVTX/MIDX blocks by index.
    pub fn readFromEmbeddedMesh(allocator: std.mem.Allocator, embedded_mesh: *const KVObject, resource: anytype) !VBIB {
        var vbib = VBIB.init(allocator);
        errdefer vbib.deinit();

        // Parse vertex buffers
        if (embedded_mesh.getArray("m_vertexBuffers")) |vb_arr| {
            vbib.vertex_buffers = try allocator.alloc(BufferData, vb_arr.count());
            for (vb_arr.items.items, 0..) |*vb_val, i| {
                const vb_obj = vb_val.asObject() orelse continue;
                vbib.vertex_buffers[i] = try embeddedBufferFromKV3(allocator, vb_obj, resource, true);
            }
        }

        // Parse index buffers
        if (embedded_mesh.getArray("m_indexBuffers")) |ib_arr| {
            vbib.index_buffers = try allocator.alloc(BufferData, ib_arr.count());
            for (ib_arr.items.items, 0..) |*ib_val, i| {
                const ib_obj = ib_val.asObject() orelse continue;
                vbib.index_buffers[i] = try embeddedBufferFromKV3(allocator, ib_obj, resource, false);
            }
        }

        return vbib;
    }
};

/// Parse a single vertex or index buffer from CTRL KV3 + raw block data.
fn embeddedBufferFromKV3(allocator: std.mem.Allocator, data: *const KVObject, resource: anytype, is_vertex: bool) !BufferData {
    const element_count = data.getU32Property("m_nElementCount") orelse 0;
    const element_size = data.getU32Property("m_nElementSizeInBytes") orelse 0;

    // Parse input layout fields (vertex attributes)
    var layout: []RenderInputLayoutField = &.{};
    if (is_vertex) {
        if (data.getArray("m_inputLayoutFields")) |layout_arr| {
            layout = try allocator.alloc(RenderInputLayoutField, layout_arr.count());
            for (layout_arr.items.items, 0..) |*field_val, fi| {
                const field_obj = field_val.asObject() orelse continue;
                // Semantic name can be string or binary blob
                const raw_name = field_obj.getStringProperty("m_pSemanticName") orelse "";
                var upper_buf = try allocator.alloc(u8, raw_name.len);
                for (raw_name, 0..) |c, ci| {
                    upper_buf[ci] = std.ascii.toUpper(c);
                }
                layout[fi] = .{
                    .semantic_name = upper_buf,
                    .semantic_index = if (field_obj.get("m_nSemanticIndex")) |v| v.asI32() orelse 0 else 0,
                    .format = @enumFromInt(field_obj.getU32Property("m_Format") orelse 0),
                    .offset = field_obj.getU32Property("m_nOffset") orelse 0,
                    .slot = if (field_obj.get("m_nSlot")) |v| v.asI32() orelse 0 else 0,
                };
            }
        }
    }

    // Get raw data from the referenced block
    const block_index = data.getU32Property("m_nBlockIndex") orelse return BufferData{
        .element_count = element_count,
        .element_size_in_bytes = element_size,
        .input_layout = layout,
    };
    const is_meshopt = if (data.get("m_bMeshoptCompressed")) |v| blk: {
        break :blk v.asBool() orelse (if (v.asI32()) |i| i != 0 else false);
    } else false;

    const block = resource.getBlockByIndex(@intCast(block_index)) orelse return error.InvalidBlockIndex;
    const raw_data = switch (block.data) {
        .data_block => |db| db.raw_data orelse return error.NoBlockData,
        else => return error.UnexpectedBlockType,
    };

    const decompressed_size: usize = @as(usize, element_count) * @as(usize, element_size);

    var buf_data: []const u8 = undefined;

    if (is_meshopt and raw_data.len < decompressed_size and raw_data.len > 0) {
        // Meshopt compressed
        if (is_vertex) {
            buf_data = meshopt.decodeVertexBuffer(allocator, element_count, element_size, raw_data) catch {
                buf_data = try allocator.dupe(u8, raw_data);
                return .{
                    .element_count = element_count,
                    .element_size_in_bytes = element_size,
                    .input_layout = layout,
                    .data = buf_data,
                };
            };
        } else {
            buf_data = meshopt.decodeIndexBuffer(allocator, element_count, element_size, raw_data) catch {
                buf_data = try allocator.dupe(u8, raw_data);
                return .{
                    .element_count = element_count,
                    .element_size_in_bytes = element_size,
                    .input_layout = layout,
                    .data = buf_data,
                };
            };
        }
    } else if (raw_data.len > 0) {
        // Uncompressed
        buf_data = try allocator.dupe(u8, raw_data);
    } else {
        buf_data = &.{};
    }

    return .{
        .element_count = element_count,
        .element_size_in_bytes = element_size,
        .input_layout = layout,
        .data = buf_data,
    };
}

// ============================================================
// Binary VBIB on-disk buffer reader
// ============================================================

fn readOnDiskBuffer(r: *BinaryReader, allocator: std.mem.Allocator, is_vertex: bool) !BufferData {
    const element_count = try r.readU32();
    const size_raw = try r.readI32();
    const element_size: u32 = @intCast(size_raw & 0x3FFFFFF);

    // Attribute offset/count (relative to refA)
    const ref_a = r.position();
    const attr_offset = try r.readU32();
    const attr_count = try r.readU32();

    // Data offset/size (relative to refB)
    const ref_b = r.position();
    const data_offset = try r.readU32();
    const total_size = try r.readI32(); // on-disk byte count

    // Read attributes
    const layout = try allocator.alloc(RenderInputLayoutField, attr_count);
    errdefer allocator.free(layout);

    r.setPosition(ref_a + attr_offset);
    for (0..attr_count) |i| {
        const name_start = r.position();
        var name_buf: [32]u8 = .{0} ** 32;
        _ = try r.readBytes(&name_buf);
        r.setPosition(name_start + 32); // fixed 32-byte name field

        var name_len: usize = 0;
        for (name_buf) |c| {
            if (c == 0) break;
            name_len += 1;
        }

        // Convert to uppercase (Source 2 convention)
        var upper_buf = try allocator.alloc(u8, name_len);
        for (name_buf[0..name_len], 0..) |c, ci| {
            upper_buf[ci] = std.ascii.toUpper(c);
        }

        layout[i] = .{
            .semantic_name = upper_buf,
            .semantic_index = try r.readI32(),
            .format = @enumFromInt(try r.readU32()),
            .offset = try r.readU32(),
            .slot = try r.readI32(),
        };
        _ = try r.readU32(); // slot_type
        _ = try r.readI32(); // instance_step_rate
    }

    // Read buffer data
    r.setPosition(ref_b + data_offset);

    const decompressed_size: usize = @as(usize, element_count) * @as(usize, element_size);
    const on_disk_size: usize = @intCast(total_size);

    var data: []const u8 = undefined;

    if (decompressed_size > on_disk_size and on_disk_size > 0) {
        // Meshopt compressed — read compressed bytes, then decompress
        const compressed = try r.readBytesAlloc(on_disk_size);
        defer allocator.free(compressed);

        if (is_vertex) {
            data = meshopt.decodeVertexBuffer(allocator, element_count, element_size, compressed) catch {
                data = try allocator.dupe(u8, compressed);
                r.setPosition(ref_b + 8);
                return .{
                    .element_count = element_count,
                    .element_size_in_bytes = element_size,
                    .input_layout = layout,
                    .data = data,
                };
            };
        } else {
            data = meshopt.decodeIndexBuffer(allocator, element_count, element_size, compressed) catch {
                data = try allocator.dupe(u8, compressed);
                r.setPosition(ref_b + 8);
                return .{
                    .element_count = element_count,
                    .element_size_in_bytes = element_size,
                    .input_layout = layout,
                    .data = data,
                };
            };
        }
    } else if (on_disk_size > 0) {
        // Uncompressed — read directly
        data = try r.readBytesAlloc(on_disk_size);
    } else {
        data = &.{};
    }

    // Advance to correct position for next buffer
    r.setPosition(ref_b + 8);

    return .{
        .element_count = element_count,
        .element_size_in_bytes = element_size,
        .input_layout = layout,
        .data = data,
    };
}

// ============================================================
// Float helpers
// ============================================================

fn readF32(data: []const u8, offset: usize) f32 {
    return @bitCast(std.mem.readInt(u32, data[offset..][0..4], .little));
}

fn readF32x3(data: []const u8, offset: usize) [3]f32 {
    return .{
        readF32(data, offset),
        readF32(data, offset + 4),
        readF32(data, offset + 8),
    };
}

/// Convert IEEE 754 half-precision float to single-precision.
pub fn halfToFloat(h: u16) f32 {
    const sign: u32 = @as(u32, h >> 15) << 31;
    const exp: u32 = (h >> 10) & 0x1F;
    const mant: u32 = h & 0x3FF;

    if (exp == 0) {
        if (mant == 0) return @bitCast(sign);
        var m = mant;
        var e: u32 = 113;
        while (m & 0x400 == 0) {
            m <<= 1;
            e -= 1;
        }
        return @bitCast(sign | (e << 23) | ((m & 0x3FF) << 13));
    } else if (exp == 31) {
        return @bitCast(sign | 0x7F800000 | (mant << 13));
    }

    return @bitCast(sign | ((exp + 112) << 23) | (mant << 13));
}

// ============================================================
// Draw Call / Scene Object / Mesh (KV3-based)
// ============================================================

pub const DrawCall = struct {
    material: []const u8 = "",
    vertex_buffer_index: u32 = 0,
    index_buffer_index: u32 = 0,
    index_buffer_offset: u32 = 0,
    base_vertex: i32 = 0,
    vertex_count: u32 = 0,
    start_index: u32 = 0,
    index_count: u32 = 0,
    tint_color: [4]f32 = .{ 1, 1, 1, 1 },
    use_compressed_normal_tangent: bool = false,
};

pub const SceneObject = struct {
    min_bounds: [3]f32 = .{ 0, 0, 0 },
    max_bounds: [3]f32 = .{ 0, 0, 0 },
    draw_calls: []DrawCall = &.{},
};

pub const Mesh = struct {
    allocator: std.mem.Allocator,
    scene_objects: []SceneObject = &.{},

    pub fn init(allocator: std.mem.Allocator) Mesh {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Mesh) void {
        for (self.scene_objects) |so| {
            for (so.draw_calls) |dc| {
                if (dc.material.len > 0) self.allocator.free(dc.material);
            }
            self.allocator.free(so.draw_calls);
        }
        self.allocator.free(self.scene_objects);
    }

    pub fn readFromKV3(self: *Mesh, root: *const KVObject) !void {
        const so_arr = root.getArray("m_sceneObjects") orelse return;
        self.scene_objects = try self.allocator.alloc(SceneObject, so_arr.count());

        for (so_arr.items.items, 0..) |*item, i| {
            const obj = item.asObject() orelse continue;
            var so = SceneObject{};

            if (obj.getSubCollection("m_vMinBounds")) |bounds| so.min_bounds = readVector3(bounds);
            if (obj.getSubCollection("m_vMaxBounds")) |bounds| so.max_bounds = readVector3(bounds);

            if (obj.getArray("m_drawCalls")) |dc_arr| {
                so.draw_calls = try self.allocator.alloc(DrawCall, dc_arr.count());
                for (dc_arr.items.items, 0..) |*dc_val, di| {
                    const dc_obj = dc_val.asObject() orelse continue;
                    var dc = DrawCall{};
                    dc.material = try self.allocator.dupe(u8, dc_obj.getStringProperty("m_material") orelse dc_obj.getStringProperty("m_pMaterial") orelse "");
                    if (dc_obj.getSubCollection("m_indexBuffer")) |ib| {
                        dc.index_buffer_index = ib.getU32Property("m_hBuffer") orelse 0;
                        dc.index_buffer_offset = ib.getU32Property("m_nBindOffsetBytes") orelse 0;
                    }
                    dc.base_vertex = if (dc_obj.get("m_nBaseVertex")) |v| v.asI32() orelse 0 else 0;
                    dc.vertex_count = dc_obj.getU32Property("m_nVertexCount") orelse 0;
                    dc.start_index = dc_obj.getU32Property("m_nStartIndex") orelse 0;
                    dc.index_count = dc_obj.getU32Property("m_nIndexCount") orelse 0;
                    dc.use_compressed_normal_tangent = if (dc_obj.get("m_bUseCompressedNormalTangent")) |v| v.asBool() orelse false else false;
                    so.draw_calls[di] = dc;
                }
            }
            self.scene_objects[i] = so;
        }
    }
};

fn readVector3(obj: *const KVObject) [3]f32 {
    var result = [3]f32{ 0, 0, 0 };
    for (0..@min(3, obj.values.items.len)) |i| {
        result[i] = obj.values.items[i].asF32() orelse 0;
    }
    return result;
}

// ============================================================
// Tests
// ============================================================

test "VBIB init/deinit" {
    var vbib = VBIB.init(std.testing.allocator);
    defer vbib.deinit();
    try std.testing.expectEqual(@as(usize, 0), vbib.vertex_buffers.len);
}

test "Mesh init/deinit" {
    var m = Mesh.init(std.testing.allocator);
    defer m.deinit();
    try std.testing.expectEqual(@as(usize, 0), m.scene_objects.len);
}

test "DxgiFormat byte sizes" {
    try std.testing.expectEqual(@as(u32, 12), DxgiFormat.r32g32b32_float.byteSize());
    try std.testing.expectEqual(@as(u32, 4), DxgiFormat.r8g8b8a8_unorm.byteSize());
    try std.testing.expectEqual(@as(u32, 4), DxgiFormat.r16g16_float.byteSize());
}

test "BufferData getIndex u16" {
    const data = [_]u8{ 0x00, 0x00, 0x01, 0x00, 0x02, 0x00 };
    const buf = BufferData{
        .element_count = 3,
        .element_size_in_bytes = 2,
        .data = &data,
    };
    try std.testing.expectEqual(@as(u32, 0), buf.getIndex(0));
    try std.testing.expectEqual(@as(u32, 1), buf.getIndex(1));
    try std.testing.expectEqual(@as(u32, 2), buf.getIndex(2));
}

test "halfToFloat conversions" {
    // 0x3C00 = 1.0 in half
    try std.testing.expectEqual(@as(f32, 1.0), halfToFloat(0x3C00));
    // 0x0000 = 0.0
    try std.testing.expectEqual(@as(f32, 0.0), halfToFloat(0x0000));
    // 0xBC00 = -1.0
    try std.testing.expectEqual(@as(f32, -1.0), halfToFloat(0xBC00));
}
