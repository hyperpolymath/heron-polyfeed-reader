// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell
//! Storage.
//!
//!  * `items.ndjson` — append-only log, one JSON object per line. THE source of truth for items.
//!  * `state.db` (SQLite, WAL) — mutable state (read marks, per-source ETag / Last-Modified /
//!    next poll / failures) plus two *derived* structures rebuilt from the log at any time:
//!    the `items` index (dedupe + listing) and an FTS5 trigram index over title and text.
//!
//! Write order is log first (fsync), then SQLite. SQLite records how far into the log it has
//! indexed (`meta.indexed_offset`); on open, anything beyond that is replayed, so a crash
//! between the two steps heals itself. `rebuild` wipes the derived tables and replays everything.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const sqlite = @import("sqlite.zig");
const Item = @import("item.zig").Item;
const Kind = @import("item.zig").Kind;
const dedupe = @import("dedupe.zig");

pub const log_name = "items.ndjson";
pub const db_name = "state.db";
pub const lock_name = "heron.lock";
const fts_text_cap = 8 * 1024;
const max_line = 32 * 1024 * 1024;

/// One log line. `t` is the ingest time (Unix seconds).
pub const Record = struct {
    v: u8 = 1,
    t: i64,
    source: []const u8,
    id: []const u8,
    title: []const u8,
    url: []const u8,
    published: ?i64,
    body: []const u8,
    kind: Kind,
};

pub const SourceState = struct {
    etag: ?[]const u8 = null,
    last_modified: ?[]const u8 = null,
    /// Adapter-private state blob (see adapter.Cond.state).
    adapter_state: ?[]const u8 = null,
    /// Wall-clock Unix seconds of the next planned poll.
    next_poll: ?i64 = null,
    failures: u32 = 0,
    last_check: ?i64 = null,
    last_ok: ?i64 = null,
    last_error: ?[]const u8 = null,
};

pub const Row = struct {
    rowid: i64,
    source: []const u8,
    id: []const u8,
    title: []const u8,
    url: []const u8,
    published: ?i64,
    ingested: i64,
    kind: []const u8,
    read: bool,
};

pub const ListOpts = struct {
    source: ?[]const u8 = null,
    unread_only: bool = false,
    limit: u32 = 50,
    offset: u32 = 0,
};

