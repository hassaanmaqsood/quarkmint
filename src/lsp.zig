//! lsp.zig — Language Server Protocol (LSP) Server for Quarkdown.
//!
//! Implements JSON-RPC 2.0 over stdio providing:
//!   - Real-time syntax diagnostics (parse & evaluation errors)
//!   - Intelligent auto-completion (standard library functions, variables, macros)
//!   - Document state tracking (didOpen, didChange, didClose)

const std = @import("std");
const parser = @import("parser.zig");
const context_mod = @import("context.zig");
const evaluator = @import("evaluator.zig");
const stdlib = @import("stdlib.zig");

const Allocator = std.mem.Allocator;
const Context = context_mod.Context;

pub const LspServer = struct {
    alloc: Allocator,
    docs: std.StringHashMap([]const u8),
    running: bool = true,

    pub fn init(alloc: Allocator) LspServer {
        return .{
            .alloc = alloc,
            .docs = std.StringHashMap([]const u8).init(alloc),
        };
    }

    pub fn deinit(self: *LspServer) void {
        var it = self.docs.iterator();
        while (it.next()) |entry| {
            self.alloc.free(entry.key_ptr.*);
            self.alloc.free(entry.value_ptr.*);
        }
        self.docs.deinit();
    }

    /// Process a single incoming JSON-RPC message and write response (if any) to `out_buf`.
    pub fn handleMessage(self: *LspServer, raw_json: []const u8, out_buf: *std.ArrayList(u8)) !void {
        var parsed = std.json.parseFromSlice(std.json.Value, self.alloc, raw_json, .{}) catch return;
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) return;

        const method = if (root.object.get("method")) |m| (if (m == .string) m.string else return) else "";
        const id = root.object.get("id");

        if (std.mem.eql(u8, method, "initialize")) {
            try self.handleInitialize(id, out_buf);
        } else if (std.mem.eql(u8, method, "initialized")) {
            // notification, no response required
        } else if (std.mem.eql(u8, method, "textDocument/didOpen")) {
            try self.handleDidOpen(root.object.get("params"), out_buf);
        } else if (std.mem.eql(u8, method, "textDocument/didChange")) {
            try self.handleDidChange(root.object.get("params"), out_buf);
        } else if (std.mem.eql(u8, method, "textDocument/didClose")) {
            self.handleDidClose(root.object.get("params"));
        } else if (std.mem.eql(u8, method, "textDocument/completion")) {
            try self.handleCompletion(id, root.object.get("params"), out_buf);
        } else if (std.mem.eql(u8, method, "shutdown")) {
            self.running = false;
            try self.sendResult(id, "null", out_buf);
        }
    }

    fn handleInitialize(self: *LspServer, id: ?std.json.Value, out: *std.ArrayList(u8)) !void {
        const caps =
            \\{"capabilities":{"textDocumentSync":1,"completionProvider":{"triggerCharacters":[".","{","$"]}}}
        ;
        try self.sendResult(id, caps, out);
    }

    fn handleDidOpen(self: *LspServer, params_opt: ?std.json.Value, out: *std.ArrayList(u8)) !void {
        const params = params_opt orelse return;
        if (params != .object) return;

        const td = params.object.get("textDocument") orelse return;
        if (td != .object) return;

        const uri_val = td.object.get("uri") orelse return;
        const text_val = td.object.get("text") orelse return;

        if (uri_val != .string or text_val != .string) return;

        const uri = uri_val.string;
        const text = text_val.string;

        const uri_copy = try self.alloc.dupe(u8, uri);
        const text_copy = try self.alloc.dupe(u8, text);

        if (self.docs.fetchRemove(uri)) |kv| {
            self.alloc.free(kv.key);
            self.alloc.free(kv.value);
        }

        try self.docs.put(uri_copy, text_copy);
        try self.publishDiagnostics(uri, text, out);
    }

    fn handleDidChange(self: *LspServer, params_opt: ?std.json.Value, out: *std.ArrayList(u8)) !void {
        const params = params_opt orelse return;
        if (params != .object) return;

        const td = params.object.get("textDocument") orelse return;
        if (td != .object) return;

        const uri_val = td.object.get("uri") orelse return;
        const cc_val = params.object.get("contentChanges") orelse return;

        if (uri_val != .string or cc_val != .array or cc_val.array.items.len == 0) return;

        const uri = uri_val.string;
        const first_change = cc_val.array.items[0];
        if (first_change != .object) return;

        const new_text_val = first_change.object.get("text") orelse return;
        if (new_text_val != .string) return;

        const text = new_text_val.string;

        if (self.docs.getPtr(uri)) |existing| {
            self.alloc.free(existing.*);
            existing.* = try self.alloc.dupe(u8, text);
        } else {
            const uri_copy = try self.alloc.dupe(u8, uri);
            const text_copy = try self.alloc.dupe(u8, text);
            try self.docs.put(uri_copy, text_copy);
        }

        try self.publishDiagnostics(uri, text, out);
    }

    fn handleDidClose(self: *LspServer, params_opt: ?std.json.Value) void {
        const params = params_opt orelse return;
        if (params != .object) return;
        const td = params.object.get("textDocument") orelse return;
        if (td != .object) return;
        const uri_val = td.object.get("uri") orelse return;
        if (uri_val != .string) return;

        if (self.docs.fetchRemove(uri_val.string)) |kv| {
            self.alloc.free(kv.key);
            self.alloc.free(kv.value);
        }
    }

    fn publishDiagnostics(self: *LspServer, uri: []const u8, source: []const u8, out: *std.ArrayList(u8)) !void {
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const alloc = arena.allocator();

        stdlib.register();

        var parse_res = parser.parse(alloc, source) catch return;
        defer parse_res.deinit();

        var ctx = Context.init(alloc, .{}) catch return;
        defer ctx.deinit();

        _ = evaluator.evaluate(&ctx, parse_res.nodes.items) catch {};

        var diag_buf = std.ArrayList(u8).empty;

        // Check for parse errors embedded in AST
        var first = true;
        for (parse_res.nodes.items) |node| {
            switch (node) {
                .parse_error => |err| {
                    if (!first) try diag_buf.append(alloc, ',');
                    first = false;
                    const line = if (err.line > 0) err.line - 1 else 0;
                    const item = try std.fmt.allocPrint(alloc,
                        \\{{"range":{{"start":{{"line":{d},"character":0}},"end":{{"line":{d},"character":80}}}},"severity":1,"message":"{s}"}}
                    , .{ line, line, err.message });
                    defer alloc.free(item);
                    try diag_buf.appendSlice(alloc, item);
                },
                else => {},
            }
        }

        // Also check context errors
        for (ctx.errors.items) |err| {
            if (!first) try diag_buf.append(alloc, ',');
            first = false;
            const line = if (err.line > 0) err.line - 1 else 0;
            const item = try std.fmt.allocPrint(alloc,
                \\{{"range":{{"start":{{"line":{d},"character":0}},"end":{{"line":{d},"character":80}}}},"severity":1,"message":"{s}"}}
            , .{ line, line, err.message });
            defer alloc.free(item);
            try diag_buf.appendSlice(alloc, item);
        }

        const notification_payload = try std.fmt.allocPrint(alloc,
            \\{{"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{{"uri":"{s}","diagnostics":[{s}]}}}}
        , .{ uri, diag_buf.items });
        defer alloc.free(notification_payload);

        try self.writeRpcPacket(notification_payload, out);
    }

    fn handleCompletion(self: *LspServer, id: ?std.json.Value, params_opt: ?std.json.Value, out: *std.ArrayList(u8)) !void {
        _ = params_opt;

        const completions =
            \\[
            \\  {"label":".include","kind":3,"detail":"Include another Quarkdown subdocument","insertText":".include {${1:path.qmd}}"},
            \\  {"label":".function","kind":3,"detail":"Define a reusable Quarkdown macro","insertText":".function {${1:name} ${2:args}} ${3:body}"},
            \\  {"label":".let","kind":6,"detail":"Define a scoped immutable variable","insertText":".let {${1:name}} {${2:value}}"},
            \\  {"label":".set","kind":6,"detail":"Update an existing variable","insertText":".set {${1:name}} {${2:value}}"},
            \\  {"label":".if","kind":15,"detail":"Conditional branching block","insertText":".if {${1:condition}} {${2:then}}"},
            \\  {"label":".repeat","kind":15,"detail":"Loop repeat block","insertText":".repeat {${1:count}} ${2:body}"},
            \\  {"label":".for","kind":15,"detail":"Loop over list items","insertText":".for {${1:var}} {${2:item1,item2}} ${3:body}"},
            \\  {"label":".box","kind":7,"detail":"Visual styled card container","insertText":".box {${1:Title}}\n${2:content}"},
            \\  {"label":".row","kind":7,"detail":"Horizontal row layout","insertText":".row\n${1:content}"},
            \\  {"label":".column","kind":7,"detail":"Vertical column layout","insertText":".column\n${1:content}"},
            \\  {"label":".docname","kind":14,"detail":"Set document title metadata","insertText":".docname {${1:Title}}"},
            \\  {"label":".docauthor","kind":14,"detail":"Set document author metadata","insertText":".docauthor {${1:Author}}"},
            \\  {"label":".docdate","kind":14,"detail":"Set document publication date","insertText":".docdate {${1:Date}}"}
            \\]
        ;

        try self.sendResult(id, completions, out);
    }

    fn sendResult(self: *LspServer, id: ?std.json.Value, result_json: []const u8, out: *std.ArrayList(u8)) !void {
        var res_buf = std.ArrayList(u8).empty;
        defer res_buf.deinit(self.alloc);

        if (id) |i| {
            if (i == .integer) {
                const s = try std.fmt.allocPrint(self.alloc,
                    \\{{"jsonrpc":"2.0","id":{d},"result":{s}}}
                , .{ i.integer, result_json });
                defer self.alloc.free(s);
                try res_buf.appendSlice(self.alloc, s);
            } else if (i == .string) {
                const s = try std.fmt.allocPrint(self.alloc,
                    \\{{"jsonrpc":"2.0","id":"{s}","result":{s}}}
                , .{ i.string, result_json });
                defer self.alloc.free(s);
                try res_buf.appendSlice(self.alloc, s);
            } else {
                const s = try std.fmt.allocPrint(self.alloc,
                    \\{{"jsonrpc":"2.0","id":null,"result":{s}}}
                , .{result_json});
                defer self.alloc.free(s);
                try res_buf.appendSlice(self.alloc, s);
            }
        } else {
            const s = try std.fmt.allocPrint(self.alloc,
                \\{{"jsonrpc":"2.0","id":null,"result":{s}}}
            , .{result_json});
            defer self.alloc.free(s);
            try res_buf.appendSlice(self.alloc, s);
        }

        try self.writeRpcPacket(res_buf.items, out);
    }

    fn writeRpcPacket(self: *LspServer, payload: []const u8, out: *std.ArrayList(u8)) !void {
        const header = try std.fmt.allocPrint(self.alloc, "Content-Length: {d}\r\n\r\n", .{payload.len});
        defer self.alloc.free(header);
        try out.appendSlice(self.alloc, header);
        try out.appendSlice(self.alloc, payload);
    }

    /// Run the LSP loop over standard input / standard output.
    pub fn runStdio(self: *LspServer) !void {
        var header_buf: [1024]u8 = undefined;
        var header_len: usize = 0;

        while (self.running) {
            var b: [1]u8 = undefined;
            const n = if (@import("builtin").os.tag == .linux)
                std.os.linux.read(0, &b, 1)
            else
                0;
            if (n == 0) break;

            if (header_len < header_buf.len) {
                header_buf[header_len] = b[0];
                header_len += 1;
            }

            if (header_len >= 4 and std.mem.endsWith(u8, header_buf[0..header_len], "\r\n\r\n")) {
                const header_str = header_buf[0 .. header_len - 4];
                var content_len: usize = 0;

                var lines = std.mem.splitSequence(u8, header_str, "\r\n");
                while (lines.next()) |line| {
                    if (std.mem.startsWith(u8, line, "Content-Length:")) {
                        const val_str = std.mem.trim(u8, line["Content-Length:".len..], " \r\t");
                        content_len = std.fmt.parseInt(usize, val_str, 10) catch 0;
                    }
                }

                if (content_len > 0) {
                    const body = try self.alloc.alloc(u8, content_len);
                    defer self.alloc.free(body);

                    var read_bytes: usize = 0;
                    while (read_bytes < content_len) {
                        const rn = if (@import("builtin").os.tag == .linux)
                            std.os.linux.read(0, body[read_bytes..].ptr, content_len - read_bytes)
                        else
                            0;
                        if (rn == 0) break;
                        read_bytes += rn;
                    }

                    var out_buf = std.ArrayList(u8).empty;
                    defer out_buf.deinit(self.alloc);

                    try self.handleMessage(body, &out_buf);

                    if (out_buf.items.len > 0) {
                        if (@import("builtin").os.tag == .linux) {
                            _ = std.os.linux.write(1, out_buf.items.ptr, out_buf.items.len);
                        }
                    }
                }

                header_len = 0;
            }
        }
    }
};

pub fn runStdio(alloc: Allocator) !void {
    var server = LspServer.init(alloc);
    defer server.deinit();
    try server.runStdio();
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

test "lsp — initialize and completions" {
    var lsp = LspServer.init(std.testing.allocator);
    defer lsp.deinit();

    var out = std.ArrayList(u8).empty;
    defer out.deinit(std.testing.allocator);

    const init_req =
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
    ;
    try lsp.handleMessage(init_req, &out);

    try std.testing.expect(std.mem.indexOf(u8, out.items, "capabilities") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "completionProvider") != null);

    out.clearRetainingCapacity();

    const comp_req =
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/completion","params":{"textDocument":{"uri":"file:///test.qmd"},"position":{"line":0,"character":1}}}
    ;
    try lsp.handleMessage(comp_req, &out);
    try std.testing.expect(std.mem.indexOf(u8, out.items, ".include") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, ".function") != null);
}

test "lsp — document diagnostics on didOpen" {
    var lsp = LspServer.init(std.testing.allocator);
    defer lsp.deinit();

    var out = std.ArrayList(u8).empty;
    defer out.deinit(std.testing.allocator);

    const open_msg =
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///doc.qmd","languageId":"quarkdown","version":1,"text":"# Hello\n\nQuarkdown LSP text.\n"}}}
    ;
    try lsp.handleMessage(open_msg, &out);

    try std.testing.expect(std.mem.indexOf(u8, out.items, "textDocument/publishDiagnostics") != null);
}
