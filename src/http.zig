// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell
//! HTTP(S) transport over std.http.Client with a hard wall-clock timeout per request.
//!
//! std.http.Client has no read timeout, so each request races a timer using Io.Select; when the
//! timer wins the request task is cancelled (which interrupts the blocking syscall).
//! Connections are not kept alive: polls are minutes apart, so pooling would only hold memory.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const transport = @import("transport.zig");
const tls_client = @import("vendor/tls_client.zig");

pub const HttpTransport = struct {
    gpa: Allocator,
    io: Io,
    client: std.http.Client,
    user_agent: []const u8,
    timeout_s: u32,

    pub fn init(gpa: Allocator, io: Io, user_agent: []const u8, timeout_s: u32) HttpTransport {
        return .{ .gpa = gpa, .io = io, .client = .{ .allocator = gpa, .io = io }, .user_agent = user_agent, .timeout_s = timeout_s };
    }

    pub fn deinit(self: *HttpTransport) void {
        self.client.deinit();
    }

    pub fn asTransport(self: *HttpTransport) transport.Transport {
        return .{ .ptr = self, .requestFn = requestImpl, .certNotAfterFn = certImpl };
    }

    const CertRace = union(enum) {
        probe: ?i64,
        timer: Io.Cancelable!void,
    };

    fn certImpl(ptr: *anyopaque, host: []const u8, port: u16) ?i64 {
        const self: *HttpTransport = @ptrCast(@alignCast(ptr));
        var buf: [2]CertRace = undefined;
        var sel = Io.Select(CertRace).init(self.io, &buf);
        sel.concurrent(.probe, probeCert, .{ self, host, port }) catch return null;
        sel.concurrent(.timer, timerTask, .{ self.io, self.timeout_s }) catch {
            sel.cancelDiscard();
            return null;
        };
        const first = sel.await() catch {
            sel.cancelDiscard();
            return null;
        };
        sel.cancelDiscard();
        return switch (first) {
            .probe => |v| v,
            .timer => null,
        };
    }

    /// Handshake with certificate verification disabled and read only the leaf's notAfter.
    /// Trust is established by the real request (std.http.Client verifies); this only records expiry.
    fn probeCert(self: *HttpTransport, host: []const u8, port: u16) ?i64 {
        const hn = Io.net.HostName.init(host) catch return null;
        const stream = hn.connect(self.io, port, .{ .mode = .stream }) catch return null;
        defer stream.close(self.io);
        const n = tls_client.min_buffer_len;
        const bufs = self.gpa.alloc(u8, n * 4) catch return null;
        defer self.gpa.free(bufs);
        var sr = stream.reader(self.io, bufs[0..n]);
        var sw = stream.writer(self.io, bufs[n .. 2 * n]);
        var entropy: [tls_client.Options.entropy_len]u8 = undefined;
        self.io.random(&entropy);
        var not_after: u64 = 0;
        _ = tls_client.init(&sr.interface, &sw.interface, .{
            .host = .{ .sni_only = host },
            .ca = .no_verification,
            .read_buffer = bufs[2 * n .. 3 * n],
            .write_buffer = bufs[3 * n ..],
            .entropy = &entropy,
            .realtime_now = Io.Timestamp.now(self.io, .real),
            .leaf_not_after = &not_after,
        }) catch {};
        return if (not_after != 0) @intCast(not_after) else null;
    }

    /// Drop the parsed CA bundle (and force a rescan on the next HTTPS request) to give memory back
    /// while idle. Costs a few milliseconds per scan; the daemon calls it between poll bursts.
    pub fn releaseCaches(self: *HttpTransport) void {
        if (!std.http.Client.disable_tls) {
            self.client.ca_bundle.deinit(self.gpa);
            self.client.ca_bundle = .empty;
            self.client.now = null;
        }
    }

    const Race = union(enum) {
        fetch: transport.Error!transport.Response,
        timer: Io.Cancelable!void,
    };

    fn timerTask(io: Io, secs: u32) Io.Cancelable!void {
        try io.sleep(.fromSeconds(secs), .awake);
    }

    fn requestImpl(ptr: *anyopaque, arena: Allocator, req: transport.Request) transport.Error!transport.Response {
        const self: *HttpTransport = @ptrCast(@alignCast(ptr));
        var buf: [2]Race = undefined;
        var sel = Io.Select(Race).init(self.io, &buf);
        sel.concurrent(.fetch, doRequest, .{ self, arena, req }) catch {
            // No spare thread: run unguarded rather than not at all.
            std.log.warn("no concurrency available; request to {s} runs without a timeout", .{req.url});
            return doRequest(self, arena, req);
        };
        sel.concurrent(.timer, timerTask, .{ self.io, self.timeout_s }) catch {
            const r = sel.await() catch {
                sel.cancelDiscard();
                return error.Other;
            };
            sel.cancelDiscard();
            return r.fetch;
        };
        const first = sel.await() catch {
            sel.cancelDiscard();
            return error.Other;
        };
        sel.cancelDiscard();
        return switch (first) {
            .fetch => |r| r,
            .timer => error.Timeout,
        };
    }

    fn dupeOpt(a: Allocator, s: ?[]const u8) Allocator.Error!?[]const u8 {
        return if (s) |v| try a.dupe(u8, v) else null;
    }

    fn doRequest(self: *HttpTransport, arena: Allocator, req: transport.Request) transport.Error!transport.Response {
        return self.doRequestInner(arena, req) catch |e| return mapError(e);
    }

    fn doRequestInner(self: *HttpTransport, arena: Allocator, req: transport.Request) !transport.Response {
        var uri = try std.Uri.parse(req.url);
        var hdrs: [3]std.http.Header = undefined;
        var nh: usize = 0;
        hdrs[nh] = .{ .name = "Accept", .value = "application/atom+xml, application/rss+xml, application/rdf+xml;q=0.9, application/xml;q=0.8, text/xml;q=0.8, */*;q=0.5" };
        nh += 1;
        if (req.etag) |v| {
            hdrs[nh] = .{ .name = "If-None-Match", .value = v };
            nh += 1;
        }
        if (req.last_modified) |v| {
            hdrs[nh] = .{ .name = "If-Modified-Since", .value = v };
            nh += 1;
        }
        // Redirects are followed here, not by std.http.Client: its automatic path dereferences an
        // uninitialised TLS clock when an http:// request redirects to https:// on a client that has
        // not yet made an https request. Every hop below is a fresh `request()`, which initialises
        // TLS state correctly.
        var hops: u8 = 0;
        while (true) : (hops += 1) {
            var r = try self.client.request(if (req.method == .head) .HEAD else .GET, uri, .{
                .keep_alive = false,
                .redirect_behavior = .unhandled,
                .headers = .{
                    .user_agent = .{ .override = self.user_agent },
                    // gzip/deflate only: zstd decoding needs a multi-megabyte window.
                    .accept_encoding = .{ .override = "gzip, deflate" },
                },
                .extra_headers = hdrs[0..nh],
            });
            defer r.deinit();
            try r.sendBodiless();

            var resp = try r.receiveHead(&.{});
            const status = @backingInt(resp.head.status);

            switch (status) {
                301, 302, 303, 307, 308 => if (req.follow_redirects) {
                    if (hops >= 5) return error.TooManyRedirects;
                    const loc = resp.head.location orelse return error.BadRedirect;
                    // Resolve (possibly relative) Location against the current URI, in an arena buffer.
                    const aux = try arena.alloc(u8, loc.len + uri_scratch);
                    @memcpy(aux[0..loc.len], loc);
                    var rest: []u8 = aux; // resolveInPlace expects the location at the start of the buffer
                    uri = std.Uri.resolveInPlace(uri, loc.len, &rest) catch return error.BadRedirect;
                    continue;
                },
                else => {},
            }

            var out: transport.Response = .{ .status = status };
            out.content_type = try dupeOpt(arena, resp.head.content_type);
            var it = resp.head.iterateHeaders();
            while (it.next()) |h| {
                if (std.ascii.eqlIgnoreCase(h.name, "etag")) out.etag = try arena.dupe(u8, h.value) else if (std.ascii.eqlIgnoreCase(h.name, "last-modified")) out.last_modified = try arena.dupe(u8, h.value) else if (std.ascii.eqlIgnoreCase(h.name, "retry-after")) out.retry_after = try arena.dupe(u8, h.value);
            }
            if (req.method == .head or status == 304 or status == 204) return out;

            var transfer_buf: [64]u8 = undefined;
            var decompress: std.http.Decompress = undefined;
            const dbuf = try arena.alloc(u8, std.compress.flate.max_window_len);
            defer arena.free(dbuf);
            const reader = resp.readerDecompressing(&transfer_buf, &decompress, dbuf);
            out.body = reader.allocRemaining(arena, .limited(req.max_body_bytes)) catch |e| switch (e) {
                error.StreamTooLong => return error.StreamTooLong,
                error.ReadFailed => return resp.bodyErr() orelse error.ReadFailed,
                error.OutOfMemory => return error.OutOfMemory,
            };
            return out;
        }
    }

    const uri_scratch = 2048;

    fn mapError(e: anyerror) transport.Error {
        const n = @errorName(e);
        const has = struct {
            fn f(hay: []const u8, needle: []const u8) bool {
                return std.mem.find(u8, hay, needle) != null;
            }
        }.f;
        if (e == error.StreamTooLong) return error.TooLarge;
        if (e == error.Canceled) return error.Timeout;
        if (has(n, "Tls") or has(n, "Certificate")) return error.TlsFailure;
        if (has(n, "Host") or has(n, "Name") or has(n, "Dns")) return error.DnsFailure;
        if (has(n, "Timeout") or has(n, "TimedOut")) return error.Timeout;
        if (has(n, "Connect") or has(n, "Network") or has(n, "Refused") or has(n, "Unreach")) return error.ConnectFailed;
        if (has(n, "Redirect") or has(n, "Http") or has(n, "Invalid") or has(n, "Redirect") or has(n, "Uri") or has(n, "Url")) return error.BadResponse;
        return error.Other;
    }
};

