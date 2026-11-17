//! A cleartext connector over `std.Io.net`.
//!
//! The connector resolves the URL's host, reaches the first address that
//! accepts, and hands back a reader, a writer, and the prior-knowledge
//! protocol. It speaks `http` only: an `https` URL is `error.TlsUnsupported`,
//! because sending cleartext to a TLS port is never what the caller meant.
//!
//! Deadlines are one absolute value on the awake clock, honored by every read
//! and write on the connection. Reads go through `Io.Batch` with a `net_read`
//! operation, which on the threaded backend is a `poll(2)` with the remaining
//! time. Writes use `MSG_DONTWAIT` and the same wait, because a blocking write
//! on a large payload waits for the whole payload regardless of how long the
//! poll said the socket was ready.
//!
//! Name resolution is not bounded. `std.Io` has no lookup timeout, so the
//! deadline starts once the host is a list of addresses.

const std = @import("std");
const Io = std.Io;
const mem = std.mem;
const posix = std.posix;
const assert = std.debug.assert;
const Allocator = mem.Allocator;
const testing = std.testing;
const stdx = @import("stdx");
const time = stdx.time;
const HostName = Io.net.HostName;
const IpAddress = Io.net.IpAddress;

const Header = @import("../header.zig").Header;
const common = @import("common.zig");
const transport = @import("transport.zig");
const BufferedWriter = @import("buffered_writer.zig").BufferedWriter;
const Protocol = transport.Protocol;
const Url = @import("../uri.zig").Url;

/// Addresses one dial tries before giving up.
pub const max_addresses = 8;

/// Longest a wait runs before the progress hook gets a turn. Only used when a
/// hook is set; without one the wait runs to the deadline.
const progress_slice_ms = 250;

/// `Io.Operation` carries socket reads and writes, so every read on this
/// connector can be bounded by the deadline.
pub const deadline_supported = true;

pub const Error = error{
    /// The URL uses a scheme this connector cannot speak.
    TlsUnsupported,
    /// The host is not an address literal and does not resolve.
    UnknownHostName,
    /// The host is neither an address nor a DNS name.
    InvalidHost,
    /// The deadline expired, in the dial or on a later wait.
    TimedOut,
    /// The progress hook returned false.
    Stopped,
    /// The transfer hook asked for a stop during a read.
    Canceled,
    /// The peer refused the connection.
    ConnectionRefused,
    /// No route to the peer.
    NetworkUnreachable,
    /// The host does not answer.
    HostUnreachable,
    /// The address family is not supported here.
    AddressFamilyUnsupported,
    /// The peer closed the connection.
    ConnectionResetByPeer,
    /// The socket was never connected.
    NotConnected,
    /// A local resource limit.
    SystemResources,
    /// A deadline was requested on a Zig version that cannot honor one.
    DeadlineUnsupported,
    /// `Io` has no polling backend for this operation.
    ConcurrencyUnavailable,
    /// Allocation failed.
    OutOfMemory,
};

// ast-grep-ignore: public-struct-field-default -- options bag; h1 is the cleartext default
pub const Config = struct {
    /// Cleartext protocol. `h2` is prior knowledge; this connector never
    /// upgrades a connection.
    protocol: Protocol = .h1,
    /// Set `TCP_NODELAY` after connect. A refused option is not fatal: the
    /// connection works, it just waits on Nagle.
    no_delay: bool = true,
};

pub const Connector = struct {
    config: Config,

    pub fn init(config: Config) Connector {
        return .{ .config = config };
    }

    /// The type-erased handle. The returned value borrows `self`, so the
    /// connector stays put while any connection it made is alive.
    pub fn handle(self: *Connector) transport.Connector {
        return .{ .ptr = self, .vtable = &connector_vtable };
    }
};

const connector_vtable: transport.Connector.VTable = .{ .connect = connectorConnect };

fn connectorConnect(ptr: *anyopaque, context: transport.Context) anyerror!transport.Connection {
    const self: *Connector = @ptrCast(@alignCast(ptr));
    const conn = try Connection.open(context, self.config);
    return conn.handle();
}

/// One cleartext connection. Allocated from `Context.gpa` because the reader
/// and writer it hands out point into it.
pub const Connection = struct {
    allocator: Allocator,
    io: Io,
    stream: Io.net.Stream,
    reader: Io.Reader,
    raw_writer: Io.Writer,
    /// Batches the request head and body chunks into one write each.
    out: BufferedWriter,
    protocol: Protocol,
    /// Consulted while a read waits, so a caller can stop a stream it is
    /// blocked on. Borrowed from `Context.progress`.
    cancel: ?transport.Progress,
    deadline: time.OptionalTimestamp,
    read_cause: ?anyerror,
    write_cause: ?anyerror,

    fn open(context: transport.Context, config: Config) Error!*Connection {
        if (context.url.scheme == .https) return error.TlsUnsupported;

        const stream = try connectStream(context, .{ .no_delay = config.no_delay });
        errdefer stream.close(context.io);

        const self = try context.gpa.create(Connection);
        self.* = .{
            .allocator = context.gpa,
            .io = context.io,
            .stream = stream,
            .reader = .{
                .vtable = &reader_vtable,
                .buffer = &.{},
                .seek = 0,
                .end = 0,
            },
            .raw_writer = .{
                .vtable = &writer_vtable,
                .buffer = &.{},
                .end = 0,
            },
            .out = undefined,
            .protocol = config.protocol,
            .cancel = context.progress,
            .deadline = context.deadline,
            .read_cause = null,
            .write_cause = null,
        };
        self.out.init(&self.raw_writer);
        return self;
    }

    fn handle(self: *Connection) transport.Connection {
        return .{
            .reader = &self.reader,
            .writer = self.out.writer(),
            .protocol = self.protocol,
            .ptr = self,
            .vtable = &connection_vtable,
        };
    }

    fn close(self: *Connection) void {
        self.stream.close(self.io);
        self.* = undefined;
    }
};

