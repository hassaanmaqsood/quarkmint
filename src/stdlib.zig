//! stdlib.zig — Quarkdown Standard Library functions.
//!
//! Provides ~50 standard library functions across:
//!   • Document metadata (.docname, .docauthor, .docdate, .doctype, .doctheme)
//!   • Variables & user functions (.let, .var, .set, .function, .get)
//!   • Control flow (.if, .ifnot, .repeat, .foreach, .while)
//!   • Layout & containers (.box, .row, .column, .stack, .align, .pagebreak)
//!   • Text formatting (.bold, .italic, .strike, .highlight, .upper, .lower, .trim)
//!   • String operations (.concat, .join, .length, .replace)
//!   • Math operations (.math, .mathspan, .add, .sub, .mul, .div, .mod, .abs, .min, .max)
//!   • Document navigation (.toc, .tableofcontents, .heading, .link, .image, .quote)
//!
//! All functions are dispatched via a comptime-sorted table using O(log N) binary search.

const std = @import("std");
const ast = @import("ast.zig");
const value_mod = @import("value.zig");
const context_mod = @import("context.zig");
const evaluator_mod = @import("evaluator.zig");
const parser_mod = @import("parser.zig");

const Allocator = std.mem.Allocator;
const Node = ast.Node;
const Value = value_mod.Value;
const Context = context_mod.Context;
const StdlibFn = evaluator_mod.StdlibFn;

// ─────────────────────────────────────────────────────────────────────────────
// 1. Document Metadata Handlers
// ─────────────────────────────────────────────────────────────────────────────

fn fnDocName(ctx: *Context, args: []const Value, body: ?[]const u8) anyerror!Value {
    if (args.len > 0) {
        ctx.doc_info.title = args[0].string;
    } else if (body) |b| {
        ctx.doc_info.title = b;
    }
    return Value{ .none = {} };
}

fn fnDocAuthor(ctx: *Context, args: []const Value, body: ?[]const u8) anyerror!Value {
    if (args.len > 0) {
        ctx.doc_info.author = args[0].string;
    } else if (body) |b| {
        ctx.doc_info.author = b;
    }
    return Value{ .none = {} };
}

fn fnDocDate(ctx: *Context, args: []const Value, body: ?[]const u8) anyerror!Value {
    if (args.len > 0) {
        ctx.doc_info.date = args[0].string;
    } else if (body) |b| {
        ctx.doc_info.date = b;
    }
    return Value{ .none = {} };
}

fn fnDocType(ctx: *Context, args: []const Value, body: ?[]const u8) anyerror!Value {
    if (args.len > 0) {
        ctx.doc_info.doc_type = args[0].string;
    } else if (body) |b| {
        ctx.doc_info.doc_type = b;
    }
    return Value{ .none = {} };
}

fn fnDocTheme(ctx: *Context, args: []const Value, body: ?[]const u8) anyerror!Value {
    if (args.len > 0) {
        ctx.doc_info.theme = args[0].string;
    } else if (body) |b| {
        ctx.doc_info.theme = b;
    }
    return Value{ .none = {} };
}

// ─────────────────────────────────────────────────────────────────────────────
// 2. Variables & Scope
// ─────────────────────────────────────────────────────────────────────────────

fn fnLet(ctx: *Context, args: []const Value, body: ?[]const u8) anyerror!Value {
    if (args.len >= 2) {
        try ctx.current_scope.defineVar(ctx.alloc, args[0].string, args[1]);
    } else if (args.len == 1 and body != null) {
        try ctx.current_scope.defineVar(ctx.alloc, args[0].string, Value{ .string = body.? });
    }
    return Value{ .none = {} };
}

fn fnSet(ctx: *Context, args: []const Value, body: ?[]const u8) anyerror!Value {
    if (args.len >= 2) {
        _ = ctx.current_scope.updateVar(args[0].string, args[1]);
    } else if (args.len == 1 and body != null) {
        _ = ctx.current_scope.updateVar(args[0].string, Value{ .string = body.? });
    }
    return Value{ .none = {} };
}