// ---------------------------------------------------------------------------
// Tests against a local server (real sockets, real HTTP/1.1 on the wire)
// ---------------------------------------------------------------------------
const testing = std.testing;
const localserver = @import("localserver.zig");

const TestCtx = struct {
    io: Io,
    hits: std.atomic.Value(u32) = .init(0),
    saw_inm: std.atomic.Value(bool) = .init(false),
    saw_ua: std.atomic.Value(bool) = .init(false),

    fn handle(p: *anyopaque, req: *std.http.Server.Request) void {
        const self: *TestCtx = @ptrCast(@alignCast(p));
        _ = self.hits.fetchAdd(1, .monotonic);
        const t = req.head.target;
        var it = req.iterateHeaders();
        var inm = false;
        while (it.next()) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "if-none-match") and std.mem.eql(u8, h.value, "\"v1\"")) {
                inm = true;
                self.saw_inm.store(true, .monotonic);
            }
            if (std.ascii.eqlIgnoreCase(h.name, "user-agent") and std.mem.eql(u8, h.value, "heron-test/1")) self.saw_ua.store(true, .monotonic);
        }
        if (std.mem.eql(u8, t, "/feed")) {
            if (inm) return req.respond("", .{ .status = .not_modified, .keep_alive = false, .extra_headers = &.{.{ .name = "ETag", .value = "\"v1\"" }} }) catch {};
            req.respond("<rss version=\"2.0\"><channel><title>T</title><item><title>One</title><guid>g1</guid></item></channel></rss>", .{
                .keep_alive = false,
                .extra_headers = &.{ .{ .name = "ETag", .value = "\"v1\"" }, .{ .name = "Last-Modified", .value = "Sat, 01 Jan 2000 00:00:00 GMT" }, .{ .name = "Content-Type", .value = "application/rss+xml; charset=utf-8" } },
            }) catch {};
        } else if (std.mem.eql(u8, t, "/redir")) {
            req.respond("", .{ .status = .found, .keep_alive = false, .extra_headers = &.{.{ .name = "Location", .value = "/feed" }} }) catch {};
        } else if (std.mem.eql(u8, t, "/loop")) {
            req.respond("", .{ .status = .found, .keep_alive = false, .extra_headers = &.{.{ .name = "Location", .value = "/loop" }} }) catch {};
        } else if (std.mem.eql(u8, t, "/limited")) {
            req.respond("slow down", .{ .status = .too_many_requests, .keep_alive = false, .extra_headers = &.{.{ .name = "Retry-After", .value = "7" }} }) catch {};
        } else if (std.mem.eql(u8, t, "/slow")) {
            self.io.sleep(.fromSeconds(5), .awake) catch {
                self.io.recancel(); // the cancel request was consumed here; re-arm so the accept loop sees it too
                return;
            };
            req.respond("late", .{ .keep_alive = false }) catch {};
        } else if (std.mem.eql(u8, t, "/big")) {
            var buf: [16384]u8 = undefined;
            @memset(&buf, 'x');
            req.respond(&buf, .{ .keep_alive = false }) catch {};
        } else req.respond("nope", .{ .status = .not_found, .keep_alive = false }) catch {};
    }
};

