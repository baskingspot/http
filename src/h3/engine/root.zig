//! HTTP/3 engines over a transport. `quic` is the server over `quic-io`.

pub const quic = @import("quic.zig");

test {
    _ = quic;
}
