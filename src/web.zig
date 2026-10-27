// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell
//! Minimal localhost-only web UI: item list, search, item view, read/unread, source and monitor status.
//!
//! Runs on its own task with its **own** SQLite connection (WAL: readers never block the poller; the
//! few writes — read marks — use a 5 s busy timeout). Server-rendered HTML, no JavaScript, no assets.
//!
//! Safety: bind address must be loopback (checked at start); every request's Host header must name
//! the bound address (DNS-rebinding defence); mutations are POST-only and, when an Origin header is
//! present, it must match Host (CSRF); CSP forbids scripts, frames and external loads; all text is
//! HTML-escaped; only http(s) URLs are rendered as links.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const app_mod = @import("app.zig");
const store_mod = @import("store.zig");
const monitor = @import("monitor.zig");
const localserver = @import("localserver.zig");
const util = @import("util.zig");

pub const Web = struct {
    gpa: Allocator,
    io: Io,
    app: *app_mod.App,
    store: *store_mod.Store,
    /// Port actually bound (differs from config when 0 was requested, e.g. in tests).
    port: u16 = 0,
    /// Address actually bound; accepted in the Host header alongside the loopback names, so a
    /// server on 127.0.0.2 or on an explicitly allowed non-loopback address answers its own name.
    bind: []const u8 = "127.0.0.1",
    /// Fixed-clock override for tests (seconds); 0 = real time.
    fixed_now: i64 = 0,

    fn now(self: *Web) i64 {
        return if (self.fixed_now != 0) self.fixed_now else Io.Timestamp.now(self.io, .real).toSeconds();
    }
};

pub fn isLoopback(addr: []const u8) bool {
    return std.mem.eql(u8, addr, "127.0.0.1") or std.mem.eql(u8, addr, "::1") or std.mem.startsWith(u8, addr, "127.");
}

/// Bind the listener (refusing non-loopback addresses). Caller then runs `localserver.serve` on a task.
pub fn bind(io: Io, bind_addr: []const u8, port: u16, allow_non_loopback: bool) !Io.net.Server {
    if (!allow_non_loopback and !isLoopback(bind_addr)) return error.NotLoopback;
    return localserver.listen(io, bind_addr, port);
}

pub fn handler(ctx: *anyopaque, req: *std.http.Server.Request) void {
    const w: *Web = @ptrCast(@alignCast(ctx));
    var arena = std.heap.ArenaAllocator.init(w.gpa);
    defer arena.deinit();
    handle(w, arena.allocator(), req) catch |e| {
        std.log.warn("web: {s}", .{@errorName(e)});
        send(req, .internal_server_error, "text/plain; charset=utf-8", "internal error\n", null);
    };
}

const security_headers = [_]std.http.Header{
    .{ .name = "Content-Security-Policy", .value = "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'" },
    .{ .name = "X-Content-Type-Options", .value = "nosniff" },
    .{ .name = "Referrer-Policy", .value = "no-referrer" },
    .{ .name = "X-Frame-Options", .value = "DENY" },
    .{ .name = "Cache-Control", .value = "no-store" },
};

fn send(req: *std.http.Server.Request, status: std.http.Status, ctype: []const u8, body: []const u8, location: ?[]const u8) void {
    var hs: [security_headers.len + 2]std.http.Header = undefined;
    var n: usize = 0;
    for (security_headers) |h| {
        hs[n] = h;
        n += 1;
    }
    hs[n] = .{ .name = "Content-Type", .value = ctype };
    n += 1;
    if (location) |l| {
        hs[n] = .{ .name = "Location", .value = l };
        n += 1;
    }
    req.respond(body, .{ .status = status, .keep_alive = false, .extra_headers = hs[0..n] }) catch {};
}

fn hostOk(w: *Web, host: []const u8) bool {
    // Accept exactly 127.0.0.1:PORT, localhost:PORT, [::1]:PORT, and the bound address itself
    // (bracketed when IPv6). Anything else is a DNS-rebinding attempt or a misdirected request.
    // A wildcard bind (0.0.0.0 / ::) is deliberately not special-cased: name the address you expose.
    var buf: [320]u8 = undefined;
    inline for (.{ "127.0.0.1", "localhost", "[::1]" }) |h| {
        const want = std.fmt.bufPrint(&buf, "{s}:{d}", .{ h, w.port }) catch return false;
        if (std.ascii.eqlIgnoreCase(host, want)) return true;
    }
    const is_v6 = std.mem.indexOfScalar(u8, w.bind, ':') != null;
    const own = (if (is_v6) std.fmt.bufPrint(&buf, "[{s}]:{d}", .{ w.bind, w.port }) else std.fmt.bufPrint(&buf, "{s}:{d}", .{ w.bind, w.port })) catch return false;
    return std.ascii.eqlIgnoreCase(host, own);
}

