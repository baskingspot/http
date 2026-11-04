//! The picohttpparser case table, ported with the deliberate divergences
//! marked. Reference: picohttpparser `test.c`.
//!
//! A case records our expected outcome, not pico's. Where the two differ, the
//! note says why; the choices are also in `docs/spec/h1.md`.

const std = @import("std");
const testing = std.testing;
const http = @import("http");

const Kind = enum { request, response, field_section };
const Outcome = enum { ok, invalid, incomplete };
const Slow = enum { no, previous_minus_one, one };

const HeadCase = struct {
    kind: Kind,
    input: []const u8,
    outcome: Outcome,
    last_len: Slow = .no,
    note: []const u8 = "",
};

const request_cases = [_]HeadCase{
    .{ .kind = .request, .input = "GET / HTTP/1.0\r\n\r\n", .outcome = .ok },
    .{ .kind = .request, .input = "GET / HTTP/1.0\r\n\r", .outcome = .incomplete },
    .{
        .kind = .request,
        .input = "GET /hoge HTTP/1.1\r\n" ++
            "Host: example.com\r\n" ++
            "Cookie: \r\n" ++
            "\r\n" ++
            "",
        .outcome = .ok,
    },
    .{
        .kind = .request,
        .input = "GET /hoge HTTP/1.1\r\n" ++
            "Host: example.com\r\n" ++
            "User-Agent: \xe3\x81\xb2\xe3/1.0\r\n" ++
            "\r\n" ++
            "",
        .outcome = .ok,
    },
    .{
        .kind = .request,
        .input = "GET / HTTP/1.0\r\n" ++
            "foo: \r\n" ++
            "foo: b\r\n" ++
            "  \tc\r\n" ++
            "\r\n" ++
            "",
        .outcome = .invalid,
        .note = "pico unfolds obs-fold; we reject",
    },
    .{ .kind = .request, .input = "GET / HTTP/1.0\r\nfoo : ab\r\n\r\n", .outcome = .invalid },
    .{ .kind = .request, .input = "GET", .outcome = .incomplete },
    .{ .kind = .request, .input = "GET ", .outcome = .incomplete },
    .{ .kind = .request, .input = "GET /", .outcome = .incomplete },
    .{ .kind = .request, .input = "GET / ", .outcome = .incomplete },
    .{ .kind = .request, .input = "GET / H", .outcome = .incomplete },
    .{ .kind = .request, .input = "GET / HTTP/1.", .outcome = .incomplete },
    .{ .kind = .request, .input = "GET / HTTP/1.0", .outcome = .incomplete },
    .{ .kind = .request, .input = "GET / HTTP/1.0\r", .outcome = .incomplete },
    .{
        .kind = .request,
        .input = "GET /hoge HTTP/1.0\r\n" ++
            "\r",
        .outcome = .incomplete,
        .last_len = .previous_minus_one,
    },
    .{
        .kind = .request,
        .input = "GET /hoge HTTP/1.0\r\n" ++
            "\r\n" ++
            "",
        .outcome = .ok,
        .last_len = .previous_minus_one,
    },
    .{ .kind = .request, .input = " / HTTP/1.0\r\n\r\n", .outcome = .invalid },
    .{ .kind = .request, .input = "GET  HTTP/1.0\r\n\r\n", .outcome = .invalid },
    .{ .kind = .request, .input = "GET / HTTP/1.0\r\n:a\r\n\r\n", .outcome = .invalid },
    .{ .kind = .request, .input = "GET / HTTP/1.0\r\n :a\r\n\r\n", .outcome = .invalid },
    .{ .kind = .request, .input = "G\x00T / HTTP/1.0\r\n\r\n", .outcome = .invalid },
    .{ .kind = .request, .input = "G\tT / HTTP/1.0\r\n\r\n", .outcome = .invalid },
    .{ .kind = .request, .input = ":GET / HTTP/1.0\r\n\r\n", .outcome = .invalid },
    .{ .kind = .request, .input = "GET /\x7fhello HTTP/1.0\r\n\r\n", .outcome = .invalid },
    .{ .kind = .request, .input = "GET / HTTP/1.0\r\na\x00b: c\r\n\r\n", .outcome = .invalid },
    .{ .kind = .request, .input = "GET / HTTP/1.0\r\nab: c\x00d\r\n\r\n", .outcome = .invalid },
    .{ .kind = .request, .input = "GET / HTTP/1.0\r\na\x1bb: c\r\n\r\n", .outcome = .invalid },
    .{ .kind = .request, .input = "GET / HTTP/1.0\r\nab: c\x1b\r\n\r\n", .outcome = .invalid },
    .{ .kind = .request, .input = "GET / HTTP/1.0\r\n/: 1\r\n\r\n", .outcome = .invalid },
    .{
        .kind = .request,
        .input = "GET /\xa0 HTTP/1.0\r\n" ++
            "h: c\xa2y\r\n" ++
            "\r\n" ++
            "",
        .outcome = .invalid,
        .note = "pico accepts MSB in the target; we reject",
    },
    .{ .kind = .request, .input = "GET / HTTP/1.0\r\n|~: 1\r\n\r\n", .outcome = .ok },
    .{ .kind = .request, .input = "GET / HTTP/1.0\r\n{: 1\r\n\r\n", .outcome = .invalid },
    .{ .kind = .request, .input = "GET / HTTP/1.0\r\nfoo: a \t \r\n\r\n", .outcome = .ok },
    .{
        .kind = .request,
        .input = "GET   /   HTTP/1.0\r\n" ++
            "\r\n" ++
            "",
        .outcome = .invalid,
        .note = "pico accepts multiple spaces; we require one",
    },
};

