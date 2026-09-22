//! lexer.zig — Two-phase zero-copy tokenizer for Quarkdown.
//!
//! Mirrors JVM Quarkdown `LexingStage`:
//!   • Phase 1: Block tokenizer — emits block-level tokens (headings, lists, code, tables, etc.)
//!   • Phase 2: Inline tokenizer — scans within text-bearing blocks for inline formatting
//!
//! Zero-copy guarantee:
//! Every Token emitted stores only (start, end) byte indices into the original source.
//! No string memory is allocated during tokenization.

const std = @import("std");
const tokens = @import("tokens.zig");

const Allocator = std.mem.Allocator;
pub const Token = tokens.Token;
pub const TokenKind = tokens.TokenKind;
pub const Extra = tokens.Extra;

// ─────────────────────────────────────────────────────────────────────────────
// Character Classification Helpers
// ─────────────────────────────────────────────────────────────────────────────

pub inline fn isAsciiAlpha(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

pub inline fn isAsciiDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

pub inline fn isAsciiAlphanumeric(c: u8) bool {
    return isAsciiAlpha(c) or isAsciiDigit(c);
}

pub inline fn isIdentChar(c: u8) bool {
    return isAsciiAlphanumeric(c) or c == '_' or c == '-';
}

pub inline fn isSpaceOrTab(c: u8) bool {
    return c == ' ' or c == '\t';
}

// ─────────────────────────────────────────────────────────────────────────────
// Cursor state for scanning
// ─────────────────────────────────────────────────────────────────────────────

pub const Cursor = struct {
    src: []const u8,
    pos: usize,

    pub inline fn init(src: []const u8) Cursor {
        return .{ .src = src, .pos = 0 };
    }

    pub inline fn isEof(self: *const Cursor) bool {
        return self.pos >= self.src.len;
    }

    pub inline fn peek(self: *const Cursor) ?u8 {
        if (self.pos < self.src.len) return self.src[self.pos];
        return null;
    }

    pub inline fn peekAt(self: *const Cursor, offset: usize) ?u8 {
        const idx = self.pos + offset;
        if (idx < self.src.len) return self.src[idx];
        return null;
    }

    pub inline fn advance(self: *Cursor) void {
        if (self.pos < self.src.len) self.pos += 1;
    }

    pub inline fn skip(self: *Cursor, n: usize) void {
        self.pos = @min(self.pos + n, self.src.len);
    }

    pub fn skipSpaces(self: *Cursor) void {
        while (self.peek()) |c| {
            if (!isSpaceOrTab(c)) break;
            self.advance();
        }
    }

    pub fn consumeLine(self: *Cursor) []const u8 {
        const start = self.pos;
        while (self.peek()) |c| {
            if (c == '\n' or c == '\r') break;
            self.advance();
        }
        return self.src[start..self.pos];
    }

    pub fn consumeNewline(self: *Cursor) void {
        if (self.peek() == @as(?u8, '\r')) self.advance();
        if (self.peek() == @as(?u8, '\n')) self.advance();
    }

    pub fn matchPrefix(self: *const Cursor, pat: []const u8) bool {
        if (self.pos + pat.len > self.src.len) return false;
        return std.mem.eql(u8, self.src[self.pos .. self.pos + pat.len], pat);
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// Phase 1: Block Tokenizer
// ─────────────────────────────────────────────────────────────────────────────

pub const BlockLexer = struct {
    cur: Cursor,
    alloc: Allocator,

    pub fn init(alloc: Allocator, src: []const u8) BlockLexer {
        return .{
            .cur = Cursor.init(src),
            .alloc = alloc,
        };
    }

    /// Tokenize the entire source buffer into a sequence of block tokens.
    pub fn tokenize(self: *BlockLexer) !std.ArrayList(Token) {
        var list: std.ArrayList(Token) = .empty;
        errdefer list.deinit(self.alloc);

        while (!self.cur.isEof()) {
            if (try self.nextBlockToken()) |tok| {
                try list.append(self.alloc, tok);
            }
        }

        try list.append(self.alloc, Token{
            .kind = .eof,
            .start = @intCast(self.cur.src.len),
            .end = @intCast(self.cur.src.len),
        });

        return list;
    }

    fn nextBlockToken(self: *BlockLexer) !?Token {
        if (self.cur.isEof()) return null;

        const line_start = self.cur.pos;

        // Count leading spaces (up to 4 for indentation detection)
        var indent: usize = 0;
        var p = self.cur.pos;
        while (p < self.cur.src.len and self.cur.src[p] == ' ') : (p += 1) {
            indent += 1;
        }

        // Blank line check
        if (p >= self.cur.src.len or self.cur.src[p] == '\n' or self.cur.src[p] == '\r') {
            self.cur.pos = p;
            self.cur.consumeNewline();
            return Token{
                .kind = .blank,
                .start = @intCast(line_start),
                .end = @intCast(self.cur.pos),
            };
        }

        // Indented code block: 4 or more leading spaces (and not followed by blank)
        if (indent >= 4) {
            return self.scanIndentedCode();
        }

        // Advance cursor past leading spaces (up to 3)
        self.cur.skip(indent);
        const ch = self.cur.peek().?;

        // ATX Heading: `#` .. `######`
        if (ch == '#') {
            if (self.scanAtxHeading(line_start)) |tok| return tok;
        }

        // Fenced code block: ``` or ~~~
        if ((ch == '`' or ch == '~') and self.cur.peekAt(1) == ch and self.cur.peekAt(2) == ch) {
            return self.scanFencedCode(line_start, ch);
        }

        // Math block: `$$`
        if (ch == '$' and self.cur.peekAt(1) == '$') {
            return self.scanMathBlock(line_start);
        }

        // Thematic break: `---`, `***`, `___`
        if (self.isThematicBreak()) {
            return self.scanThematicBreak(line_start);
        }

        // Blockquote: `>`
        if (ch == '>') {
            return self.scanBlockquote(line_start);
        }

        // GFM Table row: starts with `|` or contains `|` with table delimiter
        if (ch == '|' or self.isTableRowStart()) {
            if (self.scanTableRow(line_start)) |tok| return tok;
        }

        // Unordered list item: `- `, `* `, `+ `
        if ((ch == '-' or ch == '*' or ch == '+') and self.cur.peekAt(1) == ' ') {
            return self.scanListItem(line_start, false, ch);
        }

        // Ordered list item: `1. ` or `1) `
        if (isAsciiDigit(ch) and self.isOrderedListMarker()) {
            return self.scanListItem(line_start, true, ch);
        }

        // Quarkdown Function call: `.ident`
        if (ch == '.' and self.cur.peekAt(1) != null and isAsciiAlpha(self.cur.peekAt(1).?)) {
            return self.scanFunctionCall(line_start);
        }

        // Footnote definition: `[^label]: `
        if (ch == '[' and self.cur.peekAt(1) == '^') {
            if (self.scanFootnoteDefinition(line_start)) |tok| return tok;
        }

        // Link reference definition: `[label]: `
        if (ch == '[') {
            if (self.scanLinkDefinition(line_start)) |tok| return tok;
        }

        // HTML block: `<div`, `<!--`, `<?`, etc.
        if (ch == '<' and self.isHtmlBlockStart()) {
            return self.scanHtmlBlock(line_start);
        }

        // Setext heading check or Paragraph fallback
        return self.scanParagraphOrSetext(line_start);
    }

    // ── ATX Heading ──────────────────────────────────────────────────────────

    fn scanAtxHeading(self: *BlockLexer, start: usize) ?Token {
        var level: u3 = 0;
        var p = self.cur.pos;
        while (p < self.cur.src.len and self.cur.src[p] == '#' and level < 6) : (p += 1) {
            level += 1;
        }

        // Must be followed by space, tab, newline, or EOF
        if (p < self.cur.src.len) {
            const next = self.cur.src[p];
            if (next != ' ' and next != '\t' and next != '\n' and next != '\r') {
                return null; // Not an ATX heading
            }
        }

        self.cur.pos = p;
        _ = self.cur.consumeLine();
        self.cur.consumeNewline();

        return Token{
            .kind = .heading,
            .start = @intCast(start),
            .end = @intCast(self.cur.pos),
            .extra = .{ .heading = .{ .level = level, .is_setext = false } },
        };
    }

    // ── Fenced Code ──────────────────────────────────────────────────────────

    fn scanFencedCode(self: *BlockLexer, start: usize, fence_char: u8) Token {
        var fence_len: u8 = 0;
        while (self.cur.peek() == @as(?u8, fence_char) and fence_len < 255) : (fence_len += 1) {
            self.cur.advance();
        }

        self.cur.skipSpaces();
        const lang_start = self.cur.pos;
        const line = self.cur.consumeLine();
        const lang_trimmed = std.mem.trim(u8, line, " \t");
        const lang_end = lang_start + lang_trimmed.len;
        self.cur.consumeNewline();

        // Scan until matching closing fence or EOF
        while (!self.cur.isEof()) {
            const line_pos = self.cur.pos;
            var line_indent: usize = 0;
            while (self.cur.peek() == @as(?u8, ' ') and line_indent < 3) : (line_indent += 1) {
                self.cur.advance();
            }

            var close_len: u8 = 0;
            while (self.cur.peek() == @as(?u8, fence_char) and close_len < 255) : (close_len += 1) {
                self.cur.advance();
            }

            if (close_len >= fence_len) {
                self.cur.skipSpaces();
                if (self.cur.peek() == @as(?u8, '\n') or self.cur.peek() == @as(?u8, '\r') or self.cur.isEof()) {
                    self.cur.consumeNewline();
                    break;
                }
            }

            // Not closing fence, resume line consumption
            self.cur.pos = line_pos;
            _ = self.cur.consumeLine();
            self.cur.consumeNewline();
        }

        return Token{
            .kind = .fenced_code,
            .start = @intCast(start),
            .end = @intCast(self.cur.pos),
            .extra = .{ .code_fence = .{
                .lang_start = @intCast(lang_start),
                .lang_end = @intCast(lang_end),
                .fence_char = fence_char,
                .fence_len = fence_len,
            } },
        };
    }

    // ── Math Block ───────────────────────────────────────────────────────────

    fn scanMathBlock(self: *BlockLexer, start: usize) Token {
        self.cur.skip(2); // consume `$$`
        _ = self.cur.consumeLine();
        self.cur.consumeNewline();

        while (!self.cur.isEof()) {
            const line_pos = self.cur.pos;
            self.cur.skipSpaces();
            if (self.cur.peek() == @as(?u8, '$') and self.cur.peekAt(1) == @as(?u8, '$')) {
                self.cur.skip(2);
                self.cur.skipSpaces();
                self.cur.consumeNewline();
                break;
            }
            self.cur.pos = line_pos;
            _ = self.cur.consumeLine();
            self.cur.consumeNewline();
        }

        return Token{
            .kind = .math_block,
            .start = @intCast(start),
            .end = @intCast(self.cur.pos),
        };
    }

    // ── Indented Code Block ──────────────────────────────────────────────────

    fn scanIndentedCode(self: *BlockLexer) Token {
        const start = self.cur.pos;

        while (!self.cur.isEof()) {
            var ind: usize = 0;
            var p = self.cur.pos;
            while (p < self.cur.src.len and self.cur.src[p] == ' ') : (p += 1) {
                ind += 1;
            }

            if (p < self.cur.src.len and (self.cur.src[p] == '\n' or self.cur.src[p] == '\r')) {
                // Blank line inside indented code
                self.cur.pos = p;
                self.cur.consumeNewline();
                continue;
            }

            if (ind < 4) break; // Not indented anymore

            self.cur.pos = p;
            _ = self.cur.consumeLine();
            self.cur.consumeNewline();
        }

        return Token{
            .kind = .indented_code,
            .start = @intCast(start),
            .end = @intCast(self.cur.pos),
        };
    }

    // ── Thematic Break ───────────────────────────────────────────────────────

    fn isThematicBreak(self: *const BlockLexer) bool {
        const ch = self.cur.peek() orelse return false;
        if (ch != '-' and ch != '*' and ch != '_') return false;

        var count: usize = 0;
        var p = self.cur.pos;
        while (p < self.cur.src.len and self.cur.src[p] != '\n' and self.cur.src[p] != '\r') : (p += 1) {
            const c = self.cur.src[p];
            if (isSpaceOrTab(c)) continue;
            if (c != ch) return false;
            count += 1;
        }
        return count >= 3;
    }

    fn scanThematicBreak(self: *BlockLexer, start: usize) Token {
        _ = self.cur.consumeLine();
        self.cur.consumeNewline();
        return Token{
            .kind = .thematic_break,
            .start = @intCast(start),
            .end = @intCast(self.cur.pos),
        };
    }

    // ── Blockquote ───────────────────────────────────────────────────────────

    fn scanBlockquote(self: *BlockLexer, start: usize) Token {
        while (!self.cur.isEof()) {
            self.cur.skipSpaces();
            if (self.cur.peek() == @as(?u8, '>')) {
                self.cur.advance();
                if (self.cur.peek() == @as(?u8, ' ')) self.cur.advance();
                _ = self.cur.consumeLine();
                self.cur.consumeNewline();
            } else {
                break;
            }
        }

        return Token{
            .kind = .blockquote,
            .start = @intCast(start),
            .end = @intCast(self.cur.pos),
        };
    }

    // ── List Item ────────────────────────────────────────────────────────────

    fn isOrderedListMarker(self: *const BlockLexer) bool {
        var p = self.cur.pos;
        var digits: usize = 0;
        while (p < self.cur.src.len and isAsciiDigit(self.cur.src[p]) and digits < 9) : (p += 1) {
            digits += 1;
        }
        if (digits == 0 or p >= self.cur.src.len) return false;
        const delim = self.cur.src[p];
        if (delim != '.' and delim != ')') return false;
        p += 1;
        return p < self.cur.src.len and (self.cur.src[p] == ' ' or self.cur.src[p] == '\t');
    }

    fn scanListItem(self: *BlockLexer, start: usize, ordered: bool, marker_char: u8) Token {
        const marker_start = self.cur.pos;

        if (ordered) {
            while (self.cur.peek()) |c| {
                if (!isAsciiDigit(c)) break;
                self.cur.advance();
            }
            self.cur.advance(); // '.' or ')'
        } else {
            self.cur.advance(); // '-' or '*' or '+'
        }

        const marker_end = self.cur.pos;
        self.cur.skipSpaces();

        // Check for task checkbox: `[ ] ` or `[x] `
        var checked: ?bool = null;
        if (self.cur.peek() == @as(?u8, '[') and self.cur.peekAt(2) == @as(?u8, ']') and self.cur.peekAt(3) == @as(?u8, ' ')) {
            const mark = self.cur.peekAt(1);
            if (mark == ' ') {
                checked = false;
                self.cur.skip(4);
            } else if (mark == 'x' or mark == 'X') {
                checked = true;
                self.cur.skip(4);
            }
        }

        _ = self.cur.consumeLine();
        self.cur.consumeNewline();

        return Token{
            .kind = .list_item,
            .start = @intCast(start),
            .end = @intCast(self.cur.pos),
            .extra = .{ .list_item = .{
                .ordered = ordered,
                .marker_char = marker_char,
                .marker_start = @intCast(marker_start),
                .marker_end = @intCast(marker_end),
                .checked = checked,
            } },
        };
    }

    // ── GFM Table Row ────────────────────────────────────────────────────────

    fn isTableRowStart(self: *const BlockLexer) bool {
        var p = self.cur.pos;
        var has_pipe = false;
        while (p < self.cur.src.len and self.cur.src[p] != '\n' and self.cur.src[p] != '\r') : (p += 1) {
            if (self.cur.src[p] == '|') {
                has_pipe = true;
                break;
            }
        }
        return has_pipe;
    }

    fn scanTableRow(self: *BlockLexer, start: usize) ?Token {
        const line_start = self.cur.pos;
        const line = self.cur.consumeLine();

        // Count columns and check if delimiter row
        var pipes: u16 = 0;
        var is_delim = true;
        var has_content = false;

        for (line) |c| {
            if (c == '|') {
                pipes += 1;
            } else if (c == '-' or c == ':' or isSpaceOrTab(c)) {
                if (c == '-') has_content = true;
            } else {
                is_delim = false;
            }
        }

        if (pipes == 0) {
            self.cur.pos = line_start;
            return null;
        }

        self.cur.consumeNewline();

        return Token{
            .kind = .table_row,
            .start = @intCast(start),
            .end = @intCast(self.cur.pos),
            .extra = .{ .table_row = .{
                .is_delimiter = is_delim and has_content and pipes >= 1,
                .col_count = pipes + 1,
            } },
        };
    }

    // ── Function Call Block ──────────────────────────────────────────────────

    fn scanFunctionCall(self: *BlockLexer, start: usize) Token {
        self.cur.advance(); // consume `.`
        const name_start = self.cur.pos;

        while (self.cur.peek()) |c| {
            if (!isIdentChar(c)) break;
            self.cur.advance();
        }
        const name_end = self.cur.pos;

        self.cur.skipSpaces();
        const args_start = self.cur.pos;

        // Scan brace-delimited arguments
        while (self.cur.peek() == @as(?u8, '{')) {
            self.cur.advance(); // `{`
            var depth: usize = 1;
            while (self.cur.peek()) |c| {
                if (c == '{') depth += 1;
                if (c == '}') {
                    depth -= 1;
                    if (depth == 0) {
                        self.cur.advance();
                        break;
                    }
                }
                if (c == '\n' or c == '\r') break;
                self.cur.advance();
            }
            self.cur.skipSpaces();
        }
        const args_end = self.cur.pos;

        _ = self.cur.consumeLine();
        self.cur.consumeNewline();

        return Token{
            .kind = .function_call_block,
            .start = @intCast(start),
            .end = @intCast(self.cur.pos),
            .extra = .{ .function_call = .{
                .name_start = @intCast(name_start),
                .name_end = @intCast(name_end),
                .args_start = @intCast(args_start),
                .args_end = @intCast(args_end),
            } },
        };
    }

    // ── Footnote & Link Definitions ──────────────────────────────────────────

    fn scanFootnoteDefinition(self: *BlockLexer, start: usize) ?Token {
        var p = self.cur.pos + 2; // skip `[^`
        while (p < self.cur.src.len and self.cur.src[p] != ']' and self.cur.src[p] != '\n') : (p += 1) {}
        if (p >= self.cur.src.len or self.cur.src[p] != ']') return null;
        p += 1; // skip `]`
        if (p >= self.cur.src.len or self.cur.src[p] != ':') return null;

        self.cur.pos = p + 1;
        _ = self.cur.consumeLine();
        self.cur.consumeNewline();

        return Token{
            .kind = .footnote_definition,
            .start = @intCast(start),
            .end = @intCast(self.cur.pos),
        };
    }

    fn scanLinkDefinition(self: *BlockLexer, start: usize) ?Token {
        var p = self.cur.pos + 1; // skip `[`
        while (p < self.cur.src.len and self.cur.src[p] != ']' and self.cur.src[p] != '\n') : (p += 1) {}
        if (p >= self.cur.src.len or self.cur.src[p] != ']') return null;
        p += 1; // skip `]`
        if (p >= self.cur.src.len or self.cur.src[p] != ':') return null;

        self.cur.pos = p + 1;
        _ = self.cur.consumeLine();
        self.cur.consumeNewline();

        return Token{
            .kind = .link_definition,
            .start = @intCast(start),
            .end = @intCast(self.cur.pos),
        };
    }

    // ── HTML Block ───────────────────────────────────────────────────────────

    fn isHtmlBlockStart(self: *const BlockLexer) bool {
        const prefixes = [_][]const u8{
            "<script", "<pre",    "<style", "<table", "<div",
            "<p",      "<!--",    "<?",     "<!",     "<article",
            "<header", "<footer", "<nav",   "<aside", "<section",
        };
        for (prefixes) |pfx| {
            if (self.cur.matchPrefix(pfx)) return true;
        }
        return false;
    }

    fn scanHtmlBlock(self: *BlockLexer, start: usize) Token {
        while (!self.cur.isEof()) {
            if (self.cur.peek() == @as(?u8, '\n') or self.cur.peek() == @as(?u8, '\r')) {
                // Blank line ends the HTML block
                const p = self.cur.pos;
                self.cur.consumeNewline();
                if (self.cur.peek() == @as(?u8, '\n') or self.cur.peek() == @as(?u8, '\r') or self.cur.isEof()) {
                    self.cur.pos = p;
                    break;
                }
                continue;
            }
            _ = self.cur.consumeLine();
            self.cur.consumeNewline();
        }

        return Token{
            .kind = .html_block,
            .start = @intCast(start),
            .end = @intCast(self.cur.pos),
        };
    }

    // ── Paragraph / Setext Heading ───────────────────────────────────────────

    fn scanParagraphOrSetext(self: *BlockLexer, start: usize) Token {
        const text_start = start;
        _ = self.cur.consumeLine();
        self.cur.consumeNewline();

        // Check if the next line is a Setext underline (`===...` or `---...`)
        if (!self.cur.isEof()) {
            const next_p = self.cur.pos;
            const next_ch = self.cur.peek();
            if (next_ch == @as(?u8, '=') or next_ch == @as(?u8, '-')) {
                const marker = next_ch.?;
                var count: usize = 0;
                var p = next_p;
                while (p < self.cur.src.len and self.cur.src[p] == marker) : (p += 1) {
                    count += 1;
                }
                while (p < self.cur.src.len and isSpaceOrTab(self.cur.src[p])) : (p += 1) {}
                if (count >= 1 and (p >= self.cur.src.len or self.cur.src[p] == '\n' or self.cur.src[p] == '\r')) {
                    // Setext Heading!
                    self.cur.pos = p;
                    self.cur.consumeNewline();
                    return Token{
                        .kind = .heading,
                        .start = @intCast(text_start),
                        .end = @intCast(self.cur.pos),
                        .extra = .{ .heading = .{
                            .level = if (marker == '=') 1 else 2,
                            .is_setext = true,
                        } },
                    };
                }
            }
        }

        // Regular paragraph: consume continuation lines until blank line or block start
        while (!self.cur.isEof()) {
            if (self.cur.peek() == @as(?u8, '\n') or self.cur.peek() == @as(?u8, '\r')) break;

            // Stop if next line starts a new block
            const ch = self.cur.peek().?;
            if (ch == '#' or ch == '>' or ch == '`' or ch == '~') break;
            if (ch == '.' and self.cur.peekAt(1) != null and isAsciiAlpha(self.cur.peekAt(1).?)) break;
            if (self.isThematicBreak()) break;

            _ = self.cur.consumeLine();
            self.cur.consumeNewline();
        }

        return Token{
            .kind = .paragraph,
            .start = @intCast(start),
            .end = @intCast(self.cur.pos),
        };
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// Phase 2: Inline Tokenizer
// ─────────────────────────────────────────────────────────────────────────────

pub const InlineLexer = struct {
    src: []const u8,
    pos: usize,
    end: usize,
    alloc: Allocator,

    pub fn init(alloc: Allocator, src: []const u8, start: u32, end: u32) InlineLexer {
        return .{
            .src = src,
            .pos = start,
            .end = @min(@as(usize, end), src.len),
            .alloc = alloc,
        };
    }

    /// Tokenize the inline content slice into inline tokens.
    pub fn tokenize(self: *InlineLexer) !std.ArrayList(Token) {
        var list: std.ArrayList(Token) = .empty;
        errdefer list.deinit(self.alloc);

        var text_start = self.pos;

        while (self.pos < self.end) {
            const ch = self.src[self.pos];

            // 1. Code span: `code` or ``code``
            if (ch == '`') {
                if (self.scanCodeSpan()) |tok| {
                    try self.flushText(&list, text_start, tok.start);
                    try list.append(self.alloc, tok);
                    text_start = self.pos;
                    continue;
                }
            }

            // 2. Math span: $expr$ or $$expr$$
            if (ch == '$') {
                if (self.scanMathSpan()) |tok| {
                    try self.flushText(&list, text_start, tok.start);
                    try list.append(self.alloc, tok);
                    text_start = self.pos;
                    continue;
                }
            }

            // 3. Inline function call: .ident{args} or .ident {args}
            if (ch == '.' and self.pos + 1 < self.end and isAsciiAlpha(self.src[self.pos + 1])) {
                // Preceded by start of inline or whitespace or punctuation
                const is_call_start = self.pos == text_start or isSpaceOrTab(self.src[self.pos - 1]);
                if (is_call_start) {
                    if (self.scanInlineFunctionCall()) |tok| {
                        try self.flushText(&list, text_start, tok.start);
                        try list.append(self.alloc, tok);
                        text_start = self.pos;
                        continue;
                    }
                }
            }

            // 4. Image: ![alt](url)
            if (ch == '!' and self.pos + 1 < self.end and self.src[self.pos + 1] == '[') {
                if (self.scanLinkOrImage(true)) |tok| {
                    try self.flushText(&list, text_start, tok.start);
                    try list.append(self.alloc, tok);
                    text_start = self.pos;
                    continue;
                }
            }

            // 5. Link: [text](url)
            if (ch == '[') {
                if (self.scanLinkOrImage(false)) |tok| {
                    try self.flushText(&list, text_start, tok.start);
                    try list.append(self.alloc, tok);
                    text_start = self.pos;
                    continue;
                }
            }

            // 6. Autolink: <http...> or <mailto...>
            if (ch == '<') {
                if (self.scanAutolinkOrHtml()) |tok| {
                    try self.flushText(&list, text_start, tok.start);
                    try list.append(self.alloc, tok);
                    text_start = self.pos;
                    continue;
                }
            }

            // 7. Strong / Emphasis: **bold** or *italic* or __bold__ or _italic_
            if (ch == '*' or ch == '_') {
                if (self.scanEmphasisOrStrong()) |tok| {
                    try self.flushText(&list, text_start, tok.start);
                    try list.append(self.alloc, tok);
                    text_start = self.pos;
                    continue;
                }
            }

            // 8. Strikethrough: ~~del~~
            if (ch == '~' and self.pos + 1 < self.end and self.src[self.pos + 1] == '~') {
                if (self.scanStrikethrough()) |tok| {
                    try self.flushText(&list, text_start, tok.start);
                    try list.append(self.alloc, tok);
                    text_start = self.pos;
                    continue;
                }
            }

            // 9. Line breaks: hard break (`  \n` or `\\n`) or soft break (`\n`)
            if (ch == '\n') {
                const is_hard = (self.pos >= 2 and self.src[self.pos - 1] == ' ' and self.src[self.pos - 2] == ' ') or
                    (self.pos >= 1 and self.src[self.pos - 1] == '\\');

                const tok_start = if (is_hard and self.pos >= 1 and self.src[self.pos - 1] == '\\') self.pos - 1 else self.pos;
                try self.flushText(&list, text_start, tok_start);
                self.pos += 1;
                try list.append(self.alloc, Token{
                    .kind = if (is_hard) .hard_break else .soft_break,
                    .start = @intCast(tok_start),
                    .end = @intCast(self.pos),
                });
                text_start = self.pos;
                continue;
            }

            self.pos += 1;
        }

        try self.flushText(&list, text_start, self.end);
        return list;
    }

    fn flushText(self: *InlineLexer, list: *std.ArrayList(Token), start: usize, end: usize) !void {
        if (end > start) {
            try list.append(self.alloc, Token{
                .kind = .text,
                .start = @intCast(start),
                .end = @intCast(end),
            });
        }
    }

    // ── Code Span ────────────────────────────────────────────────────────────

    fn scanCodeSpan(self: *InlineLexer) ?Token {
        const start = self.pos;
        var fence_len: usize = 0;
        while (self.pos < self.end and self.src[self.pos] == '`') : (self.pos += 1) {
            fence_len += 1;
        }

        // Search for matching closing fence of exact same length
        var p = self.pos;
        while (p < self.end) {
            if (self.src[p] == '`') {
                var close_len: usize = 0;
                while (p + close_len < self.end and self.src[p + close_len] == '`') : (close_len += 1) {}
                if (close_len == fence_len) {
                    self.pos = p + close_len;
                    return Token{
                        .kind = .code_span,
                        .start = @intCast(start),
                        .end = @intCast(self.pos),
                    };
                }
                p += close_len;
            } else {
                p += 1;
            }
        }

        self.pos = start;
        return null;
    }

    // ── Math Span ────────────────────────────────────────────────────────────

    fn scanMathSpan(self: *InlineLexer) ?Token {
        const start = self.pos;
        const is_double = (self.pos + 1 < self.end and self.src[self.pos + 1] == '$');
        const delim_len: usize = if (is_double) 2 else 1;
        self.pos += delim_len;

        var p = self.pos;
        while (p < self.end) {
            if (self.src[p] == '$') {
                if (is_double) {
                    if (p + 1 < self.end and self.src[p + 1] == '$') {
                        self.pos = p + 2;
                        return Token{
                            .kind = .math_span,
                            .start = @intCast(start),
                            .end = @intCast(self.pos),
                        };
                    }
                    p += 1;
                } else {
                    self.pos = p + 1;
                    return Token{
                        .kind = .math_span,
                        .start = @intCast(start),
                        .end = @intCast(self.pos),
                    };
                }
            } else {
                p += 1;
            }
        }

        self.pos = start;
        return null;
    }

    // ── Inline Function Call ─────────────────────────────────────────────────

    fn scanInlineFunctionCall(self: *InlineLexer) ?Token {
        const start = self.pos;
        self.pos += 1; // consume `.`

        const name_start = self.pos;
        while (self.pos < self.end and isIdentChar(self.src[self.pos])) : (self.pos += 1) {}
        const name_end = self.pos;

        // Skip horizontal spaces
        while (self.pos < self.end and isSpaceOrTab(self.src[self.pos])) : (self.pos += 1) {}
        const args_start = self.pos;

        // Collect argument blocks `{...}`
        var has_args = false;
        while (self.pos < self.end and self.src[self.pos] == '{') {
            has_args = true;
            self.pos += 1;
            var depth: usize = 1;
            while (self.pos < self.end) : (self.pos += 1) {
                if (self.src[self.pos] == '{') depth += 1;
                if (self.src[self.pos] == '}') {
                    depth -= 1;
                    if (depth == 0) {
                        self.pos += 1;
                        break;
                    }
                }
            }
            // Only consume inter-argument whitespace if another argument block follows
            var peek = self.pos;
            while (peek < self.end and isSpaceOrTab(self.src[peek])) : (peek += 1) {}
            if (peek < self.end and self.src[peek] == '{') {
                self.pos = peek;
            }
        }
        const args_end = self.pos;

        // Inline function call must either have arguments or be a recognised standalone function
        if (!has_args and name_end == name_start) {
            self.pos = start;
            return null;
        }

        return Token{
            .kind = .function_call_inline,
            .start = @intCast(start),
            .end = @intCast(self.pos),
            .extra = .{ .function_call = .{
                .name_start = @intCast(name_start),
                .name_end = @intCast(name_end),
                .args_start = @intCast(args_start),
                .args_end = @intCast(args_end),
            } },
        };
    }

    // ── Link or Image ────────────────────────────────────────────────────────

    fn scanLinkOrImage(self: *InlineLexer, is_image: bool) ?Token {
        const start = self.pos;
        if (is_image) self.pos += 1; // skip `!`
        self.pos += 1; // skip `[`

        const label_start = self.pos;
        var depth: usize = 1;
        while (self.pos < self.end) : (self.pos += 1) {
            if (self.src[self.pos] == '[') depth += 1;
            if (self.src[self.pos] == ']') {
                depth -= 1;
                if (depth == 0) break;
            }
        }
        if (self.pos >= self.end or self.src[self.pos] != ']') {
            self.pos = start;
            return null;
        }
        const label_end = self.pos;
        self.pos += 1; // consume `]`

        // Check for inline destination `(url)`
        if (self.pos < self.end and self.src[self.pos] == '(') {
            self.pos += 1;
            while (self.pos < self.end and isSpaceOrTab(self.src[self.pos])) : (self.pos += 1) {}

            const url_start = self.pos;
            while (self.pos < self.end and self.src[self.pos] != ')' and !isSpaceOrTab(self.src[self.pos])) : (self.pos += 1) {}
            const url_end = self.pos;

            while (self.pos < self.end and isSpaceOrTab(self.src[self.pos])) : (self.pos += 1) {}
            var title_start: usize = self.pos;
            var title_end: usize = self.pos;

            if (self.pos < self.end and (self.src[self.pos] == '"' or self.src[self.pos] == '\'')) {
                const quote = self.src[self.pos];
                self.pos += 1;
                title_start = self.pos;
                while (self.pos < self.end and self.src[self.pos] != quote) : (self.pos += 1) {}
                title_end = self.pos;
                if (self.pos < self.end and self.src[self.pos] == quote) self.pos += 1;
            }

            while (self.pos < self.end and isSpaceOrTab(self.src[self.pos])) : (self.pos += 1) {}
            if (self.pos < self.end and self.src[self.pos] == ')') {
                self.pos += 1;
                return Token{
                    .kind = if (is_image) .image else .link,
                    .start = @intCast(start),
                    .end = @intCast(self.pos),
                    .extra = .{ .link = .{
                        .label_start = @intCast(label_start),
                        .label_end = @intCast(label_end),
                        .url_start = @intCast(url_start),
                        .url_end = @intCast(url_end),
                        .title_start = @intCast(title_start),
                        .title_end = @intCast(title_end),
                    } },
                };
            }
        }

        self.pos = start;
        return null;
    }

    // ── Autolink or HTML Inline ──────────────────────────────────────────────

    fn scanAutolinkOrHtml(self: *InlineLexer) ?Token {
        const start = self.pos;
        self.pos += 1; // skip `<`

        // Check for autolink URL `<http...>` or `<user@...>`
        var is_url = false;
        if (self.pos + 7 < self.end and std.mem.eql(u8, self.src[self.pos .. self.pos + 7], "http://")) is_url = true;
        if (self.pos + 8 < self.end and std.mem.eql(u8, self.src[self.pos .. self.pos + 8], "https://")) is_url = true;
        if (self.pos + 7 < self.end and std.mem.eql(u8, self.src[self.pos .. self.pos + 7], "mailto:")) is_url = true;

        while (self.pos < self.end and self.src[self.pos] != '>') : (self.pos += 1) {
            if (self.src[self.pos] == '@') is_url = true;
            if (self.src[self.pos] == '\n' or self.src[self.pos] == ' ') break;
        }

        if (self.pos < self.end and self.src[self.pos] == '>') {
            self.pos += 1;
            return Token{
                .kind = if (is_url) .auto_link else .html_inline,
                .start = @intCast(start),
                .end = @intCast(self.pos),
            };
        }

        self.pos = start;
        return null;
    }

    // ── Emphasis or Strong ───────────────────────────────────────────────────

    fn scanEmphasisOrStrong(self: *InlineLexer) ?Token {
        const start = self.pos;
        const delim = self.src[self.pos];
        var delim_len: usize = 0;
        while (self.pos < self.end and self.src[self.pos] == delim and delim_len < 3) : (self.pos += 1) {
            delim_len += 1;
        }

        if (delim_len == 0) return null;

        // Search for closing delimiter run of the same character and length
        var p = self.pos;
        while (p < self.end) {
            if (self.src[p] == delim) {
                var close_len: usize = 0;
                while (p + close_len < self.end and self.src[p + close_len] == delim) : (close_len += 1) {}
                if (close_len >= delim_len) {
                    self.pos = p + delim_len;
                    return Token{
                        .kind = if (delim_len >= 2) .strong else .emphasis,
                        .start = @intCast(start),
                        .end = @intCast(self.pos),
                    };
                }
                p += close_len;
            } else {
                p += 1;
            }
        }

        self.pos = start;
        return null;
    }

    // ── Strikethrough ────────────────────────────────────────────────────────

    fn scanStrikethrough(self: *InlineLexer) ?Token {
        const start = self.pos;
        self.pos += 2; // skip `~~`

        var p = self.pos;
        while (p + 1 < self.end) {
            if (self.src[p] == '~' and self.src[p + 1] == '~') {
                self.pos = p + 2;
                return Token{
                    .kind = .strikethrough,
                    .start = @intCast(start),
                    .end = @intCast(self.pos),
                };
            }
            p += 1;
        }

        self.pos = start;
        return null;
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// Public Entry Points
// ─────────────────────────────────────────────────────────────────────────────

/// Phase 1: Scan block tokens.
pub fn tokenizeBlocks(alloc: Allocator, src: []const u8) !std.ArrayList(Token) {
    var lexer = BlockLexer.init(alloc, src);
    return try lexer.tokenize();
}

/// Phase 2: Scan inline tokens within a byte range of the source.
pub fn tokenizeInline(alloc: Allocator, src: []const u8, start: u32, end: u32) !std.ArrayList(Token) {
    var lexer = InlineLexer.init(alloc, src, start, end);
    return try lexer.tokenize();
}

// ─────────────────────────────────────────────────────────────────────────────
// Unit Tests
// ─────────────────────────────────────────────────────────────────────────────

test "lexer — block: ATX headings" {
    const src = "# Heading 1\n## Heading 2\n### Heading 3\n";
    var tokens_list = try tokenizeBlocks(std.testing.allocator, src);
    defer tokens_list.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 4), tokens_list.items.len); // 3 headings + eof
    try std.testing.expectEqual(TokenKind.heading, tokens_list.items[0].kind);
    try std.testing.expectEqual(@as(u3, 1), tokens_list.items[0].extra.heading.level);
    try std.testing.expectEqual(TokenKind.heading, tokens_list.items[1].kind);
    try std.testing.expectEqual(@as(u3, 2), tokens_list.items[1].extra.heading.level);
    try std.testing.expectEqual(TokenKind.heading, tokens_list.items[2].kind);
    try std.testing.expectEqual(@as(u3, 3), tokens_list.items[2].extra.heading.level);
    try std.testing.expectEqual(TokenKind.eof, tokens_list.items[3].kind);
}

test "lexer — block: Setext headings" {
    const src = "Setext Level 1\n==============\n\nSetext Level 2\n--------------\n";
    var tokens_list = try tokenizeBlocks(std.testing.allocator, src);
    defer tokens_list.deinit(std.testing.allocator);

    try std.testing.expectEqual(TokenKind.heading, tokens_list.items[0].kind);
    try std.testing.expectEqual(@as(u3, 1), tokens_list.items[0].extra.heading.level);
    try std.testing.expect(tokens_list.items[0].extra.heading.is_setext);

    try std.testing.expectEqual(TokenKind.blank, tokens_list.items[1].kind);

    try std.testing.expectEqual(TokenKind.heading, tokens_list.items[2].kind);
    try std.testing.expectEqual(@as(u3, 2), tokens_list.items[2].extra.heading.level);
    try std.testing.expect(tokens_list.items[2].extra.heading.is_setext);
}

test "lexer — block: Fenced code block" {
    const src = "```zig\nconst x = 42;\n```\n";
    var tokens_list = try tokenizeBlocks(std.testing.allocator, src);
    defer tokens_list.deinit(std.testing.allocator);

    try std.testing.expectEqual(TokenKind.fenced_code, tokens_list.items[0].kind);
    const fc = tokens_list.items[0].extra.code_fence;
    try std.testing.expectEqualStrings("zig", src[fc.lang_start..fc.lang_end]);
    try std.testing.expectEqual(@as(u8, '`'), fc.fence_char);
    try std.testing.expectEqual(@as(u8, 3), fc.fence_len);
}

test "lexer — block: Function call block" {
    const src = ".docname {My Document}\n.box {Important} Note text\n";
    var tokens_list = try tokenizeBlocks(std.testing.allocator, src);
    defer tokens_list.deinit(std.testing.allocator);

    try std.testing.expectEqual(TokenKind.function_call_block, tokens_list.items[0].kind);
    const fn1 = tokens_list.items[0].extra.function_call;
    try std.testing.expectEqualStrings("docname", src[fn1.name_start..fn1.name_end]);

    try std.testing.expectEqual(TokenKind.function_call_block, tokens_list.items[1].kind);
    const fn2 = tokens_list.items[1].extra.function_call;
    try std.testing.expectEqualStrings("box", src[fn2.name_start..fn2.name_end]);
}

test "lexer — block: GFM Table and Delimiter" {
    const src = "| Title | Author |\n| :--- | :---: |\n| Book | Person |\n";
    var tokens_list = try tokenizeBlocks(std.testing.allocator, src);
    defer tokens_list.deinit(std.testing.allocator);

    try std.testing.expectEqual(TokenKind.table_row, tokens_list.items[0].kind);
    try std.testing.expect(!tokens_list.items[0].extra.table_row.is_delimiter);

    try std.testing.expectEqual(TokenKind.table_row, tokens_list.items[1].kind);
    try std.testing.expect(tokens_list.items[1].extra.table_row.is_delimiter);

    try std.testing.expectEqual(TokenKind.table_row, tokens_list.items[2].kind);
    try std.testing.expect(!tokens_list.items[2].extra.table_row.is_delimiter);
}

test "lexer — block: Lists with task items" {
    const src = "- [ ] Task 1\n- [x] Task 2 completed\n1. First item\n";
    var tokens_list = try tokenizeBlocks(std.testing.allocator, src);
    defer tokens_list.deinit(std.testing.allocator);

    try std.testing.expectEqual(TokenKind.list_item, tokens_list.items[0].kind);
    try std.testing.expectEqual(@as(?bool, false), tokens_list.items[0].extra.list_item.checked);

    try std.testing.expectEqual(TokenKind.list_item, tokens_list.items[1].kind);
    try std.testing.expectEqual(@as(?bool, true), tokens_list.items[1].extra.list_item.checked);

    try std.testing.expectEqual(TokenKind.list_item, tokens_list.items[2].kind);
    try std.testing.expect(tokens_list.items[2].extra.list_item.ordered);
}

test "lexer — inline: formatting, links, math, and inline function calls" {
    const src = "Hello *world*, this is **bold**, ~~strike~~, `code`, and $E=mc^2$ with [link](https://example.com) and .bold {quoted} text.";
    var tokens_list = try tokenizeInline(std.testing.allocator, src, 0, @intCast(src.len));
    defer tokens_list.deinit(std.testing.allocator);

    // Look for our expected tokens in sequence
    var has_em = false;
    var has_strong = false;
    var has_strike = false;
    var has_code = false;
    var has_math = false;
    var has_link = false;
    var has_fn = false;

    for (tokens_list.items) |tok| {
        switch (tok.kind) {
            .emphasis => has_em = std.mem.eql(u8, tok.slice(src), "*world*"),
            .strong => has_strong = std.mem.eql(u8, tok.slice(src), "**bold**"),
            .strikethrough => has_strike = std.mem.eql(u8, tok.slice(src), "~~strike~~"),
            .code_span => has_code = std.mem.eql(u8, tok.slice(src), "`code`"),
            .math_span => has_math = std.mem.eql(u8, tok.slice(src), "$E=mc^2$"),
            .link => has_link = std.mem.eql(u8, tok.slice(src), "[link](https://example.com)"),
            .function_call_inline => has_fn = std.mem.startsWith(u8, tok.slice(src), ".bold"),
            else => {},
        }
    }

    try std.testing.expect(has_em);
    try std.testing.expect(has_strong);
    try std.testing.expect(has_strike);
    try std.testing.expect(has_code);
    try std.testing.expect(has_math);
    try std.testing.expect(has_link);
    try std.testing.expect(has_fn);
}
