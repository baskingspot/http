# Changelog

All notable changes to http are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [0.1.0] - 2026-11-05

### Added

- `http`: HTTP/1.1 and HTTP/2 protocol kernels in one Zig module. The parsers
  return borrowed slices or fill caller-owned storage, take no allocator, do
  no I/O, and import no socket.
- `Header`, `Headers`, `Headers.values`, and `Headers.containsToken`: field
  lines with ordered duplicates, case-insensitive lookup, OWS trimming, and
  token-list membership.
- `Method`, `Status`, `Version`, and `WireVersion`: case-sensitive method
  tokens, open three-digit status values, and the effective and wire HTTP
  versions.
- `Cursor`: one infallible byte cursor for the parsers. Each protocol maps end
  of input to its own error.
- `encoding.negotiate` and `encoding.negotiateFields`: `Accept-Encoding` and
  content-coding choice over q-values, wildcard, identity, and repeated field
  lines.
- `token_list`, `content_length`, and `transfer_encoding.summarize`:
  comma-separated token lists, `Content-Length` accumulation, and
  `Transfer-Encoding` parsing with parameters and chunked checks.
- `h1.parseRequest`, `h1.parseResponse`, and `h1.parseFieldSection`:
  resumable sans-I/O head parsing with `SearchState`, exact method and status
  bytes, and rejection of bare LF, obs-fold, and whitespace before the colon.
- `h1.framing`, `h1.persistent`, `h1.targetForm`, and `h1.host`: request and
  response body framing, connection persistence, the four request-target
  forms, and the single `Host` value.
- `h1.chunked.Decoder` and `h1.Writer`: resumable chunked decoding with
  trailers and extensions, and request, status, field, Content-Length, body,
  and chunked writing over a caller-owned `std.Io.Writer`.
- `h1.ServerConn`: a sans-I/O HTTP/1 server connection machine with
  keep-alive, pipelining, buffered or application-owned request bodies,
  `Expect: 100-continue`, policy responses, idle and request deadlines, HEAD
  rules, drain, and the 101 protocol switch.
- `h1.engine.blocking`: a blocking HTTP/1 server over `std.Io`. `run` accepts
  connections and `serve` drives one stream; the handler uses `Exchange` and
  the per-exchange arena. Every connection timeout is zero.
- `h1.engine.poll`, `h1.engine.epoll`, and `h1.engine.kqueue`: HTTP/1
  readiness engines with fixed slots, nonblocking descriptors, connection
  deadlines, accept backoff, a stop descriptor, keep-alive, and pipelining.
  Poll and epoll run on Linux; kqueue runs on macOS. `error.AddressInUse`
  reports a bind conflict, and `Config.tcp_defer_accept` sets Linux
  `TCP_DEFER_ACCEPT`.
- `http.engine.Handler`, `Exchange`, `ResponseOptions`, and `PolicyContext`:
  the shared engine handler vtable with `handle`, `complete`, `report_error`,
  and `policy_response`; a stable exchange id; an engine-owned per-exchange
  arena; and response close control.
- `h1.ClientConn`: a sans-I/O HTTP/1 response machine for Content-Length,
  chunked, and close-delimited bodies, interim 1xx responses, and pipelined
  leftovers.
- `h1.client.streaming.Client`: the HTTP/1 blocking client adapter. It writes
  a request and static body, parses the response head into an arena, and
  streams the response body as a borrowed slice. A clean close keeps the
  connection reusable.
- `h2.head`, `h2.settings`, `h2.flow`, `h2.stream`, and `h2.header_block`:
  HTTP/2 field-section validation, SETTINGS application, flow-control
  windows, stream states and ids, and CONTINUATION assembly.
- `h2.Session`: a sans-I/O HTTP/2 connection machine with frame input and
  output, SETTINGS, flow control, HPACK, CONTINUATION assembly, stream
  tombstones, typed events, and `submit*` methods for requests, responses,
  data, settings, resets, and pings. The allocator is per call, so a fixed
  buffer allocator sets the ceiling.
- `h2.engine.blocking`: a blocking HTTP/2 server over `std.Io`, with a
  per-stream arena, a typed request, whole-body request buffering, flow-
  controlled response writing, and `serveIo` for a caller-owned reader and
  writer.
- `h2.engine.poll`, `h2.engine.epoll`, and `h2.engine.kqueue`: HTTP/2
  readiness engines over the shared exchange core, with fixed connection
  slots, nonblocking sockets, partial writes, deadlines, accept backoff, and a
  GOAWAY drain on stop. `http_tls` supplies the TLS transports.
- `h2.client.blocking.Client`: the HTTP/2 client adapter. It sends a request
  head and static request body, consumes WINDOW_UPDATE under flow control,
  streams a response body as a borrowed slice, reports RST_STREAM codes and
  GOAWAY boundaries, and exposes commit state and connection poison.
- `hpack.static_table`, `hpack.TableStorage`, `hpack.DynamicTable`,
  `hpack.Encoder`, and `hpack.Decoder`: HTTP/2 header compression with a
  caller-owned table, allocation-backed or fixed-buffer storage, indexed and
  literal fields, Huffman choice, and decoded fields copied into caller
  storage.
- `prefix_int` and `huffman`: the RFC 7541 integer and Huffman primitives
  shared by HPACK and QPACK.
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
- `examples/curl.zig` and `examples/http_unified_server.zig`: a streaming
  HTTP/1.1 and HTTP/2 client with ALPN and cleartext selection, and a server
  that serves both protocols on one TLS port and one cleartext port.
- Build requirements: Zig 0.16. `http` depends on `baskingspot/stdx` for
  `stdx.fmt.atoi`; `http_tls` also links OpenSSL for its TLS examples and
  transports.
