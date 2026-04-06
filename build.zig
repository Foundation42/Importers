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
}
