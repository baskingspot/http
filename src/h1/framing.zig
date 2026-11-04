//! HTTP/1.1 message body framing (RFC 9112 §6.3).
//!
//! The head is parsed; this decides how many octets follow it. The decision is
//! pure: it reads the field section and the request context, and returns a
//! `Body`. It does not read the body.
//!
//! Order matters. The no-body rules for HEAD, 1xx, 204, and 304 come first,
//! then the CONNECT tunnel rule, then the Transfer-Encoding and
//! Content-Length rules.

const std = @import("std");
const testing = std.testing;

const Header = @import("../header.zig").Header;
const Headers = @import("../header.zig").Headers;
const Method = @import("../method.zig").Method;
const Status = @import("../status.zig").Status;
const content_length = @import("../content_length.zig");
const transfer_encoding = @import("../transfer_encoding.zig");
const version_mod = @import("../version.zig");
const Version = version_mod.Version;

pub const Body = union(enum) {
    /// No body. A request with no framing fields, or a response that the
    /// request method or status forbids a body for.
    none,
    /// A body of exactly this many octets.
    length: u64,
    /// The chunked transfer coding.
    chunked,
    /// The body ends when the connection closes. Responses only.
    close,
    /// A successful CONNECT response: the connection becomes a tunnel.
    tunnel,
};

pub const Error = error{
    /// Transfer-Encoding is present on an HTTP/1.0 message (RFC 9112 §6.1).
    FaultyFraming,
    /// Transfer-Encoding and Content-Length both frame the message.
    ConflictingFraming,
    /// Transfer-Encoding is malformed, repeats chunked, or gives it
    /// parameters. A request whose final coding is not chunked also lands
    /// here.
    InvalidTransferEncoding,
    /// Content-Length is malformed, conflicting, or overflows `u64`.
    InvalidContentLength,
};

/// The body framing for a request head.
pub fn request(version: Version, headers: Headers) Error!Body {
    const te = try transfer(headers);
    const cl = try content(headers);

    // RFC 9112 §6.1: an HTTP/1.0 message with Transfer-Encoding has faulty
    // framing even when Content-Length is present.
    if (te.present and version == .@"HTTP/1.0") return error.FaultyFraming;
    // RFC 9112 §6.3 rule 3: TE overrides CL, but the combination is a request
    // smuggling signal. Reject it rather than guess which side is right.
    if (te.present and cl.present) return error.ConflictingFraming;
    if (te.present) {
        // Rule 4: a request whose final coding is not chunked cannot be
        // framed. The server must reject it.
        if (!te.chunked_last) return error.InvalidTransferEncoding;
        return .chunked;
    }
    // Rule 6, then rule 7.
    if (cl.length) |length| return .{ .length = length };
    return .none;
}

/// The body framing for a response head. `request_method` is the method of the
/// request this response answers, or null when it is not known.
pub fn response(
    version: Version,
    status: Status,
    request_method: ?Method,
    headers: Headers,
) Error!Body {
    // Rule 1: these responses never have a body, whatever the fields say.
    if (request_method == .HEAD or
        status.class() == .informational or
        status == .no_content or
        status == .not_modified)
    {
        return .none;
    }
    // Rule 2: a 2xx response to CONNECT is a tunnel, and its CL/TE are
    // ignored.
    if (request_method == .CONNECT and status.class() == .success) return .tunnel;

    const te = try transfer(headers);
    const cl = try content(headers);

    if (te.present and version == .@"HTTP/1.0") return error.FaultyFraming;
    if (te.present and cl.present) return error.ConflictingFraming;
    if (te.present) {
        // Rule 4: a final chunked coding frames the body; any other final
        // coding leaves it close-delimited.
        if (te.chunked_last) return .chunked;
        return .close;
    }
    if (cl.length) |length| return .{ .length = length };
    // Rule 8.
    return .close;
}

