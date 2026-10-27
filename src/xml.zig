// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell
//! Tolerant XML-to-DOM parser for syndication feeds.
//!
//! Goals: survive the XML found in the wild (unclosed tags, stray `&`, HTML
//! entities, unquoted attributes, junk before the root) while staying small and
//! bounded. Non-goals: validation, namespaces resolution (prefixes are kept
//! as written and matched on local name), DTD processing. Custom entities are
//! never expanded, so entity-expansion and XXE attacks are impossible.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Limits = struct {
    max_nodes: usize = 200_000,
    max_depth: usize = 256,
};

pub const Attr = struct { name: []const u8, value: []const u8 };

pub const Node = struct {
    name: []const u8,
    attrs: []const Attr = &.{},
    text_buf: std.ArrayList(u8) = .empty,
    /// Length of the parent's `text_buf` when this child was opened: the parent's direct text
    /// before this child ends there. Lets `deepText` keep mixed content in document order.
    text_pos: usize = 0,
    parent: ?*Node = null,
    first_child: ?*Node = null,
    last_child: ?*Node = null,
    next: ?*Node = null,

    pub fn local(self: *const Node) []const u8 {
        return if (std.mem.lastIndexOfScalar(u8, self.name, ':')) |i| self.name[i + 1 ..] else self.name;
    }

    pub fn is(self: *const Node, local_name: []const u8) bool {
        return std.ascii.eqlIgnoreCase(self.local(), local_name);
    }

    /// Direct text content (entities decoded, CDATA included), trimmed.
    pub fn text(self: *const Node) []const u8 {
        return std.mem.trim(u8, self.text_buf.items, " \t\r\n");
    }

    pub fn child(self: *const Node, local_name: []const u8) ?*Node {
        var c = self.first_child;
        while (c) |n| : (c = n.next) if (n.is(local_name)) return n;
        return null;
    }

    pub fn attr(self: *const Node, name: []const u8) ?[]const u8 {
        for (self.attrs) |a| {
            if (std.ascii.eqlIgnoreCase(a.name, name)) return a.value;
            // match on local part of prefixed attribute too (xml:lang -> lang)
            if (std.mem.lastIndexOfScalar(u8, a.name, ':')) |i| {
                if (std.ascii.eqlIgnoreCase(a.name[i + 1 ..], name)) return a.value;
            }
        }
        return null;
    }

    /// All descendant text concatenated in document order (used for xhtml content):
    /// `<p>Hello <b>big</b> world</p>` -> `Hello big world`.
    pub fn deepText(self: *const Node, a: Allocator) Allocator.Error![]u8 {
        var out: std.ArrayList(u8) = .empty;
        try self.deepTextInto(a, &out);
        return out.items;
    }

    fn deepTextInto(self: *const Node, a: Allocator, out: *std.ArrayList(u8)) Allocator.Error!void {
        const direct = self.text_buf.items;
        var pos: usize = 0;
        var c = self.first_child;
        while (c) |n| : (c = n.next) {
            const end = @min(n.text_pos, direct.len);
            if (end > pos) try out.appendSlice(a, direct[pos..end]);
            pos = @max(pos, end);
            try n.deepTextInto(a, out);
        }
        if (direct.len > pos) try out.appendSlice(a, direct[pos..]);
    }
};

pub const ParseError = error{ NoRoot, TooLarge } || Allocator.Error;

const html_entities = [_]struct { []const u8, u21 }{
    .{ "nbsp", 0xA0 },    .{ "copy", 0xA9 },    .{ "reg", 0xAE },     .{ "hellip", 0x2026 },
    .{ "mdash", 0x2014 }, .{ "ndash", 0x2013 }, .{ "lsquo", 0x2018 }, .{ "rsquo", 0x2019 },
    .{ "ldquo", 0x201C }, .{ "rdquo", 0x201D }, .{ "bull", 0x2022 },  .{ "trade", 0x2122 },
    .{ "euro", 0x20AC },  .{ "pound", 0xA3 },   .{ "yen", 0xA5 },     .{ "cent", 0xA2 },
    .{ "laquo", 0xAB },   .{ "raquo", 0xBB },   .{ "eacute", 0xE9 },  .{ "egrave", 0xE8 },
    .{ "agrave", 0xE0 },  .{ "uuml", 0xFC },    .{ "ouml", 0xF6 },    .{ "auml", 0xE4 },
    .{ "szlig", 0xDF },   .{ "middot", 0xB7 },  .{ "deg", 0xB0 },     .{ "times", 0xD7 },
};

