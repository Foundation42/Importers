// PVS Baker — standalone tool for computing Potentially Visible Sets
//
// Loads a Source 2 map from VPK, merges all geometry into a single
// triangle soup, builds a BIVH, and runs the stochastic PVS solver.
// No raylib dependency — pure CPU.
//
// Usage: pvs-baker <map.vpk> [content.vpk]

const std = @import("std");
const Allocator = std.mem.Allocator;
const vrf = @import("valve-resource-format");
const Resource = vrf.Resource;
const binary_kv3 = vrf.binary_kv3;
const bivh_mod = @import("bivh");
const pvs_mod = @import("pvs");

const Vec3 = [3]f32;

// Source 2 → Y-up scale factor (1 unit ≈ 0.0254m)
const S2_SCALE: f32 = 0.0254;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        const stderr = std.io.getStdErr().writer();
        try stderr.writeAll("Usage: pvs-baker <map.vpk> [content.vpk]\n\n");
        try stderr.writeAll("Computes PVS (Potentially Visible Sets) for a Source 2 map.\n");
        try stderr.writeAll("Outputs visibility data to <map>_pvs.bin\n");
        std.process.exit(1);
    }

    const map_vpk_path = args[1];
    const content_vpk_path: ?[]const u8 = if (args.len >= 3) args[2] else null;

    const stdout = std.io.getStdOut().writer();
    try stdout.print("PVS Baker — Loading {s}\n", .{map_vpk_path});

    const t0 = std.time.nanoTimestamp();

    // ── Phase 1: Load geometry from VPK ──────────────────────────────

    var all_positions = std.ArrayList(Vec3).init(allocator);
    defer all_positions.deinit();
    var all_indices = std.ArrayList(u32).init(allocator);
    defer all_indices.deinit();

    var model_count: u32 = 0;
    var failed_count: u32 = 0;

    // Load map VPK
    var map_pkg = vrf.vpk.Package.init(allocator);
    defer map_pkg.deinit();
    try map_pkg.readFile(map_vpk_path);
    try stdout.print("  Map VPK: {d} entries\n", .{map_pkg.entryCount()});

    // Optionally load content VPK
    var content_pkg: ?vrf.vpk.Package = null;
    defer if (content_pkg) |*cp| cp.deinit();
    if (content_vpk_path) |cp| {
        var pkg = vrf.vpk.Package.init(allocator);
        pkg.readFile(cp) catch |err| {
            try stdout.print("  Warning: content VPK: {}\n", .{err});
            pkg.deinit();
        };
        if (pkg.entryCount() > 0) {
            try stdout.print("  Content VPK: {d} entries\n", .{pkg.entryCount()});
            content_pkg = pkg;
        } else {
            pkg.deinit();
        }
    }

    // Iterate all vmdl_c entries
    var it = map_pkg.iterateAll();
    while (it.next()) |entry| {
        if (!std.mem.eql(u8, entry.type_name, "vmdl_c")) continue;

        const entry_data = map_pkg.readEntry(entry) catch continue;
        defer allocator.free(entry_data);

        extractModelGeometry(allocator, entry_data, &all_positions, &all_indices) catch {
            failed_count += 1;
            continue;
        };
        model_count += 1;
    }

    // Also check content VPK for models referenced by the world
    // (aggregate scene objects can reference models from content)
    if (content_pkg) |*cpkg| {
        var cit = cpkg.iterateAll();
        while (cit.next()) |entry| {
            if (!std.mem.eql(u8, entry.type_name, "vmdl_c")) continue;
            const entry_data = cpkg.readEntry(entry) catch continue;
            defer allocator.free(entry_data);
            extractModelGeometry(allocator, entry_data, &all_positions, &all_indices) catch {
                failed_count += 1;
                continue;
            };
            model_count += 1;
        }
    }

    const tri_count = @as(u32, @intCast(all_indices.items.len / 3));
    const t_load = std.time.nanoTimestamp();

    try stdout.print("\n  ═══ Geometry ═══\n", .{});
    try stdout.print("  Models:     {d} ({d} failed)\n", .{ model_count, failed_count });
    try stdout.print("  Vertices:   {d}\n", .{all_positions.items.len});
    try stdout.print("  Triangles:  {d}\n", .{tri_count});
    try stdout.print("  Load time:  {d}ms\n", .{@divTrunc(t_load - t0, 1_000_000)});

    if (tri_count == 0) {
        try stdout.writeAll("\nNo geometry found. Exiting.\n");
        return;
    }

    // ── Phase 2: Build world BIVH (ray tracing) ────────────────────

    try stdout.writeAll("\n  Building world BIVH...\n");
    const t_bivh0 = std.time.nanoTimestamp();

    var mesh_set = bivh_mod.TriangleMeshSet.fromArrays(all_positions.items, all_indices.items);
    var world_bivh = bivh_mod.Bivh.init(allocator);
    defer world_bivh.deinit();
    try world_bivh.build(&mesh_set);

    const t_bivh1 = std.time.nanoTimestamp();

    try stdout.print("  BIVH nodes:  {d}\n", .{world_bivh.node_count});
    try stdout.print("  BIVH leaves: {d}\n", .{world_bivh.leafCount()});
    try stdout.print("  BIVH depth:  {d}\n", .{world_bivh.tree_depth});
    try stdout.print("  Build time:  {d}ms\n", .{@divTrunc(t_bivh1 - t_bivh0, 1_000_000)});

    // ── Epoch definitions ─────────────────────────────────────────────
    //
    // Each epoch runs at a different resolution.  The transport graph
    // from epoch N seeds epoch N+1 — dead edges (many casts, zero hits)
    // get blacklisted so the finer epoch doesn't waste rays on them.

    const EpochDef = struct {
        cluster_shift: u5,
        exploration_rate: f32,
        time_seconds: u32,
        samples_per_pass: u32,
    };

    const epochs = [_]EpochDef{
        .{ .cluster_shift = 12, .exploration_rate = 0.5, .time_seconds = 30, .samples_per_pass = 10_000 },
        .{ .cluster_shift = 10, .exploration_rate = 0.2, .time_seconds = 60, .samples_per_pass = 10_000 },
        .{ .cluster_shift = 8, .exploration_rate = 0.05, .time_seconds = 120, .samples_per_pass = 10_000 },
    };

    const thread_count = @as(u32, @intCast(std.Thread.getCpuCount() catch 4));
    const root = world_bivh.nodes[0];
    const world_min = root.min;
    const world_max = root.max;
    const base_name = std.fs.path.stem(map_vpk_path);

    var trace_ctx = TraceContext{
        .bivh = &world_bivh,
        .mesh_set = &mesh_set,
    };

    // Ray trace benchmark (once)
    {
        const bench_count: u32 = 1000;
        const tb0 = std.time.nanoTimestamp();
        var hits: u32 = 0;
        for (0..bench_count) |bi| {
            const idx: u32 = @intCast(bi % tri_count);
            const p = pvs_mod.randomPointOnTriangle(all_positions.items, all_indices.items, idx, std.crypto.random);
            const r = traceWorld(@ptrCast(&trace_ctx), p, .{ 0, 1, 0 }, 2000.0);
            if (r.hit) hits += 1;
        }
        const tb1 = std.time.nanoTimestamp();
        try stdout.print("\n  Ray bench: {d} rays, {d} hits, {d} µs/ray\n", .{ bench_count, hits, @divTrunc(tb1 - tb0, bench_count * 1000) });
    }

    // Track previous epoch's state for seeding
    var prev_cluster_bivh: ?bivh_mod.Bivh = null;
    var prev_transport: ?pvs_mod.TransportGraph = null;
    var prev_cell_node_indices: ?[]u32 = null;

    defer if (prev_transport) |*pt| pt.deinit();
    // Note: prev_cluster_bivh and prev_cell_node_indices are freed at end of each iteration

    for (epochs, 0..) |epoch, epoch_idx| {
        try stdout.print("\n  ╔═══════════════════════════════════╗\n", .{});
        try stdout.print("  ║  Epoch {d}/{d}  (shift={d}, explore={d:.0}%)  ║\n", .{
            epoch_idx + 1, epochs.len, epoch.cluster_shift, epoch.exploration_rate * 100,
        });
        try stdout.print("  ╚═══════════════════════════════════╝\n", .{});

        const cluster_size: u32 = @as(u32, 1) << epoch.cluster_shift;
        const cluster_count = (tri_count + cluster_size - 1) / cluster_size;

        // Build cluster BIVH for this epoch
        try stdout.print("  Clusters: {d} (size {d})\n", .{ cluster_count, cluster_size });
        const t_clust0 = std.time.nanoTimestamp();

        const cluster_positions = try allocator.alloc([3]f32, cluster_count * 3);
        defer allocator.free(cluster_positions);
        const cluster_indices_buf = try allocator.alloc(u32, cluster_count * 3);
        defer allocator.free(cluster_indices_buf);

        for (0..cluster_count) |ci| {
            const start_t = @as(u32, @intCast(ci)) * cluster_size;
            const end_t = @min(start_t + cluster_size, tri_count);
            var cmin = [3]f32{ std.math.floatMax(f32), std.math.floatMax(f32), std.math.floatMax(f32) };
            var cmax = [3]f32{ -std.math.floatMax(f32), -std.math.floatMax(f32), -std.math.floatMax(f32) };
            for (start_t..end_t) |ti| {
                const base = ti * 3;
                for (0..3) |vi| {
                    const pos = all_positions.items[mesh_set.indices[base + vi]];
                    for (0..3) |a| {
                        cmin[a] = @min(cmin[a], pos[a]);
                        cmax[a] = @max(cmax[a], pos[a]);
                    }
                }
            }
            const idx: u32 = @intCast(ci * 3);
            cluster_positions[idx] = cmin;
            cluster_positions[idx + 1] = cmax;
            cluster_positions[idx + 2] = .{
                (cmin[0] + cmax[0]) * 0.5,
                (cmin[1] + cmax[1]) * 0.5,
                (cmin[2] + cmax[2]) * 0.5,
            };
            cluster_indices_buf[idx] = idx;
            cluster_indices_buf[idx + 1] = idx + 1;
            cluster_indices_buf[idx + 2] = idx + 2;
        }

        var cluster_mesh = bivh_mod.TriangleMeshSet.fromArrays(cluster_positions, cluster_indices_buf);
        var cluster_bivh = bivh_mod.Bivh.init(allocator);
        defer cluster_bivh.deinit();
        try cluster_bivh.build(&cluster_mesh);

        const t_clust1 = std.time.nanoTimestamp();
        try stdout.print("  BIVH: {d} nodes, {d} leaves ({d}ms)\n", .{
            cluster_bivh.node_count, cluster_bivh.leafCount(), @divTrunc(t_clust1 - t_clust0, 1_000_000),
        });

        // Build cell ranges
        var cell_node_indices = std.ArrayList(u32).init(allocator);
        defer cell_node_indices.deinit();
        var cell_ranges = std.ArrayList(pvs_mod.CellRange).init(allocator);
        defer cell_ranges.deinit();

        for (0..cluster_bivh.node_count) |i| {
            const node = cluster_bivh.nodes[i];
            if (!node.isLeaf()) continue;
            const first_cluster = @as(u32, @intCast(node.startPrim()));
            const last_cluster = @as(u32, @intCast(node.end_prim));
            const start_t = first_cluster * cluster_size;
            const end_t = @min((last_cluster + 1) * cluster_size, tri_count);
            try cell_node_indices.append(@intCast(i));
            try cell_ranges.append(.{ .start_tri = start_t, .end_tri = end_t });
        }

        const num_cells: u32 = @intCast(cell_ranges.items.len);
        try stdout.print("  Cells: {d}\n", .{num_cells});

        // Set up cell lookup
        var cell_ctx = CellContext{ .bivh = &cluster_bivh };

        // Create solver
        var solver = try pvs_mod.PvsSolver.init(
            allocator,
            all_positions.items,
            all_indices.items,
            cluster_bivh.node_count,
            cell_node_indices.items,
            cell_ranges.items,
            &traceWorld,
            @ptrCast(&trace_ctx),
            &findClusterCell,
            @ptrCast(&cell_ctx),
            .{
                .thread_count = thread_count,
                .max_ray_distance = 2000.0,
                .convergence_threshold = 120,
                .samples_per_pass = epoch.samples_per_pass,
                .max_passes = 100_000,
                .progress_fn = &progressCallback,
                .cluster_shift = epoch.cluster_shift,
                .exploration_rate = epoch.exploration_rate,
                .max_time_seconds = epoch.time_seconds,
            },
        );
        defer solver.deinit();

        // Seed from previous epoch's transport graph
        if (prev_transport) |*pt| {
            if (prev_cluster_bivh) |*pcb| {
                try stdout.writeAll("  Seeding from previous epoch...\n");

                // Map each fine cell centroid → coarse cell index
                const fine_to_coarse = try allocator.alloc(u32, num_cells);
                defer allocator.free(fine_to_coarse);

                for (cell_node_indices.items, 0..) |node_idx, ci| {
                    const node = cluster_bivh.nodes[node_idx];
                    const centroid = Vec3{
                        (node.min[0] + node.max[0]) * 0.5,
                        (node.min[1] + node.max[1]) * 0.5,
                        (node.min[2] + node.max[2]) * 0.5,
                    };

                    // Find which coarse cell contains this centroid
                    if (pcb.findLeaf(centroid, null)) |coarse_node| {
                        // Map coarse BIVH node → coarse cell index
                        var coarse_idx: u32 = 0;
                        for (prev_cell_node_indices.?) |pcni| {
                            if (pcni == coarse_node) break;
                            coarse_idx += 1;
                        }
                        fine_to_coarse[ci] = @min(coarse_idx, pt.cell_count - 1);
                    } else {
                        fine_to_coarse[ci] = 0;
                    }
                }

                solver.transport.seedFromCoarse(pt, fine_to_coarse, 50);

                const dead = solver.transport.deadEdges(50);
                const total_edges = @as(u64, num_cells) * (@as(u64, num_cells) - 1) / 2;
                try stdout.print("  Blacklisted: {d}/{d} edges ({d}%)\n", .{
                    dead, total_edges, if (total_edges > 0) dead * 100 / total_edges else 0,
                });
            }
        }

        // Run solve
        const t_solve0 = std.time.nanoTimestamp();
        try solver.solve();
        const t_solve1 = std.time.nanoTimestamp();

        const s = solver.stats();
        try stdout.print("  ── Results ──\n", .{});
        try stdout.print("  Passes: {d}, Visible: {d}, Avg: {d}, Min: {d}, Max: {d}\n", .{
            s.passes, s.total_visible, s.avg_visible, s.min_visible, s.max_visible,
        });
        try stdout.print("  Transport: {d} casts, {d} connected, {d} dead\n", .{
            s.transport_casts, s.transport_edges, solver.transport.deadEdges(50),
        });
        try stdout.print("  Time: {d}ms\n", .{@divTrunc(t_solve1 - t_solve0, 1_000_000)});

        // Visualization for this epoch
        const cell_centroids = try allocator.alloc(Vec3, num_cells);
        defer allocator.free(cell_centroids);
        for (cell_node_indices.items, 0..) |node_idx, ci| {
            const node = cluster_bivh.nodes[node_idx];
            cell_centroids[ci] = .{
                (node.min[0] + node.max[0]) * 0.5,
                (node.min[1] + node.max[1]) * 0.5,
                (node.min[2] + node.max[2]) * 0.5,
            };
        }

        {
            const heatmap_path = try std.fmt.allocPrint(allocator, "{s}_e{d}_transport.ppm", .{ base_name, epoch_idx + 1 });
            defer allocator.free(heatmap_path);
            try writeTransportHeatmap(allocator, &solver.transport, cell_centroids, num_cells, world_min, world_max, heatmap_path);
            try stdout.print("  → {s}\n", .{heatmap_path});
        }
        {
            const density_path = try std.fmt.allocPrint(allocator, "{s}_e{d}_density.ppm", .{ base_name, epoch_idx + 1 });
            defer allocator.free(density_path);
            try writeVisibilityDensity(allocator, &solver, &cluster_bivh, cell_node_indices.items, cluster_count, world_min, world_max, density_path);
            try stdout.print("  → {s}\n", .{density_path});
        }

        // Final epoch: serialize PVS
        if (epoch_idx == epochs.len - 1) {
            const out_path = try deriveOutputPath(allocator, map_vpk_path);
            defer allocator.free(out_path);
            try serializePvs(allocator, &solver, &cluster_bivh, out_path);
            try stdout.print("  → {s}\n", .{out_path});
        }

        // Save transport for next epoch's seeding
        if (prev_transport) |*pt| pt.deinit();
        prev_transport = solver.transport;
        // Prevent solver.deinit() from freeing the transport we just saved
        solver.transport = try pvs_mod.TransportGraph.init(allocator, 1);

        if (prev_cluster_bivh) |*pcb| pcb.deinit();
        prev_cluster_bivh = cluster_bivh;
        // Prevent defer from freeing the BIVH we're keeping
        cluster_bivh = bivh_mod.Bivh.init(allocator);

        if (prev_cell_node_indices) |pcni| allocator.free(pcni);
        prev_cell_node_indices = try allocator.dupe(u32, cell_node_indices.items);
    }

    // ── Probe Placement ────────────────────────────────────────────────
    //
    // Use the final epoch's transport graph to find visibility islands
    // and place GI probes at the transitions between them.

    if (prev_transport) |*pt| {
        if (prev_cluster_bivh) |*pcb| {
            const final_cell_indices = prev_cell_node_indices.?;
            const final_num_cells: u32 = @intCast(final_cell_indices.len);

            try stdout.print("\n  ╔═══════════════════════════╗\n", .{});
            try stdout.print("  ║    Probe Placement        ║\n", .{});
            try stdout.print("  ╚═══════════════════════════╝\n", .{});

            // Compute cell centroids for the final epoch
            const final_centroids = try allocator.alloc(Vec3, final_num_cells);
            defer allocator.free(final_centroids);
            for (final_cell_indices, 0..) |node_idx, ci| {
                const node = pcb.nodes[node_idx];
                final_centroids[ci] = .{
                    (node.min[0] + node.max[0]) * 0.5,
                    (node.min[1] + node.max[1]) * 0.5,
                    (node.min[2] + node.max[2]) * 0.5,
                };
            }

            // Try a few thresholds to find meaningful island structure
            const thresholds = [_]f32{ 0.05, 0.15, 0.25, 0.35 };
            var best_threshold: f32 = 0.15;
            var best_score: f32 = 0;

            try stdout.writeAll("  Threshold scan:\n");
            for (thresholds) |thresh| {
                var test_islands = try pvs_mod.findIslands(allocator, pt, final_num_cells, thresh, 10);
                defer test_islands.deinit();

                // Score: prefer many islands with balanced sizes (entropy-like)
                if (test_islands.num_islands > 1) {
                    var score: f32 = 0;
                    for (0..test_islands.num_islands) |isl| {
                        var sz: u32 = 0;
                        for (test_islands.island_ids[0..final_num_cells]) |id| {
                            if (id == isl) sz += 1;
                        }
                        if (sz > 0) {
                            const frac = @as(f32, @floatFromInt(sz)) / @as(f32, @floatFromInt(final_num_cells));
                            score -= frac * @log(frac); // Shannon entropy
                        }
                    }
                    try stdout.print("    {d:.0}%: {d} islands, {d} boundary, entropy={d:.2}\n", .{
                        thresh * 100, test_islands.num_islands, test_islands.num_boundary, score,
                    });
                    if (score > best_score) {
                        best_score = score;
                        best_threshold = thresh;
                    }
                } else {
                    try stdout.print("    {d:.0}%: 1 island (all connected)\n", .{thresh * 100});
                }
            }

            try stdout.print("  Best threshold: {d:.0}% (entropy={d:.2})\n", .{ best_threshold * 100, best_score });

            var islands = try pvs_mod.findIslands(allocator, pt, final_num_cells, best_threshold, 10);
            defer islands.deinit();

            try stdout.print("  Islands:    {d}\n", .{islands.num_islands});
            try stdout.print("  Boundary:   {d} cells\n", .{islands.num_boundary});

            // Print island sizes
            {
                const island_sizes = try allocator.alloc(u32, islands.num_islands);
                defer allocator.free(island_sizes);
                @memset(island_sizes, 0);
                for (islands.island_ids[0..final_num_cells]) |id| island_sizes[id] += 1;

                try stdout.writeAll("  Sizes:     ");
                for (island_sizes, 0..) |sz, i| {
                    if (i > 0) try stdout.writeAll(", ");
                    if (i >= 20) {
                        try stdout.print("... +{d} more", .{islands.num_islands - i});
                        break;
                    }
                    try stdout.print("{d}", .{sz});
                }
                try stdout.writeAll("\n");
            }

            // Place probes: island interiors + transport gradient peaks
            const island_probes = try pvs_mod.placeProbes(allocator, &islands, pt, final_centroids, final_num_cells);
            defer allocator.free(island_probes);

            const gradient_probes = try pvs_mod.findGradientProbes(allocator, pt, final_centroids, final_num_cells, 0.15);
            defer allocator.free(gradient_probes);

            // Merge into one list
            var all_probes = std.ArrayList(pvs_mod.Probe).init(allocator);
            defer all_probes.deinit();
            try all_probes.appendSlice(island_probes);
            try all_probes.appendSlice(gradient_probes);
            const probes = all_probes.items;

            var boundary_count: u32 = 0;
            var interior_count: u32 = 0;
            for (probes) |p| {
                if (p.is_boundary) boundary_count += 1 else interior_count += 1;
            }
            try stdout.print("  Island probes:    {d} (interior)\n", .{interior_count});
            try stdout.print("  Gradient probes:  {d} (transitions)\n", .{boundary_count});
            try stdout.print("  Total probes:     {d}\n", .{probes.len});

            // Visualize islands + probes
            {
                const island_path = try std.fmt.allocPrint(allocator, "{s}_islands.ppm", .{base_name});
                defer allocator.free(island_path);
                try writeIslandMap(allocator, &islands, probes, pcb, final_cell_indices, final_centroids, final_num_cells, world_min, world_max, island_path);
                try stdout.print("  → {s}\n", .{island_path});
            }

            // Write probe positions to a simple text file
            {
                const probe_path = try std.fmt.allocPrint(allocator, "{s}_probes.txt", .{base_name});
                defer allocator.free(probe_path);
                var pf = try std.fs.cwd().createFile(probe_path, .{});
                defer pf.close();
                var pw = std.io.bufferedWriter(pf.writer());
                const w = pw.writer();
                try w.print("# PVS Probes: {d} total ({d} boundary, {d} interior)\n", .{ probes.len, boundary_count, interior_count });
                try w.print("# Format: x y z island_id type\n", .{});
                for (probes) |p| {
                    try w.print("{d:.4} {d:.4} {d:.4} {d} {s}\n", .{
                        p.position[0], p.position[1], p.position[2],
                        p.island_id,
                        if (p.is_boundary) "boundary" else "interior",
                    });
                }
                try pw.flush();
                try stdout.print("  → {s}\n", .{probe_path});
            }

            // ── Visibility-Gated Probe Assignment ────────────────────────

            try stdout.print("\n  ╔═══════════════════════════╗\n", .{});
            try stdout.print("  ║  Probe Assignment (Gated) ║\n", .{});
            try stdout.print("  ╚═══════════════════════════╝\n", .{});

            // Compute cluster centroids and cell assignments for final epoch
            const final_cluster_shift: u5 = epochs[epochs.len - 1].cluster_shift;
            const final_cluster_size: u32 = @as(u32, 1) << final_cluster_shift;
            const final_cluster_count = (tri_count + final_cluster_size - 1) / final_cluster_size;

            const cluster_centroids = try allocator.alloc(Vec3, final_cluster_count);
            defer allocator.free(cluster_centroids);
            const cluster_cells = try allocator.alloc(u32, final_cluster_count);
            defer allocator.free(cluster_cells);

            for (0..final_cluster_count) |ci| {
                const start_t = @as(u32, @intCast(ci)) * final_cluster_size;
                const end_t = @min(start_t + final_cluster_size, tri_count);

                // Compute cluster centroid from triangle centroids
                var cx: f64 = 0;
                var cy: f64 = 0;
                var cz: f64 = 0;
                var count: f64 = 0;
                for (start_t..end_t) |ti| {
                    const base = ti * 3;
                    for (0..3) |vi| {
                        const pos = all_positions.items[mesh_set.indices[base + vi]];
                        cx += pos[0];
                        cy += pos[1];
                        cz += pos[2];
                        count += 1;
                    }
                }
                if (count > 0) {
                    cluster_centroids[ci] = .{
                        @floatCast(cx / count),
                        @floatCast(cy / count),
                        @floatCast(cz / count),
                    };
                } else {
                    cluster_centroids[ci] = .{ 0, 0, 0 };
                }

                // Find which cell this cluster belongs to
                if (pcb.findLeaf(cluster_centroids[ci], null)) |node_idx| {
                    // Map BIVH node index → cell index
                    var cell_idx: u32 = 0;
                    for (final_cell_indices) |cni| {
                        if (cni == node_idx) break;
                        cell_idx += 1;
                    }
                    cluster_cells[ci] = @min(cell_idx, final_num_cells - 1);
                } else {
                    cluster_cells[ci] = 0;
                }
            }

            // Find which cell each probe is in
            const probe_cells = try allocator.alloc(u32, probes.len);
            defer allocator.free(probe_cells);
            for (probes, 0..) |probe, pi| {
                if (pcb.findLeaf(probe.position, null)) |node_idx| {
                    var cell_idx: u32 = 0;
                    for (final_cell_indices) |cni| {
                        if (cni == node_idx) break;
                        cell_idx += 1;
                    }
                    probe_cells[pi] = @min(cell_idx, final_num_cells - 1);
                } else {
                    probe_cells[pi] = 0;
                }
            }

            // Assign clusters to probes with visibility gating
            var assignment = try pvs_mod.assignProbes(
                allocator,
                cluster_centroids,
                cluster_cells,
                final_cluster_count,
                probes,
                probe_cells,
                pt,
            );
            defer assignment.deinit();

            try stdout.print("  Clusters:     {d}\n", .{final_cluster_count});
            try stdout.print("  Assigned:     {d} (gated)\n", .{assignment.assigned_count});
            try stdout.print("  Fallback:     {d} (nearest, no visible probe)\n", .{assignment.fallback_count});

            // Visualize: color each cluster by its assigned probe
            {
                const assign_path = try std.fmt.allocPrint(allocator, "{s}_probe_assign.ppm", .{base_name});
                defer allocator.free(assign_path);
                try writeProbeAssignment(allocator, &assignment, cluster_centroids, final_cluster_count, probes, world_min, world_max, assign_path);
                try stdout.print("  → {s}\n", .{assign_path});
            }

            // Write assignment to binary
            {
                const assign_bin = try std.fmt.allocPrint(allocator, "{s}_probe_assign.bin", .{base_name});
                defer allocator.free(assign_bin);
                var af = try std.fs.cwd().createFile(assign_bin, .{});
                defer af.close();
                var aw = std.io.bufferedWriter(af.writer());
                const w = aw.writer();
                try w.writeAll("PASN"); // magic
                try w.writeInt(u32, final_cluster_count, .little);
                try w.writeInt(u32, @intCast(probes.len), .little);
                for (assignment.cluster_to_probe) |pid| {
                    try w.writeInt(u32, pid, .little);
                }
                try aw.flush();
                try stdout.print("  → {s}\n", .{assign_bin});
            }

            // ── Phase 4: Light Propagation ───────────────────────────────

            try stdout.print("\n  ╔═══════════════════════════╗\n", .{});
            try stdout.print("  ║  Light Propagation (SH)   ║\n", .{});
            try stdout.print("  ╚═══════════════════════════╝\n", .{});

            // Initialize per-probe SH coefficients
            const probe_sh = try allocator.alloc(pvs_mod.SHCoeffs, probes.len);
            defer allocator.free(probe_sh);
            @memset(probe_sh, pvs_mod.SHCoeffs{});

            // Inject lights:
            // 1. Sun light from above-right (warm)
            const sun_dir = Vec3{ 0.5, 0.8, 0.3 };
            const sun_len = @sqrt(sun_dir[0] * sun_dir[0] + sun_dir[1] * sun_dir[1] + sun_dir[2] * sun_dir[2]);
            const sun_norm = Vec3{ sun_dir[0] / sun_len, sun_dir[1] / sun_len, sun_dir[2] / sun_len };
            const sun_sh = pvs_mod.SHCoeffs.fromDirectional(sun_norm, .{ 1.0, 0.9, 0.7 });

            // 2. Sky ambient (cool blue)
            const sky_sh = pvs_mod.SHCoeffs.fromAmbient(.{ 0.15, 0.2, 0.35 });

            // Inject sun + sky into all probes that are "outdoors"
            // (heuristic: probes above the median Y height are outdoors)
            var median_y: f32 = 0;
            for (probes) |p| median_y += p.position[1];
            median_y /= @floatFromInt(probes.len);

            var outdoor_count: u32 = 0;
            for (probes, 0..) |probe, pi| {
                if (probe.position[1] >= median_y - 1.0) {
                    // Outdoor probe — gets sun + sky
                    probe_sh[pi].add(sun_sh);
                    probe_sh[pi].add(sky_sh);
                    outdoor_count += 1;
                } else {
                    // Indoor probe — just a little ambient
                    probe_sh[pi].add(pvs_mod.SHCoeffs.fromAmbient(.{ 0.05, 0.05, 0.08 }));
                }
            }

            try stdout.print("  Probes:       {d} ({d} outdoor)\n", .{ probes.len, outdoor_count });

            // Propagate through transport graph
            const num_bounces: u32 = 4;
            const bounce_falloff: f32 = 0.4;
            try stdout.print("  Bounces:      {d} (falloff={d:.1})\n", .{ num_bounces, bounce_falloff });

            pvs_mod.propagateLight(
                probe_sh,
                @intCast(probes.len),
                probe_cells,
                pt,
                num_bounces,
                bounce_falloff,
            );

            // Map probe lighting to clusters via assignment
            // Each cluster gets its assigned probe's SH intensity
            const cluster_light = try allocator.alloc(f32, final_cluster_count);
            defer allocator.free(cluster_light);
            var max_light: f32 = 0.001;

            for (0..final_cluster_count) |ci| {
                const pid = assignment.cluster_to_probe[ci];
                if (pid < probes.len) {
                    cluster_light[ci] = probe_sh[pid].intensity();
                    max_light = @max(max_light, cluster_light[ci]);
                } else {
                    cluster_light[ci] = 0;
                }
            }

            try stdout.print("  Max intensity: {d:.3}\n", .{max_light});

            // Visualize lighting
            {
                const light_path = try std.fmt.allocPrint(allocator, "{s}_lighting.ppm", .{base_name});
                defer allocator.free(light_path);
                try writeLightingMap(allocator, cluster_light, cluster_centroids, final_cluster_count, probe_sh, probes, max_light, world_min, world_max, light_path);
                try stdout.print("  → {s}\n", .{light_path});
            }
        }
    }

    if (prev_cell_node_indices) |pcni| allocator.free(pcni);
    if (prev_cluster_bivh) |*pcb| pcb.deinit();
    if (prev_transport) |*pt| pt.deinit();

    const t_total = std.time.nanoTimestamp();
    try stdout.print("\n  ═══ Total time: {d}ms ═══\n", .{@divTrunc(t_total - t0, 1_000_000)});
}

