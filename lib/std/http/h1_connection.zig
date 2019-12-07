const std = @import("../std.zig");
const builtin = @import("builtin");
const assert = std.debug.assert;
const mem = std.mem;
const Allocator = mem.Allocator;
const Headers = std.http.Headers;
const isTokenChar = std.http.isTokenChar;

const ConnectionType = enum {
    Client,
    Server,
};

const Http1Version = enum {
    HTTP1_0,
    HTTP1_1,
};

pub const HTTP1Connection = struct {
    const Self = @This();

    connection_type: ConnectionType,

    /// The version of this connection (not the peer's)
    version: Http1Version,

    /// The version of our peer
    peer_version: ?Http1Version = null,

    /// 100 lines seems like a reasonable default,
    /// most servers use either 100, 128, or a total header limit of 4K, 8K or similar.
    max_headers: u16 = 100,

    pub fn init(comptime connectionType: ConnectionType, version: Http1Version) Self {
        return .{
            .connection_type = connectionType,
            .version = version,
        };
    }

    pub fn newStream(self: *Self, allocator: *Allocator) HTTP1Stream {
        return HTTP1Stream.init(self, allocator);
    }

    fn readRequestLine(self: Self, headers: *Headers, peer_version: *Http1Version, buf_stream: var, offset: usize) !usize {
        assert(self.connection_type == .Server);

        var method_start_offset = offset;
        var newline_index = try buf_stream.fillUntilDelimiter(method_start_offset, '\n') ;
        if (newline_index == method_start_offset+1 and buf_stream.fifo.peekItem(method_start_offset) catch unreachable == '\r') {
            // RFC 7230 3.5: a server that is expecting to receive and parse a request-line
            // SHOULD ignore at least one empty line (CRLF) received prior to the request-line.
            method_start_offset += 2;
            newline_index = try buf_stream.fillUntilDelimiter(method_start_offset, '\n');
        }
        const len = newline_index - method_start_offset;

        // General form is: token non_space_characters HTTP/1.?\r\n

        // Shortest valid request line would be: M / HTTP/1.0\r
        if (len < "M / HTTP/1.X\r".len) return error.InvalidRequest;

        const line = (buf_stream.fifo.readableWithSize(method_start_offset, len) catch unreachable)[0..len];
        if (line[line.len - 1] != '\r') return error.InvalidRequest;
        if (!mem.endsWith(u8, line[0..line.len - 2], " HTTP/1.")) return error.InvalidRequest;

        var i: usize = 0;

        // Validate method characters and find offset of target
        while (true) : (i += 1) {
            if (i > line.len - " / HTTP/1.X\r".len) return error.InvalidRequest;

            const c = line[i];
            if (!isTokenChar(c)) {
                if (c != ' ') return error.InvalidRequest;
                break;
            }
        }
        // 0-character method or no room left for a target
        if (i == 0) return error.InvalidRequest;
        const method = line[0..i];

        // Validate target
        const target = line[i + 1 .. line.len - " HTTP/1.X\r".len];
        assert(target.len > 0);
        for (target) |c| {
            if (c == ' ') return error.InvalidRequest;
        }

        // Validate and extract http version
        const version: Http1Version = switch(line[line.len - 2]) {
            '0' => .HTTP1_0,
            '1' => .HTTP1_1,
            else => return error.InvalidRequest,
        };
        if (self.version == .HTTP1_0 and version == .HTTP1_1) {
            return error.VersionMismatch;
        }
        peer_version.* = version;

        try headers.append(":method", method, null);
        if (mem.eql(u8, method, "CONNECT")) {
            try headers.append(":authority", target, null);
        } else {
            try headers.append(":path", target, null);
        }

        return newline_index + 1;
    }

    fn writeRequestLine(self: Self, method: []const u8, target: []const u8, out_stream: var) !void {
        assert(mem.indexOfAny(u8, method, " \r\n") == null);
        assert(mem.indexOfAny(u8, target, " \r\n") == null);
        try out_stream.print("{} {} HTTP/{}\r\n",
            method,
            target,
            switch (self.version) {
                .HTTP1_0 => "1.0",
                .HTTP1_1 => "1.1",
            },
        );
    }

    fn writeStatusLine(self: Self, status_code: [3]u8, reason_phrase: []const u8, out_stream: var) !void {
        assert(std.ascii.isDigit(status_code[0]) and std.ascii.isDigit(status_code[1]) and std.ascii.isDigit(status_code[2]));
        assert(mem.indexOfAny(u8, reason_phrase, "\r\n") == null);
        try out_stream.print("HTTP/{} {} {}\r\n",
            switch (self.version) {
                .HTTP1_0 => "1.0",
                .HTTP1_1 => "1.1",
            },
            status_code,
            reason_phrase,
        );
    }

    /// Parse a HTTP 1 header and add it to `headers`
    /// An HTTP 1 header is generally of the form: `field: value\r\n`
    /// Header continuations are folded into a space character.
    fn readHeaderLine(self: Self, headers: *Headers, buf_stream: var, offset: usize) !?usize {
        var newline_index = try buf_stream.fillUntilDelimiter(offset, '\n');
        var len = newline_index - offset;
        if (len == 0) return error.InvalidRequest;
        var line = (buf_stream.fifo.readableWithSize(offset, len) catch unreachable)[0..len];
        if (line[line.len - 1] != '\r') return error.InvalidRequest;

        if (len == 1) {
            // is an empty line indicating end of headers
            return null;
        } else if (len < "f:\r".len) { // Shortest valid request line
            return error.InvalidRequest;
        }

        var i: usize = 0;

        // Validate field-name characters
        while (true) : (i += 1) {
            if (i > line.len - ":\r".len) return error.InvalidRequest;

            const c = line[i];
            if (!isTokenChar(c)) {
                // RFC 7230 3.2.4: No whitespace is allowed between the header field-name
                // and colon. In the past, differences in the handling of such whitespace have
                // led to security vulnerabilities in request routing and response handling.
                // A server MUST reject any received request message that contains whitespace
                // between a header field-name and colon with a response code of
                // 400 (Bad Request). A proxy MUST remove any such whitespace from a response
                // message before forwarding the message downstream.
                if (c != ':') return error.InvalidRequest;
                break;
            }
        }
        // 0-character field-name
        if (i == 0) return error.InvalidRequest;
        var field_name = line[0..i];

        if (std.ascii.eqlIgnoreCase(field_name, "host")) {
            field_name = ":authority";
        }

        // skip over colon (:)
        i += 1;

        // RFC 7230 3.2.4: The field value does not include any leading or trailing
        // whitespace: OWS occurring before the first non-whitespace octet of the
        // field value or after the last non-whitespace octet of the field value
        // ought to be excluded by parsers when extracting the field value from a
        // header field.
        while (true) : (i += 1) { // no halt condition on loop as we've already checked for \r
            switch (line[i]) {
                ' ', '\t' => continue, // OWS
                else => break,
            }
        }

        var field_value = std.ArrayList(u8).init(headers.data.allocator);
        errdefer field_value.deinit();
        try field_value.appendSlice(mem.trimRight(u8, line[i..line.len - 1], " \t"));

        // Historically, HTTP header field values could be extended over
        // multiple lines by preceding each extra line with at least one space
        // or horizontal tab (obs-fold).
        while (true) {
            const start_continuation_line = newline_index + 1;
            try buf_stream.fill(start_continuation_line + 1);
            switch (buf_stream.fifo.peekItem(newline_index + 1) catch unreachable) {
                ' ', '\t' => { // continuation line
                    newline_index = buf_stream.fillUntilDelimiter(start_continuation_line, '\n') catch |err| switch (err) {
                        error.EndOfStream => return error.InvalidRequest,
                        else => return err,
                    };
                    len = newline_index - start_continuation_line;

                    // Shortest valid request line would be a space then a carriage return ( \r)
                    if (len < " \r".len) return error.InvalidRequest;

                    line = buf_stream.fifo.readableWithSize(start_continuation_line, len) catch unreachable;
                    if (line[line.len - 1] != '\r') return error.InvalidRequest;

                    i = 1; // start from 1 as we know it has a continuation character

                    // no halt condition on loop as we've already checked for \r
                    while (true) : (i += 1) {
                        switch (line[i]) {
                            ' ', '\t' => continue, // OWS
                            else => break,
                        }
                    }

                    // RFC 7230 3.2.4: A server that receives an obs-fold in a
                    // request message that is not within a message/http container
                    // MUST either reject the message by sending a 400 (Bad
                    // Request), preferably with a representation explaining that
                    // obsolete line folding is unacceptable, or replace each
                    // received obs-fold with one or more SP octets prior to
                    // interpreting the field value or forwarding the message
                    // downstream.
                    try field_value.append(' ');
                    try field_value.appendSlice(mem.trimRight(u8, line[i..line.len - 1], " \t"));
                },
                else => break,
            }
        }

        // TODO: Optimise this so we don't do two allocations+copies (2nd inside of .appendOwned)
        field_name = try std.ascii.allocLowerString(headers.data.allocator, field_name);
        defer headers.data.allocator.free(field_name);

        try headers.appendOwned(field_name, field_value.toOwnedSlice(), null);

        return newline_index + 1;
    }

    fn writeHeaderLine(self: Self, field_name: []const u8, field_value: []const u8, out_stream: var) !void {
        assert(mem.indexOfAny(u8, field_name, ":\r\n") == null);
        for (field_value) |c, i| { // assert for broken continuations
            if (c == '\n') {
                assert(i < field_value.len - 1);
                assert(switch(field_value[i + 1]) {
                    ' ', '\t' => true,
                    else => false,
                });
            }
        }
        try out_stream.print("{}: {}\r\n", field_name, field_value);
    }

    fn writeHeadersDone(self: Self, out_stream: var) !void {
        try out_stream.write("\r\n");
    }

    fn readHeaderBlock(self: Self, headers: *Headers, buf_stream: var, offset: usize) !usize {
        var i = offset;

        while (self.readHeaderLine(headers, buf_stream, i) catch |err| switch (err) {
            error.EndOfStream => return error.InvalidRequest,
            else => return err,
        }) |new_offset| {
            if (headers.count() > self.max_headers) return error.TooManyHeaders;
            i = new_offset;
        }

        i += 2; // for final (empty) line's \r\n
        return i;
    }
};

