//! HTTP/1 writer methods over a caller-owned `std.Io.Writer`.
//!
//! The caller owns the sink: a fixed buffer, a file, a socket, or anything else
//! that implements `std.Io.Writer`. These functions only format; they never
//! create, flush, or close a writer, and they never allocate.
//!
//! The grammar matches the parser: CRLF only, `tchar` field names, field values
//! with no CTLs, and a request target of printable US-ASCII. Invalid input is
//! rejected before any bytes are written.

const std = @import("std");
const testing = std.testing;
const Writer = std.Io.Writer;

const Header = @import("../header.zig").Header;
const Method = @import("../method.zig").Method;
const Status = @import("../status.zig").Status;
const Version = @import("../version.zig").Version;
const h1 = @import("root.zig");

pub const Error = Writer.Error || error{
    InvalidMethod,
    InvalidTarget,
    InvalidFieldName,
    InvalidFieldValue,
    InvalidReason,
    EmptyChunk,
};

/// Write a request line for one of the common methods.
pub fn requestLine(
    w: *Writer,
    method: Method,
    target: []const u8,
    version: Version,
) Error!void {
    return requestLineToken(w, method.token(), target, version);
}

/// Write a request line for an arbitrary method token.
pub fn requestLineToken(
    w: *Writer,
    method_token: []const u8,
    target: []const u8,
    version: Version,
) Error!void {
    try validateMethod(method_token);
    try validateTarget(target);

    try w.writeAll(method_token);
    try w.writeAll(" ");
    try w.writeAll(target);
    try w.writeAll(" ");
    try w.writeAll(@tagName(version));
    try w.writeAll("\r\n");
}

/// Write a status line with the canonical reason phrase. An unnamed status
/// writes an empty reason; the separating SP is still present.
pub fn statusLine(w: *Writer, version: Version, status: Status) Error!void {
    return statusLineReason(w, version, status, status.phrase() orelse "");
}

/// Write a status line with a caller-supplied reason phrase.
pub fn statusLineReason(
    w: *Writer,
    version: Version,
    status: Status,
    reason: []const u8,
) Error!void {
    try validateReason(reason);

    try w.writeAll(@tagName(version));
    try w.print(" {d:0>3} ", .{status.code()});
    try w.writeAll(reason);
    try w.writeAll("\r\n");
}

/// Write one field line.
pub fn field(w: *Writer, name: []const u8, value: []const u8) Error!void {
    try validateFieldName(name);
    try validateFieldValue(value);

    try w.writeAll(name);
    try w.writeAll(": ");
    try w.writeAll(value);
    try w.writeAll("\r\n");
}

/// Write the empty line that ends the field section.
pub fn endFields(w: *Writer) Error!void {
    try w.writeAll("\r\n");
}

/// Write a `Content-Length` field line.
pub fn contentLength(w: *Writer, length: u64) Error!void {
    try w.print("Content-Length: {d}\r\n", .{length});
}

/// Write body bytes. The body is opaque; no validation applies.
pub fn body(w: *Writer, bytes: []const u8) Error!void {
    try w.writeAll(bytes);
}

/// Write the `Transfer-Encoding: chunked` field line.
pub fn chunked(w: *Writer) Error!void {
    try field(w, "Transfer-Encoding", "chunked");
}

/// Write one non-final chunk.
pub fn chunk(w: *Writer, bytes: []const u8) Error!void {
    if (bytes.len == 0) return error.EmptyChunk;
    try w.print("{x}\r\n", .{bytes.len});
    try w.writeAll(bytes);
    try w.writeAll("\r\n");
}

/// Write the last chunk and the trailer section. An empty trailer list writes
/// `0\r\n\r\n`.
pub fn lastChunk(w: *Writer, trailers: []const Header) Error!void {
    try w.writeAll("0\r\n");
    for (trailers) |trailer| try field(w, trailer.name, trailer.value);
    try w.writeAll("\r\n");
}

fn validateMethod(token: []const u8) Error!void {
    if (token.len == 0) return error.InvalidMethod;
    for (token) |byte| if (!h1.isTchar(byte)) return error.InvalidMethod;
}

fn validateTarget(target: []const u8) Error!void {
    if (target.len == 0) return error.InvalidTarget;
    for (target) |byte| if (!h1.isTargetByte(byte)) return error.InvalidTarget;
}

fn validateFieldName(name: []const u8) Error!void {
    if (name.len == 0) return error.InvalidFieldName;
    for (name) |byte| if (!h1.isTchar(byte)) return error.InvalidFieldName;
}

