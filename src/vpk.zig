const std = @import("std");
const BinaryReader = @import("binary_reader.zig").BinaryReader;

/// VPK file magic number.
pub const MAGIC: u32 = 0x55AA1234;

/// Special archive index meaning data is embedded in the _dir.vpk itself.
pub const DIR_PAK_INDEX: u16 = 0x7FFF;

/// Entry terminator value.
const ENTRY_TERMINATOR: u16 = 0xFFFF;

/// A single file entry within a VPK archive.
pub const PackageEntry = struct {
    /// Filename without extension.
    file_name: []const u8,
    /// Directory path (lowercase, "/" separators). " " = root.
    directory_name: []const u8,
    /// File extension (without dot). " " = no extension.
    type_name: []const u8,
    /// CRC32 of the full file content.
    crc32: u32,
    /// Preloaded data stored inline in the directory.
    small_data: []const u8,
    /// Archive file index (0x7FFF = data in _dir.vpk).
    archive_index: u16,
    /// Byte offset within the archive file.
    offset: u32,
    /// Length of file data in the archive (excluding small_data).
    length: u32,

    /// Total file size (small_data + archive data).
    pub fn totalLength(self: *const PackageEntry) u64 {
        return @as(u64, self.small_data.len) + @as(u64, self.length);
    }

    /// Get the full path: "directory/filename.extension"
    pub fn getFullPath(self: *const PackageEntry, allocator: std.mem.Allocator) ![]const u8 {
        var parts = std.ArrayList(u8).init(allocator);
        errdefer parts.deinit();

        // Directory
        if (!std.mem.eql(u8, self.directory_name, " ")) {
            try parts.appendSlice(self.directory_name);
            try parts.append('/');
        }

        // Filename
        try parts.appendSlice(self.file_name);

        // Extension
        if (!std.mem.eql(u8, self.type_name, " ")) {
            try parts.append('.');
            try parts.appendSlice(self.type_name);
        }

        return parts.toOwnedSlice();
    }
};

