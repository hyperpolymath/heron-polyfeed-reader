// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell
//! The "monitor" adapter: HTTP(S) up/down checks, change detection and TLS certificate expiry.
//!
//! * Alerts are *transitions*, not check results: DOWN after `down_after` consecutive failed checks
//!   (default 2), UP on the first success after that, CHANGED when the page content changes (at most
//!   one alert per hour per monitor), CERT when the certificate is within `cert_warn_days` of expiry
//!   or expired (once per certificate), BLOCKED when robots.txt forbids the request.
//! * Change detection: conditional GET with the stored ETag / Last-Modified first (304 = unchanged,
//!   no body transferred). When the server sends a body, the SHA-256 of its *normalised text*
//!   (scripts, styles, comments and markup removed, whitespace collapsed) decides: a changed
//!   validator with an identical hash is not a change (many servers emit unstable ETags).
//! * robots.txt (RFC 9309) is consulted before each request, cached for 24 h.
//! The monitor reports every outcome as success to the scheduler (so a down site keeps being
//! checked at its normal interval instead of being backed off); its verdict lives in the alert items
//! and in the adapter state blob.
const std = @import("std");
const Allocator = std.mem.Allocator;
const adapter = @import("adapter.zig");
const Item = @import("item.zig").Item;
const transport = @import("transport.zig");
const robots_mod = @import("robots.zig");
const util = @import("util.zig");

pub const day_s: i64 = 86400;
const robots_ttl_s: i64 = day_s;
const cert_recheck_s: i64 = 6 * 3600;
const change_alert_gap_s: i64 = 3600;
const max_body: usize = 2 * 1024 * 1024;
const max_robots_cache = 16 * 1024;

pub const Options = struct {
    expect_status: u16 = 200,
    detect_changes: bool = true,
    check_robots: bool = true,
    cert_warn_days: u32 = 14,
    down_after: u32 = 2,
};

/// Persisted in `sources.adapter_state` as JSON.
pub const State = struct {
    up: ?bool = null,
    fails: u32 = 0,
    since: i64 = 0,
    checked: i64 = 0,
    status: u16 = 0,
    err: []const u8 = "",
    hash: []const u8 = "",
    last_change: i64 = 0,
    cert_not_after: i64 = 0,
    cert_checked: i64 = 0,
    cert_alert: []const u8 = "",
    robots_at: i64 = 0,
    robots_txt: []const u8 = "",
    blocked: bool = false,
};

pub const MonitorAdapter = struct {
    pub const type_name = "monitor";
    /// Product token used to select robots.txt groups.
    ua_token: []const u8 = "heron-polyfeed-reader",

    pub fn asAdapter(self: *MonitorAdapter) adapter.Adapter {
        return .{ .type_name = type_name, .ptr = self, .fetchFn = fetchImpl };
    }

    fn fetchImpl(ptr: *anyopaque, ctx: *adapter.Context, source: adapter.Source, cond: adapter.Cond) adapter.Outcome {
        const self: *MonitorAdapter = @ptrCast(@alignCast(ptr));
        return check(self, ctx, source, cond) catch |e| .{ .failed = .{ .class = .transient, .message = @errorName(e) } };
    }
};

/// Parse state JSON (all slices allocated from `a`); bad or empty input yields defaults.
pub fn parseState(a: Allocator, text: ?[]const u8) State {
    const t = text orelse return .{};
    return std.json.parseFromSliceLeaky(State, a, t, .{ .ignore_unknown_fields = true }) catch .{};
}

pub fn parseOptions(a: Allocator, text: []const u8) Options {
    if (text.len == 0) return .{};
    return std.json.parseFromSliceLeaky(Options, a, text, .{ .ignore_unknown_fields = true }) catch .{};
}

