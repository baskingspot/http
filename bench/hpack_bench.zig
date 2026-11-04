//! HPACK encode and decode benchmarks over one typical request.

const std = @import("std");

const http = @import("http");
const testingx = @import("testingx");

const request = [_]http.Header{
    .{ .name = ":method", .value = "GET" },
    .{ .name = ":scheme", .value = "https" },
    .{ .name = ":path", .value = "/api/v1/things?page=2" },
    .{ .name = ":authority", .value = "www.example.com" },
    .{
        .name = "user-agent",
        .value = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36",
    },
    .{
        .name = "accept",
        .value = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
    },
    .{ .name = "accept-encoding", .value = "gzip, deflate, br" },
    .{ .name = "cookie", .value = "session=abc123; theme=dark; lang=en-US" },
    .{ .name = "x-trace-id", .value = "0123456789abcdef0123456789abcdef" },
};

pub fn benchmarkHpackEncode(b: *testingx.B) !void {
    var table_memory: http.hpack.TableStorage.Buffer(4096) = undefined;
    var encoder: http.hpack.Encoder = .init(try .initBuffer(&table_memory, 4096));

    var out: [4096]u8 = undefined;
    const fields = b.blackBox(&request);
    // Warm the table, so the loop measures lookup and write, not insertion.
    _ = try encoder.encode(fields, &out);

    var checksum: u8 = 0;
    while (try b.loop()) {
        const block = try encoder.encode(fields, &out);
        for (block) |byte| checksum +%= byte;
    }
    b.keepAlive(checksum);
}

pub fn benchmarkHpackDecode(b: *testingx.B) !void {
    var encode_memory: http.hpack.TableStorage.Buffer(4096) = undefined;
    var encoder: http.hpack.Encoder = .init(try .initBuffer(&encode_memory, 4096));

    var block_buf: [4096]u8 = undefined;
    const block = try encoder.encode(&request, &block_buf);

    var table_memory: http.hpack.TableStorage.Buffer(4096) = undefined;
    var decoder: http.hpack.Decoder = .init(try .initBuffer(&table_memory, 4096));

    var out: [16]http.Header = undefined;
    var out_bytes: [4096]u8 = undefined;
    const bytes = b.blackBox(block);

    var checksum: u8 = 0;
    while (try b.loop()) {
        const headers = try decoder.decode(bytes, &out, &out_bytes);
        for (headers.items) |header| {
            for (header.name) |byte| checksum +%= byte;
            for (header.value) |byte| checksum +%= byte;
        }
    }
    b.keepAlive(checksum);
}

const lookup_names = [_][]const u8{
    ":method", ":scheme",         ":path",  ":authority", "user-agent",
    "accept",  "accept-encoding", "cookie", "x-trace-id",
};

/// The 61-entry scan the static table's map replaced. Kept as a baseline so
/// the lookup row means something.
fn linearFindName(name: []const u8) ?u32 {
    var i: u32 = 1;
    while (i <= http.hpack.static_table.count) : (i += 1) {
        if (std.mem.eql(u8, http.hpack.static_table.get(i).?.name, name)) return i;
    }
    return null;
}

pub fn benchmarkHpackLookupLinear(b: *testingx.B) !void {
    const names = b.blackBox(&lookup_names);
    var sink: u32 = 0;
    while (try b.loop()) {
        for (names) |name| sink +%= linearFindName(name) orelse 0;
    }
    b.keepAlive(sink);
}

fn linearFind(header: http.Header) ?u32 {
    var i: u32 = 1;
    while (i <= http.hpack.static_table.count) : (i += 1) {
        const entry = http.hpack.static_table.get(i).?;
        if (std.mem.eql(u8, entry.name, header.name) and
            std.mem.eql(u8, entry.value, header.value)) return i;
    }
    return null;
}

pub fn benchmarkHpackExactLinear(b: *testingx.B) !void {
    const names = b.blackBox(&lookup_names);
    var sink: u32 = 0;
    while (try b.loop()) {
        for (names) |name| {
            sink +%= linearFind(.{ .name = name, .value = "v" }) orelse 0;
        }
    }
    b.keepAlive(sink);
}

pub fn benchmarkHpackExactMap(b: *testingx.B) !void {
    const names = b.blackBox(&lookup_names);
    var sink: u32 = 0;
    while (try b.loop()) {
        for (names) |name| {
            sink +%= http.hpack.static_table.find(.{ .name = name, .value = "v" }) orelse 0;
        }
    }
    b.keepAlive(sink);
}

pub fn benchmarkHpackLookupMap(b: *testingx.B) !void {
    const names = b.blackBox(&lookup_names);
    var sink: u32 = 0;
    while (try b.loop()) {
        for (names) |name| sink +%= http.hpack.static_table.findName(name) orelse 0;
    }
    b.keepAlive(sink);
}

pub fn benchmarkHpackEncodeMany(b: *testingx.B) !void {
    var table_memory: http.hpack.TableStorage.Buffer(8192) = undefined;
    var encoder = http.hpack.Encoder.init(try .initBuffer(&table_memory, 8192));

    var names: [128][16]u8 = undefined;
    var values: [128][8]u8 = undefined;
    var headers: [128]http.Header = undefined;
    for (0..128) |i| {
        const name = try std.fmt.bufPrint(&names[i], "x-field-{d}", .{i});
        const value = try std.fmt.bufPrint(&values[i], "v{d}", .{i});
        headers[i] = .{ .name = name, .value = value };
    }

    var out: [8192]u8 = undefined;
    const fields = b.blackBox(&headers);
    _ = try encoder.encode(fields, &out);

    var checksum: u8 = 0;
    while (try b.loop()) {
        const block = try encoder.encode(fields, &out);
        for (block) |byte| checksum +%= byte;
    }
    b.keepAlive(checksum);
}
