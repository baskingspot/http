# http: HTTP/1.1 and HTTP/2 in Zig: field-value parsers, sans-I/O connection machines, and the engines you build a server or client on. `just --list` shows the recipes.
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
    zig build example-h2 >/tmp/http2-conformance.log 2>&1 &
    build_pid=$!
    trap 'pkill -x http2-server 2>/dev/null || true; kill "$build_pid" 2>/dev/null || true' EXIT
    ready=0
    for _ in {1..50}; do
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

[doc("Build and run the poll example, run h2spec, then stop it; port 8081 must be free")]
[group("test")]
conformance-run-readiness *ARGS:
    #!/usr/bin/env bash
    set -euo pipefail
    zig build example-h2-readiness >/tmp/http2-readiness-conformance.log 2>&1 &
    build_pid=$!
    trap 'pkill -x http2-readiness 2>/dev/null || true; kill "$build_pid" 2>/dev/null || true' EXIT
    ready=0
    for _ in {1..50}; do
        if (exec 3<>/dev/tcp/127.0.0.1/8081) 2>/dev/null; then
            exec 3>&-
            ready=1
            break
        fi
        sleep 0.1
    done
    if [ "$ready" -ne 1 ]; then
        echo "http2-readiness did not start on 127.0.0.1:8081" >&2
        exit 1
    fi
    h2spec -h 127.0.0.1 -p 8081 {{ ARGS }}

[doc("Build and run the TLS example, run h2spec, then stop it; port 8443 must be free")]
[group("test")]
conformance-run-tls *ARGS:
    #!/usr/bin/env bash
    set -euo pipefail
    zig build example-h2-tls >/tmp/http2-tls-conformance.log 2>&1 &
    build_pid=$!
    trap 'pkill -x http2-tls 2>/dev/null || true; kill "$build_pid" 2>/dev/null || true' EXIT
    ready=0
    for _ in {1..50}; do
        if (exec 3<>/dev/tcp/127.0.0.1/8443) 2>/dev/null; then
            exec 3>&-
            ready=1
            break
        fi
        sleep 0.1
    done
    if [ "$ready" -ne 1 ]; then
        echo "http2-tls did not start on 127.0.0.1:8443" >&2
        exit 1
    fi
    h2spec -t -k -h 127.0.0.1 -p 8443 {{ ARGS }}

[doc("Build and run the TLS readiness example, run h2spec, then stop it; port 8443 must be free")]
[group("test")]
conformance-run-tls-readiness *ARGS:
    #!/usr/bin/env bash
    set -euo pipefail
    zig build example-h2-tls-readiness >/tmp/http2-tls-readiness-conformance.log 2>&1 &
    build_pid=$!
    trap 'pkill -P "$build_pid" 2>/dev/null || true; pkill -x http2-tls-readi 2>/dev/null || true; pkill -f "\\.zig-cache/.*/http2-tls-readiness$" 2>/dev/null || true; kill "$build_pid" 2>/dev/null || true' EXIT
    ready=0
    for _ in {1..50}; do
        if (exec 3<>/dev/tcp/127.0.0.1/8443) 2>/dev/null; then
            exec 3>&-
            ready=1
            break
        fi
        sleep 0.1
    done
    if [ "$ready" -ne 1 ]; then
        echo "http2-tls-readiness did not start on 127.0.0.1:8443" >&2
        exit 1
    fi
    h2spec -t -k -h 127.0.0.1 -p 8443 {{ ARGS }}

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
    oxfmt --check .oxfmtrc.jsonc README.md AGENTS.md docs/content docs/config.toml .github
    actionlint
    zizmor .
    test -z "$(gofmt -l tools)"
    just --fmt --check

[doc("Format everything lint checks")]
[group("lint")]
fmt:
    zig fmt src tests bench examples build.zig build.zig.zon
    nix fmt
    oxfmt .oxfmtrc.jsonc README.md AGENTS.md docs/content docs/config.toml .github
    just --fmt

[doc("Build the site into zig-out/site/http/: the guide (Zola, from docs/) and the API reference (docgen JSON, rendered by the theme's api.html) under api/. The router in baskingspot/site serves /http/... from it")]
[group("docs")]
doc: api
    baskingspot-docs build http

[doc("Edit the guide with live reload (http://127.0.0.1:1111), API reference included")]
[group("docs")]
guide: api
    baskingspot-docs serve http

# The API reference data. docgen comes from the baskingspot flake's docs shell,
# so this is not a Zig build dependency.
[private]
api:
    docgen --root src/root.zig --title http --repo-url https://github.com/baskingspot/http --rev main --format json --out docs/data

