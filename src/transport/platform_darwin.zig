//! Darwin transport edge for the kqueue readiness engine.

const std = @import("std");
const Io = std.Io;
const c = std.c;
const posix = std.posix;
const mem = std.mem;

pub const fd_t = c.fd_t;

pub const Listener = struct {
    fd: fd_t,
    address: Io.net.IpAddress,

    pub fn deinit(self: *Listener) void {
        _ = c.close(self.fd);
        self.* = undefined;
    }
};

pub const Stop = struct {
    read_fd: fd_t,
    write_fd: fd_t,

    pub fn init() !Stop {
        var fds: [2]fd_t = undefined;
        if (posix.errno(c.pipe(&fds)) != .SUCCESS) return error.PipeFailed;
        errdefer {
            _ = c.close(fds[0]);
            _ = c.close(fds[1]);
        }
        try nonblockCloseExec(fds[0], error.PipeFailed);
        try nonblockCloseExec(fds[1], error.PipeFailed);
        return .{ .read_fd = fds[0], .write_fd = fds[1] };
    }

    pub fn deinit(self: Stop) void {
        _ = c.close(self.read_fd);
        _ = c.close(self.write_fd);
    }

    pub fn wake(self: Stop) void {
        const byte: [1]u8 = .{1};
        _ = c.write(self.write_fd, &byte, 1);
    }
};

pub const AcceptError = error{
    ConnectionAborted,
    ListenerFailed,
    SystemResources,
};

pub fn accept(listener_fd: fd_t) AcceptError!?fd_t {
    while (true) {
        const rc = c.accept(listener_fd, null, null);
        switch (posix.errno(rc)) {
            .SUCCESS => {},
            .AGAIN => return null,
            .INTR => continue,
            .CONNABORTED, .PROTO, .PERM => return error.ConnectionAborted,
            .BADF, .FAULT, .INVAL, .NOTSOCK => return error.ListenerFailed,
            else => return error.SystemResources,
        }

        const fd: fd_t = @intCast(rc);
        nonblockCloseExec(fd, error.ListenerFailed) catch {
            _ = c.close(fd);
            return error.ListenerFailed;
        };

        const one: c_int = 1;
        _ = c.setsockopt(
            fd,
            c.SOL.SOCKET,
            c.SO.NOSIGPIPE,
            @ptrCast(&one),
            @sizeOf(c_int),
        );
        return fd;
    }
}

pub fn read(fd: fd_t, buf: []u8) !usize {
    return posix.read(fd, buf) catch |err| switch (err) {
        error.WouldBlock => error.WouldBlock,
        else => error.ReadFailed,
    };
}

pub const SendError = error{ WouldBlock, BrokenPipe };

pub fn send(fd: fd_t, head: []const u8, body: []const u8) SendError!usize {
    var iov: [2]posix.iovec_const = undefined;
    var iov_len: usize = 0;
    if (head.len != 0) {
        iov[iov_len] = .{ .base = head.ptr, .len = head.len };
        iov_len += 1;
    }
    if (body.len != 0) {
        iov[iov_len] = .{ .base = body.ptr, .len = body.len };
        iov_len += 1;
    }
    const msg: posix.msghdr_const = .{
        .name = null,
        .namelen = 0,
        .iov = &iov,
        .iovlen = @intCast(iov_len),
        .control = null,
        .controllen = 0,
        .flags = 0,
    };
    while (true) {
        const rc = c.sendmsg(fd, &msg, c.MSG.DONTWAIT);
        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            .PIPE, .CONNRESET => return error.BrokenPipe,
            else => return error.BrokenPipe,
        }
    }
}

pub fn close(fd: fd_t) void {
    _ = c.close(fd);
}

pub fn openListener(address: Io.net.IpAddress, tcp_defer_accept: bool) !Listener {
    _ = tcp_defer_accept;
    const family: c_int = switch (address) {
        .ip4 => c.AF.INET,
        .ip6 => c.AF.INET6,
    };
    const rc = c.socket(@intCast(family), c.SOCK.STREAM, 0);
    if (posix.errno(rc) != .SUCCESS) return error.SocketFailed;
    const fd: fd_t = @intCast(rc);
    errdefer _ = c.close(fd);
    try nonblockCloseExec(fd, error.SocketOptionFailed);

    const one: u32 = 1;
    if (posix.errno(c.setsockopt(
        fd,
        c.SOL.SOCKET,
        c.SO.REUSEADDR,
        mem.asBytes(&one),
        @sizeOf(u32),
    )) != .SUCCESS) return error.SocketOptionFailed;

    switch (address) {
        .ip4 => |a| {
            var sa: c.sockaddr.in = .{
                .len = @sizeOf(c.sockaddr.in),
                .family = c.AF.INET,
                .port = mem.nativeToBig(u16, a.port),
                .addr = @bitCast(a.bytes),
            };
            switch (posix.errno(c.bind(fd, @ptrCast(&sa), @sizeOf(c.sockaddr.in)))) {
                .SUCCESS => {},
                .ADDRINUSE => return error.AddressInUse,
                else => return error.BindFailed,
            }
        },
        .ip6 => |a| {
            var sa: c.sockaddr.in6 = .{
                .len = @sizeOf(c.sockaddr.in6),
                .family = c.AF.INET6,
                .port = mem.nativeToBig(u16, a.port),
                .flowinfo = a.flow,
                .addr = a.bytes,
                .scope_id = a.interface.index,
            };
            switch (posix.errno(c.bind(fd, @ptrCast(&sa), @sizeOf(c.sockaddr.in6)))) {
                .SUCCESS => {},
                .ADDRINUSE => return error.AddressInUse,
                else => return error.BindFailed,
            }
        },
    }

    if (posix.errno(c.listen(fd, 128)) != .SUCCESS) return error.ListenFailed;

    var storage: c.sockaddr.storage = undefined;
    var len: c.socklen_t = @sizeOf(c.sockaddr.storage);
    if (posix.errno(c.getsockname(fd, @ptrCast(&storage), &len)) != .SUCCESS) {
        return error.GetsocknameFailed;
    }
    const bound: Io.net.IpAddress = switch (address) {
        .ip4 => blk: {
            const sa: *const c.sockaddr.in = @ptrCast(&storage);
            break :blk .{ .ip4 = .{
                .bytes = @bitCast(sa.addr),
                .port = mem.bigToNative(u16, sa.port),
            } };
        },
        .ip6 => blk: {
            const sa: *const c.sockaddr.in6 = @ptrCast(&storage);
            break :blk .{ .ip6 = .{
                .bytes = sa.addr,
                .port = mem.bigToNative(u16, sa.port),
                .flow = sa.flowinfo,
                .interface = .{ .index = sa.scope_id },
            } };
        },
    };

    return .{ .fd = fd, .address = bound };
}

fn nonblockCloseExec(fd: fd_t, comptime failure: anyerror) !void {
    const flags = c.fcntl(fd, c.F.GETFL);
    if (posix.errno(flags) != .SUCCESS) return failure;
    const nonblock: c_int = @bitCast(@as(u32, @bitCast(posix.O{ .NONBLOCK = true })));
    const cloexec: c_int = @bitCast(@as(u32, @bitCast(posix.O{ .CLOEXEC = true })));
    if (posix.errno(c.fcntl(fd, c.F.SETFL, flags | nonblock | cloexec)) != .SUCCESS) {
        return failure;
    }
}
