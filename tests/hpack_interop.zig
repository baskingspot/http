//! HPACK interop: header blocks from golang.org/x/net/http2/hpack, decoded by
//! this package on one dynamic table.
//!
//! This is a second test artifact because `testingx.fixtures` reads the archive
//! at compile time and testingx is a lazy, dev-only dependency. The `http`
//! module never imports it; the fixture and this file stay out of the package
//! tarball too, because `build.zig.zon` lists only `src`.
//!
//! The archive's comment carries the provenance. It is an interop fixture, not
//! the specification: the RFC 7541 Appendix C sequences are the conformance
//! tests.

const std = @import("std");
const testing = std.testing;
const mem = std.mem;

const http = @import("http");
const testingx = @import("testingx");

const fixtures = testingx.fixtures(@embedFile("hpack-interop.txtar"));

/// The archive order is the connection order. Each block decodes against the
/// table the earlier blocks built.
const messages = .{
    "request-1",
    "request-2",
    "response-1",
    "request-3",
    "table-256",
    "table-4096",
};

test "the fixture's blocks decode, in order, on one table" {
    var table_memory: http.hpack.TableStorage.Buffer(4096) = undefined;
    var decoder = http.hpack.Decoder.init(try .initBuffer(&table_memory, 4096));

    var got: [32]http.Header = undefined;
    var expected: [32]http.Header = undefined;
    var out_bytes: [8192]u8 = undefined;
    var never_indexed: [32]bool = undefined;

    inline for (messages) |name| {
        const headers = try decoder.decodeFlags(
            fixtures.hex(name ++ ".wire"),
            &got,
            &out_bytes,
            &never_indexed,
        );
        const want = try parseFields(&expected, fixtures.get(name ++ ".fields"));

        try testing.expectEqual(want.len, headers.items.len);
        for (want, headers.items, 0..) |a, b, index| {
            try testing.expectEqualStrings(a.name, b.name);
            try testing.expectEqualStrings(a.value, b.value);
            // The only Sensitive field in the generator's lists is
            // `authorization`; nothing else may be never indexed.
            const sensitive = mem.eql(u8, a.name, "authorization");
            try testing.expectEqual(sensitive, never_indexed[index]);
        }
    }
}

/// One `name: value` line per field. The first `": "` separates, because a
/// field name cannot contain a colon while a value can. HTTP field values
/// cannot contain CR, LF, or NUL, so a line stays the whole value.
fn parseFields(out: []http.Header, text: []const u8) ![]http.Header {
    var count: usize = 0;
    var lines = mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (count == out.len) return error.FixtureTooLong;

        const separator = mem.find(u8, line, ": ") orelse return error.FixtureSyntax;
        out[count] = .{
            .name = line[0..separator],
            .value = line[separator + 2 ..],
        };
        count += 1;
    }
    return out[0..count];
}
