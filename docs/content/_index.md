+++
title = "http"
+++

HTTP/1.1 and HTTP/2 in Zig: field-value parsers, sans-I/O connection machines, and the engines you build a server or client on.

Zig's `std.http` has an HTTP/1.1 client and server. It has no HTTP/2 and no
HPACK, and its request and response types come with a connection attached, so a
proxy, a test, or a server with its own event loop has nothing to call. This
package is that layer. `h1` and `h2` each hold parsers, a sans-I/O connection
machine, and engines; the parsers take bytes, return borrowed slices, fill
storage you own, and never allocate.

- [Field values](#field-values): `content_length.parse`, `encoding.negotiate`, `token_list.contains`, and `transfer_encoding.summarize` read one field family each, and `Cursor` is the byte position all of them walk.
- [Headers](#headers): `Headers.get`, `values`, and `containsToken` look up a field section in wire order and fold ASCII case, and duplicate lines stay separate.
- [Method and status](#method-and-status): `Method.parse` is case-sensitive, `Status` is an open enum so an unnamed three-digit code is still a value, and `WireVersion` keeps the exact digits.
- [The h1 message](#the-h1-message): `h1.parseRequest` returns borrowed slices or `error.Incomplete`, `h1.framing` picks the body rule, `h1.chunked.Decoder` resumes mid-body, and `h1.Writer` writes the message back out.
- [The h1 connection machine](#the-h1-connection-machine): `h1.ServerConn` and `h1.ClientConn` take the bytes you read and the time you have, and own no memory and no socket.
- [The h1 engines](#the-h1-engines): `h1.engine.blocking.serve` takes one connection at a time, and `h1.engine.poll`, `.epoll`, and `.kqueue` serve fixed slots with deadlines.
- [The h2 session and frames](#the-h2-session-and-frames): `h2.frame.parse` is the frame codec, and `h2.Session` owns SETTINGS, streams, flow control, HPACK, and CONTINUATION assembly.
- [HPACK](#hpack): `hpack.Decoder` and `hpack.Encoder` share the static and dynamic tables, and `prefix_int` and `huffman` are the primitives QPACK reuses.
- [The client contract](#the-client-contract): `client.Request` and `client.Body` are protocol-neutral, and `client.blocking.Client` dispatches to an h1 or an h2 adapter.
- [Running a server](#running-a-server): `engine.Handler(Exchange)` is the one vtable every engine calls, and `http_tls` adds TLS without putting crypto in the core.
- [Performance](#performance): 81 ns against 79 ns on a typical request head, 255 ns against 334 ns on a wide one, and 3.8x on a 1 KiB header value.
- [Limits](#limits): no streaming request bodies, no connection reuse, and the rest of what is not here.

The library is pre-1.0 and the API is not frozen; a consumer pins a version.
The [API reference](api/) documents every public symbol.

# Getting started

## Install

```sh
zig fetch --save https://baskingspot.dev/http/v0.2.0.tar.gz
```

Add the module in `build.zig`:

```zig
const http = b.dependency("http", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("http", http.module("http"));
```

`http` builds with Zig 0.16 and 0.17. The package also exports a second module,
`http_tls`, for the TLS readiness engines; the `http` module itself imports no
TLS and links no crypto library.

## Import it

```zig
const http = @import("http");
```

`std.http` keeps its name, so `http` sits beside it in the same file. There is
no alias to bind.

## Read the examples

`examples/` runs every engine: one HTTP/1.1 server per wait backend, the h2c
and TLS servers, the two clients, and a small curl. `just check-example` builds
all of them in CI, `just example` serves HTTP/1.1 on 127.0.0.1:8080, and
`just example-h2` serves h2c on 8081.

The next chapter to read depends on the job. A parser or a proxy wants
[Field values](#field-values) and [The h1 message](#the-h1-message). A server
wants [Running a server](#running-a-server) and the engine chapter for its
protocol.

# Field values

Each of these reads one field family and allocates nothing. The arguments and
the returned slices are borrowed from the caller.

## Parse Content-Length

`content_length.parse(values)` takes every `Content-Length` field line as text,
in wire order, and returns the one length they agree on, or `null` when the
field is absent. Leading zeros are valid: `"0042"` is 42. Repetition is allowed
only when every value is the same number, so `&.{ "42", "42" }` and
`&.{ "42, 42" }` both give 42, and `&.{ "42", "43" }` is `error.Conflicting`.
A non-digit is `error.Invalid`; a value past `u64` is `error.Overflow`.

`content_length.Parser` feeds one line at a time for a caller that already has
a `Headers` view: `feed`, then `finish`.

```zig
const length = try http.content_length.parse(&.{ "42", "42" }); // ?u64 = 42
```

The module stops at the field value. The rule that `Transfer-Encoding` and
`Content-Length` must not both frame a request belongs to `h1.framing`, because
that is the piece that sees both fields.

## Negotiate a content coding

`encoding.negotiate(header, supported)` reads one `Accept-Encoding` value and
returns a token borrowed from `supported`, the static `encoding.identity`, or
`null` when the client accepts nothing the server can produce. `supported` is
in server preference order and must not contain `identity`, which the module
handles itself.

The rules are RFC 9110 §12.5.3: `q` weights with at most three fractional
digits, `q=0` as a refusal, `*` for every coding not named, and identity
acceptable unless `identity;q=0` or `*;q=0` excludes it. A malformed weight
counts as 0, the first entry for a coding wins, and a tie goes to the server's
order.

`encoding.negotiateFields(fields, supported)` takes every line, because
repeated `Accept-Encoding` lines combine into one ordered list.

```zig
const coding = http.encoding.negotiate("gzip;q=0.5, br;q=1", &.{ "br", "gzip" }); // "br"
```

The caller maps the token to a codec: `deflate` to a zlib decoder, `gzip` to
gzip, `br` to brotli, and `zstd` to zstd. This package ships no compressor.

## Test a token list

`token_list.contains(field, token)` answers whether a comma-separated list such
as `Connection`, `Upgrade`, or `Vary` holds a token.
`token_list.iterator(field)` yields the trimmed elements. Empty elements are
ignored as RFC 9110 §5.6.1 requires, and the comparison folds ASCII case.

```zig
const upgrade = http.token_list.contains("keep-alive, Upgrade", "upgrade"); // true
```

`Headers.containsToken(name, token)` is the same test across every line with
that name, so a duplicated field cannot hide a token.

## Summarize Transfer-Encoding

`transfer_encoding.summarize(headers)` walks the `Transfer-Encoding` lines in
order and returns a `Summary`: `present`, the final `Coding` as `last`, whether
`chunked` appeared as `seen_chunked`, and whether it was last as `chunked_last`.
A `Coding` carries the borrowed token and `has_parameters`, because the
parameters are parsed, quoted values with commas included, even though the
codings themselves are the caller's business.

`chunked` takes no parameters and may appear once. A repeat is
`error.ChunkedDuplicate`, a parameter on it is `error.ChunkedParameters`, and
malformed syntax is `error.Invalid`. A request whose final coding is not
`chunked` is `error.InvalidTransferEncoding` from `h1.framing`, not from here.

## The byte cursor

`Cursor` is the read position every parser in the package walks with: `h1`,
`prefix_int`, the Huffman decoder, and HPACK. `next`, `peek`, `take`, and
`skip` return `null` or `false` at the end of the buffer. `at` and `slice`
assert a bound a scanner has already checked.

The cursor is infallible on purpose. Running out is not an error until a
protocol says it is, so `h1` maps the end to `error.Incomplete` and `hpack`
maps it to `error.Truncated`. A caller writing its own scanner over the same
bytes can share the position instead of keeping a second one.

# Headers

`Header` and `Headers` are the field section both protocols hand back. The
view owns nothing, and every lookup is a scan of a slice you already have.

## A borrowed field line

`Header` is a name and a value, both borrowed from the message buffer. The
parser fills a `[]Header` that the caller owns, so a head is two slices: the
bytes that arrived, and the array describing them.

## Look up a field

`Headers.get(name)` returns the first value with that name. Use it for a field
the RFC defines as a singleton, such as `Host` or `Content-Length`.
`Headers.values(name)` yields every line separately and in wire order, which
`Set-Cookie` needs and which any caller needs to tell one field with a comma
from two fields. `Headers.containsToken` is the list test from the last
chapter.

Lookups trim OWS from the value. `Headers.items` is the raw span, so iterating
it gives you the trailing space back; that is the difference between the view
and the array.

## Combine, or do not

Duplicate lines are preserved, and whether to combine them is the field
family's rule. Each family gets a parser that takes the whole list:
`content_length.parse`, `encoding.negotiateFields`,
`transfer_encoding.summarize`. `Set-Cookie` never combines. h2's `cookie`
lines do not combine either; RFC 9113 §8.2.3 has the caller join them with
`"; "`.

# Method and status

These are the small value types a message carries, and both protocols use
them. The wire form stays authoritative in each.

## Parse a method

`Method` is the conventional nine: `GET`, `HEAD`, `POST`, `PUT`, `DELETE`,
`CONNECT`, `OPTIONS`, `TRACE`, `PATCH`. `Method.token` gives the wire text, and
`Method.parse` is exact, so `parse("get")` is null.

The enum is a convenience, not a registry. Methods are an open set, so an
unlisted token stays a slice and `h1.RequestHead.method_token` always holds the
exact bytes. `safe`, `idempotent`, `cacheable`, `requestHasBody`, and
`responseHasBody` follow RFC 9110 §9.2.

```zig
const method: ?http.Method = http.Method.parse("GET"); // .GET
const lower: ?http.Method = http.Method.parse("get");  // null
```

## Status codes

`Status` is an `enum(u10)` with the named codes as constants and any other
three-digit value still constructible, so a parser can return what the wire
said. `code()` is the number, `text()` the three bytes, `class()` groups 1xx
through 5xx and is null outside 100..599, and `phrase()` is null for a code
with no registered reason.

The class rule is the caller's. RFC 9110 §15 makes 100..599 the meaningful
range; this type does not enforce it, because a proxy has to pass an odd code
through.

## Versions

`Version` is the effective version, `HTTP/1.0` or `HTTP/1.1`. `WireVersion` is
the exact pair of digits. A head carries both, because RFC 9110 §6.2 says to
process a higher minor within major 1 as the highest supported minor:
`HTTP/1.9` is `version = .@"HTTP/1.1"` with
`wire_version = .{ .major = 1, .minor = 9 }`. `version.effective(wire)` does the
mapping and returns `error.UnsupportedVersion` for another major, which a
server answers with a 505.

# The h1 message

Heads, body framing, chunked coding, and the writer are the pieces of one
HTTP/1.1 message. The parser is the part that has to be strict, so it is strict
wherever RFC 9112 allows a choice.

## Parse a head

`h1.parseRequest(buf, &state, storage)` and `h1.parseResponse` return a head
and the number of bytes it consumed. `storage` is your `[]Header`, and the
head's slices borrow `buf` and `storage` both.

`h1.parseFieldSection` parses the same grammar without a start line, so it is
the trailer parser and the entry point for a caller that already split the
head.

```zig
var storage: [32]http.Header = undefined;
var search: http.h1.SearchState = .init;

const parsed = try http.h1.parseRequest(buf, &search, &storage);
const head = parsed.head; // method_token, target, and fields borrow buf and storage
const host = try http.h1.host(head.headers); // null when Host is absent
```

`error.Incomplete` means read more. `error.Invalid` is syntax. A well-formed
version with another major is `error.UnsupportedVersion`.
`error.TooManyHeaders` is separate from all of them, because a full storage
array is not hostile input and a server answers it 431.

A buffered reader may move its bytes when it refills or rebases. Copy the
target, the reason, and any field value that has to outlive the head before the
next read. `method`, `version`, and `wire_version` are plain values and always
survive.

## Resume an incomplete head

`SearchState` carries how much of the buffer has been searched for the head
terminator. Keep one per connection buffer and pass `&state`: on
`error.Incomplete` the parser records the length it searched, and the next call
starts the completeness check four bytes back, so only the new bytes are
scanned. Parsing itself still starts at byte 0. A complete head clears the
state, so one `SearchState` serves every request on a connection, and a client
that trickles one octet at a time cannot force a full rescan per read.

`h1.parseFieldSection` takes the same state and has to find an empty section,
which is a single CRLF with no `CRLF CRLF` behind it.

## Where the parser is strict

Where RFC 9112 permits either behavior, this parser rejects:

- bare LF as a line terminator, which §2.2 permits recognizing
- more than one SP between start-line components, which §3 and §4 permit parsing on whitespace
- obs-fold, which §5.2 permits rejecting or unfolding
- SP or HTAB before the first field, which §2.2 permits rejecting or consuming

It skips leading empty lines before a request line, which §2.2 asks for. A
field name is `tchar` with no space before the colon. A field value is VCHAR,
obs-text, SP, or HTAB: NUL, other CTLs, and DEL are `error.Invalid`. Trailing
OWS is trimmed and HTAB inside a value is kept.

A status code outside 100..599 comes back as a value. What to do about it is
the caller's policy.

## Frame the body

`h1.framing.request(version, headers)` returns a `RequestBody`: `.none`,
`.length`, or `.chunked`. `h1.framing.response` returns a `ResponseBody`, which
adds `.close` for a body delimited by the connection and `.tunnel` for a 2xx
response to CONNECT. Neither reads the body.

The rules are RFC 9112 §6.3, in this order:

- HEAD, 1xx, 204, and 304 have `.none`, whatever the fields say.
- A 2xx response to CONNECT is `.tunnel`. Its `Content-Length` and `Transfer-Encoding` are ignored.
- `Transfer-Encoding` with `Content-Length` is `error.ConflictingFraming`, because the combination is a smuggling signal.
- `Transfer-Encoding` on an HTTP/1.0 message is `error.FaultyFraming`.
- On a request, a final coding other than `chunked` is `error.InvalidTransferEncoding`. On a response it is `.close`.
- A request with no framing field is `.none`. A response with none is `.close`.

A malformed, conflicting, or overflowing `Content-Length` is
`error.InvalidContentLength`.

## Decode a chunked body

`h1.chunked.Decoder.init(trailer_storage)` decodes RFC 9112 §7.1. `next(buf)`
returns a `Step` with `consumed` and one `Event`: `.data` for a borrowed slice,
`.trailers` for the trailer `Headers`, or `.need_more`. `consumed` is the
prefix to drop on every step, `need_more` included, so a caller appends bytes
and retries without copying the body. A data slice may end before its chunk
does, and the decoder remembers the remaining count across calls.

Chunk extensions are parsed and ignored. A size past `u64` is
`error.Overflow`, malformed syntax is `error.Invalid`, and a trailer section
that outgrows your storage is `error.TooManyHeaders`. Which trailer fields may
be merged into the head is RFC 9110 §6.5.1 and the caller's decision.

## Decide keep-alive

`h1.persistent(version, headers)` is RFC 9112 §9.3 in one call. HTTP/1.1
persists by default, HTTP/1.0 persists only with `Connection: keep-alive`, and
`close` wins on either version.

## Classify the target

`h1.targetForm(method, target)` returns `.origin`, `.absolute`, `.authority`,
or `.asterisk` for that method, and null when the bytes fit none of them. It is
syntax only: it does not resolve an authority or normalize a path.
`h1.host(headers)` returns the single `Host` value or `error.DuplicateHost`. A
missing `Host` on an HTTP/1.1 request is the caller's 400.

## Write a message

`h1.Writer.init(&writer)` wraps a caller-owned `*std.Io.Writer` and never
creates, flushes, or closes one. `requestLine` or `statusLine` writes the start
line, `field` and `endFields` the field section, then `contentLength` and
`body`, or `chunked`, `chunk`, and `lastChunk` with trailers.
`requestLineToken` and `statusLineReason` cover a method outside the enum and a
status with no registered reason.

```zig
var buffer: [4096]u8 = undefined;
var out: std.Io.Writer = .fixed(&buffer);
var w: http.h1.Writer = .init(&out);

try w.statusLine(.@"HTTP/1.1", .ok);
try w.field("Content-Type", "text/plain");
try w.contentLength(5);
try w.endFields();
try w.body("hello");
```

The checked calls validate the parser's grammar before writing, so the writer
cannot emit a message this package rejects. The `assume*` variants skip that
work for data from a trusted source. An empty chunk is rejected either way.

# The h1 connection machine

`h1.ServerConn` and `h1.ClientConn` are the two state machines. Both own no
memory, touch no socket, and take the time as an argument, so a blocking
thread, a poll loop, and an io_uring ring drive the same code.

## The server loop

`h1.ServerConn.init(config)` takes the request buffer, the header storage, the
response head buffer, and the limits. Then:

1. Call `recvBuffer` and read into it.
2. Call `received(n, now)`. It returns `.need_more`, `.request_head`, `.request`, `.reject`, or `.closed`.
3. On `.request`, call `respond(options, body)`.
4. Write the slices from `sendSlices`: the head, then the body.
5. Call `sent(n, now)`. `.more` repeats step 4, `.read` means the 100 Continue is written and the request body is next, `.keep_alive` returns to step 1, `.close` ends the connection, and `.close_after_drain` drains the socket before closing.

After `.keep_alive`, call `advance` before the next read. A pipelined request
already in the buffer is parsed there with no syscall, and `sent` restarted the
idle timer. Call `eof` when the peer closes and `tick` when the poll deadline
expires: `tick` covers every phase, and a head, body, or application timeout
queues a 408.

A `.reject` event carries a `Status` and a `RejectReason`. Send it, then close;
`sent` says whether the engine must drain first, so a reset does not throw away
the error response.

## Bound the connection

`Limits` holds `body_bytes` and six timeouts: idle, head, body, write progress,
total, and drain. A zero duration disables that timeout, except
`drain_timeout`, where zero skips the drain and closes. `deadline()` returns
the earliest active deadline, so a poll loop can use it as the wait timeout.

The idle timeout starts at accept and after each keep-alive response. The first
request byte replaces it with the head timeout and starts the total timeout,
which restarts for each request. The write timeout restarts on every `sent`.
Once part of a response is on the wire, an expired deadline closes the
connection instead of queueing a 408.

`min_read_bytes` covers a transport with a minimum read size, such as a TLS
record layer. When an incomplete head or a default-buffered body has less free
room than that, the machine answers 431 for a head and 413 for a body instead
of stalling on a read it cannot place.

## Body storage and early responses

By default the machine buffers the whole request body in the request buffer. A
body past `body_bytes` is 413. A chunked request body is 501 with
`RejectReason.chunked_unsupported`.

When the head is complete and the body is not, `received` returns
`.request_head` with an `h1.ServerConn.Head`, so a caller can refuse or switch
protocols from the head alone. Otherwise it calls `acceptBody(storage)` to name
its own destination, or `bufferBody` to keep the default. Bytes already read
are copied once, and later reads land in the chosen storage.

A HEAD response keeps `Content-Length` and omits the body. A 204 or 304
response omits both. A final 1xx status is `error.InvalidStatus`, because the
machine owns the 100 Continue; an HTTP/1.0 request never gets one.

## Switch protocols

`switchProtocols(options)` queues a 101 and ends HTTP for the connection. The
caller supplies `Connection: Upgrade`, and the machine adds no keep-alive or
close field of its own. After `sent` returns `.switched`, `remainingInput()`
is what was read past the request: it belongs to the next protocol, and the
HTTP parser never sees it.

## The client machine

`h1.ClientConn` is the response side of one request at a time, with the same
ownership rule. You supply the receive buffer, the response field storage, and
the trailer storage, write the request with `h1.Writer`, and drive the machine.

Call `start(method)` first, because HEAD and CONNECT decide the framing. Then
`recvBuffer`, `received`, and `next`: `.response` carries the head and its
framing, `.body` is a borrowed slice valid until the next call, `.done`
completes the response, and `.closed` is a peer that left before any response
bytes. Call `eof` when the peer closes; it distinguishes a clean close from
`error.Incomplete` inside a head or a body.

An interim 1xx head arrives as a `.response` with no body. Call `start` again
to parse the final response from the bytes that remain. Trailers are parsed
into `Config.trailers`, and an empty slice rejects a trailer section.
`Config.body_bytes` caps the bytes handed to the caller, with
`error.BodyTooLarge` returned before the cap is crossed. Leftover bytes after
`.done` are the start of the next response, so `start` does not discard them.

# The h1 engines

An engine owns the transport, the buffers, the accept loop, and the handler
call. `h1.ServerConn` still does the parsing, framing, keep-alive, pipelining,
and policy responses underneath, so an engine is a driver and a policy, not a
second connection machine.

## What an engine takes

`h1.engine.blocking.Config` carries the allocator, the request buffer, the
header storage, the response head buffer, `engine.Config` for the body and
arena limits, and `write_chunk_bytes`. The readiness engines take buffer sizes
instead and allocate the slots in `init`.

Every engine calls the same `engine.Handler(Exchange)` vtable.
[Running a server](#running-a-server) has the handler contract and the
exchange.

## The blocking engine

`h1.engine.blocking.run(io, listener, handler, config)` accepts and serves one
connection at a time, and `serve` drives one stream. `serveIo` is the same loop
over a plaintext `*std.Io.Reader` and `*std.Io.Writer`, which is the seam a TLS
wrapper uses.

Every timeout is zero here, because a blocking syscall cannot enforce one. Use
it for tools, tests, and trusted peers. The accept loop retries
`ConnectionAborted` and `WouldBlock`, sleeps a second on `SystemResources` and
the fd quotas, and returns on anything else.

## The readiness engines

`h1.engine.poll` and `h1.engine.epoll` are Linux. `h1.engine.kqueue` is macOS.
One thread, fixed slots, nonblocking sockets, absolute deadlines, and a stop
descriptor: eventfd on Linux, a pipe on macOS. The type has `init`, `run`,
`stop`, `port`, and `deinit`.

The wait set holds the stop descriptor, the listener while a slot is free, and
every active slot with the interest it needs. `poll` builds a `pollfd` array on
every wait. `epoll` keeps a kernel registration and changes it only when a
slot's interest changes. `kqueue` keeps a read filter and a write filter. After
each wait the engine services the ready slots and expires what `tick` closes.

`Config.max_connections` is the slot table, allocated once in `init`. A request
allocates only when the handler uses the exchange arena. `accept_backoff` is
the pause after `EMFILE`, `ENFILE`, or `SystemResources`, 50 ms by default.
When every slot is busy the listener is not polled, so a new connection waits
in the accept backlog instead of being accepted and closed. The listener sets
`SO_REUSEADDR` and not `SO_REUSEPORT`. `tcp_defer_accept` sets Linux
`TCP_DEFER_ACCEPT`; other platforms ignore it.

`write_chunk_bytes` coalesces a head with the body prefix that fits it and caps
each send at that size. Zero keeps separate head and body slices.
`Limits.drain_timeout` bounds the close-after-drain phase, and `drain_bytes` is
the scratch for it; zero for either skips the phase.

io_uring is not an engine here. `examples/http1_uring.zig` drives
`h1.ServerConn` from a completion loop directly, which is the shape a caller
keeps.

# The h2 session and frames

The h2 side is a frame codec, a field-section validator, the state pieces the
connection needs, and `h2.Session` on top. The same code serves h2c and h2 over
TLS; nothing here reads a socket, a TLS type, or an event loop.

## Parse a frame

`h2.frame.parse(bytes, max_frame_size)` returns the 9-byte `Header`, the
payload, and `consumed`, or `error.Incomplete` until the header and all
`Length` bytes are present. The length is in the header, so there is no rescan
cursor as in HTTP/1. `h2.frame.parseHeader` reads the header alone.

The codec is syntax. An unknown frame type comes back as `Body.unknown` with
the raw payload for the caller to ignore, unused flags stay in `Header.flags`,
and the reserved stream bit is masked off. A payload above `max_frame_size` is
`error.FrameTooLarge` before the payload arrives, a fixed-length payload of the
wrong size is `error.InvalidLength`, and a pad length that covers the whole
payload is `error.InvalidPadding`. Mapping those to `FRAME_SIZE_ERROR` and
`PROTOCOL_ERROR` is the session's job.

`h2.frame.Writer` fills a caller buffer: `begin` reserves the header, `bytes`
and `int` append the payload, and `end` patches the 24-bit length. A short
buffer is `error.NoSpace`, with the partial frame left at `pos`.
`h2.frame.preface` is the client preface.

## Validate a field section

`h2.head.request(fields)` and `h2.head.response(fields)` take the decoded field
list, pseudo-headers included and in wire order, and return a typed head with
the regular fields as a `Headers` view. Every slice is borrowed.

A name is lowercase `tchar`. A value rejects NUL, CR, LF, other controls, DEL,
and edge whitespace, while HTAB inside a value and obs-text are allowed. A
pseudo-header after a regular field is `PseudoAfterField`, a repeat is
`DuplicatePseudo`, and a name this direction does not define is
`UnknownPseudo`. A request needs `:method`, `:scheme`, and `:path` unless it is
CONNECT. RFC 8441 extended CONNECT needs `:protocol` plus all three. `:status`
is exactly three digits.

The connection-specific fields are rejected: `connection`, `keep-alive`,
`proxy-connection`, `transfer-encoding`, `upgrade`, and `te` unless it is
exactly `trailers`. Cookie lines stay separate. A malformed section is a stream
error of type PROTOCOL_ERROR, and `h2.head.Error` carries the reason.

## Settings, flow control, and stream state

`h2.settings.Values` is one direction's SETTINGS with the RFC 9113 §6.5.2
defaults. `apply` validates `ENABLE_PUSH`, `INITIAL_WINDOW_SIZE`, and
`MAX_FRAME_SIZE`, keeps the last value for a repeated identifier, and ignores
an identifier it does not know.

`h2.flow.Window` is signed, because a peer can lower `SETTINGS_INITIAL_WINDOW_SIZE`
below the bytes already sent and the sender then waits for a `WINDOW_UPDATE`.
`consume` accounts DATA, `increase` applies a `WINDOW_UPDATE` (zero is
`error.ZeroIncrement`, above 2^31-1 is `error.FlowControlError`), and
`applyInitialChange` applies a SETTINGS delta to one stream window.

`h2.stream.transition` applies one frame event from one side to a stream state,
so a HEADERS with END_STREAM is `headers` then `end_stream`.
`h2.stream.Ids` allocates local identifiers with the role's parity and accepts
a remote one only when the parity matches and it is above the last seen.
`h2.header_block.Assembler` joins CONTINUATION fragments: a single-frame block
comes back borrowed, a split block is copied into your buffer, a block that
starts while one is open is `error.Interleaved`, and one that outgrows the
buffer is `error.TooLarge`.

## Drive the session

`h2.Session` owns the preface, SETTINGS, the stream table, HPACK, flow control,
CONTINUATION assembly, and the outbound queue. It has no socket, no TLS type,
and no stored allocator.

| Call                                                                                                                             | Purpose                                                                  |
| -------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------ |
| `init(allocator, .{ .role = .client })`                                                                                          | Build the session and queue the client preface and the initial SETTINGS. |
| `receive(bytes)`                                                                                                                 | Append transport bytes and return how many fit.                          |
| `nextEvent(allocator)`                                                                                                           | Parse until one event is ready; null means read more.                    |
| `submitRequest`, `submitResponse`, `submitData`, `submitTrailers`, `submitReset`, `submitSettings`, `submitGoaway`, `submitPing` | Queue frames.                                                            |
| `release(allocator, id, count)`                                                                                                  | Return consumed DATA bytes to both windows.                              |
| `send(out)`                                                                                                                      | Copy queued bytes into the transport buffer.                             |

An event is `request`, `response`, `data`, `trailers`, `reset`,
`window_update`, `settings`, `goaway`, or `connection_error`. A `reset` carries
its `origin`, so a caller can tell its own stream error from a peer reset.
Event slices borrow the input or the decoded field buffer and live until the
next `nextEvent`.

A connection error is an event too: the session queues `GOAWAY`, sets
`isClosed`, and the caller drains `send` and closes. A stream error queues
`RST_STREAM` and arrives as a local `reset`. A malformed HPACK block is
`COMPRESSION_ERROR`, a bad field section is a stream error `PROTOCOL_ERROR`,
and a frame above our `MAX_FRAME_SIZE` is `FRAME_SIZE_ERROR`.

The allocator is per call. Stream records and output chunks come from
`std.heap.MemoryPool`, so a `std.heap.FixedBufferAllocator` gives the whole
connection a fixed ceiling. `max_out_bytes` caps queued output: a header
submission returns `error.WouldBlock` at the cap, `submitData` returns the
prefix that fits, and control frames are never blocked.

Push is not implemented: a received `PUSH_PROMISE` is a connection error
`PROTOCOL_ERROR`. PRIORITY is parsed enough to reject a self-dependency and
then ignored.

## Submit a response

`submitResponse(allocator, id, value, end_stream)` takes
`http.response.Response`, where `status`, `content_type`, and
`content_length` are typed values. `h2.head.validateResponse` checks it, and
`hpack.Encoder.encodeResponse` writes `:status` and `content-length` at the
moment it writes the block. No status or length text is stored anywhere.

`submitData` accepts a prefix of a body, bounded by the stream window, the
connection window, `MAX_FRAME_SIZE`, and `max_out_bytes`, and returns the count
it took. The caller keeps the rest until more room opens.

# HPACK

HPACK is the header compression HTTP/2 uses (RFC 7541). `prefix_int` and
`huffman` sit at the package root rather than inside `hpack`, because QPACK
reuses both.

## The tables

`hpack.static_table` is the 61 fields from RFC 7541 Appendix A, as `Header`
values with static storage. `find` and `findName` answer from a comptime map.
Entries that share a name are adjacent in the RFC's order, so a name lookup
scans only that run.

`hpack.DynamicTable` is the per-connection table with the §4.1 accounting, §4.4
eviction, and compaction. It reads a `hpack.TableStorage`: one blob holding the
byte arena, one 16-byte record per slot, and a parallel `[]u32` of name hashes,
so the scan reads four bytes per slot and the record only on a hash hit.

`TableStorage.init(allocator, max_size)` allocates the blob from a runtime
`SETTINGS_HEADER_TABLE_SIZE`. `TableStorage.initBuffer(memory, max_size)` wraps
memory you own and returns `error.BufferTooSmall` when it is short;
`TableStorage.Buffer(max_size)` names that blob type for a fixed-size server. A
table holds at most `slotCount(max_size)` entries, because an entry costs at
least 32 bytes of accounting.

The storage never grows. `setMaxSize` moves only the logical maximum inside it.
Compaction moves entries, which no caller sees, because every decoded field is
copied into the caller's buffer.

## Decode a block

`hpack.Decoder.init(storage)` takes storage you sized from the table size you
advertise. `decode(block, out, out_bytes)` turns one complete block into
`Headers` copied into your arrays. `decodeFlags` also records the never-indexed
flag per field, for an intermediary that will re-encode the section.

Errors name the failure. `Truncated` is a block that ends inside a
representation, and the decoder is not resumable, because HTTP/2 hands it a
whole assembled block. `InvalidIndex`, `InvalidInteger`, and `InvalidHuffman`
are malformed input. `TableSizeTooLarge` and `TableSizeUpdateNotFirst` are the
two size-update rules. `TooManyHeaders` and `OutputTooSmall` are local limits,
and they end the connection the same as a decode error, because the table can
no longer be kept in step. An application limit on the header list belongs
after `decode`, where a stream can be reset and the connection stays in sync.

## Encode a block

`hpack.Encoder.init(storage)` takes the same `TableStorage`, because the
encoder holds the other side of the table the decoder tracks. `encodedLen(headers)`
is an upper bound that charges every field a literal name and a raw value, so a
buffer that meets it cannot run out and the table is never advanced by bytes
that were not written. `encode` and `encodeModes` write the block, and
`encodeResponse` writes a `http.response.Response` with its typed status and
length.

The default policy indexes every field, turns an exact name-and-value pair
already in a table into an indexed field, uses the first name match otherwise,
and Huffman-codes a string only when that is strictly shorter. `Mode` sets the
policy per field: `.incremental`, `.without_indexing`, or `.never_indexed`.
`Encoder.huffman = false` turns the code off for a caller that would rather
spend bytes than time.

`setMaxSize` follows the peer's `SETTINGS_HEADER_TABLE_SIZE`. It evicts at once
and queues the update for the start of the next block. A reduction followed by
a growth emits the minimum first and the final size second, which is what makes
the peer's table evict the same entries (RFC 7541 §4.2).

## Prefix integers

`prefix_int.decode(cursor, bits)`, `prefix_int.encode(buf, value, bits)`, and
`prefix_int.encodedLen(value, bits)` are the RFC 7541 §5.1 integer, with the
representation's tag bits left to the caller. A value is `u32`, the largest
index or string length a buffer that fits in memory can need. An encoding that
needs more is `error.InvalidInteger`.

A QUIC varint is a different encoding. It does not share this code, and it is
not in this package.

## The Huffman code

`huffman.decode(encoded, out)` and `huffman.encode(src, out)` are the RFC 7541
Appendix B code, with `encodedLen` for sizing. Decoding rejects EOS and padding
that is longer than seven bits or is not EOS's prefix, both as
`error.InvalidHuffman`. Encoding pads with the EOS prefix.

The decoder starts from an 8-bit root table, which covers every lowercase
letter, every digit, and most punctuation in a field value. A longer code falls
through to the canonical scan, which is the rare path; a wider root table lost
to the cache in the measurements.

# The client contract

`http.client` is the protocol-neutral layer. A `Request` in, a `Response` out,
with a body you read in borrowed slices, and one adapter per protocol behind
it.

## One request shape

`client.Request` is an exact `method_token`, a `scheme`, an `authority`, an
origin-form `target`, the regular `headers`, and a `body` of `[]const u8`. h1
sends `authority` as `Host`. h2 sends it as `:authority` and `target` as
`:path`. Names are lowercase for h2, and the request never carries `Host` or a
pseudo-field.

`client.ResponseHead` is a `protocol`, a `Status`, and a `Headers` snapshot the
client owns until the body closes or the next request starts. `client.Config`
holds the allocator, `max_header_bytes` (16 KiB), and `max_headers` (128).

## Read a body

`client.Body` is a vtable with `read` and `close`. `read` returns a `BodyRead`:
`.data` with a borrowed slice, `.eof`, `.reset` with the RST_STREAM code,
`.truncated`, `.protocol`, or `.local` with a `Local` value.

Data is never empty and stays valid until the next operation that advances the
connection, so a caller that keeps bytes across a read must copy them. An h2
slice pins the connection-level flow-control window until the next read or
close, and four 16 KiB slices exhaust the default 65,535-byte window.

`Local` says whether the connection survives. `canceled` and `capacity` keep
it; `out_of_memory` and `unusable` close it. `BodyStep` is the same shape with
`would_block` for an evented client, and a blocking `Body` never returns
`would_block`.

## Dispatch on the protocol

`client.blocking.Client.init(reader, writer, config)` takes a caller-owned
plaintext reader and writer and implements the contract over either protocol.
`config.protocol` is `.h1` or `.h2`, and `config.common` carries the allocator,
`max_header_bytes`, and `max_headers`. `request(value)` returns a
`client.Response`, and `protocol()` reports which adapter ran.

The caller chooses the protocol. ALPN or a cleartext prior-knowledge decision
belongs above this layer, where the connection is opened.

## The h1 adapters

`h1.client.streaming.Client` implements the shared contract over
`h1.ClientConn`, with a streaming response body and a per-response arena for
the head.

`h1.client.blocking.fetch` is the one-request adapter with no allocator and no
connection reuse. It takes an `h1.client.blocking.Request` and a `Config` of
caller-owned buffers, writes HTTP/1.1, adds `Content-Length` when you did not
frame the body, and returns the head, the framing, and a body slice borrowed
from `Config.body_buffer`. A body past that buffer is `error.BodyTooLarge`. A
response with neither `Content-Length` nor chunked coding reads until EOF.

`fetchIo` is the same operation over a plaintext reader and writer, which is
how `examples/http1_tls_client.zig` runs after its handshake.

## The h2 adapter

`h2.client.blocking.Client` speaks h2 and h2c over the same reader and writer
pair. It multiplexes nothing: one request at a time on a connection, with the
body streamed through `client.Body`.

A request body does not have to exist before the request starts. `begin` sends
the head without END_STREAM and returns a `client.BodyWriter`; `response` waits
for the response head whenever the caller is ready.

```zig
const writer = try client.begin(.{
    .method_token = "POST",
    .scheme = .http,
    .authority = "example.com",
    .target = "/chat",
});
try writer.write("first message");
const response = try client.response();
_ = try response.body.read();
try writer.write("second message");
try writer.close();
```

The two directions are independent. A write may block until the peer opens the
flow-control window, and response bytes that arrive during a write are held for
`Body.read`. Flow-control credit for held bytes returns as they are consumed,
so the buffer is bounded by the connection window. `request` is the
static-body convenience over the same two calls.

`goAway()` reports the connection's GOAWAY and `streamId()` the last stream it
opened, so a caller can tell which requests were processed before the boundary
and which are safe to retry. `isConnectionPoisoned()` and `commitState()` say
whether the connection can take another request at all.

# Running a server

The engines differ in transport and agree on the application side: one vtable,
one exchange, one response shape. This chapter is the part you write.

## The handler vtable

`engine.Handler(Exchange)` has four entries. `handle` builds the response and
must call `exchange.respond` before it returns; a handler that returns without
one gets a 500. `complete` runs once, after the last response byte is written
or the connection ends first. `report_error` sees a failure from `handle` or
from the engine. `policy_response` can replace a rejection's status, fields,
and body.

```zig
const engine = http.h1.engine.blocking;

fn handler(self: *App) engine.Handler {
    return .{ .ptr = self, .vtable = &.{
        .handle = handle,
        .complete = engine.Handler.noopComplete,
        .report_error = reportError,
        .policy_response = engine.Handler.defaultPolicyResponse,
    } };
}

fn handle(_: *anyopaque, exchange: *engine.Exchange) anyerror!void {
    try exchange.respond(.{ .status = .ok, .content_type = "text/plain" }, "hello\n");
}
```

`Handler.noopComplete`, `Handler.noopReportError`, and
`Handler.defaultPolicyResponse` fill the hooks you do not need. A stateless
handler passes `ptr = undefined`; a stateful one passes itself and casts it back
inside each function.

`handle` keeps `anyerror!void`, because a vtable function pointer cannot carry
a precise error set. It runs on the engine thread, so a slow handler blocks
every other connection on that thread. There is no deferral hook: the response
has to be built before `handle` returns.

## The exchange and its arena

The h1 `Exchange` carries `id`, the `*h1.ServerConn`, the complete `request`
with its head and body, and an `arena`. The h2 `Exchange` carries `id`, the
`stream_id`, a `request` of a typed head, the whole body, and the trailers, and
its own `arena`. In a streaming h2 engine the body stays empty and
`request_body` is the incremental reader instead. In both, the request lives in engine storage until `complete`,
and the body passed to `respond` must stay valid until the response is written.

`arena` is the engine's allocator for whatever the handler needs to build the
response, from `std.fmt.allocPrint` to a rendered page. The engine resets it to
`Config.arena_retain_bytes` after `complete` returns, so nothing may keep a
pointer into it. A body in handler-owned memory is also fine, as long as it
outlives the response.

## Pick the response

`engine.ResponseOptions` is the response for both protocols: `status`,
`content_type`, `headers`, and `close`. `headers` are the extra regular fields;
the engine adds framing and the protocol's own. `close` makes h1 emit one
`Connection: close` and close after the response. h2's `Exchange.respond`
rejects it as `error.InvalidResponse`, because a stream has no
connection-close meaning.

`RejectReason` is the other half of a rejection: `malformed_head`,
`conflicting_framing`, `chunked_unsupported`, `body_too_large`, and the rest
name the parser or framing category that produced the status, so an application
message does not have to reparse the head.

## The shared limits

`engine.Config` holds the two knobs with the same meaning in every engine.
`body_bytes` (64 KiB) is the largest buffered request body, and
`arena_retain_bytes` (16 KiB) is what the arena keeps after a completion. Each
engine's `Config` adds its buffers and its own settings under `common`, and
`engine.Protocol` is the `.h1` or `.h2` tag for an application that serves both.

An engine buffers one whole request before it calls the handler. That is the
trade for a plain function signature, and it makes `body_bytes` a policy value
rather than a suggestion. h2 keeps one arena per stream, so the worst case is
about `max_streams × body_bytes` of live request memory.

`h2.engine.Config.body_mode` selects `.buffered` (the default) or `.stream`.
`.stream` runs the handler on the request head instead of on the complete body.
The handler then reads the body a chunk at a time and may answer before
END_STREAM. `body_bytes` still caps one request; a peer that sends more gets
RST_STREAM `ENHANCE_YOUR_CALM`, not a larger buffer.

## Stream a request body

Set `body_mode = .stream` on the h2 engine's `Config`. The engine calls the
handler again for each turn: once at the head, once per body chunk, and once
for END_STREAM. Read with `exchange.request_body.next()`. Answer with
`beginResponse`, `write`, and `endResponse`. Park a turn with
`waitForProgress` when there is nothing to read or write yet.

```zig
/// Cross-turn state. A park returns from `handle`, so a local does not
/// survive it; keep the unsent tail and any cursor here, or behind
/// `exchange.context`.
const State = struct { pending: []const u8 = &.{} };

fn handle(state: *State, exchange: *Exchange) anyerror!void {
    while (true) {
        if (state.pending.len == 0) {
            const chunk = exchange.request_body.?.next() catch |err| switch (err) {
                error.Pending => return exchange.waitForProgress(),
                error.Canceled => return,
                error.EndOfStream => {
                    try exchange.beginResponse(.{ .status = .ok });
                    return exchange.endResponse(&.{.{ .name = "grpc-status", .value = "0" }});
                },
                else => return err,
            };
            state.pending = chunk.data;
        }
        if (!exchange.response_started) {
            try exchange.beginResponse(.{ .status = .ok });
        }
        const written = try exchange.write(state.pending);
        if (written == 0) return exchange.waitForProgress();
        state.pending = state.pending[written..];
    }
}
```

The body chunk is valid until the next `next()` call, so finish with it
before advancing: a zero `write` keeps the rest in your own state, never in a
local that the next turn loses. Its flow-control credit returns when the
handler asks for the next chunk, so a handler that stops reading stops the
peer. `write` returns the accepted count and zero when the output budget is
full; a WINDOW_UPDATE calls the handler again. `exchange.context` is an opaque
`?*anyopaque` the engine carries across turns and never reads. Arm
`exchange.setDeadline(ns)` to be called again with `exchange.wake == .expired`
when the time passes; nothing else has to happen on the connection for that to
fire. `resetStream`
is legal at any point. A peer reset makes the next read return
`error.Canceled` and the unread balance returns to the connection window.

## The h2 engines

`h2.engine.blocking.run` and `serve` are the h1 blocking engine's counterpart,
and `serveIo` is the same TLS seam. They are a transport driver around
`h2.engine.Connection`, which owns the session, the fixed slot table, the
per-stream arenas, and the handler: `receive` takes transport bytes, `drive`
delivers events and queues responses, and `send` drains output.
`h2.engine.poll`, `.epoll`, and `.kqueue` are readiness engines over that same
core.

`Config.max_streams` is both the slot count and the session's advertised
`MAX_CONCURRENT_STREAMS`. The readiness `Config` adds optional idle, write,
total, head, and body deadlines, `accept_backoff`, `drain_timeout`, and a
`transport` for the record layer. `requestStop()` sends GOAWAY, stops
accepting, and waits for active streams until `drain_timeout` expires.
`just conformance-run-readiness` runs h2spec strict against it.

## TLS lives in another module

`http` imports no TLS and links no crypto library. TLS is the separate
`http_tls` module in the same package: `http_tls.h2.engine.tls.poll`, `.epoll`,
and `.kqueue` are the h2 readiness engines over `tls_nonblocking` from
`baskingspot/tls`, with the handshake, record buffers, and ALPN inside the
transport. Set `Config.transport`, and nothing below `h2.engine.Connection`
changes.

The blocking engines take a plaintext reader and writer instead.
`examples/http2_tls.zig` runs `tls_std`'s blocking handshake with ALPN `h2` and
hands the wrapper's reader and writer to `h2.engine.blocking.serveIo`.
`examples/http1_tls.zig` and `examples/http1_tls_client.zig` do the same around
the h1 engine and `h1.client.blocking.fetchIo`. `just conformance-run-tls` and
`just interop-tls` run those pairs.

## The examples

`examples/` has one program per engine and protocol: `http1_server.zig`,
`http1_poll.zig`, `http1_epoll.zig`, `http1_kqueue.zig`, `http1_uring.zig`,
`http2_server.zig`, `http2_readiness.zig`, `http2_tls.zig`,
`http2_tls_readiness.zig`, `http_unified_server.zig`, `curl.zig`, and the two
clients. `just check-example` builds every one of them.

`just example` serves HTTP/1.1 on 127.0.0.1:8080, `just example-h2` serves h2c
on 8081, and `just example-unified` puts HTTP/1.1 and HTTP/2 on one TLS listener
with ALPN and on one cleartext listener that sniffs the preface.

# Performance

These are head-parser numbers, `ReleaseFast` on Linux aarch64, against hparse
0.2.0 on identical buffers. hparse is a head-only parser with no body, no
framing, no chunked coding, and no connection state, so the comparison is the
scanner against the scanner.

| Input                     | http   | hparse 0.2.0 | Result      |
| ------------------------- | ------ | ------------ | ----------- |
| Typical request, 5 fields | 81 ns  | 79 ns        | parity      |
| Wide request, 14 fields   | 255 ns | 334 ns       | 24% faster  |
| Response, 4 fields        | 78 ns  | 78 ns        | parity      |
| 1 KiB header value        | 85 ns  | 320 ns       | 3.8x faster |

Two of the four rows are parity. hparse is 2 ns faster on the shortest head,
and the response head is a tie. The advantage arrives with the field count and
the value length: 24% on the wide head and 3.8 times on the 1 KiB value.

`bench/h1_bench.zig` and `bench/hparse_bench.zig` carry the same buffers, and
`just bench -- --filter=Request` runs both sides of every row.

## Where the time goes

Three changes produced the long-value row. `scanTarget` and `scanLine` are one
vector pass that finds the delimiter and rejects an invalid byte in the same
load, where the old code searched and then validated. `scanToken` is one scalar
pass, because tokens are short in practice and the call into std's vector
search cost more than the table lookups it replaced. The unused byte-set
helpers went away, and the scanner tests drive the real scanners over every
byte value at every position.

The short heads are hparse's. It dispatches four method bytes at a time and
scans a field name more loosely than this parser will. The looseness is not
worth copying, and a known-method fast path measured 1 to 2 ns of a 100 ns
request.

HPACK was measured the same way: `hpack.static_table.findName` is 4.4 ns
against 11.1 ns for the 61-entry scan it replaced, and `find` is 5.7 ns against
34.4 ns. `just bench -- --filter=Hpack` runs those rows.

## Run the numbers

`just bench` builds the suite at `ReleaseFast` and runs every row.
`just bench-smoke` runs each one once to prove the suite builds. A number from
another machine will differ, so compare the two rows of a pair rather than the
absolute value against this table.

# Limits

Not implemented:

- Streaming request bodies on h1. `h1.ServerConn` has no incremental body delivery, and `h1.client.streaming` sends `Request.body` in one call. The h2 client and server do stream: `h2.client.blocking.Client.begin` and `body_mode = .stream`.
- A streaming request body through `client.blocking.Client`. The protocol-neutral facade has no `begin`; use the h2 adapter when the body does not exist up front.
- Chunked request bodies on the server. `h1.ServerConn` answers 501 with `RejectReason.chunked_unsupported`; `h1.chunked.Decoder` is there for a caller that drives the body itself.
- Response trailers on the client. `h1.ClientConn` parses them into `Config.trailers`, and `client.ResponseHead` has no trailer list, so the adapters that sit above it drop the fields.
- Connection reuse and pooling. `h1.client.blocking.fetch` reads one response and does not reuse the connection, and nothing in `http.client` pools connections. `h2.client.blocking.Client` keeps the one connection it was given.
- Redirects. A 3xx comes back as a `client.Response` with its `Status`; nothing follows it.
- Cookies. `Headers` never combines `Set-Cookie`, h2 `cookie` lines stay separate, and there is no jar.
- Routing. `h1.targetForm` classifies the target and stops. There is no router, no path parameter, and no method dispatch.
- Middleware. `engine.Handler` is one vtable with four entries, and there is no chain, interceptor, or deferral hook.
- HTTP/3. There is no `h3` namespace, no QPACK, and no QUIC varint. `prefix_int` and `huffman` are shaped for reuse; the rest does not exist.
- Server push. A received `PUSH_PROMISE` is a connection error `PROTOCOL_ERROR`.
- Priority scheduling. PRIORITY is parsed, checked for a self-dependency, and otherwise ignored.
- TLS inside `http`. Import `http_tls` for the h2 readiness engines, or hand a plaintext reader and writer to `serveIo`.
- io_uring. There is no engine for it. `examples/http1_uring.zig` drives the machine from a completion loop.