// ── BIVH adapter for PVS function pointers ──────────────────────────

const TraceContext = struct {
    bivh: *const bivh_mod.Bivh,
    mesh_set: *const bivh_mod.TriangleMeshSet,
};

fn traceWorld(ctx: *anyopaque, origin: Vec3, dir: Vec3, max_dist: f32) pvs_mod.TraceResult {
    const tc: *const TraceContext = @ptrCast(@alignCast(ctx));
    var ray = bivh_mod.TraceRay.make(
        origin[0],
        origin[1],
        origin[2],
        dir[0],
        dir[1],
        dir[2],
        max_dist,
    );
    const hit = tc.bivh.trace(tc.mesh_set, &ray, 0.0001, max_dist);
    return .{
        .hit = hit,
        .distance = ray.hit_distance,
        .primitive = ray.hit_primitive,
        .cell = ray.hit_cell,
    };
}

const CellContext = struct {
    bivh: *const bivh_mod.Bivh,
};

fn findClusterCell(ctx: *anyopaque, pos: Vec3) ?u32 {
    const cc: *const CellContext = @ptrCast(@alignCast(ctx));
    return cc.bivh.findLeaf(pos, null);
}

fn progressCallback(pass: u32, added: u64, total: u64) void {
    if (pass % 500 == 0) {
        std.debug.print("  Pass {d}: +{d} (total {d})\n", .{ pass, added, total });
    }
}

