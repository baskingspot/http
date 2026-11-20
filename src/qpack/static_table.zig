//! The QPACK static table (RFC 9204 Appendix A).
//!
//! Ninety-nine fields, fixed for the life of the protocol, shared by every
//! connection. Index 0 is the first entry, as the RFC numbers them; `get`
//! takes that index and returns null outside 0..98. The entries are `Header`
//! values with static storage, so a decoder can borrow them or copy them
//! without a lifetime question.
//!
//! Lookups are a linear scan. The table is 99 entries, and the encoder is
//! static-only until the dynamic encoder lands; measure before adding a map.

const std = @import("std");
const testing = std.testing;
const mem = std.mem;

const Header = @import("../header.zig").Header;

/// The number of static entries.
pub const count: u64 = fields.len;

/// The first dynamic index: one past the last static entry.
pub const first_dynamic: u64 = count;

pub fn get(index: u64) ?Header {
    if (index >= count) return null;
    return fields[@intCast(index)];
}

/// The index of the first entry whose name and value both match.
pub fn find(name: []const u8, value: []const u8) ?u64 {
    for (fields, 0..) |entry, index| {
        if (mem.eql(u8, entry.name, name) and mem.eql(u8, entry.value, value)) {
            return @intCast(index);
        }
    }
    return null;
}

/// The index of the first entry with this name.
pub fn findName(name: []const u8) ?u64 {
    for (fields, 0..) |entry, index| {
        if (mem.eql(u8, entry.name, name)) return @intCast(index);
    }
    return null;
}

fn field(comptime name: []const u8, comptime value: []const u8) Header {
    return .{ .name = name, .value = value };
}

/// `fields[0]` is QPACK index 0. Use `get` with an index from the wire.
const fields: [99]Header = .{
    field(":authority", ""),
    field(":path", "/"),
    field("age", "0"),
    field("content-disposition", ""),
    field("content-length", "0"),
    field("cookie", ""),
    field("date", ""),
    field("etag", ""),
    field("if-modified-since", ""),
    field("if-none-match", ""),
    field("last-modified", ""),
    field("link", ""),
    field("location", ""),
    field("referer", ""),
    field("set-cookie", ""),
    field(":method", "CONNECT"),
    field(":method", "DELETE"),
    field(":method", "GET"),
    field(":method", "HEAD"),
    field(":method", "OPTIONS"),
    field(":method", "POST"),
    field(":method", "PUT"),
    field(":scheme", "http"),
    field(":scheme", "https"),
    field(":status", "103"),
    field(":status", "200"),
    field(":status", "304"),
    field(":status", "404"),
    field(":status", "503"),
    field("accept", "*/*"),
    field("accept", "application/dns-message"),
    field("accept-encoding", "gzip, deflate, br"),
    field("accept-ranges", "bytes"),
    field("access-control-allow-headers", "cache-control"),
    field("access-control-allow-headers", "content-type"),
    field("access-control-allow-origin", "*"),
    field("cache-control", "max-age=0"),
    field("cache-control", "max-age=2592000"),
    field("cache-control", "max-age=604800"),
    field("cache-control", "no-cache"),
    field("cache-control", "no-store"),
    field("cache-control", "public, max-age=31536000"),
    field("content-encoding", "br"),
    field("content-encoding", "gzip"),
    field("content-type", "application/dns-message"),
    field("content-type", "application/javascript"),
    field("content-type", "application/json"),
    field("content-type", "application/x-www-form-urlencoded"),
    field("content-type", "image/gif"),
    field("content-type", "image/jpeg"),
    field("content-type", "image/png"),
    field("content-type", "text/css"),
    field("content-type", "text/html; charset=utf-8"),
    field("content-type", "text/plain"),
    field("content-type", "text/plain;charset=utf-8"),
    field("range", "bytes=0-"),
    field("strict-transport-security", "max-age=31536000"),
    field("strict-transport-security", "max-age=31536000; includesubdomains"),
    field("strict-transport-security", "max-age=31536000; includesubdomains; preload"),
    field("vary", "accept-encoding"),
    field("vary", "origin"),
    field("x-content-type-options", "nosniff"),
    field("x-xss-protection", "1; mode=block"),
    field(":status", "100"),
    field(":status", "204"),
    field(":status", "206"),
    field(":status", "302"),
    field(":status", "400"),
    field(":status", "403"),
    field(":status", "421"),
    field(":status", "425"),
    field(":status", "500"),
    field("accept-language", ""),
    field("access-control-allow-credentials", "FALSE"),
    field("access-control-allow-credentials", "TRUE"),
    field("access-control-allow-headers", "*"),
    field("access-control-allow-methods", "get"),
    field("access-control-allow-methods", "get, post, options"),
    field("access-control-allow-methods", "options"),
    field("access-control-expose-headers", "content-length"),
    field("access-control-request-headers", "content-type"),
    field("access-control-request-method", "get"),
    field("access-control-request-method", "post"),
    field("alt-svc", "clear"),
    field("authorization", ""),
    field("content-security-policy", "script-src 'none'; object-src 'none'; base-uri 'none'"),
    field("early-data", "1"),
    field("expect-ct", ""),
    field("forwarded", ""),
    field("if-range", ""),
    field("origin", ""),
    field("purpose", "prefetch"),
    field("server", ""),
    field("timing-allow-origin", "*"),
    field("upgrade-insecure-requests", "1"),
    field("user-agent", ""),
    field("x-forwarded-for", ""),
    field("x-frame-options", "deny"),
    field("x-frame-options", "sameorigin"),
};

