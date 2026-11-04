# Changelog

All notable changes to http are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- `h1.ClientConn`: a sans-I/O HTTP/1 response machine for one request at a
  time. It parses response heads, Content-Length, chunked, and close-delimited
  bodies, preserves pipelined leftovers, and returns borrowed body slices
  without allocating. The caller writes the request with `h1.Writer`.

- `h1.engine.poll`, `h1.engine.epoll`, and `h1.engine.kqueue`: HTTP/1
  readiness engines. Poll and epoll are Linux; kqueue is macOS. They share
  fixed slots, nonblocking descriptors, accept backoff, connection deadlines,
  keep-alive and pipelining, and a stop descriptor (eventfd on Linux, pipe on
  macOS). The handler is the shared `Handler` vtable, the same as the blocking
  engine. The wait, registration, and platform edge live in a backend; the slot
  state machine is shared. io_uring is separate. `Config.tcp_defer_accept` sets
  Linux `TCP_DEFER_ACCEPT`. A wait that returns `SystemResources` backs off and
  retries.

- `Exchange.id` and `Handler.VTable.complete`: the engine reports when the
  final response bytes are written or the connection ends, so a handler can
  release a response body it owns. The slot id is stable for the exchange.
  `Exchange.arena` is the engine-owned allocator; it is reset to
  `Config.arena_retain_bytes` after completion.

- `h1.engine.blocking`: a blocking HTTP/1 server over `std.Io`. `run` accepts one
  connection at a time; `serve` drives one stream. The handler is the shared
  `Handler` vtable with `handle`, `complete`, and `report_error`. A handler
  formats a response body with the exchange arena. The connection machine
  handles parsing, framing, keep-alive, pipelining, and policy responses.
  Every timeout is zero: a blocking syscall cannot enforce the connection
  deadlines. Evented engines are separate.

- `h2.head.request` and `h2.head.response`: field-section validation and the
  two heads. Pseudo-headers are ordered, deduplicated, and checked per
  direction; `:method`, `:scheme`, `:path`, `:authority`, `:protocol`, and
  `:status` follow RFC 9113 §8.3. Field names are lowercase `tchar`, values
  reject controls and edge whitespace, and the connection-specific fields are
  rejected. The regular fields come back as `Headers`; cookie lines are not
  combined.
- `h2.settings`, `h2.flow`, `h2.stream`, and `h2.header_block`: the h2 state
  pieces. `settings.apply` validates a peer's SETTINGS with the RFC 9113
  defaults; `flow.Window` accounts DATA and WINDOW_UPDATE with signed windows;
  `stream.transition` implements the §5.1 states and `stream.Ids` allocates by
  role parity; `header_block.Assembler` joins CONTINUATION fragments.
- `h2.Session`: the sans-I/O h2 connection machine. `receive`/`send` move
  bytes, `nextEvent` yields requests, responses, DATA, trailers, resets,
  SETTINGS, and GOAWAY, and `submit*` queues frames. SETTINGS, the stream table,
  HPACK, flow control, CONTINUATION assembly, and the outbound queue are
  inside; sockets, TLS, and the event loop are not. `submitResponse` takes a
  typed `http.response.Response`; the status and content length stay values
  until the HPACK encoder writes them. The allocator is per call;
  stream records and output chunks come from `std.heap.MemoryPool`, so a
  `FixedBufferAllocator` sets a fixed ceiling. `submitData` returns the prefix
  flow control accepts, and `release` returns consumed bytes to both windows.
  `submitSettings` sends a local SETTINGS change and applies its receive-side
  effects, capped by the storage `init` allocated. Closed streams keep a
  tombstone ring for the right `STREAM_CLOSED` behavior; a self-dependent
  HEADERS or PRIORITY and a trailer without END_STREAM are stream errors. The
  h2c example serves connections on threads and the full h2spec suite passes,
  strict included.