fn testParseRequestLine(expected: []const u8, request: []const u8) !void {
    var buf_stream = std.io.BufferedInStream(std.io.NullInStream).init(std.io.null_in_stream);
    try buf_stream.fifo.write(request);

    var h1_conn = HTTP1Connection.init(std.debug.global_allocator, .Server, .HTTP1_1);

    var headers = Headers.init(std.debug.global_allocator);
    defer headers.deinit();

    h1_conn.peer_version = @as(Http1Version, undefined); // set to undefined non-null value
    const n_discard = try h1_conn.readRequestLine(&headers, &h1_conn.peer_version.?, &buf_stream, 0);
    std.testing.expectEqual(request.len, n_discard);

    var buf: [100]u8 = undefined;
    std.testing.expectEqualSlices(u8, expected, try std.fmt.bufPrint(&buf, "{}", headers));
    buf_stream.fifo.discard(n_discard);
}

test "readRequestLine" {
    try testParseRequestLine(
        \\:method: GET
        \\:path: /
        \\
    ,
        "GET / HTTP/1.0\r\n",
    );

    std.testing.expectError(error.EndOfStream, testParseRequestLine("", "GET")); // no \r\n
    std.testing.expectError(error.EndOfStream, testParseRequestLine("", "\r\nGET")); // no \r\n with preceeding \r\n
    std.testing.expectError(error.InvalidRequest, testParseRequestLine("", "invalid request line\r\n"));
    std.testing.expectError(error.InvalidRequest, testParseRequestLine("", " / HTTP/1.1\r\n"));
    std.testing.expectError(error.InvalidRequest, testParseRequestLine("", "\r\n / HTTP/1.1\r\n"));
    std.testing.expectError(error.InvalidRequest, testParseRequestLine("", "HTTP/1.1\r\n"));
    std.testing.expectError(error.InvalidRequest, testParseRequestLine("", "GET HTTP/1.0\r\n"));
    std.testing.expectError(error.InvalidRequest, testParseRequestLine("", "GET  HTTP/1.0\r\n"));
    std.testing.expectError(error.InvalidRequest, testParseRequestLine("", "GET HTTP/1.0\r\n"));
    std.testing.expectError(error.InvalidRequest, testParseRequestLine("", "GET / HTP/1.1\r\n"));
    std.testing.expectError(error.InvalidRequest, testParseRequestLine("", "GET / HTTP 1.1\r\n"));
    std.testing.expectError(error.InvalidRequest, testParseRequestLine("", "GET / HTTP/1\r\n"));
    std.testing.expectError(error.InvalidRequest, testParseRequestLine("", "GET / HTTP/2.0\r\n"));
    std.testing.expectError(error.InvalidRequest, testParseRequestLine("", "GET / HTTP/1.1\nHeader: value\r\n")); // missing \r
}