/// VPK archive reader.
/// Reads the directory VPK (_dir.vpk) and provides access to all file entries.
pub const Package = struct {
    allocator: std.mem.Allocator,

    // Header fields
    version: u32 = 0,
    tree_size: u32 = 0,
    header_size: u32 = 0,
    file_data_section_size: u32 = 0, // v2 only
    archive_md5_section_size: u32 = 0, // v2 only
    other_md5_section_size: u32 = 0, // v2 only
    signature_section_size: u32 = 0, // v2 only

    /// All entries grouped by extension (type_name -> list of entries).
    entries: std.StringHashMap(std.ArrayList(PackageEntry)),

    /// The raw data of the _dir.vpk (kept for reading embedded file data).
    dir_data: ?[]const u8 = null,

    /// The base filename for resolving archive files (e.g. "/path/to/pak01_dir").
    /// Used to construct "/path/to/pak01_000.vpk", etc.
    base_path: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator) Package {
        return .{
            .allocator = allocator,
            .entries = std.StringHashMap(std.ArrayList(PackageEntry)).init(allocator),
        };
    }

    pub fn deinit(self: *Package) void {
        var iter = self.entries.iterator();
        while (iter.next()) |kv| {
            for (kv.value_ptr.items) |entry| {
                self.allocator.free(entry.file_name);
                self.allocator.free(entry.directory_name);
                // type_name is shared key — freed below
                if (entry.small_data.len > 0) self.allocator.free(entry.small_data);
            }
            kv.value_ptr.deinit();
            self.allocator.free(kv.key_ptr.*);
        }
        self.entries.deinit();
        if (self.dir_data) |d| self.allocator.free(d);
        if (self.base_path) |p| self.allocator.free(p);
    }

    /// Read a VPK from a file path. The path should be the _dir.vpk file.
    pub fn readFile(self: *Package, path: []const u8) !void {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const stat = try file.stat();
        const data = try self.allocator.alloc(u8, stat.size);
        errdefer self.allocator.free(data);

        const bytes_read = try file.readAll(data);
        if (bytes_read != stat.size) return error.UnexpectedEof;

        // Store base path for archive file resolution
        self.base_path = try deriveBasePath(self.allocator, path);
        self.dir_data = data;

        var reader = BinaryReader.fromSlice(data, self.allocator);
        try self.readFromReader(&reader);
    }

    /// Read a VPK from a byte slice (e.g. for testing or embedded data).
    pub fn read(self: *Package, data: []const u8) !void {
        // Make our own copy so we can hold onto it
        const owned = try self.allocator.dupe(u8, data);
        errdefer self.allocator.free(owned);

        var reader = BinaryReader.fromSlice(owned, self.allocator);
        try self.readFromReader(&reader);

        // Only store after successful parse
        self.dir_data = owned;
    }

    fn readFromReader(self: *Package, reader: *BinaryReader) !void {
        // Read and validate magic
        const magic = try reader.readU32();
        if (magic != MAGIC) return error.InvalidVpkMagic;

        self.version = try reader.readU32();
        self.tree_size = try reader.readU32();

        if (self.version == 1) {
            // No additional header fields
        } else if (self.version == 2) {
            self.file_data_section_size = try reader.readU32();
            self.archive_md5_section_size = try reader.readU32();
            self.other_md5_section_size = try reader.readU32();
            self.signature_section_size = try reader.readU32();
        } else {
            return error.UnsupportedVpkVersion;
        }

        self.header_size = @intCast(reader.position());

        // Read directory tree
        try self.readEntries(reader);
    }

    fn readEntries(self: *Package, reader: *BinaryReader) !void {
        // 3-level nested null-terminated string tree:
        // Extension -> Directory -> Filename -> entry metadata
        while (true) {
            const type_name = try reader.readNullTermString();

            if (type_name.len == 0) {
                self.allocator.free(type_name);
                break;
            }

            // Get or create entry list for this extension
            const gop = try self.entries.getOrPut(type_name);
            if (gop.found_existing) {
                // Already have this extension — free the dupe
                self.allocator.free(type_name);
            } else {
                gop.value_ptr.* = std.ArrayList(PackageEntry).init(self.allocator);
            }
            const type_key = gop.key_ptr.*;

            while (true) {
                const directory_name = try reader.readNullTermString();

                if (directory_name.len == 0) {
                    self.allocator.free(directory_name);
                    break;
                }

                while (true) {
                    const file_name = try reader.readNullTermString();

                    if (file_name.len == 0) {
                        self.allocator.free(file_name);
                        break;
                    }

                    const crc32 = try reader.readU32();
                    const small_data_size = try reader.readU16();
                    const archive_index = try reader.readU16();
                    const offset = try reader.readU32();
                    const length = try reader.readU32();
                    const terminator = try reader.readU16();

                    if (terminator != ENTRY_TERMINATOR) {
                        return error.InvalidEntryTerminator;
                    }

                    const small_data: []const u8 = if (small_data_size > 0)
                        try reader.readBytesAlloc(small_data_size)
                    else
                        &.{};

                    const dir_dupe = try self.allocator.dupe(u8, directory_name);

                    try gop.value_ptr.append(.{
                        .file_name = file_name,
                        .directory_name = dir_dupe,
                        .type_name = type_key,
                        .crc32 = crc32,
                        .small_data = small_data,
                        .archive_index = archive_index,
                        .offset = offset,
                        .length = length,
                    });
                }

                self.allocator.free(directory_name);
            }
        }
    }

    // --- Query methods ---

    /// Find an entry by its full path (e.g. "models/weapon/rifle.mdl").
    /// Handles backslash normalization and case-insensitive matching.
    pub fn findEntry(self: *const Package, file_path: []const u8) ?*const PackageEntry {
        // Normalize path separators (replace \ with /)
        var normalized: [1024]u8 = undefined;
        const len = @min(file_path.len, normalized.len);
        for (file_path[0..len], 0..) |c, i| {
            normalized[i] = if (c == '\\') '/' else c;
        }
        const path = normalized[0..len];

        // Split into directory, filename, extension
        const last_sep = std.mem.lastIndexOfScalar(u8, path, '/');
        const after_sep = if (last_sep) |s| path[s + 1 ..] else path;
        var directory: []const u8 = if (last_sep) |s| path[0..s] else " ";

        // Trim leading/trailing slashes from directory
        if (last_sep != null) {
            var d = directory;
            while (d.len > 0 and d[0] == '/') d = d[1..];
            while (d.len > 0 and d[d.len - 1] == '/') d = d[0 .. d.len - 1];
            directory = if (d.len == 0) " " else d;
        }

        // Split filename and extension
        const dot = std.mem.lastIndexOfScalar(u8, after_sep, '.');
        const file_name = if (dot) |d| after_sep[0..d] else after_sep;
        const extension = if (dot) |d| after_sep[d + 1 ..] else " ";

        // Look up by extension
        const entry_list = self.entries.get(extension) orelse return null;

        // Linear search for matching directory + filename
        for (entry_list.items) |*entry| {
            if (std.ascii.eqlIgnoreCase(entry.directory_name, directory) and
                std.ascii.eqlIgnoreCase(entry.file_name, file_name))
            {
                return entry;
            }
        }

        return null;
    }

    /// Get total number of entries across all extensions.
    pub fn entryCount(self: *const Package) usize {
        var count: usize = 0;
        var iter = self.entries.iterator();
        while (iter.next()) |kv| {
            count += kv.value_ptr.items.len;
        }
        return count;
    }

    /// Read the data for an entry. Returns allocated bytes (caller owns).
    /// For archive_index != 0x7FFF, reads from external archive files.
    /// For archive_index == 0x7FFF, reads from the dir VPK data.
    pub fn readEntry(self: *const Package, entry: *const PackageEntry) ![]u8 {
        const total: usize = @intCast(entry.totalLength());
        const output = try self.allocator.alloc(u8, total);
        errdefer self.allocator.free(output);

        // Copy small data first
        if (entry.small_data.len > 0) {
            @memcpy(output[0..entry.small_data.len], entry.small_data);
        }

        // Read main data
        if (entry.length > 0) {
            if (entry.archive_index == DIR_PAK_INDEX) {
                // Data is in the _dir.vpk itself, after header + tree
                const dir = self.dir_data orelse return error.NoDirData;
                const data_start = @as(usize, self.header_size) + @as(usize, self.tree_size) + @as(usize, entry.offset);
                const data_end = data_start + @as(usize, entry.length);

                if (data_end > dir.len) return error.UnexpectedEof;

                @memcpy(output[entry.small_data.len..][0..entry.length], dir[data_start..data_end]);
            } else {
                // Data is in an external archive file
                const archive_path = try self.getArchivePath(entry.archive_index);
                defer self.allocator.free(archive_path);

                const file = try std.fs.cwd().openFile(archive_path, .{});
                defer file.close();

                try file.seekTo(entry.offset);
                const dest = output[entry.small_data.len..][0..entry.length];
                const bytes_read = try file.readAll(dest);
                if (bytes_read != entry.length) return error.UnexpectedEof;
            }
        }

        return output;
    }

    fn getArchivePath(self: *const Package, archive_index: u16) ![]const u8 {
        const base = self.base_path orelse return error.NoBasePath;

        // Format: base_XXX.vpk
        var buf: [8]u8 = undefined;
        const suffix = std.fmt.bufPrint(&buf, "_{d:0>3}.vpk", .{archive_index}) catch return error.FormatError;

        const path = try self.allocator.alloc(u8, base.len + suffix.len);
        @memcpy(path[0..base.len], base);
        @memcpy(path[base.len..], suffix);
        return path;
    }

    /// Iterate over all entries across all extensions.
    pub fn iterateAll(self: *const Package) EntryIterator {
        return EntryIterator.init(self);
    }
};

