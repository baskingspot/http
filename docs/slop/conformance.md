# HTTP/1 conformance and chaos testing plan

Status: future work, not implemented. The current `tests/engine_http1.zig` is a
wire smoke test. It is not an external conformance suite, and it should not be
described as one.

## Decision

Build and own a source-driven suite in the spirit of h2spec, Http11Probe, and
the parser corpora. Do not gate on an external HTTP/1.1 suite until one earns
the trust h2spec has for HTTP/2.

The case data should come from mature implementations, not from cases invented
for this server. Each case must carry its source project, revision, and license.

Http11Probe is an advisory report, not a gate. It is MIT, active, and broad, but
it was created in 2026 and has little independent adoption. uNetworking/h1spec
has no license; use it as inspiration only. dropseed/h1spec is a zero-star,
single-project harness; skip it. h2spec is HTTP/2 only.

## Sources

| Source | Layer | License | What to take |
| --- | --- | --- | --- |
| `picohttpparser` | head parser | MIT | Already in `tests/h1_corpus.zig`. |
| `nodejs/llhttp` | head parser | MIT | `test/request` and `test/response` fixtures. |
| `golang/go` | server parsing | BSD-3 | `src/net/http/readrequest_test.go` tables, `transfer_test.go` framing. |
| `python-hyper/h11` | connection | MIT | `test_connection.py` and `test_io.py` sequences: partial input, keep-alive, informational responses, chunked coding. |
| `httparse` | head parser | MIT/Apache-2.0 | Parser edge cases. |
| `hyper` | connection | MIT | HTTP/1 parser and connection vectors. |
| `nginx` `ngx_http_parse.c` | head parser | BSD-2 | Behavior reference for awkward input; no unit table. Do not copy code. |

Do not copy code from a source without a license. Test vectors are still
copyrighted; keep the source and license beside each case.

## Shape

One case type:

```text
Case
  id          stable name, for example RFC9112/host/missing
  source      project, file, revision
  license     SPDX identifier
  request     raw bytes
  chunks      optional write split points
  expect      status set, close/keep-alive, body bytes
```

One driver starts the server, sends the chunks in order, half-closes for
malformed cases, reads the response, and checks the expectation. The driver
must use a real socket. The blocking engine can run this now. The poll engine
will add timeout and slow-loris cases.

A short fixed-seed case set runs in CI. The full set runs nightly.

## Chaos

Seeds are the valid and invalid cases above. Mutations:

- Flip, insert, or delete bytes.
- Truncate at every byte boundary.
- Duplicate, reorder, or split header lines.
- Replace CRLF with LF, NUL, or an invalid control byte.
- Split writes at random boundaries.
- Add a body without a matching length, or a length without a body.
- Mix Content-Length and Transfer-Encoding.

Invariants for a mutated invalid seed:

- No 2xx response.
- No crash and no hang.
- The connection closes, or the response is 4xx or 5xx and then closes.
- The response framing is valid.
- Any bytes left after the response never become a second successful request.

Use a fixed PRNG seed for reproducible failures. Run a small set in CI and a
long run nightly.

The parser already has fuzz targets. Chaos here covers the transport and the
connection machine, not just the head parser.

## Phases

1. Keep `tests/engine_http1.zig` as a smoke test, not conformance.
2. Add the case type and the raw driver. Port Go's malformed request table and
   h11's partial and chunked cases first.
3. Add the chaos mode with a fixed CI seed.
4. Add a Go `net/http` interop lane for normal clients. Go is already in the
   flake for `tools/hpack-interop`. Python is acceptable if it reuses h11
   directly, but it needs formatter and linter wiring before it is
   load-bearing.
5. Run Http11Probe against a conformance server as an advisory report. Pin the
   revision. Keep .NET 10 out of the everyday dev shell.
6. Add poll-engine cases for deadlines, partial writes, stop, and slow-loris.

## Gaps the first run will expose

- Chunked request bodies return 501. A valid chunked case must pass before any
  conformance claim. Either implement chunked first or mark these cases as
  expected failures with a tracked task.
- The blocking engine has no deadlines and one connection. Slow-loris and
  concurrent connection cases belong to poll.
- The server has no TLS, streaming responses, proxy behavior, or upgrade
  support. Those are out of scope until a consumer asks.
