// PVS Visualization — PPM image output for transport graph, islands, probes, lighting.
// Extracted from pvs_baker.zig for clarity.

const std = @import("std");
const Allocator = std.mem.Allocator;
const pvs_mod = @import("pvs");
const bivh_mod = @import("bivh");

const Vec3 = [3]f32;

pub const IMG_SIZE: u32 = 2048;

pub const Color = struct { r: u8, g: u8, b: u8 };

/// Map world XZ coordinates to pixel coordinates (top-down Y-up view).
pub fn worldToPixel(pos: Vec3, world_min: [3]f32, world_max: [3]f32, size: u32) struct { x: i32, y: i32 } {
    const margin: f32 = 0.02;
    const dx = world_max[0] - world_min[0];
    const dz = world_max[2] - world_min[2];
    const span = @max(dx, dz);
    const pad = span * margin;

    const fx = (pos[0] - world_min[0] + pad) / (span + 2 * pad);
    const fz = (pos[2] - world_min[2] + pad) / (span + 2 * pad);

    return .{
        .x = @intFromFloat(fx * @as(f32, @floatFromInt(size - 1))),
        .y = @intFromFloat((1.0 - fz) * @as(f32, @floatFromInt(size - 1))),
    };
}

pub fn lerpColor(a: Color, b: Color, t: f32) Color {
    const ct = std.math.clamp(t, 0, 1);
    return .{
        .r = @intFromFloat(@as(f32, @floatFromInt(a.r)) * (1 - ct) + @as(f32, @floatFromInt(b.r)) * ct),
        .g = @intFromFloat(@as(f32, @floatFromInt(a.g)) * (1 - ct) + @as(f32, @floatFromInt(b.g)) * ct),
        .b = @intFromFloat(@as(f32, @floatFromInt(a.b)) * (1 - ct) + @as(f32, @floatFromInt(b.b)) * ct),
    };
}

pub fn heatColor(t: f32) Color {
    const ct = std.math.clamp(t, 0, 1);
    if (ct < 0.25) {
        return lerpColor(.{ .r = 0, .g = 0, .b = 128 }, .{ .r = 0, .g = 200, .b = 200 }, ct * 4.0);
    } else if (ct < 0.5) {
        return lerpColor(.{ .r = 0, .g = 200, .b = 200 }, .{ .r = 0, .g = 255, .b = 0 }, (ct - 0.25) * 4.0);
    } else if (ct < 0.75) {
        return lerpColor(.{ .r = 0, .g = 255, .b = 0 }, .{ .r = 255, .g = 255, .b = 0 }, (ct - 0.5) * 4.0);
    } else {
        return lerpColor(.{ .r = 255, .g = 255, .b = 0 }, .{ .r = 255, .g = 0, .b = 0 }, (ct - 0.75) * 4.0);
    }
}

pub fn drawLine(pixels: []Color, size: u32, x0: i32, y0: i32, x1: i32, y1: i32, color: Color, alpha: f32) void {
    var x = x0;
    var y = y0;
    const dx_abs: i32 = if (x1 > x0) x1 - x0 else x0 - x1;
    const dy_abs: i32 = if (y1 > y0) y1 - y0 else y0 - y1;
    const sx: i32 = if (x0 < x1) 1 else -1;
    const sy: i32 = if (y0 < y1) 1 else -1;
    var err = dx_abs - dy_abs;

    const img_sz: i32 = @intCast(size);
    const steps = dx_abs + dy_abs + 1;

    for (0..@intCast(steps)) |_| {
        if (x >= 0 and x < img_sz and y >= 0 and y < img_sz) {
            const idx: usize = @intCast(y * img_sz + x);
            const old = pixels[idx];
            pixels[idx] = .{
                .r = @intCast(@min(255, @as(u16, old.r) + @as(u16, @intFromFloat(@as(f32, @floatFromInt(color.r)) * alpha)))),
                .g = @intCast(@min(255, @as(u16, old.g) + @as(u16, @intFromFloat(@as(f32, @floatFromInt(color.g)) * alpha)))),
                .b = @intCast(@min(255, @as(u16, old.b) + @as(u16, @intFromFloat(@as(f32, @floatFromInt(color.b)) * alpha)))),
            };
        }
        if (x == x1 and y == y1) break;
        const e2 = err * 2;
        if (e2 > -dy_abs) { err -= dy_abs; x += sx; }
        if (e2 < dx_abs) { err += dx_abs; y += sy; }
    }
}

