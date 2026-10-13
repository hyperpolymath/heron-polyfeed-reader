// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell
//! robots.txt (RFC 9309): which paths may our user-agent request?
//!
//! Group selection: groups naming our product token win; otherwise the `*` groups. Rule selection:
//! longest matching pattern wins, `Allow` wins ties. Patterns support `*` and a trailing `$`.
const std = @import("std");

/// Result of interpreting an HTTP response for /robots.txt (RFC 9309 §2.3.1).
pub const Availability = enum {
    /// 2xx: rules in the body apply.
    rules,
    /// 4xx: file unavailable => everything allowed.
    allow_all,
    /// 5xx / network error: crawlers must assume complete disallow.
    unreachable_,
};

pub fn availabilityForStatus(status: u16) Availability {
    return switch (status) {
        200...299 => .rules,
        400...499 => .allow_all,
        else => .unreachable_,
    };
}

fn matchPattern(pat: []const u8, path: []const u8) bool {
    var anchored = false;
    var p = pat;
    if (p.len > 0 and p[p.len - 1] == '$') {
        anchored = true;
        p = p[0 .. p.len - 1];
    }
    return globMatch(p, path, anchored);
}

fn globMatch(pat: []const u8, s: []const u8, anchored: bool) bool {
    // Iterative wildcard match; '*' matches any run (including empty). Prefix semantics unless anchored.
    var pi: usize = 0;
    var si: usize = 0;
    var star: ?usize = null;
    var mark: usize = 0;
    while (si < s.len) {
        if (pi < pat.len and pat[pi] == '*') {
            star = pi;
            mark = si;
            pi += 1;
        } else if (pi < pat.len and pat[pi] == s[si]) {
            pi += 1;
            si += 1;
        } else if (pi == pat.len and !anchored) {
            return true; // pattern fully consumed: prefix match
        } else if (star) |st| {
            pi = st + 1;
            mark += 1;
            si = mark;
        } else return false;
    }
    while (pi < pat.len and pat[pi] == '*') pi += 1;
    return pi == pat.len;
}

fn trimComment(line: []const u8) []const u8 {
    const l = if (std.mem.indexOfScalar(u8, line, '#')) |i| line[0..i] else line;
    return std.mem.trim(u8, l, " \t\r");
}

/// May `token` fetch `path` (path plus optional ?query, starting with '/')?
pub fn allowed(robots: []const u8, token: []const u8, path: []const u8) bool {
    var best_len: usize = 0;
    var best_allow = true;
    var found_specific = false;

    // Two passes: first look for groups that name our token; if none, use '*' groups.
    inline for (.{ false, true }) |use_star| {
        if (!use_star or !found_specific) {
            var in_match = false;
            var in_agents = false; // currently reading consecutive user-agent lines
            var it = std.mem.splitScalar(u8, robots, '\n');
            while (it.next()) |raw| {
                const line = trimComment(raw);
                if (line.len == 0) continue;
                const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
                const key = std.mem.trim(u8, line[0..colon], " \t");
                const val = std.mem.trim(u8, line[colon + 1 ..], " \t");
                if (std.ascii.eqlIgnoreCase(key, "user-agent")) {
                    if (!in_agents) in_match = false;
                    in_agents = true;
                    const hit = if (use_star) std.mem.eql(u8, val, "*") else std.ascii.eqlIgnoreCase(val, token);
                    if (hit) {
                        in_match = true;
                        if (!use_star) found_specific = true;
                    }
                } else {
                    in_agents = false;
                    if (!in_match) continue;
                    const is_allow = std.ascii.eqlIgnoreCase(key, "allow");
                    const is_dis = std.ascii.eqlIgnoreCase(key, "disallow");
                    if (!is_allow and !is_dis) continue;
                    if (val.len == 0) continue; // empty Disallow = allow all; empty Allow = no-op
                    if (matchPattern(val, path)) {
                        if (val.len > best_len or (val.len == best_len and is_allow)) {
                            best_len = val.len;
                            best_allow = is_allow;
                        }
                    }
                }
            }
        }
    }
    return best_allow;
}

const t = std.testing;

test "no rules / no matching group => allowed" {
    try t.expect(allowed("", "sfr", "/x"));
    try t.expect(allowed("User-agent: googlebot\nDisallow: /\n", "sfr", "/x"));
}

test "star group, prefix, allow overrides by longest match, ties to allow" {
    const r = "User-agent: *\nDisallow: /private\nAllow: /private/public\nDisallow: /tie\nAllow: /tie\n";
    try t.expect(allowed(r, "sfr", "/"));
    try t.expect(!allowed(r, "sfr", "/private/x"));
    try t.expect(allowed(r, "sfr", "/private/public/page"));
    try t.expect(allowed(r, "sfr", "/tie"));
    try t.expect(allowed(r, "sfr", "/privatex") == false); // prefix match, as specified
}

test "specific group beats star group; token match is case-insensitive" {
    const r = "User-agent: *\nDisallow: /\n\nUser-agent: SuperFeedReader\nDisallow: /admin\n";
    try t.expect(allowed(r, "superfeedreader", "/index.html"));
    try t.expect(!allowed(r, "superfeedreader", "/admin/x"));
    try t.expect(!allowed(r, "other", "/index.html"));
}

test "multiple user-agent lines share a group; comments and blank lines ignored" {
    const r = "# hi\nUser-agent: a\nUser-agent: sfr  # us\n\nDisallow: /nope # why\n";
    try t.expect(!allowed(r, "sfr", "/nope"));
    try t.expect(allowed(r, "sfr", "/yes"));
}

test "wildcards and end anchor" {
    const r = "User-agent: *\nDisallow: /*.pdf$\nDisallow: /tmp/*/cache\n";
    try t.expect(!allowed(r, "sfr", "/a/b.pdf"));
    try t.expect(allowed(r, "sfr", "/a/b.pdf?x=1"));
    try t.expect(allowed(r, "sfr", "/a/b.pdfx"));
    try t.expect(!allowed(r, "sfr", "/tmp/foo/cache/z"));
    try t.expect(allowed(r, "sfr", "/tmp/foo/other"));
}

test "empty disallow means allow all; disallow / blocks all" {
    try t.expect(allowed("User-agent: *\nDisallow:\n", "sfr", "/x"));
    try t.expect(!allowed("User-agent: *\nDisallow: /\n", "sfr", "/x"));
}

test "http status semantics" {
    try t.expectEqual(Availability.rules, availabilityForStatus(200));
    try t.expectEqual(Availability.allow_all, availabilityForStatus(404));
    try t.expectEqual(Availability.allow_all, availabilityForStatus(403));
    try t.expectEqual(Availability.unreachable_, availabilityForStatus(503));
}
