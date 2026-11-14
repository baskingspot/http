//! HTTP/2 request-head validation benchmarks: a typical gRPC request and a
//! wide one with long field values.

const testingx = @import("testingx");
const http = @import("http");

const h2 = http.h2;
const Header = http.Header;

const typical = [_]Header{
    .{ .name = ":method", .value = "POST" },
    .{ .name = ":scheme", .value = "http" },
    .{ .name = ":path", .value = "/helloworld.Greeter/SayHello" },
    .{ .name = ":authority", .value = "localhost:50051" },
    .{ .name = "content-type", .value = "application/grpc" },
    .{ .name = "te", .value = "trailers" },
    .{ .name = "user-agent", .value = "grpc-zig/0.1" },
    .{ .name = "grpc-accept-encoding", .value = "identity,gzip" },
};

const wide = [_]Header{
    .{ .name = ":method", .value = "GET" },
    .{ .name = ":scheme", .value = "https" },
    .{
        .name = ":path",
        .value = "/v2?address=db.example.com:6432&limit=100&cursor=abcdefghijklmnopqrstuvwxyz",
    },
    .{ .name = ":authority", .value = "api.example.com" },
    .{ .name = "accept", .value = "application/json, text/plain;q=0.9, */*;q=0.1" },
    .{ .name = "accept-encoding", .value = "gzip, deflate, br, zstd" },
    .{
        .name = "authorization",
        .value = "Bearer abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ",
    },
    .{ .name = "x-request-id", .value = "01234567-89ab-cdef-0123-456789abcdef" },
    .{ .name = "x-forwarded-for", .value = "203.0.113.7, 198.51.100.9" },
    .{ .name = "traceparent", .value = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01" },
    .{
        .name = "user-agent",
        .value = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko)",
    },
};

pub fn benchmarkH2HeadTypical(b: *testingx.B) !void {
    const fields = b.blackBox(&typical);
    var sink: usize = 0;
    while (try b.loop()) {
        const head = try h2.head.request(.{ .items = fields });
        sink +%= head.headers.len();
    }
    b.keepAlive(sink);
}

pub fn benchmarkH2HeadWide(b: *testingx.B) !void {
    const fields = b.blackBox(&wide);
    var sink: usize = 0;
    while (try b.loop()) {
        const head = try h2.head.request(.{ .items = fields });
        sink +%= head.headers.len();
    }
    b.keepAlive(sink);
}
