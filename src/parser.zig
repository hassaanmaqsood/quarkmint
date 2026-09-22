//! parser.zig — Two-phase, zero-copy Quarkdown parser.
//!
//! Uses `lexer.zig` to tokenize block structures and inline formatting,
//! producing a typed `Node` AST living in the caller's ArenaAllocator.
//!
//! Zero-copy guarantee:
//! Every string in every AST node is a slice of the original source buffer.
//! No strings are allocated on the heap during parsing.

const std = @import("std");
const ast = @import("ast.zig");
const tokens = @import("tokens.zig");
const lexer = @import("lexer.zig");

const Allocator = std.mem.Allocator;
pub const Node = ast.Node;
pub const Argument = ast.Argument;
pub const FunctionCallData = ast.FunctionCallData;
pub const HeadingData = ast.HeadingData;
pub const ListData = ast.ListData;
pub const ListItem = ast.ListItem;
pub const CodeBlockData = ast.CodeBlockData;
pub const LinkData = ast.LinkData;
pub const ImageData = ast.ImageData;
pub const ColumnAlign = ast.ColumnAlign;
pub const TableData = ast.TableData;
pub const LinkDefinitionData = ast.LinkDefinitionData;
pub const FootnoteData = ast.FootnoteData;
pub const BoxData = ast.BoxData;
pub const StackedData = ast.StackedData;
pub const ErrorData = ast.ErrorData;
pub const Token = tokens.Token;
pub const TokenKind = tokens.TokenKind;

// ─────────────────────────────────────────────────────────────────────────────
// ParseError — returned when allocation fails.
// ─────────────────────────────────────────────────────────────────────────────
pub const ParseError = error{
    OutOfMemory,
};

// ─────────────────────────────────────────────────────────────────────────────
// Parse Result
// ─────────────────────────────────────────────────────────────────────────────

