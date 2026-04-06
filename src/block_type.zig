/// Resource file block types.
/// Values are encoded as 4-byte ASCII packed into a u32 (little-endian).
pub const BlockType = enum(u32) {
    /// Undefined or unknown block type.
    undefined = 0,

    /// Resource External Reference List.
    rerl = cc("RERL"),

    /// Resource Edit Info.
    redi = cc("REDI"),

    /// Resource Edit Info 2 (KV3 format).
    red2 = cc("RED2"),

    /// Resource Introspection Manifest.
    ntro = cc("NTRO"),

    /// Resource Data — the main data block.
    data = cc("DATA"),

    /// Vertex and Index Buffer Information.
    vbib = cc("VBIB"),

    /// Voxel Visibility.
    vxvs = cc("VXVS"),

    /// Particle Snapshot.
    snap = cc("SNAP"),

    /// Control Data (KV3).
    ctrl = cc("CTRL"),

    /// Mesh Data.
    mdat = cc("MDAT"),

    /// Morph Data.
    mrph = cc("MRPH"),

    /// Mesh Buffer (alternative vertex/index format).
    mbuf = cc("MBUF"),

    /// Animation Data.
    anim = cc("ANIM"),

    /// Animation Sequence.
    aseq = cc("ASEQ"),

    /// Animation Group.
    agrp = cc("AGRP"),

    /// Physics Aggregate Data.
    phys = cc("PHYS"),

    /// Input Signature.
    insg = cc("INSG"),

    /// Source Map (Panorama CSS).
    srma = cc("SrMa"),

    /// Layout Content (Panorama VXML AST).
    laco = cc("LaCo"),

    /// Statistics (Panorama JS metadata).
    stat = cc("STAT"),

    /// SPIR-V Shader (S&box).
    sprv = cc("SPRV"),

    /// File/Line/Column Info.
    flci = cc("FLCI"),

    /// Distance Field.
    dstf = cc("DSTF"),

    /// Tools Buffer.
    tbuf = cc("TBUF"),

    /// Mesh Vertex Buffer.
    mvtx = cc("MVTX"),

    /// Mesh Index Buffer.
    midx = cc("MIDX"),

    /// Mesh Adjacency Buffer.
    madj = cc("MADJ"),

    _,

    /// Pack 4 ASCII characters into a little-endian u32 at comptime.
    fn cc(comptime tag: *const [4]u8) u32 {
        return @as(u32, tag[0]) |
            (@as(u32, tag[1]) << 8) |
            (@as(u32, tag[2]) << 16) |
            (@as(u32, tag[3]) << 24);
    }

    /// Return the 4-byte ASCII tag for display/debug.
    pub fn toTag(self: BlockType) [4]u8 {
        const raw: u32 = @intFromEnum(self);
        return .{
            @truncate(raw),
            @truncate(raw >> 8),
            @truncate(raw >> 16),
            @truncate(raw >> 24),
        };
    }

    pub fn format(self: BlockType, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        const tag = self.toTag();
        if (@intFromEnum(self) == 0) {
            try writer.writeAll("Undefined");
        } else {
            try writer.writeAll(&tag);
        }
    }

    /// Check if a raw u32 maps to a known block type.
    pub fn fromRaw(raw: u32) BlockType {
        return @enumFromInt(raw);
    }
};

const std = @import("std");

test "BlockType tag roundtrip" {
    const rerl = BlockType.rerl;
    const tag = rerl.toTag();
    try std.testing.expectEqualStrings("RERL", &tag);

    const data = BlockType.data;
    try std.testing.expectEqualStrings("DATA", &data.toTag());

    // Mixed case
    const srma = BlockType.srma;
    try std.testing.expectEqualStrings("SrMa", &srma.toTag());
}

test "BlockType from raw" {
    const raw: u32 = @as(u32, 'D') | (@as(u32, 'A') << 8) | (@as(u32, 'T') << 16) | (@as(u32, 'A') << 24);
    const bt = BlockType.fromRaw(raw);
    try std.testing.expectEqual(BlockType.data, bt);
}
