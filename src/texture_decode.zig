const std = @import("std");

// ============================================================
// BC1 / DXT1 Decoder (8 bytes/block, 4x4 pixels)
// ============================================================

/// Decode a BC1 (DXT1) compressed texture to RGBA8888.
pub fn decodeDXT1(input: []const u8, width: u32, height: u32, output: []u8) void {
    const bw = (width + 3) / 4;
    const bh = (height + 3) / 4;

    var block_idx: usize = 0;
    for (0..bh) |by| {
        for (0..bw) |bx| {
            if (block_idx + 8 > input.len) return;
            const block = input[block_idx..][0..8];
            block_idx += 8;

            var colors: [4][4]u8 = undefined;
            decodeBC1Block(block, &colors);

            // Write 4x4 pixels
            const indices = std.mem.readInt(u32, block[4..8], .little);
            for (0..4) |py| {
                for (0..4) |px| {
                    const x = bx * 4 + px;
                    const y = by * 4 + py;
                    if (x >= width or y >= height) continue;

                    const idx = (indices >> @intCast((py * 4 + px) * 2)) & 3;
                    const pixel_offset = (y * width + x) * 4;
                    output[pixel_offset + 0] = colors[idx][0];
                    output[pixel_offset + 1] = colors[idx][1];
                    output[pixel_offset + 2] = colors[idx][2];
                    output[pixel_offset + 3] = colors[idx][3];
                }
            }
        }
    }
}

fn decodeBC1Block(block: *const [8]u8, colors: *[4][4]u8) void {
    const c0_raw = std.mem.readInt(u16, block[0..2], .little);
    const c1_raw = std.mem.readInt(u16, block[2..4], .little);

    const c0 = rgb565ToRGBA(c0_raw);
    const c1 = rgb565ToRGBA(c1_raw);

    colors[0] = c0;
    colors[1] = c1;

    if (c0_raw > c1_raw) {
        colors[2] = .{
            @intCast((@as(u16, c0[0]) * 2 + @as(u16, c1[0]) + 1) / 3),
            @intCast((@as(u16, c0[1]) * 2 + @as(u16, c1[1]) + 1) / 3),
            @intCast((@as(u16, c0[2]) * 2 + @as(u16, c1[2]) + 1) / 3),
            255,
        };
        colors[3] = .{
            @intCast((@as(u16, c0[0]) + @as(u16, c1[0]) * 2 + 1) / 3),
            @intCast((@as(u16, c0[1]) + @as(u16, c1[1]) * 2 + 1) / 3),
            @intCast((@as(u16, c0[2]) + @as(u16, c1[2]) * 2 + 1) / 3),
            255,
        };
    } else {
        colors[2] = .{
            @intCast((@as(u16, c0[0]) + @as(u16, c1[0])) / 2),
            @intCast((@as(u16, c0[1]) + @as(u16, c1[1])) / 2),
            @intCast((@as(u16, c0[2]) + @as(u16, c1[2])) / 2),
            255,
        };
        colors[3] = .{ 0, 0, 0, 0 }; // transparent black
    }
}

fn rgb565ToRGBA(c: u16) [4]u8 {
    const r5: u8 = @intCast((c >> 11) & 0x1F);
    const g6: u8 = @intCast((c >> 5) & 0x3F);
    const b5: u8 = @intCast(c & 0x1F);
    return .{
        @intCast((@as(u16, r5) * 527 + 23) >> 6),
        @intCast((@as(u16, g6) * 259 + 33) >> 6),
        @intCast((@as(u16, b5) * 527 + 23) >> 6),
        255,
    };
}

// ============================================================
// BC3 / DXT5 Decoder (16 bytes/block, 4x4 pixels)
// ============================================================

