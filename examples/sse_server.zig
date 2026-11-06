//! Server-sent events in spirit over a pull-based response stream.
//!
//!     just example-sse
//!     curl -N http://127.0.0.1:8090/
//!
//! The handler returns a stream. The engine pulls one event at a time and
//! flushes it as a chunked HTTP/1.1 response.

const std = @import("std");
const Io = std.Io;
const print = std.debug.print;

const http = @import("http");
const stream = http.stream;

const address_text = "127.0.0.1:8090";

const App = struct {
    io: Io,

    fn handler(self: *App) http.h1.engine.Handler {
        return .{ .ptr = self, .vtable = &.{
            .handle = handle,
            .complete = http.h1.engine.Handler.noopComplete,
            .report_error = reportError,
            .policy_response = http.h1.engine.Handler.defaultPolicyResponse,
        } };
    }

    fn handle(ptr: *anyopaque, exchange: *http.h1.engine.Exchange) anyerror!void {
        const self: *App = @ptrCast(@alignCast(ptr));
        const events = try exchange.arena.create(EventStream);
        events.* = .{ .io = self.io };
        try exchange.respondStream(.{
            .status = .ok,
            .content_type = "text/event-stream",
        }, .{
            .stream = .{ .ptr = events, .vtable = &EventStream.vtable },
            .content_length = null,
        });
    }

    fn reportError(_: *anyopaque, err: anyerror) void {
        print("sse: {s}\n", .{@errorName(err)});
    }
};

const EventStream = struct {
    io: Io,
    index: u8 = 0,
    line: [64]u8 = undefined,

    const vtable: stream.ReadStream.VTable = .{ .next = next, .close = close };

    fn next(ptr: *anyopaque) stream.Read {
        const self: *EventStream = @ptrCast(@alignCast(ptr));
        if (self.index == 5) return .eof;
        self.io.sleep(.fromSeconds(1), .awake) catch |err| return .{ .failed = err };
        const text = std.fmt.bufPrint(
            &self.line,
            "data: tick {d}\n\n",
            .{self.index},
        ) catch return .{ .failed = error.BufferTooSmall };
        self.index += 1;
        return .{ .data = text };
    }

    fn close(_: *anyopaque) void {}
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const address: Io.net.IpAddress = try .parseLiteral(address_text);
    var listener = try address.listen(io, .{ .mode = .stream, .reuse_address = true });
    defer listener.deinit(io);

    var app: App = .{ .io = io };
    print("sse: listening on {s}\n", .{address_text});
    while (true) {
        const conn = listener.accept(io) catch |err| {
            print("sse: accept: {s}\n", .{@errorName(err)});
            continue;
        };
        var request_buffer: [16 * 1024]u8 = undefined;
        var headers: [64]http.Header = undefined;
        var response_head: [1024]u8 = undefined;
        http.h1.engine.blocking.serve(io, conn, app.handler(), .{
            .allocator = gpa,
            .request_buffer = &request_buffer,
            .headers = &headers,
            .response_head_buffer = &response_head,
            .common = .{ .body_bytes = 8 * 1024 },
        }) catch |err| switch (err) {
            error.WriteFailed => {},
            else => print("sse: connection: {s}\n", .{@errorName(err)}),
        };
        conn.close(io);
    }
}