const response_cases = [_]HeadCase{
    .{ .kind = .response, .input = "HTTP/1.0 200 OK\r\n\r\n", .outcome = .ok },
    .{ .kind = .response, .input = "HTTP/1.0 200 OK\r\n\r", .outcome = .incomplete },
    .{
        .kind = .response,
        .input = "HTTP/1.1 200 OK\r\n" ++
            "Host: example.com\r\n" ++
            "Cookie: \r\n" ++
            "\r\n" ++
            "",
        .outcome = .ok,
    },
    .{
        .kind = .response,
        .input = "HTTP/1.0 200 OK\r\n" ++
            "foo: \r\n" ++
            "foo: b\r\n" ++
            "  \tc\r\n" ++
            "\r\n" ++
            "",
        .outcome = .invalid,
        .note = "pico unfolds obs-fold; we reject",
    },
    .{ .kind = .response, .input = "HTTP/1.0 500 Internal Server Error\r\n\r\n", .outcome = .ok },
    .{ .kind = .response, .input = "H", .outcome = .incomplete },
    .{ .kind = .response, .input = "HTTP/1.", .outcome = .incomplete },
    .{ .kind = .response, .input = "HTTP/1.1", .outcome = .incomplete },
    .{ .kind = .response, .input = "HTTP/1.1 ", .outcome = .incomplete },
    .{ .kind = .response, .input = "HTTP/1.1 2", .outcome = .incomplete },
    .{ .kind = .response, .input = "HTTP/1.1 200", .outcome = .incomplete },
    .{ .kind = .response, .input = "HTTP/1.1 200 ", .outcome = .incomplete },
    .{ .kind = .response, .input = "HTTP/1.1 200 O", .outcome = .incomplete },
    .{ .kind = .response, .input = "HTTP/1.1 200 OK\r", .outcome = .incomplete },
    .{ .kind = .response, .input = "HTTP/1.1 200 OK\r\n", .outcome = .incomplete },
    .{
        .kind = .response,
        .input = "HTTP/1.1 200 OK\n",
        .outcome = .invalid,
        .note = "pico waits for more; a bare LF is invalid here",
    },
    .{ .kind = .response, .input = "HTTP/1.1 200 OK\r\nA: 1\r", .outcome = .incomplete },
    .{ .kind = .response, .input = "HTTP/1.1 200 OK\r\nA: 1\r\n", .outcome = .incomplete },
    .{
        .kind = .response,
        .input = "HTTP/1.0 200 OK\r\n" ++
            "\r",
        .outcome = .incomplete,
        .last_len = .previous_minus_one,
    },
    .{
        .kind = .response,
        .input = "HTTP/1.0 200 OK\r\n" ++
            "\r\n" ++
            "",
        .outcome = .ok,
        .last_len = .previous_minus_one,
    },
    .{ .kind = .response, .input = "HTTP/1. 200 OK\r\n\r\n", .outcome = .invalid },
    .{ .kind = .response, .input = "HTTP/1.2z 200 OK\r\n\r\n", .outcome = .invalid },
    .{ .kind = .response, .input = "HTTP/1.1  OK\r\n\r\n", .outcome = .invalid },
    .{
        .kind = .response,
        .input = "HTTP/1.1 099 OK\r\n" ++
            "\r\n" ++
            "",
        .outcome = .ok,
        .note = "pico rejects <100; we return the digits and leave the range rule to the caller",
    },
    .{
        .kind = .response,
        .input = "HTTP/1.1 600 OK\r\n" ++
            "\r\n" ++
            "",
        .outcome = .ok,
        .note = "pico rejects >599; we return the digits and leave the range rule to the caller",
    },
    .{ .kind = .response, .input = "HTTP/1.1 100 OK\r\n\r\n", .outcome = .ok },
    .{ .kind = .response, .input = "HTTP/1.1 599 OK\r\n\r\n", .outcome = .ok },
    .{
        .kind = .response,
        .input = "HTTP/1.1 200\r\n" ++
            "\r\n" ++
            "",
        .outcome = .invalid,
        .note = "pico accepts a missing second SP; RFC 9112 §4 requires it",
    },
    .{ .kind = .response, .input = "HTTP/1.1 200X\r\n\r\n", .outcome = .invalid },
    .{ .kind = .response, .input = "HTTP/1.1 200X \r\n\r\n", .outcome = .invalid },
    .{ .kind = .response, .input = "HTTP/1.1 200X OK\r\n\r\n", .outcome = .invalid },
    .{ .kind = .response, .input = "HTTP/1.1 200 OK\r\nbar: \t b\t \t\r\n\r\n", .outcome = .ok },
    .{
        .kind = .response,
        .input = "HTTP/1.1   200   OK\r\n" ++
            "\r\n" ++
            "",
        .outcome = .invalid,
        .note = "pico accepts multiple spaces; we require one",
    },
};

