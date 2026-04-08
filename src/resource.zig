const std = @import("std");
const BinaryReader = @import("binary_reader.zig").BinaryReader;
const BlockType = @import("block_type.zig").BlockType;
const ResourceType = @import("resource_type.zig").ResourceType;
const block_mod = @import("block.zig");
const Block = block_mod.Block;
const BlockData = block_mod.BlockData;

/// Known and expected header version for Source 2 resource files.
pub const known_header_version: u16 = 12;

/// VPK file magic number — if seen, this isn't a resource file.
pub const vpk_magic: u32 = 0x55AA1234;

/// Represents a parsed Valve Source 2 resource file.
pub const Resource = struct {
    allocator: std.mem.Allocator,

    /// Resource file size (from header).
    file_size: u32 = 0,

    /// Header version — should be 12.
    header_version: u16 = 0,

    /// File type version.
    version: u16 = 0,

    /// All parsed blocks.
    blocks: std.ArrayList(Block),

    /// The resource type (determined from extension or edit info).
    resource_type: ResourceType = .unknown,

    /// Source filename, if read from file.
    file_name: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator) Resource {
        return .{
            .allocator = allocator,
            .blocks = std.ArrayList(Block).init(allocator),
        };
    }

    pub fn deinit(self: *Resource) void {
        for (self.blocks.items) |*blk| {
            switch (blk.data) {
                .rerl => |*d| d.deinit(self.allocator),
                .redi => |*d| d.deinit(self.allocator),
                .ntro => |*d| d.deinit(self.allocator),
                .data_block => |*d| d.deinit(self.allocator),
                .kv3_block => |*d| d.deinit(self.allocator),
                .raw => {},
            }
        }
        self.blocks.deinit();
        if (self.file_name) |name| self.allocator.free(name);
    }

    /// Read a resource from a byte slice.
    pub fn read(self: *Resource, data: []const u8) !void {
        var reader = BinaryReader.fromSlice(data, self.allocator);
        try self.readFromReader(&reader);
    }

    /// Read a resource from a file path.
    pub fn readFile(self: *Resource, path: []const u8) !void {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const data = try file.readToEndAlloc(self.allocator, std.math.maxInt(u32));
        defer self.allocator.free(data);

        self.file_name = try self.allocator.dupe(u8, path);

        // Determine resource type from filename
        self.resource_type = ResourceType.fromFileName(path);

        var reader = BinaryReader.fromSlice(data, self.allocator);
        try self.readFromReader(&reader);
    }

    fn readFromReader(self: *Resource, reader: *BinaryReader) !void {
        // Read header
        self.file_size = try reader.readU32();

        // Check for VPK magic
        if (self.file_size == vpk_magic) {
            return error.IsVpkFile;
        }

        self.header_version = try reader.readU16();

        if (self.header_version != known_header_version) {
            return error.UnexpectedHeaderVersion;
        }

        self.version = try reader.readU16();

        const block_offset = try reader.readU32();
        const block_count = try reader.readU32();

        // Advance past block_offset - 8 (the two u32s we just read)
        reader.skip(@as(i64, @intCast(block_offset)) - 8);

        // Pre-allocate block slots to preserve directory order (needed for m_nBlockIndex lookups)
        try self.blocks.resize(block_count);

        // First pass: read block directory entries
        var block_entries = try self.allocator.alloc(BlockDirEntry, block_count);
        defer self.allocator.free(block_entries);

        for (0..block_count) |i| {
            const block_type_raw = try reader.readU32();
            const block_type = BlockType.fromRaw(block_type_raw);

            const pos = reader.position();
            const relative_offset = try reader.readU32();
            const size = try reader.readU32();

            const absolute_offset: u32 = @intCast(@as(u64, @intCast(pos)) + @as(u64, relative_offset));

            block_entries[i] = .{
                .block_type = block_type,
                .offset = absolute_offset,
                .size = size,
                .directory_end_pos = reader.position(),
            };

            // Initialize slot with placeholder
            self.blocks.items[i] = .{
                .block_type = block_type,
                .offset = absolute_offset,
                .size = size,
                .data = .raw,
            };

            if (size == 0) continue;

            // Parse NTRO, REDI, RED2 eagerly (needed to determine ResourceType for DATA)
            switch (block_type) {
                .ntro => {
                    const saved_pos = reader.position();
                    reader.setPosition(absolute_offset);
                    const raw = try reader.readBytesAlloc(size);
                    reader.setPosition(saved_pos);

                    self.blocks.items[i].data = .{ .ntro = .{ .raw_data = raw } };
                },
                .redi => {
                    const redi_data = try block_mod.RediData.read(reader, absolute_offset);
                    self.blocks.items[i].data = .{ .redi = redi_data };

                    // Determine resource type from special dependencies
                    if (self.resource_type == .unknown) {
                        for (redi_data.special_dependencies) |dep| {
                            const rt = ResourceType.fromCompilerIdentifier(dep.compiler_identifier, dep.string);
                            if (rt != .unknown) {
                                self.resource_type = rt;
                                break;
                            }
                        }

                        // Try single input dependency extension
                        if (self.resource_type == .unknown and redi_data.input_dependencies.len == 1) {
                            self.resource_type = ResourceType.fromFileName(redi_data.input_dependencies[0].content_relative_filename);
                        }
                    }
                },
                .red2 => {
                    const saved_pos = reader.position();
                    reader.setPosition(absolute_offset);
                    const raw = try reader.readBytesAlloc(size);
                    reader.setPosition(saved_pos);

                    self.blocks.items[i].data = .{ .kv3_block = .{ .block_type = .red2, .raw_data = raw } };
                },
                else => {},
            }

            reader.setPosition(block_entries[i].directory_end_pos);
        }

        // Second pass: parse remaining blocks (preserving directory order)
        for (block_entries, 0..) |entry, i| {
            if (entry.size == 0) continue;

            // Skip already-parsed blocks
            switch (entry.block_type) {
                .ntro, .redi, .red2 => continue,
                else => {},
            }

            self.blocks.items[i] = try self.parseBlock(reader, entry);
        }
    }

    fn parseBlock(self: *Resource, reader: *BinaryReader, entry: BlockDirEntry) !Block {
        const base = Block{
            .block_type = entry.block_type,
            .offset = entry.offset,
            .size = entry.size,
            .data = undefined,
        };
        _ = base;

        return switch (entry.block_type) {
            .rerl => Block{
                .block_type = entry.block_type,
                .offset = entry.offset,
                .size = entry.size,
                .data = .{ .rerl = try block_mod.RerlData.read(reader, entry.offset) },
            },

            .data => Block{
                .block_type = entry.block_type,
                .offset = entry.offset,
                .size = entry.size,
                .data = .{ .data_block = .{
                    .resource_type = self.resource_type,
                    .raw_data = blk: {
                        reader.setPosition(entry.offset);
                        break :blk try reader.readBytesAlloc(entry.size);
                    },
                } },
            },

            // KV3 blocks
            .ctrl, .insg, .srma, .laco, .stat, .flci, .dstf => Block{
                .block_type = entry.block_type,
                .offset = entry.offset,
                .size = entry.size,
                .data = .{ .kv3_block = .{
                    .block_type = entry.block_type,
                    .raw_data = blk: {
                        reader.setPosition(entry.offset);
                        break :blk try reader.readBytesAlloc(entry.size);
                    },
                } },
            },

            // MVTX, MIDX, MDAT — store raw bytes (needed for embedded mesh decoding)
            .mvtx, .midx, .mdat => Block{
                .block_type = entry.block_type,
                .offset = entry.offset,
                .size = entry.size,
                .data = .{ .data_block = .{
                    .resource_type = self.resource_type,
                    .raw_data = blk: {
                        reader.setPosition(entry.offset);
                        break :blk try reader.readBytesAlloc(entry.size);
                    },
                } },
            },

            // Everything else — store as raw for now
            else => Block{
                .block_type = entry.block_type,
                .offset = entry.offset,
                .size = entry.size,
                .data = .raw,
            },
        };
    }

    // --- Query helpers ---

    /// Get the first block of the given type.
    pub fn getBlockByType(self: *const Resource, block_type: BlockType) ?*const Block {
        for (self.blocks.items) |*blk| {
            if (blk.block_type == block_type) return blk;
        }
        return null;
    }

    /// Get a block by its index in the block list (matches C# Resource.GetBlockByIndex).
    pub fn getBlockByIndex(self: *const Resource, index: usize) ?*const Block {
        if (index < self.blocks.items.len) return &self.blocks.items[index];
        return null;
    }

    /// Check if the resource contains a block of the given type.
    pub fn containsBlockType(self: *const Resource, block_type: BlockType) bool {
        return self.getBlockByType(block_type) != null;
    }

    /// Get the external references block, if present.
    pub fn externalReferences(self: *const Resource) ?*const block_mod.RerlData {
        const blk = self.getBlockByType(.rerl) orelse return null;
        return switch (blk.data) {
            .rerl => |*d| d,
            else => null,
        };
    }

    /// Get the DATA block, if present.
    pub fn dataBlock(self: *const Resource) ?*const Block {
        return self.getBlockByType(.data);
    }
};

