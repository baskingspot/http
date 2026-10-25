//! `Accept-Encoding` parsing and content-coding negotiation.
//!
//! `negotiate(header, supported)` takes the field value and the server's
//! supported codings in preference order. It returns a token borrowed from
//! `supported`, the static `identity`, or `null` when the client accepts
//! nothing else. It allocates nothing.
//!
//! Rules (RFC 9110 §12.5.3):
//! - A coding's weight is its `q` parameter, 0..1 with at most three fractional
//!   digits; no parameter means 1. `q=0` is not acceptable.
//! - `*` gives a weight to every coding not named explicitly.
//! - `identity` is acceptable by default. It is excluded by `identity;q=0`, or
//!   by `*;q=0` when there is no explicit identity entry.
//! - An absent `Accept-Encoding` field is treated as `identity` here, the
//!   conservative server policy, not as "anything is acceptable".
//! - A malformed weight is 0, and the first entry for a coding wins.
//! - Ties go to the server's order in `supported`; an explicit identity
//!   weight only wins when it is higher than the best coding's.

const std = @import("std");
const ascii = std.ascii;
const testing = std.testing;

/// The token for "no content coding". It is not looked up in `supported`.
pub const identity = "identity";

/// The chosen content coding, or `null` when nothing is acceptable.
///
/// `supported` lists the content codings the server can produce, most
/// preferred first. It must not contain `identity`; that token is handled
/// here. The returned slice is either one of `supported`'s elements or
/// `identity`.
pub fn negotiate(header: ?[]const u8, supported: []const []const u8) ?[]const u8 {
    const value = header orelse return identity;

    var wildcard_q: ?u16 = null;
    var identity_q: ?u16 = null;
    var entries: Entries = .{ .value = value };
    while (entries.next()) |entry| {
        if (eq(entry.coding, "*")) {
            if (wildcard_q == null) wildcard_q = entry.q;
        } else if (eq(entry.coding, identity)) {
            if (identity_q == null) identity_q = entry.q;
        }
    }

    var best: ?[]const u8 = null;
    var best_q: u16 = 0;
    for (supported) |coding| {
        if (eq(coding, identity)) continue;
        const q = explicitQ(value, coding) orelse wildcard_q orelse 0;
        if (q > best_q) {
            best = coding;
            best_q = q;
        }
    }

    if (best_q == 0) {
        return if (identityAllowed(wildcard_q, identity_q)) identity else null;
    }
    if (identity_q) |q| {
        if (q > best_q) return identity;
    }
    return best;
}

/// The first explicit weight for `coding`, or null when the field does not
/// name it.
fn explicitQ(value: []const u8, coding: []const u8) ?u16 {
    var entries: Entries = .{ .value = value };
    while (entries.next()) |entry| {
        if (eq(entry.coding, coding)) return entry.q;
    }
    return null;
}

/// Whether the representation with no content coding is acceptable.
fn identityAllowed(wildcard_q: ?u16, identity_q: ?u16) bool {
    if (identity_q) |q| return q > 0;
    if (wildcard_q) |q| return q > 0;
    return true;
}

const Entry = struct {
    coding: []const u8,
    q: u16,
};

/// A one-pass iterator over the comma-separated entries. Each coding is a
/// borrowed slice; weights are in thousandths.
const Entries = struct {
    value: []const u8,
    pos: usize = 0,

    fn next(self: *Entries) ?Entry {
        while (self.pos <= self.value.len) {
            const start = self.pos;
            const comma = std.mem.findScalarPos(u8, self.value, start, ',') orelse self.value.len;
            self.pos = comma + 1;
            const item = trimOws(self.value[start..comma]);
            if (item.len == 0) continue;

            const semi = std.mem.findScalar(u8, item, ';');
            const coding = trimOws(if (semi) |index| item[0..index] else item);
            if (coding.len == 0) continue;

            const q = if (semi) |index| qOf(item[index + 1 ..]) orelse 1000 else 1000;
            return .{ .coding = coding, .q = q };
        }
        return null;
    }
};

