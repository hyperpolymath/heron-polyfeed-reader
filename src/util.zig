// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell
const std = @import("std");

/// "YYYY-MM-DD HH:MM" (UTC) into `buf`.
pub fn fmtDate(buf: []u8, unix: i64) []const u8 {
    if (unix < 0) return "-";
    const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(unix) };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}", .{
        yd.year, @backingInt(md.month), md.day_index + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour(),
    }) catch "-";
}

/// Network-derived text made safe to print on a terminal: every C0 control except TAB (this
/// includes ESC, so no CSI/OSC sequence survives), DEL, and the C1 controls U+0080..U+009F
/// become U+FFFD. Newlines go too, so a feed title cannot forge extra output lines.
/// Returns `s` itself when nothing needed replacing.
pub fn termSafe(a: std.mem.Allocator, s: []const u8) std.mem.Allocator.Error![]const u8 {
    if (!needsTermEscape(s)) return s;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if ((c < 0x20 and c != '\t') or c == 0x7f) {
            try out.appendSlice(a, "\u{FFFD}");
            i += 1;
        } else if (c == 0xC2 and i + 1 < s.len and s[i + 1] >= 0x80 and s[i + 1] <= 0x9F) {
            try out.appendSlice(a, "\u{FFFD}"); // UTF-8 encoding of a C1 control
            i += 2;
        } else {
            try out.append(a, c);
            i += 1;
        }
    }
    return out.items;
}

fn needsTermEscape(s: []const u8) bool {
    for (s, 0..) |c, i| {
        if ((c < 0x20 and c != '\t') or c == 0x7f) return true;
        if (c == 0xC2 and i + 1 < s.len and s[i + 1] >= 0x80 and s[i + 1] <= 0x9F) return true;
    }
    return false;
}

test "termSafe neutralises escape sequences, newlines and C1 controls; leaves text alone" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("plain \u{e9}t\u{e9}\tok", try termSafe(a, "plain \u{e9}t\u{e9}\tok"));
    try std.testing.expectEqualStrings("\u{FFFD}[31mred\u{FFFD}]52;c;Zm9v\u{FFFD}", try termSafe(a, "\x1b[31mred\x1b]52;c;Zm9v\x07"));
    try std.testing.expectEqualStrings("a\u{FFFD}b\u{FFFD}c", try termSafe(a, "a\nb\u{9b}c"));
}

/// Human duration like "5m", "3h", "2d".
pub fn fmtSpan(buf: []u8, secs: i64) []const u8 {
    const s = if (secs < 0) -secs else secs;
    const r = if (s < 90) std.fmt.bufPrint(buf, "{d}s", .{s}) else if (s < 5400) std.fmt.bufPrint(buf, "{d}m", .{@divTrunc(s + 30, 60)}) else if (s < 172800) std.fmt.bufPrint(buf, "{d}h", .{@divTrunc(s + 1800, 3600)}) else std.fmt.bufPrint(buf, "{d}d", .{@divTrunc(s + 43200, 86400)});
    return r catch "?";
}

test "fmtDate" {
    var b: [32]u8 = undefined;
    try std.testing.expectEqualStrings("2000-01-01 00:00", fmtDate(&b, 946684800));
    try std.testing.expectEqualStrings("2026-10-13 10:37", fmtDate(&b, 1791887820));
}

test "fmtSpan" {
    var b: [16]u8 = undefined;
    try std.testing.expectEqualStrings("45s", fmtSpan(&b, 45));
    try std.testing.expectEqualStrings("5m", fmtSpan(&b, 300));
    try std.testing.expectEqualStrings("3h", fmtSpan(&b, 3 * 3600));
    try std.testing.expectEqualStrings("3d", fmtSpan(&b, 3 * 86400));
}