pub const Store = struct {
    gpa: Allocator,
    io: Io,
    dir: Io.Dir,
    log: Io.File,
    lock_file: ?Io.File,
    log_size: u64,
    /// Set when a log append succeeded but its SQLite indexing did not (the transaction rolled
    /// back while `log_size` had already advanced). The next ingest replays from
    /// `meta.indexed_offset` first, so those durable records are never skipped over.
    index_lagging: bool = false,
    db: sqlite.Db,
    ins_item: sqlite.Stmt,
    ins_fts: sqlite.Stmt,
    has_item: sqlite.Stmt,

    pub const OpenError = error{ AlreadyRunning, StoreOpenFailed } || sqlite.Error || Allocator.Error;

    /// `exclusive`: take the data-directory lock (daemon and mutating maintenance commands).
    /// Read-only commands pass false and may run next to a live daemon.
    pub fn open(gpa: Allocator, io: Io, dir_path: []const u8, exclusive: bool) OpenError!Store {
        const cwd = Io.Dir.cwd();
        cwd.createDirPath(io, dir_path) catch return error.StoreOpenFailed;
        const dir = cwd.openDir(io, dir_path, .{}) catch return error.StoreOpenFailed;
        errdefer dir.close(io);

        var lock_file: ?Io.File = null;
        if (exclusive) {
            const lf = dir.createFile(io, lock_name, .{ .truncate = false }) catch return error.StoreOpenFailed;
            const got = lf.tryLock(io, .exclusive) catch false;
            if (!got) {
                lf.close(io);
                return error.AlreadyRunning;
            }
            lock_file = lf;
        }
        errdefer if (lock_file) |lf| lf.close(io);

        const log = dir.createFile(io, log_name, .{ .read = true, .truncate = false }) catch return error.StoreOpenFailed;
        errdefer log.close(io);
        var size = (log.stat(io) catch return error.StoreOpenFailed).size;

        // Heal a torn final line (crash mid-append) so the next record starts on a new line.
        if (size > 0 and exclusive) {
            var last: [1]u8 = undefined;
            _ = log.readPositionalAll(io, &last, size - 1) catch return error.StoreOpenFailed;
            if (last[0] != '\n') {
                log.writePositionalAll(io, "\n", size) catch return error.StoreOpenFailed;
                size += 1;
            }
        }

        const db_path = try std.fmt.allocPrintSentinel(gpa, "{s}/{s}", .{ dir_path, db_name }, 0);
        defer gpa.free(db_path);
        const db = try sqlite.Db.open(db_path, false);
        errdefer db.close();
        try db.exec(
            \\PRAGMA journal_mode=WAL;
            \\PRAGMA synchronous=NORMAL;
            \\PRAGMA cache_size=-2048;
            \\PRAGMA mmap_size=0;
            \\CREATE TABLE IF NOT EXISTS meta(k TEXT PRIMARY KEY, v TEXT NOT NULL) WITHOUT ROWID;
            \\CREATE TABLE IF NOT EXISTS sources(
            \\  name TEXT PRIMARY KEY, etag TEXT, last_modified TEXT, adapter_state TEXT, next_poll INTEGER,
            \\  failures INTEGER NOT NULL DEFAULT 0, last_check INTEGER, last_ok INTEGER, last_error TEXT) WITHOUT ROWID;
            \\CREATE TABLE IF NOT EXISTS read_state(source TEXT NOT NULL, id TEXT NOT NULL, at INTEGER NOT NULL,
            \\  PRIMARY KEY(source,id)) WITHOUT ROWID;
            \\CREATE TABLE IF NOT EXISTS items(
            \\  rowid INTEGER PRIMARY KEY, source TEXT NOT NULL, id TEXT NOT NULL, published INTEGER,
            \\  ingested INTEGER NOT NULL, kind TEXT NOT NULL, title TEXT NOT NULL, url TEXT NOT NULL,
            \\  log_offset INTEGER NOT NULL, UNIQUE(source,id));
            \\CREATE INDEX IF NOT EXISTS items_time ON items(COALESCE(published,ingested) DESC);
            \\CREATE VIRTUAL TABLE IF NOT EXISTS fts USING fts5(title, text, content='', contentless_delete=1, tokenize='trigram');
        );
        const ins_item = try db.prepare("INSERT OR IGNORE INTO items(source,id,published,ingested,kind,title,url,log_offset) VALUES(?1,?2,?3,?4,?5,?6,?7,?8)");
        errdefer ins_item.finalize();
        const ins_fts = try db.prepare("INSERT INTO fts(rowid,title,text) VALUES(?1,?2,?3)");
        errdefer ins_fts.finalize();
        const has_item = try db.prepare("SELECT 1 FROM items WHERE source=?1 AND id=?2");
        errdefer has_item.finalize();

        var s: Store = .{
            .gpa = gpa,
            .io = io,
            .dir = dir,
            .log = log,
            .lock_file = lock_file,
            .log_size = size,
            .db = db,
            .ins_item = ins_item,
            .ins_fts = ins_fts,
            .has_item = has_item,
        };
        if (exclusive) s.catchUp() catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.StoreOpenFailed,
        };
        return s;
    }

    pub fn close(self: *Store) void {
        self.ins_item.finalize();
        self.ins_fts.finalize();
        self.has_item.finalize();
        self.db.close();
        self.log.close(self.io);
        if (self.lock_file) |lf| lf.close(self.io);
        self.dir.close(self.io);
    }

    // ---- meta -----------------------------------------------------------------

    fn getMetaInt(self: *Store, key: []const u8) sqlite.Error!i64 {
        const st = try self.db.prepare("SELECT v FROM meta WHERE k=?1");
        defer st.finalize();
        try st.bindText(1, key);
        if (!try st.step()) return 0;
        return std.fmt.parseInt(i64, st.colText(0) orelse "0", 10) catch 0;
    }

    fn setMetaInt(self: *Store, key: []const u8, v: i64) sqlite.Error!void {
        const st = try self.db.prepare("INSERT INTO meta(k,v) VALUES(?1,?2) ON CONFLICT(k) DO UPDATE SET v=excluded.v");
        defer st.finalize();
        try st.bindText(1, key);
        var buf: [24]u8 = undefined;
        try st.bindText(2, std.fmt.bufPrint(&buf, "{d}", .{v}) catch unreachable);
        _ = try st.step();
    }

    // ---- dedupe ---------------------------------------------------------------

    fn seenImpl(ptr: *anyopaque, source: []const u8, id: []const u8) bool {
        const self: *Store = @ptrCast(@alignCast(ptr));
        defer self.has_item.reset();
        self.has_item.bindText(1, source) catch return false;
        self.has_item.bindText(2, id) catch return false;
        return self.has_item.step() catch false;
    }

    pub fn seen(self: *Store) dedupe.Seen {
        return .{ .ptr = self, .containsFn = seenImpl };
    }

    // ---- ingest ---------------------------------------------------------------

    /// Append unseen items to the log (fsync) then index them. Returns how many were new.
    pub fn ingest(self: *Store, items: []const Item, now: i64) !usize {
        if (self.index_lagging) {
            try self.catchUp();
            self.index_lagging = false;
        }
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();

        var fresh: std.ArrayList(Item) = .empty;
        var offsets: std.ArrayList(u64) = .empty;
        var buf: std.ArrayList(u8) = .empty;
        var batch_ids: std.StringHashMapUnmanaged(void) = .empty;
        for (items) |it| {
            if (seenImpl(self, it.source, it.id)) continue;
            const key = try std.fmt.allocPrint(a, "{s}\x00{s}", .{ it.source, it.id });
            if ((try batch_ids.getOrPut(a, key)).found_existing) continue;
            const line = try std.json.Stringify.valueAlloc(a, Record{
                .t = now,
                .source = it.source,
                .id = it.id,
                .title = it.title,
                .url = it.url,
                .published = it.published,
                .body = it.body,
                .kind = it.kind,
            }, .{});
            // Replay (`rebuild`, crash recovery) skips any line longer than max_line, so a record
            // that size would be visible now and vanish later. Refuse it at ingest instead.
            if (line.len + 1 > max_line) {
                std.log.warn("store: dropping {s}/{s}: serialised record ({d} bytes) exceeds the replay limit", .{ it.source, it.id, line.len });
                continue;
            }
            try offsets.append(a, self.log_size + buf.items.len);
            try fresh.append(a, it);
            try buf.appendSlice(a, line);
            try buf.append(a, '\n');
        }
        if (fresh.items.len == 0) return 0;

        try self.log.writePositionalAll(self.io, buf.items, self.log_size);
        try self.log.sync(self.io);
        self.log_size += buf.items.len;
        // From here the records are durable; if indexing them fails, replay them next time rather
        // than letting the next batch's `indexed_offset` jump past them.
        errdefer self.index_lagging = true;

        try self.db.exec("BEGIN");
        errdefer self.db.exec("ROLLBACK") catch {};
        var inserted: usize = 0;
        for (fresh.items, offsets.items) |it, off| {
            if (try self.indexOne(a, it, now, off)) inserted += 1;
        }
        try self.setMetaInt("indexed_offset", @intCast(self.log_size));
        try self.db.exec("COMMIT");
        return inserted;
    }

    /// Insert one item into `items` + `fts`. Returns false if it was already indexed.
    fn indexOne(self: *Store, a: Allocator, it: Item, ingested: i64, offset: u64) !bool {
        defer self.ins_item.reset();
        try self.ins_item.bindText(1, it.source);
        try self.ins_item.bindText(2, it.id);
        try self.ins_item.bindOptInt(3, it.published);
        try self.ins_item.bindInt(4, ingested);
        try self.ins_item.bindText(5, @tagName(it.kind));
        try self.ins_item.bindText(6, it.title);
        try self.ins_item.bindText(7, it.url);
        try self.ins_item.bindInt(8, @intCast(offset));
        _ = try self.ins_item.step();
        if (self.db.changes() == 0) return false;
        const rowid = lastRowId(self.db);
        defer self.ins_fts.reset();
        try self.ins_fts.bindInt(1, rowid);
        try self.ins_fts.bindText(2, it.title);
        try self.ins_fts.bindText(3, try plainText(a, it.body, fts_text_cap));
        _ = try self.ins_fts.step();
        return true;
    }

    // ---- replay / rebuild -------------------------------------------------------

    /// Index any log content beyond `meta.indexed_offset` (crash recovery / rebuild).
    pub fn catchUp(self: *Store) !void {
        var from: u64 = @intCast(@max(0, try self.getMetaInt("indexed_offset")));
        if (from > self.log_size) {
            // The log was replaced or truncated: the derived rows may name records (and offsets)
            // the authoritative log no longer has. Clear them, as `rebuild` does, then reindex.
            try self.db.exec("BEGIN");
            errdefer self.db.exec("ROLLBACK") catch {};
            try self.db.exec("DELETE FROM items");
            try self.db.exec("INSERT INTO fts(fts) VALUES('delete-all')");
            try self.setMetaInt("indexed_offset", 0);
            try self.db.exec("COMMIT");
            from = 0;
        }
        if (from == self.log_size) return;
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();

        try self.db.exec("BEGIN");
        errdefer self.db.exec("ROLLBACK") catch {};
        var pos = from;
        var chunk: [64 * 1024]u8 = undefined;
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(self.gpa);
        var line_start = from;
        var skipping = false;
        var committed_pos = from;
        var since_commit: usize = 0;
        while (pos < self.log_size) {
            const want: usize = @intCast(@min(chunk.len, self.log_size - pos));
            const n = try self.log.readPositionalAll(self.io, chunk[0..want], pos);
            if (n == 0) break;
            var i: usize = 0;
            while (i < n) {
                const nl = std.mem.indexOfScalarPos(u8, chunk[0..n], i, '\n');
                const end = nl orelse n;
                if (!skipping) {
                    if (line.items.len + (end - i) > max_line) {
                        skipping = true;
                        line.clearRetainingCapacity();
                    } else try line.appendSlice(self.gpa, chunk[i..end]);
                }
                if (nl != null) {
                    if (!skipping and line.items.len > 0) {
                        _ = arena.reset(.retain_capacity);
                        self.replayLine(arena.allocator(), line.items, line_start) catch |e| switch (e) {
                            error.OutOfMemory => return e,
                            else => std.log.warn("log offset {d}: skipping unreadable record ({s})", .{ line_start, @errorName(e) }),
                        };
                        since_commit += 1;
                    }
                    line.clearRetainingCapacity();
                    skipping = false;
                    line_start = pos + end + 1;
                    committed_pos = line_start;
                    if (since_commit >= 500) {
                        try self.setMetaInt("indexed_offset", @intCast(committed_pos));
                        try self.db.exec("COMMIT");
                        try self.db.exec("BEGIN");
                        since_commit = 0;
                    }
                }
                i = end + 1;
            }
            pos += n;
        }
        try self.setMetaInt("indexed_offset", @intCast(committed_pos));
        try self.db.exec("COMMIT");
    }

    fn replayLine(self: *Store, a: Allocator, line: []const u8, offset: u64) !void {
        const rec = try std.json.parseFromSliceLeaky(Record, a, line, .{ .ignore_unknown_fields = true });
        _ = try self.indexOne(a, .{
            .source = rec.source,
            .id = rec.id,
            .title = rec.title,
            .url = rec.url,
            .published = rec.published,
            .body = rec.body,
            .kind = rec.kind,
        }, rec.t, offset);
    }

    /// Drop all derived data (item index and FTS) and rebuild from the log.
    /// Read marks and source state are kept.
    pub fn rebuild(self: *Store) !void {
        try self.db.exec("BEGIN");
        errdefer self.db.exec("ROLLBACK") catch {};
        try self.db.exec("DELETE FROM items");
        try self.db.exec("INSERT INTO fts(fts) VALUES('delete-all')");
        try self.setMetaInt("indexed_offset", 0);
        try self.db.exec("COMMIT");
        try self.catchUp();
        try self.db.exec("INSERT INTO fts(fts) VALUES('optimize')");
    }

    // ---- state ------------------------------------------------------------------

    pub fn getSourceState(self: *Store, a: Allocator, name: []const u8) !SourceState {
        const st = try self.db.prepare("SELECT etag,last_modified,next_poll,failures,last_check,last_ok,last_error,adapter_state FROM sources WHERE name=?1");
        defer st.finalize();
        try st.bindText(1, name);
        if (!try st.step()) return .{};
        return .{
            .etag = if (st.colText(0)) |t| try a.dupe(u8, t) else null,
            .last_modified = if (st.colText(1)) |t| try a.dupe(u8, t) else null,
            .next_poll = st.colOptInt(2),
            .failures = @intCast(@max(0, st.colInt(3))),
            .last_check = st.colOptInt(4),
            .last_ok = st.colOptInt(5),
            .last_error = if (st.colText(6)) |t| try a.dupe(u8, t) else null,
            .adapter_state = if (st.colText(7)) |t| try a.dupe(u8, t) else null,
        };
    }

    pub fn putSourceState(self: *Store, name: []const u8, s: SourceState) !void {
        const st = try self.db.prepare(
            \\INSERT INTO sources(name,etag,last_modified,next_poll,failures,last_check,last_ok,last_error,adapter_state)
            \\VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9)
            \\ON CONFLICT(name) DO UPDATE SET etag=excluded.etag,last_modified=excluded.last_modified,
            \\next_poll=excluded.next_poll,failures=excluded.failures,last_check=excluded.last_check,
            \\last_ok=excluded.last_ok,last_error=excluded.last_error,adapter_state=excluded.adapter_state
        );
        defer st.finalize();
        try st.bindText(1, name);
        try st.bindOptText(2, s.etag);
        try st.bindOptText(3, s.last_modified);
        try st.bindOptInt(4, s.next_poll);
        try st.bindInt(5, s.failures);
        try st.bindOptInt(6, s.last_check);
        try st.bindOptInt(7, s.last_ok);
        try st.bindOptText(8, s.last_error);
        try st.bindOptText(9, s.adapter_state);
        _ = try st.step();
    }

    pub fn setNextPoll(self: *Store, name: []const u8, next_poll: i64) !void {
        const st = try self.db.prepare("INSERT INTO sources(name,next_poll) VALUES(?1,?2) ON CONFLICT(name) DO UPDATE SET next_poll=excluded.next_poll");
        defer st.finalize();
        try st.bindText(1, name);
        try st.bindInt(2, next_poll);
        _ = try st.step();
    }

    pub fn setRead(self: *Store, source: []const u8, id: []const u8, read: bool, now: i64) !void {
        const sql = if (read)
            "INSERT OR REPLACE INTO read_state(source,id,at) VALUES(?1,?2,?3)"
        else
            "DELETE FROM read_state WHERE source=?1 AND id=?2 AND ?3 IS NOT NULL";
        const st = try self.db.prepare(sql);
        defer st.finalize();
        try st.bindText(1, source);
        try st.bindText(2, id);
        try st.bindInt(3, now);
        _ = try st.step();
    }

    pub fn markAllRead(self: *Store, source: ?[]const u8, now: i64) !usize {
        const st = try self.db.prepare(
            "INSERT OR IGNORE INTO read_state(source,id,at) SELECT source,id,?1 FROM items WHERE (?2 IS NULL OR source=?2)",
        );
        defer st.finalize();
        try st.bindInt(1, now);
        try st.bindOptText(2, source);
        _ = try st.step();
        return self.db.changes();
    }

    // ---- queries ------------------------------------------------------------------

    const row_cols = "i.rowid,i.source,i.id,i.title,i.url,i.published,i.ingested,i.kind,(r.at IS NOT NULL)";
    const row_from = " FROM items i LEFT JOIN read_state r ON r.source=i.source AND r.id=i.id ";

    fn collect(a: Allocator, st: sqlite.Stmt) ![]Row {
        var out: std.ArrayList(Row) = .empty;
        while (try st.step()) {
            try out.append(a, .{
                .rowid = st.colInt(0),
                .source = try a.dupe(u8, st.colText(1).?),
                .id = try a.dupe(u8, st.colText(2).?),
                .title = try a.dupe(u8, st.colText(3).?),
                .url = try a.dupe(u8, st.colText(4).?),
                .published = st.colOptInt(5),
                .ingested = st.colInt(6),
                .kind = try a.dupe(u8, st.colText(7).?),
                .read = st.colInt(8) != 0,
            });
        }
        return out.items;
    }

    pub fn list(self: *Store, a: Allocator, o: ListOpts) ![]Row {
        const st = try self.db.prepare("SELECT " ++ row_cols ++ row_from ++
            "WHERE (?1 IS NULL OR i.source=?1) AND (?2=0 OR r.at IS NULL) " ++
            "ORDER BY COALESCE(i.published,i.ingested) DESC, i.rowid DESC LIMIT ?3 OFFSET ?4");
        defer st.finalize();
        try st.bindOptText(1, o.source);
        try st.bindInt(2, @intFromBool(o.unread_only));
        try st.bindInt(3, o.limit);
        try st.bindInt(4, o.offset);
        return collect(a, st);
    }

    /// Substring search (FTS5 trigram, case-insensitive). Queries shorter than 3 characters match nothing.
    pub fn search(self: *Store, a: Allocator, query: []const u8, limit: u32) ![]Row {
        const phrase = try quoteFtsPhrase(a, query);
        const st = try self.db.prepare("SELECT " ++ row_cols ++ " FROM fts f JOIN items i ON i.rowid=f.rowid " ++
            "LEFT JOIN read_state r ON r.source=i.source AND r.id=i.id WHERE fts MATCH ?1 " ++
            "ORDER BY COALESCE(i.published,i.ingested) DESC LIMIT ?2");
        defer st.finalize();
        try st.bindText(1, phrase);
        try st.bindInt(2, limit);
        return collect(a, st);
    }

    pub fn count(self: *Store) !struct { total: i64, unread: i64 } {
        const st = try self.db.prepare("SELECT count(*), sum(r.at IS NULL)" ++ row_from);
        defer st.finalize();
        _ = try st.step();
        return .{ .total = st.colInt(0), .unread = st.colInt(1) };
    }

    /// Fetch the full record (body etc.) for a row from the log.
    pub fn getRecord(self: *Store, a: Allocator, rowid: i64) !?Record {
        const st = try self.db.prepare("SELECT log_offset FROM items WHERE rowid=?1");
        defer st.finalize();
        try st.bindInt(1, rowid);
        if (!try st.step()) return null;
        const off: u64 = @intCast(st.colInt(0));
        // A read-only instance (the web UI) caches the log length at open; the poller's appends
        // show up in SQLite at once. Refresh the length when the index points past what we know.
        if (off >= self.log_size) self.log_size = try self.log.length(self.io);
        var line: std.ArrayList(u8) = .empty;
        var pos = off;
        var chunk: [16 * 1024]u8 = undefined;
        while (pos < self.log_size and line.items.len < max_line) {
            const want: usize = @intCast(@min(chunk.len, self.log_size - pos));
            const n = try self.log.readPositionalAll(self.io, chunk[0..want], pos);
            if (n == 0) break;
            if (std.mem.indexOfScalar(u8, chunk[0..n], '\n')) |nl| {
                try line.appendSlice(a, chunk[0..nl]);
                break;
            }
            try line.appendSlice(a, chunk[0..n]);
            pos += n;
        }
        return try std.json.parseFromSliceLeaky(Record, a, line.items, .{ .ignore_unknown_fields = true });
    }
};