pub fn fillRect(pixels: []Color, size: u32, x0: i32, y0: i32, x1: i32, y1: i32, color: Color) void {
    const img_sz: i32 = @intCast(size);
    const ax = std.math.clamp(x0, 0, img_sz - 1);
    const ay = std.math.clamp(y0, 0, img_sz - 1);
    const bx = std.math.clamp(x1, 0, img_sz - 1);
    const by = std.math.clamp(y1, 0, img_sz - 1);

    var row = ay;
    while (row <= by) : (row += 1) {
        var col = ax;
        while (col <= bx) : (col += 1) {
            pixels[@intCast(row * img_sz + col)] = color;
        }
    }
}

pub fn drawLineAccum(accum: []f32, size: u32, x0: i32, y0: i32, x1: i32, y1: i32, color: Color, weight: f32) void {
    var x = x0;
    var y = y0;
    const dx_abs: i32 = if (x1 > x0) x1 - x0 else x0 - x1;
    const dy_abs: i32 = if (y1 > y0) y1 - y0 else y0 - y1;
    const sx: i32 = if (x0 < x1) 1 else -1;
    const sy: i32 = if (y0 < y1) 1 else -1;
    var err = dx_abs - dy_abs;

    const img_sz: i32 = @intCast(size);
    const steps = dx_abs + dy_abs + 1;
    const cr = @as(f32, @floatFromInt(color.r)) * weight;
    const cg = @as(f32, @floatFromInt(color.g)) * weight;
    const cb = @as(f32, @floatFromInt(color.b)) * weight;

    for (0..@intCast(steps)) |_| {
        if (x >= 0 and x < img_sz and y >= 0 and y < img_sz) {
            const base: usize = @intCast(y * img_sz + x);
            accum[base * 3] += cr;
            accum[base * 3 + 1] += cg;
            accum[base * 3 + 2] += cb;
        }
        if (x == x1 and y == y1) break;
        const e2 = err * 2;
        if (e2 > -dy_abs) { err -= dy_abs; x += sx; }
        if (e2 < dx_abs) { err += dx_abs; y += sy; }
    }
}

pub fn toneMap(val: f32, max_val: f32) u8 {
    const normalized = val / max_val * 4.0;
    const mapped = normalized / (1.0 + normalized);
    return @intFromFloat(std.math.clamp(mapped * 255.0, 0, 255));
}

pub fn writePpm(pixels: []const Color, size: u32, path: []const u8) !void {
    var file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    var bw = std.io.bufferedWriter(file.writer());
    const w = bw.writer();
    try w.print("P6\n{d} {d}\n255\n", .{ size, size });
    for (pixels) |px| {
        try w.writeAll(&[_]u8{ px.r, px.g, px.b });
    }
    try bw.flush();
}

pub fn hsvToRgb(h: f32, s: f32, v: f32) Color {
    const c = v * s;
    const hp = h * 6.0;
    const x = c * (1.0 - @abs(@mod(hp, 2.0) - 1.0));
    const m = v - c;

    var r: f32 = 0;
    var g: f32 = 0;
    var b: f32 = 0;

    if (hp < 1) { r = c; g = x; } else if (hp < 2) { r = x; g = c; } else if (hp < 3) { g = c; b = x; } else if (hp < 4) { g = x; b = c; } else if (hp < 5) { r = x; b = c; } else { r = c; b = x; }

    return .{
        .r = @intFromFloat((r + m) * 255),
        .g = @intFromFloat((g + m) * 255),
        .b = @intFromFloat((b + m) * 255),
    };
}

pub fn writeTransportHeatmap(
    allocator: Allocator,
    transport: *const pvs_mod.TransportGraph,
    centroids: []const Vec3,
    num_cells: u32,
    world_min: [3]f32,
    world_max: [3]f32,
    path: []const u8,
) !void {
    const size = IMG_SIZE;
    const pixels = try allocator.alloc(Color, size * size);
    defer allocator.free(pixels);
    @memset(pixels, Color{ .r = 15, .g = 15, .b = 20 });

    const accum = try allocator.alloc(f32, size * size * 3);
    defer allocator.free(accum);
    @memset(accum, 0);

    for (0..num_cells) |i| {
        for (i + 1..num_cells) |j| {
            const edge = transport.getEdge(@intCast(i), @intCast(j));
            const casts = edge.casts.load(.monotonic);
            if (casts == 0) continue;
            const hits = edge.hits.load(.monotonic);
            if (hits == 0) continue;

            const prob = @as(f32, @floatFromInt(hits)) / @as(f32, @floatFromInt(casts));
            const color = heatColor(prob);
            const confidence = @min(1.0, std.math.log2(@as(f32, @floatFromInt(@min(casts, 10000))) + 1.0) / 13.0);
            const weight = prob * confidence;

            const p0 = worldToPixel(centroids[i], world_min, world_max, size);
            const p1 = worldToPixel(centroids[j], world_min, world_max, size);
            drawLineAccum(accum, size, p0.x, p0.y, p1.x, p1.y, color, weight);
        }
    }

    var max_val: f32 = 0.001;
    for (accum) |v| max_val = @max(max_val, v);

    for (0..size * size) |px| {
        const base = px * 3;
        pixels[px] = .{
            .r = toneMap(accum[base], max_val),
            .g = toneMap(accum[base + 1], max_val),
            .b = toneMap(accum[base + 2], max_val),
        };
    }

    for (centroids[0..num_cells]) |c| {
        const p = worldToPixel(c, world_min, world_max, size);
        fillRect(pixels, size, p.x - 1, p.y - 1, p.x + 1, p.y + 1, .{ .r = 255, .g = 255, .b = 255 });
    }

    try writePpm(pixels, size, path);
}

