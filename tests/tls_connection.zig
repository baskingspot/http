//! Loopback test for `http_tls.client.Connection`.
//!
//! The TLS connection owns a socket, so it needs a peer on a real one. A
//! listener thread drives `tls_nonblocking.Server` through the handshake and
//! echoes application data; the client side is the module under test.
//!
//! The fixtures are a test CA and a leaf it signed for `ztls.server.test`,
//! valid from 2026-11-08 to 2036-11-05. Not deployment identities. The shared
//! `baskingspot/tls` fixture certificate cannot be used here: it is an end
//! entity, and an end entity cannot anchor a chain.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const Io = std.Io;

const http = @import("http");
const http_tls = @import("http_tls");
const tls = @import("tls");
const tls_nonblocking = @import("tls_nonblocking");
const time = @import("stdx").time;

const Server = tls_nonblocking.Server;
const ServerHandshake = tls.ServerHandshake;

const Connection = http_tls.client.Connection;

/// 2027-01-01T00:00:00Z, inside the fixtures' validity window.
const now_sec: i64 = 1_798_761_600;

const ca_b64 =
    "MIIBoTCCAUegAwIBAgIUYElwU9zW7k8K0l+/pLW0cooLRu4wCgYIKoZIzj0EAwIwHjEcMBoG" ++
    "A1UEAwwTYmFza2luZ3Nwb3QgdGVzdCBDQTAeFw0yNjExMDgyMTI5MTJaFw0zNjExMDUyMTI5" ++
    "MTJaMB4xHDAaBgNVBAMME2Jhc2tpbmdzcG90IHRlc3QgQ0EwWTATBgcqhkjOPQIBBggqhkjO" ++
    "PQMBBwNCAAQ0i5xrrCogTXE8NieIB6Q7I6nEDRlhFy9+cBAdvE1N2bear/26RFwRfy85TCQQ" ++
    "1pfy7joeEJ7OMs6S5HqmLZMfo2MwYTAdBgNVHQ4EFgQUXklNCmBTwvBUBxWWUG+P3HMlic0w" ++
    "HwYDVR0jBBgwFoAUXklNCmBTwvBUBxWWUG+P3HMlic0wDwYDVR0TAQH/BAUwAwEB/zAOBgNV" ++
    "HQ8BAf8EBAMCAQYwCgYIKoZIzj0EAwIDSAAwRQIgGhkKrs3Ti7XbyHnHAbXeGoxoBEavp5ye" ++
    "DfHcnzBQxGUCIQDMLiQu6kV+FqRNS/inwPosu4qRRJe8Po7dHxEsMkDXhQ==";

const leaf_b64 =
    "MIIB0DCCAXWgAwIBAgIUEDqD3Y5azscjzRoDRLEJpxijgyswCgYIKoZIzj0EAwIwHjEcMBoG" ++
    "A1UEAwwTYmFza2luZ3Nwb3QgdGVzdCBDQTAeFw0yNjExMDgyMTI5MTJaFw0zNjExMDUyMTI5" ++
    "MTJaMBsxGTAXBgNVBAMMEHp0bHMuc2VydmVyLnRlc3QwWTATBgcqhkjOPQIBBggqhkjOPQMB" ++
    "BwNCAARRbBYdrnrz6oaIU2defGKr1Trlm1NL6+qqa+mmSG3AOiQoFD4BZtorlv1FBKDwgXZT" ++
    "MNwzzEoU7QNmBOUbhuRto4GTMIGQMBsGA1UdEQQUMBKCEHp0bHMuc2VydmVyLnRlc3QwDAYD" ++
    "VR0TAQH/BAIwADAOBgNVHQ8BAf8EBAMCB4AwEwYDVR0lBAwwCgYIKwYBBQUHAwEwHQYDVR0O" ++
    "BBYEFP9OTNiyuMqZKCiKd4UydrqVCmfcMB8GA1UdIwQYMBaAFF5JTQpgU8LwVAcVllBvj9xz" ++
    "JYnNMAoGCCqGSM49BAMCA0kAMEYCIQCtVJEtDQDDtmk6t6p5ahEhI7iA1Mipc7uY9z7DAd8B" ++
    "5QIhAIBubxJiTeZbKG6jZxYpzFEvdksUhZRqUS6RzKkI7AVz";

const leaf_scalar_b64 = "CH5wDP96TpNJK4U/29zPZbad1B24GBkqcNqakuC0e1g=";

/// The `comptime P` syscall backend the transports take. The listener thread
/// drives the server transport over the accepted stream's fd. It matches the
/// choice `http_tls.client.Connection` makes: poll(2) on Linux and kqueue(2)
/// on macOS.
const Platform = switch (builtin.os.tag) {
    .linux => http.h2.engine.wait_poll.Wait.Platform,
    .macos => http.h2.engine.wait_kqueue.Wait.Platform,
    else => http.h2.engine.wait_poll.Wait.Platform,
};

