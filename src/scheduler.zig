// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell
//! Poll scheduler: per-source intervals, jitter, exponential backoff on failure,
//! Retry-After, no busy loops. Pure logic over an injected monotonic `Clock` and
//! `std.Random`, so it is tested with a fake clock and a seeded PRNG.
//!
//! The daemon loop is:   while (running) { while (s.takeDue()) |id| { fetch; s.report…(id) }  sleep(s.sleepMs()); }
//! `sleepMs` is exactly the time until the next source is due (bounded by
//! `max_idle_ms`), so an idle daemon wakes at most once per `max_idle_ms`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const adapter = @import("adapter.zig");

pub const Clock = struct {
    ptr: *anyopaque,
    nowMsFn: *const fn (ptr: *anyopaque) i64,
    pub fn nowMs(self: Clock) i64 {
        return self.nowMsFn(self.ptr);
    }
};

pub const Params = struct {
    /// Jitter applied to every computed delay, in 1/1000ths (100 = ±10%).
    jitter_permille: u32 = 100,
    /// First transient-failure retry delay is min(interval, this); then doubles.
    min_retry_s: u32 = 300,
    /// Transient/malformed/rate-limited backoff never exceeds max(interval, this).
    backoff_cap_s: u32 = 6 * 3600,
    /// Permanent failures (404/410/403/401) back off to at most max(interval, this).
    permanent_cap_s: u32 = 24 * 3600,
    /// Minimum gap between any two dispatches (smooths bursts at start-up/after outages).
    min_gap_ms: u32 = 200,
    /// Upper bound on one sleep (also the wake rate of an idle daemon).
    max_idle_ms: u64 = 3600 * 1000,
    /// First polls are spread uniformly over min(interval, this) to avoid a thundering herd.
    startup_spread_s: u32 = 120,
};

pub const Id = u32;

pub const Entry = struct {
    interval_ms: u64,
    next_due: i64,
    failures: u32 = 0,
    active: bool = true,
    in_flight: bool = false,
};

