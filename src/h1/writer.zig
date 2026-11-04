//! HTTP/1 writer methods over a caller-owned `std.Io.Writer`.
//!
//! The writer carries the sink. The caller owns it: a fixed buffer, a file, a
//! socket, or anything else that implements `std.Io.Writer`. These methods only
//! format; they never create, flush, or close the sink, and they never
//! allocate.
//!
//! The grammar matches the parser: CRLF only, `tchar` field names, field values
//! with no CTLs, and a request target of printable US-ASCII. Invalid input is
//! rejected before any bytes are written.

const std = @import("std");
const testing = std.testing;
const IoWriter = std.Io.Writer;

const Header = @import("../header.zig").Header;
const Method = @import("../method.zig").Method;
const Status = @import("../status.zig").Status;
const Version = @import("../version.zig").Version;
const h1 = @import("root.zig");

pub const Writer = struct {
    /// The caller's sink. The writer never flushes or closes it.
    io: *IoWriter,

    pub const Error = IoWriter.Error || error{
        InvalidMethod,
        InvalidTarget,
        InvalidFieldName,
        InvalidFieldValue,
        InvalidReason,
        EmptyChunk,
    };

    pub fn init(io: *IoWriter) Writer {
        return .{ .io = io };
    }

    /// Write a request line for one of the common methods.
    pub fn requestLine(
        self: Writer,
        method: Method,
        target: []const u8,
        version: Version,
    ) Error!void {
        return self.requestLineToken(method.token(), target, version);
    }

    /// Write a request line for an arbitrary method token.
    pub fn requestLineToken(
        self: Writer,
        method_token: []const u8,
        target: []const u8,
        version: Version,
    ) Error!void {
        try validateMethod(method_token);
        try validateTarget(target);

        try self.io.writeAll(method_token);
        try self.io.writeAll(" ");
        try self.io.writeAll(target);
        try self.io.writeAll(" ");
        try self.io.writeAll(@tagName(version));
        try self.io.writeAll("\r\n");
    }

    /// Write a status line with the canonical reason phrase. An unnamed status
    /// writes an empty reason; the separating SP is still present.
    pub fn statusLine(self: Writer, version: Version, status: Status) Error!void {
        return self.statusLineReason(version, status, status.phrase() orelse "");
    }

    /// Write a status line with a caller-supplied reason phrase.
    pub fn statusLineReason(
        self: Writer,
        version: Version,
        status: Status,
        reason: []const u8,
    ) Error!void {
        try validateReason(reason);

        try self.io.writeAll(@tagName(version));
        try self.io.print(" {d:0>3} ", .{status.code()});
        try self.io.writeAll(reason);
        try self.io.writeAll("\r\n");
    }

    /// Write one field line.
    pub fn field(self: Writer, name: []const u8, value: []const u8) Error!void {
        try validateFieldName(name);
        try validateFieldValue(value);

        try self.io.writeAll(name);
        try self.io.writeAll(": ");
        try self.io.writeAll(value);
        try self.io.writeAll("\r\n");
    }

    /// Write the empty line that ends the field section.
    pub fn endFields(self: Writer) Error!void {
        try self.io.writeAll("\r\n");
    }

    /// Write a `Content-Length` field line.
    pub fn contentLength(self: Writer, length: u64) Error!void {
        try self.io.print("Content-Length: {d}\r\n", .{length});
    }

    /// Write body bytes. The body is opaque; no validation applies.
    pub fn body(self: Writer, bytes: []const u8) Error!void {
        try self.io.writeAll(bytes);
    }

    /// Write the `Transfer-Encoding: chunked` field line.
    pub fn chunked(self: Writer) Error!void {
        try self.field("Transfer-Encoding", "chunked");
    }

    /// Write one non-final chunk.
    pub fn chunk(self: Writer, bytes: []const u8) Error!void {
        if (bytes.len == 0) return error.EmptyChunk;
        try self.io.print("{x}\r\n", .{bytes.len});
        try self.io.writeAll(bytes);
        try self.io.writeAll("\r\n");
    }

    /// Write the last chunk and the trailer section. An empty trailer list
    /// writes `0\r\n\r\n`.
    pub fn lastChunk(self: Writer, trailers: []const Header) Error!void {
        try self.io.writeAll("0\r\n");
        for (trailers) |trailer| try self.field(trailer.name, trailer.value);
        try self.io.writeAll("\r\n");
    }
};

fn validateMethod(token: []const u8) Writer.Error!void {
    if (token.len == 0) return error.InvalidMethod;
    for (token) |byte| if (!h1.isTchar(byte)) return error.InvalidMethod;
}

fn validateTarget(target: []const u8) Writer.Error!void {
    if (target.len == 0) return error.InvalidTarget;
    for (target) |byte| if (!h1.isTargetByte(byte)) return error.InvalidTarget;
}