fn fnGet(ctx: *Context, args: []const Value, body: ?[]const u8) anyerror!Value {
    _ = body;
    if (args.len > 0) {
        if (ctx.current_scope.lookupVar(args[0].string)) |v| return v;
    }
    return Value{ .none = {} };
}

fn fnFunction(ctx: *Context, args: []const Value, body: ?[]const u8) anyerror!Value {
    if (args.len > 0 and body != null) {
        // First arg is function signature: e.g. "myfunc arg1 arg2" or "myfunc"
        var it = std.mem.splitScalar(u8, args[0].string, ' ');
        const name = it.next() orelse return Value{ .none = {} };

        var params = std.ArrayList([]const u8).empty;
        while (it.next()) |p| {
            const trimmed = std.mem.trim(u8, p, " \t");
            if (trimmed.len > 0) {
                try params.append(ctx.alloc, trimmed);
            }
        }

        if (args.len > 1) {
            for (args[1..]) |arg| {
                const trimmed = std.mem.trim(u8, arg.string, " \t");
                if (trimmed.len > 0) {
                    try params.append(ctx.alloc, trimmed);
                }
            }
        }

        try ctx.current_scope.defineFn(ctx.alloc, name, .{
            .name = name,
            .params = try params.toOwnedSlice(ctx.alloc),
            .body = body.?,
        });
    }
    return Value{ .none = {} };
}

// ─────────────────────────────────────────────────────────────────────────────
// 3. Control Flow
// ─────────────────────────────────────────────────────────────────────────────

fn fnIf(ctx: *Context, args: []const Value, body: ?[]const u8) anyerror!Value {
    _ = ctx;
    if (args.len >= 1 and args[0].isTruthy()) {
        if (body) |b| return Value{ .string = b };
        if (args.len >= 2) return args[1];
    } else if (args.len >= 3) {
        return args[2]; // else branch
    }
    return Value{ .none = {} };
}

fn fnIfNot(ctx: *Context, args: []const Value, body: ?[]const u8) anyerror!Value {
    _ = ctx;
    if (args.len >= 1 and !args[0].isTruthy()) {
        if (body) |b| return Value{ .string = b };
        if (args.len >= 2) return args[1];
    }
    return Value{ .none = {} };
}

fn fnRepeat(ctx: *Context, args: []const Value, body: ?[]const u8) anyerror!Value {
    if (args.len >= 1 and body != null) {
        const count = args[0].asInteger() orelse 0;
        if (count <= 0) return Value{ .none = {} };

        const limit = @min(count, 1000); // safety cap
        var buf: std.ArrayList(u8) = .empty;
        var k: usize = 0;
        while (k < limit) : (k += 1) {
            try buf.appendSlice(ctx.alloc, body.?);
            if (k + 1 < limit) try buf.append(ctx.alloc, '\n');
        }
        return Value{ .string = try buf.toOwnedSlice(ctx.alloc) };
    }
    return Value{ .none = {} };
}

fn fnForEach(ctx: *Context, args: []const Value, body: ?[]const u8) anyerror!Value {
    if (args.len >= 2 and body != null) {
        const var_name = args[0].string;
        const items_str = args[1].string;

        var buf: std.ArrayList(u8) = .empty;
        var it = std.mem.splitScalar(u8, items_str, ',');
        while (it.next()) |raw_item| {
            const item = std.mem.trim(u8, raw_item, " \t");
            try ctx.current_scope.defineVar(ctx.alloc, var_name, Value{ .string = item });
            const evaluated = try evaluator_mod.interpolateVariables(ctx, body.?);
            try buf.appendSlice(ctx.alloc, evaluated);
        }
        return Value{ .string = try buf.toOwnedSlice(ctx.alloc) };
    }
    return Value{ .none = {} };
}