/// `tls` wants DER in `cert_chain`; a PEM blob there fails on the peer as
/// `CertificateFieldHasWrongDataType`, which reads like a bad certificate
/// rather than a bad container.
fn derAlloc(allocator: std.mem.Allocator, b64: []const u8) ![]u8 {
    const len = try std.base64.standard.Decoder.calcSizeForSlice(b64);
    const der = try allocator.alloc(u8, len);
    errdefer allocator.free(der);
    try std.base64.standard.Decoder.decode(der, b64);
    return der;
}

fn pemAlloc(allocator: std.mem.Allocator, b64: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "-----BEGIN CERTIFICATE-----\n{s}\n-----END CERTIFICATE-----\n",
        .{b64},
    );
}

const ServerThread = struct {
    io: Io,
    listener: *Io.net.Server,
    leaf: []const u8,
    /// Protocols the server accepts, in preference order.
    alpn: []const []const u8 = &.{"h2"},
    /// Answer the first complete request head with this and close, instead of
    /// echoing. A request can arrive in several TLS records, so the head is
    /// accumulated until the blank line.
    response: ?[]const u8 = null,
    request: [2048]u8 = undefined,
    request_len: usize = 0,
    outcome: ?anyerror = null,

    /// Drive the server transport until the peer closes, echoing plaintext.
    fn run(self: *ServerThread) void {
        self.serve() catch |err| {
            self.outcome = err;
        };
    }

    /// Append application bytes to the request buffer; a head that fills it is
    /// not a request this fixture needs to answer.
    fn collect(self: *ServerThread, bytes: []const u8) !void {
        if (self.request_len + bytes.len > self.request.len) return error.RequestTooLarge;
        @memcpy(self.request[self.request_len..][0..bytes.len], bytes);
        self.request_len += bytes.len;
    }

    fn serve(self: *ServerThread) !void {
        const io = self.io;

        var stream = try self.listener.accept(io);
        defer stream.close(io);

        var scalar: [32]u8 = undefined;
        try std.base64.standard.Decoder.decode(&scalar, leaf_scalar_b64);
        var private_key = try tls.signature.PrivateKey.fromP256Scalar(&scalar);
        defer private_key.deinit();

        var server: Server = undefined;
        var record: [tls.RecordBuffer.min_storage]u8 = undefined;
        var out: [tls.frame.max_wire_record_len]u8 = undefined;
        var reassembly: [ServerHandshake.ch_reassembly_buffer_size]u8 = undefined;
        var config: ServerHandshake.Config = .{
            .keypairs = try .init(.generate()),
            .random = undefined,
            .reassembly = &reassembly,
        };
        defer config.keypairs.secureZero();
        defer config.random.secureZero();
        try io.randomSecure(&config.random.data);
        try server.init(
            &.{
                .handshake = .{ .alpn_protocols = self.alpn },
                .cert_chain = &.{self.leaf},
                .signer = private_key.signer(),
            },
            config,
            .{ .record = &record, .out = &out },
        );
        defer server.deinit();

        const fd = stream.socket.handle;
        while (true) {
            // Flush first: the client waits on our flight before it answers.
            const wire = server.sendBuffer();
            if (wire.len != 0) {
                const written = Platform.send(fd, &.{}, wire) catch return;
                if (written == 0) return;
                server.sent(written);
                continue;
            }
            switch (server.next() catch return) {
                .need_input => {
                    const dest = server.receiveBuffer();
                    if (dest.len == 0) return;
                    const n = Platform.read(fd, dest) catch return;
                    if (n == 0) {
                        server.endInput();
                        return;
                    }
                    server.received(n);
                },
                .application_data => |bytes| {
                    if (self.response) |response| {
                        try self.collect(bytes);
                        server.consumeApplication(bytes.len);
                        const head = self.request[0..self.request_len];
                        if (std.mem.find(u8, head, "\r\n\r\n") != null) {
                            try sendPlain(&server, fd, response);
                            return;
                        }
                        continue;
                    }
                    var offset: usize = 0;
                    while (offset < bytes.len) {
                        const accepted = server.write(bytes[offset..]) catch return;
                        offset += accepted;
                        const echo = server.sendBuffer();
                        if (echo.len != 0) {
                            const written = Platform.send(fd, &.{}, echo) catch return;
                            if (written == 0) return;
                            server.sent(written);
                        }
                        if (accepted == 0) return;
                    }
                    server.consumeApplication(bytes.len);
                },
                .need_output, .progress, .handshake_complete, .key_update => {},
                .close_notify, .closed => return,
                .early_data => return,
            }
        }
    }
};

