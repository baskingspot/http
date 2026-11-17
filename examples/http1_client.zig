//! An HTTP/1 client against the Go net/http interop server.
//!
//!     just interop
//!
//! This is the high-level client with no TLS: one `create`, one `get` per
//! request, and `readBody` for the one-shot case. The kept-alive connection is
//! reused across the three requests.

const std = @import("std");
const Io = std.Io;
const mem = std.mem;
const print = std.debug.print;

const http = @import("http");
const client = http.client;

const base = "http://127.0.0.1:8091";

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    const http_client = try client.Client.create(allocator, io, .{});
    defer http_client.destroy();

    {
        var response = try http_client.get(base ++ "/");
        defer response.body.close();
        try expectBody(&response, allocator, "hello from go\n");
    }

    {
        var response = try http_client.get(base ++ "/chunked");
        defer response.body.close();
        try expectBody(&response, allocator, "onetwo");
    }

    {
        var response = try http_client.fetch(base ++ "/echo", .{
            .method = .POST,
            .body = "ping",
        });
        defer response.body.close();
        try expectBody(&response, allocator, "ping");
    }

    print("http1-client: interop ok\n", .{});
}

fn expectBody(response: *client.Response, allocator: mem.Allocator, expected: []const u8) !void {
    if (response.head.status.code() != 200) {
        print("status {d}\n", .{response.head.status.code()});
        return error.UnexpectedStatus;
    }
    const body = try response.readBody(allocator, .limited(64 * 1024));
    defer allocator.free(body);
    if (!mem.eql(u8, body, expected)) {
        print("body '{s}', expected '{s}'\n", .{ body, expected });
        return error.UnexpectedBody;
    }
}
