//! `Transfer-Encoding` parsing (RFC 9110 §10.1.4, RFC 9112 §6.1).
//!
//! The field is `#transfer-coding`, where
//! `transfer-coding = token *( OWS ";" OWS transfer-parameter )` and
//! `transfer-parameter = token BWS "=" BWS ( token / quoted-string )`.
//! Field lines combine in order.
//!
//! `chunked` takes no parameters and must appear once (RFC 9112 §7.1). It has
//! to be the final coding for a request; a response with a non-final chunked
//! coding is close-delimited, so the framing decision belongs to the caller.
//! `Summary.seen_chunked` and `Summary.chunked_last` expose both facts.

const std = @import("std");
const ascii = std.ascii;
const testing = std.testing;

const Header = @import("header.zig").Header;
const Headers = @import("header.zig").Headers;
const ows = @import("ows.zig");

pub const Coding = struct {
    /// The coding token, borrowed from the field value.
    name: []const u8,
    /// Whether the coding carries at least one parameter.
    has_parameters: bool,
};

pub const Summary = struct {
    /// Whether at least one `Transfer-Encoding` field line is present.
    present: bool,
    /// The final coding, or null when the field is absent or carries no
    /// coding.
    last: ?Coding,
    /// Whether a `chunked` coding appeared anywhere in the list.
    seen_chunked: bool,
    /// Whether the final coding is `chunked`.
    chunked_last: bool,
};

pub const Error = error{
    Invalid,
    ChunkedDuplicate,
    ChunkedParameters,
};

pub fn summarize(headers: Headers) Error!Summary {
    var iterator: Iterator = .init(headers);
    var last: ?Coding = null;
    while (try iterator.next()) |coding| last = coding;

    return .{
        .present = iterator.present,
        .last = last,
        .seen_chunked = iterator.seen_chunked,
        .chunked_last = if (last) |coding|
            ascii.eqlIgnoreCase(coding.name, "chunked")
        else
            false,
    };
}

