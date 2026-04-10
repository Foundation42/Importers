// Neural PVS v2 — frustum-integrated visibility prediction.
//
// Direction + frustum-aware MLP predicts which models are visible AND
// in-frustum from a camera state. Eliminates separate frustum cull pass.
// Training uses spatial + distance weighted loss (center/near > edge/far).
//
// Input (9): x, y, z, sin_yaw, cos_yaw, sin_pitch, cos_pitch, vfov_norm, aspect_norm
// Architecture: input(9) → [H LeakyReLU] → [H LeakyReLU] → [N sigmoid]
// Output: per-model visibility probability (combined PVS + frustum)

const std = @import("std");
const Allocator = std.mem.Allocator;
const bivh_mod = @import("bivh");

const Vec3 = [3]f32;
pub const INPUT_SIZE: u32 = 9;

// Frustum parameter ranges (for normalization)
const MIN_VFOV: f32 = 1.05; // ~60 degrees
const MAX_VFOV: f32 = 2.09; // ~120 degrees
const MIN_ASPECT: f32 = 1.33; // 4:3
const MAX_ASPECT: f32 = 2.33; // ultrawide

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

fn normalize3(v: Vec3) Vec3 {
    const len = length3(v);
    if (len < 1e-10) return .{ 0, 1, 0 };
    return scale3(v, 1.0 / len);
}

fn cross3(a: Vec3, b: Vec3) Vec3 {
    return .{
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    };
}

fn midpoint(a: Vec3, b: Vec3) Vec3 {
    return .{
        (a[0] + b[0]) * 0.5,
        (a[1] + b[1]) * 0.5,
        (a[2] + b[2]) * 0.5,
    };
}

/// Build look direction from yaw + pitch (Y-up coordinate system).
fn lookDirFromAngles(sin_yaw: f32, cos_yaw: f32, sin_pitch: f32, cos_pitch: f32) Vec3 {
    return .{ cos_pitch * sin_yaw, sin_pitch, cos_pitch * cos_yaw };
}

