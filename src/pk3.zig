//! PK3 (ZIP) archive reader for Quake 3 game data.
//!
//! PK3 files are standard ZIP archives containing textures, shader scripts,
//! sounds, and other game assets. This reader provides random access to
//! entries by path with case-insensitive lookup.

const std = @import("std");

pub const Pk3 = struct {
    allocator: std.mem.Allocator,
    data: []const u8,
    entries: std.StringArrayHashMap(Entry),

    pub const Entry = struct {
        /// Offset of the local file header in the archive.
        local_header_offset: u32,
        compressed_size: u32,
        uncompressed_size: u32,
        compression_method: std.zip.CompressionMethod,
        crc32: u32,
    };

    pub fn deinit(self: *Pk3) void {
        for (self.entries.keys()) |k| {
            self.allocator.free(k);
        }
        self.entries.deinit();
    }

    /// Open a PK3 archive from raw file data (the entire file loaded in memory).
    pub fn read(allocator: std.mem.Allocator, data: []const u8) !Pk3 {
        // Find the End of Central Directory record by scanning backwards
        const end_record = try findEndRecord(data);
        const cd_offset = end_record.central_directory_offset;
        const cd_size = end_record.central_directory_size;

        if (@as(u64, cd_offset) + @as(u64, cd_size) > data.len)
            return error.InvalidArchive;

        var entries = std.StringArrayHashMap(Entry).init(allocator);
        errdefer {
            for (entries.keys()) |k| allocator.free(k);
            entries.deinit();
        }

        // Parse central directory entries
        var pos: usize = cd_offset;
        const cd_end = cd_offset + cd_size;

        while (pos + @sizeOf(std.zip.CentralDirectoryFileHeader) <= cd_end) {
            const hdr: *align(1) const std.zip.CentralDirectoryFileHeader = @ptrCast(data[pos..]);
            if (!std.mem.eql(u8, &hdr.signature, &std.zip.central_file_header_sig))
                break;

            const name_start = pos + @sizeOf(std.zip.CentralDirectoryFileHeader);
            const name_end = name_start + hdr.filename_len;
            if (name_end > cd_end) break;

            const filename = data[name_start..name_end];

            // Skip directories (trailing slash)
            if (filename.len > 0 and filename[filename.len - 1] != '/') {
                // Store lowercase for case-insensitive lookup
                const lower = try allocator.alloc(u8, filename.len);
                for (filename, 0..) |c, i| {
                    lower[i] = std.ascii.toLower(c);
                }

                try entries.put(lower, Entry{
                    .local_header_offset = hdr.local_file_header_offset,
                    .compressed_size = hdr.compressed_size,
                    .uncompressed_size = hdr.uncompressed_size,
                    .compression_method = hdr.compression_method,
                    .crc32 = hdr.crc32,
                });
            }

            pos = name_end + hdr.extra_len + hdr.comment_len;
        }

        return Pk3{
            .allocator = allocator,
            .data = data,
            .entries = entries,
        };
    }

    /// Find an entry by path (case-insensitive, forward-slash normalized).
    pub fn findEntry(self: *const Pk3, path: []const u8) ?*const Entry {
        // Normalize to lowercase for lookup
        var buf: [512]u8 = undefined;
        if (path.len > buf.len) return null;
        for (path, 0..) |c, i| {
            buf[i] = std.ascii.toLower(if (c == '\\') '/' else c);
        }
        return self.entries.getPtr(buf[0..path.len]);
    }

    /// Extract an entry's contents. Caller owns the returned slice.
    pub fn extractEntry(self: *const Pk3, entry: *const Entry, allocator: std.mem.Allocator) ![]u8 {
        // Read local file header to get actual data offset
        const lh_pos = entry.local_header_offset;
        if (@as(u64, lh_pos) + @sizeOf(std.zip.LocalFileHeader) > self.data.len)
            return error.InvalidArchive;

        const lh: *align(1) const std.zip.LocalFileHeader = @ptrCast(self.data[lh_pos..]);
        if (!std.mem.eql(u8, &lh.signature, &std.zip.local_file_header_sig))
            return error.InvalidArchive;

        const data_offset = @as(usize, lh_pos) +
            @sizeOf(std.zip.LocalFileHeader) +
            @as(usize, lh.filename_len) +
            @as(usize, lh.extra_len);

        if (data_offset + entry.compressed_size > self.data.len)
            return error.InvalidArchive;

        const compressed = self.data[data_offset..][0..entry.compressed_size];

        switch (entry.compression_method) {
            .store => {
                // Uncompressed — just dupe it
                return try allocator.dupe(u8, compressed);
            },
            .deflate => {
                // Decompress with deflate
                const result = try allocator.alloc(u8, entry.uncompressed_size);
                errdefer allocator.free(result);

                var fbs = std.io.fixedBufferStream(compressed);
                var decompressor = std.compress.flate.decompressor(fbs.reader());
                var written: usize = 0;
                while (try decompressor.next()) |chunk| {
                    if (written + chunk.len > result.len)
                        return error.DecompressSizeMismatch;
                    @memcpy(result[written..][0..chunk.len], chunk);
                    written += chunk.len;
                }
                if (written != entry.uncompressed_size)
                    return error.DecompressSizeMismatch;
                return result;
            },
            _ => return error.UnsupportedCompression,
        }
    }

    /// Extract a file by path. Returns null if not found. Caller owns the slice.
    pub fn extractFile(self: *const Pk3, path: []const u8, allocator: std.mem.Allocator) !?[]u8 {
        const entry = self.findEntry(path) orelse return null;
        return try self.extractEntry(entry, allocator);
    }

    /// Iterate all entries, calling the callback with each path and entry.
    pub fn iterateAll(self: *const Pk3) []const []const u8 {
        return self.entries.keys();
    }
};

// Find End of Central Directory record by scanning backwards from end of file.
fn findEndRecord(data: []const u8) !std.zip.EndRecord {
    if (data.len < @sizeOf(std.zip.EndRecord)) return error.InvalidArchive;

    // Scan backwards for the signature (max comment = 65535 bytes)
    const max_scan = @min(data.len, @sizeOf(std.zip.EndRecord) + 65535);
    var offset = data.len - @sizeOf(std.zip.EndRecord);

    while (true) {
        if (std.mem.eql(u8, data[offset..][0..4], &std.zip.end_record_sig)) {
            const record: *align(1) const std.zip.EndRecord = @ptrCast(data[offset..]);
            return record.*;
        }
        if (offset == data.len - max_scan) break;
        offset -= 1;
    }

    return error.InvalidArchive;
}

// ============================================================================
// Tests
// ============================================================================

test "pk3 read empty-ish zip" {
    // Minimal valid ZIP: just an end-of-central-directory record
    const end_record = [_]u8{
        'P', 'K', 5, 6, // signature
        0, 0, // disk number
        0, 0, // CD disk number
        0, 0, // records on disk
        0, 0, // total records
        0, 0, 0, 0, // CD size
        0, 0, 0, 0, // CD offset
        0, 0, // comment length
    };

    var pk3 = try Pk3.read(std.testing.allocator, &end_record);
    defer pk3.deinit();

    try std.testing.expectEqual(@as(usize, 0), pk3.entries.count());
}