// ── Geometry extraction ─────────────────────────────────────────────

fn extractModelGeometry(
    allocator: Allocator,
    data: []const u8,
    positions: *std.ArrayList(Vec3),
    indices: *std.ArrayList(u32),
) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var resource = Resource.init(arena);
    defer resource.deinit();
    resource.resource_type = .model;
    resource.read(data) catch return error.ParseFailed;

    // Try legacy VBIB/MBUF first
    for (resource.blocks.items) |blk| {
        if (blk.block_type == .vbib or blk.block_type == .mbuf) {
            if (blk.size > 0) {
                const block_bytes = data[blk.offset..][0..blk.size];
                var vbib = vrf.VBIB.readFromBinaryBlock(arena, block_bytes) catch return error.ParseFailed;
                defer vbib.deinit();
                if (vbib.vertex_buffers.len > 0 and vbib.index_buffers.len > 0) {
                    try appendVbibGeometry(allocator, &vbib, positions, indices, null);
                    return;
                }
            }
        }
    }

    // Embedded mesh path (CS2 MDAT/MVTX/MIDX)
    const ctrl_block = resource.getBlockByType(.ctrl) orelse return error.ParseFailed;
    const ctrl_raw = switch (ctrl_block.data) {
        .kv3_block => |kb| kb.raw_data orelse return error.ParseFailed,
        else => return error.ParseFailed,
    };

    var ctrl_doc = binary_kv3.decode(arena, ctrl_raw) catch return error.ParseFailed;
    defer ctrl_doc.deinit();
    const ctrl_root = ctrl_doc.root.asObject() orelse return error.ParseFailed;

    const em_arr = ctrl_root.getArray("embedded_meshes") orelse return error.ParseFailed;
    if (em_arr.count() == 0) return error.ParseFailed;
    const em_obj = em_arr.items.items[0].asObject() orelse return error.ParseFailed;

    var vbib = vrf.VBIB.readFromEmbeddedMesh(arena, em_obj, &resource) catch return error.ParseFailed;
    defer vbib.deinit();
    if (vbib.vertex_buffers.len == 0 or vbib.index_buffers.len == 0) return error.ParseFailed;

    // Parse draw calls from MDAT for per-draw-call index ranges
    const data_block_index = if (em_obj.get("m_nDataBlock")) |v| v.asU32() else null;
    if (data_block_index) |dbi| {
        if (resource.getBlockByIndex(@intCast(dbi))) |mdat_block| {
            const mdat_raw = switch (mdat_block.data) {
                .data_block => |db| db.raw_data,
                else => null,
            };
            if (mdat_raw) |raw| {
                var mdat_doc = binary_kv3.decode(arena, raw) catch null;
                if (mdat_doc) |*doc| {
                    defer doc.deinit();
                    if (doc.root.asObject()) |mdat_root| {
                        if (mdat_root.getArray("m_sceneObjects")) |so_arr| {
                            var has_draw_calls = false;
                            for (so_arr.items.items) |*so_val| {
                                const so_obj = so_val.asObject() orelse continue;
                                if (so_obj.getArray("m_drawCalls")) |dc_arr| {
                                    for (dc_arr.items.items) |*dc_val| {
                                        const dc_obj = dc_val.asObject() orelse continue;
                                        const start_index = dc_obj.getU32Property("m_nStartIndex") orelse continue;
                                        const index_count = dc_obj.getU32Property("m_nIndexCount") orelse continue;
                                        if (index_count == 0) continue;
                                        const dc_info = DrawCallRange{
                                            .start_index = start_index,
                                            .index_count = index_count,
                                        };
                                        appendVbibGeometry(allocator, &vbib, positions, indices, dc_info) catch continue;
                                        has_draw_calls = true;
                                    }
                                }
                            }
                            if (has_draw_calls) return;
                        }
                    }
                }
            }
        }
    }

    // Fallback: whole buffer as a single draw call
    try appendVbibGeometry(allocator, &vbib, positions, indices, null);
}