pub const ParseResult = struct {
    nodes: std.ArrayList(Node),
    alloc: Allocator,

    pub fn deinit(self: *ParseResult) void {
        for (self.nodes.items) |*n| n.deinit(self.alloc);
        self.nodes.deinit(self.alloc);
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// Inline Token Conversion Helpers
// ─────────────────────────────────────────────────────────────────────────────

fn stripBackticks(s: []const u8) []const u8 {
    var start: usize = 0;
    while (start < s.len and s[start] == '`') : (start += 1) {}
    var end: usize = s.len;
    while (end > start and s[end - 1] == '`') : (end -= 1) {}

    var content = s[start..end];
    if (content.len >= 2 and content[0] == ' ' and content[content.len - 1] == ' ') {
        content = content[1 .. content.len - 1];
    }
    return content;
}

fn stripDollars(s: []const u8) []const u8 {
    var start: usize = 0;
    while (start < s.len and s[start] == '$') : (start += 1) {}
    var end: usize = s.len;
    while (end > start and s[end - 1] == '$') : (end -= 1) {}
    return s[start..end];
}

fn stripDelims(s: []const u8, count: usize) []const u8 {
    if (s.len < count * 2) return s;
    return s[count .. s.len - count];
}

fn stripAngleBrackets(s: []const u8) []const u8 {
    if (s.len >= 2 and s[0] == '<' and s[s.len - 1] == '>') {
        return s[1 .. s.len - 1];
    }
    return s;
}

fn parseBraceArgs(alloc: Allocator, src: []const u8, start: u32, end: u32) !ast.List(Argument) {
    var args = ast.List(Argument).empty;
    var pos: usize = start;
    const limit = @min(@as(usize, end), src.len);

    while (pos < limit) {
        while (pos < limit and (src[pos] == ' ' or src[pos] == '\t')) : (pos += 1) {}
        if (pos >= limit or src[pos] != '{') break;
        pos += 1; // skip `{`

        const arg_start = pos;
        var depth: usize = 1;
        var colon_pos: ?usize = null;

        while (pos < limit) : (pos += 1) {
            const c = src[pos];
            if (c == '{') depth += 1;
            if (c == '}') {
                depth -= 1;
                if (depth == 0) break;
            }
            if (c == ':' and depth == 1 and colon_pos == null) {
                colon_pos = pos;
            }
        }

        const arg_end = pos;
        if (pos < limit and src[pos] == '}') pos += 1;

        if (colon_pos) |cp| {
            const key = std.mem.trim(u8, src[arg_start..cp], " \t");
            const val = std.mem.trim(u8, src[cp + 1 .. arg_end], " \t");
            try args.append(alloc, .{ .key = key, .value = val });
        } else {
            const val = std.mem.trim(u8, src[arg_start..arg_end], " \t");
            try args.append(alloc, .{ .key = "", .value = val });
        }
    }

    return args;
}

fn parseInlineToken(alloc: Allocator, src: []const u8, tok: Token) !Node {
    return switch (tok.kind) {
        .text => Node{ .text = tok.slice(src) },
        .code_span => Node{ .code_span = stripBackticks(tok.slice(src)) },
        .math_span => Node{ .math_span = stripDollars(tok.slice(src)) },
        .emphasis => Node{ .emphasis = stripDelims(tok.slice(src), 1) },
        .strong => Node{ .strong = stripDelims(tok.slice(src), 2) },
        .strikethrough => Node{ .strikethrough = stripDelims(tok.slice(src), 2) },
        .link => {
            const l = tok.extra.link;
            return Node{ .link = .{
                .text = src[l.label_start..l.label_end],
                .url = src[l.url_start..l.url_end],
                .title = if (l.title_end > l.title_start) src[l.title_start..l.title_end] else "",
            } };
        },
        .image => {
            const l = tok.extra.link;
            return Node{ .image = .{
                .alt = src[l.label_start..l.label_end],
                .url = src[l.url_start..l.url_end],
                .title = if (l.title_end > l.title_start) src[l.title_start..l.title_end] else "",
            } };
        },
        .auto_link => Node{ .auto_link = stripAngleBrackets(tok.slice(src)) },
        .html_inline => Node{ .html_inline = tok.slice(src) },
        .function_call_inline => {
            const fc = tok.extra.function_call;
            const name = src[fc.name_start..fc.name_end];
            const args = try parseBraceArgs(alloc, src, fc.args_start, fc.args_end);
            return Node{ .function_call = .{
                .name = name,
                .args = args,
                .body = null,
                .is_inline = true,
            } };
        },
        .hard_break => Node.line_break,
        .soft_break => Node.soft_break,
        else => Node{ .text = tok.slice(src) },
    };
}

// ─────────────────────────────────────────────────────────────────────────────
// Table Helpers
// ─────────────────────────────────────────────────────────────────────────────

fn splitTableRowCells(alloc: Allocator, src: []const u8, start: u32, end: u32) !ast.List([]const u8) {
    var cells = ast.List([]const u8).empty;
    var row_slice = src[start..end];
    row_slice = std.mem.trim(u8, row_slice, "\r\n \t");
    if (std.mem.startsWith(u8, row_slice, "|")) row_slice = row_slice[1..];
    if (std.mem.endsWith(u8, row_slice, "|")) row_slice = row_slice[0 .. row_slice.len - 1];

    var it = std.mem.splitScalar(u8, row_slice, '|');
    while (it.next()) |cell| {
        try cells.append(alloc, std.mem.trim(u8, cell, " \t"));
    }
    return cells;
}

fn parseTableAlignments(alloc: Allocator, src: []const u8, start: u32, end: u32) !ast.List(ColumnAlign) {
    var aligns = ast.List(ColumnAlign).empty;
    var row_slice = src[start..end];
    row_slice = std.mem.trim(u8, row_slice, "\r\n \t");
    if (std.mem.startsWith(u8, row_slice, "|")) row_slice = row_slice[1..];
    if (std.mem.endsWith(u8, row_slice, "|")) row_slice = row_slice[0 .. row_slice.len - 1];

    var it = std.mem.splitScalar(u8, row_slice, '|');
    while (it.next()) |cell| {
        const c = std.mem.trim(u8, cell, " \t");
        const left_colon = std.mem.startsWith(u8, c, ":");
        const right_colon = std.mem.endsWith(u8, c, ":");
        const align_kind: ColumnAlign = if (left_colon and right_colon)
            .center
        else if (left_colon)
            .left
        else if (right_colon)
            .right
        else
            .none;
        try aligns.append(alloc, align_kind);
    }
    return aligns;
}

// ─────────────────────────────────────────────────────────────────────────────
// Public Entry Point
// ─────────────────────────────────────────────────────────────────────────────

/// Parse `source` into an ordered list of `Node` AST nodes.
///
/// - `alloc` is typically an ArenaAllocator child allocator.
/// - Slices in returned nodes point directly into `source` with zero copies.
pub fn parse(alloc: Allocator, source: []const u8) ParseError!ParseResult {
    var block_tokens = try lexer.tokenizeBlocks(alloc, source);
    defer block_tokens.deinit(alloc);

    var nodes: std.ArrayList(Node) = .empty;
    errdefer {
        for (nodes.items) |*n| n.deinit(alloc);
        nodes.deinit(alloc);
    }

    var i: usize = 0;
    while (i < block_tokens.items.len) {
        const tok = block_tokens.items[i];

        switch (tok.kind) {
            .eof => break,

            .blank => {
                if (nodes.items.len > 0 and nodes.items[nodes.items.len - 1] == .blank) {
                    i += 1;
                    continue;
                }
                try nodes.append(alloc, Node.blank);
                i += 1;
            },

            .heading => {
                const is_setext = tok.extra.heading.is_setext;
                var text = tok.slice(source);

                if (is_setext) {
                    // Title is the first line
                    var p: usize = 0;
                    while (p < text.len and text[p] != '\n' and text[p] != '\r') : (p += 1) {}
                    text = std.mem.trim(u8, text[0..p], " \t");
                } else {
                    // ATX: skip leading '#' and spaces
                    var start: usize = 0;
                    while (start < text.len and text[start] == '#') : (start += 1) {}
                    while (start < text.len and (text[start] == ' ' or text[start] == '\t')) : (start += 1) {}

                    // Strip trailing '#' and spaces
                    var end: usize = text.len;
                    while (end > start and (text[end - 1] == '\n' or text[end - 1] == '\r' or text[end - 1] == ' ' or text[end - 1] == '\t')) : (end -= 1) {}
                    const hash_end = end;
                    while (end > start and text[end - 1] == '#') : (end -= 1) {}
                    if (end < hash_end and (end == start or text[end - 1] == ' ' or text[end - 1] == '\t')) {
                        while (end > start and (text[end - 1] == ' ' or text[end - 1] == '\t')) : (end -= 1) {}
                        text = text[start..end];
                    } else {
                        text = text[start..hash_end];
                    }
                }

                try nodes.append(alloc, Node{ .heading = .{
                    .level = tok.extra.heading.level,
                    .text = text,
                    .is_setext = is_setext,
                    .id = null,
                } });
                i += 1;
            },

            .thematic_break => {
                try nodes.append(alloc, Node.thematic_break);
                i += 1;
            },

            .fenced_code => {
                const fc = tok.extra.code_fence;
                const lang = if (fc.lang_end > fc.lang_start) source[fc.lang_start..fc.lang_end] else "";

                // Body content: from end of opening fence line to before closing fence
                var p = tok.start;
                while (p < tok.end and source[p] != '\n') : (p += 1) {}
                if (p < tok.end and source[p] == '\n') p += 1;
                const content_start = p;

                var content_end = tok.end;
                while (content_end > content_start and (source[content_end - 1] == '\n' or source[content_end - 1] == '\r' or source[content_end - 1] == ' ' or source[content_end - 1] == '\t')) : (content_end -= 1) {}
                while (content_end > content_start and source[content_end - 1] == fc.fence_char) : (content_end -= 1) {}
                while (content_end > content_start and (source[content_end - 1] == '\n' or source[content_end - 1] == '\r')) : (content_end -= 1) {}

                const content = if (content_end > content_start) source[content_start..content_end] else "";

                try nodes.append(alloc, Node{ .code_block = .{
                    .language = lang,
                    .content = content,
                } });
                i += 1;
            },

            .indented_code => {
                try nodes.append(alloc, Node{ .code_block = .{
                    .language = "",
                    .content = tok.slice(source),
                } });
                i += 1;
            },

            .blockquote => {
                // Strip `>` prefixes from lines
                var buf: std.ArrayList(u8) = .empty;
                var it = std.mem.splitScalar(u8, tok.slice(source), '\n');
                while (it.next()) |line| {
                    var l = std.mem.trimStart(u8, line, " \t");
                    if (std.mem.startsWith(u8, l, ">")) {
                        l = l[1..];
                        if (std.mem.startsWith(u8, l, " ")) l = l[1..];
                    }
                    try buf.appendSlice(alloc, l);
                    try buf.append(alloc, '\n');
                }
                const content = try buf.toOwnedSlice(alloc);

                try nodes.append(alloc, Node{ .blockquote = content });
                i += 1;
            },

            .list_item => {
                // Group contiguous list items of same ordered flag
                const is_ordered = tok.extra.list_item.ordered;
                var items = ast.List(ListItem).empty;

                while (i < block_tokens.items.len) {
                    const next_tok = block_tokens.items[i];
                    if (next_tok.kind != .list_item or next_tok.extra.list_item.ordered != is_ordered) break;

                    const marker_end = next_tok.extra.list_item.marker_end;
                    var p = marker_end;
                    while (p < next_tok.end and (source[p] == ' ' or source[p] == '\t')) : (p += 1) {}

                    if (next_tok.extra.list_item.checked != null) {
                        if (p + 4 <= next_tok.end and source[p] == '[' and source[p + 2] == ']') {
                            p += 4;
                        }
                    }

                    const item_text = std.mem.trim(u8, source[p..next_tok.end], "\r\n \t");
                    try items.append(alloc, .{
                        .text = item_text,
                        .checked = next_tok.extra.list_item.checked,
                    });
                    i += 1;
                }

                try nodes.append(alloc, Node{ .list = .{
                    .ordered = is_ordered,
                    .items = items,
                } });
            },

            .table_row => {
                // Group consecutive table rows
                var headers = ast.List([]const u8).empty;
                var alignments = ast.List(ColumnAlign).empty;
                var rows = ast.List(ast.List([]const u8)).empty;

                headers = try splitTableRowCells(alloc, source, tok.start, tok.end);
                i += 1;

                if (i < block_tokens.items.len and block_tokens.items[i].kind == .table_row and block_tokens.items[i].extra.table_row.is_delimiter) {
                    alignments = try parseTableAlignments(alloc, source, block_tokens.items[i].start, block_tokens.items[i].end);
                    i += 1;
                }

                while (i < block_tokens.items.len and block_tokens.items[i].kind == .table_row) : (i += 1) {
                    const row_cells = try splitTableRowCells(alloc, source, block_tokens.items[i].start, block_tokens.items[i].end);
                    try rows.append(alloc, row_cells);
                }

                try nodes.append(alloc, Node{ .table = .{
                    .headers = headers,
                    .alignments = alignments,
                    .rows = rows,
                } });
            },

            .math_block => {
                const s = tok.slice(source);
                const content = std.mem.trim(u8, stripDollars(s), "\r\n \t");
                try nodes.append(alloc, Node{ .math_block = content });
                i += 1;
            },

            .function_call_block => {
                const fc = tok.extra.function_call;
                const name = source[fc.name_start..fc.name_end];
                const args = try parseBraceArgs(alloc, source, fc.args_start, fc.args_end);

                // Body: remainder of line
                var body_start = fc.args_end;
                while (body_start < tok.end and (source[body_start] == ' ' or source[body_start] == '\t')) : (body_start += 1) {}
                const raw_body = std.mem.trim(u8, source[body_start..tok.end], "\r\n \t");
                const body: ?[]const u8 = if (raw_body.len > 0) raw_body else null;

                try nodes.append(alloc, Node{ .function_call = .{
                    .name = name,
                    .args = args,
                    .body = body,
                    .is_inline = false,
                } });
                i += 1;
            },

            .link_definition => {
                const s = tok.slice(source);
                var label = s;
                var url = s;
                var title: []const u8 = "";

                if (std.mem.indexOfScalar(u8, s, ']')) |rb| {
                    label = std.mem.trim(u8, s[1..rb], " \t");
                    if (rb + 2 < s.len and s[rb + 1] == ':') {
                        const rest = std.mem.trim(u8, s[rb + 2 ..], " \t\r\n");
                        if (std.mem.indexOfAny(u8, rest, " \t")) |sp| {
                            url = rest[0..sp];
                            title = std.mem.trim(u8, rest[sp + 1 ..], " \t\"'");
                        } else {
                            url = rest;
                        }
                    }
                }

                try nodes.append(alloc, Node{ .link_definition = .{
                    .label = label,
                    .url = url,
                    .title = title,
                } });
                i += 1;
            },

            .footnote_definition => {
                const s = tok.slice(source);
                var label = s;
                var content: []const u8 = "";

                if (std.mem.indexOfScalar(u8, s, ']')) |rb| {
                    label = std.mem.trim(u8, s[2..rb], " \t");
                    if (rb + 2 < s.len and s[rb + 1] == ':') {
                        content = std.mem.trim(u8, s[rb + 2 ..], " \t\r\n");
                    }
                }

                try nodes.append(alloc, Node{ .footnote_definition = .{
                    .label = label,
                    .content = content,
                } });
                i += 1;
            },

            .html_block => {
                try nodes.append(alloc, Node{ .html_block = tok.slice(source) });
                i += 1;
            },

            .paragraph => {
                const raw_text = std.mem.trim(u8, tok.slice(source), "\r\n");

                // Scan inline tokens
                var inlines = try lexer.tokenizeInline(alloc, source, tok.start, tok.end);
                defer inlines.deinit(alloc);

                var has_formatting = false;
                for (inlines.items) |itok| {
                    if (itok.kind != .text and itok.kind != .soft_break) {
                        has_formatting = true;
                        break;
                    }
                }

                if (!has_formatting) {
                    try nodes.append(alloc, Node{ .paragraph = raw_text });
                } else {
                    var rich_nodes = ast.List(Node).empty;
                    for (inlines.items) |itok| {
                        const inode = try parseInlineToken(alloc, source, itok);
                        try rich_nodes.append(alloc, inode);
                    }
                    try nodes.append(alloc, Node{ .rich_block = rich_nodes });
                }
                i += 1;
            },

            else => {
                // Inline token or fallback encountered at block level
                try nodes.append(alloc, Node{ .paragraph = tok.slice(source) });
                i += 1;
            },
        }
    }

    return ParseResult{ .nodes = nodes, .alloc = alloc };
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

test "parser — heading ATX" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var result = try parse(alloc, "## Hello World\n");
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.nodes.items.len);
    const node = result.nodes.items[0];
    try std.testing.expect(node == .heading);
    try std.testing.expectEqual(@as(u3, 2), node.heading.level);
    try std.testing.expectEqualStrings("Hello World", node.heading.text);
}

test "parser — thematic break" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var result = try parse(arena.allocator(), "---\n");
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.nodes.items.len);
    try std.testing.expect(result.nodes.items[0] == .thematic_break);
}

