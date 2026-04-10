// Exemplar-based PVS — surprise-gated sparse visibility storage.
//
// Instead of an MLP, stores a sparse set of exemplar camera states
// with their ground-truth visibility bitsets. At query time, finds
// nearby exemplars via RBF-weighted interpolation.
//
// Inspired by NeuralFields (Beaumont 2026): only stores where
// predictions fail (surprise), so exemplars cluster at visibility
// transition boundaries where they're needed most.
//
// Input (9): x, y, z, qw, qx, qy, qz, vfov_norm, aspect_norm
// Output: per-model visibility probability via RBF interpolation
//
// File format (EPVS v3): position-only inputs.
//   magic: "EPVS"
//   version: u32 = 3
//   input_size: u32 = 3
//   num_models: u32
//   num_exemplars: u32
//   pos_min: [3]f32
//   pos_max: [3]f32
//   rbf_sigma: f32
//   pos_weight: f32
//   For each exemplar:
//     input: [3]f32 (normalized x,y,z)
//     visibility: [ceil(num_models/8)]u8 (packed bitset)

const std = @import("std");
const Allocator = std.mem.Allocator;

const INPUT_SIZE: u32 = 3;

// Position-weight scaling — keeps the RBF kernel sized appropriately
// in normalized [0,1] coordinates. Inherited from the previous design
// where it had to fight against quaternion dimensions; with position-only
// inputs the value is just an RBF bandwidth tuning knob.
pub const POS_WEIGHT: f32 = 50.0;

const Exemplar = struct {
    input: [INPUT_SIZE]f32,
    visibility: []const u8, // packed bitset
};

pub const ExemplarPVS = struct {
    exemplars: []Exemplar,
    num_models: u32,
    bitset_stride: u32,
    rbf_sigma: f32,
    rbf_neg2sigma2: f32, // precomputed: -1 / (2 * sigma^2)
    pos_weight: f32 = POS_WEIGHT,

    // Normalization (same as MLP)
    pos_min: [3]f32,
    pos_scale: [3]f32,

    // Scratch buffers for inference
    out: []f32, // per-model probability output

    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *ExemplarPVS) void {
        self.arena.deinit();
    }

    /// Build normalized position-only input vector.
    fn buildInput(self: *const ExemplarPVS, pos: [3]f32) [INPUT_SIZE]f32 {
        return .{
            (pos[0] - self.pos_min[0]) * self.pos_scale[0],
            (pos[1] - self.pos_min[1]) * self.pos_scale[1],
            (pos[2] - self.pos_min[2]) * self.pos_scale[2],
        };
    }

    /// Query visibility via RBF-weighted interpolation of exemplars.
    pub fn query(self: *ExemplarPVS, pos: [3]f32) []const f32 {
        const input = self.buildInput(pos);

        @memset(self.out, 0);
        var weight_sum: f32 = 0;

        for (self.exemplars) |ex| {
            var dist_sq: f32 = 0;
            inline for (0..INPUT_SIZE) |k| {
                const d = (input[k] - ex.input[k]) * POS_WEIGHT;
                dist_sq += d * d;
            }
            const w = @exp(dist_sq * self.rbf_neg2sigma2);
            if (w < 0.001) continue;

            weight_sum += w;

            for (0..self.num_models) |j| {
                const byte_idx = j / 8;
                const bit_idx: u3 = @intCast(j % 8);
                const visible: f32 = if (ex.visibility[byte_idx] & (@as(u8, 1) << bit_idx) != 0) 1.0 else 0.0;
                self.out[j] += w * visible;
            }
        }

        if (weight_sum > 0.001) {
            const inv_w = 1.0 / weight_sum;
            for (self.out) |*v| v.* *= inv_w;
        } else {
            @memset(self.out, 1.0);
        }

        return self.out;
    }

    /// Save to EPVS format.
    pub fn save(self: *const ExemplarPVS, path: []const u8) !void {
        var file = try std.fs.cwd().createFile(path, .{});
        defer file.close();
        var bw = std.io.bufferedWriter(file.writer());
        const w = bw.writer();

        try w.writeAll("EPVS");
        try w.writeInt(u32, 3, .little); // version 3: position-only input
        try w.writeInt(u32, INPUT_SIZE, .little);
        try w.writeInt(u32, self.num_models, .little);
        try w.writeInt(u32, @intCast(self.exemplars.len), .little);

        for (self.pos_min) |val| try w.writeInt(u32, @bitCast(val), .little);
        for (0..3) |i| {
            const max_v = self.pos_min[i] + 1.0 / self.pos_scale[i];
            try w.writeInt(u32, @bitCast(max_v), .little);
        }
        try w.writeInt(u32, @bitCast(self.rbf_sigma), .little);
        try w.writeInt(u32, @bitCast(self.pos_weight), .little);

        // Write exemplars
        for (self.exemplars) |ex| {
            for (ex.input) |val| try w.writeInt(u32, @bitCast(val), .little);
            try w.writeAll(ex.visibility);
        }

        try bw.flush();
    }
};

