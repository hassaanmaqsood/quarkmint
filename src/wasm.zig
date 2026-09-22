//! wasm.zig — WebAssembly interop boundary for Quarkmint
//!
//! Memory model
//! ────────────
//! JavaScript owns the Wasm linear memory.  The flow for a single render call:
//!
//!   1. JS calls `alloc_buffer(len)` → receives a pointer into Wasm memory.
//!   2. JS writes the UTF-8 markdown string at that pointer.
//!   3. JS calls `parse_and_render(ptr, len)` → receives a NEW pointer.
//!   4. JS reads the null-terminated JSON result from that pointer.
//!   5. JS calls `free_buffer(result_ptr, result_len)` to release step-3 mem.
//!   6. JS calls `free_buffer(input_ptr, len)` to release step-1 mem.
//!
//! Two allocators are used:
//!   • bridge allocator — used ONLY for the two bridge buffers allocated/freed
//!     per call.  On wasm32-freestanding this is page_allocator (memory.grow).
//!     On native targets it is a DebugAllocator (detects leaks).
//!   • arena (ArenaAllocator wrapping bridge) — used for the entire AST and
//!     all intermediate parse structures.  Freed in one shot at end of render.
//!
//! Error contract
//! ──────────────
//! This module NEVER panics in production.  Any parsing error is captured as a
//! `parse_error` node and serialised as a JSON error field.
//! Memory-allocation failures produce a minimal hard-coded error response.
//!
//! Zig 0.16 notes
//! ──────────────
//!   • std.heap.GeneralPurposeAllocator renamed to std.heap.DebugAllocator.
//!   • std.ArrayList(T) is now unmanaged; all mutations take an Allocator arg.

const std = @import("std");
const ast = @import("ast.zig");
const parser = @import("parser.zig");
const context_mod = @import("context.zig");
const evaluator = @import("evaluator.zig");
const renderer_mod = @import("renderer.zig");
const latex_mod = @import("latex.zig");
const post = @import("post.zig");
const stdlib = @import("stdlib.zig");

const Node = ast.Node;
const Allocator = std.mem.Allocator;
const Context = context_mod.Context;
const Renderer = renderer_mod.Renderer;

// ─────────────────────────────────────────────────────────────────────────────
// Persistent bridge allocator
//
// On wasm32-freestanding `std.heap.page_allocator` calls the Wasm
// `memory.grow` instruction directly — no OS calls.
// On native targets (for tests) we use a DebugAllocator so leaks are caught.
// ─────────────────────────────────────────────────────────────────────────────

// We use a comptime branch so the same source compiles for both targets.
const is_wasm = @import("builtin").target.cpu.arch == .wasm32;

// DebugAllocator replaces GeneralPurposeAllocator in Zig 0.16.
var debug_alloc_state = std.heap.DebugAllocator(.{}){};

/// Return the bridge allocator for this target.
/// On wasm32-freestanding: page_allocator (backed by memory.grow).
/// On native test targets: DebugAllocator (detects leaks).
inline fn bridgeAlloc() Allocator {
    if (is_wasm) return std.heap.page_allocator;
    return debug_alloc_state.allocator();
}

// ─────────────────────────────────────────────────────────────────────────────
// Exported buffer management API
// ─────────────────────────────────────────────────────────────────────────────

/// Allocate `size` bytes of bridge memory.
/// Returns null on OOM — JavaScript must check for null.
/// JavaScript usage:
///   const ptr = wasm.alloc_buffer(src.length);
export fn alloc_buffer(size: usize) ?[*]u8 {
    const buf = bridgeAlloc().alloc(u8, size) catch {
        // On OOM, return null — JS must check.
        return null;
    };
    return buf.ptr;
}

/// Free a bridge buffer previously returned by `alloc_buffer` or
/// `parse_and_render`.
/// JavaScript usage:
///   wasm.free_buffer(ptr, len);
export fn free_buffer(ptr: ?[*]u8, size: usize) void {
    const p = ptr orelse return;
    bridgeAlloc().free(p[0..size]);
}

// ─────────────────────────────────────────────────────────────────────────────
// Core render function
// ─────────────────────────────────────────────────────────────────────────────

/// Parse the markdown at `ptr[0..len]` and return a pointer to a
/// null-terminated JSON byte array describing the AST.
///
/// The returned pointer is allocated with `bridgeAlloc()`.
/// JavaScript MUST call `free_buffer(result_ptr, result_len)` after reading.
/// `result_len` is available via `last_result_len()`.
///
/// Returns 0 (null) only on catastrophic OOM.
var last_len: usize = 0;

export fn last_result_len() usize {
    return last_len;
}

