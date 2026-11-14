//! HTTP/2 client adapters.

pub const Client = @import("client.zig").Client;
pub const Driver = @import("driver.zig").Driver;
const connection = @import("connection.zig");
pub const Connection = connection.Connection;
pub const Stream = connection.Stream;
pub const DataLease = connection.DataLease;
pub const Event = connection.Event;
pub const Close = connection.Close;
pub const Request = connection.Request;
pub const Options = connection.Options;

test {
    _ = Client;
    _ = Driver;
    _ = Connection;
    _ = Stream;
    _ = DataLease;
    _ = Event;
    _ = Close;
    _ = Request;
    _ = Options;
}