/// Random ray direction within a camera frustum.
/// Frustum defined by look_dir, vfov, aspect ratio.
fn randomInFrustum(look_dir: Vec3, vfov: f32, aspect: f32, rng: std.Random) Vec3 {
    // Build camera basis
    const up = Vec3{ 0, 1, 0 };
    var right = normalize3(cross3(up, look_dir));
    if (length3(right) < 0.001) {
        right = normalize3(cross3(.{ 1, 0, 0 }, look_dir));
    }
    const cam_up = cross3(look_dir, right);

    // Frustum half-extents at unit distance
    const v_tan = @tan(vfov * 0.5);
    const h_tan = aspect * v_tan;

    // Random point in frustum rectangle [-1,1] x [-1,1]
    const u = rng.float(f32) * 2.0 - 1.0;
    const v = rng.float(f32) * 2.0 - 1.0;

    return normalize3(.{
        look_dir[0] + u * h_tan * right[0] + v * v_tan * cam_up[0],
        look_dir[1] + u * h_tan * right[1] + v * v_tan * cam_up[1],
        look_dir[2] + u * h_tan * right[2] + v * v_tan * cam_up[2],
    });
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

// ── Activation functions ────────────────────────────────────────────

fn sigmoid(x: f32) f32 {
    if (x > 15) return 1.0;
    if (x < -15) return 0.0;
    return 1.0 / (1.0 + @exp(-x));
}

fn leakyRelu(x: f32) f32 {
    return if (x > 0) x else 0.01 * x;
}

fn leakyReluDeriv(x: f32) f32 {
    return if (x > 0) @as(f32, 1.0) else 0.01;
}

/// Normalize vfov to [0,1]
pub fn normVfov(vfov: f32) f32 {
    return std.math.clamp((vfov - MIN_VFOV) / (MAX_VFOV - MIN_VFOV), 0, 1);
}

/// Normalize aspect to [0,1]
pub fn normAspect(aspect: f32) f32 {
    return std.math.clamp((aspect - MIN_ASPECT) / (MAX_ASPECT - MIN_ASPECT), 0, 1);
}

// ── Training Data ───────────────────────────────────────────────────

pub const TrainingConfig = struct {
    num_samples: u32 = 20_000,
    rays_per_sample: u32 = 256,
    max_ray_dist: f32 = 2000.0,
    bundle_offset: f32 = 0.001,
    // Frustum parameter ranges for random sampling
    min_pitch: f32 = -0.785, // -45 degrees
    max_pitch: f32 = 0.785, // +45 degrees
    min_vfov: f32 = MIN_VFOV,
    max_vfov: f32 = MAX_VFOV,
    min_aspect: f32 = MIN_ASPECT,
    max_aspect: f32 = MAX_ASPECT,
    // From-region stability (Wang et al. 2025): jitter positions within radius
    // to teach stable predictions across small camera movements
    jitter_radius: f32 = 0.3, // meters — viewcell radius
    jitter_count: u32 = 3, // extra jittered samples per primary sample
};

pub const TrainingData = struct {
    positions: []Vec3,
    params: [][6]f32, // sin_yaw, cos_yaw, sin_pitch, cos_pitch, vfov_norm, aspect_norm
    labels: [][]u8, // packed model bitsets
    num_models: u32,
    bitset_stride: u32,
    num_samples: u32,
    total_rays: u64,
    allocator: Allocator,

    pub fn deinit(self: *TrainingData) void {
        for (self.labels) |l| self.allocator.free(l);
        self.allocator.free(self.labels);
        self.allocator.free(self.params);
        self.allocator.free(self.positions);
    }
};

/// Per-thread results from parallel data generation.
const ThreadResult = struct {
    positions: std.ArrayList(Vec3),
    params: std.ArrayList([6]f32),
    labels: std.ArrayList([]u8),
    sample_count: u32,
    total_rays: u64,
    attempts: u64,
};

/// Generate a single training sample. Returns true if sample was valid (found visible models).
fn generateOneSample(
    bivh: *const bivh_mod.Bivh,
    mesh_set: *const bivh_mod.TriangleMeshSet,
    world_perm: []const u32,
    tri_to_model: []const u32,
    num_models: u32,
    pos_min: Vec3,
    pos_max: Vec3,
    config: TrainingConfig,
    result: *ThreadResult,
    thread_alloc: Allocator,
) bool {
    const rng = std.crypto.random;
    const bitset_stride: u32 = (num_models + 7) / 8;

    const pos = Vec3{
        pos_min[0] + rng.float(f32) * (pos_max[0] - pos_min[0]),
        pos_min[1] + rng.float(f32) * (pos_max[1] - pos_min[1]),
        pos_min[2] + rng.float(f32) * (pos_max[2] - pos_min[2]),
    };

    const yaw = rng.float(f32) * 2.0 * std.math.pi;
    const pitch = config.min_pitch + rng.float(f32) * (config.max_pitch - config.min_pitch);
    const vfov = config.min_vfov + rng.float(f32) * (config.max_vfov - config.min_vfov);
    const aspect = config.min_aspect + rng.float(f32) * (config.max_aspect - config.min_aspect);

    const sin_yaw = @sin(yaw);
    const cos_yaw = @cos(yaw);
    const sin_pitch = @sin(pitch);
    const cos_pitch = @cos(pitch);
    const look_dir = lookDirFromAngles(sin_yaw, cos_yaw, sin_pitch, cos_pitch);

    const bitset = thread_alloc.alloc(u8, bitset_stride) catch return false;
    @memset(bitset, 0);
    var found_any = false;
    var rays: u64 = 0;

    for (0..config.rays_per_sample) |_| {
        const dir = randomInFrustum(look_dir, vfov, aspect, rng);
        var ray = bivh_mod.TraceRay.make(pos[0], pos[1], pos[2], dir[0], dir[1], dir[2], config.max_ray_dist);
        const hit = bivh.trace(mesh_set, &ray, 0.0001, config.max_ray_dist);
        rays += 1;

        if (hit and ray.hit_primitive >= 0) {
            const sorted_idx: u32 = @intCast(ray.hit_primitive);
            if (sorted_idx >= world_perm.len) continue;
            const orig_idx = world_perm[sorted_idx];
            if (orig_idx >= tri_to_model.len) continue;
            const model_id = tri_to_model[orig_idx];

            if (model_id != std.math.maxInt(u32) and model_id < num_models) {
                const was_new = !bitsetGet(bitset, model_id);
                bitsetSet(bitset, model_id);
                found_any = true;

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
                                if (b_orig < tri_to_model.len) {
                                    const b_model = tri_to_model[b_orig];
                                    if (b_model != std.math.maxInt(u32) and b_model < num_models) {
                                        bitsetSet(bitset, b_model);
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
        const param = [6]f32{ sin_yaw, cos_yaw, sin_pitch, cos_pitch, normVfov(vfov), normAspect(aspect) };
        result.positions.append(pos) catch return false;
        result.params.append(param) catch return false;
        result.labels.append(bitset) catch return false;
        result.sample_count += 1;

        // From-region jitter
        for (0..config.jitter_count) |_| {
            const jx = (rng.float(f32) * 2.0 - 1.0) * config.jitter_radius;
            const jy = (rng.float(f32) * 2.0 - 1.0) * config.jitter_radius;
            const jz = (rng.float(f32) * 2.0 - 1.0) * config.jitter_radius;
            const jittered_pos = Vec3{
                std.math.clamp(pos[0] + jx, pos_min[0], pos_max[0]),
                std.math.clamp(pos[1] + jy, pos_min[1], pos_max[1]),
                std.math.clamp(pos[2] + jz, pos_min[2], pos_max[2]),
            };

            const jittered_label = thread_alloc.alloc(u8, bitset_stride) catch continue;
            @memcpy(jittered_label, bitset);
            result.positions.append(jittered_pos) catch continue;
            result.params.append(param) catch continue;
            result.labels.append(jittered_label) catch continue;
        }

        return true;
    } else {
        thread_alloc.free(bitset);
        return false;
    }
}

/// Worker function for parallel data generation.
fn dataGenWorker(
    bivh: *const bivh_mod.Bivh,
    mesh_set: *const bivh_mod.TriangleMeshSet,
    world_perm: []const u32,
    tri_to_model: []const u32,
    num_models: u32,
    pos_min: Vec3,
    pos_max: Vec3,
    config: TrainingConfig,
    target_samples: u32,
    result: *ThreadResult,
) void {
    const thread_alloc = result.positions.allocator;
    var generated: u32 = 0;
    var att: u64 = 0;
    const max_att: u64 = @as(u64, target_samples) * 10;

    while (generated < target_samples and att < max_att) : (att += 1) {
        if (generateOneSample(
            bivh, mesh_set, world_perm, tri_to_model,
            num_models, pos_min, pos_max, config, result, thread_alloc,
        )) {
            generated += 1;
        }
    }
}

/// Generate frustum-aware training data via ray bundles (parallelized).
/// Each sample: random (position, yaw, pitch, vfov, aspect) → cast rays within frustum →
/// record which models are visible. Bundle refinement on hit.
pub fn generateTrainingData(
    allocator: Allocator,
    bivh: *const bivh_mod.Bivh,
    mesh_set: *const bivh_mod.TriangleMeshSet,
    world_perm: []const u32,
    tri_to_model: []const u32,
    num_models: u32,
    pos_min: Vec3,
    pos_max: Vec3,
    config: TrainingConfig,
    stdout: anytype,
) !TrainingData {
    const num_threads = @max(1, std.Thread.getCpuCount() catch 4);
    const samples_per_thread = (config.num_samples + @as(u32, @intCast(num_threads)) - 1) / @as(u32, @intCast(num_threads));

    try stdout.print("  Generating {d} frustum-aware samples ({d} rays/sample, {d} threads)...\n", .{
        config.num_samples, config.rays_per_sample, num_threads,
    });

    // Per-thread arenas to avoid GPA mutex contention
    const thread_arenas = try allocator.alloc(std.heap.ArenaAllocator, num_threads);
    defer allocator.free(thread_arenas);
    for (thread_arenas) |*arena| arena.* = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer for (thread_arenas) |*arena| arena.deinit();

    // Per-thread results using thread-local arenas
    const thread_results = try allocator.alloc(ThreadResult, num_threads);
    defer allocator.free(thread_results);
    for (thread_results, thread_arenas) |*tr, *arena| {
        const ta = arena.allocator();
        tr.* = .{
            .positions = std.ArrayList(Vec3).init(ta),
            .params = std.ArrayList([6]f32).init(ta),
            .labels = std.ArrayList([]u8).init(ta),
            .sample_count = 0,
            .total_rays = 0,
            .attempts = 0,
        };
    }

    // Spawn threads
    const threads = try allocator.alloc(std.Thread, num_threads);
    defer allocator.free(threads);

    for (thread_results, threads) |*tr, *t| {
        t.* = try std.Thread.spawn(.{}, dataGenWorker, .{
            bivh, mesh_set, world_perm, tri_to_model,
            num_models, pos_min, pos_max, config,
            samples_per_thread, tr,
        });
    }

    for (threads) |t| t.join();

    // Merge results
    var total_primary: u32 = 0;
    var total_rays: u64 = 0;
    var total_attempts: u64 = 0;
    for (thread_results) |tr| {
        total_primary += tr.sample_count;
        total_rays += tr.total_rays;
        total_attempts += tr.attempts;
    }

    // Count total samples including jitter
    var total_samples: usize = 0;
    for (thread_results) |tr| total_samples += tr.positions.items.len;

    // Merge into single arrays (copy from thread arenas to main allocator)
    const bitset_stride: u32 = (num_models + 7) / 8;
    var positions = try allocator.alloc(Vec3, total_samples);
    var params = try allocator.alloc([6]f32, total_samples);
    var labels_arr = try allocator.alloc([]u8, total_samples);
    var offset: usize = 0;
    for (thread_results) |tr| {
        const n = tr.positions.items.len;
        @memcpy(positions[offset..][0..n], tr.positions.items);
        @memcpy(params[offset..][0..n], tr.params.items);
        // Deep-copy label bitsets from thread arena to main allocator
        for (tr.labels.items, 0..) |arena_label, li| {
            const label = try allocator.alloc(u8, bitset_stride);
            @memcpy(label, arena_label);
            labels_arr[offset + li] = label;
        }
        offset += n;
    }

    try stdout.print("  Generated {d} primary + {d} jittered = {d} total, {d}M rays ({d} threads, {d} attempts)\n", .{
        total_primary, total_samples - total_primary, total_samples,
        total_rays / 1_000_000, num_threads, total_attempts,
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
            try stdout.print("  Models/sample: min={d}, max={d}, avg={d}\n", .{
                min_vis, max_vis, @as(u32, @intCast(total_vis / total_samples)),
            });
        }
    }

    return .{
        .positions = positions,
        .params = params,
        .labels = labels_arr,
        .num_models = num_models,
        .bitset_stride = (num_models + 7) / 8,
        .num_samples = @intCast(total_samples),
        .total_rays = total_rays,
        .allocator = allocator,
    };
}

// ── Spatial + Distance Loss Weighting ───────────────────────────────

/// Compute per-model FN penalty weights based on angular distance from
/// view center and distance from camera. Close + center = max penalty.
pub fn computeSpatialWeights(
    weights: []f32, // output: one weight per model
    pos: Vec3,
    look_dir: Vec3,
    model_centroids: []const Vec3,
    base_weight: f32,
    center_boost: f32, // extra FN penalty for center models (~2.0)
    near_boost: f32, // extra FN penalty for nearby models (~2.0)
    ref_dist: f32, // distance reference (~5.0 meters)
) void {
    for (weights, 0..) |*w, i| {
        if (i >= model_centroids.len) {
            w.* = base_weight;
            continue;
        }
        const to_model = sub3(model_centroids[i], pos);
        const dist = length3(to_model);

        // Angular factor: dot with look direction (1.0 = dead center, 0 = 90deg)
        const cos_angle = if (dist > 0.01) dot3(look_dir, scale3(to_model, 1.0 / dist)) else 0;
        const center_factor = @max(0.0, cos_angle);

        // Distance factor: close models matter more
        const near_factor = 1.0 / (1.0 + dist / ref_dist);

        w.* = base_weight * (1.0 + center_boost * center_factor + near_boost * near_factor);
    }
}

// ── MLP ─────────────────────────────────────────────────────────────

pub const MLP = struct {
    hidden_size: u32,
    output_size: u32,

    // Parameters (owned by arena)
    w1: []f32, // INPUT_SIZE × hidden
    b1: []f32,
    w2: []f32, // hidden × hidden
    b2: []f32,
    w3: []f32, // hidden × output
    b3: []f32,

    // Adam moment estimates
    m_w1: []f32, v_w1: []f32,
    m_b1: []f32, v_b1: []f32,
    m_w2: []f32, v_w2: []f32,
    m_b2: []f32, v_b2: []f32,
    m_w3: []f32, v_w3: []f32,
    m_b3: []f32, v_b3: []f32,

    // Activation cache
    z1: []f32, a1: []f32,
    z2: []f32, a2: []f32,
    out: []f32,

    // Backprop deltas
    d3: []f32, d2: []f32, d1: []f32,

    // Gradient accumulation (mini-batch)
    gw1: []f32, gb1: []f32,
    gw2: []f32, gb2: []f32,
    gw3: []f32, gb3: []f32,

    // Normalization
    pos_min: Vec3,
    pos_scale: Vec3,

    adam_t: u32 = 0,
    arena: std.heap.ArenaAllocator,

    const adam_beta1: f32 = 0.9;
    const adam_beta2: f32 = 0.999;
    const adam_eps: f32 = 1e-8;
    const grad_clip: f32 = 1.0;

    pub fn init(allocator: Allocator, num_models: u32, hidden: u32, pos_min: Vec3, pos_max: Vec3) !MLP {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        const h = hidden;
        const o = num_models;
        const inp = INPUT_SIZE;

        const mlp = MLP{
            .hidden_size = h,
            .output_size = o,
            .w1 = try a.alloc(f32, inp * h), .b1 = try a.alloc(f32, h),
            .w2 = try a.alloc(f32, h * h), .b2 = try a.alloc(f32, h),
            .w3 = try a.alloc(f32, h * o), .b3 = try a.alloc(f32, o),
            .m_w1 = try a.alloc(f32, inp * h), .v_w1 = try a.alloc(f32, inp * h),
            .m_b1 = try a.alloc(f32, h), .v_b1 = try a.alloc(f32, h),
            .m_w2 = try a.alloc(f32, h * h), .v_w2 = try a.alloc(f32, h * h),
            .m_b2 = try a.alloc(f32, h), .v_b2 = try a.alloc(f32, h),
            .m_w3 = try a.alloc(f32, h * o), .v_w3 = try a.alloc(f32, h * o),
            .m_b3 = try a.alloc(f32, o), .v_b3 = try a.alloc(f32, o),
            .z1 = try a.alloc(f32, h), .a1 = try a.alloc(f32, h),
            .z2 = try a.alloc(f32, h), .a2 = try a.alloc(f32, h),
            .out = try a.alloc(f32, o),
            .d3 = try a.alloc(f32, o), .d2 = try a.alloc(f32, h), .d1 = try a.alloc(f32, h),
            .gw1 = try a.alloc(f32, inp * h), .gb1 = try a.alloc(f32, h),
            .gw2 = try a.alloc(f32, h * h), .gb2 = try a.alloc(f32, h),
            .gw3 = try a.alloc(f32, h * o), .gb3 = try a.alloc(f32, o),
            .pos_min = pos_min,
            .pos_scale = .{
                1.0 / @max(pos_max[0] - pos_min[0], 0.001),
                1.0 / @max(pos_max[1] - pos_min[1], 0.001),
                1.0 / @max(pos_max[2] - pos_min[2], 0.001),
            },
            .arena = arena,
        };

        // Zero all moment + gradient buffers
        inline for (.{
            mlp.m_w1, mlp.v_w1, mlp.m_b1, mlp.v_b1,
            mlp.m_w2, mlp.v_w2, mlp.m_b2, mlp.v_b2,
            mlp.m_w3, mlp.v_w3, mlp.m_b3, mlp.v_b3,
            mlp.gw1,  mlp.gb1,  mlp.gw2,  mlp.gb2,
            mlp.gw3,  mlp.gb3,
        }) |buf| @memset(buf, 0);

        // Xavier initialization
        const rng = std.crypto.random;
        xavierInit(mlp.w1, inp, h, rng);
        xavierInit(mlp.w2, h, h, rng);
        xavierInit(mlp.w3, h, o, rng);
        @memset(mlp.b1, 0);
        @memset(mlp.b2, 0);
        @memset(mlp.b3, 0);

        return mlp;
    }

    pub fn deinit(self: *MLP) void {
        self.arena.deinit();
    }

    /// Build 9-element input vector
    fn buildInput(self: *const MLP, pos: Vec3, p: [6]f32) [INPUT_SIZE]f32 {
        return .{
            (pos[0] - self.pos_min[0]) * self.pos_scale[0],
            (pos[1] - self.pos_min[1]) * self.pos_scale[1],
            (pos[2] - self.pos_min[2]) * self.pos_scale[2],
            p[0], // sin_yaw
            p[1], // cos_yaw
            p[2], // sin_pitch
            p[3], // cos_pitch
            p[4], // vfov_norm
            p[5], // aspect_norm
        };
    }

    pub fn forward(self: *MLP, pos: Vec3, p: [6]f32) []const f32 {
        const input = self.buildInput(pos, p);
        const h = self.hidden_size;
        const o = self.output_size;

        for (0..h) |j| {
            var sum: f32 = self.b1[j];
            inline for (0..INPUT_SIZE) |k| {
                sum += input[k] * self.w1[k * h + j];
            }
            self.z1[j] = sum;
            self.a1[j] = leakyRelu(sum);
        }

        for (0..h) |j| {
            var sum: f32 = self.b2[j];
            for (0..h) |k| sum += self.a1[k] * self.w2[k * h + j];
            self.z2[j] = sum;
            self.a2[j] = leakyRelu(sum);
        }

        for (0..o) |j| {
            var sum: f32 = self.b3[j];
            for (0..h) |k| sum += self.a2[k] * self.w3[k * o + j];
            self.out[j] = sigmoid(sum);
        }

        return self.out;
    }

    /// Accumulate gradients with per-model spatial weights + Repulsive Visibility Loss.
    /// model_weights[j] is the FN penalty for model j (higher = more important).
    /// rvl_lambda blends BCE (λ) with RVL (1-λ). RVL pushes FPs down proportional to 1/GTP.
    /// Reference: Wang et al. "NeuralPVS: Learned Estimation of Potentially Visible Sets" (2025)
    pub fn accumulateGradients(self: *MLP, pos: Vec3, p: [6]f32, target: []const u8, model_weights: []const f32, rvl_lambda: f32) f32 {
        const input = self.buildInput(pos, p);
        const h = self.hidden_size;
        const o = self.output_size;

        // Count ground truth positives for RVL normalization
        const gtp: f32 = @floatFromInt(@max(bitsetCount(target), 1));
        const inv_gtp = 1.0 / gtp;

        // Output deltas: blend BCE + RVL
        var loss: f32 = 0;
        for (0..o) |j| {
            const t: f32 = if (bitsetGet(target, j)) 1.0 else 0.0;
            const pred = self.out[j];
            const cp = std.math.clamp(pred, 1e-7, 1.0 - 1e-7);

            // BCE gradient (weighted: FN penalty for visible models)
            const w = if (t > 0.5) model_weights[j] else 1.0;
            const bce_grad = w * (pred - t);
            loss -= w * (t * @log(cp) + (1.0 - t) * @log(1.0 - cp));

            // RVL gradient: attract toward visible GT, repel from non-visible
            // L_attr derivative: if target=1, push pred up (grad = -pred·inv_gtp)
            // L_rep derivative:  if target=0, push pred down (grad = +pred·inv_gtp)
            const rvl_grad = if (t > 0.5)
                -pred * inv_gtp * model_weights[j] // attract: strengthen with spatial weight
            else
                pred * inv_gtp; // repel: push FPs down

            self.d3[j] = rvl_lambda * bce_grad + (1.0 - rvl_lambda) * rvl_grad;
        }

        // Hidden deltas
        for (0..h) |k| {
            var sum: f32 = 0;
            for (0..o) |j| sum += self.w3[k * o + j] * self.d3[j];
            self.d2[k] = sum * leakyReluDeriv(self.z2[k]);
        }
        for (0..h) |k| {
            var sum: f32 = 0;
            for (0..h) |j| sum += self.w2[k * h + j] * self.d2[j];
            self.d1[k] = sum * leakyReluDeriv(self.z1[k]);
        }

        // Accumulate gradients
        for (0..h) |k| for (0..o) |j| {
            self.gw3[k * o + j] += self.a2[k] * self.d3[j];
        };
        for (0..o) |j| self.gb3[j] += self.d3[j];

        for (0..h) |k| for (0..h) |j| {
            self.gw2[k * h + j] += self.a1[k] * self.d2[j];
        };
        for (0..h) |j| self.gb2[j] += self.d2[j];

        inline for (0..INPUT_SIZE) |k| {
            for (0..h) |j| self.gw1[k * h + j] += input[k] * self.d1[j];
        }
        for (0..h) |j| self.gb1[j] += self.d1[j];

        return loss;
    }

    pub fn applyAdam(self: *MLP, lr: f32, batch_size: f32) void {
        self.adam_t += 1;
        const t_f: f32 = @floatFromInt(self.adam_t);
        const beta1_t = std.math.pow(f32, adam_beta1, t_f);
        const beta2_t = std.math.pow(f32, adam_beta2, t_f);
        const inv_bs = 1.0 / batch_size;

        applyAdamToArrays(self.w3, self.gw3, self.m_w3, self.v_w3, lr, inv_bs, beta1_t, beta2_t);
        applyAdamToArrays(self.b3, self.gb3, self.m_b3, self.v_b3, lr, inv_bs, beta1_t, beta2_t);
        applyAdamToArrays(self.w2, self.gw2, self.m_w2, self.v_w2, lr, inv_bs, beta1_t, beta2_t);
        applyAdamToArrays(self.b2, self.gb2, self.m_b2, self.v_b2, lr, inv_bs, beta1_t, beta2_t);
        applyAdamToArrays(self.w1, self.gw1, self.m_w1, self.v_w1, lr, inv_bs, beta1_t, beta2_t);
        applyAdamToArrays(self.b1, self.gb1, self.m_b1, self.v_b1, lr, inv_bs, beta1_t, beta2_t);
    }

    fn applyAdamToArrays(w: []f32, g: []f32, m: []f32, v: []f32, lr: f32, inv_bs: f32, beta1_t: f32, beta2_t: f32) void {
        for (w, g, m, v) |*wi, *gi, *mi, *vi| {
            const grad = std.math.clamp(gi.* * inv_bs, -grad_clip, grad_clip);
            mi.* = adam_beta1 * mi.* + (1.0 - adam_beta1) * grad;
            vi.* = adam_beta2 * vi.* + (1.0 - adam_beta2) * grad * grad;
            const m_hat = mi.* / (1.0 - beta1_t);
            const v_hat = vi.* / (1.0 - beta2_t);
            wi.* -= lr * m_hat / (@sqrt(v_hat) + adam_eps);
            gi.* = 0;
        }
    }

    /// Save weights (NPVS v3 format: frustum-integrated).
    pub fn save(self: *const MLP, path: []const u8) !void {
        var file = try std.fs.cwd().createFile(path, .{});
        defer file.close();
        var bw = std.io.bufferedWriter(file.writer());
        const w = bw.writer();

        try w.writeAll("NPVS");
        try w.writeInt(u32, 3, .little); // version 3: frustum-integrated
        try w.writeInt(u32, INPUT_SIZE, .little);
        try w.writeInt(u32, self.hidden_size, .little);
        try w.writeInt(u32, self.output_size, .little);
        for (self.pos_min) |val| try w.writeInt(u32, @bitCast(val), .little);
        for (0..3) |i| {
            const max_v = self.pos_min[i] + 1.0 / self.pos_scale[i];
            try w.writeInt(u32, @bitCast(max_v), .little);
        }

        for (self.w1) |val| try w.writeInt(u32, @bitCast(val), .little);
        for (self.b1) |val| try w.writeInt(u32, @bitCast(val), .little);
        for (self.w2) |val| try w.writeInt(u32, @bitCast(val), .little);
        for (self.b2) |val| try w.writeInt(u32, @bitCast(val), .little);
        for (self.w3) |val| try w.writeInt(u32, @bitCast(val), .little);
        for (self.b3) |val| try w.writeInt(u32, @bitCast(val), .little);

        try bw.flush();
    }

    pub fn load(allocator: Allocator, path: []const u8) !MLP {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();
        var br = std.io.bufferedReader(file.reader());
        const reader = br.reader();

        var magic: [4]u8 = undefined;
        _ = try reader.readAll(&magic);
        if (!std.mem.eql(u8, &magic, "NPVS")) return error.InvalidMagic;

        const version = try reader.readInt(u32, .little);
        if (version != 3) return error.UnsupportedVersion;

        const input_size = try reader.readInt(u32, .little);
        if (input_size != INPUT_SIZE) return error.InputSizeMismatch;

        const hidden = try reader.readInt(u32, .little);
        const output = try reader.readInt(u32, .little);

        var pm: Vec3 = undefined;
        var px: Vec3 = undefined;
        for (&pm) |*val| val.* = @bitCast(try reader.readInt(u32, .little));
        for (&px) |*val| val.* = @bitCast(try reader.readInt(u32, .little));

        var mlp = try MLP.init(allocator, output, hidden, pm, px);
        errdefer mlp.deinit();

        for (mlp.w1) |*val| val.* = @bitCast(try reader.readInt(u32, .little));
        for (mlp.b1) |*val| val.* = @bitCast(try reader.readInt(u32, .little));
        for (mlp.w2) |*val| val.* = @bitCast(try reader.readInt(u32, .little));
        for (mlp.b2) |*val| val.* = @bitCast(try reader.readInt(u32, .little));
        for (mlp.w3) |*val| val.* = @bitCast(try reader.readInt(u32, .little));
        for (mlp.b3) |*val| val.* = @bitCast(try reader.readInt(u32, .little));

        return mlp;
    }
};

// ── Training ────────────────────────────────────────────────────────

pub const TrainConfig = struct {
    epochs: u32 = 100,
    learning_rate: f32 = 0.001,
    batch_size: u32 = 32,
    hidden_size: u32 = 256,
    eval_threshold: f32 = 0.3,
    // Spatial loss weighting
    center_boost: f32 = 2.0, // extra FN penalty for center-of-view models
    near_boost: f32 = 2.0, // extra FN penalty for nearby models
    ref_dist: f32 = 5.0, // distance reference (meters in world coords)
    // Repulsive Visibility Loss (Wang et al. 2025)
    rvl_lambda: f32 = 0.85, // blend: λ·BCE + (1-λ)·RVL (paper uses 0.99 for Dice+RVL)
};

/// Train MLP on frustum-aware training data with spatial loss weighting.
pub fn train(
    allocator: Allocator,
    data: *const TrainingData,
    model_centroids: []const Vec3,
    pos_min: Vec3,
    pos_max: Vec3,
    config: TrainConfig,
    stdout: anytype,
) !MLP {
    var mlp = try MLP.init(allocator, data.num_models, config.hidden_size, pos_min, pos_max);
    errdefer mlp.deinit();

    const n = data.num_samples;
    if (n == 0) return mlp;

    // Compute base class-balanced weight
    var total_pos: u64 = 0;
    const total_samples_models: u64 = @as(u64, n) * data.num_models;
    for (data.labels[0..n]) |label| total_pos += bitsetCount(label);
    const total_neg = total_samples_models - total_pos;
    const base_weight: f32 = @min(
        if (total_pos > 0) @as(f32, @floatFromInt(total_neg)) / @as(f32, @floatFromInt(total_pos)) else 1.0,
        5.0,
    );

    // Per-model weight buffer (reused each sample)
    const model_weights = try allocator.alloc(f32, data.num_models);
    defer allocator.free(model_weights);

    const indices = try allocator.alloc(u32, n);
    defer allocator.free(indices);
    for (0..n) |i| indices[i] = @intCast(i);

    const num_params = INPUT_SIZE * config.hidden_size + config.hidden_size +
        config.hidden_size * config.hidden_size + config.hidden_size +
        config.hidden_size * data.num_models + data.num_models;

    try stdout.print("  Training MLP (frustum-integrated, spatial+distance weighted)\n", .{});
    try stdout.print("  Input: {d} (pos+yaw+pitch+vfov+aspect), H={d}, Output: {d}\n", .{
        INPUT_SIZE, config.hidden_size, data.num_models,
    });
    try stdout.print("  Samples: {d}, Epochs: {d}, lr={d:.4}, batch={d}, params={d}\n", .{
        n, config.epochs, config.learning_rate, config.batch_size, num_params,
    });
    try stdout.print("  base_weight={d:.1}, center_boost={d:.1}, near_boost={d:.1}, ref_dist={d:.1}, rvl_λ={d:.2}\n", .{
        base_weight, config.center_boost, config.near_boost, config.ref_dist, config.rvl_lambda,
    });

    const bs = config.batch_size;

    for (0..config.epochs) |epoch| {
        shuffle(indices, std.crypto.random);

        // Cosine LR decay: lr * 0.5 * (1 + cos(π * epoch / epochs))
        const progress = @as(f32, @floatFromInt(epoch)) / @as(f32, @floatFromInt(@max(config.epochs, 1)));
        const lr = config.learning_rate * 0.5 * (1.0 + @cos(progress * std.math.pi));

        var epoch_loss: f64 = 0;
        var batch_count: u32 = 0;

        for (indices, 0..) |idx, si| {
            const p = data.params[idx];
            const look_dir = lookDirFromAngles(p[0], p[1], p[2], p[3]);

            // Compute per-model spatial + distance weights
            computeSpatialWeights(
                model_weights,
                data.positions[idx],
                look_dir,
                model_centroids,
                base_weight,
                config.center_boost,
                config.near_boost,
                config.ref_dist,
            );

            _ = mlp.forward(data.positions[idx], p);
            const loss = mlp.accumulateGradients(data.positions[idx], p, data.labels[idx], model_weights, config.rvl_lambda);
            epoch_loss += loss;
            batch_count += 1;

            if (batch_count >= bs or si == indices.len - 1) {
                mlp.applyAdam(lr, @floatFromInt(batch_count));
                batch_count = 0;
            }
        }

        if (epoch < 5 or epoch % 5 == 0 or epoch == config.epochs - 1) {
            // Progress to stderr (unbuffered, visible in piped output)
            std.io.getStdErr().writer().print("[NPVS] Epoch {d}/{d}\n", .{ epoch, config.epochs }) catch {};
            var eval_fn: u64 = 0;
            var eval_fp: u64 = 0;
            var eval_pos: u64 = 0;
            var eval_neg: u64 = 0;

            // Subsample eval to avoid expensive full pass
            const eval_n = @min(n, 10_000);
            const eval_step = n / eval_n;
            var ei: u32 = 0;
            while (ei < n) : (ei += @intCast(eval_step)) {
                const i = ei;
                _ = mlp.forward(data.positions[i], data.params[i]);
                for (0..data.num_models) |j| {
                    const actual = bitsetGet(data.labels[i], j);
                    const predicted = mlp.out[j] > config.eval_threshold;
                    if (actual) {
                        eval_pos += 1;
                        if (!predicted) eval_fn += 1;
                    } else {
                        eval_neg += 1;
                        if (predicted) eval_fp += 1;
                    }
                }
            }

            const fn_rate = if (eval_pos > 0) @as(f32, @floatFromInt(eval_fn)) / @as(f32, @floatFromInt(eval_pos)) else 0;
            const fp_rate = if (eval_neg > 0) @as(f32, @floatFromInt(eval_fp)) / @as(f32, @floatFromInt(eval_neg)) else 0;

            try stdout.print("  Epoch {d:>4}: loss={d:.2}, FN={d:.2}%, FP={d:.1}%, lr={d:.6}\n", .{
                epoch,
                epoch_loss / @as(f64, @floatFromInt(n)),
                fn_rate * 100,
                fp_rate * 100,
                lr,
            });
        }
    }

    return mlp;
}

// ── Helpers ─────────────────────────────────────────────────────────

fn xavierInit(weights: []f32, fan_in: u32, fan_out: u32, rng: std.Random) void {
    const limit = @sqrt(6.0 / @as(f32, @floatFromInt(fan_in + fan_out)));
    for (weights) |*w| {
        w.* = (rng.float(f32) * 2.0 - 1.0) * limit;
    }
}

fn shuffle(arr: []u32, rng: std.Random) void {
    var i = arr.len;
    while (i > 1) {
        i -= 1;
        const j = rng.intRangeAtMost(usize, 0, i);
        const tmp = arr[i];
        arr[i] = arr[j];
        arr[j] = tmp;
    }
}