export fn parse_and_render(ptr: [*]u8, len: usize) [*]u8 {
    const source: []const u8 = ptr[0..len];

    // ── Step 1: Arena for the parse lifecycle ─────────────────────────────
    var arena = std.heap.ArenaAllocator.init(bridgeAlloc());
    defer arena.deinit(); // frees ALL parse-phase allocations in O(1)

    const alloc = arena.allocator();

    // ── Step 2: Parse ─────────────────────────────────────────────────────
    var result = parser.parse(alloc, source) catch {
        // OOM during parse — emit a minimal JSON error.
        return writeStaticError("parse OOM");
    };
    defer result.deinit();

    // ── Step 3: Serialize to JSON ─────────────────────────────────────────
    // We build into an ArrayList in arena memory, then copy to a bridge buffer.
    var json_buf: std.ArrayList(u8) = .empty;
    serializeNodes(alloc, &json_buf, result.nodes.items) catch {
        return writeStaticError("serialise OOM");
    };

    // ── Step 4: Copy serialised JSON to a bridge buffer ───────────────────
    const json_bytes = json_buf.items;
    // +1 for null terminator.
    const out = bridgeAlloc().alloc(u8, json_bytes.len + 1) catch {
        return writeStaticError("output OOM");
    };
    @memcpy(out[0..json_bytes.len], json_bytes);
    out[json_bytes.len] = 0; // null-terminate

    last_len = out.len;
    return out.ptr;
}

// ─────────────────────────────────────────────────────────────────────────────
// Virtual Filesystem for .include
// ─────────────────────────────────────────────────────────────────────────────

var global_vfs: std.StringHashMapUnmanaged([]const u8) = .empty;

/// Register a virtual file for `.include` calls.
/// Memory for path and content is duplicated into bridgeAlloc().
export fn register_virtual_file(
    path_ptr: [*]const u8,
    path_len: usize,
    content_ptr: [*]const u8,
    content_len: usize,
) void {
    const path = bridgeAlloc().alloc(u8, path_len) catch return;
    @memcpy(path, path_ptr[0..path_len]);

    const content = bridgeAlloc().alloc(u8, content_len) catch {
        bridgeAlloc().free(path);
        return;
    };
    @memcpy(content, content_ptr[0..content_len]);

    if (global_vfs.count() > 0) {
        if (global_vfs.fetchRemove(path)) |kv| {
            bridgeAlloc().free(kv.key);
            bridgeAlloc().free(kv.value);
        }
    }

    global_vfs.put(bridgeAlloc(), path, content) catch {
        bridgeAlloc().free(path);
        bridgeAlloc().free(content);
    };
}

