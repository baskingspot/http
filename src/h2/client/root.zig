//! HTTP/2 client adapters.

pub const blocking = @import("blocking.zig");
const connection = @import("connection.zig");
pub const Connection = connection.Connection;
pub const Stream = connection.Stream;
pub const DataLease = connection.DataLease;
pub const Event = connection.Event;
pub const Close = connection.Close;
pub const Request = connection.Request;
pub const Options = connection.Options;

test {
    _ = blocking;
    _ = Connection;
    _ = Stream;
    _ = DataLease;
    _ = Event;
    _ = Close;
    _ = Request;
    _ = Options;
}
