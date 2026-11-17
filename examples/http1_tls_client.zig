//! An HTTP/1.1 client over TLS 1.3 against the local example server.
//!
//! Start `just example-h1-tls` first, then run this from another terminal with
//! `just example-h1-tls-client`.
//!
//! The URL names the certificate, and `.address` points the dial at loopback,
//! so hostname verification still runs against `ztls.server.test` while the
//! connection goes to 127.0.0.1.

const std = @import("std");
const Io = std.Io;
const print = std.debug.print;

const http_tls = @import("http_tls");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    var client: http_tls.Client = undefined;
    try client.init(allocator, io, .{
        .insecure_no_chain_anchor = true,
        .alpn = &.{"http/1.1"},
    });
    defer client.deinit();

    const address: Io.net.IpAddress = try .parseLiteral("127.0.0.1:8444");
    var response = try client.fetch("https://ztls.server.test:8444/", .{
        .method_token = "GET",
        .address = address,
    });
    defer response.body.close();

    if (response.head.status.code() != 200) return error.UnexpectedStatus;
    const body = try response.readBody(allocator, .limited(64 * 1024));
    defer allocator.free(body);
    print("http1-tls-client: {s}", .{body});
}
