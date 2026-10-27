// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell
//! A tiny sequential HTTP/1.1 server used by the local web UI and by tests.
//! One request per connection (`Connection: close`), so an idle client cannot hold the loop.
const std = @import("std");
const Io = std.Io;
const net = Io.net;

pub const Handler = *const fn (ctx: *anyopaque, req: *std.http.Server.Request) void;

pub fn listen(io: Io, bind: []const u8, bind_port: u16) !net.Server {
    const addr = try net.IpAddress.parse(bind, bind_port);
    return addr.listen(io, .{ .reuse_address = true });
}

pub fn port(server: *const net.Server) u16 {
    return server.socket.address.getPort();
}

/// Per-connection read/write deadline in seconds. Generous for a loopback UI; short enough that a
/// stuck client cannot park the accept loop.
const io_timeout_s: u32 = 10;

fn setSocketTimeouts(handle: std.posix.socket_t, seconds: u32) !void {
    const tv: std.posix.timeval = .{ .sec = @intCast(seconds), .usec = 0 };
    try std.posix.setsockopt(handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&tv));
    try std.posix.setsockopt(handle, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, std.mem.asBytes(&tv));
}

/// Accept loop. Returns when cancelled (or the listener is closed).
pub fn serve(io: Io, server: *net.Server, ctx: *anyopaque, handler: Handler) void {
    while (true) {
        const stream = server.accept(io) catch |e| switch (e) {
            error.Canceled, error.SocketNotListening => return,
            else => continue,
        };
        defer stream.close(io);
        // The loop is sequential, so a client that connects and never finishes its request (or never
        // reads the response) would hold the UI for everyone. A socket deadline bounds both.
        setSocketTimeouts(stream.socket.handle, io_timeout_s) catch {};
        var rbuf: [4096]u8 = undefined;
        var wbuf: [4096]u8 = undefined;
        var r = stream.reader(io, &rbuf);
        var w = stream.writer(io, &wbuf);
        var srv = std.http.Server.init(&r.interface, &w.interface);
        var req = srv.receiveHead() catch continue;
        handler(ctx, &req);
    }
}
