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
- `bench-reqwest` — `reqwest::blocking` with rustls. Cargo and rustc come
  from the devShell; the runner builds it in `bench/compare/reqwest`.

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
`ReleaseFast`, 2026-11-17. Requests per second, mean of three runs. Run-to-run
variation on this host is five to ten percent; the ratios held across runs.

One worker, 20,000 requests:

| scenario | http | Go net/http | reqwest |
| --- | --- | --- | --- |
| h1, cleartext | 68,355 | 36,318 | 33,729 |
| h1, TLS | 60,549 | 33,835 | 31,950 |
| h2, TLS | 24,952 | 19,119 | 20,042 |

Eight workers, 40,000 requests:

| scenario | http | Go net/http | reqwest |
| --- | --- | --- | --- |
| h1, cleartext | 247,331 | 131,394 | 73,317 |
| h1, TLS | 228,050 | 122,614 | 73,152 |
| h2, TLS | 122,928 | 53,826 | 50,179 |

Read the second table as per-connection scaling, not a pooling comparison: the
Zig client has no connection pool, so eight workers are eight connections.

## Multiplexed h2c

`bench-client URL N WORKERS h2mux` puts every worker on one h2c connection
through `h2.client.mux.Mux`. Against `just example-h2` (one server thread per
connection) on this host, eight workers and 40,000 requests took 445 ms, about
90,000 requests per second, on one connection. Eight separate connections took
126 ms, about 318,000: the example server is the bound there, not the client.

TLS is not in that mode yet. `tls_nonblocking.SocketClient` requires every call
on a connection to be serial, so a pump that reads on one thread while another
writes is not legal; TLS multiplexing needs the poll-driven pump (the
step-shaped `h2.client.Connection` plus `http_tls.h2.transport.tls_client`),
which this benchmark does not have yet.

The first run of this harness found the cleartext connector writing the request
head once per field, which cost about 24 µs per request. Buffering the writes
in `client.BufferedWriter` closed that gap; the numbers above include the fix.
