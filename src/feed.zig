// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell
//! RSS 2.0 (and 0.9x), Atom 1.0 and RSS 1.0 (RDF) -> normalised items.
const std = @import("std");
const Allocator = std.mem.Allocator;
const xml = @import("xml.zig");
const encoding = @import("encoding.zig");
const dates = @import("dates.zig");
const Item = @import("item.zig").Item;

pub const Format = enum { rss2, atom, rdf };

pub const Parsed = struct {
    format: Format,
    title: []const u8,
    items: []Item,
};

pub const ParseError = error{ NotAFeed, NoRoot, TooLarge } || Allocator.Error;

/// `bytes` is the raw response body; `http_charset` the charset parameter of Content-Type.
/// Everything returned is allocated from `a` (use an arena).
pub fn parse(a: Allocator, source: []const u8, bytes: []const u8, http_charset: ?[]const u8) ParseError!Parsed {
    const utf8 = try encoding.toUtf8(a, bytes, http_charset);
    const doc = try xml.parse(a, utf8, .{});
    const root = xml.rootElement(doc).?;

    var fmt: Format = undefined;
    if (root.is("rss") or root.is("channel")) {
        fmt = .rss2;
    } else if (root.is("feed")) {
        fmt = .atom;
    } else if (root.is("rdf")) {
        fmt = .rdf;
    } else return error.NotAFeed;

    var items: std.ArrayList(Item) = .empty;
    var title: []const u8 = "";
    switch (fmt) {
        .rss2, .rdf => {
            const channel = if (root.is("channel")) root else root.child("channel");
            // A channel without a <title> is malformed but must not take the daemon down: untrusted input.
            if (channel) |ch| {
                if (ch.child("title")) |t| title = try nodeText(a, t);
            }
            // Items are channel children in RSS 2.0 and root children in RSS 1.0; accept both.
            for ([_]?*xml.Node{ channel, root }) |maybe| {
                const container = maybe orelse continue;
                var c = container.first_child;
                while (c) |n| : (c = n.next) {
                    if (n.is("item")) if (try rssItem(a, source, n)) |it| try items.append(a, it);
                }
                if (items.items.len > 0) break;
            }
        },
        .atom => {
            if (root.child("title")) |t| title = try nodeText(a, t);
            var c = root.first_child;
            while (c) |n| : (c = n.next) {
                if (n.is("entry")) if (try atomEntry(a, source, n)) |it| try items.append(a, it);
            }
        },
    }
    return .{ .format = fmt, .title = title, .items = try dedupeBatch(a, items.items) };
}

/// Text of a node; for xhtml/inner-markup content, flatten descendants.
fn nodeText(a: Allocator, n: *const xml.Node) Allocator.Error![]const u8 {
    if (n.first_child == null) return n.text();
    return std.mem.trim(u8, try n.deepText(a), " \t\r\n");
}

fn firstNonEmpty(cands: []const []const u8) []const u8 {
    for (cands) |c| if (c.len > 0) return c;
    return "";
}

fn childText(a: Allocator, n: *const xml.Node, name: []const u8) Allocator.Error![]const u8 {
    const c = n.child(name) orelse return "";
    return nodeText(a, c);
}

fn rssItem(a: Allocator, source: []const u8, n: *const xml.Node) Allocator.Error!?Item {
    const title = try childText(a, n, "title");
    var link = try childText(a, n, "link");
    var guid = try childText(a, n, "guid");
    if (guid.len == 0) if (n.attr("about")) |ab| { // RDF: rdf:about is the identifier
        guid = ab;
    };
    if (link.len == 0) {
        // RSS where <link> is missing: a permalink guid or atom:link href stands in.
        if (std.mem.startsWith(u8, guid, "http")) link = guid else if (n.child("link")) |l| link = l.attr("href") orelse "";
    }
    const date_raw = firstNonEmpty(&.{ try childText(a, n, "pubDate"), try childText(a, n, "date"), try childText(a, n, "published"), try childText(a, n, "updated") });
    const body = firstNonEmpty(&.{ try childText(a, n, "encoded"), try childText(a, n, "description"), try childText(a, n, "summary") });
    if (title.len == 0 and link.len == 0 and guid.len == 0 and body.len == 0) return null;
    const published = dates.parse(date_raw);
    return .{
        .source = source,
        .id = try deriveId(a, guid, link, published, date_raw, title, body),
        .title = title,
        .url = link,
        .published = published,
        .body = body,
        .kind = .article,
    };
}

