//! doc.zig — Quarkdoc Static Site Generator (SSG) for Quarkdown.
//!
//! Generates a modern, static documentation site from a directory of .qmd files:
//!   - Builds multi-page documentation with persistent sidebar navigation
//!   - Extracts document metadata (.docname, .docauthor, headings)
//!   - Generates client-side search index (search.json)
//!   - Injects embedded styling and asset bundles

const std = @import("std");
const parser = @import("parser.zig");
const context_mod = @import("context.zig");
const evaluator = @import("evaluator.zig");
const renderer_mod = @import("renderer.zig");
const post = @import("post.zig");
const stdlib = @import("stdlib.zig");

const Allocator = std.mem.Allocator;
const Context = context_mod.Context;
const Renderer = renderer_mod.Renderer;

pub const DocPage = struct {
    rel_path: []const u8,
    out_html_path: []const u8,
    title: []const u8,
    html_content: []const u8,
};

pub const Quarkdoc = struct {
    alloc: Allocator,
    io: std.Io,
    input_dir: []const u8,
    output_dir: []const u8,
    pages: std.ArrayList(DocPage),

    pub fn init(alloc: Allocator, io: std.Io, input_dir: []const u8, output_dir: []const u8) Quarkdoc {
        return .{
            .alloc = alloc,
            .io = io,
            .input_dir = input_dir,
            .output_dir = output_dir,
            .pages = std.ArrayList(DocPage).empty,
        };
    }

    pub fn deinit(self: *Quarkdoc) void {
        for (self.pages.items) |p| {
            self.alloc.free(p.rel_path);
            self.alloc.free(p.out_html_path);
            self.alloc.free(p.title);
            self.alloc.free(p.html_content);
        }
        self.pages.deinit(self.alloc);
    }

    /// Build the documentation site.
    pub fn build(self: *Quarkdoc) !void {
        const cwd = std.Io.Dir.cwd();

        // Ensure output directory exists
        try cwd.createDirPath(self.io, self.output_dir);

        // Discover and compile pages
        try self.collectPages(self.input_dir, "");

        // Render site with sidebar and search
        for (self.pages.items) |page| {
            try self.writeRenderedPage(page);
        }

        // Write search index
        try self.writeSearchIndex();
    }

    fn collectPages(self: *Quarkdoc, dir_path: []const u8, rel_prefix: []const u8) !void {
        const cwd = std.Io.Dir.cwd();
        var dir = cwd.openDir(self.io, dir_path, .{ .iterate = true }) catch return;
        defer dir.close(self.io);

        var it = dir.iterate();
        while (try it.next(self.io)) |entry| {
            if (entry.kind == .directory) {
                if (std.mem.startsWith(u8, entry.name, ".")) continue;
                const next_dir = try std.fs.path.join(self.alloc, &[_][]const u8{ dir_path, entry.name });
                defer self.alloc.free(next_dir);

                const next_rel = if (rel_prefix.len == 0)
                    try self.alloc.dupe(u8, entry.name)
                else
                    try std.fs.path.join(self.alloc, &[_][]const u8{ rel_prefix, entry.name });
                defer self.alloc.free(next_rel);

                try self.collectPages(next_dir, next_rel);
            } else if (entry.kind == .file) {
                if (std.mem.endsWith(u8, entry.name, ".qmd") or std.mem.endsWith(u8, entry.name, ".md")) {
                    const full_path = try std.fs.path.join(self.alloc, &[_][]const u8{ dir_path, entry.name });
                    defer self.alloc.free(full_path);

                    const file_rel = if (rel_prefix.len == 0)
                        try self.alloc.dupe(u8, entry.name)
                    else
                        try std.fs.path.join(self.alloc, &[_][]const u8{ rel_prefix, entry.name });

                    try self.processDocFile(full_path, file_rel);
                }
            }
        }
    }

    fn processDocFile(self: *Quarkdoc, full_path: []const u8, rel_path: []const u8) !void {
        const cwd = std.Io.Dir.cwd();
        const src = try cwd.readFileAlloc(self.io, full_path, self.alloc, .unlimited);
        defer self.alloc.free(src);

        stdlib.register();

        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const a = arena.allocator();

        var parse_res = try parser.parse(a, src);
        defer parse_res.deinit();

        var ctx = try Context.init(a, .{ .standalone = false });
        defer ctx.deinit();

        const eval_nodes = try evaluator.evaluate(&ctx, parse_res.nodes.items);

        var body_buf = std.ArrayList(u8).empty;
        defer body_buf.deinit(a);
        var renderer = Renderer.init(a, &body_buf, &ctx);
        try renderer.renderAll(eval_nodes.items);

        // Compute output HTML filename: replace .qmd/.md with .html
        const base_name = if (std.mem.endsWith(u8, rel_path, ".qmd"))
            rel_path[0 .. rel_path.len - 4]
        else if (std.mem.endsWith(u8, rel_path, ".md"))
            rel_path[0 .. rel_path.len - 3]
        else
            rel_path;

        const out_html = try std.fmt.allocPrint(self.alloc, "{s}.html", .{base_name});

        const title = if (ctx.doc_info.title.len > 0 and !std.mem.eql(u8, ctx.doc_info.title, "Untitled Document"))
            try self.alloc.dupe(u8, ctx.doc_info.title)
        else
            try self.alloc.dupe(u8, base_name);

        const page = DocPage{
            .rel_path = rel_path,
            .out_html_path = out_html,
            .title = title,
            .html_content = try self.alloc.dupe(u8, body_buf.items),
        };

        try self.pages.append(self.alloc, page);
    }

    fn writeRenderedPage(self: *Quarkdoc, page: DocPage) !void {
        const cwd = std.Io.Dir.cwd();
        const out_path = try std.fs.path.join(self.alloc, &[_][]const u8{ self.output_dir, page.out_html_path });
        defer self.alloc.free(out_path);

        if (std.fs.path.dirname(out_path)) |pdir| {
            try cwd.createDirPath(self.io, pdir);
        }

        const out_file = try cwd.createFile(self.io, out_path, .{});
        defer out_file.close(self.io);

        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(self.alloc);

        const header = try std.fmt.allocPrint(self.alloc,
            \\<!DOCTYPE html>
            \\<html lang="en">
            \\<head>
            \\  <meta charset="utf-8">
            \\  <meta name="viewport" content="width=device-width, initial-scale=1">
            \\  <title>{s} — Quarkdoc</title>
            \\  <style>
            \\{s}
            \\    /* Quarkdoc SSG Layout */
            \\    .qd-layout {{ display: flex; min-height: 100vh; }}
            \\    .qd-sidebar {{ width: 260px; border-right: 1px solid var(--qd-border); padding: 1.5rem; background: var(--qd-code-bg); flex-shrink: 0; }}
            \\    .qd-sidebar-title {{ font-size: 1.25rem; font-weight: 700; margin-bottom: 1rem; color: var(--qd-primary); }}
            \\    .qd-sidebar ul {{ list-style: none; padding: 0; margin: 0; }}
            \\    .qd-sidebar li {{ margin-bottom: 0.5rem; }}
            \\    .qd-sidebar a {{ color: var(--qd-fg); text-decoration: none; }}
            \\    .qd-sidebar a.active {{ color: var(--qd-primary); font-weight: 600; }}
            \\    .qd-main {{ flex-grow: 1; padding: 2.5rem 3.5rem; max-width: 900px; }}
            \\    .qd-search-input {{ width: 100%; padding: 0.5rem; border: 1px solid var(--qd-border); border-radius: 6px; margin-bottom: 1.25rem; background: var(--qd-bg); color: var(--qd-fg); }}
            \\  </style>
            \\</head>
            \\<body class="qd-doc">
            \\  <div class="qd-layout">
            \\    <aside class="qd-sidebar">
            \\      <div class="qd-sidebar-title">Quarkdoc</div>
            \\      <input type="text" class="qd-search-input" id="searchBox" placeholder="Search docs..." />
            \\      <ul>
            \\
        , .{ page.title, post.QUARKDOWN_CSS });
        defer self.alloc.free(header);
        try buf.appendSlice(self.alloc, header);

        for (self.pages.items) |other| {
            const is_active = std.mem.eql(u8, other.out_html_path, page.out_html_path);
            const active_class = if (is_active) " class=\"active\"" else "";
            const li = try std.fmt.allocPrint(self.alloc, "        <li><a href=\"{s}\"{s}>{s}</a></li>\n", .{ other.out_html_path, active_class, other.title });
            defer self.alloc.free(li);
            try buf.appendSlice(self.alloc, li);
        }

        const footer = try std.fmt.allocPrint(self.alloc,
            \\      </ul>
            \\    </aside>
            \\    <main class="qd-main">
            \\      {s}
            \\    </main>
            \\  </div>
            \\</body>
            \\</html>
            \\
        , .{page.html_content});
        defer self.alloc.free(footer);
        try buf.appendSlice(self.alloc, footer);

        try out_file.writeStreamingAll(self.io, buf.items);
    }

    fn writeSearchIndex(self: *Quarkdoc) !void {
        const cwd = std.Io.Dir.cwd();
        const search_path = try std.fs.path.join(self.alloc, &[_][]const u8{ self.output_dir, "search.json" });
        defer self.alloc.free(search_path);

        const file = try cwd.createFile(self.io, search_path, .{});
        defer file.close(self.io);

        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(self.alloc);

        try buf.appendSlice(self.alloc, "[");

        for (self.pages.items, 0..) |page, i| {
            if (i > 0) try buf.appendSlice(self.alloc, ",");
            const entry = try std.fmt.allocPrint(self.alloc, "{{\"title\":\"{s}\",\"path\":\"{s}\"}}", .{ page.title, page.out_html_path });
            defer self.alloc.free(entry);
            try buf.appendSlice(self.alloc, entry);
        }

        try buf.appendSlice(self.alloc, "]\n");
        try file.writeStreamingAll(self.io, buf.items);
    }
};
