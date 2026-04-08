const std = @import("std");

/// KV3 value flag — annotates strings with special meaning.
pub const KVFlag = enum(u8) {
    none = 0,
    resource = 1,
    resource_name = 2,
    panorama = 8,
    sound_event = 16,
    sub_class = 32,
    entity_name = 64,
};

/// KV3 binary node type — encodes value type in the types stream.
pub const KV3NodeType = enum(u8) {
    null_value = 1,
    boolean = 2,
    int64 = 3,
    uint64 = 4,
    double = 5,
    string = 6,
    binary_blob = 7,
    array = 8,
    object = 9,
    array_typed = 10,
    int32 = 11,
    uint32 = 12,
    boolean_true = 13,
    boolean_false = 14,
    int64_zero = 15,
    int64_one = 16,
    double_zero = 17,
    double_one = 18,
    float = 19,
    int16 = 20,
    uint16 = 21,
    unknown_22 = 22,
    int32_as_byte = 23,
    array_type_byte_length = 24,
    array_type_auxiliary_buffer = 25,
    _,
};

/// A KV3 value — tagged union over all possible value types.
pub const KVValue = union(enum) {
    null_value,
    boolean: bool,
    int32: i32,
    uint32: u32,
    int64: i64,
    uint64: u64,
    float32: f32,
    float64: f64,
    string: []const u8,
    binary_blob: []const u8,
    array: KVArray,
    object: KVObject,

    pub fn deinit(self: *KVValue, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .array => |*a| a.deinit(allocator),
            .object => |*o| o.deinit(allocator),
            .string => |s| if (s.len > 0) allocator.free(s),
            .binary_blob => |b| if (b.len > 0) allocator.free(b),
            else => {},
        }
    }

    // --- Accessor helpers ---

    pub fn asString(self: *const KVValue) ?[]const u8 {
        return switch (self.*) {
            .string => |s| s,
            else => null,
        };
    }

    pub fn asI32(self: *const KVValue) ?i32 {
        return switch (self.*) {
            .int32 => |v| v,
            .int64 => |v| if (v >= std.math.minInt(i32) and v <= std.math.maxInt(i32)) @intCast(v) else null,
            else => null,
        };
    }

    pub fn asU32(self: *const KVValue) ?u32 {
        return switch (self.*) {
            .uint32 => |v| v,
            .uint64 => |v| if (v <= std.math.maxInt(u32)) @intCast(v) else null,
            .int32 => |v| if (v >= 0) @intCast(v) else null,
            .int64 => |v| if (v >= 0 and v <= std.math.maxInt(u32)) @intCast(v) else null,
            else => null,
        };
    }

    pub fn asI64(self: *const KVValue) ?i64 {
        return switch (self.*) {
            .int64 => |v| v,
            .int32 => |v| @intCast(v),
            else => null,
        };
    }

    pub fn asU64(self: *const KVValue) ?u64 {
        return switch (self.*) {
            .uint64 => |v| v,
            .uint32 => |v| @intCast(v),
            else => null,
        };
    }

    pub fn asF32(self: *const KVValue) ?f32 {
        return switch (self.*) {
            .float32 => |v| v,
            .float64 => |v| @floatCast(v),
            else => null,
        };
    }

    pub fn asF64(self: *const KVValue) ?f64 {
        return switch (self.*) {
            .float64 => |v| v,
            .float32 => |v| @floatCast(v),
            else => null,
        };
    }

    pub fn asBool(self: *const KVValue) ?bool {
        return switch (self.*) {
            .boolean => |v| v,
            else => null,
        };
    }

    pub fn asObject(self: *const KVValue) ?*const KVObject {
        return switch (self.*) {
            .object => |*o| o,
            else => null,
        };
    }

    pub fn asArray(self: *const KVValue) ?*const KVArray {
        return switch (self.*) {
            .array => |*a| a,
            else => null,
        };
    }
};

