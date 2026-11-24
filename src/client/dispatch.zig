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
const mem = std.mem;
const testing = std.testing;
const Allocator = mem.Allocator;

const time = @import("stdx").time;

const h1 = @import("../h1/client/streaming.zig");
const h2 = @import("../h2/client/client.zig");
const Header = @import("../header.zig").Header;
const Method = @import("../method.zig").Method;
const uri = @import("../uri.zig");
const Url = uri.Url;
const common = @import("common.zig");
pub const Protocol = common.Protocol;
pub const Scheme = common.Scheme;
pub const Request = common.Request;
pub const Response = common.Response;
const plain = @import("plain.zig");
const transport = @import("transport.zig");

// ast-grep-ignore: public-struct-field-default -- options bag; h1 is the cleartext default
pub const Config = struct {
    protocol: Protocol = .h1,
    common: common.Config,
};

// ast-grep-ignore: public-struct-field-default -- options bag; cleartext h1 by default
pub const Options = struct {
    /// Cleartext settings, used for `http` URLs. `.protocol = .h2` is h2c
    /// prior knowledge.
    plain: plain.Config = .{},
    /// Connector for `https` URLs, from `http.tls.client.Connector.handle` or
    /// another transport. Null makes an `https` URL `error.TlsUnsupported`.
    /// The connector behind it must outlive the client.
    tls: ?transport.Connector = null,
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
    /// The request method.
    method: Method,
    headers: []const Header = &.{},
    /// The whole body, sent in one call. Empty when `body_reader` is used.
    body: []const u8 = "",
    /// The body is read from here until end of stream. On h1 the request is
    /// chunked; on h2 it goes out as DATA. Mutually exclusive with `body`.
    body_reader: ?*Io.Reader = null,
    /// Absolute deadline for this exchange, overriding the client's.
    deadline: time.OptionalTimestamp = .none,
    /// Dial budget for this exchange, overriding the client's.
    connect_deadline: time.OptionalTimestamp = .none,
    /// Runs during resolve and between connect poll slices.
    progress: ?transport.Progress = null,
    /// Connect here instead of resolving the URL's host.
    address: ?Io.net.IpAddress = null,
    /// Follow a `Location` on 301, 302, 303, 307, and 308.
    follow_redirects: bool = true,
    /// Refuse a chain longer than this with `error.TooManyRedirects`.
    max_redirects: u8 = 10,
};

