# Changelog

All notable changes to http are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- Dual-toolchain support: the tree builds and tests on Zig 0.16 and 0.17.
  `nix develop` selects 0.17 and `nix develop .#zig-old` selects 0.16. CI runs
  both lanes. The blocking `tls_std` examples remain 0.16-only because that
  TLS integration has no 0.17 transport yet.
- `h2.client.connection.Connection`: a step-shaped, multiplexed HTTP/2 client
  with writable request DATA, `DataLease` response reads, response trailers,
  per-stream flow-control backpressure, and GOAWAY boundary handling.
- `h2.Session.releaseConnection` and `releaseStream`: independent receive
  window credits for streaming servers.

## [0.2.0] - 2026-11-06

### Added

- `http.stream` and `Exchange.respondStream`: pull-based response bodies for
  the h1 blocking and readiness engines. A `ReadStream` returns one borrowed
  chunk at a time, and an unknown length is close-delimited with
  `Connection: close`. SSE, poll-engine SSE, and file-transform examples are
  included.
- `h1.engine` deferred handlers: `Exchange.deferResponse`, `Exchange.wakeHandle`,
  a copyable `Waker`, and per-exchange `timeout` and `on_timeout` policy.
  The readiness engines park the slot without polling it, cancel the external
  work on deadline or disconnect, and resume the callback on the engine thread.
- `curl`: `-X`, `-d`, `-H`, `-I`, `--http1.1`, and `-s` options.

### Changed

- `http.client.Body.read` returns `BodyError!BodyResult`. `EndOfStream` is an
  error; `resetCode()` and `localCause()` carry the reset and local-failure
  details.

## [0.1.0] - 2026-11-05

### Added

- `http`: HTTP/1.1 and HTTP/2 protocol kernels in one Zig module. Parsers
  return borrowed slices or fill caller-owned storage, take no allocator, and
  do no I/O.
- `Header`, `Headers`, `Headers.values`, and `Headers.containsToken`: field
  lines with ordered duplicates, case-insensitive lookup, OWS trimming, and
  token-list membership.
- `Method`, `Status`, `Version`, `WireVersion`, and `Cursor`: case-sensitive
  method tokens, open three-digit status values, effective and wire HTTP
  versions, and the byte cursor used by every parser.
- `encoding`, `token_list`, `content_length`, and `transfer_encoding`:
  content-coding negotiation over q-values and repeated fields, token lists,
  `Content-Length` accumulation, and `Transfer-Encoding` parsing with
  parameters and chunked checks.
- `h1.parseRequest`, `h1.parseResponse`, `h1.parseFieldSection`,
  `h1.framing`, `h1.persistent`, `h1.targetForm`, and `h1.host`: resumable
  sans-I/O HTTP/1 head parsing, body framing, persistence, request-target
  forms, and the single `Host` value.
- `h1.chunked.Decoder` and `h1.Writer`: resumable chunked decoding with
  trailers and extensions, and request, status, field, Content-Length, body,
  and chunked writing over a caller-owned `std.Io.Writer`.
- `h1.ServerConn`: a sans-I/O HTTP/1 server machine with keep-alive,
  pipelining, buffered or application-owned request bodies,
  `Expect: 100-continue`, policy responses, connection deadlines, HEAD rules,
  drain, and the 101 protocol switch.
- `h1.engine.blocking`, `h1.engine.poll`, `h1.engine.epoll`, and
  `h1.engine.kqueue`: blocking and readiness HTTP/1 servers with a shared
  handler vtable, per-exchange arena, fixed slots, connection deadlines,
  accept backoff, keep-alive, and pipelining. Poll and epoll run on Linux;
  kqueue runs on macOS. The listener reports `error.AddressInUse` on a bind
  conflict.
- `http.engine.Handler`, `Exchange`, `ResponseOptions`, and `PolicyContext`:
  the shared engine contract for request handling, completion, error
  reporting, policy responses, response close control, and a stable exchange
  id.
- `h1.ClientConn` and `h1.client.streaming.Client`: an HTTP/1 response
  machine for Content-Length, chunked, and close-delimited bodies, plus the
  blocking client adapter that streams a borrowed response body and sends a
  static request body. A second request before the first finishes is
  `error.RequestInProgress`.
- `h2.head`, `h2.settings`, `h2.flow`, `h2.stream`, and `h2.header_block`:
  HTTP/2 field-section validation, SETTINGS application, flow-control
  windows, stream states and ids, and CONTINUATION assembly.
- `h2.Session`: a sans-I/O HTTP/2 connection machine with frame input and
  output, SETTINGS, flow control, HPACK, CONTINUATION assembly, stream
  tombstones, typed events, and `submit*` methods for requests, responses,
  data, settings, resets, and pings.
- `h2.engine.blocking`, `h2.engine.poll`, `h2.engine.epoll`, and
  `h2.engine.kqueue`: blocking and readiness HTTP/2 servers with per-stream
  arenas, request buffering, flow-controlled responses, fixed slots,
  nonblocking sockets, deadlines, accept backoff, and a GOAWAY drain on stop.
- `h2.client.blocking.Client`: the HTTP/2 client adapter, with request and
  static body sending, response-body streaming as a borrowed slice,
  WINDOW_UPDATE handling, RST_STREAM codes, GOAWAY boundaries, commit state,
  and connection poison.
- `hpack.static_table`, `hpack.TableStorage`, `hpack.DynamicTable`,
  `hpack.Encoder`, `hpack.Decoder`, `prefix_int`, and `huffman`: HTTP/2 header
  compression with a caller-owned table, allocation-backed or fixed-buffer
  storage, indexed and literal fields, Huffman choice, and the shared integer
  and Huffman primitives.
- `http.client`: the protocol-neutral client contract. `Request`,
  `ResponseHead`, `Body`, `BodyRead`, `BodyStep`, `Response`, `Config`, and
  `GoAway` cover a request, a response head snapshot, borrowed body data,
  terminal and local body outcomes, and the 16 KiB header and 128 field
  limits.
- `http.client.blocking.Client`: one blocking client interface for the h1 and
  h2 adapters. `Config.protocol` selects the adapter.
- `http.client.frame_queue`: a resumable outbound frame queue for a step
  client. It keeps one partially written frame, refuses an append while a
  frame is partial, holds HEADERS and CONTINUATION contiguity, and marks
  END_HEADERS commit separately from END_STREAM completion.
- `response.Response`: status, fields, and body as a typed response value for
  the h2 session and engine writers.
- `http_tls`: an optional module for TLS 1.3 over `baskingspot/tls`, with
  `tls_std` blocking seams, ALPN h1 and h2 selection, and h2 TLS readiness
  transports. The core `http` module stays h2c-only and links no crypto.
- Build requirements: Zig 0.16. `http` depends on `baskingspot/stdx` for
  `stdx.fmt.atoi`; `http_tls` also links OpenSSL for its TLS examples and
  transports.