fn atomEntry(a: Allocator, source: []const u8, n: *const xml.Node) Allocator.Error!?Item {
    const title = try childText(a, n, "title");
    const guid = try childText(a, n, "id");
    // Prefer rel=alternate (or no rel); else the first link with an href.
    var link: []const u8 = "";
    var first_any: []const u8 = "";
    var c = n.first_child;
    while (c) |ln| : (c = ln.next) {
        if (!ln.is("link")) continue;
        const href = ln.attr("href") orelse continue;
        if (first_any.len == 0) first_any = href;
        const rel = ln.attr("rel") orelse "alternate";
        if (std.mem.eql(u8, rel, "alternate")) {
            link = href;
            break;
        }
    }
    if (link.len == 0) link = first_any;
    const date_raw = firstNonEmpty(&.{ try childText(a, n, "published"), try childText(a, n, "updated"), try childText(a, n, "issued"), try childText(a, n, "modified") });
    const body = firstNonEmpty(&.{ try childText(a, n, "content"), try childText(a, n, "summary") });
    if (title.len == 0 and link.len == 0 and guid.len == 0 and body.len == 0) return null;
    const published = dates.parse(date_raw);
    return .{
        .source = source,
        .id = try deriveId(a, guid, link, published, date_raw, title, body),
        .title = title,
        .url = link,
        .published = published,
        .body = body,
        .kind = .article,
    };
}

/// Resolve `link` against the feed's own URL (RFC 3986 §5), so a relative Atom `href` or RSS
/// `<link>` such as `/posts/1` becomes an absolute URL the UI will render. Empty links, links
/// that already carry a scheme, and unparsable bases pass through unchanged. `xml:base` is not
/// consulted: the fetched feed URL is the right base for the feeds seen in practice.
pub fn resolveLink(a: Allocator, base_url: []const u8, link: []const u8) Allocator.Error![]const u8 {
    if (link.len == 0 or hasScheme(link)) return link;
    const base = std.Uri.parse(base_url) catch return link;
    // resolveInPlace wants the reference at the start of a scratch buffer with room for a merged path.
    const buf = try a.alloc(u8, link.len + base_url.len + 2);
    @memcpy(buf[0..link.len], link);
    var aux: []u8 = buf;
    const resolved = std.Uri.resolveInPlace(base, link.len, &aux) catch return link;
    return std.fmt.allocPrint(a, "{f}", .{resolved.fmt(.all)});
}

fn hasScheme(s: []const u8) bool {
    if (s.len == 0 or !std.ascii.isAlphabetic(s[0])) return false;
    for (s, 0..) |c, i| {
        if (c == ':') return i > 0;
        if (!(std.ascii.isAlphanumeric(c) or c == '+' or c == '-' or c == '.')) return false;
    }
    return false;
}

/// Item identity: the feed's own guid / atom:id when present; otherwise link plus
/// date; otherwise (no link) a content hash of title + body. Prefixes keep the
/// three namespaces from colliding.
pub fn deriveId(a: Allocator, guid: []const u8, link: []const u8, published: ?i64, date_raw: []const u8, title: []const u8, body: []const u8) Allocator.Error![]const u8 {
    if (guid.len > 0) return guid;
    if (link.len > 0) {
        if (published) |p| return std.fmt.allocPrint(a, "link:{s}#{d}", .{ link, p });
        return std.fmt.allocPrint(a, "link:{s}#{s}", .{ link, date_raw });
    }
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(title);
    h.update("\x00");
    h.update(body);
    var d: [32]u8 = undefined;
    h.final(&d);
    return std.fmt.allocPrint(a, "hash:{x}", .{d[0..16]});
}