/// Clear all registered virtual files and release bridge memory.
export fn clear_virtual_files() void {
    if (global_vfs.count() > 0) {
        var it = global_vfs.iterator();
        while (it.next()) |entry| {
            bridgeAlloc().free(entry.key_ptr.*);
            bridgeAlloc().free(entry.value_ptr.*);
        }
        global_vfs.clearAndFree(bridgeAlloc());
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Full Document Compilation (compile & compile_fragment)
// ─────────────────────────────────────────────────────────────────────────────

var last_compile_len_val: usize = 0;

export fn last_compile_len() usize {
    return last_compile_len_val;
}

fn internal_compile(ptr: [*]u8, len: usize, standalone: bool) [*]u8 {
    stdlib.register();

    const source: []const u8 = ptr[0..len];

    // Arena for the entire compilation lifecycle
    var arena = std.heap.ArenaAllocator.init(bridgeAlloc());
    defer arena.deinit();

    const alloc = arena.allocator();

    // 1. Parse markdown
    var parse_res = parser.parse(alloc, source) catch {
        return writeStaticHtmlError("Parser Out Of Memory");
    };
    defer parse_res.deinit();

    // 2. Context & Scope
    var ctx = Context.init(alloc, .{ .standalone = standalone }) catch {
        return writeStaticHtmlError("Context Out Of Memory");
    };
    defer ctx.deinit();
    ctx.vfs = &global_vfs;

    // 3. Evaluate AST (expand stdlib & user functions, control flow, math)
    const eval_nodes = evaluator.evaluate(&ctx, parse_res.nodes.items) catch {
        return writeStaticHtmlError("Evaluator Out Of Memory");
    };

    // 4. Render HTML fragment
    var body_buf: std.ArrayList(u8) = .empty;
    var renderer = Renderer.init(alloc, &body_buf, &ctx);
    renderer.renderAll(eval_nodes.items) catch {
        return writeStaticHtmlError("Renderer Out Of Memory");
    };

    // 5. Post-process if standalone
    var out_buf: std.ArrayList(u8) = .empty;
    if (standalone) {
        post.buildDocument(alloc, &out_buf, &ctx, body_buf.items) catch {
            return writeStaticHtmlError("Document Shell Out Of Memory");
        };
    } else {
        out_buf = body_buf;
    }

    // 6. Copy to bridge buffer
    const html_bytes = out_buf.items;
    const out = bridgeAlloc().alloc(u8, html_bytes.len + 1) catch {
        return writeStaticHtmlError("Bridge Buffer Out Of Memory");
    };
    @memcpy(out[0..html_bytes.len], html_bytes);
    out[html_bytes.len] = 0; // null-terminate

    last_compile_len_val = out.len;
    last_len = out.len;
    return out.ptr;
}

/// Full compilation pipeline returning a complete standalone HTML5 document.
/// JavaScript usage:
///   const htmlPtr = wasm.compile(srcPtr, srcLen);
///   const html = readString(htmlPtr, wasm.last_compile_len());
///   wasm.free_buffer(htmlPtr, wasm.last_compile_len());
export fn compile(ptr: [*]u8, len: usize) [*]u8 {
    return internal_compile(ptr, len, true);
}

/// Compilation pipeline returning only the HTML body fragment.
/// JavaScript usage:
///   const fragPtr = wasm.compile_fragment(srcPtr, srcLen);
///   const frag = readString(fragPtr, wasm.last_compile_len());
///   wasm.free_buffer(fragPtr, wasm.last_compile_len());
export fn compile_fragment(ptr: [*]u8, len: usize) [*]u8 {
    return internal_compile(ptr, len, false);
}

fn internal_compile_latex(ptr: [*]u8, len: usize, standalone: bool) [*]u8 {
    stdlib.register();

    const source: []const u8 = ptr[0..len];

    var arena = std.heap.ArenaAllocator.init(bridgeAlloc());
    defer arena.deinit();

    const alloc = arena.allocator();

    var parse_res = parser.parse(alloc, source) catch {
        return writeStaticHtmlError("Parser Out Of Memory");
    };
    defer parse_res.deinit();

    var ctx = Context.init(alloc, .{ .standalone = standalone }) catch {
        return writeStaticHtmlError("Context Out Of Memory");
    };
    defer ctx.deinit();
    ctx.vfs = &global_vfs;

    const eval_nodes = evaluator.evaluate(&ctx, parse_res.nodes.items) catch {
        return writeStaticHtmlError("Evaluator Out Of Memory");
    };

    var body_buf: std.ArrayList(u8) = .empty;
    var renderer = latex_mod.LaTeXRenderer.init(alloc, &body_buf, &ctx);
    renderer.renderAll(eval_nodes.items) catch {
        return writeStaticHtmlError("LaTeX Renderer Out Of Memory");
    };

    var out_buf: std.ArrayList(u8) = .empty;
    if (standalone) {
        latex_mod.buildLaTeXDocument(alloc, &out_buf, &ctx, body_buf.items) catch {
            return writeStaticHtmlError("LaTeX Document Shell Out Of Memory");
        };
    } else {
        out_buf = body_buf;
    }

    const tex_bytes = out_buf.items;
    const out = bridgeAlloc().alloc(u8, tex_bytes.len + 1) catch {
        return writeStaticHtmlError("Bridge Buffer Out Of Memory");
    };
    @memcpy(out[0..tex_bytes.len], tex_bytes);
    out[tex_bytes.len] = 0;

    last_compile_len_val = out.len;
    last_len = out.len;
    return out.ptr;
}

/// Compilation pipeline returning a complete standalone LaTeX document.
export fn compile_latex(ptr: [*]u8, len: usize) [*]u8 {
    return internal_compile_latex(ptr, len, true);
}

/// Compilation pipeline returning only the LaTeX body fragment.
export fn compile_latex_fragment(ptr: [*]u8, len: usize) [*]u8 {
    return internal_compile_latex(ptr, len, false);
}

fn writeStaticHtmlError(comptime msg: []const u8) [*]u8 {
    const static = comptime blk: {
        const payload = "<div class=\"qd-error\">Quarkdown Error: " ++ msg ++ "</div>";
        var buf: [payload.len + 1]u8 = undefined;
        @memcpy(buf[0..payload.len], payload);
        buf[payload.len] = 0;
        break :blk buf;
    };
    last_compile_len_val = static.len;
    last_len = static.len;
    return @constCast(&static);
}

// ─────────────────────────────────────────────────────────────────────────────
// JSON serialisation
// ─────────────────────────────────────────────────────────────────────────────
//
// Output format:
//   { "nodes": [ <node>, … ] }
//
// Each node:
//   { "type": "<tag>", … type-specific fields … }

fn serializeNodes(alloc: Allocator, buf: *std.ArrayList(u8), nodes: []const Node) !void {
    try buf.appendSlice(alloc, "{\"nodes\":[");
    for (nodes, 0..) |node, i| {
        if (i > 0) try buf.append(alloc, ',');
        try serializeNode(alloc, buf, node);
    }
    try buf.appendSlice(alloc, "]}");
}

fn serializeNode(alloc: Allocator, buf: *std.ArrayList(u8), node: Node) !void {
    switch (node) {
        .text => |t| {
            try buf.appendSlice(alloc, "{\"type\":\"text\",\"content\":");
            try writeJsonString(alloc, buf, t);
            try buf.append(alloc, '}');
        },
        .blank => {
            try buf.appendSlice(alloc, "{\"type\":\"blank\"}");
        },
        .code_span => |cs| {
            try buf.appendSlice(alloc, "{\"type\":\"code_span\",\"content\":");
            try writeJsonString(alloc, buf, cs);
            try buf.append(alloc, '}');
        },
        .code_block => |cb| {
            try buf.appendSlice(alloc, "{\"type\":\"code_block\",\"language\":");
            try writeJsonString(alloc, buf, cb.language);
            try buf.appendSlice(alloc, ",\"content\":");
            try writeJsonString(alloc, buf, cb.content);
            try buf.append(alloc, '}');
        },
        .heading => |h| {
            try buf.appendSlice(alloc, "{\"type\":\"heading\",\"level\":");
            try writeUint(alloc, buf, h.level);
            try buf.appendSlice(alloc, ",\"text\":");
            try writeJsonString(alloc, buf, h.text);
            try buf.append(alloc, '}');
        },
        .paragraph => |t| {
            try buf.appendSlice(alloc, "{\"type\":\"paragraph\",\"content\":");
            try writeJsonString(alloc, buf, t);
            try buf.append(alloc, '}');
        },
        .blockquote => |t| {
            try buf.appendSlice(alloc, "{\"type\":\"blockquote\",\"content\":");
            try writeJsonString(alloc, buf, t);
            try buf.append(alloc, '}');
        },
        .thematic_break => {
            try buf.appendSlice(alloc, "{\"type\":\"thematic_break\"}");
        },
        .list => |l| {
            try buf.appendSlice(alloc, "{\"type\":\"list\",\"ordered\":");
            try buf.appendSlice(alloc, if (l.ordered) "true" else "false");
            try buf.appendSlice(alloc, ",\"items\":[");
            for (l.items.items, 0..) |item, i| {
                if (i > 0) try buf.append(alloc, ',');
                try buf.appendSlice(alloc, "{\"text\":");
                try writeJsonString(alloc, buf, item.text);
                if (item.checked) |chk| {
                    try buf.appendSlice(alloc, ",\"checked\":");
                    try buf.appendSlice(alloc, if (chk) "true" else "false");
                }
                try buf.append(alloc, '}');
            }
            try buf.appendSlice(alloc, "]}");
        },
        .rich_block => |rb| {
            try buf.appendSlice(alloc, "{\"type\":\"rich_block\",\"children\":[");
            for (rb.items, 0..) |child, i| {
                if (i > 0) try buf.append(alloc, ',');
                try serializeNode(alloc, buf, child);
            }
            try buf.appendSlice(alloc, "]}");
        },
        .emphasis => |e| {
            try buf.appendSlice(alloc, "{\"type\":\"emphasis\",\"content\":");
            try writeJsonString(alloc, buf, e);
            try buf.append(alloc, '}');
        },
        .strong => |s| {
            try buf.appendSlice(alloc, "{\"type\":\"strong\",\"content\":");
            try writeJsonString(alloc, buf, s);
            try buf.append(alloc, '}');
        },
        .strikethrough => |s| {
            try buf.appendSlice(alloc, "{\"type\":\"strikethrough\",\"content\":");
            try writeJsonString(alloc, buf, s);
            try buf.append(alloc, '}');
        },
        .link => |l| {
            try buf.appendSlice(alloc, "{\"type\":\"link\",\"text\":");
            try writeJsonString(alloc, buf, l.text);
            try buf.appendSlice(alloc, ",\"url\":");
            try writeJsonString(alloc, buf, l.url);
            try buf.appendSlice(alloc, ",\"title\":");
            try writeJsonString(alloc, buf, l.title);
            try buf.append(alloc, '}');
        },
        .image => |img| {
            try buf.appendSlice(alloc, "{\"type\":\"image\",\"alt\":");
            try writeJsonString(alloc, buf, img.alt);
            try buf.appendSlice(alloc, ",\"url\":");
            try writeJsonString(alloc, buf, img.url);
            try buf.appendSlice(alloc, ",\"title\":");
            try writeJsonString(alloc, buf, img.title);
            try buf.append(alloc, '}');
        },
        .auto_link => |al| {
            try buf.appendSlice(alloc, "{\"type\":\"auto_link\",\"url\":");
            try writeJsonString(alloc, buf, al);
            try buf.append(alloc, '}');
        },
        .html_inline => |hi| {
            try buf.appendSlice(alloc, "{\"type\":\"html_inline\",\"content\":");
            try writeJsonString(alloc, buf, hi);
            try buf.append(alloc, '}');
        },
        .html_block => |hb| {
            try buf.appendSlice(alloc, "{\"type\":\"html_block\",\"content\":");
            try writeJsonString(alloc, buf, hb);
            try buf.append(alloc, '}');
        },
        .math_span => |ms| {
            try buf.appendSlice(alloc, "{\"type\":\"math_span\",\"content\":");
            try writeJsonString(alloc, buf, ms);
            try buf.append(alloc, '}');
        },
        .math_block => |mb| {
            try buf.appendSlice(alloc, "{\"type\":\"math_block\",\"content\":");
            try writeJsonString(alloc, buf, mb);
            try buf.append(alloc, '}');
        },
        .table => |tbl| {
            try buf.appendSlice(alloc, "{\"type\":\"table\",\"headers\":[");
            for (tbl.headers.items, 0..) |h, i| {
                if (i > 0) try buf.append(alloc, ',');
                try writeJsonString(alloc, buf, h);
            }
            try buf.appendSlice(alloc, "],\"alignments\":[");
            for (tbl.alignments.items, 0..) |a, i| {
                if (i > 0) try buf.append(alloc, ',');
                try writeJsonString(alloc, buf, @tagName(a));
            }
            try buf.appendSlice(alloc, "],\"rows\":[");
            for (tbl.rows.items, 0..) |row, i| {
                if (i > 0) try buf.append(alloc, ',');
                try buf.append(alloc, '[');
                for (row.items, 0..) |cell, j| {
                    if (j > 0) try buf.append(alloc, ',');
                    try writeJsonString(alloc, buf, cell);
                }
                try buf.append(alloc, ']');
            }
            try buf.appendSlice(alloc, "]}");
        },
        .link_definition => |ld| {
            try buf.appendSlice(alloc, "{\"type\":\"link_definition\",\"label\":");
            try writeJsonString(alloc, buf, ld.label);
            try buf.appendSlice(alloc, ",\"url\":");
            try writeJsonString(alloc, buf, ld.url);
            try buf.appendSlice(alloc, ",\"title\":");
            try writeJsonString(alloc, buf, ld.title);
            try buf.append(alloc, '}');
        },
        .footnote_definition => |fd| {
            try buf.appendSlice(alloc, "{\"type\":\"footnote_definition\",\"label\":");
            try writeJsonString(alloc, buf, fd.label);
            try buf.appendSlice(alloc, ",\"content\":");
            try writeJsonString(alloc, buf, fd.content);
            try buf.append(alloc, '}');
        },
        .page_break => {
            try buf.appendSlice(alloc, "{\"type\":\"page_break\"}");
        },
        .box => |b| {
            try buf.appendSlice(alloc, "{\"type\":\"box\",\"title\":");
            if (b.title) |t| try writeJsonString(alloc, buf, t) else try buf.appendSlice(alloc, "null");
            try buf.appendSlice(alloc, ",\"content\":");
            try writeJsonString(alloc, buf, b.content);
            try buf.append(alloc, '}');
        },
        .stacked => |s| {
            try buf.appendSlice(alloc, "{\"type\":\"stacked\",\"kind\":");
            try writeJsonString(alloc, buf, @tagName(s.kind));
            try buf.appendSlice(alloc, ",\"content\":");
            try writeJsonString(alloc, buf, s.content);
            try buf.append(alloc, '}');
        },
        .function_call => |fc| {
            try buf.appendSlice(alloc, "{\"type\":\"function_call\",\"name\":");
            try writeJsonString(alloc, buf, fc.name);
            try buf.appendSlice(alloc, ",\"is_inline\":");
            try buf.appendSlice(alloc, if (fc.is_inline) "true" else "false");
            try buf.appendSlice(alloc, ",\"args\":[");
            for (fc.args.items, 0..) |arg, i| {
                if (i > 0) try buf.append(alloc, ',');
                try buf.appendSlice(alloc, "{\"key\":");
                try writeJsonString(alloc, buf, arg.key);
                try buf.appendSlice(alloc, ",\"value\":");
                try writeJsonString(alloc, buf, arg.value);
                try buf.append(alloc, '}');
            }
            try buf.appendSlice(alloc, "],\"body\":");
            if (fc.body) |b| try writeJsonString(alloc, buf, b) else try buf.appendSlice(alloc, "null");
            try buf.append(alloc, '}');
        },
        .line_break => {
            try buf.appendSlice(alloc, "{\"type\":\"line_break\"}");
        },
        .soft_break => {
            try buf.appendSlice(alloc, "{\"type\":\"soft_break\"}");
        },
        .parse_error => |e| {
            try buf.appendSlice(alloc, "{\"type\":\"parse_error\",\"message\":");
            try writeJsonString(alloc, buf, e.message);
            try buf.appendSlice(alloc, ",\"line\":");
            try writeUint(alloc, buf, e.line);
            try buf.append(alloc, '}');
        },
    }
}

/// Write a properly escaped JSON string (including surrounding `"`).
fn writeJsonString(alloc: Allocator, buf: *std.ArrayList(u8), s: []const u8) !void {
    try buf.append(alloc, '"');
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(alloc, "\\\""),
            '\\' => try buf.appendSlice(alloc, "\\\\"),
            '\n' => try buf.appendSlice(alloc, "\\n"),
            '\r' => try buf.appendSlice(alloc, "\\r"),
            '\t' => try buf.appendSlice(alloc, "\\t"),
            // Remaining C0 control chars not handled above → \uXXXX.
            // Ranges explicitly exclude '\t'(0x09), '\n'(0x0A), '\r'(0x0D).
            0x00...0x08, 0x0B...0x0C, 0x0E...0x1F => {
                var tmp: [6]u8 = undefined;
                const n = std.fmt.bufPrint(&tmp, "\\u{X:0>4}", .{c}) catch unreachable;
                try buf.appendSlice(alloc, n);
            },
            else => try buf.append(alloc, c),
        }
    }
    try buf.append(alloc, '"');
}

