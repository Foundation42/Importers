/// MeshOptimizer vertex and index buffer decoders.
/// Ported from https://github.com/zeux/meshoptimizer
const std = @import("std");

const VertexHeader: u8 = 0xa0;
const IndexHeader: u8 = 0xe0;
const VertexBlockSizeBytes: usize = 8192;
const VertexBlockMaxSize: usize = 256;
const ByteGroupSize: usize = 16;
const ByteGroupDecodeLimit: usize = 24;

const BitsV0 = [4]u8{ 0, 2, 4, 8 };
const BitsV1_0 = [_]u8{ 0, 1, 2, 4, 8 };
const BitsV1_1 = [_]u8{ 0, 1, 2, 4, 8 };
const BitsV1_2 = [_]u8{ 0, 1, 2, 4, 8 };

// ============================================================
// Vertex Buffer Decoder
// ============================================================

pub fn decodeVertexBuffer(allocator: std.mem.Allocator, vertex_count: usize, vertex_size: usize, buffer: []const u8) ![]u8 {
    if (vertex_size == 0 or vertex_size > 256 or vertex_size % 4 != 0) return error.InvalidVertexSize;
    if (buffer.len < 1) return error.BufferTooShort;
    if ((buffer[0] & 0xF0) != VertexHeader) return error.InvalidVertexHeader;

    const version: u8 = buffer[0] & 0x0F;
    if (version > 1) return error.UnsupportedVersion;

    var data = buffer[1..];

    const tail_size = vertex_size + (if (version == 0) @as(usize, 0) else vertex_size / 4);
    const tail_min = if (version == 0) @as(usize, 32) else @as(usize, 24);
    const tail_padded = @max(tail_size, tail_min);

    if (data.len < tail_padded) return error.BufferTooShort;

    var result = try allocator.alloc(u8, vertex_count * vertex_size);
    errdefer allocator.free(result);

    const last_vertex = try allocator.alloc(u8, vertex_size);
    defer allocator.free(last_vertex);

    // Copy last vertex from tail
    @memcpy(last_vertex, data[data.len - tail_size ..][0..vertex_size]);

    const channels: ?[]const u8 = if (version == 0) null else data[data.len - tail_size + vertex_size ..][0 .. vertex_size / 4];

    const vertex_block_size = blk: {
        var r = VertexBlockSizeBytes / vertex_size;
        r &= ~(ByteGroupSize - 1);
        break :blk if (r < VertexBlockMaxSize) r else VertexBlockMaxSize;
    };

    var vertex_offset: usize = 0;

    // Temp buffers
    const buf_mem = try allocator.alloc(u8, VertexBlockMaxSize * 4);
    defer allocator.free(buf_mem);
    const transposed = try allocator.alloc(u8, VertexBlockSizeBytes);
    defer allocator.free(transposed);

    while (vertex_offset < vertex_count) {
        const block_size = if (vertex_offset + vertex_block_size < vertex_count)
            vertex_block_size
        else
            vertex_count - vertex_offset;

        data = try decodeVertexBlock(data, result[vertex_offset * vertex_size ..], block_size, vertex_size, last_vertex, channels, version, buf_mem, transposed);
        vertex_offset += block_size;
    }

    return result;
}