const Transfer = struct {
    present: bool,
    chunked_last: bool,
};

fn transfer(headers: Headers) Error!Transfer {
    const summary = transfer_encoding.summarize(headers) catch
        return error.InvalidTransferEncoding;
    return .{
        .present = summary.present,
        .chunked_last = summary.chunked_last,
    };
}

const Content = struct {
    present: bool,
    length: ?u64,
};

fn content(headers: Headers) Error!Content {
    var parser: content_length.Parser = .{};
    var present = false;
    var values = headers.values("Content-Length");
    while (values.next()) |value| {
        present = true;
        parser.feed(value) catch return error.InvalidContentLength;
    }
    return .{ .present = present, .length = parser.finish() };
}

fn section(items: []const Header) Headers {
    return .{ .items = items };
}

test "request: no framing fields means no body" {
    try testing.expectEqualDeep(Body.none, try request(.@"HTTP/1.1", section(&.{})));
    try testing.expectEqualDeep(Body.none, try request(.@"HTTP/1.0", section(&.{})));
}

test "request: Content-Length" {
    try testing.expectEqualDeep(Body{ .length = 42 }, try request(.@"HTTP/1.1", section(&.{
        .{ .name = "Content-Length", .value = "42" },
    })));
    try testing.expectEqualDeep(Body{ .length = 0 }, try request(.@"HTTP/1.0", section(&.{
        .{ .name = "content-length", .value = "0" },
    })));
    try testing.expectEqualDeep(Body{ .length = 42 }, try request(.@"HTTP/1.1", section(&.{
        .{ .name = "Content-Length", .value = "42, 42" },
    })));
}

test "request: chunked" {
    const chunked = section(&.{
        .{ .name = "Transfer-Encoding", .value = "chunked" },
    });
    try testing.expectEqualDeep(Body.chunked, try request(.@"HTTP/1.1", chunked));

    const gzip_chunked = section(&.{
        .{ .name = "Transfer-Encoding", .value = "gzip, chunked" },
    });
    try testing.expectEqualDeep(Body.chunked, try request(.@"HTTP/1.1", gzip_chunked));
}

test "request: a final coding other than chunked is rejected" {
    const gzip = section(&.{
        .{ .name = "Transfer-Encoding", .value = "gzip" },
    });
    try testing.expectError(error.InvalidTransferEncoding, request(.@"HTTP/1.1", gzip));

    const chunked_gzip = section(&.{
        .{ .name = "Transfer-Encoding", .value = "chunked, gzip" },
    });
    try testing.expectError(error.InvalidTransferEncoding, request(.@"HTTP/1.1", chunked_gzip));

    const empty = section(&.{
        .{ .name = "Transfer-Encoding", .value = "" },
    });
    try testing.expectError(error.InvalidTransferEncoding, request(.@"HTTP/1.1", empty));
}

test "request: Transfer-Encoding and Content-Length conflict" {
    const both = section(&.{
        .{ .name = "Transfer-Encoding", .value = "chunked" },
        .{ .name = "Content-Length", .value = "42" },
    });
    try testing.expectError(error.ConflictingFraming, request(.@"HTTP/1.1", both));
}

test "request: Transfer-Encoding on HTTP/1.0 is faulty" {
    const te = section(&.{
        .{ .name = "Transfer-Encoding", .value = "chunked" },
    });
    try testing.expectError(error.FaultyFraming, request(.@"HTTP/1.0", te));

    const both = section(&.{
        .{ .name = "Transfer-Encoding", .value = "chunked" },
        .{ .name = "Content-Length", .value = "42" },
    });
    try testing.expectError(error.FaultyFraming, request(.@"HTTP/1.0", both));
}