/// A borrowed iterator over every coding, in field order. Empty list elements
/// are skipped. It enforces the `chunked` rules that apply wherever the field
/// appears: no parameters and no repetition.
pub const Iterator = struct {
    headers: Headers,
    header_index: u32,
    line: []const u8,
    pos: usize,
    present: bool,
    seen_chunked: bool,

    pub fn init(headers: Headers) Iterator {
        return .{
            .headers = headers,
            .header_index = 0,
            .line = "",
            .pos = 0,
            .present = false,
            .seen_chunked = false,
        };
    }

    pub fn next(self: *Iterator) Error!?Coding {
        while (true) {
            if (self.pos < self.line.len) {
                if (try self.nextCoding()) |coding| return coding;
            }
            if (!self.advanceLine()) return null;
        }
    }

    fn advanceLine(self: *Iterator) bool {
        while (@as(usize, self.header_index) < self.headers.items.len) {
            const header = self.headers.items[@intCast(self.header_index)];
            self.header_index += 1;
            if (!ascii.eqlIgnoreCase(header.name, "Transfer-Encoding")) continue;

            self.present = true;
            self.line = ows.trim(header.value);
            self.pos = 0;
            return true;
        }
        return false;
    }

    fn nextCoding(self: *Iterator) Error!?Coding {
        // Skip OWS and empty list elements.
        while (self.pos < self.line.len) {
            const byte = self.line[self.pos];
            if (byte == ',' or byte == ' ' or byte == '\t') {
                self.pos += 1;
                continue;
            }
            break;
        }
        if (self.pos == self.line.len) return null;

        const start = self.pos;
        if (!isTchar(self.line[self.pos])) return error.Invalid;
        self.pos += 1;
        while (self.pos < self.line.len and isTchar(self.line[self.pos])) self.pos += 1;
        const name = self.line[start..self.pos];

        var has_parameters = false;
        while (true) {
            self.skipOws();
            if (self.pos == self.line.len) break;
            switch (self.line[self.pos]) {
                ';' => {
                    self.pos += 1;
                    has_parameters = true;
                    try self.parseParameter();
                },
                ',' => {
                    self.pos += 1;
                    break;
                },
                else => return error.Invalid,
            }
        }

        if (ascii.eqlIgnoreCase(name, "chunked")) {
            if (has_parameters) return error.ChunkedParameters;
            if (self.seen_chunked) return error.ChunkedDuplicate;
            self.seen_chunked = true;
        }
        return .{ .name = name, .has_parameters = has_parameters };
    }

    fn skipOws(self: *Iterator) void {
        while (self.pos < self.line.len) {
            const byte = self.line[self.pos];
            if (byte != ' ' and byte != '\t') break;
            self.pos += 1;
        }
    }

    fn parseParameter(self: *Iterator) Error!void {
        self.skipOws();
        if (self.pos == self.line.len or !isTchar(self.line[self.pos])) return error.Invalid;
        self.pos += 1;
        while (self.pos < self.line.len and isTchar(self.line[self.pos])) self.pos += 1;

        self.skipOws();
        if (self.pos == self.line.len or self.line[self.pos] != '=') return error.Invalid;
        self.pos += 1;
        self.skipOws();
        if (self.pos == self.line.len) return error.Invalid;

        if (self.line[self.pos] == '"') {
            try self.skipQuotedString();
        } else if (isTchar(self.line[self.pos])) {
            self.pos += 1;
            while (self.pos < self.line.len and isTchar(self.line[self.pos])) self.pos += 1;
        } else {
            return error.Invalid;
        }
    }

    fn skipQuotedString(self: *Iterator) Error!void {
        if (self.pos == self.line.len or self.line[self.pos] != '"') return error.Invalid;
        self.pos += 1;

        while (self.pos < self.line.len) {
            const byte = self.line[self.pos];
            if (byte == '"') {
                self.pos += 1;
                return;
            }
            if (byte == '\\') {
                self.pos += 1;
                if (self.pos == self.line.len) return error.Invalid;
                if (!isQuotedPair(self.line[self.pos])) return error.Invalid;
                self.pos += 1;
                continue;
            }
            if (!isQdtext(byte)) return error.Invalid;
            self.pos += 1;
        }
        return error.Invalid;
    }
};

/// RFC 9110 §5.6.2.
fn isTchar(byte: u8) bool {
    return switch (byte) {
        '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => true,
        '0'...'9', 'A'...'Z', 'a'...'z' => true,
        else => false,
    };
}

/// RFC 9110 §5.6.4: `qdtext = HTAB / SP / %x21 / %x23-5B / %x5D-7E / obs-text`.
fn isQdtext(byte: u8) bool {
    return byte == '\t' or
        byte == ' ' or
        byte == '!' or
        (byte >= '#' and byte <= '[') or
        (byte >= ']' and byte <= '~') or
        byte >= 0x80;
}

/// RFC 9110 §5.6.4: `quoted-pair = "\" ( HTAB / SP / VCHAR / obs-text )`.
fn isQuotedPair(byte: u8) bool {
    return byte == '\t' or byte == ' ' or (byte >= 0x21 and byte <= 0x7e) or byte >= 0x80;
}

test "summarize: chunked is last" {
    const headers: Headers = .{ .items = &.{
        .{ .name = "Transfer-Encoding", .value = "gzip, chunked" },
    } };
    const summary = try summarize(headers);

    try testing.expect(summary.present);
    try testing.expect(summary.seen_chunked);
    try testing.expect(summary.chunked_last);
    if (summary.last) |coding| {
        try testing.expectEqualStrings("chunked", coding.name);
        try testing.expect(!coding.has_parameters);
    } else {
        return error.TestUnexpectedResult;
    }
}