pub const Client = struct {
    /// The adapter for the open connection. Null before the first exchange and
    /// after the previous one closed.
    inner: ?Inner,
    /// The dialing form. Null when the caller attached a reader and writer.
    dialing: ?Dialing,
    /// The allocator this client was made with, so `destroy` can free it.
    allocator: Allocator,
    /// A transport cause latched when a failing exchange closed the connection
    /// before the caller could ask it. `readCause` and `writeCause` fall back
    /// to these.
    last_read_cause: ?anyerror,
    last_write_cause: ?anyerror,

    const Inner = union(Protocol) {
        h1: h1.Client,
        h2: h2.Client,
    };

    const Dialing = struct {
        io: Io,
        allocator: Allocator,
        /// The cleartext connector, in place so the client owns its storage.
        plain_transport: plain.Connector,
        /// The caller's `https` connector, borrowed for the client's lifetime.
        tls: ?transport.Connector,
        max_header_bytes: usize,
        max_headers: usize,
        deadline: time.OptionalTimestamp,
        connect_deadline: time.OptionalTimestamp,
        /// The byte transport behind `inner`, when one is open.
        connection: ?transport.Connection = null,
        /// What the open connection reaches, for reuse. Null when nothing is
        /// open.
        key: ?Key = null,
        /// Whether the open connection was dialed with a transfer hook. A hook
        /// cannot be installed after the fact, so reuse requires a match.
        hooked: bool = false,
    };

    /// The origin a pooled connection serves: scheme, host, and port.
    const Key = struct {
        scheme: Scheme,
        port: u16,
        host_len: u8,
        host: [Io.net.HostName.max_len]u8,

        fn fromUrl(url: Url) ?Key {
            if (url.host.len > Io.net.HostName.max_len) return null;
            var key: Key = .{
                .scheme = url.scheme,
                .port = url.port,
                .host_len = @intCast(url.host.len),
                .host = undefined,
            };
            @memcpy(key.host[0..url.host.len], url.host);
            return key;
        }

        fn hostSlice(self: *const Key) []const u8 {
            return self.host[0..self.host_len];
        }

        fn matches(self: *const Key, url: Url) bool {
            return self.scheme == url.scheme and
                self.port == url.port and
                mem.eql(u8, self.hostSlice(), url.host);
        }
    };

    /// Initialize a client that dials for itself. Initialize in the final
    /// location: the default connector points into this value.
    pub fn init(self: *Client, allocator: Allocator, io: Io, options: Options) !void {
        if (options.max_headers == 0) return error.InvalidConfig;
        self.* = .{
            .inner = null,
            .allocator = allocator,
            .last_read_cause = null,
            .last_write_cause = null,
            .dialing = .{
                .io = io,
                .allocator = allocator,
                .plain_transport = .init(options.plain),
                .tls = options.tls,
                .max_header_bytes = options.max_header_bytes,
                .max_headers = options.max_headers,
                .deadline = options.deadline,
                .connect_deadline = options.connect_deadline,
                .connection = null,
            },
        };
    }

    /// Allocate a client and initialize it. Release it with `destroy`, which
    /// also frees the client itself.
    pub fn create(allocator: Allocator, io: Io, options: Options) !*Client {
        const self = try allocator.create(Client);
        errdefer allocator.destroy(self);
        try self.init(allocator, io, options);
        return self;
    }

    /// Release a client made by `create`.
    pub fn destroy(self: *Client) void {
        const allocator = self.allocator;
        self.deinit();
        allocator.destroy(self);
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
        self.* = .{
            .inner = null,
            .dialing = null,
            .allocator = config.common.allocator,
            .last_read_cause = null,
            .last_write_cause = null,
        };
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
        } catch |err| {
            // A failing send closes the connection on the way out, so keep the
            // cause the caller can no longer reach.
            self.latchCause();
            return err;
        };
    }

    /// Send one request whose body is read from `body_reader` until end of
    /// stream. The adapter frames it: chunked on h1, DATA on h2.
    pub fn requestStream(
        self: *Client,
        value: Request,
        body_reader: *Io.Reader,
    ) !Response {
        return switch (self.inner orelse return error.NotOpen) {
            .h1 => |*client| client.requestStream(value, body_reader),
            .h2 => |*client| client.requestStream(value, body_reader),
        } catch |err| {
            self.latchCause();
            return err;
        };
    }

    /// The request call that both the fresh and the reused path share.
    fn exchange(self: *Client, url: Url, options: RequestOptions) !Response {
        if (options.body_reader != null and options.body.len != 0) {
            return error.BodyNotAllowed;
        }
        const value: Request = .{
            .method = options.method,
            .scheme = url.scheme,
            .authority = url.authority,
            .target = url.target,
            .headers = options.headers,
            .body = options.body,
        };
        if (options.body_reader) |reader| return self.requestStream(value, reader);
        return self.request(value);
    }

    /// Dial and send one request to `url_text`. The URL is parsed with this
    /// client's allocator and released before the response is returned.
    pub fn fetch(self: *Client, url_text: []const u8, options: RequestOptions) !Response {
        const allocator = if (self.dialing) |dialing|
            dialing.allocator
        else
            return error.NotDialing;
        var url = try Url.parse(allocator, url_text);
        defer url.deinit(allocator);
        return self.send(url, options);
    }

    /// One `GET`. The common case.
    pub fn get(self: *Client, url_text: []const u8) !Response {
        return self.fetch(url_text, .{ .method = .GET });
    }

    /// Dial `url` and send one request over the new connection. The previous
    /// connection is closed first, so the body of its response must already be
    /// closed.
    ///
    /// A stop from `RequestOptions.progress` leaves this function as
    /// `error.Stopped` from a cleartext dial, `error.Canceled` from a TLS dial,
    /// or `error.ReadFailed` when it ended a read, with `error.Canceled` on
    /// `readCause`. The connection is closed by then, so the causes are kept
    /// for exactly this check.
    pub fn send(self: *Client, url: Url, options: RequestOptions) !Response {
        var attempt = options;
        var current = url;
        var hops: u8 = 0;
        // Two buffers ping-pong: the URL being resolved borrows one while the
        // next one is written into the other.
        var storage = [2]std.ArrayList(u8){ .empty, .empty };
        defer for (&storage) |*buffer| buffer.deinit(self.allocator);
        var next_storage: usize = 0;
        var filtered: ?[]Header = null;
        defer if (filtered) |headers| self.allocator.free(headers);

        while (true) {
            attempt.headers = if (filtered) |headers| headers else options.headers;
            var response = try self.sendOnce(current, attempt);

            if (!options.follow_redirects) return response;
            const code = response.head.status.code();
            const follows = switch (code) {
                301, 302, 303, 307, 308 => true,
                else => false,
            };
            if (!follows) return response;
            const location = response.head.headers.get("Location") orelse return response;
            if (hops >= options.max_redirects) {
                response.body.close();
                return error.TooManyRedirects;
            }

            const next = try uri.resolveInto(
                self.allocator,
                current,
                location,
                &storage[next_storage],
            );

            // 303 always becomes GET; 301 and 302 do for a non-GET, non-HEAD.
            const to_get = code == 303 or
                ((code == 301 or code == 302) and
                    attempt.method != .GET and
                    attempt.method != .HEAD);
            if (to_get) {
                attempt.method = .GET;
                attempt.body = "";
                attempt.body_reader = null;
            } else if (attempt.body_reader != null) {
                // The reader is spent, so a method-preserving redirect cannot
                // replay the body. Report the redirect instead.
                return response;
            }

            // Credentials are for the origin that was asked, not the next one.
            if (next.port != current.port or !mem.eql(u8, next.host, current.host)) {
                if (filtered) |headers| self.allocator.free(headers);
                filtered = try stripCredentials(self.allocator, options.headers);
            }

            response.body.close();
            current = next;
            next_storage = 1 - next_storage;
            hops += 1;
        }
    }

    /// Expose the credential filter to the tests next to the client.
    pub fn stripForTest(allocator: Allocator, headers: []const Header) ![]Header {
        return stripCredentials(allocator, headers);
    }

    /// The caller's fields minus the credentials, for a redirect that leaves
    /// the origin. Names compare case-insensitively.
    fn stripCredentials(allocator: Allocator, headers: []const Header) ![]Header {
        var kept: std.ArrayList(Header) = .empty;
        errdefer kept.deinit(allocator);
        for (headers) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "authorization") or
                std.ascii.eqlIgnoreCase(header.name, "cookie") or
                std.ascii.eqlIgnoreCase(header.name, "proxy-authorization")) continue;
            try kept.append(allocator, header);
        }
        return kept.toOwnedSlice(allocator);
    }

    /// One exchange, no redirect policy. The caller owns `url` and `options`.
    fn sendOnce(self: *Client, url: Url, options: RequestOptions) !Response {
        const dialing = if (self.dialing) |*dialing| dialing else return error.NotDialing;
        self.last_read_cause = null;
        self.last_write_cause = null;

        const deadline = if (options.deadline.get() != null)
            options.deadline
        else
            dialing.deadline;

        // A kept-alive connection to the same origin carries the request when
        // the previous body was finished and the hook shape still fits.
        if (self.canReuse(&url, options)) {
            const connection = &dialing.connection.?;
            try connection.setDeadline(deadline);
            connection.setCancel(options.progress);
            return self.exchange(url, options) catch |err| {
                // An idle connection can be closed by the peer between
                // requests. Nothing was received, so one fresh dial is safe.
                if (err != error.EndOfStream) return err;
                self.closeConnection();
                return self.dialAndSend(url, options, deadline);
            };
        }

        self.closeConnection();
        return self.dialAndSend(url, options, deadline);
    }

    fn dialAndSend(
        self: *Client,
        url: Url,
        options: RequestOptions,
        deadline: time.OptionalTimestamp,
    ) !Response {
        const dialing = if (self.dialing) |*dialing| dialing else return error.NotDialing;
        const connect_deadline = if (options.connect_deadline.get() != null)
            options.connect_deadline
        else
            dialing.connect_deadline;
        // The scheme chooses the transport: cleartext, or the TLS connector the
        // caller supplied. A client without one cannot reach `https`.
        const connector = switch (url.scheme) {
            .http => dialing.plain_transport.handle(),
            .https => dialing.tls orelse return error.TlsUnsupported,
        };
        var connection = try connector.connect(.{
            .io = dialing.io,
            .gpa = dialing.allocator,
            .url = url,
            .deadline = deadline,
            .connect_deadline = connect_deadline,
            .progress = options.progress,
            .address = options.address,
        });
        // The connection is deinit'ed exactly once: here until the client
        // owns it, and through closeConnection after that.
        var connection_owned = true;
        errdefer if (connection_owned) connection.deinit();

        try self.openAdapter(connection.reader, connection.writer, .{
            .protocol = connection.protocol,
            .common = .{
                .allocator = dialing.allocator,
                .max_header_bytes = dialing.max_header_bytes,
                .max_headers = dialing.max_headers,
                .read_cause = connection.cause(),
            },
        });
        dialing.connection = connection;
        dialing.key = Key.fromUrl(url);
        dialing.hooked = options.progress != null;
        connection_owned = false;
        errdefer self.closeConnection();

        return self.exchange(url, options);
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
        if (self.dialing) |dialing| {
            if (dialing.connection) |connection| return connection.readCause();
        }
        return self.last_read_cause;
    }

    /// Why the last write on the open connection failed. Falls back to the cause
    /// latched by a failing exchange, which closed the connection.
    pub fn writeCause(self: *const Client) ?anyerror {
        if (self.dialing) |dialing| {
            if (dialing.connection) |connection| return connection.writeCause();
        }
        return self.last_write_cause;
    }

    /// Keep the transport's causes before a failure closes the connection.
    fn latchCause(self: *Client) void {
        const dialing = if (self.dialing) |*dialing| dialing else return;
        const connection = if (dialing.connection) |*connection| connection else return;
        self.last_read_cause = connection.readCause();
        self.last_write_cause = connection.writeCause();
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

    /// True when the open connection reaches `url` and can carry another
    /// request: its last body was finished and the connection stayed clean.
    fn canReuse(self: *Client, url: *const Url, options: RequestOptions) bool {
        const dialing = if (self.dialing) |*dialing| dialing else return false;
        if (dialing.connection == null) return false;
        const key = dialing.key orelse return false;
        if (!key.matches(url.*)) return false;
        // A hook cannot be added to a connection dialed without one.
        if ((options.progress != null) != dialing.hooked) return false;
        return switch (self.inner orelse return false) {
            .h1 => |*client| client.reusable(),
            .h2 => |*client| client.reusable(),
        };
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
            dialing.key = null;
            dialing.hooked = false;
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
        .method = .POST,
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
    try testing.expectError(error.NotDialing, client.send(url, .{ .method = .GET }));
}

test "a dialing client with no request yet has no protocol" {
    var client: Client = undefined;
    try client.init(testing.allocator, testing.io, .{});
    defer client.deinit();
    try testing.expectEqual(@as(?Protocol, null), client.protocol());
    try testing.expectError(error.NotOpen, client.request(.{
        .method = .GET,
        .scheme = .http,
        .authority = "example.com",
        .target = "/",
    }));
}

test "send releases the connection once when the head exchange fails" {
    const Fake = struct {
        const Self = @This();

        reader: Io.Reader = Io.Reader.failing,
        writer: Io.Writer = Io.Writer.failing,
        deinits: *usize,

        fn release(ptr: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.deinits.* += 1;
            self.* = undefined;
        }

        fn setDeadline(
            _: *anyopaque,
            _: time.OptionalTimestamp,
        ) error{DeadlineUnsupported}!void {}

        fn readCause(_: *const anyopaque) ?anyerror {
            return error.Canceled;
        }

        fn writeCause(_: *const anyopaque) ?anyerror {
            return error.TimedOut;
        }

        fn setCancel(_: *anyopaque, _: ?transport.Progress) void {}

        const connection_vtable: transport.Connection.VTable = .{
            .deinit = release,
            .setDeadline = setDeadline,
            .readCause = readCause,
            .writeCause = writeCause,
            .setCancel = setCancel,
        };

        fn connect(ptr: *anyopaque, _: transport.Context) anyerror!transport.Connection {
            const self: *Self = @ptrCast(@alignCast(ptr));
            return .{
                .reader = &self.reader,
                .writer = &self.writer,
                .protocol = .h1,
                .ptr = self,
                .vtable = &connection_vtable,
            };
        }

        const connector_vtable: transport.Connector.VTable = .{ .connect = connect };

        fn handle(self: *Self) transport.Connector {
            return .{ .ptr = self, .vtable = &connector_vtable };
        }
    };

    var deinits: usize = 0;
    var fake: Fake = .{ .deinits = &deinits };
    var client: Client = undefined;
    try client.init(testing.allocator, testing.io, .{ .tls = fake.handle() });
    defer client.deinit();

    // https selects the fake TLS connector; http would dial the real plain one.
    const url = try Url.parse(testing.allocator, "https://example.com/");
    defer url.deinit(testing.allocator);

    if (client.send(url, .{ .method = .GET })) |_| {
        return error.TestExpectedError;
    } else |_| {}

    try testing.expectEqual(@as(usize, 1), deinits);
    // The connection is gone by now, so the causes have to survive it.
    try testing.expectEqual(@as(?anyerror, error.Canceled), client.readCause());
    try testing.expectEqual(@as(?anyerror, error.TimedOut), client.writeCause());
}

test "an https URL needs a TLS connector" {
    var client: Client = undefined;
    try client.init(testing.allocator, testing.io, .{});
    defer client.deinit();
    try testing.expectError(error.TlsUnsupported, client.get("https://example.com/"));
}

test "a client that only attached a socket has no URL entry point" {
    var failing_reader = Io.Reader.failing;
    var failing_writer = Io.Writer.failing;
    var client: Client = undefined;
    try client.attached(&failing_reader, &failing_writer, .{
        .common = .{ .allocator = testing.allocator },
    });
    defer client.deinit();
    try testing.expectError(error.NotDialing, client.get("http://127.0.0.1:1/"));
}
