//! Server engines over the sans-I/O HTTP/2 session.
//!
//! The session owns protocol state; an engine owns the transport and the
//! handler loop. `blocking` is the reference engine.

pub const blocking = @import("blocking.zig");
pub const Config = blocking.Config;
pub const Connection = blocking.Connection;

test {
    _ = blocking;
}