extern fn sqlite3_last_insert_rowid(db: *anyopaque) i64;
fn lastRowId(db: sqlite.Db) i64 {
    return sqlite3_last_insert_rowid(@ptrCast(db.h));
}

/// Quote user text as one FTS5 phrase ("" doubles embedded quotes).
pub fn quoteFtsPhrase(a: Allocator, q: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(a, '"');
    for (q) |c| {
        if (c == '"') try out.append(a, '"');
        try out.append(a, c);
    }
    try out.append(a, '"');
    return out.items;
}

/// Strip HTML tags, collapse whitespace, cap length (at a UTF-8 boundary).
pub fn plainText(a: Allocator, html: []const u8, cap: usize) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var in_tag = false;
    var space = true;
    for (html, 0..) |c, i| {
        if (out.items.len >= cap) break;
        // Only a plausible tag opener starts markup: a bare "<" in decoded text ("2 < 3") is text.
        if (c == '<' and !in_tag and i + 1 < html.len and tagOpener(html[i + 1])) {
            in_tag = true;
            continue;
        }
        if (c == '>' and in_tag) {
            in_tag = false;
            if (!space) {
                try out.append(a, ' ');
                space = true;
            }
            continue;
        }
        if (in_tag) continue;
        if (std.ascii.isWhitespace(c)) {
            if (!space) try out.append(a, ' ');
            space = true;
        } else {
            try out.append(a, c);
            space = false;
        }
    }
    var n = out.items.len;
    // do not leave a truncated multi-byte sequence at the end
    while (n > 0 and !std.unicode.utf8ValidateSlice(out.items[0..n])) n -= 1;
    while (n > 0 and out.items[n - 1] == ' ') n -= 1;
    return out.items[0..n];
}

