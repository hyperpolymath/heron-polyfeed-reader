// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell
//! Byte-transport interface used by HTTP-based adapters. The real implementation
//! lives in http.zig; tests use fakes, so parsing/scheduling never need a network.
const std = @import("std");

pub const Method = enum { get, head };

pub const Request = struct {
    url: []const u8,
    method: Method = .get,
    etag: ?[]const u8 = null,
    last_modified: ?[]const u8 = null,
    max_body_bytes: usize = 8 * 1024 * 1024,
    /// Follow redirects (bounded by the implementation).
    follow_redirects: bool = true,
};

pub const Response = struct {
    status: u16,
    etag: ?[]const u8 = null,
    last_modified: ?[]const u8 = null,
    retry_after: ?[]const u8 = null,
    content_type: ?[]const u8 = null,
    /// Allocated from the request arena.
    body: []const u8 = "",
    /// Final URL after redirects, if different.
    final_url: ?[]const u8 = null,
};

pub const Error = error{
    Timeout,
    DnsFailure,
    ConnectFailed,
    TlsFailure,
    TooLarge,
    BadResponse,
    Other,
};

pub const Transport = struct {
    ptr: *anyopaque,
    requestFn: *const fn (ptr: *anyopaque, arena: std.mem.Allocator, req: Request) Error!Response,

    pub fn request(self: Transport, arena: std.mem.Allocator, req: Request) Error!Response {
        return self.requestFn(self.ptr, arena, req);
    }
};