/// The `q` parameter's weight in thousandths, or null when it is absent. A
/// malformed weight is 0: the field said something, and it was not a valid
/// preference.
fn qOf(params: []const u8) ?u16 {
    var iterator = std.mem.splitScalar(u8, params, ';');
    while (iterator.next()) |raw| {
        const param = trimOws(raw);
        const equals = std.mem.findScalar(u8, param, '=') orelse continue;
        const name = trimOws(param[0..equals]);
        if (!eq(name, "q")) continue;
        return parseQ(param[equals + 1 ..]) orelse 0;
    }
    return null;
}

/// Parse a qvalue (RFC 9110 §12.4.2) into thousandths, or null when it is not
/// one. `0`, `0.5`, `1`, and `1.000` are valid; `1.5`, `0.0001`, and `abc`
/// are not.
fn parseQ(raw: []const u8) ?u16 {
    const value = trimOws(raw);
    if (value.len == 0) return null;
    if (value[0] != '0' and value[0] != '1') return null;

    var q: u16 = if (value[0] == '1') 1000 else 0;
    if (value.len == 1) return q;
    if (value[1] != '.') return null;

    var scale: u16 = 100;
    var index: usize = 2;
    while (index < value.len) : (index += 1) {
        const byte = value[index];
        if (byte < '0' or byte > '9') return null;
        if (index >= 5) return null; // more than three fractional digits
        q += @as(u16, byte - '0') * scale;
        scale /= 10;
    }
    if (value[0] == '1' and q != 1000) return null;
    return q;
}

fn trimOws(value: []const u8) []const u8 {
    var start: usize = 0;
    while (start < value.len and (value[start] == ' ' or value[start] == '\t')) start += 1;
    var end: usize = value.len;
    while (end > start and (value[end - 1] == ' ' or value[end - 1] == '\t')) end -= 1;
    return value[start..end];
}

fn eq(a: []const u8, b: []const u8) bool {
    return ascii.eqlIgnoreCase(a, b);
}