pub fn writeIslandMap(
    allocator: Allocator,
    islands: *const pvs_mod.IslandResult,
    probes: []const pvs_mod.Probe,
    cluster_bivh: *const bivh_mod.Bivh,
    cell_node_indices: []const u32,
    cell_centroids: []const Vec3,
    num_cells: u32,
    world_min: [3]f32,
    world_max: [3]f32,
    path: []const u8,
) !void {
    const size = IMG_SIZE;
    const pixels = try allocator.alloc(Color, size * size);
    defer allocator.free(pixels);
    @memset(pixels, Color{ .r = 15, .g = 15, .b = 20 });

    const island_colors = try allocator.alloc(Color, islands.num_islands);
    defer allocator.free(island_colors);
    for (0..islands.num_islands) |i| {
        const hue = @as(f32, @floatFromInt(i)) * 0.618033988749895;
        island_colors[i] = hsvToRgb(hue - @floor(hue), 0.7, 0.8);
    }

    for (cell_node_indices[0..num_cells], 0..) |node_idx, ci| {
        const node = cluster_bivh.nodes[node_idx];
        const color = island_colors[islands.island_ids[ci]];
        const p_min = worldToPixel(node.min, world_min, world_max, size);
        const p_max = worldToPixel(node.max, world_min, world_max, size);
        fillRect(pixels, size, p_min.x, p_max.y, p_max.x, p_min.y, color);
    }

    for (cell_node_indices[0..num_cells]) |node_idx| {
        const node = cluster_bivh.nodes[node_idx];
        const p_min = worldToPixel(node.min, world_min, world_max, size);
        const p_max = worldToPixel(node.max, world_min, world_max, size);
        const outline = Color{ .r = 40, .g = 40, .b = 40 };
        drawLine(pixels, size, p_min.x, p_max.y, p_max.x, p_max.y, outline, 1.0);
        drawLine(pixels, size, p_max.x, p_max.y, p_max.x, p_min.y, outline, 1.0);
        drawLine(pixels, size, p_max.x, p_min.y, p_min.x, p_min.y, outline, 1.0);
        drawLine(pixels, size, p_min.x, p_min.y, p_min.x, p_max.y, outline, 1.0);
    }

    for (probes) |probe| {
        const p = worldToPixel(probe.position, world_min, world_max, size);
        if (probe.is_boundary) {
            const s_half: i32 = 4;
            drawLine(pixels, size, p.x, p.y - s_half, p.x + s_half, p.y, .{ .r = 255, .g = 255, .b = 255 }, 1.0);
            drawLine(pixels, size, p.x + s_half, p.y, p.x, p.y + s_half, .{ .r = 255, .g = 255, .b = 255 }, 1.0);
            drawLine(pixels, size, p.x, p.y + s_half, p.x - s_half, p.y, .{ .r = 255, .g = 255, .b = 255 }, 1.0);
            drawLine(pixels, size, p.x - s_half, p.y, p.x, p.y - s_half, .{ .r = 255, .g = 255, .b = 255 }, 1.0);
        } else {
            fillRect(pixels, size, p.x - 3, p.y - 3, p.x + 3, p.y + 3, .{ .r = 255, .g = 255, .b = 0 });
        }
    }

    for (islands.boundary_cells[0..islands.num_boundary]) |cell| {
        const p = worldToPixel(cell_centroids[cell], world_min, world_max, size);
        fillRect(pixels, size, p.x - 1, p.y - 1, p.x + 1, p.y + 1, .{ .r = 255, .g = 100, .b = 100 });
    }

    try writePpm(pixels, size, path);
}

