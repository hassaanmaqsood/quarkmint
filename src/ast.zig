//! ast.zig — Quarkdown Abstract Syntax Tree
//!
//! All string fields are zero-copy slices into the original source buffer.
//! The AST lives entirely inside an ArenaAllocator; every allocation is freed
//! in a single O(1) deinit() call, with no per-node destructor overhead.
//!
//! Design choices:
//!   • `Node` is a tagged union (union(enum)) — no vtable, tight packing,
//!     cache-friendly traversal.
//!   • `Scope` is an intrusive linked list; each scope holds a StringHashMap
//!     of bindings.  Variable lookup walks parent pointers O(depth).
//!   • `FunctionCall` stores args in an ArrayList (ordered, so positional args
//!     are preserved).
//!
//! Zig 0.16 notes:
//!   • std.ArrayList(T) is now unmanaged (no stored allocator).  All mutation
//!     methods require an explicit `gpa: Allocator` argument.
//!   • std.heap.GeneralPurposeAllocator is renamed std.heap.DebugAllocator.
//!   • std.StringHashMap remains managed (stores its own allocator).

const std = @import("std");
const Allocator = std.mem.Allocator;

// ─────────────────────────────────────────────────────────────────────────────
// Convenience alias — ArrayList is now unmanaged in Zig 0.16.
// We surface it as-is; callers must pass their allocator to every mutation.
// ─────────────────────────────────────────────────────────────────────────────
pub fn List(comptime T: type) type {
    return std.ArrayList(T);
}

// ─────────────────────────────────────────────────────────────────────────────
// Node types
// ─────────────────────────────────────────────────────────────────────────────

/// A key=value pair for named function arguments, e.g. `.fn {key: value}`.
/// `key` may be empty for positional args.
pub const Argument = struct {
    key: []const u8, // "" for positional
    value: []const u8,
};

/// Data carried by a Quarkdown function call node.
///
/// Example source:    `.greet {name} body text`
///   name  = "greet"
///   args  = [Argument{ .key = "", .value = "name" }]
///   body  = "body text"
pub const FunctionCallData = struct {
    /// Slice into source: the bare function name without the leading dot.
    name: []const u8,
    /// Positional and named arguments, in source order.
    /// Unmanaged: caller must supply allocator to append/deinit.
    args: List(Argument),
    /// Optional body (block content between the arg list and the next blank line).
    body: ?[]const u8,
    /// True if invoked inline mid-sentence: `.fn {arg}`
    is_inline: bool = false,

    /// Release the args list using the same allocator it was populated with.
    pub fn deinit(self: *FunctionCallData, alloc: Allocator) void {
        self.args.deinit(alloc);
    }
};

/// Data carried by a Heading node.
pub const HeadingData = struct {
    level: u3, // 1–6
    text: []const u8,
    is_setext: bool = false,
    id: ?[]const u8 = null, // for TOC and anchor slugs
};

/// An item in an ordered or unordered list.
pub const ListItem = struct {
    text: []const u8,
    checked: ?bool = null, // null for normal, false for [ ], true for [x]
};

/// Data carried by a List node (ordered or unordered).
pub const ListData = struct {
    ordered: bool,
    /// Unmanaged: caller must supply allocator to append/deinit.
    items: List(ListItem),

    pub fn deinit(self: *ListData, alloc: Allocator) void {
        self.items.deinit(alloc);
    }
};

/// Data carried by a Code block.
pub const CodeBlockData = struct {
    language: []const u8, // may be empty
    content: []const u8,
};

/// Data carried by an inline or reference link.
pub const LinkData = struct {
    text: []const u8,
    url: []const u8,
    title: []const u8 = "",
};

/// Data carried by an image node.
pub const ImageData = struct {
    alt: []const u8,
    url: []const u8,
    title: []const u8 = "",
};

/// Column alignment for GFM tables.
pub const ColumnAlign = enum {
    none,
    left,
    center,
    right,
};

/// Data carried by a GFM table.
pub const TableData = struct {
    headers: List([]const u8),
    alignments: List(ColumnAlign),
    rows: List(List([]const u8)),

    pub fn deinit(self: *TableData, alloc: Allocator) void {
        self.headers.deinit(alloc);
        self.alignments.deinit(alloc);
        for (self.rows.items) |*r| r.deinit(alloc);
        self.rows.deinit(alloc);
    }
};

