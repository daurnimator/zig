const std = @import("../std.zig");
const assert = std.debug.assert;
const maxInt = std.math.maxInt;

const State = enum {
    Complete,
    Value,
    Array,
    Object,
};

/// Writes JSON ([RFC8259](https://tools.ietf.org/html/rfc8259)) formatted data
/// to a stream. `max_depth` is a comptime-known upper bound on the nesting depth,
/// pass `null` for this value to disable safety checks.
pub fn WriteStream(comptime OutStream: type, comptime max_depth: ?usize) type {
    return struct {
        const Self = @This();

        pub const Stream = OutStream;

        whitespace: std.json.StringifyOptions.Whitespace = std.json.StringifyOptions.Whitespace{
            .indent_level = 0,
            .indent = .{ .Space = 1 },
        },

        stream: *OutStream,

        need_comma: bool,
        const state_tracking = max_depth != null;
        const StateStack = if (state_tracking)
            struct {
                index: usize,
                stack: [max_depth.?]State,

                fn push(state_stack: *StateStack, state: State) void {
                    state_stack.index += 1;
                    state_stack.stack[state_stack.index] = state;
                }

                fn pop(state_stack: *StateStack) void {
                    state_stack.stack[state_stack.index] = undefined;
                    state_stack.index -= 1;
                }

                fn check(state_stack: StateStack, wanted: State) void {
                    assert(state_stack.stack[state_stack.index] == wanted);
                }
            }
        else
            void;
        state_stack: StateStack,

        pub fn init(stream: *OutStream) Self {
            var state_stack: StateStack = undefined;
            if (state_tracking) {
                state_stack = .{
                    .index = 1,
                    .stack = undefined,
                };
                state_stack.stack[0] = .Complete;
                state_stack.stack[1] = .Value;
            }
            return Self{
                .stream = stream,
                .need_comma = false,
                .state_stack = state_stack,
            };
        }

        pub fn beginArray(self: *Self) !void {
            if (state_tracking) self.state_stack.check(.Value); // need to call arrayElem or objectField
            try self.stream.writeByte('[');
            if (state_tracking) {
                self.state_stack.stack[self.state_stack.index] = .Array;
            }
            self.need_comma = false;
            self.whitespace.indent_level += 1;
        }

        pub fn beginObject(self: *Self) !void {
            if (state_tracking) self.state_stack.check(.Value); // need to call arrayElem or objectField
            try self.stream.writeByte('{');
            if (state_tracking) {
                self.state_stack.stack[self.state_stack.index] = .Object;
            }
            self.need_comma = false;
            self.whitespace.indent_level += 1;
        }

        pub fn arrayElem(self: *Self) !void {
            if (state_tracking) self.state_stack.check(.Array);
            if (self.need_comma) {
                try self.stream.writeByte(',');
            } else {
                self.need_comma = true;
            }
            if (state_tracking) self.state_stack.push(.Value);
            try self.indent();
        }

        pub fn objectField(self: *Self, name: []const u8) !void {
            if (state_tracking) self.state_stack.check(.Object);
            if (self.need_comma) {
                try self.stream.writeByte(',');
            }
            // No need to set `self.need_comma = true;` it's done by writeEscapedString below
            if (state_tracking) self.state_stack.push(.Value);
            try self.indent();
            try self.writeEscapedString(name);
            try self.stream.writeByte(':');
            if (self.whitespace.separator) {
                try self.stream.writeByte(' ');
            }
        }

        pub fn endArray(self: *Self) !void {
            if (state_tracking) self.state_stack.check(.Array);
            self.whitespace.indent_level -= 1;
            if (self.need_comma) {
                try self.indent();
            }
            self.need_comma = true;
            if (state_tracking) self.state_stack.pop();
            try self.stream.writeByte(']');
        }

        pub fn endObject(self: *Self) !void {
            if (state_tracking) self.state_stack.check(.Object);
            self.whitespace.indent_level -= 1;
            if (self.need_comma) {
                try self.indent();
            }
            self.need_comma = true;
            if (state_tracking) self.state_stack.pop();
            try self.stream.writeByte('}');
        }

        pub fn emitNull(self: *Self) !void {
            if (state_tracking) self.state_stack.check(.Value);
            try self.stringify(null);
            self.state_stack.pop();
        }

        pub fn emitBool(self: *Self, value: bool) !void {
            if (state_tracking) self.state_stack.check(.Value);
            try self.stringify(value);
            self.state_stack.pop();
        }

        pub fn emitNumber(
            self: *Self,
            /// An integer, float, or `std.math.BigInt`. Emitted as a bare number if it fits losslessly
            /// in a IEEE 754 double float, otherwise emitted as a string to the full precision.
            value: var,
        ) !void {
            if (state_tracking) self.state_stack.check(.Value);
            switch (@typeInfo(@TypeOf(value))) {
                .Int => |info| {
                    if (info.bits < 53) {
                        try self.stream.print("{}", .{value});
                    } else if (value < 4503599627370496 and (!info.is_signed or value > -4503599627370496)) {
                        try self.stream.print("{}", .{value});
                    }
                },
                .Float => if (@floatCast(f64, value) == value) {
                    try self.stream.print("{}", .{value});
                },
                else => {
                    try self.stream.print("\"{}\"", .{value});
                },
            }
            self.need_comma = true;
            self.state_stack.pop();
        }

        pub fn emitString(self: *Self, string: []const u8) !void {
            try self.writeEscapedString(string);
            self.state_stack.pop();
        }

        fn writeEscapedString(self: *Self, string: []const u8) !void {
            assert(std.unicode.utf8ValidateSlice(string));
            try self.stringify(string);
        }

        /// Writes the complete json into the output stream
        pub fn emitJson(self: *Self, json: std.json.Value) Stream.Error!void {
            try self.stringify(json);
            self.state_stack.pop();
        }

        fn indent(self: *Self) !void {
            if (state_tracking) {
                assert(self.state_stack.index >= 1);
            }
            try self.stream.writeByte('\n');
            try self.whitespace.outputIndent(self.stream, OutStream.Error, OutStream.write);
        }

        fn stringify(self: *Self, value: var) !void {
            try std.json.stringify(value, std.json.StringifyOptions{
                .whitespace = self.whitespace,
            }, self.stream, OutStream.Error, OutStream.write);
            self.need_comma = true;
        }
    };
}

