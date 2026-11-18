const std = @import("std");
const Io = std.Io;

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
