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
const mem = std.mem;
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

const ServerCtx = struct {
    io: Io,
    listener: *Io.net.Server,
    result: ?anyerror = null,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const address: Io.net.IpAddress = try .parse(address_text, 0);

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
    var state: http.h1.SearchState = .{};
    var storage: [64]http.Header = undefined;

    while (true) {
        var parsed: http.h1.ParsedRequest = undefined;
        while (true) {
            parsed = http.h1.parseRequest(
                buffer[0..used],
                &state,
                &storage,
            ) catch |err| switch (err) {
                error.Incomplete => {
                    if (used == buffer.len) return error.HeadTooLarge;
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
        var body_end: usize = body_start;
        var body_len: usize = 0;
        switch (framing) {
            .none => {},
            .length => |length| {
                if (length > max_body) return error.BodyTooLarge;
                const n: usize = @intCast(length);
                while (used - body_end < n) {
                    if (used == buffer.len) return error.BodyTooLarge;
                    const got = try recvInto(&ring, fd, buffer[used..]);
                    if (got == 0) return error.PeerClosed;
                    used += got;
                }
                body_end = body_start + n;
                body_len = n;
            },
            .chunked => {
                var trailer_storage: [16]http.Header = undefined;
                var decoder: http.h1.chunked.Decoder = .init(&trailer_storage);
                while (!decoder.isDone()) {
                    const step = decoder.next(buffer[body_end..used]) catch |err| switch (err) {
                        error.Invalid, error.TooManyHeaders => return error.InvalidChunkedBody,
                        error.Overflow => return error.ChunkSizeOverflow,
                        error.Incomplete => unreachable,
                    };
                    body_end += step.consumed;
                    switch (step.event) {
                        .data => |data| {
                            body_len += data.len;
                            if (body_len > max_body) return error.BodyTooLarge;
                        },
                        .trailers => {},
                        .need_more => {},
                    }
                    if (step.event == .need_more and step.consumed == 0) {
                        if (used == buffer.len) return error.BodyTooLarge;
                        const got = try recvInto(&ring, fd, buffer[used..]);
                        if (got == 0) return error.PeerClosed;
                        used += got;
                    }
                }
            },
        }

        var body_buffer: [256]u8 = undefined;
        const method_name = if (method) |known| known.token() else "UNKNOWN";
        const response_body = try std.fmt.bufPrint(
            &body_buffer,
            "{s} {s} ({d}-byte body)\n",
            .{ method_name, target, body_len },
        );
        const status: http.Status = if (mem.eql(u8, target, "/")) .ok else .not_found;

        // The first response is chunked so the client exercises the response
        // decoder. The second keeps Content-Length.
        var head_buffer: [256]u8 = undefined;
        var head_io: Io.Writer = .fixed(&head_buffer);
        var head: http.h1.Writer = .init(&head_io);
        try head.statusLine(version, status);
        try head.field("Content-Type", "text/plain");
        try head.field("Connection", if (keep_alive) "keep-alive" else "close");
        if (mem.eql(u8, target, "/")) {
            try head.chunked();
        } else {
            try head.contentLength(response_body.len);
        }
        try head.endFields();
        try sendAll(&ring, fd, head_io.buffered());

        if (mem.eql(u8, target, "/")) {
            var frame_buffer: [512]u8 = undefined;
            var frame_io: Io.Writer = .fixed(&frame_buffer);
            var frame: http.h1.Writer = .init(&frame_io);
            try frame.chunk(response_body);
            try frame.lastChunk(&.{});
            try sendAll(&ring, fd, frame_io.buffered());
        } else {
            try sendAll(&ring, fd, response_body);
        }

        const consumed = body_end;
        const leftover = used - consumed;
        @memmove(buffer[0..leftover], buffer[consumed..used]);
        used = leftover;

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
    var pos: usize = 0;
    var state: http.h1.SearchState = .{};
    var storage: [32]http.Header = undefined;
    const methods = [_]http.Method{ .POST, .GET };
    var response_index: usize = 0;
    var first_body: [256]u8 = undefined;
    var first_body_len: usize = 0;

    while (response_index < methods.len) {
        var parsed: http.h1.ParsedResponse = undefined;
        while (true) {
            parsed = http.h1.parseResponse(
                buffer[pos..used],
                &state,
                &storage,
            ) catch |err| switch (err) {
                error.Incomplete => {
                    if (used == buffer.len) return error.ResponseTooLarge;
                    const n = try recvInto(&ring, fd, buffer[used..]);
                    if (n == 0) return error.PeerClosed;
                    used += n;
                    continue;
                },
                error.Invalid, error.UnsupportedVersion, error.TooManyHeaders => return err,
            };
            break;
        }
        pos += parsed.consumed;

        if (response_index == 0 and parsed.head.status != .ok) return error.UnexpectedStatus;
        if (response_index == 1 and parsed.head.status != .not_found) return error.UnexpectedStatus;

        const framing = try http.h1.framing.response(
            parsed.head.version,
            parsed.head.status,
            methods[response_index],
            parsed.head.headers,
        );

        switch (framing) {
            .none => {},
            .length => |length| {
                const n: usize = @intCast(length);
                while (used - pos < n) {
                    if (used == buffer.len) return error.ResponseTooLarge;
                    const got = try recvInto(&ring, fd, buffer[used..]);
                    if (got == 0) return error.PeerClosed;
                    used += got;
                }
                pos += n;
            },
            .chunked => {
                var trailer_storage: [8]http.Header = undefined;
                var decoder: http.h1.chunked.Decoder = .init(&trailer_storage);
                while (!decoder.isDone()) {
                    const step = decoder.next(buffer[pos..used]) catch |err| switch (err) {
                        error.Invalid, error.TooManyHeaders, error.Overflow => return err,
                        error.Incomplete => unreachable,
                    };
                    pos += step.consumed;
                    switch (step.event) {
                        .data => |data| {
                            if (response_index == 0) {
                                if (first_body_len + data.len > first_body.len) {
                                    return error.BodyTooLarge;
                                }
                                @memcpy(first_body[first_body_len..][0..data.len], data);
                                first_body_len += data.len;
                            }
                        },
                        .trailers => {},
                        .need_more => {},
                    }
                    if (step.event == .need_more and step.consumed == 0) {
                        if (used == buffer.len) return error.ResponseTooLarge;
                        const got = try recvInto(&ring, fd, buffer[used..]);
                        if (got == 0) return error.PeerClosed;
                        used += got;
                    }
                }
            },
            .close => return error.UnexpectedCloseFraming,
            .tunnel => return error.UnexpectedTunnel,
        }
        response_index += 1;
    }

    if (!mem.eql(u8, first_body[0..first_body_len], "POST / (5-byte body)\n")) {
        return error.UnexpectedBody;
    }
    std.debug.print("[uring] decoded chunked response body ({d} bytes)\n", .{first_body_len});
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
