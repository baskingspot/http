//! Server engines over the sans-I/O HTTP/1 connection machine.
//!
//! The parser modules stay free of sockets. Each engine owns a transport and
//! drives `h1.ServerConn`; the connection machine owns no memory and does no
//! I/O.

const builtin = @import("builtin");
const poll_impl = @import("poll.zig");
const epoll_impl = @import("epoll.zig");
const kqueue_impl = @import("kqueue.zig");

pub const blocking = @import("blocking.zig");
pub const poll = if (builtin.os.tag == .linux) poll_impl else struct {};
pub const epoll = if (builtin.os.tag == .linux) epoll_impl else struct {};
pub const kqueue = if (builtin.os.tag == .macos) kqueue_impl else struct {};
pub const Exchange = @import("common.zig").Exchange;
pub const Handler = @import("common.zig").Handler;

test {
    _ = blocking;
    _ = poll;
    _ = epoll;
    _ = kqueue;
    _ = Exchange;
    _ = Handler;
}