/// Drop repeated ids inside one fetched batch (first occurrence wins, order kept).
pub fn dedupeBatch(a: Allocator, items: []Item) Allocator.Error![]Item {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var out: std.ArrayList(Item) = .empty;
    for (items) |it| {
        const gop = try seen.getOrPut(a, it.id);
        if (gop.found_existing) continue;
        try out.append(a, it);
    }
    return out.items;
}

// ---------------------------------------------------------------------------
// Tests: real recorded feeds + hand-made edge-case fixtures (src/testdata).
// ---------------------------------------------------------------------------
const testing = std.testing;

fn parseFixture(a: Allocator, comptime path: []const u8, http_charset: ?[]const u8) !Parsed {
    return parse(a, "t", @embedFile("testdata/" ++ path), http_charset);
}

test "real: BBC RSS 2.0 with CDATA and dc:/media: namespaces" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try parseFixture(arena.allocator(), "real/bbc.rss", "utf-8");
    try testing.expectEqual(Format.rss2, p.format);
    try testing.expectEqualStrings("BBC News", p.title);
    try testing.expect(p.items.len >= 20);
    for (p.items) |it| {
        try testing.expect(it.title.len > 0);
        try testing.expect(std.mem.startsWith(u8, it.url, "http"));
        try testing.expect(it.published != null);
        try testing.expect(it.id.len > 0);
    }
}

test "real: LWN, Zig news, kernel.org RSS 2.0" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    inline for (.{ .{ "real/lwn.rss", 15 }, .{ "real/zig.rss", 30 }, .{ "real/kernel.rss", 9 } }) |fx| {
        const p = try parseFixture(a, fx[0], null);
        try testing.expectEqual(Format.rss2, p.format);
        try testing.expectEqual(@as(usize, fx[1]), p.items.len);
        for (p.items) |it| try testing.expect(it.published != null);
    }
}

test "real: Slashdot RSS 1.0 (RDF), ISO-8859-1 declared, items are root children" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try parseFixture(arena.allocator(), "real/slashdot.rdf", null);
    try testing.expectEqual(Format.rdf, p.format);
    try testing.expectEqual(@as(usize, 15), p.items.len);
    for (p.items) |it| {
        try testing.expect(it.title.len > 0);
        try testing.expect(it.published != null); // dc:date
        try testing.expect(std.unicode.utf8ValidateSlice(it.title));
        try testing.expect(std.unicode.utf8ValidateSlice(it.body));
    }
}

test "real: Atom (xkcd, Rust blog)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const x = try parseFixture(a, "real/xkcd.atom", null);
    try testing.expectEqual(Format.atom, x.format);
    try testing.expectEqual(@as(usize, 4), x.items.len);
    try testing.expectEqualStrings("Rejected Space Mission Profiles", x.items[0].title);
    const r = try parseFixture(a, "real/rustblog.atom", null);
    try testing.expectEqual(@as(usize, 10), r.items.len);
    for (r.items) |it| {
        try testing.expect(it.id.len > 0 and it.url.len > 0 and it.published != null and it.body.len > 0);
    }
}

test "edge: malformed XML still yields items" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try parseFixture(arena.allocator(), "malformed.rss", null);
    try testing.expectEqual(@as(usize, 3), p.items.len);
    try testing.expectEqualStrings("Fish & Chips < 5 quid", p.items[0].title);
    try testing.expectEqualStrings("Unclosed description", p.items[1].body);
    try testing.expectEqualStrings("Third", p.items[2].title);
}

test "edge: declared utf-8 but contains cp1252 bytes (mixed encodings)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try parseFixture(arena.allocator(), "mixed-encoding.rss", null);
    try testing.expectEqual(@as(usize, 2), p.items.len);
    try testing.expectEqualStrings("Caf\u{e9} \u{2018}quoted\u{2019} \u{4e2d}\u{6587}", p.items[0].title);
    try testing.expect(std.unicode.utf8ValidateSlice(p.items[1].title));
}

