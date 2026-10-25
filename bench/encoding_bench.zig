//! `Accept-Encoding` negotiation benchmarks.

const testingx = @import("testingx");
const http = @import("http");

const typical = "gzip, deflate, br";
const wide = "gzip;q=0.8, deflate;q=0.5, br;q=0.9, zstd;q=0.7, identity;q=0.1, *;q=0.2";
const supported = [_][]const u8{ "br", "gzip", "deflate", "zstd" };

pub fn benchmarkNegotiateTypical(b: *testingx.B) !void {
    const field = b.blackBox(typical);
    var sink: usize = 0;
    while (try b.loop()) {
        const coding = http.encoding.negotiate(field, &supported) orelse unreachable;
        sink +%= coding.len;
    }
    b.keepAlive(sink);
}

pub fn benchmarkNegotiateWide(b: *testingx.B) !void {
    const field = b.blackBox(wide);
    var sink: usize = 0;
    while (try b.loop()) {
        const coding = http.encoding.negotiate(field, &supported) orelse unreachable;
        sink +%= coding.len;
    }
    b.keepAlive(sink);
}

pub fn benchmarkNegotiateFields(b: *testingx.B) !void {
    const fields = b.blackBox([_][]const u8{ "gzip;q=0.8, br;q=0.9", "deflate;q=0.5" });
    var sink: usize = 0;
    while (try b.loop()) {
        const coding = http.encoding.negotiateFields(&fields, &supported) orelse unreachable;
        sink +%= coding.len;
    }
    b.keepAlive(sink);
}

pub fn benchmarkNegotiateReject(b: *testingx.B) !void {
    const field = b.blackBox("gzip;q=0, br;q=0, deflate;q=0, zstd;q=0, identity;q=0");
    var sink: usize = 0;
    while (try b.loop()) {
        if (http.encoding.negotiate(field, &supported)) |coding| sink +%= coding.len;
    }
    b.keepAlive(sink);
}
