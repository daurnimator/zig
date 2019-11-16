const std = @import("../std.zig");
const os = std.os;

/// TODO make a proposal to make `std.fs.File` use *FILE when linking libc and this just becomes
/// std.io.FileOutStream because std.fs.File.write would do this when linking
/// libc.
pub const COutStream = struct {
    c_file: *std.c.FILE,

    pub fn init(c_file: *std.c.FILE) COutStream {
        return COutStream{
            .c_file = c_file,
        };
    }

    pub const WriteError = std.fs.File.WriteError;

    pub fn write(self: COutStream, bytes: []const u8) WriteError!void {
        const amt_written = std.c.fwrite(bytes.ptr, 1, bytes.len, self.c_file);
        if (amt_written == bytes.len) return;
        switch (std.c._errno().*) {
            0 => unreachable,
            os.EINVAL => unreachable,
            os.EFAULT => unreachable,
            os.EAGAIN => unreachable, // this is a blocking API
            os.EBADF => unreachable, // always a race condition
            os.EDESTADDRREQ => unreachable, // connect was never called
            os.EDQUOT => return error.DiskQuota,
            os.EFBIG => return error.FileTooBig,
            os.EIO => return error.InputOutput,
            os.ENOSPC => return error.NoSpaceLeft,
            os.EPERM => return error.AccessDenied,
            os.EPIPE => return error.BrokenPipe,
            else => |err| return os.unexpectedErrno(@intCast(usize, err)),
        }
    }

    pub usingnamespace std.io.OutStream(COutStream);
};
