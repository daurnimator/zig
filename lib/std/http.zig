test "std.http" {
    _ = @import("http/headers.zig");
}

pub const Headers = @import("http/headers.zig").Headers;

/// Valid token characters
const tchars = blk: {
    var t = [_]bool{false} ** 128;
    for ("!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ") |c| {
        t[c] = true;
    }
    break :blk t;
};

pub fn isTokenChar(c: u8) bool {
    if (c > 127) return false;
    return tchars[c];
}