pub const Scheduler = struct {
    gpa: Allocator,
    clock: Clock,
    rng: std.Random,
    params: Params,
    entries: std.ArrayList(Entry) = .empty,
    last_dispatch: i64 = std.math.minInt(i64) / 2,

    pub fn init(gpa: Allocator, clock: Clock, rng: std.Random, params: Params) Scheduler {
        return .{ .gpa = gpa, .clock = clock, .rng = rng, .params = params };
    }

    pub fn deinit(self: *Scheduler) void {
        self.entries.deinit(self.gpa);
    }

    /// Add a source. `due_in_ms`: when known (restored from storage) the delay until
    /// first poll; otherwise a random start-up offset is used.
    pub fn add(self: *Scheduler, interval_s: u32, due_in_ms: ?u64, failures: u32) Allocator.Error!Id {
        const interval_ms: u64 = @as(u64, @max(interval_s, 1)) * 1000;
        const delay: u64 = due_in_ms orelse blk: {
            const spread = @min(interval_ms, @as(u64, self.params.startup_spread_s) * 1000);
            break :blk self.rng.uintLessThan(u64, spread + 1);
        };
        try self.entries.append(self.gpa, .{
            .interval_ms = interval_ms,
            .next_due = self.clock.nowMs() + @as(i64, @intCast(delay)),
            .failures = failures,
        });
        return @intCast(self.entries.items.len - 1);
    }

    pub fn remove(self: *Scheduler, id: Id) void {
        self.entries.items[id].active = false;
    }

    fn jitter(self: *Scheduler, base_ms: u64, upward_only: bool) u64 {
        const delta: i64 = @intCast(base_ms * self.params.jitter_permille / 1000);
        if (delta == 0) return base_ms;
        const lo: i64 = if (upward_only) 0 else -delta;
        const r = self.rng.intRangeAtMost(i64, lo, delta);
        return @intCast(@as(i64, @intCast(base_ms)) + r);
    }

    /// Un-jittered backoff for the n-th consecutive failure (n >= 1).
    pub fn backoffMs(self: *const Scheduler, interval_ms: u64, n: u32, class: adapter.FailureClass) u64 {
        const p = self.params;
        const base_ms: u64 = switch (class) {
            // Transient problems retry sooner than the poll interval so recovery is quick…
            .transient, .malformed => @min(interval_ms, @as(u64, p.min_retry_s) * 1000),
            // …but a server that is limiting or refusing us is left at the normal cadence.
            .rate_limited, .permanent => interval_ms,
        };
        const cap_s: u64 = if (class == .permanent) p.permanent_cap_s else p.backoff_cap_s;
        const cap_ms = @max(interval_ms, cap_s * 1000);
        const shift: u6 = @intCast(@min(n -| 1, 30));
        const d = std.math.shlExact(u64, base_ms, shift) catch cap_ms;
        return @min(d, cap_ms);
    }

    pub fn reportSuccess(self: *Scheduler, id: Id) void {
        const e = &self.entries.items[id];
        e.in_flight = false;
        e.failures = 0;
        e.next_due = self.clock.nowMs() + @as(i64, @intCast(self.jitter(e.interval_ms, false)));
    }

    pub fn reportFailure(self: *Scheduler, id: Id, class: adapter.FailureClass, retry_after_s: ?u32) void {
        const e = &self.entries.items[id];
        e.in_flight = false;
        e.failures +|= 1;
        var d = self.jitter(self.backoffMs(e.interval_ms, e.failures, class), false);
        if (retry_after_s) |ra| {
            // Retry-After is a floor: never poll earlier than the server asked; jitter only adds.
            const floor_ms = @as(u64, ra) * 1000;
            if (floor_ms > d) d = self.jitter(floor_ms, true);
        }
        e.next_due = self.clock.nowMs() + @as(i64, @intCast(d));
    }

    /// Next entry that is due (earliest first) and allowed by the dispatch gap.
    pub fn takeDue(self: *Scheduler) ?Id {
        const now = self.clock.nowMs();
        if (now < self.last_dispatch + self.params.min_gap_ms) return null;
        var best: ?usize = null;
        for (self.entries.items, 0..) |e, i| {
            if (!e.active or e.in_flight or e.next_due > now) continue;
            if (best == null or e.next_due < self.entries.items[best.?].next_due) best = i;
        }
        const i = best orelse return null;
        self.entries.items[i].in_flight = true;
        self.last_dispatch = now;
        return @intCast(i);
    }

    /// How long the caller may sleep before something could be due. Never 0 while
    /// idle, never more than `max_idle_ms`; 0 means "something is due now".
    pub fn sleepMs(self: *const Scheduler) u64 {
        const now = self.clock.nowMs();
        var earliest: ?i64 = null;
        for (self.entries.items) |e| {
            if (!e.active or e.in_flight) continue;
            if (earliest == null or e.next_due < earliest.?) earliest = e.next_due;
        }
        const e = earliest orelse return self.params.max_idle_ms;
        const t = @max(e, self.last_dispatch + self.params.min_gap_ms);
        if (t <= now) return 0;
        return @min(@as(u64, @intCast(t - now)), self.params.max_idle_ms);
    }

    /// Milliseconds until `id` is next due (0 if overdue), for persisting next-poll times.
    pub fn dueInMs(self: *const Scheduler, id: Id) u64 {
        const d = self.entries.items[id].next_due - self.clock.nowMs();
        return if (d <= 0) 0 else @intCast(d);
    }
};

// ---------------------------------------------------------------------------
// Tests with a fake clock
// ---------------------------------------------------------------------------
const testing = std.testing;

pub const FakeClock = struct {
    t: i64 = 1_000_000,
    fn now(ptr: *anyopaque) i64 {
        const self: *FakeClock = @ptrCast(@alignCast(ptr));
        return self.t;
    }
    pub fn clock(self: *FakeClock) Clock {
        return .{ .ptr = self, .nowMsFn = now };
    }
    pub fn advance(self: *FakeClock, ms: u64) void {
        self.t += @intCast(ms);
    }
};

fn mk(fc: *FakeClock, prng: *std.Random.DefaultPrng, p: Params) Scheduler {
    return Scheduler.init(testing.allocator, fc.clock(), prng.random(), p);
}

const no_jitter: Params = .{ .jitter_permille = 0, .min_gap_ms = 0 };

test "nothing is due before its interval; due exactly at it; success reschedules" {
    var fc: FakeClock = .{};
    var prng = std.Random.DefaultPrng.init(1);
    var s = mk(&fc, &prng, no_jitter);
    defer s.deinit();
    const id = try s.add(600, 0, 0);
    try testing.expectEqual(@as(?Id, id), s.takeDue());
    s.reportSuccess(id);
    try testing.expectEqual(@as(?Id, null), s.takeDue());
    try testing.expectEqual(@as(u64, 600_000), s.sleepMs());
    fc.advance(599_999);
    try testing.expectEqual(@as(?Id, null), s.takeDue());
    try testing.expectEqual(@as(u64, 1), s.sleepMs());
    fc.advance(1);
    try testing.expectEqual(@as(?Id, id), s.takeDue());
}

