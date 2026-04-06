const std = @import("std");

/// A binary reader for little-endian Valve resource files.
/// Works directly on a slice with a position cursor — no stream abstractions.
pub const BinaryReader = struct {
    data: []const u8,
    pos: usize,
    allocator: std.mem.Allocator,

    pub fn fromSlice(data: []const u8, allocator: std.mem.Allocator) BinaryReader {
        return .{ .data = data, .pos = 0, .allocator = allocator };
    }

    /// Current position in the buffer.
    pub fn position(self: *const BinaryReader) u64 {
        return @intCast(self.pos);
    }

    /// Set absolute position.
    pub fn setPosition(self: *BinaryReader, p: u64) void {
        self.pos = @intCast(@min(p, self.data.len));
    }

    /// Total length of the underlying data.
    pub fn length(self: *const BinaryReader) u64 {
        return @intCast(self.data.len);
    }

    /// Skip forward (or backward with negative) by n bytes.
    pub fn skip(self: *BinaryReader, n: i64) void {
        const new_pos = @as(i64, @intCast(self.pos)) + n;
        self.pos = @intCast(@max(0, @min(new_pos, @as(i64, @intCast(self.data.len)))));
    }

    // --- Primitive reads (little-endian) ---

    fn ensure(self: *const BinaryReader, n: usize) !void {
        if (self.pos + n > self.data.len) return error.UnexpectedEof;
    }

    pub fn readByte(self: *BinaryReader) !u8 {
        try self.ensure(1);
        const b = self.data[self.pos];
        self.pos += 1;
        return b;
    }

    pub fn readU16(self: *BinaryReader) !u16 {
        try self.ensure(2);
        const val = std.mem.readInt(u16, self.data[self.pos..][0..2], .little);
        self.pos += 2;
        return val;
    }

    pub fn readU32(self: *BinaryReader) !u32 {
        try self.ensure(4);
        const val = std.mem.readInt(u32, self.data[self.pos..][0..4], .little);
        self.pos += 4;
        return val;
    }

    pub fn readU64(self: *BinaryReader) !u64 {
        try self.ensure(8);
        const val = std.mem.readInt(u64, self.data[self.pos..][0..8], .little);
        self.pos += 8;
        return val;
    }

    pub fn readI16(self: *BinaryReader) !i16 {
        try self.ensure(2);
        const val = std.mem.readInt(i16, self.data[self.pos..][0..2], .little);
        self.pos += 2;
        return val;
    }

    pub fn readI32(self: *BinaryReader) !i32 {
        try self.ensure(4);
        const val = std.mem.readInt(i32, self.data[self.pos..][0..4], .little);
        self.pos += 4;
        return val;
    }

    pub fn readI64(self: *BinaryReader) !i64 {
        try self.ensure(8);
        const val = std.mem.readInt(i64, self.data[self.pos..][0..8], .little);
        self.pos += 8;
        return val;
    }

    pub fn readF32(self: *BinaryReader) !f32 {
        const bits = try self.readU32();
        return @bitCast(bits);
    }

    pub fn readF64(self: *BinaryReader) !f64 {
        const bits = try self.readU64();
        return @bitCast(bits);
    }

    /// Read N bytes into a caller-provided buffer.
    pub fn readBytes(self: *BinaryReader, buf: []u8) !usize {
        const avail = @min(buf.len, self.data.len - self.pos);
        @memcpy(buf[0..avail], self.data[self.pos..][0..avail]);
        self.pos += avail;
        return avail;
    }

    /// Read exactly N bytes, allocating the result. Caller owns the memory.
    pub fn readBytesAlloc(self: *BinaryReader, n: usize) ![]u8 {
        try self.ensure(n);
        const buf = try self.allocator.alloc(u8, n);
        @memcpy(buf, self.data[self.pos..][0..n]);
        self.pos += n;
        return buf;
    }

    /// Return a slice view into the underlying data without copying.
    pub fn sliceFrom(self: *BinaryReader, n: usize) ![]const u8 {
        try self.ensure(n);
        const s = self.data[self.pos..][0..n];
        self.pos += n;
        return s;
    }

    // --- String reads ---

    /// Read a null-terminated UTF-8 string. Caller owns returned slice.
    pub fn readNullTermString(self: *BinaryReader) ![]const u8 {
        const start = self.pos;
        while (self.pos < self.data.len) {
            if (self.data[self.pos] == 0) {
                const str = try self.allocator.dupe(u8, self.data[start..self.pos]);
                self.pos += 1; // skip null
                return str;
            }
            self.pos += 1;
        }
        // Reached end without null — return what we have
        return try self.allocator.dupe(u8, self.data[start..self.pos]);
    }

    /// Read an offset-relative string.
    /// Format: i32 relative_offset from current position,
    /// then jump to (current_pos + offset) to read a null-terminated string,
    /// then restore position to current_pos + 4.
    pub fn readOffsetString(self: *BinaryReader) ![]const u8 {
        const current_offset = self.pos;
        const offset = try self.readI32();

        if (offset == 0) {
            return try self.allocator.dupe(u8, "");
        }

        const target: usize = @intCast(@as(i64, @intCast(current_offset)) + @as(i64, offset));
        self.pos = target;

        const str = try self.readNullTermString();

        self.pos = current_offset + 4;

        return str;
    }

    /// Peek at upcoming u32 without advancing position.
    pub fn peekU32(self: *BinaryReader) !u32 {
        try self.ensure(4);
        return std.mem.readInt(u32, self.data[self.pos..][0..4], .little);
    }
};

// --- Tests ---

test "BinaryReader basic reads" {
    const data = [_]u8{
        0x10, 0x00, 0x00, 0x00, // u32 = 16
        0x0C, 0x00, // u16 = 12
        0x48, 0x65, 0x6C, 0x6C, 0x6F, 0x00, // "Hello\0"
    };

    var r = BinaryReader.fromSlice(&data, std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 16), try r.readU32());
    try std.testing.expectEqual(@as(u16, 12), try r.readU16());

    const str = try r.readNullTermString();
    defer std.testing.allocator.free(str);
    try std.testing.expectEqualStrings("Hello", str);
}

test "BinaryReader offset string" {
    // Layout:
    // [0..4] offset = 4 (relative to position 0, pointing to byte 4)
    // [4..10] "World\0"
    const data = [_]u8{
        0x04, 0x00, 0x00, 0x00, // i32 offset = 4
        0x57, 0x6F, 0x72, 0x6C, 0x64, 0x00, // "World\0"
    };

    var r = BinaryReader.fromSlice(&data, std.testing.allocator);
    const str = try r.readOffsetString();
    defer std.testing.allocator.free(str);
    try std.testing.expectEqualStrings("World", str);
    try std.testing.expectEqual(@as(u64, 4), r.position());
}

test "BinaryReader peek" {
    const data = [_]u8{ 0xFF, 0x00, 0x00, 0x00 };
    var r = BinaryReader.fromSlice(&data, std.testing.allocator);
    const val = try r.peekU32();
    try std.testing.expectEqual(@as(u32, 0xFF), val);
    try std.testing.expectEqual(@as(u64, 0), r.position());
}

test "BinaryReader eof detection" {
    const data = [_]u8{ 0x01 };
    var r = BinaryReader.fromSlice(&data, std.testing.allocator);
    try std.testing.expectError(error.UnexpectedEof, r.readU32());
}
