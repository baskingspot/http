//! A small blocking HTTP/1.1 server over std.Io, one task per connection.
//!
//!     just example
//!     curl -v http://127.0.0.1:8080/
//!
//! The accept loop owns the listener; each accepted stream moves into its own
//! task, which owns the stream and the per-connection buffers. The engine
//! still sees exactly one connection. `handle` sees a complete request and
//! formats a response body with the exchange arena.

const std = @import("std");
const Io = std.Io;
const print = std.debug.print;

const http = @import("http");
const engine = http.h1.engine.blocking;

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

    var app: App = .{};

    // The group holds the connection tasks, so shutdown has one handle to
    // wait on or cancel. A task frees its own resources when it returns, so a
    // long-lived group is fine; only the group itself has to be awaited or
    // cancelled before the process can exit.
    var group: Io.Group = .init;
    defer group.cancel(io);

    while (true) {
        const stream = listener.accept(io) catch |err| switch (err) {
            error.ConnectionAborted, error.WouldBlock => continue,
            error.ProcessFdQuotaExceeded,
            error.SystemFdQuotaExceeded,
            error.SystemResources,
            => {
                io.sleep(.fromSeconds(1), .awake) catch |sleep_err| switch (sleep_err) {
                    error.Canceled => return,
                };
                continue;
            },
            error.Canceled => return,
            else => return err,
        };
        // `concurrent`, not `async`: `async` is allowed to run the task inline
        // when the pool is busy, which would stall this loop behind one slow
        // client. `concurrent` either starts a real task or fails.
        group.concurrent(io, serveConnection, .{ init.gpa, io, stream, &app }) catch |err| {
            // No concurrency available: drop the connection rather than
            // serialize it into the accept loop.
            stream.close(io);
            app.onError(err);
        };
    }
}

/// Everything one connection task owns. The engine borrows slices of this, so
/// it has to outlive the call to `engine.serve`.
const Connection = struct {
    request: [16 * 1024]u8 = undefined,
    headers: [64]http.Header = undefined,
    response_head: [1024]u8 = undefined,

    fn config(self: *Connection, allocator: std.mem.Allocator) engine.Config {
        return .{
            .allocator = allocator,
            .request_buffer = &self.request,
            .headers = &self.headers,
            .response_head_buffer = &self.response_head,
            .body_bytes = 8 * 1024,
        };
    }
};

/// One task body. Returning `void` keeps it coercible to `Cancelable!void`,
/// and errors go to `on_error` here instead of vanishing into the group.
fn serveConnection(
    allocator: std.mem.Allocator,
    io: Io,
    stream: Io.net.Stream,
    handler: *App,
) void {
    defer stream.close(io);

    var connection: Connection = .{};
    engine.serve(App, io, stream, handler, connection.config(allocator)) catch |err| {
        handler.onError(err);
    };
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
            try std.fmt.allocPrint(
                exchange.arena,
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
        print("http1-server: {s}\n", .{@errorName(err)});
    }
};
