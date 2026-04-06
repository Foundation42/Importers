//! TGA (Truevision TARGA) image decoder.
//!
//! Decodes uncompressed and RLE-compressed TGA files (types 2 and 10)
//! with 24-bit RGB and 32-bit RGBA pixel formats. Output is always
//! RGBA8888 with correct vertical orientation.

const std = @import("std");

pub const TgaImage = struct {
    width: u32,
    height: u32,
    /// RGBA8888 pixel data (4 bytes per pixel), top-to-bottom, left-to-right.
    pixels: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *TgaImage) void {
        self.allocator.free(self.pixels);
    }
};

/// TGA image types we support.
const ImageType = enum(u8) {
    uncompressed_rgb = 2,
    rle_rgb = 10,
    _,
};

/// Decode a TGA file from raw bytes. Returns RGBA8888 pixels.
pub fn decode(allocator: std.mem.Allocator, data: []const u8) !TgaImage {
    if (data.len < 18) return error.FileTooShort;

    // TGA header (18 bytes)
    const id_length = data[0];
    //const colormap_type = data[1];
    const image_type: ImageType = @enumFromInt(data[2]);
    // Skip colormap spec (bytes 3-7)
    // Image spec (bytes 8-17)
    //const x_origin = std.mem.readInt(u16, data[8..10], .little);
    //const y_origin = std.mem.readInt(u16, data[10..12], .little);
    const width: u32 = std.mem.readInt(u16, data[12..14], .little);
    const height: u32 = std.mem.readInt(u16, data[14..16], .little);
    const bpp = data[16]; // bits per pixel
    const descriptor = data[17];

    if (width == 0 or height == 0) return error.InvalidDimensions;
    if (bpp != 24 and bpp != 32) return error.UnsupportedBpp;

    const bytes_per_pixel = @as(u32, bpp) / 8;
    const top_origin = (descriptor & 0x20) != 0; // bit 5 = top-down

    // Skip image ID
    const pixel_start: usize = 18 + @as(usize, id_length);
    if (pixel_start > data.len) return error.FileTooShort;
    const pixel_data = data[pixel_start..];

    const total_pixels = width * height;
    const pixels = try allocator.alloc(u8, total_pixels * 4);
    errdefer allocator.free(pixels);

    switch (image_type) {
        .uncompressed_rgb => {
            const needed = total_pixels * bytes_per_pixel;
            if (pixel_data.len < needed) return error.FileTooShort;
            decodeRaw(pixel_data, pixels, total_pixels, bytes_per_pixel);
        },
        .rle_rgb => {
            try decodeRle(pixel_data, pixels, total_pixels, bytes_per_pixel);
        },
        _ => return error.UnsupportedImageType,
    }

    // Flip vertically if origin is bottom-left (default TGA orientation)
    if (!top_origin) {
        flipVertical(pixels, width, height);
    }

    return TgaImage{
        .width = width,
        .height = height,
        .pixels = pixels,
        .allocator = allocator,
    };
}

/// Decode uncompressed BGR(A) -> RGBA.
fn decodeRaw(src: []const u8, dst: []u8, pixel_count: u32, bpp: u32) void {
    var si: usize = 0;
    var di: usize = 0;
    for (0..pixel_count) |_| {
        // TGA stores BGR(A)
        dst[di + 0] = src[si + 2]; // R
        dst[di + 1] = src[si + 1]; // G
        dst[di + 2] = src[si + 0]; // B
        dst[di + 3] = if (bpp == 4) src[si + 3] else 255; // A
        si += bpp;
        di += 4;
    }
}

/// Decode RLE-compressed BGR(A) -> RGBA.
fn decodeRle(src: []const u8, dst: []u8, pixel_count: u32, bpp: u32) !void {
    var si: usize = 0;
    var pixels_decoded: u32 = 0;

    while (pixels_decoded < pixel_count) {
        if (si >= src.len) return error.UnexpectedEof;
        const packet = src[si];
        si += 1;

        const count: u32 = @as(u32, packet & 0x7F) + 1;
        if (pixels_decoded + count > pixel_count) return error.InvalidRleData;

        if (packet & 0x80 != 0) {
            // RLE packet: one pixel repeated `count` times
            if (si + bpp > src.len) return error.UnexpectedEof;
            const r = src[si + 2];
            const g = src[si + 1];
            const b = src[si + 0];
            const a: u8 = if (bpp == 4) src[si + 3] else 255;
            si += bpp;

            for (0..count) |_| {
                const di = pixels_decoded * 4;
                dst[di + 0] = r;
                dst[di + 1] = g;
                dst[di + 2] = b;
                dst[di + 3] = a;
                pixels_decoded += 1;
            }
        } else {
            // Raw packet: `count` literal pixels
            if (si + count * bpp > src.len) return error.UnexpectedEof;
            for (0..count) |_| {
                const di = pixels_decoded * 4;
                dst[di + 0] = src[si + 2];
                dst[di + 1] = src[si + 1];
                dst[di + 2] = src[si + 0];
                dst[di + 3] = if (bpp == 4) src[si + 3] else 255;
                si += bpp;
                pixels_decoded += 1;
            }
        }
    }
}

