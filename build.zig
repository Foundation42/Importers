const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Main library module
    const vrf_mod = b.addModule("valve-resource-format", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Library artifact (static)
    const lib = b.addStaticLibrary(.{
        .name = "valve-resource-format",
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(lib);

    // Tests
    const tests = b.addTest(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    // Example / CLI tool
    const exe = b.addExecutable(.{
        .name = "vrf-tool",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("valve-resource-format", vrf_mod);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the VRF tool");
    run_step.dependOn(&run_cmd.step);

    // Example: extract_mesh
    const example = b.addExecutable(.{
        .name = "extract-mesh",
        .root_source_file = b.path("examples/extract_mesh.zig"),
        .target = target,
        .optimize = optimize,
    });
    example.root_module.addImport("valve-resource-format", vrf_mod);
    b.installArtifact(example);

    const run_example = b.addRunArtifact(example);
    run_example.step.dependOn(b.getInstallStep());

    const example_step = b.step("example", "Run the mesh extraction example");
    example_step.dependOn(&run_example.step);

    // Example: load_q3bsp
    const q3bsp_example = b.addExecutable(.{
        .name = "load-q3bsp",
        .root_source_file = b.path("examples/load_q3bsp.zig"),
        .target = target,
        .optimize = optimize,
    });
    q3bsp_example.root_module.addImport("valve-resource-format", vrf_mod);
    b.installArtifact(q3bsp_example);

    const run_q3bsp = b.addRunArtifact(q3bsp_example);
    run_q3bsp.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_q3bsp.addArgs(args);
    }

    const q3bsp_step = b.step("q3bsp", "Run the Q3 BSP loader example");
    q3bsp_step.dependOn(&run_q3bsp.step);

    // Example: test_tga
    const tga_example = b.addExecutable(.{
        .name = "test-tga",
        .root_source_file = b.path("examples/test_tga.zig"),
        .target = target,
        .optimize = optimize,
    });
    tga_example.root_module.addImport("valve-resource-format", vrf_mod);
    b.installArtifact(tga_example);

    const run_tga = b.addRunArtifact(tga_example);
    run_tga.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_tga.addArgs(args);
    }

    const tga_step = b.step("test-tga", "Test TGA decoder against PK3 textures");
    tga_step.dependOn(&run_tga.step);

    // Tool: list-vpk
    const list_vpk = b.addExecutable(.{
        .name = "list-vpk",
        .root_source_file = b.path("src/list_vpk.zig"),
        .target = target,
        .optimize = optimize,
    });
    list_vpk.root_module.addImport("valve-resource-format", vrf_mod);
    b.installArtifact(list_vpk);

    const run_list_vpk = b.addRunArtifact(list_vpk);
    run_list_vpk.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_list_vpk.addArgs(args);
    }

    const list_vpk_step = b.step("list-vpk", "List contents of a VPK archive");
    list_vpk_step.dependOn(&run_list_vpk.step);

    // Tool: verify-vpk
    const verify_vpk = b.addExecutable(.{
        .name = "verify-vpk",
        .root_source_file = b.path("src/verify_vpk.zig"),
        .target = target,
        .optimize = optimize,
    });
    verify_vpk.root_module.addImport("valve-resource-format", vrf_mod);
    b.installArtifact(verify_vpk);

    // Tool: dump-world
    const dump_world = b.addExecutable(.{
        .name = "dump-world",
        .root_source_file = b.path("src/dump_world.zig"),
        .target = target,
        .optimize = optimize,
    });
    dump_world.root_module.addImport("valve-resource-format", vrf_mod);
    b.installArtifact(dump_world);

    // Modules: BIVH + PVS (used by pvs-baker, available to importers of this package)
    // Always ReleaseFast — the baker is compute-heavy.
    const bivh_mod = b.addModule("bivh", .{
        .root_source_file = b.path("src/bivh.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });

    const pvs_module = b.addModule("pvs", .{
        .root_source_file = b.path("src/pvs.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });

    // Tool: pvs-baker — PVS solver for Source 2 maps (no Raylib)
    const pvs_baker = b.addExecutable(.{
        .name = "pvs-baker",
        .root_source_file = b.path("src/pvs_baker.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    const vrf_fast = b.addModule("valve-resource-format-fast", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    const pvs_viz_module = b.addModule("pvs_viz", .{
        .root_source_file = b.path("src/pvs_viz.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    pvs_viz_module.addImport("pvs", pvs_module);
    pvs_viz_module.addImport("bivh", bivh_mod);

    const pvs_neural_module = b.addModule("pvs_neural", .{
        .root_source_file = b.path("src/pvs_neural.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    pvs_neural_module.addImport("bivh", bivh_mod);

    const minball_module = b.addModule("minball", .{
        .root_source_file = b.path("src/minball.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });

    const pvs_exemplar_module = b.addModule("pvs_exemplar", .{
        .root_source_file = b.path("src/pvs_exemplar.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });

    pvs_baker.root_module.addImport("valve-resource-format", vrf_fast);
    pvs_baker.root_module.addImport("bivh", bivh_mod);
    pvs_baker.root_module.addImport("pvs", pvs_module);
    pvs_baker.root_module.addImport("pvs_viz", pvs_viz_module);
    pvs_baker.root_module.addImport("pvs_neural", pvs_neural_module);
    pvs_baker.root_module.addImport("pvs_exemplar", pvs_exemplar_module);
    pvs_baker.root_module.addImport("minball", minball_module);
    b.installArtifact(pvs_baker);

    const pvs_run = b.addRunArtifact(pvs_baker);
    pvs_run.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        pvs_run.addArgs(args);
    }
    const pvs_step = b.step("pvs-baker", "Run PVS baker on a Source 2 map");
    pvs_step.dependOn(&pvs_run.step);
}