pub const EntryIterator = struct {
    map_iter: std.StringHashMap(std.ArrayList(PackageEntry)).Iterator,
    current_list: ?[]const PackageEntry = null,
    index: usize = 0,

    fn init(pkg: *const Package) EntryIterator {
        return .{ .map_iter = pkg.entries.iterator() };
    }

    pub fn next(self: *EntryIterator) ?*const PackageEntry {
        while (true) {
            if (self.current_list) |list| {
                if (self.index < list.len) {
                    const entry = &list[self.index];
                    self.index += 1;
                    return entry;
                }
            }
            // Advance to next extension group
            const kv = self.map_iter.next() orelse return null;
            self.current_list = kv.value_ptr.items;
            self.index = 0;
        }
    }
};

/// Derive the base path from a _dir.vpk path.
/// E.g. "/game/csgo/pak01_dir.vpk" -> "/game/csgo/pak01"
fn deriveBasePath(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    // Strip .vpk extension
    const without_ext = if (std.mem.endsWith(u8, path, ".vpk"))
        path[0 .. path.len - 4]
    else
        path;

    // Strip _dir suffix
    const base = if (std.mem.endsWith(u8, without_ext, "_dir"))
        without_ext[0 .. without_ext.len - 4]
    else
        without_ext;

    return try allocator.dupe(u8, base);
}