test "json write stream" {
    var out_buf: [1024]u8 = undefined;
    var slice_stream = std.io.SliceOutStream.init(&out_buf);
    const out = &slice_stream.stream;

    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();

    var w = std.json.WriteStream(@TypeOf(out).Child, 10).init(out);
    try w.emitJson(try getJson(&arena_allocator.allocator));

    const result = slice_stream.getWritten();
    const expected =
        \\{
        \\ "object": {
        \\  "one": 1,
        \\  "two": 2.0e+00
        \\ },
        \\ "string": "This is a string",
        \\ "array": [
        \\  "Another string",
        \\  1,
        \\  3.14e+00
        \\ ],
        \\ "int": 10,
        \\ "float": 3.14e+00
        \\}
    ;
    std.testing.expect(std.mem.eql(u8, expected, result));
}

fn getJson(allocator: *std.mem.Allocator) !std.json.Value {
    var value = std.json.Value{ .Object = std.json.ObjectMap.init(allocator) };
    _ = try value.Object.put("string", std.json.Value{ .String = "This is a string" });
    _ = try value.Object.put("int", std.json.Value{ .Integer = @intCast(i64, 10) });
    _ = try value.Object.put("float", std.json.Value{ .Float = 3.14 });
    _ = try value.Object.put("array", try getJsonArray(allocator));
    _ = try value.Object.put("object", try getJsonObject(allocator));
    return value;
}

fn getJsonObject(allocator: *std.mem.Allocator) !std.json.Value {
    var value = std.json.Value{ .Object = std.json.ObjectMap.init(allocator) };
    _ = try value.Object.put("one", std.json.Value{ .Integer = @intCast(i64, 1) });
    _ = try value.Object.put("two", std.json.Value{ .Float = 2.0 });
    return value;
}

fn getJsonArray(allocator: *std.mem.Allocator) !std.json.Value {
    var value = std.json.Value{ .Array = std.json.Array.init(allocator) };
    var array = &value.Array;
    _ = try array.append(std.json.Value{ .String = "Another string" });
    _ = try array.append(std.json.Value{ .Integer = @intCast(i64, 1) });
    _ = try array.append(std.json.Value{ .Float = 3.14 });

    return value;
}
