// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell
//! Engine: run one source through its adapter and persist the outcome. This is the only code
//! that knows both the adapter interface and the store; the scheduler only sees `PollResult`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const adapter = @import("adapter.zig");
const store_mod = @import("store.zig");
const transport = @import("transport.zig");
const dedupe = @import("dedupe.zig");

pub const PollResult = struct {
    ok: bool,
    new_items: usize = 0,
    unchanged: bool = false,
    class: ?adapter.FailureClass = null,
    retry_after_s: ?u32 = null,
    /// Static or arena-less text safe to print after the poll (copied into a small buffer).
    message: [96]u8 = @splat(0),

    pub fn messageSlice(self: *const PollResult) []const u8 {
        return std.mem.sliceTo(&self.message, 0);
    }
    fn setMessage(self: *PollResult, text: []const u8) void {
        const n = @min(text.len, self.message.len - 1);
        @memcpy(self.message[0..n], text[0..n]);
        self.message[n] = 0;
    }
};

pub const Engine = struct {
    gpa: Allocator,
    store: *store_mod.Store,
    registry: *const adapter.Registry,
    transport: transport.Transport,

    /// Poll `source` once. `now` is wall-clock Unix seconds.
    pub fn poll(self: *Engine, source: adapter.Source, now: i64) PollResult {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();

        var res: PollResult = .{ .ok = false };
        const ad = self.registry.find(source.type_name) orelse {
            res.class = .permanent;
            res.setMessage("no adapter for this source type");
            self.recordFailure(a, source.name, now, res.messageSlice());
            return res;
        };
        var st = self.store.getSourceState(a, source.name) catch store_mod.SourceState{};
        const cond: adapter.Cond = .{ .etag = st.etag, .last_modified = st.last_modified, .state = st.adapter_state };
        var ctx: adapter.Context = .{ .arena = a, .transport = self.transport, .now = now };

        st.last_check = now;
        switch (ad.fetch(&ctx, source, cond)) {
            .items => |b| {
                const n = self.store.ingest(b.items, now) catch |e| {
                    // Storage failure: do not advance validators, so the next poll refetches.
                    res.class = .transient;
                    res.setMessage(@errorName(e));
                    self.recordFailure(a, source.name, now, @errorName(e));
                    return res;
                };
                st.etag = b.cond.etag;
                st.last_modified = b.cond.last_modified;
                st.adapter_state = b.cond.state orelse st.adapter_state;
                st.failures = 0;
                st.last_ok = now;
                st.last_error = null;
                res.ok = true;
                res.new_items = n;
            },
            .not_modified => |c| {
                st.etag = c.etag;
                st.last_modified = c.last_modified;
                st.adapter_state = c.state orelse st.adapter_state;
                st.failures = 0;
                st.last_ok = now;
                st.last_error = null;
                res.ok = true;
                res.unchanged = true;
            },
            .failed => |f| {
                st.failures +|= 1;
                st.last_error = f.message;
                res.class = f.class;
                res.retry_after_s = f.retry_after_s;
                res.setMessage(f.message);
            },
        }
        self.store.putSourceState(source.name, st) catch |e| std.log.warn("saving state for {s}: {s}", .{ source.name, @errorName(e) });
        return res;
    }

    fn recordFailure(self: *Engine, a: Allocator, name: []const u8, now: i64, msg: []const u8) void {
        var st = self.store.getSourceState(a, name) catch store_mod.SourceState{};
        st.failures +|= 1;
        st.last_check = now;
        st.last_error = msg;
        self.store.putSourceState(name, st) catch {};
    }
};

// ---------------------------------------------------------------------------
const testing = std.testing;
const feed_adapter = @import("feed_adapter.zig");

