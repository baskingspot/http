//! Optional whitespace: SP and HTAB only (RFC 9110 §5.6.3).
//!
//! Not `std.ascii.isWhitespace`, which also covers CR, LF, VT, and FF. A field
//! parser that trims those accepts bytes the grammar does not allow.

const testing = @import("std").testing;

pub fn trim(value: []const u8) []const u8 {
    var start: usize = 0;
    while (start < value.len and isOws(value[start])) start += 1;
    var end: usize = value.len;
    while (end > start and isOws(value[end - 1])) end -= 1;
    return value[start..end];
}

pub fn isOws(byte: u8) bool {
    return byte == ' ' or byte == '\t';
}

test "trim only touches SP and HTAB" {
    try testing.expectEqualStrings("a", trim(" \t a \t "));
    try testing.expectEqualStrings("", trim(" \t "));
    try testing.expectEqualStrings("a\r", trim("a\r"));
    try testing.expectEqualStrings("\na", trim("\na"));
    try testing.expectEqualStrings("a b", trim("a b"));
}
