//! An epoll(7)-based HTTP/2 server engine.
//!
//! The readiness loop is shared with poll and kqueue; this module supplies the
//! Linux epoll registration and wait backend.

const readiness = @import("readiness.zig");
const Wait = @import("../../transport/wait_epoll.zig").Wait;

pub const Config = readiness.Config;
pub const Exchange = readiness.Exchange;
pub const Handler = readiness.Handler;
pub const Server = readiness.Server(Wait);
