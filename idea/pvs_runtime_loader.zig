// PVS Runtime Loader — for Forge/ac project integration
//
// Loads baked PVS data and cluster→model mapping for runtime culling.
// Usage in render loop:
//   1. Find camera's cell: cluster_bivh.findLeaf(camera_pos)
//   2. Get visible clusters: pvs_data.getVisibleClusters(camera_cell)
//   3. Convert to visible models: cluster_models.getVisibleModels(visible_clusters)
//   4. Render only visible models

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const PVSData = struct {
    cells: []Cell,
    allocator: Allocator,

    const Cell = struct {
        visible_clusters: []u32,
    };

    pub fn deinit(self: *PVSData) void {
        for (self.cells) |cell| {
            self.allocator.free(cell.visible_clusters);
        }
        self.allocator.free(self.cells);
    }

    pub fn loadFromFile(allocator: Allocator, path: []const u8) !PVSData {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();
        const reader = file.reader();

        // Read header
        var magic: [4]u8 = undefined;
        _ = try reader.readAll(&magic);
        if (!std.mem.eql(u8, &magic, "PVSN")) return error.InvalidMagic;

        const num_cells = try reader.readInt(u32, .little);
        const cells = try allocator.alloc(Cell, num_cells);
        errdefer allocator.free(cells);

        // Read each cell's visible cluster list
        for (cells) |*cell| {
            const count = try reader.readInt(u32, .little);
            const visible = try allocator.alloc(u32, count);
            errdefer allocator.free(visible);

            for (visible) |*cluster_id| {
                cluster_id.* = try reader.readInt(u32, .little);
            }
            cell.visible_clusters = visible;
        }

        return .{
            .cells = cells,
            .allocator = allocator,
        };
    }

    pub fn getVisibleClusters(self: *const PVSData, cell_id: u32) []const u32 {
        if (cell_id >= self.cells.len) return &[_]u32{};
        return self.cells[cell_id].visible_clusters;
    }
};

pub const ClusterModels = struct {
    cluster_to_models: [][]const u32,
    num_models: u32,
    allocator: Allocator,

    pub fn deinit(self: *ClusterModels) void {
        for (self.cluster_to_models) |models| {
            self.allocator.free(models);
        }
        self.allocator.free(self.cluster_to_models);
    }

    pub fn loadFromFile(allocator: Allocator, path: []const u8) !ClusterModels {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();
        const reader = file.reader();

        // Read header
        var magic: [4]u8 = undefined;
        _ = try reader.readAll(&magic);
        if (!std.mem.eql(u8, &magic, "CMOD")) return error.InvalidMagic;

        const num_clusters = try reader.readInt(u32, .little);
        const num_models = try reader.readInt(u32, .little);

        const cluster_to_models = try allocator.alloc([]u32, num_clusters);
        errdefer allocator.free(cluster_to_models);

        // Read each cluster's model list
        for (0..num_clusters) |i| {
            const cluster_id = try reader.readInt(u32, .little);
            if (cluster_id != i) return error.InvalidClusterOrder;

            const count = try reader.readInt(u32, .little);
            const models = try allocator.alloc(u32, count);
            errdefer allocator.free(models);

            for (models) |*model_id| {
                model_id.* = try reader.readInt(u32, .little);
            }
            cluster_to_models[i] = models;
        }

        return .{
            .cluster_to_models = cluster_to_models,
            .num_models = num_models,
            .allocator = allocator,
        };
    }

    /// Collect all models visible from the given cluster set
    pub fn getVisibleModels(
        self: *const ClusterModels,
        visible_clusters: []const u32,
        allocator: Allocator,
    ) ![]u32 {
        var model_set = std.AutoHashMap(u32, void).init(allocator);
        defer model_set.deinit();

        for (visible_clusters) |cluster_id| {
            if (cluster_id >= self.cluster_to_models.len) continue;

            for (self.cluster_to_models[cluster_id]) |model_id| {
                try model_set.put(model_id, {});
            }
        }

        // Convert set to array
        const visible_models = try allocator.alloc(u32, model_set.count());
        var iter = model_set.keyIterator();
        var i: usize = 0;
        while (iter.next()) |key| {
            visible_models[i] = key.*;
            i += 1;
        }

        return visible_models;
    }

    /// Inline version that writes directly to a boolean array (faster, no allocation)
    pub fn markVisibleModels(
        self: *const ClusterModels,
        visible_clusters: []const u32,
        visible_flags: []bool, // Must be size num_models, caller's responsibility
    ) void {
        @memset(visible_flags, false);

        for (visible_clusters) |cluster_id| {
            if (cluster_id >= self.cluster_to_models.len) continue;

            for (self.cluster_to_models[cluster_id]) |model_id| {
                if (model_id < visible_flags.len) {
                    visible_flags[model_id] = true;
                }
            }
        }
    }
};

