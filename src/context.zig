//! context.zig — Per-compile execution context.
//!
//! Owns the scope hierarchy, document metadata, table of contents, compile options,
//! and error collector. All structures allocate from the per-compile ArenaAllocator.

const std = @import("std");
const ast = @import("ast.zig");
const scope_mod = @import("scope.zig");
const value_mod = @import("value.zig");

const Allocator = std.mem.Allocator;
pub const Scope = scope_mod.Scope;
pub const Value = value_mod.Value;
pub const FnDef = value_mod.FnDef;
pub const ErrorData = ast.ErrorData;

/// Document metadata collected during compilation (via `.docname`, `.docauthor`, etc.)
pub const DocumentInfo = struct {
    title: []const u8 = "Untitled Document",
    author: []const u8 = "",
    date: []const u8 = "",
    doc_type: []const u8 = "article",
    theme: []const u8 = "default",
};

/// Entry in the document's generated Table of Contents.
pub const TOCEntry = struct {
    level: u3,
    text: []const u8,
    id: []const u8, // HTML anchor slug
};

/// Compilation options configuring the pipeline.
pub const CompileOptions = struct {
    standalone: bool = false, // Wrap output in <!DOCTYPE html> document shell
    math_katex: bool = true, // Emit KaTeX math delimiters
    base_url: []const u8 = "",
};

/// Entry in the document's footnotes list.
pub const FootnoteEntry = struct {
    id: usize,
    label: []const u8,
    text: []const u8,
};

/// The execution context for compiling a single Quarkdown document.
pub const Context = struct {
    root_scope: *Scope,
    current_scope: *Scope,
    child_scopes: std.ArrayList(*Scope),
    doc_info: DocumentInfo,
    toc: std.ArrayList(TOCEntry),
    footnotes: std.ArrayList(FootnoteEntry),
    errors: std.ArrayList(ErrorData),
    options: CompileOptions,
    vfs: ?*const std.StringHashMapUnmanaged([]const u8) = null,
    include_depth: usize = 0,
    alloc: Allocator,

    /// Initialize a new compilation context using the provided arena allocator.
    pub fn init(alloc: Allocator, options: CompileOptions) !Context {
        const root = try alloc.create(Scope);
        root.* = Scope.init(null);

        return Context{
            .root_scope = root,
            .current_scope = root,
            .child_scopes = .empty,
            .doc_info = .{},
            .toc = .empty,
            .footnotes = .empty,
            .errors = .empty,
            .options = options,
            .vfs = null,
            .include_depth = 0,
            .alloc = alloc,
        };
    }

    pub fn addFootnote(self: *Context, label: []const u8, text: []const u8) Allocator.Error!usize {
        const id = self.footnotes.items.len + 1;
        try self.footnotes.append(self.alloc, .{
            .id = id,
            .label = label,
            .text = text,
        });
        return id;
    }

    /// Clean up any heap-allocated lists (arena handles bulk free).
    pub fn deinit(self: *Context) void {
        self.root_scope.deinit(self.alloc);
        self.alloc.destroy(self.root_scope);
        for (self.child_scopes.items) |child| {
            child.deinit(self.alloc);
            self.alloc.destroy(child);
        }
        self.child_scopes.deinit(self.alloc);
        self.toc.deinit(self.alloc);
        self.errors.deinit(self.alloc);
    }

    /// Push a new child scope onto the scope stack.
    pub fn pushScope(self: *Context) !*Scope {
        const child = try self.current_scope.createChild(self.alloc);
        try self.child_scopes.append(self.alloc, child);
        self.current_scope = child;
        return child;
    }

    /// Pop the current scope, restoring its parent.
    pub fn popScope(self: *Context) void {
        if (self.current_scope.parent) |parent| {
            self.current_scope = parent;
        }
    }

    /// Register a heading in the table of contents and return its unique HTML anchor slug.
    pub fn addHeading(self: *Context, level: u3, text: []const u8, custom_id: ?[]const u8) ![]const u8 {
        const base_slug = if (custom_id) |cid|
            if (cid.len > 0) cid else try self.slugify(text)
        else
            try self.slugify(text);

        // Ensure slug uniqueness
        var slug = base_slug;
        var duplicate_count: usize = 0;
        for (self.toc.items) |entry| {
            if (std.mem.eql(u8, entry.id, base_slug)) {
                duplicate_count += 1;
            }
        }
        if (duplicate_count > 0) {
            slug = try std.fmt.allocPrint(self.alloc, "{s}-{d}", .{ base_slug, duplicate_count });
        }

        try self.toc.append(self.alloc, .{
            .level = level,
            .text = text,
            .id = slug,
        });

        return slug;
    }

    /// Record a non-fatal compilation or evaluation error.
    pub fn addError(self: *Context, message: []const u8, line: u32) !void {
        try self.errors.append(self.alloc, .{
            .message = message,
            .line = line,
        });
    }

    /// Convert heading text into an URL/HTML-safe slug: "Hello, World!" -> "hello-world"
    pub fn slugify(self: *Context, text: []const u8) ![]const u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(self.alloc);

        var prev_was_dash = true;
        for (text) |c| {
            if (c >= 'A' and c <= 'Z') {
                try buf.append(self.alloc, c + 32); // lowercase
                prev_was_dash = false;
            } else if ((c >= 'a' and c <= 'z') or (c >= '0' and c <= '9')) {
                try buf.append(self.alloc, c);
                prev_was_dash = false;
            } else if (c == ' ' or c == '-' or c == '_' or c == '.') {
                if (!prev_was_dash) {
                    try buf.append(self.alloc, '-');
                    prev_was_dash = true;
                }
            }
        }

        // Strip trailing dash if present
        while (buf.items.len > 0 and buf.items[buf.items.len - 1] == '-') {
            _ = buf.pop();
        }

        if (buf.items.len == 0) {
            return "heading";
        }

        return try buf.toOwnedSlice(self.alloc);
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

test "context — scope push and pop" {
    const alloc = std.testing.allocator;

    var ctx = try Context.init(alloc, .{});
    defer ctx.deinit();

    try ctx.current_scope.defineVar(alloc, "global", Value{ .string = "val" });

    _ = try ctx.pushScope();
    try ctx.current_scope.defineVar(alloc, "local", Value{ .integer = 42 });

    // Local scope sees both
    try std.testing.expectEqualStrings("val", ctx.current_scope.lookupVar("global").?.string);
    try std.testing.expectEqual(@as(i64, 42), ctx.current_scope.lookupVar("local").?.integer);

    ctx.popScope();

    // After pop, back to root scope
    try std.testing.expect(ctx.current_scope.lookupVar("local") == null);
    try std.testing.expectEqualStrings("val", ctx.current_scope.lookupVar("global").?.string);
}

test "context — slugify and TOC registration with duplicates" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var ctx = try Context.init(alloc, .{});
    defer ctx.deinit();

    const slug1 = try ctx.addHeading(1, "Getting Started!", null);
    try std.testing.expectEqualStrings("getting-started", slug1);

    const slug2 = try ctx.addHeading(2, "Getting Started!", null); // duplicate
    try std.testing.expectEqualStrings("getting-started-1", slug2);

    try std.testing.expectEqual(@as(usize, 2), ctx.toc.items.len);
    try std.testing.expectEqual(@as(u3, 1), ctx.toc.items[0].level);
    try std.testing.expectEqual(@as(u3, 2), ctx.toc.items[1].level);
}