/// Write every byte of `bytes` as application data, flushing as it goes.
fn sendPlain(server: *Server, fd: std.posix.socket_t, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const accepted = try server.write(bytes[offset..]);
        offset += accepted;
        const wire = server.sendBuffer();
        if (wire.len != 0) {
            const written = Platform.send(fd, &.{}, wire) catch return error.TransportClosed;
            if (written == 0) return error.TransportClosed;
            server.sent(written);
        }
        if (accepted == 0) return error.NoProgress;
    }
}

const Harness = struct {
    io: Io,
    listener: Io.net.Server,
    address: Io.net.IpAddress,
    thread_data: ServerThread,
    thread: std.Thread,

    const Options = struct {
        alpn: []const []const u8 = &.{"h2"},
        response: ?[]const u8 = null,
    };

    fn init(
        self: *Harness,
        allocator: std.mem.Allocator,
        leaf: []const u8,
        options: Options,
    ) !void {
        self.io = testing.io;
        self.address = try .parseLiteral("127.0.0.1:0");
        self.listener = try self.address.listen(self.io, .{
            .mode = .stream,
            .reuse_address = true,
        });
        self.address.setPort(self.listener.socket.address.getPort());
        self.thread_data = .{
            .io = self.io,
            .listener = &self.listener,
            .leaf = leaf,
            .alpn = options.alpn,
            .response = options.response,
        };
        _ = allocator;
        self.thread = try .spawn(.{}, ServerThread.run, .{&self.thread_data});
    }

    fn deinit(self: *Harness) void {
        self.thread.join();
        self.listener.deinit(self.io);
        if (self.thread_data.outcome) |err| {
            std.debug.panic("server thread failed: {s}", .{@errorName(err)});
        }
        self.* = undefined;
    }
};

test "the connection reads and writes plaintext over TLS" {
    const allocator = testing.allocator;

    const leaf_der = try derAlloc(allocator, leaf_b64);
    defer allocator.free(leaf_der);
    const ca_pem = try pemAlloc(allocator, ca_b64);
    defer allocator.free(ca_pem);

    var harness: Harness = undefined;
    try harness.init(allocator, leaf_der, .{});
    defer harness.deinit();

    const socket = try harness.address.connect(harness.io, .{ .mode = .stream });
    defer socket.close(harness.io);

    var conn: Connection = undefined;
    try conn.init(allocator, harness.io, socket, .{
        .ca_pem = ca_pem,
        .host_name = "ztls.server.test",
        .now_sec = now_sec,
        .alpn = &.{"h2"},
    });
    defer conn.deinit();

    // Chain verification ran: the leaf is signed by the CA we handed in.
    try testing.expect(!conn.expired());

    const w = conn.writer();
    const r = conn.reader();

    try w.writeAll("hello");
    var got: [5]u8 = undefined;
    try r.readSliceAll(&got);
    try testing.expectEqualStrings("hello", &got);

    // A second round trip, to prove the connection is still in step after the
    // first one and no plaintext was consumed twice.
    try w.writeAll("second");
    var again: [6]u8 = undefined;
    try r.readSliceAll(&again);
    try testing.expectEqualStrings("second", &again);
}

test "a passed deadline ends the wait and reports itself" {
    const allocator = testing.allocator;

    const leaf_der = try derAlloc(allocator, leaf_b64);
    defer allocator.free(leaf_der);
    const ca_pem = try pemAlloc(allocator, ca_b64);
    defer allocator.free(ca_pem);

    var harness: Harness = undefined;
    try harness.init(allocator, leaf_der, .{});
    defer harness.deinit();

    const socket = try harness.address.connect(harness.io, .{ .mode = .stream });
    defer socket.close(harness.io);

    var conn: Connection = undefined;
    try conn.init(allocator, harness.io, socket, .{
        .ca_pem = ca_pem,
        .host_name = "ztls.server.test",
        .now_sec = now_sec,
        .alpn = &.{"h2"},
    });
    defer conn.deinit();

    // Nothing is in flight, so a read can only end by the deadline.
    conn.setDeadline(try .init(.fromNanoseconds(0)));
    var buf: [8]u8 = undefined;
    try testing.expectError(error.ReadFailed, conn.reader().readSliceAll(&buf));
    // `Io.Reader` cannot report a timeout, so the connection remembers it.
    try testing.expect(conn.expired());

    // Clearing the deadline makes the connection usable again.
    conn.setDeadline(.none);
    try conn.writer().writeAll("still here");
    conn.setDeadline(try .init(.fromNanoseconds(0)));
    try testing.expectError(error.ReadFailed, conn.reader().readSliceAll(&buf));
}