fn decodeVertexBlock(
    data_in: []const u8,
    vertex_data: []u8,
    vertex_count: usize,
    vertex_size: usize,
    last_vertex: []u8,
    channels: ?[]const u8,
    version: u8,
    buf: []u8,
    transposed: []u8,
) ![]const u8 {
    var data = data_in;
    const vertex_count_aligned = (vertex_count + ByteGroupSize - 1) & ~(ByteGroupSize - 1);
    const control_size: usize = if (version == 0) 0 else vertex_size / 4;

    const control = data[0..control_size];
    data = data[control_size..];

    var k: usize = 0;
    while (k < vertex_size) : (k += 4) {
        const ctrl_byte: u8 = if (version == 0) 0 else control[k / 4];

        for (0..4) |j| {
            const ctrl: u2 = @intCast((ctrl_byte >> @intCast(j * 2)) & 3);

            if (ctrl == 3) {
                // Literal
                if (data.len < vertex_count) return error.BufferTooShort;
                @memcpy(buf[j * vertex_count ..][0..vertex_count], data[0..vertex_count]);
                data = data[vertex_count..];
            } else if (ctrl == 2) {
                // Zero
                @memset(buf[j * vertex_count ..][0..vertex_count], 0);
            } else {
                // Byte group decode
                const bits: u8 = if (version == 0) BitsV0[ctrl] else BitsV1_0[ctrl];
                data = try decodeBytes(data, buf[j * vertex_count ..][0..vertex_count_aligned], bits);
            }
        }

        const channel: u8 = if (version == 0 or channels == null) 0 else channels.?[k / 4];

        switch (channel & 3) {
            0 => decodeDeltas(1, buf, transposed[k..], vertex_count, vertex_size, last_vertex[k..], 0),
            1 => decodeDeltas(2, buf, transposed[k..], vertex_count, vertex_size, last_vertex[k..], 0),
            2 => decodeDeltas(4, buf, transposed[k..], vertex_count, vertex_size, last_vertex[k..], @intCast((32 -% (@as(u32, channel) >> 4)) & 31)),
            else => return error.InvalidChannel,
        }
    }

    @memcpy(vertex_data[0 .. vertex_count * vertex_size], transposed[0 .. vertex_count * vertex_size]);
    @memcpy(last_vertex, transposed[vertex_size * (vertex_count - 1) ..][0..vertex_size]);

    return data;
}

fn decodeDeltas(comptime size: comptime_int, buffer: []const u8, transposed: []u8, vertex_count: usize, vertex_size: usize, last_vertex_in: []u8, rot: u5) void {
    const last_vertex = last_vertex_in;

    for (0..4 / size) |kk| {
        var p: u32 = 0;
        for (0..size) |j| {
            p |= @as(u32, last_vertex[kk * size + j]) << @intCast(8 * j);
        }

        for (0..vertex_count) |i| {
            var v: u32 = 0;
            for (0..size) |j| {
                v |= @as(u32, buffer[(kk * size + j) * vertex_count + i]) << @intCast(8 * j);
            }

            v = switch (size) {
                1 => unzigzag8(@truncate(v)) +% p,
                2 => unzigzag16(@truncate(v)) +% p,
                4 => rotate32(v, rot) ^ p,
                else => unreachable,
            };

            const base = i * vertex_size + kk * size;
            for (0..size) |j| {
                transposed[base + j] = @truncate(v >> @intCast(j * 8));
            }
            p = v;
        }
    }
}

fn unzigzag8(v: u8) u32 {
    return (0 -% @as(u32, v & 1)) ^ (@as(u32, v) >> 1);
}

fn unzigzag16(v: u16) u32 {
    return (0 -% @as(u32, v & 1)) ^ (@as(u32, v) >> 1);
}

fn rotate32(v: u32, r: u5) u32 {
    return (v << r) | (v >> ((@as(u5, 31) -% r) +% 1));
}

fn decodeBytes(data_in: []const u8, destination: []u8, bits: u8) ![]const u8 {
    if (destination.len % ByteGroupSize != 0) return error.InvalidAlignment;
    var data = data_in;

    const header_size = (destination.len / ByteGroupSize + 3) / 4;
    const header = data[0..header_size];
    data = data[header_size..];

    var i: usize = 0;
    while (i < destination.len) : (i += ByteGroupSize) {
        if (data.len < ByteGroupDecodeLimit) return error.BufferTooShort;

        const header_offset = i / ByteGroupSize;
        const bitsk = (header[header_offset / 4] >> @intCast((header_offset % 4) * 2)) & 3;

        const actual_bits = if (bits == 0) BitsV0[bitsk] else blk: {
            const table = [5]u8{ 0, 1, 2, 4, 8 };
            break :blk table[@min(bitsk, 4)];
        };

        data = decodeBytesGroup(data, destination[i..][0..ByteGroupSize], actual_bits);
    }

    return data;
}

