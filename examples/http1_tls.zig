//! An HTTP/1.1 server over TLS 1.3 on the direct engine.
//!
//!     just example-h1-tls
//!     curl -k https://127.0.0.1:8444/
//!     curl -kN https://127.0.0.1:8444/events
//!
//! TLS comes from `baskingspot/tls` through `tls_std`. The handshake is
//! eager; its reader and writer are the plaintext transport for the h1
//! direct engine. One thread per connection. The certificate is a leaf signed
//! by a test CA, so a client can verify the chain against that CA.
//!
//! `/events` is a `text/event-stream` that ends after five one-second ticks.
//! `examples/sse_client.zig` reads it.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const print = std.debug.print;

const http = @import("http");
const tls = @import("tls");
const tls_std = @import("tls_std");

const address_text = "127.0.0.1:8444";
const response_body = "h1 over tls hello\n";

const fixture = @import("tls_ca_fixture.zig");

const Handler = http.h1.engine.Handler;

const tick_count = 5;

/// One event a second, then a clean end. The direct engine serves one
/// connection per thread, so `next` may sleep.
const Ticks = struct {
    io: Io,
    sent: usize = 0,
    buffer: [32]u8 = undefined,

    const vtable: http.stream.ReadStream.VTable = .{ .next = next, .close = close };

    fn next(ptr: *anyopaque) http.stream.ReadError!http.stream.ReadResult {
        const self: *Ticks = @ptrCast(@alignCast(ptr));
        if (self.sent == tick_count) return error.EndOfStream;
        self.io.sleep(.fromSeconds(1), .awake) catch return error.Canceled;
        const event = std.mem.print(&self.buffer, "data: tick {d}\n\n", .{self.sent}) catch
            return error.ReadFailed;
        self.sent += 1;
        return .{ .data = event };
    }

    fn close(_: *anyopaque) void {}
};

const App = struct {
    io: Io,

    fn handler(self: *App) Handler {
        return .{ .ptr = self, .vtable = &.{
            .handle = handle,
            .complete = Handler.noopComplete,
            .report_error = reportError,
            .policy_response = Handler.defaultPolicyResponse,
        } };
    }

    fn handle(ptr: *anyopaque, exchange: *http.h1.engine.Exchange) anyerror!void {
        const self: *App = @ptrCast(@alignCast(ptr));
        if (std.mem.eql(u8, exchange.request.head.target, "/events")) {
            const ticks = try exchange.arena.create(Ticks);
            ticks.* = .{ .io = self.io };
            return exchange.respondStream(.{
                .status = .ok,
                .content_type = "text/event-stream",
            }, .{
                .stream = .{ .ptr = ticks, .vtable = &Ticks.vtable },
                .content_length = null,
            });
        }
        try exchange.respond(.{
            .status = .ok,
            .content_type = "text/plain; charset=utf-8",
        }, response_body);
    }

    fn reportError(_: *anyopaque, err: anyerror) void {
        print("http1-tls: error: {s}\n", .{@errorName(err)});
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const address: Io.net.IpAddress = try .parseLiteral(address_text);

    var listener = try address.listen(io, .{
        .mode = .stream,
        .reuse_address = true,
    });
    defer listener.deinit(io);

    print("http1-tls: listening on {s}\n", .{address_text});

    while (true) {
        const stream = listener.accept(io) catch |err| {
            print("http1-tls: accept: {s}\n", .{@errorName(err)});
            continue;
        };
        const thread = std.Thread.spawn(.{}, serveThread, .{ gpa, io, stream }) catch |err| {
            print("http1-tls: thread: {s}\n", .{@errorName(err)});
            stream.close(io);
            continue;
        };
        thread.detach();
    }
}

fn serveThread(gpa: Allocator, io: Io, stream: Io.net.Stream) void {
    serveConnection(gpa, io, stream) catch |err| App.reportError(undefined, err);
}

fn serveConnection(gpa: Allocator, io: Io, stream: Io.net.Stream) !void {
    var cert_buf: [1024]u8 = undefined;
    const cert = try fixture.decodeLeaf(&cert_buf);
    const scalar = try fixture.decodeScalar();

    var signer = try tls.signature.PrivateKey.fromP256Scalar(&scalar);
    defer signer.deinit();

    var conn: tls_std.Server = undefined;
    var scratch: tls_std.Server.Scratch = .init;
    try conn.accept(io, stream, .{
        .cert_chain = &.{cert},
        .signer = signer.signer(),
        .alpn = &.{"http/1.1"},
    }, &scratch);
    defer conn.deinit();
    defer conn.close();

    const alpn = conn.selectedAlpn() orelse return error.NoAlpn;
    if (!std.mem.eql(u8, alpn, "http/1.1")) return error.WrongAlpn;

    var app: App = .{ .io = io };
    var request_buffer: [16 * 1024]u8 = undefined;
    var headers: [64]http.Header = undefined;
    var response_head: [1024]u8 = undefined;
    try http.h1.engine.direct.serveIo(
        io,
        conn.reader(),
        conn.writer(),
        app.handler(),
        .{
            .allocator = gpa,
            .request_buffer = &request_buffer,
            .headers = &headers,
            .response_head_buffer = &response_head,
            .common = .{ .body_bytes = 8 * 1024 },
        },
    );
}
