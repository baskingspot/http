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
//! Zig 0.16 has no socket read or write operation in `Io.Operation`, so a
//! deadline cannot be bounded there; `connect` reports
//! `error.DeadlineUnsupported` instead of accepting one it would ignore.
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

const compat = @import("../compat.zig");
const common = @import("common.zig");
const transport = @import("transport.zig");
const Protocol = transport.Protocol;
const Url = @import("../uri.zig").Url;

/// Addresses one dial tries before giving up.
pub const max_addresses = 8;

/// Longest a wait runs before the progress hook gets a turn. Only used when a
/// hook is set; without one the wait runs to the deadline.
const progress_slice_ms = 250;

/// Zig 0.17 carries socket reads and writes in `Io.Operation`. Zig 0.16 has
/// only `net_receive`, so a bounded stream wait does not exist there.
pub const deadline_supported = @hasField(Io.Operation, "net_read");

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
    writer: Io.Writer,
    protocol: Protocol,
    deadline: time.OptionalTimestamp,
    read_cause: ?anyerror,
    write_cause: ?anyerror,

    fn open(context: transport.Context, config: Config) Error!*Connection {
        if (context.url.scheme == .https) return error.TlsUnsupported;
        if (context.deadline.get() != null or context.connect_deadline.get() != null)
            if (!deadline_supported) return error.DeadlineUnsupported;

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
            .writer = .{
                .vtable = &writer_vtable,
                .buffer = &.{},
                .end = 0,
            },
            .protocol = config.protocol,
            .deadline = context.deadline,
            .read_cause = null,
            .write_cause = null,
        };
        return self;
    }

    fn handle(self: *Connection) transport.Connection {
        return .{
            .reader = &self.reader,
            .writer = &self.writer,
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
    .setDeadline = connectionSetDeadline,
    .readCause = connectionReadCause,
    .writeCause = connectionWriteCause,
};

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
    if (deadline.get() != null and !deadline_supported) return error.DeadlineUnsupported;
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
    if (comptime deadline_supported) {
        var storage: [1]Io.Operation.Storage = undefined;
        var batch: Io.Batch = .init(&storage);
        const index = batch.add(.{ .net_read = .{
            .socket_handle = self.stream.socket.handle,
            .data = buffers,
        } });
        waitForRead(self, &batch) catch |err| {
            self.read_cause = err;
            return err;
        };
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

    // 0.16 keeps socket reads on the `Io` vtable and has no batch operation
    // for them, so this call waits with no bound. `open` refuses a deadline on
    // that lane rather than accept one it cannot honor.
    if (comptime @hasField(Io.VTable, "netRead")) {
        const count = self.io.vtable.netRead(
            self.io.userdata,
            self.stream.socket.handle,
            buffers,
        ) catch |err| switch (err) {
            error.Canceled => {
                self.read_cause = error.Stopped;
                return error.Stopped;
            },
            else => {
                self.read_cause = err;
                return error.SystemResources;
            },
        };
        return count;
    }
    unreachable;
}

/// Wait for the read batch, bounded by the connection's deadline. A timeout
/// or a cancel has to be reaped before the batch's stack storage dies.
fn waitForRead(self: *Connection, batch: *Io.Batch) Error!void {
    const timeout: Io.Timeout = if (self.deadline.get()) |value|
        .{ .deadline = Io.Timestamp.fromNanoseconds(value.nanoseconds).withClock(.awake) }
    else
        .none;
    batch.awaitConcurrent(self.io, timeout) catch |err| {
        batch.cancel(self.io);
        return switch (err) {
            error.Timeout => error.TimedOut,
            error.Canceled => error.Stopped,
            error.ConcurrencyUnavailable => error.ConcurrencyUnavailable,
        };
    };
}

fn writerDrain(
    w: *Io.Writer,
    data: []const []const u8,
    splat: usize,
) Io.Writer.Error!usize {
    const self: *Connection = @alignCast(@fieldParentPtr("writer", w));
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
        @intCast(compat.enumToInt(posix.E.CONNREFUSED)) => error.ConnectionRefused,
        @intCast(compat.enumToInt(posix.E.NETUNREACH)) => error.NetworkUnreachable,
        @intCast(compat.enumToInt(posix.E.HOSTUNREACH)) => error.HostUnreachable,
        @intCast(compat.enumToInt(posix.E.TIMEDOUT)) => error.TimedOut,
        @intCast(compat.enumToInt(posix.E.CONNRESET)) => error.ConnectionResetByPeer,
        @intCast(compat.enumToInt(posix.E.AFNOSUPPORT)) => error.AddressFamilyUnsupported,
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
    const text = try std.fmt.bufPrint(buffer, "{s}://127.0.0.1:{d}/", .{ scheme, port });
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
    if (comptime !deadline_supported) return error.SkipZigTest;

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
        .method_token = "GET",
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
    if (comptime !deadline_supported) return error.SkipZigTest;

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
        .method_token = "GET",
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

test "a deadline the lane cannot honor is refused" {
    if (comptime deadline_supported) return error.SkipZigTest;

    var text: [64]u8 = undefined;
    const url = try parseFor(1, &text, "http");
    defer url.deinit(testing.allocator);

    const soon = try time.OptionalTimestamp.init(
        time.Timestamp.fromNanoseconds(
            @as(u64, @intCast(time.now(.awake).nanoseconds)) + std.time.ns_per_s,
        ),
    );
    var connector: Connector = .init(.{});
    try testing.expectError(error.DeadlineUnsupported, connector.handle().connect(.{
        .io = testing.io,
        .gpa = testing.allocator,
        .url = url,
        .deadline = soon,
    }));
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

    var response = try client.send(url, .{ .method_token = "GET" });
    defer response.body.close();
    try testing.expectEqual(@as(?Protocol, .h1), client.protocol());

    var got: [8]u8 = undefined;
    var writer: Io.Writer = .fixed(&got);
    const used = try response.body.reader.streamRemaining(&writer);
    try testing.expectEqualStrings("hello", got[0..used]);
}
