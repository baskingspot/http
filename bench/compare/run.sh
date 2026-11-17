#!/usr/bin/env bash
# Client comparison: baskingspot/http, Go net/http, and reqwest against one
# Go reference server. Loopback, keep-alive, a 13-byte body, no compression.
#
#   N=20000 CONC=1 RUNS=3 just bench-compare
#
# Raw CSV goes to $OUT (scenario,client,requests,ns,run); the summary is
# printed as scenario,client,mean_rps,best_rps,runs.
set -euo pipefail
cd "$(dirname "$0")/../.."

N=${N:-20000}
CONC=${CONC:-1}
RUNS=${RUNS:-3}
OUT=${OUT:-/tmp/bench-compare.csv}

echo "building" >&2
zig build compare-client-bin -Doptimize=ReleaseFast
go build -o zig-out/bin/bench-server bench/compare/server.go
go build -o zig-out/bin/bench-go bench/compare/go_client.go
( cd bench/compare/reqwest && cargo build --release )
cp bench/compare/reqwest/target/release/reqwest-bench zig-out/bin/bench-reqwest

server_pid=
cleanup() {
    if [ -n "$server_pid" ]; then kill "$server_pid" 2>/dev/null || true; fi
}
trap cleanup EXIT

start_server() {
    local port=$1
    shift
    zig-out/bin/bench-server -addr "127.0.0.1:$port" "$@" >/tmp/bench-server."$port".log 2>&1 &
    server_pid=$!
    for _ in $(seq 100); do
        if curl -sk --max-time 1 "https://127.0.0.1:$port/" >/dev/null 2>&1 ||
            curl -s --max-time 1 "http://127.0.0.1:$port/" >/dev/null 2>&1; then
            return 0
        fi
        sleep 0.05
    done
    echo "server on $port did not come up" >&2
    exit 1
}

stop_server() {
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
    server_pid=
}

run_client() {
    local client=$1 url=$2 mode=$3
    case "$client" in
    zig) zig-out/bin/bench-client "$url" "$N" "$CONC" "$mode" ;;
    go)
        if [ "$mode" = h2 ]; then
            zig-out/bin/bench-go -url "$url" -n "$N" -conc "$CONC" -h2
        else
            zig-out/bin/bench-go -url "$url" -n "$N" -conc "$CONC"
        fi
        ;;
    reqwest) zig-out/bin/bench-reqwest "$url" "$N" "$CONC" "$mode" ;;
    esac
}

: >"$OUT"
scenario() {
    local name=$1 url=$2 port=$3 mode=$4
    shift 4
    start_server "$port" "$@"
    for client in zig go reqwest; do run_client "$client" "$url" "$mode" >/dev/null; done
    for run in $(seq "$RUNS"); do
        for client in zig go reqwest; do
            read -r _ requests ns <<<"$(run_client "$client" "$url" "$mode")"
            echo "$name,$client,$requests,$ns,$run" >>"$OUT"
        done
    done
    stop_server
}

scenario h1-clear http://127.0.0.1:9000/ 9000 h1
scenario h1-tls https://127.0.0.1:9443/ 9443 h1 -tls -alpn h1
scenario h2-tls https://127.0.0.1:9444/ 9444 h2 -tls -alpn h2

echo "scenario,client,mean_rps,best_rps,runs"
awk -F, '{
        key = $1 "," $2;
        sum[key] += $4; n[key] += 1; reqs[key] = $3;
        if (!(key in min) || $4 < min[key]) min[key] = $4;
    }
    END {
        for (k in sum) {
            split(k, parts, ",");
            printf "%s,%s,%.0f,%.0f,%d\n", parts[1], parts[2],
                reqs[k] * n[k] * 1e9 / sum[k],
                reqs[k] * 1e9 / min[k], n[k];
        }
    }' "$OUT" | sort

echo "raw: $OUT" >&2
