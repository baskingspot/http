//! The HPACK static table (RFC 7541 Appendix A).
//!
//! Sixty-one fields, fixed for the life of the protocol, shared by every
//! connection. Index 1 is the first entry, as the RFC numbers them; `get`
//! takes that index and returns null outside 1..61. The entries are `Header`
//! values with static storage, so a decoder can borrow them or copy them
//! without a lifetime question.

const std = @import("std");
const mem = std.mem;
const testing = std.testing;

const stdx = @import("stdx");

const Header = @import("../header.zig").Header;

pub fn get(index: u32) ?Header {
    if (index == 0 or index > count) return null;
    return fields[index - 1];
}

fn field(comptime name: []const u8, comptime value: []const u8) Header {
    return .{ .name = name, .value = value };
}

/// The number of static entries.
pub const count = fields.len;

/// The first dynamic index: one past the last static entry.
pub const first_dynamic: u32 = count + 1;

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

/// The entries that share one name, as a half-open range of `fields` indices.
const Run = struct {
    first: u8,
    count: u8,
};

const NameMap = stdx.bounded_array_hash_map.String(Run, count);

/// Name to run. Built once at comptime, so a lookup hashes the name and probes
/// instead of comparing it against all sixty-one entries.
const by_name: NameMap = blk: {
    @setEvalBranchQuota(10_000);
    var map: NameMap = .init;
    var i: usize = 0;
    while (i < count) {
        const name = fields[i].name;
        var end = i + 1;
        while (end < count and mem.eql(u8, fields[end].name, name)) end += 1;

        // The map keeps one run per name. A name that appears again after its
        // run would be unreachable, or would overwrite the first run.
        var later = end;
        while (later < count) : (later += 1) {
            if (mem.eql(u8, fields[later].name, name)) {
                @compileError("static table duplicate names must be adjacent");
            }
        }

        map.putAssumeCapacity(name, .{
            .first = @intCast(i),
            .count = @intCast(end - i),
        });
        i = end;
    }
    break :blk map;
};

/// The index of the first entry whose name and value both match, or null.
pub fn find(header: Header) ?u32 {
    const run = by_name.get(header.name) orelse return null;
    var i: usize = run.first;
    const end = i + run.count;
    while (i < end) : (i += 1) {
        if (mem.eql(u8, fields[i].value, header.value)) return @intCast(i + 1);
    }
    return null;
}

/// The index of the first entry with this name, or null. Entries that share a
/// name are adjacent, so this is the run's first index.
pub fn findName(name: []const u8) ?u32 {
    const run = by_name.get(name) orelse return null;
    return @as(u32, run.first) + 1;
}

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

test "find and findName prefer the first matching entry" {
    try testing.expectEqual(2, find(.{ .name = ":method", .value = "GET" }).?);
    try testing.expectEqual(3, find(.{ .name = ":method", .value = "POST" }).?);
    try testing.expectEqual(8, find(.{ .name = ":status", .value = "200" }).?);
    try testing.expectEqual(16, find(.{ .name = "accept-encoding", .value = "gzip, deflate" }).?);

    try testing.expect(find(.{ .name = ":method", .value = "get" }) == null);
    try testing.expect(find(.{ .name = "accept", .value = "text/plain" }) == null);

    try testing.expectEqual(1, findName(":authority").?);
    try testing.expectEqual(2, findName(":method").?);
    try testing.expectEqual(19, findName("accept").?);
    try testing.expectEqual(61, findName("www-authenticate").?);
    try testing.expect(findName("x-not-there") == null);
}

test "find and findName cover every entry" {
    for (fields, 0..) |entry, i| {
        const index: u32 = @intCast(i + 1);
        try testing.expectEqual(index, find(entry).?);

        const first = findName(entry.name).?;
        try testing.expectEqualStrings(entry.name, get(first).?.name);
        try testing.expect(first <= index);
    }

    try testing.expectEqual(@as(u32, 2), findName(":method").?);
    try testing.expectEqual(@as(u32, 4), findName(":path").?);
    try testing.expectEqual(@as(u32, 6), findName(":scheme").?);
    try testing.expectEqual(@as(u32, 8), findName(":status").?);
    try testing.expectEqual(@as(u32, 14), find(.{ .name = ":status", .value = "500" }).?);
}

test "a name that prefixes another is not a match" {
    try testing.expectEqual(@as(u32, 19), findName("accept").?);
    try testing.expectEqual(@as(u32, 16), findName("accept-encoding").?);
    try testing.expect(findName("accep") == null);
    try testing.expect(findName("accept-encodin") == null);
    try testing.expect(findName("accept-encodingx") == null);
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
