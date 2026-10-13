// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell
//! Process-level wiring shared by the CLI and the daemon: where config/data live, loading the
//! config, building the adapter registry and the list of jobs.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const config = @import("config.zig");
const adapter = @import("adapter.zig");
const feed_adapter = @import("feed_adapter.zig");
const http = @import("http.zig");

pub const Overrides = struct {
    config_path: ?[]const u8 = null,
    data_dir: ?[]const u8 = null,
};

pub const App = struct {
    gpa: Allocator,
    io: Io,
    /// Owns config text, paths, job list. Freed in deinit.
    arena: std.heap.ArenaAllocator,
    config_path: []const u8,
    data_dir: []const u8,
    cfg: config.Config,
    jobs: []adapter.Source = &.{},
    feed: feed_adapter.FeedAdapter = .{},
    registry: adapter.Registry = .{},
    http: ?http.HttpTransport = null,

    pub const LoadError = error{ ConfigNotFound, InvalidConfig, NoHome } || Allocator.Error;

    /// Load configuration. The returned App must not be moved after `setup()`.
    pub fn load(gpa: Allocator, io: Io, env: *const std.process.Environ.Map, ov: Overrides, diag: *config.Diagnostic) LoadError!App {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();

        const home = env.get("HOME");
        const config_path = ov.config_path orelse env.get("SFR_CONFIG") orelse blk: {
            if (env.get("XDG_CONFIG_HOME")) |x| break :blk try std.fmt.allocPrint(a, "{s}/superfeedreader/config.json", .{x});
            const h = home orelse return error.NoHome;
            break :blk try std.fmt.allocPrint(a, "{s}/.config/superfeedreader/config.json", .{h});
        };
        const text = Io.Dir.cwd().readFileAlloc(io, config_path, a, .limited(1024 * 1024)) catch {
            diag.message = try std.fmt.allocPrint(a, "cannot read config file {s}", .{config_path});
            return error.ConfigNotFound;
        };
        const cfg = config.parse(a, text, diag) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidConfig => return error.InvalidConfig,
        };
        const data_dir = ov.data_dir orelse env.get("SFR_DATA") orelse cfg.data_dir orelse blk: {
            if (env.get("XDG_DATA_HOME")) |x| break :blk try std.fmt.allocPrint(a, "{s}/superfeedreader", .{x});
            const h = home orelse return error.NoHome;
            break :blk try std.fmt.allocPrint(a, "{s}/.local/share/superfeedreader", .{h});
        };

        var jobs: std.ArrayList(adapter.Source) = .empty;
        for (cfg.sources) |s| try jobs.append(a, .{ .name = s.name, .type_name = s.type_name, .url = s.url, .interval_s = s.interval_s, .options = s.options });
        for (cfg.monitors) |m| {
            const opts = try std.fmt.allocPrint(a, "{{\"expect_status\":{d},\"detect_changes\":{},\"check_robots\":{},\"cert_warn_days\":{d}}}", .{ m.expect_status, m.detect_changes, m.check_robots, m.cert_warn_days });
            try jobs.append(a, .{ .name = m.name, .type_name = "monitor", .url = m.url, .interval_s = m.interval_s, .options = opts });
        }
        return .{ .gpa = gpa, .io = io, .arena = arena, .config_path = config_path, .data_dir = data_dir, .cfg = cfg, .jobs = jobs.items };
    }

    /// Register adapters. Call once, after the App has its final address.
    pub fn setup(self: *App) !void {
        try self.registry.register(self.feed.asAdapter());
    }

    pub fn transport(self: *App) @import("transport.zig").Transport {
        if (self.http == null) self.http = http.HttpTransport.init(self.gpa, self.io, self.cfg.user_agent, self.cfg.timeout_s);
        return self.http.?.asTransport();
    }

    pub fn deinit(self: *App) void {
        if (self.http) |*h| h.deinit();
        self.arena.deinit();
    }
};
