# http: Pure HTTP field-value parsers: content negotiation, ranges, entity tags, dates, and media types. `just --list` shows the recipes.
# AGENTS.md holds the working conventions.

[private]
default:
    @just --list

[doc("Unit tests, through the testingx runner")]
[group("test")]
test:
    zig build test --summary all

[doc("Regenerate the HPACK interop fixture from golang.org/x/net/http2/hpack")]
[group("test")]
fixture:
    cd tools/hpack-interop && go run . > ../../tests/hpack-interop.txtar.tmp
    mv tests/hpack-interop.txtar.tmp tests/hpack-interop.txtar

[doc("Run the fuzzer with an iteration budget, for example `just fuzz 50M`. Uses the built-in test runner, which testingx does not replace in fuzz mode. ReleaseSafe forces the LLVM backend, dodging the 0.16.0 self-hosted-backend bug in Debug fuzz mode (ziglang/zig#30655)")]
[group("test")]
fuzz LIMIT="10M":
    zig build fuzz -Doptimize=ReleaseSafe --fuzz={{ LIMIT }}

[doc("Run benchmarks (ReleaseFast by default); args pass to the binary: just bench --benchtime=250ms --filter=Negotiate")]
[group("bench")]
bench *ARGS:
    zig build bench -- {{ ARGS }}

[doc("Run every benchmark once: proves the suite builds and runs, without measuring")]
[group("bench")]
bench-smoke:
    zig build bench -- --benchtime=8x --count=1 --no-env

[doc("Run h2spec against the example on 127.0.0.1:8081 (start `just example-h2` first); args select sections, e.g. `just conformance http2/5.1`")]
[group("test")]
conformance *ARGS:
    h2spec -h 127.0.0.1 -p 8081 {{ ARGS }}

[doc("Build and run the h2c example, run h2spec, then stop it; port 8081 must be free")]
[group("test")]
conformance-run *ARGS:
    #!/usr/bin/env bash
    set -euo pipefail
    zig build example-h2-bin
    bin=$(find .zig-cache -type f -name http2-server -printf '%T@ %p\n' | sort -nr | head -n1 | cut -d' ' -f2-)
    "$bin" >/tmp/http2-conformance.log 2>&1 &
    server_pid=$!
    trap 'kill "$server_pid" 2>/dev/null || true' EXIT
    ready=0
    for _ in $(seq 1 50); do
        if (exec 3<>/dev/tcp/127.0.0.1/8081) 2>/dev/null; then
            exec 3>&-
            ready=1
            break
        fi
        sleep 0.1
    done
    if [ "$ready" -ne 1 ]; then
        echo "http2-server did not start on 127.0.0.1:8081" >&2
        exit 1
    fi
    h2spec -h 127.0.0.1 -p 8081 {{ ARGS }}

[doc("Run h2load against the example on 127.0.0.1:8081 (start `just example-h2` first)")]
[group("test")]
load *ARGS:
    h2load -n 100 -c 1 -m 10 http://127.0.0.1:8081/ {{ ARGS }}

[doc("Lint Zig, Nix, Markdown, the workflows, and this justfile: ziglint-0-16, the ast-grep house rules, zig fmt, nix fmt, oxfmt, actionlint, zizmor, and just --fmt")]
[group("lint")]
lint:
    ziglint-0-16
    baskingspot-lint src
    zig fmt --check src tests bench examples build.zig build.zig.zon
    nix fmt -- --ci
    oxfmt --check README.md AGENTS.md .github
    actionlint
    zizmor .
    just --fmt --check

[doc("Format everything lint checks")]
[group("lint")]
fmt:
    zig fmt src tests bench examples build.zig build.zig.zon
    nix fmt
    oxfmt README.md AGENTS.md .github
    just --fmt

[doc("Run the HTTP/1.1 example server on 127.0.0.1:8080")]
[group("example")]
example:
    zig build example

[doc("Run the HTTP/1.1 poll example server (Linux only)")]
[group("example")]
example-poll:
    zig build example-poll

[doc("Run the HTTP/1.1 epoll example server (Linux only)")]
[group("example")]
example-epoll:
    zig build example-epoll

[doc("Run the HTTP/1.1 io_uring example (Linux only)")]
[group("example")]
example-uring:
    zig build example-uring

[doc("Run the primitive HTTP/2 h2c example server on 127.0.0.1:8081")]
[group("example")]
example-h2:
    zig build example-h2

[doc("Build the HTTP/1.1 and HTTP/2 examples without running them")]
[group("example")]
check-example:
    zig build example-bin
    zig build example-poll-bin
    zig build example-epoll-bin
    zig build example-uring-bin
    zig build example-h2-bin

[doc("Everything CI runs")]
[group("ci")]
ci: test lint check-example
