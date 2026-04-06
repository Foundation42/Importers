const std = @import("std");
const kv3 = @import("kv3.zig");
const KVValue = kv3.KVValue;
const KVObject = kv3.KVObject;
const KVArray = kv3.KVArray;
const lz4 = @import("lz4.zig");
const zstd = std.compress.zstd;
const KVFlag = kv3.KVFlag;
const KV3NodeType = kv3.KV3NodeType;

/// KV3 version signatures.
pub const MAGIC0: u32 = 0x03564B56; // VKV3 (legacy)
pub const MAGIC1: u32 = 0x4B563301; // KV3\x01
pub const MAGIC2: u32 = 0x4B563302; // KV3\x02
pub const MAGIC3: u32 = 0x4B563303; // KV3\x03
pub const MAGIC4: u32 = 0x4B563304; // KV3\x04
pub const MAGIC5: u32 = 0x4B563305; // KV3\x05

pub fn isBinaryKV3(magic: u32) bool {
    return magic == MAGIC0 or magic == MAGIC1 or magic == MAGIC2 or
        magic == MAGIC3 or magic == MAGIC4 or magic == MAGIC5;
}

/// Buffer slices for the different byte-width segments.
const Buffers = struct {
    bytes1: []const u8 = &.{},
    bytes2: []const u8 = &.{},
    bytes4: []const u8 = &.{},
    bytes8: []const u8 = &.{},
};

/// Parsing context that tracks positions through all buffer segments.
const Context = struct {
    version: i32,
    types: []const u8 = &.{},
    object_lengths: []const u8 = &.{},
    binary_blobs: []const u8 = &.{},
    binary_blob_lengths: []const u8 = &.{},
    strings: [][]const u8 = &.{},
    buffer: Buffers = .{},
    auxiliary_buffer: Buffers = .{},
    allocator: std.mem.Allocator,
};

/// Parsed KV3 document.
pub const KV3Document = struct {
    root: KVValue,
    format_guid: [16]u8,
    allocator: std.mem.Allocator,
    /// Owned memory that must be freed.
    owned_buffers: std.ArrayList([]u8),
    owned_strings: ?[][]const u8 = null,

    pub fn deinit(self: *KV3Document) void {
        @constCast(&self.root).deinit(self.allocator);
        for (self.owned_buffers.items) |buf| {
            self.allocator.free(buf);
        }
        self.owned_buffers.deinit();
        if (self.owned_strings) |strings| {
            self.allocator.free(strings);
        }
    }
};

/// Decode a BinaryKV3 block from raw bytes.
pub fn decode(allocator: std.mem.Allocator, data: []const u8) !KV3Document {
    if (data.len < 4) return error.InvalidKV3Data;

    const magic = std.mem.readInt(u32, data[0..4], .little);

    if (magic == MAGIC0) {
        return error.LegacyKV3NotSupported; // TODO: version 0 support
    }

    const version: i32 = @intCast(magic & 0xFF);
    const base_magic = magic & 0xFFFFFF00;

    if (base_magic != 0x4B563300) return error.InvalidKV3Magic;
    if (version < 1 or version > 5) return error.UnsupportedKV3Version;

    return decodeVersioned(allocator, data, version);
}