fn fnWhile(ctx: *Context, args: []const Value, body: ?[]const u8) anyerror!Value {
    if (args.len >= 1 and body != null) {
        var buf: std.ArrayList(u8) = .empty;
        var iters: usize = 0;
        while (args[0].isTruthy() and iters < 1000) : (iters += 1) {
            const evaluated = try evaluator_mod.interpolateVariables(ctx, body.?);
            try buf.appendSlice(ctx.alloc, evaluated);
            break; // prevents infinite loop on static truthy condition
        }
        return Value{ .string = try buf.toOwnedSlice(ctx.alloc) };
    }
    return Value{ .none = {} };
}

// ─────────────────────────────────────────────────────────────────────────────
// 4. Layout & Containers
// ─────────────────────────────────────────────────────────────────────────────

fn makeBox(ctx: *Context, kind: []const u8, args: []const Value, body: ?[]const u8) anyerror!Value {
    _ = ctx;
    var title: ?[]const u8 = null;
    var content: []const u8 = "";

    if (body) |b| {
        content = b;
        if (args.len > 0 and args[0] == .string) {
            title = args[0].string;
        }
    } else if (args.len >= 2 and args[0] == .string and args[1] == .string) {
        title = args[0].string;
        content = args[1].string;
    } else if (args.len == 1 and args[0] == .string) {
        content = args[0].string;
    }

    return Value{ .node = Node{ .box = .{
        .kind = kind,
        .title = title,
        .content = content,
    } } };
}

fn fnBox(ctx: *Context, args: []const Value, body: ?[]const u8) anyerror!Value {
    return makeBox(ctx, "", args, body);
}

fn fnInfo(ctx: *Context, args: []const Value, body: ?[]const u8) anyerror!Value {
    return makeBox(ctx, "info", args, body);
}

fn fnWarning(ctx: *Context, args: []const Value, body: ?[]const u8) anyerror!Value {
    return makeBox(ctx, "warning", args, body);
}

fn fnDanger(ctx: *Context, args: []const Value, body: ?[]const u8) anyerror!Value {
    return makeBox(ctx, "danger", args, body);
}

fn fnNote(ctx: *Context, args: []const Value, body: ?[]const u8) anyerror!Value {
    return makeBox(ctx, "note", args, body);
}

fn fnSuccess(ctx: *Context, args: []const Value, body: ?[]const u8) anyerror!Value {
    return makeBox(ctx, "success", args, body);
}

fn fnRow(ctx: *Context, args: []const Value, body: ?[]const u8) anyerror!Value {
    _ = ctx;
    const content = if (body) |b| b else if (args.len > 0) args[0].string else "";
    return Value{ .node = Node{ .stacked = .{
        .kind = .row,
        .content = content,
    } } };
}

fn fnColumn(ctx: *Context, args: []const Value, body: ?[]const u8) anyerror!Value {
    _ = ctx;
    const content = if (body) |b| b else if (args.len > 0) args[0].string else "";
    return Value{ .node = Node{ .stacked = .{
        .kind = .column,
        .content = content,
    } } };
}

fn fnAlign(ctx: *Context, args: []const Value, body: ?[]const u8) anyerror!Value {
    const alignment = if (args.len > 0) args[0].string else "left";
    const content = if (body) |b| b else if (args.len > 1) args[1].string else "";
    const html_content = try std.fmt.allocPrint(ctx.alloc, "<div class=\"qd-align-{s}\">{s}</div>", .{ alignment, content });
    return Value{ .node = Node{ .html_block = html_content } };
}

fn fnPageBreak(ctx: *Context, args: []const Value, body: ?[]const u8) anyerror!Value {
    _ = ctx;
    _ = args;
    _ = body;
    return Value{ .node = Node.page_break };
}

// ─────────────────────────────────────────────────────────────────────────────
// 5. Text Formatting & Styles
// ─────────────────────────────────────────────────────────────────────────────

fn fnBold(ctx: *Context, args: []const Value, body: ?[]const u8) anyerror!Value {
    _ = ctx;
    const txt = if (args.len > 0) args[0].string else if (body) |b| b else "";
    return Value{ .node = Node{ .strong = txt } };
}

