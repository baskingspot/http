//! A kqueue(2)-based HTTP/2 server engine over TLS.
//!
//! The readiness loop is the core engine; this wrapper supplies the wait
//! backend and the `tls_nonblocking` transport.

const engine = @import("root.zig");
const transport = @import("transport/tls.zig");

pub const Config = engine.readiness.Config(transport.Transport);
pub const Exchange = engine.Exchange;
pub const Handler = engine.Handler;
pub const Server = engine.readiness.Server(
    engine.wait_kqueue.Wait,
    transport.Transport,
);
