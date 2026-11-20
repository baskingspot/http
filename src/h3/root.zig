//! HTTP/3 (RFC 9114), sans I/O.
//!
//! `frame` is the first layer: the type and length varints, typed payloads, and
//! a reader that walks one QUIC stream. QPACK, the control stream, and the
//! session are not here yet.

pub const frame = @import("frame.zig");

test {
    _ = frame;
}
