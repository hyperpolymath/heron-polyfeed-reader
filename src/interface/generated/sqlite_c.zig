// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell
// GENERATED from src/interface/Abi/Sqlite.idr by `just seam-gen`. Do not edit:
// change the Idris2 description and regenerate. `just seam-check` fails on drift;
// scripts/check-sqlite-seam.sh compares this file with sqlite3.h.
//! heron's SQLite C boundary: every SQLite function and integer constant it uses.

pub const Handle = opaque {};
pub const StmtHandle = opaque {};

pub const SQLITE_OK: c_int = 0;
pub const SQLITE_ROW: c_int = 100;
pub const SQLITE_DONE: c_int = 101;
pub const SQLITE_NULL: c_int = 5;
pub const SQLITE_OPEN_READONLY: c_int = 1;
pub const SQLITE_OPEN_READWRITE: c_int = 2;
pub const SQLITE_OPEN_CREATE: c_int = 4;
pub const SQLITE_OPEN_NOMUTEX: c_int = 32768;

pub extern fn sqlite3_open_v2(filename: [*:0]const u8, db: *?*Handle, flags: c_int, vfs: ?[*:0]const u8) c_int;
pub extern fn sqlite3_close_v2(db: ?*Handle) c_int;
pub extern fn sqlite3_exec(db: ?*Handle, sql: [*:0]const u8, cb: ?*anyopaque, arg: ?*anyopaque, err: ?*?[*:0]u8) c_int;
pub extern fn sqlite3_free(p: ?*anyopaque) void;
pub extern fn sqlite3_errmsg(db: ?*Handle) [*:0]const u8;
pub extern fn sqlite3_prepare_v2(db: ?*Handle, sql: [*]const u8, n: c_int, stmt: *?*StmtHandle, tail: ?*?[*]const u8) c_int;
pub extern fn sqlite3_finalize(s: ?*StmtHandle) c_int;
pub extern fn sqlite3_reset(s: ?*StmtHandle) c_int;
pub extern fn sqlite3_clear_bindings(s: ?*StmtHandle) c_int;
pub extern fn sqlite3_step(s: ?*StmtHandle) c_int;
pub extern fn sqlite3_bind_text(s: ?*StmtHandle, i: c_int, p: [*]const u8, n: c_int, d: ?*const fn (?*anyopaque) callconv(.c) void) c_int;
pub extern fn sqlite3_bind_int64(s: ?*StmtHandle, i: c_int, v: i64) c_int;
pub extern fn sqlite3_bind_null(s: ?*StmtHandle, i: c_int) c_int;
pub extern fn sqlite3_column_text(s: ?*StmtHandle, i: c_int) ?[*]const u8;
pub extern fn sqlite3_column_bytes(s: ?*StmtHandle, i: c_int) c_int;
pub extern fn sqlite3_column_int64(s: ?*StmtHandle, i: c_int) i64;
pub extern fn sqlite3_column_type(s: ?*StmtHandle, i: c_int) c_int;
pub extern fn sqlite3_changes(db: ?*Handle) c_int;
pub extern fn sqlite3_busy_timeout(db: ?*Handle, ms: c_int) c_int;
pub extern fn sqlite3_last_insert_rowid(db: ?*Handle) i64;
pub extern fn sqlite3_soft_heap_limit64(n: i64) i64;
pub extern fn sqlite3_memory_used() i64;
