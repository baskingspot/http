# http

Pure HTTP field-value parsers: content negotiation, ranges, entity tags, dates, and media types.

The parser modules are sans-I/O. Parse a header value, negotiate a content
coding, compare validators. The parsers take borrowed slices and fill
caller-owned storage. `h1.ServerConn` is a sans-I/O connection state machine;
`h1.engine.blocking` owns the socket, the clock, and the handler loop over
`std.Io`. Evented engines are separate.

This project is incubating. It is unstable, its API will change, and it is not
ready to depend on.

## What is in it

- `encoding`: `Accept-Encoding` negotiation. `negotiate(header, supported)`
  returns a token borrowed from `supported` in server-preference order,
  `"identity"`, or `null` when the client accepts nothing else.
  `negotiateFields` takes every `Accept-Encoding` line, because the lines
  combine as one ordered list. The caller maps the token to its codec: `gzip`,
  `br`, `zstd`, or `deflate` for a zlib codec.
- `token_list`: comma-separated token lists (`Connection`, `Upgrade`, `Vary`).
  `contains(field, token)` tests membership without allocating; `iterator`
  yields trimmed elements. Empty elements are ignored, and the comparison
  folds ASCII case.
- `transfer_encoding`: `Transfer-Encoding` parsing. `summarize` walks the
  field lines in order and returns the final coding, whether `chunked`
  appeared, and whether it was last. Repeated `chunked` and parameters on it
  are errors. Parameters are parsed, including quoted values with commas.
- `Method`: the conventional nine request methods as a local enum.
  `Method.token(.GET)` is `"GET"`, and `Method.parse("GET")` is exact and
  case-sensitive. An unlisted token stays a slice and `parse` returns null.
  `safe`, `idempotent`, `cacheable`, `requestHasBody`, and `responseHasBody`
  follow RFC 9110 §9.2.
- `Status`: status codes as an open enum. `.ok`, `.not_found`, and the rest
  are named; any other three-digit code is still a value, so `class` returns
  null only outside 100..599. `Status.parse(200)` is `.ok`, `status.code()` is
  the wire number, and `phrase()` returns null for an unnamed code.
- `Cursor`: the shared read position over borrowed bytes. `next`, `peek`,
  `take`, and `skip` return null or false at the end; `at` and `slice` assert
  bounds a scanner already checked. The cursor never decides whether running
  out is an error, so `h1` maps it to `Incomplete` and HPACK to `Truncated`.
  `h1`, `prefix_int`, and the Huffman decoder all use it.
- `Header` / `Headers`: `Header` is a borrowed name/value pair. `Headers` is an
  ordered, case-insensitive view over a field section. `get` returns the first
  value for singleton fields, `values` yields every line separately
  (`Set-Cookie` needs that), and `containsToken` tests list membership across
  all lines. Lookups trim OWS; the raw spans stay in `Headers.items`.
- `h1`: sans-I/O HTTP/1.1 head parsing. `RequestHead.method` is the common
  method as `?Method`, and `method_token` is always the exact wire bytes;
  `ResponseHead.status` is `Status`. `version` is the effective version after
  RFC 9110 §6.2, and `wire_version` keeps the exact major and minor. Both heads
  carry `Headers`.
  `parseRequest` and `parseResponse` return `error.Incomplete` until a whole
  head arrives, and take a `SearchState` so a client trickling bytes cannot
  force a rescan. Strict where RFC 9112 allows leniency: bare LF, obs-fold, whitespace
  before the colon, and lenient start-line whitespace are rejected.
  `h1.parseFieldSection` parses a standalone field section, which is also the
  trailer parser. `h1.chunked.Decoder` is a resumable chunked body decoder:
  chunk sizes and extensions, a trailer section, borrowed data slices, and
  `need_more` across reads.
  `h1.Writer` carries a caller-owned `std.Io.Writer` and formats a request or
  status line, fields, a Content-Length or chunked body, and trailers into it;
  it never flushes or closes the sink. Checked methods validate the grammar;
  the `assume*` variants skip validation for trusted data.
  `h1.framing` decides the body from a head: a request is `.none`, `.length`,
  or `.chunked`; a response adds `.close` and `.tunnel` (RFC 9112 §6.3).
  `h1.persistent` applies the §9.3 connection rule. It rejects TE with CL, TE
  on an HTTP/1.0 message, and a request whose final coding is not `chunked`.
  `h1.targetForm` classifies the request target as origin, absolute, authority,
  or asterisk for the method; `h1.host` returns the single Host value or
  `error.DuplicateHost`.
  `h1.ServerConn` drives one connection over those pieces: it buffers a
  request body, keeps the leftover for a pipelined request, queues policy
  errors, and writes a response through a caller head buffer. It owns no
  memory and does no I/O.