fn decodeVersioned(allocator: std.mem.Allocator, data: []const u8, version: i32) !KV3Document {
    var pos: usize = 4; // past magic

    // Format GUID (16 bytes)
    if (pos + 16 > data.len) return error.UnexpectedEof;
    var format_guid: [16]u8 = undefined;
    @memcpy(&format_guid, data[pos..][0..16]);
    pos += 16;

    // Compression method
    const compression_method = readU32(data, &pos) orelse return error.UnexpectedEof;

    var count_bytes1: i32 = 0;
    var count_bytes2: i32 = 0;
    var count_bytes4: i32 = 0;
    var count_bytes8: i32 = 0;
    var count_types: i32 = 0;
    var size_uncompressed_total: i32 = 0;
    var size_compressed_total: i32 = 0;
    var count_blocks: i32 = 0;
    var size_binary_blobs_bytes: i32 = 0;

    if (version == 1) {
        count_bytes1 = readI32(data, &pos) orelse return error.UnexpectedEof;
        count_bytes4 = readI32(data, &pos) orelse return error.UnexpectedEof;
        count_bytes8 = readI32(data, &pos) orelse return error.UnexpectedEof;
        size_uncompressed_total = readI32(data, &pos) orelse return error.UnexpectedEof;
        size_compressed_total = @intCast(data.len - pos);
    } else {
        _ = readU16(data, &pos) orelse return error.UnexpectedEof; // compressionDictionaryId
        _ = readU16(data, &pos) orelse return error.UnexpectedEof; // compressionFrameSize
        count_bytes1 = readI32(data, &pos) orelse return error.UnexpectedEof;
        count_bytes4 = readI32(data, &pos) orelse return error.UnexpectedEof;
        count_bytes8 = readI32(data, &pos) orelse return error.UnexpectedEof;
        count_types = readI32(data, &pos) orelse return error.UnexpectedEof;
        _ = readU16(data, &pos) orelse return error.UnexpectedEof; // count_objects
        _ = readU16(data, &pos) orelse return error.UnexpectedEof; // count_arrays
        size_uncompressed_total = readI32(data, &pos) orelse return error.UnexpectedEof;
        size_compressed_total = readI32(data, &pos) orelse return error.UnexpectedEof;
        count_blocks = readI32(data, &pos) orelse return error.UnexpectedEof;
        size_binary_blobs_bytes = readI32(data, &pos) orelse return error.UnexpectedEof;
    }

    if (version >= 4) {
        count_bytes2 = readI32(data, &pos) orelse return error.UnexpectedEof;
        _ = readI32(data, &pos) orelse return error.UnexpectedEof; // size_block_compressed_sizes_bytes
    }

    var size_uncompressed_buffer1: i32 = 0;
    var size_compressed_buffer1: i32 = 0;
    var size_uncompressed_buffer2: i32 = 0;
    var size_compressed_buffer2: i32 = 0;
    var count_bytes1_buffer2: i32 = 0;
    var count_bytes2_buffer2: i32 = 0;
    var count_bytes4_buffer2: i32 = 0;
    var count_bytes8_buffer2: i32 = 0;
    var count_objects_buffer2: i32 = 0;

    if (version >= 5) {
        size_uncompressed_buffer1 = readI32(data, &pos) orelse return error.UnexpectedEof;
        size_compressed_buffer1 = readI32(data, &pos) orelse return error.UnexpectedEof;
        size_uncompressed_buffer2 = readI32(data, &pos) orelse return error.UnexpectedEof;
        size_compressed_buffer2 = readI32(data, &pos) orelse return error.UnexpectedEof;
        count_bytes1_buffer2 = readI32(data, &pos) orelse return error.UnexpectedEof;
        count_bytes2_buffer2 = readI32(data, &pos) orelse return error.UnexpectedEof;
        count_bytes4_buffer2 = readI32(data, &pos) orelse return error.UnexpectedEof;
        count_bytes8_buffer2 = readI32(data, &pos) orelse return error.UnexpectedEof;
        _ = readI32(data, &pos) orelse return error.UnexpectedEof; // unk13
        count_objects_buffer2 = readI32(data, &pos) orelse return error.UnexpectedEof;
        _ = readI32(data, &pos) orelse return error.UnexpectedEof; // countArrays_buffer2
        _ = readI32(data, &pos) orelse return error.UnexpectedEof; // unk16
    } else {
        size_compressed_buffer1 = size_compressed_total;
        size_uncompressed_buffer1 = size_uncompressed_total;
    }

    // Track owned memory
    var owned_buffers = std.ArrayList([]u8).init(allocator);
    errdefer {
        for (owned_buffers.items) |buf| allocator.free(buf);
        owned_buffers.deinit();
    }

    // Decompress buffer 1
    var buffer1: []u8 = undefined;
    const buf1_alloc_size: usize = @intCast(
        if (version < 5 and compression_method == 2)
            size_uncompressed_buffer1 + size_binary_blobs_bytes
        else
            size_uncompressed_buffer1,
    );

    if (compression_method == 0) {
        // Uncompressed
        const size: usize = @intCast(size_uncompressed_buffer1);
        if (pos + size > data.len) return error.UnexpectedEof;
        buffer1 = try allocator.alloc(u8, buf1_alloc_size);
        try owned_buffers.append(buffer1);
        @memcpy(buffer1[0..size], data[pos..][0..size]);
        pos += size;
    } else if (compression_method == 1) {
        // LZ4
        const compressed_size: usize = @intCast(size_compressed_buffer1);
        if (pos + compressed_size > data.len) return error.UnexpectedEof;
        buffer1 = try allocator.alloc(u8, buf1_alloc_size);
        try owned_buffers.append(buffer1);
        const out_size: usize = @intCast(size_uncompressed_buffer1);
        const written = lz4.decompress(data[pos..][0..compressed_size], buffer1[0..out_size]) catch return error.DecompressionFailed;
        if (written != out_size) return error.DecompressionSizeMismatch;
        pos += compressed_size;
    } else if (compression_method == 2) {
        // ZSTD
        const compressed_size: usize = @intCast(size_compressed_buffer1);
        if (pos + compressed_size > data.len) return error.UnexpectedEof;

        var out_size: usize = undefined;
        if (version < 5) {
            // Pre-v5: buffer1 + binary blobs compressed together
            out_size = @intCast(size_uncompressed_buffer1 + size_binary_blobs_bytes);
        } else {
            out_size = @intCast(size_uncompressed_buffer1);
        }

        buffer1 = try allocator.alloc(u8, buf1_alloc_size);
        try owned_buffers.append(buffer1);
        _ = zstd.decompress.decode(buffer1[0..out_size], data[pos..][0..compressed_size], false) catch return error.DecompressionFailed;
        pos += compressed_size;
    } else {
        return error.UnknownCompressionMethod;
    }

    const buf1_span = buffer1[0..@intCast(size_uncompressed_buffer1)];

    // Slice buffer 1 into byte-width segments
    var ctx = Context{
        .version = version,
        .allocator = allocator,
    };

    var offset: usize = 0;

    var buffer1_bufs = Buffers{};

    if (count_bytes1 > 0) {
        const end = offset + @as(usize, @intCast(count_bytes1));
        buffer1_bufs.bytes1 = buf1_span[offset..end];
        offset = end;
    }

    if (count_bytes2 > 0) {
        align_offset(&offset, 2);
        const end = offset + @as(usize, @intCast(count_bytes2)) * 2;
        buffer1_bufs.bytes2 = buf1_span[offset..end];
        offset = end;
    }

    if (count_bytes4 > 0) {
        align_offset(&offset, 4);
        const end = offset + @as(usize, @intCast(count_bytes4)) * 4;
        buffer1_bufs.bytes4 = buf1_span[offset..end];
        offset = end;
    }

    if (count_bytes8 > 0) {
        align_offset(&offset, 8);
        const end = offset + @as(usize, @intCast(count_bytes8)) * 8;
        buffer1_bufs.bytes8 = buf1_span[offset..end];
        offset = end;
    } else if (version < 5) {
        align_offset(&offset, 8);
    }

    // Read string count (first i32 from bytes4)
    if (buffer1_bufs.bytes4.len < 4) return error.InvalidKV3Data;
    const count_strings: usize = @intCast(std.mem.readInt(i32, buffer1_bufs.bytes4[0..4], .little));
    buffer1_bufs.bytes4 = buffer1_bufs.bytes4[4..];

    // Read strings
    var strings = try allocator.alloc([]const u8, count_strings);
    errdefer allocator.free(strings);

    if (version >= 5) {
        // v5: strings are in bytes1 of buffer1 (auxiliary buffer)
        var str_buf = buffer1_bufs.bytes1;
        for (0..count_strings) |i| {
            const null_pos = std.mem.indexOfScalar(u8, str_buf, 0) orelse str_buf.len;
            strings[i] = str_buf[0..null_pos];
            if (null_pos < str_buf.len) {
                str_buf = str_buf[null_pos + 1 ..];
            }
        }
        ctx.auxiliary_buffer = buffer1_bufs;
    } else {
        // v1-4: strings follow the byte segments
        ctx.buffer = buffer1_bufs;
        var str_data = buf1_span[offset..];
        for (0..count_strings) |i| {
            const null_pos = std.mem.indexOfScalar(u8, str_data, 0) orelse str_data.len;
            strings[i] = str_data[0..null_pos];
            offset += null_pos + 1;
            if (null_pos < str_data.len) {
                str_data = str_data[null_pos + 1 ..];
            }
        }

        // Types (v1-4: follow strings in buffer1)
        // After strings, the remaining buffer contains types, then either:
        //   - a 4-byte trailer (0xFFEEDD00) if no blocks, or
        //   - binary blob lengths (countBlocks * 4) + trailer (4) if blocks > 0
        if (count_blocks == 0) {
            // Types are everything from offset to (end - 4 for trailer)
            const remaining = buf1_span[offset..];
            if (remaining.len < 4) return error.InvalidKV3Data;
            ctx.types = remaining[0 .. remaining.len - 4];
            // Validate trailer
            const trailer = std.mem.readInt(u32, remaining[remaining.len - 4 ..][0..4], .little);
            if (trailer != 0xFFEEDD00) return error.InvalidKV3Trailer;
        } else {
            // Types are everything from offset to start of binary blob lengths
            // Binary blob lengths = countBlocks * 4 bytes + 4 byte trailer (0xFFEEDD00)
            const blob_meta_size = @as(usize, @intCast(count_blocks)) * 4 + 4;
            const remaining = buf1_span[offset..];
            if (remaining.len < blob_meta_size) return error.InvalidKV3Data;
            ctx.types = remaining[0 .. remaining.len - blob_meta_size];
            const blob_meta = remaining[remaining.len - blob_meta_size ..];
            ctx.binary_blob_lengths = blob_meta[0 .. @as(usize, @intCast(count_blocks)) * 4];
            // Validate trailer after blob lengths
            const trailer = std.mem.readInt(u32, blob_meta[@as(usize, @intCast(count_blocks)) * 4 ..][0..4], .little);
            if (trailer != 0xFFEEDD00) return error.InvalidKV3Trailer;
        }
    }

    ctx.strings = strings;

    // Buffer 2 (v5 only)
    if (version >= 5) {
        const size2: usize = @intCast(size_uncompressed_buffer2);
        const buffer2 = try allocator.alloc(u8, size2);
        try owned_buffers.append(buffer2);

        if (compression_method == 0) {
            if (pos + size2 > data.len) return error.UnexpectedEof;
            @memcpy(buffer2, data[pos..][0..size2]);
            pos += size2;
        } else if (compression_method == 1) {
            const compressed_size2: usize = @intCast(size_compressed_buffer2);
            if (pos + compressed_size2 > data.len) return error.UnexpectedEof;
            const written = lz4.decompress(data[pos..][0..compressed_size2], buffer2[0..size2]) catch return error.DecompressionFailed;
            if (written != size2) return error.DecompressionSizeMismatch;
            pos += compressed_size2;
        } else if (compression_method == 2) {
            const compressed_size2: usize = @intCast(size_compressed_buffer2);
            if (pos + compressed_size2 > data.len) return error.UnexpectedEof;
            _ = zstd.decompress.decode(buffer2[0..size2], data[pos..][0..compressed_size2], false) catch return error.DecompressionFailed;
            pos += compressed_size2;
        } else {
            return error.UnknownCompressionMethod;
        }

        {

            var buffer2_bufs = Buffers{};
            var off2: usize = 0;

            // Object lengths first
            const obj_len_bytes = @as(usize, @intCast(count_objects_buffer2)) * 4;
            ctx.object_lengths = buffer2[0..obj_len_bytes];
            off2 = obj_len_bytes;

            if (count_bytes1_buffer2 > 0) {
                const end = off2 + @as(usize, @intCast(count_bytes1_buffer2));
                buffer2_bufs.bytes1 = buffer2[off2..end];
                off2 = end;
            }
            if (count_bytes2_buffer2 > 0) {
                align_offset(&off2, 2);
                const end = off2 + @as(usize, @intCast(count_bytes2_buffer2)) * 2;
                buffer2_bufs.bytes2 = buffer2[off2..end];
                off2 = end;
            }
            if (count_bytes4_buffer2 > 0) {
                align_offset(&off2, 4);
                const end = off2 + @as(usize, @intCast(count_bytes4_buffer2)) * 4;
                buffer2_bufs.bytes4 = buffer2[off2..end];
                off2 = end;
            }
            if (count_bytes8_buffer2 > 0) {
                align_offset(&off2, 8);
                const end = off2 + @as(usize, @intCast(count_bytes8_buffer2)) * 8;
                buffer2_bufs.bytes8 = buffer2[off2..end];
                off2 = end;
            }

            // Types in v5 are in buffer2
            ctx.types = buffer2[off2..][0..@intCast(count_types)];
            off2 += @intCast(count_types);

            if (count_blocks == 0) {
                if (off2 + 4 <= buffer2.len) {
                    const trailer = std.mem.readInt(u32, buffer2[off2..][0..4], .little);
                    if (trailer != 0xFFEEDD00) return error.InvalidKV3Trailer;
                }
            } else {
                const remaining = buffer2[off2..];
                const blob_lengths_size = @as(usize, @intCast(count_blocks)) * 4;
                ctx.binary_blob_lengths = remaining[0..blob_lengths_size];
                const trailer = std.mem.readInt(u32, remaining[blob_lengths_size..][0..4], .little);
                if (trailer != 0xFFEEDD00) return error.InvalidKV3Trailer;
            }

            ctx.buffer = buffer2_bufs;
        }
    }

    // Binary blobs
    if (count_blocks > 0) {
        const blobs_size: usize = @intCast(size_binary_blobs_bytes);

        if (compression_method == 0) {
            if (pos + blobs_size > data.len) return error.UnexpectedEof;
            const blobs = try allocator.alloc(u8, blobs_size);
            try owned_buffers.append(blobs);
            @memcpy(blobs, data[pos..][0..blobs_size]);
            pos += blobs_size;
            ctx.binary_blobs = blobs;
        } else if (compression_method == 2 and version < 5) {
            // Pre-v5 ZSTD: blobs were decompressed with buffer1 above
            // They sit at offset size_uncompressed_buffer1 in buffer1
            const blob_start: usize = @intCast(size_uncompressed_buffer1);
            ctx.binary_blobs = buffer1[blob_start..][0..blobs_size];
        } else if (compression_method == 2 and version >= 5) {
            // v5 ZSTD: blobs compressed separately
            const compressed_blobs_size: usize = @intCast(size_compressed_total - size_compressed_buffer1 - size_compressed_buffer2);
            if (pos + compressed_blobs_size > data.len) return error.UnexpectedEof;
            const blobs = try allocator.alloc(u8, blobs_size);
            try owned_buffers.append(blobs);
            _ = zstd.decompress.decode(blobs[0..blobs_size], data[pos..][0..compressed_blobs_size], false) catch return error.DecompressionFailed;
            pos += compressed_blobs_size;
            ctx.binary_blobs = blobs;
        } else if (compression_method == 1) {
            // LZ4 blobs: compressed block sizes stored in bufferWithBinaryBlobSizes
            // For now, read as uncompressed (TODO: LZ4 chain decode for blobs)
            if (pos + blobs_size > data.len) return error.UnexpectedEof;
            const blobs = try allocator.alloc(u8, blobs_size);
            try owned_buffers.append(blobs);
            // LZ4 blob decompression uses chain decoder with frame sizes
            // This is a simplified path — real LZ4 blobs need frame-by-frame decode
            const written = lz4.decompress(data[pos..][0..@min(data.len - pos, blobs_size * 2)], blobs[0..blobs_size]) catch return error.DecompressionFailed;
            _ = written;
            ctx.binary_blobs = blobs;
        }

        // Trailer after blobs
        if (pos + 4 <= data.len) {
            const trailer = std.mem.readInt(u32, data[pos..][0..4], .little);
            if (trailer != 0xFFEEDD00) return error.InvalidKV3Trailer;
            pos += 4;
        }
    }

    // Parse root value
    const type_and_flag = readType(&ctx);
    const root = try readBinaryValue(&ctx, type_and_flag[0], type_and_flag[1]);

    return KV3Document{
        .root = root,
        .format_guid = format_guid,
        .allocator = allocator,
        .owned_buffers = owned_buffers,
        .owned_strings = strings,
    };
}

