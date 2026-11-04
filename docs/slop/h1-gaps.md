# HTTP/1 parser: hparse comparison and current gaps

Snapshot 2026-11-03. Reference: `hparse` 0.2.0, `src/root.zig` from
`github.com/nikneym/hparse` (cached as
`hparse-0.2.0-IukW0s67AADCDZ7ROogFU5EJAVLyI8aiR0LPNvZd88OK`). The comparison
was run against both implementations on the same buffers.

## What hparse is

One file, 1,105 lines, head-only. It parses the request line or status line
and the field section, fills caller storage, and returns the consumed length.
It has no body, no framing, no chunked coding, no trailers, and no connection
state. Its `Method` is the fixed nine; an unknown method is `error.Invalid`. Its
`Version` is 1.0 and 1.1 only; 1.2 is `error.Invalid`. It has no `last_len`
gate, so each call rescans from byte 0.

The scanners are vector and SWAR passes. That is the useful part to study. The
grammar is not: it is deliberately permissive, and the repo's own notes record
the cursor over-read at the buffer end and the validation change at the 16-byte
vector boundary.

## Probe results

Same input, hparse and `baskingspot/http`:

| Input | hparse 0.2.0 | http |
| --- | --- | --- |
| `Foo Bar: x` | accepts, name `Foo Bar` | `Invalid` |
| `Foo : x` | accepts, name `Foo ` | `Invalid` |
| `X: a` then ` b: c` | accepts as second field `" b"` | `Invalid` (obs-fold) |
| `X: a\tb` | `Invalid` | accepts |
| bare LF line endings | accepts | `Invalid` / `Incomplete` |
| `HTTP/1.2` | `Invalid` | parsed as 1.1 |
| `PROPFIND` | `Invalid` | method null, token `PROPFIND` |
| `X: y \t` | `Invalid` (HTAB); `X: y ` keeps the space | trims OWS |
| leading empty line | `Invalid` | skipped |
| obs-text in value | accepts | accepts |
| obs-text in target | accepts | `Invalid` |
| DEL in target | `Invalid` | `Invalid` |
| `204` with no second SP | accepts | `Invalid` |
| two SP after status | skips them | second SP starts the reason |
| `099`, `600` | accepts | accepts |

So the head parser is already stricter than hparse where the RFC permits
strictness, and more permissive only where the registry is open (methods) or
the RFC requires handling (1.2 through 1.9). hparse does not reveal a head
parsing gap; it confirms the choices in `docs/spec/h1.md`.

## Where the performance comes from

The SIMD idea is picohttpparser's, not hparse's. pico's `findchar_fast` uses
SSE4.2 `_mm_cmpestri` with a range table to find the first control character or
delimiter in a 16-byte block, then a scalar loop finishes the token. hparse's
README acknowledges picohttpparser, seanmonstar/httparse, Karl Seguin's
SIMD-with-Zig, Lemire's SWAR post, and Bit Twiddling Hacks. hparse is the
portable Zig translation of that design: `@Vector` comparisons plus `@ctz`
instead of SSE4.2 intrinsics, a SWAR fallback for targets without vectors, a
4-byte method dispatch, and an 8-byte version compare. The parts hparse adds
are real, but the scanning strategy is pico's.

The useful lesson is the one-pass scanner, not "use vectors everywhere". A
first benchmark of the old parser against hparse on the same buffers, built
`-O ReleaseFast` on aarch64 with 16-byte NEON:

| Input | http before | hparse | ratio |
| --- | --- | --- | --- |
| typical scrape, 5 fields | 103 ns | 76 ns | 1.36 |
| Chrome request, 10 fields | 332 ns | 231 ns | 1.44 |
| 76-byte header name | 88 ns | 81 ns | 1.09 |
| 1 KiB header value | 625 ns | 342 ns | 1.83 |

The old code scanned each target and field line twice: once with
`std.mem.find*` for the delimiter, then once to validate. It also called
`findScalarPos` and then ran a scalar tchar loop for every token. hparse scans
once and stops at the first stop byte.

The permanent bench now carries both parsers: `bench/hparse_bench.zig` runs
hparse 0.2.0 on the same heads, and `build.zig` builds the imported `http`,
`hparse`, and `stdx` modules at ReleaseFast. That last part was a bug in the
wiring: the suite root was ReleaseFast, but its imports kept the default Debug
mode, so the old rows measured Debug parser code. The numbers below are from
`just bench --benchtime=100ms --count=3 --filter=Request` and the response
filter.