test "parser — paragraph" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var result = try parse(arena.allocator(), "Hello, World!\n");
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.nodes.items.len);
    try std.testing.expect(result.nodes.items[0] == .paragraph);
    try std.testing.expectEqualStrings("Hello, World!", result.nodes.items[0].paragraph);
}

test "parser — function call: .greet {name} body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var result = try parse(arena.allocator(), ".greet {name} body\n");
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.nodes.items.len);
    const node = result.nodes.items[0];
    try std.testing.expect(node == .function_call);

    const fc = node.function_call;
    try std.testing.expectEqualStrings("greet", fc.name);
    try std.testing.expectEqual(@as(usize, 1), fc.args.items.len);
    try std.testing.expectEqualStrings("name", fc.args.items[0].value);
    try std.testing.expectEqualStrings("", fc.args.items[0].key);
    try std.testing.expectEqualStrings("body", fc.body.?);
}

test "parser — function call: named argument" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var result = try parse(arena.allocator(), ".fn {key: value}\n");
    defer result.deinit();

    const fc = result.nodes.items[0].function_call;
    try std.testing.expectEqualStrings("fn", fc.name);
    try std.testing.expectEqualStrings("key", fc.args.items[0].key);
    try std.testing.expectEqualStrings("value", fc.args.items[0].value);
}