const field_cases = [_]HeadCase{
    .{ .kind = .field_section, .input = "Host: example.com\r\nCookie: \r\n\r\n", .outcome = .ok },
    .{
        .kind = .field_section,
        .input = "Host: example.com\r\n" ++
            "Cookie: \r\n" ++
            "\r\n" ++
            "",
        .outcome = .ok,
        .last_len = .one,
    },
    .{
        .kind = .field_section,
        .input = "Host: example.com\r\n" ++
            "Cookie: \r\n" ++
            "\r",
        .outcome = .incomplete,
    },
    .{
        .kind = .field_section,
        .input = "Host: e\x07fample.com\r\n" ++
            "Cookie: \r\n" ++
            "\r",
        .outcome = .invalid,
    },
};

test "picohttpparser head corpus" {
    for (request_cases) |case| try expectHead(case);
    for (response_cases) |case| try expectHead(case);
    for (field_cases) |case| try expectHead(case);
}

fn expectHead(case: HeadCase) !void {
    var storage: [8]http.Header = undefined;
    const last_len: u32 = switch (case.last_len) {
        .no => 0,
        .previous_minus_one => @intCast(case.input.len - 1),
        .one => 1,
    };

    var state: http.h1.SearchState = .{ .searched = last_len };
    switch (case.kind) {
        .request => try expectOutcome(case, http.h1.parseRequest(case.input, &state, &storage)),
        .response => try expectOutcome(case, http.h1.parseResponse(case.input, &state, &storage)),
        .field_section => try expectOutcome(
            case,
            http.h1.parseFieldSection(case.input, &state, &storage),
        ),
    }
}

fn expectOutcome(case: HeadCase, result: anytype) !void {
    switch (case.outcome) {
        .ok => {
            const parsed = try result;
            try testing.expectEqual(@as(u32, @intCast(case.input.len)), parsed.consumed);
        },
        .invalid => try testing.expectError(error.Invalid, result),
        .incomplete => try testing.expectError(error.Incomplete, result),
    }
}

const ChunkExpected = union(enum) {
    body: []const u8,
    invalid,
    incomplete,
    overflow,
};

const ChunkCase = struct {
    input: []const u8,
    expected: ChunkExpected,
    note: []const u8 = "",
};

