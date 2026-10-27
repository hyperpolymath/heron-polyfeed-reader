// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell
//! The "feed" adapter: RSS 2.0 / Atom / RSS 1.0 over HTTP(S) with conditional GET.
const std = @import("std");
const adapter = @import("adapter.zig");
const feed = @import("feed.zig");
const transport = @import("transport.zig");
const encoding = @import("encoding.zig");

pub const FeedAdapter = struct {
    pub const type_name = "feed";

    pub fn asAdapter(self: *FeedAdapter) adapter.Adapter {
        return .{ .type_name = type_name, .ptr = self, .fetchFn = fetchImpl };
    }

    fn fetchImpl(_: *anyopaque, ctx: *adapter.Context, source: adapter.Source, cond: adapter.Cond) adapter.Outcome {
        return fetch(ctx, source, cond);
    }
};

fn fail(class: adapter.FailureClass, status: ?u16, retry: ?u32, msg: []const u8) adapter.Outcome {
    return .{ .failed = .{ .class = class, .http_status = status, .retry_after_s = retry, .message = msg } };
}

pub fn fetch(ctx: *adapter.Context, source: adapter.Source, cond: adapter.Cond) adapter.Outcome {
    const resp = ctx.transport.request(ctx.arena, .{
        .url = source.url,
        .etag = cond.etag,
        .last_modified = cond.last_modified,
    }) catch |e| return fail(.transient, null, null, @errorName(e));

    const retry = if (resp.retry_after) |h| adapter.parseRetryAfter(h, ctx.now) else null;
    switch (resp.status) {
        304 => return .{
            .not_modified = .{
                // A 304 may omit validators; keep what we had.
                .etag = resp.etag orelse cond.etag,
                .last_modified = resp.last_modified orelse cond.last_modified,
            },
        },
        200...299 => {},
        429 => return fail(.rate_limited, 429, retry, "429 Too Many Requests"),
        503 => return fail(.rate_limited, 503, retry, "503 Service Unavailable"),
        401, 403, 404, 410 => return fail(.permanent, resp.status, retry, "client error"),
        else => return fail(.transient, resp.status, retry, "unexpected HTTP status"),
    }

    const charset = if (resp.content_type) |ct| encoding.charsetFromContentType(ct) else null;
    const parsed = feed.parse(ctx.arena, source.name, resp.body, charset) catch |e| switch (e) {
        error.OutOfMemory => return fail(.transient, resp.status, null, "out of memory"),
        error.TooLarge => return fail(.malformed, resp.status, null, "feed too large or too deeply nested"),
        error.NotAFeed => return fail(.malformed, resp.status, null, "response is XML but not RSS, Atom or RDF"),
        error.NoRoot => return fail(.malformed, resp.status, null, "response is not XML"),
    };
    // Relative links (Atom permits them; some RSS carries them) are resolved against the URL the
    // feed was actually retrieved from: after a redirect that is the final URL, not the configured one.
    const base_url = resp.final_url orelse source.url;
    for (parsed.items) |*it| it.url = feed.resolveLink(ctx.arena, base_url, it.url) catch it.url;
    return .{ .items = .{
        .items = parsed.items,
        .title = parsed.title,
        .cond = .{ .etag = resp.etag, .last_modified = resp.last_modified },
    } };
}

// ---- tests with a fake transport -------------------------------------------

const FakeTransport = struct {
    responses: []const transport.Response,
    err: ?transport.Error = null,
    calls: usize = 0,
    last_req: ?transport.Request = null,

    fn requestImpl(ptr: *anyopaque, _: std.mem.Allocator, req: transport.Request) transport.Error!transport.Response {
        const self: *FakeTransport = @ptrCast(@alignCast(ptr));
        self.last_req = req;
        defer self.calls += 1;
        if (self.err) |e| return e;
        return self.responses[@min(self.calls, self.responses.len - 1)];
    }
    fn t(self: *FakeTransport) transport.Transport {
        return .{ .ptr = self, .requestFn = requestImpl };
    }
};

const src: adapter.Source = .{ .name = "t", .type_name = "feed", .url = "http://x/feed", .interval_s = 60 };
const body = @embedFile("testdata/dedupe.rss");

fn run(ft: *FakeTransport, cond: adapter.Cond, now: i64, arena: std.mem.Allocator) adapter.Outcome {
    var ctx: adapter.Context = .{ .arena = arena, .transport = ft.t(), .now = now };
    return fetch(&ctx, src, cond);
}

