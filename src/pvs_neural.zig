// Neural PVS — learns visibility as a function of position + view direction.
//
// Direction-aware MLP predicts which models are visible from a position
// looking in a specific direction. Training data generated via ray bundles
// within a FOV cone (adaptive refinement on hit).
//
// Architecture: (x,y,z,sin_yaw,cos_yaw) → [H LeakyReLU] → [H LeakyReLU] → [N sigmoid]
// Loss: class-balanced BCE (auto-weighted from label statistics)
// Like a neural, spatially aware bloom filter.

const std = @import("std");
const Allocator = std.mem.Allocator;
const bivh_mod = @import("bivh");

const Vec3 = [3]f32;
const INPUT_SIZE: u32 = 5; // x, y, z, sin_yaw, cos_yaw

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

fn length3(v: Vec3) f32 {
    return @sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
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

/// Random direction within a cone of half_angle around look_dir.
/// Uses uniform sampling on spherical cap.
fn randomInCone(look_dir: Vec3, half_angle: f32, rng: std.Random) Vec3 {
    const cos_half = @cos(half_angle);
    // Uniform on spherical cap: cos(theta) in [cos_half, 1]
    const cos_theta = 1.0 - rng.float(f32) * (1.0 - cos_half);
    const sin_theta = @sqrt(1.0 - cos_theta * cos_theta);
    const phi = 2.0 * std.math.pi * rng.float(f32);

    // Local direction (z = look_dir)
    const lx = sin_theta * @cos(phi);
    const ly = sin_theta * @sin(phi);
    const lz = cos_theta;

    // Build orthonormal basis from look_dir
    const up = Vec3{ 0, 1, 0 };
    var x_axis = normalize3(cross3(up, look_dir));
    // Degenerate case: look_dir parallel to up
    if (length3(x_axis) < 0.001) {
        x_axis = normalize3(cross3(.{ 1, 0, 0 }, look_dir));
    }
    const y_axis = cross3(look_dir, x_axis);

    // Rotate local → world
    return normalize3(.{
        x_axis[0] * lx + y_axis[0] * ly + look_dir[0] * lz,
        x_axis[1] * lx + y_axis[1] * ly + look_dir[1] * lz,
        x_axis[2] * lx + y_axis[2] * ly + look_dir[2] * lz,
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

// ── Training Data ───────────────────────────────────────────────────

pub const TrainingConfig = struct {
    num_samples: u32 = 10_000,
    rays_per_sample: u32 = 256,
    max_ray_dist: f32 = 2000.0,
    bundle_offset: f32 = 0.001,
    fov_half_angle: f32 = 0.87, // ~50 degrees in radians
};

pub const TrainingData = struct {
    positions: []Vec3,
    directions: [][2]f32, // sin_yaw, cos_yaw per sample
    labels: [][]u8, // packed model bitsets
    num_models: u32,
    bitset_stride: u32,
    num_samples: u32,
    total_rays: u64,
    allocator: Allocator,

    pub fn deinit(self: *TrainingData) void {
        for (self.labels) |l| self.allocator.free(l);
        self.allocator.free(self.labels);
        self.allocator.free(self.directions);
        self.allocator.free(self.positions);
    }
};

/// Generate direction-aware training data via ray bundles.
/// Each sample: random position + random yaw → cast rays within FOV cone →
/// record which models are visible. Bundle refinement on hit (6 child rays).
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
    const rng = std.crypto.random;
    const bitset_stride: u32 = (num_models + 7) / 8;

    var positions = std.ArrayList(Vec3).init(allocator);
    defer positions.deinit();
    var directions = std.ArrayList([2]f32).init(allocator);
    defer directions.deinit();
    var labels = std.ArrayList([]u8).init(allocator);
    defer labels.deinit();

    var sample: u32 = 0;
    var total_rays: u64 = 0;
    var attempts: u64 = 0;
    const max_attempts: u64 = @as(u64, config.num_samples) * 10;

    try stdout.print("  Generating {d} direction-aware samples ({d} rays/sample, FOV={d:.0}deg)...\n", .{
        config.num_samples,
        config.rays_per_sample,
        config.fov_half_angle * 180.0 / std.math.pi * 2.0,
    });

    while (sample < config.num_samples and attempts < max_attempts) : (attempts += 1) {
        // Random position within map bounds
        const pos = Vec3{
            pos_min[0] + rng.float(f32) * (pos_max[0] - pos_min[0]),
            pos_min[1] + rng.float(f32) * (pos_max[1] - pos_min[1]),
            pos_min[2] + rng.float(f32) * (pos_max[2] - pos_min[2]),
        };

        // Random yaw (horizontal look direction in XZ plane, Y-up)
        const yaw = rng.float(f32) * 2.0 * std.math.pi;
        const sin_yaw = @sin(yaw);
        const cos_yaw = @cos(yaw);
        const look_dir = Vec3{ sin_yaw, 0, cos_yaw }; // horizontal

        const bitset = try allocator.alloc(u8, bitset_stride);
        @memset(bitset, 0);
        var found_any = false;

        // Cast rays within FOV cone around look direction
        for (0..config.rays_per_sample) |_| {
            const dir = randomInCone(look_dir, config.fov_half_angle, rng);

            var ray = bivh_mod.TraceRay.make(pos[0], pos[1], pos[2], dir[0], dir[1], dir[2], config.max_ray_dist);
            const hit = bivh.trace(mesh_set, &ray, 0.0001, config.max_ray_dist);
            total_rays += 1;

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

                    // Bundle refinement: 6 child rays on NEW discovery
                    if (was_new) {
                        const tri_base = @as(usize, sorted_idx) * 3;
                        if (tri_base + 2 >= mesh_set.indices.len) continue;
                        const v0 = mesh_set.positions[mesh_set.indices[tri_base]];
                        const v1 = mesh_set.positions[mesh_set.indices[tri_base + 1]];
                        const v2 = mesh_set.positions[mesh_set.indices[tri_base + 2]];

                        const probes = [6]Vec3{
                            v0,              v1,              v2,
                            midpoint(v0, v1), midpoint(v0, v2), midpoint(v1, v2),
                        };

                        for (probes) |probe| {
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
                            total_rays += 1;

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

        if (found_any) {
            try positions.append(pos);
            try directions.append(.{ sin_yaw, cos_yaw });
            try labels.append(bitset);
            sample += 1;
            if (sample % 1000 == 0) {
                try stdout.print("    {d}/{d} samples, {d}M rays\n", .{ sample, config.num_samples, total_rays / 1_000_000 });
            }
        } else {
            allocator.free(bitset);
        }
    }

    try stdout.print("  Generated {d} samples, {d}M rays total ({d} attempts)\n", .{
        sample, total_rays / 1_000_000, attempts,
    });

    // Stats on label density
    {
        var min_vis: u32 = std.math.maxInt(u32);
        var max_vis: u32 = 0;
        var total_vis: u64 = 0;
        for (labels.items) |l| {
            const c = bitsetCount(l);
            min_vis = @min(min_vis, c);
            max_vis = @max(max_vis, c);
            total_vis += c;
        }
        if (sample > 0) {
            try stdout.print("  Models/sample: min={d}, max={d}, avg={d}\n", .{
                min_vis, max_vis, @as(u32, @intCast(total_vis / sample)),
            });
        }
    }

    return .{
        .positions = try positions.toOwnedSlice(),
        .directions = try directions.toOwnedSlice(),
        .labels = try labels.toOwnedSlice(),
        .num_models = num_models,
        .bitset_stride = bitset_stride,
        .num_samples = sample,
        .total_rays = total_rays,
        .allocator = allocator,
    };
}

// ── MLP ─────────────────────────────────────────────────────────────

pub const MLP = struct {
    // Architecture
    hidden_size: u32,
    output_size: u32,

    // Parameters (owned by arena)
    w1: []f32, // INPUT_SIZE × hidden
    b1: []f32, // hidden
    w2: []f32, // hidden × hidden
    b2: []f32, // hidden
    w3: []f32, // hidden × output
    b3: []f32, // output

    // Adam moment estimates
    m_w1: []f32, v_w1: []f32,
    m_b1: []f32, v_b1: []f32,
    m_w2: []f32, v_w2: []f32,
    m_b2: []f32, v_b2: []f32,
    m_w3: []f32, v_w3: []f32,
    m_b3: []f32, v_b3: []f32,

    // Activation cache
    z1: []f32,
    a1: []f32, // post-LeakyReLU
    z2: []f32,
    a2: []f32, // post-LeakyReLU
    out: []f32, // post-sigmoid = predictions

    // Backprop deltas
    d3: []f32,
    d2: []f32,
    d1: []f32,

    // Gradient accumulation buffers (for mini-batch)
    gw1: []f32, gb1: []f32,
    gw2: []f32, gb2: []f32,
    gw3: []f32, gb3: []f32,

    // Normalization (position only — direction is already [-1,1])
    pos_min: Vec3,
    pos_scale: Vec3,

    // Adam state
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
            .w1 = try a.alloc(f32, inp * h),
            .b1 = try a.alloc(f32, h),
            .w2 = try a.alloc(f32, h * h),
            .b2 = try a.alloc(f32, h),
            .w3 = try a.alloc(f32, h * o),
            .b3 = try a.alloc(f32, o),
            .m_w1 = try a.alloc(f32, inp * h),
            .v_w1 = try a.alloc(f32, inp * h),
            .m_b1 = try a.alloc(f32, h),
            .v_b1 = try a.alloc(f32, h),
            .m_w2 = try a.alloc(f32, h * h),
            .v_w2 = try a.alloc(f32, h * h),
            .m_b2 = try a.alloc(f32, h),
            .v_b2 = try a.alloc(f32, h),
            .m_w3 = try a.alloc(f32, h * o),
            .v_w3 = try a.alloc(f32, h * o),
            .m_b3 = try a.alloc(f32, o),
            .v_b3 = try a.alloc(f32, o),
            .z1 = try a.alloc(f32, h),
            .a1 = try a.alloc(f32, h),
            .z2 = try a.alloc(f32, h),
            .a2 = try a.alloc(f32, h),
            .out = try a.alloc(f32, o),
            .d3 = try a.alloc(f32, o),
            .d2 = try a.alloc(f32, h),
            .d1 = try a.alloc(f32, h),
            // Gradient accumulators
            .gw1 = try a.alloc(f32, inp * h),
            .gb1 = try a.alloc(f32, h),
            .gw2 = try a.alloc(f32, h * h),
            .gb2 = try a.alloc(f32, h),
            .gw3 = try a.alloc(f32, h * o),
            .gb3 = try a.alloc(f32, o),
            .pos_min = pos_min,
            .pos_scale = .{
                1.0 / @max(pos_max[0] - pos_min[0], 0.001),
                1.0 / @max(pos_max[1] - pos_min[1], 0.001),
                1.0 / @max(pos_max[2] - pos_min[2], 0.001),
            },
            .arena = arena,
        };

        // Zero Adam moments
        @memset(mlp.m_w1, 0);
        @memset(mlp.v_w1, 0);
        @memset(mlp.m_b1, 0);
        @memset(mlp.v_b1, 0);
        @memset(mlp.m_w2, 0);
        @memset(mlp.v_w2, 0);
        @memset(mlp.m_b2, 0);
        @memset(mlp.v_b2, 0);
        @memset(mlp.m_w3, 0);
        @memset(mlp.v_w3, 0);
        @memset(mlp.m_b3, 0);
        @memset(mlp.v_b3, 0);

        // Zero gradient accumulators
        @memset(mlp.gw1, 0);
        @memset(mlp.gb1, 0);
        @memset(mlp.gw2, 0);
        @memset(mlp.gb2, 0);
        @memset(mlp.gw3, 0);
        @memset(mlp.gb3, 0);

        // Xavier/Glorot initialization
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

    /// Build 5-element input vector: normalized (x,y,z) + (sin_yaw, cos_yaw)
    fn buildInput(self: *const MLP, pos: Vec3, dir: [2]f32) [INPUT_SIZE]f32 {
        return .{
            (pos[0] - self.pos_min[0]) * self.pos_scale[0],
            (pos[1] - self.pos_min[1]) * self.pos_scale[1],
            (pos[2] - self.pos_min[2]) * self.pos_scale[2],
            dir[0], // sin_yaw (already [-1,1])
            dir[1], // cos_yaw (already [-1,1])
        };
    }

    /// Forward pass: (position, direction) → model visibility probabilities
    pub fn forward(self: *MLP, pos: Vec3, dir: [2]f32) []const f32 {
        const input = self.buildInput(pos, dir);
        const h = self.hidden_size;
        const o = self.output_size;

        // Layer 1: input(5) → hidden (LeakyReLU)
        for (0..h) |j| {
            var sum: f32 = self.b1[j];
            inline for (0..INPUT_SIZE) |k| {
                sum += input[k] * self.w1[k * h + j];
            }
            self.z1[j] = sum;
            self.a1[j] = leakyRelu(sum);
        }

        // Layer 2: hidden → hidden (LeakyReLU)
        for (0..h) |j| {
            var sum: f32 = self.b2[j];
            for (0..h) |k| {
                sum += self.a1[k] * self.w2[k * h + j];
            }
            self.z2[j] = sum;
            self.a2[j] = leakyRelu(sum);
        }

        // Layer 3: hidden → output (sigmoid)
        for (0..o) |j| {
            var sum: f32 = self.b3[j];
            for (0..h) |k| {
                sum += self.a2[k] * self.w3[k * o + j];
            }
            self.out[j] = sigmoid(sum);
        }

        return self.out;
    }

    /// Accumulate gradients for one sample (call forward() first).
    /// Does NOT update weights — call applyAdam() after a mini-batch.
    pub fn accumulateGradients(self: *MLP, pos: Vec3, dir: [2]f32, target: []const u8, pos_weight: f32) f32 {
        const input = self.buildInput(pos, dir);
        const h = self.hidden_size;
        const o = self.output_size;

        // Compute deltas

        var loss: f32 = 0;
        for (0..o) |j| {
            const t: f32 = if (bitsetGet(target, j)) 1.0 else 0.0;
            const p = self.out[j];
            const w = if (t > 0.5) pos_weight else 1.0;
            self.d3[j] = w * (p - t);
            const cp = std.math.clamp(p, 1e-7, 1.0 - 1e-7);
            loss -= w * (t * @log(cp) + (1.0 - t) * @log(1.0 - cp));
        }

        for (0..h) |k| {
            var sum: f32 = 0;
            for (0..o) |j| {
                sum += self.w3[k * o + j] * self.d3[j];
            }
            self.d2[k] = sum * leakyReluDeriv(self.z2[k]);
        }

        for (0..h) |k| {
            var sum: f32 = 0;
            for (0..h) |j| {
                sum += self.w2[k * h + j] * self.d2[j];
            }
            self.d1[k] = sum * leakyReluDeriv(self.z1[k]);
        }

        // Accumulate gradients (add, not replace)

        // Layer 3
        for (0..h) |k| {
            for (0..o) |j| {
                self.gw3[k * o + j] += self.a2[k] * self.d3[j];
            }
        }
        for (0..o) |j| {
            self.gb3[j] += self.d3[j];
        }

        // Layer 2
        for (0..h) |k| {
            for (0..h) |j| {
                self.gw2[k * h + j] += self.a1[k] * self.d2[j];
            }
        }
        for (0..h) |j| {
            self.gb2[j] += self.d2[j];
        }

        // Layer 1
        inline for (0..INPUT_SIZE) |k| {
            for (0..h) |j| {
                self.gw1[k * h + j] += input[k] * self.d1[j];
            }
        }
        for (0..h) |j| {
            self.gb1[j] += self.d1[j];
        }

        return loss;
    }

    /// Apply accumulated gradients via Adam, then zero gradient buffers.
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
            gi.* = 0; // zero for next batch
        }
    }

    /// Save weights to binary file (NPVS v2 format).
    pub fn save(self: *const MLP, path: []const u8) !void {
        var file = try std.fs.cwd().createFile(path, .{});
        defer file.close();
        var bw = std.io.bufferedWriter(file.writer());
        const w = bw.writer();

        try w.writeAll("NPVS");
        try w.writeInt(u32, 2, .little); // version 2: direction-aware
        try w.writeInt(u32, INPUT_SIZE, .little);
        try w.writeInt(u32, self.hidden_size, .little);
        try w.writeInt(u32, self.output_size, .little);
        for (self.pos_min) |v| try w.writeInt(u32, @bitCast(v), .little);
        for (0..3) |i| {
            const max_v = self.pos_min[i] + 1.0 / self.pos_scale[i];
            try w.writeInt(u32, @bitCast(max_v), .little);
        }

        for (self.w1) |v| try w.writeInt(u32, @bitCast(v), .little);
        for (self.b1) |v| try w.writeInt(u32, @bitCast(v), .little);
        for (self.w2) |v| try w.writeInt(u32, @bitCast(v), .little);
        for (self.b2) |v| try w.writeInt(u32, @bitCast(v), .little);
        for (self.w3) |v| try w.writeInt(u32, @bitCast(v), .little);
        for (self.b3) |v| try w.writeInt(u32, @bitCast(v), .little);

        try bw.flush();
    }

    /// Load weights from binary file.
    pub fn load(allocator: Allocator, path: []const u8) !MLP {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();
        var br = std.io.bufferedReader(file.reader());
        const reader = br.reader();

        var magic: [4]u8 = undefined;
        _ = try reader.readAll(&magic);
        if (!std.mem.eql(u8, &magic, "NPVS")) return error.InvalidMagic;

        const version = try reader.readInt(u32, .little);
        if (version != 2) return error.UnsupportedVersion;

        const input_size = try reader.readInt(u32, .little);
        if (input_size != INPUT_SIZE) return error.InputSizeMismatch;

        const hidden = try reader.readInt(u32, .little);
        const output = try reader.readInt(u32, .little);

        var pos_min: Vec3 = undefined;
        var pos_max: Vec3 = undefined;
        for (&pos_min) |*v| v.* = @bitCast(try reader.readInt(u32, .little));
        for (&pos_max) |*v| v.* = @bitCast(try reader.readInt(u32, .little));

        var mlp = try MLP.init(allocator, output, hidden, pos_min, pos_max);
        errdefer mlp.deinit();

        for (mlp.w1) |*v| v.* = @bitCast(try reader.readInt(u32, .little));
        for (mlp.b1) |*v| v.* = @bitCast(try reader.readInt(u32, .little));
        for (mlp.w2) |*v| v.* = @bitCast(try reader.readInt(u32, .little));
        for (mlp.b2) |*v| v.* = @bitCast(try reader.readInt(u32, .little));
        for (mlp.w3) |*v| v.* = @bitCast(try reader.readInt(u32, .little));
        for (mlp.b3) |*v| v.* = @bitCast(try reader.readInt(u32, .little));

        return mlp;
    }

    /// Evaluate at runtime: returns model visibility flags.
    pub fn evaluate(self: *MLP, pos: Vec3, dir: [2]f32, flags: []bool, threshold: f32) void {
        _ = self.forward(pos, dir);
        for (flags, 0..) |*f, i| {
            f.* = if (i < self.out.len) self.out[i] > threshold else true;
        }
    }
};

// ── Training ────────────────────────────────────────────────────────

pub const TrainConfig = struct {
    epochs: u32 = 100,
    learning_rate: f32 = 0.001, // Adam LR — can be higher with mini-batch
    batch_size: u32 = 32,
    hidden_size: u32 = 256,
    eval_threshold: f32 = 0.3,
};

/// Train MLP on direction-aware training data.
pub fn train(
    allocator: Allocator,
    data: *const TrainingData,
    pos_min: Vec3,
    pos_max: Vec3,
    config: TrainConfig,
    stdout: anytype,
) !MLP {
    var mlp = try MLP.init(allocator, data.num_models, config.hidden_size, pos_min, pos_max);
    errdefer mlp.deinit();

    const n = data.num_samples;
    if (n == 0) return mlp;

    // Compute class-balanced positive weight
    var total_pos: u64 = 0;
    const total_samples_models: u64 = @as(u64, n) * data.num_models;
    for (data.labels[0..n]) |label| {
        total_pos += bitsetCount(label);
    }
    const total_neg = total_samples_models - total_pos;
    const pos_weight: f32 = if (total_pos > 0)
        @as(f32, @floatFromInt(total_neg)) / @as(f32, @floatFromInt(total_pos))
    else
        1.0;
    const capped_weight = @min(pos_weight, 5.0);

    // Shuffle indices
    const indices = try allocator.alloc(u32, n);
    defer allocator.free(indices);
    for (0..n) |i| indices[i] = @intCast(i);

    const num_params = INPUT_SIZE * config.hidden_size + config.hidden_size +
        config.hidden_size * config.hidden_size + config.hidden_size +
        config.hidden_size * data.num_models + data.num_models;

    try stdout.print("  Training MLP (Adam + LeakyReLU + mini-batch + direction-aware)\n", .{});
    try stdout.print("  Input: {d} (x,y,z,sin_yaw,cos_yaw), H={d}, Output: {d}\n", .{
        INPUT_SIZE, config.hidden_size, data.num_models,
    });
    try stdout.print("  Samples: {d}, Epochs: {d}, lr={d:.4}, batch={d}, params={d}\n", .{
        n, config.epochs, config.learning_rate, config.batch_size, num_params,
    });
    try stdout.print("  pos_weight={d:.1} (auto from {d}/{d} pos/neg)\n", .{
        capped_weight, total_pos, total_neg,
    });

    const bs = config.batch_size;
    const bs_f: f32 = @floatFromInt(bs);

    for (0..config.epochs) |epoch| {
        shuffle(indices, std.crypto.random);

        var epoch_loss: f64 = 0;
        var batch_count: u32 = 0;

        for (indices, 0..) |idx, si| {
            _ = mlp.forward(data.positions[idx], data.directions[idx]);
            const loss = mlp.accumulateGradients(
                data.positions[idx],
                data.directions[idx],
                data.labels[idx],
                capped_weight,
            );
            epoch_loss += loss;
            batch_count += 1;

            // Apply Adam update at end of each mini-batch
            if (batch_count >= bs or si == indices.len - 1) {
                mlp.applyAdam(config.learning_rate, @floatFromInt(batch_count));
                batch_count = 0;
            }
        }
        _ = bs_f;

        if (epoch % 10 == 0 or epoch == config.epochs - 1) {
            var eval_fn: u64 = 0;
            var eval_fp: u64 = 0;
            var eval_pos: u64 = 0;
            var eval_neg: u64 = 0;

            for (0..n) |i| {
                _ = mlp.forward(data.positions[i], data.directions[i]);
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

            try stdout.print("  Epoch {d:>4}: loss={d:.2}, FN={d:.2}%, FP={d:.1}%\n", .{
                epoch,
                epoch_loss / @as(f64, @floatFromInt(n)),
                fn_rate * 100,
                fp_rate * 100,
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
