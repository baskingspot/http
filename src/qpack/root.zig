//! QPACK field compression for HTTP/3 (RFC 9204).
//!
//! The pieces are the static table, the dynamic table, the two unframed
//! instruction streams, and the string literal the instructions and field lines
//! share. `static_table` is the RFC's 99 fixed fields; `DynamicTable` is the
//! per-connection, per-direction table with QPACK's absolute index space.
//!
//! `decoder.Decoder` turns one field section into `Header` values. The encoder
//! is not here yet; the instruction streams and the tables are the layer it
//! will compose.
//!
//! `http.prefix_int` and `http.huffman` are the shared primitives; QPACK adds
//! `prefix_int.decodeWide` for the 62-bit integers RFC 9204 §4.1.1 requires.

pub const static_table = @import("static_table.zig");
pub const dynamic_table = @import("dynamic_table.zig");
pub const decoder = @import("decoder.zig");
pub const decoder_stream = @import("decoder_stream.zig");
pub const encoder_stream = @import("encoder_stream.zig");
pub const string = @import("string.zig");

pub const Decoder = decoder.Decoder;
pub const DynamicTable = dynamic_table.DynamicTable;
pub const TableStorage = @import("../TableStorage.zig");

test {
    _ = static_table;
    _ = dynamic_table;
    _ = decoder;
    _ = decoder_stream;
    _ = encoder_stream;
    _ = string;
    _ = TableStorage;
}