/// Visible-text normalisation for change hashing.
pub fn normalizeText(a: Allocator, html: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    var space = true;
    while (i < html.len) {
        const c = html[i];
        if (c == '<') {
            const rest = html[i..];
            if (std.mem.startsWith(u8, rest, "<!--")) {
                i += if (std.mem.find(u8, rest, "-->")) |e| e + 3 else rest.len;
            } else if (startsWithIgnoreCase(rest, "<script") or startsWithIgnoreCase(rest, "<style")) {
                const close: []const u8 = if (startsWithIgnoreCase(rest, "<script")) "</script" else "</style";
                const e = std.ascii.findIgnoreCase(rest, close) orelse rest.len;
                const gt = std.mem.indexOfScalarPos(u8, rest, e, '>') orelse rest.len - 1;
                i += gt + 1;
            } else {
                const gt = std.mem.indexOfScalar(u8, rest, '>') orelse rest.len - 1;
                i += gt + 1;
            }
            if (!space) {
                try out.append(a, ' ');
                space = true;
            }
            continue;
        }
        if (std.ascii.isWhitespace(c)) {
            if (!space) try out.append(a, ' ');
            space = true;
        } else {
            try out.append(a, c);
            space = false;
        }
        i += 1;
    }
    while (out.items.len > 0 and out.items[out.items.len - 1] == ' ') out.items.len -= 1;
    return out.items;
}

fn startsWithIgnoreCase(s: []const u8, prefix: []const u8) bool {
    return s.len >= prefix.len and std.ascii.eqlIgnoreCase(s[0..prefix.len], prefix);
}

fn hashHex(a: Allocator, text: []const u8) Allocator.Error![]const u8 {
    var d: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(text, &d, .{});
    return std.fmt.allocPrint(a, "{x}", .{d[0..16]});
}

const Alerts = struct {
    a: Allocator,
    source: adapter.Source,
    now: i64,
    list: std.ArrayList(Item) = .empty,

    fn add(self: *Alerts, id: []const u8, title: []const u8, body: []const u8) Allocator.Error!void {
        try self.list.append(self.a, .{
            .source = self.source.name,
            .id = id,
            .title = title,
            .url = self.source.url,
            .published = self.now,
            .body = body,
            .kind = .alert,
        });
    }
};

const Target = struct { https: bool, host: []const u8, port: u16, path_query: []const u8, robots_url: []const u8 };

fn parseTarget(a: Allocator, url: []const u8) !Target {
    const uri = try std.Uri.parse(url);
    const https = std.ascii.eqlIgnoreCase(uri.scheme, "https");
    const host_c = uri.host orelse return error.InvalidUrl;
    const host = try host_c.toRawMaybeAlloc(a);
    const port: u16 = uri.port orelse if (https) 443 else 80;
    const path = try uri.path.toRawMaybeAlloc(a);
    const q: ?[]const u8 = if (uri.query) |qc| try qc.toRawMaybeAlloc(a) else null;
    const pq = try std.fmt.allocPrint(a, "{s}{s}{s}", .{ if (path.len == 0) "/" else path, if (q != null) "?" else "", q orelse "" });
    const default_port: u16 = if (https) 443 else 80;
    const hostport = if (port == default_port) host else try std.fmt.allocPrint(a, "{s}:{d}", .{ host, port });
    const robots_url = try std.fmt.allocPrint(a, "{s}://{s}/robots.txt", .{ if (https) "https" else "http", hostport });
    return .{ .https = https, .host = host, .port = port, .path_query = pq, .robots_url = robots_url };
}

