//! One TLS port serving HTTP/1.1 and HTTP/2 by ALPN.
//!
//!     just example-unified
//!     just curl https://127.0.0.1:8445/
//!     curl -k --http1.1 https://127.0.0.1:8445/
//!
//! The handshake selects the protocol before any HTTP byte. Each connection
//! then runs the matching blocking engine over the TLS reader and writer.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const print = std.debug.print;

const http = @import("http");
const tls = @import("tls");
const tls_std = @import("tls_std");
const tls_fixture = @import("tls_fixture.zig");

const address_text = "127.0.0.1:8445";

const H1App = struct {
    fn handler() http.h1.engine.Handler {
        return .{ .ptr = undefined, .vtable = &.{
            .handle = handle,
            .complete = http.h1.engine.Handler.noopComplete,
            .report_error = reportError,
            .policy_response = http.h1.engine.Handler.defaultPolicyResponse,
        } };
    }

    fn handle(_: *anyopaque, exchange: *http.h1.engine.Exchange) anyerror!void {
        try exchange.respond(.{
            .status = .ok,
            .content_type = "text/plain; charset=utf-8",
        }, "h1 on the shared port\n");
    }

    fn reportError(_: *anyopaque, err: anyerror) void {
        print("unified: h1: {s}\n", .{@errorName(err)});
    }
};

const H2App = struct {
    fn handler() http.h2.engine.Handler {
        return .{ .ptr = undefined, .vtable = &.{
            .handle = handle,
            .complete = http.h2.engine.Handler.noopComplete,
            .report_error = reportError,
            .policy_response = http.h2.engine.Handler.defaultPolicyResponse,
        } };
    }

    fn handle(_: *anyopaque, exchange: *http.h2.engine.Exchange) anyerror!void {
        try exchange.respond(.{
            .status = .ok,
            .content_type = "text/plain; charset=utf-8",
        }, "h2 on the shared port\n");
    }

    fn reportError(_: *anyopaque, err: anyerror) void {
        print("unified: h2: {s}\n", .{@errorName(err)});
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

    print("unified: listening on {s}\n", .{address_text});

    while (true) {
        const stream = listener.accept(io) catch |err| {
            print("unified: accept: {s}\n", .{@errorName(err)});
            continue;
        };
        const thread = std.Thread.spawn(.{}, serveThread, .{ gpa, io, stream }) catch |err| {
            print("unified: thread: {s}\n", .{@errorName(err)});
            stream.close(io);
            continue;
        };
        thread.detach();
    }
}

fn serveThread(gpa: Allocator, io: Io, stream: Io.net.Stream) void {
    serveConnection(gpa, io, stream) catch |err| {
        print("unified: connection: {s}\n", .{@errorName(err)});
    };
}

fn serveConnection(gpa: Allocator, io: Io, stream: Io.net.Stream) !void {
    var cert_buffer: [1024]u8 = undefined;
    const cert = try tls_fixture.decodeCert(&cert_buffer);
    const scalar = try tls_fixture.decodeScalar();

    var signer = try tls.signature.PrivateKey.fromP256Scalar(&scalar);
    defer signer.deinit();

    var conn: tls_std.Server = undefined;
    try conn.accept(io, stream, .{
        .cert_chain = &.{cert},
        .signer = signer.signer(),
        .alpn = &.{ "h2", "http/1.1" },
    });
    defer conn.deinit();
    defer conn.close();

    const alpn = conn.selectedAlpn() orelse return error.NoAlpn;
    if (std.mem.eql(u8, alpn, "h2")) {
        var read_buffer: [16 * 1024]u8 = undefined;
        var write_buffer: [4 * 1024]u8 = undefined;
        try http.h2.engine.blocking.serveIo(
            conn.reader(),
            conn.writer(),
            H2App.handler(),
            .{
                .allocator = gpa,
                .read_buffer = &read_buffer,
                .write_buffer = &write_buffer,
                .common = .{},
            },
        );
        return;
    }
    if (std.mem.eql(u8, alpn, "http/1.1")) {
        var request_buffer: [16 * 1024]u8 = undefined;
        var headers: [64]http.Header = undefined;
        var response_head: [1024]u8 = undefined;
        try http.h1.engine.blocking.serveIo(
            io,
            conn.reader(),
            conn.writer(),
            H1App.handler(),
            .{
                .allocator = gpa,
                .request_buffer = &request_buffer,
                .headers = &headers,
                .response_head_buffer = &response_head,
                .common = .{ .body_bytes = 8 * 1024 },
            },
        );
        return;
    }
    return error.UnsupportedAlpn;
}