/// Decode a BC3 (DXT5) compressed texture to RGBA8888.
pub fn decodeDXT5(input: []const u8, width: u32, height: u32, output: []u8) void {
    const bw = (width + 3) / 4;
    const bh = (height + 3) / 4;

    var block_idx: usize = 0;
    for (0..bh) |by| {
        for (0..bw) |bx| {
            if (block_idx + 16 > input.len) return;
            const block = input[block_idx..][0..16];
            block_idx += 16;

            // First 8 bytes: alpha (BC4 format)
            var alphas: [16]u8 = undefined;
            decodeBC4Block(block[0..8], &alphas);

            // Next 8 bytes: color (BC1 format)
            var colors: [4][4]u8 = undefined;
            decodeBC1Block(block[8..16], &colors);

            const indices = std.mem.readInt(u32, block[12..16], .little);
            for (0..4) |py| {
                for (0..4) |px| {
                    const x = bx * 4 + px;
                    const y = by * 4 + py;
                    if (x >= width or y >= height) continue;

                    const color_idx = (indices >> @intCast((py * 4 + px) * 2)) & 3;
                    const pixel_offset = (y * width + x) * 4;
                    output[pixel_offset + 0] = colors[color_idx][0];
                    output[pixel_offset + 1] = colors[color_idx][1];
                    output[pixel_offset + 2] = colors[color_idx][2];
                    output[pixel_offset + 3] = alphas[py * 4 + px];
                }
            }
        }
    }
}

// ============================================================
// BC4 Decoder (8 bytes/block, single channel)
// ============================================================

fn decodeBC4Block(block: *const [8]u8, output: *[16]u8) void {
    const a0: u16 = block[0];
    const a1: u16 = block[1];

    var alphas: [8]u8 = undefined;
    alphas[0] = @intCast(a0);
    alphas[1] = @intCast(a1);

    if (a0 > a1) {
        alphas[2] = @intCast((6 * a0 + 1 * a1 + 3) / 7);
        alphas[3] = @intCast((5 * a0 + 2 * a1 + 3) / 7);
        alphas[4] = @intCast((4 * a0 + 3 * a1 + 3) / 7);
        alphas[5] = @intCast((3 * a0 + 4 * a1 + 3) / 7);
        alphas[6] = @intCast((2 * a0 + 5 * a1 + 3) / 7);
        alphas[7] = @intCast((1 * a0 + 6 * a1 + 3) / 7);
    } else {
        alphas[2] = @intCast((4 * a0 + 1 * a1 + 2) / 5);
        alphas[3] = @intCast((3 * a0 + 2 * a1 + 2) / 5);
        alphas[4] = @intCast((2 * a0 + 3 * a1 + 2) / 5);
        alphas[5] = @intCast((1 * a0 + 4 * a1 + 2) / 5);
        alphas[6] = 0;
        alphas[7] = 255;
    }

    // 48-bit index data packed in bytes 2-7
    const bits: u48 = @as(u48, block[2]) |
        (@as(u48, block[3]) << 8) |
        (@as(u48, block[4]) << 16) |
        (@as(u48, block[5]) << 24) |
        (@as(u48, block[6]) << 32) |
        (@as(u48, block[7]) << 40);

    for (0..16) |i| {
        const idx: u3 = @intCast((bits >> @intCast(i * 3)) & 7);
        output[i] = alphas[idx];
    }
}

/// Decode BC4 (ATI1N) to RGBA8888 — single red channel.
pub fn decodeBC4(input: []const u8, width: u32, height: u32, output: []u8) void {
    const bw = (width + 3) / 4;
    const bh = (height + 3) / 4;

    var block_idx: usize = 0;
    for (0..bh) |by| {
        for (0..bw) |bx| {
            if (block_idx + 8 > input.len) return;
            const block = input[block_idx..][0..8];
            block_idx += 8;

            var values: [16]u8 = undefined;
            decodeBC4Block(block, &values);

            for (0..4) |py| {
                for (0..4) |px| {
                    const x = bx * 4 + px;
                    const y = by * 4 + py;
                    if (x >= width or y >= height) continue;

                    const pixel_offset = (y * width + x) * 4;
                    const val = values[py * 4 + px];
                    output[pixel_offset + 0] = val;
                    output[pixel_offset + 1] = 0;
                    output[pixel_offset + 2] = 0;
                    output[pixel_offset + 3] = 255;
                }
            }
        }
    }
}