pub fn writeProbeAssignment(
    allocator: Allocator,
    assignment: *const pvs_mod.ProbeAssignment,
    cluster_centroids: []const Vec3,
    cluster_count: u32,
    probes: []const pvs_mod.Probe,
    world_min: [3]f32,
    world_max: [3]f32,
    path: []const u8,
) !void {
    const size = IMG_SIZE;
    const pixels = try allocator.alloc(Color, size * size);
    defer allocator.free(pixels);
    @memset(pixels, Color{ .r = 10, .g = 10, .b = 15 });

    const probe_colors = try allocator.alloc(Color, probes.len);
    defer allocator.free(probe_colors);
    for (0..probes.len) |i| {
        const hue = @as(f32, @floatFromInt(i)) * 0.618033988749895;
        probe_colors[i] = hsvToRgb(hue - @floor(hue), 0.8, 0.85);
    }

    for (0..cluster_count) |ci| {
        const probe_id = assignment.cluster_to_probe[ci];
        if (probe_id >= probes.len) continue;
        const p = worldToPixel(cluster_centroids[ci], world_min, world_max, size);
        fillRect(pixels, size, p.x - 1, p.y - 1, p.x + 1, p.y + 1, probe_colors[probe_id]);
    }

    for (probes) |probe| {
        const p = worldToPixel(probe.position, world_min, world_max, size);
        if (probe.is_boundary) {
            drawLine(pixels, size, p.x, p.y - 5, p.x + 5, p.y, .{ .r = 255, .g = 255, .b = 255 }, 1.0);
            drawLine(pixels, size, p.x + 5, p.y, p.x, p.y + 5, .{ .r = 255, .g = 255, .b = 255 }, 1.0);
            drawLine(pixels, size, p.x, p.y + 5, p.x - 5, p.y, .{ .r = 255, .g = 255, .b = 255 }, 1.0);
            drawLine(pixels, size, p.x - 5, p.y, p.x, p.y - 5, .{ .r = 255, .g = 255, .b = 255 }, 1.0);
        } else {
            fillRect(pixels, size, p.x - 4, p.y - 4, p.x + 4, p.y + 4, .{ .r = 255, .g = 255, .b = 0 });
        }
    }

    try writePpm(pixels, size, path);
}

pub fn writeLightingMap(
    allocator: Allocator,
    cluster_light: []const f32,
    cluster_centroids: []const Vec3,
    cluster_count: u32,
    probe_sh: []const pvs_mod.SHCoeffs,
    probes: []const pvs_mod.Probe,
    world_min: [3]f32,
    world_max: [3]f32,
    path: []const u8,
) !void {
    const size = IMG_SIZE;
    const pixels = try allocator.alloc(Color, size * size);
    defer allocator.free(pixels);
    @memset(pixels, Color{ .r = 5, .g = 5, .b = 8 });

    const sorted = try allocator.alloc(f32, cluster_count);
    defer allocator.free(sorted);
    @memcpy(sorted, cluster_light);
    std.mem.sort(f32, sorted, {}, std.sort.asc(f32));
    const p90 = sorted[@min(cluster_count - 1, cluster_count * 9 / 10)];
    const exposure = if (p90 > 0.001) 8.0 / p90 else 1.0;

    for (0..cluster_count) |ci| {
        const intensity = cluster_light[ci] * exposure;
        const mapped = intensity / (1.0 + intensity);
        const color = Color{
            .r = @intFromFloat(std.math.clamp(mapped * 255 * 1.1, 0, 255)),
            .g = @intFromFloat(std.math.clamp(mapped * 255 * 0.9, 0, 255)),
            .b = @intFromFloat(std.math.clamp(mapped * 255 * 0.7 + (1.0 - mapped) * 40, 0, 255)),
        };
        const p = worldToPixel(cluster_centroids[ci], world_min, world_max, size);
        fillRect(pixels, size, p.x - 2, p.y - 2, p.x + 2, p.y + 2, color);
    }

    for (probes, 0..) |probe, pi| {
        const p = worldToPixel(probe.position, world_min, world_max, size);
        const sh_val = probe_sh[pi].intensity() * exposure;
        const sh_mapped = sh_val / (1.0 + sh_val);
        const bright: u8 = @intFromFloat(std.math.clamp(sh_mapped * 255, 0, 255));

        if (probe.is_boundary) {
            drawLine(pixels, size, p.x, p.y - 4, p.x + 4, p.y, .{ .r = bright, .g = bright, .b = 255 }, 1.0);
            drawLine(pixels, size, p.x + 4, p.y, p.x, p.y + 4, .{ .r = bright, .g = bright, .b = 255 }, 1.0);
            drawLine(pixels, size, p.x, p.y + 4, p.x - 4, p.y, .{ .r = bright, .g = bright, .b = 255 }, 1.0);
            drawLine(pixels, size, p.x - 4, p.y, p.x, p.y - 4, .{ .r = bright, .g = bright, .b = 255 }, 1.0);
        } else {
            fillRect(pixels, size, p.x - 3, p.y - 3, p.x + 3, p.y + 3, .{ .r = bright, .g = bright, .b = bright });
        }
    }

    try writePpm(pixels, size, path);
}
