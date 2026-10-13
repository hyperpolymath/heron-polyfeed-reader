const std = @import("std");
const sfr = @import("sfr");
pub fn main(init: std.process.Init) !void {
    _ = init;
    std.debug.print("sfr {s}\n", .{sfr.version});
}