const connection_vtable: transport.Connection.VTable = .{
    .deinit = connectionDeinit,
    .shutdown = connectionShutdown,
    .setDeadline = connectionSetDeadline,
    .readCause = connectionReadCause,
    .writeCause = connectionWriteCause,
    .setCancel = connectionSetCancel,
};

fn connectionSetCancel(ptr: *anyopaque, cancel: ?transport.Progress) void {
    const self: *Connection = @ptrCast(@alignCast(ptr));
    self.cancel = cancel;
}

fn ignoreError(_: anyerror) void {}

fn connectionShutdown(ptr: *anyopaque) void {
    const self: *Connection = @ptrCast(@alignCast(ptr));
    self.stream.shutdown(self.io, .both) catch |err| ignoreError(err);
}

fn connectionDeinit(ptr: *anyopaque) void {
    const self: *Connection = @ptrCast(@alignCast(ptr));
    const allocator = self.allocator;
    self.close();
    allocator.destroy(self);
}

fn connectionSetDeadline(
    ptr: *anyopaque,
    deadline: time.OptionalTimestamp,
) error{DeadlineUnsupported}!void {
    const self: *Connection = @ptrCast(@alignCast(ptr));
    self.deadline = deadline;
}

fn connectionReadCause(ptr: *const anyopaque) ?anyerror {
    const self: *const Connection = @ptrCast(@alignCast(ptr));
    return self.read_cause;
}

fn connectionWriteCause(ptr: *const anyopaque) ?anyerror {
    const self: *const Connection = @ptrCast(@alignCast(ptr));
    return self.write_cause;
}

const reader_vtable: Io.Reader.VTable = .{
    .stream = readerStream,
    .readVec = readerReadVec,
};

const writer_vtable: Io.Writer.VTable = .{
    .drain = writerDrain,
};

fn readerStream(
    erased: *Io.Reader,
    w: *Io.Writer,
    limit: Io.Limit,
) Io.Reader.StreamError!usize {
    const self: *Connection = @alignCast(@fieldParentPtr("reader", erased));
    const destination = limit.slice(try w.writableSliceGreedy(1));
    if (destination.len == 0) return 0;
    var buffers = [_][]u8{destination};
    const count = readOnce(self, &buffers) catch return error.ReadFailed;
    if (count == 0) return error.EndOfStream;
    w.advance(count);
    return count;
}

fn readerReadVec(erased: *Io.Reader, data: [][]u8) Io.Reader.Error!usize {
    const self: *Connection = @alignCast(@fieldParentPtr("reader", erased));
    // The socket read asserts its first buffer is non-empty, and a caller may
    // hand over an empty one.
    var first: usize = 0;
    while (first < data.len and data[first].len == 0) first += 1;
    if (first == data.len) return 0;
    const count = readOnce(self, data[first..]) catch return error.ReadFailed;
    if (count == 0) return error.EndOfStream;
    return count;
}

/// One socket read. A zero return is end of stream, not an error, and every
/// failure latches its cause for `transport.Connection.readCause`.
fn readOnce(self: *Connection, buffers: [][]u8) Error!usize {
    self.read_cause = null;
    while (true) {
        if (shouldCancel(self)) {
            self.read_cause = error.Canceled;
            return error.Canceled;
        }
        var storage: [1]Io.Operation.Storage = undefined;
        var batch: Io.Batch = .init(&storage);
        const index = batch.add(.{ .net_read = .{
            .socket_handle = self.stream.socket.handle,
            .data = buffers,
        } });
        // A cancel slice that expires without data only means the hook gets
        // another turn; the caller's deadline is what actually ends a read.
        const whole_wait = waitForRead(self, &batch) catch |err| {
            self.read_cause = err;
            return err;
        };
        if (!whole_wait) continue;
        const completion = batch.next() orelse {
            self.read_cause = error.ConcurrencyUnavailable;
            return error.ConcurrencyUnavailable;
        };
        assert(completion.index == index);
        const result = completion.result.net_read catch |err| {
            self.read_cause = err;
            return error.SystemResources;
        };
        return result.data_len;
    }
}

/// How long one read may wait before the transfer hook is consulted again.
const cancel_poll_ns: u64 = 100 * std.time.ns_per_ms;

fn shouldCancel(self: *const Connection) bool {
    const cancel = self.cancel orelse return false;
    return !cancel.run(.transfer);
}

/// Wait for the read batch. Returns false when the wait was one cancel slice,
/// so the caller consults the hook and waits again. A timeout or a cancel is
/// reaped before the batch's stack storage dies.
fn waitForRead(self: *Connection, batch: *Io.Batch) Error!bool {
    const timeout: Io.Timeout = if (waitDeadline(self)) |value|
        .{ .deadline = Io.Timestamp.fromNanoseconds(value.nanoseconds).withClock(.awake) }
    else
        .none;
    batch.awaitConcurrent(self.io, timeout) catch |err| {
        batch.cancel(self.io);
        return switch (err) {
            error.Timeout => if (self.cancel != null and !expired(self.deadline))
                false
            else
                error.TimedOut,
            error.Canceled => error.Stopped,
            error.ConcurrencyUnavailable => error.ConcurrencyUnavailable,
        };
    };
    return true;
}

