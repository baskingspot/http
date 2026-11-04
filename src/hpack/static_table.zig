//! The HPACK static table (RFC 7541 Appendix A).
//!
//! Sixty-one fields, fixed for the life of the protocol, shared by every
//! connection. Index 1 is the first entry, as the RFC numbers them; `get`
//! takes that index and returns null outside 1..61. The entries are `Header`
//! values with static storage, so a decoder can borrow them or copy them
//! without a lifetime question.

const std = @import("std");
const testing = std.testing;
const mem = std.mem;

const Header = @import("../header.zig").Header;

pub fn get(index: u32) ?Header {
    if (index == 0 or index > count) return null;
    return fields[index - 1];
}

fn field(comptime name: []const u8, comptime value: []const u8) Header {
    return .{ .name = name, .value = value };
}

/// The number of static entries. The first dynamic index is `count + 1`.
pub const count = fields.len;

/// `fields[0]` is HPACK index 1. Use `get` with an index from the wire.
const fields: [61]Header = .{
    field(":authority", ""),
    field(":method", "GET"),
    field(":method", "POST"),
    field(":path", "/"),
    field(":path", "/index.html"),
    field(":scheme", "http"),
    field(":scheme", "https"),
    field(":status", "200"),
    field(":status", "204"),
    field(":status", "206"),
    field(":status", "304"),
    field(":status", "400"),
    field(":status", "404"),
    field(":status", "500"),
    field("accept-charset", ""),
    field("accept-encoding", "gzip, deflate"),
    field("accept-language", ""),
    field("accept-ranges", ""),
    field("accept", ""),
    field("access-control-allow-origin", ""),
    field("age", ""),
    field("allow", ""),
    field("authorization", ""),
    field("cache-control", ""),
    field("content-disposition", ""),
    field("content-encoding", ""),
    field("content-language", ""),
    field("content-length", ""),
    field("content-location", ""),
    field("content-range", ""),
    field("content-type", ""),
    field("cookie", ""),
    field("date", ""),
    field("etag", ""),
    field("expect", ""),
    field("expires", ""),
    field("from", ""),
    field("host", ""),
    field("if-match", ""),
    field("if-modified-since", ""),
    field("if-none-match", ""),
    field("if-range", ""),
    field("if-unmodified-since", ""),
    field("last-modified", ""),
    field("link", ""),
    field("location", ""),
    field("max-forwards", ""),
    field("proxy-authenticate", ""),
    field("proxy-authorization", ""),
    field("range", ""),
    field("referer", ""),
    field("refresh", ""),
    field("retry-after", ""),
    field("server", ""),
    field("set-cookie", ""),
    field("strict-transport-security", ""),
    field("transfer-encoding", ""),
    field("user-agent", ""),
    field("vary", ""),
    field("via", ""),
    field("www-authenticate", ""),
};

test "the RFC's numbered entries, at both ends and the pseudo-headers" {
    try testing.expectEqualStrings(":authority", get(1).?.name);
    try testing.expectEqualStrings("", get(1).?.value);
    try testing.expectEqualStrings(":method", get(2).?.name);
    try testing.expectEqualStrings("GET", get(2).?.value);
    try testing.expectEqualStrings("POST", get(3).?.value);
    try testing.expectEqualStrings(":status", get(8).?.name);
    try testing.expectEqualStrings("200", get(8).?.value);
    try testing.expectEqualStrings("500", get(14).?.value);
    try testing.expectEqualStrings("accept-encoding", get(16).?.name);
    try testing.expectEqualStrings("gzip, deflate", get(16).?.value);
    try testing.expectEqualStrings("cookie", get(32).?.name);
    try testing.expectEqualStrings("set-cookie", get(55).?.name);
    try testing.expectEqualStrings("www-authenticate", get(61).?.name);
}

test "outside 1..61 there is nothing" {
    try testing.expect(get(0) == null);
    try testing.expect(get(62) == null);
    try testing.expect(get(1000) == null);
}

test "every entry is reachable and distinct by name and value" {
    var index: u32 = 1;
    while (index <= count) : (index += 1) {
        const a = get(index).?;
        try testing.expect(a.name.len != 0);
        var other: u32 = index + 1;
        while (other <= count) : (other += 1) {
            const b = get(other).?;
            try testing.expect(!(mem.eql(u8, a.name, b.name) and
                mem.eql(u8, a.value, b.value)));
        }
    }
}