test "RFC 9204 Appendix A, the known indices" {
    try testing.expectEqual(@as(u64, 99), count);
    try testing.expectEqual(@as(u64, 99), first_dynamic);

    try testing.expectEqualStrings(":authority", get(0).?.name);
    try testing.expectEqualStrings("", get(0).?.value);
    try testing.expectEqualStrings("/", get(1).?.value);
    try testing.expectEqualStrings(":method", get(17).?.name);
    try testing.expectEqualStrings("GET", get(17).?.value);
    try testing.expectEqualStrings("application/dns-message", get(30).?.value);
    try testing.expectEqualStrings("text/html; charset=utf-8", get(52).?.value);
    try testing.expectEqualStrings("text/plain;charset=utf-8", get(54).?.value);
    try testing.expectEqualStrings(
        "max-age=31536000; includesubdomains; preload",
        get(58).?.value,
    );
    try testing.expectEqualStrings(":status", get(63).?.name);
    try testing.expectEqualStrings("100", get(63).?.value);
    try testing.expectEqualStrings(
        "script-src 'none'; object-src 'none'; base-uri 'none'",
        get(85).?.value,
    );
    try testing.expectEqualStrings("sameorigin", get(98).?.value);
    try testing.expect(get(99) == null);
}

test "find distinguishes the two :status runs" {
    try testing.expectEqual(@as(?u64, 25), find(":status", "200"));
    try testing.expectEqual(@as(?u64, 63), find(":status", "100"));
    try testing.expectEqual(@as(?u64, 24), findName(":status"));

    try testing.expectEqual(@as(?u64, 33), find("access-control-allow-headers", "cache-control"));
    try testing.expectEqual(@as(?u64, 75), find("access-control-allow-headers", "*"));
    try testing.expectEqual(@as(?u64, 33), findName("access-control-allow-headers"));

    try testing.expect(find(":status", "999") == null);
    try testing.expect(find("nope", "") == null);
    try testing.expect(findName("nope") == null);
}

test "every entry is the first exact match for its pair" {
    for (0..count) |index| {
        const entry = get(index).?;
        try testing.expectEqual(@as(?u64, @intCast(index)), find(entry.name, entry.value));
        try testing.expect(findName(entry.name).? <= index);
    }
}
