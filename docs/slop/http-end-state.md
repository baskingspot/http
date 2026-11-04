# http end state

Primitive wire-protocol kernels for HTTP/1.1, HTTP/2, and HTTP/3: framing and
header compression (HPACK/QPACK), plus the shared field-value parsers.

Sans-I/O is the current contract: no sockets, no TLS, no QUIC transport, no
connection management, no allocator in the parser layer. If an I/O layer ever
exists, it sits above the kernels; the kernels do not learn about sockets.

Namespaces are `http.h1`, `http.h2`, and `http.h3`.

## What is shared

`Header { name, value }` is the one name/value type across all three protocols.
It is also the natural entry type for the HPACK static table (61 entries) and
the QPACK static table (99 entries), which is the strongest argument for
keeping it plain borrowed slices.

The shared contract:

- Ordered. Duplicates are preserved; combining is per-family policy.
- Names are compared case-insensitively on lookup, never normalized in place.
- Both slices are borrowed. What they borrow from differs: the message buffer
  for HTTP/1, a decode buffer for HTTP/2 and HTTP/3, or a dynamic table if the
  decoder is allowed to hand out table references.
- Pseudo-headers are fields whose name starts with `:`. The type does not care.

`Headers` is a borrowed slice view over `[]const Header`. A decoder fills a
caller-owned `[]Header` and reports the count; the same `Headers` helpers then
apply. `Values` iterates every line with a given name, in order.

Protocol differences are validation, not types:

- HTTP/1: obs-fold reject-or-unfold, tchar names, `Transfer-Encoding` framing.
- HTTP/2 and HTTP/3: lowercase names only, pseudo-headers precede regular
  fields, connection-specific fields are forbidden, `cookie` lines concatenate
  with `"; "` before processing.
- `Set-Cookie` never combines, in any protocol.

No `h1.Header` unless a protocol needs metadata the shared type must not
carry. Encoder-side metadata (indexing mode, table index) belongs in a parallel
array or a `HeaderRef` wrapper, not in `Header`.

## Modules

Shared field values, already present or planned:

```
Cursor.zig           the byte read position every parser walks with
header.zig           Header, Headers, Values
ows.zig              SP/HTAB
token_list.zig       #token lists
content_length.zig   Content-Length
encoding.zig         Accept-Encoding
date.zig             IMF-fixdate parse/format (Date, Expires, conditionals)
cookie.zig           request cookie pairs, Set-Cookie attributes
```

Compression, shared by HTTP/2 and HTTP/3:

```
huffman.zig          RFC 7541 Appendix B, also used by QPACK unchanged
prefix_int.zig       HPACK/QPACK prefix integers (not QUIC varints)
hpack/               static table, dynamic table, decoder, encoder
qpack/               static table, dynamic table, decoder, encoder
```

What QPACK actually shares, checked against RFC 9204:

- The Huffman code is reused without modification (§4.1.2).
- The prefix integer *format* is reused (§4.1.1), but QPACK requires decoding
  up to 62 bits, while `prefix_int` returns `u32` for HPACK's 2^32-1 bound.
  Sharing it means a wider or generic decode path, decided when QPACK lands.
- The string literal is H + length + bytes, but QPACK allows an N-bit-prefix
  string starting mid-octet, with N from 2 to 8 (§4.1.2). The Huffman codec is
  shared; the HPACK string reader is not.
- The static table is QPACK's own 99 entries, not HPACK's 61. The comptime
  name-run lookup pattern carries over; the data does not.
- The dynamic table's storage, accounting (name + value + 32), FIFO eviction,
  and compaction carry over. The index space does not: QPACK addresses entries
  by absolute index, Base, and relative index, tracks an insert count, and can
  block a field section until the required insertions arrive. The HPACK table
  and decoder cannot be reused as-is.
- The instruction sets and the encoder/decoder state machines are different.

HPACK and QPACK share the Huffman code and the string-literal shape (H bit +
7-bit length prefix). They do not share tables or state. QUIC varints (2-bit
prefix, 1/2/4/8 bytes) are a different encoding and must not reuse
`prefix_int`.

Protocol kernels:

```
h1/                  request line, status line, field section, chunked coding,
                     trailers, CL/TE framing, connection persistence
h2/                  frame header, typed payloads, SETTINGS, CONTINUATION
                     assembly, error codes, header-list validation
h3/                  QUIC varint, frame header, typed payloads, SETTINGS,
                     header-list validation with QPACK
```

`h1/`'s field-section scanner is written in this repo. It follows
picohttpparser's incremental-read contract (consumed bytes, `last_len`), but
not its C. The hand-written tests pin the cases where the RFC allows a choice;
the pico corpus is not ported yet. hparse 0.2.0 is the reference to benchmark
against, not a conformance oracle: its validation changes at the 16-byte vector
boundary (a short `Bad name` is accepted, a long `Bad name with space` is
rejected), its cursor over-reads the buffer end, and it leaves trailing OWS to
callers.

`h3/` is sequenced last. It needs QUIC varints and QUIC stream delivery, and
neither belongs in this package yet. No work there until a QUIC primitive
exists.

## State

Parsers stay stateless. Two things are stateful and belong to the caller:

- HPACK and QPACK decoders, because the dynamic table spans a connection.
- Header-block assembly, because HTTP/2 CONTINUATION and HTTP/3 stream framing
  deliver one block in pieces.

Recommended shape: a decoder is a struct the caller owns per connection; its
dynamic table buffer and decode output buffer are caller-provided slices sized
from the peer's SETTINGS. Nothing in the decoder allocates.

Open question: whether a decoded field may borrow a dynamic-table entry or must
be copied into the caller's output buffer. Recommendation: copy. It removes a
lifetime hazard (a table eviction invalidating a live field) for a linear copy
of the output, and it makes `Header` mean the same thing on all three protocols.

## Scope boundary

In: frame headers and payloads, header-block compression and decompression,
field-section syntax, chunked coding, request/status lines, framing rules, and
the h2 connection state machine (`h2.Session`): stream state, flow control, and
CONTINUATION assembly.

Out: scheduling, prioritization, application SETTINGS policy, connection reuse,
retries, TLS, QUIC transport, server or middleware types, cookie storage.

Encoders: decode first. The field model is the same either way; encoder
insertion policy and Huffman-vs-literal choices are a separate design.

Cookie jar: a client-side store, not a wire primitive. It needs storage, expiry,
domain/path matching, and a public suffix list. Keep it out of this package
until a client exists that has to keep cookies.
