const std = @import("std");
const kv3 = @import("kv3.zig");
const KVObject = kv3.KVObject;
const KVArray = kv3.KVArray;

/// Material group — a named set of material overrides.
pub const MaterialGroup = struct {
    name: []const u8,
    materials: [][]const u8,
};

/// A parsed Source 2 model (.vmdl).
pub const Model = struct {
    allocator: std.mem.Allocator,

    name: ?[]const u8 = null,

    /// Paths to referenced meshes (.vmesh_c).
    ref_meshes: [][]const u8 = &.{},

    /// LoD group masks per mesh.
    ref_lod_group_masks: []u64 = &.{},

    /// Paths to referenced animation groups.
    ref_anim_groups: [][]const u8 = &.{},

    /// Paths to referenced physics data.
    ref_physics_data: [][]const u8 = &.{},

    /// Named mesh visibility groups.
    mesh_groups: [][]const u8 = &.{},

    /// Material groups (skin variants).
    material_groups: []MaterialGroup = &.{},

    /// Default mesh group mask.
    default_mesh_group_mask: u32 = 0,

    pub fn init(allocator: std.mem.Allocator) Model {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Model) void {
        if (self.name) |n| self.allocator.free(n);
        for (self.ref_meshes) |m| self.allocator.free(m);
        self.allocator.free(self.ref_meshes);
        self.allocator.free(self.ref_lod_group_masks);
        for (self.ref_anim_groups) |a| self.allocator.free(a);
        self.allocator.free(self.ref_anim_groups);
        for (self.ref_physics_data) |p| self.allocator.free(p);
        self.allocator.free(self.ref_physics_data);
        for (self.mesh_groups) |g| self.allocator.free(g);
        self.allocator.free(self.mesh_groups);
        for (self.material_groups) |mg| {
            self.allocator.free(mg.name);
            for (mg.materials) |m| self.allocator.free(m);
            self.allocator.free(mg.materials);
        }
        self.allocator.free(self.material_groups);
    }

    /// Parse model data from KV3 root object.
    pub fn readFromKV3(self: *Model, root: *const KVObject) !void {
        if (root.getStringProperty("m_name")) |n| {
            self.name = try self.allocator.dupe(u8, n);
        }

        self.ref_meshes = try readStringArray(self.allocator, root, "m_refMeshes");
        self.ref_anim_groups = try readStringArray(self.allocator, root, "m_refAnimGroups");
        self.ref_physics_data = try readStringArray(self.allocator, root, "m_refPhysicsData");
        self.mesh_groups = try readStringArray(self.allocator, root, "m_meshGroups");

        // LoD group masks
        if (root.getArray("m_refLODGroupMasks")) |arr| {
            var masks = try self.allocator.alloc(u64, arr.count());
            for (arr.items.items, 0..) |*val, i| {
                masks[i] = val.asU64() orelse 0;
            }
            self.ref_lod_group_masks = masks;
        }

        // Default mesh group mask
        self.default_mesh_group_mask = root.getU32Property("m_nDefaultMeshGroupMask") orelse 0;

        // Material groups
        if (root.getArray("m_materialGroups")) |mg_arr| {
            var groups = try self.allocator.alloc(MaterialGroup, mg_arr.count());
            for (mg_arr.items.items, 0..) |*mg_val, i| {
                const mg_obj = mg_val.asObject() orelse continue;
                const name = try self.allocator.dupe(u8, mg_obj.getStringProperty("m_name") orelse "");
                const materials = try readStringArray(self.allocator, mg_obj, "m_materials");
                groups[i] = .{ .name = name, .materials = materials };
            }
            self.material_groups = groups;
        }
    }
};

// ============================================================
// World
// ============================================================

/// World node reference.
pub const WorldNodeRef = struct {
    prefix: []const u8,
};

/// A parsed Source 2 world (.vwrld).
pub const World = struct {
    allocator: std.mem.Allocator,

    entity_lumps: [][]const u8 = &.{},
    world_nodes: []WorldNodeRef = &.{},

    pub fn init(allocator: std.mem.Allocator) World {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *World) void {
        for (self.entity_lumps) |e| self.allocator.free(e);
        self.allocator.free(self.entity_lumps);
        for (self.world_nodes) |wn| self.allocator.free(wn.prefix);
        self.allocator.free(self.world_nodes);
    }

    /// Parse world data from KV3 root object.
    pub fn readFromKV3(self: *World, root: *const KVObject) !void {
        self.entity_lumps = try readStringArray(self.allocator, root, "m_entityLumps");

        if (root.getArray("m_worldNodes")) |wn_arr| {
            var nodes = try self.allocator.alloc(WorldNodeRef, wn_arr.count());
            for (wn_arr.items.items, 0..) |*wn_val, i| {
                const wn_obj = wn_val.asObject() orelse continue;
                nodes[i] = .{
                    .prefix = try self.allocator.dupe(u8, wn_obj.getStringProperty("m_worldNodePrefix") orelse ""),
                };
            }
            self.world_nodes = nodes;
        }
    }
};

/// A parsed Source 2 world node (.vwnod).
pub const WorldNode = struct {
    allocator: std.mem.Allocator,
    layer_names: [][]const u8 = &.{},
    // Scene objects reuse the Mesh.SceneObject type
    // Aggregate and clutter scene objects would go here too

    pub fn init(allocator: std.mem.Allocator) WorldNode {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *WorldNode) void {
        for (self.layer_names) |l| self.allocator.free(l);
        self.allocator.free(self.layer_names);
    }

    /// Parse world node data from KV3 root object.
    pub fn readFromKV3(self: *WorldNode, root: *const KVObject) !void {
        self.layer_names = try readStringArray(self.allocator, root, "m_layerNames");
    }
};

// ============================================================
// Helpers
// ============================================================

fn readStringArray(allocator: std.mem.Allocator, obj: *const KVObject, key: []const u8) ![][]const u8 {
    const arr = obj.getArray(key) orelse return &.{};
    var result = try allocator.alloc([]const u8, arr.count());
    for (arr.items.items, 0..) |*val, i| {
        result[i] = try allocator.dupe(u8, val.asString() orelse "");
    }
    return result;
}

// ============================================================
// Tests
// ============================================================

test "Model init/deinit" {
    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    try std.testing.expect(m.name == null);
    try std.testing.expectEqual(@as(usize, 0), m.ref_meshes.len);
}

test "World init/deinit" {
    var w = World.init(std.testing.allocator);
    defer w.deinit();
    try std.testing.expectEqual(@as(usize, 0), w.entity_lumps.len);
}

test "WorldNode init/deinit" {
    var wn = WorldNode.init(std.testing.allocator);
    defer wn.deinit();
    try std.testing.expectEqual(@as(usize, 0), wn.layer_names.len);
}