pub fn check(self: *MonitorAdapter, ctx: *adapter.Context, source: adapter.Source, cond: adapter.Cond) !adapter.Outcome {
    const a = ctx.arena;
    const now = ctx.now;
    const opt = parseOptions(a, source.options);
    var st = parseState(a, cond.state);
    var alerts: Alerts = .{ .a = a, .source = source, .now = now };
    const target = parseTarget(a, source.url) catch return .{ .failed = .{ .class = .permanent, .message = "invalid monitor url" } };

    var new_etag = cond.etag;
    var new_lm = cond.last_modified;
    st.checked = now;

    // ---- robots.txt -------------------------------------------------------------------------
    var robots_failed: ?[]const u8 = null;
    var skip_request = false;
    if (opt.check_robots) {
        if (st.robots_at == 0 or now - st.robots_at >= robots_ttl_s) {
            if (ctx.transport.request(a, .{ .url = target.robots_url, .max_body_bytes = 256 * 1024 })) |rr| {
                switch (robots_mod.availabilityForStatus(rr.status)) {
                    .rules => {
                        st.robots_txt = rr.body[0..@min(rr.body.len, max_robots_cache)];
                        st.robots_at = now;
                    },
                    .allow_all => {
                        st.robots_txt = "";
                        st.robots_at = now;
                    },
                    .unreachable_ => robots_failed = "robots.txt unavailable (server error); not requesting the page",
                }
            } else |e| robots_failed = try std.fmt.allocPrint(a, "robots.txt unreachable: {s}", .{@errorName(e)});
        }
        if (robots_failed == null and !robots_mod.allowed(st.robots_txt, self.ua_token, target.path_query)) {
            skip_request = true;
            if (!st.blocked) {
                st.blocked = true;
                try alerts.add(
                    try std.fmt.allocPrint(a, "blocked:{d}", .{now}),
                    try std.fmt.allocPrint(a, "BLOCKED: robots.txt forbids monitoring {s}", .{source.name}),
                    try std.fmt.allocPrint(a, "{s} disallows {s} for {s}. Monitoring of this URL is paused until robots.txt allows it (or set check_robots=false for a site you own).", .{ target.robots_url, target.path_query, self.ua_token }),
                );
            }
        } else if (robots_failed == null) st.blocked = false;
    }

    // ---- the request ------------------------------------------------------------------------
    var resp: ?transport.Response = null;
    var err_text: []const u8 = "";
    if (robots_failed) |m| {
        err_text = m;
    } else if (!skip_request) {
        const want_body = opt.detect_changes;
        var req: transport.Request = .{
            .url = source.url,
            .method = if (want_body) .get else .head,
            .max_body_bytes = max_body,
            .etag = if (want_body) cond.etag else null,
            .last_modified = if (want_body) cond.last_modified else null,
        };
        var result = ctx.transport.request(a, req);
        if (result) |r| {
            if (req.method == .head and (r.status == 405 or r.status == 501)) {
                req.method = .get;
                result = ctx.transport.request(a, req);
            }
        } else |_| {}
        if (result) |r| resp = r else |e| err_text = try std.fmt.allocPrint(a, "{s}", .{@errorName(e)});
    }

    if (!skip_request) {
        const ok = if (resp) |r| (r.status == opt.expect_status or (r.status == 304 and opt.detect_changes)) else false;
        if (resp) |r| {
            st.status = r.status;
            if (!ok) err_text = try std.fmt.allocPrint(a, "HTTP {d} (expected {d})", .{ r.status, opt.expect_status });
        } else st.status = 0;
        st.err = if (ok) "" else err_text;

        if (ok) {
            st.fails = 0;
            if (st.up == false) {
                try alerts.add(
                    try std.fmt.allocPrint(a, "up:{d}", .{now}),
                    try std.fmt.allocPrint(a, "UP: {s} is back", .{source.name}),
                    try std.fmt.allocPrint(a, "{s} answered HTTP {d} after being down for {s}.", .{ source.url, st.status, spanText(a, now - st.since) }),
                );
            }
            if (st.up != true) {
                st.up = true;
                st.since = now;
            }
        } else {
            st.fails +|= 1;
            if (st.fails >= opt.down_after and st.up != false) {
                try alerts.add(
                    try std.fmt.allocPrint(a, "down:{d}", .{now}),
                    try std.fmt.allocPrint(a, "DOWN: {s} — {s}", .{ source.name, st.err }),
                    try std.fmt.allocPrint(a, "{s} failed {d} consecutive check(s): {s}.", .{ source.url, st.fails, st.err }),
                );
                st.up = false;
                st.since = now;
            }
        }

        // ---- change detection ---------------------------------------------------------------
        if (ok and opt.detect_changes) if (resp) |r| if (r.status != 304) {
            new_etag = r.etag;
            new_lm = r.last_modified;
            const h = try hashHex(a, try normalizeText(a, r.body));
            if (st.hash.len > 0 and !std.mem.eql(u8, st.hash, h)) {
                if (st.last_change == 0 or now - st.last_change >= change_alert_gap_s) {
                    try alerts.add(
                        try std.fmt.allocPrint(a, "changed:{s}:{d}", .{ h[0..8], now }),
                        try std.fmt.allocPrint(a, "CHANGED: {s}", .{source.name}),
                        try std.fmt.allocPrint(a, "The text content of {s} changed (hash {s} → {s}).", .{ source.url, st.hash[0..8], h[0..8] }),
                    );
                    st.last_change = now;
                }
            }
            st.hash = h;
        };
    }

    // ---- TLS certificate expiry ----------------------------------------------------------------
    if (target.https and !skip_request and (st.cert_checked == 0 or now - st.cert_checked >= cert_recheck_s)) {
        if (ctx.transport.certNotAfter(target.host, target.port)) |na| {
            st.cert_not_after = na;
            st.cert_checked = now;
            const days_left = @divFloor(na - now, day_s);
            const kind: ?[]const u8 = if (na <= now) "expired" else if (opt.cert_warn_days > 0 and days_left <= opt.cert_warn_days) "warn" else null;
            if (kind) |k| {
                const id = try std.fmt.allocPrint(a, "cert:{d}:{s}", .{ na, k });
                if (!std.mem.eql(u8, id, st.cert_alert)) {
                    var db: [32]u8 = undefined;
                    try alerts.add(
                        id,
                        if (na <= now)
                            try std.fmt.allocPrint(a, "CERT EXPIRED: {s}", .{source.name})
                        else
                            try std.fmt.allocPrint(a, "CERT: {s} expires in {d} day(s)", .{ source.name, days_left }),
                        try std.fmt.allocPrint(a, "The TLS certificate served by {s}:{d} {s} {s} UTC.", .{ target.host, target.port, if (na <= now) "expired on" else "expires on", util.fmtDate(&db, na) }),
                    );
                    st.cert_alert = id;
                }
            }
        }
    }

    const state_json = try std.json.Stringify.valueAlloc(a, st, .{});
    const new_cond: adapter.Cond = .{ .etag = new_etag, .last_modified = new_lm, .state = state_json };
    if (alerts.list.items.len > 0) return .{ .items = .{ .items = alerts.list.items, .cond = new_cond } };
    return .{ .not_modified = new_cond };
}

