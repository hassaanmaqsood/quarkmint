//! value.zig — Runtime value system for Quarkdown.
//!
//! Values are passed to and returned from Quarkdown functions, stored in scopes,
//! and coerced to expected parameter types.

const std = @import("std");
const ast = @import("ast.zig");

const Allocator = std.mem.Allocator;
const Node = ast.Node;

/// User-defined function definition created via `.function {name param1 param2} {body}`.
pub const FnDef = struct {
    name: []const u8,
    params: []const []const u8,
    body: []const u8,
};

/// Tagged union representing any runtime value in Quarkdown.
pub const Value = union(enum) {
    none,
    boolean: bool,
    integer: i64,
    float: f64,
    string: []const u8,
    node: Node,
    node_list: []Node,
    enum_val: []const u8,

    /// Check if the value is truthy (for `.if`, `.ifnot`, etc.)
    pub fn isTruthy(self: Value) bool {
        return switch (self) {
            .none => false,
            .boolean => |b| b,
            .integer => |i| i != 0,
            .float => |f| f != 0.0,
            .string => |s| s.len > 0 and !std.mem.eql(u8, s, "false"),
            .node_list => |nl| nl.len > 0,
            .enum_val => |e| e.len > 0,
            .node => true,
        };
    }

    /// Format or return a string representation of the value.
    pub fn asString(self: Value, alloc: Allocator) ![]const u8 {
        return switch (self) {
            .none => "",
            .boolean => |b| if (b) "true" else "false",
            .integer => |i| try std.fmt.allocPrint(alloc, "{d}", .{i}),
            .float => |f| try std.fmt.allocPrint(alloc, "{d}", .{f}),
            .string => |s| s,
            .enum_val => |e| e,
            .node => |n| switch (n) {
                .text, .paragraph, .blockquote, .code_span => |t| t,
                .heading => |h| h.text,
                .code_block => |cb| cb.content,
                else => "",
            },
            .node_list => "",
        };
    }

    /// Try to parse integer from string or return existing integer.
    pub fn asInteger(self: Value) ?i64 {
        return switch (self) {
            .integer => |i| i,
            .float => |f| @intFromFloat(f),
            .boolean => |b| if (b) 1 else 0,
            .string => |s| std.fmt.parseInt(i64, std.mem.trim(u8, s, " \t"), 10) catch null,
            else => null,
        };
    }

    /// Try to parse float from string or return existing float.
    pub fn asFloat(self: Value) ?f64 {
        return switch (self) {
            .float => |f| f,
            .integer => |i| @floatFromInt(i),
            .boolean => |b| if (b) 1.0 else 0.0,
            .string => |s| std.fmt.parseFloat(f64, std.mem.trim(u8, s, " \t")) catch null,
            else => null,
        };
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

test "value — truthiness" {
    try std.testing.expect((Value{ .boolean = true }).isTruthy());
    try std.testing.expect(!(Value{ .boolean = false }).isTruthy());
    try std.testing.expect((Value{ .integer = 42 }).isTruthy());
    try std.testing.expect(!(Value{ .integer = 0 }).isTruthy());
    try std.testing.expect((Value{ .string = "hello" }).isTruthy());
    try std.testing.expect(!(Value{ .string = "" }).isTruthy());
    try std.testing.expect(!(Value{ .none = {} }).isTruthy());
}

test "value — integer parsing" {
    const v1 = Value{ .string = "123" };
    try std.testing.expectEqual(@as(?i64, 123), v1.asInteger());

    const v2 = Value{ .integer = 456 };
    try std.testing.expectEqual(@as(?i64, 456), v2.asInteger());
}