- `h1.engine.blocking`: a blocking HTTP/1 server over `std.Io`. `run` accepts one
  connection at a time; `serve` drives one stream. The handler formats a
  response body with the exchange arena, and the connection machine handles
  parsing, framing, keep-alive, pipelining, and policy responses. The blocking
  engine sets every timeout to zero because a blocking syscall cannot enforce
  them; the evented engines are separate.
- `h1.engine.poll`, `h1.engine.epoll`, and `h1.engine.kqueue`: readiness
  servers with fixed slots, nonblocking sockets, accept backoff, connection
  deadlines, keep-alive and pipelining. Poll and epoll are Linux; kqueue is
  macOS. They share the slot state machine and differ in registration, wait,
  and the platform edge. All use the same `Handler` vtable and `Exchange` as
  the blocking engine. `Handler.VTable.complete` reports when a borrowed
  response body can be released. Each exchange owns an arena that is reset
  after completion. io_uring is separate.
- `prefix_int`: HPACK and QPACK prefix integers (RFC 7541 §5.1), shared by
  both. Up to 32 bits, with the representation's tag bits left to the caller.
- `huffman`: the RFC 7541 Appendix B Huffman code, shared by HPACK and QPACK.
  Decodes into caller storage and rejects EOS and bad padding; encodes with
  the EOS prefix padding. An eight-bit root table covers every letter and
  digit, so the canonical scan is the rare path.
- `hpack`: HPACK for HTTP/2. `static_table` is the RFC's 61 fields,
  `DynamicTable` is the per-connection table; `TableStorage` is its bytes,
  slot records, and hash array, either allocated once from an allocator or
  wrapped over a caller byte buffer. `hpack.Decoder` turns one complete header block
  into `Header` values copied into the caller's buffer, and `hpack.Encoder`
  writes one. `decodeFlags`
  records the RFC 7541 §6.2.3 never-indexed flag, and `encodeModes` takes one
  `Mode` per field. The encoder indexes by default, reuses an exact pair as an
  indexed field, Huffman-codes only when that is strictly shorter, and sends
  the table size update a SETTINGS change requires. The Appendix C request and
  response sequences are the tests.
- `h2.frame`: sans-I/O HTTP/2 framing (RFC 9113 §4, §6). `parse` takes the
  bytes so far and returns the frame header and a typed payload; `Writer`
  fills a caller buffer and patches the 24-bit length. Frame syntax only:
  stream state, settings, and CONTINUATION assembly belong above it. h2c and
  h2 over TLS share it.
- `h2.head`: request and response heads over the field list HPACK produced
  (RFC 9113 §8.2, §8.3). Pseudo-headers are extracted and validated, the
  regular fields come back as `Headers`, and CONNECT and extended CONNECT are
  handled. Malformed sections are a stream error PROTOCOL_ERROR. Cookie lines
  are not combined; the caller owns that storage.
- `h2.settings`, `h2.flow`, `h2.stream`, and `h2.header_block`: the state
  pieces the h2 session composes. Settings carry the RFC 9113 defaults and
  validate a peer's values; flow-control windows are signed for a shrunk
  initial window; stream transitions follow §5.1 and allocate identifiers by
  role parity; header-block assembly joins CONTINUATION fragments into a
  caller-owned buffer.
