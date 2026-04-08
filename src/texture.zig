const std = @import("std");
const BinaryReader = @import("binary_reader.zig").BinaryReader;

// ============================================================
// Enums
// ============================================================

/// Source 2 compiled texture formats (VTexFormat).
pub const VTexFormat = enum(u8) {
    unknown = 0,
    dxt1 = 1, // BC1 — 8 bytes/block
    dxt5 = 2, // BC3 — 16 bytes/block
    i8 = 3, // Intensity 8-bit
    rgba8888 = 4, // 4 bytes/pixel
    r16 = 5, // 2 bytes/pixel
    rg1616 = 6, // 4 bytes/pixel
    rgba16161616 = 7, // 8 bytes/pixel
    r16f = 8, // 2 bytes/pixel (half)
    rg1616f = 9, // 4 bytes/pixel (half)
    rgba16161616f = 10, // 8 bytes/pixel (half)
    r32f = 11, // 4 bytes/pixel
    rg3232f = 12, // 8 bytes/pixel
    rgb323232f = 13, // 12 bytes/pixel
    rgba32323232f = 14, // 16 bytes/pixel
    jpeg_rgba8888 = 15,
    png_rgba8888 = 16,
    jpeg_dxt5 = 17,
    png_dxt5 = 18,
    bc6h = 19, // HDR — 16 bytes/block
    bc7 = 20, // 16 bytes/block
    ati2n = 21, // BC5U — 16 bytes/block
    ia88 = 22, // 2 bytes/pixel
    etc2 = 23, // 8 bytes/block
    etc2_eac = 24, // 16 bytes/block
    r11_eac = 25, // 8 bytes/block
    rg11_eac = 26, // 16 bytes/block
    ati1n = 27, // BC4U — 8 bytes/block
    bgra8888 = 28, // 4 bytes/pixel
    webp_rgba8888 = 29,
    webp_dxt5 = 30,
    _,

    /// Bytes per block for BCn/ETC formats, or bytes per pixel for uncompressed.
    pub fn blockSize(self: VTexFormat) u32 {
        return switch (self) {
            .dxt1 => 8,
            .dxt5 => 16,
            .i8 => 1,
            .rgba8888, .bgra8888 => 4,
            .r16, .ia88 => 2,
            .rg1616, .rg1616f => 4,
            .rgba16161616, .rgba16161616f => 8,
            .r16f => 2,
            .r32f => 4,
            .rg3232f => 8,
            .rgb323232f => 12,
            .rgba32323232f => 16,
            .bc6h, .bc7, .ati2n => 16,
            .etc2 => 8,
            .etc2_eac, .rg11_eac => 16,
            .r11_eac, .ati1n => 8,
            else => 1,
        };
    }

    /// Whether this format uses block compression (BCn or ETC).
    pub fn isBlockCompressed(self: VTexFormat) bool {
        return switch (self) {
            .dxt1, .dxt5, .bc6h, .bc7, .ati1n, .ati2n,
            .etc2, .etc2_eac, .r11_eac, .rg11_eac,
            => true,
            else => false,
        };
    }
};

/// Texture behavior flags.
pub const VTexFlags = packed struct(u16) {
    suggest_clamp_s: bool = false,
    suggest_clamp_t: bool = false,
    suggest_clamp_u: bool = false,
    no_lod: bool = false,
    cube_texture: bool = false,
    volume_texture: bool = false,
    texture_array: bool = false,
    panorama_dilate_color: bool = false,
    panorama_convert_ycocg_dxt5: bool = false,
    create_linear_api_texture: bool = false,
    _pad: u6 = 0,
};

/// Extra data block types.
pub const VTexExtraData = enum(u32) {
    unknown = 0,
    fallback_bits = 1,
    sheet = 2,
    metadata = 3,
    compressed_mip_size = 4,
    cubemap_radiance_sh = 5,
    _,
};

// ============================================================
// Texture Header
// ============================================================

