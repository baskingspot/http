//! Pull-based response bodies for the server engines.
//!
//! A handler returns a `ReadStream`; the engine calls `next` only when it can
//! send another chunk. The returned slice stays valid until the next `next` or
//! `close`, so the engine can hold it across a partial write.

const std = @import("std");
const Io = std.Io;

/// A single successful read. The slice is never empty.
pub const ReadResult = struct {
    data: []const u8,
};

pub const ReadError = error{
    /// The body reached a clean end.
    EndOfStream,
    /// No bytes are ready yet. The stream is still open.
    Pending,
    /// The read was canceled by the caller or the transport.
    Canceled,
    /// The underlying source failed to read.
    ReadFailed,
    /// Allocation failed inside the source.
    OutOfMemory,
};

pub const ReadStream = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        next: *const fn (ptr: *anyopaque) ReadError!ReadResult,
        close: *const fn (ptr: *anyopaque) void,
    };

    pub fn next(self: ReadStream) ReadError!ReadResult {
        return self.vtable.next(self.ptr);
    }

    pub fn close(self: ReadStream) void {
        self.vtable.close(self.ptr);
    }
};

pub const ResponseStream = struct {
    stream: ReadStream,
    /// `null` means an unknown length. HTTP/1.1 uses chunked framing and may
    /// keep the connection alive; HTTP/1.0 closes the connection after the
    /// body. HTTP/2 sends DATA without a declared length.
    content_length: ?u64 = null,
};

/// A response source over an `Io.Queue`. Closing either side of the queue wakes
/// the other side with `error.Closed`, which gives the stream pipe-style
/// cancellation without a coroutine runtime.
pub const QueueStream = struct {
    io: Io,
    queue: *Io.Queue([]const u8),
    stream: ReadStream,

    pub fn init(io: Io, queue: *Io.Queue([]const u8)) QueueStream {
        return .{
            .io = io,
            .queue = queue,
            .stream = .{ .ptr = undefined, .vtable = &vtable },
        };
    }

    pub fn source(self: *QueueStream) ReadStream {
        self.stream.ptr = self;
        return self.stream;
    }

    fn next(ptr: *anyopaque) ReadError!ReadResult {
        const self: *QueueStream = @ptrCast(@alignCast(ptr));
        const item = self.queue.getOne(self.io) catch |err| switch (err) {
            error.Closed => return error.EndOfStream,
            error.Canceled => return error.Canceled,
        };
        return .{ .data = item };
    }

    fn close(ptr: *anyopaque) void {
        const self: *QueueStream = @ptrCast(@alignCast(ptr));
        self.queue.close(self.io);
    }

    const vtable: ReadStream.VTable = .{ .next = next, .close = close };
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

    fn next(ptr: *anyopaque) ReadError!ReadResult {
        const self: *ReaderStream = @ptrCast(@alignCast(ptr));
        var iovecs: [1][]u8 = .{self.buffer};
        const n = self.reader.readVec(&iovecs) catch |err| switch (err) {
            error.EndOfStream => return error.EndOfStream,
            error.ReadFailed => return error.ReadFailed,
        };
        if (n != 0) return .{ .data = self.buffer[0..n] };

        // A buffered reader can return 0 after filling its own buffer.
        const buffered = self.reader.buffered();
        if (buffered.len == 0) return error.EndOfStream;
        const take = @min(buffered.len, self.buffer.len);
        @memcpy(self.buffer[0..take], buffered[0..take]);
        self.reader.toss(take);
        return .{ .data = self.buffer[0..take] };
    }

    fn close(_: *anyopaque) void {}

    const vtable: ReadStream.VTable = .{ .next = next, .close = close };
};
