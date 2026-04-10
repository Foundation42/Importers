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
const pvs_viz = @import("pvs_viz");
const pvs_neural = @import("pvs_neural");
const pvs_exemplar = @import("pvs_exemplar");

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
    const stderr = std.io.getStdErr().writer();
    try stdout.print("PVS Baker — Loading {s}\n", .{map_vpk_path});

    const t0 = std.time.nanoTimestamp();

    // ── FAST_EPVS fast path: skip walker/probes/datagen, rerun exemplar
    // selection AND MLP training from the cached training data. The cache
    // is self-contained (TDAT v2 includes per-PVS-unit centroids) so no
    // geometry re-load is needed.
    const fast_epvs = std.process.getEnvVarOwned(allocator, "FAST_EPVS") catch null;
    defer if (fast_epvs) |s| allocator.free(s);

    if (fast_epvs != null) {
        const base_name = std.fs.path.stem(map_vpk_path);
        const train_path = try std.fmt.allocPrint(allocator, "{s}_train.bin", .{base_name});
        defer allocator.free(train_path);

        try stderr.print("[FastEPVS] Loading cached training data from {s}\n", .{train_path});
        var train_data = pvs_neural.TrainingData.load(allocator, train_path) catch |err| {
            try stderr.print("[FastEPVS] Failed to load training cache: {}\n", .{err});
            try stderr.print("[FastEPVS] Run baker without FAST_EPVS once to generate the cache.\n", .{});
            std.process.exit(1);
        };
        defer train_data.deinit();

        try stdout.print("  Loaded {d} samples, {d} models, {d}MB\n", .{
            train_data.num_samples, train_data.num_models,
            (train_data.num_samples * (12 + 24 + train_data.bitset_stride)) / (1024 * 1024),
        });

        // ── Exemplar selection ──
        const t_ex0 = std.time.nanoTimestamp();
        try stderr.print("[Exemplar] Building exemplar model...\n", .{});
        var epvs = try pvs_exemplar.selectExemplars(
            allocator,
            &train_data,
            train_data.world_min,
            train_data.world_max,
            .{
                .max_exemplars = 64000,
                .rbf_sigma = 0.5,
                .surprise_threshold = 0.05,
                .seed_count = 200,
            },
            stdout,
        );
        defer epvs.deinit();

        const t_ex1 = std.time.nanoTimestamp();
        try stdout.print("  Exemplar build: {d}ms\n", .{@divTrunc(t_ex1 - t_ex0, 1_000_000)});

        try pvs_exemplar.evaluate(&epvs, &train_data, 0.3, stdout);

        const epvs_path = try std.fmt.allocPrint(allocator, "{s}_epvs.bin", .{base_name});
        defer allocator.free(epvs_path);
        try epvs.save(epvs_path);
        try stdout.print("  → {s}\n", .{epvs_path});

        // ── MLP training (skippable via SKIP_MLP) ──
        const skip_mlp = std.process.getEnvVarOwned(allocator, "SKIP_MLP") catch null;
        defer if (skip_mlp) |s| allocator.free(s);

        if (skip_mlp == null) {
            try stderr.print("[FastEPVS] Training MLP from cached data...\n", .{});
            const t_mlp0 = std.time.nanoTimestamp();
            var mlp = try pvs_neural.train(
                allocator,
                &train_data,
                train_data.centroids,
                train_data.world_min,
                train_data.world_max,
                .{
                    .epochs = 30,
                    .learning_rate = 0.0005,
                    .batch_size = 32,
                    .hidden_size = 384,
                    .eval_threshold = 0.3,
                    .near_boost = 2.0,
                    .ref_dist = 5.0,
                },
                stdout,
            );
            defer mlp.deinit();

            const t_mlp1 = std.time.nanoTimestamp();
            try stdout.print("  MLP training: {d}ms\n", .{@divTrunc(t_mlp1 - t_mlp0, 1_000_000)});

            const npvs_path = try std.fmt.allocPrint(allocator, "{s}_npvs.bin", .{base_name});
            defer allocator.free(npvs_path);
            try mlp.save(npvs_path);
            try stdout.print("  → {s}\n", .{npvs_path});
        } else {
            try stderr.print("[FastEPVS] SKIP_MLP set — skipping MLP training\n", .{});
        }

        const t_total = std.time.nanoTimestamp();
        try stdout.print("\n  ═══ Total time: {d}ms ═══\n", .{@divTrunc(t_total - t0, 1_000_000)});
        return;
    }

    // ── Phase 1: Load geometry from VPK ──────────────────────────────

    var all_positions = std.ArrayList(Vec3).init(allocator);
    defer all_positions.deinit();
    var all_indices = std.ArrayList(u32).init(allocator);
    defer all_indices.deinit();

    // Track model triangle ranges for cluster→model mapping
    const ModelRange = struct {
        tri_start: u32,
        tri_end: u32,
        name: []const u8,
    };
    var model_ranges = std.ArrayList(ModelRange).init(allocator);
    defer {
        for (model_ranges.items) |mr| allocator.free(mr.name);
        model_ranges.deinit();
    }

    // Per-submesh ranges (one entry per draw call). The model_name field
    // borrows from the corresponding model_ranges entry's owned name buffer
    // — they have the same lifetime.
    var submesh_ranges = std.ArrayList(SubmeshRange).init(allocator);
    defer submesh_ranges.deinit();

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
    var proxy_count: u32 = 0;
    var it = map_pkg.iterateAll();
    while (it.next()) |entry| {
        if (!std.mem.eql(u8, entry.type_name, "vmdl_c")) continue;

        // Skip non-renderable proxy geometry (clip brushes, occluders, etc.)
        if (isProxyModel(entry.file_name)) {
            proxy_count += 1;
            continue;
        }

        const entry_data = map_pkg.readEntry(entry) catch continue;
        defer allocator.free(entry_data);

        // Allocate the name first so the sub-mesh ranges can borrow it.
        const name = allocator.dupe(u8, entry.file_name) catch continue;

        const tri_start = @as(u32, @intCast(all_indices.items.len / 3));
        extractModelGeometry(allocator, entry_data, &all_positions, &all_indices, &submesh_ranges, name) catch {
            allocator.free(name);
            failed_count += 1;
            continue;
        };
        const tri_end = @as(u32, @intCast(all_indices.items.len / 3));

        model_ranges.append(.{
            .tri_start = tri_start,
            .tri_end = tri_end,
            .name = name,
        }) catch {
            allocator.free(name);
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

            if (isProxyModel(entry.file_name)) {
                proxy_count += 1;
                continue;
            }

            const entry_data = cpkg.readEntry(entry) catch continue;
            defer allocator.free(entry_data);

            const name = allocator.dupe(u8, entry.file_name) catch continue;

            const tri_start = @as(u32, @intCast(all_indices.items.len / 3));
            extractModelGeometry(allocator, entry_data, &all_positions, &all_indices, &submesh_ranges, name) catch {
                allocator.free(name);
                failed_count += 1;
                continue;
            };
            const tri_end = @as(u32, @intCast(all_indices.items.len / 3));

            model_ranges.append(.{
                .tri_start = tri_start,
                .tri_end = tri_end,
                .name = name,
            }) catch {
                allocator.free(name);
                continue;
            };
            model_count += 1;
        }
    }
    if (proxy_count > 0) {
        try stderr.print("[Baker] Filtered {d} proxy models (clip brushes, occluders)\n", .{proxy_count});
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

    var mesh_set = try bivh_mod.TriangleMeshSet.fromArraysWithPerm(all_positions.items, all_indices.items, allocator);
    defer mesh_set.deinitPerm();
    var world_bivh = bivh_mod.Bivh.init(allocator);
    defer world_bivh.deinit();
    try world_bivh.build(&mesh_set);

    const t_bivh1 = std.time.nanoTimestamp();

    try stdout.print("  BIVH nodes:  {d}\n", .{world_bivh.node_count});
    try stdout.print("  BIVH leaves: {d}\n", .{world_bivh.leafCount()});
    try stdout.print("  BIVH depth:  {d}\n", .{world_bivh.tree_depth});
    try stdout.print("  Build time:  {d}ms\n", .{@divTrunc(t_bivh1 - t_bivh0, 1_000_000)});

    // ── BFS Walker Solve ─────────────────────────────────────────────
    //
    // Single-pass BFS walker: expand from each cell through spatial
    // neighbors, confirm connectivity with a few rays, walls block
    // expansion.  No epochs needed — systematic, not stochastic.

    const cluster_shift: u5 = 8;
    const cluster_size: u32 = @as(u32, 1) << cluster_shift;
    const cluster_count = (tri_count + cluster_size - 1) / cluster_size;

    const thread_count = @as(u32, @intCast(std.Thread.getCpuCount() catch 4));
    const root = world_bivh.nodes[0];
    const world_min = root.min;
    const world_max = root.max;
    const base_name = std.fs.path.stem(map_vpk_path);

    var trace_ctx = TraceContext{
        .bivh = &world_bivh,
        .mesh_set = &mesh_set,
    };

    // Ray trace benchmark
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

    // Build cluster BIVH
    try stdout.print("\n  Building cluster BIVH ({d} clusters of {d})...\n", .{ cluster_count, cluster_size });
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

    var cluster_mesh = try bivh_mod.TriangleMeshSet.fromArraysWithPerm(cluster_positions, cluster_indices_buf, allocator);
    defer cluster_mesh.deinitPerm();
    var cluster_bivh = bivh_mod.Bivh.init(allocator);
    defer cluster_bivh.deinit();
    try cluster_bivh.build(&cluster_mesh);

    const t_clust1 = std.time.nanoTimestamp();
    try stdout.print("  BIVH: {d} nodes, {d} leaves ({d}ms)\n", .{
        cluster_bivh.node_count, cluster_bivh.leafCount(), @divTrunc(t_clust1 - t_clust0, 1_000_000),
    });

    // Build cell info — use cluster BIVH perm to get original cluster IDs
    const cluster_perm = cluster_mesh.perm orelse return error.NoPerm;

    var cell_node_indices = std.ArrayList(u32).init(allocator);
    defer cell_node_indices.deinit();
    var cell_ranges_list = std.ArrayList(pvs_mod.CellRange).init(allocator);
    defer cell_ranges_list.deinit();
    var cell_centroids_list = std.ArrayList(Vec3).init(allocator);
    defer cell_centroids_list.deinit();
    var cell_mins_list = std.ArrayList([3]f32).init(allocator);
    defer cell_mins_list.deinit();
    var cell_maxs_list = std.ArrayList([3]f32).init(allocator);
    defer cell_maxs_list.deinit();
    // Per-cell: list of original cluster IDs (for model mapping)
    var cell_cluster_ids = std.ArrayList([]u32).init(allocator);
    defer {
        for (cell_cluster_ids.items) |ids| allocator.free(ids);
        cell_cluster_ids.deinit();
    }

    for (0..cluster_bivh.node_count) |i| {
        const node = cluster_bivh.nodes[i];
        if (!node.isLeaf()) continue;
        const first_sorted = @as(u32, @intCast(node.startPrim()));
        const last_sorted = @as(u32, @intCast(node.end_prim));

        // Translate sorted positions to original cluster IDs via perm
        const count = last_sorted - first_sorted + 1;
        const orig_ids = try allocator.alloc(u32, count);
        var min_orig_tri: u32 = std.math.maxInt(u32);
        var max_orig_tri: u32 = 0;
        for (0..count) |k| {
            const orig_cluster = cluster_perm[first_sorted + k];
            orig_ids[k] = orig_cluster;
            min_orig_tri = @min(min_orig_tri, orig_cluster * cluster_size);
            max_orig_tri = @max(max_orig_tri, @min((orig_cluster + 1) * cluster_size, tri_count));
        }

        try cell_node_indices.append(@intCast(i));
        try cell_ranges_list.append(.{
            .start_tri = min_orig_tri,
            .end_tri = max_orig_tri,
        });
        try cell_centroids_list.append(.{
            (node.min[0] + node.max[0]) * 0.5,
            (node.min[1] + node.max[1]) * 0.5,
            (node.min[2] + node.max[2]) * 0.5,
        });
        try cell_mins_list.append(node.min);
        try cell_maxs_list.append(node.max);
        try cell_cluster_ids.append(orig_ids);
    }

    const num_cells: u32 = @intCast(cell_ranges_list.items.len);
    try stdout.print("  Cells: {d}\n", .{num_cells});

    // ── Run BFS Walker ───────────────────────────────────────────────

    try stdout.print("\n  ╔═══════════════════════════════════╗\n", .{});
    try stdout.print("  ║  BFS Walker Solve                 ║\n", .{});
    try stdout.print("  ╚═══════════════════════════════════╝\n", .{});
    try stdout.print("  Threads: {d}, Rays/pair: 8\n", .{thread_count});

    var walker = try pvs_mod.WalkerSolver.init(
        allocator,
        all_positions.items,
        all_indices.items,
        cell_ranges_list.items,
        cell_centroids_list.items,
        cell_mins_list.items,
        cell_maxs_list.items,
        &traceWorld,
        @ptrCast(&trace_ctx),
        .{
            .thread_count = thread_count,
            .max_ray_distance = 2000.0,
            .max_depth = 50,
            .rays_per_pair = 8,
            .neighbor_gap = 2.0,
            .cluster_shift = cluster_shift,
            .progress_fn = &walkerProgress,
        },
    );
    defer walker.deinit();

    const t_solve0 = std.time.nanoTimestamp();
    try walker.solve();
    const t_solve1 = std.time.nanoTimestamp();

    const ws = walker.stats();
    try stdout.print("\n  ── Results ──\n", .{});
    try stdout.print("  Cells walked: {d}\n", .{ws.passes});
    try stdout.print("  Connections:  {d} per cell avg, min={d}, max={d}\n", .{ ws.avg_visible, ws.min_visible, ws.max_visible });
    try stdout.print("  Transport:    {d} rays cast, {d} edges connected\n", .{ ws.transport_casts, ws.transport_edges });
    try stdout.print("  Solve time:   {d}ms\n", .{@divTrunc(t_solve1 - t_solve0, 1_000_000)});

    // Visualization
    {
        const heatmap_path = try std.fmt.allocPrint(allocator, "{s}_transport.ppm", .{base_name});
        defer allocator.free(heatmap_path);
        try pvs_viz.writeTransportHeatmap(allocator, &walker.transport, cell_centroids_list.items, num_cells, world_min, world_max, heatmap_path);
        try stdout.print("  → {s}\n", .{heatmap_path});
    }

    // ── Probe Placement ────────────────────────────────────────────────

    {
        const pt = &walker.transport;
        const pcb = &cluster_bivh;
        const final_cell_indices = cell_node_indices.items;
        const final_num_cells = num_cells;

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
            try pvs_viz.writeIslandMap(allocator, &islands, probes, pcb, final_cell_indices, final_centroids, final_num_cells, world_min, world_max, island_path);
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
        const final_cluster_shift: u5 = cluster_shift;
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
            try pvs_viz.writeProbeAssignment(allocator, &assignment, cluster_centroids, final_cluster_count, probes, world_min, world_max, assign_path);
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
            try pvs_viz.writeLightingMap(allocator, cluster_light, cluster_centroids, final_cluster_count, probe_sh, probes, world_min, world_max, light_path);
            try stdout.print("  → {s}\n", .{light_path});
        }

        // ── Per-Cell Model Sets (direct, no cluster intermediary) ────
        try stdout.print("\n  ╔═══════════════════════════╗\n", .{});
        try stdout.print("  ║  Cell → Model Mapping     ║\n", .{});
        try stdout.print("  ╚═══════════════════════════╝\n", .{});
        const t_map0 = std.time.nanoTimestamp();

        const num_models: u32 = @intCast(model_ranges.items.len);
        const bitset_stride = (num_models + 7) / 8; // bytes per model bitset

        // Build reverse mapping: original_tri_idx → model_id
        const tri_to_model = try allocator.alloc(u32, tri_count);
        defer allocator.free(tri_to_model);
        @memset(tri_to_model, std.math.maxInt(u32));
        for (model_ranges.items, 0..) |mr, model_id| {
            for (mr.tri_start..mr.tri_end) |ti| {
                tri_to_model[ti] = @intCast(model_id);
            }
        }

        // For each cell, find which models have triangles in it
        const world_perm = mesh_set.perm orelse return error.NoPerm;
        const cell_model_bitsets = try allocator.alloc([]u8, final_num_cells);
        defer {
            for (cell_model_bitsets) |bs| allocator.free(bs);
            allocator.free(cell_model_bitsets);
        }

        for (0..final_num_cells) |ci| {
            const bs = try allocator.alloc(u8, bitset_stride);
            @memset(bs, 0);

            // Iterate original cluster IDs for this cell
            for (cell_cluster_ids.items[ci]) |orig_cluster| {
                const start_t = orig_cluster * cluster_size;
                const end_t = @min(start_t + cluster_size, tri_count);
                for (start_t..end_t) |sorted_idx| {
                    const original_idx = world_perm[sorted_idx];
                    const model_id = tri_to_model[original_idx];
                    if (model_id != std.math.maxInt(u32)) {
                        bs[model_id / 8] |= @as(u8, 1) << @intCast(model_id % 8);
                    }
                }
            }
            cell_model_bitsets[ci] = bs;
        }

        // Compute per-cell VISIBLE model bitsets (expand through transport graph)
        const vis_model_bitsets = try allocator.alloc([]u8, final_num_cells);
        defer {
            for (vis_model_bitsets) |bs| allocator.free(bs);
            allocator.free(vis_model_bitsets);
        }

        for (0..final_num_cells) |ci| {
            const bs = try allocator.alloc(u8, bitset_stride);
            // Start with own models
            @memcpy(bs, cell_model_bitsets[ci]);

            // OR in models from all connected cells
            for (0..final_num_cells) |cj| {
                if (ci == cj) continue;
                const edge = pt.getEdge(@intCast(ci), @intCast(cj));
                if (edge.hits.load(.monotonic) > 0) {
                    for (0..bitset_stride) |bi| {
                        bs[bi] |= cell_model_bitsets[cj][bi];
                    }
                }
            }
            vis_model_bitsets[ci] = bs;
        }

        // Stats
        {
            var min_vis: u32 = std.math.maxInt(u32);
            var max_vis: u32 = 0;
            var total_vis: u64 = 0;
            for (0..final_num_cells) |ci| {
                var count: u32 = 0;
                for (vis_model_bitsets[ci]) |byte| {
                    count += @popCount(byte);
                }
                min_vis = @min(min_vis, count);
                max_vis = @max(max_vis, count);
                total_vis += count;
            }
            try stdout.print("  Visible models/cell: min={d}, max={d}, avg={d}\n", .{
                min_vis, max_vis, @as(u32, @intCast(total_vis / final_num_cells)),
            });
        }

        const t_map1 = std.time.nanoTimestamp();
        try stdout.print("  Mapping time: {d}ms\n", .{@divTrunc(t_map1 - t_map0, 1_000_000)});

        // ── Write _pvs_runtime.bin (single output file) ─────────────
        {
            try stdout.print("\n  ╔═══════════════════════════╗\n", .{});
            try stdout.print("  ║  Writing Runtime Data     ║\n", .{});
            try stdout.print("  ╚═══════════════════════════╝\n", .{});

            const rt_path = try std.fmt.allocPrint(allocator, "{s}_pvs_runtime.bin", .{base_name});
            defer allocator.free(rt_path);
            var rtf = try std.fs.cwd().createFile(rt_path, .{});
            defer rtf.close();
            var rtw = std.io.bufferedWriter(rtf.writer());
            const rw = rtw.writer();

            // Header
            try rw.writeAll("PVR2");
            try rw.writeInt(u32, final_num_cells, .little);
            try rw.writeInt(u32, num_models, .little);
            try rw.writeInt(u32, @intCast(probes.len), .little);
            try rw.writeInt(u32, bitset_stride, .little);

            // Cell centroids (for nearest-centroid lookup at runtime)
            for (cell_centroids_list.items) |c| {
                for (c) |v| try rw.writeInt(u32, @bitCast(v), .little);
            }

            // Per-cell visible model bitsets
            for (vis_model_bitsets) |bs| {
                try rw.writeAll(bs);
            }

            // Probe data (positions + SH)
            for (probes, 0..) |probe, pi| {
                for (probe.position) |v| try rw.writeInt(u32, @bitCast(v), .little);
                for (probe_sh[pi].r) |v| try rw.writeInt(u32, @bitCast(v), .little);
                for (probe_sh[pi].g) |v| try rw.writeInt(u32, @bitCast(v), .little);
                for (probe_sh[pi].b) |v| try rw.writeInt(u32, @bitCast(v), .little);
            }

            try rtw.flush();
            try stdout.print("  → {s}\n", .{rt_path});
        }

        // Write _models.txt (for runtime name matching)
        {
            const mn_txt = try std.fmt.allocPrint(allocator, "{s}_models.txt", .{base_name});
            defer allocator.free(mn_txt);
            var mnf = try std.fs.cwd().createFile(mn_txt, .{});
            defer mnf.close();
            var mnw = std.io.bufferedWriter(mnf.writer());
            const mw = mnw.writer();
            try mw.print("# Model list: {d} models\n", .{num_models});
            try mw.writeAll("# Format: model_id tri_start tri_end name\n");
            for (model_ranges.items, 0..) |mr, mid| {
                try mw.print("{d} {d} {d} {s}\n", .{ mid, mr.tri_start, mr.tri_end, mr.name });
            }
            try mnw.flush();
            try stdout.print("  → {s}\n", .{mn_txt});
        }

        // Write probe_assign.bin (for GI — existing format)
        {
            const assign_bin = try std.fmt.allocPrint(allocator, "{s}_probe_assign.bin", .{base_name});
            defer allocator.free(assign_bin);
            var af = try std.fs.cwd().createFile(assign_bin, .{});
            defer af.close();
            var aw = std.io.bufferedWriter(af.writer());
            const aw2 = aw.writer();
            try aw2.writeAll("PASN");
            try aw2.writeInt(u32, final_cluster_count, .little);
            try aw2.writeInt(u32, @intCast(probes.len), .little);
            for (assignment.cluster_to_probe) |pid| {
                try aw2.writeInt(u32, pid, .little);
            }
            try aw.flush();
            try stdout.print("  → {s}\n", .{assign_bin});
        }

        // ── Phase: Neural PVS Training (frustum-integrated) ────────────
        {
            try stdout.print("\n  ╔═══════════════════════════╗\n", .{});
            try stdout.print("  ║  Neural PVS Training v2   ║\n", .{});
            try stdout.print("  ╚═══════════════════════════╝\n", .{});

            const t_neural0 = std.time.nanoTimestamp();

            stderr.print("[NPVS] Computing model centroids + MinBalls...\n", .{}) catch {};

            // Compute model centroids (for spatial loss weighting)
            const model_centroids = try allocator.alloc([3]f32, num_models);
            defer allocator.free(model_centroids);
            for (model_ranges.items, 0..) |mr, mi| {
                var cx: f64 = 0;
                var cy: f64 = 0;
                var cz: f64 = 0;
                var count: f64 = 0;
                for (mr.tri_start..mr.tri_end) |ti| {
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
                    model_centroids[mi] = .{
                        @floatCast(cx / count),
                        @floatCast(cy / count),
                        @floatCast(cz / count),
                    };
                } else {
                    model_centroids[mi] = .{ 0, 0, 0 };
                }
            }

            // (Used to write a _model_bounds.bin sidecar with MinBall spheres
            // per model. Removed: the baker's coordinate space didn't match the
            // runtime's instance transforms, so the spheres ended up in the wrong
            // place and frustum culling dropped half the geometry. The runtime
            // now computes spheres from its own AABBs at load time.)

            // Extract probe positions for surprise-distributed sampling
            const probe_pos_array = try allocator.alloc([3]f32, probes.len);
            defer allocator.free(probe_pos_array);
            for (probes, 0..) |probe, pi| probe_pos_array[pi] = probe.position;

            // OMNI_EPVS: omnidirectional sampling for the exemplar baker.
            // Each sample fires rays over the full sphere from a position and
            // stores ALL visible models — orientation is dropped entirely.
            // The exemplar baker selects in position-only space and the runtime
            // does standard frustum culling on top of the kNN result.
            const omni_epvs = std.process.getEnvVarOwned(allocator, "OMNI_EPVS") catch null;
            defer if (omni_epvs) |s| allocator.free(s);
            if (omni_epvs != null) {
                stderr.print("[NPVS] OMNI_EPVS set — omnidirectional sampling enabled\n", .{}) catch {};
            }

            // ── Per-submesh PVS units (omni mode only) ──
            // In omni mode we treat each submesh as its own PVS unit instead
            // of one bit per model. This fixes data quality for Source 2
            // aggregate models (e.g. asphalt agg_merge_*) that span the whole
            // map: a single per-model PVS bit for those is "always visible"
            // and carries no information. Per-submesh, each chunk gets its
            // own bit. Submeshes whose AABB exceeds the world-fraction
            // threshold are excluded from PVS entirely (still ray-traced for
            // occlusion, but always drawn at runtime — see drawCulled).
            var pvs_units_tri_to_unit: ?[]u32 = null;
            defer if (pvs_units_tri_to_unit) |slice| allocator.free(slice);
            var pvs_units_count: u32 = num_models;
            var pvs_units_centroids: ?[][3]f32 = null;
            defer if (pvs_units_centroids) |c| allocator.free(c);

            if (omni_epvs != null) {
                try buildSubmeshPvsUnits(
                    allocator,
                    submesh_ranges.items,
                    all_positions.items,
                    all_indices.items,
                    world_min,
                    world_max,
                    base_name,
                    tri_count,
                    &pvs_units_tri_to_unit,
                    &pvs_units_count,
                    &pvs_units_centroids,
                    stdout,
                );
            }

            const data_tri_to_unit: []const u32 = pvs_units_tri_to_unit orelse tri_to_model;
            const data_num_units: u32 = pvs_units_count;
            const data_centroids: []const Vec3 = if (pvs_units_centroids) |c| c else model_centroids;

            // Generate training data, seeded from GI probes
            stderr.print("[NPVS] Starting probe-seeded data generation...\n", .{}) catch {};
            var train_data = try pvs_neural.generateTrainingData(
                allocator,
                &world_bivh,
                &mesh_set,
                world_perm,
                data_tri_to_unit,
                data_num_units,
                world_min,
                world_max,
                .{
                    .num_samples = 20_000,
                    // Sphere covers ~6× the solid angle of a typical frustum,
                    // so bump rays per sample in omni mode to keep per-direction
                    // density similar.
                    .rays_per_sample = if (omni_epvs != null) @as(u32, 1024) else @as(u32, 256),
                    .max_ray_dist = 2000.0,
                    .omni_mode = omni_epvs != null,
                },
                probe_pos_array,
                stdout,
            );
            defer train_data.deinit();

            const t_data = std.time.nanoTimestamp();
            const data_gen_ms = @divTrunc(t_data - t_neural0, 1_000_000);
            try stdout.print("  Data gen: {d}ms\n", .{data_gen_ms});

            // Copy the per-PVS-unit centroids into the training data so the
            // cache file is self-contained — FAST_EPVS can then re-run BOTH
            // exemplar selection AND MLP training without re-loading geometry.
            if (train_data.centroids.len == data_centroids.len) {
                @memcpy(train_data.centroids, data_centroids);
            }

            // Save training data cache for fast iteration (FAST_EPVS path)
            {
                const train_path = try std.fmt.allocPrint(allocator, "{s}_train.bin", .{base_name});
                defer allocator.free(train_path);
                try train_data.save(train_path);
                try stdout.print("  → {s} (training cache)\n", .{train_path});
            }

            // Skip MLP training when SKIP_MLP env var is set (faster iteration on exemplars).
            // In OMNI_EPVS mode the MLP still trains, just with all-zero orientation
            // dimensions in the input (those weights will train to zero) and a much
            // larger output layer (one neuron per PVS unit / sub-mesh instead of one
            // per model). Worth seeing what the MLP learns from the richer signal.
            const skip_mlp = std.process.getEnvVarOwned(allocator, "SKIP_MLP") catch null;
            defer if (skip_mlp) |s| allocator.free(s);

            if (skip_mlp == null) {
                stderr.print("[NPVS] Data gen: {d}ms, starting training...\n", .{data_gen_ms}) catch {};

                // Train MLP with distance-weighted loss (position-only input).
                var mlp = try pvs_neural.train(
                    allocator,
                    &train_data,
                    data_centroids,
                    world_min,
                    world_max,
                    .{
                        .epochs = 30,
                        .learning_rate = 0.0005,
                        .batch_size = 32,
                        .hidden_size = 384,
                        .eval_threshold = 0.3,
                        .near_boost = 2.0,
                        .ref_dist = 5.0,
                    },
                    stdout,
                );
                defer mlp.deinit();

                const t_train = std.time.nanoTimestamp();
                try stdout.print("  Training: {d}ms\n", .{@divTrunc(t_train - t_data, 1_000_000)});

                // Save weights
                const npvs_path = try std.fmt.allocPrint(allocator, "{s}_npvs.bin", .{base_name});
                defer allocator.free(npvs_path);
                try mlp.save(npvs_path);
                try stdout.print("  → {s}\n", .{npvs_path});
                stderr.print("[NPVS] Done! Saved to {s}\n", .{npvs_path}) catch {};
            } else {
                stderr.print("[NPVS] SKIP_MLP set — skipping MLP training\n", .{}) catch {};
            }

            // ── Exemplar PVS (alternative model) ──
            stderr.print("[Exemplar] Building exemplar model...\n", .{}) catch {};
            const t_exemplar0 = std.time.nanoTimestamp();
            var epvs = try pvs_exemplar.selectExemplars(
                allocator,
                &train_data,
                world_min,
                world_max,
                .{
                    .max_exemplars = 64000,
                    .rbf_sigma = 0.5,
                    .surprise_threshold = 0.05,
                    .seed_count = 200,
                },
                stdout,
            );
            defer epvs.deinit();

            const t_exemplar1 = std.time.nanoTimestamp();
            try stdout.print("  Exemplar build: {d}ms\n", .{@divTrunc(t_exemplar1 - t_exemplar0, 1_000_000)});

            // Evaluate
            try pvs_exemplar.evaluate(&epvs, &train_data, 0.3, stdout);

            const epvs_path = try std.fmt.allocPrint(allocator, "{s}_epvs.bin", .{base_name});
            defer allocator.free(epvs_path);
            try epvs.save(epvs_path);
            try stdout.print("  → {s}\n", .{epvs_path});
            stderr.print("[Exemplar] Done! Saved to {s}\n", .{epvs_path}) catch {};
        }
    }

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

