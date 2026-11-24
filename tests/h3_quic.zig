//! The HTTP/3 driver over a real loopback connection.
//!
//! A server `Engine` and a client `h3.Session` exchange more requests than the
//! server's stream table holds. A slot or table entry that is not released at
//! the end of a request makes the connection stop serving, which is what this
//! test measures. One request asks for a body one byte over the send-buffer
//! budget; that stream is reset, and the connection must keep serving.
//!
//! `quic-io` is the transport, with the native TLS backend and the public
//! certificate from `baskingspot/tls`. The client trusts it insecurely because
//! this is a loopback test.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const Allocator = std.mem.Allocator;

const http = @import("http");
const quic_io = @import("quic-io");

const server_cert = @embedFile("tls_server_crt");
const server_key = @embedFile("tls_server_key");

const limits: quic_io.SizingLimits = .{
    .streams = 16,
    .stream_ring = 16 * 1024,
    .peer_initial = 4,
    .preheat = 4,
};
const Engine = http.h3.engine.quic.Engine(limits);
const ClientEndpoint = quic_io.Endpoint(quic_io.Sizing(limits));

const request_count = 24;
const body = "hello from h3";

// A `quic-io` endpoint must not move.
var server_endpoint: Engine.Endpoint = undefined;
var client_endpoint: ClientEndpoint = undefined;

fn serverHandle(_: *anyopaque, exchange: *Engine.Exchange) anyerror!void {
    const path = exchange.request.path orelse return error.InvalidPath;
    if (std.mem.eql(u8, path, "/big")) {
        var big: [Engine.max_body_bytes + 1]u8 = @splat('x');
        try exchange.respond(.ok, "text/plain", &big);
        return;
    }
    try exchange.respond(.ok, "text/plain", body);
}

const Outcome = struct {
    status: ?http.Status = null,
    bytes: [64]u8 = undefined,
    len: usize = 0,
    reset: bool = false,
};

const Client = struct {
    io: Io,
    allocator: Allocator,
    session: http.h3.Session,
    connection: quic_io.Connection,
    control: quic_io.Stream,
    request: ?quic_io.Stream = null,
    outcome: Outcome = .{},

    fn find(self: *Client, id: u62) ?quic_io.Stream {
        if (@as(u62, @intCast(self.control.id)) == id) return self.control;
        if (self.request) |stream| {
            if (@as(u62, @intCast(stream.id)) == id) return stream;
        }
        return null;
    }

    fn writeStream(self: *Client, stream: quic_io.Stream, bytes: []const u8, fin: bool) !void {
        var pos: usize = 0;
        while (pos < bytes.len) {
            const n = try stream.write(self.io, bytes[pos..]);
            if (n == 0) return error.NoSpace;
            pos += n;
        }
        if (fin) try stream.shutdown(self.io, .send);
    }

    fn drain(self: *Client) !void {
        while (self.session.nextAction()) |action| {
            switch (action) {
                .write => |write| {
                    const stream = self.find(write.stream_id) orelse
                        return error.UnknownStream;
                    try self.writeStream(stream, write.bytes, write.fin);
                },
                .reset => |reset| {
                    if (self.find(reset.stream_id)) |stream| {
                        stream.shutdown(self.io, .both) catch |err| switch (err) {
                            error.StreamClosed, error.ConnectionClosed => {},
                            else => {},
                        };
                    }
                },
                .stop_sending => |stop| {
                    if (self.find(stop.stream_id)) |stream| {
                        stream.shutdown(self.io, .recv) catch |err| switch (err) {
                            error.StreamClosed, error.ConnectionClosed => {},
                            else => {},
                        };
                    }
                },
                .close => |code| self.connection.closeWith(self.io, code),
            }
            self.session.release(self.allocator);
        }
    }

    fn events(self: *Client, current: ?u62) !void {
        while (try self.session.nextEvent(self.allocator)) |event| {
            switch (event) {
                .response => |response| {
                    if (current != null and response.stream_id == current.?) {
                        self.outcome.status = response.head.status;
                    }
                },
                .data => |data| {
                    if (current != null and data.stream_id == current.?) {
                        if (self.outcome.len + data.bytes.len > self.outcome.bytes.len) {
                            return error.ResponseTooLarge;
                        }
                        @memcpy(
                            self.outcome.bytes[self.outcome.len..][0..data.bytes.len],
                            data.bytes,
                        );
                        self.outcome.len += data.bytes.len;
                    }
                },
                .reset => |reset| {
                    if (current != null and reset.stream_id == current.?) {
                        self.outcome.reset = true;
                    }
                },
                .connection_error => return error.ConnectionError,
                .stream_error => return error.StreamError,
                else => {},
            }
        }
        try self.drain();
    }

    fn feed(self: *Client, id: u62, bytes: []const u8) !void {
        var offset: usize = 0;
        while (offset < bytes.len) {
            const consumed = self.session.receive(self.allocator, id, bytes[offset..], false);
            offset += consumed;
            try self.events(id);
            if (consumed == 0) {
                if (self.session.isClosed()) return error.ConnectionClosed;
                continue;
            }
        }
    }
};