// ============================================================
// Tests
// ============================================================

fn buildTestVpk(allocator: std.mem.Allocator) ![]u8 {
    // Build a minimal v1 VPK with one file: "test/hello.txt" containing "Hello!"
    var buf = std.ArrayList(u8).init(allocator);
    const w = buf.writer();

    // Header
    try w.writeInt(u32, MAGIC, .little); // magic
    try w.writeInt(u32, 1, .little); // version
    // tree_size placeholder — we'll patch it
    const tree_size_pos = buf.items.len;
    try w.writeInt(u32, 0, .little); // tree_size (placeholder)

    const tree_start = buf.items.len;

    // Extension: "txt\0"
    try w.writeAll("txt\x00");

    // Directory: "test\0"
    try w.writeAll("test\x00");

    // Filename: "hello\0"
    try w.writeAll("hello\x00");

    // Entry metadata (18 bytes)
    try w.writeInt(u32, 0, .little); // crc32 (not checked in this test)
    try w.writeInt(u16, 6, .little); // small_data_size = 6 ("Hello!")
    try w.writeInt(u16, DIR_PAK_INDEX, .little); // archive_index (embedded)
    try w.writeInt(u32, 0, .little); // offset
    try w.writeInt(u32, 0, .little); // length (all data is in small_data)
    try w.writeInt(u16, ENTRY_TERMINATOR, .little); // terminator

    // Small data: "Hello!"
    try w.writeAll("Hello!");

    // End filenames
    try w.writeByte(0);
    // End directories
    try w.writeByte(0);
    // End extensions
    try w.writeByte(0);

    const tree_end = buf.items.len;

    // Patch tree_size
    std.mem.writeInt(u32, buf.items[tree_size_pos..][0..4], @intCast(tree_end - tree_start), .little);

    return buf.toOwnedSlice();
}

test "VPK parse minimal v1 package" {
    const data = try buildTestVpk(std.testing.allocator);
    defer std.testing.allocator.free(data);

    var pkg = Package.init(std.testing.allocator);
    defer pkg.deinit();

    try pkg.read(data);

    try std.testing.expectEqual(@as(u32, 1), pkg.version);
    try std.testing.expectEqual(@as(usize, 1), pkg.entryCount());

    // Find by path
    const entry = pkg.findEntry("test/hello.txt");
    try std.testing.expect(entry != null);

    const e = entry.?;
    try std.testing.expectEqualStrings("hello", e.file_name);
    try std.testing.expectEqualStrings("test", e.directory_name);
    try std.testing.expectEqualStrings("txt", e.type_name);
    try std.testing.expectEqual(@as(u64, 6), e.totalLength());
    try std.testing.expectEqualStrings("Hello!", e.small_data);
}

