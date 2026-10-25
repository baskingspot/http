//! http: pure HTTP field-value parsers. No server, no allocator, no `std.Io`.
//!
//! Each module parses one field family and returns borrowed slices or fills
//! caller-owned storage. The caller maps content-coding tokens to its codecs.

pub const encoding = @import("encoding.zig");

test {
    _ = encoding;
}