pub const Texture = struct {
    version: u16 = 0,
    flags: VTexFlags = .{},
    reflectivity: [4]f32 = .{ 0, 0, 0, 0 },
    width: u16 = 0,
    height: u16 = 0,
    depth: u16 = 0,
    format: VTexFormat = .unknown,
    num_mip_levels: u8 = 0,
    picmip0_res: u32 = 0,

    /// Non-power-of-2 dimensions (from METADATA extra data).
    non_pow2_width: u16 = 0,
    non_pow2_height: u16 = 0,

    /// Compressed mip sizes (from COMPRESSED_MIP_SIZE extra data).
    compressed_mips: ?[]u32 = null,
    is_compressed_mips: bool = false,

    /// Data offset (past header + extra data).
    data_offset: u32 = 0,

    /// The raw texture data (all mip levels).
    data: ?[]const u8 = null,

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Texture {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Texture) void {
        if (self.compressed_mips) |mips| self.allocator.free(mips);
    }

    /// Actual display width (uses non-pow2 if available).
    pub fn actualWidth(self: *const Texture) u16 {
        return if (self.non_pow2_width > 0) self.non_pow2_width else self.width;
    }

    /// Actual display height (uses non-pow2 if available).
    pub fn actualHeight(self: *const Texture) u16 {
        return if (self.non_pow2_height > 0) self.non_pow2_height else self.height;
    }

    /// Parse texture header from a DATA block's raw bytes.
    pub fn readHeader(self: *Texture, block_data: []const u8) !void {
        if (block_data.len < 40) return error.InvalidTextureHeader;

        var r = BinaryReader.fromSlice(block_data, self.allocator);

        self.version = try r.readU16();
        if (self.version != 1) return error.UnsupportedTextureVersion;

        self.flags = @bitCast(try r.readU16());

        self.reflectivity[0] = try r.readF32();
        self.reflectivity[1] = try r.readF32();
        self.reflectivity[2] = try r.readF32();
        self.reflectivity[3] = try r.readF32();

        self.width = try r.readU16();
        self.height = try r.readU16();
        self.depth = try r.readU16();

        self.format = @enumFromInt(try r.readByte());
        self.num_mip_levels = try r.readByte();
        self.picmip0_res = try r.readU32();

        const extra_data_offset = try r.readU32();
        const extra_data_count = try r.readU32();

        // Parse extra data blocks
        if (extra_data_count > 0) {
            r.setPosition(@as(u64, extra_data_offset) + r.position() - 8);

            for (0..extra_data_count) |_| {
                const extra_type: VTexExtraData = @enumFromInt(try r.readU32());
                const extra_offset = try r.readU32();
                const extra_size = try r.readU32();

                const saved_pos = r.position();

                switch (extra_type) {
                    .metadata => {
                        // NonPow2 dimensions at offset +4 and +6
                        if (extra_size >= 8) {
                            r.setPosition(@as(u64, extra_offset) + saved_pos - 8);
                            r.skip(4); // skip first 4 bytes
                            self.non_pow2_width = try r.readU16();
                            self.non_pow2_height = try r.readU16();
                        }
                    },
                    .compressed_mip_size => {
                        r.setPosition(@as(u64, extra_offset) + saved_pos - 8);
                        const compression_flag = try r.readI32();
                        _ = try r.readI32(); // mipsOffset
                        const mip_count_raw = try r.readI32();
                        const mip_count: usize = @intCast(mip_count_raw);

                        if (mip_count > 0) {
                            var mips = try self.allocator.alloc(u32, mip_count);
                            for (0..mip_count) |i| {
                                mips[i] = @intCast(try r.readI32());
                            }
                            self.compressed_mips = mips;
                            self.is_compressed_mips = (compression_flag == 1);
                        }
                    },
                    else => {},
                }

                r.setPosition(saved_pos);
            }
        }

        // Data starts after the header
        self.data_offset = @intCast(r.position());
        if (block_data.len > self.data_offset) {
            self.data = block_data[self.data_offset..];
        }
    }

    /// Calculate buffer size for a specific mip level.
    pub fn calculateMipSize(self: *const Texture, mip_level: u32) usize {
        const mip_w = @max(1, @as(u32, self.width) >> @intCast(mip_level));
        const mip_h = @max(1, @as(u32, self.height) >> @intCast(mip_level));
        const mip_d = @max(1, @as(u32, self.depth) >> @intCast(mip_level));

        if (self.format.isBlockCompressed()) {
            // Align to 4-pixel blocks
            const aligned_w = (mip_w + 3) & ~@as(u32, 3);
            const aligned_h = (mip_h + 3) & ~@as(u32, 3);
            const num_blocks = (aligned_w * aligned_h) >> 4; // /16 pixels per block
            return @as(usize, num_blocks) * @as(usize, self.format.blockSize()) * @as(usize, mip_d);
        } else {
            return @as(usize, mip_w) * @as(usize, mip_h) * @as(usize, mip_d) * @as(usize, self.format.blockSize());
        }
    }

    /// Total size of all texture data across all mip levels.
    pub fn calculateTextureDataSize(self: *const Texture) usize {
        var total: usize = 0;
        for (0..self.num_mip_levels) |mip| {
            total += self.calculateMipSize(@intCast(mip));
        }
        return total;
    }

    /// Get the raw bytes for a specific mip level (level 0 = highest resolution).
    /// For compressed mips, returns the LZ4-compressed data; use getDecompressedMipData() instead.
    /// Get the raw bytes for a specific mip level (level 0 = highest resolution).
    /// Mips are stored smallest-first on disk: skip from (num_mip_levels-1) down to target.
    pub fn getMipData(self: *const Texture, mip_level: u32) ?[]const u8 {
        const tex_data = self.data orelse return null;

        // Skip mips stored before the target (smallest mips come first on disk)
        var offset: usize = 0;
        if (self.num_mip_levels > 1) {
            var j: u32 = self.num_mip_levels - 1;
            while (j > mip_level) : (j -= 1) {
                if (self.compressed_mips) |mips| {
                    if (j < mips.len) {
                        const compressed_size = mips[j];
                        const calc_size = self.calculateMipSize(j);
                        offset += if (calc_size > compressed_size) compressed_size else calc_size;
                    } else {
                        offset += self.calculateMipSize(j);
                    }
                } else {
                    offset += self.calculateMipSize(j);
                }
                if (j == 0) break;
            }
        }

        // Size of the target mip on disk
        const size = if (self.compressed_mips) |mips| blk: {
            if (mip_level < mips.len) {
                const compressed_size = mips[mip_level];
                const calc_size = self.calculateMipSize(mip_level);
                break :blk if (calc_size > compressed_size) compressed_size else calc_size;
            }
            break :blk self.calculateMipSize(mip_level);
        } else self.calculateMipSize(mip_level);

        if (offset + size > tex_data.len) return null;
        return tex_data[offset..][0..size];
    }

    /// Decode the highest resolution mip level to RGBA8888.
    /// Returns width * height * 4 bytes (RGBA). Caller owns the memory.
    pub fn decodeRGBA(self: *const Texture) ![]u8 {
        return self.decodeMipRGBA(0);
    }

    /// Decode a specific mip level to RGBA8888.
    pub fn decodeMipRGBA(self: *const Texture, mip_level: u32) ![]u8 {
        const raw_mip = self.getMipData(mip_level) orelse return error.NoTextureData;
        const mip_w = @max(1, @as(u32, self.width) >> @intCast(mip_level));
        const mip_h = @max(1, @as(u32, self.height) >> @intCast(mip_level));

        // LZ4 decompress if needed
        const expected_size = self.calculateMipSize(mip_level);
        const mip_data = if (self.is_compressed_mips and raw_mip.len < expected_size and raw_mip.len > 0) blk: {
            const lz4 = @import("lz4.zig");
            const buf = self.allocator.alloc(u8, expected_size) catch return error.NoTextureData;
            _ = lz4.decompress(raw_mip, buf) catch {
                self.allocator.free(buf);
                return error.NoTextureData;
            };
            break :blk buf;
        } else raw_mip;
        defer if (self.is_compressed_mips and mip_data.ptr != raw_mip.ptr) self.allocator.free(mip_data);

        const output_size = @as(usize, mip_w) * @as(usize, mip_h) * 4;
        const output = try self.allocator.alloc(u8, output_size);
        errdefer self.allocator.free(output);

        const decode = @import("texture_decode.zig");

        switch (self.format) {
            .dxt1 => decode.decodeDXT1(mip_data, mip_w, mip_h, output),
            .dxt5 => decode.decodeDXT5(mip_data, mip_w, mip_h, output),
            .bc7 => try decode.decodeBC7(mip_data, mip_w, mip_h, output),
            .rgba8888 => @memcpy(output, mip_data[0..output_size]),
            .bgra8888 => decode.decodeBGRA8888(mip_data, output),
            .i8 => decode.decodeI8(mip_data, output),
            .ia88 => decode.decodeIA88(mip_data, output),
            .ati1n => decode.decodeBC4(mip_data, mip_w, mip_h, output),
            .ati2n => decode.decodeBC5(mip_data, mip_w, mip_h, output),
            else => return error.UnsupportedTextureFormat,
        }

        return output;
    }
};

