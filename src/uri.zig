//! Absolute `http` and `https` URLs, split into the pieces a request needs.
//!
//! A URL is a name for a peer, not a connection: `parse` does no I/O and
//! touches no socket. The returned fields borrow the text passed in, except
//! `target`, which needs an allocation when the URL has a query and no path.
//!
//! The split is deliberately narrow. There is no userinfo, no fragment sent to
//! the peer, no other scheme, and no relative reference. A caller that needs
//! IDNA, percent-decoding, or reference resolution does that above this.

const std = @import("std");
const Io = std.Io;
const mem = std.mem;
const Allocator = std.mem.Allocator;
const testing = std.testing;
const stdx = @import("stdx");
const HostPort = stdx.net.HostPort;

const Scheme = @import("client/common.zig").Scheme;

pub const ParseError = error{
    /// No `://` separator.
    MissingScheme,
    /// A scheme other than `http` or `https`.
    UnsupportedScheme,
    /// Nothing between `://` and the path.
    EmptyAuthority,
    /// `user:password@` has no place in a request target; send `Authorization`.
    UserinfoUnsupported,
    /// A host or port the splitter rejects.
    InvalidAuthority,
    /// A URL the splitter accepts but cannot represent.
    InvalidUrl,
    OutOfMemory,
};

// ast-grep-ignore: public-struct-field-default -- URL value; target is borrowed when possible
pub const Url = struct {
    scheme: Scheme,
    /// The authority as written, without userinfo: `example.com`,
    /// `example.com:8080`, or `[::1]:8080`. This is the h1 `Host` value and the
    /// h2 `:authority` value, and it stays in step with the port the caller
    /// dials.
    authority: []const u8,
    /// The host without IPv6 brackets, ready for `IpAddress.parse` or DNS.
    host: []const u8,
    /// The explicit port, or the scheme default.
    port: u16,
    /// The origin-form request target: path and query, never empty, `/` when
    /// the URL has no path.
    target: []const u8,
    /// Storage for `target` when the URL began with `?`, which needs a leading
    /// `/`. Free it with `deinit`.
    owned_target: ?[]u8 = null,

    /// Split one absolute URL. The fields borrow `text` except when
    /// `owned_target` is set.
    pub fn parse(allocator: Allocator, text: []const u8) ParseError!Url {
        const separator = mem.find(u8, text, "://") orelse return error.MissingScheme;
        const scheme: Scheme = if (mem.eql(u8, text[0..separator], "http"))
            .http
        else if (mem.eql(u8, text[0..separator], "https"))
            .https
        else
            return error.UnsupportedScheme;

        const rest = text[separator + 3 ..];
        const authority_len = mem.findAny(u8, rest, "/?#") orelse rest.len;
        const authority = rest[0..authority_len];
        if (authority.len == 0) return error.EmptyAuthority;
        if (mem.findScalar(u8, authority, '@') != null) return error.UserinfoUnsupported;

        const split = HostPort.parse(authority, defaultPort(scheme)) catch
            return error.InvalidAuthority;

        // An empty target is `/`. A target that opens with `?` needs the path
        // prepended, which is the one case that cannot borrow `text`.
        const after_authority = rest[authority_len..];
        const tail = after_authority[0 .. mem.findScalar(u8, after_authority, '#') orelse
            after_authority.len];
        var url: Url = .{
            .scheme = scheme,
            .authority = authority,
            .host = split.host,
            .port = split.port,
            .target = "/",
        };
        if (tail.len != 0) {
            if (tail[0] == '/') {
                url.target = tail;
            } else {
                const owned = try std.fmt.allocPrint(allocator, "/{s}", .{tail});
                url.target = owned;
                url.owned_target = owned;
            }
        }
        return url;
    }

    pub fn deinit(self: Url, allocator: Allocator) void {
        if (self.owned_target) |owned| allocator.free(owned);
    }

    pub fn defaultPort(scheme: Scheme) u16 {
        return switch (scheme) {
            .http => 80,
            .https => 443,
        };
    }
};