fn testReadHeaderLine(expected: []const u8, request: []const u8) !void {
    var buf_stream = std.io.BufferedInStream(std.io.NullInStream).init(std.io.null_in_stream);
    try buf_stream.fifo.write(request);

    var h1_conn = HTTP1Connection.init(std.debug.global_allocator, .Server, .HTTP1_1);

    var headers = Headers.init(std.debug.global_allocator);
    defer headers.deinit();

    if (try h1_conn.readHeaderLine(&headers, &buf_stream, 0)) |n_discard| {
        std.testing.expect(request.len > n_discard);

        var buf: [100]u8 = undefined;
        std.testing.expectEqualSlices(u8, expected, try std.fmt.bufPrint(&buf, "{}", headers));
        buf_stream.fifo.discard(n_discard);
    }
}

test "readHeaderLine" {
    try testReadHeaderLine(
        \\foo: bar
        \\
    ,
        "foo: bar\r\n\r\n",
    );

    // trailing whitespace
    try testReadHeaderLine(
        \\foo: bar
        \\
    ,
        "foo: bar \r\n\r\n",
    );

    // continuation
    try testReadHeaderLine(
        \\foo: bar qux
        \\
    ,
        "foo: bar\r\n qux\r\n\r\n",
    );

    // not a continuation, but only partial next header
    try testReadHeaderLine(
        \\foo: bar
        \\
    ,
        "foo: bar\r\npartial",
    );

    // not a continuation as gets a single byte of EOH
    try testReadHeaderLine(
        \\foo: bar
        \\
    ,
        "foo: bar\r\n\r",
    );

    std.testing.expectError(error.EndOfStream, testReadHeaderLine("", "")); // no data
    std.testing.expectError(error.EndOfStream, testReadHeaderLine("", "foo")); // sudden connection close
    std.testing.expectError(error.EndOfStream, testReadHeaderLine("", "foo:")); // sudden connection close after field name
    std.testing.expectError(error.EndOfStream, testReadHeaderLine("", "foo: ba")); // sudden connection close after :
    std.testing.expectError(error.EndOfStream, testReadHeaderLine("", "foo: bar\r")); // has carriage return but no new line: unknown if it was going to be a header continuation or not
    std.testing.expectError(error.EndOfStream, testReadHeaderLine("", "foo: bar\r\n")); // closed after new line: unknown if it was going to be a header continuation or not
    std.testing.expectError(error.InvalidRequest, testReadHeaderLine("", "foo : bar\r\n\r\n")); // disallows whitespace before :
    std.testing.expectError(error.InvalidRequest, testReadHeaderLine("", ": fs\r\n\r\n")); // no field name
    std.testing.expectError(error.InvalidRequest, testReadHeaderLine("", "foo bar\r\n\r\n")); // no colon
}

