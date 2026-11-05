//! Protocol dispatch for a blocking client.
//!
//! Both adapters share the types in `client/common.zig` and speak over the
//! caller-owned reader and writer. The caller chooses the protocol above this
//! layer; TLS ALPN or a cleartext prior-knowledge decision belongs there.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;

const common = @import("common.zig");
const h1 = @import("../h1/client/streaming.zig");
const h2 = @import("../h2/client/blocking.zig");

pub const Protocol = common.Protocol;
pub const Request = common.Request;
pub const Response = common.Response;

// ast-grep-ignore: public-struct-field-default -- options bag; h1 is the cleartext default
pub const Config = struct {
    protocol: Protocol = .h1,
    common: common.Config,
};

pub const Client = struct {
    inner: Inner,

    const Inner = union(Protocol) {
        h1: h1.Client,
        h2: h2.Client,
    };

    pub fn init(
        self: *Client,
        reader: *Io.Reader,
        writer: *Io.Writer,
        config: Config,
    ) !void {
        switch (config.protocol) {
            .h1 => {
                self.inner = .{ .h1 = undefined };
                try self.inner.h1.init(reader, writer, config.common);
            },
            .h2 => {
                self.inner = .{ .h2 = undefined };
                try self.inner.h2.init(reader, writer, config.common);
            },
        }
    }

    pub fn deinit(self: *Client) void {
        switch (self.inner) {
            .h1 => |*client| client.deinit(),
            .h2 => |*client| client.deinit(),
        }
        self.* = undefined;
    }

    pub fn request(self: *Client, value: Request) !Response {
        return switch (self.inner) {
            .h1 => |*client| client.request(value),
            .h2 => |*client| client.request(value),
        };
    }

    pub fn protocol(self: *const Client) Protocol {
        return self.inner;
    }
};

test "cleartext h1 dispatch reaches the h1 adapter" {
    var reader = Io.Reader.failing;
    var out: [1024]u8 = undefined;
    var writer = Io.Writer.fixed(&out);
    var client: Client = undefined;
    try client.init(&reader, &writer, .{
        .protocol = .h1,
        .common = .{ .allocator = testing.allocator },
    });
    defer client.deinit();

    try testing.expectEqual(Protocol.h1, client.protocol());
    try testing.expectError(error.RequestBodyUnsupported, client.request(.{
        .method_token = "POST",
        .scheme = .http,
        .authority = "example.com",
        .target = "/",
        .body = "x",
    }));
}
