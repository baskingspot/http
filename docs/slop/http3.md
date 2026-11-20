# HTTP/3 and QPACK: scope

Status: 2026-11-19. This note fixes the layers and the order of work. It does
not freeze an API. `docs/slop/http-end-state.md` already fixed the namespace,
the shared field model, and the QPACK boundary.

## What exists

`baskingspot/quic` is RFC 9000 and RFC 9001: packet and frame codecs, transport
parameters, streams, loss recovery, and a TLS driver. It has no HTTP.

`http` is h1 and h2, with HPACK, `huffman`, `prefix_int`, the h2 session, and
the engines. `http.varint` is the QUIC integer (RFC 9000 §16), and
`http.h3.frame` is the frame codec and per-stream reader, `http.h3.head`
validates request and response heads, and `http.qpack` is the static and
dynamic tables, both instruction streams, the field-section decoder, and a
static-only encoder. The h3 control stream and session are next.

## Where h3 lives

`http.h3`, next to `h1` and `h2`.

The core h3 layer has no `quic` dependency. Frames, QPACK, the control stream,
and the session take bytes on a numbered stream and give back bytes for a
numbered stream. The driver that pumps `quic.io` into the session is
`http.h3.engine.quic`, part of the `http` module, not a sub-module.

The driver waits for `baskingspot/tls` to stop using libcrypto. Matt is removing
that dependency. When it lands, `http_tls` folds into `http` as well, and no
sub-module remains. Do not add `http_quic`.

The one duplication is `http.varint` and `quic.varint` implementing RFC 9000
§16. It is about forty lines with no state. A dependency on an incubating
package for one integer codec is worse. If a third package needs the codec, it
moves to `stdx`.

## Layers

The order is bottom up. Each row owns its tests.

| Layer | Module | Contract | RFC |
| --- | --- | --- | --- |
| 1 | `http.varint` | QUIC integer over `Cursor` and a caller buffer | 9000 §16 |
| 2 | `http.h3.frame` | frame header and typed payload, stream reader, writer | 9114 §7 |
| 3 | `http.qpack` | static table, dynamic table, field-section decoder, encoder, both instruction streams | 9204 |
| 4 | `http.h3.settings` | setting ids, values, reserved HTTP/2 ids | 9114 §7.2.4, 9204 §5 |
| 5 | `http.h3.error_code` | `H3_*` and `QPACK_*` codes | 9114 §8.1, 9204 §6 |
| 6 | `http.h3.head` | request, response, and trailer validation | 9114 §4.2–4.4 |
| 7 | `http.h3.control` | unidirectional stream type, control stream state, QPACK stream ownership | 9114 §6.2 |
| 8 | `http.h3.Session` | one connection: streams, heads, data, GOAWAY, resets | 9114 §4–7 |
| 9 | `http.h3.engine.quic` | driver over `quic.io`: ALPN `h3`, byte pumps, stream lifecycle | 9114 §3 |

## Framing

An HTTP/3 frame is a type varint, a length varint, and the payload. There is no
flags octet, no padding bit, and no reserved bit (RFC 9114 §7.1). Neither varint
must use the shortest encoding. The length must match the payload bytes exactly
(RFC 9114 §10.8).

Payload lengths are not trusted. `frame.readHeader` returns the type and the
length without waiting for the payload, and the caller decides what to do with
the length:

- DATA payload is passed through in chunks. It has no size bound and never goes
  into an assembly buffer.
- HEADERS payload is assembled up to a caller byte cap on the compressed
  block. Beyond it the caller's error policy applies; `H3_EXCESSIVE_LOAD` is
  the usual choice. The decoded field section is checked separately against
  `SETTINGS_MAX_FIELD_SECTION_SIZE` (RFC 9114 §4.2.2).
- Control frames are small and bounded by their own syntax.

The writer is simpler than h2's. The payload length is known before the frame
is written, because a HEADERS block is encoded first and a DATA frame is a
caller-sized chunk. `frame.write(buf, frame_type, payload)` emits the type, the
length, and the payload in one call. No length patch, no start/end pair. A
caller that already holds the payload uses `frame.writeHeader` and appends the
bytes itself.

The reserved HTTP/2 frame types (0x02, 0x06, 0x08, 0x09) are never valid in
HTTP/3. Receipt is `H3_FRAME_UNEXPECTED` on every stream. A known frame type on
a stream that does not permit it is also `H3_FRAME_UNEXPECTED` (RFC 9114 §7,
Table 1). Unknown extension frame types are ignored on every stream, including
the control stream. The one exception is position: an unknown frame does not
satisfy the SETTINGS-first rule (RFC 9114 §9).

There is no END_STREAM flag. The QUIC FIN ends the message, and a FIN in the
middle of a frame is `H3_FRAME_ERROR` (RFC 9114 §7.1).