fn writeUint(alloc: Allocator, buf: *std.ArrayList(u8), v: anytype) !void {
    var tmp: [20]u8 = undefined;
    const s = std.fmt.bufPrint(&tmp, "{d}", .{v}) catch unreachable;
    try buf.appendSlice(alloc, s);
}

// ─────────────────────────────────────────────────────────────────────────────
// Static error helper (no allocation)
// ─────────────────────────────────────────────────────────────────────────────

/// Write a hardcoded error JSON into a tiny static buffer.
/// Called only when even the bridge allocator fails.
fn writeStaticError(comptime msg: []const u8) [*]u8 {
    // Comptime-known size; lives in the Wasm data section.
    const static = comptime blk: {
        const payload = "{\"nodes\":[{\"type\":\"parse_error\",\"message\":\"" ++ msg ++ "\",\"line\":0}]}";
        var buf: [payload.len + 1]u8 = undefined;
        @memcpy(buf[0..payload.len], payload);
        buf[payload.len] = 0;
        break :blk buf;
    };
    // SAFETY: this is read-only by JS; it lives for the program lifetime.
    // We cast away const intentionally — the C ABI requires [*]u8 here.
    // JS must NOT call free_buffer on this pointer (it is not heap-allocated).
    last_len = static.len;
    return @constCast(&static);
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

test "wasm — alloc_buffer / free_buffer roundtrip" {
    const size = 64;
    const ptr = alloc_buffer(size) orelse {
        try std.testing.expect(false); // OOM — should not happen in tests
        return;
    };
    // Write something to verify the memory is accessible.
    ptr[0] = 'A';
    ptr[size - 1] = 'Z';
    try std.testing.expectEqual(@as(u8, 'A'), ptr[0]);
    free_buffer(ptr, size);
}

test "wasm — parse_and_render: heading" {
    const src = "# Hello\n";
    const in_ptr = alloc_buffer(src.len) orelse {
        try std.testing.expect(false);
        return;
    };
    @memcpy(in_ptr[0..src.len], src);

    const out_ptr = parse_and_render(in_ptr, src.len);
    try std.testing.expect(@intFromPtr(out_ptr) != 0);

    const out_len = last_result_len();
    const out_slice = out_ptr[0..out_len];
    // Must contain the JSON type field.
    try std.testing.expect(std.mem.indexOf(u8, out_slice, "\"heading\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_slice, "\"Hello\"") != null);

    free_buffer(out_ptr, out_len);
    free_buffer(in_ptr, src.len);
}

test "wasm — parse_and_render: function_call shape" {
    const src = ".greet {name} body\n";
    const in_ptr = alloc_buffer(src.len) orelse {
        try std.testing.expect(false);
        return;
    };
    @memcpy(in_ptr[0..src.len], src);

    const out_ptr = parse_and_render(in_ptr, src.len);
    const out_len = last_result_len();
    const out_slice = out_ptr[0..out_len];

    try std.testing.expect(std.mem.indexOf(u8, out_slice, "\"function_call\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_slice, "\"greet\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_slice, "\"name\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_slice, "\"body\"") != null);

    free_buffer(out_ptr, out_len);
    free_buffer(in_ptr, src.len);
}

test "wasm — parse_and_render: JSON is valid (no unclosed braces)" {
    const src = ".doc {title: My Doc} .heading {level: 1} Intro\n\nParagraph.\n";
    const in_ptr = alloc_buffer(src.len) orelse {
        try std.testing.expect(false);
        return;
    };
    @memcpy(in_ptr[0..src.len], src);

    const out_ptr = parse_and_render(in_ptr, src.len);
    const out_len = last_result_len();
    const out_slice = out_ptr[0..out_len];

    // Balanced brace check.
    var depth: i32 = 0;
    for (out_slice) |c| {
        if (c == '{') depth += 1;
        if (c == '}') depth -= 1;
    }
    try std.testing.expectEqual(@as(i32, 0), depth);

    free_buffer(out_ptr, out_len);
    free_buffer(in_ptr, src.len);
}

test "wasm — parse_and_render: rich blocks, math, and tables" {
    const src = "| Col1 | Col2 |\n| :--- | :---: |\n| Cell1 | Cell2 |\n\nThis is *italic* and $math$.\n";
    const in_ptr = alloc_buffer(src.len) orelse {
        try std.testing.expect(false);
        return;
    };
    @memcpy(in_ptr[0..src.len], src);

    const out_ptr = parse_and_render(in_ptr, src.len);
    const out_len = last_result_len();
    const out_slice = out_ptr[0..out_len];

    try std.testing.expect(std.mem.indexOf(u8, out_slice, "\"table\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_slice, "\"rich_block\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_slice, "\"emphasis\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_slice, "\"math_span\"") != null);

    free_buffer(out_ptr, out_len);
    free_buffer(in_ptr, src.len);
}

test "wasm — parse_and_render: no leaks" {
    // Run through the DebugAllocator so any leaks are caught at test teardown.
    const src = "# Title\n\n.fn {a} {b} body\n\n- item 1\n- item 2\n";
    const in_ptr = alloc_buffer(src.len) orelse {
        try std.testing.expect(false);
        return;
    };
    @memcpy(in_ptr[0..src.len], src);

    const out_ptr = parse_and_render(in_ptr, src.len);
    const out_len = last_result_len();
    free_buffer(out_ptr, out_len);
    free_buffer(in_ptr, src.len);

    // If the DebugAllocator detects a leak it will print a report and the
    // test will fail.
    if (!is_wasm) {
        const result = debug_alloc_state.deinit();
        try std.testing.expect(result != .leak);
        // Re-initialize so subsequent tests can still use the allocator.
        debug_alloc_state = std.heap.DebugAllocator(.{}){};
    }
}

test "wasm — compile: standalone HTML5 document" {
    const src =
        \\.docname {My Research Paper}
        \\.docauthor {Jane Doe}
        \\.docdate {2026-09-22}
        \\
        \\# Introduction
        \\
        \\This is a **bold** paragraph with $E = mc^2$.
        \\
        \\.box {Note} This is a callout box.
    ;

    const in_ptr = alloc_buffer(src.len) orelse return error.OutOfMemory;
    @memcpy(in_ptr[0..src.len], src);

    const out_ptr = compile(in_ptr, src.len);
    const out_len = last_compile_len();
    const html_slice = out_ptr[0..out_len];

    // Assert standalone HTML5 document structure
    try std.testing.expect(std.mem.startsWith(u8, html_slice, "<!DOCTYPE html>"));
    try std.testing.expect(std.mem.indexOf(u8, html_slice, "<title>My Research Paper</title>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html_slice, "<h1 class=\"qd-title\">My Research Paper</h1>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html_slice, "<span class=\"qd-author\">Jane Doe</span>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html_slice, "<span class=\"qd-date\">2026-09-22</span>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html_slice, "<h1 id=\"introduction\">Introduction</h1>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html_slice, "<strong>bold</strong>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html_slice, "<div class=\"qd-box\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, html_slice, "var(--qd-bg)") != null); // Embedded CSS
    try std.testing.expect(std.mem.endsWith(u8, html_slice, "</html>\n\x00"));

    free_buffer(out_ptr, out_len);
    free_buffer(in_ptr, src.len);
}

test "wasm — compile_fragment: body fragment only" {
    const src = "# Heading\n\nParagraph text.\n";

    const in_ptr = alloc_buffer(src.len) orelse return error.OutOfMemory;
    @memcpy(in_ptr[0..src.len], src);

    const out_ptr = compile_fragment(in_ptr, src.len);
    const out_len = last_compile_len();
    const frag_slice = out_ptr[0..out_len];

    // Assert fragment does NOT contain html/head/body shell
    try std.testing.expect(std.mem.indexOf(u8, frag_slice, "<!DOCTYPE html>") == null);
    try std.testing.expect(std.mem.indexOf(u8, frag_slice, "<head>") == null);
    try std.testing.expect(std.mem.indexOf(u8, frag_slice, "<h1 id=\"heading\">Heading</h1>") != null);
    try std.testing.expect(std.mem.indexOf(u8, frag_slice, "<p>Paragraph text.</p>") != null);

    free_buffer(out_ptr, out_len);
    free_buffer(in_ptr, src.len);
}

test "wasm — virtual files & .include across compile" {
    const header_name = "sub.qmd";
    const header_content = "## Included Section\n\nSome subtext.\n";

    register_virtual_file(header_name.ptr, header_name.len, header_content.ptr, header_content.len);
    defer clear_virtual_files();

    const src = "# Main\n\n.include {sub.qmd}\n";
    const in_ptr = alloc_buffer(src.len) orelse return error.OutOfMemory;
    @memcpy(in_ptr[0..src.len], src);

    const out_ptr = compile_fragment(in_ptr, src.len);
    const out_len = last_compile_len();
    const html = out_ptr[0..out_len];

    try std.testing.expect(std.mem.indexOf(u8, html, "<h1 id=\"main\">Main</h1>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<h2 id=\"included-section\">Included Section</h2>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<p>Some subtext.</p>") != null);

    free_buffer(out_ptr, out_len);
    free_buffer(in_ptr, src.len);
}

test "wasm — compile: leak check" {
    const src = "# Title\n\n.let {x} {42}\n\nValue is $x.\n";
    const in_ptr = alloc_buffer(src.len) orelse return error.OutOfMemory;
    @memcpy(in_ptr[0..src.len], src);

    const out_ptr = compile(in_ptr, src.len);
    const out_len = last_compile_len();

    free_buffer(out_ptr, out_len);
    free_buffer(in_ptr, src.len);

    if (!is_wasm) {
        const result = debug_alloc_state.deinit();
        try std.testing.expect(result != .leak);
        debug_alloc_state = std.heap.DebugAllocator(.{}){};
    }
}

test "wasm — compile_latex and compile_latex_fragment" {
    const src = ".docname {My Article}\n# Introduction\n\nQuarkdown LaTeX $E=mc^2$.\n";
    const in_ptr = alloc_buffer(src.len) orelse return error.OutOfMemory;
    @memcpy(in_ptr[0..src.len], src);

    // 1. Standalone LaTeX
    const out_ptr = compile_latex(in_ptr, src.len);
    const out_len = last_compile_len();
    const tex_slice = out_ptr[0..out_len];

    try std.testing.expect(std.mem.indexOf(u8, tex_slice, "\\documentclass[11pt,a4paper]{article}") != null);
    try std.testing.expect(std.mem.indexOf(u8, tex_slice, "\\title{My Article}") != null);
    try std.testing.expect(std.mem.indexOf(u8, tex_slice, "\\section{Introduction}") != null);
    try std.testing.expect(std.mem.indexOf(u8, tex_slice, "$E=mc^2$") != null);
    try std.testing.expect(std.mem.indexOf(u8, tex_slice, "\\end{document}") != null);

    free_buffer(out_ptr, out_len);

    // 2. Fragment LaTeX
    const frag_ptr = compile_latex_fragment(in_ptr, src.len);
    const frag_len = last_compile_len();
    const frag_slice = frag_ptr[0..frag_len];

    try std.testing.expect(std.mem.indexOf(u8, frag_slice, "\\documentclass") == null);
    try std.testing.expect(std.mem.indexOf(u8, frag_slice, "\\section{Introduction}") != null);

    free_buffer(frag_ptr, frag_len);
    free_buffer(in_ptr, src.len);

    if (!is_wasm) {
        const result = debug_alloc_state.deinit();
        try std.testing.expect(result != .leak);
        debug_alloc_state = std.heap.DebugAllocator(.{}){};
    }
}