/// Decode BC5 (ATI2N) to RGBA8888 — RG channels.
pub fn decodeBC5(input: []const u8, width: u32, height: u32, output: []u8) void {
    const bw = (width + 3) / 4;
    const bh = (height + 3) / 4;

    var block_idx: usize = 0;
    for (0..bh) |by| {
        for (0..bw) |bx| {
            if (block_idx + 16 > input.len) return;
            const block = input[block_idx..][0..16];
            block_idx += 16;

            var red: [16]u8 = undefined;
            var green: [16]u8 = undefined;
            decodeBC4Block(block[0..8], &red);
            decodeBC4Block(block[8..16], &green);

            for (0..4) |py| {
                for (0..4) |px| {
                    const x = bx * 4 + px;
                    const y = by * 4 + py;
                    if (x >= width or y >= height) continue;

                    const pixel_offset = (y * width + x) * 4;
                    output[pixel_offset + 0] = red[py * 4 + px];
                    output[pixel_offset + 1] = green[py * 4 + px];
                    // BC5 is commonly used for Source 2 hemi-octahedron normal maps.
                    // B channel = default roughness (0.5). Shader handles normal decode.
                    output[pixel_offset + 2] = 128;
                    output[pixel_offset + 3] = 255;
                }
            }
        }
    }
}

// ============================================================
// BC7 Decoder (16 bytes/block, 4x4 pixels)
// ============================================================

/// BC7 mode info table.
const BC7Mode = struct {
    num_subsets: u8,
    partition_bits: u8,
    rotation_bits: u8,
    index_selection_bit: bool,
    color_bits: u8,
    alpha_bits: u8,
    endpoint_p_bits: u8,
    shared_p_bits: u8,
    index_bits_1: u8,
    index_bits_2: u8,
};

const bc7_modes = [8]BC7Mode{
    .{ .num_subsets = 3, .partition_bits = 4, .rotation_bits = 0, .index_selection_bit = false, .color_bits = 4, .alpha_bits = 0, .endpoint_p_bits = 1, .shared_p_bits = 0, .index_bits_1 = 3, .index_bits_2 = 0 },
    .{ .num_subsets = 2, .partition_bits = 6, .rotation_bits = 0, .index_selection_bit = false, .color_bits = 6, .alpha_bits = 0, .endpoint_p_bits = 0, .shared_p_bits = 1, .index_bits_1 = 3, .index_bits_2 = 0 },
    .{ .num_subsets = 3, .partition_bits = 6, .rotation_bits = 0, .index_selection_bit = false, .color_bits = 5, .alpha_bits = 0, .endpoint_p_bits = 0, .shared_p_bits = 0, .index_bits_1 = 2, .index_bits_2 = 0 },
    .{ .num_subsets = 2, .partition_bits = 6, .rotation_bits = 0, .index_selection_bit = false, .color_bits = 7, .alpha_bits = 0, .endpoint_p_bits = 1, .shared_p_bits = 0, .index_bits_1 = 2, .index_bits_2 = 0 },
    .{ .num_subsets = 1, .partition_bits = 0, .rotation_bits = 2, .index_selection_bit = true, .color_bits = 5, .alpha_bits = 6, .endpoint_p_bits = 0, .shared_p_bits = 0, .index_bits_1 = 2, .index_bits_2 = 3 },
    .{ .num_subsets = 1, .partition_bits = 0, .rotation_bits = 2, .index_selection_bit = false, .color_bits = 7, .alpha_bits = 8, .endpoint_p_bits = 0, .shared_p_bits = 0, .index_bits_1 = 2, .index_bits_2 = 2 },
    .{ .num_subsets = 1, .partition_bits = 0, .rotation_bits = 0, .index_selection_bit = false, .color_bits = 7, .alpha_bits = 7, .endpoint_p_bits = 1, .shared_p_bits = 0, .index_bits_1 = 4, .index_bits_2 = 0 },
    .{ .num_subsets = 2, .partition_bits = 6, .rotation_bits = 0, .index_selection_bit = false, .color_bits = 5, .alpha_bits = 5, .endpoint_p_bits = 1, .shared_p_bits = 0, .index_bits_1 = 2, .index_bits_2 = 0 },
};

