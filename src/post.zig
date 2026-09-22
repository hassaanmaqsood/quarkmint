//! post.zig — HTML5 document wrapper and post-processing for Quarkdown.
//!
//! Wraps rendered HTML fragments into a complete, standalone HTML5 document shell
//! with embedded Quarkdown CSS, viewport metadata, document title, and optional header.

const std = @import("std");
const context_mod = @import("context.zig");
const html = @import("html.zig");

const Allocator = std.mem.Allocator;
pub const Context = context_mod.Context;
pub const DocumentInfo = context_mod.DocumentInfo;

/// Embedded stylesheet containing responsive typography and Quarkmint styling.
pub const QUARKMINT_CSS = @embedFile("assets/quarkmint.css");
pub const QUARKDOWN_CSS = QUARKMINT_CSS;

/// Wrap rendered body HTML into a complete, standalone HTML5 document.
pub fn buildDocument(
    alloc: Allocator,
    buf: *std.ArrayList(u8),
    ctx: *const Context,
    body_html: []const u8,
) Allocator.Error!void {
    const info = &ctx.doc_info;

    // DOCTYPE and opening html tag
    try buf.appendSlice(alloc, "<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n");
    try buf.appendSlice(alloc, "  <meta charset=\"utf-8\">\n");
    try buf.appendSlice(alloc, "  <meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">\n");

    // Title tag
    try buf.appendSlice(alloc, "  <title>");
    if (info.title.len > 0) {
        try html.escapeText(alloc, buf, info.title);
    } else {
        try buf.appendSlice(alloc, "Quarkdown Document");
    }
    try buf.appendSlice(alloc, "</title>\n");

    // Embedded CSS
    try buf.appendSlice(alloc, "  <style>\n");
    try buf.appendSlice(alloc, QUARKDOWN_CSS);
    try buf.appendSlice(alloc, "\n  </style>\n");

    // KaTeX for pixel-perfect LaTeX mathematics
    try buf.appendSlice(alloc,
        \\  <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.css">
        \\  <script defer src="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.js"></script>
        \\  <script defer src="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/contrib/auto-render.min.js" onload="renderMathInElement(document.body,{delimiters:[{left:'$$',right:'$$',display:true},{left:'$',right:'$',display:false}],ignoredTags:['script','noscript','style','textarea','pre','code'],throwOnError:false});"></script>
        \\
    );

    // Close head and open body
    try buf.appendSlice(alloc, "</head>\n");

    // Body tag with doctype class
    try buf.appendSlice(alloc, "<body class=\"qd-doc");
    if (info.doc_type.len > 0) {
        try buf.appendSlice(alloc, " qd-");
        try html.escapeText(alloc, buf, info.doc_type);
    }
    try buf.appendSlice(alloc, "\">\n");

    // Container
    try buf.appendSlice(alloc, "<div class=\"qd-doc-container\">\n");

    // Document header (if title, author, or date are specified)
    const has_title = info.title.len > 0 and !std.mem.eql(u8, info.title, "Untitled Document");
    const has_author = info.author.len > 0;
    const has_date = info.date.len > 0;

    if (has_title or has_author or has_date) {
        try buf.appendSlice(alloc, "  <header class=\"qd-header\">\n");
        if (has_title) {
            try buf.appendSlice(alloc, "    <h1 class=\"qd-title\">");
            try html.escapeText(alloc, buf, info.title);
            try buf.appendSlice(alloc, "</h1>\n");
        }
        if (has_author or has_date) {
            try buf.appendSlice(alloc, "    <div class=\"qd-meta\">\n");
            if (has_author) {
                try buf.appendSlice(alloc, "      <span class=\"qd-author\">");
                try html.escapeText(alloc, buf, info.author);
                try buf.appendSlice(alloc, "</span>\n");
            }
            if (has_date) {
                try buf.appendSlice(alloc, "      <span class=\"qd-date\">");
                try html.escapeText(alloc, buf, info.date);
                try buf.appendSlice(alloc, "</span>\n");
            }
            try buf.appendSlice(alloc, "    </div>\n");
        }
        try buf.appendSlice(alloc, "  </header>\n");
    }

    // Main content
    try buf.appendSlice(alloc, "  <main class=\"qd-content\">\n");
    try buf.appendSlice(alloc, body_html);
    try buf.appendSlice(alloc, "\n  </main>\n");

    // Close container, body, html
    try buf.appendSlice(alloc, "</div>\n</body>\n</html>\n");
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

test "post — buildDocument generates valid HTML5 document shell" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var ctx = try Context.init(alloc, .{ .standalone = true });
    ctx.doc_info.title = "Test Paper";
    ctx.doc_info.author = "Jane Doe";
    ctx.doc_info.date = "2026-09-22";

    var buf: std.ArrayList(u8) = .empty;
    const body = "<p>Hello Quarkdown!</p>";

    try buildDocument(alloc, &buf, &ctx, body);

    const doc = buf.items;
    try std.testing.expect(std.mem.startsWith(u8, doc, "<!DOCTYPE html>"));
    try std.testing.expect(std.mem.indexOf(u8, doc, "<title>Test Paper</title>") != null);
    try std.testing.expect(std.mem.indexOf(u8, doc, "<h1 class=\"qd-title\">Test Paper</h1>") != null);
    try std.testing.expect(std.mem.indexOf(u8, doc, "<span class=\"qd-author\">Jane Doe</span>") != null);
    try std.testing.expect(std.mem.indexOf(u8, doc, "<span class=\"qd-date\">2026-09-22</span>") != null);
    try std.testing.expect(std.mem.indexOf(u8, doc, "<p>Hello Quarkdown!</p>") != null);
    try std.testing.expect(std.mem.indexOf(u8, doc, "var(--qd-bg)") != null);
    try std.testing.expect(std.mem.endsWith(u8, doc, "</html>\n"));
}

test "post — default untitled document shell" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var ctx = try Context.init(alloc, .{});

    var buf: std.ArrayList(u8) = .empty;
    const body = "<p>Simple Body</p>";

    try buildDocument(alloc, &buf, &ctx, body);

    const doc = buf.items;
    try std.testing.expect(std.mem.startsWith(u8, doc, "<!DOCTYPE html>"));
    try std.testing.expect(std.mem.indexOf(u8, doc, "<title>Untitled Document</title>") != null);
    // Should NOT have an extra header if untitled
    try std.testing.expect(std.mem.indexOf(u8, doc, "<header class=\"qd-header\">") == null);
    try std.testing.expect(std.mem.indexOf(u8, doc, "<p>Simple Body</p>") != null);
}
