//! Server engines over the sans-I/O HTTP/1 connection machine.
//!
//! The parser modules stay free of sockets. Each engine owns a transport and
//! drives `h1.ServerConn`; the connection machine owns no memory and does no
//! I/O.

pub const blocking = @import("blocking.zig");
pub const poll = @import("poll.zig");
pub const epoll = @import("epoll.zig");
pub const Exchange = @import("common.zig").Exchange;

test {
    _ = blocking;
    _ = poll;
    _ = epoll;
    _ = Exchange;
}
