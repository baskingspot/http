//! HTTP/1.1 over io_uring, client and server in one process.
//!
//!     just example-uring
//!
//! The point is the parser under a nonblocking data path: io_uring owns the
//! socket edge, `h1.parseRequest` gets whatever bytes arrived, and the same
//! head/framing/persistence calls from the blocking example decide what to do.
//! The listener accept is blocking on purpose; the ring drives every read and
//! write after that.
//!
//! The client sends two pipelined requests. The server answers both on one
//! connection and closes on the second. The second request is deliberately
//! already in the buffer after the first head, so the example has to consume
//! the first request and move the leftover forward before parsing again.

const std = @import("std");
const Io = std.Io;
const IoUring = std.os.linux.IoUring;
const posix = std.posix;
const builtin = @import("builtin");

const http = @import("http");

comptime {
    if (builtin.os.tag != .linux) @compileError("http1_uring is Linux-only");
}

const address_text = "127.0.0.1";
const max_head = 16 * 1024;
const max_body = 64 * 1024;
const max_target = 256;
const buffer_len = max_head + max_body;

const requests =
    "POST / HTTP/1.1\r\n" ++
    "Host: example.com\r\n" ++
    "Content-Length: 5\r\n" ++
    "\r\n" ++
    "hello" ++
    "GET /nope HTTP/1.1\r\n" ++
    "Host: example.com\r\n" ++
    "Connection: close\r\n" ++
    "\r\n";

const response_format =
    "{s} {d} {s}\r\n" ++
    "Content-Length: {d}\r\n" ++
    "Content-Type: text/plain\r\n" ++
    "Connection: {s}\r\n\r\n";

const ServerCtx = struct {
    io: Io,
    listener: *Io.net.Server,
    result: ?anyerror = null,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const address = try Io.net.IpAddress.parse(address_text, 0);

    var listener = try address.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    const port = listener.socket.address.getPort();

    var ctx: ServerCtx = .{ .io = io, .listener = &listener };
    const server_thread = try std.Thread.spawn(.{}, serverRun, .{&ctx});

    // Do not hang forever on an early client failure: leave the accept thread
    // detached and let process exit take it down.
    clientRun(io, port) catch |err| {
        server_thread.detach();
        return err;
    };
    server_thread.join();
    if (ctx.result) |err| return err;

    std.debug.print("[uring] done\n", .{});
}

fn serverRun(ctx: *ServerCtx) void {
    serverServe(ctx) catch |err| {
        ctx.result = err;
    };
}

