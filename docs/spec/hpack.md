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
dynamic table is its only state; nothing is allocated. The caller supplies a
byte arena whose length is the SETTINGS_HEADER_TABLE_SIZE this endpoint
advertises, and `arena.len / 32` slots for the entry metadata. An entry costs
at least 32 bytes of accounting, so that is the most entries the table can
hold.

The arena is packed against its high end: new entries copy below the live
ones, and eviction drops the oldest. That leaves gaps that a later insertion
reclaims by compacting, which moves entries. The decoder copies every field
into the caller's buffer, so no caller ever sees a pointer into the arena and
compaction is invisible.

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

- An encoder. Its table is `DynamicTable`; what is missing is the insertion
  policy and how the never-indexed flag travels through re-encoding.
- Header-list validation: lowercase names, pseudo-headers before fields,
  forbidden connection-specific fields, cookie concatenation. Those are
  RFC 9113 §8.2 and §8.3 rules and belong in `h2`, after decoding.
