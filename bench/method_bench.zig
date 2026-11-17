//! `Method.parse` benchmarks: one mixed stream over the named set, and one
//! GET-heavy stream shaped like real traffic.

const std = @import("std");
const testingx = @import("testingx");
const http = @import("http");

const Method = http.Method;

const broad = [_][]const u8{
    "GET",   "POST",    "HEAD",  "PUT",     "DELETE",
    "PATCH", "OPTIONS", "TRACE", "CONNECT", "PROPFIND",
};

const get_heavy = blk: {
    var tokens: [100][]const u8 = undefined;
    for (&tokens, 0..) |*token, index| {
        token.* = if (index < 90)
            "GET"
        else if (index < 95)
            "POST"
        else if (index < 98)
            "HEAD"
        else if (index < 99)
            "OPTIONS"
        else
            "PROPFIND";
    }
    break :blk tokens;
};

pub fn benchmarkMethodBroad(b: *testingx.B) !void {
    const tokens = b.blackBox(&broad);
    var sink: u32 = 0;
    var index: usize = 0;
    while (try b.loop()) : (index += 1) {
        const method = Method.parse(tokens[index % tokens.len]);
        sink +%= @backingInt(std.meta.activeTag(method));
    }
    b.keepAlive(sink);
}

pub fn benchmarkMethodGetHeavy(b: *testingx.B) !void {
    const tokens = b.blackBox(&get_heavy);
    var sink: u32 = 0;
    var index: usize = 0;
    while (try b.loop()) : (index += 1) {
        const method = Method.parse(tokens[index % tokens.len]);
        sink +%= @backingInt(std.meta.activeTag(method));
    }
    b.keepAlive(sink);
}