fn handle(w: *Web, a: Allocator, req: *std.http.Server.Request) !void {
    var host: ?[]const u8 = null;
    var origin: ?[]const u8 = null;
    var it = req.iterateHeaders();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "host")) host = h.value;
        if (std.ascii.eqlIgnoreCase(h.name, "origin")) origin = h.value;
    }
    if (host == null or !hostOk(w, host.?)) return send(req, .misdirected_request, "text/plain; charset=utf-8", "bad host\n", null);

    const target = req.head.target;
    const qpos = std.mem.indexOfScalar(u8, target, '?');
    const path = target[0 .. qpos orelse target.len];
    const query = if (qpos) |q| target[q + 1 ..] else "";
    const is_post = req.head.method == .POST;
    if (req.head.method != .GET and req.head.method != .HEAD and !is_post)
        return send(req, .method_not_allowed, "text/plain; charset=utf-8", "method not allowed\n", null);

    if (is_post) {
        if (origin) |o| {
            const want = try std.fmt.allocPrint(a, "http://{s}", .{host.?});
            if (!std.ascii.eqlIgnoreCase(o, want)) return send(req, .forbidden, "text/plain; charset=utf-8", "cross-origin request refused\n", null);
        }
        return handlePost(w, a, req, path, query);
    }

    var out: Io.Writer.Allocating = .init(a);
    const o = &out.writer;
    if (std.mem.eql(u8, path, "/")) {
        try pageList(w, a, o, query);
    } else if (std.mem.startsWith(u8, path, "/item/")) {
        const rowid = std.fmt.parseInt(i64, path["/item/".len..], 10) catch return send(req, .not_found, "text/plain; charset=utf-8", "not found\n", null);
        // Only a real GET marks the item read; HEAD (link checkers, previews) must not mutate.
        if (!try pageItem(w, a, o, rowid, req.head.method == .GET)) return send(req, .not_found, "text/plain; charset=utf-8", "not found\n", null);
    } else if (std.mem.eql(u8, path, "/status")) {
        try pageStatus(w, a, o);
    } else return send(req, .not_found, "text/plain; charset=utf-8", "not found\n", null);
    send(req, .ok, "text/html; charset=utf-8", out.written(), null);
}

fn handlePost(w: *Web, a: Allocator, req: *std.http.Server.Request, path: []const u8, query: []const u8) !void {
    const t = w.now();
    if (std.mem.startsWith(u8, path, "/read/") or std.mem.startsWith(u8, path, "/unread/")) {
        const is_read = std.mem.startsWith(u8, path, "/read/");
        const rowid = std.fmt.parseInt(i64, path[(if (is_read) @as(usize, 6) else 8)..], 10) catch
            return send(req, .not_found, "text/plain; charset=utf-8", "not found\n", null);
        if (try w.store.getRecord(a, rowid)) |rec| try w.store.setRead(rec.source, rec.id, is_read, t) else return send(req, .not_found, "text/plain; charset=utf-8", "not found\n", null);
    } else if (std.mem.eql(u8, path, "/mark-all-read")) {
        const src = try queryParam(a, query, "source");
        _ = try w.store.markAllRead(if (src) |s| (if (s.len > 0) s else null) else null, t);
    } else return send(req, .not_found, "text/plain; charset=utf-8", "not found\n", null);
    send(req, .see_other, "text/plain; charset=utf-8", "", "/");
}

// ---- pages -----------------------------------------------------------------------------------

