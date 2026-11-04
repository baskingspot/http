//! A small h2c server over std.Io, driven by the blocking h2 engine.
//!
//!     just example-h2
//!     curl -v --http2-prior-knowledge http://127.0.0.1:8081/
//!     nghttp -v http://127.0.0.1:8081/
//!     just conformance-run
//!
//! The engine owns the session and the transport; this file owns the handler:
//! requests, content-length checks, and a response body that resumes when flow
//! control opens. One thread per connection sits above the engine's `serve`.
//! No TLS: this is h2c with prior knowledge.

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

const Handler = struct {
    gpa: Allocator,
    requests: [max_streams]?Request = @splat(null),
    pending: [max_streams]?Pending = @splat(null),

    pub fn handle(
        self: *Handler,
        conn: *http.h2.engine.Connection,
        event: http.h2.session.Event,
    ) !void {
        const session = conn.session;
        switch (event) {
            .request => |request| {
                const slot = findFreeRequest(&self.requests) orelse {
                    try session.submitReset(self.gpa, request.stream_id, .refused_stream);
                    return;
                };
                const method: Method = if (std.mem.eql(u8, request.head.method_token, "HEAD"))
                    .head
                else if (std.mem.eql(u8, request.head.method_token, "GET"))
                    .get
                else
                    .other;

                const content_length = parseContentLength(request.head.headers) catch {
                    try session.submitReset(self.gpa, request.stream_id, .protocol_error);
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
                const request = findRequest(&self.requests, data.stream_id) orelse return;
                request.received += data.bytes.len;
                if (data.end_stream) request.ready = true;
            },

            .trailers => |trailers| {
                if (trailers.end_stream) {
                    if (findRequest(&self.requests, trailers.stream_id)) |request| {
                        request.ready = true;
                    }
                }
            },

            .window_update => |update| {
                if (update.stream_id == 0) {
                    for (&self.pending) |*slot| {
                        if (slot.* != null) {
                            try pump(session, self.gpa, slot, &self.requests);
                        }
                    }
                } else if (findPending(&self.pending, update.stream_id)) |slot| {
                    try pump(session, self.gpa, slot, &self.requests);
                }
            },

            .reset => |reset| {
                clearRequest(&self.requests, reset.stream_id);
                clearPending(&self.pending, reset.stream_id);
            },

            .settings => {
                for (&self.pending) |*slot| {
                    if (slot.* != null) {
                        try pump(session, self.gpa, slot, &self.requests);
                    }
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

    pub fn afterEvents(self: *Handler, conn: *http.h2.engine.Connection) !void {
        try respondReady(conn.session, self.gpa, &self.requests, &self.pending);
    }

    pub fn onError(self: *Handler, err: anyerror) void {
        _ = self;
        print("http2-server: connection: {s}\n", .{@errorName(err)});
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
    serveConnection(gpa, io, stream) catch |err| {
        print("http2-server: connection: {s}\n", .{@errorName(err)});
    };
    stream.close(io);
}

fn serveConnection(gpa: Allocator, io: Io, stream: Io.net.Stream) !void {
    var handler: Handler = .{ .gpa = gpa };
    var read_buffer: [16 * 1024]u8 = undefined;
    var write_buffer: [4096]u8 = undefined;
    try http.h2.engine.blocking.serve(Handler, gpa, io, stream, &handler, .{
        .session = .{ .role = .server },
        .read_buffer = &read_buffer,
        .write_buffer = &write_buffer,
    });
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