test "per-source intervals: earliest-due first, independent cadences" {
    var fc: FakeClock = .{};
    var prng = std.Random.DefaultPrng.init(1);
    var s = mk(&fc, &prng, no_jitter);
    defer s.deinit();
    const fast = try s.add(60, 0, 0);
    const slow = try s.add(3600, 0, 0);
    var polls = [_]u32{ 0, 0 };
    var t: u64 = 0;
    while (t < 3600 * 1000) : (t += 1000) {
        while (s.takeDue()) |id| {
            polls[id] += 1;
            s.reportSuccess(id);
        }
        fc.advance(1000);
    }
    try testing.expectEqual(@as(u32, 60), polls[fast]); // t=0,60,…,3540
    try testing.expectEqual(@as(u32, 1), polls[slow]);
}

test "jitter stays within ±10% and varies" {
    var fc: FakeClock = .{};
    var prng = std.Random.DefaultPrng.init(42);
    var s = mk(&fc, &prng, .{ .min_gap_ms = 0 });
    defer s.deinit();
    const id = try s.add(1000, 0, 0);
    var min_seen: u64 = std.math.maxInt(u64);
    var max_seen: u64 = 0;
    for (0..200) |_| {
        _ = s.takeDue();
        s.reportSuccess(id);
        const d = s.dueInMs(id);
        min_seen = @min(min_seen, d);
        max_seen = @max(max_seen, d);
        try testing.expect(d >= 900_000 and d <= 1_100_000);
        fc.advance(d);
    }
    try testing.expect(max_seen - min_seen > 50_000); // actually spread out
}

test "start-up offsets are spread within min(interval, spread)" {
    var fc: FakeClock = .{};
    var prng = std.Random.DefaultPrng.init(7);
    var s = mk(&fc, &prng, .{});
    defer s.deinit();
    var distinct = std.AutoHashMap(u64, void).init(testing.allocator);
    defer distinct.deinit();
    for (0..50) |_| {
        const id = try s.add(3600, null, 0);
        const d = s.dueInMs(id);
        try testing.expect(d <= 120_000);
        try distinct.put(d, {});
    }
    try testing.expect(distinct.count() > 25);
    const small = try s.add(10, null, 0);
    try testing.expect(s.dueInMs(small) <= 10_000);
}

test "exponential backoff: transient doubles from min(interval,5min) up to the cap, success resets" {
    var fc: FakeClock = .{};
    var prng = std.Random.DefaultPrng.init(1);
    var s = mk(&fc, &prng, no_jitter);
    defer s.deinit();
    const id = try s.add(3600, 0, 0);
    const expect_s = [_]u64{ 300, 600, 1200, 2400, 4800, 9600, 19200, 21600, 21600 }; // cap 6h
    for (expect_s) |e| {
        try testing.expectEqual(@as(?Id, id), s.takeDue());
        s.reportFailure(id, .transient, null);
        try testing.expectEqual(e * 1000, s.dueInMs(id));
        fc.advance(e * 1000);
    }
    try testing.expectEqual(@as(?Id, id), s.takeDue());
    s.reportSuccess(id);
    try testing.expectEqual(@as(u32, 0), s.entries.items[id].failures);
    try testing.expectEqual(@as(u64, 3600_000), s.dueInMs(id));
}

test "short interval: backoff starts at the interval and never goes below it" {
    var fc: FakeClock = .{};
    var prng = std.Random.DefaultPrng.init(1);
    var s = mk(&fc, &prng, no_jitter);
    defer s.deinit();
    const id = try s.add(30, 0, 0);
    _ = s.takeDue();
    s.reportFailure(id, .transient, null);
    try testing.expectEqual(@as(u64, 30_000), s.dueInMs(id));
    fc.advance(30_000);
    _ = s.takeDue();
    s.reportFailure(id, .transient, null);
    try testing.expectEqual(@as(u64, 60_000), s.dueInMs(id));
}

test "interval longer than the cap is never shortened below the interval" {
    var fc: FakeClock = .{};
    var prng = std.Random.DefaultPrng.init(1);
    var s = mk(&fc, &prng, no_jitter);
    defer s.deinit();
    const id = try s.add(86400, 0, 0); // daily
    for (0..10) |_| {
        _ = s.takeDue();
        s.reportFailure(id, .rate_limited, null);
        try testing.expect(s.dueInMs(id) >= 86_400_000);
        fc.advance(s.dueInMs(id));
    }
}

