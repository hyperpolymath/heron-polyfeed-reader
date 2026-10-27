// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell
//! Character-set detection and conversion to UTF-8 for feed bodies.
//!
//! Precedence (RFC 7303 style): byte-order mark, then HTTP charset, then the
//! XML declaration, then UTF-8. Latin-1 / US-ASCII labels are decoded as
//! windows-1252 (as browsers do), because that is what such feeds contain.
//! Bytes that are invalid in a stream declared as UTF-8 are repaired by
//! reading the offending byte as windows-1252: this recovers the common
//! "declared UTF-8, actually mixed" feed instead of emitting U+FFFD.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Charset = enum { utf8, utf16le, utf16be, windows1252, iso8859_15 };

const cp1252_c1 = [32]u21{
    0x20AC, 0x0081, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
    0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x008D, 0x017D, 0x008F,
    0x0090, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
    0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x009D, 0x017E, 0x0178,
};

fn latin1Cp(b: u8, cs: Charset) u21 {
    if (b >= 0x80 and b <= 0x9F) return cp1252_c1[b - 0x80];
    if (cs == .iso8859_15) switch (b) {
        0xA4 => return 0x20AC,
        0xA6 => return 0x0160,
        0xA8 => return 0x0161,
        0xB4 => return 0x017D,
        0xB8 => return 0x017E,
        0xBC => return 0x0152,
        0xBD => return 0x0153,
        0xBE => return 0x0178,
        else => {},
    };
    return b;
}

/// Map a charset label (case-insensitive) to a supported charset.
pub fn fromLabel(label: []const u8) ?Charset {
    var buf: [32]u8 = undefined;
    const l = std.mem.trim(u8, label, " \t\"'");
    if (l.len == 0 or l.len > buf.len) return null;
    const low = std.ascii.lowerString(&buf, l);
    const eq = std.mem.eql;
    if (eq(u8, low, "utf-8") or eq(u8, low, "utf8")) return .utf8;
    if (eq(u8, low, "utf-16le") or eq(u8, low, "utf-16") or eq(u8, low, "ucs-2")) return .utf16le;
    if (eq(u8, low, "utf-16be")) return .utf16be;
    if (eq(u8, low, "iso-8859-15") or eq(u8, low, "latin9")) return .iso8859_15;
    for ([_][]const u8{ "iso-8859-1", "iso8859-1", "latin1", "latin-1", "us-ascii", "ascii", "windows-1252", "cp1252", "iso_8859-1", "l1" }) |n| {
        if (eq(u8, low, n)) return .windows1252;
    }
    return null;
}

/// Extract `charset=` from a Content-Type header value.
pub fn charsetFromContentType(ct: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, ct, ';');
    _ = it.next();
    while (it.next()) |part| {
        const p = std.mem.trim(u8, part, " \t");
        if (p.len > 8 and std.ascii.eqlIgnoreCase(p[0..8], "charset=")) return std.mem.trim(u8, p[8..], " \t\"'");
    }
    return null;
}

fn sniffDeclaration(bytes: []const u8) ?[]const u8 {
    const head = bytes[0..@min(bytes.len, 256)];
    if (!std.mem.startsWith(u8, head, "<?xml")) return null;
    const end = std.mem.indexOf(u8, head, "?>") orelse head.len;
    const decl = head[0..end];
    const k = std.ascii.findIgnoreCase(decl, "encoding") orelse return null;
    var i = k + "encoding".len;
    while (i < decl.len and (decl[i] == ' ' or decl[i] == '=')) i += 1;
    if (i >= decl.len) return null;
    const q = decl[i];
    if (q != '"' and q != '\'') return null;
    const rest = decl[i + 1 ..];
    const e = std.mem.indexOfScalar(u8, rest, q) orelse return null;
    return rest[0..e];
}

pub fn detect(bytes: []const u8, http_charset: ?[]const u8) struct { cs: Charset, skip: usize } {
    if (std.mem.startsWith(u8, bytes, "\xEF\xBB\xBF")) return .{ .cs = .utf8, .skip = 3 };
    if (std.mem.startsWith(u8, bytes, "\xFF\xFE")) return .{ .cs = .utf16le, .skip = 2 };
    if (std.mem.startsWith(u8, bytes, "\xFE\xFF")) return .{ .cs = .utf16be, .skip = 2 };
    // BOM-less UTF-16 starting with "<\0" or "\0<"
    if (bytes.len >= 4 and bytes[0] == '<' and bytes[1] == 0 and bytes[2] != 0 and bytes[3] == 0) return .{ .cs = .utf16le, .skip = 0 };
    if (bytes.len >= 4 and bytes[0] == 0 and bytes[1] == '<' and bytes[2] == 0 and bytes[3] != 0) return .{ .cs = .utf16be, .skip = 0 };
    if (http_charset) |h| if (fromLabel(h)) |cs| return .{ .cs = cs, .skip = 0 };
    if (sniffDeclaration(bytes)) |d| if (fromLabel(d)) |cs| return .{ .cs = cs, .skip = 0 };
    return .{ .cs = .utf8, .skip = 0 };
}