fn appendCp(out: *std.ArrayList(u8), a: Allocator, cp: u32) Allocator.Error!void {
    var buf: [4]u8 = undefined;
    const c: u21 = if (cp == 0 or cp > 0x10FFFF or (cp >= 0xD800 and cp <= 0xDFFF)) 0xFFFD else @intCast(cp);
    const n = std.unicode.utf8Encode(c, &buf) catch unreachable;
    try out.appendSlice(a, buf[0..n]);
}

/// Append `raw` to `out`, decoding character and entity references.
pub fn appendDecoded(out: *std.ArrayList(u8), a: Allocator, raw: []const u8) Allocator.Error!void {
    var i: usize = 0;
    while (i < raw.len) {
        const amp = std.mem.indexOfScalarPos(u8, raw, i, '&') orelse {
            try out.appendSlice(a, raw[i..]);
            return;
        };
        try out.appendSlice(a, raw[i..amp]);
        i = amp;
        const semi = std.mem.indexOfScalarPos(u8, raw, amp + 1, ';');
        if (semi == null or semi.? - amp > 12) {
            try out.append(a, '&');
            i += 1;
            continue;
        }
        const name = raw[amp + 1 .. semi.?];
        var done = true;
        if (name.len > 1 and name[0] == '#') {
            const cp: ?u32 = if (name[1] == 'x' or name[1] == 'X')
                std.fmt.parseInt(u32, name[2..], 16) catch null
            else
                std.fmt.parseInt(u32, name[1..], 10) catch null;
            if (cp) |v| try appendCp(out, a, v) else done = false;
        } else if (std.mem.eql(u8, name, "amp")) {
            try out.append(a, '&');
        } else if (std.mem.eql(u8, name, "lt")) {
            try out.append(a, '<');
        } else if (std.mem.eql(u8, name, "gt")) {
            try out.append(a, '>');
        } else if (std.mem.eql(u8, name, "quot")) {
            try out.append(a, '"');
        } else if (std.mem.eql(u8, name, "apos")) {
            try out.append(a, '\'');
        } else {
            done = false;
            for (html_entities) |e| if (std.mem.eql(u8, name, e[0])) {
                try appendCp(out, a, e[1]);
                done = true;
                break;
            };
        }
        if (done) i = semi.? + 1 else {
            try out.append(a, '&');
            i += 1;
        }
    }
}

fn isNameStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_' or c == ':' or c >= 0x80;
}
fn isNameChar(c: u8) bool {
    return isNameStart(c) or std.ascii.isDigit(c) or c == '-' or c == '.';
}

