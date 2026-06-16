const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The library module, importable by consumers as `@import("projectdetect")`.
    // Zero third-party dependencies (the config loader ships a minimal YAML
    // parser); matches the gitmeta-zig convention.
    const mod = b.addModule("projectdetect", .{
        .root_source_file = b.path("src/projectdetect.zig"),
        .target = target,
        .optimize = optimize,
    });

    // `zig build test` — compiles and runs every `test {}` block reachable
    // from the module root (projectdetect.zig pulls in the test files).
    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_mod_tests.step);

    // `zig build example [-- <path>...]` — runnable demo of the API.
    const example = b.addExecutable(.{
        .name = "projectdetect-example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/usage.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "projectdetect", .module = mod }},
        }),
    });
    const run_example = b.addRunArtifact(example);
    if (b.args) |args| run_example.addArgs(args);
    const example_step = b.step("example", "Run the usage example");
    example_step.dependOn(&run_example.step);
}
