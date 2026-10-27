// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell
//! Command-line interface.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const app_mod = @import("app.zig");
const config = @import("config.zig");
const store_mod = @import("store.zig");
const engine_mod = @import("engine.zig");
const daemon = @import("daemon.zig");
const util = @import("util.zig");
const monitor_mod = @import("monitor.zig");

const usage =
    \\heron-polyfeed-reader — a small local feed reader and site monitor
    \\
    \\usage: heron [--config FILE] [--data DIR] <command> [args]
    \\
    \\  daemon                    run in the foreground: poll sources, serve the web UI if enabled
    \\  fetch [NAME...]           poll the named sources (default: all) once, now
    \\  list [--source NAME] [--unread] [--limit N]
    \\  search TEXT               substring search over titles and text (needs 3+ characters)
    \\  show ID                   print an item and mark it read
    \\  read ID | unread ID       change an item's read state
    \\  mark-all-read [NAME]
    \\  sources                   per-source status: last check, failures, next poll
    \\  monitors                  monitor status: up/down, HTTP status, TLS certificate expiry
    \\  rebuild                   rebuild the index and search tables from the log
    \\  check-config              validate the config file
    \\  help
    \\
;

pub fn main(init: std.process.Init) u8 {
    return run(init) catch |e| {
        std.log.err("{s}", .{@errorName(e)});
        return 1;
    };
}

fn run(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    var out_buf: [4096]u8 = undefined;
    var out_w = Io.File.stdout().writer(io, &out_buf);
    const out = &out_w.interface;
    defer out.flush() catch {};

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const argv = try init.minimal.args.toSlice(arena);
    var ov: app_mod.Overrides = .{};
    var pos: std.ArrayList([]const u8) = .empty;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--config") and i + 1 < argv.len) {
            i += 1;
            ov.config_path = argv[i];
        } else if (std.mem.eql(u8, a, "--data") and i + 1 < argv.len) {
            i += 1;
            ov.data_dir = argv[i];
        } else try pos.append(arena, a);
    }
    if (pos.items.len == 0 or std.mem.eql(u8, pos.items[0], "help") or std.mem.eql(u8, pos.items[0], "--help")) {
        try out.writeAll(usage);
        return if (pos.items.len == 0) 2 else 0;
    }
    const cmd = pos.items[0];
    const args = pos.items[1..];

    // The daemon lowers its priority before any thread exists (Linux nice is per-thread).
    if (std.mem.eql(u8, cmd, "daemon")) daemon.lowerPriority();

    var diag: config.Diagnostic = .{};
    var app = app_mod.App.load(gpa, io, init.environ_map, ov, &diag) catch |e| {
        try out.flush();
        std.log.err("{s}{s}{s}", .{ @errorName(e), if (diag.message.len > 0) ": " else "", diag.message });
        return 1;
    };
    defer app.deinit();
    try app.setup();

    if (std.mem.eql(u8, cmd, "check-config")) {
        try out.print("ok: {d} source(s), {d} monitor(s); data dir {s}\n", .{ app.cfg.sources.len, app.cfg.monitors.len, app.data_dir });
        return 0;
    }

    const exclusive = for ([_][]const u8{ "daemon", "fetch", "rebuild", "read", "unread", "mark-all-read", "show" }) |c| {
        if (std.mem.eql(u8, cmd, c)) break !std.mem.eql(u8, cmd, "show") and !std.mem.eql(u8, cmd, "read") and !std.mem.eql(u8, cmd, "unread") and !std.mem.eql(u8, cmd, "mark-all-read");
    } else false;
    var store = store_mod.Store.open(gpa, io, app.data_dir, exclusive) catch |e| switch (e) {
        error.AlreadyRunning => {
            try out.flush();
            std.log.err("another heron process (probably the daemon) is using {s}; this command needs the data lock", .{app.data_dir});
            return 1;
        },
        else => return e,
    };
    defer store.close();

    const now = Io.Timestamp.now(io, .real).toSeconds();
    if (std.mem.eql(u8, cmd, "daemon")) {
        try out.flush();
        try daemon.run(&app, &store);
        return 0;
    } else if (std.mem.eql(u8, cmd, "fetch")) {
        return cmdFetch(&app, &store, out, args, now);
    } else if (std.mem.eql(u8, cmd, "list")) {
        var o: store_mod.ListOpts = .{};
        var j: usize = 0;
        while (j < args.len) : (j += 1) {
            if (std.mem.eql(u8, args[j], "--unread")) o.unread_only = true else if (std.mem.eql(u8, args[j], "--source") and j + 1 < args.len) {
                j += 1;
                o.source = args[j];
            } else if (std.mem.eql(u8, args[j], "--limit") and j + 1 < args.len) {
                j += 1;
                o.limit = std.fmt.parseInt(u32, args[j], 10) catch return usageErr(out);
            } else return usageErr(out);
        }
        try printRows(out, try store.list(arena, o));
        return 0;
    } else if (std.mem.eql(u8, cmd, "search")) {
        if (args.len != 1) return usageErr(out);
        if (std.unicode.utf8CountCodepoints(args[0]) catch 0 < 3) {
            try out.writeAll("search needs at least 3 characters (trigram index)\n");
            return 2;
        }
        try printRows(out, try store.search(arena, args[0], 50));
        return 0;
    } else if (std.mem.eql(u8, cmd, "show") or std.mem.eql(u8, cmd, "read") or std.mem.eql(u8, cmd, "unread")) {
        if (args.len != 1) return usageErr(out);
        const id = std.fmt.parseInt(i64, args[0], 10) catch return usageErr(out);
        const rec = (try store.getRecord(arena, id)) orelse {
            try out.print("no item {d}\n", .{id});
            return 1;
        };
        if (std.mem.eql(u8, cmd, "show")) {
            var db: [32]u8 = undefined;
            try out.print("{s}\n{s}\n[{s}] {s}  ({s})\n\n{s}\n", .{
                rec.title,          rec.url,
                rec.source,         if (rec.published) |p| util.fmtDate(&db, p) else "undated",
                @tagName(rec.kind), try store_mod.plainText(arena, rec.body, 64 * 1024),
            });
        }
        try store.setRead(rec.source, rec.id, !std.mem.eql(u8, cmd, "unread"), now);
        return 0;
    } else if (std.mem.eql(u8, cmd, "mark-all-read")) {
        const n = try store.markAllRead(if (args.len > 0) args[0] else null, now);
        try out.print("{d} item(s) marked read\n", .{n});
        return 0;
    } else if (std.mem.eql(u8, cmd, "sources")) {
        return cmdSources(&app, &store, out, arena, now);
    } else if (std.mem.eql(u8, cmd, "monitors")) {
        return cmdMonitors(&app, &store, out, arena, now);
    } else if (std.mem.eql(u8, cmd, "rebuild")) {
        try store.rebuild();
        const c = try store.count();
        try out.print("rebuilt: {d} item(s), {d} unread\n", .{ c.total, c.unread });
        return 0;
    }
    return usageErr(out);
}

