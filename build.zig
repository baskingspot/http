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

    // The bench suite runs ReleaseFast, but an imported module keeps its own
    // optimize mode. Build bench-specific copies so the suite does not call
    // Debug parser code. `testingx.addBench` builds its own suite module at
    // ReleaseFast; these are the imports it reaches.
    const bench_optimize: std.builtin.OptimizeMode = .ReleaseFast;
    const bench_stdx = b.dependency("stdx", .{ .target = target, .optimize = bench_optimize });
    const bench_mod = b.addModule("http-bench", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = bench_optimize,
        .imports = &.{.{ .name = "stdx", .module = bench_stdx.module("stdx") }},
    });

    // testingx provides the test runner and the bench engine. It is lazy
    // because only the root build uses it; a consumer never fetches it. On the
    // first configure pass it is not fetched yet, `lazyDependency` returns
    // null, and the build runner fetches it and reruns this script.
    const testingx_dep = b.lazyDependency("testingx", .{ .target = target });
    // The reference parser for the benchmark comparison. Dev-only and lazy:
    // it never enters a consumer's fetch path.
    const hparse_dep = b.lazyDependency(
        "hparse",
        .{ .target = target, .optimize = bench_optimize },
    );
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

    // The example is a real program, not a test. `check-example` builds it in
    // CI; `example` runs it. It is developer-only, like the bench.
    const example_mod = b.createModule(.{
        .root_source_file = b.path("examples/http1_server.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "http", .module = mod }},
    });
    const example = b.addExecutable(.{
        .name = "http1-server",
        .root_module = example_mod,
    });
    b.step("example-bin", "Build the HTTP/1.1 example server")
        .dependOn(&example.step);

    const run_example = b.addRunArtifact(example);
    if (b.args) |args| run_example.addArgs(args);
    b.step("example", "Run the HTTP/1.1 example server")
        .dependOn(&run_example.step);

    // The io_uring example is Linux-only. The steps exist everywhere so
    // `check-example` is portable; only Linux gets a target to build.
    const uring_bin = b.step("example-uring-bin", "Build the HTTP/1.1 io_uring example");
    const uring_run = b.step("example-uring", "Run the HTTP/1.1 io_uring example");
    if (target.result.os.tag == .linux) {
        const uring_mod = b.createModule(.{
            .root_source_file = b.path("examples/http1_uring.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "http", .module = mod }},
        });
        const uring = b.addExecutable(.{
            .name = "http1-uring",
            .root_module = uring_mod,
        });
        uring_bin.dependOn(&uring.step);

        const run_uring = b.addRunArtifact(uring);
        if (b.args) |args| run_uring.addArgs(args);
        uring_run.dependOn(&run_uring.step);
    }

    if (b.lazyImport(@This(), "testingx")) |testingx| {
        const dep = testingx_dep orelse unreachable;
        // hparse is fetched by the same lazy pass. If it is still null, the
        // build runner fetches it and reruns this script, then adds the step.
        if (hparse_dep) |hparse| {
            const run_bench = testingx.addBench(b, .{
                .module = dep.module("testingx"),
                .root_source_file = b.path("bench/bench.zig"),
                .imports = &.{
                    .{ .name = "http", .module = bench_mod },
                    .{ .name = "hparse", .module = hparse.module("hparse") },
                },
                .target = target,
            });
            if (b.args) |args| run_bench.addArgs(args);

            b.step("bench", "Run benchmarks").dependOn(&run_bench.step);
        }
    }
}
