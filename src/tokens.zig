//! tokens.zig — Token definitions for the Quarkdown zero-copy lexer.
//!
//! Every token stores byte offsets (start, end) into the original source buffer.
//! No string data is allocated during tokenization.

const std = @import("std");

/// Classification of tokens emitted by the block and inline lexers.
pub const TokenKind = enum {
    // ── Block-level tokens ──────────────────────────────────────────────────
    heading, // ATX (#..######) or Setext (=== / ---)
    thematic_break, // ---, ***, ___
    fenced_code, // ``` ... ``` or ~~~ ... ~~~
    indented_code, // 4-space or tab indented block
    blockquote, // > blockquote lines
    list_item, // unordered (- * +) or ordered (1. 1)) item
    blank, // empty or whitespace-only line
    paragraph, // regular text block
    html_block, // <tag>...</tag>, <!-- -->, etc.
    table_row, // | col1 | col2 |
    link_definition, // [label]: url "title"
    footnote_definition, // [^label]: footnote text
    function_call_block, // .fn {arg} body at block level
    math_block, // $$ ... $$ or .math block

    // ── Inline-level tokens ─────────────────────────────────────────────────
    text, // plain text segment
    soft_break, // newline in text block
    hard_break, // double space + newline or \ + newline
    code_span, // `code`
    emphasis, // *em* or _em_
    strong, // **strong** or __strong__
    strikethrough, // ~~strike~~
    link, // [text](url) or [text][ref]
    image, // ![alt](url)
    auto_link, // <https://...> or <user@example.com>
    html_inline, // <span>...</span>
    math_span, // $expr$
    function_call_inline, // .fn {arg} inline

    eof,

    pub fn isBlock(self: TokenKind) bool {
        return switch (self) {
            .heading,
            .thematic_break,
            .fenced_code,
            .indented_code,
            .blockquote,
            .list_item,
            .blank,
            .paragraph,
            .html_block,
            .table_row,
            .link_definition,
            .footnote_definition,
            .function_call_block,
            .math_block,
            => true,
            else => false,
        };
    }

    pub fn isInline(self: TokenKind) bool {
        return !self.isBlock() and self != .eof;
    }

    pub fn name(self: TokenKind) []const u8 {
        return @tagName(self);
    }
};

/// Extra metadata payload for kind-specific token details.
pub const Extra = union {
    none: void,

    heading: struct {
        level: u3, // 1..6
        is_setext: bool = false,
    },

    code_fence: struct {
        lang_start: u32,
        lang_end: u32,
        fence_char: u8, // '`' or '~'
        fence_len: u8,
    },

    list_item: struct {
        ordered: bool,
        marker_char: u8, // '-', '*', '+', '.', ')'
        marker_start: u32,
        marker_end: u32,
        checked: ?bool, // null = normal, false = [ ], true = [x]
    },

    table_row: struct {
        is_delimiter: bool,
        col_count: u16,
    },

    link: struct {
        label_start: u32,
        label_end: u32,
        url_start: u32,
        url_end: u32,
        title_start: u32,
        title_end: u32,
    },

    function_call: struct {
        name_start: u32,
        name_end: u32,
        args_start: u32,
        args_end: u32,
    },
};

/// A zero-copy token pointing into the source byte slice.
pub const Token = struct {
    kind: TokenKind,
    start: u32,
    end: u32,
    extra: Extra = .{ .none = {} },

    /// Slice the source text spanning this token — strictly zero-copy.
    pub inline fn slice(self: Token, src: []const u8) []const u8 {
        if (self.start >= src.len or self.end > src.len or self.start > self.end) return "";
        return src[self.start..self.end];
    }

    /// Length in bytes of this token in the source buffer.
    pub inline fn len(self: Token) u32 {
        return if (self.end >= self.start) self.end - self.start else 0;
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

test "tokens — token slicing and kind categorization" {
    const src = "## Hello World\n";
    const tok = Token{
        .kind = .heading,
        .start = 0,
        .end = 14,
        .extra = .{ .heading = .{ .level = 2 } },
    };

    try std.testing.expect(tok.kind.isBlock());
    try std.testing.expect(!tok.kind.isInline());
    try std.testing.expectEqualStrings("## Hello World", tok.slice(src));
    try std.testing.expectEqual(@as(u3, 2), tok.extra.heading.level);
    try std.testing.expectEqual(@as(u32, 14), tok.len());
}

test "tokens — inline token classification" {
    const src = "This is *italic* and **bold**";
    const em_tok = Token{
        .kind = .emphasis,
        .start = 8,
        .end = 16,
    };
    try std.testing.expect(em_tok.kind.isInline());
    try std.testing.expectEqualStrings("*italic*", em_tok.slice(src));
}
