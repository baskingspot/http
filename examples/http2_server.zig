//! A small h2c server over std.Io, driven by the blocking h2 engine.
//!
//!     just example-h2
//!     curl -v --http2-prior-knowledge http://127.0.0.1:8081/
//!     nghttp -v http://127.0.0.1:8081/
//!     just conformance-run
//!
//! The engine buffers the request, validates it, and pumps the response. This
//! file owns only the handler and the accept loop. One thread per connection
//! sits above `serve`. No TLS: this is h2c with prior knowledge.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
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
        print("http2-server: error: {s}\n", .{@errorName(err)});
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const address: Io.net.IpAddress = try .parseLiteral(address_text);

    var listener = try address.listen(io, .{
        .mode = .stream,
        .reuse_address = true,
    });
    defer listener.deinit(io);

    print("http2-server: listening on {s}\n", .{address_text});

    while (true) {
        const stream = listener.accept(io) catch |err| {
            print("http2-server: accept: {s}\n", .{@errorName(err)});
            continue;
        };
        const thread = std.Thread.spawn(.{}, serveThread, .{ gpa, io, stream }) catch |err| {
            print("http2-server: thread: {s}\n", .{@errorName(err)});
            stream.close(io);
            continue;
        };
        thread.detach();
    }
}

fn serveThread(gpa: Allocator, io: Io, stream: Io.net.Stream) void {
    serveConnection(gpa, io, stream) catch |err| App.reportError(undefined, err);
    stream.close(io);
}

fn serveConnection(gpa: Allocator, io: Io, stream: Io.net.Stream) !void {
    var read_buffer: [16 * 1024]u8 = undefined;
    var write_buffer: [4096]u8 = undefined;
    try http.h2.engine.blocking.serve(io, stream, App.handler(), .{
        .allocator = gpa,
        .read_buffer = &read_buffer,
        .write_buffer = &write_buffer,
        .max_streams = 128,
        .common = .{},
    });
}