// ── Bitset helpers ─────────────────────────────────────────────────

fn bitsetGet(bitset: []const u8, idx: u32) bool {
    return bitset[idx / 8] & (@as(u8, 1) << @intCast(idx % 8)) != 0;
}

fn bitsetCount(bitset: []const u8) u32 {
    var count: u32 = 0;
    for (bitset) |byte| count += @popCount(byte);
    return count;
}

/// Hamming distance between two bitsets.
fn bitsetHamming(a: []const u8, b: []const u8) u32 {
    var dist: u32 = 0;
    for (a, b) |ab, bb| dist += @popCount(ab ^ bb);
    return dist;
}

// ── Exemplar Selection (Surprise-Gated) ────────────────────────────

pub const SelectionConfig = struct {
    max_exemplars: u32 = 2000,
    rbf_sigma: f32 = 0.15, // RBF bandwidth in normalized input space
    surprise_threshold: f32 = 0.3, // min prediction error to store exemplar
    seed_count: u32 = 200, // initial random seed exemplars
};

/// Select exemplars via greedy surprise hunting.
///
/// Algorithm (TinyTape-style active learning):
///   1. Seed with K random exemplars for initial coverage
///   2. Compute prediction error for ALL training samples
///   3. Loop:
///      a. Find the sample with the highest error (most surprising)
///      b. If max error < threshold, stop (manifold fully covered)
///      c. Add it as an exemplar
///      d. Update predictions only for samples near the new exemplar
///   4. This naturally hunts the visibility manifold for surprises —
///      open spaces with uniform visibility get covered quickly,
///      while boundaries and occluder edges accumulate exemplars.
pub fn selectExemplars(
    allocator: Allocator,
    data: anytype, // TrainingData
    pos_min: [3]f32,
    pos_max: [3]f32,
    config: SelectionConfig,
    stdout: anytype,
) !ExemplarPVS {
    const num_models = data.num_models;
    const bitset_stride = (num_models + 7) / 8;
    const num_samples = data.num_samples;

    const pos_scale = [3]f32{
        1.0 / @max(pos_max[0] - pos_min[0], 0.001),
        1.0 / @max(pos_max[1] - pos_min[1], 0.001),
        1.0 / @max(pos_max[2] - pos_min[2], 0.001),
    };

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    var exemplars = std.ArrayList(Exemplar).init(a);

    const neg2sigma2 = -1.0 / (2.0 * config.rbf_sigma * config.rbf_sigma);

    // Outside this radius, the RBF weight is < 1e-5 — no need to update predictions
    const update_radius_sq = 4.0 * config.rbf_sigma * 4.0 * config.rbf_sigma;

    // Build normalized position-only inputs for all samples
    const inputs = try a.alloc([INPUT_SIZE]f32, num_samples);
    for (0..num_samples) |i| {
        const pos = data.positions[i];
        inputs[i] = .{
            (pos[0] - pos_min[0]) * pos_scale[0],
            (pos[1] - pos_min[1]) * pos_scale[1],
            (pos[2] - pos_min[2]) * pos_scale[2],
        };
    }

    // Per-sample state for greedy selection
    const sample_error = try a.alloc(f32, num_samples);
    const sample_weight_sum = try a.alloc(f32, num_samples);
    // Per-sample accumulated weighted visibility (output * weight_sum)
    const sample_acc = try a.alloc(f32, num_samples * num_models);
    @memset(sample_error, 0);
    @memset(sample_weight_sum, 0);
    @memset(sample_acc, 0);
    const selected = try a.alloc(bool, num_samples);
    @memset(selected, false);

    // Helper: incorporate one exemplar's contribution into a sample's accumulator
    const ContribCtx = struct {
        fn apply(
            sample_input: *const [INPUT_SIZE]f32,
            sample_label: []const u8,
            ex_input: *const [INPUT_SIZE]f32,
            ex_visibility: []const u8,
            n_models: u32,
            stride: u32,
            neg2s2: f32,
            update_r2: f32,
            acc: []f32,
            ws: *f32,
            err_out: *f32,
        ) void {
            var dist_sq: f32 = 0;
            inline for (0..INPUT_SIZE) |k| {
                const d = (sample_input[k] - ex_input[k]) * POS_WEIGHT;
                dist_sq += d * d;
            }
            if (dist_sq > update_r2) return;

            const w = @exp(dist_sq * neg2s2);
            if (w < 0.0001) return;

            ws.* += w;

            for (0..n_models) |j| {
                const byte_idx = j / 8;
                const bit_idx: u3 = @intCast(j % 8);
                const visible: f32 = if (ex_visibility[byte_idx] & (@as(u8, 1) << bit_idx) != 0) 1.0 else 0.0;
                acc[j] += w * visible;
            }

            // Recompute error for this sample
            const inv_w = 1.0 / ws.*;
            var error_sum: f32 = 0;
            for (0..n_models) |j| {
                const gt: f32 = if (sample_label[j / 8] & (@as(u8, 1) << @intCast(j % 8)) != 0) 1.0 else 0.0;
                const pred = acc[j] * inv_w;
                error_sum += @abs(pred - gt);
            }
            err_out.* = error_sum / @as(f32, @floatFromInt(n_models));
            _ = stride;
        }
    };

    // Phase 1: Seed with random exemplars for initial coverage
    var rng = std.Random.DefaultPrng.init(42);
    const random = rng.random();
    const seed_count = @min(config.seed_count, num_samples);

    const indices = try a.alloc(u32, num_samples);
    for (indices, 0..) |*idx, i| idx.* = @intCast(i);
    for (0..seed_count) |i| {
        const j = i + random.uintLessThan(usize, num_samples - i);
        const tmp = indices[i];
        indices[i] = indices[j];
        indices[j] = tmp;
    }

    for (0..seed_count) |i| {
        const idx = indices[i];
        const vis_copy = try a.alloc(u8, bitset_stride);
        @memcpy(vis_copy, data.labels[idx]);
        try exemplars.append(.{
            .input = inputs[idx],
            .visibility = vis_copy,
        });
        selected[idx] = true;
    }

    try stdout.print("[Exemplar] Seeded {d} exemplars, computing initial errors...\n", .{seed_count});

    // Compute initial error for all samples (full O(N*K) sweep, only done once)
    for (0..num_samples) |si| {
        if (selected[si]) continue;
        const acc_slice = sample_acc[si * num_models .. (si + 1) * num_models];
        for (exemplars.items) |ex| {
            ContribCtx.apply(
                &inputs[si],
                data.labels[si],
                &ex.input,
                ex.visibility,
                num_models,
                bitset_stride,
                neg2sigma2,
                update_radius_sq,
                acc_slice,
                &sample_weight_sum[si],
                &sample_error[si],
            );
        }
        // If no exemplar was within range, error = 1.0 (max surprise)
        if (sample_weight_sum[si] < 0.0001) sample_error[si] = 1.0;
    }

    // Phase 2: Greedy max-error selection
    var iter: u32 = 0;
    var last_max_err: f32 = 0;
    while (exemplars.items.len < config.max_exemplars) : (iter += 1) {
        // Find sample with max error
        var max_err: f32 = 0;
        var max_idx: u32 = 0;
        for (0..num_samples) |si| {
            if (selected[si]) continue;
            if (sample_error[si] > max_err) {
                max_err = sample_error[si];
                max_idx = @intCast(si);
            }
        }
        last_max_err = max_err;

        // Stop if no surprises left
        if (max_err < config.surprise_threshold) break;

        // Add as exemplar
        const vis_copy = try a.alloc(u8, bitset_stride);
        @memcpy(vis_copy, data.labels[max_idx]);
        try exemplars.append(.{
            .input = inputs[max_idx],
            .visibility = vis_copy,
        });
        selected[max_idx] = true;
        const new_ex = exemplars.items[exemplars.items.len - 1];

        // Update predictions only for samples near the new exemplar
        var updated: u32 = 0;
        for (0..num_samples) |si| {
            if (selected[si]) continue;
            // Quick distance check before doing full work
            var dist_sq: f32 = 0;
            inline for (0..INPUT_SIZE) |k| {
                const d = (inputs[si][k] - new_ex.input[k]) * POS_WEIGHT;
                dist_sq += d * d;
            }
            if (dist_sq > update_radius_sq) continue;

            const acc_slice = sample_acc[si * num_models .. (si + 1) * num_models];
            ContribCtx.apply(
                &inputs[si],
                data.labels[si],
                &new_ex.input,
                new_ex.visibility,
                num_models,
                bitset_stride,
                neg2sigma2,
                update_radius_sq,
                acc_slice,
                &sample_weight_sum[si],
                &sample_error[si],
            );
            updated += 1;
        }

        // Progress every 100 exemplars
        if ((exemplars.items.len % 100) == 0) {
            try stdout.print("  [{d}] max_error={d:.4}, last update touched {d} samples\n", .{
                exemplars.items.len, max_err, updated,
            });
        }
    }

    try stdout.print("[Exemplar] Greedy selection done: {d} exemplars, final max_error={d:.4}\n", .{
        exemplars.items.len, last_max_err,
    });
    try stdout.print("[Exemplar] {d} bytes per exemplar\n", .{INPUT_SIZE * 4 + bitset_stride});

    const file_size = 4 + 4 + 4 + 4 + 4 + 24 + 4 + exemplars.items.len * (INPUT_SIZE * 4 + bitset_stride);
    try stdout.print("[Exemplar] Estimated file size: {d} KB\n", .{file_size / 1024});

    return ExemplarPVS{
        .exemplars = try exemplars.toOwnedSlice(),
        .num_models = num_models,
        .bitset_stride = bitset_stride,
        .rbf_sigma = config.rbf_sigma,
        .rbf_neg2sigma2 = neg2sigma2,
        .pos_min = pos_min,
        .pos_scale = pos_scale,
        .out = try a.alloc(f32, num_models),
        .arena = arena,
    };
}