const DrawCallRange = struct {
    start_index: u32,
    index_count: u32,
};

fn appendVbibGeometry(
    allocator: Allocator,
    vbib: *vrf.VBIB,
    positions: *std.ArrayList(Vec3),
    indices: *std.ArrayList(u32),
    range: ?DrawCallRange,
) !void {
    _ = allocator;
    const vb = &vbib.vertex_buffers[0];
    const ib = &vbib.index_buffers[0];

    const start_idx = if (range) |r| r.start_index else 0;
    const idx_count = if (range) |r| r.index_count else ib.element_count;

    // Find vertex range used by these indices
    var min_vert: u32 = std.math.maxInt(u32);
    var max_vert: u32 = 0;
    for (0..idx_count) |i| {
        const raw = ib.getIndex(start_idx + @as(u32, @intCast(i)));
        min_vert = @min(min_vert, raw);
        max_vert = @max(max_vert, raw);
    }
    if (min_vert > max_vert) return;

    const vert_count = max_vert - min_vert + 1;
    const base_vertex: u32 = @intCast(positions.items.len);

    // Append positions (Source 2 Z-up → Y-up: x, z, -y)
    try positions.ensureUnusedCapacity(vert_count);
    for (0..vert_count) |i| {
        const pos = vb.getPosition(min_vert + @as(u32, @intCast(i)));
        positions.appendAssumeCapacity(.{
            pos[0] * S2_SCALE,
            pos[2] * S2_SCALE,
            -pos[1] * S2_SCALE,
        });
    }

    // Append indices (rebased to global position array)
    try indices.ensureUnusedCapacity(idx_count);
    for (0..idx_count) |i| {
        const raw = ib.getIndex(start_idx + @as(u32, @intCast(i)));
        indices.appendAssumeCapacity(base_vertex + (raw - min_vert));
    }
}

