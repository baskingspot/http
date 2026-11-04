# HTTP/1 writer: shape sketch

First slice implemented 2026-11-04. The sink is a caller-owned
`*std.Io.Writer`; the writer never creates, flushes, or closes one.

## Goal

Encode an HTTP/1 request or response into caller-owned bytes, with the same
constraints as the parsers: no allocator, no `std.Io`, borrowed inputs, and a
strict grammar. A writer that can emit a message the parser rejects is a bug in
the writer, not a caller mistake.

The line syntax is HTTP/1-specific, so the type belongs at `http.h1.Writer`.

## Constraints

- Caller owns the output buffer. `init(buffer)`, `written()` returns the used
  prefix, and a full buffer is `error.NoSpaceLeft`.
- CRLF only. Field names are `tchar`; field values are `field-vchar / SP / HTAB`
  plus obs-text; request targets are printable US-ASCII. These are the parser's
  rules, reused rather than restated.
- `Version` is the effective version; the wire spelling is the tag name
  (`HTTP/1.0`, `HTTP/1.1`).
- `Content-Length` is known in advance or the body uses `Transfer-Encoding:
  chunked`. There is no backpatch: a forward-only writer cannot know a length
  that the caller did not provide, and chunked is the HTTP answer.
- Chunked output follows RFC 9112 §7.1: hex size, extensions, CRLF, data, CRLF,
  last chunk, trailer fields, CRLF. The decoder already defines the accepted
  grammar.

## Shape A: forward-only writer (recommended)

```zig
var buffer: [4096]u8 = undefined;
var w: h1.Writer = .init(&buffer);

try w.statusLine(.@"HTTP/1.1", .ok);
try w.field("Content-Type", "text/plain");
try w.contentLength(5);
try w.endFields();
try w.body("hello");

const bytes = w.written();
```

For a chunked response:

```zig
try w.statusLine(.@"HTTP/1.1", .ok);
try w.chunked();
try w.endFields();
try w.chunk("hello");
try w.chunk(" world");
try w.chunkEnd(&.{.{ .name = "X-Checksum", .value = "abc" }});
```

Primitives:

- `requestLine(method, target, version)` and `requestLineToken(token, target,
  version)` for a method outside the common enum.
- `statusLine(version, status)` uses `Status.phrase()`; a variant takes an
  explicit reason for an unnamed code.
- `field(name, value)`, `endFields()`.
- `contentLength(n)`, `body(bytes)`.
- `chunked()`, `chunk(bytes)`, `chunkEnd(trailers)`.
- `header` entries are borrowed; the writer copies bytes into the output.

The first slice should stop at `requestLine`, `statusLine`, `field`,
`endFields`, `contentLength`, and `body`. Chunked is the second slice; the
io_uring example already has a manual chunked response to replace.

## Shape B: value-tree encoder

```zig
const response: h1.Response = .{
    .version = .@"HTTP/1.1",
    .status = .ok,
    .headers = &headers,
    .body = "hello",
};
const bytes = try h1.encodeResponse(&buffer, response);
```

Pros: computes `Content-Length`, validates duplicate singletons, and is easy to
test. Cons: a body must already be contiguous, a streaming body needs a callback
or a chunk list, and the tree is a second representation of what `Headers`
already is. A chunked tree needs the chunk boundaries, which a single `body`
slice cannot express.

## Recommendation

A is implemented in `src/h1/writer.zig` over `std.Io.Writer`: request and
status lines, fields, `endFields`, `contentLength`, `body`, and
`chunked`/`chunk`/`lastChunk`. The blocking example uses the connection's
writer; the io_uring example uses a fixed buffer writer and sends the bytes.
If the examples later want a `Response` value, B is a thin function over A, not
a second encoder.

## Open questions

- Does `statusLine` use `Status.phrase()` or require the caller to pass the
  reason? Default: use the phrase, and provide an explicit variant.
- Does the writer reject an invalid field name/value, or trust the caller?
  Default: reject. The check shares the parser's tables.
- Do chunk extensions need a public form, or is `chunk(bytes)` enough? Default:
  no extensions until a caller asks; the decoder already ignores them.
- Where does the writer live for HTTP/2 and HTTP/3? They have their own framing;
  keep the writer h1-specific.

## Non-goals

Connection management, header ordering policy, `Date` generation, compression,
TLS, and a server type. The writer emits bytes; the caller owns the connection.