test "permanent failures back off to the 24h cap; rate_limited starts at interval" {
    var fc: FakeClock = .{};
    var prng = std.Random.DefaultPrng.init(1);
    var s = mk(&fc, &prng, no_jitter);
    defer s.deinit();
    const id = try s.add(3600, 0, 0);
    var last: u64 = 0;
    for (0..8) |_| {
        _ = s.takeDue();
        s.reportFailure(id, .permanent, null);
        last = s.dueInMs(id);
        fc.advance(last);
    }
    try testing.expectEqual(@as(u64, 24 * 3600 * 1000), last);
    const id2 = try s.add(3600, 0, 0);
    _ = s.takeDue();
    s.reportFailure(id2, .rate_limited, null);
    try testing.expectEqual(@as(u64, 3600_000), s.dueInMs(id2));
}

test "Retry-After is a floor: longer than backoff wins, shorter is ignored, never polls early" {
    var fc: FakeClock = .{};
    var prng = std.Random.DefaultPrng.init(1);
    var s = mk(&fc, &prng, no_jitter);
    defer s.deinit();
    const id = try s.add(60, 0, 0);
    _ = s.takeDue();
    s.reportFailure(id, .rate_limited, 7200);
    try testing.expectEqual(@as(u64, 7200_000), s.dueInMs(id));
    fc.advance(7199_999);
    try testing.expectEqual(@as(?Id, null), s.takeDue());
    fc.advance(1);
    try testing.expectEqual(@as(?Id, id), s.takeDue());
    s.reportFailure(id, .rate_limited, 5); // 5s < backoff (2nd failure => 120s)
    try testing.expectEqual(@as(u64, 120_000), s.dueInMs(id));
    // with jitter on, Retry-After is still a hard floor
    var s2 = mk(&fc, &prng, .{ .min_gap_ms = 0 });
    defer s2.deinit();
    const j = try s2.add(60, 0, 0);
    for (0..100) |_| {
        _ = s2.takeDue();
        s2.reportFailure(j, .rate_limited, 1000);
        try testing.expect(s2.dueInMs(j) >= 1_000_000);
        s2.entries.items[j].failures = 0;
        fc.advance(s2.dueInMs(j));
    }
}

test "dispatch gap spaces out simultaneous due sources" {
    var fc: FakeClock = .{};
    var prng = std.Random.DefaultPrng.init(1);
    var s = mk(&fc, &prng, .{ .jitter_permille = 0, .min_gap_ms = 200 });
    defer s.deinit();
    for (0..3) |_| _ = try s.add(600, 0, 0);
    try testing.expect(s.takeDue() != null);
    try testing.expectEqual(@as(?Id, null), s.takeDue()); // same instant: gap not elapsed
    try testing.expectEqual(@as(u64, 200), s.sleepMs());
    fc.advance(200);
    try testing.expect(s.takeDue() != null);
}

test "no busy loop: idle daemon wakes once per max_idle; with sources, once per due time" {
    var fc: FakeClock = .{};
    var prng = std.Random.DefaultPrng.init(1);
    var s = mk(&fc, &prng, no_jitter);
    defer s.deinit();
    // Idle (no sources): simulate 24h of the daemon loop; count wake-ups.
    var wakes: u32 = 0;
    var elapsed: u64 = 0;
    while (elapsed < 24 * 3600 * 1000) {
        try testing.expectEqual(@as(?Id, null), s.takeDue());
        const sl = s.sleepMs();
        try testing.expect(sl > 0);
        fc.advance(sl);
        elapsed += sl;
        wakes += 1;
    }
    try testing.expectEqual(@as(u32, 24), wakes);
    // One 15-minute source over 24h: ~96 polls, and wakes == polls (+1 final).
    const id = try s.add(900, 0, 0);
    var polls: u32 = 0;
    wakes = 0;
    elapsed = 0;
    while (elapsed < 24 * 3600 * 1000) {
        while (s.takeDue()) |x| {
            polls += 1;
            s.reportSuccess(x);
        }
        const sl = s.sleepMs();
        try testing.expect(sl > 0);
        fc.advance(sl);
        elapsed += sl;
        wakes += 1;
    }
    _ = id;
    try testing.expectEqual(@as(u32, 96), polls);
    try testing.expect(wakes <= polls + 1);
}

test "removed sources are never dispatched; restored schedule is honoured" {
    var fc: FakeClock = .{};
    var prng = std.Random.DefaultPrng.init(1);
    var s = mk(&fc, &prng, no_jitter);
    defer s.deinit();
    const a = try s.add(60, 0, 0);
    s.remove(a);
    try testing.expectEqual(@as(?Id, null), s.takeDue());
    const b = try s.add(600, 90_000, 3); // restored: due in 90s with 3 prior failures
    try testing.expectEqual(@as(u64, 90_000), s.sleepMs());
    try testing.expectEqual(@as(u32, 3), s.entries.items[b].failures);
}
