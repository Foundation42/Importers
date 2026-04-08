const std = @import("std");
const vpk = @import("valve-resource-format").vpk;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        const stderr = std.io.getStdErr().writer();
        try stderr.writeAll("Usage: list-vpk <file.vpk> [extension-filter]\n");
        std.process.exit(1);
    }

    const path = args[1];
    const filter = if (args.len >= 3) args[2] else null;
    const stdout = std.io.getStdOut().writer();

    var pkg = vpk.Package.init(allocator);
    defer pkg.deinit();

    pkg.readFile(path) catch |err| {
        try std.io.getStdErr().writer().print("Error reading VPK: {}\n", .{err});
        std.process.exit(1);
    };

    try stdout.print("VPK v{d}, {d} entries\n", .{ pkg.version, pkg.entryCount() });

    // List extensions and counts
    try stdout.writeAll("\nExtensions:\n");
    var ext_iter = pkg.entries.iterator();
    while (ext_iter.next()) |kv| {
        try stdout.print("  .{s}: {d} files\n", .{ kv.key_ptr.*, kv.value_ptr.items.len });
    }

    // If filter provided, list matching files
    if (filter) |f| {
        try stdout.print("\nFiles matching .{s}:\n", .{f});
        if (pkg.entries.get(f)) |list| {
            for (list.items) |*entry| {
                const full_path = try entry.getFullPath(allocator);
                defer allocator.free(full_path);
                try stdout.print("  {s} ({d} bytes)\n", .{ full_path, entry.totalLength() });
            }
        } else {
            try stdout.writeAll("  (none)\n");
        }
    }
}
