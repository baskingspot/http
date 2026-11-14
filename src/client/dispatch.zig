//! The HTTP client: one type for a caller that owns its socket and for one
//! that wants the client to dial.
//!
//! `attached` takes a reader and writer somebody else opened, and dispatches
//! the exchange to the h1 or h2 adapter. `send` dials through a
//! `client.transport.Connector` first: the connector decides plain or TLS, the
//! ALPN selection decides the adapter, and one deadline covers the dial and
//! every read and write after it.
//!
//! A client holds at most one connection. `send` closes the previous one, and
//! the response body borrows the current one, so close the body before the next
//! `send` or `deinit`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const testing = std.testing;
const time = @import("stdx").time;

const Header = @import("../header.zig").Header;
const Url = @import("../uri.zig").Url;
const common = @import("common.zig");
const plain = @import("plain.zig");
const transport = @import("transport.zig");
const h1 = @import("../h1/client/streaming.zig");
const h2 = @import("../h2/client/client.zig");

pub const Protocol = common.Protocol;
pub const Request = common.Request;
pub const Response = common.Response;

// ast-grep-ignore: public-struct-field-default -- options bag; h1 is the cleartext default
pub const Config = struct {
    protocol: Protocol = .h1,
    common: common.Config,
};

// ast-grep-ignore: public-struct-field-default -- options bag; cleartext h1 by default
pub const Options = struct {
    /// How to reach a peer. Null speaks cleartext HTTP/1.1 through
    /// `client.plain` with its defaults.
    transport: ?transport.Connector = null,
    /// Largest response field section, in bytes.
    max_header_bytes: usize = 16 * 1024,
    /// Largest response field count.
    max_headers: usize = 128,
    /// Deadline for every exchange that does not set its own.
    deadline: time.OptionalTimestamp = .none,
    /// Dial budget for every exchange that does not set its own. Bounds resolve,
    /// connect, and handshake even when `deadline` is `.none`.
    connect_deadline: time.OptionalTimestamp = .none,
};

// ast-grep-ignore: public-struct-field-default -- options bag; a GET without a body
pub const RequestOptions = struct {
    /// The exact wire method token.
    method_token: []const u8,
    headers: []const Header = &.{},
    body: []const u8 = "",
    /// Absolute deadline for this exchange, overriding the client's.
    deadline: time.OptionalTimestamp = .none,
    /// Dial budget for this exchange, overriding the client's.
    connect_deadline: time.OptionalTimestamp = .none,
    /// Runs during resolve and between connect poll slices.
    progress: ?transport.Progress = null,
    /// Connect here instead of resolving the URL's host.
    address: ?Io.net.IpAddress = null,
};

