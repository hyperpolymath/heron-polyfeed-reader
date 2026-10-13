// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell
//! Configuration: a plain JSON file (no YAML). See `examples/sfr.json`.
//!
//! {
//!   "data_dir": "/var/lib/sfr",                 // optional
//!   "user_agent": "sfr/0.1 (+contact)",         // optional
//!   "timeout_s": 30,                            // optional, per request
//!   "web": { "enabled": true, "bind": "127.0.0.1", "port": 8484 },   // optional
//!   "sources":  [ { "name": "lwn", "type": "feed", "url": "https://lwn.net/headlines/rss", "interval_s": 900 } ],
//!   "monitors": [ { "name": "site", "url": "https://example.org/", "interval_s": 300,
//!                  "expect_status": 200, "detect_changes": true, "check_robots": true } ]
//! }
//!
//! Unknown keys inside a source are kept as that adapter's private `options` (raw JSON), so
//! new source types can add settings without touching this file.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const min_interval_s: u32 = 60;
pub const default_interval_s: u32 = 1800;

pub const SourceCfg = struct {
    name: []const u8,
    type_name: []const u8,
    url: []const u8,
    interval_s: u32,
    /// Raw JSON object text of adapter-specific settings ("" if none).
    options: []const u8 = "",
};

pub const MonitorCfg = struct {
    name: []const u8,
    url: []const u8,
    interval_s: u32,
    expect_status: u16 = 200,
    detect_changes: bool = true,
    check_robots: bool = true,
    /// Alert when the TLS certificate has fewer than this many days left (0 = off).
    cert_warn_days: u32 = 14,
};

pub const WebCfg = struct {
    enabled: bool = false,
    bind: []const u8 = "127.0.0.1",
    port: u16 = 8484,
};

pub const Config = struct {
    data_dir: ?[]const u8 = null,
    user_agent: []const u8 = "superfeedreader/0.1 (+https://github.com/hyperpolymath/superfeedreader)",
    timeout_s: u32 = 30,
    web: WebCfg = .{},
    sources: []SourceCfg = &.{},
    monitors: []MonitorCfg = &.{},
};

pub const Diagnostic = struct { message: []const u8 = "" };

pub const Error = error{InvalidConfig} || Allocator.Error;

fn bad(a: Allocator, diag: *Diagnostic, comptime fmt: []const u8, args: anytype) Error {
    diag.message = std.fmt.allocPrint(a, fmt, args) catch "invalid configuration";
    return error.InvalidConfig;
}

fn validName(n: []const u8) bool {
    if (n.len == 0 or n.len > 64) return false;
    for (n) |c| if (!(std.ascii.isAlphanumeric(c) or c == '.' or c == '_' or c == '-')) return false;
    return true;
}

fn validHttpUrl(u: []const u8) bool {
    const uri = std.Uri.parse(u) catch return false;
    if (!(std.ascii.eqlIgnoreCase(uri.scheme, "http") or std.ascii.eqlIgnoreCase(uri.scheme, "https"))) return false;
    return uri.host != null;
}

