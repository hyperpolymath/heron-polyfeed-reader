// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell
//! Tolerant date parsing for feeds: RFC 822/2822 (incl. 2-digit years, named
//! zones, missing seconds, trailing comments), RFC 3339 / ISO 8601 (extended,
//! basic, partial dates), HTTP-date, and bare Unix epochs. Returns Unix seconds
//! (UTC) or null; never guesses on ambiguous numeric day/month forms.
const std = @import("std");

pub fn daysFromCivil(y_in: i64, m: i64, d: i64) i64 {
    const y = if (m <= 2) y_in - 1 else y_in;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp = @mod(m + 9, 12);
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

fn isLeap(y: i64) bool {
    return (@mod(y, 4) == 0 and @mod(y, 100) != 0) or @mod(y, 400) == 0;
}

fn daysInMonth(y: i64, m: i64) i64 {
    return switch (m) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeap(y)) 29 else 28,
        else => 0,
    };
}

fn build(y: i64, mo: i64, d: i64, h: i64, mi: i64, s: i64, off_min: i64) ?i64 {
    if (mo < 1 or mo > 12 or d < 1 or d > daysInMonth(y, mo)) return null;
    if (h < 0 or h > 24 or mi < 0 or mi > 59 or s < 0 or s > 60) return null;
    if (y < 1 or y > 9999) return null;
    return daysFromCivil(y, mo, d) * 86400 + h * 3600 + mi * 60 + s - off_min * 60;
}

const months = [_][]const u8{ "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec" };

fn monthFromName(s: []const u8) ?i64 {
    if (s.len < 3) return null;
    var buf: [3]u8 = undefined;
    _ = std.ascii.lowerString(&buf, s[0..3]);
    for (months, 0..) |m, i| if (std.mem.eql(u8, &buf, m)) return @intCast(i + 1);
    return null;
}

fn zoneOffsetMinutes(z: []const u8) ?i64 {
    var buf: [8]u8 = undefined;
    if (z.len == 0) return 0;
    if (z.len > buf.len) return null;
    const u = std.ascii.upperString(&buf, z);
    const table = [_]struct { []const u8, i64 }{
        .{ "GMT", 0 },    .{ "UT", 0 },     .{ "UTC", 0 },    .{ "Z", 0 },
        .{ "EST", -300 }, .{ "EDT", -240 }, .{ "CST", -360 }, .{ "CDT", -300 },
        .{ "MST", -420 }, .{ "MDT", -360 }, .{ "PST", -480 }, .{ "PDT", -420 },
        .{ "BST", 60 },   .{ "CET", 60 },   .{ "CEST", 120 }, .{ "EET", 120 },
        .{ "EEST", 180 }, .{ "WET", 0 },    .{ "WEST", 60 },  .{ "IST", 330 },
        .{ "JST", 540 },  .{ "AEST", 600 }, .{ "AEDT", 660 },
    };
    for (table) |e| if (std.mem.eql(u8, u, e[0])) return e[1];
    if (u[0] == '+' or u[0] == '-') {
        const sign: i64 = if (u[0] == '-') -1 else 1;
        var digits: [4]u8 = undefined;
        var n: usize = 0;
        for (u[1..]) |c| {
            if (c == ':') continue;
            if (!std.ascii.isDigit(c) or n >= 4) return null;
            digits[n] = c;
            n += 1;
        }
        const hh: i64 = switch (n) {
            2 => std.fmt.parseInt(i64, digits[0..2], 10) catch return null,
            4 => std.fmt.parseInt(i64, digits[0..2], 10) catch return null,
            else => return null,
        };
        const mm: i64 = if (n == 4) (std.fmt.parseInt(i64, digits[2..4], 10) catch return null) else 0;
        if (hh > 23 or mm > 59) return null;
        return sign * (hh * 60 + mm);
    }
    return null;
}

fn digitsAt(s: []const u8, i: usize, n: usize) ?i64 {
    if (i + n > s.len) return null;
    var v: i64 = 0;
    for (s[i .. i + n]) |c| {
        if (!std.ascii.isDigit(c)) return null;
        v = v * 10 + (c - '0');
    }
    return v;
}