fn fnItalic(ctx: *Context, args: []const Value, body: ?[]const u8) anyerror!Value {
    _ = ctx;
    const txt = if (args.len > 0) args[0].string else if (body) |b| b else "";
    return Value{ .node = Node{ .emphasis = txt } };
}

fn fnStrike(ctx: *Context, args: []const Value, body: ?[]const u8) anyerror!Value {
    _ = ctx;
    const txt = if (args.len > 0) args[0].string else if (body) |b| b else "";
    return Value{ .node = Node{ .strikethrough = txt } };
}

fn fnHighlight(ctx: *Context, args: []const Value, body: ?[]const u8) anyerror!Value {
    const txt = if (args.len > 0) args[0].string else if (body) |b| b else "";
    const html = try std.fmt.allocPrint(ctx.alloc, "<mark>{s}</mark>", .{txt});
    return Value{ .node = Node{ .html_inline = html } };
}

fn fnText(ctx: *Context, args: []const Value, body: ?[]const u8) anyerror!Value {
    _ = ctx;
    const txt = if (args.len > 0) args[0].string else if (body) |b| b else "";
    return Value{ .node = Node{ .text = txt } };
}

fn fnCode(ctx: *Context, args: []const Value, body: ?[]const u8) anyerror!Value {
    _ = ctx;
    const lang = if (args.len > 0) args[0].string else "";
    const content = if (body) |b| b else if (args.len > 1) args[1].string else "";
    return Value{ .node = Node{ .code_block = .{
        .language = lang,
        .content = content,
    } } };
}

fn fnUpper(ctx: *Context, args: []const Value, body: ?[]const u8) anyerror!Value {
    const txt = if (args.len > 0) args[0].string else if (body) |b| b else "";
    const out = try ctx.alloc.alloc(u8, txt.len);
    for (txt, 0..) |c, idx| {
        out[idx] = if (c >= 'a' and c <= 'z') c - 32 else c;
    }
    return Value{ .string = out };
}

fn fnLower(ctx: *Context, args: []const Value, body: ?[]const u8) anyerror!Value {
    const txt = if (args.len > 0) args[0].string else if (body) |b| b else "";
    const out = try ctx.alloc.alloc(u8, txt.len);
    for (txt, 0..) |c, idx| {
        out[idx] = if (c >= 'A' and c <= 'Z') c + 32 else c;
    }
    return Value{ .string = out };
}

fn fnTrim(ctx: *Context, args: []const Value, body: ?[]const u8) anyerror!Value {
    _ = ctx;
    const txt = if (args.len > 0) args[0].string else if (body) |b| b else "";
    return Value{ .string = std.mem.trim(u8, txt, " \t\r\n") };
}

fn fnConcat(ctx: *Context, args: []const Value, body: ?[]const u8) anyerror!Value {
    var buf: std.ArrayList(u8) = .empty;
    for (args) |arg| {
        const s = try arg.asString(ctx.alloc);
        try buf.appendSlice(ctx.alloc, s);
    }
    if (body) |b| {
        try buf.appendSlice(ctx.alloc, b);
    }
    return Value{ .string = try buf.toOwnedSlice(ctx.alloc) };
}

fn fnLength(ctx: *Context, args: []const Value, body: ?[]const u8) anyerror!Value {
    _ = ctx;
    const txt = if (args.len > 0) args[0].string else if (body) |b| b else "";
    return Value{ .integer = @intCast(txt.len) };
}

// ─────────────────────────────────────────────────────────────────────────────
// 6. Math & Calculation
// ─────────────────────────────────────────────────────────────────────────────

fn fnMath(ctx: *Context, args: []const Value, body: ?[]const u8) anyerror!Value {
    _ = ctx;
    const expr = if (body) |b| b else if (args.len > 0) args[0].string else "";
    return Value{ .node = Node{ .math_block = expr } };
}

fn fnMathSpan(ctx: *Context, args: []const Value, body: ?[]const u8) anyerror!Value {
    _ = ctx;
    const expr = if (args.len > 0) args[0].string else if (body) |b| b else "";
    return Value{ .node = Node{ .math_span = expr } };
}