/// Parse UTF-8 `src` (see encoding.zig) into a tree. The returned node is a synthetic
/// document root whose children are the top-level elements; `a` should be an arena.
pub fn parse(a: Allocator, src: []const u8, limits: Limits) ParseError!*Node {
    const root = try a.create(Node);
    root.* = .{ .name = "#document" };
    var cur: *Node = root;
    var depth: usize = 0;
    var count: usize = 0;
    var i: usize = 0;

    while (i < src.len) {
        if (src[i] != '<') {
            const end = std.mem.indexOfScalarPos(u8, src, i, '<') orelse src.len;
            if (cur != root) try appendDecoded(&cur.text_buf, a, src[i..end]);
            i = end;
            continue;
        }
        const rest = src[i..];
        if (std.mem.startsWith(u8, rest, "<!--")) {
            const e = std.mem.indexOf(u8, rest[4..], "-->");
            i = if (e) |x| i + 4 + x + 3 else src.len;
        } else if (std.mem.startsWith(u8, rest, "<![CDATA[")) {
            const e = std.mem.indexOf(u8, rest[9..], "]]>");
            const body = if (e) |x| rest[9 .. 9 + x] else rest[9..];
            if (cur != root) try cur.text_buf.appendSlice(a, body);
            i = if (e) |x| i + 9 + x + 3 else src.len;
        } else if (std.mem.startsWith(u8, rest, "<!")) {
            // DOCTYPE or other declaration: skip, honouring an internal subset [...].
            var j = i + 2;
            var bracket: usize = 0;
            while (j < src.len) : (j += 1) {
                if (src[j] == '[') bracket += 1;
                if (src[j] == ']' and bracket > 0) bracket -= 1;
                if (src[j] == '>' and bracket == 0) break;
            }
            i = @min(j + 1, src.len);
        } else if (std.mem.startsWith(u8, rest, "<?")) {
            const e = std.mem.indexOf(u8, rest[2..], "?>");
            i = if (e) |x| i + 2 + x + 2 else src.len;
        } else if (std.mem.startsWith(u8, rest, "</")) {
            var j = i + 2;
            const ns = j;
            while (j < src.len and isNameChar(src[j])) j += 1;
            const name = src[ns..j];
            while (j < src.len and src[j] != '>') j += 1;
            i = @min(j + 1, src.len);
            // Pop to the nearest matching open element; ignore stray end tags.
            var p: ?*Node = cur;
            while (p) |n| : (p = n.parent) {
                if (n == root) break;
                if (std.mem.eql(u8, n.name, name)) {
                    var k: ?*Node = cur;
                    while (k != null and k.? != n) : (k = k.?.parent) depth -= 1;
                    cur = n.parent.?;
                    depth -= 1;
                    break;
                }
            }
        } else if (rest.len > 1 and isNameStart(rest[1])) {
            var j = i + 1;
            while (j < src.len and isNameChar(src[j])) j += 1;
            const name = src[i + 1 .. j];
            var attrs: std.ArrayList(Attr) = .empty;
            var self_close = false;
            // attributes
            while (j < src.len) {
                while (j < src.len and std.ascii.isWhitespace(src[j])) j += 1;
                if (j >= src.len) break;
                if (src[j] == '>') {
                    j += 1;
                    break;
                }
                if (src[j] == '/') {
                    self_close = true;
                    j += 1;
                    continue;
                }
                if (src[j] == '<') break; // malformed: new tag begins; don't consume it
                const ans = j;
                while (j < src.len and !std.ascii.isWhitespace(src[j]) and src[j] != '=' and src[j] != '>' and src[j] != '/' and src[j] != '<') j += 1;
                const an = src[ans..j];
                if (an.len == 0) {
                    j += 1;
                    continue;
                }
                while (j < src.len and std.ascii.isWhitespace(src[j])) j += 1;
                var value: []const u8 = "";
                if (j < src.len and src[j] == '=') {
                    j += 1;
                    while (j < src.len and std.ascii.isWhitespace(src[j])) j += 1;
                    if (j < src.len and (src[j] == '"' or src[j] == '\'')) {
                        const q = src[j];
                        const vs = j + 1;
                        const ve = std.mem.indexOfScalarPos(u8, src, vs, q) orelse src.len;
                        var buf: std.ArrayList(u8) = .empty;
                        try appendDecoded(&buf, a, src[vs..ve]);
                        value = buf.items;
                        j = @min(ve + 1, src.len);
                    } else {
                        const vs = j;
                        while (j < src.len and !std.ascii.isWhitespace(src[j]) and src[j] != '>') j += 1;
                        var buf: std.ArrayList(u8) = .empty;
                        try appendDecoded(&buf, a, src[vs..j]);
                        value = buf.items;
                    }
                }
                try attrs.append(a, .{ .name = an, .value = value });
            }
            i = j;
            count += 1;
            if (count > limits.max_nodes or depth >= limits.max_depth) return error.TooLarge;
            const node = try a.create(Node);
            node.* = .{ .name = name, .attrs = attrs.items, .parent = cur, .text_pos = cur.text_buf.items.len };
            if (cur.last_child) |l| l.next = node else cur.first_child = node;
            cur.last_child = node;
            if (!self_close) {
                cur = node;
                depth += 1;
            }
        } else {
            // Lone '<' that is not markup: treat as text.
            if (cur != root) try cur.text_buf.append(a, '<');
            i += 1;
        }
    }
    if (root.first_child == null) return error.NoRoot;
    return root;
}

