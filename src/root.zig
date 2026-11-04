//! http: pure HTTP field-value parsers and an HTTP/1.1 head parser. No server,
//! no allocator, no `std.Io`.
//!
//! Each module parses one field family or message head and returns borrowed
//! slices or fills caller-owned storage. The caller maps content-coding tokens
//! to its codecs.

pub const content_length = @import("content_length.zig");
pub const encoding = @import("encoding.zig");
pub const h1 = @import("h1/root.zig");
pub const Header = @import("header.zig").Header;
pub const Headers = @import("header.zig").Headers;
pub const Method = @import("method.zig").Method;
pub const method = @import("method.zig");
pub const Status = @import("status.zig").Status;
pub const status = @import("status.zig");
pub const token_list = @import("token_list.zig");
pub const Values = @import("header.zig").Values;

test {
    _ = @import("header.zig");
    _ = @import("method.zig");
    _ = @import("status.zig");
    _ = content_length;
    _ = h1;
    _ = encoding;
    _ = token_list;
}