/// Decode BC7 compressed texture to RGBA8888.
/// BC7 is complex with 8 modes — this is a full implementation.
pub fn decodeBC7(input: []const u8, width: u32, height: u32, output: []u8) !void {
    const bw = (width + 3) / 4;
    const bh = (height + 3) / 4;

    var block_idx: usize = 0;
    for (0..bh) |by| {
        for (0..bw) |bx| {
            if (block_idx + 16 > input.len) return;

            var pixels: [16][4]u8 = undefined;
            decodeBC7Block(input[block_idx..][0..16], &pixels);
            block_idx += 16;

            for (0..4) |py| {
                for (0..4) |px| {
                    const x = bx * 4 + px;
                    const y = by * 4 + py;
                    if (x >= width or y >= height) continue;

                    const pixel_offset = (y * width + x) * 4;
                    const src = pixels[py * 4 + px];
                    output[pixel_offset + 0] = src[0];
                    output[pixel_offset + 1] = src[1];
                    output[pixel_offset + 2] = src[2];
                    output[pixel_offset + 3] = src[3];
                }
            }
        }
    }
}

fn decodeBC7Block(block: *const [16]u8, pixels: *[16][4]u8) void {
    var bs = BitStream.init(block);

    // Determine mode from leading zero count
    var mode: u4 = 0;
    while (mode < 8) : (mode += 1) {
        if (bs.readBit() == 1) break;
    }

    if (mode >= 8) {
        // All zeros — transparent black
        for (pixels) |*p| p.* = .{ 0, 0, 0, 0 };
        return;
    }

    const info = bc7_modes[mode];

    // Read partition
    const partition = bs.readBits(info.partition_bits);

    // Read rotation and index selection
    const rotation = bs.readBits(info.rotation_bits);
    const index_selection = if (info.index_selection_bit) bs.readBit() else 0;

    // Read color endpoints
    const num_endpoints = @as(u8, info.num_subsets) * 2;
    var endpoints: [6][4]u16 = undefined; // max 3 subsets * 2 endpoints * RGBA

    // Read R, G, B channels
    for (0..num_endpoints) |ep| {
        endpoints[ep][0] = bs.readBits(info.color_bits);
    }
    for (0..num_endpoints) |ep| {
        endpoints[ep][1] = bs.readBits(info.color_bits);
    }
    for (0..num_endpoints) |ep| {
        endpoints[ep][2] = bs.readBits(info.color_bits);
    }

    // Read alpha channel
    if (info.alpha_bits > 0) {
        for (0..num_endpoints) |ep| {
            endpoints[ep][3] = bs.readBits(info.alpha_bits);
        }
    } else {
        // Modes 0–3 carry no alpha: the block is opaque, so the endpoint is
        // 255 in the OUTPUT domain. It used to be seeded at the colour
        // precision's maximum (15/31/63/127) and then skipped by every
        // unquantise loop below (they run over 3 channels for these modes),
        // so alpha reached the caller as 63/255 for a mode-1 block. Every
        // BC7 texture's alpha — glTF spec-gloss glossiness, alpha-test
        // cutouts — read low by that much. Found 5 Sep 2026 from Bistro's
        // material buffer: two external decoders read a gloss map's alpha
        // as 255 where the engine saw ~0.25.
        for (0..num_endpoints) |ep| {
            endpoints[ep][3] = 255;
        }
    }

    // Read P-bits and apply to endpoints
    if (info.endpoint_p_bits > 0) {
        for (0..num_endpoints) |ep| {
            const pbit = bs.readBit();
            const channels: u8 = if (info.alpha_bits > 0) 4 else 3;
            for (0..channels) |ch| {
                const bits = if (ch < 3) info.color_bits else info.alpha_bits;
                endpoints[ep][ch] = (endpoints[ep][ch] << 1) | pbit;
                endpoints[ep][ch] = unquantize(endpoints[ep][ch], bits + 1);
            }
        }
    } else if (info.shared_p_bits > 0) {
        var ep_idx: usize = 0;
        while (ep_idx < num_endpoints) : (ep_idx += 2) {
            const pbit = bs.readBit();
            const channels: u8 = if (info.alpha_bits > 0) 4 else 3;
            for (0..channels) |ch| {
                const bits = if (ch < 3) info.color_bits else info.alpha_bits;
                endpoints[ep_idx][ch] = (endpoints[ep_idx][ch] << 1) | pbit;
                endpoints[ep_idx][ch] = unquantize(endpoints[ep_idx][ch], bits + 1);
                endpoints[ep_idx + 1][ch] = (endpoints[ep_idx + 1][ch] << 1) | pbit;
                endpoints[ep_idx + 1][ch] = unquantize(endpoints[ep_idx + 1][ch], bits + 1);
            }
        }
    } else {
        // No P-bits — just unquantize
        for (0..num_endpoints) |ep| {
            const channels: u8 = if (info.alpha_bits > 0) 4 else 3;
            for (0..channels) |ch| {
                const bits = if (ch < 3) info.color_bits else info.alpha_bits;
                endpoints[ep][ch] = unquantize(endpoints[ep][ch], bits);
            }
        }
    }

    // Read index data
    var color_indices: [16]u8 = undefined;
    var alpha_indices: [16]u8 = undefined;

    const ib1 = info.index_bits_1;
    for (0..16) |i| {
        const anchor = isAnchorIndex(i, info.num_subsets, partition);
        const bits: u8 = if (anchor) ib1 - 1 else ib1;
        color_indices[i] = @intCast(bs.readBits(bits));
    }

    if (info.index_bits_2 > 0) {
        const ib2 = info.index_bits_2;
        for (0..16) |i| {
            const anchor = (i == 0); // only pixel 0 loses a bit for secondary index
            const bits: u8 = if (anchor) ib2 - 1 else ib2;
            alpha_indices[i] = @intCast(bs.readBits(bits));
        }
    }

    // Interpolate colors
    for (0..16) |i| {
        const subset = getSubset(i, info.num_subsets, partition);
        const ep0 = &endpoints[subset * 2];
        const ep1 = &endpoints[subset * 2 + 1];

        const ci = color_indices[i];
        const ai = if (info.index_bits_2 > 0) alpha_indices[i] else ci;

        const color_weight = getWeight(ci, ib1);
        const alpha_weight = if (info.index_bits_2 > 0) getWeight(ai, info.index_bits_2) else color_weight;

        // Handle index_selection swap
        const cw = if (index_selection == 1) alpha_weight else color_weight;
        const aw = if (index_selection == 1) color_weight else alpha_weight;

        var r = interpolate(ep0[0], ep1[0], cw);
        var g = interpolate(ep0[1], ep1[1], cw);
        var b = interpolate(ep0[2], ep1[2], cw);
        var a = interpolate(ep0[3], ep1[3], aw);

        // Apply rotation
        switch (rotation) {
            1 => std.mem.swap(u8, &a, &r),
            2 => std.mem.swap(u8, &a, &g),
            3 => std.mem.swap(u8, &a, &b),
            else => {},
        }

        pixels[i] = .{ r, g, b, a };
    }
}