test "the driver serves more requests than its stream table" {
    try testing.expect(Engine.max_body_bytes > 0);

    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var address: quic_io.IpAddress = undefined;
    const server_socket = bound: {
        var port: u16 = 47701;
        while (port < 47751) : (port += 1) {
            address = .{ .ip4 = .loopback(port) };
            break :bound address.bind(io, .{ .mode = .dgram }) catch continue;
        }
        return error.NoFreePort;
    };
    defer server_endpoint.deinit(io);
    try server_endpoint.listen(testing.allocator, .{
        .io = io,
        .socket = server_socket,
        .certificate = server_cert,
        .key = server_key,
        .alpn = &.{"h3"},
        .parameters = .{
            .max_idle_timeout = 10_000,
            .initial_max_streams_bidi = 4,
            .initial_max_streams_uni = 4,
        },
    });

    var serving = try io.concurrent(Engine.serve, .{
        io,
        testing.allocator,
        &server_endpoint,
        Engine.Handler{ .context = undefined, .handle = serverHandle },
    });
    var joined = false;
    defer if (!joined) {
        serving.cancel(io) catch |err| switch (err) {
            error.Canceled => {},
            else => {},
        };
    };

    const local: quic_io.IpAddress = .{ .ip4 = .loopback(0) };
    const client_socket = try local.bind(io, .{ .mode = .dgram });
    defer client_endpoint.deinit(io);
    const connection = try client_endpoint.connect(testing.allocator, .{
        .io = io,
        .socket = client_socket,
        .peer = address,
        .server_name = "test.local",
        .alpn = &.{"h3"},
        .trust = .insecure,
        .parameters = .{
            .max_idle_timeout = 10_000,
            .initial_max_streams_bidi = 1,
            .initial_max_streams_uni = 4,
        },
    });

    const control = try connection.openStream(io, .uni);
    var client: Client = .{
        .io = io,
        .allocator = testing.allocator,
        .session = undefined,
        .connection = connection,
        .control = control,
    };
    client.session = try http.h3.Session.init(testing.allocator, .{
        .role = .client,
        .control_stream = @intCast(control.id),
        .encoder_stream = null,
        .decoder_stream = null,
        .qpack_max_table_capacity = 0,
        .qpack_blocked_streams = 0,
        .max_field_section_size = 16 * 1024,
        .max_streams = 16,
        .max_fields = 64,
        .max_in_header_block = 16 * 1024,
        .max_control_frame = 16 * 1024,
        .max_data_event = 16 * 1024,
        .max_blocked_bytes = 64 * 1024,
    });
    defer client.session.deinit(testing.allocator);
    try client.drain();

    // The server's control and decoder streams. Their type bytes are enough to
    // classify them; the client does not need the server's SETTINGS to read a
    // static QPACK block.
    for (0..2) |_| {
        const stream = try connection.acceptStream(io);
        var buffer: [4096]u8 = undefined;
        var vectors = [1][]u8{&buffer};
        const n = try stream.read(io, &vectors);
        try client.feed(@intCast(stream.id), buffer[0..n]);
    }

    var normal: usize = 0;
    var big_reset = false;
    var path_buffer: [16]u8 = undefined;

    for (0..request_count) |i| {
        const path = if (i == 0)
            "/big"
        else
            std.mem.print(&path_buffer, "/{d}", .{i}) catch unreachable;
        const fields = [_]http.Header{
            .{ .name = ":method", .value = "GET" },
            .{ .name = ":scheme", .value = "https" },
            .{ .name = ":authority", .value = "test.local" },
            .{ .name = ":path", .value = path },
        };

        const stream = try connection.openStream(io, .bidi);
        const id: u62 = @intCast(stream.id);
        client.request = stream;
        client.outcome = .{};
        try client.session.submitRequest(testing.allocator, id, &fields, true);
        try client.drain();

        var buffer: [4096]u8 = undefined;
        while (true) {
            var vectors = [1][]u8{&buffer};
            const n = stream.read(io, &vectors) catch |err| switch (err) {
                error.StreamReset => {
                    client.session.reset(testing.allocator, id, 0);
                    try client.events(id);
                    break;
                },
                error.StreamClosed, error.ConnectionClosed => break,
                else => return err,
            };
            if (n == 0) {
                _ = client.session.receive(testing.allocator, id, "", true);
                try client.events(id);
                break;
            }
            try client.feed(id, buffer[0..n]);
        }

        client.session.forgetStream(testing.allocator, id) catch |err| switch (err) {
            error.StreamBusy => return error.StreamNotReleased,
            error.UnknownStream => return error.StreamAlreadyGone,
            else => return err,
        };
        stream.close(io);
        client.request = null;

        if (i == 0) {
            try testing.expect(client.outcome.reset);
            big_reset = true;
        } else {
            try testing.expectEqual(http.Status.ok, client.outcome.status.?);
            try testing.expectEqualStrings(
                body,
                client.outcome.bytes[0..client.outcome.len],
            );
            normal += 1;
        }
    }

    try testing.expect(big_reset);
    try testing.expectEqual(request_count - 1, normal);

    connection.close(io);
    try serving.await(io);
    joined = true;
}