fn readType(ctx: *Context) struct { KV3NodeType, KVFlag } {
    if (ctx.types.len == 0) return .{ @enumFromInt(0), .none };

    var databyte = ctx.types[0];
    ctx.types = ctx.types[1..];
    var flag_info: KVFlag = .none;

    if (ctx.version >= 3) {
        if ((databyte & 0x80) > 0) {
            databyte &= 0x3F;
            if (ctx.types.len > 0) {
                flag_info = @enumFromInt(ctx.types[0]);
                ctx.types = ctx.types[1..];
            }
        }
    } else if ((databyte & 0x80) > 0) {
        databyte &= 0x7F;
        if (ctx.types.len > 0) {
            var raw_flag = ctx.types[0];
            ctx.types = ctx.types[1..];

            // Multiline string flag
            if ((raw_flag & 4) > 0) {
                raw_flag ^= 4;
            }

            flag_info = switch (raw_flag) {
                0 => .none,
                1 => .resource,
                2 => .resource_name,
                8 => .panorama,
                16 => .sound_event,
                32 => .sub_class,
                else => .none,
            };
        }
    }

    return .{ @enumFromInt(databyte), flag_info };
}

const KV3Error = error{
    InvalidKV3Data,
    OutOfMemory,
    UnknownKV3NodeType,
};