fn parseIso(s: []const u8) ?i64 {
    // Basic form: YYYYMMDD[THHMMSS[Z]]
    if (s.len >= 8 and digitsAt(s, 0, 8) != null and (s.len == 8 or s[8] == 'T' or s[8] == 't')) {
        const y = digitsAt(s, 0, 4).?;
        const mo = digitsAt(s, 4, 2).?;
        const d = digitsAt(s, 6, 2).?;
        if (s.len == 8) return build(y, mo, d, 0, 0, 0, 0);
        const h = digitsAt(s, 9, 2) orelse return null;
        const mi = digitsAt(s, 11, 2) orelse 0;
        const sec = digitsAt(s, 13, 2) orelse 0;
        const tail = if (s.len > 15) s[15..] else "";
        const off = zoneOffsetMinutes(std.mem.trim(u8, tail, " ")) orelse return null;
        return build(y, mo, d, h, mi, sec, off);
    }
    const y = digitsAt(s, 0, 4) orelse return null;
    if (s.len == 4) return build(y, 1, 1, 0, 0, 0, 0);
    if (s[4] != '-') return null;
    const mo = digitsAt(s, 5, 2) orelse return null;
    if (s.len == 7) return build(y, mo, 1, 0, 0, 0, 0);
    if (s[7] != '-') return null;
    const d = digitsAt(s, 8, 2) orelse return null;
    if (s.len == 10) return build(y, mo, d, 0, 0, 0, 0);
    if (s[10] != 'T' and s[10] != 't' and s[10] != ' ') return null;
    const h = digitsAt(s, 11, 2) orelse return null;
    var i: usize = 13;
    var mi: i64 = 0;
    var sec: i64 = 0;
    if (i < s.len and s[i] == ':') {
        mi = digitsAt(s, i + 1, 2) orelse return null;
        i += 3;
        if (i < s.len and s[i] == ':') {
            sec = digitsAt(s, i + 1, 2) orelse return null;
            i += 3;
            if (i < s.len and (s[i] == '.' or s[i] == ',')) {
                i += 1;
                while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
            }
        }
    }
    const tail = std.mem.trim(u8, s[i..], " ");
    const off = zoneOffsetMinutes(tail) orelse return null;
    return build(y, mo, d, h, mi, sec, off);
}

fn parseRfc822(s_in: []const u8) ?i64 {
    // Strip trailing "(comment)".
    var s = std.mem.trim(u8, s_in, " \t\r\n");
    if (std.mem.indexOfScalar(u8, s, '(')) |p| s = std.mem.trim(u8, s[0..p], " \t");
    var tok: [10][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, s, " \t,");
    while (it.next()) |t| {
        if (n == tok.len) return null;
        tok[n] = t;
        n += 1;
    }
    var i: usize = 0;
    // Optional weekday.
    if (i < n and tok[i].len >= 3 and std.ascii.isAlphabetic(tok[i][0]) and monthFromName(tok[i]) == null) i += 1;
    // Weekday abbreviations like "Mar" (Tuesday in some locales) collide with months; accept only if next token is numeric.
    if (i == 0 and n >= 4 and std.ascii.isAlphabetic(tok[0][0]) and std.ascii.isDigit(tok[1][0])) i += 1;
    if (i + 3 > n) return null;
    const day = std.fmt.parseInt(i64, std.mem.trimEnd(u8, tok[i], ".stndrh"), 10) catch return null;
    const mo = monthFromName(tok[i + 1]) orelse return null;
    var yr = std.fmt.parseInt(i64, tok[i + 2], 10) catch return null;
    if (tok[i + 2].len == 2) yr += if (yr < 50) 2000 else 1900 else if (tok[i + 2].len == 3) yr += 1900;
    var h: i64 = 0;
    var mi: i64 = 0;
    var sec: i64 = 0;
    var off: i64 = 0;
    var j = i + 3;
    if (j < n and std.mem.indexOfScalar(u8, tok[j], ':') != null) {
        var p = std.mem.splitScalar(u8, tok[j], ':');
        h = std.fmt.parseInt(i64, p.next().?, 10) catch return null;
        mi = std.fmt.parseInt(i64, p.next() orelse "0", 10) catch return null;
        if (p.next()) |sx| {
            const dot = std.mem.indexOfScalar(u8, sx, '.') orelse sx.len;
            sec = std.fmt.parseInt(i64, sx[0..dot], 10) catch return null;
        }
        j += 1;
        if (j < n) off = zoneOffsetMinutes(tok[j]) orelse 0;
    }
    return build(yr, mo, day, h, mi, sec, off);
}

