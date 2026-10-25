//! `Content-Length` benchmarks.

const testingx = @import("testingx");
const http = @import("http");

const single = [_][]const u8{"1234"};
const duplicate = [_][]const u8{ "1234", "1234" };
const comma = [_][]const u8{"1234, 1234"};
const maximum = [_][]const u8{"18446744073709551615"};

pub fn benchmarkContentLengthSingle(b: *testingx.B) !void {
    const values = b.blackBox(&single);
    var sink: u64 = 0;
    while (try b.loop()) {
        sink +%= (try http.content_length.parse(values)).?;
    }
    b.keepAlive(sink);
}

pub fn benchmarkContentLengthDuplicate(b: *testingx.B) !void {
    const values = b.blackBox(&duplicate);
    var sink: u64 = 0;
    while (try b.loop()) {
        sink +%= (try http.content_length.parse(values)).?;
    }
    b.keepAlive(sink);
}

pub fn benchmarkContentLengthComma(b: *testingx.B) !void {
    const values = b.blackBox(&comma);
    var sink: u64 = 0;
    while (try b.loop()) {
        sink +%= (try http.content_length.parse(values)).?;
    }
    b.keepAlive(sink);
}

pub fn benchmarkContentLengthMaximum(b: *testingx.B) !void {
    const values = b.blackBox(&maximum);
    var sink: u64 = 0;
    while (try b.loop()) {
        sink +%= (try http.content_length.parse(values)).?;
    }
    b.keepAlive(sink);
}
