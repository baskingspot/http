//! Server engines over the sans-I/O HTTP/2 session.
//!
//! The session owns protocol state; an engine owns the transport, the request
//! buffering, and the handler loop. `blocking` is the reference engine; the
//! readiness engines share the same exchange core.

const builtin = @import("builtin");
const poll_impl = @import("poll.zig");
const epoll_impl = @import("epoll.zig");
const kqueue_impl = @import("kqueue.zig");

pub const blocking = @import("blocking.zig");
pub const poll = if (builtin.os.tag == .linux) poll_impl else struct {};
pub const epoll = if (builtin.os.tag == .linux) epoll_impl else struct {};
pub const kqueue = if (builtin.os.tag == .macos) kqueue_impl else struct {};

pub const connection = @import("connection.zig");
pub const Connection = connection.Connection;
pub const ConnectionOptions = connection.Options;

pub const Config = blocking.Config;
pub const Exchange = blocking.Exchange;
pub const Handler = blocking.Handler;
pub const Request = blocking.Request;
pub const ResponseOptions = blocking.ResponseOptions;

test {
    _ = blocking;
    _ = poll;
    _ = epoll;
    _ = kqueue;
}
