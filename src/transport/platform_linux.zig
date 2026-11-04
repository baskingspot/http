//! Linux transport edge for the readiness engines.

const std = @import("std");
const Io = std.Io;
const linux = std.os.linux;
const posix = std.posix;
const mem = std.mem;

pub const fd_t = linux.fd_t;

pub const Listener = struct {
    fd: fd_t,
    address: Io.net.IpAddress,

    pub fn deinit(self: *Listener) void {
        _ = linux.close(self.fd);
        self.* = undefined;
    }
};

pub const Stop = struct {
    read_fd: fd_t,
    write_fd: fd_t,

    pub fn init() !Stop {
        const rc = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
        if (linux.errno(rc) != .SUCCESS) return error.EventfdFailed;
        const fd: fd_t = @intCast(rc);
        return .{ .read_fd = fd, .write_fd = fd };
    }

    pub fn deinit(self: Stop) void {
        _ = linux.close(self.read_fd);
    }

    pub fn wake(self: Stop) void {
        var one: u64 = 1;
        _ = linux.write(self.write_fd, mem.asBytes(&one), @sizeOf(u64));
    }
};

pub const AcceptError = error{
    ConnectionAborted,
    ListenerFailed,
    SystemResources,
};

pub fn accept(listener_fd: fd_t) AcceptError!?fd_t {
    while (true) {
        const rc = linux.accept4(
            listener_fd,
            null,
            null,
            linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC,
        );
        switch (linux.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .AGAIN => return null,
            .INTR => continue,
            .CONNABORTED, .PROTO, .PERM => return error.ConnectionAborted,
            .BADF, .FAULT, .INVAL, .NOTSOCK => return error.ListenerFailed,
            else => return error.SystemResources,
        }
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
    const msg: linux.msghdr_const = .{
        .name = null,
        .namelen = 0,
        .iov = &iov,
        .iovlen = iov_len,
        .control = null,
        .controllen = 0,
        .flags = 0,
    };
    while (true) {
        const rc = linux.sendmsg(fd, &msg, linux.MSG.DONTWAIT | linux.MSG.NOSIGNAL);
        switch (linux.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            .PIPE, .CONNRESET => return error.BrokenPipe,
            else => return error.BrokenPipe,
        }
    }
}

pub fn close(fd: fd_t) void {
    _ = linux.close(fd);
}

pub fn openListener(address: Io.net.IpAddress, tcp_defer_accept: bool) !Listener {
    const family: u32 = switch (address) {
        .ip4 => linux.AF.INET,
        .ip6 => linux.AF.INET6,
    };
    const fd_rc = linux.socket(
        family,
        linux.SOCK.STREAM | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK,
        0,
    );
    if (linux.errno(fd_rc) != .SUCCESS) return error.SocketFailed;
    const fd: fd_t = @intCast(fd_rc);
    errdefer _ = linux.close(fd);

    const one: u32 = 1;
    const opt_rc = linux.setsockopt(
        fd,
        linux.SOL.SOCKET,
        linux.SO.REUSEADDR,
        mem.asBytes(&one),
        @sizeOf(u32),
    );
    if (linux.errno(opt_rc) != .SUCCESS) return error.SocketOptionFailed;

    if (tcp_defer_accept) {
        const seconds: u32 = 1;
        const defer_rc = linux.setsockopt(
            fd,
            linux.IPPROTO.TCP,
            linux.TCP.DEFER_ACCEPT,
            mem.asBytes(&seconds),
            @sizeOf(u32),
        );
        if (linux.errno(defer_rc) != .SUCCESS) return error.SocketOptionFailed;
    }

    switch (address) {
        .ip4 => |a| {
            var sa: linux.sockaddr.in = .{
                .port = mem.nativeToBig(u16, a.port),
                .addr = @bitCast(a.bytes),
            };
            const bind_rc = linux.bind(fd, @ptrCast(&sa), @sizeOf(linux.sockaddr.in));
            if (linux.errno(bind_rc) != .SUCCESS) return error.BindFailed;
        },
        .ip6 => |a| {
            var sa: linux.sockaddr.in6 = .{
                .port = mem.nativeToBig(u16, a.port),
                .flowinfo = a.flow,
                .addr = a.bytes,
                .scope_id = a.interface.index,
            };
            const bind_rc = linux.bind(fd, @ptrCast(&sa), @sizeOf(linux.sockaddr.in6));
            if (linux.errno(bind_rc) != .SUCCESS) return error.BindFailed;
        },
    }

    const listen_rc = linux.listen(fd, 128);
    if (linux.errno(listen_rc) != .SUCCESS) return error.ListenFailed;

    var storage: linux.sockaddr.storage = undefined;
    var len: linux.socklen_t = @sizeOf(linux.sockaddr.storage);
    const name_rc = linux.getsockname(fd, @ptrCast(&storage), &len);
    if (linux.errno(name_rc) != .SUCCESS) return error.GetsocknameFailed;
    const bound: Io.net.IpAddress = switch (address) {
        .ip4 => blk: {
            const sa: *const linux.sockaddr.in = @ptrCast(&storage);
            break :blk .{ .ip4 = .{
                .bytes = @bitCast(sa.addr),
                .port = mem.bigToNative(u16, sa.port),
            } };
        },
        .ip6 => blk: {
            const sa: *const linux.sockaddr.in6 = @ptrCast(&storage);
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