const style =
    \\<style>
    \\:root{color-scheme:light dark;--fg:#1d1d1f;--bg:#fff;--mut:#6e6e73;--ln:#d2d2d7;--ac:#0b57d0}
    \\@media(prefers-color-scheme:dark){:root{--fg:#e8e8ed;--bg:#161618;--mut:#98989d;--ln:#38383a;--ac:#8ab4f8}}
    \\body{font:16px/1.5 system-ui,sans-serif;color:var(--fg);background:var(--bg);margin:0 auto;max-width:56rem;padding:1rem}
    \\a{color:var(--ac)}nav a,nav button{margin-right:1rem}header{border-bottom:1px solid var(--ln);margin-bottom:1rem}
    \\li{list-style:none;padding:.4rem 0;border-bottom:1px solid var(--ln)}ul{padding:0}
    \\.unread a.t{font-weight:700}.m{color:var(--mut);font-size:.85rem}pre{white-space:pre-wrap;word-wrap:break-word}
    \\table{border-collapse:collapse;width:100%}td,th{text-align:left;padding:.25rem .5rem;border-bottom:1px solid var(--ln)}
    \\button{font:inherit;background:none;border:0;color:var(--ac);cursor:pointer;padding:0}form{display:inline}
    \\input[type=search]{font:inherit;padding:.2rem .4rem}
    \\</style>
;

fn esc(o: *Io.Writer, s: []const u8) !void {
    for (s) |c| switch (c) {
        '&' => try o.writeAll("&amp;"),
        '<' => try o.writeAll("&lt;"),
        '>' => try o.writeAll("&gt;"),
        '"' => try o.writeAll("&quot;"),
        '\'' => try o.writeAll("&#39;"),
        else => try o.writeByte(c),
    };
}

fn urlEnc(o: *Io.Writer, s: []const u8) !void {
    for (s) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') try o.writeByte(c) else try o.print("%{X:0>2}", .{c});
    }
}

fn head(o: *Io.Writer, title: []const u8) !void {
    try o.writeAll("<!doctype html><html lang=en><meta charset=utf-8><meta name=viewport content=\"width=device-width,initial-scale=1\"><title>");
    try esc(o, title);
    try o.writeAll("</title>");
    try o.writeAll(style);
    try o.writeAll("<body><header><nav><a href=\"/\">Unread</a><a href=\"/?all=1\">All</a><a href=\"/status\">Status</a>" ++
        "<form action=\"/\" method=get><input type=search name=q placeholder=\"search (3+ chars)\"> <button>Search</button></form></nav></header>");
}

/// Highest list page served; 1e6 pages of 50 is 5e7 rows, far beyond any log, and 5e7 fits u32.
const max_page: u32 = 1_000_000;

fn sourceParam(o: *Io.Writer, source: ?[]const u8) !void {
    const s = source orelse return;
    try o.writeAll("&amp;source=");
    try urlEnc(o, s);
}

fn isWebUrl(u: []const u8) bool {
    return std.ascii.startsWithIgnoreCase(u, "http://") or std.ascii.startsWithIgnoreCase(u, "https://");
}

fn pageList(w: *Web, a: Allocator, o: *Io.Writer, query: []const u8) !void {
    const q = try queryParam(a, query, "q");
    const source = blk: {
        const s = try queryParam(a, query, "source");
        break :blk if (s) |v| (if (v.len > 0) v else null) else null;
    };
    const all = (try queryParam(a, query, "all")) != null;
    // Clamp the page so `page * per` can never overflow u32 (a ReleaseSafe panic on a crafted URL).
    const page: u32 = if (try queryParam(a, query, "page")) |p| @min(std.fmt.parseInt(u32, p, 10) catch 0, max_page) else 0;
    const per: u32 = 50;

    try head(o, "heron-polyfeed-reader");
    const rows = if (q) |text|
        (if (text.len >= 3) try w.store.search(a, text, per) else &[_]store_mod.Row{})
    else
        try w.store.list(a, .{ .source = source, .unread_only = !all, .limit = per + 1, .offset = page * per });
    const c = try w.store.count();
    try o.print("<p class=m>{d} unread of {d} items", .{ c.unread, c.total });
    if (q) |text| {
        try o.writeAll(" — search “");
        try esc(o, text);
        try o.writeAll("”");
    }
    try o.writeAll("</p>");
    if (q == null) {
        try o.writeAll("<form method=post action=\"/mark-all-read");
        if (source) |s| {
            try o.writeAll("?source=");
            try urlEnc(o, s);
        }
        try o.writeAll("\"><button>Mark all read</button></form>");
    }
    try o.writeAll("<ul>");
    const shown = @min(rows.len, per);
    for (rows[0..shown]) |r| {
        try o.print("<li class=\"{s}\"><a class=t href=\"/item/{d}\">", .{ if (r.read) "read" else "unread", r.rowid });
        try esc(o, if (r.title.len > 0) r.title else "(untitled)");
        try o.writeAll("</a><br><span class=m>");
        try esc(o, r.source);
        if (!std.mem.eql(u8, r.kind, "article")) {
            try o.writeAll(" · ");
            try esc(o, r.kind);
        }
        var db: [32]u8 = undefined;
        try o.print(" · {s}</span></li>", .{if (r.published) |p| util.fmtDate(&db, p) else "undated"});
    }
    try o.writeAll("</ul>");
    if (q == null) {
        // Pagination keeps every filter the page was opened with (all, source).
        if (page > 0) {
            try o.print("<a href=\"/?page={d}{s}", .{ page - 1, if (all) "&amp;all=1" else "" });
            try sourceParam(o, source);
            try o.writeAll("\">« newer</a> ");
        }
        if (rows.len > per) {
            try o.print("<a href=\"/?page={d}{s}", .{ page + 1, if (all) "&amp;all=1" else "" });
            try sourceParam(o, source);
            try o.writeAll("\">older »</a>");
        }
    }
    try o.writeAll("</body></html>");
}

fn pageItem(w: *Web, a: Allocator, o: *Io.Writer, rowid: i64, mark_read: bool) !bool {
    const rec = (try w.store.getRecord(a, rowid)) orelse return false;
    if (mark_read) try w.store.setRead(rec.source, rec.id, true, w.now()); // opening an item marks it read
    try head(o, rec.title);
    try o.writeAll("<h2>");
    try esc(o, rec.title);
    try o.writeAll("</h2><p class=m>");
    try esc(o, rec.source);
    var db: [32]u8 = undefined;
    try o.print(" · {s} · {s}</p>", .{ if (rec.published) |p| util.fmtDate(&db, p) else "undated", @tagName(rec.kind) });
    if (isWebUrl(rec.url)) {
        try o.writeAll("<p><a rel=\"noreferrer noopener\" href=\"");
        try esc(o, rec.url);
        try o.writeAll("\">");
        try esc(o, rec.url);
        try o.writeAll("</a></p>");
    } else if (rec.url.len > 0) {
        try o.writeAll("<p class=m>");
        try esc(o, rec.url);
        try o.writeAll("</p>");
    }
    try o.print("<form method=post action=\"/unread/{d}\"><button>Mark unread</button></form><pre>", .{rowid});
    try esc(o, try store_mod.plainText(a, rec.body, 64 * 1024));
    try o.writeAll("</pre></body></html>");
    return true;
}

fn pageStatus(w: *Web, a: Allocator, o: *Io.Writer) !void {
    try head(o, "status");
    const t = w.now();
    try o.writeAll("<h3>Sources</h3><table><tr><th>name<th>type<th>last ok<th>fails<th>last error");
    for (w.app.jobs) |job| {
        if (std.mem.eql(u8, job.type_name, "monitor")) continue;
        const st = try w.store.getSourceState(a, job.name);
        var b: [16]u8 = undefined;
        try o.writeAll("<tr><td>");
        try esc(o, job.name);
        try o.print("<td>{s}<td>{s}<td>{d}<td>", .{ job.type_name, if (st.last_ok) |x| util.fmtSpan(&b, t - x) else "never", st.failures });
        try esc(o, st.last_error orelse "");
    }
    try o.writeAll("</table><h3>Monitors</h3><table><tr><th>name<th>state<th>since<th>http<th>cert expires in<th>note");
    for (w.app.jobs) |job| {
        if (!std.mem.eql(u8, job.type_name, "monitor")) continue;
        const st = try w.store.getSourceState(a, job.name);
        const ms = monitor.parseState(a, st.adapter_state);
        var b1: [16]u8 = undefined;
        var b3: [16]u8 = undefined;
        try o.writeAll("<tr><td>");
        try esc(o, job.name);
        const state: []const u8 = if (ms.blocked) "blocked" else if (ms.up) |u| (if (u) "up" else "DOWN") else "unknown";
        try o.print("<td>{s}<td>{s}<td>{d}<td>{s}<td>", .{
            state,
            if (ms.since > 0) util.fmtSpan(&b1, t - ms.since) else "-",
            ms.status,
            if (ms.cert_not_after > 0) (if (ms.cert_not_after <= t) "EXPIRED" else util.fmtSpan(&b3, ms.cert_not_after - t)) else "-",
        });
        try esc(o, ms.err);
    }
    try o.writeAll("</table></body></html>");
}

// ---- query strings ---------------------------------------------------------------------------

/// Value of `key` in an application/x-www-form-urlencoded query string, percent-decoded; null if absent.
pub fn queryParam(a: Allocator, query: []const u8, key: []const u8) Allocator.Error!?[]const u8 {
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=');
        const k = pair[0 .. eq orelse pair.len];
        if (!std.mem.eql(u8, k, key)) continue;
        const v = if (eq) |e| pair[e + 1 ..] else "";
        return try decode(a, v);
    }
    return null;
}

fn decode(a: Allocator, s: []const u8) Allocator.Error![]const u8 {
    var out = try a.alloc(u8, s.len);
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == '+') {
            out[n] = ' ';
        } else if (c == '%' and i + 2 < s.len) {
            const hex = std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16) catch {
                out[n] = c;
                n += 1;
                continue;
            };
            out[n] = hex;
            i += 2;
        } else out[n] = c;
        n += 1;
    }
    return out[0..n];
}

