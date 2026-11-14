//! The TLS engines and transports for `baskingspot/http`.
//!
//! This module imports `tls` and `tls_nonblocking`. Import it only when a
//! program terminates TLS; the core `http` module stays free of TLS code and
//! links no crypto library.
//!
//! ```zig
//! const http_tls = @import("http_tls");
//! const Engine = http_tls.h2.engine.tls.poll; // or .epoll / .kqueue
//! ```

const builtin = @import("builtin");

const tls_poll_impl = @import("h2/engine/tls_poll.zig");
const tls_epoll_impl = @import("h2/engine/tls_epoll.zig");
const tls_kqueue_impl = @import("h2/engine/tls_kqueue.zig");
const tls_client_impl = @import("h2/engine/transport/tls_client.zig");

/// Trust anchors from PEM bytes, and the type `tls.certificate.Policy` takes.
pub const anchors = @import("http_tls/anchors.zig");
pub const Bundle = anchors.Bundle;

/// A plaintext connection over TLS: reader, writer, one deadline.
pub const client = @import("http_tls/client.zig");

pub const h2 = struct {
    pub const transport = struct {
        pub const tls_client = tls_client_impl;
    };

    pub const engine = struct {
        pub const tls = struct {
            pub const poll = if (builtin.os.tag == .linux) tls_poll_impl else struct {};
            pub const epoll = if (builtin.os.tag == .linux) tls_epoll_impl else struct {};
            pub const kqueue = if (builtin.os.tag == .macos) tls_kqueue_impl else struct {};
        };
    };
};

test {
    _ = h2;
    // Reference the files directly: `_ = anchors` names a container value and
    // is elided, which silently drops every test in it.
    _ = @import("http_tls/anchors.zig");
    _ = @import("http_tls/client.zig");
    _ = @import("h2/engine/transport/tls.zig");
    _ = @import("h2/engine/transport/tls_client.zig");
}
