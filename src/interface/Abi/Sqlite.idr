-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
||| heron's SQLite C boundary, written once (PROOF-NEEDS SEAM-4).
|||
||| `seam` lists every SQLite function heron calls and `consts` every integer
||| constant it uses. From these one source:
|||
|||   * `SeamGen` renders `src/interface/generated/sqlite_c.zig`, the only place
|||     heron declares SQLite (`just seam-check` fails if the committed file
|||     differs from a fresh render);
|||   * `seamAgreesWithHeader` below proves, by evaluation in the type checker,
|||     that each declaration's ABI shape matches `header`, a table of
|||     `vendor/sqlite/sqlite3.h` (SQLite 3.50.4);
|||   * `scripts/check-sqlite-seam.sh` compares the rendered Zig with
|||     `zig translate-c` of the header itself, so the table is not trusted
|||     on its own.
|||
||| What is proved is ABI shape (arity, and for each parameter and result
||| whether it is a 32-bit int, a 64-bit int, a pointer, or no value), not
||| SQLite's behaviour, which stays ASSUMED (PROOF-POLICY section 1.1).
module Abi.Sqlite

import Data.List
import Data.String

%default total

||| The Zig type forms the boundary uses.
public export
data ZTy = CInt | I64 | Void | U8
         | Named String       -- an opaque type, only ever behind a pointer
         | Opt ZTy            -- ?T
         | One Bool ZTy       -- *T, or *const T when the flag is set
         | Many Bool ZTy      -- [*]T / [*]const T
         | ManyZ Bool ZTy     -- [*:0]T / [*:0]const T
         | Destructor         -- SQLite's destructor callback pointer

public export
render : ZTy -> String
render CInt = "c_int"
render I64 = "i64"
render Void = "void"
render U8 = "u8"
render (Named n) = n
render (Opt t) = "?" ++ render t
render (One c t) = "*" ++ (if c then "const " else "") ++ render t
render (Many c t) = "[*]" ++ (if c then "const " else "") ++ render t
render (ManyZ c t) = "[*:0]" ++ (if c then "const " else "") ++ render t
render Destructor = "?*const fn (?*anyopaque) callconv(.c) void"

public export
record Fn where
  constructor MkFn
  name   : String
  params : List (String, ZTy)
  ret    : ZTy

handle, stmt, cstr, anyPtr : ZTy
handle = Opt (One False (Named "Handle"))
stmt = Opt (One False (Named "StmtHandle"))
cstr = ManyZ True U8
anyPtr = Opt (One False (Named "anyopaque"))

||| Every SQLite function heron calls.
public export
seam : List Fn
seam =
  [ MkFn "sqlite3_open_v2" [("filename", cstr), ("db", One False handle), ("flags", CInt), ("vfs", Opt cstr)] CInt
  , MkFn "sqlite3_close_v2" [("db", handle)] CInt
  , MkFn "sqlite3_exec" [("db", handle), ("sql", cstr), ("cb", anyPtr), ("arg", anyPtr), ("err", Opt (One False (Opt (ManyZ False U8))))] CInt
  , MkFn "sqlite3_free" [("p", anyPtr)] Void
  , MkFn "sqlite3_errmsg" [("db", handle)] cstr
  , MkFn "sqlite3_prepare_v2" [("db", handle), ("sql", Many True U8), ("n", CInt), ("stmt", One False stmt), ("tail", Opt (One False (Opt (Many True U8))))] CInt
  , MkFn "sqlite3_finalize" [("s", stmt)] CInt
  , MkFn "sqlite3_reset" [("s", stmt)] CInt
  , MkFn "sqlite3_clear_bindings" [("s", stmt)] CInt
  , MkFn "sqlite3_step" [("s", stmt)] CInt
  , MkFn "sqlite3_bind_text" [("s", stmt), ("i", CInt), ("p", Many True U8), ("n", CInt), ("d", Destructor)] CInt
  , MkFn "sqlite3_bind_int64" [("s", stmt), ("i", CInt), ("v", I64)] CInt
  , MkFn "sqlite3_bind_null" [("s", stmt), ("i", CInt)] CInt
  , MkFn "sqlite3_column_text" [("s", stmt), ("i", CInt)] (Opt (Many True U8))
  , MkFn "sqlite3_column_bytes" [("s", stmt), ("i", CInt)] CInt
  , MkFn "sqlite3_column_int64" [("s", stmt), ("i", CInt)] I64
  , MkFn "sqlite3_column_type" [("s", stmt), ("i", CInt)] CInt
  , MkFn "sqlite3_changes" [("db", handle)] CInt
  , MkFn "sqlite3_busy_timeout" [("db", handle), ("ms", CInt)] CInt
  , MkFn "sqlite3_last_insert_rowid" [("db", handle)] I64
  , MkFn "sqlite3_soft_heap_limit64" [("n", I64)] I64
  , MkFn "sqlite3_memory_used" [] I64
  ]