const testing = std.testing;

test "queryParam decodes and finds keys" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("a b&c", (try queryParam(a, "x=1&q=a+b%26c&z", "q")).?);
    try testing.expect((try queryParam(a, "x=1", "q")) == null);
    try testing.expectEqualStrings("", (try queryParam(a, "q=", "q")).?);
    try testing.expectEqualStrings("%zz", (try queryParam(a, "q=%zz", "q")).?);
    try testing.expectEqualStrings("é", (try queryParam(a, "q=%C3%A9", "q")).?);
}

test "loopback check" {
    try testing.expect(isLoopback("127.0.0.1"));
    try testing.expect(isLoopback("::1"));
    try testing.expect(!isLoopback("0.0.0.0"));
    try testing.expect(!isLoopback("192.168.1.2"));
}

fn rawRequest(a: Allocator, io: Io, port: u16, request: []const u8) ![]const u8 {
    const addr = try Io.net.IpAddress.parse("127.0.0.1", port);
    const stream = try addr.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    var wbuf: [1024]u8 = undefined;
    var rbuf: [4096]u8 = undefined;
    var wr = stream.writer(io, &wbuf);
    try wr.interface.writeAll(request);
    try wr.interface.flush();
    var rd = stream.reader(io, &rbuf);
    return rd.interface.allocRemaining(a, .limited(1 << 20)) catch |e| switch (e) {
        error.ReadFailed => return "",
        else => |x| return x,
    };
}

