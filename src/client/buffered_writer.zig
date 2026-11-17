//! A fixed-buffer writer over a transport writer.
//!
//! The h1 and h2 adapters write a request head in small pieces. A transport
//! writer that hands every piece to the socket makes that several syscalls per
//! request; the TLS writer would turn it into one TLS record per field. Staging
//! the bytes here batches the head and each body chunk into one write, and a
//! flush pushes the rest.
//!
//! The buffer is inline so its owner can embed this by value; initializing it
//! fixes `interface.buffer`, so the owner must not move afterwards.

const std = @import("std");
const Io = std.Io;

pub const BufferedWriter = struct {
    data: [16 * 1024]u8 = undefined,
    inner: *Io.Writer = undefined,
    interface: Io.Writer = undefined,

    pub fn init(self: *BufferedWriter, inner: *Io.Writer) void {
        self.inner = inner;
        self.interface = .{
            .vtable = &vtable,
            .buffer = &self.data,
            .end = 0,
        };
    }

    pub fn writer(self: *BufferedWriter) *Io.Writer {
        return &self.interface;
    }

    const vtable: Io.Writer.VTable = .{ .drain = drain };

    /// Send the buffered bytes, then `data`, through to the transport. A
    /// transport failure becomes `error.WriteFailed`, the way every writer
    /// vtable reports one; the transport keeps the real cause on the
    /// connection.
    fn drain(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const self: *BufferedWriter = @fieldParentPtr("interface", w);
        const buffered = w.buffered();
        var total: usize = 0;
        if (buffered.len != 0) {
            _ = self.inner.vtable.drain(self.inner, &.{buffered}, 1) catch
                return error.WriteFailed;
            total += buffered.len;
        }
        for (data, 0..) |slice, index| {
            if (slice.len == 0) continue;
            const repeat = if (index + 1 == data.len) splat else 1;
            for (0..repeat) |_| {
                _ = self.inner.vtable.drain(self.inner, &.{slice}, 1) catch
                    return error.WriteFailed;
                total += slice.len;
            }
        }
        return w.consume(total);
    }
};
