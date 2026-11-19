const std = @import("std");
const Io = std.Io;

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
