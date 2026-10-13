// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Core library module: everything except the CLI entry point.
    const core = b.addModule("sfr", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    // Vendored SQLite amalgamation, compiled by `zig cc`. Only the options we need.
    core.addIncludePath(b.path("vendor/sqlite"));
    core.addCSourceFile(.{
        .file = b.path("vendor/sqlite/sqlite3.c"),
        .flags = &.{
            "-DSQLITE_ENABLE_FTS5=1",
            "-DSQLITE_THREADSAFE=2", // multi-thread: one connection per thread
            "-DSQLITE_OMIT_LOAD_EXTENSION=1",
            "-DSQLITE_DEFAULT_MEMSTATUS=0",
            "-DSQLITE_OMIT_DEPRECATED=1",
            "-DSQLITE_OMIT_SHARED_CACHE=1",
            "-DSQLITE_DQS=0",
            "-DSQLITE_DEFAULT_WAL_SYNCHRONOUS=1",
            "-DSQLITE_USE_ALLOCA=1",
            "-fno-sanitize=undefined",
        },
    });

    const exe = b.addExecutable(.{
        .name = "sfr",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "sfr", .module = core }},
            .link_libc = true,
        }),
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    run.addPassthruArgs();
    b.step("run", "Run sfr").dependOn(&run.step);

    const core_tests = b.addTest(.{ .root_module = core });
    const run_core_tests = b.addRunArtifact(core_tests);
    // Fixtures are located relative to the project root.
    run_core_tests.setCwd(b.path("."));
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_core_tests.step);
}