SETTINGS go on the control stream and are never acknowledged. A peer's SETTINGS
can arrive after the first request, so the session starts from the defaults
(RFC 9114 §7.2.4.2). The control stream is critical: closing it is
`H3_CLOSED_CRITICAL_STREAM`.

## QPACK

The decoder is complete. A peer may use the dynamic table, so the decoder parses
encoder instructions, resolves absolute, relative, and post-base indices, and
holds a field section until its required insertions arrive.

The encoder is static-only. It emits indexed and literal representations
from the 99-entry static table and never sends an encoder instruction.
RFC 9204 §4.2 lets an endpoint skip the encoder stream when the encoder does not
use the dynamic table, so a static-only encoder opens no encoder stream and
cannot block. The dynamic encoder needs per-stream reference tracking to evict
safely. It comes after an end-to-end session works.

Shared primitives:

- `huffman` is reused unchanged (RFC 9204 §4.1.2).
- `prefix_int` decodes to `u32` for HPACK. QPACK must decode to 62 bits
  (RFC 9204 §4.1.1), so `prefix_int` gets a wide entry point. The `u32` path
  stays, because HPACK's contract does not change.
- The static table is QPACK's own 99 entries. The comptime name-run lookup
  carries over; the data does not.
- The dynamic table carries the storage, the `name + value + 32` accounting,
  and FIFO eviction. The index space is new: absolute index, insert count,
  dropped count, Base, relative index, and post-base index.

### Blocked sections

A field section that references an insertion the decoder has not received is
blocked. The decoder parses the section prefix first, which carries the
Required Insert Count and the Delta Base. If the insert count is behind, the
decoder returns `blocked` with the required count and changes no table state.
It holds the compressed block and retries when the encoder stream advances the
count.

The block is bounded twice: by the caller's `SETTINGS_QPACK_BLOCKED_STREAMS`
and by a byte ceiling on the held sections. A section that exceeds either is
`QPACK_DECOMPRESSION_FAILED`. A retry is FIFO over the held sections.

The decoder emits a Section Acknowledgment on the decoder stream for every
section it decodes with a non-zero Required Insert Count, and a Stream
Cancellation when the request stream is reset. Both are instructions, not
frames, and the session queues them on the decoder stream.

### Instruction streams

Encoder instructions are `Set Dynamic Table Capacity`, `Insert With Name
Reference`, `Insert With Literal Name`, and `Duplicate` (RFC 9204 §4.3).
Decoder instructions are `Section Acknowledgment`, `Stream Cancellation`, and
`Insert Count Increment` (§4.4). They are not framed. A parser takes a `Cursor`
by value, parses one instruction, and commits the position only when the whole
instruction is present. A truncated instruction consumes nothing.

The instruction stream parser is not the frame parser with a different header.
The bytes have no length prefix, so the only way to find the end of an
instruction is to parse it.

## Field sections

The h3 rules differ from h2 in three places:

- A request whose scheme requires an authority must carry `:authority` or
  `Host`, and both must match when both are present (RFC 9114 §4.3.1). h2 does
  not check `Host`.
- CONNECT omits `:scheme` and `:path` and requires `:authority` (§4.4), as in
  h2. Extended CONNECT adds `:protocol` and the three fields, as RFC 9220
  defines for both versions.
- Connection-specific fields are forbidden and `TE` may only be `trailers`
  (§4.2), as in h2.

The field-name and field-value syntax, the pseudo-header ordering, and the
forbidden-field list are the same code. They live in `field_section.zig`, and
each version owns its request rules. The h2 tests are the regression check.

## The QUIC seam

`h3.Session` never opens a stream and never owns a socket. The binding opens
the streams and pumps bytes.

The binding opens the unidirectional streams at startup and hands each one to
the session with its kind:

```zig
session.attach(control_id, .control);   // session queues 0x00 and SETTINGS
session.attach(encoder_id, .encoder);   // session queues 0x02
session.attach(decoder_id, .decoder);   // session queues 0x03
```

A static-only encoder skips the encoder stream. The decoder stream is needed
when the advertised QPACK capacity is above zero.

Inbound:

```zig
const consumed = session.receive(stream_id, bytes, fin);
session.reset(stream_id, error_code);
```

`receive` consumes a prefix of the bytes and returns the count, as h2's
`receive` does. The binding compacts its QUIC receive ring by that count. No
stream data is copied unless a frame must be assembled. DATA is borrowed and
passed to `nextEvent`; the slice is valid until the next `receive`, because the
caller owns the bytes that carried it. A decoded head borrows the session's
decode buffer until the event is released, as in `h2.Session`.

Outbound:

```zig
while (session.nextWrite()) |write| {
    // write.stream_id, write.bytes, write.fin
    send(write.stream_id, write.bytes, write.fin);
    session.release(write);
}
```

