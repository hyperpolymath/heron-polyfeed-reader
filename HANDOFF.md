<!-- SPDX-License-Identifier: MPL-2.0 -->
<!-- SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell -->
# Handoff: heron-polyfeed-reader

Lightweight desktop feed-reader + site-monitor daemon in Zig 0.17.0 (Linux first). Binary: `heron`.
State at handoff: milestones M0–M6 complete, 85/85 unit tests pass (host and `Containerfile` test stage),
idle RSS ~8 MB (ReleaseSafe, 24 feeds + 6 monitors + web UI). Nothing has been pushed anywhere.

## First steps for the next agent

1. `git log --oneline` (history is the milestone record). Default branch is `master`; target is `hyperpolymath/heron-polyfeed-reader` `main`.
2. Add the remote and push (or open a PR if the remote already has commits; expect to rebase over any initial README/LICENSE).
3. Add CI (none yet): run the `Containerfile` `test` target; consider a ReleaseSafe build + RSS check.
4. Triage every review-app finding and CI failure/anomaly (CodeRabbit etc.) before merging; say why anything odd happened.

## Build and test

- Needs **Zig 0.17.0 exactly** (std.Io, std.http and TLS APIs changed from 0.15/0.16; do not assume older APIs; check against the installed std).
- `zig build test --summary all`; `zig build -Doptimize=ReleaseSafe`.
- Containerised: `docker|podman build -f Containerfile --target test -t heron-test .`, `--target runtime -t heron .` (scratch image, ~23 MB; toolchain pinned by SHA-256 via `ADD --checksum`).
- SQLite 3.50.4 amalgamation is vendored in `vendor/sqlite` (FTS5, THREADSAFE=2, no load-extension) and built by `zig cc`. `@cImport` no longer exists in 0.17, so FFI is hand-written externs in `src/sqlite.zig`.
- `src/vendor/tls_client.zig` is a patched copy of std's TLS client (`[sfr patch]` markers: `host.sni_only`, `leaf_not_after`) used only to read the leaf certificate expiry. It must be re-synced when Zig is upgraded (see `src/vendor/NOTICE`). The `[sfr patch]` markers are the old project name.

## Layout (src/)

| file | role |
|---|---|
| `item.zig`, `adapter.zig` | Item model; Adapter vtable, Registry, `Cond` (etag, last_modified, opaque `state`), `Outcome` = items / not_modified / failed, `FailureClass`, `parseRetryAfter` |
| `transport.zig`, `http.zig` | Fakeable Transport interface; HTTP(S) impl (Select-based wall-clock timeout, manual redirects, size cap, cert probe) |
| `xml.zig`, `encoding.zig`, `dates.zig`, `feed.zig`, `feed_adapter.zig`, `dedupe.zig` | Tolerant XML DOM (XXE-safe), encoding detection/conversion, tolerant dates, RSS2/Atom/RDF mapping, guid/id then link+date dedupe |
| `scheduler.zig` | Pure logic over an injected Clock + PRNG: intervals, jitter, exp. backoff, Retry-After floor, startup spread, no busy loop; `FakeClock` for tests |
| `store.zig` | NDJSON log (source of truth) + SQLite (mutable state, FTS5 trigram index rebuildable from the log); crash-replay via `meta.indexed_offset`; lock file |
| `monitor.zig`, `robots.zig` | Monitor adapter (transition-only alerts, change hash, TLS expiry, robots.txt RFC 9309) |
| `engine.zig`, `app.zig`, `daemon.zig`, `cli.zig`, `web.zig`, `localserver.zig`, `config.zig`, `util.zig` | Poll orchestration, wiring, daemon loop + signals, CLI, localhost web UI, tiny HTTP server, JSON config |
| `testdata/` | Recorded real feeds (`real/`) and hand-made edge cases (malformed XML, mixed encodings, UTF-16, odd dates) |

## Design decisions made without input (revisit freely)

- JSON config (no YAML); web UI off unless configured; default bind 127.0.0.1:8484; non-loopback bind needs `web.allow_non_loopback`.
- Web UI: Host-header allowlist (DNS rebinding), Origin check on POST, CSP, no JS, http(s)-only links, own SQLite connection.
- Monitor alerts are stored as items of kind `alert`; first success is a silent baseline; DOWN after 2 failures; change alerts rate-limited to 1/h.
- Adapter interface is meant to take NNTP/NNTPS, Gopher, Gemini (TOFU), ActivityPub/AT Protocol without core changes (unproven: no second non-HTTP adapter exists). WebSub deliberately not implemented.
- Binary name `heron`, env `HERON_CONFIG` / `HERON_DATA`, lock `heron.lock`.

## Known gaps / untested

- Never run against live public sites; all HTTP tests use a local fixture server.
- Cert probe verified only against a self-signed cert (not CA-signed, SNI-routed, or TLS1.2-only hosts).
- Web UI exercised via raw HTTP, not a browser; no search pagination.
- Only x86_64 Linux; no soak test; RSS measured over one ~45 s idle window.
- Container `test` stage not re-counted after the final rename (host run was 85/85).
- Not yet applied from Jonathan's standing preferences: Idris2 for APIs (there are none beyond the local web UI), the unified-hexadeca-api / estate Zig API conventions, DoQ/DoH + DNSSEC resolution for fetches (see his `zig-dnssec` / `zig-boringtls` repos), SDP/firewall gating, VeriSim/LMDB storage choices, and any use of his type work (echo/tropical/choreographic) or januskey/mma-framework for security. Worth a deliberate pass.

## Conventions to keep

- SPDX headers on every source file: `SPDX-License-Identifier: MPL-2.0`, `SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell`.
- No Python in the repo. FFI in hand-written Zig externs. Containerise build/tests by default.
- Commit at each milestone. Do not push or open PRs unless asked.
- Commit trailers used so far:
  `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>` and `Claude-Session: https://claude.ai/code/session_018RAZ2eXR5QXneYQV8Pds98` (use your own session's trailers going forward).

## Suggested next work

1. Push, CI, review-app triage, merge.
2. Second adapter (NNTP or Gemini) to prove the adapter seam; then ActivityPub/AT.
3. Live-site soak test and a real-CA cert-probe check.
4. A `monitors`-style summary in the web UI index; search pagination.
5. Decide the estate-integration items under "Known gaps".