fn decodeBytesGroup(data: []const u8, dest: *[ByteGroupSize]u8, bits: u8) []const u8 {
    switch (bits) {
        0 => {
            @memset(dest, 0);
            return data;
        },
        8 => {
            @memcpy(dest, data[0..ByteGroupSize]);
            return data[ByteGroupSize..];
        },
        else => {
            // For 1, 2, 4 bit modes the C# code reads from high-to-low bits
            // within each byte. The encoding packs (8/bits) values per byte,
            // MSB first. If value == (1<<bits)-1, read a literal from overflow.
            const vals_per_byte: usize = 8 / @as(usize, bits);
            const header_bytes: usize = (ByteGroupSize + vals_per_byte - 1) / vals_per_byte;
            var consumed: usize = header_bytes;
            const sentinel: u8 = (@as(u8, 1) << @intCast(bits)) - 1;

            for (0..ByteGroupSize) |di| {
                const header_byte_idx = di / vals_per_byte;
                const val_idx_in_byte = di % vals_per_byte;
                // Values are packed MSB-first: first value is in highest bits
                const shift: u3 = @intCast(8 - @as(u8, bits) * @as(u8, @intCast(val_idx_in_byte + 1)));
                const val: u8 = (data[header_byte_idx] >> shift) & sentinel;

                if (val == sentinel) {
                    dest[di] = data[consumed];
                    consumed += 1;
                } else {
                    dest[di] = val;
                }
            }

            return data[consumed..];
        },
    }
}

// ============================================================
// Index Buffer Decoder
// ============================================================

pub fn decodeIndexBuffer(allocator: std.mem.Allocator, index_count: usize, index_size: usize, buffer: []const u8) ![]u8 {
    if (index_count % 3 != 0) return error.InvalidIndexCount;
    if (index_size != 2 and index_size != 4) return error.InvalidIndexSize;

    const data_offset = 1 + (index_count / 3);
    if (buffer.len < data_offset + 16) return error.BufferTooShort;
    if ((buffer[0] & 0xF0) != IndexHeader) return error.InvalidIndexHeader;

    const version: u8 = buffer[0] & 0x0F;
    if (version > 1) return error.UnsupportedVersion;

    var vertex_fifo = [_]u32{0} ** 16;
    var edge_fifo = [_][2]u32{.{ 0, 0 }} ** 16;
    var edge_fifo_offset: usize = 0;
    var vertex_fifo_offset: usize = 0;

    var next: u32 = 0;
    var last: u32 = 0;
    const fecmax: u8 = if (version >= 1) 13 else 15;

    var buf_index: usize = 1;
    const data_end = buffer.len - 16;
    const data = buffer[data_offset..data_end];
    var data_pos: usize = 0;

    const codeaux_table = buffer[buffer.len - 16 ..];

    const result = try allocator.alloc(u8, index_count * index_size);
    errdefer allocator.free(result);

    var i: usize = 0;
    while (i < index_count) : (i += 3) {
        const codetri = buffer[buf_index];
        buf_index += 1;

        if (codetri < 0xf0) {
            const fe = codetri >> 4;
            const edge = edge_fifo[(@as(usize, edge_fifo_offset) -% 1 -% @as(usize, fe)) & 15];
            const a = edge[0];
            const b = edge[1];
            var c: u32 = undefined;

            const fec: u8 = codetri & 15;

            if (fec < fecmax) {
                c = if (fec == 0) next else vertex_fifo[(@as(usize, vertex_fifo_offset) -% 1 -% @as(usize, fec)) & 15];
                if (fec == 0) next += 1;
                pushVertexFifo(&vertex_fifo, &vertex_fifo_offset, c, fec == 0);
            } else {
                if (fec != 15) {
                    c = last +% @as(u32, @intCast(@as(i32, @intCast(fec)) - @as(i32, @intCast(fec ^ 3))));
                    last = c;
                } else {
                    c = decodeIndex(data, last, &data_pos);
                    last = c;
                }
                pushVertexFifo(&vertex_fifo, &vertex_fifo_offset, c, true);
            }

            pushEdgeFifo(&edge_fifo, &edge_fifo_offset, c, b);
            pushEdgeFifo(&edge_fifo, &edge_fifo_offset, a, c);
            writeTriangle(result, i, index_size, a, b, c);
        } else if (codetri < 0xfe) {
            const codeaux = codeaux_table[codetri & 15];
            const feb = codeaux >> 4;
            const fec_val = codeaux & 15;

            const a = next;
            next += 1;

            const b = if (feb == 0) blk: {
                const v = next;
                next += 1;
                break :blk v;
            } else vertex_fifo[(@as(usize, vertex_fifo_offset) -% @as(usize, feb)) & 15];

            const c = if (fec_val == 0) blk: {
                const v = next;
                next += 1;
                break :blk v;
            } else vertex_fifo[(@as(usize, vertex_fifo_offset) -% @as(usize, fec_val)) & 15];

            writeTriangle(result, i, index_size, a, b, c);

            pushVertexFifo(&vertex_fifo, &vertex_fifo_offset, a, true);
            pushVertexFifo(&vertex_fifo, &vertex_fifo_offset, b, feb == 0);
            pushVertexFifo(&vertex_fifo, &vertex_fifo_offset, c, fec_val == 0);

            pushEdgeFifo(&edge_fifo, &edge_fifo_offset, b, a);
            pushEdgeFifo(&edge_fifo, &edge_fifo_offset, c, b);
            pushEdgeFifo(&edge_fifo, &edge_fifo_offset, a, c);
        } else {
            const codeaux = data[data_pos];
            data_pos += 1;

            const fea: u8 = if (codetri == 0xfe) 0 else 15;
            const feb = codeaux >> 4;
            const fec_val = codeaux & 15;

            if (codeaux == 0) next = 0;

            var a: u32 = if (fea == 0) blk: {
                const v = next;
                next += 1;
                break :blk v;
            } else 0;
            var b: u32 = if (feb == 0) blk: {
                const v = next;
                next += 1;
                break :blk v;
            } else vertex_fifo[(@as(usize, vertex_fifo_offset) -% @as(usize, feb)) & 15];
            var c: u32 = if (fec_val == 0) blk: {
                const v = next;
                next += 1;
                break :blk v;
            } else vertex_fifo[(@as(usize, vertex_fifo_offset) -% @as(usize, fec_val)) & 15];

            if (fea == 15) {
                a = decodeIndex(data, last, &data_pos);
                last = a;
            }
            if (feb == 15) {
                b = decodeIndex(data, last, &data_pos);
                last = b;
            }
            if (fec_val == 15) {
                c = decodeIndex(data, last, &data_pos);
                last = c;
            }

            writeTriangle(result, i, index_size, a, b, c);

            pushVertexFifo(&vertex_fifo, &vertex_fifo_offset, a, true);
            pushVertexFifo(&vertex_fifo, &vertex_fifo_offset, b, feb == 0 or feb == 15);
            pushVertexFifo(&vertex_fifo, &vertex_fifo_offset, c, fec_val == 0 or fec_val == 15);

            pushEdgeFifo(&edge_fifo, &edge_fifo_offset, b, a);
            pushEdgeFifo(&edge_fifo, &edge_fifo_offset, c, b);
            pushEdgeFifo(&edge_fifo, &edge_fifo_offset, a, c);
        }
    }

    return result;
}

