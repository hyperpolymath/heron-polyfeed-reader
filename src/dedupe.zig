// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell
//! Cross-fetch dedupe: given the items of a fetch, keep only those whose
//! (source, id) has not been seen. The `Seen` interface is implemented by the
//! SQLite-backed store in production and by `MemSeen` in tests.
const std = @import("std");
const Item = @import("item.zig").Item;

pub const Seen = struct {
    ptr: *anyopaque,
    containsFn: *const fn (ptr: *anyopaque, source: []const u8, id: []const u8) bool,

    pub fn contains(self: Seen, source: []const u8, id: []const u8) bool {
        return self.containsFn(self.ptr, source, id);
    }
};

/// Returns the not-yet-seen subset in original order. Allocates from `a`.
pub fn filterNew(a: std.mem.Allocator, seen: Seen, items: []const Item) std.mem.Allocator.Error![]Item {
    var out: std.ArrayList(Item) = .empty;
    for (items) |it| if (!seen.contains(it.source, it.id)) try out.append(a, it);
    return out.items;
}

pub const MemSeen = struct {
    set: std.StringHashMapUnmanaged(void) = .empty,
    gpa: std.mem.Allocator,

    fn key(a: std.mem.Allocator, source: []const u8, id: []const u8) ![]u8 {
        return std.fmt.allocPrint(a, "{s}\x00{s}", .{ source, id });
    }
    pub fn add(self: *MemSeen, source: []const u8, id: []const u8) !void {
        try self.set.put(self.gpa, try key(self.gpa, source, id), {});
    }
    pub fn deinit(self: *MemSeen) void {
        var it = self.set.keyIterator();
        while (it.next()) |k| self.gpa.free(k.*);
        self.set.deinit(self.gpa);
    }
    fn containsImpl(ptr: *anyopaque, source: []const u8, id: []const u8) bool {
        const self: *MemSeen = @ptrCast(@alignCast(ptr));
        var buf: [1024]u8 = undefined;
        const k = std.fmt.bufPrint(&buf, "{s}\x00{s}", .{ source, id }) catch return false;
        return self.set.contains(k);
    }
    pub fn seen(self: *MemSeen) Seen {
        return .{ .ptr = self, .containsFn = containsImpl };
    }
};

test "filterNew drops seen ids, scoped by source" {
    var ms: MemSeen = .{ .gpa = std.testing.allocator };
    defer ms.deinit();
    try ms.add("a", "1");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const mk = struct {
        fn f(s: []const u8, id: []const u8) Item {
            return .{ .source = s, .id = id, .title = "", .url = "", .published = null, .body = "", .kind = .article };
        }
    }.f;
    const items = [_]Item{ mk("a", "1"), mk("a", "2"), mk("b", "1") };
    const fresh = try filterNew(arena.allocator(), ms.seen(), &items);
    try std.testing.expectEqual(@as(usize, 2), fresh.len);
    try std.testing.expectEqualStrings("2", fresh[0].id);
    try std.testing.expectEqualStrings("b", fresh[1].source);
}