pub const Client = struct {
    /// The adapter for the open connection. Null before the first exchange and
    /// after the previous one closed.
    inner: ?Inner,
    /// The dialing form. Null when the caller attached a reader and writer.
    dialing: ?Dialing,

    const Inner = union(Protocol) {
        h1: h1.Client,
        h2: h2.Client,
    };

    const Dialing = struct {
        io: Io,
        allocator: Allocator,
        /// Either the caller's handle or `default_transport.handle()`.
        connector: transport.Connector,
        /// Stable storage for the handle above, so the client does not have to
        /// carry a pointer to something the caller keeps alive.
        default_transport: plain.Connector,
        max_header_bytes: usize,
        max_headers: usize,
        deadline: time.OptionalTimestamp,
        connect_deadline: time.OptionalTimestamp,
        /// The byte transport behind `inner`, when one is open.
        connection: ?transport.Connection = null,
    };

    /// Initialize a client that dials for itself. Initialize in the final
    /// location: the default connector points into this value.
    pub fn init(self: *Client, allocator: Allocator, io: Io, options: Options) !void {
        if (options.max_headers == 0) return error.InvalidConfig;
        self.* = .{
            .inner = null,
            .dialing = .{
                .io = io,
                .allocator = allocator,
                .connector = undefined,
                .default_transport = .init(.{}),
                .max_header_bytes = options.max_header_bytes,
                .max_headers = options.max_headers,
                .deadline = options.deadline,
                .connect_deadline = options.connect_deadline,
                .connection = null,
            },
        };
        const dialing = &self.dialing.?;
        dialing.connector = options.transport orelse dialing.default_transport.handle();
    }

    /// Initialize a client over a reader and writer somebody else opened, and
    /// which the caller keeps alive. Nothing about that socket is dialed,
    /// bounded, or closed here.
    pub fn attached(
        self: *Client,
        reader: *Io.Reader,
        writer: *Io.Writer,
        config: Config,
    ) !void {
        self.* = .{ .inner = null, .dialing = null };
        try self.openAdapter(reader, writer, config);
    }

    /// Close the open connection, if any.
    pub fn deinit(self: *Client) void {
        self.closeConnection();
        self.* = undefined;
    }

    /// Send one request over the open connection. `send` is the entry point
    /// that dials; use it unless the transport is already yours.
    pub fn request(self: *Client, value: Request) !Response {
        return switch (self.inner orelse return error.NotOpen) {
            .h1 => |*client| client.request(value),
            .h2 => |*client| client.request(value),
        };
    }

    /// Dial `url` and send one request over the new connection. The previous
    /// connection is closed first, so the body of its response must already be
    /// closed.
    pub fn send(self: *Client, url: Url, options: RequestOptions) !Response {
        const dialing = if (self.dialing) |*dialing| dialing else return error.NotDialing;
        self.closeConnection();

        const deadline = if (options.deadline.get() != null)
            options.deadline
        else
            dialing.deadline;
        const connect_deadline = if (options.connect_deadline.get() != null)
            options.connect_deadline
        else
            dialing.connect_deadline;
        var connection = try dialing.connector.connect(.{
            .io = dialing.io,
            .gpa = dialing.allocator,
            .url = url,
            .deadline = deadline,
            .connect_deadline = connect_deadline,
            .progress = options.progress,
            .address = options.address,
        });
        errdefer connection.deinit();

        try self.openAdapter(connection.reader, connection.writer, .{
            .protocol = connection.protocol,
            .common = .{
                .allocator = dialing.allocator,
                .max_header_bytes = dialing.max_header_bytes,
                .max_headers = dialing.max_headers,
                .read_cause = connection.cause(),
            },
        });
        errdefer self.closeConnection();
        dialing.connection = connection;

        return self.request(.{
            .method_token = options.method_token,
            .scheme = url.scheme,
            .authority = url.authority,
            .target = url.target,
            .headers = options.headers,
            .body = options.body,
        });
    }

    /// The protocol of the open connection, or null when none is open.
    pub fn protocol(self: *const Client) ?Protocol {
        if (self.inner) |inner| return inner;
        return null;
    }

    /// Why the last read on the open connection failed. Valid while a response
    /// body is open: it names a truncation, a reset, a protocol fault, or a
    /// local cause such as a deadline. `Body.outcome` carries the same
    /// information on the body itself.
    pub fn readCause(self: *const Client) ?anyerror {
        const dialing = self.dialing orelse return null;
        if (dialing.connection) |*connection| return connection.readCause();
        return null;
    }

    /// Why the last write on the open connection failed. Valid while a response
    /// body is open.
    pub fn writeCause(self: *const Client) ?anyerror {
        const dialing = self.dialing orelse return null;
        if (dialing.connection) |*connection| return connection.writeCause();
        return null;
    }

    fn openAdapter(
        self: *Client,
        reader: *Io.Reader,
        writer: *Io.Writer,
        config: Config,
    ) !void {
        switch (config.protocol) {
            .h1 => {
                self.inner = .{ .h1 = undefined };
                self.inner.?.h1.init(reader, writer, config.common) catch |err| {
                    self.inner = null;
                    return err;
                };
            },
            .h2 => {
                self.inner = .{ .h2 = undefined };
                self.inner.?.h2.init(reader, writer, config.common) catch |err| {
                    self.inner = null;
                    return err;
                };
            },
        }
    }

    fn closeConnection(self: *Client) void {
        if (self.inner) |*inner| switch (inner.*) {
            .h1 => |*client| client.deinit(),
            .h2 => |*client| client.deinit(),
        };
        self.inner = null;
        if (self.dialing) |*dialing| {
            if (dialing.connection) |*connection| connection.deinit();
            dialing.connection = null;
        }
    }
};

test "attached mode reaches the h1 adapter" {
    var reader = Io.Reader.failing;
    var out: [1024]u8 = undefined;
    var writer = Io.Writer.fixed(&out);
    var client: Client = undefined;
    try client.attached(&reader, &writer, .{
        .protocol = .h1,
        .common = .{ .allocator = testing.allocator },
    });
    defer client.deinit();

    try testing.expectEqual(@as(?Protocol, .h1), client.protocol());
    try testing.expectError(error.ReadFailed, client.request(.{
        .method_token = "POST",
        .scheme = .http,
        .authority = "example.com",
        .target = "/",
        .body = "x",
    }));
}

test "a client that only attached a socket cannot dial" {
    var failing_reader = Io.Reader.failing;
    var failing_writer = Io.Writer.failing;
    var client: Client = undefined;
    try client.attached(&failing_reader, &failing_writer, .{
        .common = .{ .allocator = testing.allocator },
    });
    defer client.deinit();

    const url = try Url.parse(testing.allocator, "http://127.0.0.1:1/");
    defer url.deinit(testing.allocator);
    try testing.expectError(error.NotDialing, client.send(url, .{ .method_token = "GET" }));
}

test "a dialing client with no request yet has no protocol" {
    var client: Client = undefined;
    try client.init(testing.allocator, testing.io, .{});
    defer client.deinit();
    try testing.expectEqual(@as(?Protocol, null), client.protocol());
    try testing.expectError(error.NotOpen, client.request(.{
        .method_token = "GET",
        .scheme = .http,
        .authority = "example.com",
        .target = "/",
    }));
}
