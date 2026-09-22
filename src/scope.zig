//! scope.zig — Lexical scoping for Quarkdown variables and functions.
//!
//! Scopes form an intrusive linked list:
//!   root (global) ← document ← block ← loop / function body
//!
//! Variable and function resolution walks the scope chain towards root O(depth).

const std = @import("std");
const value_mod = @import("value.zig");

const Allocator = std.mem.Allocator;
pub const Value = value_mod.Value;
pub const FnDef = value_mod.FnDef;

pub const Scope = struct {
    parent: ?*Scope,
    vars: std.StringHashMapUnmanaged(Value),
    fns: std.StringHashMapUnmanaged(FnDef),

    /// Initialize an empty scope linked to `parent`.
    pub fn init(parent: ?*Scope) Scope {
        return .{
            .parent = parent,
            .vars = .empty,
            .fns = .empty,
        };
    }

    /// Release hash map allocations for this scope.
    pub fn deinit(self: *Scope, alloc: Allocator) void {
        self.vars.deinit(alloc);
        self.fns.deinit(alloc);
    }

    /// Define or overwrite a variable in *this* immediate scope frame.
    pub fn defineVar(self: *Scope, alloc: Allocator, name: []const u8, val: Value) !void {
        try self.vars.put(alloc, name, val);
    }

    /// Look up a variable, walking up the parent scope chain if not found locally.
    pub fn lookupVar(self: *const Scope, name: []const u8) ?Value {
        if (self.vars.count() > 0) {
            if (self.vars.get(name)) |v| return v;
        }
        if (self.parent) |p| return p.lookupVar(name);
        return null;
    }

    /// Update an existing variable in the nearest enclosing scope where it is bound.
    /// Returns true if updated, false if variable was not declared in any scope.
    pub fn updateVar(self: *Scope, name: []const u8, val: Value) bool {
        if (self.vars.count() > 0) {
            if (self.vars.getPtr(name)) |ptr| {
                ptr.* = val;
                return true;
            }
        }
        if (self.parent) |p| return p.updateVar(name, val);
        return false;
    }

    /// Define or overwrite a function definition in *this* immediate scope frame.
    pub fn defineFn(self: *Scope, alloc: Allocator, name: []const u8, def: FnDef) !void {
        try self.fns.put(alloc, name, def);
    }

    /// Look up a function definition, walking up the parent scope chain.
    pub fn lookupFn(self: *const Scope, name: []const u8) ?FnDef {
        if (self.fns.count() > 0) {
            if (self.fns.get(name)) |f| return f;
        }
        if (self.parent) |p| return p.lookupFn(name);
        return null;
    }

    /// Create and return a heap-allocated child scope.
    pub fn createChild(self: *Scope, alloc: Allocator) !*Scope {
        const child_ptr = try alloc.create(Scope);
        child_ptr.* = Scope.init(self);
        return child_ptr;
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

test "scope — variable resolution & shadowing" {
    const alloc = std.testing.allocator;

    var root = Scope.init(null);
    defer root.deinit(alloc);

    try root.defineVar(alloc, "x", Value{ .integer = 10 });
    try root.defineVar(alloc, "y", Value{ .string = "global" });

    var child = Scope.init(&root);
    defer child.deinit(alloc);

    try child.defineVar(alloc, "x", Value{ .integer = 20 }); // shadows root x

    // Child resolves shadowed x = 20, and inherited y = "global"
    const child_x = child.lookupVar("x").?;
    try std.testing.expectEqual(@as(i64, 20), child_x.integer);

    const child_y = child.lookupVar("y").?;
    try std.testing.expectEqualStrings("global", child_y.string);

    // Root resolves its own x = 10
    const root_x = root.lookupVar("x").?;
    try std.testing.expectEqual(@as(i64, 10), root_x.integer);
}

test "scope — function definition and lookup" {
    const alloc = std.testing.allocator;

    var root = Scope.init(null);
    defer root.deinit(alloc);

    const params = [_][]const u8{ "a", "b" };
    try root.defineFn(alloc, "add", .{
        .name = "add",
        .params = &params,
        .body = ".let {res} {$a + $b}",
    });

    var child = Scope.init(&root);
    defer child.deinit(alloc);

    const fn_def = child.lookupFn("add").?;
    try std.testing.expectEqualStrings("add", fn_def.name);
    try std.testing.expectEqual(@as(usize, 2), fn_def.params.len);
    try std.testing.expectEqualStrings("a", fn_def.params[0]);
}

test "scope — updateVar mutates existing scope" {
    const alloc = std.testing.allocator;

    var root = Scope.init(null);
    defer root.deinit(alloc);

    try root.defineVar(alloc, "count", Value{ .integer = 1 });

    var child = Scope.init(&root);
    defer child.deinit(alloc);

    const updated = child.updateVar("count", Value{ .integer = 2 });
    try std.testing.expect(updated);

    try std.testing.expectEqual(@as(i64, 2), root.lookupVar("count").?.integer);
}
