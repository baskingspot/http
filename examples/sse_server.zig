//! Server-sent events in spirit over a pull-based response stream.
//!
//!     just example-sse
//!     curl -N http://127.0.0.1:8090/
//!
//! The handler returns a stream. The engine pulls one event at a time and
//! flushes it as a close-delimited HTTP/1.1 response.

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
        print("sse: {s}\n", .{@errorName(err)});
    }
};

const events = [_][]const u8{
    "data: tick 0\n\n",
    "data: tick 1\n\n",
    "data: tick 2\n\n",
    "data: tick 3\n\n",
    "data: tick 4\n\n",
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

    fn next(ptr: *anyopaque) stream.ReadError!stream.ReadResult {
        const self: *SseSource = @ptrCast(@alignCast(ptr));
        const item = self.queue.getOne(self.io) catch |err| switch (err) {
            error.Closed => return error.EndOfStream,
            error.Canceled => return error.Canceled,
        };
        return .{ .data = item };
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
