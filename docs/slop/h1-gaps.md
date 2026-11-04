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
| `HTTP/1.2` | `Invalid` | parsed as 1.1, wire pair `1.2` |
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
| typical scrape, 5 fields | 91 ns | 79 ns | 1.15 |
| response, 4 fields | 88 ns | 72 ns | 1.22 |
| wide request, 14 fields | 290 ns | 333 ns | 0.87 |
| 1 KiB header value | 92 ns | 307 ns | 0.30 |

These are higher than the ad-hoc numbers above because the bench keeps the
parsed head alive; the ad-hoc harness observed only `consumed`, which let the
compiler drop the result construction. The trade is visible and acceptable:
hparse wins the short-head cases by 15-22%, http wins the wide and long-value
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

The H1 message path is in place: head parsing, standalone field sections,
Transfer-Encoding, the RFC 9112 §6.3 body decision, chunked decoding with
trailers, the §9.3 persistence rule, target-form classification, and the single
Host helper. The examples use the chunked decoder for requests, and the io_uring
example decodes a chunked response. The picohttpparser case table is ported in
`tests/h1_corpus.zig`, with the deliberate divergences marked. The writer has a
benchmark in `bench/writer_bench.zig`.

No parser gaps remain. A protocol writer beyond `h1.Writer` is a separate
feature, not a parser gap.
