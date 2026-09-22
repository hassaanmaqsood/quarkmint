//! evaluator.zig — Quarkdown AST evaluator and expression expander.
//!
//! Traverses the parsed AST, executes function calls, resolves scopes and variables,
//! tracks headings in the Table of Contents, and splices expanded nodes in-place.

const std = @import("std");
const ast = @import("ast.zig");
const value_mod = @import("value.zig");
const coercion = @import("coercion.zig");
const context_mod = @import("context.zig");
const parser_mod = @import("parser.zig");

const Allocator = std.mem.Allocator;
pub const Node = ast.Node;
pub const Value = value_mod.Value;
pub const FnDef = value_mod.FnDef;
pub const Context = context_mod.Context;

/// Function signature for standard library handlers registered from stdlib.zig.
pub const StdlibFn = *const fn (ctx: *Context, args: []const Value, body: ?[]const u8) anyerror!Value;

/// External resolver hook for Milestone 5 stdlib integration.
pub var external_resolver: ?*const fn (name: []const u8) ?StdlibFn = null;

// ─────────────────────────────────────────────────────────────────────────────
// Core AST Evaluation
// ─────────────────────────────────────────────────────────────────────────────

/// Walk and evaluate a slice of AST nodes, expanding all function calls in-place.
pub fn evaluate(ctx: *Context, nodes: []const Node) !std.ArrayList(Node) {
    var out: std.ArrayList(Node) = .empty;
    errdefer {
        for (out.items) |*n| n.deinit(ctx.alloc);
        out.deinit(ctx.alloc);
    }

    for (nodes) |node| {
        try evaluateNode(ctx, &out, node);
    }

    return out;
}

