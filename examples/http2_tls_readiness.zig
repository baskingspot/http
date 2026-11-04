//! A small h2-over-TLS server on the readiness engine.
//!
//!     just example-h2-tls-readiness
//!     just conformance-run-tls-readiness
//!
//! poll(2) on Linux, kqueue(2) on macOS. TLS 1.3 comes from
//! `baskingspot/tls` through its caller-driven `tls_nonblocking` transport;
//! the readiness loop owns the socket and the fixed connection slots.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const print = std.debug.print;

const http = @import("http");
const http_tls = @import("http_tls");
const tls = @import("tls");
const tls_fixture = @import("tls_fixture.zig");

const Engine = switch (builtin.os.tag) {
    .linux => http_tls.h2.engine.tls.poll,
    .macos => http_tls.h2.engine.tls.kqueue,
    else => @compileError("the readiness example is Linux and macOS only"),
};

const address_text = "127.0.0.1:8443";
const response_body = "h2 over tls readiness hello\n";

const App = struct {
    fn handler() http.h2.engine.Handler {
        return .{ .ptr = undefined, .vtable = &.{
            .handle = handle,
            .complete = http.h2.engine.Handler.noopComplete,
            .report_error = reportError,
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
        print("http2-tls-readiness: error: {s}\n", .{@errorName(err)});
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const address: Io.net.IpAddress = try .parseLiteral(address_text);

    var cert_buf: [1024]u8 = undefined;
    const cert = try tls_fixture.decodeCert(&cert_buf);
    const scalar_buf = try tls_fixture.decodeScalar();
    var signer = try tls.signature.PrivateKey.fromP256Scalar(&scalar_buf);
    defer signer.deinit();

    // The readiness transport replaces these fields per connection. They are
    // present to satisfy `ServerHandshake.Config`; no connection uses them.
    var keypairs: tls.ServerHandshake.KeyPairs = try .init(.generate());
    defer keypairs.secureZero();

    var server = try Engine.Server.init(io, address, App.handler(), .{
        .allocator = gpa,
        .max_connections = 64,
        .max_streams = 128,
        .transport = .{
            .handshake = .{
                .keypairs = keypairs,
                .random = .init(@splat(0x72)),
                .alpn_protocols = &.{"h2"},
            },
            .cert_chain = &.{cert},
            .signer = signer.signer(),
        },
    });
    defer server.deinit();

    print("http2-tls-readiness: listening on {s}\n", .{address_text});
    try server.run();
}