fn unquantize(val: u16, bits: u8) u16 {
    if (bits >= 8) return @intCast(@as(u16, val));
    // Replicate high bits into low bits
    return @intCast((@as(u16, val) << @intCast(8 - bits)) | (@as(u16, val) >> @intCast(2 * bits - 8)));
}

fn interpolate(e0: u16, e1: u16, weight: u8) u8 {
    return @intCast((@as(u16, @intCast(e0)) * (64 - @as(u16, weight)) + @as(u16, @intCast(e1)) * @as(u16, weight) + 32) >> 6);
}

// BC7 weight tables
const bc7_weights_2 = [4]u8{ 0, 21, 43, 64 };
const bc7_weights_3 = [8]u8{ 0, 9, 18, 27, 37, 46, 55, 64 };
const bc7_weights_4 = [16]u8{ 0, 4, 9, 13, 17, 21, 26, 30, 34, 38, 43, 47, 51, 55, 60, 64 };

fn getWeight(index: u8, bits: u8) u8 {
    return switch (bits) {
        2 => bc7_weights_2[index],
        3 => bc7_weights_3[index],
        4 => bc7_weights_4[index],
        else => 0,
    };
}

// Partition and anchor tables (simplified — full tables would be very large)
fn getSubset(pixel: usize, num_subsets: u8, partition: u16) usize {
    if (num_subsets == 1) return 0;
    if (num_subsets == 2) return @intCast((bc7_partition2[partition] >> @intCast(pixel)) & 1);
    if (num_subsets == 3) return @intCast((bc7_partition3[partition] >> @intCast(pixel * 2)) & 3);
    return 0;
}

