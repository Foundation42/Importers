// PVS data generation — fires omnidirectional ray bundles from probe-seeded
// positions and records which sub-meshes are visible. The output is a
// `TrainingData` cache that feeds the exemplar selector and (formerly) the
// MLP trainer. The MLP path was retired now that the cell-graph + exemplar
// hybrid covers the same ground better and cheaper, so this file is purely
// data-gen + cache I/O.

const std = @import("std");
const Allocator = std.mem.Allocator;
const bivh_mod = @import("bivh");

const Vec3 = [3]f32;

// ── Vector math helpers ─────────────────────────────────────────────

fn sub3(a: Vec3, b: Vec3) Vec3 {
    return .{ a[0] - b[0], a[1] - b[1], a[2] - b[2] };
}

fn add3(a: Vec3, b: Vec3) Vec3 {
    return .{ a[0] + b[0], a[1] + b[1], a[2] + b[2] };
}

fn scale3(v: Vec3, s: f32) Vec3 {
    return .{ v[0] * s, v[1] * s, v[2] * s };
}

fn dot3(a: Vec3, b: Vec3) f32 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

fn length3(v: Vec3) f32 {
    return @sqrt(dot3(v, v));
}

fn midpoint(a: Vec3, b: Vec3) Vec3 {
    return .{
        (a[0] + b[0]) * 0.5,
        (a[1] + b[1]) * 0.5,
        (a[2] + b[2]) * 0.5,
    };
}

/// Uniform random direction on the unit sphere (Marsaglia's method).
fn randomOnSphere(rng: std.Random) Vec3 {
    while (true) {
        const x = rng.float(f32) * 2.0 - 1.0;
        const y = rng.float(f32) * 2.0 - 1.0;
        const s = x * x + y * y;
        if (s >= 1.0 or s == 0.0) continue;
        const factor = 2.0 * @sqrt(1.0 - s);
        return .{
            x * factor,
            y * factor,
            1.0 - 2.0 * s,
        };
    }
}

// ── Bitset helpers ──────────────────────────────────────────────────

fn bitsetGet(bitset: []const u8, idx: usize) bool {
    const byte = idx / 8;
    const bit: u3 = @intCast(idx % 8);
    return byte < bitset.len and (bitset[byte] & (@as(u8, 1) << bit)) != 0;
}

fn bitsetSet(bitset: []u8, idx: usize) void {
    const byte = idx / 8;
    const bit: u3 = @intCast(idx % 8);
    if (byte < bitset.len) bitset[byte] |= @as(u8, 1) << bit;
}

fn bitsetCount(bitset: []const u8) u32 {
    var count: u32 = 0;
    for (bitset) |b| count += @popCount(b);
    return count;
}

// ── Training Data ───────────────────────────────────────────────────

pub const TrainingConfig = struct {
    num_samples: u32 = 20_000,
    rays_per_sample: u32 = 1024,
    max_ray_dist: f32 = 2000.0,
    bundle_offset: f32 = 0.001,
};