- `h2.engine.blocking`: the blocking h2 server engine over `std.Io`, the h2
  counterpart to `h1.engine.blocking`. `serve` buffers one complete request per
  stream and hands it to a type-erased `Handler` as an `Exchange` with a typed
  head, whole body, trailers, and a per-stream arena. `respond` records the
  response; the engine validates it, sends the HEADERS, and pumps the body
  under flow control. `complete` and `report_error` close the lifecycle. The
  sans-I/O `h2.engine.Connection` core holds the session, slots, arenas, and
  handler; the blocking engine is a transport driver around it, and the h2c
  example uses it with a thread per connection.
- `h2.engine.poll`, `h2.engine.epoll`, and `h2.engine.kqueue`: the h2
  readiness engines over the same exchange core. One thread, fixed connection
  slots, nonblocking sockets, partial writes, optional idle/write/total/head/body
  deadlines, accept backoff, and a GOAWAY drain on stop. poll and epoll are
  Linux; kqueue is macOS. The wait backends and platform edge live in
  `src/transport`, shared with the h1 engines. `just ci` runs the strict h2spec
  conformance suite against the readiness example.
- `Status`: the status codes as an open enum. Named codes are constants; any
  other three-digit code is still a value. `Status.code()`, `Status.class()`,
  `Status.phrase()`, and `Status.parse()` work on the wire number, and the
  parser returns `Status` directly.
- `Method`: the conventional nine request methods as a local enum, with
  `Method.token()`, the case-sensitive `Method.parse()`, and the RFC 9110
  §9.2 predicates.
- `Header`, `Headers`, and `Headers.values`: borrowed field lines and ordered,
  case-insensitive lookup over a field section. Duplicate lines are yielded
  separately, and lookups trim OWS.
- `Headers.containsToken`: list-element membership across every line with a
  given name.
- `encoding.negotiate`: `Accept-Encoding` parsing and content-coding
  negotiation over the q-value, wildcard, and identity rules. The chosen
  token is borrowed from the caller's supported list.
- `encoding.negotiateFields`: the same negotiation across multiple field
  lines, which combine as one ordered list.
- `token_list.contains` and `token_list.iterator`: comma-separated token
  lists such as `Connection` and `Upgrade`, with OWS handling and
  case-insensitive membership.
- `h1.parseRequest` and `h1.parseResponse`: sans-I/O HTTP/1.1 head parsing.
  `RequestHead.method` is `?Method` and `method_token` keeps the exact wire
  bytes; `ResponseHead.status` is `Status`; `version` is the effective version
  after RFC 9110 §6.2 and `wire_version` keeps the wire pair. Both heads carry
  `Headers`. Both report `error.Incomplete` until a whole head arrives, take
  a `SearchState` for a resumable completeness check, and reject bare LF,
  obs-fold, and whitespace before the colon.
- `h1.ServerConn`: a sans-I/O server connection state machine. It owns no
  memory and does no I/O. The caller supplies the request buffer, field
  storage, response head buffer, and time. It handles keep-alive and
  pipelining, buffers request bodies up to a limit, answers `Expect:
  100-continue`, and queues policy responses. Call `start` after accept so a
  silent connection has a deadline. Separate idle and head timeouts bound the
  keep-alive wait and the request head; `drain_timeout` bounds a lingering
  close, and zero skips the drain. HEAD responses keep Content-Length and omit
  the body. Chunked request bodies return 501 for now. A final 1xx response is
  rejected; an HTTP/1.0 request never receives 100 Continue.
- `h1.framing.request` and `h1.framing.response`: body framing per RFC 9112
  §6.3. A request returns `RequestBody`: `.none`, `.length`, or `.chunked`. A
  response returns `ResponseBody`, which adds `.close` and `.tunnel`. TE with
  CL, TE on an HTTP/1.0 message, and a request whose final coding is not
  `chunked` are errors.
- `h1.persistent`: the RFC 9112 §9.3 connection decision from the version and
  the `Connection` tokens. HTTP/1.1 persists by default; HTTP/1.0 persists
  only with `keep-alive`; `close` wins.
- `h1.targetForm`: the four request-target forms from RFC 9112 §3.2, classified
  by the method. The target stays syntax; routing is the caller's.
- `h1.host`: the single `Host` value, or `error.DuplicateHost` when the field
  repeats. A missing Host in an HTTP/1.1 request is the caller's 400.