fn startServer(io: Io, ctx: *TestCtx, server: *Io.net.Server) !Io.Future(void) {
    server.* = try localserver.listen(io, "127.0.0.1", 0);
    return io.concurrent(localserver.serve, .{ io, server, @as(*anyopaque, ctx), TestCtx.handle });
}

test "http transport: 200 with validators, conditional 304, 429 Retry-After, 404, size cap, timeout" {
    const io = testing.io;
    var ctx: TestCtx = .{ .io = io };
    var server: Io.net.Server = undefined;
    var fut = try startServer(io, &ctx, &server);
    var stopped = false;
    defer if (!stopped) {
        _ = fut.cancel(io);
        server.deinit(io);
    };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var t = HttpTransport.init(testing.allocator, io, "heron-test/1", 1);
    defer t.deinit();
    const tr = t.asTransport();
    const base = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}", .{localserver.port(&server)});

    const r1 = try tr.request(a, .{ .url = try std.fmt.allocPrint(a, "{s}/feed", .{base}) });
    try testing.expectEqual(@as(u16, 200), r1.status);
    try testing.expectEqualStrings("\"v1\"", r1.etag.?);
    try testing.expectEqualStrings("Sat, 01 Jan 2000 00:00:00 GMT", r1.last_modified.?);
    try testing.expectEqualStrings("application/rss+xml; charset=utf-8", r1.content_type.?);
    try testing.expect(std.mem.startsWith(u8, r1.body, "<rss"));
    try testing.expect(ctx.saw_ua.load(.monotonic));

    const r2 = try tr.request(a, .{ .url = try std.fmt.allocPrint(a, "{s}/feed", .{base}), .etag = "\"v1\"" });
    try testing.expectEqual(@as(u16, 304), r2.status);
    try testing.expect(ctx.saw_inm.load(.monotonic));

    const r3 = try tr.request(a, .{ .url = try std.fmt.allocPrint(a, "{s}/limited", .{base}) });
    try testing.expectEqual(@as(u16, 429), r3.status);
    try testing.expectEqualStrings("7", r3.retry_after.?);

    const rr = try tr.request(a, .{ .url = try std.fmt.allocPrint(a, "{s}/redir", .{base}) });
    try testing.expectEqual(@as(u16, 200), rr.status); // relative redirect followed
    try testing.expect(std.mem.startsWith(u8, rr.body, "<rss"));
    const r302 = try tr.request(a, .{ .url = try std.fmt.allocPrint(a, "{s}/redir", .{base}), .follow_redirects = false });
    try testing.expectEqual(@as(u16, 302), r302.status);
    try testing.expectError(error.BadResponse, tr.request(a, .{ .url = try std.fmt.allocPrint(a, "{s}/loop", .{base}) })); // redirect loop is bounded

    const r4 = try tr.request(a, .{ .url = try std.fmt.allocPrint(a, "{s}/missing", .{base}) });
    try testing.expectEqual(@as(u16, 404), r4.status);

    try testing.expectError(error.TooLarge, tr.request(a, .{ .url = try std.fmt.allocPrint(a, "{s}/big", .{base}), .max_body_bytes = 1000 }));

    const t0 = Io.Timestamp.now(io, .awake);
    try testing.expectError(error.Timeout, tr.request(a, .{ .url = try std.fmt.allocPrint(a, "{s}/slow", .{base}) }));
    const took_ms = t0.durationTo(Io.Timestamp.now(io, .awake)).toMilliseconds();
    try testing.expect(took_ms >= 900 and took_ms < 3000);

    // Nothing listening: connection refused is a transport error, not a hang.
    _ = fut.cancel(io);
    server.deinit(io);
    stopped = true;
    try testing.expectError(error.ConnectFailed, tr.request(a, .{ .url = try std.fmt.allocPrint(a, "{s}/feed", .{base}) }));
}
