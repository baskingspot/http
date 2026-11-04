//! The optional TLS readiness engines for `baskingspot/http`.
//!
//! This module imports `tls` and `tls_nonblocking`. Import it only when the
//! server terminates TLS; the core `http` module stays free of TLS code and
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

pub const h2 = struct {
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
}