| Input | http | hparse | ratio |
| --- | --- | --- | --- |
| typical scrape, 5 fields | 92 ns | 78 ns | 1.18 |
| response, 4 fields | 88 ns | 77 ns | 1.14 |
| wide request, 14 fields | 293 ns | 332 ns | 0.88 |
| 1 KiB header value | 92 ns | 307 ns | 0.30 |

These are higher than the ad-hoc numbers above because the bench keeps the
parsed head alive; the ad-hoc harness observed only `consumed`, which let the
compiler drop the result construction. The trade is visible and acceptable:
hparse wins the short-head cases by 14-18%, http wins the wide and long-value
cases, and the long value is the one that matters for throughput and hostile
input. hparse's short-head advantage is its 4-byte method dispatch and its
looser key scan; the latter is not worth copying.

Three changes produced the long-value win:

- `scanTarget` and `scanLine` are one vector pass. The mask contains the stop
  byte and every invalid byte at once, so the delimiter search and the
  validation are the same load.
- `scanToken` is one scalar pass, not `findScalarPos` followed by a validation
  loop. Tokens are short in practice, and the std search call costs more than
  the table lookups it replaces. This was the largest surprise: the scalar
  loop beat the vector search even on a 76-byte name.
- The now-unused `allTargetBytes` and `allFieldValueBytes` helpers are gone;
  the scanner tests drive the real scanners over every byte value at every
  position, across the vector and scalar paths.

Not taken, with reasons:

- The SWAR fallback. It only matters on a target where
  `std.simd.suggestVectorLength(u8)` is null. That is not a target this
  package ships to today. Add it if one appears.
- The 4-byte method dispatch. It is faster only by rejecting unknown methods,
  which is the opposite of the open registry this package keeps. A known-method
  fast path is possible, but the measured method parse was 1-2 ns of a 100 ns
  request.
- A vectorized tchar check. The scalar one-pass is faster for real header
  names; the two-pass search it replaced was the problem.

## Gaps

Ordered by what blocks a usable HTTP/1.1 message parser.

| Area | RFC 9112 | State | What is missing |
| --- | --- | --- | --- |
| Field section as its own entry point | §5 | private | `parseHeaders` is embedded in the head parser. Trailers and callers that already parsed a start line need a public field-section parser. |
| Transfer-Encoding field | §6.1 | none | Coding list with parameters, `chunked` must be final, no parameters on `chunked`. `token_list` cannot do this. |
| Message body framing | §6.3 | none | The ordered rules: no body for HEAD/1xx/204/304, tunnel for CONNECT 2xx, TE overrides CL, chunked final, otherwise CL, otherwise close for a response and none for a request. `content_length.parse` exists but h1 does not call it. |
| Chunked decoding | §7.1 | none | Resumable state machine, chunk-size overflow, chunk extensions (parse and ignore), last-chunk, data spans reads. |
| Trailer section | §7.1.2, RFC 9110 §6.5.1 | none | Parse field lines after the last chunk; do not merge fields that are not mergeable. |
| Persistence | §9.3 | none | HTTP/1.1 default persistent, HTTP/1.0 default close, `Connection: close` / `keep-alive` tokens. `Headers.containsToken` is the building block. |
| Request-target form | §3.2 | chars only | origin / absolute / authority / asterisk. Deliberately routing policy today; revisit when a router consumes it. |
| Host rules | §3.2 | not enforced | Exactly one Host in an HTTP/1.1 request. Server policy today. |
| Interim responses | RFC 9110 §15.2 | caller loop | `parseResponse` returns the first head. `Status.class()` identifies 1xx, but the contract for "keep reading for the final response" is not documented. |
| picohttpparser corpus | — | not ported | `docs/slop/http-end-state.md` claims the corpus is ported. It is not; the tests are hand-written. Port it with the deliberate divergences marked. |

Fixed during this review: `scanLine` searched only for `\r`, so a bare LF in
a field value or reason phrase returned `Incomplete` and waited for more
bytes. It now stops at the first control byte and rejects anything that is not
CR, in the same pass. `just test` has 64 tests, including the new cases. The
bench now wires hparse 0.2.0 in as a lazy, dev-only dependency and builds every
imported module at ReleaseFast.

## Recommended order

1. Expose the field-section parser. It is the trailer parser.
2. Add `h1.framing`: a pure decision over `Headers`, version, method, and
   status. This connects `content_length` to h1 and is the gate for every
   body-reading API.
3. Add the chunked decoder over the framing result.
4. Add trailers on top of the field-section parser.
5. Add the persistence helper.
6. Port the picohttpparser corpus with the deliberate divergences marked.

Framing first is deliberate: chunked, trailers, and persistence all need to
know whether there is a body before they mean anything.
