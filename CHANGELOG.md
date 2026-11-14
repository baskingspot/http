# Changelog

All notable changes to http are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Changed

- Outgoing frames no longer stage through a second buffer: the session's
  output queue takes a frame's header and payload in one scatter append, so
  each payload is copied once on the way out instead of twice. The staging
  buffer is gone.
- `h2.Session` no longer pre-reserves a stream table sized to
  `max_streams`; the table grows with the live count. A table sized sixteen
  times the live set made every stream lookup probe long chains and every
  tombstone rebuild walk the whole oversized table — under gRPC-style churn
  that was a fifth of the session's CPU. The insertions grow through the
  allocator, and the stream-limit refusal stays count-based.
- `h2` engine connections track live streams through `stdx.slot`'s pool
  instead of scanning the whole slot array. A pass that visited every
  configured slot — a cache line each, a thousand slots when a handful of
  streams were live — now visits only the live ones, in arrival order, and
  the engine's own link bookkeeping is gone: the pool owns the links, the
  handles are the indices, and the separate free-index allocation is deleted.
  Per-request server cycles drop accordingly under load. The `stdx`
  dependency moves to its unreleased `main` for the pool.

### Fixed

- `h2.Session` rebuilds its stream table once removed streams outnumber
  live ones. Removals leave tombstones in the table, so a long-lived session
  with churn — every gRPC call is one stream opened and closed — walked ever
  longer probe chains on every event for the life of the connection. Lookups
  are flat again no matter how many streams the session has served.

### Added

- `client.Body.reader` is a `std.Io.Reader`, so a response body goes anywhere a
  reader goes: `streamRemaining`, `allocRemaining`, `take`, or a caller's own
  parser. Framing is decoded beneath it, and a caller cannot observe whether the
  response was delimited by Content-Length, by chunked framing, or by the close
  of the connection. `client.Config.read_cause` binds a reader that latches why
  a read failed, and `http_tls.client.Connection.readCause()` provides one.

### Changed

- `client.Body` is `reader`, `outcome()`, and `close()`. Read it with
  `body.reader` and name a failure with `body.outcome()`, which is `.truncated`,
  `.protocol_error`, `.reset` with the RST_STREAM code, or `.local` with a
  `Local` value. The old `read()` and `BodyResult` are gone from the blocking
  body, and `resetCode()` and `localCause()` are replaced by `outcome()`.
- A clean body end is `error.EndOfStream` from the reader. Every other outcome
  is `error.ReadFailed`, including an h2 reset, which used to arrive as
  `error.Reset`.
- `Local` gains `timed_out` for a read deadline the caller set. Without
  `Config.read_cause` such a failure reads as a truncation.

### Fixed

- An h1 streaming response body is no longer capped at 16 MiB, or at any size.
  `h1.ClientConn.Config.body_bytes` is `?u64` and defaults to null, meaning
  unbounded, because the machine buffers one receive window and never the whole
  body. `h1.client.blocking.fetch` passes its `body_buffer` length as before.
- A response body over a caller's cap can no longer be reported as
  `error.Protocol`. It is a local capacity limit, and `outcome()` says so.
- A read never blocks for more bytes once it has some, so a duplex h2 caller
  that writes between reads keeps its turn.

## [0.4.2] - 2026-11-12

### Changed

- The `tls` pin is v0.4.1, which carries the stdx v0.4.0 alignment, so one
  tls instance serves every graph that also holds tls directly.

## [0.4.1] - 2026-11-12

### Changed

- The `stdx` pin is v0.4.0, so one stdx instance serves every graph that also
  holds stdx directly. Additive on top of the commit 0.3.0 shipped: no API
  change for http.

## [0.4.0] - 2026-11-12

### Changed

- h2 `engine.blocking.serveIo` takes `Io` as its first argument, matching the h1 engine and `serve`. Call sites pass `io` and, for a TLS transport, `wait_fd = .init(conn.socketHandle())`. `Config.wait_fd` is a `stdx.posix.OptionalFd`.
- The h1 start line and field lines accept LF as a line end as well as CRLF, as RFC 9112 §2.2 permits. A bare CR is still `error.Invalid`, and chunk framing still requires CRLF.
- `h2.client.Driver.read`, `ReadDeadline.set`, `Exchange.setDeadline`, and `http_tls.client.Connection.setDeadline` take `stdx.time.OptionalTimestamp`. Use `.none` to clear a deadline. `http_tls.client.Connection.Options.deadline` replaces `deadline_ns`. Per-stream deadlines store one `u64` instead of an optional `i96`.

### Fixed

