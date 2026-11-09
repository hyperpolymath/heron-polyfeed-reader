// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell
//! Minimal SQLite wrapper. Every SQLite function and integer constant comes
//! from interface/generated/sqlite_c.zig, rendered from the Idris2 description
//! in src/interface/Abi/Sqlite.idr (PROOF-NEEDS SEAM-4). Nothing here declares
//! the C ABI by hand.
const std = @import("std");
const c = @import("interface/generated/sqlite_c.zig");

const Handle = c.Handle;
const StmtHandle = c.StmtHandle;

/// A pointer sentinel, not an integer, so it is not part of the generated file:
/// SQLite copies the bound text before the call returns.
const SQLITE_TRANSIENT: ?*const fn (?*anyopaque) callconv(.c) void = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));

pub const Error = error{ SqliteOpen, SqliteExec, SqlitePrepare, SqliteStep, SqliteBind, OutOfMemory };

pub fn softHeapLimit(bytes: i64) void {
    _ = c.sqlite3_soft_heap_limit64(bytes);
}
pub fn memoryUsed() i64 {
    return c.sqlite3_memory_used();
}

pub const Db = struct {
    h: *Handle,

    pub fn open(path: [:0]const u8, readonly: bool) Error!Db {
        var h: ?*Handle = null;
        const flags: c_int = c.SQLITE_OPEN_NOMUTEX | if (readonly) c.SQLITE_OPEN_READONLY else (c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE);
        if (c.sqlite3_open_v2(path.ptr, &h, flags, null) != c.SQLITE_OK) {
            _ = c.sqlite3_close_v2(h);
            return error.SqliteOpen;
        }
        _ = c.sqlite3_busy_timeout(h, 5000);
        return .{ .h = h.? };
    }

    pub fn close(self: Db) void {
        _ = c.sqlite3_close_v2(self.h);
    }

    pub fn exec(self: Db, sql: [:0]const u8) Error!void {
        var err: ?[*:0]u8 = null;
        if (c.sqlite3_exec(self.h, sql.ptr, null, null, &err) != c.SQLITE_OK) {
            if (err) |e| {
                std.log.warn("sqlite exec: {s}", .{e});
                c.sqlite3_free(e);
            }
            return error.SqliteExec;
        }
    }

    pub fn errmsg(self: Db) []const u8 {
        return std.mem.span(c.sqlite3_errmsg(self.h));
    }

    pub fn lastInsertRowid(self: Db) i64 {
        return c.sqlite3_last_insert_rowid(self.h);
    }

    pub fn changes(self: Db) usize {
        return @intCast(c.sqlite3_changes(self.h));
    }

    pub fn prepare(self: Db, sql: []const u8) Error!Stmt {
        var s: ?*StmtHandle = null;
        if (c.sqlite3_prepare_v2(self.h, sql.ptr, @intCast(sql.len), &s, null) != c.SQLITE_OK) {
            std.log.warn("sqlite prepare: {s}", .{self.errmsg()});
            return error.SqlitePrepare;
        }
        return .{ .h = s.?, .db = self };
    }
};

pub const Stmt = struct {
    h: *StmtHandle,
    db: Db,

    pub fn finalize(self: Stmt) void {
        _ = c.sqlite3_finalize(self.h);
    }

    pub fn reset(self: Stmt) void {
        _ = c.sqlite3_reset(self.h);
        _ = c.sqlite3_clear_bindings(self.h);
    }

    /// Bind index is 1-based. Strings are copied by SQLite.
    pub fn bindText(self: Stmt, i: usize, s: []const u8) Error!void {
        // A zero-length slice may have an undefined pointer; use a static one.
        const p: [*]const u8 = if (s.len == 0) "" else s.ptr;
        if (c.sqlite3_bind_text(self.h, @intCast(i), p, @intCast(s.len), SQLITE_TRANSIENT) != c.SQLITE_OK) return error.SqliteBind;
    }
    pub fn bindInt(self: Stmt, i: usize, v: i64) Error!void {
        if (c.sqlite3_bind_int64(self.h, @intCast(i), v) != c.SQLITE_OK) return error.SqliteBind;
    }
    pub fn bindOptText(self: Stmt, i: usize, s: ?[]const u8) Error!void {
        if (s) |t| return self.bindText(i, t);
        if (c.sqlite3_bind_null(self.h, @intCast(i)) != c.SQLITE_OK) return error.SqliteBind;
    }
    pub fn bindOptInt(self: Stmt, i: usize, v: ?i64) Error!void {
        if (v) |t| return self.bindInt(i, t);
        if (c.sqlite3_bind_null(self.h, @intCast(i)) != c.SQLITE_OK) return error.SqliteBind;
    }

    /// Returns true if a row is available, false when done.
    pub fn step(self: Stmt) Error!bool {
        return switch (c.sqlite3_step(self.h)) {
            c.SQLITE_ROW => true,
            c.SQLITE_DONE => false,
            else => {
                std.log.warn("sqlite step: {s}", .{self.db.errmsg()});
                return error.SqliteStep;
            },
        };
    }

    /// Borrowed from SQLite; valid until the next step/reset. NULL gives null.
    pub fn colText(self: Stmt, i: usize) ?[]const u8 {
        if (c.sqlite3_column_type(self.h, @intCast(i)) == c.SQLITE_NULL) return null;
        const p = c.sqlite3_column_text(self.h, @intCast(i)) orelse return "";
        return p[0..@intCast(c.sqlite3_column_bytes(self.h, @intCast(i)))];
    }
    pub fn colInt(self: Stmt, i: usize) i64 {
        return c.sqlite3_column_int64(self.h, @intCast(i));
    }
    pub fn colOptInt(self: Stmt, i: usize) ?i64 {
        if (c.sqlite3_column_type(self.h, @intCast(i)) == c.SQLITE_NULL) return null;
        return c.sqlite3_column_int64(self.h, @intCast(i));
    }
};

test "sqlite links; fts5 trigram works" {
    const db = try Db.open(":memory:", false);
    defer db.close();
    try db.exec("CREATE VIRTUAL TABLE t USING fts5(x, tokenize='trigram')");
    try db.exec("INSERT INTO t(x) VALUES ('hello brave world'), ('nothing')");
    const s = try db.prepare("SELECT x FROM t WHERE t MATCH ?1");
    defer s.finalize();
    try s.bindText(1, "rave");
    try std.testing.expect(try s.step());
    try std.testing.expectEqualStrings("hello brave world", s.colText(0).?);
    try std.testing.expect(!(try s.step()));
}