fn pushEdgeFifo(fifo: *[16][2]u32, offset: *usize, a: u32, b: u32) void {
    fifo[offset.*] = .{ a, b };
    offset.* = (offset.* + 1) & 15;
}

fn pushVertexFifo(fifo: *[16]u32, offset: *usize, v: u32, cond: bool) void {
    fifo[offset.*] = v;
    offset.* = (offset.* + @as(usize, if (cond) 1 else 0)) & 15;
}

fn decodeVByte(data: []const u8, pos: *usize) u32 {
    const lead: u32 = data[pos.*];
    pos.* += 1;
    if (lead < 128) return lead;

    var result = lead & 127;
    var shift: u5 = 7;
    for (0..4) |_| {
        const group: u32 = data[pos.*];
        pos.* += 1;
        result |= (group & 127) << shift;
        shift +%= 7;
        if (group < 128) break;
    }
    return result;
}

fn decodeIndex(data: []const u8, last: u32, pos: *usize) u32 {
    const v = decodeVByte(data, pos);
    const d: u32 = @bitCast(@as(i32, @bitCast((v >> 1) ^ (0 -% (v & 1)))));
    return last +% d;
}

fn writeTriangle(dest: []u8, offset: usize, index_size: usize, a: u32, b: u32, c: u32) void {
    const o = offset * index_size;
    if (index_size == 2) {
        std.mem.writeInt(u16, dest[o..][0..2], @truncate(a), .little);
        std.mem.writeInt(u16, dest[o + 2 ..][0..2], @truncate(b), .little);
        std.mem.writeInt(u16, dest[o + 4 ..][0..2], @truncate(c), .little);
    } else {
        std.mem.writeInt(u32, dest[o..][0..4], a, .little);
        std.mem.writeInt(u32, dest[o + 4 ..][0..4], b, .little);
        std.mem.writeInt(u32, dest[o + 8 ..][0..4], c, .little);
    }
}