test "200 returns items and validators; conditional headers are sent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ft: FakeTransport = .{ .responses = &.{.{ .status = 200, .body = body, .etag = "\"v2\"", .last_modified = "Sat, 01 Jan 2000 00:00:00 GMT" }} };
    const o = run(&ft, .{ .etag = "\"v1\"", .last_modified = "old" }, 0, arena.allocator());
    try std.testing.expectEqual(@as(usize, 5), o.items.items.len);
    try std.testing.expectEqualStrings("\"v2\"", o.items.cond.etag.?);
    try std.testing.expectEqualStrings("\"v1\"", ft.last_req.?.etag.?);
    try std.testing.expectEqualStrings("old", ft.last_req.?.last_modified.?);
}

test "304 keeps previous validators" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ft: FakeTransport = .{ .responses = &.{.{ .status = 304 }} };
    const o = run(&ft, .{ .etag = "\"v1\"" }, 0, arena.allocator());
    try std.testing.expectEqualStrings("\"v1\"", o.not_modified.etag.?);
}

test "429 honours Retry-After seconds and date; 503 without header" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ft: FakeTransport = .{ .responses = &.{.{ .status = 429, .retry_after = "120" }} };
    var o = run(&ft, .{}, 0, arena.allocator());
    try std.testing.expectEqual(adapter.FailureClass.rate_limited, o.failed.class);
    try std.testing.expectEqual(@as(?u32, 120), o.failed.retry_after_s);
    ft = .{ .responses = &.{.{ .status = 503, .retry_after = "Sat, 01 Jan 2000 00:01:00 GMT" }} };
    o = run(&ft, .{}, 946684800, arena.allocator());
    try std.testing.expectEqual(@as(?u32, 60), o.failed.retry_after_s);
    ft = .{ .responses = &.{.{ .status = 503 }} };
    o = run(&ft, .{}, 0, arena.allocator());
    try std.testing.expectEqual(@as(?u32, null), o.failed.retry_after_s);
}

test "status classes and transport errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cases = [_]struct { u16, adapter.FailureClass }{ .{ 404, .permanent }, .{ 410, .permanent }, .{ 403, .permanent }, .{ 500, .transient }, .{ 502, .transient } };
    for (cases) |c| {
        var ft: FakeTransport = .{ .responses = &.{.{ .status = c[0] }} };
        try std.testing.expectEqual(c[1], run(&ft, .{}, 0, arena.allocator()).failed.class);
    }
    var ft: FakeTransport = .{ .responses = &.{}, .err = error.Timeout };
    try std.testing.expectEqual(adapter.FailureClass.transient, run(&ft, .{}, 0, arena.allocator()).failed.class);
}

test "relative entry links are resolved against the feed URL" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const atom =
        \\<feed xmlns="http://www.w3.org/2005/Atom"><title>t</title>
        \\<entry><id>e1</id><title>one</title><link rel="alternate" href="/posts/1"/></entry>
        \\<entry><id>e2</id><title>two</title><link href="https://other.example/2"/></entry>
        \\</feed>
    ;
    var ft: FakeTransport = .{ .responses = &.{.{ .status = 200, .body = atom }} };
    const o = run(&ft, .{}, 0, arena.allocator());
    try std.testing.expectEqual(@as(usize, 2), o.items.items.len);
    try std.testing.expectEqualStrings("http://x/posts/1", o.items.items[0].url);
    try std.testing.expectEqualStrings("https://other.example/2", o.items.items[1].url);

    // After a redirect the base is the final URL, not the configured one.
    var ft2: FakeTransport = .{ .responses = &.{.{ .status = 200, .body = atom, .final_url = "https://moved.example/blog/feed.xml" }} };
    const o2 = run(&ft2, .{}, 0, arena.allocator());
    try std.testing.expectEqualStrings("https://moved.example/posts/1", o2.items.items[0].url);
}

test "HTML and garbage bodies are malformed, not crashes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ft: FakeTransport = .{ .responses = &.{.{ .status = 200, .body = "<html><body>captcha</body></html>" }} };
    try std.testing.expectEqual(adapter.FailureClass.malformed, run(&ft, .{}, 0, arena.allocator()).failed.class);
    ft = .{ .responses = &.{.{ .status = 200, .body = "\x00\x01\x02" }} };
    try std.testing.expectEqual(adapter.FailureClass.malformed, run(&ft, .{}, 0, arena.allocator()).failed.class);
}
