//! A poll(2)-based HTTP/2 server engine over TLS.
//!
//! The readiness loop is the core engine; this wrapper supplies the wait
//! backend and the `tls_nonblocking` transport.

const http = @import("http");
const transport = @import("transport/tls.zig");

pub const Config = http.h2.engine.readiness.Config(transport.Transport);
pub const Exchange = http.h2.engine.Exchange;
pub const Handler = http.h2.engine.Handler;
pub const Server = http.h2.engine.readiness.Server(
    http.h2.engine.wait_poll.Wait,
    transport.Transport,
);
