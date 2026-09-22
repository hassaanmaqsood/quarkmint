//! coercion.zig — Type coercion rules for Quarkdown function arguments.
//!
//! Converts raw argument values into parameter types declared by functions.

const std = @import("std");
const ast = @import("ast.zig");
const value_mod = @import("value.zig");

const Allocator = std.mem.Allocator;
pub const Value = value_mod.Value;
pub const Node = ast.Node;

pub const CoercionError = error{
    TypeMismatch,
    OutOfMemory,
};

pub const ParamKind = enum {
    any,
    string,
    integer,
    float,
    boolean,
    node,
    node_list,
    enum_val,
};

/// Coerce `val` into the requested `target` type.
pub fn coerce(alloc: Allocator, val: Value, target: ParamKind) CoercionError!Value {
    if (target == .any) return val;

    switch (target) {
        .any => return val,

        .string => {
            if (val == .string) return val;
            const str = val.asString(alloc) catch return error.OutOfMemory;
            return Value{ .string = str };
        },

        .integer => {
            if (val == .integer) return val;
            if (val.asInteger()) |i| return Value{ .integer = i };
            return error.TypeMismatch;
        },

        .float => {
            if (val == .float) return val;
            if (val.asFloat()) |f| return Value{ .float = f };
            return error.TypeMismatch;
        },

        .boolean => {
            return Value{ .boolean = val.isTruthy() };
        },

        .node => {
            switch (val) {
                .node => |n| return Value{ .node = n },
                .string => |s| return Value{ .node = Node{ .text = s } },
                .integer, .float, .boolean => {
                    const str = val.asString(alloc) catch return error.OutOfMemory;
                    return Value{ .node = Node{ .text = str } };
                },
                .node_list => |nl| {
                    if (nl.len > 0) return Value{ .node = nl[0] };
                    return Value{ .node = Node{ .text = "" } };
                },
                else => return Value{ .node = Node{ .text = "" } },
            }
        },

        .node_list => {
            switch (val) {
                .node_list => return val,
                .node => |n| {
                    const list = alloc.alloc(Node, 1) catch return error.OutOfMemory;
                    list[0] = n;
                    return Value{ .node_list = list };
                },
                .string => |s| {
                    const list = alloc.alloc(Node, 1) catch return error.OutOfMemory;
                    list[0] = Node{ .text = s };
                    return Value{ .node_list = list };
                },
                else => return Value{ .node_list = &[_]Node{} },
            }
        },

        .enum_val => {
            switch (val) {
                .enum_val => return val,
                .string => |s| return Value{ .enum_val = s },
                else => return error.TypeMismatch,
            }
        },
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

test "coercion — string to integer and float" {
    const alloc = std.testing.allocator;

    const v1 = Value{ .string = "42" };
    const c1 = try coerce(alloc, v1, .integer);
    try std.testing.expectEqual(@as(i64, 42), c1.integer);

    const v2 = Value{ .string = "3.14" };
    const c2 = try coerce(alloc, v2, .float);
    try std.testing.expect(c2.float > 3.13 and c2.float < 3.15);
}

test "coercion — int to string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const v = Value{ .integer = 100 };
    const c = try coerce(alloc, v, .string);
    try std.testing.expectEqualStrings("100", c.string);
}

test "coercion — string to node" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const v = Value{ .string = "Hello" };
    const c = try coerce(alloc, v, .node);
    try std.testing.expect(c.node == .text);
    try std.testing.expectEqualStrings("Hello", c.node.text);
}
