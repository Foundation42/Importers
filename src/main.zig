const std = @import("std");
const vrf = @import("valve-resource-format");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        const stderr = std.io.getStdErr().writer();
        try stderr.print("Usage: {s} <file.xxx_c>\n", .{args[0]});
        try stderr.writeAll("\nParses a Source 2 compiled resource file and prints info about its blocks.\n");
        std.process.exit(1);
    }

    const path = args[1];
    const stdout = std.io.getStdOut().writer();

    try stdout.print("Reading: {s}\n", .{path});

    var resource = vrf.Resource.init(allocator);
    defer resource.deinit();

    resource.readFile(path) catch |err| {
        const stderr = std.io.getStdErr().writer();
        try stderr.print("Error reading resource: {}\n", .{err});
        std.process.exit(1);
    };

    try stdout.print("File size: {d} bytes\n", .{resource.file_size});
    try stdout.print("Header version: {d}\n", .{resource.header_version});
    try stdout.print("Version: {d}\n", .{resource.version});

    if (resource.resource_type.extension()) |ext| {
        try stdout.print("Resource type: .{s}\n", .{ext});
    } else {
        try stdout.writeAll("Resource type: unknown\n");
    }

    try stdout.print("Blocks ({d}):\n", .{resource.blocks.items.len});

    for (resource.blocks.items) |blk| {
        const tag = blk.block_type.toTag();
        try stdout.print("  {s}  offset={d}  size={d}", .{ tag, blk.offset, blk.size });

        switch (blk.data) {
            .rerl => |rerl| {
                try stdout.print("  ({d} external refs)", .{rerl.resource_ref_info_list.len});
                for (rerl.resource_ref_info_list) |ref_info| {
                    try stdout.print("\n    0x{X:0>16} -> {s}", .{ ref_info.id, ref_info.name });
                }
            },
            .redi => |redi| {
                try stdout.print("  ({d} input deps, {d} special deps)", .{
                    redi.input_dependencies.len,
                    redi.special_dependencies.len,
                });
                for (redi.special_dependencies) |dep| {
                    try stdout.print("\n    compiler: {s}  string: {s}", .{ dep.compiler_identifier, dep.string });
                }
            },
            .data_block => |data| {
                if (data.resource_type.extension()) |ext| {
                    try stdout.print("  (resource type: .{s})", .{ext});
                }
            },
            .kv3_block => |kv3| {
                const kv3_tag = kv3.block_type.toTag();
                try stdout.print("  (KV3 block: {s})", .{kv3_tag});
            },
            .ntro => {
                try stdout.writeAll("  (introspection manifest)");
            },
            .raw => {
                try stdout.writeAll("  (raw/unparsed)");
            },
        }
        try stdout.writeAll("\n");
    }
}
