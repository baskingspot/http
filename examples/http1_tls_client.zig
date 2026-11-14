//! An HTTP/1.1 client over TLS 1.3, on std.Io.
//!
//! Start `just example-h1-tls` first, then run this from another terminal.

const std = @import("std");
const Io = std.Io;
const print = std.debug.print;

const http = @import("http");
const tls_std = @import("tls_std");

const address_text = "127.0.0.1:8444";

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const address: Io.net.IpAddress = try .parseLiteral(address_text);
    const stream = try address.connect(io, .{ .mode = .stream });

    var conn: tls_std.Client = undefined;
    try conn.connect(io, stream, .{
        .host = null,
        .verify = .insecure,
        .alpn = &.{"http/1.1"},
    });
    defer conn.deinit();
    defer conn.close();

    const alpn = conn.selectedAlpn() orelse return error.NoAlpn;
    if (!std.mem.eql(u8, alpn, "http/1.1")) return error.WrongAlpn;

    var recv: [16 * 1024]u8 = undefined;
    var headers: [32]http.Header = undefined;
    var trailers: [8]http.Header = undefined;
    var body: [16 * 1024]u8 = undefined;
    var write: [1024]u8 = undefined;

    const response = try http.h1.client.buffered.fetchIo(
        conn.reader(),
        conn.writer(),
        .{
            .method = .GET,
            .target = "/",
            .headers = &.{.{ .name = "Host", .value = "ztls.server.test" }},
        },
        .{
            .recv_buffer = &recv,
            .headers = &headers,
            .trailers = &trailers,
            .body_buffer = &body,
            .write_buffer = &write,
        },
    );

    if (response.head.status.code() != 200) return error.UnexpectedStatus;
    print("http1-tls-client: {s}", .{response.body});
}
