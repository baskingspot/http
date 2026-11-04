//! A small blocking HTTP/1.1 server over std.Io.
//!
//!     just example
//!     curl -v http://127.0.0.1:8080/
//!
//! The engine owns the connection. `handle` sees a complete request and
//! formats a response body into the per-connection scratch.

const std = @import("std");
const Io = std.Io;
const print = std.debug.print;

const http = @import("http");
const engine = http.engine.blocking;

const address_text = "127.0.0.1:8080";
const max_target = 256;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const address: Io.net.IpAddress = try .parseLiteral(address_text);

    var listener = try address.listen(io, .{
        .mode = .stream,
        .reuse_address = true,
    });
    defer listener.deinit(io);

    print("http1-server: listening on {s}\n", .{address_text});

    var request_buffer: [16 * 1024]u8 = undefined;
    var headers: [64]http.Header = undefined;
    var response_head: [1024]u8 = undefined;
    var response_body: [512]u8 = undefined;

    try engine.run(io, &listener, .{
        .context = null,
        .handle = handle,
        .on_error = report,
    }, .{
        .request_buffer = &request_buffer,
        .headers = &headers,
        .response_head_buffer = &response_head,
        .response_body_buffer = &response_body,
        .body_bytes = 8 * 1024,
    });
}

fn handle(_: ?*anyopaque, call: *engine.Call) anyerror!void {
    const head = call.request.head;
    const target = head.target;

    if (target.len > max_target) {
        try call.conn.respond(.{ .status = .uri_too_long }, "request target too long\n");
        return;
    }
    if (http.h1.targetForm(head.method, target) != .origin) {
        try call.conn.respond(.{ .status = .bad_request }, "unsupported request-target form\n");
        return;
    }

    const is_root = std.mem.eql(u8, target, "/");
    const method_name = if (head.method) |method| method.token() else "UNKNOWN";
    const body = if (is_root)
        try std.fmt.bufPrint(
            call.response_body,
            "{s} {s} ({d}-byte body)\n",
            .{ method_name, target, call.request.body.len },
        )
    else
        "not found\n";

    try call.conn.respond(.{
        .status = if (is_root) .ok else .not_found,
        .content_type = "text/plain; charset=utf-8",
    }, body);
}

fn report(_: ?*anyopaque, err: anyerror) void {
    print("http1-server: {s}\n", .{@errorName(err)});
}
