//! HPACK header compression, as HTTP/2 uses it (RFC 7541).
//!
//! The pieces are the two tables and the decoder. The static table is the
//! RFC's 61 fixed fields; the dynamic table is the per-connection, per-
//! direction list the encoder and decoder keep in step. `Decoder` owns a
//! dynamic table and turns one complete header block into `Header` values.
//!
//! The primitives the format is built from live outside this namespace
//! because QPACK reuses them: `http.prefix_int` and `http.huffman`.
//!
//! An encoder is not here yet. Its table is this one; what is missing is the
//! insertion policy (which fields to index, when to Huffman) and the decision
//! of how to carry the §6.2.3 never-indexed flag through re-encoding.

pub const decoder = @import("decoder.zig");
pub const dynamic_table = @import("dynamic_table.zig");
pub const static_table = @import("static_table.zig");

pub const Decoder = decoder.Decoder;
pub const DynamicTable = dynamic_table.DynamicTable;
pub const Slot = dynamic_table.Slot;

/// The first dynamic index: 62, one past the static table.
pub const first_dynamic = decoder.first_dynamic;

test {
    _ = decoder;
    _ = dynamic_table;
    _ = static_table;
}
