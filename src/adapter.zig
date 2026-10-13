// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell
//! The adapter interface: one `fetch(source)` per source *type*, returning normalised
//! items or a status result. The scheduler, storage, CLI and UI see only this file.
//! Adding NNTP/Gemini/Gopher/ActivityPub/AT Protocol/WebSub-fed sources means
//! implementing `Adapter` and calling `Registry.register`; nothing in the core changes.
const std = @import("std");
const Item = @import("item.zig").Item;
const Transport = @import("transport.zig").Transport;
const dates = @import("dates.zig");

/// A configured source, as the adapter sees it. `options` is the adapter-private
/// remainder of the config entry (raw JSON object text, or "" if none), so new
/// adapter types can carry their own settings without core changes.
pub const Source = struct {
    name: []const u8,
    type_name: []const u8,
    url: []const u8,
    interval_s: u32,
    options: []const u8 = "",
};

/// Opaque-to-the-core resume token. For HTTP adapters: conditional-GET validators.
/// Other adapters may reuse the fields (e.g. NNTP stores the last article number in `etag`).
pub const Cond = struct {
    etag: ?[]const u8 = null,
    last_modified: ?[]const u8 = null,
    /// Adapter-private persisted state (opaque to the core): e.g. a monitor keeps its last
    /// up/down verdict and body hash here; an NNTP adapter would keep the last article number.
    state: ?[]const u8 = null,
};

pub const FailureClass = enum {
    transient, // network error, 5xx: retry with backoff
    rate_limited, // 429/503 with or without Retry-After
    permanent, // 401/403/404/410: retry slowly (capped long backoff), keep source
    malformed, // reachable but unparsable
};

pub const Failure = struct {
    class: FailureClass,
    http_status: ?u16 = null,
    /// Seconds the server asked us to wait (already clamped), if any.
    retry_after_s: ?u32 = null,
    message: []const u8 = "",
};

pub const Batch = struct {
    items: []Item,
    cond: Cond = .{},
    /// Feed/channel title, if known.
    title: ?[]const u8 = null,
};

pub const Outcome = union(enum) {
    items: Batch,
    not_modified: Cond,
    failed: Failure,
};

/// Per-fetch context. `arena` owns everything the outcome points to; the caller
/// frees it after persisting. `now` is Unix seconds (injected so Retry-After
/// HTTP-dates are testable).
pub const Context = struct {
    arena: std.mem.Allocator,
    transport: Transport,
    now: i64,
};

pub const Adapter = struct {
    type_name: []const u8,
    ptr: *anyopaque,
    fetchFn: *const fn (ptr: *anyopaque, ctx: *Context, source: Source, cond: Cond) Outcome,

    pub fn fetch(self: Adapter, ctx: *Context, source: Source, cond: Cond) Outcome {
        return self.fetchFn(self.ptr, ctx, source, cond);
    }
};

pub const Registry = struct {
    list: [16]Adapter = undefined,
    len: usize = 0,

    pub fn register(self: *Registry, a: Adapter) error{RegistryFull}!void {
        if (self.len == self.list.len) return error.RegistryFull;
        self.list[self.len] = a;
        self.len += 1;
    }

    pub fn find(self: *const Registry, type_name: []const u8) ?Adapter {
        for (self.list[0..self.len]) |a| if (std.mem.eql(u8, a.type_name, type_name)) return a;
        return null;
    }
};

pub const max_retry_after_s: u32 = 7 * 24 * 3600;

/// Parse a Retry-After header (delta-seconds or HTTP-date), clamped to [0, 7 days].
pub fn parseRetryAfter(value: []const u8, now: i64) ?u32 {
    const v = std.mem.trim(u8, value, " \t");
    if (v.len == 0) return null;
    if (std.fmt.parseInt(u64, v, 10)) |secs| return @intCast(@min(secs, max_retry_after_s)) else |_| {}
    const t = dates.parse(v) orelse return null;
    if (t <= now) return 0;
    return @intCast(@min(t - now, max_retry_after_s));
}

test "retry-after delta and date" {
    try std.testing.expectEqual(@as(?u32, 120), parseRetryAfter("120", 0));
    try std.testing.expectEqual(@as(?u32, max_retry_after_s), parseRetryAfter("99999999999", 0));
    try std.testing.expectEqual(@as(?u32, 30), parseRetryAfter("Sat, 01 Jan 2000 00:00:30 GMT", 946684800));
    try std.testing.expectEqual(@as(?u32, 0), parseRetryAfter("Sat, 01 Jan 2000 00:00:00 GMT", 946684900));
    try std.testing.expectEqual(@as(?u32, null), parseRetryAfter("soon", 0));
}

test "registry lookup" {
    var reg: Registry = .{};
    var dummy: u8 = 0;
    const f = struct {
        fn f(_: *anyopaque, _: *Context, _: Source, _: Cond) Outcome {
            return .{ .failed = .{ .class = .transient } };
        }
    }.f;
    try reg.register(.{ .type_name = "feed", .ptr = &dummy, .fetchFn = f });
    try std.testing.expect(reg.find("feed") != null);
    try std.testing.expect(reg.find("nntp") == null);
}