pub fn parse(input: []const u8) ?i64 {
    const s = std.mem.trim(u8, input, " \t\r\n");
    if (s.len == 0) return null;
    // Epoch seconds / milliseconds.
    if (s.len >= 9 and s.len <= 13) {
        var all = true;
        for (s) |c| if (!std.ascii.isDigit(c)) {
            all = false;
            break;
        };
        if (all) {
            const v = std.fmt.parseInt(i64, s, 10) catch return null;
            if (s.len >= 11) return @divTrunc(v, 1000);
            if (s.len >= 9 and s.len <= 10) return v;
        }
    }
    if (std.ascii.isDigit(s[0]) and s.len >= 4 and (digitsAt(s, 0, 4) != null) and
        (s.len == 4 or s[4] == '-' or (s.len >= 8 and digitsAt(s, 0, 8) != null)))
        return parseIso(s);
    return parseRfc822(s);
}

fn expectDate(expected: ?i64, s: []const u8) !void {
    try std.testing.expectEqual(expected, parse(s));
}

test "rfc822 variants" {
    try expectDate(946684800, "Sat, 01 Jan 2000 00:00:00 GMT");
    try expectDate(946684800, "Sat, 01 Jan 2000 00:00:00 +0000");
    try expectDate(946684800, "1 Jan 2000 00:00 UT");
    try expectDate(946684800 + 3600, "Sat, 1 Jan 2000 01:00 Z");
    try expectDate(946684800, "Sat, 01 Jan 2000 01:00:00 +0100");
    try expectDate(946684800 + 5 * 3600, "Sat, 01 Jan 2000 00:00:00 EST");
    try expectDate(946684800, "Sat, 01 Jan 00 00:00:00 GMT"); // 2-digit year
    try expectDate(946684800, "SAT, 01 JAN 2000 00:00:00 GMT"); // upper case
    try expectDate(946684800, "Saturday, 01 January 2000 00:00:00 GMT"); // long names
    try expectDate(946684800, "Sat, 01 Jan 2000 00:00:00 GMT (Coordinated Universal Time)");
    try expectDate(946684800, "01 Jan 2000");
    try expectDate(946684800 + 3600, "Sat, 01 Jan 2000 00:00:00 -0100");
    try expectDate(946684800, "Sat, 01 Jan 2000 00:00:00.123 GMT");
}

test "iso 8601 variants" {
    try expectDate(946684800, "2000-01-01T00:00:00Z");
    try expectDate(946684800, "2000-01-01T00:00:00+00:00");
    try expectDate(946684800, "2000-01-01T01:00:00+01:00");
    try expectDate(946684800, "2000-01-01T01:00:00+0100");
    try expectDate(946684800, "2000-01-01 00:00:00");
    try expectDate(946684800, "2000-01-01T00:00:00.123456Z");
    try expectDate(946684800, "2000-01-01");
    try expectDate(946684800, "2000-01");
    try expectDate(946684800, "2000");
    try expectDate(946684800, "20000101T000000Z");
    try expectDate(946684800, "2000-01-01t00:00z");
    try expectDate(946684800, "946684800");
    try expectDate(946684800, "946684800000");
}

test "invalid dates rejected" {
    try expectDate(null, "");
    try expectDate(null, "yesterday");
    try expectDate(null, "2000-13-01T00:00:00Z");
    try expectDate(null, "2001-02-29");
    try expectDate(null, "Sat, 32 Jan 2000 00:00:00 GMT");
    try expectDate(null, "Sat, 01 Foo 2000 00:00:00 GMT");
    try expectDate(null, "01/02/2000"); // ambiguous: refuse to guess
    try expectDate(null, "2000-01-01T25:00:00Z");
}

test "leap day and pre-epoch" {
    try expectDate(951782400, "2000-02-29T00:00:00Z");
    try expectDate(-86400, "1969-12-31T00:00:00Z");
}