// ── Output ──────────────────────────────────────────────────────────

fn deriveOutputPath(allocator: Allocator, vpk_path: []const u8) ![]u8 {
    // Strip extension and append _pvs.bin
    const base = std.fs.path.stem(vpk_path);
    return std.fmt.allocPrint(allocator, "{s}_pvs.bin", .{base});
}

fn serializePvs(
    allocator: Allocator,
    solver: *const pvs_mod.PvsSolver,
    bivh: *const bivh_mod.Bivh,
    path: []const u8,
) !void {
    var file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    var bw = std.io.bufferedWriter(file.writer());
    const writer = bw.writer();

    // Header
    try writer.writeAll("PVS1"); // magic
    try writer.writeInt(u32, solver.tri_count, .little);
    try writer.writeInt(u32, solver.cluster_count, .little);
    try writer.writeInt(u32, bivh.node_count, .little);
    try writer.writeInt(u32, @intCast(solver.visibility.cells.len), .little);

    // For each active cell: cell_index, visible_count, [visible_cluster_indices...]
    const buf = try allocator.alloc(u32, solver.cluster_count);
    defer allocator.free(buf);

    var cells_written: u32 = 0;
    for (solver.visibility.cells, 0..) |cell, ci| {
        if (cell) |bm| {
            const count = bm.getSetBits(buf);
            if (count == 0) continue;
            try writer.writeInt(u32, @intCast(ci), .little);
            try writer.writeInt(u32, count, .little);
            for (0..count) |i| {
                try writer.writeInt(u32, buf[i], .little);
            }
            cells_written += 1;
        }
    }

    try bw.flush();
    std.debug.print("  Serialized {d} cells to {s}\n", .{ cells_written, path });
}