- h2 `engine.blocking.serveIo` delivers a parked handler's `Exchange.setDeadline` wake at its time. The loop drove the connection with a stopped clock and read without a timeout, so a handler parked on a future wake slept until unrelated input arrived on the connection — a gRPC server enforcing `grpc-timeout` then never answered a silent client. The loop now drives on the awake clock and, with the new `Config.wait_fd`, waits on the socket only until the earliest wake. A red test parks with a wake a hundred milliseconds out while the client sends nothing; without the fix it hangs.

- h2 `Session` decodes the field block of a HEADERS it rejects, including a late HEADERS or trailers on a stream it already reset, and across CONTINUATION, before it fails the stream (RFC 9113 §4.3). Dropping the block left the HPACK dynamic table behind the peer's, so a later block on another stream decoded wrong fields or closed the connection with a compression error.
- A Zig 0.17 project that depends on http builds again. Zig 0.17 configures every package in the dependency graph, so tls 0.3.0's lazy `libxev` dependency failed to build even for a consumer that never enabled `http_tls`. The `tls` pin moves to v0.4.0, which dropped `tls_xev`.
- `hpack.Decoder` returns the new `error.Desynchronized` for every block after one that ended early or was invalid, instead of decoding it against a table that no longer matches the peer's. A `TooManyHeaders` or `OutputTooSmall` error leaves the decoder usable only when the whole block was read with the table in step, which needs `out_bytes` to hold the largest table entry; with less, it ends the block early and poisons the decoder. h2 `Session` sizes its decode storage to hold the larger of `max_header_list_size` and `header_table_size`.

## [0.3.0] - 2026-11-10

### Added

- `h2.client.Driver` drives a multiplexed `Connection` through caller-owned byte interfaces and buffers. It retains unaccepted input and completes successful short writes. Reader-mode deadlines use `ReadDeadline` hooks, including `http_tls.client.Connection.readDeadline()`.
- h2 request-body streaming, client and server. The client sends a body it does
  not have up front: `h2.client.blocking.Client.begin` queues the request
  HEADERS and returns a `client.BodyWriter`, `write` adds DATA under flow
  control, and `close` sends END_STREAM. `response()` reads the response head
  separately, so both directions stay live on one stream and a response may
  arrive while the request body is incomplete. The server sets
  `body_mode = .stream` on the h2 engine `Config`: the handler runs on the
  request head, reads `Exchange.request_body`, and answers with
  `beginResponse`, `write`, `endResponse`, or `resetStream` before END_STREAM.
  A body chunk's flow-control credit returns when the next chunk is asked for,
  so a handler that stops reading stops the peer. A peer reset makes the next
  read `error.Canceled`, and the outstanding balance returns to the connection
  window only. In `.stream`, `Config.body_bytes` caps the unconsumed body, not its
  total: a handler that keeps reading may take an upload of any length, and
  the two per-slot buffers are reused. A peer that runs ahead of the handler
  gets RST_STREAM `ENHANCE_YOUR_CALM` rather than a bigger buffer.
  `.buffered` still caps the whole request body. `respond` in the
  h2 engine is now the buffered convenience over the same pump.

- h2 handler deadlines: `Exchange.setDeadline(absolute_ns)` arms an
  application timer, and `Exchange.wake` says whether the handler was called
  for progress or because that deadline passed. The engine clears the deadline
  before the expiry call, so parking again without a new one makes progress.
  `Connection.deadline` stays the engine's own close condition; the new
  `Connection.wakeDeadline` is what a readiness driver includes in its poll
  timeout, so a future deadline with no socket activity still wakes. Application
  timers survive DATA, trailers, and WINDOW_UPDATE. In `.stream`,
  `Config.body_timeout` no longer resets a stream once its response started.
- `tests/tls_connection.zig`: a loopback test for `http_tls.client.Connection`.
  A listener thread drives `tls_nonblocking.Server` through a handshake and
  echoes plaintext; the client side is the connection under test. Covers a
  round trip and a passed deadline, against a generated test CA whose leaf it
  verifies, so chain verification is exercised end to end.
- `tests/tls_consumer.zig`: a consumer of the `http_tls` module by name, built
  as its own artifact. It pins that the module compiles when something other
  than itself imports it, which a file inside the module importing
  `@import("http_tls")` does not.
- `http_tls.client.Connection`: a blocking plaintext connection over TLS. Takes
  a socket and PEM bytes, hands back `reader()`, `writer()`, `setDeadline`, and
  `expired()`. The connection owns the deadline because an `Io.Reader` cannot
  report one, and because polling the socket under TLS gives the next reader a
  raw record rather than plaintext. It keeps no plaintext copy: the transport
  pins the delivered slice, a partial consume keeps the tail, and the reader
  consumes exactly what it hands over. `ca_pem` is optional and
  `insecure_no_chain_anchor` mirrors the transport, so a caller can express "no
  verification" the way `tls` itself allows.
