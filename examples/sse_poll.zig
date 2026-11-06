//! Server-sent events over the poll engine.
//!
//!     just example-sse-poll
//!     curl -N http://127.0.0.1:8092/
//!
//! The producer writes events into an `Io.Queue`; the poll engine pulls one
//! event when the socket is writable and waits for the next one without
//! blocking the other connection slots.

const std = @import("std");
const Io = std.Io;
const print = std.debug.print;

const http = @import("http");
const stream = http.stream;

const address_text = "127.0.0.1:8092";

const events = [_][]const u8{
    "data: tick 0\n\n",
    "data: tick 1\n\n",
    "data: tick 2\n\n",
    "data: tick 3\n\n",
    "data: tick 4\n\n",
};

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
        const source = try SseSource.init(exchange.arena, self.io);
        try exchange.respondStream(.{
            .status = .ok,
            .content_type = "text/event-stream",
        }, .{
            .stream = source.stream,
            .content_length = null,
        });
    }

    fn reportError(_: *anyopaque, err: anyerror) void {
        print("sse-poll: {s}\n", .{@errorName(err)});
    }
};

const SseSource = struct {
    io: Io,
    queue: Io.Queue([]const u8),
    buffer: [8][]const u8,
    producer: Io.Future(void),
    stream: stream.ReadStream,

    const vtable: stream.ReadStream.VTable = .{ .next = next, .close = close };

    fn init(allocator: std.mem.Allocator, io: Io) !*SseSource {
        const self = try allocator.create(SseSource);
        self.* = .{
            .io = io,
            .queue = undefined,
            .buffer = undefined,
            .producer = undefined,
            .stream = .{ .ptr = self, .vtable = &vtable },
        };
        self.queue = .init(&self.buffer);
        self.producer = io.async(produce, .{ io, self });
        return self;
    }

    fn produce(io: Io, self: *SseSource) void {
        for (events) |event| {
            io.sleep(.fromSeconds(1), .awake) catch return;
            self.queue.putOne(io, event) catch return;
        }
        self.queue.close(io);
    }

    fn next(ptr: *anyopaque) stream.Read {
        const self: *SseSource = @ptrCast(@alignCast(ptr));
        var item: [1][]const u8 = undefined;
        const n = self.queue.get(self.io, &item, 0) catch |err| switch (err) {
            error.Closed => return .eof,
            error.Canceled => return .{ .failed = err },
        };
        if (n == 0) return .pending;
        return .{ .data = item[0] };
    }

    fn close(ptr: *anyopaque) void {
        const self: *SseSource = @ptrCast(@alignCast(ptr));
        self.queue.close(self.io);
        _ = self.producer.cancel(self.io);
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const address: Io.net.IpAddress = try .parseLiteral(address_text);
    var app: App = .{ .io = io };
    var server = try http.h1.engine.poll.Server.init(io, address, app.handler(), .{
        .allocator = gpa,
        .max_connections = 8,
        .common = .{ .body_bytes = 8 * 1024 },
    });
    defer server.deinit();
    print("sse-poll: listening on {s}\n", .{address_text});
    try server.run();
}
