const std = @import("std");
const Io = std.Io;
const posix = std.posix;

/// Returns zero forever without producing buffered bytes.
pub const StalledReader = struct {
    reader: Io.Reader,
    reads: usize = 0,

    pub fn init(self: *StalledReader) void {
        self.reader = .{
            .vtable = &.{ .stream = stream, .readVec = readVec },
            .buffer = &.{},
            .seek = 0,
            .end = 0,
        };
        self.reads = 0;
    }

    fn stream(_: *Io.Reader, _: *Io.Writer, _: Io.Limit) Io.Reader.StreamError!usize {
        return 0;
    }

    fn readVec(reader: *Io.Reader, _: [][]u8) Io.Reader.Error!usize {
        const self: *StalledReader = @fieldParentPtr("reader", reader);
        self.reads += 1;
        return 0;
    }
};

/// Fills its own buffer with the whole record and returns zero, the way a TLS
/// reader reports a pending record. The buffer is larger than any engine read
/// buffer the tests use, so the engine copies the record out in pieces and the
/// rest waits in `reader.buffer`.
///
/// After the record, a call with bytes still in that buffer means the engine
/// reached the transport while its own input was in hand. A real socket blocks
/// there, so this reader polls `idle_fd`, which never becomes readable, and
/// counts the wait.
pub const PendingRecordReader = struct {
    reader: Io.Reader,
    io: Io,
    bytes: []const u8,
    /// The engine's read buffer size. `Io.Reader.readVec` shrinks the slice it
    /// hands the transport by the bytes it copied out of the reader's buffer,
    /// so a short slice is the only trace a transport read leaves when the
    /// caller had input in hand.
    read_buffer_len: usize,
    /// A socket that stays idle for the whole test.
    idle_fd: ?posix.fd_t = null,
    /// How long the transport blocks before the test gives up on it.
    probe_ms: i32 = 1_500,
    buffer: [32 * 1024]u8 = undefined,
    sent: bool = false,
    /// Transport reads taken while the engine still had buffered bytes.
    buffered_reads: usize = 0,
    /// Time spent in those reads.
    buffered_wait_ns: i96 = 0,

    pub fn init(
        self: *PendingRecordReader,
        io: Io,
        bytes: []const u8,
        read_buffer_len: usize,
        idle_fd: ?posix.fd_t,
    ) void {
        self.reader = .{
            .vtable = &.{ .stream = stream, .readVec = readVec },
            .buffer = &self.buffer,
            .seek = 0,
            .end = 0,
        };
        self.io = io;
        self.bytes = bytes;
        self.read_buffer_len = read_buffer_len;
        self.idle_fd = idle_fd;
        self.probe_ms = 1_500;
        self.sent = false;
        self.buffered_reads = 0;
        self.buffered_wait_ns = 0;
    }

    fn stream(_: *Io.Reader, _: *Io.Writer, _: Io.Limit) Io.Reader.StreamError!usize {
        return 0;
    }

    fn readVec(reader: *Io.Reader, data: [][]u8) Io.Reader.Error!usize {
        const self: *PendingRecordReader = @alignCast(@fieldParentPtr("reader", reader));
        if (!self.sent) {
            self.sent = true;
            std.debug.assert(self.bytes.len <= self.buffer.len);
            @memcpy(self.buffer[0..self.bytes.len], self.bytes);
            reader.end = self.bytes.len;
            return 0;
        }
        // The record is delivered. A short slice means the caller copied the
        // rest of the engine's read buffer out of this reader first and reached
        // the transport with those bytes still unserved. A real socket blocks
        // here, so poll the idle one and count the wait.
        if (data.len != 0 and data[0].len != self.read_buffer_len) {
            self.buffered_reads += 1;
            if (self.idle_fd) |fd| {
                const started: Io.Timestamp = .now(self.io, .awake);
                var fds = [_]posix.pollfd{.{
                    .fd = fd,
                    .events = posix.POLL.IN,
                    .revents = 0,
                }};
                _ = posix.poll(&fds, self.probe_ms) catch 0;
                self.buffered_wait_ns += started.durationTo(.now(self.io, .awake)).nanoseconds;
            }
            std.debug.print(
                "transport read with the record still buffered, blocked {d:.1} ms\n",
                .{@as(f64, @floatFromInt(self.buffered_wait_ns)) / std.time.ns_per_ms},
            );
        }
        return error.EndOfStream;
    }
};

