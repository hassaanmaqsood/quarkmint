//! html.zig — HTML tag builders and escaping utilities.
//!
//! Provides zero-allocation-where-possible HTML generation helpers:
//!   • HTML entity escaping for text and attribute values (&, <, >, ", ')
//!   • Opening, closing, and void tag generation

const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Attr = struct {
    name: []const u8,
    value: []const u8,
};

/// Escape and append text content into `buf` ensuring & < > " ' are safely encoded.
pub fn escapeText(alloc: Allocator, buf: *std.ArrayList(u8), s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '&' => try buf.appendSlice(alloc, "&amp;"),
            '<' => try buf.appendSlice(alloc, "&lt;"),
            '>' => try buf.appendSlice(alloc, "&gt;"),
            '"' => try buf.appendSlice(alloc, "&quot;"),
            '\'' => try buf.appendSlice(alloc, "&#39;"),
            else => try buf.append(alloc, c),
        }
    }
}

/// Append opening tag `<tag attr1="val1" ...>`
pub fn openTag(alloc: Allocator, buf: *std.ArrayList(u8), tag: []const u8, attrs: []const Attr) !void {
    try buf.append(alloc, '<');
    try buf.appendSlice(alloc, tag);
    for (attrs) |attr| {
        if (attr.name.len == 0) continue;
        try buf.append(alloc, ' ');
        try buf.appendSlice(alloc, attr.name);
        try buf.appendSlice(alloc, "=\"");
        try escapeText(alloc, buf, attr.value);
        try buf.append(alloc, '"');
    }
    try buf.append(alloc, '>');
}

/// Append closing tag `</tag>`
pub fn closeTag(alloc: Allocator, buf: *std.ArrayList(u8), tag: []const u8) !void {
    try buf.appendSlice(alloc, "</");
    try buf.appendSlice(alloc, tag);
    try buf.append(alloc, '>');
}

/// Append self-closing void tag `<tag attr1="val1" ... />`
pub fn voidTag(alloc: Allocator, buf: *std.ArrayList(u8), tag: []const u8, attrs: []const Attr) !void {
    try buf.append(alloc, '<');
    try buf.appendSlice(alloc, tag);
    for (attrs) |attr| {
        if (attr.name.len == 0) continue;
        try buf.append(alloc, ' ');
        try buf.appendSlice(alloc, attr.name);
        try buf.appendSlice(alloc, "=\"");
        try escapeText(alloc, buf, attr.value);
        try buf.append(alloc, '"');
    }
    try buf.appendSlice(alloc, " />");
}

/// Append raw unescaped string into `buf`.
pub fn raw(alloc: Allocator, buf: *std.ArrayList(u8), s: []const u8) !void {
    try buf.appendSlice(alloc, s);
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

test "html — escape text" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);

    try escapeText(std.testing.allocator, &buf, "Fish & Chips <100% \"pure\">");
    try std.testing.expectEqualStrings("Fish &amp; Chips &lt;100% &quot;pure&quot;&gt;", buf.items);
}

test "html — tag builders" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);

    const attrs = [_]Attr{
        .{ .name = "class", .value = "btn primary" },
        .{ .name = "id", .value = "submit-btn" },
    };
    try openTag(std.testing.allocator, &buf, "button", &attrs);
    try raw(std.testing.allocator, &buf, "Click Me");
    try closeTag(std.testing.allocator, &buf, "button");

    try std.testing.expectEqualStrings("<button class=\"btn primary\" id=\"submit-btn\">Click Me</button>", buf.items);
}