const Fake = struct {
    queue: []const transport.Response,
    err: ?transport.Error = null,
    i: usize = 0,
    inm_buf: [32]u8 = undefined,
    seen_inm: ?[]const u8 = null,
    fn req(p: *anyopaque, _: Allocator, r: transport.Request) transport.Error!transport.Response {
        const self: *Fake = @ptrCast(@alignCast(p));
        self.seen_inm = if (r.etag) |e| blk: {
            @memcpy(self.inm_buf[0..e.len], e); // borrowed only for the duration of the call
            break :blk self.inm_buf[0..e.len];
        } else null;
        if (self.err) |e| return e;
        defer self.i += 1;
        return self.queue[@min(self.i, self.queue.len - 1)];
    }
    fn tr(self: *Fake) transport.Transport {
        return .{ .ptr = self, .requestFn = req };
    }
};

const feed_body = @embedFile("testdata/dedupe.rss");

test "poll: 200 ingests, validators persist, 304 is cheap, failure counts, success resets" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer path_arena.deinit();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", path_arena.allocator());
    var store = try store_mod.Store.open(testing.allocator, testing.io, dir, true);
    defer store.close();

    var fa: feed_adapter.FeedAdapter = .{};
    var reg: adapter.Registry = .{};
    try reg.register(fa.asAdapter());
    var fake: Fake = .{ .queue = &.{
        .{ .status = 200, .body = feed_body, .etag = "\"e1\"" },
        .{ .status = 304 },
        .{ .status = 500 },
        .{ .status = 429, .retry_after = "90" },
        .{ .status = 200, .body = feed_body, .etag = "\"e2\"" },
    } };
    var eng: Engine = .{ .gpa = testing.allocator, .store = &store, .registry = &reg, .transport = fake.tr() };
    const src: adapter.Source = .{ .name = "s", .type_name = "feed", .url = "http://x/", .interval_s = 60 };

    var r = eng.poll(src, 100);
    try testing.expect(r.ok);
    try testing.expectEqual(@as(usize, 5), r.new_items);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var st = try store.getSourceState(arena.allocator(), "s");
    try testing.expectEqualStrings("\"e1\"", st.etag.?);
    try testing.expectEqual(@as(?i64, 100), st.last_ok);

    r = eng.poll(src, 200);
    try testing.expect(r.ok and r.unchanged);
    try testing.expectEqualStrings("\"e1\"", fake.seen_inm.?); // conditional GET used stored validator
    try testing.expectEqual(@as(usize, 0), r.new_items);

    r = eng.poll(src, 300);
    try testing.expect(!r.ok);
    try testing.expectEqual(adapter.FailureClass.transient, r.class.?);
    st = try store.getSourceState(arena.allocator(), "s");
    try testing.expectEqual(@as(u32, 1), st.failures);
    try testing.expectEqualStrings("\"e1\"", st.etag.?); // validators survive failures

    r = eng.poll(src, 400);
    try testing.expectEqual(adapter.FailureClass.rate_limited, r.class.?);
    try testing.expectEqual(@as(?u32, 90), r.retry_after_s);
    st = try store.getSourceState(arena.allocator(), "s");
    try testing.expectEqual(@as(u32, 2), st.failures);

    r = eng.poll(src, 500); // same items again: nothing new
    try testing.expect(r.ok);
    try testing.expectEqual(@as(usize, 0), r.new_items);
    st = try store.getSourceState(arena.allocator(), "s");
    try testing.expectEqual(@as(u32, 0), st.failures);
    try testing.expectEqualStrings("\"e2\"", st.etag.?);
}

test "poll: unknown adapter type is a permanent failure, not a crash" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer path_arena.deinit();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", path_arena.allocator());
    var store = try store_mod.Store.open(testing.allocator, testing.io, dir, true);
    defer store.close();
    var reg: adapter.Registry = .{};
    var fake: Fake = .{ .queue = &.{} };
    var eng: Engine = .{ .gpa = testing.allocator, .store = &store, .registry = &reg, .transport = fake.tr() };
    const r = eng.poll(.{ .name = "n", .type_name = "nntp", .url = "news://x", .interval_s = 60 }, 1);
    try testing.expectEqual(adapter.FailureClass.permanent, r.class.?);
}