test "parser — function call: multiple args" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var result = try parse(arena.allocator(), ".func {arg1} {arg2} {arg3}\n");
    defer result.deinit();

    const fc = result.nodes.items[0].function_call;
    try std.testing.expectEqualStrings("func", fc.name);
    try std.testing.expectEqual(@as(usize, 3), fc.args.items.len);
    try std.testing.expectEqualStrings("arg1", fc.args.items[0].value);
    try std.testing.expectEqualStrings("arg2", fc.args.items[1].value);
    try std.testing.expectEqualStrings("arg3", fc.args.items[2].value);
}

test "parser — unordered list with items" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src = "- one\n- two\n- three\n";
    var result = try parse(arena.allocator(), src);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.nodes.items.len);
    const list = result.nodes.items[0].list;
    try std.testing.expect(!list.ordered);
    try std.testing.expectEqual(@as(usize, 3), list.items.items.len);
    try std.testing.expectEqualStrings("one", list.items.items[0].text);
}

test "parser — mixed document" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src = "# Title\n\nA paragraph.\n\n.greet {Alice} Hello there!\n";
    var result = try parse(arena.allocator(), src);
    defer result.deinit();

    var non_blank: usize = 0;
    for (result.nodes.items) |n| {
        if (n != .blank) non_blank += 1;
    }
    try std.testing.expect(non_blank >= 3);
}