// ── Visualization ───────────────────────────────────────────────────

const IMG_SIZE: u32 = 2048;

const Color = struct { r: u8, g: u8, b: u8 };

/// Map world XZ coordinates to pixel coordinates (top-down Y-up view).
/// X maps to pixel X, Z maps to pixel Y (inverted so +Z is up).
fn worldToPixel(pos: Vec3, world_min: [3]f32, world_max: [3]f32, size: u32) struct { x: i32, y: i32 } {
    const margin: f32 = 0.02; // 2% margin
    const dx = world_max[0] - world_min[0];
    const dz = world_max[2] - world_min[2];
    const span = @max(dx, dz); // uniform scale
    const pad = span * margin;

    const fx = (pos[0] - world_min[0] + pad) / (span + 2 * pad);
    const fz = (pos[2] - world_min[2] + pad) / (span + 2 * pad);

    return .{
        .x = @intFromFloat(fx * @as(f32, @floatFromInt(size - 1))),
        .y = @intFromFloat((1.0 - fz) * @as(f32, @floatFromInt(size - 1))),
    };
}

/// Lerp between two colors.
fn lerpColor(a: Color, b: Color, t: f32) Color {
    const ct = std.math.clamp(t, 0, 1);
    return .{
        .r = @intFromFloat(@as(f32, @floatFromInt(a.r)) * (1 - ct) + @as(f32, @floatFromInt(b.r)) * ct),
        .g = @intFromFloat(@as(f32, @floatFromInt(a.g)) * (1 - ct) + @as(f32, @floatFromInt(b.g)) * ct),
        .b = @intFromFloat(@as(f32, @floatFromInt(a.b)) * (1 - ct) + @as(f32, @floatFromInt(b.b)) * ct),
    };
}

/// Heat color ramp: blue → cyan → green → yellow → red
fn heatColor(t: f32) Color {
    const ct = std.math.clamp(t, 0, 1);
    if (ct < 0.25) {
        return lerpColor(.{ .r = 0, .g = 0, .b = 128 }, .{ .r = 0, .g = 200, .b = 200 }, ct * 4.0);
    } else if (ct < 0.5) {
        return lerpColor(.{ .r = 0, .g = 200, .b = 200 }, .{ .r = 0, .g = 255, .b = 0 }, (ct - 0.25) * 4.0);
    } else if (ct < 0.75) {
        return lerpColor(.{ .r = 0, .g = 255, .b = 0 }, .{ .r = 255, .g = 255, .b = 0 }, (ct - 0.5) * 4.0);
    } else {
        return lerpColor(.{ .r = 255, .g = 255, .b = 0 }, .{ .r = 255, .g = 0, .b = 0 }, (ct - 0.75) * 4.0);
    }
}

/// Draw a line using Bresenham's algorithm with additive blending.
fn drawLine(pixels: []Color, size: u32, x0: i32, y0: i32, x1: i32, y1: i32, color: Color, alpha: f32) void {
    var x = x0;
    var y = y0;
    const dx_abs: i32 = if (x1 > x0) x1 - x0 else x0 - x1;
    const dy_abs: i32 = if (y1 > y0) y1 - y0 else y0 - y1;
    const sx: i32 = if (x0 < x1) 1 else -1;
    const sy: i32 = if (y0 < y1) 1 else -1;
    var err = dx_abs - dy_abs;

    const img_sz: i32 = @intCast(size);
    const steps = dx_abs + dy_abs + 1;

    for (0..@intCast(steps)) |_| {
        if (x >= 0 and x < img_sz and y >= 0 and y < img_sz) {
            const idx: usize = @intCast(y * img_sz + x);
            const old = pixels[idx];
            pixels[idx] = .{
                .r = @intCast(@min(255, @as(u16, old.r) + @as(u16, @intFromFloat(@as(f32, @floatFromInt(color.r)) * alpha)))),
                .g = @intCast(@min(255, @as(u16, old.g) + @as(u16, @intFromFloat(@as(f32, @floatFromInt(color.g)) * alpha)))),
                .b = @intCast(@min(255, @as(u16, old.b) + @as(u16, @intFromFloat(@as(f32, @floatFromInt(color.b)) * alpha)))),
            };
        }
        if (x == x1 and y == y1) break;
        const e2 = err * 2;
        if (e2 > -dy_abs) {
            err -= dy_abs;
            x += sx;
        }
        if (e2 < dx_abs) {
            err += dx_abs;
            y += sy;
        }
    }
}

/// Fill an axis-aligned rectangle.
fn fillRect(pixels: []Color, size: u32, x0: i32, y0: i32, x1: i32, y1: i32, color: Color) void {
    const img_sz: i32 = @intCast(size);
    const ax = std.math.clamp(x0, 0, img_sz - 1);
    const ay = std.math.clamp(y0, 0, img_sz - 1);
    const bx = std.math.clamp(x1, 0, img_sz - 1);
    const by = std.math.clamp(y1, 0, img_sz - 1);

    var row = ay;
    while (row <= by) : (row += 1) {
        var col = ax;
        while (col <= bx) : (col += 1) {
            pixels[@intCast(row * img_sz + col)] = color;
        }
    }
}

/// Accumulate line into float RGB buffer (no clamping).
fn drawLineAccum(accum: []f32, size: u32, x0: i32, y0: i32, x1: i32, y1: i32, color: Color, weight: f32) void {
    var x = x0;
    var y = y0;
    const dx_abs: i32 = if (x1 > x0) x1 - x0 else x0 - x1;
    const dy_abs: i32 = if (y1 > y0) y1 - y0 else y0 - y1;
    const sx: i32 = if (x0 < x1) 1 else -1;
    const sy: i32 = if (y0 < y1) 1 else -1;
    var err = dx_abs - dy_abs;

    const img_sz: i32 = @intCast(size);
    const steps = dx_abs + dy_abs + 1;

    const cr = @as(f32, @floatFromInt(color.r)) * weight;
    const cg = @as(f32, @floatFromInt(color.g)) * weight;
    const cb = @as(f32, @floatFromInt(color.b)) * weight;

    for (0..@intCast(steps)) |_| {
        if (x >= 0 and x < img_sz and y >= 0 and y < img_sz) {
            const base: usize = @intCast(y * img_sz + x);
            accum[base * 3] += cr;
            accum[base * 3 + 1] += cg;
            accum[base * 3 + 2] += cb;
        }
        if (x == x1 and y == y1) break;
        const e2 = err * 2;
        if (e2 > -dy_abs) {
            err -= dy_abs;
            x += sx;
        }
        if (e2 < dx_abs) {
            err += dx_abs;
            y += sy;
        }
    }
}

/// Reinhard tone mapping: maps [0, inf) → [0, 255]
fn toneMap(val: f32, max_val: f32) u8 {
    // Normalize, then Reinhard: L / (1 + L)
    const normalized = val / max_val * 4.0; // exposure boost
    const mapped = normalized / (1.0 + normalized);
    return @intFromFloat(std.math.clamp(mapped * 255.0, 0, 255));
}

fn writePpm(pixels: []const Color, size: u32, path: []const u8) !void {
    var file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    var bw = std.io.bufferedWriter(file.writer());
    const w = bw.writer();
    try w.print("P6\n{d} {d}\n255\n", .{ size, size });
    for (pixels) |px| {
        try w.writeAll(&[_]u8{ px.r, px.g, px.b });
    }
    try bw.flush();
}

