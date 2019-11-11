const std = @import("../std.zig");
const assert = std.debug.assert;
const InStream = std.io.InStream;

/// Seekable Stream Mixin
///
/// Expects:
///  - pub const SeekError
///  - pub fn seekTo(self: var, pos: u64) SeekError!void
///  - pub fn seekBy(self: var, amt: i64) SeekError!void
///  - pub const GetPosError
///  - pub fn getEndPos(self: var) GetPosError!u64
///  - pub fn getPos(self: var) GetPosError!u64
pub fn SeekableStream(comptime Self: type) type {
    return struct {
    };
}

pub const SliceSeekableInStream = struct {
    const Self = @This();

    pos: usize,
    slice: []const u8,

    pub fn init(slice: []const u8) Self {
        return Self{
            .slice = slice,
            .pos = 0,
        };
    }

    pub const ReadError = error{};

    pub fn read(self: *Self, dest: []u8) ReadError!usize {
        const size = std.math.min(dest.len, self.slice.len - self.pos);
        const end = self.pos + size;

        std.mem.copy(u8, dest[0..size], self.slice[self.pos..end]);
        self.pos = end;

        return size;
    }

    pub usingnamespace InStream(Self);

    pub const SeekError = error{EndOfStream};

    pub fn seekTo(self: *Self, pos: u64) SeekError!void {
        const usize_pos = @intCast(usize, pos);
        if (usize_pos >= self.slice.len) return error.EndOfStream;
        self.pos = usize_pos;
    }

    pub fn seekBy(self: *Self, amt: i64) SeekError!void {
        if (amt < 0) {
            const abs_amt = @intCast(usize, -amt);
            if (abs_amt > self.pos) return error.EndOfStream;
            self.pos -= abs_amt;
        } else {
            const usize_amt = @intCast(usize, amt);
            if (self.pos + usize_amt >= self.slice.len) return error.EndOfStream;
            self.pos += usize_amt;
        }
    }

    pub const GetPosError = error{};

    pub fn getEndPos(self: *Self) GetPosError!u64 {
        return @intCast(u64, self.slice.len);
    }

    pub fn getPos(self: *Self) GetPosError!u64 {
        return @intCast(u64, self.pos);
    }

    usingnamespace SeekableStream(Self);
};