fn tagOpener(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '/' or c == '!' or c == '?';
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
const testing = std.testing;

fn mkItem(source: []const u8, id: []const u8, title: []const u8, body: []const u8, pub_: ?i64) Item {
    return .{ .source = source, .id = id, .title = title, .url = "http://x/", .published = pub_, .body = body, .kind = .article };
}

fn tmpPath(a: Allocator, tmp: *testing.TmpDir) ![]u8 {
    return tmp.dir.realPathFileAlloc(testing.io, ".", a) catch unreachable;
}

test "plainText strips tags and caps at a code point boundary" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("Hello big world", try plainText(a, "<p>Hello <b>big</b>\n world</p>", 100));
    try testing.expectEqualStrings("2 < 3 and x y<", try plainText(a, "2 < 3 and <b>x</b> y<", 100)); // a bare < is text
    const t = try plainText(a, "ab\u{e9}\u{e9}", 3); // cap lands inside é
    try testing.expect(std.unicode.utf8ValidateSlice(t));
}

test "ingest, dedupe, search (trigram substring), read marks, source state" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmpPath(a, &tmp);

    var s = try Store.open(testing.allocator, testing.io, dir, true);
    defer s.close();
    const items = [_]Item{
        mkItem("a", "1", "Zig 0.17 released", "<p>The <b>allocator</b> story improves</p>", 1000),
        mkItem("a", "2", "Other news", "nothing to see", 2000),
        mkItem("b", "1", "Same id other source", "x", 3000),
        mkItem("a", "1", "dup in batch", "x", 4000),
    };
    try testing.expectEqual(@as(usize, 3), try s.ingest(&items, 5000));
    try testing.expectEqual(@as(usize, 0), try s.ingest(&items, 5001)); // all seen
    try testing.expect(s.seen().contains("a", "2"));
    try testing.expect(!s.seen().contains("a", "9"));

    const rows = try s.list(a, .{});
    try testing.expectEqual(@as(usize, 3), rows.len);
    try testing.expectEqualStrings("Same id other source", rows[0].title); // newest first
    const only_a = try s.list(a, .{ .source = "a" });
    try testing.expectEqual(@as(usize, 2), only_a.len);

    const hit = try s.search(a, "locator", 10); // substring inside "allocator", from stripped body
    try testing.expectEqual(@as(usize, 1), hit.len);
    try testing.expectEqualStrings("Zig 0.17 released", hit[0].title);
    try testing.expectEqual(@as(usize, 1), (try s.search(a, "ZIG 0.17", 10)).len); // case-insensitive
    try testing.expectEqual(@as(usize, 0), (try s.search(a, "<b>", 10)).len); // tags not indexed
    try testing.expectEqual(@as(usize, 0), (try s.search(a, "zi", 10)).len); // < 3 chars: nothing
    _ = try s.search(a, "weird \"quote\" AND OR (", 10); // must not be a syntax error

    try s.setRead("a", "1", true, 6000);
    try testing.expectEqual(@as(usize, 2), (try s.list(a, .{ .unread_only = true })).len);
    const c = try s.count();
    try testing.expectEqual(@as(i64, 3), c.total);
    try testing.expectEqual(@as(i64, 2), c.unread);
    try s.setRead("a", "1", false, 6001);
    try testing.expectEqual(@as(usize, 3), (try s.list(a, .{ .unread_only = true })).len);
    try testing.expectEqual(@as(usize, 3), try s.markAllRead(null, 7000));

    try s.putSourceState("a", .{ .etag = "\"e\"", .last_modified = "lm", .next_poll = 123, .failures = 2, .last_error = "boom" });
    const st = try s.getSourceState(a, "a");
    try testing.expectEqualStrings("\"e\"", st.etag.?);
    try testing.expectEqual(@as(u32, 2), st.failures);
    try testing.expectEqual(@as(?i64, 123), st.next_poll);
    try testing.expect((try s.getSourceState(a, "nope")).etag == null);

    const rec = (try s.getRecord(a, rows[2].rowid)).?;
    try testing.expectEqualStrings("<p>The <b>allocator</b> story improves</p>", rec.body);
}