test "summarize: field lines combine in order" {
    const headers: Headers = .{ .items = &.{
        .{ .name = "Transfer-Encoding", .value = "gzip" },
        .{ .name = "X-Other", .value = "chunked" },
        .{ .name = "transfer-encoding", .value = "chunked" },
    } };
    const summary = try summarize(headers);

    try testing.expect(summary.present);
    try testing.expect(summary.chunked_last);
    try testing.expectEqualStrings("chunked", summary.last.?.name);
}

test "summarize: chunked not last is a response framing choice" {
    const headers: Headers = .{ .items = &.{
        .{ .name = "Transfer-Encoding", .value = "chunked, gzip" },
    } };
    const summary = try summarize(headers);

    try testing.expect(summary.seen_chunked);
    try testing.expect(!summary.chunked_last);
    try testing.expectEqualStrings("gzip", summary.last.?.name);
}

test "summarize: chunked appears once" {
    const headers: Headers = .{ .items = &.{
        .{ .name = "Transfer-Encoding", .value = "chunked, chunked" },
    } };
    try testing.expectError(error.ChunkedDuplicate, summarize(headers));
}

test "summarize: chunked takes no parameters" {
    const headers: Headers = .{ .items = &.{
        .{ .name = "Transfer-Encoding", .value = "chunked;level=1" },
    } };
    try testing.expectError(error.ChunkedParameters, summarize(headers));
}

test "summarize: parameters and quoted values" {
    const headers: Headers = .{ .items = &.{
        .{ .name = "Transfer-Encoding", .value = "gzip; level = \"1, 2\";q=\"a\\\"b\"" },
    } };
    const summary = try summarize(headers);

    try testing.expectEqualStrings("gzip", summary.last.?.name);
    try testing.expect(summary.last.?.has_parameters);
    try testing.expect(!summary.chunked_last);
}

test "summarize: empty field is present with no coding" {
    const headers: Headers = .{ .items = &.{
        .{ .name = "Transfer-Encoding", .value = "" },
    } };
    const summary = try summarize(headers);

    try testing.expect(summary.present);
    try testing.expect(summary.last == null);
    try testing.expect(!summary.chunked_last);
}

test "summarize: other fields do not count" {
    const headers: Headers = .{ .items = &.{
        .{ .name = "TE", .value = "chunked" },
        .{ .name = "X-Transfer-Encoding", .value = "chunked" },
    } };
    const summary = try summarize(headers);

    try testing.expect(!summary.present);
    try testing.expect(summary.last == null);
}

test "summarize: malformed lists" {
    const values = [_][]const u8{
        "gzip;",
        "gzip;level",
        "gzip;=1",
        "gzip;level=",
        "gzip chunked",
        "gzip;level=1 chunked",
        "gzip;level=\"unterminated",
        "gzip;level=\"bad\\",
    };
    for (values) |value| {
        const headers: Headers = .{ .items = &.{
            .{ .name = "Transfer-Encoding", .value = value },
        } };
        try testing.expectError(error.Invalid, summarize(headers));
    }
}

test "fuzz transfer encoding" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) anyerror!void {
            var buf: [128]u8 = undefined;
            const value = buf[0..smith.slice(&buf)];
            const headers: Headers = .{ .items = &.{
                .{ .name = "Transfer-Encoding", .value = value },
            } };

            const summary = summarize(headers) catch return;
            if (summary.last) |coding| {
                try testing.expect(within(value, coding.name));
                try testing.expect(coding.name.len != 0);
            }
        }
    }.run, .{
        .corpus = &.{
            "",
            "chunked",
            "gzip, chunked",
            "gzip;q=1",
            "chunked;x=1",
            "chunked, gzip",
        },
    });
}

fn within(outer: []const u8, inner: []const u8) bool {
    const base = @intFromPtr(outer.ptr);
    const start = @intFromPtr(inner.ptr);
    return start >= base and start + inner.len <= base + outer.len;
}