/// The earlier of the caller's deadline and one cancel slice, when the
/// transfer hook is set.
fn waitDeadline(self: *const Connection) ?time.Timestamp {
    if (self.cancel == null) return self.deadline.get();
    const now = @as(u64, @intCast(time.now(.awake).nanoseconds));
    const slice = std.math.add(u64, now, cancel_poll_ns) catch std.math.maxInt(u64);
    const at: time.Timestamp = .fromNanoseconds(slice);
    const deadline = self.deadline.get() orelse return at;
    return if (deadline.nanoseconds <= at.nanoseconds) deadline else at;
}

fn writerDrain(
    w: *Io.Writer,
    data: []const []const u8,
    splat: usize,
) Io.Writer.Error!usize {
    const self: *Connection = @alignCast(@fieldParentPtr("raw_writer", w));
    self.write_cause = null;
    var total: usize = 0;
    for (data, 0..) |slice, index| {
        const repeat = if (index + 1 == data.len) splat else 1;
        for (0..repeat) |_| {
            writeFully(self, slice) catch return error.WriteFailed;
            total += slice.len;
        }
    }
    return total;
}

/// Write every byte or fail. A failure can leave a prefix on the wire, so the
/// connection is not reusable after `error.WriteFailed`.
fn writeFully(self: *Connection, bytes: []const u8) Error!void {
    var rest = bytes;
    while (rest.len != 0) {
        const sent = sendOnce(self, rest) catch |err| {
            self.write_cause = err;
            return err;
        };
        if (sent == 0) {
            waitBeforeWrite(self) catch |err| {
                self.write_cause = err;
                return err;
            };
            continue;
        }
        rest = rest[sent..];
    }
}

/// Send what the socket takes now. `MSG_DONTWAIT` is deliberate: a blocking
/// send waits for the entire payload even when the poll said one byte fits,
/// which would outlast any deadline.
fn sendOnce(self: *Connection, bytes: []const u8) Error!usize {
    var iovec = [_]posix.iovec_const{.{ .base = bytes.ptr, .len = bytes.len }};
    var message: posix.msghdr_const = .{
        .name = null,
        .namelen = 0,
        .iov = &iovec,
        .iovlen = 1,
        .control = null,
        .controllen = 0,
        .flags = 0,
    };
    while (true) {
        const rc = posix.system.sendmsg(
            self.stream.socket.handle,
            &message,
            posix.MSG.NOSIGNAL | posix.MSG.DONTWAIT,
        );
        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .AGAIN => return 0,
            .PIPE, .CONNRESET => return error.ConnectionResetByPeer,
            .NOTCONN => return error.NotConnected,
            .TIMEDOUT => return error.TimedOut,
            .NOBUFS, .NOMEM => return error.SystemResources,
            else => return error.SystemResources,
        }
    }
}

fn waitBeforeWrite(self: *Connection) Error!void {
    if (expired(self.deadline)) return error.TimedOut;
    var poll_fds = [_]posix.pollfd{.{
        .fd = self.stream.socket.handle,
        .events = posix.POLL.OUT,
        .revents = 0,
    }};
    while (true) {
        const timeout = try pollTimeout(self.deadline, null);
        const ready = posix.poll(&poll_fds, timeout) catch return error.SystemResources;
        if (ready != 0) return;
        if (expired(self.deadline)) return error.TimedOut;
    }
}

// ---------------------------------------------------------------------------
// Dialing
// ---------------------------------------------------------------------------

/// What the dial applies after the stream is connected.
// ast-grep-ignore: public-struct-field-default -- options bag; no-delay is the default
pub const DialOptions = struct {
    /// Set `TCP_NODELAY`. Shared by every transport that uses this dial.
    no_delay: bool = true,
};

/// Resolve and connect the URL's host without wrapping the stream in an HTTP
/// connection. A TLS connector uses this and then adds its own record layer.
pub fn connectStream(context: transport.Context, options: DialOptions) Error!Io.net.Stream {
    const stream = try dial(context);
    errdefer stream.close(context.io);
    if (options.no_delay) {
        // A stack that refuses NODELAY serializes small writes for the life of
        // the connection, so it fails the dial rather than silently dropping
        // the promise.
        stdx.posix.setsockopt(
            stream.socket.handle,
            posix.IPPROTO.TCP,
            posix.TCP.NODELAY,
            1,
        ) catch return error.SystemResources;
    }
    return stream;
}

fn dial(context: transport.Context) Error!Io.net.Stream {
    const deadline = context.dialDeadline();
    if (expired(deadline)) return error.TimedOut;
    if (context.progress) |progress| {
        if (!progress.run(.resolve)) return error.Stopped;
    }

    if (context.address) |address| {
        if (context.progress) |progress| {
            if (!progress.run(.connect)) return error.Stopped;
        }
        return connectAddress(context, address, deadline);
    }

    var addresses: [max_addresses]IpAddress = undefined;
    const count = try resolve(context.io, context.url.host, context.url.port, &addresses);
    if (count == 0) return error.UnknownHostName;

    var last: Error = error.UnknownHostName;
    for (addresses[0..count]) |address| {
        if (context.progress) |progress| {
            if (!progress.run(.connect)) return error.Stopped;
        }
        const stream = connectAddress(context, address, deadline) catch |err| switch (err) {
            error.TimedOut,
            error.Stopped,
            error.InvalidHost,
            error.DeadlineUnsupported,
            => return err,
            else => {
                last = err;
                continue;
            },
        };
        return stream;
    }
    return last;
}