fn evaluateNode(ctx: *Context, out: *std.ArrayList(Node), node: Node) !void {
    switch (node) {
        .function_call => |fc| {
            const val = try evalFunctionCall(ctx, fc);
            const expanded = try valueToNodes(ctx.alloc, val);
            for (expanded) |en| {
                try out.append(ctx.alloc, en);
            }
        },

        .heading => |h| {
            const interpolated_text = try interpolateVariables(ctx, h.text);
            const slug = try ctx.addHeading(h.level, interpolated_text, h.id);
            try out.append(ctx.alloc, Node{ .heading = .{
                .level = h.level,
                .text = interpolated_text,
                .id = slug,
            } });
        },

        .rich_block => |rb| {
            var new_children = ast.List(Node).empty;
            for (rb.items) |child| {
                switch (child) {
                    .function_call => |fc| {
                        const val = try evalFunctionCall(ctx, fc);
                        const child_nodes = try valueToNodes(ctx.alloc, val);
                        for (child_nodes) |cn| {
                            try new_children.append(ctx.alloc, cn);
                        }
                    },
                    .text => |t| {
                        const interpolated = try interpolateVariables(ctx, t);
                        try new_children.append(ctx.alloc, Node{ .text = interpolated });
                    },
                    .strong => |s| {
                        const interpolated = try interpolateVariables(ctx, s);
                        try new_children.append(ctx.alloc, Node{ .strong = interpolated });
                    },
                    .emphasis => |e| {
                        const interpolated = try interpolateVariables(ctx, e);
                        try new_children.append(ctx.alloc, Node{ .emphasis = interpolated });
                    },
                    .strikethrough => |st| {
                        const interpolated = try interpolateVariables(ctx, st);
                        try new_children.append(ctx.alloc, Node{ .strikethrough = interpolated });
                    },
                    else => {
                        try new_children.append(ctx.alloc, child);
                    },
                }
            }
            try out.append(ctx.alloc, Node{ .rich_block = new_children });
        },

        .paragraph => |p| {
            // Check for variable interpolation: `$var`
            const interpolated = try interpolateVariables(ctx, p);
            try out.append(ctx.alloc, Node{ .paragraph = interpolated });
        },

        else => {
            try out.append(ctx.alloc, node);
        },
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Function Call Evaluation
// ─────────────────────────────────────────────────────────────────────────────

fn evalFunctionCall(ctx: *Context, fc: ast.FunctionCallData) !Value {
    // 1. Evaluate arguments (interpolate variables / expressions)
    var evaled_args = std.ArrayList(Value).empty;
    defer evaled_args.deinit(ctx.alloc);

    for (fc.args.items) |arg| {
        const interpolated = try interpolateVariables(ctx, arg.value);
        try evaled_args.append(ctx.alloc, Value{ .string = interpolated });
    }

    // 2. Check built-in evaluation primitives (.let, .var, .set, .if, .docname, etc.)
    if (std.mem.eql(u8, fc.name, "let") or std.mem.eql(u8, fc.name, "var") or std.mem.eql(u8, fc.name, "set")) {
        const is_set = std.mem.eql(u8, fc.name, "set");
        if (evaled_args.items.len >= 2) {
            const var_name = evaled_args.items[0].string;
            const var_val = evaled_args.items[1];
            if (!is_set or !ctx.current_scope.updateVar(var_name, var_val)) {
                try ctx.current_scope.defineVar(ctx.alloc, var_name, var_val);
            }
        } else if (evaled_args.items.len == 1) {
            if (fc.body != null) {
                const var_name = evaled_args.items[0].string;
                const body_interp = try interpolateVariables(ctx, fc.body.?);
                const var_val = Value{ .string = body_interp };
                if (!is_set or !ctx.current_scope.updateVar(var_name, var_val)) {
                    try ctx.current_scope.defineVar(ctx.alloc, var_name, var_val);
                }
            } else if (evaled_args.items[0] == .string) {
                const s = evaled_args.items[0].string;
                if (std.mem.indexOfAny(u8, s, " \t")) |sp| {
                    const var_name = std.mem.trim(u8, s[0..sp], " \t");
                    const var_val_str = std.mem.trim(u8, s[sp + 1 ..], " \t");
                    const var_val = Value{ .string = var_val_str };
                    if (!is_set or !ctx.current_scope.updateVar(var_name, var_val)) {
                        try ctx.current_scope.defineVar(ctx.alloc, var_name, var_val);
                    }
                }
            }
        }
        return Value{ .none = {} };
    }

    if (std.mem.eql(u8, fc.name, "if")) {
        if (evaled_args.items.len >= 1) {
            const cond = evaled_args.items[0];
            if (cond.isTruthy()) {
                if (fc.body) |b| {
                    return Value{ .string = try interpolateVariables(ctx, b) };
                } else if (evaled_args.items.len >= 2) {
                    return evaled_args.items[1];
                }
            }
        }
        return Value{ .none = {} };
    }

    if (std.mem.eql(u8, fc.name, "ifnot")) {
        if (evaled_args.items.len >= 1) {
            const cond = evaled_args.items[0];
            if (!cond.isTruthy()) {
                if (fc.body) |b| {
                    return Value{ .string = try interpolateVariables(ctx, b) };
                } else if (evaled_args.items.len >= 2) {
                    return evaled_args.items[1];
                }
            }
        }
        return Value{ .none = {} };
    }

    if (std.mem.eql(u8, fc.name, "docname")) {
        if (evaled_args.items.len >= 1) {
            ctx.doc_info.title = evaled_args.items[0].string;
        } else if (fc.body) |b| {
            ctx.doc_info.title = try interpolateVariables(ctx, b);
        }
        return Value{ .none = {} };
    }

    if (std.mem.eql(u8, fc.name, "docauthor")) {
        if (evaled_args.items.len >= 1) {
            ctx.doc_info.author = evaled_args.items[0].string;
        } else if (fc.body) |b| {
            ctx.doc_info.author = try interpolateVariables(ctx, b);
        }
        return Value{ .none = {} };
    }

    if (std.mem.eql(u8, fc.name, "docdate")) {
        if (evaled_args.items.len >= 1) {
            ctx.doc_info.date = evaled_args.items[0].string;
        } else if (fc.body) |b| {
            ctx.doc_info.date = try interpolateVariables(ctx, b);
        }
        return Value{ .none = {} };
    }

    if (std.mem.eql(u8, fc.name, "doctype")) {
        if (evaled_args.items.len >= 1) {
            ctx.doc_info.doc_type = evaled_args.items[0].string;
        } else if (fc.body) |b| {
            ctx.doc_info.doc_type = try interpolateVariables(ctx, b);
        }
        return Value{ .none = {} };
    }

    // 3. Check user-defined function in scope
    if (ctx.current_scope.lookupFn(fc.name)) |fn_def| {
        _ = try ctx.pushScope();
        defer ctx.popScope();

        if (fn_def.params.len == 2 and evaled_args.items.len == 1 and evaled_args.items[0] == .string) {
            const raw = evaled_args.items[0].string;
            if (std.mem.indexOfScalar(u8, raw, '#')) |hash_pos| {
                const p0 = std.mem.trim(u8, raw[0..hash_pos], " \t");
                const p1 = std.mem.trim(u8, raw[hash_pos..], " \t");
                try ctx.current_scope.defineVar(ctx.alloc, fn_def.params[0], Value{ .string = p0 });
                try ctx.current_scope.defineVar(ctx.alloc, fn_def.params[1], Value{ .string = p1 });
            } else if (std.mem.indexOfAny(u8, raw, " \t")) |sp| {
                const p0 = std.mem.trim(u8, raw[0..sp], " \t");
                const p1 = std.mem.trim(u8, raw[sp + 1 ..], " \t");
                try ctx.current_scope.defineVar(ctx.alloc, fn_def.params[0], Value{ .string = p0 });
                try ctx.current_scope.defineVar(ctx.alloc, fn_def.params[1], Value{ .string = p1 });
            } else {
                try ctx.current_scope.defineVar(ctx.alloc, fn_def.params[0], evaled_args.items[0]);
                try ctx.current_scope.defineVar(ctx.alloc, fn_def.params[1], Value{ .none = {} });
            }
        } else {
            for (fn_def.params, 0..) |param_name, idx| {
                const val = if (idx < evaled_args.items.len) evaled_args.items[idx] else Value{ .none = {} };
                try ctx.current_scope.defineVar(ctx.alloc, param_name, val);
            }
        }

        const body_interp = try interpolateVariables(ctx, fn_def.body);
        return Value{ .string = body_interp };
    }

    // 4. Check if function name is a variable reference (e.g. `.x`)
    if (ctx.current_scope.lookupVar(fc.name)) |var_val| {
        return var_val;
    }

    // 5. Check external stdlib resolver (Milestone 5 hook)
    if (external_resolver) |resolver| {
        if (resolver(fc.name)) |handler| {
            return try handler(ctx, evaled_args.items, fc.body);
        }
    }

    // 6. Unknown function: return as unexpanded or empty string
    return Value{ .none = {} };
}

// ─────────────────────────────────────────────────────────────────────────────
// Variable Interpolation: `$ident`
// ─────────────────────────────────────────────────────────────────────────────

pub fn interpolateVariables(ctx: *Context, text: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, text, '$') == null) {
        return text; // fast path: no $ in string
    }

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(ctx.alloc);

    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '$' and i + 1 < text.len and (isAlpha(text[i + 1]) or text[i + 1] == '_')) {
            const var_start = i + 1;
            var var_end = var_start;
            while (var_end < text.len and (isAlnum(text[var_end]) or text[var_end] == '_')) : (var_end += 1) {}
            const var_name = text[var_start..var_end];

            if (ctx.current_scope.lookupVar(var_name)) |val| {
                const s = try val.asString(ctx.alloc);
                try buf.appendSlice(ctx.alloc, s);
            } else {
                try buf.appendSlice(ctx.alloc, text[i..var_end]);
            }
            i = var_end;
        } else {
            try buf.append(ctx.alloc, text[i]);
            i += 1;
        }
    }

    return try buf.toOwnedSlice(ctx.alloc);
}

