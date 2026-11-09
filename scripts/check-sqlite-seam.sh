#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell
#
# check-sqlite-seam.sh — heron's SQLite C boundary against sqlite3.h
# (PROOF-NEEDS SEAM-1 and SEAM-4).
#
#   check-sqlite-seam.sh header   Compare src/interface/generated/sqlite_c.zig
#                                 with `zig translate-c vendor/sqlite/sqlite3.h`:
#                                 every declared function must exist in the
#                                 header with the same arity and the same ABI
#                                 shape for each parameter and the result
#                                 (32-bit int, 64-bit int, pointer, no value),
#                                 and every constant must have the header's
#                                 value. Needs only zig.
#   check-sqlite-seam.sh regen    Render the file again from
#                                 src/interface/Abi/Sqlite.idr and fail if the
#                                 committed copy differs. Needs idris2; FATAL
#                                 when it is missing, never skipped.
#   check-sqlite-seam.sh all      Both.
#
# Also: no file outside src/interface/generated/ may declare an SQLite
# function, so the generated file stays the only declaration.
#
# Exit: 0 pass; 1 a mismatch (listed); 2 usage or a missing tool.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GEN="$ROOT/src/interface/generated/sqlite_c.zig"
HDR="$ROOT/vendor/sqlite/sqlite3.h"
MODE="${1:-}"

die() { echo "check-sqlite-seam: $*" >&2; exit 2; }
[ -n "$MODE" ] || die "usage: check-sqlite-seam.sh header|regen|all"
[ -f "$GEN" ] || die "missing $GEN"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0

# ABI shape of one Zig type, after any `name:` prefix is removed.
#   W32 c_int, W64 i64 / c_longlong / sqlite3_int64, NoRet void,
#   Ptr anything with a pointer or a function pointer in it,
#   ?<type> anything else, which never matches and so fails the check.
CLASSIFY='
function cls(t) {
  gsub(/^[ \t]+|[ \t]+$/, "", t)
  sub(/^[A-Za-z_][A-Za-z_0-9]*: /, "", t)
  if (t ~ /\*/ || t ~ /fn \(/) return "Ptr"
  if (t == "c_int") return "W32"
  if (t == "i64" || t == "c_longlong" || t == "sqlite3_int64" || t == "sqlite_int64") return "W64"
  if (t == "void") return "NoRet"
  return "?" t
}
# One line per extern: name, comma-separated parameter shapes, result shape.
/^pub extern fn / {
  line = $0
  name = line; sub(/^pub extern fn /, "", name); sub(/\(.*/, "", name)
  rest = line; sub(/^[^(]*\(/, "", rest)
  # The parameter list ends at the parenthesis that balances the opening one.
  depth = 1; args = ""
  for (i = 1; i <= length(rest); i++) {
    ch = substr(rest, i, 1)
    if (ch == "(") depth++
    if (ch == ")") { depth--; if (depth == 0) break }
    args = args ch
  }
  ret = substr(rest, i + 1); sub(/;[ \t]*$/, "", ret)
  out = ""; n = 0; d = 0; cur = ""
  for (j = 1; j <= length(args); j++) {
    ch = substr(args, j, 1)
    if (ch == "(") d++
    if (ch == ")") d--
    if (ch == "," && d == 0) { out = out (n ? "," : "") cls(cur); n++; cur = ""; continue }
    cur = cur ch
  }
  if (cur ~ /[^ \t]/) { out = out (n ? "," : "") cls(cur); n++ }
  print name, (out == "" ? "-" : out), cls(ret)
}'

check_header() {
  command -v zig >/dev/null 2>&1 || die "zig is not on PATH (the header check needs zig translate-c)"
  [ -f "$HDR" ] || die "missing $HDR"
  zig translate-c "$HDR" > "$TMP/hdr.zig" 2> "$TMP/tc.err" \
    || { cat "$TMP/tc.err" >&2; die "zig translate-c failed on $HDR"; }

  awk "$CLASSIFY" "$GEN" | sort > "$TMP/ours"
  [ -s "$TMP/ours" ] || { echo "FAIL: no extern declarations found in $GEN"; fail=1; return; }
  cut -d' ' -f1 "$TMP/ours" > "$TMP/names"
  awk "$CLASSIFY" "$TMP/hdr.zig" | sort | awk 'NR==FNR { want[$1]; next } ($1 in want)' "$TMP/names" - > "$TMP/theirs"

  while read -r name ps r; do
    h="$(awk -v n="$name" '$1 == n { print $2, $3 }' "$TMP/theirs")"
    if [ -z "$h" ]; then
      echo "FAIL: $name is not declared in sqlite3.h"; fail=1
    elif [ "$h" != "$ps $r" ]; then
      echo "FAIL: $name: ours ($ps) -> $r, header (${h% *}) -> ${h##* }"; fail=1
    fi
  done < "$TMP/ours"

  # Constants: integer value in the header (decimal or hex, through
  # @as(c_int, …) or promoteIntLiteral) against ours.
  while read -r name val; do
    hv="$(grep -E "^pub const $name = " "$TMP/hdr.zig" | head -1 | grep -oE '0x[0-9a-fA-F]+|[0-9]+' | tail -1 || true)"
    if [ -z "$hv" ]; then
      echo "FAIL: constant $name is not in sqlite3.h"; fail=1
    elif [ "$((hv))" != "$((val))" ]; then
      echo "FAIL: constant $name: ours $val, header $((hv))"; fail=1
    fi
  done < <(sed -nE 's/^pub const (SQLITE_[A-Z0-9_]+): c_int = (-?[0-9]+);$/\1 \2/p' "$GEN")

  local nf nc
  nf="$(wc -l < "$TMP/ours")"
  nc="$(grep -cE '^pub const SQLITE_' "$GEN" || true)"
  [ "$fail" = 0 ] && echo "PASS: $nf functions and $nc constants in sqlite_c.zig agree with sqlite3.h (zig $(zig version))"

  # The generated file is the only SQLite declaration in the tree.
  local stray
  stray="$(grep -rnE 'extern fn sqlite3_' "$ROOT/src" --include='*.zig' | grep -v '^'"$ROOT"'/src/interface/generated/' || true)"
  if [ -n "$stray" ]; then
    echo "FAIL: SQLite declared outside src/interface/generated/:"
    echo "$stray"
    fail=1
  fi
}

check_regen() {
  command -v idris2 >/dev/null 2>&1 \
    || die "idris2 is not on PATH; the regen check cannot run (not skipped: install idris2 or use 'header')"
  ( cd "$ROOT/src/interface" && idris2 --build abi.ipkg > "$TMP/build.log" 2>&1 ) \
    || { cat "$TMP/build.log" >&2; echo "FAIL: abi.ipkg (with the seamgen executable) does not build"; fail=1; return; }
  "$ROOT/src/interface/build/exec/seamgen" > "$TMP/sqlite_c.zig"
  if diff -u "$GEN" "$TMP/sqlite_c.zig" > "$TMP/drift"; then
    echo "PASS: sqlite_c.zig is exactly what Abi/Sqlite.idr renders ($(idris2 --version))"
  else
    echo "FAIL: sqlite_c.zig differs from a fresh render; run 'just seam-gen':"
    cat "$TMP/drift"
    fail=1
  fi
}

case "$MODE" in
  header) check_header ;;
  regen)  check_regen ;;
  all)    check_header; check_regen ;;
  *)      die "unknown mode '$MODE' (header|regen|all)" ;;
esac
exit "$fail"
