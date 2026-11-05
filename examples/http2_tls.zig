//! A small h2c-over-TLS (h2) server on the blocking engine.
//!
//!     just example-h2-tls
//!     just conformance-run-tls
//!
//! TLS 1.3 comes from `baskingspot/tls` through its blocking `tls_std`
//! integration: the handshake is eager, then its reader and writer are the
//! plaintext transport for the h2 engine. One thread per connection.
//!
//! The certificate and scalar are the public test fixture from
//! `baskingspot/tls`; they are not a deployment identity.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const print = std.debug.print;

const http = @import("http");
const tls = @import("tls");
const tls_std = @import("tls_std");

const address_text = "127.0.0.1:8443";
const response_body = "h2c over tls hello\n";

const tls_fixture = @import("tls_fixture.zig");

const Handler = http.h2.engine.Handler;

const App = struct {
    fn handler() Handler {
        return .{ .ptr = undefined, .vtable = &.{
            .handle = handle,
            .complete = Handler.noopComplete,
            .report_error = reportError,
            .policy_response = Handler.defaultPolicyResponse,
        } };
    }

    fn handle(_: *anyopaque, exchange: *http.h2.engine.Exchange) anyerror!void {
        const is_head = std.mem.eql(u8, exchange.request.head.method_token, "HEAD");
        try exchange.respond(.{
            .status = .ok,
            .content_type = "text/plain; charset=utf-8",
        }, if (is_head) "" else response_body);
    }

    fn reportError(_: *anyopaque, err: anyerror) void {
        print("http2-tls: error: {s}\n", .{@errorName(err)});
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

    print("http2-tls: listening on {s}\n", .{address_text});

    while (true) {
        const stream = listener.accept(io) catch |err| {
            print("http2-tls: accept: {s}\n", .{@errorName(err)});
            continue;
        };
        const thread = std.Thread.spawn(.{}, serveThread, .{ gpa, io, stream }) catch |err| {
            print("http2-tls: thread: {s}\n", .{@errorName(err)});
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
    const cert = try tls_fixture.decodeCert(&cert_buf);
    const scalar_buf = try tls_fixture.decodeScalar();

    var signer = try tls.signature.PrivateKey.fromP256Scalar(&scalar_buf);
    defer signer.deinit();

    var conn: tls_std.Server = undefined;
    try conn.accept(io, stream, .{
        .cert_chain = &.{cert},
        .signer = signer.signer(),
        .alpn = &.{"h2"},
    });
    defer conn.deinit();
    defer conn.close();

    const alpn = conn.selectedAlpn() orelse return error.NoAlpn;
    if (!std.mem.eql(u8, alpn, "h2")) return error.WrongAlpn;
    print("http2-tls: handshake complete (ALPN={s})\n", .{alpn});

    var read_buffer: [16 * 1024]u8 = undefined;
    var write_buffer: [1]u8 = undefined;
    try http.h2.engine.blocking.serveIo(
        conn.reader(),
        conn.writer(),
        App.handler(),
        .{
            .allocator = gpa,
            .read_buffer = &read_buffer,
            .write_buffer = &write_buffer,
            .max_streams = 128,
            .common = .{},
        },
    );
}
