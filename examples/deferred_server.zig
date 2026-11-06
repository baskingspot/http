//! A handler that answers from later work without blocking the poll thread.
//!
//!     just example-deferred
//!     just curl -s http://127.0.0.1:8093/
//!
//! The handler parks the exchange, starts one `Io.async` task, and returns.
//! The task wakes the engine when its result is ready; the engine then calls
//! the resume callback on its own thread.

const std = @import("std");
const Io = std.Io;
const print = std.debug.print;

const http = @import("http");

const address_text = "127.0.0.1:8093";
const response_body = "deferred hello\n";

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
        const wait = try exchange.arena.create(Wait);
        wait.* = .{
            .io = self.io,
            .producer = undefined,
            .waker = exchange.wakeHandle().?,
        };
        try exchange.deferResponse(wait, resumeHandler, cancelWait, .{});
        wait.producer = self.io.async(produce, .{ self.io, wait.waker });
    }

    fn produce(io: Io, waker: http.engine.Waker) void {
        io.sleep(.fromMilliseconds(500), .awake) catch return;
        waker.wake();
    }

    fn cancelWait(ctx: *anyopaque) void {
        const wait: *Wait = @ptrCast(@alignCast(ctx));
        _ = wait.producer.cancel(wait.io);
    }

    fn resumeHandler(
        ctx: *anyopaque,
        exchange: *http.h1.engine.Exchange,
    ) anyerror!http.engine.ResumeResult {
        const wait: *Wait = @ptrCast(@alignCast(ctx));
        _ = wait.producer.cancel(wait.io);
        try exchange.respond(.{
            .status = .ok,
            .content_type = "text/plain",
        }, response_body);
        return .responded;
    }

    fn reportError(_: *anyopaque, err: anyerror) void {
        print("deferred: {s}\n", .{@errorName(err)});
    }
};

const Wait = struct {
    io: Io,
    producer: Io.Future(void),
    waker: http.engine.Waker,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const address: Io.net.IpAddress = try .parseLiteral(address_text);
    var app: App = .{ .io = io };
    var server: http.h1.engine.poll.Server = try .init(io, address, app.handler(), .{
        .allocator = gpa,
        .max_connections = 8,
        .common = .{ .body_bytes = 8 * 1024 },
    });
    defer server.deinit();
    print("deferred: listening on {s}\n", .{address_text});
    try server.run();
}
