// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell
const std = @import("std");
const heron = @import("heron");

pub const std_options: std.Options = .{ .log_level = .info };

pub fn main(init: std.process.Init) u8 {
    return heron.cli.main(init);
}
