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
