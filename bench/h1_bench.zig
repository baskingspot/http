//! HTTP/1.1 head parsing benchmarks: a typical scrape, a wide head, and a
//! response head.

const testingx = @import("testingx");
const http = @import("http");

const h1 = http.h1;

const typical =
    "GET /metrics?x=1 HTTP/1.1\r\n" ++
    "Host: example.com\r\n" ++
    "User-Agent: test/1.0\r\n" ++
    "Accept: */*\r\n" ++
    "Accept-Encoding: gzip, br\r\n" ++
    "\r\n";

const wide =
    "GET /v2?address=db.example.com:6432 HTTP/1.1\r\n" ++
    "Host: example.com\r\n" ++
    "User-Agent: exosphere/0.1\r\n" ++
    "Accept: */*\r\n" ++
    "Accept-Encoding: gzip, deflate, br, zstd\r\n" ++
    "Connection: keep-alive\r\n" ++
    "Content-Type: application/json\r\n" ++
    "Content-Length: 128\r\n" ++
    "Authorization: Bearer abcdefghijklmnopqrstuvwxyz012345\r\n" ++
    "X-Request-Id: 01234567-89ab-cdef-0123-456789abcdef\r\n" ++
    "X-Forwarded-For: 203.0.113.7, 198.51.100.9\r\n" ++
    "X-Forwarded-Proto: https\r\n" ++
    "X-Forwarded-Host: example.com\r\n" ++
    "Traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01\r\n" ++
    "\r\n";

const response =
    "HTTP/1.1 200 OK\r\n" ++
    "Content-Type: application/json\r\n" ++
    "Content-Length: 1234\r\n" ++
    "Date: Mon, 26 Oct 2026 12:00:00 GMT\r\n" ++
    "Connection: keep-alive\r\n" ++
    "\r\n";

pub fn benchmarkRequestTypical(b: *testingx.B) !void {
    const buf = b.blackBox(typical);
    var storage: [16]http.Field = undefined;
    var sink: usize = 0;
    while (try b.loop()) {
        const parsed = try h1.parseRequest(buf, 0, &storage);
        sink +%= parsed.head.target.len + parsed.head.fields.len;
    }
    b.keepAlive(sink);
    b.keepAlive(&storage);
}

pub fn benchmarkRequestWide(b: *testingx.B) !void {
    const buf = b.blackBox(wide);
    var storage: [32]http.Field = undefined;
    var sink: usize = 0;
    while (try b.loop()) {
        const parsed = try h1.parseRequest(buf, 0, &storage);
        sink +%= parsed.head.target.len + parsed.head.fields.len;
    }
    b.keepAlive(sink);
    b.keepAlive(&storage);
}

pub fn benchmarkResponse(b: *testingx.B) !void {
    const buf = b.blackBox(response);
    var storage: [16]http.Field = undefined;
    var sink: usize = 0;
    while (try b.loop()) {
        const parsed = try h1.parseResponse(buf, 0, &storage);
        sink +%= parsed.head.reason.len + parsed.head.fields.len;
    }
    b.keepAlive(sink);
    b.keepAlive(&storage);
}

const long_value = "a" ** 1024;
const long_request = "GET / HTTP/1.1\r\nX-Long: " ++ long_value ++ "\r\n\r\n";

// No final empty line: the completeness gate scans and returns Incomplete.
const incomplete_request = "GET / HTTP/1.1\r\n" ++ ("X-Filler: value\r\n" ** 400);

pub fn benchmarkRequestLongValue(b: *testingx.B) !void {
    const buf: []const u8 = long_request;
    var storage: [4]http.Field = undefined;
    var sink: usize = 0;
    while (try b.loop()) {
        const parsed = try h1.parseRequest(buf, 0, &storage);
        sink +%= parsed.head.fields[1].value.len;
    }
    b.keepAlive(sink);
    b.keepAlive(&storage);
}

pub fn benchmarkIncompleteScan(b: *testingx.B) !void {
    const buf: []const u8 = incomplete_request;
    var storage: [4]http.Field = undefined;
    var sink: usize = 0;
    while (try b.loop()) {
        const parsed = h1.parseRequest(buf, 4096, &storage);
        if (parsed) |_| {
            unreachable;
        } else |err| {
            sink +%= @intFromError(err);
        }
    }
    b.keepAlive(sink);
    b.keepAlive(&storage);
}