/// Alternates an empty zero read with one byte. The delay makes the whole
/// request longer than a stall budget while every gap stays below it.
pub const TrickleReader = struct {
    reader: Io.Reader,
    io: Io,
    bytes: []const u8,
    delay: Io.Duration,
    byte_index: usize = 0,
    zero_reads: usize = 0,
    read_zero: bool = true,

    pub fn init(self: *TrickleReader, io: Io, bytes: []const u8, delay: Io.Duration) void {
        self.reader = .{
            .vtable = &.{ .stream = stream, .readVec = readVec },
            .buffer = &.{},
            .seek = 0,
            .end = 0,
        };
        self.io = io;
        self.bytes = bytes;
        self.delay = delay;
        self.byte_index = 0;
        self.zero_reads = 0;
        self.read_zero = true;
    }

    fn stream(_: *Io.Reader, _: *Io.Writer, _: Io.Limit) Io.Reader.StreamError!usize {
        return 0;
    }

    fn readVec(reader: *Io.Reader, data: [][]u8) Io.Reader.Error!usize {
        const self: *TrickleReader = @alignCast(@fieldParentPtr("reader", reader));
        if (self.byte_index == self.bytes.len) return error.EndOfStream;
        if (self.read_zero) {
            self.read_zero = false;
            self.zero_reads += 1;
            self.io.sleep(self.delay, .awake) catch return error.ReadFailed;
            return 0;
        }
        self.read_zero = true;
        data[0][0] = self.bytes[self.byte_index];
        self.byte_index += 1;
        return 1;
    }
};

/// Serves one complete request, idles, returns one empty zero read, then
/// serves a second request. The idle delay must not arm the stall clock.
pub const IdleReader = struct {
    const Phase = enum { first, zero, second, done };

    reader: Io.Reader,
    io: Io,
    first: []const u8,
    second: []const u8,
    idle: Io.Duration,
    phase: Phase = .first,

    pub fn init(
        self: *IdleReader,
        io: Io,
        first: []const u8,
        second: []const u8,
        idle: Io.Duration,
    ) void {
        self.reader = .{
            .vtable = &.{ .stream = stream, .readVec = readVec },
            .buffer = &.{},
            .seek = 0,
            .end = 0,
        };
        self.io = io;
        self.first = first;
        self.second = second;
        self.idle = idle;
        self.phase = .first;
    }

    fn stream(_: *Io.Reader, _: *Io.Writer, _: Io.Limit) Io.Reader.StreamError!usize {
        return 0;
    }

    fn readVec(reader: *Io.Reader, data: [][]u8) Io.Reader.Error!usize {
        const self: *IdleReader = @alignCast(@fieldParentPtr("reader", reader));
        switch (self.phase) {
            .first => {
                self.phase = .zero;
                return copy(data, self.first);
            },
            .zero => {
                self.phase = .second;
                self.io.sleep(self.idle, .awake) catch return error.ReadFailed;
                return 0;
            },
            .second => {
                self.phase = .done;
                return copy(data, self.second);
            },
            .done => return error.EndOfStream,
        }
    }

    fn copy(data: [][]u8, bytes: []const u8) usize {
        std.debug.assert(bytes.len <= data[0].len);
        @memcpy(data[0][0..bytes.len], bytes);
        return bytes.len;
    }
};

/// A reader whose first record reads directly into the caller's buffer and
/// whose later records go through `Io.Reader.defaultReadVec`'s internal buffer.
pub const SplitReader = struct {
    reader: Io.Reader,
    records: []const []const u8,
    record_index: usize = 0,
    zero_reads: usize = 0,
    buffer: [32 * 1024]u8 = undefined,

    pub fn init(self: *SplitReader, records: []const []const u8) void {
        self.reader = .{
            .vtable = &.{
                .stream = stream,
                .readVec = readVec,
            },
            .buffer = &.{},
            .seek = 0,
            .end = 0,
        };
        self.records = records;
        self.record_index = 0;
        self.zero_reads = 0;
    }

    fn stream(reader: *Io.Reader, writer: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        const self: *SplitReader = @fieldParentPtr("reader", reader);
        if (self.record_index == self.records.len) return error.EndOfStream;

        const record = self.records[self.record_index];
        std.debug.assert(record.len <= @backingInt(limit));
        try writer.writeAll(record);
        self.record_index += 1;
        if (self.record_index == 1) {
            std.debug.assert(reader.buffer.len == 0);
            reader.buffer = &self.buffer;
        }
        return record.len;
    }

    fn readVec(reader: *Io.Reader, data: [][]u8) Io.Reader.Error!usize {
        const self: *SplitReader = @fieldParentPtr("reader", reader);
        const n = try Io.Reader.defaultReadVec(reader, data);
        if (n == 0) self.zero_reads += 1;
        return n;
    }
};
