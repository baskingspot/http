//! HTTP/2 (RFC 9113), h2c and h2 over TLS alike. Sans-I/O.
//!
//! The frame codec is the first layer: frame headers, typed payloads, and an
//! outbound writer over a caller buffer. `Session` composes it with settings,
//! stream state, flow control, HPACK, and CONTINUATION assembly.
pub const flow = @import("flow.zig");
pub const frame = @import("frame.zig");
pub const head = @import("head.zig");
pub const header_block = @import("header_block.zig");
pub const session = @import("session.zig");
pub const Session = session.Session;
pub const settings = @import("settings.zig");
pub const stream = @import("stream.zig");

test {
    _ = flow;
    _ = frame;
    _ = head;
    _ = header_block;
    _ = session;
    _ = settings;
    _ = stream;
}
