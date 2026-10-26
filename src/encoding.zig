//! `Accept-Encoding` parsing and content-coding negotiation.
//!
//! `negotiate(header, supported)` takes one field value and the server's
//! supported codings in preference order. `negotiateFields` takes every field
//! line with that name, because multiple lines combine as one ordered list
//! (RFC 9110 §5.3). Both return a token borrowed from `supported`, the static
//! `identity`, or `null` when the client accepts nothing else. They allocate
//! nothing.
//!
//! Rules (RFC 9110 §12.5.3):
//! - A coding's weight is its `q` parameter, 0..1 with at most three fractional
//!   digits; no parameter means 1. `q=0` is not acceptable.
//! - `*` gives a weight to every coding not named explicitly.
//! - `identity` is acceptable by default. It is excluded by `identity;q=0`, or
//!   by `*;q=0` when there is no explicit identity entry.
//! - An empty field lists no codings and negotiates to `identity`. An absent
//!   field is the caller's policy: pass `""` for the conservative default, or
//!   `"*"` to treat every supported coding as acceptable.
//! - A malformed weight is 0, and the first entry for a coding wins.
//! - Ties go to the server's order in `supported`; an explicit identity
//!   weight only wins when it is higher than the best coding's.

const std = @import("std");
const ascii = std.ascii;
const testing = std.testing;
const mem = std.mem;
const fmt = std.fmt;

const ows = @import("ows.zig");

/// The token for "no content coding". It is not looked up in `supported`.
pub const identity = "identity";

/// The chosen content coding, or `null` when nothing is acceptable.
///
/// `supported` lists the content codings the server can produce, most
/// preferred first. It must not contain `identity`; that token is handled
/// here. The returned slice is either one of `supported`'s elements or
/// `identity`.
pub fn negotiate(header: []const u8, supported: []const []const u8) ?[]const u8 {
    return negotiateFields(&.{header}, supported);
}

/// Like `negotiate`, over every field line named `Accept-Encoding`.
///
/// The lines combine as if they were one comma-separated list, in order
/// (RFC 9110 §5.3). A coding named on two lines therefore takes the weight of
/// its first appearance.
pub fn negotiateFields(fields: []const []const u8, supported: []const []const u8) ?[]const u8 {
    // The common case parses each field entry once. Servers do not offer
    // dozens of codings; past the bound, fall back to rescanning per coding.
    if (supported.len > max_tracked) return negotiateRescan(fields, supported);

    var first_q: [max_tracked]?u16 = @splat(null);
    var wildcard_q: ?u16 = null;
    var identity_q: ?u16 = null;

    var entries: AllEntries = .{ .fields = fields };
    while (entries.next()) |entry| {
        if (mem.eql(u8, entry.coding, "*")) {
            if (wildcard_q == null) wildcard_q = entry.q;
        } else if (ascii.eqlIgnoreCase(entry.coding, identity)) {
            if (identity_q == null) identity_q = entry.q;
        }
        for (supported, 0..) |coding, index| {
            if (first_q[index] == null and ascii.eqlIgnoreCase(entry.coding, coding)) {
                first_q[index] = entry.q;
                break;
            }
        }
    }
    return choose(supported, first_q[0..supported.len], wildcard_q, identity_q);
}

/// Upper bound on the codings the single-pass path tracks. A server listing
/// more than this still negotiates, one rescan per coding.
const max_tracked = 32;

/// One rescan per coding: the fallback for an unusually long `supported`.
fn negotiateRescan(fields: []const []const u8, supported: []const []const u8) ?[]const u8 {
    var wildcard_q: ?u16 = null;
    var identity_q: ?u16 = null;
    var entries: AllEntries = .{ .fields = fields };
    while (entries.next()) |entry| {
        if (mem.eql(u8, entry.coding, "*")) {
            if (wildcard_q == null) wildcard_q = entry.q;
        } else if (ascii.eqlIgnoreCase(entry.coding, identity)) {
            if (identity_q == null) identity_q = entry.q;
        }
    }

    var best: ?[]const u8 = null;
    var best_q: u16 = 0;
    for (supported) |coding| {
        if (ascii.eqlIgnoreCase(coding, identity)) continue;
        const q = firstQ(fields, coding) orelse wildcard_q orelse 0;
        if (q > best_q) {
            best = coding;
            best_q = q;
        }
    }

    return finish(best, best_q, wildcard_q, identity_q);
}

fn choose(
    supported: []const []const u8,
    first_q: []const ?u16,
    wildcard_q: ?u16,
    identity_q: ?u16,
) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_q: u16 = 0;
    for (supported, first_q) |coding, q| {
        if (ascii.eqlIgnoreCase(coding, identity)) continue;
        const weight = q orelse wildcard_q orelse 0;
        if (weight > best_q) {
            best = coding;
            best_q = weight;
        }
    }
    return finish(best, best_q, wildcard_q, identity_q);
}

fn finish(best: ?[]const u8, best_q: u16, wildcard_q: ?u16, identity_q: ?u16) ?[]const u8 {
    if (best_q == 0) {
        return if (identityAllowed(wildcard_q, identity_q)) identity else null;
    }
    if (identity_q) |q| {
        if (q > best_q) return identity;
    }
    return best;
}

