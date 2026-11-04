//! A kqueue(2)-based HTTP/1 server engine.
//!
//! The readiness loop is shared with poll and epoll; this module supplies the
//! Darwin transport edge and the kqueue registration and wait backend.

const readiness = @import("readiness.zig");
const Wait = @import("wait_kqueue.zig").Wait;

pub const Config = readiness.Config;
pub const Exchange = readiness.Exchange;
pub const Handler = readiness.Handler;
pub const Server = readiness.Server(Wait);