/// Evaluate exemplar model on training data at multiple thresholds.
/// Reports the FN/FP curve so we can pick the best operating point.
pub fn evaluate(
    epvs: *ExemplarPVS,
    data: anytype,
    primary_threshold: f32,
    stdout: anytype,
) !void {
    const thresholds = [_]f32{ 0.05, 0.10, 0.15, 0.20, 0.25, 0.30, 0.40, 0.50 };
    var fn_counts = [_]u64{0} ** thresholds.len;
    var fp_counts = [_]u64{0} ** thresholds.len;
    var total_pos: u64 = 0;
    var total_neg: u64 = 0;

    // Also track raw probability stats to understand the distribution
    var sum_pos_pred: f64 = 0; // sum of predictions for actually-visible models
    var sum_neg_pred: f64 = 0; // sum of predictions for actually-invisible models

    const eval_count = @min(data.num_samples, 10000);

    for (0..eval_count) |si| {
        const pos = data.positions[si];
        _ = epvs.query(pos);

        for (0..epvs.num_models) |j| {
            const gt = bitsetGet(data.labels[si], @intCast(j));
            const pred = epvs.out[j];
            if (gt) {
                total_pos += 1;
                sum_pos_pred += pred;
                inline for (thresholds, 0..) |t, ti| {
                    if (pred <= t) fn_counts[ti] += 1;
                }
            } else {
                total_neg += 1;
                sum_neg_pred += pred;
                inline for (thresholds, 0..) |t, ti| {
                    if (pred > t) fp_counts[ti] += 1;
                }
            }
        }
    }

    try stdout.print("[Exemplar] Eval ({d} samples, {d} pos, {d} neg)\n", .{
        eval_count, total_pos, total_neg,
    });
    try stdout.print("  Avg pred for visible:   {d:.3}  (closer to 1.0 = better)\n", .{
        sum_pos_pred / @as(f64, @floatFromInt(@max(total_pos, 1))),
    });
    try stdout.print("  Avg pred for invisible: {d:.3}  (closer to 0.0 = better)\n", .{
        sum_neg_pred / @as(f64, @floatFromInt(@max(total_neg, 1))),
    });
    try stdout.print("  Threshold sweep:\n", .{});
    try stdout.print("    thresh   FN%      FP%\n", .{});
    inline for (thresholds, 0..) |t, ti| {
        const fn_rate = @as(f32, @floatFromInt(fn_counts[ti])) / @as(f32, @floatFromInt(@max(total_pos, 1))) * 100.0;
        const fp_rate = @as(f32, @floatFromInt(fp_counts[ti])) / @as(f32, @floatFromInt(@max(total_neg, 1))) * 100.0;
        const marker = if (@abs(t - primary_threshold) < 0.001) " ←" else "";
        try stdout.print("    {d:.2}     {d:6.2}   {d:6.2}{s}\n", .{ t, fn_rate, fp_rate, marker });
    }
}
