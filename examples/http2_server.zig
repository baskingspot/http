//! A small h2c server over std.Io, driven by `h2.Session`.
//!
//!     just example-h2
//!     curl -v --http2-prior-knowledge http://127.0.0.1:8081/
//!     nghttp -v http://127.0.0.1:8081/
//!     just conformance
//!
//! The session owns the protocol state; this file owns the sockets, the
//! handler, and the accept loop. It accepts connections on threads, waits for a
//! request to end before it answers, and resumes a body when flow control opens
//! the window. No TLS: this is h2c with prior knowledge.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const print = std.debug.print;

const http = @import("http");

const address_text = "127.0.0.1:8081";
const max_streams = 128;
const response_body = "h2c hello\n";

const Method = enum { get, head, other };

const Request = struct {
    stream_id: u31,
    method: Method,
    content_length: ?u64,
    received: u64,
    ready: bool,
    responded: bool,
};

const Pending = struct {
    stream_id: u31,
    offset: usize,
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
    serveConnection(gpa, io, stream) catch |err| {
        print("http2-server: connection: {s}\n", .{@errorName(err)});
    };
    stream.close(io);
}

fn serveConnection(gpa: Allocator, io: Io, stream: Io.net.Stream) !void {
    var reader = stream.reader(io, &.{});
    var write_buffer: [4096]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);
    const r = &reader.interface;
    const w = &writer.interface;

    var session = try http.h2.Session.init(gpa, .{ .role = .server });
    defer session.deinit(gpa);

    var requests: [max_streams]?Request = @splat(null);
    var pending: [max_streams]?Pending = @splat(null);

    var read_buf: [16 * 1024]u8 = undefined;
    var out_buf: [4096]u8 = undefined;

    while (true) {
        while (true) {
            const n = session.send(&out_buf);
            if (n == 0) break;
            try w.writeAll(out_buf[0..n]);
        }
        try w.flush();

        var vecs: [1][]u8 = .{&read_buf};
        const n = r.readVec(&vecs) catch |err| switch (err) {
            error.EndOfStream => return,
            error.ReadFailed => return err,
        };
        if (n == 0) return;

        var offset: usize = 0;
        while (offset < n) {
            const consumed = session.receive(read_buf[offset..n]);
            if (consumed == 0) break;
            offset += consumed;

            while (try session.nextEvent(gpa)) |event| {
                try handleEvent(&session, gpa, event, &requests, &pending);
            }
        }

        if (!session.isClosed()) {
            try respondReady(&session, gpa, &requests, &pending);
        }

        if (session.isClosed()) {
            while (true) {
                const written = session.send(&out_buf);
                if (written == 0) break;
                try w.writeAll(out_buf[0..written]);
            }
            try w.flush();
            return;
        }
    }
}

fn handleEvent(
    session: *http.h2.Session,
    gpa: Allocator,
    event: http.h2.session.Event,
    requests: *[max_streams]?Request,
    pending: *[max_streams]?Pending,
) !void {
    switch (event) {
        .request => |request| {
            const slot = findFreeRequest(requests) orelse {
                try session.submitReset(gpa, request.stream_id, .refused_stream);
                return;
            };
            const method: Method = if (std.mem.eql(u8, request.head.method_token, "HEAD"))
                .head
            else if (std.mem.eql(u8, request.head.method_token, "GET"))
                .get
            else
                .other;

            const content_length = parseContentLength(request.head.headers) catch {
                try session.submitReset(gpa, request.stream_id, .protocol_error);
                return;
            };
            slot.* = .{
                .stream_id = request.stream_id,
                .method = method,
                .content_length = content_length,
                .received = 0,
                .ready = request.end_stream,
                .responded = false,
            };
        },

        .data => |data| {
            const request = findRequest(requests, data.stream_id) orelse return;
            request.received += data.bytes.len;
            if (data.bytes.len > 0) {
                try session.release(gpa, data.stream_id, @intCast(data.bytes.len));
            }
            if (data.end_stream) request.ready = true;
        },

        .trailers => |trailers| {
            if (trailers.end_stream) {
                if (findRequest(requests, trailers.stream_id)) |request| {
                    request.ready = true;
                }
            }
        },

        .window_update => |update| {
            if (update.stream_id == 0) {
                for (pending) |*slot| {
                    if (slot.* != null) try pump(session, gpa, slot, requests);
                }
            } else if (findPending(pending, update.stream_id)) |slot| {
                try pump(session, gpa, slot, requests);
            }
        },

        .reset => |reset| {
            clearRequest(requests, reset.stream_id);
            clearPending(pending, reset.stream_id);
        },

        .settings => {
            for (pending) |*slot| {
                if (slot.* != null) try pump(session, gpa, slot, requests);
            }
        },

        .goaway => |goaway| {
            print("GOAWAY last={d} code=0x{x}\n", .{
                goaway.last_stream_id,
                @intFromEnum(goaway.code),
            });
        },

        .connection_error => |err| {
            print("connection error: 0x{x}\n", .{@intFromEnum(err.code)});
        },

        .response => {},
    }
}

