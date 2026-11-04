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

[doc("Run the HTTP/1.1 io_uring example (Linux only)")]
[group("example")]
example-uring:
    zig build example-uring

[doc("Build the HTTP/1.1 examples without running them")]
[group("example")]
check-example:
    zig build example-bin
    zig build example-poll-bin
    zig build example-uring-bin

[doc("Everything CI runs")]
[group("ci")]
ci: test lint check-example