pub const TrainingData = struct {
    positions: []Vec3,
    labels: [][]u8, // packed model bitsets
    num_models: u32,
    bitset_stride: u32,
    num_samples: u32,
    total_rays: u64,
    world_min: Vec3 = .{ 0, 0, 0 },
    world_max: Vec3 = .{ 1, 1, 1 },
    allocator: Allocator,

    pub fn deinit(self: *TrainingData) void {
        for (self.labels) |l| self.allocator.free(l);
        self.allocator.free(self.labels);
        self.allocator.free(self.positions);
    }

    /// Save training data to a binary cache file (TDAT v3).
    /// v3 dropped the orientation params and per-PVS-unit centroids that
    /// only the (now-removed) MLP trainer needed.
    pub fn save(self: *const TrainingData, path: []const u8) !void {
        var file = try std.fs.cwd().createFile(path, .{});
        defer file.close();
        var bw = std.io.bufferedWriter(file.writer());
        const w = bw.writer();

        try w.writeAll("TDAT");
        try w.writeInt(u32, 3, .little);
        try w.writeInt(u32, self.num_models, .little);
        try w.writeInt(u32, self.num_samples, .little);
        try w.writeInt(u32, self.bitset_stride, .little);
        try w.writeInt(u64, self.total_rays, .little);

        for (self.world_min) |v| try w.writeInt(u32, @bitCast(v), .little);
        for (self.world_max) |v| try w.writeInt(u32, @bitCast(v), .little);

        for (0..self.num_samples) |i| {
            for (self.positions[i]) |v| try w.writeInt(u32, @bitCast(v), .little);
            try w.writeAll(self.labels[i]);
        }

        try bw.flush();
    }

    pub fn load(allocator: Allocator, path: []const u8) !TrainingData {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();
        var br = std.io.bufferedReader(file.reader());
        const reader = br.reader();

        var magic: [4]u8 = undefined;
        _ = try reader.readAll(&magic);
        if (!std.mem.eql(u8, &magic, "TDAT")) return error.InvalidMagic;

        const version = try reader.readInt(u32, .little);
        if (version != 3) return error.UnsupportedVersion;

        const num_models = try reader.readInt(u32, .little);
        const num_samples = try reader.readInt(u32, .little);
        const bitset_stride = try reader.readInt(u32, .little);
        const total_rays = try reader.readInt(u64, .little);

        var world_min: Vec3 = undefined;
        var world_max: Vec3 = undefined;
        for (&world_min) |*v| v.* = @bitCast(try reader.readInt(u32, .little));
        for (&world_max) |*v| v.* = @bitCast(try reader.readInt(u32, .little));

        const positions = try allocator.alloc(Vec3, num_samples);
        errdefer allocator.free(positions);
        const labels = try allocator.alloc([]u8, num_samples);
        errdefer {
            for (labels) |l| allocator.free(l);
            allocator.free(labels);
        }

        for (0..num_samples) |i| {
            for (&positions[i]) |*v| v.* = @bitCast(try reader.readInt(u32, .little));
            labels[i] = try allocator.alloc(u8, bitset_stride);
            _ = try reader.readAll(labels[i]);
        }

        return .{
            .positions = positions,
            .labels = labels,
            .num_models = num_models,
            .bitset_stride = bitset_stride,
            .num_samples = num_samples,
            .total_rays = total_rays,
            .world_min = world_min,
            .world_max = world_max,
            .allocator = allocator,
        };
    }
};

// ── Sampler ─────────────────────────────────────────────────────────

const ThreadResult = struct {
    positions: std.ArrayList(Vec3),
    labels: std.ArrayList([]u8),
    sample_count: u32,
    total_rays: u64,
    attempts: u64,
};