// ============================================================
// Compressed Normal Decoder (Source 2 / CS2)
// ============================================================

/// Decode a compressed normal from a packed u32 (R32_UINT format).
/// CS2 packs: 1 sign bit, 11 tangent rotation bits, 10 X bits, 10 Y bits.
pub fn decompressNormal(raw: u32) [3]f32 {
    const result = decompressNormalTangentImpl(raw);
    return .{ result[0][0], result[0][1], result[0][2] };
}

/// Decode a compressed tangent from a packed u32 (R32_UINT format).
pub fn decompressTangent(raw: u32) [4]f32 {
    return decompressNormalTangentImpl(raw)[1];
}

fn decompressNormalTangentImpl(raw: u32) [2][4]f32 {
    const sign_bit = raw & 1;
    const t_bits: f32 = @floatFromInt((raw >> 1) & 0x7FF); // 11 bits
    const x_bits: f32 = @floatFromInt((raw >> 12) & 0x3FF); // 10 bits
    const y_bits: f32 = @floatFromInt((raw >> 22) & 0x3FF); // 10 bits

    var nx = (x_bits / 1023.0) * 2.0 - 1.0;
    var ny = (y_bits / 1023.0) * 2.0 - 1.0;
    var nz = 1.0 - @abs(nx) - @abs(ny);

    // Octahedron unwrap: if Z < 0, compensate X and Y
    if (nz < 0) {
        const comp = @abs(nz);
        nx += if (nx >= 0) -comp else comp;
        ny += if (ny >= 0) -comp else comp;
    }

    // Normalize
    const len = @sqrt(nx * nx + ny * ny + nz * nz);
    if (len > 0.0001) {
        nx /= len;
        ny /= len;
        nz /= len;
    }

    // Derive tangent from normal
    const tangent_sign: f32 = if (nz >= 0) 1.0 else -1.0;
    const rcp_tz = 1.0 / (tangent_sign + nz);

    const tx = -tangent_sign * (nx * nx) * rcp_tz + 1.0;
    const ty = -tangent_sign * (nx * ny) * rcp_tz;
    const tz = -tangent_sign * nx;

    // Rotate tangent by packed angle
    const tau = 6.283185307;
    const angle = (t_bits / 2047.0) * tau;
    const cos_a = @cos(angle);
    const sin_a = @sin(angle);

    // cross(normal, tangent)
    const cx = ny * tz - nz * ty;
    const cy = nz * tx - nx * tz;
    const cz = nx * ty - ny * tx;

    const rtx = tx * cos_a + cx * sin_a;
    const rty = ty * cos_a + cy * sin_a;
    const rtz = tz * cos_a + cz * sin_a;

    const tw: f32 = if (sign_bit == 0) -1.0 else 1.0;

    return .{
        .{ nx, ny, nz, 0 },
        .{ rtx, rty, rtz, tw },
    };
}

// ============================================================
// Tests
// ============================================================

test "decompressNormal Z-up" {
    // Pack a straight-up normal (0, 0, 1):
    // X = (0 + 1) / 2 * 1023 = 511.5 -> 512
    // Y = (0 + 1) / 2 * 1023 = 511.5 -> 512
    // nz = 1 - 0 - 0 = 1 (positive, no compensation needed)
    const val: u32 =(512 << 22) | (512 << 12) | (0 << 1) | 0;
    const n = decompressNormal(val);

    // Should be approximately (0, 0, 1)
    try std.testing.expect(@abs(n[0]) < 0.01);
    try std.testing.expect(@abs(n[1]) < 0.01);
    try std.testing.expect(n[2] > 0.99);
}

test "decompressNormal X-axis" {
    // Pack a normal pointing along X (1, 0, 0):
    // X = (1 + 1) / 2 * 1023 = 1023
    // Y = (0 + 1) / 2 * 1023 = 512
    // nz = 1 - 1 - 0 = 0
    const val: u32 =(512 << 22) | (1023 << 12) | (0 << 1) | 0;
    const n = decompressNormal(val);

    try std.testing.expect(n[0] > 0.99);
    try std.testing.expect(@abs(n[1]) < 0.01);
    try std.testing.expect(@abs(n[2]) < 0.05);
}