fn getStr(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn getInt(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const v = obj.get(key) orelse return null;
    return if (v == .integer) v.integer else null;
}

fn getBool(obj: std.json.ObjectMap, key: []const u8) ?bool {
    const v = obj.get(key) orelse return null;
    return if (v == .bool) v.bool else null;
}

/// Parse and validate. All returned memory belongs to `a` (use an arena).
pub fn parse(a: Allocator, text: []const u8, diag: *Diagnostic) Error!Config {
    const root = std.json.parseFromSliceLeaky(std.json.Value, a, text, .{}) catch |e|
        return bad(a, diag, "not valid JSON: {s}", .{@errorName(e)});
    if (root != .object) return bad(a, diag, "top level must be an object", .{});
    const obj = root.object;
    var cfg: Config = .{};

    if (getStr(obj, "data_dir")) |d| cfg.data_dir = d;
    if (getStr(obj, "user_agent")) |d| cfg.user_agent = d;
    if (getInt(obj, "timeout_s")) |t| {
        if (t < 1 or t > 600) return bad(a, diag, "timeout_s must be 1..600", .{});
        cfg.timeout_s = @intCast(t);
    }
    if (obj.get("web")) |w| {
        if (w != .object) return bad(a, diag, "web must be an object", .{});
        cfg.web.enabled = getBool(w.object, "enabled") orelse true;
        if (getStr(w.object, "bind")) |b| cfg.web.bind = b;
        if (getInt(w.object, "port")) |p| {
            if (p < 1 or p > 65535) return bad(a, diag, "web.port out of range", .{});
            cfg.web.port = @intCast(p);
        }
    }

    var names: std.StringHashMapUnmanaged(void) = .empty;
    var sources: std.ArrayList(SourceCfg) = .empty;
    if (obj.get("sources")) |sv| {
        if (sv != .array) return bad(a, diag, "sources must be an array", .{});
        for (sv.array.items, 0..) |item, idx| {
            if (item != .object) return bad(a, diag, "sources[{d}] must be an object", .{idx});
            const o = item.object;
            const name = getStr(o, "name") orelse return bad(a, diag, "sources[{d}]: missing name", .{idx});
            if (!validName(name)) return bad(a, diag, "sources[{d}]: bad name '{s}' (use A-Z a-z 0-9 . _ -, max 64)", .{ idx, name });
            if ((try names.getOrPut(a, name)).found_existing) return bad(a, diag, "duplicate name '{s}'", .{name});
            const type_name = getStr(o, "type") orelse "feed";
            const url = getStr(o, "url") orelse return bad(a, diag, "source '{s}': missing url", .{name});
            const interval = getInt(o, "interval_s") orelse default_interval_s;
            if (interval < min_interval_s or interval > 30 * 86400) return bad(a, diag, "source '{s}': interval_s must be {d}..2592000", .{ name, min_interval_s });
            if (std.mem.eql(u8, type_name, "feed") and !validHttpUrl(url)) return bad(a, diag, "source '{s}': url must be http(s)", .{name});
            var options: []const u8 = "";
            if (o.get("options")) |opt| {
                if (opt != .object) return bad(a, diag, "source '{s}': options must be an object", .{name});
                options = try std.json.Stringify.valueAlloc(a, opt, .{});
            }
            try sources.append(a, .{ .name = name, .type_name = type_name, .url = url, .interval_s = @intCast(interval), .options = options });
        }
    }
    cfg.sources = sources.items;

    var monitors: std.ArrayList(MonitorCfg) = .empty;
    if (obj.get("monitors")) |mv| {
        if (mv != .array) return bad(a, diag, "monitors must be an array", .{});
        for (mv.array.items, 0..) |item, idx| {
            if (item != .object) return bad(a, diag, "monitors[{d}] must be an object", .{idx});
            const o = item.object;
            const name = getStr(o, "name") orelse return bad(a, diag, "monitors[{d}]: missing name", .{idx});
            if (!validName(name)) return bad(a, diag, "monitors[{d}]: bad name '{s}'", .{ idx, name });
            if ((try names.getOrPut(a, name)).found_existing) return bad(a, diag, "duplicate name '{s}'", .{name});
            const url = getStr(o, "url") orelse return bad(a, diag, "monitor '{s}': missing url", .{name});
            if (!validHttpUrl(url)) return bad(a, diag, "monitor '{s}': url must be http(s)", .{name});
            const interval = getInt(o, "interval_s") orelse 300;
            if (interval < min_interval_s or interval > 30 * 86400) return bad(a, diag, "monitor '{s}': interval_s must be {d}..2592000", .{ name, min_interval_s });
            var m: MonitorCfg = .{ .name = name, .url = url, .interval_s = @intCast(interval) };
            if (getInt(o, "expect_status")) |s| {
                if (s < 100 or s > 599) return bad(a, diag, "monitor '{s}': expect_status out of range", .{name});
                m.expect_status = @intCast(s);
            }
            if (getBool(o, "detect_changes")) |b| m.detect_changes = b;
            if (getBool(o, "check_robots")) |b| m.check_robots = b;
            if (getInt(o, "cert_warn_days")) |d| m.cert_warn_days = @intCast(@max(0, d));
            try monitors.append(a, m);
        }
    }
    cfg.monitors = monitors.items;
    return cfg;
}

test "valid config with defaults, options passthrough, monitors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var d: Diagnostic = .{};
    const c = try parse(arena.allocator(),
        \\{"sources":[{"name":"lwn","url":"https://lwn.net/headlines/rss","interval_s":900},
        \\            {"name":"n","type":"nntp","url":"news://x/y","options":{"group":"a.b"}}],
        \\ "monitors":[{"name":"site","url":"https://example.org/","expect_status":204,"check_robots":false}],
        \\ "web":{"port":9000}}
    , &d);
    try std.testing.expectEqual(@as(usize, 2), c.sources.len);
    try std.testing.expectEqualStrings("feed", c.sources[0].type_name);
    try std.testing.expectEqual(@as(u32, 900), c.sources[0].interval_s);
    try std.testing.expectEqual(default_interval_s, c.sources[1].interval_s);
    try std.testing.expectEqualStrings("{\"group\":\"a.b\"}", c.sources[1].options);
    try std.testing.expectEqual(@as(u16, 204), c.monitors[0].expect_status);
    try std.testing.expect(!c.monitors[0].check_robots and c.monitors[0].detect_changes);
    try std.testing.expectEqual(@as(u16, 9000), c.web.port);
    try std.testing.expectEqualStrings("127.0.0.1", c.web.bind);
}

test "rejections carry a message" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cases = [_][]const u8{
        "[]",
        "{not json",
        "{\"sources\":[{\"url\":\"http://x/\"}]}", // no name
        "{\"sources\":[{\"name\":\"a b\",\"url\":\"http://x/\"}]}", // bad name
        "{\"sources\":[{\"name\":\"a\",\"url\":\"ftp://x/\"}]}", // bad scheme
        "{\"sources\":[{\"name\":\"a\",\"url\":\"http://x/\",\"interval_s\":5}]}", // too fast
        "{\"sources\":[{\"name\":\"a\",\"url\":\"http://x/\"},{\"name\":\"a\",\"url\":\"http://y/\"}]}", // dup
        "{\"monitors\":[{\"name\":\"a\",\"url\":\"http://x/\"}],\"sources\":[{\"name\":\"a\",\"url\":\"http://y/\"}]}", // dup across kinds
        "{\"web\":{\"port\":70000}}",
        "{\"timeout_s\":0}",
    };
    for (cases) |text| {
        var d: Diagnostic = .{};
        try std.testing.expectError(error.InvalidConfig, parse(arena.allocator(), text, &d));
        try std.testing.expect(d.message.len > 0);
    }
}
