-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
||| Prints `src/interface/generated/sqlite_c.zig` from `Abi.Sqlite`.
||| Built by `idris2 --build abi.ipkg`; run through `just seam-gen` (write) or
||| `just seam-check` (compare).
module SeamGen

import Abi.Sqlite

%default total

main : IO ()
main = traverse_ putStrLn zigFile
