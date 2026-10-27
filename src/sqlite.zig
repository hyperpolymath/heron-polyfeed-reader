// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell
//! Minimal SQLite wrapper. The C ABI is declared by hand (no translate-c), so
//! the FFI surface is exactly the functions listed in `extern` below.
const std = @import("std");

const Handle = opaque {};
const StmtHandle = opaque {};

const SQLITE_OK: c_int = 0;
const SQLITE_ROW: c_int = 100;
const SQLITE_DONE: c_int = 101;
const SQLITE_OPEN_READWRITE: c_int = 0x2;
const SQLITE_OPEN_CREATE: c_int = 0x4;
const SQLITE_OPEN_NOMUTEX: c_int = 0x8000;
const SQLITE_OPEN_READONLY: c_int = 0x1;
const SQLITE_TRANSIENT: ?*const fn (?*anyopaque) callconv(.c) void = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));

extern fn sqlite3_open_v2(filename: [*:0]const u8, db: *?*Handle, flags: c_int, vfs: ?[*:0]const u8) c_int;
extern fn sqlite3_close_v2(db: ?*Handle) c_int;
extern fn sqlite3_exec(db: ?*Handle, sql: [*:0]const u8, cb: ?*anyopaque, arg: ?*anyopaque, err: ?*?[*:0]u8) c_int;
extern fn sqlite3_free(p: ?*anyopaque) void;
extern fn sqlite3_errmsg(db: ?*Handle) [*:0]const u8;
extern fn sqlite3_prepare_v2(db: ?*Handle, sql: [*]const u8, n: c_int, stmt: *?*StmtHandle, tail: ?*?[*]const u8) c_int;
extern fn sqlite3_finalize(s: ?*StmtHandle) c_int;
extern fn sqlite3_reset(s: ?*StmtHandle) c_int;
extern fn sqlite3_clear_bindings(s: ?*StmtHandle) c_int;
extern fn sqlite3_step(s: ?*StmtHandle) c_int;
extern fn sqlite3_bind_text(s: ?*StmtHandle, i: c_int, p: [*]const u8, n: c_int, d: ?*const fn (?*anyopaque) callconv(.c) void) c_int;
extern fn sqlite3_bind_int64(s: ?*StmtHandle, i: c_int, v: i64) c_int;
extern fn sqlite3_bind_null(s: ?*StmtHandle, i: c_int) c_int;
extern fn sqlite3_column_text(s: ?*StmtHandle, i: c_int) ?[*]const u8;
extern fn sqlite3_column_bytes(s: ?*StmtHandle, i: c_int) c_int;
extern fn sqlite3_column_int64(s: ?*StmtHandle, i: c_int) i64;
extern fn sqlite3_column_type(s: ?*StmtHandle, i: c_int) c_int;
extern fn sqlite3_changes(db: ?*Handle) c_int;
extern fn sqlite3_busy_timeout(db: ?*Handle, ms: c_int) c_int;
extern fn sqlite3_soft_heap_limit64(n: i64) i64;
extern fn sqlite3_memory_used() i64;

pub const Error = error{ SqliteOpen, SqliteExec, SqlitePrepare, SqliteStep, SqliteBind, OutOfMemory };

pub fn softHeapLimit(bytes: i64) void {
    _ = sqlite3_soft_heap_limit64(bytes);
}
pub fn memoryUsed() i64 {
    return sqlite3_memory_used();
}

pub const Db = struct {
    h: *Handle,

    pub fn open(path: [:0]const u8, readonly: bool) Error!Db {
        var h: ?*Handle = null;
        const flags: c_int = SQLITE_OPEN_NOMUTEX | if (readonly) SQLITE_OPEN_READONLY else (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE);
        if (sqlite3_open_v2(path.ptr, &h, flags, null) != SQLITE_OK) {
            _ = sqlite3_close_v2(h);
            return error.SqliteOpen;
        }
        _ = sqlite3_busy_timeout(h, 5000);
        return .{ .h = h.? };
    }

    pub fn close(self: Db) void {
        _ = sqlite3_close_v2(self.h);
    }

    pub fn exec(self: Db, sql: [:0]const u8) Error!void {
        var err: ?[*:0]u8 = null;
        if (sqlite3_exec(self.h, sql.ptr, null, null, &err) != SQLITE_OK) {
            if (err) |e| {
                std.log.warn("sqlite exec: {s}", .{e});
                sqlite3_free(e);
            }
            return error.SqliteExec;
        }
    }

    pub fn errmsg(self: Db) []const u8 {
        return std.mem.span(sqlite3_errmsg(self.h));
    }

    pub fn changes(self: Db) usize {
        return @intCast(sqlite3_changes(self.h));
    }

    pub fn prepare(self: Db, sql: []const u8) Error!Stmt {
        var s: ?*StmtHandle = null;
        if (sqlite3_prepare_v2(self.h, sql.ptr, @intCast(sql.len), &s, null) != SQLITE_OK) {
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
        _ = sqlite3_finalize(self.h);
    }

    pub fn reset(self: Stmt) void {
        _ = sqlite3_reset(self.h);
        _ = sqlite3_clear_bindings(self.h);
    }

    /// Bind index is 1-based. Strings are copied by SQLite.
    pub fn bindText(self: Stmt, i: usize, s: []const u8) Error!void {
        // A zero-length slice may have an undefined pointer; use a static one.
        const p: [*]const u8 = if (s.len == 0) "" else s.ptr;
        if (sqlite3_bind_text(self.h, @intCast(i), p, @intCast(s.len), SQLITE_TRANSIENT) != SQLITE_OK) return error.SqliteBind;
    }
    pub fn bindInt(self: Stmt, i: usize, v: i64) Error!void {
        if (sqlite3_bind_int64(self.h, @intCast(i), v) != SQLITE_OK) return error.SqliteBind;
    }
    pub fn bindOptText(self: Stmt, i: usize, s: ?[]const u8) Error!void {
        if (s) |t| return self.bindText(i, t);
        if (sqlite3_bind_null(self.h, @intCast(i)) != SQLITE_OK) return error.SqliteBind;
    }
    pub fn bindOptInt(self: Stmt, i: usize, v: ?i64) Error!void {
        if (v) |t| return self.bindInt(i, t);
        if (sqlite3_bind_null(self.h, @intCast(i)) != SQLITE_OK) return error.SqliteBind;
    }

    /// Returns true if a row is available, false when done.
    pub fn step(self: Stmt) Error!bool {
        return switch (sqlite3_step(self.h)) {
            SQLITE_ROW => true,
            SQLITE_DONE => false,
            else => {
                std.log.warn("sqlite step: {s}", .{self.db.errmsg()});
                return error.SqliteStep;
            },
        };
    }

    /// Borrowed from SQLite; valid until the next step/reset. NULL gives null.
    pub fn colText(self: Stmt, i: usize) ?[]const u8 {
        if (sqlite3_column_type(self.h, @intCast(i)) == 5) return null; // SQLITE_NULL
        const p = sqlite3_column_text(self.h, @intCast(i)) orelse return "";
        return p[0..@intCast(sqlite3_column_bytes(self.h, @intCast(i)))];
    }
    pub fn colInt(self: Stmt, i: usize) i64 {
        return sqlite3_column_int64(self.h, @intCast(i));
    }
    pub fn colOptInt(self: Stmt, i: usize) ?i64 {
        if (sqlite3_column_type(self.h, @intCast(i)) == 5) return null;
        return sqlite3_column_int64(self.h, @intCast(i));
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