/// Percent-encode `bytes` as one query component: everything outside the
/// unreserved set of RFC 3986 §2.3 becomes `%XX`.
pub fn percentEncode(w: *Io.Writer, bytes: []const u8) Io.Writer.Error!void {
    const hex = "0123456789ABCDEF";
    for (bytes) |byte| {
        if (isUnreserved(byte)) {
            try w.writeByte(byte);
        } else {
            try w.writeAll(&.{ '%', hex[byte >> 4], hex[byte & 0xf] });
        }
    }
}

fn isUnreserved(byte: u8) bool {
    return switch (byte) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~' => true,
        else => false,
    };
}

test "a URL splits into the fields a request needs" {
    const cases = [_]struct {
        text: []const u8,
        scheme: Scheme,
        authority: []const u8,
        host: []const u8,
        port: u16,
        target: []const u8,
    }{
        .{
            .text = "http://example.com",
            .scheme = .http,
            .authority = "example.com",
            .host = "example.com",
            .port = 80,
            .target = "/",
        },
        .{
            .text = "https://10.96.0.1:6443/apis/v1?labelSelector=a%3Db",
            .scheme = .https,
            .authority = "10.96.0.1:6443",
            .host = "10.96.0.1",
            .port = 6443,
            .target = "/apis/v1?labelSelector=a%3Db",
        },
        .{
            .text = "http://[::1]:8080/x#frag",
            .scheme = .http,
            .authority = "[::1]:8080",
            .host = "::1",
            .port = 8080,
            .target = "/x",
        },
        .{
            .text = "https://example.com?q=1",
            .scheme = .https,
            .authority = "example.com",
            .host = "example.com",
            .port = 443,
            .target = "/?q=1",
        },
        .{
            .text = "https://example.com:443/path",
            .scheme = .https,
            .authority = "example.com:443",
            .host = "example.com",
            .port = 443,
            .target = "/path",
        },
    };
    for (cases) |case| {
        const url = try Url.parse(testing.allocator, case.text);
        defer url.deinit(testing.allocator);
        try testing.expectEqual(case.scheme, url.scheme);
        try testing.expectEqualStrings(case.authority, url.authority);
        try testing.expectEqualStrings(case.host, url.host);
        try testing.expectEqual(case.port, url.port);
        try testing.expectEqualStrings(case.target, url.target);
    }
}

test "a URL the client cannot send is refused" {
    const cases = [_]struct { text: []const u8, expected: ParseError }{
        .{ .text = "example.com/path", .expected = error.MissingScheme },
        .{ .text = "ftp://example.com/", .expected = error.UnsupportedScheme },
        .{ .text = "http://", .expected = error.EmptyAuthority },
        .{ .text = "http:///path", .expected = error.EmptyAuthority },
        .{ .text = "http://user:pass@example.com/", .expected = error.UserinfoUnsupported },
        .{ .text = "http://:80/", .expected = error.InvalidAuthority },
        .{ .text = "http://[::1/", .expected = error.InvalidAuthority },
        .{ .text = "http://::1:80/", .expected = error.InvalidAuthority },
        .{ .text = "http://example.com:0/", .expected = error.InvalidAuthority },
        .{ .text = "http://example.com:/", .expected = error.InvalidAuthority },
    };
    for (cases) |case| {
        try testing.expectError(case.expected, Url.parse(testing.allocator, case.text));
    }
}

test "the default port follows the scheme" {
    try testing.expectEqual(80, Url.defaultPort(.http));
    try testing.expectEqual(443, Url.defaultPort(.https));
}

test "query components are percent-encoded to the unreserved set" {
    var buffer: [128]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);
    try percentEncode(&writer, "app=kubernetes,name=x/y z~");
    try testing.expectEqualStrings("app%3Dkubernetes%2Cname%3Dx%2Fy%20z~", writer.buffered());

    var empty: [1]u8 = undefined;
    var empty_writer: Io.Writer = .fixed(&empty);
    try percentEncode(&empty_writer, "");
    try testing.expectEqual(@as(usize, 0), empty_writer.buffered().len);
}