test "VPK findEntry path normalization" {
    const data = try buildTestVpk(std.testing.allocator);
    defer std.testing.allocator.free(data);

    var pkg = Package.init(std.testing.allocator);
    defer pkg.deinit();

    try pkg.read(data);

    // Backslash normalization
    try std.testing.expect(pkg.findEntry("test\\hello.txt") != null);

    // Case insensitive
    try std.testing.expect(pkg.findEntry("TEST/HELLO.txt") != null);

    // Non-existent
    try std.testing.expect(pkg.findEntry("nope/nah.txt") == null);
}

test "VPK readEntry with small_data" {
    const data = try buildTestVpk(std.testing.allocator);
    defer std.testing.allocator.free(data);

    var pkg = Package.init(std.testing.allocator);
    defer pkg.deinit();

    try pkg.read(data);

    const entry = pkg.findEntry("test/hello.txt").?;
    const content = try pkg.readEntry(entry);
    defer std.testing.allocator.free(content);

    try std.testing.expectEqualStrings("Hello!", content);
}

test "VPK getFullPath" {
    const entry = PackageEntry{
        .file_name = "rifle",
        .directory_name = "models/weapon",
        .type_name = "mdl",
        .crc32 = 0,
        .small_data = &.{},
        .archive_index = 0,
        .offset = 0,
        .length = 0,
    };

    const path = try entry.getFullPath(std.testing.allocator);
    defer std.testing.allocator.free(path);

    try std.testing.expectEqualStrings("models/weapon/rifle.mdl", path);
}

test "VPK getFullPath root directory" {
    const entry = PackageEntry{
        .file_name = "readme",
        .directory_name = " ",
        .type_name = "txt",
        .crc32 = 0,
        .small_data = &.{},
        .archive_index = 0,
        .offset = 0,
        .length = 0,
    };

    const path = try entry.getFullPath(std.testing.allocator);
    defer std.testing.allocator.free(path);

    try std.testing.expectEqualStrings("readme.txt", path);
}

test "VPK reject invalid magic" {
    var data: [12]u8 = undefined;
    std.mem.writeInt(u32, data[0..4], 0xDEADBEEF, .little);
    std.mem.writeInt(u32, data[4..8], 1, .little);
    std.mem.writeInt(u32, data[8..12], 0, .little);

    var pkg = Package.init(std.testing.allocator);
    defer pkg.deinit();

    try std.testing.expectError(error.InvalidVpkMagic, pkg.read(&data));
}

test "VPK reject unsupported version" {
    var data: [12]u8 = undefined;
    std.mem.writeInt(u32, data[0..4], MAGIC, .little);
    std.mem.writeInt(u32, data[4..8], 99, .little);
    std.mem.writeInt(u32, data[8..12], 0, .little);

    var pkg = Package.init(std.testing.allocator);
    defer pkg.deinit();

    try std.testing.expectError(error.UnsupportedVpkVersion, pkg.read(&data));
}

test "VPK iterate all entries" {
    const data = try buildTestVpk(std.testing.allocator);
    defer std.testing.allocator.free(data);

    var pkg = Package.init(std.testing.allocator);
    defer pkg.deinit();

    try pkg.read(data);

    var it = pkg.iterateAll();
    var count: usize = 0;
    while (it.next()) |_| count += 1;

    try std.testing.expectEqual(@as(usize, 1), count);
}

test "VPK deriveBasePath" {
    const p1 = try deriveBasePath(std.testing.allocator, "/game/csgo/pak01_dir.vpk");
    defer std.testing.allocator.free(p1);
    try std.testing.expectEqualStrings("/game/csgo/pak01", p1);

    const p2 = try deriveBasePath(std.testing.allocator, "pak01_dir.vpk");
    defer std.testing.allocator.free(p2);
    try std.testing.expectEqualStrings("pak01", p2);
}