/// Data carried by a link reference definition: `[label]: url "title"`
pub const LinkDefinitionData = struct {
    label: []const u8,
    url: []const u8,
    title: []const u8 = "",
};

/// Data carried by a footnote definition: `[^label]: footnote content`
pub const FootnoteData = struct {
    label: []const u8,
    content: []const u8,
};

/// Data carried by a Quarkdown container `.box {title} content` or `.info`, `.warning`, etc.
pub const BoxData = struct {
    kind: []const u8 = "",
    title: ?[]const u8 = null,
    content: []const u8,
};

/// Data carried by a Quarkdown layout `.row` or `.column`
pub const StackedKind = enum { row, column };
pub const StackedData = struct {
    kind: StackedKind,
    content: []const u8,
};

/// A parsing error embedded in the AST rather than returned as a Zig error.
/// This lets the Wasm module always produce output instead of panicking.
pub const ErrorData = struct {
    message: []const u8,
    /// 1-based line number in the source document.
    line: u32,
};

/// The central tagged union.  Every variant is a value type; the union lives
/// in arena memory so no heap allocation inside individual variants is needed
/// except for the ArrayList members of FunctionCallData, ListData, and TableData
/// (those also allocate from the same arena).
pub const Node = union(enum) {
    // ── Block-level variants ──
    text: []const u8,
    blank,
    code_span: []const u8,
    code_block: CodeBlockData,
    heading: HeadingData,
    paragraph: []const u8,
    rich_block: List(Node),
    blockquote: []const u8,
    thematic_break,
    list: ListData,
    function_call: FunctionCallData,
    line_break,
    soft_break,
    parse_error: ErrorData,

    // ── Inline-level variants ──
    emphasis: []const u8,
    strong: []const u8,
    strikethrough: []const u8,
    link: LinkData,
    image: ImageData,
    auto_link: []const u8,
    html_inline: []const u8,
    html_block: []const u8,
    math_span: []const u8,
    math_block: []const u8,

    // ── Table ──
    table: TableData,

    // ── Definitions ──
    link_definition: LinkDefinitionData,
    footnote_definition: FootnoteData,

    // ── Quarkdown layout / containers ──
    page_break,
    box: BoxData,
    stacked: StackedData,

    /// Recursively release any heap sub-allocations.
    /// The arena allocator frees the node storage itself; this is for
    /// explicit ownership in non-arena contexts (e.g., tests).
    pub fn deinit(self: *Node, alloc: Allocator) void {
        switch (self.*) {
            .function_call => |*fc| fc.deinit(alloc),
            .list => |*l| l.deinit(alloc),
            .table => |*t| t.deinit(alloc),
            .rich_block => |*rb| {
                for (rb.items) |*child| child.deinit(alloc);
                rb.deinit(alloc);
            },
            else => {},
        }
    }

    /// Return a human-readable tag name for serialisation / debugging.
    pub fn tagName(self: Node) []const u8 {
        return @tagName(self);
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// Scope — variable / function binding environment
// ─────────────────────────────────────────────────────────────────────────────

/// A single scope frame.  Scopes form an intrusive linked list:
///   global ← module ← function-body ← loop-iteration …
///
/// std.StringHashMap remains managed (stores its own allocator internally),
/// so Scope.init / Scope.deinit do NOT need explicit allocator forwarding.
pub const Scope = struct {
    /// Bindings: variable name → value (both zero-copy slices into source).
    bindings: std.StringHashMap([]const u8),
    /// Enclosing scope.  Null for the root (global) scope.
    parent: ?*Scope,

    /// Allocate a new scope from `alloc`, linked to `parent`.
    pub fn init(alloc: Allocator, parent: ?*Scope) Scope {
        return .{
            .bindings = std.StringHashMap([]const u8).init(alloc),
            .parent = parent,
        };
    }

    /// Release the bindings hash map.
    pub fn deinit(self: *Scope) void {
        self.bindings.deinit();
    }

    /// Bind `name` → `value` in *this* scope frame.
    pub fn define(self: *Scope, name: []const u8, value: []const u8) !void {
        try self.bindings.put(name, value);
    }

    /// Walk the scope chain, returning the value bound to `name` or null.
    pub fn resolve(self: *const Scope, name: []const u8) ?[]const u8 {
        if (self.bindings.get(name)) |v| return v;
        if (self.parent) |p| return p.resolve(name);
        return null;
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

test "ast — Node tagged union sizes are sane" {
    // Ensure the union compiles and the tag field is present.
    const n: Node = .{ .text = "hello" };
    try std.testing.expectEqualStrings("text", n.tagName());

    const h: Node = .{ .heading = .{ .level = 2, .text = "World" } };
    try std.testing.expectEqualStrings("heading", h.tagName());
}

test "ast — Scope chain: child resolves parent bindings" {
    // Use std.testing.allocator to catch any leaks.
    const alloc = std.testing.allocator;

    var root = Scope.init(alloc, null);
    defer root.deinit();

    try root.define("x", "42");

    var child = Scope.init(alloc, &root);
    defer child.deinit();

    try child.define("y", "hello");

    // child can see both x (from parent) and y (local)
    try std.testing.expectEqualStrings("42", child.resolve("x").?);
    try std.testing.expectEqualStrings("hello", child.resolve("y").?);

    // parent cannot see y
    try std.testing.expectEqual(@as(?[]const u8, null), root.resolve("y"));
    // parent sees its own x
    try std.testing.expectEqualStrings("42", root.resolve("x").?);
}

test "ast — Scope shadowing: child binding hides parent" {
    const alloc = std.testing.allocator;

    var root = Scope.init(alloc, null);
    defer root.deinit();
    try root.define("x", "parent_value");

    var child = Scope.init(alloc, &root);
    defer child.deinit();
    try child.define("x", "child_value");

    try std.testing.expectEqualStrings("child_value", child.resolve("x").?);
    try std.testing.expectEqualStrings("parent_value", root.resolve("x").?);
}

test "ast — FunctionCallData lifecycle (no leaks)" {
    const alloc = std.testing.allocator;

    var fc = FunctionCallData{
        .name = "greet",
        .args = List(Argument).empty,
        .body = "body text",
    };
    defer fc.deinit(alloc);

    try fc.args.append(alloc, .{ .key = "", .value = "Alice" });
    try fc.args.append(alloc, .{ .key = "style", .value = "formal" });

    try std.testing.expectEqualStrings("greet", fc.name);
    try std.testing.expectEqual(@as(usize, 2), fc.args.items.len);
    try std.testing.expectEqualStrings("Alice", fc.args.items[0].value);
    try std.testing.expectEqualStrings("style", fc.args.items[1].key);
}

test "ast — ListData lifecycle (no leaks)" {
    const alloc = std.testing.allocator;

    var ld = ListData{
        .ordered = false,
        .items = List(ListItem).empty,
    };
    defer ld.deinit(alloc);

    try ld.items.append(alloc, .{ .text = "first item" });
    try ld.items.append(alloc, .{ .text = "second item", .checked = true });

    try std.testing.expectEqual(@as(usize, 2), ld.items.items.len);
    try std.testing.expectEqualStrings("first item", ld.items.items[0].text);
    try std.testing.expectEqual(@as(?bool, true), ld.items.items[1].checked);
}

test "ast — TableData lifecycle (no leaks)" {
    const alloc = std.testing.allocator;

    var tbl = TableData{
        .headers = List([]const u8).empty,
        .alignments = List(ColumnAlign).empty,
        .rows = List(List([]const u8)).empty,
    };
    defer tbl.deinit(alloc);

    try tbl.headers.append(alloc, "Col1");
    try tbl.headers.append(alloc, "Col2");
    try tbl.alignments.append(alloc, .left);
    try tbl.alignments.append(alloc, .center);

    var row1 = List([]const u8).empty;
    try row1.append(alloc, "A");
    try row1.append(alloc, "B");
    try tbl.rows.append(alloc, row1);

    try std.testing.expectEqual(@as(usize, 2), tbl.headers.items.len);
    try std.testing.expectEqual(@as(usize, 1), tbl.rows.items.len);
}