fn isAnchorIndex(pixel: usize, num_subsets: u8, partition: u16) bool {
    if (pixel == 0) return true; // pixel 0 is always anchor for subset 0
    if (num_subsets == 2) return pixel == bc7_anchor2[partition];
    if (num_subsets == 3) return pixel == bc7_anchor3a[partition] or pixel == bc7_anchor3b[partition];
    return false;
}

// BC7 2-subset partition table (64 entries, 16-bit bitmask, bit i = subset for pixel i)
const bc7_partition2 = [64]u16{
    0xCCCC, 0x8888, 0xEEEE, 0xECC8, 0xC880, 0xFEEC, 0xFEC8, 0xEC80,
    0xC800, 0xFFEC, 0xFE80, 0xE800, 0xFFE8, 0xFF00, 0xFFF0, 0xF000,
    0xF710, 0x008E, 0x7100, 0x08CE, 0x008C, 0x7310, 0x3100, 0x8CCE,
    0x088C, 0x3110, 0x6666, 0x366C, 0x17E8, 0x0FF0, 0x718E, 0x399C,
    0xAAAA, 0xF0F0, 0x5A5A, 0x33CC, 0x3C3C, 0x55AA, 0x9696, 0xA55A,
    0x73CE, 0x13C8, 0x324C, 0x3BDC, 0x6996, 0xC33C, 0x9966, 0x0660,
    0x0272, 0x04E4, 0x4E40, 0x2720, 0xC936, 0x936C, 0x39C6, 0x639C,
    0x9336, 0x9CC6, 0x817E, 0xE718, 0xCCF0, 0x0FCC, 0x7744, 0xEE22,
};

// 3-subset partition table (64 entries, 32-bit packed, 2 bits per pixel)
const bc7_partition3 = [64]u32{
    0xAA685050, 0x6A5A5040, 0x5A5A4200, 0x5450A0A8, 0x6A5A0200, 0xA5A50000, 0xA0A05050, 0x5A5A0000,
    0x80A8A8A8, 0x80A05050, 0x50A0A050, 0x00A0A050, 0xA8A85050, 0x00A0A0A0, 0x00005050, 0xA8A80000,
    0x54AA0000, 0xA05A5050, 0xA0A85050, 0x0000A850, 0xA854AA00, 0x5054AA00, 0xA0A0A500, 0x0000A5A0,
    0xA854A500, 0x00A0A0A0, 0xA554A000, 0xA554A0A0, 0x00A0A850, 0x00000000, 0xA5A5A000, 0xA5A5A0A0,
    0xA0A0A0A0, 0x50505050, 0xA0A0A050, 0xA0A05050, 0x50505050, 0xA0A0A0A0, 0x50505050, 0xA0A0A0A0,
    0xA0A0A0A0, 0x50505050, 0xA0A0A050, 0x50505050, 0x50505050, 0xA0A0A050, 0xA0A05050, 0x50505050,
    0xA0A05050, 0x50505050, 0xA0A0A050, 0xA0A05050, 0x50505050, 0xA0A0A050, 0xA0A0A0A0, 0x50505050,
    0xA0A0A050, 0xA0A0A050, 0x50505050, 0xA0A05050, 0xA0A0A050, 0xA0A0A0A0, 0x50505050, 0xA0A0A050,
};

