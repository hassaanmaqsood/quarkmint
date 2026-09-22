//! renderer.zig — Quarkdown AST to HTML byte stream renderer.
//!
//! Renders CommonMark standard elements and Quarkdown extensions into an append-only
//! byte buffer (`std.ArrayList(u8)`) adhering to the Quarkdown HTML contract.

const std = @import("std");
const ast = @import("ast.zig");
const html = @import("html.zig");
const context_mod = @import("context.zig");
const math_mod = @import("math.zig");

const Allocator = std.mem.Allocator;
pub const Node = ast.Node;
pub const Context = context_mod.Context;

pub const Renderer = struct {
    buf: *std.ArrayList(u8),
    ctx: *const Context,
    alloc: Allocator,

    pub fn init(alloc: Allocator, buf: *std.ArrayList(u8), ctx: *const Context) Renderer {
        return .{
            .buf = buf,
            .ctx = ctx,
            .alloc = alloc,
        };
    }

    /// Render a slice of AST nodes into the output HTML buffer.
    pub fn renderAll(self: *Renderer, nodes: []const Node) Allocator.Error!void {
        for (nodes) |node| {
            try self.renderNode(node);
        }
    }

    pub fn renderNode(self: *Renderer, node: Node) Allocator.Error!void {
        switch (node) {
            .heading => |h| {
                const tag = try std.fmt.allocPrint(self.alloc, "h{d}", .{h.level});
                if (h.id) |slug| {
                    const attrs = [_]html.Attr{.{ .name = "id", .value = slug }};
                    try html.openTag(self.alloc, self.buf, tag, &attrs);
                } else {
                    try html.openTag(self.alloc, self.buf, tag, &.{});
                }
                try html.escapeText(self.alloc, self.buf, h.text);
                try html.closeTag(self.alloc, self.buf, tag);
                try self.buf.append(self.alloc, '\n');
            },

            .paragraph => |p| {
                try html.openTag(self.alloc, self.buf, "p", &.{});
                try html.escapeText(self.alloc, self.buf, p);
                try html.closeTag(self.alloc, self.buf, "p");
                try self.buf.append(self.alloc, '\n');
            },

            .rich_block => |rb| {
                try html.openTag(self.alloc, self.buf, "p", &.{});
                for (rb.items) |child| {
                    try self.renderInline(child);
                }
                try html.closeTag(self.alloc, self.buf, "p");
                try self.buf.append(self.alloc, '\n');
            },

            .text => |t| {
                try html.escapeText(self.alloc, self.buf, t);
            },

            .emphasis => |e| {
                try html.openTag(self.alloc, self.buf, "em", &.{});
                try html.escapeText(self.alloc, self.buf, e);
                try html.closeTag(self.alloc, self.buf, "em");
            },

            .strong => |s| {
                try html.openTag(self.alloc, self.buf, "strong", &.{});
                try html.escapeText(self.alloc, self.buf, s);
                try html.closeTag(self.alloc, self.buf, "strong");
            },

            .strikethrough => |s| {
                try html.openTag(self.alloc, self.buf, "del", &.{});
                try html.escapeText(self.alloc, self.buf, s);
                try html.closeTag(self.alloc, self.buf, "del");
            },

            .code_span => |cs| {
                try html.openTag(self.alloc, self.buf, "code", &.{});
                try html.escapeText(self.alloc, self.buf, cs);
                try html.closeTag(self.alloc, self.buf, "code");
            },

            .code_block => |cb| {
                try html.openTag(self.alloc, self.buf, "pre", &.{});
                if (cb.language.len > 0) {
                    const cls = try std.fmt.allocPrint(self.alloc, "language-{s}", .{cb.language});
                    const attrs = [_]html.Attr{.{ .name = "class", .value = cls }};
                    try html.openTag(self.alloc, self.buf, "code", &attrs);
                } else {
                    try html.openTag(self.alloc, self.buf, "code", &.{});
                }
                try html.escapeText(self.alloc, self.buf, cb.content);
                try html.closeTag(self.alloc, self.buf, "code");
                try html.closeTag(self.alloc, self.buf, "pre");
                try self.buf.append(self.alloc, '\n');
            },

            .blockquote => |b| {
                try html.openTag(self.alloc, self.buf, "blockquote", &.{});
                try self.buf.append(self.alloc, '\n');
                try html.openTag(self.alloc, self.buf, "p", &.{});
                try html.escapeText(self.alloc, self.buf, b);
                try html.closeTag(self.alloc, self.buf, "p");
                try self.buf.append(self.alloc, '\n');
                try html.closeTag(self.alloc, self.buf, "blockquote");
                try self.buf.append(self.alloc, '\n');
            },

            .thematic_break => {
                try html.voidTag(self.alloc, self.buf, "hr", &.{});
                try self.buf.append(self.alloc, '\n');
            },

            .list => |l| {
                const list_tag = if (l.ordered) "ol" else "ul";
                try html.openTag(self.alloc, self.buf, list_tag, &.{});
                try self.buf.append(self.alloc, '\n');

                for (l.items.items) |item| {
                    try html.openTag(self.alloc, self.buf, "li", &.{});
                    if (item.checked) |chk| {
                        if (chk) {
                            try self.buf.appendSlice(self.alloc, "<input type=\"checkbox\" checked disabled /> ");
                        } else {
                            try self.buf.appendSlice(self.alloc, "<input type=\"checkbox\" disabled /> ");
                        }
                    }
                    try html.escapeText(self.alloc, self.buf, item.text);
                    try html.closeTag(self.alloc, self.buf, "li");
                    try self.buf.append(self.alloc, '\n');
                }

                try html.closeTag(self.alloc, self.buf, list_tag);
                try self.buf.append(self.alloc, '\n');
            },

            .table => |tbl| {
                try html.openTag(self.alloc, self.buf, "table", &.{});
                try self.buf.append(self.alloc, '\n');

                if (tbl.headers.items.len > 0) {
                    try html.openTag(self.alloc, self.buf, "thead", &.{});
                    try self.buf.append(self.alloc, '\n');
                    try html.openTag(self.alloc, self.buf, "tr", &.{});
                    try self.buf.append(self.alloc, '\n');

                    for (tbl.headers.items, 0..) |h, col_idx| {
                        const align_style = self.getAlignStyle(tbl.alignments.items, col_idx);
                        if (align_style) |st| {
                            const attrs = [_]html.Attr{.{ .name = "style", .value = st }};
                            try html.openTag(self.alloc, self.buf, "th", &attrs);
                        } else {
                            try html.openTag(self.alloc, self.buf, "th", &.{});
                        }
                        try html.escapeText(self.alloc, self.buf, h);
                        try html.closeTag(self.alloc, self.buf, "th");
                        try self.buf.append(self.alloc, '\n');
                    }

                    try html.closeTag(self.alloc, self.buf, "tr");
                    try self.buf.append(self.alloc, '\n');
                    try html.closeTag(self.alloc, self.buf, "thead");
                    try self.buf.append(self.alloc, '\n');
                }

                try html.openTag(self.alloc, self.buf, "tbody", &.{});
                try self.buf.append(self.alloc, '\n');

                for (tbl.rows.items) |row| {
                    try html.openTag(self.alloc, self.buf, "tr", &.{});
                    try self.buf.append(self.alloc, '\n');

                    for (row.items, 0..) |cell, col_idx| {
                        const align_style = self.getAlignStyle(tbl.alignments.items, col_idx);
                        if (align_style) |st| {
                            const attrs = [_]html.Attr{.{ .name = "style", .value = st }};
                            try html.openTag(self.alloc, self.buf, "td", &attrs);
                        } else {
                            try html.openTag(self.alloc, self.buf, "td", &.{});
                        }
                        try html.escapeText(self.alloc, self.buf, cell);
                        try html.closeTag(self.alloc, self.buf, "td");
                        try self.buf.append(self.alloc, '\n');
                    }

                    try html.closeTag(self.alloc, self.buf, "tr");
                    try self.buf.append(self.alloc, '\n');
                }

                try html.closeTag(self.alloc, self.buf, "tbody");
                try self.buf.append(self.alloc, '\n');
                try html.closeTag(self.alloc, self.buf, "table");
                try self.buf.append(self.alloc, '\n');
            },

            .link => |l| {
                var attrs = std.ArrayList(html.Attr).empty;
                try attrs.append(self.alloc, .{ .name = "href", .value = l.url });
                if (l.title.len > 0) {
                    try attrs.append(self.alloc, .{ .name = "title", .value = l.title });
                }
                try html.openTag(self.alloc, self.buf, "a", attrs.items);
                try html.escapeText(self.alloc, self.buf, l.text);
                try html.closeTag(self.alloc, self.buf, "a");
            },

            .image => |img| {
                var attrs = std.ArrayList(html.Attr).empty;
                try attrs.append(self.alloc, .{ .name = "src", .value = img.url });
                try attrs.append(self.alloc, .{ .name = "alt", .value = img.alt });
                if (img.title.len > 0) {
                    try attrs.append(self.alloc, .{ .name = "title", .value = img.title });
                }
                try html.voidTag(self.alloc, self.buf, "img", attrs.items);
            },

            .auto_link => |al| {
                const attrs = [_]html.Attr{.{ .name = "href", .value = al }};
                try html.openTag(self.alloc, self.buf, "a", &attrs);
                try html.escapeText(self.alloc, self.buf, al);
                try html.closeTag(self.alloc, self.buf, "a");
            },

            .html_inline => |hi| {
                try self.buf.appendSlice(self.alloc, hi);
            },

            .html_block => |hb| {
                try self.buf.appendSlice(self.alloc, hb);
                try self.buf.append(self.alloc, '\n');
            },

            .math_block => |mb| {
                const attrs = [_]html.Attr{
                    .{ .name = "class", .value = "math" },
                    .{ .name = "data-tex", .value = mb },
                };
                try html.openTag(self.alloc, self.buf, "div", &attrs);
                try math_mod.renderTeXToMathML(self.alloc, self.buf, mb, true);
                try html.closeTag(self.alloc, self.buf, "div");
                try self.buf.append(self.alloc, '\n');
            },

            .math_span => |ms| {
                const attrs = [_]html.Attr{
                    .{ .name = "class", .value = "math" },
                    .{ .name = "data-tex", .value = ms },
                };
                try html.openTag(self.alloc, self.buf, "span", &attrs);
                try math_mod.renderTeXToMathML(self.alloc, self.buf, ms, false);
                try html.closeTag(self.alloc, self.buf, "span");
            },

            .box => |b| {
                const attrs = [_]html.Attr{.{ .name = "class", .value = "qd-box" }};
                try html.openTag(self.alloc, self.buf, "div", &attrs);
                if (b.title) |t| {
                    try html.openTag(self.alloc, self.buf, "h5", &.{});
                    try html.escapeText(self.alloc, self.buf, t);
                    try html.closeTag(self.alloc, self.buf, "h5");
                }
                try html.openTag(self.alloc, self.buf, "div", &[_]html.Attr{.{ .name = "class", .value = "qd-box-content" }});
                try self.renderContentWithMath(b.content);
                try html.closeTag(self.alloc, self.buf, "div");
                try html.closeTag(self.alloc, self.buf, "div");
                try self.buf.append(self.alloc, '\n');
            },

            .stacked => |s| {
                const cls = if (s.kind == .row) "qd-row" else "qd-col";
                const attrs = [_]html.Attr{.{ .name = "class", .value = cls }};
                try html.openTag(self.alloc, self.buf, "div", &attrs);
                try self.renderContentWithMath(s.content);
                try html.closeTag(self.alloc, self.buf, "div");
                try self.buf.append(self.alloc, '\n');
            },

            .page_break => {
                const attrs = [_]html.Attr{.{ .name = "class", .value = "page-break" }};
                try html.openTag(self.alloc, self.buf, "div", &attrs);
                try html.closeTag(self.alloc, self.buf, "div");
                try self.buf.append(self.alloc, '\n');
            },

            .line_break => {
                try html.voidTag(self.alloc, self.buf, "br", &.{});
                try self.buf.append(self.alloc, '\n');
            },

            .soft_break => {
                try self.buf.append(self.alloc, '\n');
            },

            .blank => {},

            .link_definition, .footnote_definition => {},

            .parse_error => |e| {
                const attrs = [_]html.Attr{.{ .name = "class", .value = "qd-error" }};
                try html.openTag(self.alloc, self.buf, "div", &attrs);
                try html.escapeText(self.alloc, self.buf, e.message);
                try html.closeTag(self.alloc, self.buf, "div");
                try self.buf.append(self.alloc, '\n');
            },

            .function_call => |fc| {
                // If any unexpanded function call reaches renderer, format as fallback
                const attrs = [_]html.Attr{.{ .name = "class", .value = "qd-unexpanded" }};
                try html.openTag(self.alloc, self.buf, "span", &attrs);
                try self.buf.append(self.alloc, '.');
                try html.escapeText(self.alloc, self.buf, fc.name);
                try html.closeTag(self.alloc, self.buf, "span");
            },
        }
    }

    fn renderInline(self: *Renderer, node: Node) Allocator.Error!void {
        try self.renderNode(node);
    }

    fn getAlignStyle(self: *Renderer, aligns: []const ast.ColumnAlign, col_idx: usize) ?[]const u8 {
        _ = self;
        if (col_idx >= aligns.len) return null;
        return switch (aligns[col_idx]) {
            .left => "text-align: left;",
            .center => "text-align: center;",
            .right => "text-align: right;",
            .none => null,
        };
    }

    fn renderContentWithMath(self: *Renderer, content: []const u8) Allocator.Error!void {
        var i: usize = 0;
        var text_start: usize = 0;

        while (i < content.len) {
            if (i + 1 < content.len and content[i] == '$' and content[i + 1] == '$') {
                if (i > text_start) {
                    try html.escapeText(self.alloc, self.buf, content[text_start..i]);
                }
                const math_start = i + 2;
                if (std.mem.indexOfPos(u8, content, math_start, "$$")) |end_pos| {
                    const tex = std.mem.trim(u8, content[math_start..end_pos], " \t\r\n");
                    const attrs = [_]html.Attr{
                        .{ .name = "class", .value = "math" },
                        .{ .name = "data-tex", .value = tex },
                    };
                    try html.openTag(self.alloc, self.buf, "div", &attrs);
                    try math_mod.renderTeXToMathML(self.alloc, self.buf, tex, true);
                    try html.closeTag(self.alloc, self.buf, "div");
                    i = end_pos + 2;
                    text_start = i;
                    continue;
                } else {
                    i += 2;
                }
            } else if (content[i] == '$') {
                if (i > text_start) {
                    try html.escapeText(self.alloc, self.buf, content[text_start..i]);
                }
                const math_start = i + 1;
                if (std.mem.indexOfPos(u8, content, math_start, "$")) |end_pos| {
                    const tex = std.mem.trim(u8, content[math_start..end_pos], " \t\r\n");
                    const attrs = [_]html.Attr{
                        .{ .name = "class", .value = "math" },
                        .{ .name = "data-tex", .value = tex },
                    };
                    try html.openTag(self.alloc, self.buf, "span", &attrs);
                    try math_mod.renderTeXToMathML(self.alloc, self.buf, tex, false);
                    try html.closeTag(self.alloc, self.buf, "span");
                    i = end_pos + 1;
                    text_start = i;
                    continue;
                } else {
                    i += 1;
                }
            } else {
                i += 1;
            }
        }

        if (text_start < content.len) {
            try html.escapeText(self.alloc, self.buf, content[text_start..]);
        }
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

test "renderer — heading with slug ID and paragraph" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var ctx = try Context.init(alloc, .{});
    defer ctx.deinit();

    var buf: std.ArrayList(u8) = .empty;

    var r = Renderer.init(alloc, &buf, &ctx);

    const nodes = [_]Node{
        .{ .heading = .{ .level = 1, .text = "Hello World", .id = "hello-world" } },
        .{ .paragraph = "This is a paragraph with & special characters." },
    };

    try r.renderAll(&nodes);

    const expected =
        \\<h1 id="hello-world">Hello World</h1>
        \\<p>This is a paragraph with &amp; special characters.</p>
        \\
    ;
    try std.testing.expectEqualStrings(expected, buf.items);
}

test "renderer — list with task items" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var ctx = try Context.init(alloc, .{});
    defer ctx.deinit();

    var buf: std.ArrayList(u8) = .empty;
    var r = Renderer.init(alloc, &buf, &ctx);

    var items = ast.List(ast.ListItem).empty;
    try items.append(alloc, .{ .text = "Normal item" });
    try items.append(alloc, .{ .text = "Done task", .checked = true });
    try items.append(alloc, .{ .text = "Todo task", .checked = false });

    const nodes = [_]Node{
        .{ .list = .{ .ordered = false, .items = items } },
    };

    try r.renderAll(&nodes);

    try std.testing.expect(std.mem.indexOf(u8, buf.items, "<ul>\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "<li>Normal item</li>\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "<li><input type=\"checkbox\" checked disabled /> Done task</li>\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "<li><input type=\"checkbox\" disabled /> Todo task</li>\n") != null);
}

test "renderer — Quarkdown box and math" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var ctx = try Context.init(alloc, .{ .math_katex = true });
    defer ctx.deinit();

    var buf: std.ArrayList(u8) = .empty;
    var r = Renderer.init(alloc, &buf, &ctx);

    const nodes = [_]Node{
        .{ .box = .{ .title = "Note", .content = "Pay attention!" } },
        .{ .math_block = "E = mc^2" },
    };

    try r.renderAll(&nodes);

    try std.testing.expect(std.mem.indexOf(u8, buf.items, "<div class=\"qd-box\"><h5>Note</h5><div class=\"qd-box-content\">Pay attention!</div></div>") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "<div class=\"math\" data-tex=\"E = mc^2\"><math display=\"block\"><mi>E</mi><mo>=</mo><mi>m</mi><msup><mi>c</mi><mn>2</mn></msup></math></div>") != null);
}