fn readBinaryValue(ctx: *Context, datatype: KV3NodeType, flag_info: KVFlag) KV3Error!KVValue {
    _ = flag_info;
    return readValue(ctx, datatype);
}

fn readValue(ctx: *Context, datatype: KV3NodeType) KV3Error!KVValue {
    switch (datatype) {
        // Hardcoded values
        .null_value => return .null_value,
        .boolean_true => return .{ .boolean = true },
        .boolean_false => return .{ .boolean = false },
        .int64_zero => return .{ .int64 = 0 },
        .int64_one => return .{ .int64 = 1 },
        .double_zero => return .{ .float64 = 0.0 },
        .double_one => return .{ .float64 = 1.0 },

        // 1-byte values
        .boolean => {
            const val = consumeBytes1(ctx, 1);
            return .{ .boolean = val[0] == 1 };
        },
        .int32_as_byte => {
            const val = consumeBytes1(ctx, 1);
            return .{ .int32 = @intCast(val[0]) };
        },

        // 2-byte values
        .int16 => {
            const val = consumeBytes2(ctx, 2);
            return .{ .int32 = std.mem.readInt(i16, val[0..2], .little) };
        },
        .uint16 => {
            const val = consumeBytes2(ctx, 2);
            return .{ .uint32 = std.mem.readInt(u16, val[0..2], .little) };
        },

        // 4-byte values
        .int32 => {
            const val = consumeBytes4(ctx, 4);
            return .{ .int32 = std.mem.readInt(i32, val[0..4], .little) };
        },
        .uint32 => {
            const val = consumeBytes4(ctx, 4);
            return .{ .uint32 = std.mem.readInt(u32, val[0..4], .little) };
        },
        .float => {
            const val = consumeBytes4(ctx, 4);
            const bits = std.mem.readInt(u32, val[0..4], .little);
            return .{ .float32 = @bitCast(bits) };
        },

        // 8-byte values
        .int64 => {
            const val = consumeBytes8(ctx, 8);
            return .{ .int64 = std.mem.readInt(i64, val[0..8], .little) };
        },
        .uint64 => {
            const val = consumeBytes8(ctx, 8);
            return .{ .uint64 = std.mem.readInt(u64, val[0..8], .little) };
        },
        .double => {
            const val = consumeBytes8(ctx, 8);
            const bits = std.mem.readInt(u64, val[0..8], .little);
            return .{ .float64 = @bitCast(bits) };
        },

        // String
        .string => {
            const val = consumeBytes4(ctx, 4);
            const id = std.mem.readInt(i32, val[0..4], .little);
            if (id == -1 or id < 0) {
                return .{ .string = try ctx.allocator.dupe(u8, "") };
            }
            const str = ctx.strings[@intCast(id)];
            return .{ .string = try ctx.allocator.dupe(u8, str) };
        },

        // Binary blob
        .binary_blob => {
            if (ctx.version < 2) {
                // v1: length in bytes4, data in bytes1
                const len_data = consumeBytes4(ctx, 4);
                const blob_len: usize = @intCast(std.mem.readInt(i32, len_data[0..4], .little));
                if (blob_len > 0) {
                    const blob = consumeBytes1(ctx, blob_len);
                    return .{ .binary_blob = try ctx.allocator.dupe(u8, blob) };
                }
                return .{ .binary_blob = &.{} };
            } else {
                // v2+: length from binary_blob_lengths, data from binary_blobs
                if (ctx.binary_blob_lengths.len < 4) return error.InvalidKV3Data;
                const blob_len: usize = @intCast(std.mem.readInt(i32, ctx.binary_blob_lengths[0..4], .little));
                ctx.binary_blob_lengths = ctx.binary_blob_lengths[4..];
                if (blob_len > 0) {
                    if (ctx.binary_blobs.len < blob_len) return error.InvalidKV3Data;
                    const blob_data = ctx.binary_blobs[0..blob_len];
                    ctx.binary_blobs = ctx.binary_blobs[blob_len..];
                    return .{ .binary_blob = try ctx.allocator.dupe(u8, blob_data) };
                }
                return .{ .binary_blob = &.{} };
            }
        },

        // Array (heterogeneous)
        .array => {
            const len_data = consumeBytes4(ctx, 4);
            const array_length: usize = @intCast(std.mem.readInt(i32, len_data[0..4], .little));

            var arr = try KVArray.initCapacity(ctx.allocator, array_length);
            errdefer arr.deinit(ctx.allocator);

            for (0..array_length) |_| {
                const tf = readType(ctx);
                const val = try readBinaryValue(ctx, tf[0], tf[1]);
                try arr.add(val, tf[1]);
            }

            return .{ .array = arr };
        },

        // Typed array
        .array_typed, .array_type_byte_length => {
            var array_length: usize = undefined;

            if (datatype == .array_type_byte_length) {
                const len_byte = consumeBytes1(ctx, 1);
                array_length = len_byte[0];
            } else {
                const len_data = consumeBytes4(ctx, 4);
                array_length = @intCast(std.mem.readInt(i32, len_data[0..4], .little));
            }

            const sub_tf = readType(ctx);

            var arr = try KVArray.initCapacity(ctx.allocator, array_length);
            errdefer arr.deinit(ctx.allocator);

            for (0..array_length) |_| {
                const val = try readBinaryValue(ctx, sub_tf[0], sub_tf[1]);
                try arr.add(val, sub_tf[1]);
            }

            return .{ .array = arr };
        },

        // Typed array from auxiliary buffer (v5)
        .array_type_auxiliary_buffer => {
            const len_byte = consumeBytes1(ctx, 1);
            const array_length: usize = len_byte[0];

            const sub_tf = readType(ctx);

            var arr = try KVArray.initCapacity(ctx.allocator, array_length);
            errdefer arr.deinit(ctx.allocator);

            // Swap buffers
            const tmp = ctx.buffer;
            ctx.buffer = ctx.auxiliary_buffer;
            ctx.auxiliary_buffer = tmp;

            for (0..array_length) |_| {
                const val = try readBinaryValue(ctx, sub_tf[0], sub_tf[1]);
                try arr.add(val, sub_tf[1]);
            }

            // Swap back
            const tmp2 = ctx.buffer;
            ctx.buffer = ctx.auxiliary_buffer;
            ctx.auxiliary_buffer = tmp2;

            return .{ .array = arr };
        },

        // Object
        .object => {
            var object_length: usize = undefined;

            if (ctx.version >= 5) {
                if (ctx.object_lengths.len < 4) return error.InvalidKV3Data;
                object_length = @intCast(std.mem.readInt(i32, ctx.object_lengths[0..4], .little));
                ctx.object_lengths = ctx.object_lengths[4..];
            } else {
                const len_data = consumeBytes4(ctx, 4);
                object_length = @intCast(std.mem.readInt(i32, len_data[0..4], .little));
            }

            var obj = try KVObject.initCapacity(ctx.allocator, object_length);
            errdefer obj.deinit(ctx.allocator);

            for (0..object_length) |_| {
                // Read type+flag
                const tf = readType(ctx);

                // Read key string ID
                const key_data = consumeBytes4(ctx, 4);
                const string_id = std.mem.readInt(i32, key_data[0..4], .little);

                const key_str = if (string_id == -1 or string_id < 0)
                    try ctx.allocator.dupe(u8, "")
                else
                    try ctx.allocator.dupe(u8, ctx.strings[@intCast(string_id)]);

                const val = try readBinaryValue(ctx, tf[0], tf[1]);
                try obj.add(key_str, val, tf[1]);
            }

            return .{ .object = obj };
        },

        else => return error.UnknownKV3NodeType,
    }
}