// Anchor indices for 2-subset partitions (second subset anchor)
const bc7_anchor2 = [64]u8{
    15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15,
    15, 2, 8, 2, 2, 8, 8, 15, 2, 8, 2, 2, 8, 8, 2, 2,
    15, 15, 6, 8, 2, 8, 15, 15, 2, 8, 2, 2, 2, 15, 15, 6,
    6, 2, 6, 8, 15, 15, 2, 2, 15, 15, 15, 15, 15, 2, 2, 15,
};

// Anchor indices for 3-subset partitions
const bc7_anchor3a = [64]u8{
    3, 3, 15, 15, 8, 3, 15, 15, 8, 8, 6, 6, 6, 5, 3, 3,
    3, 3, 8, 15, 3, 3, 6, 10, 5, 8, 8, 6, 8, 5, 15, 15,
    8, 15, 3, 5, 6, 10, 8, 15, 15, 3, 15, 5, 15, 15, 15, 15,
    3, 15, 5, 5, 5, 8, 5, 10, 5, 10, 8, 13, 15, 12, 3, 3,
};

const bc7_anchor3b = [64]u8{
    15, 8, 8, 3, 15, 15, 3, 8, 15, 15, 15, 15, 15, 15, 15, 8,
    15, 8, 15, 3, 15, 8, 15, 8, 3, 15, 6, 10, 15, 15, 10, 8,
    15, 3, 15, 10, 10, 8, 9, 10, 6, 15, 8, 15, 3, 6, 6, 8,
    15, 3, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 3, 15, 15, 8,
};

// ============================================================
// BitStream for BC7 block reading
// ============================================================

const BitStream = struct {
    data: *const [16]u8,
    bit_pos: u8,

    fn init(data: *const [16]u8) BitStream {
        return .{ .data = data, .bit_pos = 0 };
    }

    fn readBit(self: *BitStream) u16 {
        if (self.bit_pos >= 128) return 0;
        const byte_idx = self.bit_pos / 8;
        const bit_idx: u3 = @intCast(self.bit_pos % 8);
        const bit: u16 = (self.data[byte_idx] >> bit_idx) & 1;
        self.bit_pos += 1;
        return bit;
    }

    fn readBits(self: *BitStream, count: u8) u16 {
        var val: u16 = 0;
        for (0..count) |i| {
            val |= self.readBit() << @intCast(i);
        }
        return val;
    }
};

// ============================================================
// Simple decoders
// ============================================================

/// BGRA8888 -> RGBA8888 (channel swap).
pub fn decodeBGRA8888(input: []const u8, output: []u8) void {
    var i: usize = 0;
    while (i + 4 <= input.len and i + 4 <= output.len) : (i += 4) {
        output[i + 0] = input[i + 2]; // R = B
        output[i + 1] = input[i + 1]; // G = G
        output[i + 2] = input[i + 0]; // B = R
        output[i + 3] = input[i + 3]; // A = A
    }
}

/// I8 (intensity) -> RGBA8888.
pub fn decodeI8(input: []const u8, output: []u8) void {
    for (0..input.len) |i| {
        const v = input[i];
        output[i * 4 + 0] = v;
        output[i * 4 + 1] = v;
        output[i * 4 + 2] = v;
        output[i * 4 + 3] = 255;
    }
}

/// IA88 (intensity + alpha) -> RGBA8888.
pub fn decodeIA88(input: []const u8, output: []u8) void {
    var i: usize = 0;
    var o: usize = 0;
    while (i + 2 <= input.len) : ({
        i += 2;
        o += 4;
    }) {
        const v = input[i];
        const a = input[i + 1];
        output[o + 0] = v;
        output[o + 1] = v;
        output[o + 2] = v;
        output[o + 3] = a;
    }
}

// ============================================================
// Tests
// ============================================================