fn validateFieldValue(value: []const u8) Error!void {
    for (value) |byte| if (!h1.isFieldValueByte(byte)) return error.InvalidFieldValue;
}

fn validateReason(reason: []const u8) Error!void {
    for (reason) |byte| if (!h1.isFieldValueByte(byte)) return error.InvalidReason;
}

test "request line" {
    var buffer: [64]u8 = undefined;
    var w: Writer = .fixed(&buffer);
    try requestLine(&w, .GET, "/x?y=1", .@"HTTP/1.1");
    try testing.expectEqualStrings("GET /x?y=1 HTTP/1.1\r\n", w.buffered());
}

test "request line with an arbitrary token" {
    var buffer: [64]u8 = undefined;
    var w: Writer = .fixed(&buffer);
    try requestLineToken(&w, "PROPFIND", "/", .@"HTTP/1.0");
    try testing.expectEqualStrings("PROPFIND / HTTP/1.0\r\n", w.buffered());
}

test "status line uses the canonical phrase" {
    var buffer: [64]u8 = undefined;
    var w: Writer = .fixed(&buffer);
    try statusLine(&w, .@"HTTP/1.1", .ok);
    try testing.expectEqualStrings("HTTP/1.1 200 OK\r\n", w.buffered());

    w = .fixed(&buffer);
    try statusLine(&w, .@"HTTP/1.0", .not_found);
    try testing.expectEqualStrings("HTTP/1.0 404 Not Found\r\n", w.buffered());
}

test "status line: unnamed code and explicit reason" {
    var buffer: [64]u8 = undefined;
    var w: Writer = .fixed(&buffer);
    const unnamed: Status = @enumFromInt(599);
    try statusLine(&w, .@"HTTP/1.1", unnamed);
    try testing.expectEqualStrings("HTTP/1.1 599 \r\n", w.buffered());

    w = .fixed(&buffer);
    try statusLineReason(&w, .@"HTTP/1.1", .ok, "Fine");
    try testing.expectEqualStrings("HTTP/1.1 200 Fine\r\n", w.buffered());
}

test "fields, length, and body" {
    var buffer: [128]u8 = undefined;
    var w: Writer = .fixed(&buffer);
    try statusLine(&w, .@"HTTP/1.1", .ok);
    try field(&w, "Content-Type", "text/plain");
    try contentLength(&w, 5);
    try endFields(&w);
    try body(&w, "hello");
    try testing.expectEqualStrings(
        "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 5\r\n\r\nhello",
        w.buffered(),
    );
}

test "chunked body and trailers" {
    var buffer: [256]u8 = undefined;
    var w: Writer = .fixed(&buffer);
    try statusLine(&w, .@"HTTP/1.1", .ok);
    try chunked(&w);
    try endFields(&w);
    try chunk(&w, "hello");
    try chunk(&w, " world");
    try lastChunk(&w, &.{
        .{ .name = "X-Checksum", .value = "abc" },
    });
    try testing.expectEqualStrings(
        "HTTP/1.1 200 OK\r\n" ++
            "Transfer-Encoding: chunked\r\n" ++
            "\r\n" ++
            "5\r\nhello\r\n" ++
            "6\r\n world\r\n" ++
            "0\r\nX-Checksum: abc\r\n\r\n",
        w.buffered(),
    );
}

test "invalid input is rejected before writing" {
    var buffer: [64]u8 = undefined;
    var w: Writer = .fixed(&buffer);
    try testing.expectError(error.InvalidFieldName, field(&w, "Bad Name", "x"));
    try testing.expectError(error.InvalidFieldValue, field(&w, "X", "a\rb"));
    try testing.expectError(error.InvalidTarget, requestLine(&w, .GET, "/a b", .@"HTTP/1.1"));
    try testing.expectError(
        error.InvalidMethod,
        requestLineToken(&w, "GE T", "/", .@"HTTP/1.1"),
    );
    try testing.expectError(error.InvalidReason, statusLineReason(&w, .@"HTTP/1.1", .ok, "a\rb"));
    try testing.expectError(error.EmptyChunk, chunk(&w, ""));
    try testing.expectEqualStrings("", w.buffered());
}

test "a full fixed buffer is WriteFailed" {
    var buffer: [4]u8 = undefined;
    var w: Writer = .fixed(&buffer);
    try testing.expectError(error.WriteFailed, requestLine(&w, .GET, "/", .@"HTTP/1.1"));
}