- `h2.Session`: the sans-I/O h2 connection machine. It owns the preface,
  SETTINGS, streams, HPACK, flow control, CONTINUATION assembly, and the
  outbound queue. `receive` and `send` move bytes; `nextEvent` returns decoded
  requests, responses, DATA, trailers, resets, and GOAWAY; the `submit*`
  methods queue frames, `submitResponse` takes a typed
  `http.response.Response` (status and content length stay values until the
  encoder writes them), and `submitSettings` sends a local SETTINGS change. The
  allocator is per call and never stored. Stream
  records and output chunks come from fixed-record pools, so a
  `FixedBufferAllocator` gives the connection a fixed ceiling. The h2c example
  is the conformance target: `just conformance` runs h2spec against it, and the
  full suite passes in strict mode.
- `h2.engine.blocking`: a blocking server engine over `std.Io`, the h2
  counterpart to `h1.engine.blocking`. `serve` drives one connection and `run`
  is the accept loop. The shared `h2.engine.Connection` core buffers one
  request per stream and hands it to a type-erased `Handler` as an `Exchange`:
  a typed head, the whole body up to `body_bytes`, and trailers, with a
  per-stream arena. `respond` records the
  response and the engine sends it under flow control; `complete` and
  `report_error` close the lifecycle. The h2c example is this engine with a
  thread per connection above `serve`; `h2.Session` remains the streaming
  escape hatch.
- `h2.engine.poll`, `h2.engine.epoll`, and `h2.engine.kqueue`: the readiness
  engines. One thread, fixed connection slots, nonblocking sockets, and the same
  `Connection` core and `Exchange` handler. poll and epoll are Linux; kqueue is
  macOS. The wait backends and platform edge move to `src/transport`, shared
  with the h1 engines. `just conformance-run-readiness` runs h2spec against the
  readiness example.
- `content_length`: `Content-Length` parsing and combination. Repeated values
  must agree, a comma list of identical values is accepted, and non-digits,
  conflicts, and overflow are errors. `null` means the field was absent.
  `content_length.Parser` feeds one field line at a time for a caller that
  already has a field view. The caller owns the rule that `Transfer-Encoding`
  and `Content-Length` cannot both frame a request; `h1.framing` applies it.

Ranges, entity tags, dates, media types, and form decoding are next. The parser
modules remain free of server types. `h1.engine.blocking`,
`h1.engine.poll`, `h1.engine.epoll`, and `h1.engine.kqueue` are the servers in
the package; io_uring remains separate, and the parser modules still have no
I/O runtime.

## Usage

```zig
const http = @import("http");

const coding = http.encoding.negotiate("gzip;q=0.5, br;q=1", &.{ "br", "gzip" });
// "br"
```

The token is borrowed from `supported`; `"identity"` is a static string. The
tests carry the q-value, wildcard, and identity rules.

```zig
const persistent = !http.token_list.contains("keep-alive, Upgrade", "close");
const length = try http.content_length.parse(&.{ "42", "42" }); // 42
```

## Work on it

`nix develop` provides the toolchain. `just ci` runs what CI runs, `just bench`
runs the benchmarks, `just fuzz` drives the fuzz targets with the built-in
runner, and `just example` runs the HTTP/1.1 server example.

`just example-h2` runs an h2c server on `127.0.0.1:8081`, driven by
`h2.engine.blocking`. Poke it with `curl -v --http2-prior-knowledge
http://127.0.0.1:8081/`, or with the devshell's `nghttp -v
http://127.0.0.1:8081/` to see the frames. It handles the preface, SETTINGS,
PING, HPACK, flow control, and a fixed 200 response over a real session loop;
the socket, TLS, and handler live outside the library. `just conformance-run`
starts its own example, runs h2spec, and stops it (pass `-S` for strict);
`just conformance` targets an example you already started, and `just load`
runs h2load.

## License

MIT. See `LICENSE`.