test "request: malformed Content-Length" {
    const invalid = section(&.{
        .{ .name = "Content-Length", .value = "abc" },
    });
    try testing.expectError(error.InvalidContentLength, request(.@"HTTP/1.1", invalid));

    const conflicting = section(&.{
        .{ .name = "Content-Length", .value = "42" },
        .{ .name = "Content-Length", .value = "43" },
    });
    try testing.expectError(error.InvalidContentLength, request(.@"HTTP/1.1", conflicting));

    const overflow = section(&.{
        .{ .name = "Content-Length", .value = "18446744073709551616" },
    });
    try testing.expectError(error.InvalidContentLength, request(.@"HTTP/1.1", overflow));
}

test "response: no body for HEAD, 1xx, 204, and 304" {
    const te = section(&.{
        .{ .name = "Transfer-Encoding", .value = "chunked" },
    });
    const cl = section(&.{
        .{ .name = "Content-Length", .value = "42" },
    });

    try testing.expectEqualDeep(Body.none, try response(.@"HTTP/1.1", .ok, .HEAD, te));
    try testing.expectEqualDeep(Body.none, try response(.@"HTTP/1.1", .ok, .HEAD, cl));
    try testing.expectEqualDeep(Body.none, try response(.@"HTTP/1.1", .@"continue", null, te));
    try testing.expectEqualDeep(Body.none, try response(.@"HTTP/1.1", .no_content, null, te));
    try testing.expectEqualDeep(Body.none, try response(.@"HTTP/1.1", .not_modified, null, te));

    // The no-body rule comes before the HTTP/1.0 faulty-framing rule.
    try testing.expectEqualDeep(Body.none, try response(.@"HTTP/1.0", .ok, .HEAD, te));
}

test "response: CONNECT tunnel" {
    const te = section(&.{
        .{ .name = "Transfer-Encoding", .value = "chunked" },
    });
    const cl = section(&.{
        .{ .name = "Content-Length", .value = "42" },
    });

    try testing.expectEqualDeep(Body.tunnel, try response(.@"HTTP/1.1", .ok, .CONNECT, te));
    try testing.expectEqualDeep(Body.tunnel, try response(.@"HTTP/1.1", .created, .CONNECT, cl));

    // A non-2xx response to CONNECT is not a tunnel.
    try testing.expectEqualDeep(Body{ .length = 42 }, try response(
        .@"HTTP/1.1",
        .not_found,
        .CONNECT,
        cl,
    ));
}

test "response: normal framing" {
    const cl = section(&.{
        .{ .name = "Content-Length", .value = "42" },
    });
    try testing.expectEqualDeep(Body{ .length = 42 }, try response(.@"HTTP/1.1", .ok, .GET, cl));

    const chunked = section(&.{
        .{ .name = "Transfer-Encoding", .value = "gzip, chunked" },
    });
    try testing.expectEqualDeep(Body.chunked, try response(.@"HTTP/1.1", .ok, .GET, chunked));

    // A final coding that is not chunked is close-delimited.
    const gzip = section(&.{
        .{ .name = "Transfer-Encoding", .value = "chunked, gzip" },
    });
    try testing.expectEqualDeep(Body.close, try response(.@"HTTP/1.1", .ok, .GET, gzip));

    try testing.expectEqualDeep(Body.close, try response(.@"HTTP/1.1", .ok, .GET, section(&.{})));
}

test "response: conflicts and HTTP/1.0" {
    const both = section(&.{
        .{ .name = "Transfer-Encoding", .value = "chunked" },
        .{ .name = "Content-Length", .value = "42" },
    });
    try testing.expectError(error.ConflictingFraming, response(.@"HTTP/1.1", .ok, .GET, both));

    const te = section(&.{
        .{ .name = "Transfer-Encoding", .value = "chunked" },
    });
    try testing.expectError(error.FaultyFraming, response(.@"HTTP/1.0", .ok, .GET, te));

    const invalid = section(&.{
        .{ .name = "Content-Length", .value = "abc" },
    });
    try testing.expectError(error.InvalidContentLength, response(.@"HTTP/1.1", .ok, .GET, invalid));
}
