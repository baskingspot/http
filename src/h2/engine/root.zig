//! Server engines over the sans-I/O HTTP/2 session.
//!
//! The session owns protocol state; an engine owns the transport, the request
//! buffering, and the handler loop. `blocking` is the reference engine; the
//! readiness engines share the same exchange core.

const builtin = @import("builtin");
const poll_impl = @import("poll.zig");
const epoll_impl = @import("epoll.zig");
const kqueue_impl = @import("kqueue.zig");
const wait_poll_impl = @import("../../transport/wait_poll.zig");
const wait_epoll_impl = @import("../../transport/wait_epoll.zig");
const wait_kqueue_impl = @import("../../transport/wait_kqueue.zig");

pub const blocking = @import("blocking.zig");
pub const poll = if (builtin.os.tag == .linux) poll_impl else struct {};
pub const epoll = if (builtin.os.tag == .linux) epoll_impl else struct {};
pub const kqueue = if (builtin.os.tag == .macos) kqueue_impl else struct {};

pub const connection = @import("connection.zig");
pub const Connection = connection.Connection;
pub const ConnectionOptions = connection.Options;

// Shared with the optional `http_tls` module, which instantiates the
// readiness loop with a TLS transport. The core `http` module does not import
// TLS itself.
pub const readiness = @import("readiness.zig");
pub const transport = @import("transport.zig");
pub const wait = @import("../../transport/wait.zig");
pub const wait_poll = if (builtin.os.tag == .linux) wait_poll_impl else struct {};
pub const wait_epoll = if (builtin.os.tag == .linux) wait_epoll_impl else struct {};
pub const wait_kqueue = if (builtin.os.tag == .macos) wait_kqueue_impl else struct {};

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
