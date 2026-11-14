//! A file served through a pull-based transform stream.
//!
//!     just example-stream README.md
//!     curl http://127.0.0.1:8091/
//!
//! The source reads a file in chunks, XORs each byte, and returns the chunk to
//! the engine. The response has no known length, so the engine uses chunked
//! HTTP/1.1. The transform is a stand-in for compression or a stream cipher.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const print = std.debug.print;

const http = @import("http");
const stream = http.stream;

const address_text = "127.0.0.1:8091";

const App = struct {
    io: Io,
    path: []const u8,

    fn handler(self: *App) http.h1.engine.Handler {
        return .{ .ptr = self, .vtable = &.{
            .handle = handle,
            .complete = http.h1.engine.Handler.noopComplete,
            .report_error = reportError,
            .policy_response = http.h1.engine.Handler.defaultPolicyResponse,
        } };
    }

    fn handle(ptr: *anyopaque, exchange: *http.h1.engine.Exchange) anyerror!void {
        const self: *App = @ptrCast(@alignCast(ptr));
        const source = try FileSource.init(exchange.arena, self.io, self.path);
        try exchange.respondStream(.{
            .status = .ok,
            .content_type = "application/octet-stream",
        }, .{
            .stream = .{ .ptr = source, .vtable = &FileSource.vtable },
            .content_length = null,
        });
    }

    fn reportError(_: *anyopaque, err: anyerror) void {
        print("pipeline: {s}\n", .{@errorName(err)});
    }
};

const FileSource = struct {
    io: Io,
    file: Io.File,
    reader: Io.File.Reader,
    reader_buffer: []u8,
    input: []u8,
    output: []u8,

    const vtable: stream.ReadStream.VTable = .{ .next = next, .close = close };

    fn init(allocator: Allocator, io: Io, path: []const u8) !*FileSource {
        const self = try allocator.create(FileSource);
        self.io = io;
        self.file = try Io.Dir.cwd().openFile(io, path, .{});
        errdefer self.file.close(io);
        self.reader_buffer = try allocator.alloc(u8, 16 * 1024);
        self.input = try allocator.alloc(u8, 16 * 1024);
        self.output = try allocator.alloc(u8, 16 * 1024);
        self.reader = self.file.reader(io, self.reader_buffer);
        return self;
    }

    fn next(ptr: *anyopaque) stream.ReadError!stream.ReadResult {
        const self: *FileSource = @ptrCast(@alignCast(ptr));
        const n = self.reader.interface.readSliceShort(self.input) catch
            return error.ReadFailed;
        if (n == 0) return error.EndOfStream;
        for (self.input[0..n], 0..) |byte, index| {
            self.output[index] = byte ^ 0x5a;
        }
        return .{ .data = self.output[0..n] };
    }

    fn close(ptr: *anyopaque) void {
        const self: *FileSource = @ptrCast(@alignCast(ptr));
        self.file.close(self.io);
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 2) {
        print("usage: stream-pipeline <file>\n", .{});
        return error.InvalidArguments;
    }

    const address: Io.net.IpAddress = try .parseLiteral(address_text);
    var listener = try address.listen(io, .{ .mode = .stream, .reuse_address = true });
    defer listener.deinit(io);
    var app: App = .{ .io = io, .path = args[1] };
    print("pipeline: {s} on {s}\n", .{ args[1], address_text });

    while (true) {
        const conn = listener.accept(io) catch |err| {
            print("pipeline: accept: {s}\n", .{@errorName(err)});
            continue;
        };
        var request_buffer: [16 * 1024]u8 = undefined;
        var headers: [64]http.Header = undefined;
        var response_head: [1024]u8 = undefined;
        http.h1.engine.direct.serve(io, conn, app.handler(), .{
            .allocator = gpa,
            .request_buffer = &request_buffer,
            .headers = &headers,
            .response_head_buffer = &response_head,
            .common = .{ .body_bytes = 8 * 1024 },
        }) catch |err| switch (err) {
            error.WriteFailed => {},
            else => print("pipeline: connection: {s}\n", .{@errorName(err)}),
        };
        conn.close(io);
    }
}
