const std = @import("std");
const kv3 = @import("kv3.zig");
const KVObject = kv3.KVObject;
const KVValue = kv3.KVValue;
const KVArray = kv3.KVArray;

/// A parsed Source 2 material (.vmat).
pub const Material = struct {
    allocator: std.mem.Allocator,

    name: ?[]const u8 = null,
    shader_name: ?[]const u8 = null,

    int_params: std.StringHashMap(i64),
    float_params: std.StringHashMap(f32),
    vector_params: std.StringHashMap([4]f32),
    texture_params: std.StringHashMap([]const u8),

    int_attributes: std.StringHashMap(i64),
    float_attributes: std.StringHashMap(f32),
    vector_attributes: std.StringHashMap([4]f32),
    string_attributes: std.StringHashMap([]const u8),

    pub fn init(allocator: std.mem.Allocator) Material {
        return .{
            .allocator = allocator,
            .int_params = std.StringHashMap(i64).init(allocator),
            .float_params = std.StringHashMap(f32).init(allocator),
            .vector_params = std.StringHashMap([4]f32).init(allocator),
            .texture_params = std.StringHashMap([]const u8).init(allocator),
            .int_attributes = std.StringHashMap(i64).init(allocator),
            .float_attributes = std.StringHashMap(f32).init(allocator),
            .vector_attributes = std.StringHashMap([4]f32).init(allocator),
            .string_attributes = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *Material) void {
        if (self.name) |n| self.allocator.free(n);
        if (self.shader_name) |s| self.allocator.free(s);
        freeStringMap(self.allocator, &self.int_params);
        freeStringMap(self.allocator, &self.float_params);
        freeStringMap(self.allocator, &self.vector_params);
        freeStringValueMap(self.allocator, &self.texture_params);
        freeStringMap(self.allocator, &self.int_attributes);
        freeStringMap(self.allocator, &self.float_attributes);
        freeStringMap(self.allocator, &self.vector_attributes);
        freeStringValueMap(self.allocator, &self.string_attributes);
    }

    /// Parse material data from a KV3 object (the DATA block root).
    pub fn readFromKV3(self: *Material, root: *const KVObject) !void {
        // Material name
        if (root.getStringProperty("m_materialName")) |name| {
            self.name = try self.allocator.dupe(u8, name);
        }

        // Shader name
        if (root.getStringProperty("m_shaderName")) |name| {
            self.shader_name = try self.allocator.dupe(u8, name);
        }

        // Int params: array of { m_name, m_nValue }
        if (root.getArray("m_intParams")) |arr| {
            try readNamedIntParams(self.allocator, arr, &self.int_params, "m_nValue");
        }

        // Float params: array of { m_name, m_flValue }
        if (root.getArray("m_floatParams")) |arr| {
            try readNamedFloatParams(self.allocator, arr, &self.float_params, "m_flValue");
        }

        // Vector params: array of { m_name, m_value }
        if (root.getArray("m_vectorParams")) |arr| {
            try readNamedVectorParams(self.allocator, arr, &self.vector_params);
        }

        // Texture params: array of { m_name, m_pValue }
        if (root.getArray("m_textureParams")) |arr| {
            try readNamedStringParams(self.allocator, arr, &self.texture_params, "m_pValue");
        }

        // Int attributes
        if (root.getArray("m_intAttributes")) |arr| {
            try readNamedIntParams(self.allocator, arr, &self.int_attributes, "m_nValue");
        }

        // Float attributes
        if (root.getArray("m_floatAttributes")) |arr| {
            try readNamedFloatParams(self.allocator, arr, &self.float_attributes, "m_flValue");
        }

        // Vector attributes
        if (root.getArray("m_vectorAttributes")) |arr| {
            try readNamedVectorParams(self.allocator, arr, &self.vector_attributes);
        }

        // String attributes
        if (root.getArray("m_stringAttributes")) |arr| {
            try readNamedStringParams(self.allocator, arr, &self.string_attributes, "m_value");
        }
    }

    /// Get a texture parameter by name.
    pub fn getTexture(self: *const Material, name: []const u8) ?[]const u8 {
        return self.texture_params.get(name);
    }

    /// Get a float parameter by name.
    pub fn getFloat(self: *const Material, name: []const u8) ?f32 {
        return self.float_params.get(name);
    }

    /// Get a vector parameter by name.
    pub fn getVector(self: *const Material, name: []const u8) ?[4]f32 {
        return self.vector_params.get(name);
    }

    /// Get an int parameter by name.
    pub fn getInt(self: *const Material, name: []const u8) ?i64 {
        return self.int_params.get(name);
    }
};

// ============================================================
// KV3 array reading helpers
// ============================================================

fn readNamedIntParams(allocator: std.mem.Allocator, arr: *const KVArray, map: *std.StringHashMap(i64), value_key: []const u8) !void {
    for (arr.items.items) |*item| {
        const obj = item.asObject() orelse continue;
        const name = obj.getStringProperty("m_name") orelse continue;
        const val = obj.get(value_key) orelse continue;
        const int_val = val.asI64() orelse continue;
        const key = try allocator.dupe(u8, name);
        try map.put(key, int_val);
    }
}

fn readNamedFloatParams(allocator: std.mem.Allocator, arr: *const KVArray, map: *std.StringHashMap(f32), value_key: []const u8) !void {
    for (arr.items.items) |*item| {
        const obj = item.asObject() orelse continue;
        const name = obj.getStringProperty("m_name") orelse continue;
        const val = obj.get(value_key) orelse continue;
        const float_val = val.asF32() orelse continue;
        const key = try allocator.dupe(u8, name);
        try map.put(key, float_val);
    }
}

fn readNamedVectorParams(allocator: std.mem.Allocator, arr: *const KVArray, map: *std.StringHashMap([4]f32)) !void {
    for (arr.items.items) |*item| {
        const obj = item.asObject() orelse continue;
        const name = obj.getStringProperty("m_name") orelse continue;
        const vec_obj = obj.getSubCollection("m_value") orelse continue;
        const vec = readVector4(vec_obj);
        const key = try allocator.dupe(u8, name);
        try map.put(key, vec);
    }
}

fn readNamedStringParams(allocator: std.mem.Allocator, arr: *const KVArray, map: *std.StringHashMap([]const u8), value_key: []const u8) !void {
    for (arr.items.items) |*item| {
        const obj = item.asObject() orelse continue;
        const name = obj.getStringProperty("m_name") orelse continue;
        const val = obj.getStringProperty(value_key) orelse continue;
        const key = try allocator.dupe(u8, name);
        const value = try allocator.dupe(u8, val);
        try map.put(key, value);
    }
}

fn readVector4(obj: *const KVObject) [4]f32 {
    // Vector4 can be stored as named fields or as array
    var result = [4]f32{ 0, 0, 0, 0 };

    // Try array indices first (KV3 arrays)
    if (obj.keys.items.len >= 4) {
        for (0..@min(4, obj.values.items.len)) |i| {
            result[i] = obj.values.items[i].asF32() orelse 0;
        }
    }

    return result;
}

// ============================================================
// Cleanup helpers
// ============================================================

fn freeStringMap(allocator: std.mem.Allocator, map: anytype) void {
    var iter = map.iterator();
    while (iter.next()) |entry| {
        allocator.free(entry.key_ptr.*);
    }
    map.deinit();
}

fn freeStringValueMap(allocator: std.mem.Allocator, map: *std.StringHashMap([]const u8)) void {
    var iter = map.iterator();
    while (iter.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        allocator.free(entry.value_ptr.*);
    }
    map.deinit();
}

// ============================================================
// Tests
// ============================================================

test "Material init/deinit" {
    var mat = Material.init(std.testing.allocator);
    defer mat.deinit();

    try std.testing.expect(mat.name == null);
    try std.testing.expect(mat.shader_name == null);
}