fn writeTransportHeatmap(
    allocator: Allocator,
    transport: *const pvs_mod.TransportGraph,
    centroids: []const Vec3,
    num_cells: u32,
    world_min: [3]f32,
    world_max: [3]f32,
    path: []const u8,
) !void {
    const size = IMG_SIZE;
    const pixels = try allocator.alloc(Color, size * size);
    defer allocator.free(pixels);
    @memset(pixels, Color{ .r = 15, .g = 15, .b = 20 }); // dark background

    // Accumulate edge density into a float buffer, then tone-map
    const accum = try allocator.alloc(f32, size * size * 3);
    defer allocator.free(accum);
    @memset(accum, 0);

    for (0..num_cells) |i| {
        for (i + 1..num_cells) |j| {
            const edge = transport.getEdge(@intCast(i), @intCast(j));
            const casts = edge.casts.load(.monotonic);
            if (casts == 0) continue;
            const hits = edge.hits.load(.monotonic);
            if (hits == 0) continue;

            const prob = @as(f32, @floatFromInt(hits)) / @as(f32, @floatFromInt(casts));
            const color = heatColor(prob);
            // Weight by confidence (log scale to avoid blowout)
            const confidence = @min(1.0, std.math.log2(@as(f32, @floatFromInt(@min(casts, 10000))) + 1.0) / 13.0);
            const weight = prob * confidence;

            const p0 = worldToPixel(centroids[i], world_min, world_max, size);
            const p1 = worldToPixel(centroids[j], world_min, world_max, size);
            drawLineAccum(accum, size, p0.x, p0.y, p1.x, p1.y, color, weight);
        }
    }

    // Tone-map: find max, then apply Reinhard
    var max_val: f32 = 0.001;
    for (accum) |v| max_val = @max(max_val, v);

    for (0..size * size) |px| {
        const base = px * 3;
        pixels[px] = .{
            .r = toneMap(accum[base], max_val),
            .g = toneMap(accum[base + 1], max_val),
            .b = toneMap(accum[base + 2], max_val),
        };
    }

    // Draw cell centers as bright dots on top
    for (centroids[0..num_cells]) |c| {
        const p = worldToPixel(c, world_min, world_max, size);
        fillRect(pixels, size, p.x - 1, p.y - 1, p.x + 1, p.y + 1, .{ .r = 255, .g = 255, .b = 255 });
    }

    try writePpm(pixels, size, path);
}

fn writeVisibilityDensity(
    allocator: Allocator,
    solver: *const pvs_mod.PvsSolver,
    cluster_bivh: *const bivh_mod.Bivh,
    cell_node_indices: []const u32,
    cluster_count: u32,
    world_min: [3]f32,
    world_max: [3]f32,
    path: []const u8,
) !void {
    const size = IMG_SIZE;
    const pixels = try allocator.alloc(Color, size * size);
    defer allocator.free(pixels);
    @memset(pixels, Color{ .r = 15, .g = 15, .b = 20 });

    // Find max visible count for normalization
    var max_count: u32 = 1;
    for (cell_node_indices) |node_idx| {
        const count = solver.visibility.visibleCount(node_idx);
        max_count = @max(max_count, count);
    }

    // Draw each cell as a filled rectangle colored by visibility density
    for (cell_node_indices) |node_idx| {
        const node = cluster_bivh.nodes[node_idx];
        const count = solver.visibility.visibleCount(node_idx);
        const t = @as(f32, @floatFromInt(count)) / @as(f32, @floatFromInt(max_count));

        const p_min = worldToPixel(node.min, world_min, world_max, size);
        const p_max = worldToPixel(node.max, world_min, world_max, size);

        // p_min.y > p_max.y because Y is inverted in screen space
        const color = heatColor(t);
        fillRect(pixels, size, p_min.x, p_max.y, p_max.x, p_min.y, color);
    }

    // Overlay: draw outline text showing count / total
    // (PPM is simple — no text, but the colors tell the story)

    // Draw cell outlines in white for structure
    for (cell_node_indices) |node_idx| {
        const node = cluster_bivh.nodes[node_idx];
        const p_min = worldToPixel(node.min, world_min, world_max, size);
        const p_max = worldToPixel(node.max, world_min, world_max, size);
        const outline = Color{ .r = 80, .g = 80, .b = 80 };
        drawLine(pixels, size, p_min.x, p_max.y, p_max.x, p_max.y, outline, 1.0);
        drawLine(pixels, size, p_max.x, p_max.y, p_max.x, p_min.y, outline, 1.0);
        drawLine(pixels, size, p_max.x, p_min.y, p_min.x, p_min.y, outline, 1.0);
        drawLine(pixels, size, p_min.x, p_min.y, p_min.x, p_max.y, outline, 1.0);
    }

    // Legend: draw a color bar at the bottom
    const bar_y: i32 = @intCast(size - 30);
    const bar_h: i32 = 20;
    for (0..size) |xi| {
        const t = @as(f32, @floatFromInt(xi)) / @as(f32, @floatFromInt(size - 1));
        const color = heatColor(t);
        fillRect(pixels, size, @intCast(xi), bar_y, @intCast(xi), bar_y + bar_h, color);
    }

    // Labels: "0" on left, max on right (as pixel text is hard, just mark with white ticks)
    fillRect(pixels, size, 0, bar_y - 5, 2, bar_y - 1, .{ .r = 255, .g = 255, .b = 255 });
    fillRect(pixels, size, @intCast(size - 3), bar_y - 5, @intCast(size - 1), bar_y - 1, .{ .r = 255, .g = 255, .b = 255 });

    _ = cluster_count;

    try writePpm(pixels, size, path);
}

fn writeIslandMap(
    allocator: Allocator,
    islands: *const pvs_mod.IslandResult,
    probes: []const pvs_mod.Probe,
    cluster_bivh: *const bivh_mod.Bivh,
    cell_node_indices: []const u32,
    cell_centroids: []const Vec3,
    num_cells: u32,
    world_min: [3]f32,
    world_max: [3]f32,
    path: []const u8,
) !void {
    const size = IMG_SIZE;
    const pixels = try allocator.alloc(Color, size * size);
    defer allocator.free(pixels);
    @memset(pixels, Color{ .r = 15, .g = 15, .b = 20 });

    // Distinct colors per island (golden ratio hue spread)
    const island_colors = try allocator.alloc(Color, islands.num_islands);
    defer allocator.free(island_colors);
    for (0..islands.num_islands) |i| {
        const hue = @as(f32, @floatFromInt(i)) * 0.618033988749895;
        const h = hue - @floor(hue);
        island_colors[i] = hsvToRgb(h, 0.7, 0.8);
    }

    // Draw cells colored by island
    for (cell_node_indices[0..num_cells], 0..) |node_idx, ci| {
        const node = cluster_bivh.nodes[node_idx];
        const island = islands.island_ids[ci];
        const color = island_colors[island];

        const p_min = worldToPixel(node.min, world_min, world_max, size);
        const p_max = worldToPixel(node.max, world_min, world_max, size);
        fillRect(pixels, size, p_min.x, p_max.y, p_max.x, p_min.y, color);
    }

    // Draw cell outlines
    for (cell_node_indices[0..num_cells]) |node_idx| {
        const node = cluster_bivh.nodes[node_idx];
        const p_min = worldToPixel(node.min, world_min, world_max, size);
        const p_max = worldToPixel(node.max, world_min, world_max, size);
        const outline = Color{ .r = 40, .g = 40, .b = 40 };
        drawLine(pixels, size, p_min.x, p_max.y, p_max.x, p_max.y, outline, 1.0);
        drawLine(pixels, size, p_max.x, p_max.y, p_max.x, p_min.y, outline, 1.0);
        drawLine(pixels, size, p_max.x, p_min.y, p_min.x, p_min.y, outline, 1.0);
        drawLine(pixels, size, p_min.x, p_min.y, p_min.x, p_max.y, outline, 1.0);
    }

    // Draw probes — boundary probes as white diamonds, interior as yellow circles
    for (probes) |probe| {
        const p = worldToPixel(probe.position, world_min, world_max, size);
        if (probe.is_boundary) {
            // White diamond for boundary probes
            const s_half: i32 = 4;
            drawLine(pixels, size, p.x, p.y - s_half, p.x + s_half, p.y, .{ .r = 255, .g = 255, .b = 255 }, 1.0);
            drawLine(pixels, size, p.x + s_half, p.y, p.x, p.y + s_half, .{ .r = 255, .g = 255, .b = 255 }, 1.0);
            drawLine(pixels, size, p.x, p.y + s_half, p.x - s_half, p.y, .{ .r = 255, .g = 255, .b = 255 }, 1.0);
            drawLine(pixels, size, p.x - s_half, p.y, p.x, p.y - s_half, .{ .r = 255, .g = 255, .b = 255 }, 1.0);
        } else {
            // Yellow square for interior probes
            fillRect(pixels, size, p.x - 3, p.y - 3, p.x + 3, p.y + 3, .{ .r = 255, .g = 255, .b = 0 });
        }
    }

    // Mark boundary cells with a bright outline
    for (islands.boundary_cells[0..islands.num_boundary]) |cell| {
        const p = worldToPixel(cell_centroids[cell], world_min, world_max, size);
        fillRect(pixels, size, p.x - 1, p.y - 1, p.x + 1, p.y + 1, .{ .r = 255, .g = 100, .b = 100 });
    }

    try writePpm(pixels, size, path);
}