/// Flip RGBA image vertically in-place.
fn flipVertical(pixels: []u8, width: u32, height: u32) void {
    const row_bytes = width * 4;
    var top: usize = 0;
    var bottom: usize = (@as(usize, height) - 1) * row_bytes;

    while (top < bottom) {
        for (0..row_bytes) |i| {
            const tmp = pixels[top + i];
            pixels[top + i] = pixels[bottom + i];
            pixels[bottom + i] = tmp;
        }
        top += row_bytes;
        bottom -= row_bytes;
    }
}

// ============================================================================
// Tests
// ============================================================================

test "decode uncompressed 24-bit TGA" {
    // Minimal 2x2 uncompressed 24-bit TGA, bottom-up origin
    var data: [18 + 12]u8 = undefined;
    @memset(&data, 0);
    data[2] = 2; // uncompressed RGB
    std.mem.writeInt(u16, data[12..14], 2, .little); // width
    std.mem.writeInt(u16, data[14..16], 2, .little); // height
    data[16] = 24; // bpp
    data[17] = 0; // bottom-up origin

    // Pixels in BGR order, bottom row first
    // Bottom-left: red (B=0, G=0, R=255)
    data[18] = 0;
    data[19] = 0;
    data[20] = 255;
    // Bottom-right: green
    data[21] = 0;
    data[22] = 255;
    data[23] = 0;
    // Top-left: blue
    data[24] = 255;
    data[25] = 0;
    data[26] = 0;
    // Top-right: white
    data[27] = 255;
    data[28] = 255;
    data[29] = 255;

    var img = try decode(std.testing.allocator, &data);
    defer img.deinit();

    try std.testing.expectEqual(@as(u32, 2), img.width);
    try std.testing.expectEqual(@as(u32, 2), img.height);

    // After vertical flip, top-left should be blue (was bottom row: top-left)
    // Top row = what was the bottom row in TGA
    // Wait: bottom-up means row 0 in file = bottom of image.
    // After flip: pixel[0] = top-left = what was top-left in image = TGA row 1, col 0 = blue
    try std.testing.expectEqual(@as(u8, 0), img.pixels[0]); // R (blue pixel)
    try std.testing.expectEqual(@as(u8, 0), img.pixels[1]); // G
    try std.testing.expectEqual(@as(u8, 255), img.pixels[2]); // B
    try std.testing.expectEqual(@as(u8, 255), img.pixels[3]); // A
}

test "decode RLE 32-bit TGA" {
    // Minimal 3x1 RLE 32-bit TGA, top-down origin
    // RLE packet: repeat red 3 times
    var data: [18 + 5]u8 = undefined;
    @memset(&data, 0);
    data[2] = 10; // RLE RGB
    std.mem.writeInt(u16, data[12..14], 3, .little); // width
    std.mem.writeInt(u16, data[14..16], 1, .little); // height
    data[16] = 32; // bpp
    data[17] = 0x20; // top-down origin

    // RLE packet: 0x82 = run of 3 (0x80 | (3-1))
    data[18] = 0x82;
    data[19] = 0; // B
    data[20] = 0; // G
    data[21] = 255; // R
    data[22] = 128; // A

    var img = try decode(std.testing.allocator, &data);
    defer img.deinit();

    try std.testing.expectEqual(@as(u32, 3), img.width);

    // All 3 pixels should be red with alpha=128
    for (0..3) |i| {
        try std.testing.expectEqual(@as(u8, 255), img.pixels[i * 4 + 0]); // R
        try std.testing.expectEqual(@as(u8, 0), img.pixels[i * 4 + 1]); // G
        try std.testing.expectEqual(@as(u8, 0), img.pixels[i * 4 + 2]); // B
        try std.testing.expectEqual(@as(u8, 128), img.pixels[i * 4 + 3]); // A
    }
}