// ============================================================
// Tests
// ============================================================

test "VTexFormat block sizes" {
    try std.testing.expectEqual(@as(u32, 8), VTexFormat.dxt1.blockSize());
    try std.testing.expectEqual(@as(u32, 16), VTexFormat.dxt5.blockSize());
    try std.testing.expectEqual(@as(u32, 16), VTexFormat.bc7.blockSize());
    try std.testing.expectEqual(@as(u32, 4), VTexFormat.rgba8888.blockSize());
    try std.testing.expectEqual(@as(u32, 1), VTexFormat.i8.blockSize());
}

test "VTexFormat block compression detection" {
    try std.testing.expect(VTexFormat.dxt1.isBlockCompressed());
    try std.testing.expect(VTexFormat.bc7.isBlockCompressed());
    try std.testing.expect(!VTexFormat.rgba8888.isBlockCompressed());
    try std.testing.expect(!VTexFormat.i8.isBlockCompressed());
}

test "Texture mip size calculation" {
    var tex = Texture.init(std.testing.allocator);
    defer tex.deinit();

    tex.width = 256;
    tex.height = 256;
    tex.depth = 1;
    tex.format = .dxt5;
    tex.num_mip_levels = 9;

    // 256x256 DXT5: (256*256)/16 blocks * 16 bytes = 65536
    try std.testing.expectEqual(@as(usize, 65536), tex.calculateMipSize(0));
    // 128x128: (128*128)/16 * 16 = 16384
    try std.testing.expectEqual(@as(usize, 16384), tex.calculateMipSize(1));
    // 64x64: (64*64)/16 * 16 = 4096
    try std.testing.expectEqual(@as(usize, 4096), tex.calculateMipSize(2));
}

