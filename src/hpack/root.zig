//! HPACK header compression, as HTTP/2 uses it (RFC 7541).
//!
//! The pieces are the two tables, a decoder, and an encoder. The static table is the
//! RFC's 61 fixed fields; the dynamic table is the per-connection, per-
//! direction list the encoder and decoder keep in step. `Decoder` owns a
//! dynamic table and turns one complete header block into `Header` values.
//!
//! The primitives the format is built from live outside this namespace
//! because QPACK reuses them: `http.prefix_int` and `http.huffman`.
//!
//! The encoder shares this table. Its default policy indexes every field,
//! reuses an exact pair as an indexed field, and Huffman-codes a string only
//! when that is strictly shorter; `encodeModes` takes a `Mode` per field for
//! the two representations that leave the table alone.

pub const decoder = @import("decoder.zig");
pub const encoder = @import("encoder.zig");
pub const dynamic_table = @import("dynamic_table.zig");
pub const static_table = @import("static_table.zig");

pub const Decoder = decoder.Decoder;
pub const Encoder = encoder.Encoder;
pub const Mode = encoder.Mode;
pub const DynamicTable = dynamic_table.DynamicTable;
pub const TableStorage = @import("TableStorage.zig");

/// The first dynamic index: 62, one past the static table.
pub const first_dynamic = decoder.first_dynamic;

test {
    _ = decoder;
    _ = encoder;
    _ = dynamic_table;
    _ = TableStorage;
    _ = static_table;
}
