//! The h2c byte transport: nonblocking socket reads and writes, no protocol
//! layer between the fd and the h2 session.

const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const fd_t = std.posix.fd_t;

const wait = @import("../../../transport/wait.zig");
const common = @import("../transport.zig");
const Event = common.Event;

pub const Transport = struct {
    pub const Options = struct {};

    pub fn defaultOptions() ?Options {
        return .{};
    }

    pub fn init(
        allocator: Allocator,
        _: Io,
        fd: fd_t,
        options: Options,
        read_bytes: usize,
        write_bytes: usize,
    ) anyerror!Slot {
        return Slot.init(allocator, fd, options, read_bytes, write_bytes);
    }

    // ast-grep-ignore: public-struct-field-default -- internal slot; Transport.init sets all fields
    pub const Slot = struct {
        fd: fd_t,
        allocator: Allocator,
        read_buffer: []u8,
        write_buffer: []u8,
        read_start: usize = 0,
        read_end: usize = 0,
        write_start: usize = 0,
        write_end: usize = 0,
        input_ended: bool = false,

        pub fn init(
            allocator: Allocator,
            fd: fd_t,
            _: Options,
            read_bytes: usize,
            write_bytes: usize,
        ) !Slot {
            const read_buffer = try allocator.alloc(u8, read_bytes);
            errdefer allocator.free(read_buffer);
            const write_buffer = try allocator.alloc(u8, write_bytes);
            return .{
                .fd = fd,
                .allocator = allocator,
                .read_buffer = read_buffer,
                .write_buffer = write_buffer,
            };
        }

        pub fn deinit(self: *Slot) void {
            self.allocator.free(self.read_buffer);
            self.allocator.free(self.write_buffer);
            self.* = undefined;
        }

        pub fn receive(self: *Slot, comptime P: type) anyerror!void {
            if (self.input_ended or self.read_start < self.read_end) return;
            self.read_start = 0;
            self.read_end = 0;
            const n = P.read(self.fd, self.read_buffer) catch |err| switch (err) {
                error.WouldBlock => return,
                else => return err,
            };
            if (n == 0) {
                self.input_ended = true;
                return;
            }
            self.read_end = n;
        }

        pub fn next(self: *Slot) anyerror!Event {
            if (self.read_start < self.read_end) {
                return .{ .application_data = self.read_buffer[self.read_start..self.read_end] };
            }
            if (self.input_ended) return .closed;
            return .need_input;
        }

        pub fn consume(self: *Slot, n: usize) void {
            assert(n <= self.read_end - self.read_start);
            self.read_start += n;
            if (self.read_start == self.read_end) {
                self.read_start = 0;
                self.read_end = 0;
            }
        }

        pub fn write(self: *Slot, bytes: []const u8) anyerror!usize {
            const free = self.write_buffer[self.write_end..];
            if (free.len == 0) return 0;
            const n = @min(bytes.len, free.len);
            @memcpy(free[0..n], bytes[0..n]);
            self.write_end += n;
            return n;
        }

        pub fn send(self: *Slot, comptime P: type) anyerror!void {
            while (self.write_start < self.write_end) {
                const n = P.send(
                    self.fd,
                    &.{},
                    self.write_buffer[self.write_start..self.write_end],
                ) catch |err| switch (err) {
                    error.WouldBlock => return,
                    else => return err,
                };
                if (n == 0) return error.Closed;
                self.write_start += n;
            }
            self.write_start = 0;
            self.write_end = 0;
        }

        pub fn interest(self: *const Slot) wait.Interest {
            var result: wait.Interest = .empty;
            if (!self.input_ended and self.read_start == self.read_end) result.insert(.read);
            if (self.write_start < self.write_end) result.insert(.write);
            return result;
        }

        pub fn closeWrite(self: *Slot) anyerror!void {
            _ = self;
        }

        pub fn canWrite(_: *const Slot) bool {
            return true;
        }

        pub fn selectedAlpn(_: *const Slot) ?[]const u8 {
            return null;
        }
    };
};