fn usageErr(out: *Io.Writer) !u8 {
    try out.writeAll(usage);
    return 2;
}

fn printRows(out: *Io.Writer, rows: []const store_mod.Row) !void {
    for (rows) |r| {
        var db: [32]u8 = undefined;
        const when = if (r.published) |p| util.fmtDate(&db, p) else "                ";
        try out.print("{d:>6} {s} {s} [{s}] {s}\n", .{ @as(u64, @intCast(r.rowid)), if (r.read) " " else "*", when, r.source, r.title });
    }
    if (rows.len == 0) try out.writeAll("(nothing)\n");
}

fn cmdFetch(app: *app_mod.App, store: *store_mod.Store, out: *Io.Writer, names: []const []const u8, now: i64) !u8 {
    var eng: engine_mod.Engine = .{ .gpa = app.gpa, .store = store, .registry = &app.registry, .transport = app.transport() };
    // A misspelled or removed name must not look like a successful poll of nothing.
    for (names) |n| {
        var known = false;
        for (app.jobs) |job| if (std.mem.eql(u8, n, job.name)) {
            known = true;
        };
        if (!known) {
            try out.print("fetch: no source or monitor named '{s}' (see: heron sources)\n", .{n});
            return 2;
        }
    }
    var failures: u8 = 0;
    for (app.jobs) |job| {
        if (names.len > 0) {
            var want = false;
            for (names) |n| if (std.mem.eql(u8, n, job.name)) {
                want = true;
            };
            if (!want) continue;
        }
        const res = eng.poll(job, now);
        if (res.ok) {
            try out.print("{s}: {s}, {d} new\n", .{ job.name, if (res.unchanged) "unchanged" else "ok", res.new_items });
        } else {
            failures += 1;
            try out.print("{s}: FAILED {s}: {s}\n", .{ job.name, @tagName(res.class.?), res.messageSlice() });
        }
        try out.flush();
    }
    return if (failures > 0) 1 else 0;
}

fn cmdSources(app: *app_mod.App, store: *store_mod.Store, out: *Io.Writer, arena: Allocator, now: i64) !u8 {
    try out.print("{s:<20} {s:<8} {s:>9} {s:>6} {s:>9}  {s}\n", .{ "name", "type", "last ok", "fails", "next", "last error" });
    for (app.jobs) |job| {
        const st = try store.getSourceState(arena, job.name);
        var b1: [16]u8 = undefined;
        var b2: [16]u8 = undefined;
        const ok_ago = if (st.last_ok) |t| util.fmtSpan(&b1, now - t) else "never";
        const next = if (st.next_poll) |t| (if (t <= now) "due" else util.fmtSpan(&b2, t - now)) else "-";
        try out.print("{s:<20} {s:<8} {s:>9} {d:>6} {s:>9}  {s}\n", .{ job.name, job.type_name, ok_ago, st.failures, next, st.last_error orelse "" });
    }
    return 0;
}

fn cmdMonitors(app: *app_mod.App, store: *store_mod.Store, out: *Io.Writer, arena: Allocator, now: i64) !u8 {
    try out.print("{s:<20} {s:<8} {s:>9} {s:>6} {s:>10}  {s}\n", .{ "name", "state", "since", "http", "cert", "note" });
    for (app.jobs) |job| {
        if (!std.mem.eql(u8, job.type_name, "monitor")) continue;
        const st = try store.getSourceState(arena, job.name);
        const ms = monitor_mod.parseState(arena, st.adapter_state);
        var b1: [16]u8 = undefined;
        var b2: [16]u8 = undefined;
        var b3: [16]u8 = undefined;
        const state: []const u8 = if (ms.blocked) "blocked" else if (ms.up) |u| (if (u) "up" else "DOWN") else "unknown";
        const since = if (ms.since > 0) util.fmtSpan(&b1, now - ms.since) else "-";
        const http_s = if (ms.status > 0) try std.fmt.bufPrint(&b2, "{d}", .{ms.status}) else "-";
        const cert = if (ms.cert_not_after > 0)
            (if (ms.cert_not_after <= now) "EXPIRED" else util.fmtSpan(&b3, ms.cert_not_after - now))
        else
            "-";
        try out.print("{s:<20} {s:<8} {s:>9} {s:>6} {s:>10}  {s}\n", .{ job.name, state, since, http_s, cert, ms.err });
    }
    return 0;
}
