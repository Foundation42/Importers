//! Test TGA decoder against real Q3 textures from PK3 files.

const std = @import("std");
const vrf = @import("valve-resource-format");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("Usage: test-tga <pk3-file>\n", .{});
        return;
    }

    const pk3_data = try std.fs.cwd().readFileAlloc(allocator, args[1], 512 * 1024 * 1024);
    defer allocator.free(pk3_data);

    var pk3 = try vrf.Pk3.read(allocator, pk3_data);
    defer pk3.deinit();

    var decoded: u32 = 0;
    var failed: u32 = 0;
    var total: u32 = 0;

    for (pk3.iterateAll()) |path| {
        if (!std.mem.endsWith(u8, path, ".tga")) continue;
        total += 1;

        if (try pk3.extractFile(path, allocator)) |tga_data| {
            defer allocator.free(tga_data);
            if (vrf.tga.decode(allocator, tga_data)) |*img| {
                var image = img.*;
                defer image.deinit();
                decoded += 1;
            } else |err| {
                std.debug.print("  FAIL: {s} ({any})\n", .{ path, err });
                failed += 1;
            }
        }
    }
    std.debug.print("\nDecoded: {d}/{d} TGA files ({d} failed)\n", .{ decoded, total, failed });
}
