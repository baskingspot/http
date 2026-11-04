# HPACK: references and choices

The static table and the Huffman code come from the RFC text, not from another
implementation. `src/hpack/static_table.zig` transcribes Appendix A, and the
Huffman table in `src/huffman.zig` was generated from Appendix B and checked
three ways: each row's bit string matches its hex value, the code is canonical
(symbols of one length hold consecutive values), and it is prefix-free. The
Appendix C examples are the conformance tests, including the response
sequences that force eviction at a 256-byte table size.

The namespace split follows what HTTP/2 and HTTP/3 share. `prefix_int` and
`huffman` sit at the crate root because QPACK reuses both; `hpack` holds the
tables and the decoder.

## Normative references

- [RFC 7541](https://www.rfc-editor.org/rfc/rfc7541): HPACK. §2.3 index
  spaces, §2.3.1 static table, §2.3.2 dynamic table, §2.3.3 index address
  space, §4.1 size accounting, §4.2 maximum size changes, §4.3 eviction on a
  size change, §4.4 eviction on insert, §5.1 integers, §5.2 string literals,
  §6.1 indexed field, §6.2.1 incremental indexing, §6.2.2 without indexing,
  §6.2.3 never indexed, §6.3 dynamic table size update, Appendix A, Appendix
  B, Appendix C.
- [RFC 9113](https://www.rfc-editor.org/rfc/rfc9113): HTTP/2. §4.3 header
  block state, §6.5.2 SETTINGS_HEADER_TABLE_SIZE and the 4,096-byte initial
  size, §8.2 field validity, §8.2.2 connection-specific fields, §8.2.3
  cookie concatenation, §8.3.1 and §8.3.2 pseudo-header fields. Those field
  rules belong to `h2`, not to this decoder.
- [RFC 9204](https://www.rfc-editor.org/rfc/rfc9204): QPACK reuses the
  Appendix B Huffman code unchanged, which is why it is not inside `hpack`.

## Choices where the RFC permits more than one behavior

| Subject | RFC | Choice |
| --- | --- | --- |
| Integer width | 7541 §5.1 (limits are an implementation choice) | `u32`, the largest index or string length a buffer that fits in memory can need. Larger values are `error.InvalidInteger`. |
| Non-minimal integer encodings | 7541 §5.1 | Accepted. Continuation octets with a zero payload are still a value until the count would overflow 32 bits. |
| Huffman EOS | 7541 §5.2 (MUST error) | `error.InvalidHuffman`. |
| Huffman padding over seven bits, or not EOS's prefix | 7541 §5.2 (MUST error) | `error.InvalidHuffman`. |
| Decoded field storage | 7541 §4.4 note on evicted names | Copied into the caller's buffer. A field never borrows a dynamic-table entry, so an eviction cannot invalidate a live field. |
| Never-indexed flag | 7541 §6.2.3 (intermediaries MUST preserve) | `decodeFlags` writes one flag per field. `decode` drops it; an endpoint does not need it. |
| Dynamic table size update after a field | 7541 §4.2 | `error.TableSizeUpdateNotFirst`. |
| Any number of size updates before the first field | 7541 §4.2 | Accepted; the last one wins. Returning to a lower size first is legal. |
| Size update above the advertised table size | 7541 §6.3, 9113 §6.5.2 | `error.TableSizeTooLarge`. The arena's length is the advertised size. |
| Entry larger than the maximum size | 7541 §4.4 (not an error) | The table empties and the entry is dropped. |
| Block ends inside a representation | — | `error.Truncated`, not a resumable `Incomplete`: HTTP/2 assembles the whole block first. |
| Caller's field or byte storage exhausted | — | `error.TooManyHeaders` or `error.OutputTooSmall`, and both end the connection like a decoding error, because the table can no longer be kept in step. |

## State

The decoder is one struct the caller owns per connection and direction. The
dynamic table is its only state; the decoder allocates nothing. The table reads
a `TableStorage`: a byte arena, one 16-byte record per slot, and a parallel
`[]u32` of name hashes. `TableStorage.init(allocator, max_size)` allocates one
chunk for all three, sized from the SETTINGS_HEADER_TABLE_SIZE this endpoint
advertises. `initBuffer(memory, max_size)` wraps a caller's opaque blob for a
stack or fixed-size server; `TableStorage.Buffer(max_size)` names that blob
type. A blob shorter than `bytesNeeded(max_size)` is `error.BufferTooSmall`,
and a maximum beyond `u32` is `error.TooLarge`. The storage
never grows after init; `setMaxSize` changes only the logical maximum inside it.
An entry costs at least 32 bytes of accounting, so the table can hold at most
`arena.len / 32` entries.

The arena is packed against its high end: new entries copy below the live
ones, and eviction drops the oldest. That leaves gaps that a later insertion
reclaims by compacting, which moves entries. The decoder copies every field
into the caller's buffer, so no caller ever sees a pointer into the arena and
compaction is invisible.

## Lookups

The static table has a fixed key set, so its name lookup is a comptime-built
`stdx.bounded_array_hash_map.String`. Entries that share a name are adjacent in
the RFC's order, so the map stores one run per name and an exact lookup scans
only that run: two entries for `:method`, at most seven for `:status`. The
dynamic table cannot use a map keyed by slice, because compaction moves the
name bytes. Its hashes are a separate `[]u32`, so the scan reads four bytes per
slot; the records stay 16-byte entries and are read once, on a hash match. Below
32 entries a scalar pass over the hashes beats `findScalar` setup; above it, the
vectorized `mem.findScalarPos` runs.

On the nine names of the request benchmark, a static `findName` is 4.4 ns
against 11.1 ns for the 61-entry scan it replaced, and a `find` is 5.7 ns
against 34.4 ns (`just bench -- --filter=Hpack`). Encoding the nine-field
request with a warm table and a checksummed output is about 180 ns; reverting the
static lookup to its scan gives 320 ns. The dynamic split pays at size: a warm
128-field encode is about 3.4 us, against 6.2 us when the hash shared the
20-byte record. At nine fields the separate arrays cost a little locality,
about 180 ns against 157 ns for the shared record; the threshold keeps the
scalar path below 32 entries.

The hasher was measured too, over the same nine names: Wyhash (what
`std.hash_map.StringContext` uses) is 40 ns for the nine, XxHash64 59,
RapidHash 64, XxHash3 67. Wyhash stays.

`stdx.static_map` and `stdx.prefix_map` were considered. `static_map` wraps the
same `bounded_array_hash_map.Custom` built at comptime, so it is the same
machine with a nicer literal API; it rejects duplicate keys, which is exactly
why this table stores a run per name. `prefix_map` is a radix tree, which pays
per byte and earns its place for longest-prefix queries, not equality on 61
short names.

For the static table, a struct of arrays was not needed: the comptime map
answers in one probe, and a SIMD scan over 61 slice descriptors would still read
all 61. For the dynamic table, the table can reach 128 entries, so the hash
array is worth splitting out and scanning with vectors.

## Huffman codec

The decoder uses an 8-bit root table; codes of nine bits or more fall through
to the canonical scan. That covers every lowercase letter, digit, and most
punctuation in a field value, so the scan is the rare path.

On a 55-byte user agent the encoder is 72 ns (1.3 ns/byte) and the decoder
166 ns (3.0 ns/byte); an 84-byte cookie is 105 ns and 262 ns. A 10-bit root
(2 KiB) decoded 178 ns and 284 ns, and a 12-bit root (8 KiB) 181 ns and 283 ns,
so the larger tables lose to cache. Filling the bit buffer eight bytes at a
time, and `noalias` plus inlined bit operations, measured neutral. The 8-bit
root stays; the remaining cost is the serial one-symbol-per-iteration loop, and
a decoder that emits several symbols per lookup needs a table big enough to
lose the same cache trade.

## Encoding

`Encoder` writes a block into caller storage. `encodedLen` is the upper bound:
it charges every field a literal name and a raw value, the largest a field can
be, so a block that passes the bound cannot run out and the dynamic table is
never advanced by bytes that were not written.

The default policy indexes every field, turns an exact name-and-value pair
already in either table into an indexed field, uses the first static or dynamic
name match otherwise, and Huffman-codes a string only when that is strictly
shorter. A caller sets a `Mode` per field to opt out (`without_indexing`,
`never_indexed`), and can turn Huffman off on the encoder.

`setMaxSize` mirrors the peer's SETTINGS_HEADER_TABLE_SIZE. It evicts at once
and queues the update for the start of the next block. A reduction followed by
a growth emits the minimum first and the final size second, which is what makes
the peer's table evict the same entries (§4.2).

The encoder does not reproduce `golang.org/x/net/http2/hpack` byte for byte on
one point: for a name-only match in the static table, Go picks the last entry
with that name (`:path` 5) and this encoder picks the first (`:path` 4). Both
are one-byte indices; the fixture is a decode interop, not an encoder oracle.

## Interop fixture

`tests/hpack-interop.txtar` holds six blocks from
`golang.org/x/net/http2/hpack` v0.58.0 on one connection, with the field list
each block decodes to. `just fixture` regenerates it through
`tools/hpack-interop`, whose `go.mod` and `go.sum` pin the encoder. The archive
and the generator are dev-only:
`build.zig.zon` lists only `src`, so neither ships. RFC 7541 Appendix C remains
the conformance set; this fixture catches encoder behavior the RFC examples do
not, such as a Sensitive field, long literals, and table size updates.

## Not here

- Header-list validation: lowercase names, pseudo-headers before fields,
  forbidden connection-specific fields, cookie concatenation. Those are
  RFC 9113 §8.2 and §8.3 rules and belong in `h2`, after decoding.