/// The first explicit weight for `coding`, or null when no field line names
/// it.
fn firstQ(fields: []const []const u8, coding: []const u8) ?u16 {
    var entries: AllEntries = .{ .fields = fields };
    while (entries.next()) |entry| {
        if (ascii.eqlIgnoreCase(entry.coding, coding)) return entry.q;
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

/// Every entry across every field line, in order.
const AllEntries = struct {
    fields: []const []const u8,
    field_index: u32 = 0,
    entries: Entries = .{ .value = "" },

    fn next(self: *AllEntries) ?Entry {
        while (true) {
            if (self.entries.next()) |entry| return entry;
            if (@as(usize, self.field_index) == self.fields.len) return null;
            self.entries = .{ .value = self.fields[@intCast(self.field_index)] };
            self.field_index += 1;
        }
    }
};

/// A one-pass iterator over the comma-separated entries. Each coding is a
/// borrowed slice; weights are in thousandths.
const Entries = struct {
    value: []const u8,
    pos: u32 = 0,

    fn next(self: *Entries) ?Entry {
        while (@as(usize, self.pos) <= self.value.len) {
            const start = self.pos;
            var end = start;
            var semi: ?u32 = null;
            while (@as(usize, end) < self.value.len and
                self.value[@intCast(end)] != ',') : (end += 1)
            {
                if (semi == null and self.value[@intCast(end)] == ';') semi = end;
            }
            self.pos = end + 1;

            const span = if (semi) |index|
                self.value[@intCast(start)..@intCast(index)]
            else
                self.value[@intCast(start)..@intCast(end)];
            const coding = ows.trim(span);
            if (coding.len == 0) continue;

            const q = if (semi) |index|
                qOf(self.value[@intCast(index + 1)..@intCast(end)]) orelse 1000
            else
                1000;
            return .{ .coding = coding, .q = q };
        }
        return null;
    }
};

/// The `q` parameter's weight in thousandths, or null when it is absent. A
/// malformed weight is 0: the field said something, and it was not a valid
/// preference.
fn qOf(params: []const u8) ?u16 {
    var iterator = mem.splitScalar(u8, params, ';');
    while (iterator.next()) |raw| {
        const param = ows.trim(raw);
        const equals = mem.findScalar(u8, param, '=') orelse continue;
        const name = ows.trim(param[0..equals]);
        if (!ascii.eqlIgnoreCase(name, "q")) continue;
        return parseQ(param[equals + 1 ..]) orelse 0;
    }
    return null;
}

/// Parse a qvalue (RFC 9110 §12.4.2) into thousandths, or null when it is not
/// one. `0`, `0.5`, `1`, and `1.000` are valid; `1.5`, `0.0001`, and `abc`
/// are not.
fn parseQ(raw: []const u8) ?u16 {
    const value = ows.trim(raw);
    if (value.len == 0) return null;
    if (value[0] != '0' and value[0] != '1') return null;

    var q: u16 = if (value[0] == '1') 1000 else 0;
    if (value.len == 1) return q;
    if (value[1] != '.') return null;

    var scale: u16 = 100;
    var index: u32 = 2;
    while (@as(usize, index) < value.len) : (index += 1) {
        const byte = value[@intCast(index)];
        if (byte < '0' or byte > '9') return null;
        if (index >= 5) return null; // more than three fractional digits
        q += @as(u16, byte - '0') * scale;
        scale /= 10;
    }
    if (value[0] == '1' and q != 1000) return null;
    return q;
}

test "negotiate: the field, the weights, and the server order" {
    const Case = struct {
        header: []const u8,
        supported: []const []const u8,
        want: ?[]const u8,
    };
    const cases = [_]Case{
        // An empty field lists no codings and falls back to identity.
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
        .{
            .header = "gzip;q=0, br;q=0, identity;q=0",
            .supported = &.{ "br", "gzip" },
            .want = null,
        },
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
        .{
            .header = " gzip ; q = 0.8 , br ; q = 1 ",
            .supported = &.{ "br", "gzip" },
            .want = "br",
        },
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

        // One line through the general entry point must agree.
        const many = negotiateFields(&.{case.header}, case.supported);
        if (got) |token| {
            try testing.expect(many != null);
            try testing.expectEqualStrings(token, many.?);
        } else {
            try testing.expect(many == null);
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

test "negotiateFields: lines combine as one ordered list" {
    const Case = struct {
        fields: []const []const u8,
        supported: []const []const u8,
        want: ?[]const u8,
    };
    const cases = [_]Case{
        // No field lines at all: the conservative default.
        .{ .fields = &.{}, .supported = &.{"gzip"}, .want = identity },
        .{ .fields = &.{ "", "" }, .supported = &.{"gzip"}, .want = identity },
        // Ties still follow the server's order.
        .{ .fields = &.{ "br", "gzip" }, .supported = &.{ "br", "gzip" }, .want = "br" },
        .{ .fields = &.{ "gzip", "br" }, .supported = &.{ "br", "gzip" }, .want = "br" },
        // A weight on a later line competes normally.
        .{
            .fields = &.{ "gzip;q=0.5", "br;q=0.9" },
            .supported = &.{ "br", "gzip" },
            .want = "br",
        },
        // The first appearance of a coding wins, across lines.
        .{ .fields = &.{ "gzip;q=0", "gzip;q=1" }, .supported = &.{"gzip"}, .want = identity },
        .{ .fields = &.{ "gzip;q=1", "gzip;q=0" }, .supported = &.{"gzip"}, .want = "gzip" },
        // Wildcard and identity may arrive on different lines.
        .{ .fields = &.{ "*;q=0", "identity;q=1" }, .supported = &.{"gzip"}, .want = identity },
        .{ .fields = &.{ "*;q=0", "gzip;q=0.5" }, .supported = &.{ "br", "gzip" }, .want = "gzip" },
        .{ .fields = &.{ "gzip;q=0", "identity;q=0" }, .supported = &.{"gzip"}, .want = null },
    };

    for (cases) |case| {
        const got = negotiateFields(case.fields, case.supported);
        if (case.want) |want| {
            try testing.expect(got != null);
            try testing.expectEqualStrings(want, got.?);
        } else {
            try testing.expect(got == null);
        }
    }
}

/// The qvalue ABNF, written out: no more than three fractional digits, and
/// a `1` may only be followed by zeros.
fn referenceQ(raw: []const u8) ?u16 {
    const value = mem.trim(u8, raw, " \t");
    if (value.len == 0) return null;

    if (value[0] == '0') {
        if (value.len == 1) return 0;
        if (value[1] != '.') return null;
        const digits = value[2..];
        if (digits.len > 3) return null;
        var q: u16 = 0;
        var scale: u16 = 100;
        for (digits) |byte| {
            if (byte < '0' or byte > '9') return null;
            q += @as(u16, byte - '0') * scale;
            scale /= 10;
        }
        return q;
    }
    if (value[0] == '1') {
        if (value.len == 1) return 1000;
        if (value[1] != '.') return null;
        const digits = value[2..];
        if (digits.len > 3) return null;
        for (digits) |byte| if (byte != '0') return null;
        return 1000;
    }
    return null;
}

test "parseQ: every short string over a tiny alphabet agrees with the ABNF" {
    const alphabet = "01.9a ";
    var buf: [5]u8 = undefined;
    for (1..buf.len + 1) |len| {
        var code: usize = 0;
        var total: usize = 1;
        for (0..len) |_| total *= alphabet.len;
        while (code < total) : (code += 1) {
            var rest = code;
            for (0..len) |i| {
                buf[i] = alphabet[rest % alphabet.len];
                rest /= alphabet.len;
            }
            try testing.expectEqual(referenceQ(buf[0..len]), parseQ(buf[0..len]));
        }
    }
}

test "fuzz accept-encoding" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) anyerror!void {
            var buf: [128]u8 = undefined;
            const field = buf[0..smith.slice(&buf)];

            const result = negotiate(field, &.{ "br", "gzip", "zstd" });
            if (result) |token| {
                const known = mem.eql(u8, token, "br") or
                    mem.eql(u8, token, "gzip") or
                    mem.eql(u8, token, "zstd") or
                    mem.eql(u8, token, identity);
                try testing.expect(known);
            }

            // Splitting a field at a comma cannot change the ordered entries.
            if (mem.findScalar(u8, field, ',')) |at| {
                const one = negotiate(field, &.{"gzip"});
                const two = negotiateFields(&.{ field[0..at], field[at + 1 ..] }, &.{"gzip"});
                if (one) |token| {
                    try testing.expect(two != null);
                    try testing.expectEqualStrings(token, two.?);
                } else {
                    try testing.expect(two == null);
                }
            }
        }
    }.run, .{
        .corpus = &.{
            "",
            "gzip",
            "gzip;q=0",
            "br, gzip",
            "*",
            "*;q=0",
            "identity;q=0, *;q=0",
            "gzip;q=0.0001",
            "gzip;q=abc",
        },
    });
}

test "negotiateFields: the rescan fallback past the tracked bound" {
    var names: [max_tracked + 8][4]u8 = undefined;
    var supported: [max_tracked + 8][]const u8 = undefined;
    for (&names, &supported, 0..) |*name, *coding, index| {
        coding.* = fmt.bufPrint(name, "x{d}", .{index}) catch unreachable;
    }
    supported[supported.len - 1] = "zstd";

    try testing.expectEqualStrings("zstd", negotiateFields(&.{"zstd"}, &supported).?);
    try testing.expectEqualStrings("x0", negotiateFields(&.{"x0"}, &supported).?);
    try testing.expectEqualStrings("x0", negotiateFields(&.{"x0;q=0.5, zstd;q=0.4"}, &supported).?);
    try testing.expectEqualStrings(identity, negotiateFields(&.{""}, &supported).?);
    try testing.expect(negotiateFields(&.{"identity;q=0"}, &supported) == null);
}