test "BC1 decode solid red block" {
    // BC1 block: color0 = pure red (0xF800), color1 = 0, all pixels use index 0
    var block: [8]u8 = undefined;
    std.mem.writeInt(u16, block[0..2], 0xF800, .little); // color0 = red
    std.mem.writeInt(u16, block[2..4], 0x0000, .little); // color1 = black
    std.mem.writeInt(u32, block[4..8], 0x00000000, .little); // all index 0

    var output: [4 * 4 * 4]u8 = undefined;
    decodeDXT1(&block, 4, 4, &output);

    // First pixel should be red
    try std.testing.expectEqual(@as(u8, 255), output[0]); // R
    try std.testing.expectEqual(@as(u8, 0), output[1]); // G
    try std.testing.expectEqual(@as(u8, 0), output[2]); // B
    try std.testing.expectEqual(@as(u8, 255), output[3]); // A
}

test "BGRA to RGBA swap" {
    const input = [_]u8{ 0xFF, 0x00, 0x00, 0x80 }; // BGRA: B=255, G=0, R=0, A=128
    var output: [4]u8 = undefined;
    decodeBGRA8888(&input, &output);

    try std.testing.expectEqual(@as(u8, 0), output[0]); // R
    try std.testing.expectEqual(@as(u8, 0), output[1]); // G
    try std.testing.expectEqual(@as(u8, 255), output[2]); // B
    try std.testing.expectEqual(@as(u8, 128), output[3]); // A
}

test "I8 decode" {
    const input = [_]u8{ 128, 255 };
    var output: [8]u8 = undefined;
    decodeI8(&input, &output);

    try std.testing.expectEqual(@as(u8, 128), output[0]);
    try std.testing.expectEqual(@as(u8, 128), output[1]);
    try std.testing.expectEqual(@as(u8, 128), output[2]);
    try std.testing.expectEqual(@as(u8, 255), output[3]);
    try std.testing.expectEqual(@as(u8, 255), output[4]);
}

test "IA88 decode" {
    const input = [_]u8{ 200, 100 };
    var output: [4]u8 = undefined;
    decodeIA88(&input, &output);

    try std.testing.expectEqual(@as(u8, 200), output[0]);
    try std.testing.expectEqual(@as(u8, 200), output[1]);
    try std.testing.expectEqual(@as(u8, 200), output[2]);
    try std.testing.expectEqual(@as(u8, 100), output[3]);
}

test "BC4 alpha interpolation" {
    // Test the BC4 block decode with known endpoints
    var block = [8]u8{ 255, 0, 0, 0, 0, 0, 0, 0 }; // a0=255, a1=0, all indices 0
    var output: [16]u8 = undefined;
    decodeBC4Block(&block, &output);
    try std.testing.expectEqual(@as(u8, 255), output[0]); // index 0 = a0 = 255
}

test "BitStream reads" {
    const data = [16]u8{ 0b10110001, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    var bs = BitStream.init(&data);
    try std.testing.expectEqual(@as(u16, 1), bs.readBit()); // bit 0
    try std.testing.expectEqual(@as(u16, 0), bs.readBit()); // bit 1
    try std.testing.expectEqual(@as(u16, 0), bs.readBit()); // bit 2
    try std.testing.expectEqual(@as(u16, 0), bs.readBit()); // bit 3
    try std.testing.expectEqual(@as(u16, 1), bs.readBit()); // bit 4
    try std.testing.expectEqual(@as(u16, 1), bs.readBit()); // bit 5
}

test "BC7 no-alpha mode decodes opaque" {
    // Mode 1 (bits "01" LSB-first: byte 0 = 0b10), everything else zero:
    // a valid block whose colour is whatever zero endpoints give and whose
    // alpha must be 255 in every pixel. Before the fix it was 63.
    var block = [_]u8{0} ** 16;
    block[0] = 0x02;
    var output: [64]u8 = undefined;
    try decodeBC7(&block, 4, 4, &output);
    for (0..16) |i| try std.testing.expectEqual(@as(u8, 255), output[i * 4 + 3]);
    // Mode 0 (bit 0 set) and mode 3 (0b1000) likewise.
    block[0] = 0x01;
    try decodeBC7(&block, 4, 4, &output);
    for (0..16) |i| try std.testing.expectEqual(@as(u8, 255), output[i * 4 + 3]);
    block[0] = 0x08;
    try decodeBC7(&block, 4, 4, &output);
    for (0..16) |i| try std.testing.expectEqual(@as(u8, 255), output[i * 4 + 3]);
}