fn appendCp(out: *std.ArrayList(u8), a: Allocator, cp: u21) Allocator.Error!void {
    var buf: [4]u8 = undefined;
    const c: u21 = if (cp > 0x10FFFF or (cp >= 0xD800 and cp <= 0xDFFF)) 0xFFFD else cp;
    const n = std.unicode.utf8Encode(c, &buf) catch unreachable;
    try out.appendSlice(a, buf[0..n]);
}

/// Convert `bytes` to valid UTF-8 allocated from `a` (an arena in practice).
pub fn toUtf8(a: Allocator, bytes: []const u8, http_charset: ?[]const u8) Allocator.Error![]u8 {
    const d = detect(bytes, http_charset);
    const src = bytes[d.skip..];
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(a, src.len + src.len / 8);
    switch (d.cs) {
        .utf8 => {
            var i: usize = 0;
            while (i < src.len) {
                const b = src[i];
                if (b < 0x80) {
                    try out.append(a, b);
                    i += 1;
                    continue;
                }
                const n = std.unicode.utf8ByteSequenceLength(b) catch 0;
                if (n > 0 and i + n <= src.len and std.unicode.utf8ValidateSlice(src[i .. i + n])) {
                    try out.appendSlice(a, src[i .. i + n]);
                    i += n;
                } else {
                    try appendCp(&out, a, latin1Cp(b, .windows1252));
                    i += 1;
                }
            }
        },
        .windows1252, .iso8859_15 => {
            for (src) |b| {
                if (b < 0x80) try out.append(a, b) else try appendCp(&out, a, latin1Cp(b, d.cs));
            }
        },
        .utf16le, .utf16be => {
            var i: usize = 0;
            while (i + 1 < src.len) {
                const u: u16 = if (d.cs == .utf16le)
                    @as(u16, src[i]) | (@as(u16, src[i + 1]) << 8)
                else
                    (@as(u16, src[i]) << 8) | src[i + 1];
                i += 2;
                if (u >= 0xD800 and u <= 0xDBFF and i + 1 < src.len) {
                    const lo: u16 = if (d.cs == .utf16le)
                        @as(u16, src[i]) | (@as(u16, src[i + 1]) << 8)
                    else
                        (@as(u16, src[i]) << 8) | src[i + 1];
                    if (lo >= 0xDC00 and lo <= 0xDFFF) {
                        i += 2;
                        try appendCp(&out, a, 0x10000 + ((@as(u21, u) - 0xD800) << 10) + (lo - 0xDC00));
                        continue;
                    }
                }
                try appendCp(&out, a, u);
            }
        },
    }
    return out.items;
}

test "utf8 passthrough and BOM strip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try toUtf8(arena.allocator(), "\xEF\xBB\xBF<a>h\xC3\xA9</a>", null);
    try std.testing.expectEqualStrings("<a>h\xC3\xA9</a>", out);
}

test "latin1 declared in xml decl" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try toUtf8(arena.allocator(), "<?xml version=\"1.0\" encoding=\"ISO-8859-1\"?><a>caf\xE9 \x93q\x94</a>", null);
    try std.testing.expectEqualStrings("<?xml version=\"1.0\" encoding=\"ISO-8859-1\"?><a>caf\xC3\xA9 \xE2\x80\x9Cq\xE2\x80\x9D</a>", out);
}

test "http charset beats declaration; BOM beats http" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const o1 = try toUtf8(a, "<?xml version=\"1.0\" encoding=\"utf-8\"?>\xE9", "iso-8859-1");
    try std.testing.expect(std.mem.endsWith(u8, o1, "\xC3\xA9"));
    const o2 = try toUtf8(a, "\xEF\xBB\xBF\xC3\xA9", "iso-8859-1");
    try std.testing.expectEqualStrings("\xC3\xA9", o2);
}

test "invalid utf8 bytes repaired as cp1252" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try toUtf8(arena.allocator(), "ok \xC3\xA9 bad \x92 end", null);
    try std.testing.expectEqualStrings("ok \xC3\xA9 bad \xE2\x80\x99 end", out);
}

test "utf16 le with bom and surrogate pair" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try toUtf8(arena.allocator(), "\xFF\xFE<\x00a\x00>\x00\x3D\xD8\x00\xDE", null); // U+1F600
    try std.testing.expectEqualStrings("<a>\xF0\x9F\x98\x80", out);
}

test "charset from content-type" {
    try std.testing.expectEqualStrings("utf-8", charsetFromContentType("text/xml; charset=\"utf-8\"").?);
    try std.testing.expect(charsetFromContentType("application/xml") == null);
}