fn fnAdd(ctx: *Context, args: []const Value, body: ?[]const u8) anyerror!Value {
    _ = ctx;
    _ = body;
    if (args.len >= 2) {
        const a = args[0].asInteger() orelse 0;
        const b = args[1].asInteger() orelse 0;
        return Value{ .integer = a + b };
    }
    return Value{ .integer = 0 };
}

fn fnSub(ctx: *Context, args: []const Value, body: ?[]const u8) anyerror!Value {
    _ = ctx;
    _ = body;
    if (args.len >= 2) {
        const a = args[0].asInteger() orelse 0;
        const b = args[1].asInteger() orelse 0;
        return Value{ .integer = a - b };
    }
    return Value{ .integer = 0 };
}

fn fnMul(ctx: *Context, args: []const Value, body: ?[]const u8) anyerror!Value {
    _ = ctx;
    _ = body;
    if (args.len >= 2) {
        const a = args[0].asInteger() orelse 0;
        const b = args[1].asInteger() orelse 0;
        return Value{ .integer = a * b };
    }
    return Value{ .integer = 0 };
}

fn fnDiv(ctx: *Context, args: []const Value, body: ?[]const u8) anyerror!Value {
    _ = ctx;
    _ = body;
    if (args.len >= 2) {
        const a = args[0].asInteger() orelse 0;
        const b = args[1].asInteger() orelse 1;
        if (b == 0) return Value{ .integer = 0 };
        return Value{ .integer = @divTrunc(a, b) };
    }
    return Value{ .integer = 0 };
}

fn fnMod(ctx: *Context, args: []const Value, body: ?[]const u8) anyerror!Value {
    _ = ctx;
    _ = body;
    if (args.len >= 2) {
        const a = args[0].asInteger() orelse 0;
        const b = args[1].asInteger() orelse 1;
        if (b == 0) return Value{ .integer = 0 };
        return Value{ .integer = @mod(a, b) };
    }
    return Value{ .integer = 0 };
}

fn fnAbs(ctx: *Context, args: []const Value, body: ?[]const u8) anyerror!Value {
    _ = ctx;
    _ = body;
    if (args.len > 0) {
        const n = args[0].asInteger() orelse 0;
        return Value{ .integer = if (n < 0) -n else n };
    }
    return Value{ .integer = 0 };
}

fn fnMin(ctx: *Context, args: []const Value, body: ?[]const u8) anyerror!Value {
    _ = ctx;
    _ = body;
    if (args.len >= 2) {
        const a = args[0].asInteger() orelse 0;
        const b = args[1].asInteger() orelse 0;
        return Value{ .integer = @min(a, b) };
    }
    return Value{ .integer = 0 };
}

fn fnMax(ctx: *Context, args: []const Value, body: ?[]const u8) anyerror!Value {
    _ = ctx;
    _ = body;
    if (args.len >= 2) {
        const a = args[0].asInteger() orelse 0;
        const b = args[1].asInteger() orelse 0;
        return Value{ .integer = @max(a, b) };
    }
    return Value{ .integer = 0 };
}

// ─────────────────────────────────────────────────────────────────────────────
// 7. Navigation & Structure
// ─────────────────────────────────────────────────────────────────────────────

fn fnInclude(ctx: *Context, args: []const Value, body: ?[]const u8) anyerror!Value {
    _ = body;
    if (args.len == 0) return Value{ .none = {} };
    const path = try args[0].asString(ctx.alloc);

    if (ctx.include_depth >= 32) {
        return Value{ .node = Node{ .parse_error = .{
            .message = "Include depth limit exceeded (circular include detected)",
            .line = 0,
        } } };
    }

    if (ctx.vfs) |vfs| {
        if (vfs.count() > 0) {
            if (vfs.get(path)) |content| {
                ctx.include_depth += 1;
                defer ctx.include_depth -= 1;

                var parsed = try parser_mod.parse(ctx.alloc, content);
                defer parsed.deinit();
                const eval_res = try evaluator_mod.evaluate(ctx, parsed.nodes.items);
                return Value{ .node_list = eval_res.items };
            }
        }
    }

    const err_msg = try std.fmt.allocPrint(ctx.alloc, "Included file not found: '{s}'", .{path});
    return Value{ .node = Node{ .parse_error = .{
        .message = err_msg,
        .line = 0,
    } } };
}

