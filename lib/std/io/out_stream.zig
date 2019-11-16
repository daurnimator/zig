const std = @import("../std.zig");
const builtin = @import("builtin");
const root = @import("root");
const mem = std.mem;

// TODO: https://github.com/ziglang/zig/issues/3699
pub fn OutStreamError(comptime T: type) type {
    var SelfType = T;
    if (@typeId(SelfType) == .Pointer) {
        SelfType = SelfType.Child;
    }
    return SelfType.WriteError;
}

/// Writable Stream Mixin
///
/// Expects:
///  - pub const WriteError
///  - pub fn write(self: var, bytes: []const u8) WriteError!void
pub fn OutStream(comptime Self: type) type {
    return struct {
        pub fn print(self: var, comptime format: []const u8, args: ...) Self.WriteError!void {
            const arg_type = @typeInfo(@typeOf(Self.write)).Fn.args[0].arg_type.?;
            var self_coerced: arg_type = undefined;
            if (arg_type == @typeOf(self)) {
                self_coerced = self;
            } else if (@typeId(@typeOf(self)) == .Pointer and Self == arg_type) {
                self_coerced = self.*;
            } else {
                @compileError("non-matching types");
            }

            return std.fmt.format(
                self_coerced,
                Self.WriteError,
                Self.write,
                format,
                args,
            );
        }

        pub fn writeByte(self: var, byte: u8) Self.WriteError!void {
            const slice = @as(*const [1]u8, &byte)[0..];
            return self.write(slice);
        }

        pub fn writeByteNTimes(self: var, byte: u8, n: usize) Self.WriteError!void {
            const slice = @as(*const [1]u8, &byte)[0..];
            var i: usize = 0;
            while (i < n) : (i += 1) {
                try self.write(slice);
            }
        }

        /// Write a native-endian integer.
        pub fn writeIntNative(self: var, comptime T: type, value: T) Self.WriteError!void {
            var bytes: [(T.bit_count + 7) / 8]u8 = undefined;
            mem.writeIntNative(T, &bytes, value);
            return self.write(&bytes);
        }

        /// Write a foreign-endian integer.
        pub fn writeIntForeign(self: var, comptime T: type, value: T) Self.WriteError!void {
            var bytes: [(T.bit_count + 7) / 8]u8 = undefined;
            mem.writeIntForeign(T, &bytes, value);
            return self.write(&bytes);
        }

        pub fn writeIntLittle(self: var, comptime T: type, value: T) Self.WriteError!void {
            var bytes: [(T.bit_count + 7) / 8]u8 = undefined;
            mem.writeIntLittle(T, &bytes, value);
            return self.write(&bytes);
        }

        pub fn writeIntBig(self: var, comptime T: type, value: T) Self.WriteError!void {
            var bytes: [(T.bit_count + 7) / 8]u8 = undefined;
            mem.writeIntBig(T, &bytes, value);
            return self.write(&bytes);
        }

        pub fn writeInt(self: var, comptime T: type, value: T, endian: builtin.Endian) Self.WriteError!void {
            var bytes: [(T.bit_count + 7) / 8]u8 = undefined;
            mem.writeInt(T, &bytes, value, endian);
            return self.write(&bytes);
        }
    };
}
