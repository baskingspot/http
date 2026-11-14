//! HTTP/1 client adapters.

pub const buffered = @import("buffered.zig");
pub const streaming = @import("streaming.zig");

test {
    _ = buffered;
    _ = streaming;
}
