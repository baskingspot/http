//! A blocking HTTP/2 server engine over std.Io.
//!
//! `serve` drives one connection: it reads transport bytes into the session,
//! hands events to the handler, flushes queued frames, and returns when the
//! peer closes or the session fails. `run` is the accept loop, one connection
//! at a time, matching `h1.engine.blocking`.
//!
//! The handler owns application state. The engine owns the session, the
//! socket, and the transport buffers. A handler type provides:
//!
//!     pub fn handle(self: *Handler, conn: *Connection, event: h2.session.Event) anyerror!void
//!
//! and may also provide:
//!
//!     pub fn afterEvents(self: *Handler, conn: *Connection) anyerror!void
//!     pub fn onError(self: *Handler, err: anyerror) void
//!
//! `afterEvents` runs after the session has delivered every event in the
//! current read, before output is flushed. A handler that answers a request
//! uses it to batch responses. The engine returns DATA bytes to both flow
//! control windows after `handle` returns; the handler must copy anything it
//! needs beyond the call and must not release those bytes itself.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const session_mod = @import("../session.zig");
const Session = session_mod.Session;
const Options = session_mod.Options;
const Event = session_mod.Event;

/// One live connection. The session is the protocol API the handler calls.
pub const Connection = struct {
    session: *Session,
};

// ast-grep-ignore: public-struct-field-default -- options bag; session carries its own defaults
pub const Config = struct {
    session: Options,
    /// Transport read scratch. The engine feeds these bytes to `Session.receive`.
    read_buffer: []u8,
    /// The `std.Io` writer's buffer.
    write_buffer: []u8,
};

/// Accept connections until an unrecoverable accept error.
pub fn run(
    comptime Handler: type,
    gpa: Allocator,
    io: Io,
    listener: *Io.net.Server,
    handler: *Handler,
    config: Config,
) !void {
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
        defer stream.close(io);

        serve(Handler, gpa, io, stream, handler, config) catch |err| {
            report(Handler, handler, err);
            continue;
        };
    }
}

/// Serve one connection until the peer closes or the session fails.
pub fn serve(
    comptime Handler: type,
    gpa: Allocator,
    io: Io,
    stream: Io.net.Stream,
    handler: *Handler,
    config: Config,
) !void {
    if (config.read_buffer.len == 0 or config.write_buffer.len == 0) {
        return error.NoBuffer;
    }

    var session = try Session.init(gpa, config.session);
    defer session.deinit(gpa);
    var conn: Connection = .{ .session = &session };

    var reader = stream.reader(io, &.{});
    var writer = stream.writer(io, config.write_buffer);
    const r = &reader.interface;
    const w = &writer.interface;
    var out_buffer: [4096]u8 = undefined;

    while (true) {
        try flush(&session, w, &out_buffer);

        var vecs: [1][]u8 = .{config.read_buffer};
        const n = r.readVec(&vecs) catch |err| switch (err) {
            error.EndOfStream => return,
            error.ReadFailed => return err,
        };
        if (n == 0) return;

        var offset: usize = 0;
        while (offset < n) {
            const consumed = session.receive(config.read_buffer[offset..n]);
            if (consumed == 0) return error.InputFull;
            offset += consumed;

            while (try session.nextEvent(gpa)) |event| {
                try handler.handle(&conn, event);
                switch (event) {
                    .data => |data| {
                        if (data.bytes.len > 0) {
                            try session.release(
                                gpa,
                                data.stream_id,
                                @intCast(data.bytes.len),
                            );
                        }
                    },
                    else => {},
                }
            }

            if (@hasDecl(Handler, "afterEvents")) {
                try handler.afterEvents(&conn);
            }
        }

        if (session.isClosed()) {
            try flush(&session, w, &out_buffer);
            return;
        }
    }
}

fn flush(session: *Session, w: *Io.Writer, out: []u8) !void {
    while (true) {
        const n = session.send(out);
        if (n == 0) break;
        try w.writeAll(out[0..n]);
    }
    try w.flush();
}

fn report(comptime Handler: type, handler: *Handler, err: anyerror) void {
    if (@hasDecl(Handler, "onError")) handler.onError(err);
}