/// Address literals bypass DNS. A name resolves to every address the lookup
/// returns, in order; the caller's deadline and progress hook govern how many
/// are tried.
fn resolve(
    io: Io,
    host: []const u8,
    port: u16,
    out: []IpAddress,
) Error!usize {
    if (IpAddress.parse(host, port)) |address| {
        out[0] = address;
        return 1;
    } else |_| {}

    const host_name: HostName = HostName.init(host) catch return error.InvalidHost;
    var results: [max_addresses]HostName.LookupResult = undefined;
    var queue: Io.Queue(HostName.LookupResult) = .init(&results);

    // The resolver blocks when the queue is full, and a headless Service can
    // answer with more addresses than the queue holds. Run it as a task and
    // drain it from here instead of waiting for it to finish first.
    var lookup: Lookup = .{
        .io = io,
        .host_name = host_name,
        .port = port,
        .queue = &queue,
    };
    var future = io.async(Lookup.run, .{&lookup});
    defer {
        future.cancel(io);
        // A canceled lookup may still be parked on a full queue. Take what is
        // left so it can observe the cancel and finish.
        while (queue.getOneUncancelable(io)) |_| {} else |_| {}
    }

    var count: usize = 0;
    while (count < out.len) {
        const result = queue.getOne(io) catch |err| switch (err) {
            // The lookup closes the queue after the last result.
            error.Closed => break,
            error.Canceled => return error.Stopped,
        };
        switch (result) {
            .address => |address| {
                out[count] = address;
                count += 1;
            },
            .canonical_name => {},
        }
    }
    if (count == 0) {
        // The queue is closed, so the lookup has finished; take its error
        // rather than report every failure as a missing name.
        future.await(io);
        if (lookup.failure) |failure| {
            return switch (failure) {
                error.Canceled => error.Stopped,
                else => error.UnknownHostName,
            };
        }
    }
    return count;
}

/// One name lookup, run as a task so the caller can drain a bounded queue.
const Lookup = struct {
    io: Io,
    host_name: HostName,
    port: u16,
    queue: *Io.Queue(HostName.LookupResult),
    failure: ?anyerror = null,

    fn run(self: *Lookup) void {
        self.host_name.lookup(self.io, self.queue, .{ .port = self.port }) catch |err| {
            self.failure = err;
        };
    }
};

fn connectAddress(
    context: transport.Context,
    address: IpAddress,
    deadline: time.OptionalTimestamp,
) Error!Io.net.Stream {
    const family: posix.sa_family_t = switch (address) {
        .ip4 => posix.AF.INET,
        .ip6 => posix.AF.INET6,
    };
    const raw = posix.system.socket(family, posix.SOCK.STREAM, posix.IPPROTO.TCP);
    if (posix.errno(raw) != .SUCCESS) return error.SystemResources;
    const fd: posix.socket_t = @intCast(raw);
    errdefer _ = posix.system.close(fd);
    try setCloexec(fd);
    try setNonBlocking(fd, true);
    errdefer setNonBlocking(fd, false) catch {};

    var storage: posix.sockaddr.storage = mem.zeroes(posix.sockaddr.storage);
    const address_length = fillSockaddr(&storage, address);

    var connecting = true;
    while (true) {
        const rc = posix.system.connect(fd, @ptrCast(&storage), address_length);
        switch (posix.errno(rc)) {
            .SUCCESS => {
                connecting = false;
                break;
            },
            .INTR => continue,
            .AGAIN, .INPROGRESS => break,
            .CONNREFUSED => return error.ConnectionRefused,
            .NETUNREACH => return error.NetworkUnreachable,
            .HOSTUNREACH => return error.HostUnreachable,
            .TIMEDOUT => return error.TimedOut,
            .AFNOSUPPORT => return error.AddressFamilyUnsupported,
            .MFILE, .NFILE, .NOBUFS, .NOMEM => return error.SystemResources,
            .ACCES, .PERM => return error.SystemResources,
            else => return error.SystemResources,
        }
    }

    if (connecting) {
        try waitWritable(fd, deadline, context.progress);
        const so_error = getsockoptError(fd) catch return error.SystemResources;
        if (so_error != 0) return errnoToError(so_error);
    }

    // The read path needs a blocking descriptor: `Io.Batch` polls, then does
    // the read, and a nonblocking read after a spurious wakeup would trip an
    // unexpected-errno assertion inside `Io`.
    try setNonBlocking(fd, false);

    return .{ .socket = .{ .handle = fd, .address = address } };
}

fn errnoToError(so_error: c_int) Error {
    // The value comes back from `getsockopt(SO_ERROR)` as a bare errno, not as
    // the enum `posix.system` maps, so it needs its own mapping.
    return switch (so_error) {
        @intCast(@backingInt(posix.E.CONNREFUSED)) => error.ConnectionRefused,
        @intCast(@backingInt(posix.E.NETUNREACH)) => error.NetworkUnreachable,
        @intCast(@backingInt(posix.E.HOSTUNREACH)) => error.HostUnreachable,
        @intCast(@backingInt(posix.E.TIMEDOUT)) => error.TimedOut,
        @intCast(@backingInt(posix.E.CONNRESET)) => error.ConnectionResetByPeer,
        @intCast(@backingInt(posix.E.AFNOSUPPORT)) => error.AddressFamilyUnsupported,
        else => error.SystemResources,
    };
}

/// Wait until `fd` is writable, in slices when a progress hook is set, and
/// until the deadline at most.
fn waitWritable(
    fd: posix.socket_t,
    deadline: time.OptionalTimestamp,
    progress: ?transport.Progress,
) Error!void {
    var poll_fds = [_]posix.pollfd{.{
        .fd = fd,
        .events = posix.POLL.OUT,
        .revents = 0,
    }};
    while (true) {
        const timeout = try pollTimeout(deadline, progress);
        const ready = posix.poll(&poll_fds, timeout) catch |err| switch (err) {
            error.SystemResources => return error.SystemResources,
            else => return error.SystemResources,
        };
        if (ready != 0) return;
        if (deadline.get() != null and expired(deadline)) return error.TimedOut;
        if (progress) |hook| {
            if (!hook.run(.connect)) return error.Stopped;
        }
    }
}

