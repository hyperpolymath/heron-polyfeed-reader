// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell
//! The background daemon: scheduler loop + (optionally) the local web UI.
const std = @import("std");
const Io = std.Io;
const app_mod = @import("app.zig");
const engine_mod = @import("engine.zig");
const scheduler = @import("scheduler.zig");
const store_mod = @import("store.zig");
const util = @import("util.zig");

extern fn setpriority(which: c_int, who: c_uint, prio: c_int) c_int;

/// Lower this process's CPU priority. On Linux nice values are per-thread and inherited by threads
/// created afterwards, so call this before any worker threads exist.
pub fn lowerPriority() void {
    if (setpriority(0, 0, 19) != 0) std.log.warn("could not lower process priority", .{});
}

var g_stop: Io.Event = .unset;
var g_io: ?Io = null;

fn onSignal(_: std.posix.SIG) callconv(.c) void {
    if (g_io) |io| g_stop.set(io);
}

pub fn installSignalHandlers(io: Io) void {
    g_io = io;
    const act: std.posix.Sigaction = .{
        .handler = .{ .handler = onSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.INT, &act, null);
    std.posix.sigaction(.TERM, &act, null);
}

const MonoClock = struct {
    io: Io,
    fn now(p: *anyopaque) i64 {
        const self: *MonoClock = @ptrCast(@alignCast(p));
        return Io.Timestamp.now(self.io, .boot).toMilliseconds();
    }
    fn clock(self: *MonoClock) scheduler.Clock {
        return .{ .ptr = self, .nowMsFn = now };
    }
};

fn wallNow(io: Io) i64 {
    return Io.Timestamp.now(io, .real).toSeconds();
}

pub fn run(app: *app_mod.App, store: *store_mod.Store) !void {
    const io = app.io;
    installSignalHandlers(io);

    var mono: MonoClock = .{ .io = io };
    var seed: [8]u8 = undefined;
    io.random(&seed);
    var prng = std.Random.DefaultPrng.init(std.mem.readInt(u64, &seed, .little));
    var sched = scheduler.Scheduler.init(app.gpa, mono.clock(), prng.random(), .{});
    defer sched.deinit();

    var eng: engine_mod.Engine = .{ .gpa = app.gpa, .store = store, .registry = &app.registry, .transport = app.transport() };

    // Restore each job's schedule from storage so restarts neither stampede nor skip polls.
    var scratch = std.heap.ArenaAllocator.init(app.gpa);
    defer scratch.deinit();
    const now0 = wallNow(io);
    for (app.jobs) |job| {
        const st = store.getSourceState(scratch.allocator(), job.name) catch store_mod.SourceState{};
        const due_in: ?u64 = if (st.next_poll) |np| @intCast(@max(0, np - now0) * 1000) else null;
        _ = try sched.add(job.interval_s, due_in, st.failures);
    }
    std.log.info("daemon started: {d} job(s), data in {s}", .{ app.jobs.len, app.data_dir });

    while (!g_stop.isSet()) {
        var polled = false;
        while (sched.takeDue()) |id| {
            polled = true;
            const job = app.jobs[id];
            const t0 = Io.Timestamp.now(io, .boot);
            const now = wallNow(io);
            const res = eng.poll(job, now);
            if (res.ok) sched.reportSuccess(id) else sched.reportFailure(id, res.class orelse .transient, res.retry_after_s);
            const next = now + @as(i64, @intCast(sched.dueInMs(id) / 1000));
            store.setNextPoll(job.name, next) catch {};
            const took = t0.durationTo(Io.Timestamp.now(io, .boot)).toMilliseconds();
            if (res.ok) {
                std.log.info("{s}: {s}, {d} new, {d} ms", .{ job.name, if (res.unchanged) "unchanged" else "ok", res.new_items, took });
            } else {
                var b: [16]u8 = undefined;
                std.log.warn("{s}: {s} ({s}); retry in {s}", .{ job.name, @tagName(res.class.?), res.messageSlice(), util.fmtSpan(&b, @intCast(sched.dueInMs(id) / 1000)) });
            }
            if (g_stop.isSet()) break;
        }
        if (polled) if (app.http) |*h| h.releaseCaches();
        if (g_stop.isSet()) break;
        const ms = sched.sleepMs();
        if (ms == 0) continue;
        g_stop.waitTimeout(io, .{ .duration = .{ .raw = .fromMilliseconds(@intCast(ms)), .clock = .boot } }) catch |e| switch (e) {
            error.Timeout => {},
            error.Canceled => break,
        };
    }
    std.log.info("daemon stopping", .{});
}