fn hsvToRgb(h: f32, s: f32, v: f32) Color {
    const c = v * s;
    const hp = h * 6.0;
    const x = c * (1.0 - @abs(@mod(hp, 2.0) - 1.0));
    const m = v - c;

    var r: f32 = 0;
    var g: f32 = 0;
    var b: f32 = 0;

    if (hp < 1) {
        r = c; g = x;
    } else if (hp < 2) {
        r = x; g = c;
    } else if (hp < 3) {
        g = c; b = x;
    } else if (hp < 4) {
        g = x; b = c;
    } else if (hp < 5) {
        r = x; b = c;
    } else {
        r = c; b = x;
    }

    return .{
        .r = @intFromFloat((r + m) * 255),
        .g = @intFromFloat((g + m) * 255),
        .b = @intFromFloat((b + m) * 255),
    };
}

fn writeProbeAssignment(
    allocator: Allocator,
    assignment: *const pvs_mod.ProbeAssignment,
    cluster_centroids: []const Vec3,
    cluster_count: u32,
    probes: []const pvs_mod.Probe,
    world_min: [3]f32,
    world_max: [3]f32,
    path: []const u8,
) !void {
    const size = IMG_SIZE;
    const pixels = try allocator.alloc(Color, size * size);
    defer allocator.free(pixels);
    @memset(pixels, Color{ .r = 10, .g = 10, .b = 15 });

    // Generate a color per probe using golden ratio hue
    const probe_colors = try allocator.alloc(Color, probes.len);
    defer allocator.free(probe_colors);
    for (0..probes.len) |i| {
        const hue = @as(f32, @floatFromInt(i)) * 0.618033988749895;
        const h = hue - @floor(hue);
        probe_colors[i] = hsvToRgb(h, 0.8, 0.85);
    }

    // Plot each cluster as a dot colored by its assigned probe
    for (0..cluster_count) |ci| {
        const probe_id = assignment.cluster_to_probe[ci];
        if (probe_id >= probes.len) continue;
        const color = probe_colors[probe_id];
        const p = worldToPixel(cluster_centroids[ci], world_min, world_max, size);
        fillRect(pixels, size, p.x - 1, p.y - 1, p.x + 1, p.y + 1, color);
    }

    // Draw probe positions — white for boundary, yellow for interior
    for (probes) |probe| {
        const p = worldToPixel(probe.position, world_min, world_max, size);
        if (probe.is_boundary) {
            // White diamond
            drawLine(pixels, size, p.x, p.y - 5, p.x + 5, p.y, .{ .r = 255, .g = 255, .b = 255 }, 1.0);
            drawLine(pixels, size, p.x + 5, p.y, p.x, p.y + 5, .{ .r = 255, .g = 255, .b = 255 }, 1.0);
            drawLine(pixels, size, p.x, p.y + 5, p.x - 5, p.y, .{ .r = 255, .g = 255, .b = 255 }, 1.0);
            drawLine(pixels, size, p.x - 5, p.y, p.x, p.y - 5, .{ .r = 255, .g = 255, .b = 255 }, 1.0);
        } else {
            // Yellow square
            fillRect(pixels, size, p.x - 4, p.y - 4, p.x + 4, p.y + 4, .{ .r = 255, .g = 255, .b = 0 });
        }
    }

    try writePpm(pixels, size, path);
}

fn writeLightingMap(
    allocator: Allocator,
    cluster_light: []const f32,
    cluster_centroids: []const Vec3,
    cluster_count: u32,
    probe_sh: []const pvs_mod.SHCoeffs,
    probes: []const pvs_mod.Probe,
    max_light: f32,
    world_min: [3]f32,
    world_max: [3]f32,
    path: []const u8,
) !void {
    const size = IMG_SIZE;
    const pixels = try allocator.alloc(Color, size * size);
    defer allocator.free(pixels);
    @memset(pixels, Color{ .r = 5, .g = 5, .b = 8 });

    // Find median intensity for adaptive exposure
    _ = max_light;
    const sorted = try allocator.alloc(f32, cluster_count);
    defer allocator.free(sorted);
    @memcpy(sorted, cluster_light);
    std.mem.sort(f32, sorted, {}, std.sort.asc(f32));
    // Use 90th percentile for exposure — most clusters should be visible
    const p90 = sorted[@min(cluster_count - 1, cluster_count * 9 / 10)];
    const exposure = if (p90 > 0.001) 8.0 / p90 else 1.0;

    // Plot each cluster colored by its lighting intensity
    for (0..cluster_count) |ci| {
        const intensity = cluster_light[ci] * exposure;
        const mapped = intensity / (1.0 + intensity); // Reinhard with adaptive exposure

        // Warm/cool: bright = warm sun, dim = cool shadow
        const color = Color{
            .r = @intFromFloat(std.math.clamp(mapped * 255 * 1.1, 0, 255)),
            .g = @intFromFloat(std.math.clamp(mapped * 255 * 0.9, 0, 255)),
            .b = @intFromFloat(std.math.clamp(mapped * 255 * 0.7 + (1.0 - mapped) * 40, 0, 255)),
        };

        const p = worldToPixel(cluster_centroids[ci], world_min, world_max, size);
        fillRect(pixels, size, p.x - 2, p.y - 2, p.x + 2, p.y + 2, color);
    }

    // Draw probes colored by their SH intensity
    for (probes, 0..) |probe, pi| {
        const p = worldToPixel(probe.position, world_min, world_max, size);
        const sh_val = probe_sh[pi].intensity() * exposure;
        const sh_mapped = sh_val / (1.0 + sh_val);
        const bright: u8 = @intFromFloat(std.math.clamp(sh_mapped * 255, 0, 255));

        if (probe.is_boundary) {
            drawLine(pixels, size, p.x, p.y - 4, p.x + 4, p.y, .{ .r = bright, .g = bright, .b = 255 }, 1.0);
            drawLine(pixels, size, p.x + 4, p.y, p.x, p.y + 4, .{ .r = bright, .g = bright, .b = 255 }, 1.0);
            drawLine(pixels, size, p.x, p.y + 4, p.x - 4, p.y, .{ .r = bright, .g = bright, .b = 255 }, 1.0);
            drawLine(pixels, size, p.x - 4, p.y, p.x, p.y - 4, .{ .r = bright, .g = bright, .b = 255 }, 1.0);
        } else {
            fillRect(pixels, size, p.x - 3, p.y - 3, p.x + 3, p.y + 3, .{ .r = bright, .g = bright, .b = bright });
        }
    }

    try writePpm(pixels, size, path);
}