/// Milliseconds until the deadline, or the progress slice when a hook is set.
fn pollTimeout(
    deadline: time.OptionalTimestamp,
    progress: ?transport.Progress,
) Error!i32 {
    const value = deadline.get() orelse
        return if (progress != null) progress_slice_ms else -1;
    const now = @as(u64, @intCast(time.now(.awake).nanoseconds));
    if (now >= value.nanoseconds) return error.TimedOut;
    const remaining_ms = (value.nanoseconds - now) / std.time.ns_per_ms;
    if (remaining_ms == 0) return 0;
    const capped: i32 = @intCast(@min(remaining_ms, std.math.maxInt(i32) / 2));
    return if (progress != null) @min(capped, progress_slice_ms) else capped;
}

fn expired(deadline: time.OptionalTimestamp) bool {
    const value = deadline.get() orelse return false;
    return @as(u64, @intCast(time.now(.awake).nanoseconds)) >= value.nanoseconds;
}

fn getsockoptError(fd: posix.socket_t) !c_int {
    return stdx.posix.getsockopt(fd, posix.SOL.SOCKET, posix.SO.ERROR);
}

fn setCloexec(fd: posix.socket_t) !void {
    const rc = posix.system.fcntl(fd, posix.F.SETFD, @as(usize, posix.FD_CLOEXEC));
    if (posix.errno(rc) != .SUCCESS) return error.SystemResources;
}

fn setNonBlocking(fd: posix.socket_t, enabled: bool) !void {
    const raw = posix.system.fcntl(fd, posix.F.GETFL, @as(usize, 0));
    if (posix.errno(raw) != .SUCCESS) return error.SystemResources;
    var flags: posix.O = @bitCast(@as(u32, @intCast(raw)));
    flags.NONBLOCK = enabled;
    const set = posix.system.fcntl(fd, posix.F.SETFL, @as(u32, @bitCast(flags)));
    if (posix.errno(set) != .SUCCESS) return error.SystemResources;
}

