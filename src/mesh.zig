const std = @import("std");
const kv3 = @import("kv3.zig");
const KVObject = kv3.KVObject;
const KVArray = kv3.KVArray;
const KVValue = kv3.KVValue;

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
// Vertex/Index Buffer (VBIB)
// ============================================================

/// A vertex attribute layout field.
pub const RenderInputLayoutField = struct {
    semantic_name: []const u8,
    semantic_index: i32 = 0,
    format: DxgiFormat = .unknown,
    offset: u32 = 0,
    slot: i32 = 0,
    shader_semantic: []const u8 = "",
};

/// A vertex or index buffer.
pub const BufferData = struct {
    element_count: u32 = 0,
    element_size_in_bytes: u32 = 0,
    input_layout: []RenderInputLayoutField = &.{},
    data: []const u8 = &.{},
};

/// Vertex and Index Buffer Information block (VBIB).
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
            if (vb.data.len > 0) self.allocator.free(vb.data);
        }
        self.allocator.free(self.vertex_buffers);

        for (self.index_buffers) |ib| {
            if (ib.data.len > 0) self.allocator.free(ib.data);
        }
        self.allocator.free(self.index_buffers);
    }

    /// Parse VBIB from KV3 data.
    pub fn readFromKV3(self: *VBIB, root: *const KVObject) !void {
        if (root.getArray("m_vertexBuffers")) |vb_arr| {
            self.vertex_buffers = try self.readBuffers(vb_arr, true);
        }
        if (root.getArray("m_indexBuffers")) |ib_arr| {
            self.index_buffers = try self.readBuffers(ib_arr, false);
        }
    }

    fn readBuffers(self: *VBIB, arr: *const KVArray, is_vertex: bool) ![]BufferData {
        var buffers = try self.allocator.alloc(BufferData, arr.count());
        errdefer self.allocator.free(buffers);

        for (arr.items.items, 0..) |*item, i| {
            const obj = item.asObject() orelse continue;
            buffers[i] = .{
                .element_count = obj.getU32Property("m_nElementCount") orelse 0,
                .element_size_in_bytes = obj.getU32Property("m_nElementSizeInBytes") orelse 0,
            };

            // Input layout (vertex buffers only)
            if (is_vertex) {
                if (obj.getArray("m_inputLayoutFields")) |layout_arr| {
                    var fields = try self.allocator.alloc(RenderInputLayoutField, layout_arr.count());
                    for (layout_arr.items.items, 0..) |*field_val, fi| {
                        const field_obj = field_val.asObject() orelse continue;
                        fields[fi] = .{
                            .semantic_name = try self.allocator.dupe(u8, field_obj.getStringProperty("m_pSemanticName") orelse ""),
                            .semantic_index = field_obj.get("m_nSemanticIndex").?.asI32() orelse 0,
                            .format = @enumFromInt(field_obj.getU32Property("m_Format") orelse 0),
                            .offset = field_obj.getU32Property("m_nOffset") orelse 0,
                            .slot = field_obj.get("m_nSlot").?.asI32() orelse 0,
                            .shader_semantic = try self.allocator.dupe(u8, field_obj.getStringProperty("m_szShaderSemantic") orelse ""),
                        };
                    }
                    buffers[i].input_layout = fields;
                }
            }

            // Buffer data (inline via m_pData)
            // Note: actual buffer data may come from external blocks — for now handle inline blobs
        }

        return buffers;
    }
};

// ============================================================
// Draw Call
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

/// A scene object containing draw calls.
pub const SceneObject = struct {
    min_bounds: [3]f32 = .{ 0, 0, 0 },
    max_bounds: [3]f32 = .{ 0, 0, 0 },
    draw_calls: []DrawCall = &.{},
};

// ============================================================
// Mesh
// ============================================================

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

    /// Parse mesh data from KV3 root object.
    pub fn readFromKV3(self: *Mesh, root: *const KVObject) !void {
        const so_arr = root.getArray("m_sceneObjects") orelse return;

        self.scene_objects = try self.allocator.alloc(SceneObject, so_arr.count());

        for (so_arr.items.items, 0..) |*item, i| {
            const obj = item.asObject() orelse continue;
            var so = SceneObject{};

            // Bounds
            if (obj.getSubCollection("m_vMinBounds")) |bounds| {
                so.min_bounds = readVector3(bounds);
            }
            if (obj.getSubCollection("m_vMaxBounds")) |bounds| {
                so.max_bounds = readVector3(bounds);
            }

            // Draw calls
            if (obj.getArray("m_drawCalls")) |dc_arr| {
                so.draw_calls = try self.allocator.alloc(DrawCall, dc_arr.count());

                for (dc_arr.items.items, 0..) |*dc_val, di| {
                    const dc_obj = dc_val.asObject() orelse continue;
                    var dc = DrawCall{};

                    // Material path
                    const mat_name = dc_obj.getStringProperty("m_material") orelse
                        dc_obj.getStringProperty("m_pMaterial") orelse "";
                    dc.material = try self.allocator.dupe(u8, mat_name);

                    // Index buffer
                    if (dc_obj.getSubCollection("m_indexBuffer")) |ib| {
                        dc.index_buffer_index = ib.getU32Property("m_hBuffer") orelse 0;
                        dc.index_buffer_offset = ib.getU32Property("m_nBindOffsetBytes") orelse 0;
                    }

                    // Vertex count and index range
                    dc.base_vertex = (dc_obj.get("m_nBaseVertex") orelse &KVValue{ .int32 = 0 }).asI32() orelse 0;
                    dc.vertex_count = dc_obj.getU32Property("m_nVertexCount") orelse 0;
                    dc.start_index = dc_obj.getU32Property("m_nStartIndex") orelse 0;
                    dc.index_count = dc_obj.getU32Property("m_nIndexCount") orelse 0;

                    // Flags
                    dc.use_compressed_normal_tangent = (dc_obj.get("m_bUseCompressedNormalTangent") orelse &KVValue{ .boolean = false }).asBool() orelse false;

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