/// Generate one sample: pick a position (probe-seeded with jitter, or
/// uniform random world space), fire `rays_per_sample` rays uniformly
/// over the sphere, and record which PVS units were hit.
fn generateOneSample(
    bivh: *const bivh_mod.Bivh,
    mesh_set: *const bivh_mod.TriangleMeshSet,
    world_perm: []const u32,
    tri_to_unit: []const u32,
    num_units: u32,
    pos_min: Vec3,
    pos_max: Vec3,
    config: TrainingConfig,
    probe_positions: ?[]const [3]f32,
    result: *ThreadResult,
    thread_alloc: Allocator,
) bool {
    const rng = std.crypto.random;
    const bitset_stride: u32 = (num_units + 7) / 8;

    const pos = if (probe_positions) |probes| blk: {
        const pi = rng.uintLessThan(usize, probes.len);
        const seed = probes[pi];
        const jr: f32 = 0.5; // meters
        break :blk Vec3{
            std.math.clamp(seed[0] + (rng.float(f32) * 2.0 - 1.0) * jr, pos_min[0], pos_max[0]),
            std.math.clamp(seed[1] + (rng.float(f32) * 2.0 - 1.0) * jr, pos_min[1], pos_max[1]),
            std.math.clamp(seed[2] + (rng.float(f32) * 2.0 - 1.0) * jr, pos_min[2], pos_max[2]),
        };
    } else Vec3{
        pos_min[0] + rng.float(f32) * (pos_max[0] - pos_min[0]),
        pos_min[1] + rng.float(f32) * (pos_max[1] - pos_min[1]),
        pos_min[2] + rng.float(f32) * (pos_max[2] - pos_min[2]),
    };

    const bitset = thread_alloc.alloc(u8, bitset_stride) catch return false;
    @memset(bitset, 0);
    var found_any = false;
    var rays: u64 = 0;

    for (0..config.rays_per_sample) |_| {
        const dir = randomOnSphere(rng);
        var ray = bivh_mod.TraceRay.make(pos[0], pos[1], pos[2], dir[0], dir[1], dir[2], config.max_ray_dist);
        const hit = bivh.trace(mesh_set, &ray, 0.0001, config.max_ray_dist);
        rays += 1;

        if (hit and ray.hit_primitive >= 0) {
            const sorted_idx: u32 = @intCast(ray.hit_primitive);
            if (sorted_idx >= world_perm.len) continue;
            const orig_idx = world_perm[sorted_idx];
            if (orig_idx >= tri_to_unit.len) continue;
            const unit_id = tri_to_unit[orig_idx];

            if (unit_id != std.math.maxInt(u32) and unit_id < num_units) {
                const was_new = !bitsetGet(bitset, unit_id);
                bitsetSet(bitset, unit_id);
                found_any = true;

                // Bundle refinement: when we hit a new unit, fire short rays
                // from each triangle vertex/midpoint back toward our position
                // to catch nearby co-visible geometry.
                if (was_new) {
                    const tri_base = @as(usize, sorted_idx) * 3;
                    if (tri_base + 2 >= mesh_set.indices.len) continue;
                    const v0 = mesh_set.positions[mesh_set.indices[tri_base]];
                    const v1 = mesh_set.positions[mesh_set.indices[tri_base + 1]];
                    const v2 = mesh_set.positions[mesh_set.indices[tri_base + 2]];

                    const probes_arr = [6]Vec3{
                        v0,              v1,              v2,
                        midpoint(v0, v1), midpoint(v0, v2), midpoint(v1, v2),
                    };

                    for (probes_arr) |probe| {
                        const to_cam = sub3(pos, probe);
                        const dist = length3(to_cam);
                        if (dist < 0.01) continue;
                        const dir_to_cam = scale3(to_cam, 1.0 / dist);
                        const offset_probe = add3(probe, scale3(dir_to_cam, config.bundle_offset));

                        var bundle_ray = bivh_mod.TraceRay.make(
                            offset_probe[0], offset_probe[1], offset_probe[2],
                            dir_to_cam[0],   dir_to_cam[1],   dir_to_cam[2],
                            dist,
                        );
                        const bundle_hit = bivh.trace(mesh_set, &bundle_ray, 0.0001, dist);
                        rays += 1;

                        if (bundle_hit and bundle_ray.hit_primitive >= 0) {
                            const b_sorted: u32 = @intCast(bundle_ray.hit_primitive);
                            if (b_sorted < world_perm.len) {
                                const b_orig = world_perm[b_sorted];
                                if (b_orig < tri_to_unit.len) {
                                    const b_unit = tri_to_unit[b_orig];
                                    if (b_unit != std.math.maxInt(u32) and b_unit < num_units) {
                                        bitsetSet(bitset, b_unit);
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    result.total_rays += rays;
    result.attempts += 1;

    if (found_any) {
        result.positions.append(pos) catch return false;
        result.labels.append(bitset) catch return false;
        result.sample_count += 1;
        return true;
    } else {
        thread_alloc.free(bitset);
        return false;
    }
}

fn dataGenWorker(
    bivh: *const bivh_mod.Bivh,
    mesh_set: *const bivh_mod.TriangleMeshSet,
    world_perm: []const u32,
    tri_to_unit: []const u32,
    num_units: u32,
    pos_min: Vec3,
    pos_max: Vec3,
    config: TrainingConfig,
    probe_positions: ?[]const [3]f32,
    target_samples: u32,
    result: *ThreadResult,
) void {
    const thread_alloc = result.positions.allocator;
    var generated: u32 = 0;
    var att: u64 = 0;
    const max_att: u64 = @as(u64, target_samples) * 10;

    while (generated < target_samples and att < max_att) : (att += 1) {
        if (generateOneSample(
            bivh, mesh_set, world_perm, tri_to_unit,
            num_units, pos_min, pos_max, config, probe_positions, result, thread_alloc,
        )) {
            generated += 1;
        }
    }
}

/// Generate omnidirectional training data, parallelized via thread-local arenas.
pub fn generateTrainingData(
    allocator: Allocator,
    bivh: *const bivh_mod.Bivh,
    mesh_set: *const bivh_mod.TriangleMeshSet,
    world_perm: []const u32,
    tri_to_unit: []const u32,
    num_units: u32,
    pos_min: Vec3,
    pos_max: Vec3,
    config: TrainingConfig,
    probe_positions: ?[]const [3]f32,
    stdout: anytype,
) !TrainingData {
    const num_threads = @max(1, std.Thread.getCpuCount() catch 4);
    const samples_per_thread = (config.num_samples + @as(u32, @intCast(num_threads)) - 1) / @as(u32, @intCast(num_threads));

    if (probe_positions) |pp| {
        try stdout.print("  Generating {d} probe-seeded omnidirectional samples from {d} probes ({d} rays/sample, {d} threads)...\n", .{
            config.num_samples, pp.len, config.rays_per_sample, num_threads,
        });
    } else {
        try stdout.print("  Generating {d} uniform random omnidirectional samples ({d} rays/sample, {d} threads)...\n", .{
            config.num_samples, config.rays_per_sample, num_threads,
        });
    }

    // Per-thread arenas to avoid GPA mutex contention
    const thread_arenas = try allocator.alloc(std.heap.ArenaAllocator, num_threads);
    defer allocator.free(thread_arenas);
    for (thread_arenas) |*arena| arena.* = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer for (thread_arenas) |*arena| arena.deinit();

    const thread_results = try allocator.alloc(ThreadResult, num_threads);
    defer allocator.free(thread_results);
    for (thread_results, thread_arenas) |*tr, *arena| {
        const ta = arena.allocator();
        tr.* = .{
            .positions = std.ArrayList(Vec3).init(ta),
            .labels = std.ArrayList([]u8).init(ta),
            .sample_count = 0,
            .total_rays = 0,
            .attempts = 0,
        };
    }

    const threads = try allocator.alloc(std.Thread, num_threads);
    defer allocator.free(threads);

    for (thread_results, threads) |*tr, *t| {
        t.* = try std.Thread.spawn(.{}, dataGenWorker, .{
            bivh, mesh_set, world_perm, tri_to_unit,
            num_units, pos_min, pos_max, config, probe_positions,
            samples_per_thread, tr,
        });
    }

    for (threads) |t| t.join();

    var total_primary: u32 = 0;
    var total_rays: u64 = 0;
    var total_attempts: u64 = 0;
    for (thread_results) |tr| {
        total_primary += tr.sample_count;
        total_rays += tr.total_rays;
        total_attempts += tr.attempts;
    }

    var total_samples: usize = 0;
    for (thread_results) |tr| total_samples += tr.positions.items.len;

    // Merge thread-arena results into main allocator
    const bitset_stride: u32 = (num_units + 7) / 8;
    var positions = try allocator.alloc(Vec3, total_samples);
    var labels_arr = try allocator.alloc([]u8, total_samples);
    var offset: usize = 0;
    for (thread_results) |tr| {
        const n = tr.positions.items.len;
        @memcpy(positions[offset..][0..n], tr.positions.items);
        for (tr.labels.items, 0..) |arena_label, li| {
            const label = try allocator.alloc(u8, bitset_stride);
            @memcpy(label, arena_label);
            labels_arr[offset + li] = label;
        }
        offset += n;
    }

    try stdout.print("  Generated {d} samples, {d}M rays ({d} threads, {d} attempts)\n", .{
        total_samples, total_rays / 1_000_000, num_threads, total_attempts,
    });

    // Stats on label density
    {
        var min_vis: u32 = std.math.maxInt(u32);
        var max_vis: u32 = 0;
        var total_vis: u64 = 0;
        for (labels_arr) |l| {
            const c = bitsetCount(l);
            min_vis = @min(min_vis, c);
            max_vis = @max(max_vis, c);
            total_vis += c;
        }
        if (total_samples > 0) {
            try stdout.print("  Units/sample: min={d}, max={d}, avg={d}\n", .{
                min_vis, max_vis, @as(u32, @intCast(total_vis / total_samples)),
            });
        }
    }

    return .{
        .positions = positions,
        .labels = labels_arr,
        .num_models = num_units,
        .bitset_stride = bitset_stride,
        .num_samples = @intCast(total_samples),
        .total_rays = total_rays,
        .world_min = pos_min,
        .world_max = pos_max,
        .allocator = allocator,
    };
}