fn fillSockaddr(storage: *posix.sockaddr.storage, address: IpAddress) posix.socklen_t {
    switch (address) {
        .ip4 => |ip| {
            const in: posix.sockaddr.in = .{
                .port = mem.nativeToBig(u16, ip.port),
                .addr = @bitCast(ip.bytes),
            };
            @memcpy(
                mem.asBytes(storage)[0..@sizeOf(posix.sockaddr.in)],
                mem.asBytes(&in),
            );
            return @sizeOf(posix.sockaddr.in);
        },
        .ip6 => |ip| {
            const in6: posix.sockaddr.in6 = .{
                .port = mem.nativeToBig(u16, ip.port),
                .flowinfo = 0,
                .addr = ip.bytes,
                .scope_id = 0,
            };
            @memcpy(
                mem.asBytes(storage)[0..@sizeOf(posix.sockaddr.in6)],
                mem.asBytes(&in6),
            );
            return @sizeOf(posix.sockaddr.in6);
        },
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const dispatch = @import("dispatch.zig");

/// One loopback listener that answers exactly one connection.
const Fixture = struct {
    io: Io,
    listener: Io.net.Server,
    address: IpAddress,
    response: []const u8,
    /// Milliseconds to wait after the head-and-body write before closing.
    hold_ms: u64,
    result: ?anyerror = null,
    thread: std.Thread,

    /// Initialize in its final location: the server thread holds a pointer
    /// here for the whole test.
    fn init(self: *Fixture, response: []const u8, hold_ms: u64) !void {
        self.* = .{
            .io = testing.io,
            .listener = undefined,
            .address = try .parseLiteral("127.0.0.1:0"),
            .response = response,
            .hold_ms = hold_ms,
            .thread = undefined,
        };
        self.listener = try self.address.listen(self.io, .{
            .mode = .stream,
            .reuse_address = true,
        });
        self.address.setPort(self.listener.socket.address.getPort());
        self.thread = try .spawn(.{}, run, .{self});
    }

    fn deinit(self: *Fixture) void {
        self.thread.join();
        self.listener.deinit(self.io);
        if (self.result) |failure| @panic(@errorName(failure));
        self.* = undefined;
    }

    fn run(self: *Fixture) void {
        const stream = self.listener.accept(self.io) catch |err| {
            self.result = err;
            return;
        };
        defer stream.close(self.io);

        var request: [1024]u8 = undefined;
        var used: usize = 0;
        var reader = stream.reader(self.io, &.{});
        while (used < request.len) {
            var iovecs: [1][]u8 = .{request[used..]};
            used += reader.interface.readVec(&iovecs) catch break;
            if (mem.find(u8, request[0..used], "\r\n\r\n") != null) break;
        }

        var buffer: [256]u8 = undefined;
        var writer = stream.writer(self.io, &buffer);
        writer.interface.writeAll(self.response) catch |err| {
            self.result = err;
            return;
        };
        writer.interface.flush() catch |err| {
            self.result = err;
            return;
        };
        if (self.hold_ms != 0) {
            const hold = self.hold_ms * std.time.ns_per_ms;
            self.io.sleep(.{ .nanoseconds = hold }, .awake) catch |err| {
                self.result = err;
                return;
            };
        }
    }
};

fn parseFor(port: u16, buffer: []u8, scheme: []const u8) !Url {
    const text = try mem.print(buffer, "{s}://127.0.0.1:{d}/", .{ scheme, port });
    return Url.parse(testing.allocator, text);
}

test "a dial that opens with https is refused" {
    var text: [64]u8 = undefined;
    const url = try parseFor(443, &text, "https");
    defer url.deinit(testing.allocator);

    var connector: Connector = .init(.{});
    try testing.expectError(error.TlsUnsupported, connector.handle().connect(.{
        .io = testing.io,
        .gpa = testing.allocator,
        .url = url,
    }));
}

test "a progress hook can stop the dial before it connects" {
    var text: [64]u8 = undefined;
    const url = try parseFor(1, &text, "http");
    defer url.deinit(testing.allocator);

    var state: StopState = .{};
    var connector: Connector = .init(.{});
    try testing.expectError(error.Stopped, connector.handle().connect(.{
        .io = testing.io,
        .gpa = testing.allocator,
        .url = url,
        .progress = .{ .context = &state, .step = StopState.step },
    }));
    try testing.expectEqual(@as(usize, 1), state.calls);
    try testing.expectEqual(transport.Phase.resolve, state.last.?);
}

const StopState = struct {
    calls: usize = 0,
    last: ?transport.Phase = null,

    fn step(context: *anyopaque, phase: transport.Phase) bool {
        const self: *StopState = @ptrCast(@alignCast(context));
        self.calls += 1;
        self.last = phase;
        return false;
    }
};

test "an expired deadline ends the dial before it resolves" {
    var text: [64]u8 = undefined;
    const url = try parseFor(1, &text, "http");
    defer url.deinit(testing.allocator);

    const past = try time.OptionalTimestamp.init(.fromNanoseconds(1));
    var connector: Connector = .init(.{});
    try testing.expectError(error.TimedOut, connector.handle().connect(.{
        .io = testing.io,
        .gpa = testing.allocator,
        .url = url,
        .deadline = past,
    }));
}

test "the connector carries a request and a streaming body" {
    var fixture: Fixture = undefined;
    try fixture.init(
        "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello",
        0,
    );
    defer fixture.deinit();

    var text: [64]u8 = undefined;
    const url = try parseFor(fixture.address.getPort(), &text, "http");
    defer url.deinit(testing.allocator);

    var connector: Connector = .init(.{});
    var connection = try connector.handle().connect(.{
        .io = testing.io,
        .gpa = testing.allocator,
        .url = url,
    });
    defer connection.deinit();
    try testing.expectEqual(Protocol.h1, connection.protocol);

    var client: dispatch.Client = undefined;
    try client.attached(connection.reader, connection.writer, .{
        .protocol = connection.protocol,
        .common = .{
            .allocator = testing.allocator,
            .read_cause = connection.cause(),
        },
    });
    defer client.deinit();

    var response = try client.request(.{
        .method = .GET,
        .scheme = .http,
        .authority = url.authority,
        .target = url.target,
    });
    defer response.body.close();

    var got: [8]u8 = undefined;
    var writer: Io.Writer = .fixed(&got);
    const used = try response.body.reader.streamRemaining(&writer);
    try testing.expectEqualStrings("hello", got[0..used]);
    try testing.expect(response.body.outcome() == null);
}

test "a body read the deadline ended is a local timeout" {
    var fixture: Fixture = undefined;
    try fixture.init(
        "HTTP/1.1 200 OK\r\nContent-Length: 20\r\nConnection: close\r\n\r\nshort",
        250,
    );
    defer fixture.deinit();

    var text: [64]u8 = undefined;
    const url = try parseFor(fixture.address.getPort(), &text, "http");
    defer url.deinit(testing.allocator);

    const now = @as(u64, @intCast(time.now(.awake).nanoseconds));
    const deadline = try time.OptionalTimestamp.init(
        time.Timestamp.fromNanoseconds(now + 50 * std.time.ns_per_ms),
    );

    var connector: Connector = .init(.{});
    var connection = try connector.handle().connect(.{
        .io = testing.io,
        .gpa = testing.allocator,
        .url = url,
        .deadline = deadline,
    });
    defer connection.deinit();

    var client: dispatch.Client = undefined;
    try client.attached(connection.reader, connection.writer, .{
        .protocol = connection.protocol,
        .common = .{
            .allocator = testing.allocator,
            .read_cause = connection.cause(),
        },
    });
    defer client.deinit();

    var response = try client.request(.{
        .method = .GET,
        .scheme = .http,
        .authority = url.authority,
        .target = url.target,
    });
    // The hook reads the body even when the test abandons it, so the drain in
    // `close` does not run into the same deadline.
    defer response.body.close();

    var got: [20]u8 = undefined;
    var writer: Io.Writer = .fixed(&got);
    try testing.expectError(error.ReadFailed, response.body.reader.streamRemaining(&writer));
    try testing.expectEqual(common.Outcome{ .local = .timed_out }, response.body.outcome().?);
}

test "the client dials and sends through its connector" {
    var fixture: Fixture = undefined;
    try fixture.init(
        "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello",
        0,
    );
    defer fixture.deinit();

    var text: [64]u8 = undefined;
    const url = try parseFor(fixture.address.getPort(), &text, "http");
    defer url.deinit(testing.allocator);

    var client: dispatch.Client = undefined;
    try client.init(testing.allocator, testing.io, .{});
    defer client.deinit();
    try testing.expectEqual(@as(?Protocol, null), client.protocol());

    var response = try client.send(url, .{ .method = .GET });
    defer response.body.close();
    try testing.expectEqual(@as(?Protocol, .h1), client.protocol());

    var got: [8]u8 = undefined;
    var writer: Io.Writer = .fixed(&got);
    const used = try response.body.reader.streamRemaining(&writer);
    try testing.expectEqualStrings("hello", got[0..used]);
}

const TransferStop = struct {
    io: Io,
    start: i96 = 0,
    after_ns: i96,
    calls: usize = 0,

    fn step(context: *anyopaque, phase: transport.Phase) bool {
        const self: *TransferStop = @ptrCast(@alignCast(context));
        self.calls += 1;
        if (phase != .transfer) return true;
        const now = Io.Clock.awake.now(self.io).nanoseconds;
        return now - self.start < self.after_ns;
    }
};

test "a transfer hook ends a body read the peer stalled" {
    var fixture: Fixture = undefined;
    try fixture.init(
        "HTTP/1.1 200 OK\r\nContent-Length: 20\r\nConnection: close\r\n\r\nshort",
        400,
    );
    defer fixture.deinit();

    var text: [64]u8 = undefined;
    const url = try parseFor(fixture.address.getPort(), &text, "http");
    defer url.deinit(testing.allocator);

    var state: TransferStop = .{ .io = testing.io, .after_ns = 150 * std.time.ns_per_ms };
    state.start = Io.Clock.awake.now(testing.io).nanoseconds;

    var client: dispatch.Client = undefined;
    try client.init(testing.allocator, testing.io, .{});
    defer client.deinit();

    var response = try client.send(url, .{
        .method = .GET,
        .progress = .{ .context = &state, .step = TransferStop.step },
    });
    defer response.body.abort();

    var got: [20]u8 = undefined;
    var writer: Io.Writer = .fixed(&got);
    const started = Io.Clock.awake.now(testing.io).nanoseconds;
    try testing.expectError(error.ReadFailed, response.body.reader.streamRemaining(&writer));
    const elapsed = Io.Clock.awake.now(testing.io).nanoseconds - started;

    try testing.expect(elapsed < std.time.ns_per_s);
    try testing.expectEqual(common.Outcome{ .local = .canceled }, response.body.outcome().?);
    try testing.expect(state.calls >= 2);
}

test "client.get takes a URL and returns the body" {
    var fixture: Fixture = undefined;
    try fixture.init(
        "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello",
        0,
    );
    defer fixture.deinit();

    var text: [64]u8 = undefined;
    const url_text = try mem.print(
        &text,
        "http://127.0.0.1:{d}/",
        .{fixture.address.getPort()},
    );

    var client: dispatch.Client = undefined;
    try client.init(testing.allocator, testing.io, .{});
    defer client.deinit();

    var response = try client.get(url_text);
    defer response.body.close();

    var got: [8]u8 = undefined;
    var writer: Io.Writer = .fixed(&got);
    const used = try response.body.reader.streamRemaining(&writer);
    try testing.expectEqualStrings("hello", got[0..used]);
}

/// A loopback peer that answers `connection_budget` connections. On each one it
/// answers requests until the client closes or the response says `close`.
const KeepAlive = struct {
    io: Io,
    listener: Io.net.Server,
    address: IpAddress,
    response: []const u8,
    /// Answers served in order when non-empty, one per request.
    responses: []const []const u8 = &.{},
    served: usize = 0,
    /// Everything the peer received, for asserting the wire form.
    captured: [4096]u8 = undefined,
    captured_len: usize = 0,
    connection_budget: usize,
    accepted: usize = 0,
    requests: usize = 0,
    result: ?anyerror = null,
    thread: std.Thread,

    fn init(
        self: *KeepAlive,
        response: []const u8,
        connection_budget: usize,
    ) !void {
        self.* = .{
            .io = testing.io,
            .listener = undefined,
            .address = try .parseLiteral("127.0.0.1:0"),
            .response = response,
            .connection_budget = connection_budget,
            .thread = undefined,
        };
        self.listener = try self.address.listen(self.io, .{
            .mode = .stream,
            .reuse_address = true,
        });
        self.address.setPort(self.listener.socket.address.getPort());
        self.thread = try .spawn(.{}, run, .{self});
    }

    fn deinit(self: *KeepAlive) void {
        self.thread.join();
        self.listener.deinit(self.io);
        if (self.result) |err| @panic(@errorName(err));
        self.* = undefined;
    }

    fn run(self: *KeepAlive) void {
        self.serve() catch |err| {
            self.result = err;
        };
    }

    fn serve(self: *KeepAlive) !void {
        while (self.accepted < self.connection_budget) {
            const stream = try self.listener.accept(self.io);
            self.accepted += 1;
            defer stream.close(self.io);

            var reader = stream.reader(self.io, &.{});
            var buffer: [256]u8 = undefined;
            var writer = stream.writer(self.io, &buffer);
            while (true) {
                var request: [1024]u8 = undefined;
                var used: usize = 0;
                while (used < request.len) {
                    var iovecs: [1][]u8 = .{request[used..]};
                    const n = reader.interface.readVec(&iovecs) catch return;
                    if (n == 0) return;
                    used += n;
                    if (mem.find(u8, request[0..used], "\r\n\r\n") != null) break;
                }
                const room = self.captured.len - self.captured_len;
                const capture = self.captured[self.captured_len..][0..@min(used, room)];
                @memcpy(capture, request[0..capture.len]);
                self.captured_len += capture.len;

                self.requests += 1;
                const response = if (self.responses.len != 0)
                    self.responses[@min(self.served, self.responses.len - 1)]
                else
                    self.response;
                self.served += 1;
                try writer.interface.writeAll(response);
                try writer.interface.flush();
                if (mem.find(u8, response, "Connection: close") != null) break;
                if (self.responses.len != 0 and self.served == self.responses.len) break;
            }
        }
    }
};

test "a second request reuses the kept-alive connection" {
    var fixture: KeepAlive = undefined;
    try fixture.init(
        "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok",
        1,
    );
    defer fixture.deinit();

    var text: [64]u8 = undefined;
    const url_text = try mem.print(
        &text,
        "http://127.0.0.1:{d}/",
        .{fixture.address.getPort()},
    );

    var client: dispatch.Client = undefined;
    try client.init(testing.allocator, testing.io, .{});
    defer client.deinit();

    for (0..2) |_| {
        var response = try client.get(url_text);
        var got: [2]u8 = undefined;
        var writer: Io.Writer = .fixed(&got);
        const used = try response.body.reader.streamRemaining(&writer);
        try testing.expectEqualStrings("ok", got[0..used]);
        response.body.close();
    }

    try testing.expectEqual(@as(usize, 1), fixture.accepted);
    try testing.expectEqual(@as(usize, 2), fixture.requests);
}

test "a Connection: close response is not reused" {
    var fixture: KeepAlive = undefined;
    try fixture.init(
        "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok",
        2,
    );
    defer fixture.deinit();

    var text: [64]u8 = undefined;
    const url_text = try mem.print(
        &text,
        "http://127.0.0.1:{d}/",
        .{fixture.address.getPort()},
    );

    var client: dispatch.Client = undefined;
    try client.init(testing.allocator, testing.io, .{});
    defer client.deinit();

    for (0..2) |_| {
        var response = try client.get(url_text);
        var got: [2]u8 = undefined;
        var writer: Io.Writer = .fixed(&got);
        const used = try response.body.reader.streamRemaining(&writer);
        try testing.expectEqualStrings("ok", got[0..used]);
        response.body.close();
    }

    try testing.expectEqual(@as(usize, 2), fixture.accepted);
}

test "Client.create returns a heap client and readBody collects the body" {
    var fixture: Fixture = undefined;
    try fixture.init(
        "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello",
        0,
    );
    defer fixture.deinit();

    var text: [64]u8 = undefined;
    const url_text = try mem.print(
        &text,
        "http://127.0.0.1:{d}/",
        .{fixture.address.getPort()},
    );

    const client = try dispatch.Client.create(testing.allocator, testing.io, .{});
    defer client.destroy();

    var response = try client.get(url_text);
    defer response.body.close();
    const bytes = try response.readBody(testing.allocator, .limited(1024));
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("hello", bytes);
}

test "a 302 is followed to a relative Location with GET" {
    var fixture: KeepAlive = undefined;
    try fixture.init("", 1);
    fixture.responses = &.{
        "HTTP/1.1 302 Found\r\nLocation: /next\r\nContent-Length: 0\r\n\r\n",
        "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok",
    };
    defer fixture.deinit();

    var text: [64]u8 = undefined;
    const url_text = try mem.print(
        &text,
        "http://127.0.0.1:{d}/start",
        .{fixture.address.getPort()},
    );

    const client = try dispatch.Client.create(testing.allocator, testing.io, .{});
    defer client.destroy();

    var response = try client.get(url_text);
    defer response.body.close();
    try testing.expectEqual(@as(u16, 200), response.head.status.code());

    const body = try response.readBody(testing.allocator, .limited(16));
    defer testing.allocator.free(body);
    try testing.expectEqualStrings("ok", body);

    // One connection carried both requests, and the second was a GET /next.
    try testing.expectEqual(@as(usize, 1), fixture.accepted);
    try testing.expectEqual(@as(usize, 2), fixture.requests);
    const wire = fixture.captured[0..fixture.captured_len];
    try testing.expect(mem.find(u8, wire, "GET /next") != null);
}

test "a 307 keeps the method and replays the body" {
    var fixture: KeepAlive = undefined;
    try fixture.init("", 1);
    fixture.responses = &.{
        "HTTP/1.1 307 Temporary Redirect\r\nLocation: /next\r\nContent-Length: 0\r\n\r\n",
        "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok",
    };
    defer fixture.deinit();

    var text: [64]u8 = undefined;
    const url_text = try mem.print(
        &text,
        "http://127.0.0.1:{d}/start",
        .{fixture.address.getPort()},
    );

    const client = try dispatch.Client.create(testing.allocator, testing.io, .{});
    defer client.destroy();

    const url = try Url.parse(testing.allocator, url_text);
    defer url.deinit(testing.allocator);
    var response = try client.send(url, .{
        .method = .POST,
        .body = "hello",
    });
    defer response.body.close();
    try testing.expectEqual(@as(u16, 200), response.head.status.code());

    const second = fixture.captured[0..fixture.captured_len];
    try testing.expectEqual(2, mem.count(u8, second, "POST /"));
    try testing.expect(mem.find(u8, second, "hello") != null);
}

test "a redirect chain longer than max_redirects is refused" {
    var fixture: KeepAlive = undefined;
    try fixture.init("", 1);
    const loop = "HTTP/1.1 302 Found\r\nLocation: /loop\r\nContent-Length: 0\r\n\r\n";
    fixture.responses = &.{ loop, loop, loop, loop };
    defer fixture.deinit();

    var text: [64]u8 = undefined;
    const url_text = try mem.print(
        &text,
        "http://127.0.0.1:{d}/loop",
        .{fixture.address.getPort()},
    );

    const client = try dispatch.Client.create(testing.allocator, testing.io, .{});
    defer client.destroy();

    const url = try Url.parse(testing.allocator, url_text);
    defer url.deinit(testing.allocator);
    try testing.expectError(error.TooManyRedirects, client.send(url, .{
        .method = .GET,
        .max_redirects = 2,
    }));
}

test "credentials are stripped when a redirect leaves the origin" {
    const headers = [_]Header{
        .{ .name = "Authorization", .value = "Bearer x" },
        .{ .name = "Cookie", .value = "a=b" },
        .{ .name = "Proxy-Authorization", .value = "Basic y" },
        .{ .name = "Accept", .value = "*/*" },
    };
    const kept = try dispatch.Client.stripForTest(testing.allocator, &headers);
    defer testing.allocator.free(kept);
    try testing.expectEqual(@as(usize, 1), kept.len);
    try testing.expectEqualStrings("Accept", kept[0].name);
}
