//! A small HTTP/1.1 server over a TCP socket.
//!
//!     just example
//!     curl -v http://127.0.0.1:8080/
//!
//! The shape is the point: read a head, frame the body, read the body, write a
//! response, and decide whether the connection stays open. The head borrows
//! the reader's buffer, so anything needed after the body read is copied first.

const std = @import("std");
const Io = std.Io;
const print = std.debug.print;

const http = @import("http");

const address_text = "127.0.0.1:8080";
const max_head = 16 * 1024;
const max_body = 64 * 1024;
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

    while (true) {
        const stream = listener.accept(io) catch |err| {
            print("http1-server: accept: {s}\n", .{@errorName(err)});
            continue;
        };
        serveConnection(io, stream) catch |err| {
            print("http1-server: connection: {s}\n", .{@errorName(err)});
        };
        stream.close(io);
    }
}

fn serveConnection(io: Io, stream: Io.net.Stream) !void {
    var read_buffer: [max_head]u8 = undefined;
    var write_buffer: [max_head]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    var writer = stream.writer(io, &write_buffer);
    const r = &reader.interface;
    const w = &writer.interface;

    while (true) {
        var header_storage: [64]http.Header = undefined;
        const head = readRequest(r, &header_storage) catch |err| switch (err) {
            error.EndOfStream, error.ReadFailed => return,
            error.HeadTooLarge => {
                writeError(
                    w,
                    .@"HTTP/1.1",
                    .request_header_fields_too_large,
                    "request head too large\n",
                ) catch return;
                return;
            },
            error.UnsupportedVersion => {
                writeError(
                    w,
                    .@"HTTP/1.1",
                    .http_version_not_supported,
                    "unsupported HTTP version\n",
                ) catch return;
                return;
            },
            error.Invalid, error.TooManyHeaders => {
                writeError(w, .@"HTTP/1.1", .bad_request, "malformed request\n") catch return;
                return;
            },
        };

        // Decide everything that depends on the head before the body read. The
        // head borrows the reader's buffer, and the body read may rebase it.
        const version = head.version;
        const keep_alive = http.h1.persistent(version, head.headers);
        const method = head.method;

        const host_value = http.h1.host(head.headers) catch {
            writeError(w, version, .bad_request, "duplicate Host\n") catch return;
            return;
        };
        if (version == .@"HTTP/1.1" and host_value == null) {
            writeError(w, version, .bad_request, "missing Host\n") catch return;
            return;
        }

        var target_buffer: [max_target]u8 = undefined;
        if (head.target.len > target_buffer.len) {
            writeError(w, version, .uri_too_long, "request target too long\n") catch return;
            return;
        }
        @memcpy(target_buffer[0..head.target.len], head.target);
        const target = target_buffer[0..head.target.len];
        if (http.h1.targetForm(method, target) != .origin) {
            writeError(w, version, .bad_request, "unsupported request-target form\n") catch return;
            return;
        }

        const framing = http.h1.framing.request(version, head.headers) catch |err| {
            const status: http.Status = switch (err) {
                error.FaultyFraming,
                error.ConflictingFraming,
                error.InvalidTransferEncoding,
                error.InvalidContentLength,
                => .bad_request,
            };
            writeError(w, version, status, "bad message framing\n") catch return;
            return;
        };

        var body_buffer: [max_body]u8 = undefined;
        const body_len: usize = switch (framing) {
            .none => 0,
            .length => |length| blk: {
                if (length > @as(u64, body_buffer.len)) {
                    writeError(
                        w,
                        version,
                        .payload_too_large,
                        "request body too large\n",
                    ) catch return;
                    return;
                }
                const n: usize = @intCast(length);
                r.readSliceAll(body_buffer[0..n]) catch return;
                break :blk n;
            },
            .chunked => blk: {
                var trailer_storage: [16]http.Header = undefined;
                var decoder: http.h1.chunked.Decoder = .init(&trailer_storage);
                var decoded: usize = 0;

                while (!decoder.isDone()) {
                    const step = decoder.next(r.buffered()) catch |err| switch (err) {
                        error.Incomplete => {
                            r.fillMore() catch return;
                            continue;
                        },
                        error.Invalid, error.TooManyHeaders => {
                            writeError(
                                w,
                                version,
                                .bad_request,
                                "malformed chunked body\n",
                            ) catch return;
                            return;
                        },
                        error.Overflow => {
                            writeError(
                                w,
                                version,
                                .payload_too_large,
                                "chunk size overflow\n",
                            ) catch return;
                            return;
                        },
                    };
                    r.toss(step.consumed);
                    switch (step.event) {
                        .data => |data| {
                            decoded += data.len;
                            if (decoded > max_body) {
                                writeError(
                                    w,
                                    version,
                                    .payload_too_large,
                                    "request body too large\n",
                                ) catch return;
                                return;
                            }
                        },
                        .trailers => {},
                        .need_more => {},
                    }
                    if (step.event == .need_more and step.consumed == 0) {
                        r.fillMore() catch return;
                    }
                }
                break :blk decoded;
            },
        };

        const is_root = std.mem.eql(u8, target, "/");
        const method_name = if (method) |known| known.token() else "UNKNOWN";
        var response_buffer: [512]u8 = undefined;
        const response_body = if (is_root)
            std.fmt.bufPrint(
                &response_buffer,
                "{s} {s} ({d}-byte body)\n",
                .{ method_name, target, body_len },
            ) catch "hello\n"
        else
            "not found\n";
        const status: http.Status = if (is_root) .ok else .not_found;

        writeResponse(w, version, status, response_body, keep_alive) catch return;
        if (!keep_alive) return;
    }
}

const ReadError = error{
    EndOfStream,
    ReadFailed,
    HeadTooLarge,
    Invalid,
    UnsupportedVersion,
    TooManyHeaders,
};

/// Fill the reader's buffer until a whole head is present, then consume it.
/// The returned head borrows both `storage` and the reader's buffer.
fn readRequest(r: *Io.Reader, storage: []http.Header) ReadError!http.h1.RequestHead {
    var state: http.h1.SearchState = .init;

    while (true) {
        const buffered = r.buffered();
        if (buffered.len != 0) {
            const parsed = http.h1.parseRequest(
                buffered,
                &state,
                storage,
            ) catch |err| switch (err) {
                error.Incomplete => {
                    // No room left to grow the head. This is the 431 case.
                    if (buffered.len == r.buffer.len) return error.HeadTooLarge;
                    try r.fillMore();
                    continue;
                },
                error.Invalid => return error.Invalid,
                error.UnsupportedVersion => return error.UnsupportedVersion,
                error.TooManyHeaders => return error.TooManyHeaders,
            };
            r.toss(parsed.consumed);
            return parsed.head;
        }
        try r.fillMore();
    }
}

fn writeResponse(
    io_writer: *Io.Writer,
    version: http.Version,
    status: http.Status,
    body: []const u8,
    keep_alive: bool,
) !void {
    var w: http.h1.Writer = .init(io_writer);
    try w.statusLine(version, status);
    try w.field("Content-Type", "text/plain; charset=utf-8");
    try w.contentLength(body.len);
    try w.field("Connection", if (keep_alive) "keep-alive" else "close");
    try w.endFields();
    try w.body(body);
    try io_writer.flush();
}

fn writeError(
    w: *Io.Writer,
    version: http.Version,
    status: http.Status,
    message: []const u8,
) !void {
    try writeResponse(w, version, status, message, false);
}
