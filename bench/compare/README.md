# Client comparison

How fast the high-level client moves a small request over one keep-alive
connection, next to Go `net/http` and reqwest. The point is a baseline for the
client as a library, not a server benchmark: one Go reference server answers
every client, the body is 13 bytes, and the loop is sequential.

```sh
just bench-compare                 # N=20000, CONC=1, RUNS=3
CONC=8 N=40000 just bench-compare  # eight workers
```

The runner builds three clients against one Go server and prints a summary:

- `bench-client` — `http_tls.Client` from this repo, built `ReleaseFast`.
- `bench-go` — `net/http` with keep-alive and, for h2, Go's automatic h2.
- `bench-reqwest` — `reqwest::blocking` with rustls. Cargo is not in the
  project devShell; the runner uses `nix shell nixpkgs#cargo nixpkgs#rustc`
  when the binary is missing.

Scenarios: cleartext h1, TLS h1, and TLS h2. The server sets an explicit
`Content-Length`, so h1 has no chunked framing. Every client reads the body to
the end.

## What the client owns

`bench-client` creates one client per worker, and this client keeps one
connection per instance. At `CONC=8` that is eight connections for the Zig
client. Go and reqwest share one client between workers: Go multiplexes h2
streams over one connection, and reqwest does the same through its pool. The
h2 row therefore measures different connection counts, and the h1 rows are the
closest comparison.

TLS verification differs slightly: Go and reqwest skip the chain and the
hostname, while the Zig client skips the chain but still checks the name
against the server's certificate. That favors Go and reqwest.

## Results

NixOS, 8-core arm64, loopback, Go 1.27.3, reqwest 0.12.28 (rustls), Zig 0.17.1
`ReleaseFast`, 2026-11-16. Requests per second, mean of three runs.

One worker, 20,000 requests:

| scenario | http | Go net/http | reqwest |
| --- | --- | --- | --- |
| h1, cleartext | 70,360 | 37,965 | 34,687 |
| h1, TLS | 64,250 | 37,332 | 33,846 |
| h2, TLS | 25,246 | 20,401 | 20,908 |

Eight workers, 40,000 requests:

| scenario | http | Go net/http | reqwest |
| --- | --- | --- | --- |
| h1, cleartext | 273,105 | 139,849 | 78,061 |
| h1, TLS | 258,894 | 135,229 | 74,967 |
| h2, TLS | 140,564 | 57,015 | 51,879 |

Read the second table as per-connection scaling, not a pooling comparison: the
Zig client has no connection pool and no h2 multiplexing yet, so eight workers
are eight connections.

The first run of this harness found the cleartext connector writing the request
head once per field, which cost about 24 µs per request. Buffering the writes
in `client.BufferedWriter` closed that gap; the numbers above include the fix.
