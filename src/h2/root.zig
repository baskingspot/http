//! HTTP/2 (RFC 9113), h2c and h2 over TLS alike. Sans-I/O.
//!
//! The frame codec is the first layer: frame headers, typed payloads, and an
//! outbound writer over a caller buffer. Stream state, flow control, settings
//! state, and CONTINUATION assembly belong above it.
pub const frame = @import("frame.zig");
pub const head = @import("head.zig");

test {
    _ = frame;
    _ = head;
}
