const std = @import("std");
const BinaryReader = @import("binary_reader.zig").BinaryReader;
const BlockType = @import("block_type.zig").BlockType;
const ResourceType = @import("resource_type.zig").ResourceType;

/// Parsed block data — a tagged union over all known block types.
pub const Block = struct {
    /// The block type tag.
    block_type: BlockType,

    /// Offset to the block data in the file.
    offset: u32,

    /// Size of the block data in bytes.
    size: u32,

    /// The parsed block content.
    data: BlockData,
};

/// Union of all block data payloads.
/// Initially only metadata blocks are implemented; resource-specific
/// blocks will be added as we port more of VRF.
pub const BlockData = union(enum) {
    /// Not yet parsed / unknown block type — raw bytes available via offset+size.
    raw,

    /// RERL — external resource reference list.
    rerl: RerlData,

    /// REDI — legacy resource edit info (binary format).
    redi: RediData,

    /// NTRO — resource introspection manifest (placeholder).
    ntro: NtroData,

    /// DATA — the main data block. Type depends on ResourceType.
    /// For now, stored as raw until resource-type-specific parsers exist.
    data_block: DataBlockData,

    /// Generic KV3 block (CTRL, INSG, SrMa, LaCo, STAT, FLCI, DSTF, RED2, etc.)
    kv3_block: Kv3BlockData,
};

// ============================================================
// RERL — Resource External Reference List
// ============================================================

pub const ResourceReferenceInfo = struct {
    id: u64,
    name: []const u8,
};

pub const RerlData = struct {
    resource_ref_info_list: []ResourceReferenceInfo,

    pub fn deinit(self: *RerlData, allocator: std.mem.Allocator) void {
        for (self.resource_ref_info_list) |ref_info| {
            allocator.free(ref_info.name);
        }
        allocator.free(self.resource_ref_info_list);
    }

    pub fn read(reader: *BinaryReader, offset: u32) !RerlData {
        reader.setPosition(offset);

        const entries_offset = try reader.readU32();
        const count = try reader.readU32();

        if (count == 0) {
            return RerlData{ .resource_ref_info_list = &.{} };
        }

        // Jump to entries: offset field + entries_offset - 8
        const entries_pos = @as(u64, offset) + entries_offset;
        reader.setPosition(entries_pos);

        var list = try reader.allocator.alloc(ResourceReferenceInfo, @intCast(count));
        errdefer reader.allocator.free(list);

        for (0..@intCast(count)) |i| {
            const id = try reader.readU64();
            const prev_pos = reader.position();

            // String offset is relative to current position
            const str_offset = try reader.readI64();
            const str_pos: u64 = @intCast(@as(i64, @intCast(prev_pos)) + str_offset);
            reader.setPosition(str_pos);

            const name = try reader.readNullTermString();

            reader.setPosition(prev_pos + 8); // past the i64 string offset

            list[i] = .{
                .id = id,
                .name = name,
            };
        }

        return RerlData{ .resource_ref_info_list = list };
    }

    /// Look up a resource name by its ID.
    pub fn getNameById(self: *const RerlData, id: u64) ?[]const u8 {
        for (self.resource_ref_info_list) |ref_info| {
            if (ref_info.id == id) return ref_info.name;
        }
        return null;
    }
};

// ============================================================
// REDI — Resource Edit Info (legacy binary format)
// ============================================================

pub const InputDependency = struct {
    content_relative_filename: []const u8,
    content_search_path: []const u8,
    file_crc: u32,
    optional: bool,
    file_exists: bool,
    is_game_file: bool,
};

pub const SpecialDependency = struct {
    string: []const u8,
    compiler_identifier: []const u8,
    fingerprint: u32,
    user_data: u32,
};

pub const ArgumentDependency = struct {
    parameter_name: []const u8,
    parameter_type: []const u8,
    fingerprint: u32,
    fingerprint_default: u32,
};

pub const AdditionalRelatedFile = struct {
    content_relative_filename: []const u8,
    content_search_path: []const u8,
};