pub const HTTP1Stream = struct {
    const Self = @This();

    allocator: *Allocator,

    /// The connection this stream belongs to
    connection: *HTTP1Connection,

    const States = enum {
        idle,
    };
    state: States = .idle,

    /// Are we currently reading a trailer or a header?
    is_trailers: bool = false,


    pub fn init(connection: *HTTP1Connection, allocator: *Allocator) HTTP1Stream {
        return .{
            .connection = connection,
            .allocator = allocator,
        };
    }

    pub fn readRequestHeaders(self: *Self, buf_stream: var) !Headers {
        assert(self.connection.connection_type == .Server);

        var headers = Headers.init(self.allocator);
        errdefer headers.deinit();

        self.connection.peer_version = @as(Http1Version, undefined); // set to undefined non-null value
        var offset = try self.connection.readRequestLine(&headers, &self.connection.peer_version.?, buf_stream, 0);
        offset = try self.connection.readHeaderBlock(&headers, buf_stream, offset);

        buf_stream.fifo.discard(offset);

        return headers;
    }

    fn ignoreWritingField(self: Self, field_name: []const u8) bool {
        switch (self.connection.connection_type) {
            .Client => {
                if (mem.eql(u8, field_name, ":authority")) return true;
                if (mem.eql(u8, field_name, ":method")) return true;
                if (mem.eql(u8, field_name, ":path")) return true;
                if (mem.eql(u8, field_name, ":scheme")) return true;
                if (mem.eql(u8, field_name, ":protocol")) return true; // from RFC 8441
            },
            .Server => {
                if (mem.eql(u8, field_name, ":status")) return true;
            },
        }
        return false;
    }

    fn writeHeaderBlock(self: Self, headers: Headers, out_stream: var) !void {
        var it = headers.iterator();

        switch (self.connection.connection_type) {
            .Client => {
                const method = ((headers.getOnly(":method") catch unreachable) orelse unreachable).value;

                var target: []const u8 = undefined;
                if (mem.eql(u8, method, "CONNECT")) {
                    target = ((headers.getOnly(":authority") catch unreachable) orelse unreachable).value;
                    assert(!headers.contains(":path")); // CONNECT requests should not have a path
                } else {
                    // RFC 7230 Section 5.4: A client MUST send a Host header field in all HTTP/1.1 request messages.
                    assert(self.connection.version == .HTTP1_0 or headers.contains(":authority"));
                    target = ((headers.getOnly(":path") catch unreachable) orelse unreachable).value;
                }

                try self.connection.writeRequestLine(method, target, out_stream);
            },
            .Server => {
                const status_slice = ((headers.getOnly(":status") catch unreachable) orelse unreachable).value;
                assert(status_slice.len == 3);
                const status = @ptrCast(*[3]u8, status_slice.ptr);
                // RFC 7231 Section 6.2:
                // Since HTTP/1.0 did not define any 1xx status codes,
                // a server MUST NOT send a 1xx response to an HTTP/1.0 client.
                assert(!(status[0] == '1' and self.connection.peer_version.? == .HTTP1_0));

                const reason_phrase = "TODO: reason phrase";

                try self.connection.writeStatusLine(status.*, reason_phrase, out_stream);
            },
        }

        while (it.next()) |entry| {
            if (!self.ignoreWritingField(entry.name)) {
                try self.connection.writeHeaderLine(entry.name, entry.value, out_stream);
            } else {
                if (mem.eql(u8, entry.name, ":authority")) {
                    // TODO: for CONNECT requests, :authority is the path
                }
            }
        }

        try self.connection.writeHeadersDone(out_stream);
    }
};

fn testReadRequestHeaders(expected: []const u8, request: []const u8) !void {
    var buf_stream = std.io.BufferedInStream(std.io.NullInStream).init(std.io.null_in_stream);
    try buf_stream.fifo.write(request);

    var h1_conn = HTTP1Connection.init(.Server, .HTTP1_1);
    const h1_stream = h1_conn.newStream(std.debug.global_allocator);
    const headers = try h1_stream.readRequestHeaders(&buf_stream);
    defer headers.deinit();

    var buf: [100]u8 = undefined;
    std.testing.expectEqualSlices(u8, expected, try std.fmt.bufPrint(&buf, "{}", headers));
}

test "readRequestHeaders" {
    try testReadRequestHeaders(
        \\:method: GET
        \\:path: /
        \\foo: bar
        \\
    ,
        "GET / HTTP/1.0\r\nfoo: bar\r\n\r\n",
    );
}
