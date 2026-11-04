//! Server engines over the sans-I/O HTTP/2 session.
//!
//! The session owns protocol state; an engine owns the transport, the request
//! buffering, and the handler loop. `blocking` is the reference engine.

pub const blocking = @import("blocking.zig");
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
}