test "the connector dials https and serves a request" {
    const allocator = testing.allocator;

    const leaf_der = try derAlloc(allocator, leaf_b64);
    defer allocator.free(leaf_der);
    const ca_pem = try pemAlloc(allocator, ca_b64);
    defer allocator.free(ca_pem);

    var harness: Harness = undefined;
    try harness.init(allocator, leaf_der, .{
        .alpn = &.{"http/1.1"},
        .response = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello",
    });
    defer harness.deinit();

    // The certificate names `ztls.server.test`, which does not resolve in this
    // process, so the dial takes the address override and the URL host still
    // drives SNI and the certificate check.
    var text: [96]u8 = undefined;
    const url_text = try std.fmt.bufPrint(
        &text,
        "https://ztls.server.test:{d}/v1/secret",
        .{harness.address.getPort()},
    );
    const url = try http.client.Url.parse(allocator, url_text);
    defer url.deinit(allocator);

    var connector: http_tls.client.Connector = .init(.{ .ca_pem = ca_pem });
    var client: http.client.Client = undefined;
    try client.init(allocator, harness.io, .{ .transport = connector.handle() });
    defer client.deinit();

    var response = try client.send(url, .{
        .method_token = "GET",
        .address = harness.address,
    });
    defer response.body.close();

    // The client offered h2 first and the server only accepts http/1.1, so the
    // selection decides the adapter.
    try testing.expectEqual(http.client.Protocol.h1, client.protocol().?);

    var got: [8]u8 = undefined;
    var writer: Io.Writer = .fixed(&got);
    const used = try response.body.reader.streamRemaining(&writer);
    try testing.expectEqualStrings("hello", got[0..used]);
    try testing.expect(response.body.outcome() == null);
}

test "the connector refuses a cleartext URL" {
    var connector: http_tls.client.Connector = .init(.{});
    const url = try http.client.Url.parse(testing.allocator, "http://127.0.0.1:1/");
    defer url.deinit(testing.allocator);
    try testing.expectError(error.PlainUnsupported, connector.handle().connect(.{
        .io = testing.io,
        .gpa = testing.allocator,
        .url = url,
    }));
}

/// Says keep going for `after_ns`, then stops. The delay is what proves the
/// handshake read itself is bounded: without that, the hook would never run
/// again inside a read that waits to the deadline.
const AbortState = struct {
    io: Io,
    start: i96 = 0,
    after_ns: i96,
    seen: usize = 0,

    fn step(context: *anyopaque, phase: http.client.transport.Phase) bool {
        const self: *AbortState = @ptrCast(@alignCast(context));
        self.seen += 1;
        if (phase != .handshake) return true;
        const now = Io.Clock.awake.now(self.io).nanoseconds;
        return now - self.start < self.after_ns;
    }
};

test "a progress hook aborts a handshake the peer never answers" {
    // The regression guard is the five second budget, and 0.16 refuses a
    // socket deadline outright.
    if (comptime !http.client.plain.deadline_supported) return error.SkipZigTest;

    const allocator = testing.allocator;

    // The listener never accepts, so the kernel completes the TCP connect and
    // the handshake then waits for a ServerHello that never comes. A five
    // second budget keeps a regression from hanging the suite.
    var address: Io.net.IpAddress = try .parseLiteral("127.0.0.1:0");
    var listener = try address.listen(testing.io, .{
        .mode = .stream,
        .reuse_address = true,
    });
    defer listener.deinit(testing.io);
    address.setPort(listener.socket.address.getPort());

    var text: [96]u8 = undefined;
    const url = try http.client.Url.parse(
        allocator,
        try std.fmt.bufPrint(&text, "https://ztls.server.test:{d}/", .{address.getPort()}),
    );
    defer url.deinit(allocator);

    const now = @as(u64, @intCast(time.now(.awake).nanoseconds));
    const budget = try time.OptionalTimestamp.init(
        time.Timestamp.fromNanoseconds(now + 5 * std.time.ns_per_s),
    );

    var state: AbortState = .{ .io = testing.io, .after_ns = 150 * std.time.ns_per_ms };
    state.start = Io.Clock.awake.now(testing.io).nanoseconds;
    var connector: http_tls.client.Connector = .init(.{
        .insecure_no_chain_anchor = true,
    });
    try testing.expectError(error.Canceled, connector.handle().connect(.{
        .io = testing.io,
        .gpa = allocator,
        .url = url,
        .address = address,
        .connect_deadline = budget,
        .progress = .{ .context = &state, .step = AbortState.step },
    }));
    const elapsed = Io.Clock.awake.now(testing.io).nanoseconds - state.start;
    try testing.expect(elapsed < std.time.ns_per_s);
    try testing.expect(state.seen >= 2);
}