fn serverServe(ctx: *ServerCtx) !void {
    const io = ctx.io;
    var ring: IoUring = try initRing();

    const stream = try ctx.listener.accept(io);
    defer stream.close(io);
    const fd = stream.socket.handle;
    std.debug.print("[uring] server accepted\n", .{});

    var buffer: [buffer_len]u8 = undefined;
    var used: usize = 0;
    var last_len: u32 = 0;
    var storage: [64]http.Header = undefined;

    while (true) {
        var parsed: http.h1.ParsedRequest = undefined;
        while (true) {
            parsed = http.h1.parseRequest(
                buffer[0..used],
                last_len,
                &storage,
            ) catch |err| switch (err) {
                error.Incomplete => {
                    if (used == buffer.len) return error.HeadTooLarge;
                    last_len = @intCast(used);
                    const n = try recvInto(&ring, fd, buffer[used..]);
                    if (n == 0) return; // peer closed
                    used += n;
                    continue;
                },
                error.Invalid => return error.Invalid,
                error.UnsupportedVersion => return error.UnsupportedVersion,
                error.TooManyHeaders => return error.TooManyHeaders,
            };
            break;
        }

        // The head borrows `buffer`; take everything the response needs now.
        const version = parsed.head.version;
        const keep_alive = http.h1.persistent(version, parsed.head.headers);
        const framing = try http.h1.framing.request(version, parsed.head.headers);
        const method = parsed.head.method;

        var target_buffer: [max_target]u8 = undefined;
        if (parsed.head.target.len > target_buffer.len) return error.TargetTooLong;
        @memcpy(target_buffer[0..parsed.head.target.len], parsed.head.target);
        const target = target_buffer[0..parsed.head.target.len];

        const body_start: usize = parsed.consumed;
        const body_len: usize = switch (framing) {
            .none => 0,
            .length => |length| blk: {
                if (length > max_body) return error.BodyTooLarge;
                const n: usize = @intCast(length);
                while (@as(usize, used) - body_start < n) {
                    if (used == buffer.len) return error.BodyTooLarge;
                    const got = try recvInto(&ring, fd, buffer[used..]);
                    if (got == 0) return error.PeerClosed;
                    used += got;
                }
                break :blk n;
            },
            .chunked => return error.ChunkedNotImplemented,
        };

        var body_buffer: [256]u8 = undefined;
        const method_name = if (method) |known| known.token() else "UNKNOWN";
        const response_body = try std.fmt.bufPrint(
            &body_buffer,
            "{s} {s} ({d}-byte body)\n",
            .{ method_name, target, body_len },
        );
        const status: http.Status = if (std.mem.eql(u8, target, "/")) .ok else .not_found;
        const phrase = status.phrase() orelse "Unknown";
        var response_buffer: [512]u8 = undefined;
        const response_head = try std.fmt.bufPrint(
            &response_buffer,
            response_format,
            .{
                @tagName(version),
                status.code(),
                phrase,
                response_body.len,
                if (keep_alive) "keep-alive" else "close",
            },
        );

        try sendAll(&ring, fd, response_head);
        try sendAll(&ring, fd, response_body);

        const consumed = body_start + body_len;
        const leftover = used - consumed;
        @memmove(buffer[0..leftover], buffer[consumed..used]);
        used = leftover;
        last_len = 0;

        if (!keep_alive) return;
    }
}

fn clientRun(io: Io, port: u16) !void {
    var ring: IoUring = try initRing();

    const address = try Io.net.IpAddress.parse(address_text, port);
    const stream = try address.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    const fd = stream.socket.handle;
    std.debug.print("[uring] client connected\n", .{});

    try sendAll(&ring, fd, requests);

    var buffer: [16 * 1024]u8 = undefined;
    var used: usize = 0;
    while (true) {
        const n = try recvInto(&ring, fd, buffer[used..]);
        if (n == 0) break;
        used += n;
        if (used == buffer.len) return error.ResponseTooLarge;
    }

    const response = buffer[0..used];
    if (std.mem.find(u8, response, "200 OK") == null) return error.MissingOk;
    if (std.mem.find(u8, response, "404 Not Found") == null) return error.MissingNotFound;
    if (std.mem.find(u8, response, "POST / (5-byte body)") == null) return error.MissingBody;

    std.debug.print("[uring] received {d} bytes, both responses present\n", .{used});
}

fn initRing() !IoUring {
    return IoUring.init(8, 0) catch |err| switch (err) {
        error.PermissionDenied, error.SystemOutdated => {
            std.debug.print("[uring] io_uring unavailable: {s}\n", .{@errorName(err)});
            return error.IoUringUnavailable;
        },
        else => return err,
    };
}

fn sendAll(ring: *IoUring, fd: posix.fd_t, bytes: []const u8) !void {
    var sent: usize = 0;
    while (sent < bytes.len) {
        _ = try ring.send(1, fd, bytes[sent..], 0);
        _ = try ring.submit();
        const cqe = try ring.copy_cqe();
        if (cqe.err() != .SUCCESS) return error.IoUringFailed;
        if (cqe.res == 0) return error.PeerClosed;
        sent += @intCast(cqe.res);
    }
}

fn recvInto(ring: *IoUring, fd: posix.fd_t, dest: []u8) !usize {
    if (dest.len == 0) return 0;
    _ = try ring.recv(2, fd, .{ .buffer = dest }, 0);
    _ = try ring.submit();
    const cqe = try ring.copy_cqe();
    if (cqe.err() != .SUCCESS) return error.IoUringFailed;
    return @intCast(cqe.res);
}