/// An ordered key-value collection (KV3 object).
pub const KVObject = struct {
    /// Parallel arrays for keys and values (preserves insertion order).
    keys: std.ArrayList([]const u8),
    values: std.ArrayList(KVValue),
    flags: std.ArrayList(KVFlag),

    pub fn init(allocator: std.mem.Allocator) KVObject {
        return .{
            .keys = std.ArrayList([]const u8).init(allocator),
            .values = std.ArrayList(KVValue).init(allocator),
            .flags = std.ArrayList(KVFlag).init(allocator),
        };
    }

    pub fn initCapacity(allocator: std.mem.Allocator, capacity: usize) !KVObject {
        var obj = KVObject{
            .keys = try std.ArrayList([]const u8).initCapacity(allocator, capacity),
            .values = try std.ArrayList(KVValue).initCapacity(allocator, capacity),
            .flags = try std.ArrayList(KVFlag).initCapacity(allocator, capacity),
        };
        _ = &obj;
        return obj;
    }

    pub fn deinit(self: *KVObject, allocator: std.mem.Allocator) void {
        for (self.keys.items) |key| {
            if (key.len > 0) allocator.free(key);
        }
        self.keys.deinit();
        for (self.values.items) |*val| {
            @constCast(val).deinit(allocator);
        }
        self.values.deinit();
        self.flags.deinit();
    }

    pub fn add(self: *KVObject, key: []const u8, value: KVValue, flag: KVFlag) !void {
        try self.keys.append(key);
        try self.values.append(value);
        try self.flags.append(flag);
    }

    pub fn count(self: *const KVObject) usize {
        return self.keys.items.len;
    }

    /// Get a value by key name.
    pub fn get(self: *const KVObject, key: []const u8) ?*const KVValue {
        for (self.keys.items, 0..) |k, i| {
            if (std.mem.eql(u8, k, key)) return &self.values.items[i];
        }
        return null;
    }

    /// Get a string property by key.
    pub fn getStringProperty(self: *const KVObject, key: []const u8) ?[]const u8 {
        const val = self.get(key) orelse return null;
        return val.asString();
    }

    /// Get a u32 property by key.
    pub fn getU32Property(self: *const KVObject, key: []const u8) ?u32 {
        const val = self.get(key) orelse return null;
        return val.asU32();
    }

    /// Get a bool property by key.
    pub fn getBoolProperty(self: *const KVObject, key: []const u8) ?bool {
        const val = self.get(key) orelse return null;
        return val.asBool();
    }

    /// Get a sub-collection (nested object) by key.
    pub fn getSubCollection(self: *const KVObject, key: []const u8) ?*const KVObject {
        const val = self.get(key) orelse return null;
        return val.asObject();
    }

    /// Get an array by key.
    pub fn getArray(self: *const KVObject, key: []const u8) ?*const KVArray {
        const val = self.get(key) orelse return null;
        return val.asArray();
    }
};

/// A KV3 array (ordered list of values).
pub const KVArray = struct {
    items: std.ArrayList(KVValue),
    item_flags: std.ArrayList(KVFlag),

    pub fn init(allocator: std.mem.Allocator) KVArray {
        return .{
            .items = std.ArrayList(KVValue).init(allocator),
            .item_flags = std.ArrayList(KVFlag).init(allocator),
        };
    }

    pub fn initCapacity(allocator: std.mem.Allocator, capacity: usize) !KVArray {
        return .{
            .items = try std.ArrayList(KVValue).initCapacity(allocator, capacity),
            .item_flags = try std.ArrayList(KVFlag).initCapacity(allocator, capacity),
        };
    }

    pub fn deinit(self: *KVArray, allocator: std.mem.Allocator) void {
        for (self.items.items) |*val| {
            @constCast(val).deinit(allocator);
        }
        self.items.deinit();
        self.item_flags.deinit();
    }

    pub fn add(self: *KVArray, value: KVValue, flag: KVFlag) !void {
        try self.items.append(value);
        try self.item_flags.append(flag);
    }

    pub fn count(self: *const KVArray) usize {
        return self.items.items.len;
    }
};

// ============================================================
// Tests
// ============================================================

test "KVObject basic operations" {
    const allocator = std.testing.allocator;

    var obj = KVObject.init(allocator);
    defer obj.deinit(allocator);

    const key = try allocator.dupe(u8, "name");
    const val_str = try allocator.dupe(u8, "hello");
    try obj.add(key, .{ .string = val_str }, .none);

    const key2 = try allocator.dupe(u8, "count");
    try obj.add(key2, .{ .int32 = 42 }, .none);

    try std.testing.expectEqual(@as(usize, 2), obj.count());
    try std.testing.expectEqualStrings("hello", obj.getStringProperty("name").?);
    try std.testing.expectEqual(@as(i32, 42), obj.get("count").?.asI32().?);
}

test "KVArray basic operations" {
    const allocator = std.testing.allocator;

    var arr = KVArray.init(allocator);
    defer arr.deinit(allocator);

    try arr.add(.{ .int32 = 1 }, .none);
    try arr.add(.{ .int32 = 2 }, .none);
    try arr.add(.{ .int32 = 3 }, .none);

    try std.testing.expectEqual(@as(usize, 3), arr.count());
    try std.testing.expectEqual(@as(i32, 2), arr.items.items[1].asI32().?);
}

test "KVValue type coercions" {
    const v_i32: KVValue = .{ .int32 = 42 };
    try std.testing.expectEqual(@as(i64, 42), v_i32.asI64().?);

    const v_f32: KVValue = .{ .float32 = 3.14 };
    try std.testing.expect(v_f32.asF64().? > 3.13);

    const v_bool: KVValue = .{ .boolean = true };
    try std.testing.expectEqual(true, v_bool.asBool().?);

    const v_null: KVValue = .null_value;
    try std.testing.expect(v_null.asString() == null);
}
