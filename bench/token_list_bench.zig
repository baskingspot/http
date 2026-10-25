//! Token-list benchmarks.

const testingx = @import("testingx");
const http = @import("http");

const short = "keep-alive, Upgrade";
const long = "keep-alive, Upgrade, TE, trailer, close, HTTP2-Settings, proxy-authorization";

pub fn benchmarkTokenListHit(b: *testingx.B) !void {
    const field = b.blackBox(short);
    var sink: usize = 0;
    while (try b.loop()) {
        sink +%= @intFromBool(http.token_list.contains(field, "upgrade"));
    }
    b.keepAlive(sink);
}

pub fn benchmarkTokenListMiss(b: *testingx.B) !void {
    const field = b.blackBox(long);
    var sink: usize = 0;
    while (try b.loop()) {
        sink +%= @intFromBool(http.token_list.contains(field, "not-here"));
    }
    b.keepAlive(sink);
}

pub fn benchmarkTokenListMissEarly(b: *testingx.B) !void {
    const field = b.blackBox(short);
    var sink: usize = 0;
    while (try b.loop()) {
        sink +%= @intFromBool(http.token_list.contains(field, "not-here-at-all"));
    }
    b.keepAlive(sink);
}

pub fn benchmarkTokenListIterator(b: *testingx.B) !void {
    const field = b.blackBox(long);
    var sink: usize = 0;
    while (try b.loop()) {
        var elements = http.token_list.iterator(field);
        while (elements.next()) |element| sink +%= element.len;
    }
    b.keepAlive(sink);
}