- `h1.parseFieldSection`: a standalone field section and the trailer parser.
  An empty section is a single CRLF; the returned headers borrow the input and
  the caller's storage.
- `h1.chunked.Decoder`: resumable chunked transfer coding (RFC 9112 §7.1).
  `next` returns a borrowed data slice, the trailer `Headers`, or `need_more`,
  with the consumed prefix on every step. Chunk extensions are parsed and
  ignored; a chunk-size overflow is `error.Overflow`.
- `h1.Writer`: carries a caller-owned `std.Io.Writer` and writes request/status
  lines, field lines, Content-Length, body bytes, and chunked bodies with
  trailers. Checked methods validate the parser's grammar; the `assume*`
  variants skip validation for trusted data. The writer never allocates,
  flushes, or closes the sink.
- `transfer_encoding.summarize`: the `Transfer-Encoding` coding list in field
  order, with the final coding, a seen/last `chunked` flag, parameter parsing
  (including quoted values), and rejection of repeated or parameterized
  `chunked`.
- `content_length.Parser`: `Content-Length` accumulation one field line at a
  time for a caller that already has a field view. `parse` remains the slice
  form.
- `Version` and `WireVersion`: the effective version and the exact wire pair,
  exported at the package root and from `h1`.
- `Cursor`: one byte cursor for every parser here, replacing the private
  cursors in `h1`, `prefix_int`, and the Huffman decoder. It is infallible;
  each protocol maps the end of input to its own error.
- `prefix_int.decode`, `prefix_int.encode`, and `prefix_int.encodedLen`:
  RFC 7541 §5.1 integers, shared by HPACK and QPACK. Values are `u32`;
  encodings that need more are `error.InvalidInteger`.
- `huffman.decode` and `huffman.encode`: the RFC 7541 Appendix B code, shared
  by HPACK and QPACK. Decoding rejects EOS and padding that is over seven bits
  or not EOS's prefix.
- `hpack.static_table`: the 61 predefined fields from RFC 7541 Appendix A, as
  `Header` values with static storage.
- `hpack.TableStorage`: the dynamic table's byte arena, slot records, and
  parallel hash array. `init(allocator, max_size)` allocates one chunk for all
  three from a runtime SETTINGS_HEADER_TABLE_SIZE. `initBuffer(memory, max_size)`
  wraps a caller blob and returns `error.BufferTooSmall` when it is too short;
  `TableStorage.Buffer(max_size)` is the blob type.
- `hpack.DynamicTable`: the per-connection table over `TableStorage`, with the
  RFC 7541 §4.1 size accounting, §4.4 eviction, compaction, and
  `find`/`findName` over a contiguous hash array.
- `hpack.static_table.find` and `hpack.static_table.findName`: name and
  name-and-value lookup over a comptime map, instead of a 61-entry scan.
- `hpack.Encoder` and `hpack.Mode`: header block encoding for HTTP/2.
  Incremental indexing is the default, an exact name and value reuse an
  indexed field, and Huffman is chosen only when it is strictly shorter.
  `setMaxSize` follows a SETTINGS change and emits the size update, including
  the minimum-first pair RFC 7541 §4.2 needs after a reduction and a growth.
- `hpack.Decoder`: header block decoding for HTTP/2. Decoded fields are copied
  into a caller-owned buffer, so a field never borrows a dynamic-table entry.
  `decode` returns `Headers`; `decodeFlags` also records the RFC 7541 §6.2.3
  never-indexed flag per field for an intermediary that re-encodes.
- `content_length.parse`: `Content-Length` parsing and duplicate
  combination. Conflicting values, non-digits, and overflow are errors;
  `null` means the field was absent.

### Changed

- `h1.parseRequest`, `h1.parseResponse`, and `h1.parseFieldSection` take a
  `SearchState` instead of a raw `last_len`. The parser records the searched
  length on `error.Incomplete` and clears it after a complete parse.
- The package owns its public types. `Header`, `Method`, `Status`, and
  `h1.Version` no longer alias `std.http`.
- The package depends on `baskingspot/stdx` for `stdx.fmt.atoi`;
  `content_length` parses its digits with it.
