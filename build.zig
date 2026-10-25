const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // stdx is first-party and part of the module: its `fmt.atoi` is the
    // integer parser here, and consumers resolve it through this import.
    const stdx = b.dependency("stdx", .{ .target = target, .optimize = optimize });

    // The only exported module. Everything below is developer-only: returning
    // early for a consumer keeps testingx and the bench graph out of its fetch
    // path.
    const mod = b.addModule("http", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "stdx", .module = stdx.module("stdx") }},
    });

    if (b.pkg_hash.len != 0) return;

    // testingx provides the test runner and the bench engine. It is lazy
    // because only the root build uses it; a consumer never fetches it. On the
    // first configure pass it is not fetched yet, `lazyDependency` returns
    // null, and the build runner fetches it and reruns this script.
    const testingx_dep = b.lazyDependency("testingx", .{ .target = target });
    const test_runner: ?std.Build.Step.Compile.TestRunner = if (testingx_dep) |dep|
        .{ .path = dep.path("src/runner.zig"), .mode = .simple }
    else
        null;

    const tests = b.addTest(.{
        .root_module = mod,
        .test_runner = test_runner,
    });
    const run_tests = b.addRunArtifact(tests);
    run_tests.addArg(b.fmt("--seed=0x{x}", .{b.graph.random_seed}));
    if (b.args) |args| run_tests.addArgs(args);

    const test_step = b.step("test", "Run the unit tests");
    test_step.dependOn(&run_tests.step);

    // Fuzzing needs the built-in runner: testingx's main rejects fuzz mode
    // because the fuzzer speaks a private protocol. `just fuzz` drives this.
    const fuzz_tests = b.addTest(.{ .root_module = mod });
    const run_fuzz_tests = b.addRunArtifact(fuzz_tests);
    run_fuzz_tests.has_side_effects = true;
    b.step("fuzz", "Fuzz the parsers (built-in test runner)")
        .dependOn(&run_fuzz_tests.step);

    if (b.lazyImport(@This(), "testingx")) |testingx| {
        const dep = testingx_dep orelse unreachable;
        const run_bench = testingx.addBench(b, .{
            .module = dep.module("testingx"),
            .root_source_file = b.path("bench/bench.zig"),
            .imports = &.{.{ .name = "http", .module = mod }},
            .target = target,
        });
        if (b.args) |args| run_bench.addArgs(args);

        b.step("bench", "Run benchmarks").dependOn(&run_bench.step);
    }
}