A write is a borrowed slice tagged with the QUIC stream id. The binding copies
it into the stream's send buffer. Control, QPACK, and request writes all use the
same queue, so one loop drains everything.

Events:

```zig
while (try session.nextEvent(allocator)) |event| { ... }
```

`request`, `response`, `data`, `trailers`, `reset`, `goaway`, `settings`, and
`connection_error`, mirroring `h2.Session`. An interim 1xx response is a
`response` event and the final response follows it. Two h3 additions:

- `stream_error` carries a per-stream code the binding applies with RESET_STREAM
  and STOP_SENDING.
- `discard_stream` tells the binding to stop reading an unknown unidirectional
  stream type (RFC 9114 §6.2).

Its own errors map to RFC 9114 §8.1 codes. QUIC closes the connection with one
code and resets a stream with another. The binding passes each through
unchanged.

Stream ids are u62. The low two bits tell client-initiated from
server-initiated and bidirectional from unidirectional (RFC 9000 §2.1). That is
three lines and it keeps the binding from passing redundant data.

## Scope cuts

- Server push: no. A client never sends MAX_PUSH_ID, so the push ID space stays
  unset and the client rejects a push stream or a PUSH_PROMISE with
  `H3_ID_ERROR`. A server ignores a MAX_PUSH_ID from the client because it never
  pushes, rejects PUSH_PROMISE with `H3_FRAME_UNEXPECTED`, and rejects a
  client-initiated push stream with `H3_STREAM_CREATION_ERROR`. A MAX_PUSH_ID
  from a server is `H3_FRAME_UNEXPECTED`. CANCEL_PUSH is `H3_ID_ERROR` because
  no promise exists.
- Priorities (RFC 9218): no. PRIORITY_UPDATE is an extension frame. An
  implementation that does not know the extension ignores it, as RFC 9114 §9
  requires. No priority state is kept.
- Datagrams (RFC 9221): no.
- 0-RTT: no. QUIC owns replay, and the h3 settings a client must remember are a
  later concern.
- CONNECT tunnels: validation only. The session carries the data frames; proxy
  behavior is the application's.

QUIC owns flow control, retransmission, timers, and congestion. h3 has none of
them.

## Order and gates

| Step | Work | Done when |
| --- | --- | --- |
| 1 | `varint` | RFC 9000 Table 4 and Appendix A.1 pass; fuzz target |
| 2 | `h3.frame` reader and writer | split headers and payloads round-trip; reserved types reject; fuzz target |
| 3 | QPACK tables and instruction streams | RFC 9204 Appendix B encoder and decoder streams parse; truncation consumes nothing |
| 4 | QPACK decoder | Appendix B field sections decode; a blocked section reports its count and holds no state |
| 5 | QPACK static-only encoder | our decoder and the Go fixture read every block |
| 6 | `h3.head` and shared field syntax | h2 tests stay green; h3 `Host`/`:authority` cases pass |
| 7 | settings, error codes, control stream | second control stream, closed critical stream, and missing SETTINGS all fail with the right code |
| 8 | `h3.Session` | in-memory client and server sessions exchange a request, a response, trailers, a reset, and GOAWAY |
| 9 | `h3.engine.quic` driver and example | `curl --http3` gets 200 on loopback; `http` still builds without `quic` before the driver lands |
| 10 | dynamic QPACK encoder | blocked encoder tests and interop pass |

Steps 1 through 6 are done as of 2026-11-19. Steps 2 and 3 were independent
after step 1. Step 8 needs 2, 4, 5, 6, and 7. Step 9 needs 8 and the QUIC
driver.

## Testing

- RFC 9204 Appendix B is the conformance set: encoder stream, decoder stream,
  request examples, duplicate, and dynamic table.
- A second implementation produces the interop fixture, as `golang.org/x/net/
  http2/hpack` does for HPACK. `github.com/quic-go/qpack` is the candidate. Check
  that its API exposes the encoder-stream bytes before fixing the fixture shape.
  The fixture lives in `tests/qpack-interop.txtar` and is generated by
  `tools/qpack-interop`. It is not built yet. The decoder is covered by RFC 9204
  Appendix B; the static-only encoder currently round-trips through our decoder
  only.
- The dev shell has `curl` 8.23 with ngtcp2 and nghttp3. `curl --http3` against
  the example server is the end-to-end check at step 9.
- `h3spec` is not installed. It tests a QUIC server and needs step 9. Add it to
  the dev shell then, or run it from a container.
- Every parser with a loop gets a fuzz target, seeded from the RFC vectors and
  the interop fixture.

## Open decisions

1. QPACK encoder: static-only first, dynamic after the session works. The
   decoder is complete from the start. This is the split above.
2. Push, priorities, datagrams, and 0-RTT: out of scope, as listed.

Defaults are in this note. Change them before step 3 if any is wrong.
