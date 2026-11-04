//! A blocking HTTP/2 server engine over std.Io.
//!
//! The engine owns the transport loop, not the exchange state. It feeds the
//! shared `Connection` core, flushes queued output, and blocks on reads. One
//! connection is served at a time; the h2c example adds a thread per
//! connection. No deadlines, like `h1.engine.blocking`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const session_mod = @import("../session.zig");
const Options = session_mod.Options;
const connection_mod = @import("connection.zig");
const Connection = connection_mod.Connection;
const common = @import("common.zig");

pub const Exchange = common.Exchange;
pub const Handler = common.Handler;
pub const Request = common.Request;
pub const ResponseOptions = common.ResponseOptions;

// ast-grep-ignore: public-struct-field-default -- options bag; defaults are the policy
pub const Config = struct {
    allocator: Allocator,
    /// Transport read scratch fed to `Connection.receive`.
    read_buffer: []u8,
    /// The `std.Io` writer's buffer.
    write_buffer: []u8,
    /// Engine slot count and the session's MAX_CONCURRENT_STREAMS.
    max_streams: u16 = 128,
    /// Per-request body cap. Worst-case live memory is max_streams × this.
    body_bytes: usize = 64 * 1024,
    /// Retained per-stream arena capacity after complete.
    arena_retain_bytes: usize = 4 * 1024,
    session: Options = .{ .role = .server },
};

/// Accept connections until an unrecoverable accept error.
pub fn run(
    io: Io,
    listener: *Io.net.Server,
    handler: Handler,
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

        serve(io, stream, handler, config) catch |err| {
            handler.vtable.report_error(handler.ptr, err);
            continue;
        };
    }
}

/// Serve one connection until the peer closes or the session fails.
pub fn serve(
    io: Io,
    stream: Io.net.Stream,
    handler: Handler,
    config: Config,
) !void {
    if (config.read_buffer.len == 0 or config.write_buffer.len == 0) {
        return error.NoBuffer;
    }

    var conn = try Connection.init(.{
        .allocator = config.allocator,
        .handler = handler,
        .max_streams = config.max_streams,
        .body_bytes = config.body_bytes,
        .arena_retain_bytes = config.arena_retain_bytes,
        .session = config.session,
    });
    defer conn.deinit();

    var reader = stream.reader(io, &.{});
    var writer = stream.writer(io, config.write_buffer);
    const r = &reader.interface;
    const w = &writer.interface;
    var out_buffer: [4096]u8 = undefined;

    while (true) {
        _ = conn.drive(Io.Timestamp.zero) catch |err| {
            flush(&conn, w, &out_buffer) catch |flush_err| {
                _ = @errorName(flush_err);
            };
            return err;
        };
        try flush(&conn, w, &out_buffer);
        if (try conn.drive(Io.Timestamp.zero)) continue;
        if (conn.isClosed()) {
            try flush(&conn, w, &out_buffer);
            return;
        }

        var vecs: [1][]u8 = .{config.read_buffer};
        const n = r.readVec(&vecs) catch |err| switch (err) {
            error.EndOfStream => return,
            error.ReadFailed => return err,
        };
        if (n == 0) return;

        var offset: usize = 0;
        while (offset < n) {
            const consumed = conn.receive(config.read_buffer[offset..n]);
            if (consumed == 0) {
                if (conn.isClosed()) try flush(&conn, w, &out_buffer);
                return error.InputFull;
            }
            offset += consumed;

            _ = conn.drive(Io.Timestamp.zero) catch |err| {
                flush(&conn, w, &out_buffer) catch |flush_err| {
                    _ = @errorName(flush_err);
                };
                return err;
            };
            if (conn.isClosed()) {
                try flush(&conn, w, &out_buffer);
                return;
            }
        }
    }
}

fn flush(conn: *Connection, w: *Io.Writer, out: []u8) !void {
    while (true) {
        const n = conn.send(out);
        if (n == 0) break;
        try w.writeAll(out[0..n]);
    }
    try w.flush();
}
