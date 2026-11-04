//! A small h2c server on the readiness (poll) engine.
//!
//!     just example-h2-poll
//!     just conformance
//!
//! The handler is the same exchange handler as the blocking example; the
//! transport is one thread with fixed connection slots.

const std = @import("std");
const Io = std.Io;
const print = std.debug.print;

const http = @import("http");

const address_text = "127.0.0.1:8081";
const response_body = "h2c hello\n";

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
        print("http2-poll: error: {s}\n", .{@errorName(err)});
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const address: Io.net.IpAddress = try .parseLiteral(address_text);

    var server = try http.h2.engine.poll.Server.init(io, address, App.handler(), .{
        .allocator = gpa,
        .max_connections = 64,
        .max_streams = 128,
    });
    defer server.deinit();

    print("http2-poll: listening on {s}\n", .{address_text});
    try server.run();
}