// --- Buffer consumption helpers ---

fn consumeBytes1(ctx: *Context, n: usize) []const u8 {
    const result = ctx.buffer.bytes1[0..n];
    ctx.buffer.bytes1 = ctx.buffer.bytes1[n..];
    return result;
}

fn consumeBytes2(ctx: *Context, n: usize) []const u8 {
    const result = ctx.buffer.bytes2[0..n];
    ctx.buffer.bytes2 = ctx.buffer.bytes2[n..];
    return result;
}

fn consumeBytes4(ctx: *Context, n: usize) []const u8 {
    const result = ctx.buffer.bytes4[0..n];
    ctx.buffer.bytes4 = ctx.buffer.bytes4[n..];
    return result;
}

fn consumeBytes8(ctx: *Context, n: usize) []const u8 {
    const result = ctx.buffer.bytes8[0..n];
    ctx.buffer.bytes8 = ctx.buffer.bytes8[n..];
    return result;
}

// --- Utility ---

fn align_offset(offset: *usize, alignment: usize) void {
    const mask = alignment - 1;
    offset.* = (offset.* + mask) & ~mask;
}

fn readU32(data: []const u8, pos: *usize) ?u32 {
    if (pos.* + 4 > data.len) return null;
    const val = std.mem.readInt(u32, data[pos.*..][0..4], .little);
    pos.* += 4;
    return val;
}