pub const RediData = struct {
    input_dependencies: []InputDependency,
    additional_input_dependencies: []InputDependency,
    argument_dependencies: []ArgumentDependency,
    special_dependencies: []SpecialDependency,
    additional_related_files: []AdditionalRelatedFile,
    child_resource_list: [][]const u8,

    pub fn deinit(self: *RediData, allocator: std.mem.Allocator) void {
        for (self.input_dependencies) |dep| {
            allocator.free(dep.content_relative_filename);
            allocator.free(dep.content_search_path);
        }
        allocator.free(self.input_dependencies);

        for (self.additional_input_dependencies) |dep| {
            allocator.free(dep.content_relative_filename);
            allocator.free(dep.content_search_path);
        }
        allocator.free(self.additional_input_dependencies);

        for (self.argument_dependencies) |dep| {
            allocator.free(dep.parameter_name);
            allocator.free(dep.parameter_type);
        }
        allocator.free(self.argument_dependencies);

        for (self.special_dependencies) |dep| {
            allocator.free(dep.string);
            allocator.free(dep.compiler_identifier);
        }
        allocator.free(self.special_dependencies);

        for (self.additional_related_files) |f| {
            allocator.free(f.content_relative_filename);
            allocator.free(f.content_search_path);
        }
        allocator.free(self.additional_related_files);

        for (self.child_resource_list) |name| {
            allocator.free(name);
        }
        allocator.free(self.child_resource_list);
    }

    pub fn read(reader: *BinaryReader, offset: u32) !RediData {
        var sub_block: u32 = 0;

        const ReadCountResult = struct { count: u32 };

        const advanceGetCount = struct {
            fn call(r: *BinaryReader, off: u32, sb: *u32) !ReadCountResult {
                const base = @as(u64, off) + @as(u64, sb.*) * 8;
                r.setPosition(base);
                const entry_offset = try r.readU32();
                const count = try r.readU32();
                r.setPosition(base + @as(u64, entry_offset));
                sb.* += 1;
                return .{ .count = count };
            }
        }.call;

        // Sub-block 0: Input dependencies
        const input_deps = blk: {
            const result = try advanceGetCount(reader, offset, &sub_block);
            var list = try reader.allocator.alloc(InputDependency, result.count);
            errdefer reader.allocator.free(list);
            for (0..result.count) |i| {
                list[i] = .{
                    .content_relative_filename = try reader.readOffsetString(),
                    .content_search_path = try reader.readOffsetString(),
                    .file_crc = try reader.readU32(),
                    .optional = (try reader.readU32() & 1) != 0,
                    .file_exists = false, // flags packed in same u32
                    .is_game_file = false,
                };
            }
            break :blk list;
        };

        // Sub-block 1: Additional input dependencies
        const addl_input_deps = blk: {
            const result = try advanceGetCount(reader, offset, &sub_block);
            var list = try reader.allocator.alloc(InputDependency, result.count);
            errdefer reader.allocator.free(list);
            for (0..result.count) |i| {
                list[i] = .{
                    .content_relative_filename = try reader.readOffsetString(),
                    .content_search_path = try reader.readOffsetString(),
                    .file_crc = try reader.readU32(),
                    .optional = (try reader.readU32() & 1) != 0,
                    .file_exists = false,
                    .is_game_file = false,
                };
            }
            break :blk list;
        };

        // Sub-block 2: Argument dependencies
        const arg_deps = blk: {
            const result = try advanceGetCount(reader, offset, &sub_block);
            var list = try reader.allocator.alloc(ArgumentDependency, result.count);
            errdefer reader.allocator.free(list);
            for (0..result.count) |i| {
                list[i] = .{
                    .parameter_name = try reader.readOffsetString(),
                    .parameter_type = try reader.readOffsetString(),
                    .fingerprint = try reader.readU32(),
                    .fingerprint_default = try reader.readU32(),
                };
            }
            break :blk list;
        };

        // Sub-block 3: Special dependencies
        const special_deps = blk: {
            const result = try advanceGetCount(reader, offset, &sub_block);
            var list = try reader.allocator.alloc(SpecialDependency, result.count);
            errdefer reader.allocator.free(list);
            for (0..result.count) |i| {
                list[i] = .{
                    .string = try reader.readOffsetString(),
                    .compiler_identifier = try reader.readOffsetString(),
                    .fingerprint = try reader.readU32(),
                    .user_data = try reader.readU32(),
                };
            }
            break :blk list;
        };

        // Sub-block 4: Custom dependencies (skip, not implemented in VRF either)
        {
            const result = try advanceGetCount(reader, offset, &sub_block);
            if (result.count > 0) {
                return error.CustomDependenciesNotImplemented;
            }
        }

        // Sub-block 5: Additional related files
        const addl_related = blk: {
            const result = try advanceGetCount(reader, offset, &sub_block);
            var list = try reader.allocator.alloc(AdditionalRelatedFile, result.count);
            errdefer reader.allocator.free(list);
            for (0..result.count) |i| {
                list[i] = .{
                    .content_relative_filename = try reader.readOffsetString(),
                    .content_search_path = try reader.readOffsetString(),
                };
            }
            break :blk list;
        };

        // Sub-block 6: Child resource list
        const child_resources = blk: {
            const result = try advanceGetCount(reader, offset, &sub_block);
            var list = try reader.allocator.alloc([]const u8, result.count);
            errdefer reader.allocator.free(list);
            for (0..result.count) |i| {
                _ = try reader.readU64(); // id (ignored to match RED2)
                const name = try reader.readOffsetString();
                _ = try reader.readI32(); // unknown
                list[i] = name;
            }
            break :blk list;
        };

        // Sub-blocks 7,8,9: Searchable user data (int, float, string KV pairs) — skip for now
        // We'd need a KV structure to store these; deferring to KV3 implementation

        return RediData{
            .input_dependencies = input_deps,
            .additional_input_dependencies = addl_input_deps,
            .argument_dependencies = arg_deps,
            .special_dependencies = special_deps,
            .additional_related_files = addl_related,
            .child_resource_list = child_resources,
        };
    }
};

// ============================================================
// NTRO — Resource Introspection Manifest (placeholder)
// ============================================================

pub const NtroData = struct {
    // Will contain struct/enum definitions when fully implemented.
    // For now just a marker that the block was recognized.
    raw_data: ?[]const u8 = null,

    pub fn deinit(self: *NtroData, allocator: std.mem.Allocator) void {
        if (self.raw_data) |data| allocator.free(data);
    }
};

// ============================================================
// DATA — Main data block (type depends on ResourceType)
// ============================================================

pub const DataBlockData = struct {
    /// The resource type this data block represents.
    resource_type: ResourceType = .unknown,
    /// Raw bytes for now — will be replaced by typed data per resource type.
    raw_data: ?[]const u8 = null,

    pub fn deinit(self: *DataBlockData, allocator: std.mem.Allocator) void {
        if (self.raw_data) |data| allocator.free(data);
    }
};

// ============================================================
// KV3 block placeholder (CTRL, INSG, etc.)
// ============================================================

pub const Kv3BlockData = struct {
    /// Which block type this KV3 data came from.
    block_type: BlockType,
    /// Raw bytes — will be parsed by KV3 decoder later.
    raw_data: ?[]const u8 = null,

    pub fn deinit(self: *Kv3BlockData, allocator: std.mem.Allocator) void {
        if (self.raw_data) |data| allocator.free(data);
    }
};