inline fn isAlpha(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

inline fn isAlnum(c: u8) bool {
    return isAlpha(c) or (c >= '0' and c <= '9');
}

// ─────────────────────────────────────────────────────────────────────────────
// Value to AST Nodes
// ─────────────────────────────────────────────────────────────────────────────

pub fn valueToNodes(alloc: Allocator, val: Value) ![]Node {
    switch (val) {
        .none => return &[_]Node{},
        .node => |n| {
            const arr = try alloc.alloc(Node, 1);
            arr[0] = n;
            return arr;
        },
        .node_list => |nl| return nl,
        .string => |s| {
            if (s.len == 0) return &[_]Node{};
            const trimmed = std.mem.trim(u8, s, " \t\r\n");
            const arr = try alloc.alloc(Node, 1);
            if (std.mem.startsWith(u8, trimmed, "<") and std.mem.endsWith(u8, trimmed, ">")) {
                arr[0] = Node{ .html_inline = s };
            } else {
                arr[0] = Node{ .text = s };
            }
            return arr;
        },
        .integer => |i| {
            const s = try std.fmt.allocPrint(alloc, "{d}", .{i});
            const arr = try alloc.alloc(Node, 1);
            arr[0] = Node{ .text = s };
            return arr;
        },
        .float => |f| {
            const s = try std.fmt.allocPrint(alloc, "{d}", .{f});
            const arr = try alloc.alloc(Node, 1);
            arr[0] = Node{ .text = s };
            return arr;
        },
        .boolean => |b| {
            const arr = try alloc.alloc(Node, 1);
            arr[0] = Node{ .text = if (b) "true" else "false" };
            return arr;
        },
        .enum_val => |e| {
            const arr = try alloc.alloc(Node, 1);
            arr[0] = Node{ .text = e };
            return arr;
        },
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

test "evaluator — .let and variable lookup" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var ctx = try Context.init(alloc, .{});
    defer ctx.deinit();

    // Source with .let and variable usage
    const src = ".let {author} {Alice}\n\nHello from $author!\n";
    var parse_res = try parser_mod.parse(alloc, src);
    defer parse_res.deinit();

    var eval_res = try evaluate(&ctx, parse_res.nodes.items);
    defer eval_res.deinit(alloc);

    // .let produces no node, paragraph becomes "Hello from Alice!"
    var found_paragraph = false;
    for (eval_res.items) |node| {
        if (node == .paragraph) {
            try std.testing.expectEqualStrings("Hello from Alice!", node.paragraph);
            found_paragraph = true;
        }
    }
    try std.testing.expect(found_paragraph);
}

test "evaluator — .if condition execution" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var ctx = try Context.init(alloc, .{});
    defer ctx.deinit();

    const src = ".if {true} {Visible}\n.if {false} {Hidden}\n";
    var parse_res = try parser_mod.parse(alloc, src);
    defer parse_res.deinit();

    var eval_res = try evaluate(&ctx, parse_res.nodes.items);
    defer eval_res.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), eval_res.items.len);
    try std.testing.expectEqualStrings("Visible", eval_res.items[0].text);
}

test "evaluator — document metadata .docname and .docauthor" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var ctx = try Context.init(alloc, .{});
    defer ctx.deinit();

    const src = ".docname {My Super Document}\n.docauthor {John Doe}\n";
    var parse_res = try parser_mod.parse(alloc, src);
    defer parse_res.deinit();

    var eval_res = try evaluate(&ctx, parse_res.nodes.items);
    defer eval_res.deinit(alloc);

    try std.testing.expectEqualStrings("My Super Document", ctx.doc_info.title);
    try std.testing.expectEqualStrings("John Doe", ctx.doc_info.author);
}
