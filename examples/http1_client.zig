//! An HTTP/1 client over std.Io against the Go net/http interop server.

const std = @import("std");
const Io = std.Io;
const print = std.debug.print;

const http = @import("http");
const client = http.h1.client.buffered;

const address_text = "127.0.0.1:8091";

const Buffers = struct {
    recv: [16 * 1024]u8 = undefined,
    headers: [32]http.Header = undefined,
    trailers: [8]http.Header = undefined,
    body: [16 * 1024]u8 = undefined,
    write: [1024]u8 = undefined,

    fn config(self: *Buffers) client.Config {
        return .{
            .recv_buffer = &self.recv,
            .headers = &self.headers,
            .trailers = &self.trailers,
            .body_buffer = &self.body,
            .write_buffer = &self.write,
        };
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const address: Io.net.IpAddress = try .parseLiteral(address_text);
    var buffers: Buffers = .{};

    const root = try fetch(io, address, .GET, "/", "", &buffers);
    try expectBody(root, "hello from go\n");

    const chunked = try fetch(io, address, .GET, "/chunked", "", &buffers);
    try expectBody(chunked, "onetwo");

    const echoed = try fetch(io, address, .POST, "/echo", "ping", &buffers);
    try expectBody(echoed, "ping");

    print("http1-client: interop ok\n", .{});
}

fn fetch(
    io: Io,
    address: Io.net.IpAddress,
    method: http.Method,
    target: []const u8,
    body: []const u8,
    buffers: *Buffers,
) !client.Response {
    const stream = try address.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    return client.fetch(io, stream, .{
        .method = method,
        .target = target,
        .headers = &.{.{ .name = "Host", .value = address_text }},
        .body = body,
    }, buffers.config());
}

fn expectBody(response: client.Response, expected: []const u8) !void {
    if (response.head.status.code() != 200) {
        print("status {d}\n", .{response.head.status.code()});
        return error.UnexpectedStatus;
    }
    if (!std.mem.eql(u8, response.body, expected)) {
        print("body '{s}', expected '{s}'\n", .{ response.body, expected });
        return error.UnexpectedBody;
    }
}