test "edge: UTF-16LE with BOM" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try parseFixture(arena.allocator(), "utf16le.atom", null);
    try testing.expectEqual(Format.atom, p.format);
    try testing.expectEqualStrings("\u{3053}\u{3093}\u{306b}\u{3061}\u{306f}", p.items[0].title);
}

test "edge: HTTP charset overrides a lying declaration" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try parseFixture(arena.allocator(), "latin1-no-declaration.rss", "iso-8859-1");
    try testing.expectEqualStrings("Z\u{fc}rich \u{e0} la carte", p.items[0].title);
}

test "edge: unusual date formats" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try parseFixture(arena.allocator(), "odd-dates.rss", null);
    try testing.expectEqual(@as(usize, 9), p.items.len);
    const expect = [_]?i64{ 946684800, 946684800, 946684800, 946684800, 946684800, 946684800 + 5 * 3600, 946684800, null, 946684800 };
    for (p.items, expect, 0..) |it, e, i| {
        testing.expectEqual(e, it.published) catch |err| {
            std.debug.print("item {d} ({s}): got {?d}\n", .{ i, it.title, it.published });
            return err;
        };
    }
}

test "dedupe: guid wins; link+date fallback; hash fallback; in-batch duplicates dropped" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try parseFixture(arena.allocator(), "dedupe.rss", null);
    try testing.expectEqual(@as(usize, 5), p.items.len); // 7 items, 2 duplicate ids
    try testing.expectEqualStrings("guid-1", p.items[0].id);
    try testing.expectEqualStrings("link:http://example.com/a#946684800", p.items[1].id);
    try testing.expectEqualStrings("link:http://example.com/a#946771200", p.items[2].id); // re-dated post is a new item
    try testing.expect(std.mem.startsWith(u8, p.items[3].id, "hash:"));
    try testing.expectEqualStrings("guid-2", p.items[4].id);
}

test "edge: channel without a title yields an empty title, not a panic" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try parse(arena.allocator(), "t", "<rss><channel><item><title>x</title><link>http://x/1</link></item></channel></rss>", null);
    try testing.expectEqualStrings("", p.title);
    try testing.expectEqual(@as(usize, 1), p.items.len);
    const r = try parse(arena.allocator(), "t", "<rdf:RDF><channel/><item><title>y</title></item></rdf:RDF>", null);
    try testing.expectEqualStrings("", r.title);
    try testing.expectEqual(@as(usize, 1), r.items.len);
}

test "resolveLink: relative references resolve against the feed URL; absolute and schemed pass through" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("http://x/posts/1", try resolveLink(a, "http://x/feed.xml", "/posts/1"));
    try testing.expectEqualStrings("http://x/blog/posts/1", try resolveLink(a, "http://x/blog/feed.xml", "posts/1"));
    try testing.expectEqualStrings("http://x/a/c?q=1", try resolveLink(a, "http://x/a/b/feed", "../c?q=1"));
    try testing.expectEqualStrings("https://x:8443/p", try resolveLink(a, "https://x:8443/feed", "/p"));
    try testing.expectEqualStrings("https://other/z", try resolveLink(a, "http://x/feed", "https://other/z"));
    try testing.expectEqualStrings("mailto:a@b", try resolveLink(a, "http://x/feed", "mailto:a@b"));
    try testing.expectEqualStrings("//cdn/x", try resolveLink(a, "not a url", "//cdn/x"));
    try testing.expectEqualStrings("", try resolveLink(a, "http://x/feed", ""));
}

test "not a feed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.NotAFeed, parse(arena.allocator(), "t", "<html><body>Rate limited</body></html>", null));
    try testing.expectError(error.NoRoot, parse(arena.allocator(), "t", "plain text", null));
}