test "reopen keeps everything; second instance is refused; read-only open works alongside" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmpPath(a, &tmp);
    {
        var s = try Store.open(testing.allocator, testing.io, dir, true);
        defer s.close();
        _ = try s.ingest(&.{mkItem("a", "1", "persisted", "b", 1)}, 10);
        try testing.expectError(error.AlreadyRunning, Store.open(testing.allocator, testing.io, dir, true));
        var ro = try Store.open(testing.allocator, testing.io, dir, false);
        defer ro.close();
        try testing.expectEqual(@as(usize, 1), (try ro.list(a, .{})).len);
        // Appended after the read-only open: listed via SQLite, and the record is readable too
        // (the cached log length must not be trusted past what the index points at).
        _ = try s.ingest(&.{mkItem("a", "2", "appended later", "<p>later body</p>", 2)}, 11);
        const rows = try ro.list(a, .{ .limit = 10 });
        try testing.expectEqual(@as(usize, 2), rows.len);
        for (rows) |r| try testing.expect((try ro.getRecord(a, r.rowid)) != null);
    }
    var s = try Store.open(testing.allocator, testing.io, dir, true);
    defer s.close();
    try testing.expectEqual(@as(usize, 2), (try s.list(a, .{})).len);
}

test "rebuild from the log restores items, FTS and dedupe, and keeps read marks" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmpPath(a, &tmp);
    var s = try Store.open(testing.allocator, testing.io, dir, true);
    defer s.close();
    var batch: [40]Item = undefined;
    for (&batch, 0..) |*it, i| it.* = mkItem("a", try std.fmt.allocPrint(a, "id{d}", .{i}), try std.fmt.allocPrint(a, "title number {d} \u{4e2d}\u{6587}", .{i}), "<p>body text with needle</p>", @intCast(i));
    _ = try s.ingest(&batch, 100);
    try s.setRead("a", "id3", true, 1);
    try s.db.exec("DELETE FROM items; INSERT INTO fts(fts) VALUES('delete-all'); DELETE FROM meta;"); // simulate lost/corrupt derived data
    try testing.expectEqual(@as(usize, 0), (try s.list(a, .{})).len);
    try s.rebuild();
    try testing.expectEqual(@as(usize, 40), (try s.list(a, .{ .limit = 100 })).len);
    try testing.expectEqual(@as(usize, 40), (try s.search(a, "needle", 100)).len);
    try testing.expectEqual(@as(usize, 1), (try s.search(a, "number 17", 100)).len);
    try testing.expectEqual(@as(usize, 40), (try s.search(a, " \u{4e2d}\u{6587}", 100)).len); // trigram: needs >= 3 chars, so include the space
    try testing.expectEqual(@as(usize, 0), (try s.search(a, "\u{4e2d}\u{6587}", 100)).len); // documented limitation: 2 chars
    try testing.expect(s.seen().contains("a", "id39"));
    try testing.expectEqual(@as(usize, 39), (try s.list(a, .{ .unread_only = true, .limit = 100 })).len);
    try testing.expectEqual(@as(usize, 0), try s.ingest(&batch, 200)); // nothing re-added
}

