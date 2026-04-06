//! Example: Load and inspect a Quake 3 BSP file.
//!
//! Usage: load-q3bsp <path/to/map.bsp> [pk3-dir]
//!
//! If pk3-dir is provided, loads all .pk3 files from that directory
//! and resolves shader scripts and texture references.

const std = @import("std");
const vrf = @import("valve-resource-format");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("Usage: load-q3bsp <path/to/map.bsp> [pk3-dir]\n", .{});
        return;
    }

    // Read BSP file
    const file = try std.fs.cwd().openFile(args[1], .{});
    defer file.close();

    const data = try file.readToEndAlloc(allocator, 256 * 1024 * 1024); // 256 MB max
    defer allocator.free(data);

    var bsp = try vrf.Q3Bsp.read(allocator, data);
    defer bsp.deinit();

    // Print summary
    std.debug.print("=== Quake 3 BSP ===\n", .{});
    std.debug.print("Shaders:    {d}\n", .{bsp.shaders.len});
    std.debug.print("Planes:     {d}\n", .{bsp.planes.len});
    std.debug.print("Nodes:      {d}\n", .{bsp.nodes.len});
    std.debug.print("Leafs:      {d}\n", .{bsp.leafs.len});
    std.debug.print("Leaf faces: {d}\n", .{bsp.leaf_faces.len});
    std.debug.print("Models:     {d}\n", .{bsp.models.len});
    std.debug.print("Brushes:    {d}\n", .{bsp.brushes.len});
    std.debug.print("Vertices:   {d}\n", .{bsp.vertices.len});
    std.debug.print("Mesh verts: {d}\n", .{bsp.mesh_verts.len});
    std.debug.print("Faces:      {d}\n", .{bsp.faces.len});
    std.debug.print("Effects:    {d}\n", .{bsp.effects.len});
    std.debug.print("Lightmaps:  {d}\n", .{bsp.numLightmaps()});
    std.debug.print("Light vols: {d}\n", .{bsp.light_vols.len});
    std.debug.print("Vis clusters: {d}\n", .{bsp.vis_data.num_clusters});
    std.debug.print("Entities:   {d}\n", .{bsp.entities.len});

    // Print first 5 shaders
    std.debug.print("\n--- Shaders (first 5) ---\n", .{});
    for (bsp.shaders[0..@min(5, bsp.shaders.len)], 0..) |*s, i| {
        std.debug.print("  [{d}] {s} (surface=0x{x}, content=0x{x})\n", .{
            i, s.getName(), s.surface_flags, s.content_flags,
        });
    }

    // Print face type counts
    var poly_count: u32 = 0;
    var patch_count: u32 = 0;
    var mesh_count: u32 = 0;
    var billboard_count: u32 = 0;
    var other_count: u32 = 0;
    for (bsp.faces) |f| {
        switch (f.getSurfaceType()) {
            .polygon => poly_count += 1,
            .patch => patch_count += 1,
            .mesh => mesh_count += 1,
            .billboard => billboard_count += 1,
            _ => other_count += 1,
        }
    }
    std.debug.print("\n--- Face types ---\n", .{});
    std.debug.print("  Polygons:   {d}\n", .{poly_count});
    std.debug.print("  Patches:    {d}\n", .{patch_count});
    std.debug.print("  Meshes:     {d}\n", .{mesh_count});
    std.debug.print("  Billboards: {d}\n", .{billboard_count});
    if (other_count > 0) std.debug.print("  Other:      {d}\n", .{other_count});

    // Print entities with classnames
    std.debug.print("\n--- Entities (first 10) ---\n", .{});
    for (bsp.entities[0..@min(10, bsp.entities.len)], 0..) |*e, i| {
        const classname = e.getClassname() orelse "(no classname)";
        if (e.getOrigin()) |origin| {
            std.debug.print("  [{d}] {s} @ ({d:.1}, {d:.1}, {d:.1})\n", .{
                i, classname, origin[0], origin[1], origin[2],
            });
        } else {
            std.debug.print("  [{d}] {s}\n", .{ i, classname });
        }
    }

    // World model info
    if (bsp.models.len > 0) {
        const world = &bsp.models[0];
        std.debug.print("\n--- World model ---\n", .{});
        std.debug.print("  Bounds: ({d:.1}, {d:.1}, {d:.1}) to ({d:.1}, {d:.1}, {d:.1})\n", .{
            world.mins[0], world.mins[1], world.mins[2],
            world.maxs[0], world.maxs[1], world.maxs[2],
        });
        std.debug.print("  Faces: {d}, Brushes: {d}\n", .{ world.num_faces, world.num_brushes });
    }

    // Extract geometry
    std.debug.print("\n--- Geometry extraction ---\n", .{});
    var mesh = try bsp.extractGeometry(allocator, .{});
    defer mesh.deinit();

    std.debug.print("  Extracted vertices:  {d}\n", .{mesh.vertices.len});
    std.debug.print("  Extracted indices:   {d}\n", .{mesh.indices.len});
    std.debug.print("  Extracted triangles: {d}\n", .{mesh.triangleCount()});

    // Show bounds of extracted geometry
    if (mesh.vertices.len > 0) {
        var min = mesh.vertices[0].position;
        var max = mesh.vertices[0].position;
        for (mesh.vertices[1..]) |v| {
            for (0..3) |a| {
                if (v.position[a] < min[a]) min[a] = v.position[a];
                if (v.position[a] > max[a]) max[a] = v.position[a];
            }
        }
        std.debug.print("  Mesh bounds: ({d:.1}, {d:.1}, {d:.1}) to ({d:.1}, {d:.1}, {d:.1})\n", .{
            min[0], min[1], min[2], max[0], max[1], max[2],
        });
    }

    // Count unique shaders used
    var shader_set = std.AutoHashMap(i32, void).init(allocator);
    defer shader_set.deinit();
    for (mesh.shader_indices) |si| {
        try shader_set.put(si, {});
    }
    std.debug.print("  Unique shaders used: {d}\n", .{shader_set.count()});

    // Split by shader for per-material rendering
    std.debug.print("\n--- Sub-meshes (per shader) ---\n", .{});
    const sub_meshes = try mesh.splitByShader(allocator);
    defer {
        for (sub_meshes) |*sm| {
            var s = sm.*;
            s.deinit();
        }
        allocator.free(sub_meshes);
    }
    std.debug.print("  Sub-mesh count: {d}\n", .{sub_meshes.len});
    for (sub_meshes[0..@min(10, sub_meshes.len)], 0..) |sm, i| {
        const shader_name = if (sm.shader_index >= 0 and @as(usize, @intCast(sm.shader_index)) < bsp.shaders.len)
            bsp.shaders[@intCast(sm.shader_index)].getName()
        else
            "(none)";
        std.debug.print("  [{d}] shader={s} verts={d} tris={d} lm={d}\n", .{
            i, shader_name, sm.vertices.len, sm.triangleCount(), sm.lightmap_index,
        });
    }

    // Build lightmap atlas
    std.debug.print("\n--- Lightmap atlas ---\n", .{});
    var atlas = try vrf.buildLightmapAtlas(&bsp, allocator);
    defer atlas.deinit();

    std.debug.print("  Lightmap count: {d}\n", .{atlas.count});
    std.debug.print("  Atlas size: {d}x{d} ({d} cols, {d} rows)\n", .{
        atlas.width, atlas.height, atlas.cols, atlas.rows,
    });
    std.debug.print("  Atlas pixels: {d} bytes (RGBA)\n", .{atlas.pixels.len});

    if (atlas.count > 0) {
        const scale = atlas.getLightmapScale();
        std.debug.print("  UV scale: ({d:.4}, {d:.4})\n", .{ scale[0], scale[1] });

        // Show offsets for first few lightmaps
        for (0..@min(4, atlas.count)) |li| {
            const off = atlas.getLightmapOffset(@intCast(li));
            std.debug.print("  LM[{d}] offset: ({d:.4}, {d:.4})\n", .{ li, off[0], off[1] });
        }

        // Remap lightmap UVs
        vrf.remapLightmapUVs(&mesh, &atlas);
        std.debug.print("  Lightmap UVs remapped to atlas space.\n", .{});

        // Show sample remapped UV
        if (mesh.vertices.len > 0) {
            const v = mesh.vertices[0];
            std.debug.print("  Sample vertex LM UV: ({d:.4}, {d:.4})\n", .{
                v.lightmap_coord[0], v.lightmap_coord[1],
            });
        }
    }

    // BSP traversal + visibility test
    std.debug.print("\n--- BSP traversal & visibility ---\n", .{});
    {
        // Use the world center as a test camera position
        if (bsp.models.len > 0) {
            const world = &bsp.models[0];
            const camera_pos = [3]f32{
                (world.mins[0] + world.maxs[0]) / 2.0,
                (world.mins[1] + world.maxs[1]) / 2.0,
                (world.mins[2] + world.maxs[2]) / 2.0,
            };

            const leaf = bsp.findLeaf(camera_pos);
            std.debug.print("  Camera at center: ({d:.0}, {d:.0}, {d:.0})\n", .{
                camera_pos[0], camera_pos[1], camera_pos[2],
            });
            std.debug.print("  Camera leaf cluster: {d}\n", .{leaf.cluster});

            // Create a test frustum that sees everything (identity-ish VP matrix)
            // This simulates a very wide FOV camera to test the pipeline
            const wide_frustum = vrf.Frustum{
                .planes = .{
                    .{ 1, 0, 0, 100000 }, // left
                    .{ -1, 0, 0, 100000 }, // right
                    .{ 0, 1, 0, 100000 }, // bottom
                    .{ 0, -1, 0, 100000 }, // top
                    .{ 0, 0, 1, 100000 }, // near
                    .{ 0, 0, -1, 100000 }, // far
                },
            };

            // Collect visible faces with PVS + frustum
            var vis_set = try bsp.collectVisibleFaces(allocator, camera_pos, &wide_frustum);
            defer vis_set.deinit();
            std.debug.print("  Visible faces (wide frustum): {d} / {d} total\n", .{
                vis_set.count, bsp.faces.len,
            });

            // Now test with a narrow frustum pointing along +X
            const narrow_frustum = vrf.Frustum{
                .planes = .{
                    .{ 0.707, 0, 0.707, 0 }, // left (45 deg)
                    .{ 0.707, 0, -0.707, 0 }, // right (45 deg)
                    .{ 0, 0.707, 0.707, 0 }, // bottom
                    .{ 0, 0.707, -0.707, 0 }, // top
                    .{ 0, 0, 1, 100000 }, // near
                    .{ 0, 0, -1, 100000 }, // far
                },
            };

            var narrow_vis = try bsp.collectVisibleFaces(allocator, camera_pos, &narrow_frustum);
            defer narrow_vis.deinit();
            std.debug.print("  Visible faces (narrow frustum): {d} / {d} total\n", .{
                narrow_vis.count, bsp.faces.len,
            });

            // Walk front-to-back and count leaves visited
            const Counter = struct {
                count: *u32,
            };
            var ftb_count: u32 = 0;
            bsp.walkFrontToBack(camera_pos, Counter, .{ .count = &ftb_count }, struct {
                fn cb(ctx: Counter, _: usize, _: *const vrf.q3bsp.Leaf) void {
                    ctx.count.* += 1;
                }
            }.cb);
            std.debug.print("  Front-to-back walk: {d} leaves visited\n", .{ftb_count});
        }
    }

    // PK3 + shader resolution (optional)
    if (args.len >= 3) {
        std.debug.print("\n--- PK3 / Shader resolution ---\n", .{});

        const pk3_dir_path = args[2];
        var pk3_dir = std.fs.cwd().openDir(pk3_dir_path, .{ .iterate = true }) catch |err| {
            std.debug.print("  Cannot open pk3 directory: {}\n", .{err});
            return;
        };
        defer pk3_dir.close();

        // Load shader database from all pk3 files
        var shader_db = vrf.ShaderDb.init(allocator);
        defer shader_db.deinit();

        var pk3_files = std.ArrayList(struct { data: []u8, pk3: vrf.Pk3 }).init(allocator);
        defer {
            for (pk3_files.items) |*item| {
                item.pk3.deinit();
                allocator.free(item.data);
            }
            pk3_files.deinit();
        }

        var dir_it = pk3_dir.iterate();
        while (try dir_it.next()) |entry| {
            if (entry.kind != .file) continue;
            const name = entry.name;
            if (!std.mem.endsWith(u8, name, ".pk3")) continue;

            std.debug.print("  Loading: {s}\n", .{name});
            const pk3_file = pk3_dir.openFile(name, .{}) catch continue;
            defer pk3_file.close();

            const pk3_data = pk3_file.readToEndAlloc(allocator, 512 * 1024 * 1024) catch continue;
            errdefer allocator.free(pk3_data);

            var pk3_archive = vrf.Pk3.read(allocator, pk3_data) catch |err| {
                std.debug.print("    Error reading pk3: {}\n", .{err});
                allocator.free(pk3_data);
                continue;
            };
            errdefer pk3_archive.deinit();

            std.debug.print("    Entries: {d}\n", .{pk3_archive.entries.count()});

            // Find and load .shader files
            var shader_count: u32 = 0;
            for (pk3_archive.entries.keys()) |key| {
                if (std.mem.endsWith(u8, key, ".shader")) {
                    if (pk3_archive.extractFile(key, allocator) catch null) |shader_src| {
                        defer allocator.free(shader_src);
                        shader_db.loadShaderScript(shader_src) catch {};
                        shader_count += 1;
                    }
                }
            }
            if (shader_count > 0) {
                std.debug.print("    Loaded {d} shader scripts\n", .{shader_count});
            }

            try pk3_files.append(.{ .data = pk3_data, .pk3 = pk3_archive });
        }

        std.debug.print("  Total shaders in DB: {d}\n", .{shader_db.shaders.count()});

        // Resolve textures for BSP shaders
        std.debug.print("\n--- Texture resolution ---\n", .{});
        var resolved: u32 = 0;
        var unresolved: u32 = 0;

        for (bsp.shaders[0..@min(20, bsp.shaders.len)], 0..) |*s, i| {
            const shader_name = s.getName();
            if (std.mem.eql(u8, shader_name, "noshader")) continue;

            // Try shader DB first
            if (shader_db.find(shader_name)) |shader| {
                if (shader.getDiffuseMap()) |diffuse| {
                    std.debug.print("  [{d}] {s} -> {s}", .{ i, shader_name, diffuse });

                    // Try to find the texture in pk3 files
                    var found = false;
                    for (pk3_files.items) |*item| {
                        if (item.pk3.findEntry(diffuse) != null) {
                            std.debug.print(" [found in pk3]", .{});
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        // Try common extensions
                        const exts = [_][]const u8{ ".tga", ".jpg", ".png" };
                        for (exts) |ext| {
                            var path_buf: [512]u8 = undefined;
                            const try_path = std.fmt.bufPrint(&path_buf, "{s}{s}", .{ diffuse, ext }) catch continue;
                            for (pk3_files.items) |*item| {
                                if (item.pk3.findEntry(try_path) != null) {
                                    std.debug.print(" [found as {s}]", .{ext});
                                    found = true;
                                    break;
                                }
                            }
                            if (found) break;
                        }
                    }

                    std.debug.print("\n", .{});
                    resolved += 1;
                    continue;
                }
            }

            // No shader definition — try direct texture lookup
            const exts = [_][]const u8{ ".tga", ".jpg", ".png" };
            var found = false;
            for (exts) |ext| {
                var path_buf: [512]u8 = undefined;
                const try_path = std.fmt.bufPrint(&path_buf, "{s}{s}", .{ shader_name, ext }) catch continue;
                for (pk3_files.items) |*item| {
                    if (item.pk3.findEntry(try_path) != null) {
                        std.debug.print("  [{d}] {s} -> {s}{s} [direct]\n", .{ i, shader_name, shader_name, ext });
                        found = true;
                        resolved += 1;
                        break;
                    }
                }
                if (found) break;
            }
            if (!found) {
                std.debug.print("  [{d}] {s} -> UNRESOLVED\n", .{ i, shader_name });
                unresolved += 1;
            }
        }

        std.debug.print("\n  Resolved: {d}, Unresolved: {d}\n", .{ resolved, unresolved });
    }
}
