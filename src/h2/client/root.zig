//! HTTP/2 client adapters.

pub const blocking = @import("blocking.zig");
pub const Connection = @import("connection.zig").Connection;
pub const Stream = @import("connection.zig").Stream;
pub const DataLease = @import("connection.zig").DataLease;

test {
    _ = blocking;
    _ = Connection;
    _ = Stream;
    _ = DataLease;
}