fn walkerProgress(cells_done: u32, total_cells: u32, connections: u64) void {
    std.debug.print("  Walker: {d}/{d} cells, {d} connections\n", .{ cells_done, total_cells, connections });
}

// ── Geometry extraction ─────────────────────────────────────────────

/// Per-submesh geometry range. Populated by `extractModelGeometry` when an
/// output list is provided. Each entry maps a contiguous slice of the global
/// triangle array back to its source (model name + submesh index inside that
/// model). Used for sub-mesh-granularity PVS so aggregate world geometry
/// doesn't all share one PVS bit.
pub const SubmeshRange = struct {
    tri_start: u32,
    tri_end: u32,
    model_name: []const u8, // borrowed (lives as long as the caller's name buffer)
    submesh_idx: u32,
};

fn extractModelGeometry(
    allocator: Allocator,
    data: []const u8,
    positions: *std.ArrayList(Vec3),
    indices: *std.ArrayList(u32),
    submesh_ranges: ?*std.ArrayList(SubmeshRange),
    model_name: []const u8,
) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var resource = Resource.init(arena);
    defer resource.deinit();
    resource.resource_type = .model;
    resource.read(data) catch return error.ParseFailed;

    // Helper: record one sub-mesh boundary, given the tri count before/after.
    const Helper = struct {
        fn record(
            list: ?*std.ArrayList(SubmeshRange),
            mname: []const u8,
            sidx: *u32,
            tri_before: u32,
            tri_after: u32,
        ) void {
            if (tri_after <= tri_before) return;
            if (list) |l| {
                l.append(.{
                    .tri_start = tri_before,
                    .tri_end = tri_after,
                    .model_name = mname,
                    .submesh_idx = sidx.*,
                }) catch {};
            }
            sidx.* += 1;
        }
    };
    var submesh_idx: u32 = 0;

    // Try legacy VBIB/MBUF first
    for (resource.blocks.items) |blk| {
        if (blk.block_type == .vbib or blk.block_type == .mbuf) {
            if (blk.size > 0) {
                const block_bytes = data[blk.offset..][0..blk.size];
                var vbib = vrf.VBIB.readFromBinaryBlock(arena, block_bytes) catch return error.ParseFailed;
                defer vbib.deinit();
                if (vbib.vertex_buffers.len > 0 and vbib.index_buffers.len > 0) {
                    const tri_before: u32 = @intCast(indices.items.len / 3);
                    try appendVbibGeometry(allocator, &vbib, positions, indices, null);
                    const tri_after: u32 = @intCast(indices.items.len / 3);
                    Helper.record(submesh_ranges, model_name, &submesh_idx, tri_before, tri_after);
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
                                        const tri_before: u32 = @intCast(indices.items.len / 3);
                                        appendVbibGeometry(allocator, &vbib, positions, indices, dc_info) catch continue;
                                        const tri_after: u32 = @intCast(indices.items.len / 3);
                                        Helper.record(submesh_ranges, model_name, &submesh_idx, tri_before, tri_after);
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
    {
        const tri_before: u32 = @intCast(indices.items.len / 3);
        try appendVbibGeometry(allocator, &vbib, positions, indices, null);
        const tri_after: u32 = @intCast(indices.items.len / 3);
        Helper.record(submesh_ranges, model_name, &submesh_idx, tri_before, tri_after);
    }
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

/// Build per-submesh PVS units, apply the oversize-skip filter, and write
/// the `_pvs_submeshes.bin` sidecar that the runtime needs to map each
/// (model, submesh) pair to its PVS bit.
///
/// Inputs:
///   submesh_ranges — one entry per (model, submesh) tagged with tri range
///   positions/indices — global geometry arrays
///   world_min/max — for the size threshold
///   base_name — for the sidecar filename
///   tri_count — total triangles (size of the output tri_to_unit array)
///
/// Outputs:
///   *out_tri_to_unit — allocated u32 slice of length tri_count, mapping
///                      original triangle index → PVS unit ID. Triangles
///                      from skipped submeshes get sentinel (max u32).
///   *out_num_units — number of PVS bits actually assigned
fn buildSubmeshPvsUnits(
    allocator: Allocator,
    submesh_ranges: []const SubmeshRange,
    positions: []const Vec3,
    indices: []const u32,
    world_min: Vec3,
    world_max: Vec3,
    base_name: []const u8,
    tri_count: u32,
    out_tri_to_unit: *?[]u32,
    out_num_units: *u32,
    out_centroids: *?[][3]f32,
    stdout: anytype,
) !void {
    const stderr = std.io.getStdErr().writer();

    // Threshold for "oversized" submesh: any submesh whose AABB diagonal
    // exceeds this fraction of the world diagonal is skipped from PVS.
    // Default 0.25 catches the worst aggregate offenders without losing
    // legitimate large props. Override via SUBMESH_MAX_FRACTION env var.
    var max_fraction: f32 = 0.25;
    if (std.process.getEnvVarOwned(allocator, "SUBMESH_MAX_FRACTION") catch null) |s| {
        defer allocator.free(s);
        if (std.fmt.parseFloat(f32, s)) |v| max_fraction = v else |_| {}
    }

    const world_dx = world_max[0] - world_min[0];
    const world_dy = world_max[1] - world_min[1];
    const world_dz = world_max[2] - world_min[2];
    const world_diag = @sqrt(world_dx * world_dx + world_dy * world_dy + world_dz * world_dz);
    const max_diag = world_diag * max_fraction;

    try stdout.print("\n  ╔═══════════════════════════════╗\n", .{});
    try stdout.print("  ║  Per-Submesh PVS Units        ║\n", .{});
    try stdout.print("  ╚═══════════════════════════════╝\n", .{});
    try stdout.print("  Total submeshes:    {d}\n", .{submesh_ranges.len});
    try stdout.print("  Skip threshold:     {d:.2}× world diag = {d:.1}m\n", .{ max_fraction, max_diag });

    // Compute per-submesh AABBs and decide skip/keep.
    const SubmeshInfo = struct {
        aabb_min: [3]f32,
        aabb_max: [3]f32,
        diag: f32,
        skipped: bool,
        pvs_id: u32, // sentinel = max u32 if skipped
    };
    const infos = try allocator.alloc(SubmeshInfo, submesh_ranges.len);
    defer allocator.free(infos);

    var skipped_count: u32 = 0;
    var assigned: u32 = 0;
    for (submesh_ranges, 0..) |sr, si| {
        var lo = [3]f32{ std.math.floatMax(f32), std.math.floatMax(f32), std.math.floatMax(f32) };
        var hi = [3]f32{ -std.math.floatMax(f32), -std.math.floatMax(f32), -std.math.floatMax(f32) };
        for (sr.tri_start..sr.tri_end) |ti| {
            const base = ti * 3;
            for (0..3) |vi| {
                const v = positions[indices[base + vi]];
                if (v[0] < lo[0]) lo[0] = v[0];
                if (v[1] < lo[1]) lo[1] = v[1];
                if (v[2] < lo[2]) lo[2] = v[2];
                if (v[0] > hi[0]) hi[0] = v[0];
                if (v[1] > hi[1]) hi[1] = v[1];
                if (v[2] > hi[2]) hi[2] = v[2];
            }
        }
        const dx = hi[0] - lo[0];
        const dy = hi[1] - lo[1];
        const dz = hi[2] - lo[2];
        const diag = @sqrt(dx * dx + dy * dy + dz * dz);
        const skipped = diag > max_diag;
        infos[si] = .{
            .aabb_min = lo,
            .aabb_max = hi,
            .diag = diag,
            .skipped = skipped,
            .pvs_id = if (skipped) std.math.maxInt(u32) else blk: {
                const id = assigned;
                assigned += 1;
                break :blk id;
            },
        };
        if (skipped) skipped_count += 1;
    }

    try stdout.print("  Skipped (oversized): {d}\n", .{skipped_count});
    try stdout.print("  PVS units assigned:  {d}\n", .{assigned});

    // Print the largest skipped offenders so we can verify the threshold.
    if (skipped_count > 0) {
        try stdout.print("  Largest skipped:\n", .{});
        // Find top-5 by diagonal
        const top_n: usize = @min(5, submesh_ranges.len);
        var top_idx: [5]usize = .{ 0, 0, 0, 0, 0 };
        var top_diag: [5]f32 = .{ 0, 0, 0, 0, 0 };
        var top_filled: usize = 0;
        for (infos, 0..) |info, si| {
            if (!info.skipped) continue;
            if (top_filled < top_n) {
                top_idx[top_filled] = si;
                top_diag[top_filled] = info.diag;
                top_filled += 1;
            } else {
                // Find smallest in top, replace if bigger
                var min_i: usize = 0;
                for (1..top_n) |k| if (top_diag[k] < top_diag[min_i]) {
                    min_i = k;
                };
                if (info.diag > top_diag[min_i]) {
                    top_idx[min_i] = si;
                    top_diag[min_i] = info.diag;
                }
            }
        }
        // Sort top descending
        for (0..top_filled) |i| {
            for (i + 1..top_filled) |j| {
                if (top_diag[j] > top_diag[i]) {
                    std.mem.swap(usize, &top_idx[i], &top_idx[j]);
                    std.mem.swap(f32, &top_diag[i], &top_diag[j]);
                }
            }
        }
        for (0..top_filled) |i| {
            const si = top_idx[i];
            const sr = submesh_ranges[si];
            try stdout.print("    {d:6.1}m  [submesh {d}/{s}]\n", .{
                top_diag[i], sr.submesh_idx, sr.model_name,
            });
        }
    }

    // Build the tri→unit mapping. Skipped submeshes get the sentinel.
    const tri_to_unit = try allocator.alloc(u32, tri_count);
    @memset(tri_to_unit, std.math.maxInt(u32));
    for (submesh_ranges, infos) |sr, info| {
        const id = info.pvs_id;
        for (sr.tri_start..sr.tri_end) |ti| {
            tri_to_unit[ti] = id;
        }
    }

    // Write the sidecar: per-(model,submesh) → pvs_id (or sentinel).
    // Format: PVSM v1
    //   magic "PVSM"
    //   version u32
    //   num_units u32
    //   num_models u32
    //   For each model: u16 name_len, u8[name_len] name, u32 num_submeshes,
    //                   u32[num_submeshes] pvs_id (sentinel = max u32 if skipped)
    {
        const sidecar_path = try std.fmt.allocPrint(allocator, "{s}_pvs_submeshes.bin", .{base_name});
        defer allocator.free(sidecar_path);
        var f = try std.fs.cwd().createFile(sidecar_path, .{});
        defer f.close();
        var bw = std.io.bufferedWriter(f.writer());
        const w = bw.writer();

        try w.writeAll("PVSM");
        try w.writeInt(u32, 1, .little);
        try w.writeInt(u32, assigned, .little);

        // Group submeshes by model. Submeshes for one model are contiguous in
        // submesh_ranges (we build them in order during phase 1) and share the
        // same model_name pointer, so we can just walk and break on changes.
        var num_models_in_sidecar: u32 = 0;
        var i: usize = 0;
        while (i < submesh_ranges.len) {
            num_models_in_sidecar += 1;
            const name = submesh_ranges[i].model_name;
            i += 1;
            while (i < submesh_ranges.len and std.mem.eql(u8, submesh_ranges[i].model_name, name)) : (i += 1) {}
        }
        try w.writeInt(u32, num_models_in_sidecar, .little);

        i = 0;
        while (i < submesh_ranges.len) {
            const start = i;
            const name = submesh_ranges[start].model_name;
            i += 1;
            while (i < submesh_ranges.len and std.mem.eql(u8, submesh_ranges[i].model_name, name)) : (i += 1) {}
            const num_sub: u32 = @intCast(i - start);
            try w.writeInt(u16, @intCast(name.len), .little);
            try w.writeAll(name);
            try w.writeInt(u32, num_sub, .little);
            for (start..i) |j| {
                try w.writeInt(u32, infos[j].pvs_id, .little);
            }
        }

        try bw.flush();
        try stdout.print("  → {s} ({d} models, {d} units)\n", .{ sidecar_path, num_models_in_sidecar, assigned });
    }

    // Build per-PVS-unit centroids (AABB midpoints) for the MLP's spatial
    // loss weighting. Skipped sub-meshes don't get a centroid since they
    // have no PVS bit. The MLP needs one centroid per output neuron.
    const centroids = try allocator.alloc([3]f32, assigned);
    for (submesh_ranges, infos) |sr, info| {
        _ = sr;
        if (info.skipped) continue;
        centroids[info.pvs_id] = .{
            (info.aabb_min[0] + info.aabb_max[0]) * 0.5,
            (info.aabb_min[1] + info.aabb_max[1]) * 0.5,
            (info.aabb_min[2] + info.aabb_max[2]) * 0.5,
        };
    }

    out_tri_to_unit.* = tri_to_unit;
    out_num_units.* = assigned;
    out_centroids.* = centroids;
    stderr.print("[Submesh PVS] {d} units, {d} skipped\n", .{ assigned, skipped_count }) catch {};
}

/// Check if a model name indicates non-renderable proxy geometry.
fn isProxyModel(name: []const u8) bool {
    const filters = [_][]const u8{
        "_occluder",      "_proxy",     "_shadow",
        "_clip",          "_cb_",       "_mesh_overlay",
        "occluder",       "shadowproxy", "navmesh",
        "_lod0_noao",
    };
    for (filters) |f| {
        if (std.mem.indexOf(u8, name, f) != null) return true;
    }
    return false;
}

// (Visualization functions moved to pvs_viz.zig)