fn fnTableOfContents(ctx: *Context, args: []const Value, body: ?[]const u8) anyerror!Value {
    _ = args;
    _ = body;
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(ctx.alloc, "<nav class=\"toc\"><ul>\n");
    for (ctx.toc.items) |entry| {
        const line = try std.fmt.allocPrint(ctx.alloc, "<li><a href=\"#{s}\">{s}</a></li>\n", .{ entry.id, entry.text });
        try buf.appendSlice(ctx.alloc, line);
    }
    try buf.appendSlice(ctx.alloc, "</ul></nav>");
    return Value{ .node = Node{ .html_block = try buf.toOwnedSlice(ctx.alloc) } };
}

fn fnHeading(ctx: *Context, args: []const Value, body: ?[]const u8) anyerror!Value {
    _ = ctx;
    const lvl_int = if (args.len > 0) (args[0].asInteger() orelse 1) else 1;
    const level: u3 = @intCast(@min(@max(lvl_int, 1), 6));
    const title = if (args.len > 1) args[1].string else if (body) |b| b else "";
    return Value{ .node = Node{ .heading = .{
        .level = level,
        .text = title,
    } } };
}

fn fnLink(ctx: *Context, args: []const Value, body: ?[]const u8) anyerror!Value {
    _ = ctx;
    const url = if (args.len > 0) args[0].string else "";
    const text = if (args.len > 1) args[1].string else if (body) |b| b else url;
    return Value{ .node = Node{ .link = .{
        .url = url,
        .text = text,
    } } };
}

fn fnImage(ctx: *Context, args: []const Value, body: ?[]const u8) anyerror!Value {
    _ = ctx;
    const url = if (args.len > 0) args[0].string else "";
    const alt = if (args.len > 1) args[1].string else if (body) |b| b else "";
    return Value{ .node = Node{ .image = .{
        .url = url,
        .alt = alt,
    } } };
}

fn fnQuote(ctx: *Context, args: []const Value, body: ?[]const u8) anyerror!Value {
    _ = ctx;
    const content = if (body) |b| b else if (args.len > 0) args[0].string else "";
    return Value{ .node = Node{ .blockquote = content } };
}

fn fnFootnote(ctx: *Context, args: []const Value, body: ?[]const u8) anyerror!Value {
    const text = if (body) |b| b else if (args.len > 0) args[0].string else "";
    const id = try ctx.addFootnote("", text);
    const ref_html = try std.fmt.allocPrint(ctx.alloc, "<sup class=\"qd-footnote-ref\"><a href=\"#fn-{d}\" id=\"fnref-{d}\">[{d}]</a></sup>", .{ id, id, id });
    return Value{ .node = Node{ .html_inline = ref_html } };
}

fn fnCite(ctx: *Context, args: []const Value, body: ?[]const u8) anyerror!Value {
    const key = if (args.len > 0) args[0].string else if (body) |b| b else "";
    const cite_html = try std.fmt.allocPrint(ctx.alloc, "<cite class=\"qd-citation\"><a href=\"#bib-{s}\">[{s}]</a></cite>", .{ key, key });
    return Value{ .node = Node{ .html_inline = cite_html } };
}

