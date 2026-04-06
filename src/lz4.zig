const std = @import("std");

/// LZ4 raw block decompressor (no frame header).
///
/// This implements the LZ4 block format as used by Valve in KV3 data.
/// See: https://github.com/lz4/lz4/blob/dev/doc/lz4_Block_format.md
///
/// The format is a sequence of "sequences", each consisting of:
///   1. Token byte: high nibble = literal length, low nibble = match length
///   2. Optional extra literal length bytes (if high nibble == 15)
///   3. Literal bytes
///   4. Match offset (u16 LE) — distance back in output
///   5. Optional extra match length bytes (if low nibble == 15)
///
/// Match length has a +4 implicit minimum (MINMATCH).
pub fn decompress(input: []const u8, output: []u8) !usize {
    var ip: usize = 0; // input position
    var op: usize = 0; // output position

    while (ip < input.len) {
        // 1. Read token
        const token = input[ip];
        ip += 1;

        // 2. Literal length
        var literal_length: usize = token >> 4;
        if (literal_length == 15) {
            literal_length += try readMoreLength(input, &ip);
        }

        // 3. Copy literals
        if (literal_length > 0) {
            if (ip + literal_length > input.len) return error.LZ4InputOverflow;
            if (op + literal_length > output.len) return error.LZ4OutputOverflow;

            @memcpy(output[op..][0..literal_length], input[ip..][0..literal_length]);
            ip += literal_length;
            op += literal_length;
        }

        // Check if this was the last sequence (no match after final literals)
        if (ip >= input.len) break;

        // 4. Match offset (u16 LE)
        if (ip + 2 > input.len) return error.LZ4InputOverflow;
        const match_offset: usize = @as(usize, input[ip]) | (@as(usize, input[ip + 1]) << 8);
        ip += 2;

        if (match_offset == 0) return error.LZ4InvalidOffset;
        if (match_offset > op) return error.LZ4InvalidOffset;

        // 5. Match length
        var match_length: usize = (token & 0x0F) + 4; // MINMATCH = 4
        if ((token & 0x0F) == 15) {
            match_length += try readMoreLength(input, &ip);
        }

        // 6. Copy match (byte-by-byte for overlapping copies)
        if (op + match_length > output.len) return error.LZ4OutputOverflow;

        const match_start = op - match_offset;
        for (0..match_length) |i| {
            output[op + i] = output[match_start + (i % match_offset)];
        }
        op += match_length;
    }

    return op;
}

/// Read additional length bytes (each 0xFF adds 255, first non-0xFF terminates).
fn readMoreLength(input: []const u8, ip: *usize) !usize {
    var extra: usize = 0;
    while (ip.* < input.len) {
        const byte = input[ip.*];
        ip.* += 1;
        extra += byte;
        if (byte != 0xFF) break;
    }
    return extra;
}

// ============================================================
// Tests
// ============================================================

test "LZ4 decompress literals only" {
    // Token: literal_length=5, match_length=0 (no match since it's the last sequence)
    // 0x50 = high nibble 5, low nibble 0
    const input = [_]u8{ 0x50, 'H', 'e', 'l', 'l', 'o' };
    var output: [32]u8 = undefined;

    const size = try decompress(&input, &output);
    try std.testing.expectEqual(@as(usize, 5), size);
    try std.testing.expectEqualStrings("Hello", output[0..5]);
}

test "LZ4 decompress with match" {
    // "abcabc" compressed:
    // Sequence 1: token 0x30 (3 literals, match=4), literals "abc", offset=3
    // But match_length 4 > remaining "abc" so actual = "abcabca" with 4-byte min match
    // Let's build it manually:
    // Token: literal_len=6, no match (last sequence)
    // Actually let's just test a simple repeat pattern.

    // "AAAAAA" (6 A's):
    // Seq 1: token 0x10 (1 literal, match_len = 0+4=4), literal 'A', offset=1
    // That gives: A + copy 4 from offset 1 = "AAAAA" (5 bytes)
    // Then we need one more... Let's do token 0x11 for match_len=5
    const input = [_]u8{
        0x11, // literal_len=1, match_extra=1 -> match_len=4+1=5
        'A', // 1 literal byte
        0x01, 0x00, // match offset = 1
    };
    var output: [32]u8 = undefined;

    const size = try decompress(&input, &output);
    try std.testing.expectEqual(@as(usize, 6), size);
    try std.testing.expectEqualStrings("AAAAAA", output[0..6]);
}

test "LZ4 decompress extended literal length" {
    // 20 literal bytes: token high nibble = 15, then 5 more (15+5=20)
    var input: [23]u8 = undefined;
    input[0] = 0xF0; // literal_len=15, match_len=0
    input[1] = 5; // extra literal length: 15 + 5 = 20
    for (2..22) |i| input[i] = @intCast('A' + (i - 2));

    var output: [32]u8 = undefined;
    const size = try decompress(input[0..22], &output);
    try std.testing.expectEqual(@as(usize, 20), size);
}

test "LZ4 reject zero offset" {
    const input = [_]u8{
        0x10, 'A', // 1 literal, match
        0x00, 0x00, // offset = 0 (invalid)
    };
    var output: [32]u8 = undefined;
    try std.testing.expectError(error.LZ4InvalidOffset, decompress(&input, &output));
}

test "LZ4 reject offset beyond output" {
    const input = [_]u8{
        0x10, 'A', // 1 literal, match
        0x05, 0x00, // offset = 5 (but only 1 byte written)
    };
    var output: [32]u8 = undefined;
    try std.testing.expectError(error.LZ4InvalidOffset, decompress(&input, &output));
}
