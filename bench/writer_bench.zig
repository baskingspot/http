//! h1.Writer benchmarks: a fixed-buffer response and a chunked response.

const std = @import("std");
const Io = std.Io;
const testingx = @import("testingx");
const http = @import("http");

const body = "hello world";

pub fn benchmarkWriterResponse(b: *testingx.B) !void {
    var buffer: [1024]u8 = undefined;
    var sink: usize = 0;
    while (try b.loop()) {
        var io: Io.Writer = .fixed(&buffer);
        var w: http.h1.Writer = .init(&io);
        try w.statusLine(.@"HTTP/1.1", .ok);
        try w.field("Content-Type", "text/plain");
        try w.contentLength(body.len);
        try w.endFields();
        try w.body(body);
        sink +%= io.buffered().len;
    }
    b.keepAlive(sink);
}

pub fn benchmarkWriterChunked(b: *testingx.B) !void {
    var buffer: [1024]u8 = undefined;
    var sink: usize = 0;
    while (try b.loop()) {
        var io: Io.Writer = .fixed(&buffer);
        var w: http.h1.Writer = .init(&io);
        try w.statusLine(.@"HTTP/1.1", .ok);
        try w.chunked();
        try w.endFields();
        try w.chunk(body);
        try w.lastChunk(&.{});
        sink +%= io.buffered().len;
    }
    b.keepAlive(sink);
}
