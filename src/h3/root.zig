//! HTTP/3 (RFC 9114), sans I/O.
//!
//! `frame` is the framing layer: the type and length varints, typed payloads,
//! and a reader that walks one QUIC stream. `head` validates the decoded
//! request, response, and trailer field sections. The control stream and the
//! session are not here yet.

pub const frame = @import("frame.zig");
pub const head = @import("head.zig");

test {
    _ = frame;
    _ = head;
}