- `h2.client.Connection.connectionErrorCode`: the frame error code behind a
  connection error. Streams closed by one report `.local.unusable`, which
  previously arrived with no way to tell what failed the connection.
- `h2.engine.Exchange.respond` copies the response options into the exchange
  arena before sending them. A header or trailer list built on the handler's
  stack is now safe; the engine sends it after `handle` returns. `RespondError`
  gains `error.OutOfMemory`. The response body is still borrowed and must stay
  valid until `complete` returns.

- `http_tls.h2.transport.tls_client`: the h2-over-TLS client byte transport.
  Same `transport.Event` union as the h2c and TLS server transports, with the
  binary-frame rules documented. A client/server handshake, application data,
  and close_notify are tested over pumpable buffers with no socket.
- `http_tls.anchors.build`: build a trust store from PEM bytes the caller
  already holds, with `now_sec` supplied. Returns `error.NoTrustAnchors` when
  nothing usable loaded, and discards a partial set rather than handing back a
  store that fails later as a chain error. The caller owns the bundle.
- `http_tls` now runs its own unit tests under `zig build test`, as a separate
  artifact because it links libcrypto. The TLS transport's mapping is pinned:
  a peer `close_notify` is `Event.closed`, a transport EOF is
  `error.UnexpectedEof`, and a peer alert is never masked by a drain.
- `http_tls` TLS transport `peerAlert`: after `next` returns `error.PeerAlert`,
  the slot reports the peer's alert level and description. A fatal handshake
  alert is no longer an unnamed error. The alert is unavailable once the
  transport reaches `.closed`, so the transport latches it when it arrives.
- Dual-toolchain support: the tree builds and tests on Zig 0.16 and 0.17.
  `nix develop` selects 0.17 and `nix develop .#zig-old` selects 0.16. CI runs
  both lanes, including the blocking TLS examples and conformance cells.
- h1 streaming responses: an unknown `ResponseStream.content_length` now uses
  chunked framing on HTTP/1.1. The terminal chunk returns the connection to
  keep-alive. HTTP/1.0 keeps the close-delimited path. HEAD, 204, and 304 send
  the head without pulling the source, and a known length is enforced exactly.
- `h2.client.connection.Connection`: a step-shaped, multiplexed HTTP/2 client
  with writable request DATA, `DataLease` response reads, response trailers,
  per-stream flow-control backpressure, and GOAWAY boundary handling.
  `h2.client` also exports `Event`, `Close`, `Request`, and `Options`, so a
  caller can name the event union and dispatch per stream.
  `Connection.wantsInput` tells a hand-driven loop whether a socket read can
  make progress, which prevents a read that blocks after the last stream
  closes.
- `h2.engine.ResponseOptions.trailers`: a borrowed trailing header section,
  sent as its own HEADERS block after the body. This is how HTTP/2 carries a
  gRPC status. The h1 engines reject a non-empty list with
  `error.InvalidResponse` instead of dropping it.
- `h2.Session.releaseConnection` and `releaseStream`: independent receive
  window credits for streaming servers.

### Changed

- Package consumers get `http` without fetching TLS or CLI dependencies. Pass
  `.tls = true` to `b.dependency("http", ...)` to import `http_tls`; the repo's
  own test and example graph keeps TLS enabled by default. `testingx` stays
  developer-only.
- `http_tls.client.Connection` now delegates socket I/O, trust anchors, and
  deadlines to `tls_nonblocking.SocketClient`. It still requires the configured
  ALPN protocol and exposes `selectedAlpn`, `peerAlert`, `readError`,
  `writeError`, and `expired()` without hiding the underlying cause.

### Fixed

- `h2.client.Driver.read(null)` preserves a transport timeout as a terminal error, not an expired read deadline.
- `h2.client.Connection.wantsInput()` keeps accepted streams readable after GOAWAY. `canOpen()` also compiles through a const receiver.
- Terminal read errors, `Driver.flush()` errors, and EOF prevent driver reuse. `failureCause()` preserves the first terminal cause. Timed reads reap pending batch operations and retain concurrent completions.
- `http_tls` builds on Zig 0.16 again. The deadline wait used the 0.17-only
  `Io.Operation.net_read`; on 0.16 a future deadline now reports
  `error.DeadlineUnsupported` and an already-passed deadline still reports
  `error.TimedOut`. `tests/tls_connection.zig` also selected the Linux wait
  backend on macOS, so the suite did not compile there.

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