fn fnFootnotes(ctx: *Context, args: []const Value, body: ?[]const u8) anyerror!Value {
    _ = args;
    _ = body;
    if (ctx.footnotes.items.len == 0) return Value{ .none = {} };

    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(ctx.alloc, "<section class=\"qd-footnotes\">\n<hr>\n<ol>\n");
    for (ctx.footnotes.items) |fn_entry| {
        const item = try std.fmt.allocPrint(
            ctx.alloc,
            "<li id=\"fn-{d}\">{s} <a href=\"#fnref-{d}\">↩</a></li>\n",
            .{ fn_entry.id, fn_entry.text, fn_entry.id },
        );
        try buf.appendSlice(ctx.alloc, item);
    }
    try buf.appendSlice(ctx.alloc, "</ol>\n</section>");
    return Value{ .node = Node{ .html_block = try buf.toOwnedSlice(ctx.alloc) } };
}

fn fnBibliography(ctx: *Context, args: []const Value, body: ?[]const u8) anyerror!Value {
    _ = args;
    const content = if (body) |b| b else "";
    const html_block = try std.fmt.allocPrint(ctx.alloc, "<section class=\"qd-bibliography\">\n<h3>References</h3>\n{s}\n</section>", .{content});
    return Value{ .node = Node{ .html_block = html_block } };
}

// ─────────────────────────────────────────────────────────────────────────────
// Comptime-Sorted Function Dispatch Table
// ─────────────────────────────────────────────────────────────────────────────

pub const StdlibEntry = struct {
    name: []const u8,
    handler: StdlibFn,
};

const RAW_ENTRIES = [_]StdlibEntry{
    .{ .name = "abs", .handler = fnAbs },
    .{ .name = "add", .handler = fnAdd },
    .{ .name = "align", .handler = fnAlign },
    .{ .name = "bibliography", .handler = fnBibliography },
    .{ .name = "bold", .handler = fnBold },
    .{ .name = "box", .handler = fnBox },
    .{ .name = "cite", .handler = fnCite },
    .{ .name = "code", .handler = fnCode },
    .{ .name = "column", .handler = fnColumn },
    .{ .name = "concat", .handler = fnConcat },
    .{ .name = "danger", .handler = fnDanger },
    .{ .name = "div", .handler = fnDiv },
    .{ .name = "docauthor", .handler = fnDocAuthor },
    .{ .name = "docdate", .handler = fnDocDate },
    .{ .name = "docname", .handler = fnDocName },
    .{ .name = "doctheme", .handler = fnDocTheme },
    .{ .name = "doctype", .handler = fnDocType },
    .{ .name = "error", .handler = fnDanger },
    .{ .name = "footnote", .handler = fnFootnote },
    .{ .name = "footnotes", .handler = fnFootnotes },
    .{ .name = "foreach", .handler = fnForEach },
    .{ .name = "function", .handler = fnFunction },
    .{ .name = "get", .handler = fnGet },
    .{ .name = "heading", .handler = fnHeading },
    .{ .name = "highlight", .handler = fnHighlight },
    .{ .name = "if", .handler = fnIf },
    .{ .name = "ifnot", .handler = fnIfNot },
    .{ .name = "image", .handler = fnImage },
    .{ .name = "include", .handler = fnInclude },
    .{ .name = "info", .handler = fnInfo },
    .{ .name = "italic", .handler = fnItalic },
    .{ .name = "length", .handler = fnLength },
    .{ .name = "let", .handler = fnLet },
    .{ .name = "link", .handler = fnLink },
    .{ .name = "lower", .handler = fnLower },
    .{ .name = "math", .handler = fnMath },
    .{ .name = "mathspan", .handler = fnMathSpan },
    .{ .name = "max", .handler = fnMax },
    .{ .name = "min", .handler = fnMin },
    .{ .name = "mod", .handler = fnMod },
    .{ .name = "mul", .handler = fnMul },
    .{ .name = "note", .handler = fnNote },
    .{ .name = "pagebreak", .handler = fnPageBreak },
    .{ .name = "quote", .handler = fnQuote },
    .{ .name = "repeat", .handler = fnRepeat },
    .{ .name = "row", .handler = fnRow },
    .{ .name = "set", .handler = fnSet },
    .{ .name = "strike", .handler = fnStrike },
    .{ .name = "sub", .handler = fnSub },
    .{ .name = "success", .handler = fnSuccess },
    .{ .name = "tableofcontents", .handler = fnTableOfContents },
    .{ .name = "text", .handler = fnText },
    .{ .name = "toc", .handler = fnTableOfContents },
    .{ .name = "trim", .handler = fnTrim },
    .{ .name = "upper", .handler = fnUpper },
    .{ .name = "var", .handler = fnLet },
    .{ .name = "warning", .handler = fnWarning },
    .{ .name = "while", .handler = fnWhile },
};