fn respondReady(
    session: *http.h2.Session,
    gpa: Allocator,
    requests: *[max_streams]?Request,
    pending: *[max_streams]?Pending,
) !void {
    for (requests) |*slot| {
        const request = if (slot.*) |*request| request else continue;
        if (!request.ready or request.responded) continue;

        if (request.content_length) |expected| {
            if (expected != request.received) {
                try session.submitReset(gpa, request.stream_id, .protocol_error);
                slot.* = null;
                continue;
            }
        }

        const is_head = request.method == .head;
        const fields = [_]http.Header{
            .{ .name = ":status", .value = "200" },
            .{ .name = "content-type", .value = "text/plain; charset=utf-8" },
            .{ .name = "content-length", .value = "10" },
        };
        session.submitResponse(gpa, request.stream_id, &fields, is_head) catch |err| {
            if (err == error.UnknownStream) {
                slot.* = null;
                continue;
            }
            return err;
        };
        request.responded = true;

        if (is_head) {
            slot.* = null;
            continue;
        }

        const pending_slot = findFreePending(pending) orelse {
            try session.submitReset(gpa, request.stream_id, .internal_error);
            slot.* = null;
            continue;
        };
        pending_slot.* = .{ .stream_id = request.stream_id, .offset = 0 };
        try pump(session, gpa, pending_slot, requests);
    }
}

fn pump(
    session: *http.h2.Session,
    gpa: Allocator,
    slot: *?Pending,
    requests: *[max_streams]?Request,
) !void {
    const body = if (slot.*) |*body| body else return;
    const n = try session.submitData(gpa, body.stream_id, response_body[body.offset..], true);
    body.offset += n;

    if (body.offset == response_body.len) {
        clearRequest(requests, body.stream_id);
        slot.* = null;
    }
}

fn parseContentLength(headers: http.Headers) error{Invalid}!?u64 {
    var value: ?u64 = null;
    for (headers.items) |field| {
        if (!std.ascii.eqlIgnoreCase(field.name, "content-length")) continue;
        const parsed = std.fmt.parseInt(u64, field.value, 10) catch return error.Invalid;
        if (value) |previous| {
            if (previous != parsed) return error.Invalid;
        }
        value = parsed;
    }
    return value;
}

fn findRequest(requests: *[max_streams]?Request, id: u31) ?*Request {
    for (requests) |*slot| {
        if (slot.*) |*request| {
            if (request.stream_id == id) return request;
        }
    }
    return null;
}

fn findFreeRequest(requests: *[max_streams]?Request) ?*?Request {
    for (requests) |*slot| {
        if (slot.* == null) return slot;
    }
    return null;
}

fn findPending(pending: *[max_streams]?Pending, id: u31) ?*?Pending {
    for (pending) |*slot| {
        if (slot.*) |body| {
            if (body.stream_id == id) return slot;
        }
    }
    return null;
}

fn findFreePending(pending: *[max_streams]?Pending) ?*?Pending {
    for (pending) |*slot| {
        if (slot.* == null) return slot;
    }
    return null;
}

fn clearRequest(requests: *[max_streams]?Request, id: u31) void {
    for (requests) |*slot| {
        if (slot.*) |request| {
            if (request.stream_id == id) slot.* = null;
        }
    }
}

fn clearPending(pending: *[max_streams]?Pending, id: u31) void {
    for (pending) |*slot| {
        if (slot.*) |body| {
            if (body.stream_id == id) slot.* = null;
        }
    }
}
