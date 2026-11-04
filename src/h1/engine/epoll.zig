//! An epoll(7)-based HTTP/1 server engine.
//!
//! The readiness loop is shared with poll; this module supplies the epoll
//! registration and wait backend.

const readiness = @import("readiness.zig");
const Wait = @import("wait_epoll.zig").Wait;

pub const Config = readiness.Config;
pub const Exchange = readiness.Exchange;

pub fn Server(comptime Handler: type) type {
    return readiness.Server(Handler, Wait);
}
