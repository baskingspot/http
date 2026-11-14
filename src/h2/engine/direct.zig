//! An HTTP/2 server engine over std.Io, one connection per call.
//!
//! The engine owns the transport loop, not the exchange state. It feeds the
//! shared `Connection` core, flushes queued output, and waits on reads. One
//! connection is served at a time; the h2c example adds a thread per
//! connection. Handler wakes (`Exchange.setDeadline`) are delivered on the
//! awake clock; the engine's own close deadlines are not enforced, like
//! `h1.engine.direct`.

const std = @import("std");
const Io = std.Io;
const posix = std.posix;
const Allocator = std.mem.Allocator;

const OptionalFd = @import("stdx").posix.OptionalFd;

const shared = @import("../../engine/common.zig");
const session_mod = @import("../session.zig");
const Options = session_mod.Options;
const common = @import("common.zig");
pub const Exchange = common.Exchange;
pub const Handler = common.Handler;
pub const Request = common.Request;
pub const ResponseOptions = common.ResponseOptions;
const connection_mod = @import("connection.zig");
const Connection = connection_mod.Connection;
pub const BodyMode = connection_mod.BodyMode;

// ast-grep-ignore: public-struct-field-default -- options bag; defaults are the policy
pub const Config = struct {
    allocator: Allocator,
    /// Transport read scratch fed to `Connection.receive`.
    read_buffer: []u8,
    /// The `std.Io` writer's buffer.
    write_buffer: []u8,
    /// Engine slot count and the session's MAX_CONCURRENT_STREAMS.
    max_streams: u16 = 128,
    common: shared.Config = .{ .arena_retain_bytes = 4 * 1024 },
    session: Options = .{ .role = .server },
    /// `.buffered` runs the handler on the complete body. `.stream` runs it on
    /// the request head, so it can answer before END_STREAM.
    body_mode: BodyMode = .buffered,
    /// The transport socket, when the engine can wait on it. A handler that
    /// parks with `Exchange.setDeadline` is woken at that time even if the
    /// peer sends nothing: the read waits on this fd only until the earliest
    /// armed wake. `.none` keeps the plain blocking read, where a wake arrives
    /// together with the next input. `serve` sets it from the stream; a TLS
    /// caller passes the transport's socket handle.
    wait_fd: OptionalFd = .none,
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

/// Serve one connection over a transport stream.
pub fn serve(
    io: Io,
    stream: Io.net.Stream,
    handler: Handler,
    config: Config,
) !void {
    if (config.read_buffer.len == 0 or config.write_buffer.len == 0) {
        return error.NoBuffer;
    }

    var reader = stream.reader(io, &.{});
    var writer = stream.writer(io, config.write_buffer);
    var waited = config;
    waited.wait_fd = .init(stream.socket.handle);
    try serveIo(io, &reader.interface, &writer.interface, handler, waited);
}

/// Serve one connection over an already-open reader/writer pair. This is the
/// TLS seam: a `tls_std` server hands its reader and writer here, and the h2
/// session runs over decrypted bytes.
///
/// A handler that parks with `Exchange.setDeadline` is woken at that time:
/// with `wait_fd` set the read waits on the socket only until the earliest
/// wake, and the clock drives the rest. Without `wait_fd`, a wake arrives
/// with the next input, because the plain read has no timeout.
pub fn serveIo(
    io: Io,
    reader: *Io.Reader,
    writer: *Io.Writer,
    handler: Handler,
    config: Config,
) !void {
    if (config.read_buffer.len == 0) return error.NoBuffer;

    var conn: Connection = try .init(.{
        .allocator = config.allocator,
        .handler = handler,
        .max_streams = config.max_streams,
        .body_bytes = config.common.body_bytes,
        .arena_retain_bytes = config.common.arena_retain_bytes,
        .session = config.session,
        .body_mode = config.body_mode,
    });
    defer conn.deinit();

    var out_buffer: [4096]u8 = undefined;

    while (true) {
        const now: Io.Timestamp = .now(io, .awake);
        _ = conn.drive(now) catch |err| {
            flush(&conn, writer, &out_buffer) catch |flush_err| {
                _ = @errorName(flush_err);
            };
            return err;
        };
        try flush(&conn, writer, &out_buffer);
        if (try conn.drive(now)) continue;
        if (conn.isClosed()) {
            try flush(&conn, writer, &out_buffer);
            return;
        }

        // A parked handler armed a wake time. Wait for input or that time,
        // whichever comes first, so the wake is delivered without cross
        // traffic on the connection.
        if (try waitOrWake(io, &conn, config.wait_fd)) continue;

        var vecs: [1][]u8 = .{config.read_buffer};
        const n = reader.readVec(&vecs) catch |err| switch (err) {
            error.EndOfStream => return,
            error.ReadFailed => return err,
        };
        if (n == 0) return;

        var offset: usize = 0;
        while (offset < n) {
            const consumed = conn.receive(config.read_buffer[offset..n]);
            if (consumed == 0) {
                if (conn.isClosed()) try flush(&conn, writer, &out_buffer);
                return error.InputFull;
            }
            offset += consumed;

            _ = conn.drive(now) catch |err| {
                flush(&conn, writer, &out_buffer) catch |flush_err| {
                    _ = @errorName(flush_err);
                };
                return err;
            };
            if (conn.isClosed()) {
                try flush(&conn, writer, &out_buffer);
                return;
            }
        }
    }
}

/// Wait for the earliest handler wake without missing input. True means the
/// wait ended at the wake time, or the wake is already due: the caller loops
/// and `drive` delivers it. False means input is waiting, or no wake is armed
/// or no fd was given, and the caller takes the plain blocking read.
fn waitOrWake(io: Io, conn: *Connection, fd: OptionalFd) !bool {
    const wake_at = conn.wakeDeadline() orelse return false;
    const fd_value = fd.get() orelse return false;
    const now: Io.Timestamp = .now(io, .awake);
    if (now.nanoseconds >= wake_at.nanoseconds) return true;

    const remaining = wake_at.nanoseconds - now.nanoseconds;
    const bounded: u64 = @intCast(@min(remaining, std.math.maxInt(i64)));
    const ms: i32 = @intCast(@min(
        (bounded + std.time.ns_per_ms - 1) / std.time.ns_per_ms,
        std.math.maxInt(i32),
    ));
    var fds = [_]posix.pollfd{.{
        .fd = fd_value,
        .events = posix.POLL.IN,
        .revents = 0,
    }};
    _ = try posix.poll(&fds, ms);
    const input = fds[0].revents & (posix.POLL.IN |
        posix.POLL.HUP |
        posix.POLL.ERR) != 0;
    return !input;
}

fn flush(conn: *Connection, w: *Io.Writer, out: []u8) !void {
    while (true) {
        const n = conn.send(out);
        if (n == 0) break;
        try w.writeAll(out[0..n]);
    }
    try w.flush();
}
