//! Example: Dump all emissive information for a Quake 3 map.
//!
//! Usage: dump-q3-emissives <map-name> <pk3-dir>
//!
//!   map-name: BSP name without extension (e.g. "wrackdm17", "q3dm6ish")
//!   pk3-dir:  Directory containing .pk3 archives (maps + shaders searched across all)
//!
//! Prints:
//!   - All shaders in the DB with q3map_surfacelight > 0 (shader-level emitters)
//!   - All `light` / `lightJunior` entities from the BSP's entity lump
//!   - Cross-reference: which BSP-referenced shaders actually resolve to emitters
//!
//! Serves as the Phase 1 validation ground-truth table for the emissive-NEE path.

const std = @import("std");
const vrf = @import("valve-resource-format");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 3) {
        std.debug.print("Usage: dump-q3-emissives <map-name> <pk3-dir>\n", .{});
        std.debug.print("  e.g.  dump-q3-emissives wrackdm17 test_files/q3/pk3/\n", .{});
        return;
    }

    const map_name = args[1];
    const pk3_dir_path = args[2];

    // ------------------------------------------------------------------------
    // Load every PK3 in the directory; collect shader scripts into one DB
    // ------------------------------------------------------------------------
    var pk3_dir = try std.fs.cwd().openDir(pk3_dir_path, .{ .iterate = true });
    defer pk3_dir.close();

    var shader_db = vrf.ShaderDb.init(allocator);
    defer shader_db.deinit();

    const Pk3Entry = struct { data: []u8, pk3: vrf.Pk3 };
    var pk3_files = std.ArrayList(Pk3Entry).init(allocator);
    defer {
        for (pk3_files.items) |*item| {
            item.pk3.deinit();
            allocator.free(item.data);
        }
        pk3_files.deinit();
    }

    var total_shader_scripts: u32 = 0;

    var dir_it = pk3_dir.iterate();
    while (try dir_it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".pk3")) continue;

        const pk3_file = pk3_dir.openFile(entry.name, .{}) catch continue;
        defer pk3_file.close();

        const pk3_data = pk3_file.readToEndAlloc(allocator, 512 * 1024 * 1024) catch continue;
        errdefer allocator.free(pk3_data);

        var pk3_archive = vrf.Pk3.read(allocator, pk3_data) catch {
            allocator.free(pk3_data);
            continue;
        };
        errdefer pk3_archive.deinit();

        var scripts_here: u32 = 0;
        for (pk3_archive.entries.keys()) |key| {
            if (!std.mem.endsWith(u8, key, ".shader")) continue;
            if (pk3_archive.extractFile(key, allocator) catch null) |src| {
                defer allocator.free(src);
                shader_db.loadShaderScript(src) catch {};
                scripts_here += 1;
            }
        }
        total_shader_scripts += scripts_here;

        try pk3_files.append(.{ .data = pk3_data, .pk3 = pk3_archive });
    }

    std.debug.print("=== PK3s loaded ===\n", .{});
    std.debug.print("  Archives:       {d}\n", .{pk3_files.items.len});
    std.debug.print("  Shader scripts: {d}\n", .{total_shader_scripts});
    std.debug.print("  Shader DB:      {d} entries\n", .{shader_db.shaders.count()});

    // ------------------------------------------------------------------------
    // Extract the requested BSP from whichever PK3 carries it
    // ------------------------------------------------------------------------
    var bsp_path_buf: [256]u8 = undefined;
    const bsp_path = try std.fmt.bufPrint(&bsp_path_buf, "maps/{s}.bsp", .{map_name});

    var bsp_data: ?[]u8 = null;
    defer if (bsp_data) |d| allocator.free(d);

    for (pk3_files.items) |*item| {
        if (item.pk3.findEntry(bsp_path) != null) {
            bsp_data = item.pk3.extractFile(bsp_path, allocator) catch null;
            if (bsp_data != null) break;
        }
    }

    if (bsp_data == null) {
        std.debug.print("\nERROR: {s} not found in any pk3 (looked for '{s}').\n", .{ map_name, bsp_path });
        return;
    }

    var bsp = try vrf.Q3Bsp.read(allocator, bsp_data.?);
    defer bsp.deinit();

    std.debug.print("\n=== BSP: {s} ===\n", .{map_name});
    std.debug.print("  Shaders referenced: {d}\n", .{bsp.shaders.len});
    std.debug.print("  Entities:           {d}\n", .{bsp.entities.len});

    // ------------------------------------------------------------------------
    // Shader-level emitters (q3map_surfacelight > 0)
    // ------------------------------------------------------------------------
    std.debug.print("\n--- Shader-level emitters (q3map_surfacelight > 0) ---\n", .{});
    var shader_emitter_count: u32 = 0;
    for (shader_db.shaders.values()) |*s| {
        if (!s.isEmissive()) continue;
        shader_emitter_count += 1;
        std.debug.print("  {s}\n", .{s.name});
        std.debug.print("    intensity: {d:.1}   colour: ({d:.3}, {d:.3}, {d:.3})", .{
            s.surface_light, s.light_rgb[0], s.light_rgb[1], s.light_rgb[2],
        });
        if (s.light_image) |img| {
            std.debug.print("   lightimage: {s}", .{img});
        }
        std.debug.print("\n", .{});
    }
    std.debug.print("  [{d} emissive shaders total in DB]\n", .{shader_emitter_count});

    // ------------------------------------------------------------------------
    // Cross-reference: which BSP-referenced shaders are emitters?
    // ------------------------------------------------------------------------
    std.debug.print("\n--- BSP-referenced shaders that are emitters ---\n", .{});
    var bsp_emitter_count: u32 = 0;
    for (bsp.shaders, 0..) |*s, i| {
        const name = s.getName();
        const shader = shader_db.find(name) orelse continue;
        if (!shader.isEmissive()) continue;
        bsp_emitter_count += 1;
        std.debug.print("  [{d}] {s}   intensity={d:.1}  rgb=({d:.2}, {d:.2}, {d:.2})\n", .{
            i, name, shader.surface_light, shader.light_rgb[0], shader.light_rgb[1], shader.light_rgb[2],
        });
    }
    if (bsp_emitter_count == 0) {
        std.debug.print("  (none — shader-level emitter path not exercised by this map)\n", .{});
    } else {
        std.debug.print("  [{d} emitter shaders actually referenced by {s}]\n", .{ bsp_emitter_count, map_name });
    }

    // ------------------------------------------------------------------------
    // Point-light entities
    // ------------------------------------------------------------------------
    std.debug.print("\n--- Light entities (classname: light / lightJunior) ---\n", .{});
    const lights = try vrf.findLightEntities(allocator, bsp.entities);
    defer allocator.free(lights);

    var regular: u32 = 0;
    var junior: u32 = 0;
    var with_target: u32 = 0;
    for (lights) |l| {
        if (l.is_junior) junior += 1 else regular += 1;
        if (l.target != null) with_target += 1;
    }
    std.debug.print("  light:       {d}\n", .{regular});
    std.debug.print("  lightJunior: {d}\n", .{junior});
    std.debug.print("  spotlights (with target): {d}\n", .{with_target});

    // Show first 10 as a sanity check
    const show_n = @min(10, lights.len);
    std.debug.print("\n  First {d} entries:\n", .{show_n});
    for (lights[0..show_n], 0..) |l, i| {
        const kind = if (l.is_junior) "lightJunior" else "light";
        std.debug.print("    [{d}] {s} @ ({d:.0}, {d:.0}, {d:.0})  intensity={d:.0}  rgb=({d:.2}, {d:.2}, {d:.2})", .{
            i, kind, l.origin[0], l.origin[1], l.origin[2],
            l.intensity, l.color[0], l.color[1], l.color[2],
        });
        if (l.target) |t| std.debug.print("  target={s}", .{t});
        if (l.radius) |r| std.debug.print("  radius={d:.0}", .{r});
        std.debug.print("\n", .{});
    }

    // ------------------------------------------------------------------------
    // Summary suitable for Phase 1 ground-truth table
    // ------------------------------------------------------------------------
    std.debug.print("\n=== Phase 1 ground-truth summary ===\n", .{});
    std.debug.print("  Shader emitters referenced by map: {d}\n", .{bsp_emitter_count});
    std.debug.print("  Point-light entities:              {d} (regular) + {d} (junior)\n", .{ regular, junior });
    std.debug.print("  Spotlights (target != null):       {d}\n", .{with_target});
}
