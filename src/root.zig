//! http: pure HTTP field-value parsers. No server, no allocator, no `std.Io`.
//!
//! Each module parses one field family and returns borrowed slices or fills
//! caller-owned storage. The caller maps content-coding tokens to its codecs.

pub const content_length = @import("content_length.zig");
pub const encoding = @import("encoding.zig");
pub const token_list = @import("token_list.zig");

test {
    _ = content_length;
    _ = encoding;
    _ = token_list;
}
