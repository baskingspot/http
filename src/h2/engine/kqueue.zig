//! A kqueue(2)-based HTTP/2 server engine.
//!
//! The readiness loop is shared with poll and epoll; this module supplies the
//! Darwin kqueue registration and wait backend.

const readiness = @import("readiness.zig");
const Wait = @import("../../transport/wait_kqueue.zig").Wait;
const transport = @import("transport/plain.zig");

pub const Config = readiness.Config(transport.Transport);
pub const Exchange = readiness.Exchange;
pub const Handler = readiness.Handler;
pub const Server = readiness.Server(Wait, transport.Transport);
