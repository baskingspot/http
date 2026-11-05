//! HTTP/1 client adapters.

pub const blocking = @import("blocking.zig");
pub const streaming = @import("streaming.zig");

test {
    _ = blocking;
    _ = streaming;
}
