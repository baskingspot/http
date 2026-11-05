//! A small h2c server on the readiness engine.
//!
//!     just example-h2-readiness
//!     just conformance-run-readiness
//!
//! poll(2) on Linux, kqueue(2) on macOS. The handler is the same exchange
//! handler as the blocking example; the transport is one thread with fixed
//! connection slots.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const print = std.debug.print;

const http = @import("http");

const Engine = switch (builtin.os.tag) {
    .linux => http.h2.engine.poll,
    .macos => http.h2.engine.kqueue,
    else => @compileError("the readiness example is Linux and macOS only"),
};

const address_text = "127.0.0.1:8081";
const response_body = "h2c hello\n";

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
        print("http2-readiness: error: {s}\n", .{@errorName(err)});
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const address: Io.net.IpAddress = try .parseLiteral(address_text);

    var server = try Engine.Server.init(io, address, App.handler(), .{
        .allocator = gpa,
        .max_connections = 64,
        .max_streams = 128,
    });
    defer server.deinit();

    print("http2-readiness: listening on {s}\n", .{address_text});
    try server.run();
}
