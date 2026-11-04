//! A poll(2)-based HTTP/1 server engine.
//!
//! The readiness loop is shared with epoll; this module supplies the poll(2)
//! registration and wait backend.

const readiness = @import("readiness.zig");
const Wait = @import("../../transport/wait_poll.zig").Wait;

pub const Config = readiness.Config;
pub const Exchange = readiness.Exchange;
pub const Handler = readiness.Handler;
pub const Server = readiness.Server(Wait);