fn readI32(data: []const u8, pos: *usize) ?i32 {
    if (pos.* + 4 > data.len) return null;
    const val = std.mem.readInt(i32, data[pos.*..][0..4], .little);
    pos.* += 4;
    return val;
}

fn readU16(data: []const u8, pos: *usize) ?u16 {
    if (pos.* + 2 > data.len) return null;
    const val = std.mem.readInt(u16, data[pos.*..][0..2], .little);
    pos.* += 2;
    return val;
}

// ============================================================
// Tests
// ============================================================

/// Build a minimal uncompressed KV3 v3 binary blob containing a simple object:
/// { "name": "test", "value": 42 }
fn buildTestKV3(allocator: std.mem.Allocator) ![]u8 {
    var buf = std.ArrayList(u8).init(allocator);
    const w = buf.writer();

    // Magic: KV3\x03
    try w.writeInt(u32, MAGIC3, .little);

    // Format GUID (16 zero bytes)
    try w.writeByteNTimes(0, 16);

    // Compression method: 0 = uncompressed
    try w.writeInt(u32, 0, .little);

    // v2+ header fields
    try w.writeInt(u16, 0, .little); // compressionDictionaryId
    try w.writeInt(u16, 0, .little); // compressionFrameSize

    // We need to build the buffer contents first, then compute sizes.
    // Strings: "name", "test", "value" (3 strings)
    // Bytes1: empty
    // Bytes4: string_count(3) + object_length(2) + key_id(0="name") + string_id(1="test") + key_id(2="value") + int32(42) = 6 i32s = 24 bytes
    // But string_count is consumed first from bytes4, then object_length, then key/values
    // Types: object_type, [string_type, int32_type] for 2 properties = 3 bytes
    // Trailer: 0xFFEEDD00

    // Layout plan:
    // Bytes1: 0 bytes
    // Bytes4: 7 * 4 = 28 bytes:
    //   [0] string_count = 3
    //   [1] object_length = 2
    //   [2] key_string_id = 0 ("name")
    //   [3] value_string_id = 1 ("test")
    //   [4] key_string_id = 2 ("value")
    //   [5] int32_value = 42
    //   (wait - string_count is consumed first, then during parsing)
    //
    // Actually the bytes4 layout is:
    //   First 4 bytes = string count (consumed before parsing)
    //   Then during object parsing:
    //     read object_length from bytes4
    //     for each property:
    //       read type from types
    //       read key_string_id from bytes4
    //       read value from appropriate buffer

    // So bytes4 (excluding the string count prefix) needs:
    //   object_length(2), key_id(0), string_value_id(1), key_id(2), int32_value(42)
    // = 5 i32s = 20 bytes (plus string count = 24 bytes total = 6 i32s)

    const count_bytes1: i32 = 0;
    const count_bytes4: i32 = 6; // 6 i32 values (including string count)
    const count_bytes8: i32 = 0;

    // Strings: "name\0test\0value\0" = 15 bytes
    const strings_data = "name\x00test\x00value\x00";

    // Types: for the root object + 2 properties
    // Root type: OBJECT (9)
    // Property 1 type: STRING (6)
    // Property 2 type: INT32 (11)
    const types_data = [_]u8{ 9, 6, 11 };

    // Trailer
    const trailer = [4]u8{ 0x00, 0xDD, 0xEE, 0xFF }; // 0xFFEEDD00 LE

    // Total uncompressed size = bytes4_data + strings + types + trailer
    // bytes4 = 6 * 4 = 24
    // strings = 15
    // types = 3
    // trailer = 4
    // total = 46
    const count_types: i32 = @intCast(strings_data.len + types_data.len);
    const size_uncompressed_total: i32 = count_bytes4 * 4 + @as(i32, @intCast(strings_data.len)) + @as(i32, @intCast(types_data.len)) + 4;

    try w.writeInt(i32, count_bytes1, .little);
    try w.writeInt(i32, count_bytes4, .little);
    try w.writeInt(i32, count_bytes8, .little);
    try w.writeInt(i32, count_types, .little);
    try w.writeInt(u16, 0, .little); // countObjects
    try w.writeInt(u16, 0, .little); // countArrays
    try w.writeInt(i32, size_uncompressed_total, .little);
    try w.writeInt(i32, size_uncompressed_total, .little); // sizeCompressed = same (uncompressed)
    try w.writeInt(i32, 0, .little); // countBlocks
    try w.writeInt(i32, 0, .little); // sizeBinaryBlobsBytes

    // Buffer 1 data (uncompressed)
    // Bytes4: string_count + object_length + key0 + val0 + key1 + val1
    try w.writeInt(i32, 3, .little); // string_count = 3
    try w.writeInt(i32, 2, .little); // object_length = 2
    try w.writeInt(i32, 0, .little); // key_id = 0 ("name")
    try w.writeInt(i32, 1, .little); // value = string_id 1 ("test")
    try w.writeInt(i32, 2, .little); // key_id = 2 ("value")
    try w.writeInt(i32, 42, .little); // value = 42

    // Strings
    try w.writeAll(strings_data);

    // Types
    try w.writeAll(&types_data);

    // Trailer
    try w.writeAll(&trailer);

    return buf.toOwnedSlice();
}

test "BinaryKV3 decode simple object" {
    const data = try buildTestKV3(std.testing.allocator);
    defer std.testing.allocator.free(data);

    var doc = try decode(std.testing.allocator, data);
    defer doc.deinit();

    // Root should be an object
    const root = doc.root.asObject().?;
    try std.testing.expectEqual(@as(usize, 2), root.count());

    // "name" -> "test"
    try std.testing.expectEqualStrings("test", root.getStringProperty("name").?);

    // "value" -> 42
    try std.testing.expectEqual(@as(i32, 42), root.get("value").?.asI32().?);
}

test "BinaryKV3 isBinaryKV3" {
    try std.testing.expect(isBinaryKV3(MAGIC1));
    try std.testing.expect(isBinaryKV3(MAGIC5));
    try std.testing.expect(isBinaryKV3(MAGIC0));
    try std.testing.expect(!isBinaryKV3(0xDEADBEEF));
}

test "BinaryKV3 reject bad magic" {
    var data: [4]u8 = undefined;
    std.mem.writeInt(u32, &data, 0xDEADBEEF, .little);
    try std.testing.expectError(error.InvalidKV3Magic, decode(std.testing.allocator, &data));
}