const BlockDirEntry = struct {
    block_type: BlockType,
    offset: u32,
    size: u32,
    directory_end_pos: u64,
};

// ============================================================
// Tests
// ============================================================

test "Resource parse minimal valid header" {
    // Construct a minimal valid resource file:
    // Header: file_size(4) + header_version(2) + version(2) + block_offset(4) + block_count(4) = 16 bytes
    // No blocks
    var buf: [16]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();

    try w.writeInt(u32, 16, .little); // file_size
    try w.writeInt(u16, 12, .little); // header_version
    try w.writeInt(u16, 0, .little); // version
    try w.writeInt(u32, 8, .little); // block_offset (skip 0 extra bytes)
    try w.writeInt(u32, 0, .little); // block_count

    var resource = Resource.init(std.testing.allocator);
    defer resource.deinit();

    try resource.read(&buf);

    try std.testing.expectEqual(@as(u32, 16), resource.file_size);
    try std.testing.expectEqual(@as(u16, 12), resource.header_version);
    try std.testing.expectEqual(@as(u32, 0), @as(u32, @intCast(resource.blocks.items.len)));
}

test "Resource rejects VPK magic" {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, vpk_magic, .little);

    var resource = Resource.init(std.testing.allocator);
    defer resource.deinit();

    try std.testing.expectError(error.IsVpkFile, resource.read(&buf));
}

test "Resource rejects wrong header version" {
    var buf: [16]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();

    try w.writeInt(u32, 16, .little);
    try w.writeInt(u16, 99, .little); // wrong version
    try w.writeInt(u16, 0, .little);
    try w.writeInt(u32, 8, .little);
    try w.writeInt(u32, 0, .little);

    var resource = Resource.init(std.testing.allocator);
    defer resource.deinit();

    try std.testing.expectError(error.UnexpectedHeaderVersion, resource.read(&buf));
}