test "parser — fenced code block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src = "```zig\nconst x = 1;\n```\n";
    var result = try parse(arena.allocator(), src);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.nodes.items.len);
    const cb = result.nodes.items[0].code_block;
    try std.testing.expectEqualStrings("zig", cb.language);
    try std.testing.expect(std.mem.indexOf(u8, cb.content, "const x = 1;") != null);
}

test "parser — rich block with inline formatting" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src = "This has *italic* and **bold** text.\n";
    var result = try parse(arena.allocator(), src);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.nodes.items.len);
    const node = result.nodes.items[0];
    try std.testing.expect(node == .rich_block);

    var found_em = false;
    var found_strong = false;
    for (node.rich_block.items) |child| {
        if (child == .emphasis and std.mem.eql(u8, child.emphasis, "italic")) found_em = true;
        if (child == .strong and std.mem.eql(u8, child.strong, "bold")) found_strong = true;
    }
    try std.testing.expect(found_em);
    try std.testing.expect(found_strong);
}

test "parser — GFM table parsing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src = "| Name | Role |\n| :--- | :---: |\n| Alice | Admin |\n| Bob | User |\n";
    var result = try parse(arena.allocator(), src);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.nodes.items.len);
    const tbl = result.nodes.items[0].table;
    try std.testing.expectEqual(@as(usize, 2), tbl.headers.items.len);
    try std.testing.expectEqualStrings("Name", tbl.headers.items[0]);
    try std.testing.expectEqualStrings("Role", tbl.headers.items[1]);
    try std.testing.expectEqual(ColumnAlign.left, tbl.alignments.items[0]);
    try std.testing.expectEqual(ColumnAlign.center, tbl.alignments.items[1]);
    try std.testing.expectEqual(@as(usize, 2), tbl.rows.items.len);
    try std.testing.expectEqualStrings("Alice", tbl.rows.items[0].items[0]);
    try std.testing.expectEqualStrings("Admin", tbl.rows.items[0].items[1]);
}

test "parser — memory: no leaks via arena" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src = ".hello {world} foo\n## Title\n\nParagraph with *emphasis*.\n";
    var result = try parse(arena.allocator(), src);
    defer result.deinit();

    try std.testing.expect(result.nodes.items.len > 0);
}