fn spanText(a: Allocator, secs: i64) []const u8 {
    const buf = a.alloc(u8, 16) catch return "a while";
    return util.fmtSpan(buf, secs);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
const testing = std.testing;

const Fake = struct {
    main: ?transport.Response = .{ .status = 200, .body = "<html><body>hello</body></html>" },
    main_err: ?transport.Error = null,
    robots: ?transport.Response = .{ .status = 404 },
    robots_err: ?transport.Error = null,
    cert: ?i64 = null,
    main_calls: u32 = 0,
    robots_calls: u32 = 0,
    cert_calls: u32 = 0,
    last_method: transport.Method = .get,
    sent_etag: bool = false,

    fn req(p: *anyopaque, _: Allocator, r: transport.Request) transport.Error!transport.Response {
        const self: *Fake = @ptrCast(@alignCast(p));
        if (std.mem.endsWith(u8, r.url, "/robots.txt")) {
            self.robots_calls += 1;
            if (self.robots_err) |e| return e;
            return self.robots.?;
        }
        self.main_calls += 1;
        self.last_method = r.method;
        self.sent_etag = r.etag != null;
        if (self.main_err) |e| return e;
        if (r.method == .head and self.main.?.status == 405) return self.main.?;
        return self.main.?;
    }
    fn certFn(p: *anyopaque, _: []const u8, _: u16) ?i64 {
        const self: *Fake = @ptrCast(@alignCast(p));
        self.cert_calls += 1;
        return self.cert;
    }
    fn tr(self: *Fake) transport.Transport {
        return .{ .ptr = self, .requestFn = req, .certNotAfterFn = certFn };
    }
};

const Harness = struct {
    arena: std.heap.ArenaAllocator,
    fake: Fake = .{},
    mon: MonitorAdapter = .{},
    cond: adapter.Cond = .{},
    src: adapter.Source = .{ .name = "site", .type_name = "monitor", .url = "https://example.org/page?x=1", .interval_s = 60, .options = "{}" },

    fn init() Harness {
        return .{ .arena = std.heap.ArenaAllocator.init(testing.allocator) };
    }
    fn deinit(h: *Harness) void {
        h.arena.deinit();
    }
    /// Run one check at `now`; returns alert titles (empty slice if none). Updates stored cond.
    fn step(h: *Harness, now: i64) ![]const []const u8 {
        const a = h.arena.allocator();
        var ctx: adapter.Context = .{ .arena = a, .transport = h.fake.tr(), .now = now };
        const out = try check(&h.mon, &ctx, h.src, h.cond);
        var titles: std.ArrayList([]const u8) = .empty;
        switch (out) {
            .items => |b| {
                h.cond = b.cond;
                for (b.items) |it| {
                    try testing.expectEqual(@import("item.zig").Kind.alert, it.kind);
                    try titles.append(a, it.title);
                }
            },
            .not_modified => |c| h.cond = c,
            .failed => return error.UnexpectedFailure,
        }
        return titles.items;
    }
    fn state(h: *Harness) State {
        return parseState(h.arena.allocator(), h.cond.state);
    }
};

fn expectTitle(titles: []const []const u8, prefix: []const u8) !void {
    try testing.expectEqual(@as(usize, 1), titles.len);
    try testing.expect(std.mem.startsWith(u8, titles[0], prefix));
}

test "up/down: baseline silent; DOWN only after 2 failures; no repeat alerts; UP once on recovery" {
    var h = Harness.init();
    defer h.deinit();
    try testing.expectEqual(@as(usize, 0), (try h.step(1000)).len); // first success: baseline, no alert
    try testing.expectEqual(@as(?bool, true), h.state().up);

    h.fake.main = .{ .status = 503 };
    try testing.expectEqual(@as(usize, 0), (try h.step(1060)).len); // 1st failure: not yet
    try expectTitle(try h.step(1120), "DOWN: site"); // 2nd failure: transition
    try testing.expectEqual(@as(usize, 0), (try h.step(1180)).len); // still down: silent
    try testing.expectEqual(@as(usize, 0), (try h.step(1240)).len);
    try testing.expectEqual(@as(?bool, false), h.state().up);
    try testing.expectEqual(@as(u32, 4), h.state().fails);

    h.fake.main = .{ .status = 200, .body = "<html><body>hello</body></html>" };
    const t = try h.step(1300);
    try expectTitle(t, "UP: site");
    try testing.expectEqual(@as(usize, 0), (try h.step(1360)).len);
}

test "a single blip does not alert; transport errors count as failures" {
    var h = Harness.init();
    defer h.deinit();
    _ = try h.step(1000);
    h.fake.main_err = error.Timeout;
    try testing.expectEqual(@as(usize, 0), (try h.step(1060)).len);
    h.fake.main_err = null;
    try testing.expectEqual(@as(usize, 0), (try h.step(1120)).len); // recovered before down_after
    try testing.expectEqual(@as(?bool, true), h.state().up);
    h.fake.main_err = error.ConnectFailed;
    _ = try h.step(1180);
    const t = try h.step(1240);
    try expectTitle(t, "DOWN: site");
    try testing.expect(std.mem.indexOf(u8, t[0], "ConnectFailed") != null);
}

test "down on the very first checks alerts after down_after failures; down_after=1 alerts at once" {
    var h = Harness.init();
    defer h.deinit();
    h.fake.main = .{ .status = 500 };
    try testing.expectEqual(@as(usize, 0), (try h.step(1000)).len);
    try expectTitle(try h.step(1060), "DOWN");
    var h2 = Harness.init();
    defer h2.deinit();
    h2.src.options = "{\"down_after\":1}";
    h2.fake.main = .{ .status = 500 };
    try expectTitle(try h2.step(1000), "DOWN");
}

test "expect_status: 204 expected, 200 is a failure" {
    var h = Harness.init();
    defer h.deinit();
    h.src.options = "{\"expect_status\":204,\"down_after\":1}";
    h.fake.main = .{ .status = 204 };
    try testing.expectEqual(@as(usize, 0), (try h.step(1000)).len);
    h.fake.main = .{ .status = 200, .body = "x" };
    try expectTitle(try h.step(1060), "DOWN");
}

test "change detection: hash of normalised text; markup/script noise ignored; validators first" {
    var h = Harness.init();
    defer h.deinit();
    h.fake.main = .{ .status = 200, .body = "<html><script>var t=1</script><body><p>Price:  10</p></body></html>", .etag = "\"a\"" };
    _ = try h.step(1000);
    try testing.expectEqualStrings("\"a\"", h.cond.etag.?);

    // Same visible text, different markup/script/whitespace and a *different* ETag => not a change.
    h.fake.main = .{ .status = 200, .body = "<html><script>var t=2</script><body>\n<div class=x>Price: 10</div></body></html>", .etag = "\"b\"" };
    try testing.expectEqual(@as(usize, 0), (try h.step(1060)).len);
    try testing.expect(h.fake.sent_etag); // conditional GET was attempted
    try testing.expectEqualStrings("\"b\"", h.cond.etag.?);

    // 304 => unchanged, body never examined.
    h.fake.main = .{ .status = 304 };
    try testing.expectEqual(@as(usize, 0), (try h.step(1120)).len);
    try testing.expectEqual(@as(?bool, true), h.state().up);

    // Real text change => alert.
    h.fake.main = .{ .status = 200, .body = "<body>Price: 12</body>", .etag = "\"c\"" };
    try expectTitle(try h.step(1180), "CHANGED: site");
}

test "change alerts are rate limited to one per hour; hash still tracks" {
    var h = Harness.init();
    defer h.deinit();
    h.fake.main = .{ .status = 200, .body = "v0" };
    _ = try h.step(10_000);
    h.fake.main = .{ .status = 200, .body = "v1" };
    try expectTitle(try h.step(10_060), "CHANGED");
    h.fake.main = .{ .status = 200, .body = "v2" };
    try testing.expectEqual(@as(usize, 0), (try h.step(10_120)).len); // within the hour: suppressed
    h.fake.main = .{ .status = 200, .body = "v3" };
    try expectTitle(try h.step(10_060 + 3600), "CHANGED"); // after the gap
}

test "detect_changes=false uses HEAD, falls back to GET on 405, never alerts on content" {
    var h = Harness.init();
    defer h.deinit();
    h.src.options = "{\"detect_changes\":false}";
    _ = try h.step(1000);
    try testing.expectEqual(transport.Method.head, h.fake.last_method);
    h.fake.main = .{ .status = 405 };
    h.fake.main_calls = 0;
    _ = try h.step(1060); // HEAD 405 -> GET also 405 here => failure counted, but exercised the retry
    try testing.expectEqual(@as(u32, 2), h.fake.main_calls);
}

test "robots.txt: disallow blocks the request and alerts once; allow resumes; cached 24h" {
    var h = Harness.init();
    defer h.deinit();
    h.fake.robots = .{ .status = 200, .body = "User-agent: *\nDisallow: /page\n" };
    const t = try h.step(1000);
    try expectTitle(t, "BLOCKED: robots.txt forbids");
    try testing.expectEqual(@as(u32, 0), h.fake.main_calls); // page never requested
    try testing.expectEqual(@as(usize, 0), (try h.step(1060)).len); // no repeat alert
    try testing.expectEqual(@as(u32, 1), h.fake.robots_calls); // cached
    try testing.expectEqual(@as(?bool, null), h.state().up); // blocked is not "down"

    // After the TTL the file is re-read; now it allows us.
    h.fake.robots = .{ .status = 200, .body = "User-agent: *\nDisallow: /admin\n" };
    try testing.expectEqual(@as(usize, 0), (try h.step(1000 + 86400 + 1)).len);
    try testing.expectEqual(@as(u32, 2), h.fake.robots_calls);
    try testing.expectEqual(@as(u32, 1), h.fake.main_calls);
    try testing.expectEqual(@as(?bool, true), h.state().up);
}

test "robots.txt: 404 allows; 5xx or network error fails the check without requesting the page" {
    var h = Harness.init();
    defer h.deinit();
    _ = try h.step(1000); // 404 robots => allowed
    try testing.expectEqual(@as(u32, 1), h.fake.main_calls);

    var h2 = Harness.init();
    defer h2.deinit();
    h2.src.options = "{\"down_after\":1}";
    h2.fake.robots = .{ .status = 503 };
    const t = try h2.step(1000);
    try expectTitle(t, "DOWN");
    try testing.expectEqual(@as(u32, 0), h2.fake.main_calls);

    var h3 = Harness.init();
    defer h3.deinit();
    h3.src.options = "{\"down_after\":1}";
    h3.fake.robots_err = error.Timeout;
    try expectTitle(try h3.step(1000), "DOWN");

    var h4 = Harness.init();
    defer h4.deinit();
    h4.src.options = "{\"check_robots\":false}";
    h4.fake.robots = .{ .status = 200, .body = "User-agent: *\nDisallow: /\n" };
    _ = try h4.step(1000);
    try testing.expectEqual(@as(u32, 0), h4.fake.robots_calls); // not even fetched
    try testing.expectEqual(@as(u32, 1), h4.fake.main_calls);
}

test "tls certificate: warn once per cert, expired, renewal re-arms, http skipped, probe throttled" {
    var h = Harness.init();
    defer h.deinit();
    const now: i64 = 1_800_000_000;
    h.fake.cert = now + 5 * day_s; // inside the 14-day window
    const t = try h.step(now);
    try expectTitle(t, "CERT: site expires in 5 day(s)");
    try testing.expectEqual(now + 5 * day_s, h.state().cert_not_after);

    try testing.expectEqual(@as(usize, 0), (try h.step(now + 60)).len); // throttled: no probe
    try testing.expectEqual(@as(u32, 1), h.fake.cert_calls);
    try testing.expectEqual(@as(usize, 0), (try h.step(now + 7 * 3600)).len); // re-probed, same cert: no repeat
    try testing.expectEqual(@as(u32, 2), h.fake.cert_calls);

    h.fake.cert = now + 90 * day_s; // renewed
    try testing.expectEqual(@as(usize, 0), (try h.step(now + 14 * 3600)).len);
    try testing.expectEqual(now + 90 * day_s, h.state().cert_not_after);

    h.fake.cert = now - 3600; // expired
    try expectTitle(try h.step(now + 21 * 3600), "CERT EXPIRED");

    var plain = Harness.init();
    defer plain.deinit();
    plain.src.url = "http://example.org/";
    plain.fake.cert = 1;
    _ = try plain.step(now);
    try testing.expectEqual(@as(u32, 0), plain.fake.cert_calls);
}

test "normalizeText" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("a b c", try normalizeText(a, "<p>a</p>\n<!-- x --><SCRIPT>bad()</SCRIPT> <b>b</b>   c "));
    try testing.expectEqualStrings("x", try normalizeText(a, "<style>p{}</style>x<script>unterminated"));
}