||| Every integer constant heron uses. (`SQLITE_TRANSIENT` is a pointer
||| sentinel, not an integer, and stays in `src/sqlite.zig`.)
public export
consts : List (String, Integer)
consts =
  [ ("SQLITE_OK", 0)
  , ("SQLITE_ROW", 100)
  , ("SQLITE_DONE", 101)
  , ("SQLITE_NULL", 5)
  , ("SQLITE_OPEN_READONLY", 1)
  , ("SQLITE_OPEN_READWRITE", 2)
  , ("SQLITE_OPEN_CREATE", 4)
  , ("SQLITE_OPEN_NOMUTEX", 32768)
  ]

--------------------------------------------------------------------------------
-- ABI shape and the agreement proof
--------------------------------------------------------------------------------

||| What the C calling convention sees. `W8` exists so that a byte passed by
||| value cannot be mistaken for anything the header declares: no SQLite
||| function heron calls takes or returns one.
public export
data Cls = W8 | W32 | W64 | Ptr | NoRet

public export
Eq Cls where
  W8 == W8 = True
  W32 == W32 = True
  W64 == W64 = True
  Ptr == Ptr = True
  NoRet == NoRet = True
  _ == _ = False

public export
cls : ZTy -> Cls
cls CInt = W32
cls I64 = W64
cls Void = NoRet
cls U8 = W8
cls (Named _) = Ptr
cls (Opt t) = cls t
cls (One _ _) = Ptr
cls (Many _ _) = Ptr
cls (ManyZ _ _) = Ptr
cls Destructor = Ptr

||| `sqlite3.h` (3.50.4) as ABI shapes: name, parameter shapes, result shape.
||| `scripts/check-sqlite-seam.sh` checks the rendered Zig against the header
||| directly, so a transcription error here cannot pass on its own.
public export
header : List (String, List Cls, Cls)
header =
  [ ("sqlite3_open_v2", [Ptr, Ptr, W32, Ptr], W32)
  , ("sqlite3_close_v2", [Ptr], W32)
  , ("sqlite3_exec", [Ptr, Ptr, Ptr, Ptr, Ptr], W32)
  , ("sqlite3_free", [Ptr], NoRet)
  , ("sqlite3_errmsg", [Ptr], Ptr)
  , ("sqlite3_prepare_v2", [Ptr, Ptr, W32, Ptr, Ptr], W32)
  , ("sqlite3_finalize", [Ptr], W32)
  , ("sqlite3_reset", [Ptr], W32)
  , ("sqlite3_clear_bindings", [Ptr], W32)
  , ("sqlite3_step", [Ptr], W32)
  , ("sqlite3_bind_text", [Ptr, W32, Ptr, W32, Ptr], W32)
  , ("sqlite3_bind_int64", [Ptr, W32, W64], W32)
  , ("sqlite3_bind_null", [Ptr, W32], W32)
  , ("sqlite3_column_text", [Ptr, W32], Ptr)
  , ("sqlite3_column_bytes", [Ptr, W32], W32)
  , ("sqlite3_column_int64", [Ptr, W32], W64)
  , ("sqlite3_column_type", [Ptr, W32], W32)
  , ("sqlite3_changes", [Ptr], W32)
  , ("sqlite3_busy_timeout", [Ptr, W32], W32)
  , ("sqlite3_last_insert_rowid", [Ptr], W64)
  , ("sqlite3_soft_heap_limit64", [W64], W64)
  , ("sqlite3_memory_used", [], W64)
  ]

public export
shape : Fn -> (String, List Cls, Cls)
shape f = (f.name, map (cls . snd) f.params, cls f.ret)

public export
agreeOne : Fn -> (String, List Cls, Cls) -> Bool
agreeOne f (n, ps, r) = let (m, qs, s) = shape f in m == n && qs == ps && s == r

public export
agrees : List Fn -> List (String, List Cls, Cls) -> Bool
agrees [] [] = True
agrees (f :: fs) (h :: hs) = agreeOne f h && agrees fs hs
agrees _ _ = False

||| Each function heron declares has the ABI shape the header gives it, in the
||| same order, with nothing missing or extra on either side.
export
seamAgreesWithHeader : agrees Abi.Sqlite.seam Abi.Sqlite.header = True
seamAgreesWithHeader = Refl

--------------------------------------------------------------------------------
-- Rendering
--------------------------------------------------------------------------------

public export
emitFn : Fn -> String
emitFn f = "pub extern fn " ++ f.name ++ "("
        ++ joinBy ", " (map (\(n, t) => n ++ ": " ++ render t) f.params)
        ++ ") " ++ render f.ret ++ ";"

public export
emitConst : (String, Integer) -> String
emitConst (n, v) = "pub const " ++ n ++ ": c_int = " ++ show v ++ ";"

||| The whole of `src/interface/generated/sqlite_c.zig`.
public export
zigFile : List String
zigFile =
  [ "// SPDX-License-Identifier: MPL-2.0"
  , "// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell"
  , "// GENERATED from src/interface/Abi/Sqlite.idr by `just seam-gen`. Do not edit:"
  , "// change the Idris2 description and regenerate. `just seam-check` fails on drift;"
  , "// scripts/check-sqlite-seam.sh compares this file with sqlite3.h."
  , "//! heron's SQLite C boundary: every SQLite function and integer constant it uses."
  , ""
  , "pub const Handle = opaque {};"
  , "pub const StmtHandle = opaque {};"
  , ""
  ] ++ map emitConst consts ++ [""] ++ map emitFn seam
