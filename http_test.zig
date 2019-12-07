const std = @import("std");
const net = std.net;
const os = std.os;
const math = std.math;
const mem = std.mem;
const Allocator = mem.Allocator;
const File = std.fs.File;
const assert = std.debug.assert;

pub const io_mode = .evented;


pub fn main() anyerror!void {
    const allocator = std.heap.direct_allocator;

    const req_listen_addr = try net.Address.parseIp4("127.0.0.1", 9002);

    // const loop = std.event.Loop.instance.?;
    // loop.beginOneEvent();

    var server = net.StreamServer.init(.{});
    defer server.deinit();
    try server.listen(req_listen_addr);
    std.debug.warn("listening at {}\n", server.listen_address);

    while (true) {
        const conn = try server.accept();
        // std.debug.warn("accepted connection from {} fd={}\n", conn.address, conn.file.handle);

        const FrameType = @Frame(handleConnection);
        // const frame = try allocator.alignedAlloc(u8, @alignOf(FrameType), @sizeOf(FrameType));
        // _ = @asyncCall(frame, {}, handleConnection, allocator, conn);
        const frame = try allocator.create(FrameType);
        frame.* = async handleConnection(allocator, conn);
    }
}

pub fn handleConnection(allocator: *Allocator, conn: net.StreamServer.Connection) !void {
    // defer allocator.free(@frame());
    defer conn.file.close();

    var in_stream = std.io.BufferedInStream(File).init(conn.file);
    var out_stream = std.io.BufferedOutStream(File).init(conn.file);
    var h1_connection = std.http.HTTP1Connection.init(.Server, .HTTP1_1);

    while (true) {
        // wait for some data on the connection before allocating
        in_stream.fill(1) catch |err| switch(err) {
            error.EndOfStream => break,
            else => return err,
        };

        const frame = try allocator.create(@Frame(handleStream));
        frame.* = async handleStream(std.heap.direct_allocator, &h1_connection, &in_stream, &out_stream);

    }
}

pub fn handleStream(
    allocator: *Allocator,
    h1_connection: *std.http.HTTP1Connection,
    in_stream: *std.io.BufferedInStream(File),
    out_stream: *std.io.BufferedOutStream(File),
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const stream_allocator = &arena.allocator;

    var h1_stream = h1_connection.newStream(stream_allocator);

    const request_headers = try h1_stream.readRequestHeaders(in_stream);
    defer request_headers.deinit();
    // std.debug.warn("{}", request_headers);

    var response_headers = std.http.Headers.init(stream_allocator);
    defer response_headers.deinit();
    try response_headers.append(":status", "204", null);
    try response_headers.append("server", "zig-test", null);
    try response_headers.append("connection", "keep-alive", null);

    try h1_stream.writeHeaderBlock(response_headers, out_stream);
    try out_stream.flush();
    // try conn.file.print(
    //     "HTTP/1.1 204 Server Not Built\r\n" ++
    //     "Server: zig-test\r\n" ++
    //     "Connection: keep-alive\r\n" ++
    //     "\r\n",
    // );
}
