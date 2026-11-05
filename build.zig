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

    // TLS is a separate module: importing it must not put libcrypto in an
    // h2c-only build. Consumers that terminate TLS import `http_tls`.
    const tls_dep = b.dependency("tls", .{
        .target = target,
        .optimize = optimize,
    });
    const http_tls_mod = b.addModule("http_tls", .{
        .root_source_file = b.path("src/http_tls.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "http", .module = mod },
            .{ .name = "tls", .module = tls_dep.module("tls") },
            .{ .name = "tls_nonblocking", .module = tls_dep.module("tls_nonblocking") },
        },
    });
    http_tls_mod.link_libc = true;
    http_tls_mod.linkSystemLibrary("crypto", .{});

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

    // The interop fixture reads a txtar archive with testingx at compile time,
    // so it is a second test artifact with its own module. `http` itself never
    // imports testingx, and `tests/` is outside the package tarball.
    if (testingx_dep) |dep| {
        const interop_mod = b.addModule("http-interop-tests", .{
            .root_source_file = b.path("tests/hpack_interop.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "http", .module = mod },
                .{ .name = "testingx", .module = dep.module("testingx") },
            },
        });
        const interop_tests = b.addTest(.{
            .root_module = interop_mod,
            .test_runner = test_runner,
        });
        const run_interop = b.addRunArtifact(interop_tests);
        run_interop.addArg(b.fmt("--seed=0x{x}", .{b.graph.random_seed}));
        if (b.args) |args| run_interop.addArgs(args);
        test_step.dependOn(&run_interop.step);
    }

    // The picohttpparser case table. It lives outside the package for the same
    // reason as the interop fixture: it imports `http` and is not shipped.
    const corpus_mod = b.createModule(.{
        .root_source_file = b.path("tests/h1_corpus.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "http", .module = mod }},
    });
    const corpus_tests = b.addTest(.{
        .root_module = corpus_mod,
        .test_runner = test_runner,
    });
    const run_corpus = b.addRunArtifact(corpus_tests);
    run_corpus.addArg(b.fmt("--seed=0x{x}", .{b.graph.random_seed}));
    if (b.args) |args| run_corpus.addArgs(args);
    test_step.dependOn(&run_corpus.step);

    // The blocking engine over real loopback sockets. The tests live outside
    // the package like the corpus and the interop fixture.
    const engine_tests_mod = b.createModule(.{
        .root_source_file = b.path("tests/engine_http1.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "http", .module = mod }},
    });
    const engine_tests = b.addTest(.{
        .root_module = engine_tests_mod,
        .test_runner = test_runner,
    });
    const run_engine_tests = b.addRunArtifact(engine_tests);
    run_engine_tests.addArg(b.fmt("--seed=0x{x}", .{b.graph.random_seed}));
    if (b.args) |args| run_engine_tests.addArgs(args);
    test_step.dependOn(&run_engine_tests.step);

    // The blocking HTTP/2 engine over a real loopback socket.
    const h2_engine_tests_mod = b.createModule(.{
        .root_source_file = b.path("tests/engine_h2.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "http", .module = mod }},
    });
    const h2_engine_tests = b.addTest(.{
        .root_module = h2_engine_tests_mod,
        .test_runner = test_runner,
    });
    const run_h2_engine_tests = b.addRunArtifact(h2_engine_tests);
    run_h2_engine_tests.addArg(b.fmt("--seed=0x{x}", .{b.graph.random_seed}));
    if (b.args) |args| run_h2_engine_tests.addArgs(args);
    test_step.dependOn(&run_h2_engine_tests.step);

    // The readiness HTTP/2 engine runs the same socket test on poll, epoll,
    // and kqueue. It is Linux and macOS only.
    if (target.result.os.tag == .linux or target.result.os.tag == .macos) {
        const readiness_options = b.addOptions();
        readiness_options.addOption(bool, "epoll", false);
        const readiness_tests_mod = b.createModule(.{
            .root_source_file = b.path("tests/engine_h2_readiness.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "http", .module = mod },
                .{ .name = "engine_options", .module = readiness_options.createModule() },
            },
        });
        const readiness_tests = b.addTest(.{
            .root_module = readiness_tests_mod,
            .test_runner = test_runner,
        });
        const run_readiness_tests = b.addRunArtifact(readiness_tests);
        run_readiness_tests.addArg(b.fmt("--seed=0x{x}", .{b.graph.random_seed}));
        if (b.args) |args| run_readiness_tests.addArgs(args);
        test_step.dependOn(&run_readiness_tests.step);

        if (target.result.os.tag == .linux) {
            const epoll_options = b.addOptions();
            epoll_options.addOption(bool, "epoll", true);
            const epoll_tests_mod = b.createModule(.{
                .root_source_file = b.path("tests/engine_h2_readiness.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "http", .module = mod },
                    .{ .name = "engine_options", .module = epoll_options.createModule() },
                },
            });
            const epoll_tests = b.addTest(.{
                .root_module = epoll_tests_mod,
                .test_runner = test_runner,
            });
            const run_epoll_tests = b.addRunArtifact(epoll_tests);
            run_epoll_tests.addArg(b.fmt("--seed=0x{x}", .{b.graph.random_seed}));
            if (b.args) |args| run_epoll_tests.addArgs(args);
            test_step.dependOn(&run_epoll_tests.step);
        }
    }

    // The readiness engines run the same integration suite. Linux builds the
    // poll and epoll artifacts; macOS builds the kqueue artifact.
    if (target.result.os.tag == .linux) {
        const poll_options = b.addOptions();
        poll_options.addOption(bool, "epoll", false);
        poll_options.addOption(bool, "kqueue", false);
        const poll_tests_mod = b.createModule(.{
            .root_source_file = b.path("tests/engine_poll.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "http", .module = mod },
                .{ .name = "engine_options", .module = poll_options.createModule() },
            },
        });
        const poll_tests = b.addTest(.{
            .root_module = poll_tests_mod,
            .test_runner = test_runner,
        });
        const run_poll_tests = b.addRunArtifact(poll_tests);
        run_poll_tests.addArg(b.fmt("--seed=0x{x}", .{b.graph.random_seed}));
        if (b.args) |args| run_poll_tests.addArgs(args);
        test_step.dependOn(&run_poll_tests.step);

        const epoll_options = b.addOptions();
        epoll_options.addOption(bool, "epoll", true);
        epoll_options.addOption(bool, "kqueue", false);
        const epoll_tests_mod = b.createModule(.{
            .root_source_file = b.path("tests/engine_poll.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "http", .module = mod },
                .{ .name = "engine_options", .module = epoll_options.createModule() },
            },
        });
        const epoll_tests = b.addTest(.{
            .root_module = epoll_tests_mod,
            .test_runner = test_runner,
        });
        const run_epoll_tests = b.addRunArtifact(epoll_tests);
        run_epoll_tests.addArg(b.fmt("--seed=0x{x}", .{b.graph.random_seed}));
        if (b.args) |args| run_epoll_tests.addArgs(args);
        test_step.dependOn(&run_epoll_tests.step);
    }

    // kqueue is the readiness backend on macOS. The same integration suite
    // runs there with the Linux-only tests skipped.
    if (target.result.os.tag == .macos) {
        const kqueue_options = b.addOptions();
        kqueue_options.addOption(bool, "epoll", false);
        kqueue_options.addOption(bool, "kqueue", true);
        const kqueue_tests_mod = b.createModule(.{
            .root_source_file = b.path("tests/engine_poll.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "http", .module = mod },
                .{ .name = "engine_options", .module = kqueue_options.createModule() },
            },
        });
        const kqueue_tests = b.addTest(.{
            .root_module = kqueue_tests_mod,
            .test_runner = test_runner,
        });
        const run_kqueue_tests = b.addRunArtifact(kqueue_tests);
        run_kqueue_tests.addArg(b.fmt("--seed=0x{x}", .{b.graph.random_seed}));
        if (b.args) |args| run_kqueue_tests.addArgs(args);
        test_step.dependOn(&run_kqueue_tests.step);
    }

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

    // The HTTP/1 client example is driven by the Go interop recipe.
    const interop_client_mod = b.createModule(.{
        .root_source_file = b.path("examples/http1_client.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "http", .module = mod }},
    });
    const interop_client = b.addExecutable(.{
        .name = "http1-client",
        .root_module = interop_client_mod,
    });
    b.step("interop-client-bin", "Build the HTTP/1 client interop example")
        .dependOn(&interop_client.step);

    const run_interop_client = b.addRunArtifact(interop_client);
    if (b.args) |args| run_interop_client.addArgs(args);
    b.step("interop-client", "Run the HTTP/1 client against the Go interop server")
        .dependOn(&run_interop_client.step);

    // The h2c example: the frame codec and HPACK over blocking sockets.
    const h2_example_mod = b.createModule(.{
        .root_source_file = b.path("examples/http2_server.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "http", .module = mod }},
    });
    const h2_example = b.addExecutable(.{
        .name = "http2-server",
        .root_module = h2_example_mod,
    });
    b.step("example-h2-bin", "Build the HTTP/2 h2c example server")
        .dependOn(&h2_example.step);

    const run_h2_example = b.addRunArtifact(h2_example);
    if (b.args) |args| run_h2_example.addArgs(args);
    b.step("example-h2", "Run the HTTP/2 h2c example server")
        .dependOn(&run_h2_example.step);

    // The readiness h2c example is Linux and macOS only. The steps exist
    // everywhere so `check-example` is portable; only the supported systems get
    // a target to build.
    const h2_readiness_example_bin = b.step(
        "example-h2-readiness-bin",
        "Build the HTTP/2 readiness example server",
    );
    const h2_readiness_example_run = b.step(
        "example-h2-readiness",
        "Run the HTTP/2 readiness example server",
    );
    if (target.result.os.tag == .linux or target.result.os.tag == .macos) {
        const h2_readiness_mod = b.createModule(.{
            .root_source_file = b.path("examples/http2_readiness.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "http", .module = mod }},
        });
        const h2_readiness = b.addExecutable(.{
            .name = "http2-readiness",
            .root_module = h2_readiness_mod,
        });
        h2_readiness_example_bin.dependOn(&h2_readiness.step);

        const run_h2_readiness = b.addRunArtifact(h2_readiness);
        if (b.args) |args| run_h2_readiness.addArgs(args);
        h2_readiness_example_run.dependOn(&run_h2_readiness.step);
    }

    // The TLS readiness example is Linux and macOS only. It uses the separate
    // `http_tls` module, so the h2c core never links libcrypto.
    const h2_tls_readiness_example_bin = b.step(
        "example-h2-tls-readiness-bin",
        "Build the HTTP/2 TLS readiness example server",
    );
    const h2_tls_readiness_example_run = b.step(
        "example-h2-tls-readiness",
        "Run the HTTP/2 TLS readiness example server",
    );
    if (target.result.os.tag == .linux or target.result.os.tag == .macos) {
        const h2_tls_readiness_mod = b.createModule(.{
            .root_source_file = b.path("examples/http2_tls_readiness.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "http", .module = mod },
                .{ .name = "http_tls", .module = http_tls_mod },
                .{ .name = "tls", .module = tls_dep.module("tls") },
            },
        });
        h2_tls_readiness_mod.link_libc = true;
        h2_tls_readiness_mod.linkSystemLibrary("crypto", .{});
        const h2_tls_readiness = b.addExecutable(.{
            .name = "http2-tls-readiness",
            .root_module = h2_tls_readiness_mod,
        });
        h2_tls_readiness_example_bin.dependOn(&h2_tls_readiness.step);

        const run_h2_tls_readiness = b.addRunArtifact(h2_tls_readiness);
        if (b.args) |args| run_h2_tls_readiness.addArgs(args);
        h2_tls_readiness_example_run.dependOn(&run_h2_tls_readiness.step);
    }

    // The TLS h2 example is Linux and macOS only. It imports tls and the
    // blocking tls_std integration from baskingspot/tls.
    const h2_tls_example_bin = b.step(
        "example-h2-tls-bin",
        "Build the HTTP/2 TLS example server",
    );
    const h2_tls_example_run = b.step(
        "example-h2-tls",
        "Run the HTTP/2 TLS example server",
    );
    if (target.result.os.tag == .linux or target.result.os.tag == .macos) {
        const h2_tls_mod = b.createModule(.{
            .root_source_file = b.path("examples/http2_tls.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "http", .module = mod },
                .{ .name = "tls", .module = tls_dep.module("tls") },
                .{ .name = "tls_std", .module = tls_dep.module("tls_std") },
            },
        });
        h2_tls_mod.link_libc = true;
        h2_tls_mod.linkSystemLibrary("crypto", .{});
        const h2_tls = b.addExecutable(.{
            .name = "http2-tls",
            .root_module = h2_tls_mod,
        });
        h2_tls_example_bin.dependOn(&h2_tls.step);

        const run_h2_tls = b.addRunArtifact(h2_tls);
        if (b.args) |args| run_h2_tls.addArgs(args);
        h2_tls_example_run.dependOn(&run_h2_tls.step);
    }

    // The HTTP/1 TLS examples use the blocking tls_std integration from
    // baskingspot/tls. Both are Linux and macOS only.
    const h1_tls_example_bin = b.step(
        "example-h1-tls-bin",
        "Build the HTTP/1.1 TLS example server",
    );
    const h1_tls_example_run = b.step(
        "example-h1-tls",
        "Run the HTTP/1.1 TLS example server",
    );
    const h1_tls_client_bin = b.step(
        "example-h1-tls-client-bin",
        "Build the HTTP/1.1 TLS example client",
    );
    const h1_tls_client_run = b.step(
        "example-h1-tls-client",
        "Run the HTTP/1.1 TLS example client",
    );
    if (target.result.os.tag == .linux or target.result.os.tag == .macos) {
        const h1_tls_mod = b.createModule(.{
            .root_source_file = b.path("examples/http1_tls.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "http", .module = mod },
                .{ .name = "tls", .module = tls_dep.module("tls") },
                .{ .name = "tls_std", .module = tls_dep.module("tls_std") },
            },
        });
        h1_tls_mod.link_libc = true;
        h1_tls_mod.linkSystemLibrary("crypto", .{});
        const h1_tls = b.addExecutable(.{
            .name = "http1-tls",
            .root_module = h1_tls_mod,
        });
        h1_tls_example_bin.dependOn(&h1_tls.step);

        const run_h1_tls = b.addRunArtifact(h1_tls);
        if (b.args) |args| run_h1_tls.addArgs(args);
        h1_tls_example_run.dependOn(&run_h1_tls.step);

        const h1_tls_client_mod = b.createModule(.{
            .root_source_file = b.path("examples/http1_tls_client.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "http", .module = mod },
                .{ .name = "tls_std", .module = tls_dep.module("tls_std") },
            },
        });
        h1_tls_client_mod.link_libc = true;
        h1_tls_client_mod.linkSystemLibrary("crypto", .{});
        const h1_tls_client = b.addExecutable(.{
            .name = "http1-tls-client",
            .root_module = h1_tls_client_mod,
        });
        h1_tls_client_bin.dependOn(&h1_tls_client.step);

        const run_h1_tls_client = b.addRunArtifact(h1_tls_client);
        if (b.args) |args| run_h1_tls_client.addArgs(args);
        h1_tls_client_run.dependOn(&run_h1_tls_client.step);
    }

    // One TLS port serving h1 and h2 by ALPN.
    const unified_example_bin = b.step(
        "example-unified-bin",
        "Build the HTTP/1.1 and HTTP/2 TLS example server",
    );
    const unified_example_run = b.step(
        "example-unified",
        "Run the HTTP/1.1 and HTTP/2 TLS example server",
    );
    if (target.result.os.tag == .linux or target.result.os.tag == .macos) {
        const unified_mod = b.createModule(.{
            .root_source_file = b.path("examples/http_unified_server.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "http", .module = mod },
                .{ .name = "tls", .module = tls_dep.module("tls") },
                .{ .name = "tls_std", .module = tls_dep.module("tls_std") },
            },
        });
        unified_mod.link_libc = true;
        unified_mod.linkSystemLibrary("crypto", .{});
        const unified = b.addExecutable(.{
            .name = "http-unified-server",
            .root_module = unified_mod,
        });
        unified_example_bin.dependOn(&unified.step);

        const run_unified = b.addRunArtifact(unified);
        if (b.args) |args| run_unified.addArgs(args);
        unified_example_run.dependOn(&run_unified.step);
    }

    // The tiny curl example. HTTPS uses the same tls_std wrapper as the h1 TLS
    // examples; the HTTP layer still sees only reader and writer interfaces.
    const curl_example_bin = b.step("example-curl-bin", "Build the HTTP/1.1 curl example");
    const curl_example_run = b.step("example-curl", "Run the HTTP/1.1 curl example");
    if (target.result.os.tag == .linux or target.result.os.tag == .macos) {
        const curl_mod = b.createModule(.{
            .root_source_file = b.path("examples/curl.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "http", .module = mod },
                .{ .name = "tls_std", .module = tls_dep.module("tls_std") },
            },
        });
        curl_mod.link_libc = true;
        curl_mod.linkSystemLibrary("crypto", .{});
        const curl = b.addExecutable(.{
            .name = "http1-curl",
            .root_module = curl_mod,
        });
        curl_example_bin.dependOn(&curl.step);

        const run_curl = b.addRunArtifact(curl);
        if (b.args) |args| run_curl.addArgs(args);
        curl_example_run.dependOn(&run_curl.step);
    }

    // The poll example is Linux-only for now. The steps exist everywhere so
    // `check-example` is portable; only Linux gets a target to build.
    const poll_example_bin = b.step("example-poll-bin", "Build the HTTP/1.1 poll example server");
    const poll_example_run = b.step("example-poll", "Run the HTTP/1.1 poll example server");
    if (target.result.os.tag == .linux) {
        const poll_mod = b.createModule(.{
            .root_source_file = b.path("examples/http1_poll.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "http", .module = mod }},
        });
        const poll = b.addExecutable(.{
            .name = "http1-poll",
            .root_module = poll_mod,
        });
        poll_example_bin.dependOn(&poll.step);

        const run_poll = b.addRunArtifact(poll);
        if (b.args) |args| run_poll.addArgs(args);
        poll_example_run.dependOn(&run_poll.step);
    }

    // The epoll example is Linux-only. The steps exist everywhere so
    // `check-example` is portable; only Linux gets a target to build.
    const epoll_example_bin = b.step(
        "example-epoll-bin",
        "Build the HTTP/1.1 epoll example server",
    );
    const epoll_example_run = b.step(
        "example-epoll",
        "Run the HTTP/1.1 epoll example server",
    );
    if (target.result.os.tag == .linux) {
        const epoll_mod = b.createModule(.{
            .root_source_file = b.path("examples/http1_epoll.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "http", .module = mod }},
        });
        const epoll = b.addExecutable(.{
            .name = "http1-epoll",
            .root_module = epoll_mod,
        });
        epoll_example_bin.dependOn(&epoll.step);

        const run_epoll = b.addRunArtifact(epoll);
        if (b.args) |args| run_epoll.addArgs(args);
        epoll_example_run.dependOn(&run_epoll.step);
    }

    // The kqueue example is macOS-only. The steps exist everywhere so
    // `check-example` is portable; only macOS gets a target to build.
    const kqueue_example_bin = b.step(
        "example-kqueue-bin",
        "Build the HTTP/1.1 kqueue example server",
    );
    const kqueue_example_run = b.step(
        "example-kqueue",
        "Run the HTTP/1.1 kqueue example server",
    );
    if (target.result.os.tag == .macos) {
        const kqueue_mod = b.createModule(.{
            .root_source_file = b.path("examples/http1_kqueue.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "http", .module = mod }},
        });
        const kqueue = b.addExecutable(.{
            .name = "http1-kqueue",
            .root_module = kqueue_mod,
        });
        kqueue_example_bin.dependOn(&kqueue.step);

        const run_kqueue = b.addRunArtifact(kqueue);
        if (b.args) |args| run_kqueue.addArgs(args);
        kqueue_example_run.dependOn(&run_kqueue.step);
    }

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