test "web UI end to end: pages, escaping, read marks, host/origin checks, loopback only" {
    const io = testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", a);

    var st = try store_mod.Store.open(testing.allocator, io, dir, true);
    defer st.close();
    const Item = @import("item.zig").Item;
    _ = try st.ingest(&[_]Item{
        .{ .source = "s1", .id = "1", .title = "<script>alert(1)</script> & Zig", .url = "javascript:alert(1)", .published = 1000, .body = "<p>Hello <b>world</b></p>", .kind = .article },
        .{ .source = "s1", .id = "2", .title = "Second", .url = "https://example.org/2", .published = 2000, .body = "needle haystack", .kind = .article },
    }, 5000);

    var jobs = [_]@import("adapter.zig").Source{.{ .name = "s1", .type_name = "rss", .url = "https://example.org/feed", .interval_s = 600, .options = "" }};
    var app: app_mod.App = .{ .gpa = testing.allocator, .io = io, .arena = std.heap.ArenaAllocator.init(testing.allocator), .config_path = "", .data_dir = dir, .cfg = .{}, .jobs = &jobs };
    defer app.arena.deinit();

    try testing.expectError(error.NotLoopback, bind(io, "0.0.0.0", 0, false));
    var server = try bind(io, "127.0.0.1", 0, false);
    var w: Web = .{ .gpa = testing.allocator, .io = io, .app = &app, .store = &st, .port = localserver.port(&server), .fixed_now = 6000 };
    var fut = try io.concurrent(localserver.serve, .{ io, &server, @as(*anyopaque, &w), handler });
    defer {
        _ = fut.cancel(io);
        server.deinit(io);
    }

    const hostline = try std.fmt.allocPrint(a, "Host: 127.0.0.1:{d}\r\n", .{w.port});
    const get = struct {
        fn f(al: Allocator, i: Io, p: u16, method: []const u8, path: []const u8, extra: []const u8) ![]const u8 {
            const req = try std.fmt.allocPrint(al, "{s} {s} HTTP/1.1\r\n{s}Connection: close\r\n\r\n", .{ method, path, extra });
            return rawRequest(al, i, p, req);
        }
    }.f;

    // Index: both unread, title escaped, never raw markup.
    const idx = try get(a, io, w.port, "GET", "/", hostline);
    try testing.expect(std.mem.startsWith(u8, idx, "HTTP/1.1 200"));
    try testing.expect(std.mem.indexOf(u8, idx, "&lt;script&gt;alert(1)") != null);
    try testing.expect(std.mem.indexOf(u8, idx, "<script>") == null);
    try testing.expect(std.mem.indexOf(u8, idx, "Content-Security-Policy") != null);
    try testing.expect(std.mem.indexOf(u8, idx, "2 unread of 2") != null);

    // Item view marks read; javascript: URL is not made into a link.
    const item1 = try get(a, io, w.port, "GET", "/item/1", hostline);
    try testing.expect(std.mem.indexOf(u8, item1, "Hello world") != null);
    try testing.expect(std.mem.indexOf(u8, item1, "href=\"javascript:") == null);
    try testing.expectEqual(@as(i64, 1), (try st.count()).unread);
    const item2 = try get(a, io, w.port, "GET", "/item/2", hostline);
    try testing.expect(std.mem.indexOf(u8, item2, "href=\"https://example.org/2\"") != null);
    try testing.expectEqual(@as(i64, 0), (try st.count()).unread);

    // POST /unread/N works (303 back to /), GET to a mutating path does not mutate.
    const un = try get(a, io, w.port, "POST", "/unread/2", hostline);
    try testing.expect(std.mem.startsWith(u8, un, "HTTP/1.1 303"));
    try testing.expectEqual(@as(i64, 1), (try st.count()).unread);
    _ = try get(a, io, w.port, "GET", "/mark-all-read", hostline);
    try testing.expectEqual(@as(i64, 1), (try st.count()).unread);
    _ = try get(a, io, w.port, "POST", "/mark-all-read", hostline);
    try testing.expectEqual(@as(i64, 0), (try st.count()).unread);

    // Search (substring, trigram) and the status page.
    const s = try get(a, io, w.port, "GET", "/?q=hayst", hostline);
    try testing.expect(std.mem.indexOf(u8, s, "Second") != null);
    const stat = try get(a, io, w.port, "GET", "/status", hostline);
    try testing.expect(std.mem.indexOf(u8, stat, "s1") != null);

    // DNS-rebinding and CSRF defences.
    const evil = try get(a, io, w.port, "GET", "/", "Host: evil.example\r\n");
    try testing.expect(std.mem.startsWith(u8, evil, "HTTP/1.1 421"));
    const csrf = try get(a, io, w.port, "POST", "/unread/1", try std.fmt.allocPrint(a, "{s}Origin: http://evil.example\r\n", .{hostline}));
    try testing.expect(std.mem.startsWith(u8, csrf, "HTTP/1.1 403"));
    try testing.expectEqual(@as(i64, 0), (try st.count()).unread);
    const nf = try get(a, io, w.port, "GET", "/item/999", hostline);
    try testing.expect(std.mem.startsWith(u8, nf, "HTTP/1.1 404"));

    // Pagination keeps the source filter (and `all`). Two items, 50 per page: page 1 shows a "newer" link.
    const p1 = try get(a, io, w.port, "GET", "/?page=1&all=1&source=s1", hostline);
    try testing.expect(std.mem.indexOf(u8, p1, "href=\"/?page=0&amp;all=1&amp;source=s1\"") != null);

    // HEAD must not mark an item read; an absurd page number must not overflow (ReleaseSafe panic).
    _ = try get(a, io, w.port, "POST", "/unread/1", hostline);
    try testing.expectEqual(@as(i64, 1), (try st.count()).unread);
    const hd = try get(a, io, w.port, "HEAD", "/item/1", hostline);
    try testing.expect(std.mem.startsWith(u8, hd, "HTTP/1.1 200"));
    try testing.expectEqual(@as(i64, 1), (try st.count()).unread);
    const big = try get(a, io, w.port, "GET", "/?page=4294967295", hostline);
    try testing.expect(std.mem.startsWith(u8, big, "HTTP/1.1 200"));
}