const chunk_cases = [_]ChunkCase{
    .{ .input = "b\r\nhello world\r\n0\r\n\r\n", .expected = .{ .body = "hello world" } },
    .{ .input = "6\r\nhello \r\n5\r\nworld\r\n0\r\n\r\n", .expected = .{ .body = "hello world" } },
    .{
        .input = "6;comment=hi\r\n" ++
            "hello \r\n" ++
            "5\r\n" ++
            "world\r\n" ++
            "0\r\n" ++
            "\r\n" ++
            "",
        .expected = .{ .body = "hello world" },
    },
    .{
        .input = "6 ; comment\r\n" ++
            "hello \r\n" ++
            "5\r\n" ++
            "world\r\n" ++
            "0\r\n" ++
            "\r\n" ++
            "",
        .expected = .{ .body = "hello world" },
    },
    .{
        .input = "6\r\n" ++
            "hello \r\n" ++
            "5\r\n" ++
            "world\r\n" ++
            "0\r\n" ++
            "a: b\r\n" ++
            "c: d\r\n" ++
            "\r\n" ++
            "",
        .expected = .{ .body = "hello world" },
    },
    .{
        .input = "b\r\n" ++
            "hello world\r\n" ++
            "0\r\n" ++
            "",
        .expected = .incomplete,
        .note = "pico with consume_trailer=0 stops; we always parse the trailer section",
    },
    .{ .input = "z\r\nabcdefg", .expected = .invalid },
    .{ .input = "6\r\nhello \r\nffffffffffffffff\r\nabcdefg", .expected = .incomplete },
    .{ .input = "6\r\nhello \r\nfffffffffffffffff\r\nabcdefg", .expected = .overflow },
    .{ .input = "1x\r\na\r\n0\r\n", .expected = .invalid },
    .{ .input = "6\nhello \r\n5\r\nworld\r\n0\r\n", .expected = .invalid },
    .{ .input = "6\r\nhello \n5\r\nworld\r\n0\r\n", .expected = .invalid },
    .{ .input = "6\r\nhello \r\n5\r\nworld\n0\r\n", .expected = .invalid },
    .{ .input = "6\r\nhello \r\n5\r\nworld\r\n0\n", .expected = .invalid },
    .{ .input = "6\rX\nhello \n5\r\nworld\r\n0\r\n", .expected = .invalid },
    .{
        .input = "b\r\n" ++
            "hello world\r\n" ++
            "0\r\n" ++
            "\n",
        .expected = .invalid,
        .note = "pico accepts bare LF in trailers; we reject",
    },
    .{
        .input = "6\r\n" ++
            "hello \r\n" ++
            "5\r\n" ++
            "world\r\n" ++
            "0\r\n" ++
            "a: b\nc: d\n\n",
        .expected = .invalid,
        .note = "pico accepts bare LF in trailers; we reject",
    },
};

test "picohttpparser chunked corpus" {
    var storage: [8]http.Header = undefined;
    var out: [64]u8 = undefined;

    for (chunk_cases) |case| {
        const result = decodeCorpus(case.input, &storage, &out);
        switch (case.expected) {
            .body => |body| {
                const got = try result;
                try testing.expectEqualStrings(body, got);
            },
            .invalid => try testing.expectError(error.Invalid, result),
            .incomplete => try testing.expectError(error.Incomplete, result),
            .overflow => try testing.expectError(error.Overflow, result),
        }
    }
}

fn decodeCorpus(input: []const u8, storage: []http.Header, out: []u8) ![]const u8 {
    var decoder: http.h1.chunked.Decoder = .init(storage);
    var rest = input;
    var len: usize = 0;

    while (!decoder.isDone()) {
        const step = try decoder.next(rest);
        rest = rest[step.consumed..];
        switch (step.event) {
            .data => |data| {
                @memcpy(out[len..][0..data.len], data);
                len += data.len;
            },
            .trailers => {},
            .need_more => if (step.consumed == 0) return error.Incomplete,
        }
    }
    return out[0..len];
}

test "chunked leaves the next message for the caller" {
    var storage: [4]http.Header = undefined;
    var out: [16]u8 = undefined;
    const input: []const u8 = "5\r\nabcde\r\n0\r\n\r\nGET / HTTP/1.1\r\n\r\n";

    var decoder: http.h1.chunked.Decoder = .init(&storage);
    var rest = input;
    var len: usize = 0;
    while (!decoder.isDone()) {
        const step = try decoder.next(rest);
        rest = rest[step.consumed..];
        switch (step.event) {
            .data => |data| {
                @memcpy(out[len..][0..data.len], data);
                len += data.len;
            },
            .trailers => {},
            .need_more => if (step.consumed == 0) return error.TestUnexpectedResult,
        }
    }

    try testing.expectEqualStrings("abcde", out[0..len]);
    try testing.expectEqualStrings("GET / HTTP/1.1\r\n\r\n", rest);
}