test "crash recovery: log ahead of the index (and a torn last line) heals on open" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmpPath(a, &tmp);
    {
        var s = try Store.open(testing.allocator, testing.io, dir, true);
        defer s.close();
        _ = try s.ingest(&.{mkItem("a", "1", "one", "b", 1)}, 10);
        // Simulate a crash after the log append but before the SQLite commit, then a torn write.
        const rec = try std.json.Stringify.valueAlloc(a, Record{ .t = 11, .source = "a", .id = "2", .title = "two", .url = "u", .published = 2, .body = "b", .kind = .article }, .{});
        const extra = try std.fmt.allocPrint(a, "{s}\n{{\"v\":1,\"t\":12,\"source\":\"a\",\"id\":\"3\",\"ti", .{rec});
        try s.log.writePositionalAll(testing.io, extra, s.log_size);
    }
    var s = try Store.open(testing.allocator, testing.io, dir, true);
    defer s.close();
    const rows = try s.list(a, .{});
    try testing.expectEqual(@as(usize, 2), rows.len); // "one" and replayed "two"; torn record skipped
    // new appends land on a fresh line and are readable
    _ = try s.ingest(&.{mkItem("a", "4", "four", "b", 4)}, 20);
    try testing.expectEqual(@as(usize, 3), (try s.list(a, .{})).len);
    try s.rebuild();
    try testing.expectEqual(@as(usize, 3), (try s.list(a, .{})).len);
}

test "a log replaced by a shorter one clears derived rows before reindexing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmpPath(a, &tmp);
    var first_len: u64 = 0;
    {
        var s = try Store.open(testing.allocator, testing.io, dir, true);
        defer s.close();
        _ = try s.ingest(&.{mkItem("a", "1", "kept", "b", 1)}, 10);
        first_len = s.log_size;
        _ = try s.ingest(&.{mkItem("a", "2", "gone", "needle", 2)}, 11);
        // Restore an older log: only the first record survives.
        try s.log.setLength(testing.io, first_len);
    }
    var s = try Store.open(testing.allocator, testing.io, dir, true);
    defer s.close();
    const rows = try s.list(a, .{ .limit = 10 });
    try testing.expectEqual(@as(usize, 1), rows.len); // "gone" no longer listed
    try testing.expectEqualStrings("kept", rows[0].title);
    try testing.expectEqual(@as(usize, 0), (try s.search(a, "needle", 10)).len); // nor searchable
    try testing.expect((try s.getRecord(a, rows[0].rowid)) != null);
}