[doc("Deploy the rendered docs to Cloudflare as an assets-only Worker (config in wrangler.jsonc). Needs CLOUDFLARE_API_TOKEN in the environment, plus CLOUDFLARE_ACCOUNT_ID if the token can see more than one account")]
[group("docs")]
doc-deploy: doc
    wrangler deploy

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

[doc("Run the HTTP/1.1 kqueue example server (macOS only)")]
[group("example")]
example-kqueue:
    zig build example-kqueue

[doc("Run the HTTP/1.1 io_uring example (Linux only)")]
[group("example")]
example-uring:
    zig build example-uring

[doc("Run the primitive HTTP/2 h2c example server on 127.0.0.1:8081")]
[group("example")]
example-h2:
    zig build example-h2

[doc("Run the readiness (poll/kqueue) HTTP/2 h2c example server on 127.0.0.1:8081")]
[group("example")]
example-h2-readiness:
    zig build example-h2-readiness

[doc("Run the HTTP/2 TLS example server on 127.0.0.1:8443")]
[group("example")]
example-h2-tls:
    zig build example-h2-tls

[doc("Run the readiness HTTP/2 TLS example server on 127.0.0.1:8443")]
[group("example")]
example-h2-tls-readiness:
    zig build example-h2-tls-readiness

[doc("Build the HTTP/1.1 and HTTP/2 examples without running them")]
[group("example")]
check-example:
    zig build example-bin
    zig build example-sse-bin
    zig build example-stream-bin
    zig build example-poll-bin
    zig build example-epoll-bin
    zig build example-kqueue-bin
    zig build example-uring-bin
    zig build example-h2-bin
    zig build example-h2-readiness-bin
    zig build example-h2-tls-bin
    zig build example-h2-tls-readiness-bin
    zig build example-h1-tls-bin
    zig build example-h1-tls-client-bin
    zig build example-unified-bin
    zig build example-curl-bin
    zig build interop-client-bin

[doc("Run the HTTP/1 client against a Go net/http server")]
[group("test")]
interop:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p .zig-cache
    go build -C tools/http1-interop -o "$PWD/.zig-cache/http1-interop" .
    .zig-cache/http1-interop >/tmp/http1-interop.log 2>&1 &
    server_pid=$!
    trap 'kill "$server_pid" 2>/dev/null || true' EXIT
    for _ in {1..50}; do
        if curl -fsS http://127.0.0.1:8091/ >/dev/null 2>&1; then
            break
        fi
        sleep 0.1
    done
    zig build interop-client

[doc("Run the tiny curl example: just curl [--http2] <url>")]
[group("example")]
curl *ARGS:
    zig build example-curl -- {{ ARGS }}

[doc("Run TLS 8445 and cleartext 8082, both serving HTTP/1.1 and HTTP/2")]
[group("example")]
example-unified:
    zig build example-unified

[doc("Run the pull-based SSE example on 127.0.0.1:8090")]
[group("example")]
example-sse:
    zig build example-sse

[doc("Run the poll-engine SSE example on 127.0.0.1:8092")]
[group("example")]
example-sse-poll:
    zig build example-sse-poll

[doc("Run the pull-based file transform example: just example-stream README.md")]
[group("example")]
example-stream *ARGS:
    zig build example-stream -- {{ ARGS }}

[doc("Run the HTTP/1.1 TLS example server on 127.0.0.1:8444")]
[group("example")]
example-h1-tls:
    zig build example-h1-tls

[doc("Run the HTTP/1.1 TLS example client against 127.0.0.1:8444")]
[group("example")]
example-h1-tls-client:
    zig build example-h1-tls-client

[doc("Run the HTTP/1.1 TLS client against the TLS example server")]
[group("test")]
interop-tls:
    #!/usr/bin/env bash
    set -euo pipefail
    zig build example-h1-tls >/tmp/http1-tls.log 2>&1 &
    server_pid=$!
    trap 'pkill -P "$server_pid" 2>/dev/null || true; pkill -x http1-tls 2>/dev/null || true; pkill -f "\\.zig-cache/.*/http1-tls$" 2>/dev/null || true; kill "$server_pid" 2>/dev/null || true' EXIT
    ready=0
    for _ in {1..300}; do
        if curl -kfsS https://127.0.0.1:8444/ >/dev/null 2>&1; then
            ready=1
            break
        fi
        sleep 0.2
    done
    if [ "$ready" -ne 1 ]; then
        cat /tmp/http1-tls.log >&2 || true
        exit 1
    fi
    zig build example-h1-tls-client

[doc("Build and start the readiness example, run h2spec strict, and stop it")]
[group("test")]
conformance-ci:
    just conformance-run-readiness -S -o 2
    just conformance-run-tls -S -o 2
    just conformance-run-tls-readiness -S -o 2

[doc("Everything CI runs")]
[group("ci")]
ci: test lint interop interop-tls check-example conformance-ci doc