fn validateFieldName(name: []const u8) Writer.Error!void {
    if (name.len == 0) return error.InvalidFieldName;
    for (name) |byte| if (!h1.isTchar(byte)) return error.InvalidFieldName;
}

fn validateFieldValue(value: []const u8) Writer.Error!void {
    for (value) |byte| if (!h1.isFieldValueByte(byte)) return error.InvalidFieldValue;
}

fn validateReason(reason: []const u8) Writer.Error!void {
    for (reason) |byte| if (!h1.isFieldValueByte(byte)) return error.InvalidReason;
}

test "request line" {
    var buffer: [64]u8 = undefined;
    var io: IoWriter = .fixed(&buffer);
    var w: Writer = .init(&io);
    try w.requestLine(.GET, "/x?y=1", .@"HTTP/1.1");
    try testing.expectEqualStrings("GET /x?y=1 HTTP/1.1\r\n", io.buffered());
}

test "request line with an arbitrary token" {
    var buffer: [64]u8 = undefined;
    var io: IoWriter = .fixed(&buffer);
    var w: Writer = .init(&io);
    try w.requestLineToken("PROPFIND", "/", .@"HTTP/1.0");
    try testing.expectEqualStrings("PROPFIND / HTTP/1.0\r\n", io.buffered());
}

test "status line uses the canonical phrase" {
    var buffer: [64]u8 = undefined;
    var io: IoWriter = .fixed(&buffer);
    var w: Writer = .init(&io);
    try w.statusLine(.@"HTTP/1.1", .ok);
    try testing.expectEqualStrings("HTTP/1.1 200 OK\r\n", io.buffered());

    io = .fixed(&buffer);
    w = .init(&io);
    try w.statusLine(.@"HTTP/1.0", .not_found);
    try testing.expectEqualStrings("HTTP/1.0 404 Not Found\r\n", io.buffered());
}

test "status line: unnamed code and explicit reason" {
    var buffer: [64]u8 = undefined;
    var io: IoWriter = .fixed(&buffer);
    var w: Writer = .init(&io);
    const unnamed: Status = @enumFromInt(599);
    try w.statusLine(.@"HTTP/1.1", unnamed);
    try testing.expectEqualStrings("HTTP/1.1 599 \r\n", io.buffered());

    io = .fixed(&buffer);
    w = .init(&io);
    try w.statusLineReason(.@"HTTP/1.1", .ok, "Fine");
    try testing.expectEqualStrings("HTTP/1.1 200 Fine\r\n", io.buffered());
}

test "fields, length, and body" {
    var buffer: [128]u8 = undefined;
    var io: IoWriter = .fixed(&buffer);
    var w: Writer = .init(&io);
    try w.statusLine(.@"HTTP/1.1", .ok);
    try w.field("Content-Type", "text/plain");
    try w.contentLength(5);
    try w.endFields();
    try w.body("hello");
    try testing.expectEqualStrings(
        "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 5\r\n\r\nhello",
        io.buffered(),
    );
}

test "chunked body and trailers" {
    var buffer: [256]u8 = undefined;
    var io: IoWriter = .fixed(&buffer);
    var w: Writer = .init(&io);
    try w.statusLine(.@"HTTP/1.1", .ok);
    try w.chunked();
    try w.endFields();
    try w.chunk("hello");
    try w.chunk(" world");
    try w.lastChunk(&.{
        .{ .name = "X-Checksum", .value = "abc" },
    });
    try testing.expectEqualStrings(
        "HTTP/1.1 200 OK\r\n" ++
            "Transfer-Encoding: chunked\r\n" ++
            "\r\n" ++
            "5\r\nhello\r\n" ++
            "6\r\n world\r\n" ++
            "0\r\nX-Checksum: abc\r\n\r\n",
        io.buffered(),
    );
}

test "invalid input is rejected before writing" {
    var buffer: [64]u8 = undefined;
    var io: IoWriter = .fixed(&buffer);
    var w: Writer = .init(&io);
    try testing.expectError(error.InvalidFieldName, w.field("Bad Name", "x"));
    try testing.expectError(error.InvalidFieldValue, w.field("X", "a\rb"));
    try testing.expectError(error.InvalidTarget, w.requestLine(.GET, "/a b", .@"HTTP/1.1"));
    try testing.expectError(error.InvalidMethod, w.requestLineToken("GE T", "/", .@"HTTP/1.1"));
    try testing.expectError(error.InvalidReason, w.statusLineReason(.@"HTTP/1.1", .ok, "a\rb"));
    try testing.expectError(error.EmptyChunk, w.chunk(""));
    try testing.expectEqualStrings("", io.buffered());
}

test "a full fixed buffer is WriteFailed" {
    var buffer: [4]u8 = undefined;
    var io: IoWriter = .fixed(&buffer);
    var w: Writer = .init(&io);
    try testing.expectError(error.WriteFailed, w.requestLine(.GET, "/", .@"HTTP/1.1"));
}
