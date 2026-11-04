//! An epoll(7)-based HTTP/1.1 server.
//!
//! Linux only for now. The engine owns a fixed set of nonblocking slots, an
//! accept loop, connection deadlines, and a stop eventfd.

const std = @import("std");
const Io = std.Io;
const print = std.debug.print;

const http = @import("http");
const engine = http.h1.engine.epoll;

const EpollServer = engine.Server(App);
const address_text = "127.0.0.1:8080";
const max_target = 256;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const address: Io.net.IpAddress = try .parseLiteral(address_text);

    var app: App = .{};
    var server = try EpollServer.init(io, address, &app, .{
        .allocator = init.gpa,
        .max_connections = 64,
        .body_bytes = 8 * 1024,
    });
    defer server.deinit();

    print("http1-epoll: listening on {s}\n", .{address_text});
    try server.run();
}

const App = struct {
    pub fn handle(_: *App, exchange: *engine.Exchange) anyerror!void {
        const head = exchange.request.head;
        const target = head.target;

        if (target.len > max_target) {
            try exchange.respond(.{ .status = .uri_too_long }, "request target too long\n");
            return;
        }
        if (http.h1.targetForm(head.method, target) != .origin) {
            try exchange.respond(.{ .status = .bad_request }, "unsupported request-target form\n");
            return;
        }

        const is_root = std.mem.eql(u8, target, "/");
        const method_name = if (head.method) |method| method.token() else "UNKNOWN";
        const body = if (is_root)
            try std.fmt.bufPrint(
                exchange.response_body,
                "{s} {s} ({d}-byte body)\n",
                .{ method_name, target, exchange.request.body.len },
            )
        else
            "not found\n";

        try exchange.respond(.{
            .status = if (is_root) .ok else .not_found,
            .content_type = "text/plain; charset=utf-8",
        }, body);
    }

    pub fn onError(_: *App, err: anyerror) void {
        print("http1-epoll: {s}\n", .{@errorName(err)});
    }
};