test "Texture mip size RGBA" {
    var tex = Texture.init(std.testing.allocator);
    defer tex.deinit();

    tex.width = 512;
    tex.height = 512;
    tex.depth = 1;
    tex.format = .rgba8888;
    tex.num_mip_levels = 1;

    // 512x512 * 4 bytes = 1048576
    try std.testing.expectEqual(@as(usize, 1048576), tex.calculateMipSize(0));
}

test "Texture header parse" {
    // Build a minimal 40-byte texture header
    var buf: [44]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();

    try w.writeInt(u16, 1, .little); // version
    try w.writeInt(u16, 0, .little); // flags
    try w.writeInt(u32, 0, .little); // reflectivity x
    try w.writeInt(u32, 0, .little); // reflectivity y
    try w.writeInt(u32, 0, .little); // reflectivity z
    try w.writeInt(u32, 0, .little); // reflectivity w
    try w.writeInt(u16, 256, .little); // width
    try w.writeInt(u16, 128, .little); // height
    try w.writeInt(u16, 1, .little); // depth
    try w.writeByte(4); // format = RGBA8888
    try w.writeByte(1); // num_mip_levels
    try w.writeInt(u32, 256, .little); // picmip0_res
    try w.writeInt(u32, 8, .little); // extra_data_offset
    try w.writeInt(u32, 0, .little); // extra_data_count

    var tex = Texture.init(std.testing.allocator);
    defer tex.deinit();

    try tex.readHeader(&buf);

    try std.testing.expectEqual(@as(u16, 256), tex.width);
    try std.testing.expectEqual(@as(u16, 128), tex.height);
    try std.testing.expectEqual(VTexFormat.rgba8888, tex.format);
    try std.testing.expectEqual(@as(u8, 1), tex.num_mip_levels);
}