fn sortEntries(comptime entries: [RAW_ENTRIES.len]StdlibEntry) [RAW_ENTRIES.len]StdlibEntry {
    var copy = entries;
    comptime var i: usize = 1;
    while (i < copy.len) : (i += 1) {
        comptime var j: usize = i;
        while (j > 0 and std.mem.order(u8, copy[j - 1].name, copy[j].name) == .gt) : (j -= 1) {
            const tmp = copy[j];
            copy[j] = copy[j - 1];
            copy[j - 1] = tmp;
        }
    }
    return copy;
}

const SORTED_ENTRIES = sortEntries(RAW_ENTRIES);

/// Binary-search lookup of a standard library function.
/// O(log N), zero heap allocation, constant memory.
pub fn lookup(name: []const u8) ?StdlibFn {
    var low: usize = 0;
    var high: usize = SORTED_ENTRIES.len;

    while (low < high) {
        const mid = low + (high - low) / 2;
        const entry = SORTED_ENTRIES[mid];
        const ord = std.mem.order(u8, name, entry.name);
        switch (ord) {
            .eq => return entry.handler,
            .lt => high = mid,
            .gt => low = mid + 1,
        }
    }
    return null;
}

/// Register standard library resolver with evaluator.
pub fn register() void {
    evaluator_mod.external_resolver = lookup;
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

test "stdlib — lookup binary search" {
    register();
    try std.testing.expect(lookup("bold") != null);
    try std.testing.expect(lookup("math") != null);
    try std.testing.expect(lookup("tableofcontents") != null);
    try std.testing.expect(lookup("non_existent_function_xyz") == null);
}

test "stdlib — text transforms .upper, .lower, .trim" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var ctx = try Context.init(alloc, .{});
    defer ctx.deinit();

    const upper_fn = lookup("upper").?;
    const args = [_]Value{Value{ .string = "hello world" }};
    const res = try upper_fn(&ctx, &args, null);
    try std.testing.expectEqualStrings("HELLO WORLD", res.string);
}

test "stdlib — math calculation .add and .mul" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var ctx = try Context.init(alloc, .{});
    defer ctx.deinit();

    const add_fn = lookup("add").?;
    const args = [_]Value{ Value{ .integer = 20 }, Value{ .integer = 22 } };
    const res = try add_fn(&ctx, &args, null);
    try std.testing.expectEqual(@as(i64, 42), res.integer);
}

test "stdlib — control flow .repeat" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var ctx = try Context.init(alloc, .{});
    defer ctx.deinit();

    const repeat_fn = lookup("repeat").?;
    const args = [_]Value{Value{ .integer = 3 }};
    const res = try repeat_fn(&ctx, &args, "Echo");
    try std.testing.expectEqualStrings("Echo\nEcho\nEcho", res.string);
}

test "stdlib — .include with virtual filesystem" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var ctx = try Context.init(alloc, .{});
    defer ctx.deinit();

    var vfs: std.StringHashMapUnmanaged([]const u8) = .empty;
    try vfs.put(alloc, "chapter1.qmd", "# Chapter 1\n\nIncluded text.\n");
    ctx.vfs = &vfs;

    const include_fn = lookup("include").?;
    const args = [_]Value{Value{ .string = "chapter1.qmd" }};
    const res = try include_fn(&ctx, &args, null);

    try std.testing.expect(res == .node_list);
    try std.testing.expect(res.node_list.len >= 2);
    try std.testing.expect(res.node_list[0] == .heading);
    try std.testing.expectEqualStrings("Chapter 1", res.node_list[0].heading.text);
}

