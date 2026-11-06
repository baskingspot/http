//! Pull-based response bodies for the server engines.
//!
//! A handler returns a `ReadStream`; the engine calls `next` only when it can
//! send another chunk. The returned slice stays valid until the next `next` or
//! `close`, so the engine can hold it across a partial write.
//!
//! This first cut is the blocking shape. A step client adds a `Poll`/`Waker`
//! variant without changing the ownership rules.

const std = @import("std");
const Io = std.Io;

pub const Read = union(enum) {
    data: []const u8,
    eof,
    failed: anyerror,
};

pub const ReadStream = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        next: *const fn (ptr: *anyopaque) Read,
        close: *const fn (ptr: *anyopaque) void,
    };

    pub fn next(self: ReadStream) Read {
        return self.vtable.next(self.ptr);
    }

    pub fn close(self: ReadStream) void {
        self.vtable.close(self.ptr);
    }
};

pub const ResponseStream = struct {
    stream: ReadStream,
    /// `null` selects chunked on HTTP/1.1 and an unknown length on HTTP/2.
    content_length: ?u64 = null,
};

/// A response source over a caller-owned `std.Io.Reader` and buffer. The source
/// copies each chunk into `buffer`; the reader and buffer must outlive the
/// stream.
pub const ReaderStream = struct {
    reader: *Io.Reader,
    buffer: []u8,
    stream: ReadStream,

    pub fn init(reader: *Io.Reader, buffer: []u8) ReaderStream {
        return .{
            .reader = reader,
            .buffer = buffer,
            .stream = .{ .ptr = undefined, .vtable = &vtable },
        };
    }

    pub fn source(self: *ReaderStream) ReadStream {
        self.stream.ptr = self;
        return self.stream;
    }

    fn next(ptr: *anyopaque) Read {
        const self: *ReaderStream = @ptrCast(@alignCast(ptr));
        var iovecs: [1][]u8 = .{self.buffer};
        const n = self.reader.readVec(&iovecs) catch |err| return .{ .failed = err };
        if (n != 0) return .{ .data = self.buffer[0..n] };

        // A buffered reader can return 0 after filling its own buffer.
        const buffered = self.reader.buffered();
        if (buffered.len == 0) return .eof;
        const take = @min(buffered.len, self.buffer.len);
        @memcpy(self.buffer[0..take], buffered[0..take]);
        self.reader.toss(take);
        return .{ .data = self.buffer[0..take] };
    }

    fn close(_: *anyopaque) void {}

    const vtable: ReadStream.VTable = .{ .next = next, .close = close };
};