/// First element child of the document (the root element).
pub fn rootElement(doc: *Node) ?*Node {
    return doc.first_child;
}

fn parseT(a: Allocator, s: []const u8) !*Node {
    return parse(a, s, .{});
}

test "basic tree, attrs, cdata, entities" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const doc = try parseT(a, "<?xml version=\"1.0\"?><r x='1' y=\"a&amp;b\" z=q><t>a &lt; b &#x41;&#66;</t><c><![CDATA[<b>raw</b>]]></c><e/></r>");
    const r = rootElement(doc).?;
    try std.testing.expectEqualStrings("a&b", r.attr("y").?);
    try std.testing.expectEqualStrings("q", r.attr("z").?);
    try std.testing.expectEqualStrings("a < b AB", r.child("t").?.text());
    try std.testing.expectEqualStrings("<b>raw</b>", r.child("c").?.text());
    try std.testing.expect(r.child("e") != null);
}

test "malformed: unclosed tags, stray ampersand, stray end tag, lone <" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const doc = try parseT(a, "junk<rss><channel><item><title>Fish & Chips < 5</title><link>http://x/?a=1&b=2</link></bogus><description>d</item><item><title>2</title></rss>");
    const ch = rootElement(doc).?.child("channel").?;
    const it = ch.child("item").?;
    try std.testing.expectEqualStrings("Fish & Chips < 5", it.child("title").?.text());
    try std.testing.expectEqualStrings("http://x/?a=1&b=2", it.child("link").?.text());
    try std.testing.expectEqualStrings("d", it.child("description").?.text());
    try std.testing.expect(it.next != null);
}

test "doctype with internal subset and custom entity is not expanded" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const doc = try parseT(a, "<!DOCTYPE r [<!ENTITY lol \"lol\"><!ENTITY x SYSTEM \"file:///etc/passwd\">]><r>&x;&lol;</r>");
    try std.testing.expectEqualStrings("&x;&lol;", rootElement(doc).?.text());
}

test "no root and limits" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectError(error.NoRoot, parseT(a, "just text"));
    try std.testing.expectError(error.TooLarge, parse(a, "<a><b><c/></b></a>", .{ .max_nodes = 2 }));
    try std.testing.expectError(error.TooLarge, parse(a, "<a><b><c>", .{ .max_depth = 2 }));
}

test "deepText keeps mixed content in document order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const doc = try parseT(a, "<t><p>Hello <b>big</b> world<br/>, <i>a<u>b</u>c</i>d</p></t>");
    const p = rootElement(doc).?.child("p").?;
    try std.testing.expectEqualStrings("Hello big world, abcd", try p.deepText(a));
    try std.testing.expectEqualStrings("Hello  world, d", p.text()); // direct text only, as before
}

test "prefix handling and html entities" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const doc = try parseT(a, "<rdf:RDF><item rdf:about=\"u\"><dc:date>d</dc:date><title>a&nbsp;b&mdash;c&bogus;</title></item></rdf:RDF>");
    const it = rootElement(doc).?.child("item").?;
    try std.testing.expectEqualStrings("u", it.attr("about").?);
    try std.testing.expectEqualStrings("d", it.child("date").?.text());
    try std.testing.expectEqualStrings("a\u{a0}b\u{2014}c&bogus;", it.child("title").?.text());
}
