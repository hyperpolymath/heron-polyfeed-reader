// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell
//! The single item model every adapter produces and everything downstream consumes.
const std = @import("std");

/// What sort of thing an item is. New adapters add variants here; storage and UI
/// only treat the value as a label (stored as its tag name).
pub const Kind = enum {
    article, // feed entry (RSS/Atom/RDF)
    post, // social post (future: ActivityPub, AT Protocol)
    message, // discussion message (future: NNTP)
    document, // gopher/gemini resource (future)
    alert, // monitor transition (up/down/changed/cert-expiry)
};

pub const Item = struct {
    /// Source name from the config; with `id` forms the dedupe key.
    source: []const u8,
    /// Stable id within the source (guid / atom:id, or derived: link + date, or content hash).
    id: []const u8,
    title: []const u8,
    url: []const u8,
    /// Unix seconds UTC, if the feed gave a parsable date.
    published: ?i64,
    body: []const u8,
    kind: Kind,
};