pub const ProbeAssignment = struct {
    cluster_to_probe: []u32,
    num_probes: u32,
    allocator: Allocator,

    pub fn deinit(self: *ProbeAssignment) void {
        self.allocator.free(self.cluster_to_probe);
    }

    pub fn loadFromFile(allocator: Allocator, path: []const u8) !ProbeAssignment {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();
        const reader = file.reader();

        var magic: [4]u8 = undefined;
        _ = try reader.readAll(&magic);
        if (!std.mem.eql(u8, &magic, "PASN")) return error.InvalidMagic;

        const num_clusters = try reader.readInt(u32, .little);
        const num_probes = try reader.readInt(u32, .little);

        const cluster_to_probe = try allocator.alloc(u32, num_clusters);
        errdefer allocator.free(cluster_to_probe);

        for (cluster_to_probe) |*probe_id| {
            probe_id.* = try reader.readInt(u32, .little);
        }

        return .{
            .cluster_to_probe = cluster_to_probe,
            .num_probes = num_probes,
            .allocator = allocator,
        };
    }

    pub fn getProbeId(self: *const ProbeAssignment, cluster_id: u32) ?u32 {
        if (cluster_id >= self.cluster_to_probe.len) return null;
        const probe_id = self.cluster_to_probe[cluster_id];
        if (probe_id >= self.num_probes) return null;
        return probe_id;
    }
};

// ── Example render loop integration ──────────────────────────────────

pub const PVSRenderer = struct {
    pvs_data: PVSData,
    cluster_models: ClusterModels,
    probe_assignment: ProbeAssignment,
    visible_model_flags: []bool, // Persistent allocation to avoid per-frame alloc
    allocator: Allocator,

    pub fn init(allocator: Allocator, map_base_name: []const u8) !PVSRenderer {
        // Load all PVS data files
        const pvs_path = try std.fmt.allocPrint(allocator, "{s}_pvs.bin", .{map_base_name});
        defer allocator.free(pvs_path);
        const pvs_data = try PVSData.loadFromFile(allocator, pvs_path);
        errdefer pvs_data.deinit();

        const cm_path = try std.fmt.allocPrint(allocator, "{s}_cluster_models.bin", .{map_base_name});
        defer allocator.free(cm_path);
        const cluster_models = try ClusterModels.loadFromFile(allocator, cm_path);
        errdefer cluster_models.deinit();

        const pa_path = try std.fmt.allocPrint(allocator, "{s}_probe_assign.bin", .{map_base_name});
        defer allocator.free(pa_path);
        const probe_assignment = try ProbeAssignment.loadFromFile(allocator, pa_path);
        errdefer probe_assignment.deinit();

        const visible_model_flags = try allocator.alloc(bool, cluster_models.num_models);
        @memset(visible_model_flags, false);

        return .{
            .pvs_data = pvs_data,
            .cluster_models = cluster_models,
            .probe_assignment = probe_assignment,
            .visible_model_flags = visible_model_flags,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *PVSRenderer) void {
        self.allocator.free(self.visible_model_flags);
        self.probe_assignment.deinit();
        self.cluster_models.deinit();
        self.pvs_data.deinit();
    }

    /// Call this once per frame with camera position.
    /// Returns: nothing (modifies visible_model_flags in-place)
    pub fn updateVisibility(
        self: *PVSRenderer,
        camera_pos: [3]f32,
        cluster_bivh: anytype, // Your cluster BIVH from the baker
    ) void {
        // 1. Find camera's cell
        const camera_cell = cluster_bivh.findLeaf(camera_pos, null) orelse {
            // Camera outside all cells — mark everything invisible
            @memset(self.visible_model_flags, false);
            return;
        };

        // 2. Get visible clusters from PVS
        const visible_clusters = self.pvs_data.getVisibleClusters(camera_cell);

        // 3. Mark visible models (writes to self.visible_model_flags)
        self.cluster_models.markVisibleModels(visible_clusters, self.visible_model_flags);
    }

    /// Check if a model should be rendered
    pub fn isModelVisible(self: *const PVSRenderer, model_id: u32) bool {
        if (model_id >= self.visible_model_flags.len) return false;
        return self.visible_model_flags[model_id];
    }
};

// ── Render loop pseudo-code ──────────────────────────────────────────

// Initialization (once at map load):
// var pvs_renderer = try PVSRenderer.init(allocator, "de_dust2");
// defer pvs_renderer.deinit();

// Per-frame (in render loop):
// pvs_renderer.updateVisibility(camera.position, cluster_bivh);
//
// for (scene_models.items, 0..) |model, model_id| {
//     if (!pvs_renderer.isModelVisible(@intCast(model_id))) continue;
//
//     // This model is visible — draw it
//     renderer.drawModel(model);
//
//     // Also: get probe for GI lighting
//     const cluster_id = model.cluster_id; // You'd track this during model load
//     if (pvs_renderer.probe_assignment.getProbeId(cluster_id)) |probe_id| {
//         const probe_sh = probe_sh_buffer[probe_id]; // SH coeffs loaded separately
//         shader.setUniform("u_probe_sh", probe_sh);
//     }
// }