test "negotiate: the field, the weights, and the server order" {
    const Case = struct {
        header: ?[]const u8,
        supported: []const []const u8,
        want: ?[]const u8,
    };
    const cases = [_]Case{
        // Absent and empty fields fall back to identity.
        .{ .header = null, .supported = &.{ "br", "gzip" }, .want = identity },
        .{ .header = "", .supported = &.{ "br", "gzip" }, .want = identity },
        // A named coding with no weight is fully acceptable.
        .{ .header = "gzip", .supported = &.{ "br", "gzip" }, .want = "gzip" },
        .{ .header = "br", .supported = &.{ "br", "gzip" }, .want = "br" },
        // Ties follow the server's preference order.
        .{ .header = "gzip, br", .supported = &.{ "br", "gzip" }, .want = "br" },
        .{ .header = "gzip;q=0.9, br;q=0.9", .supported = &.{ "br", "gzip" }, .want = "br" },
        // A higher weight wins over the server's order.
        .{ .header = "gzip;q=1, br;q=0.5", .supported = &.{ "br", "gzip" }, .want = "gzip" },
        .{ .header = "gzip;q=0.5, br;q=1", .supported = &.{ "br", "gzip" }, .want = "br" },
        // q=0 is not acceptable; identity is the fallback.
        .{ .header = "gzip;q=0", .supported = &.{"gzip"}, .want = identity },
        .{ .header = "gzip;q=0, br;q=0", .supported = &.{ "br", "gzip" }, .want = identity },
        .{ .header = "gzip;q=0, br;q=0, identity;q=0", .supported = &.{ "br", "gzip" }, .want = null },
        // The wildcard covers codings not named, including identity's
        // exclusion at q=0.
        .{ .header = "*", .supported = &.{ "br", "gzip" }, .want = "br" },
        .{ .header = "*;q=0", .supported = &.{ "br", "gzip" }, .want = null },
        .{ .header = "*;q=0, gzip;q=0.5", .supported = &.{ "br", "gzip" }, .want = "gzip" },
        .{ .header = "*;q=0, identity;q=1", .supported = &.{ "br", "gzip" }, .want = identity },
        // An explicit identity weight competes; on a tie the coding wins.
        .{ .header = "identity;q=0.5, gzip;q=0.4", .supported = &.{"gzip"}, .want = identity },
        .{ .header = "identity;q=0.5, gzip;q=0.5", .supported = &.{"gzip"}, .want = "gzip" },
        .{ .header = "gzip;q=0.5, identity;q=0", .supported = &.{"gzip"}, .want = "gzip" },
        // Malformed weights are 0; the first entry for a coding wins.
        .{ .header = "gzip;q=abc", .supported = &.{"gzip"}, .want = identity },
        .{ .header = "gzip;q=1.5", .supported = &.{"gzip"}, .want = identity },
        .{ .header = "gzip;q=0.0001", .supported = &.{"gzip"}, .want = identity },
        .{ .header = "gzip;q=0.1234", .supported = &.{"gzip"}, .want = identity },
        .{ .header = "gzip;q=0.123", .supported = &.{"gzip"}, .want = "gzip" },
        .{ .header = "gzip;q=0, gzip;q=1", .supported = &.{"gzip"}, .want = identity },
        // Tokens and parameter names are case-insensitive; OWS is ignored.
        .{ .header = "GZIP;Q=0.8, Br;q=0.9", .supported = &.{ "br", "gzip" }, .want = "br" },
        .{ .header = " gzip ; q = 0.8 , br ; q = 1 ", .supported = &.{ "br", "gzip" }, .want = "br" },
        // The token is the caller's: aliases and the deflate mapping live there.
        .{ .header = "deflate", .supported = &.{"deflate"}, .want = "deflate" },
        .{ .header = "x-gzip", .supported = &.{"gzip"}, .want = identity },
        // No supported coding: identity is still the default.
        .{ .header = "gzip", .supported = &.{}, .want = identity },
        .{ .header = "identity;q=0", .supported = &.{}, .want = null },
    };

    for (cases) |case| {
        const got = negotiate(case.header, case.supported);
        if (case.want) |want| {
            try testing.expect(got != null);
            try testing.expectEqualStrings(want, got.?);
        } else {
            try testing.expect(got == null);
        }
    }
}

test "negotiate: the empty list pieces and odd separators" {
    try testing.expectEqualStrings(identity, negotiate(",", &.{"gzip"}).?);
    try testing.expectEqualStrings(identity, negotiate(",,,", &.{"gzip"}).?);
    try testing.expectEqualStrings("gzip", negotiate("gzip;", &.{"gzip"}).?);
    try testing.expectEqualStrings("gzip", negotiate("gzip;q", &.{"gzip"}).?);
    try testing.expectEqualStrings("gzip", negotiate("gzip;;q=0.5", &.{"gzip"}).?);
    try testing.expectEqualStrings("gzip", negotiate("gzip;q=0.5;", &.{"gzip"}).?);
}

test "negotiate: the scale's boundaries" {
    // 0, 0.5, 1, and 1.000 are valid.
    try testing.expectEqualStrings("gzip", negotiate("gzip;q=0.001", &.{"gzip"}).?);
    try testing.expectEqualStrings(identity, negotiate("gzip;q=0.000", &.{"gzip"}).?);
    try testing.expectEqualStrings("gzip", negotiate("gzip;q=1.000", &.{"gzip"}).?);
    try testing.expectEqualStrings(identity, negotiate("gzip;q=1.001", &.{"gzip"}).?);
    try testing.expectEqualStrings(identity, negotiate("gzip;q=0.", &.{"gzip"}).?);
    try testing.expectEqualStrings("gzip", negotiate("gzip;q=1.", &.{"gzip"}).?);
}
