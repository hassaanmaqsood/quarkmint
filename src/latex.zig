//! latex.zig — Quarkdown AST to LaTeX byte stream renderer.
//!
//! Emits clean, standard, compilable LaTeX from Quarkdown's AST.
//! Supports both body fragments and full standalone documents compatible with
//! pdflatex, xelatex, tectonic, and pdflatex.wasm.

const std = @import("std");
const ast = @import("ast.zig");
const context_mod = @import("context.zig");

const Allocator = std.mem.Allocator;
pub const Node = ast.Node;
pub const Context = context_mod.Context;

/// Escape special LaTeX characters in plain text.
pub fn escapeLatex(alloc: Allocator, buf: *std.ArrayList(u8), text: []const u8) Allocator.Error!void {
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        switch (c) {
            '\\' => try buf.appendSlice(alloc, "\\textbackslash{}"),
            '&' => try buf.appendSlice(alloc, "\\&"),
            '%' => try buf.appendSlice(alloc, "\\%"),
            '$' => try buf.appendSlice(alloc, "\\$"),
            '#' => try buf.appendSlice(alloc, "\\#"),
            '_' => try buf.appendSlice(alloc, "\\_"),
            '{' => try buf.appendSlice(alloc, "\\{"),
            '}' => try buf.appendSlice(alloc, "\\}"),
            '~' => try buf.appendSlice(alloc, "\\textasciitilde{}"),
            '^' => try buf.appendSlice(alloc, "\\textasciicircum{}"),
            '<' => try buf.appendSlice(alloc, "\\textless{}"),
            '>' => try buf.appendSlice(alloc, "\\textgreater{}"),
            else => try buf.append(alloc, c),
        }
        i += 1;
    }
}

pub const LaTeXRenderer = struct {
    buf: *std.ArrayList(u8),
    ctx: *const Context,
    alloc: Allocator,

    pub fn init(alloc: Allocator, buf: *std.ArrayList(u8), ctx: *const Context) LaTeXRenderer {
        return .{
            .buf = buf,
            .ctx = ctx,
            .alloc = alloc,
        };
    }

    /// Render a slice of AST nodes into LaTeX.
    pub fn renderAll(self: *LaTeXRenderer, nodes: []const Node) Allocator.Error!void {
        for (nodes) |node| {
            try self.renderNode(node);
        }
    }

    pub fn renderNode(self: *LaTeXRenderer, node: Node) Allocator.Error!void {
        switch (node) {
            .heading => |h| {
                const cmd = switch (h.level) {
                    1 => "section",
                    2 => "subsection",
                    3 => "subsubsection",
                    4 => "paragraph",
                    5 => "subparagraph",
                    else => "subparagraph",
                };
                try self.buf.appendSlice(self.alloc, "\\");
                try self.buf.appendSlice(self.alloc, cmd);
                if (h.id) |_| {
                    // Standard numbered section
                    try self.buf.append(self.alloc, '{');
                    try escapeLatex(self.alloc, self.buf, h.text);
                    try self.buf.appendSlice(self.alloc, "}\n");
                    if (h.id) |slug| {
                        try self.buf.appendSlice(self.alloc, "\\label{sec:");
                        try self.buf.appendSlice(self.alloc, slug);
                        try self.buf.appendSlice(self.alloc, "}\n");
                    }
                } else {
                    try self.buf.append(self.alloc, '{');
                    try escapeLatex(self.alloc, self.buf, h.text);
                    try self.buf.appendSlice(self.alloc, "}\n");
                }
                try self.buf.append(self.alloc, '\n');
            },

            .paragraph => |p| {
                try escapeLatex(self.alloc, self.buf, p);
                try self.buf.appendSlice(self.alloc, "\n\n");
            },

            .rich_block => |rb| {
                for (rb.items) |child| {
                    try self.renderInline(child);
                }
                try self.buf.appendSlice(self.alloc, "\n\n");
            },

            .text => |t| {
                try escapeLatex(self.alloc, self.buf, t);
            },

            .emphasis => |e| {
                try self.buf.appendSlice(self.alloc, "\\textit{");
                try escapeLatex(self.alloc, self.buf, e);
                try self.buf.append(self.alloc, '}');
            },

            .strong => |s| {
                try self.buf.appendSlice(self.alloc, "\\textbf{");
                try escapeLatex(self.alloc, self.buf, s);
                try self.buf.append(self.alloc, '}');
            },

            .strikethrough => |s| {
                try self.buf.appendSlice(self.alloc, "\\sout{");
                try escapeLatex(self.alloc, self.buf, s);
                try self.buf.append(self.alloc, '}');
            },

            .code_span => |cs| {
                try self.buf.appendSlice(self.alloc, "\\texttt{");
                try escapeLatex(self.alloc, self.buf, cs);
                try self.buf.append(self.alloc, '}');
            },

            .code_block => |cb| {
                if (cb.language.len > 0) {
                    try self.buf.appendSlice(self.alloc, "\\begin{lstlisting}[language=");
                    try self.buf.appendSlice(self.alloc, cb.language);
                    try self.buf.appendSlice(self.alloc, "]\n");
                } else {
                    try self.buf.appendSlice(self.alloc, "\\begin{lstlisting}\n");
                }
                try self.buf.appendSlice(self.alloc, cb.content);
                if (cb.content.len > 0 and cb.content[cb.content.len - 1] != '\n') {
                    try self.buf.append(self.alloc, '\n');
                }
                try self.buf.appendSlice(self.alloc, "\\end{lstlisting}\n\n");
            },

            .blockquote => |b| {
                try self.buf.appendSlice(self.alloc, "\\begin{quote}\n");
                try escapeLatex(self.alloc, self.buf, b);
                try self.buf.appendSlice(self.alloc, "\n\\end{quote}\n\n");
            },

            .thematic_break => {
                try self.buf.appendSlice(self.alloc, "\\bigskip\\noindent\\hrule\\bigskip\n\n");
            },

            .list => |l| {
                const env = if (l.ordered) "enumerate" else "itemize";
                try self.buf.appendSlice(self.alloc, "\\begin{");
                try self.buf.appendSlice(self.alloc, env);
                try self.buf.appendSlice(self.alloc, "}\n");

                for (l.items.items) |item| {
                    try self.buf.appendSlice(self.alloc, "  \\item ");
                    if (item.checked) |chk| {
                        if (chk) {
                            try self.buf.appendSlice(self.alloc, "[$\\boxtimes$] ");
                        } else {
                            try self.buf.appendSlice(self.alloc, "[$\\square$] ");
                        }
                    }
                    try escapeLatex(self.alloc, self.buf, item.text);
                    try self.buf.append(self.alloc, '\n');
                }

                try self.buf.appendSlice(self.alloc, "\\end{");
                try self.buf.appendSlice(self.alloc, env);
                try self.buf.appendSlice(self.alloc, "}\n\n");
            },

            .table => |tbl| {
                if (tbl.headers.items.len == 0 and tbl.rows.items.len == 0) return;

                const col_count = if (tbl.headers.items.len > 0)
                    tbl.headers.items.len
                else if (tbl.rows.items.len > 0)
                    tbl.rows.items[0].items.len
                else
                    0;

                if (col_count == 0) return;

                try self.buf.appendSlice(self.alloc, "\\begin{center}\n\\begin{tabular}{");
                var c_idx: usize = 0;
                while (c_idx < col_count) : (c_idx += 1) {
                    const align_char: u8 = if (c_idx < tbl.alignments.items.len)
                        switch (tbl.alignments.items[c_idx]) {
                            .left => 'l',
                            .center => 'c',
                            .right => 'r',
                            .none => 'l',
                        }
                    else
                        'l';
                    try self.buf.append(self.alloc, align_char);
                    if (c_idx + 1 < col_count) try self.buf.append(self.alloc, ' ');
                }
                try self.buf.appendSlice(self.alloc, "}\n\\hline\n");

                if (tbl.headers.items.len > 0) {
                    for (tbl.headers.items, 0..) |h, i| {
                        try self.buf.appendSlice(self.alloc, "\\textbf{");
                        try escapeLatex(self.alloc, self.buf, h);
                        try self.buf.append(self.alloc, '}');
                        if (i + 1 < tbl.headers.items.len) {
                            try self.buf.appendSlice(self.alloc, " & ");
                        } else {
                            try self.buf.appendSlice(self.alloc, " \\\\\n\\hline\n");
                        }
                    }
                }

                for (tbl.rows.items) |row| {
                    for (row.items, 0..) |cell, i| {
                        try escapeLatex(self.alloc, self.buf, cell);
                        if (i + 1 < row.items.len) {
                            try self.buf.appendSlice(self.alloc, " & ");
                        } else {
                            try self.buf.appendSlice(self.alloc, " \\\\\n");
                        }
                    }
                }

                try self.buf.appendSlice(self.alloc, "\\hline\n\\end{tabular}\n\\end{center}\n\n");
            },

            .link => |l| {
                try self.buf.appendSlice(self.alloc, "\\href{");
                try self.buf.appendSlice(self.alloc, l.url);
                try self.buf.appendSlice(self.alloc, "}{");
                try escapeLatex(self.alloc, self.buf, l.text);
                try self.buf.append(self.alloc, '}');
            },

            .image => |img| {
                try self.buf.appendSlice(self.alloc, "\\begin{figure}[htbp]\n\\centering\n");
                try self.buf.appendSlice(self.alloc, "\\includegraphics[max width=\\textwidth]{");
                try self.buf.appendSlice(self.alloc, img.url);
                try self.buf.appendSlice(self.alloc, "}\n");
                if (img.alt.len > 0) {
                    try self.buf.appendSlice(self.alloc, "\\caption{");
                    try escapeLatex(self.alloc, self.buf, img.alt);
                    try self.buf.appendSlice(self.alloc, "}\n");
                }
                try self.buf.appendSlice(self.alloc, "\\end{figure}\n\n");
            },

            .auto_link => |al| {
                try self.buf.appendSlice(self.alloc, "\\url{");
                try self.buf.appendSlice(self.alloc, al);
                try self.buf.append(self.alloc, '}');
            },

            .html_inline, .html_block => {
                // Raw HTML has no direct LaTeX mapping; omitted or converted to comment
            },

            .math_block => |mb| {
                try self.buf.appendSlice(self.alloc, "\\[\n");
                try self.buf.appendSlice(self.alloc, mb);
                try self.buf.appendSlice(self.alloc, "\n\\]\n\n");
            },

            .math_span => |ms| {
                try self.buf.append(self.alloc, '$');
                try self.buf.appendSlice(self.alloc, ms);
                try self.buf.append(self.alloc, '$');
            },

            .box => |b| {
                if (b.title) |t| {
                    try self.buf.appendSlice(self.alloc, "\\begin{tcolorbox}[title={");
                    try escapeLatex(self.alloc, self.buf, t);
                    try self.buf.appendSlice(self.alloc, "}]\n");
                } else {
                    try self.buf.appendSlice(self.alloc, "\\begin{tcolorbox}\n");
                }
                try escapeLatex(self.alloc, self.buf, b.content);
                try self.buf.appendSlice(self.alloc, "\n\\end{tcolorbox}\n\n");
            },

            .stacked => |s| {
                try escapeLatex(self.alloc, self.buf, s.content);
                try self.buf.appendSlice(self.alloc, "\n\n");
            },

            .page_break => {
                try self.buf.appendSlice(self.alloc, "\\newpage\n\n");
            },

            .line_break => {
                try self.buf.appendSlice(self.alloc, "\\newline\n");
            },

            .soft_break => {
                try self.buf.append(self.alloc, '\n');
            },

            .blank => {},

            .link_definition, .footnote_definition => {},

            .parse_error => |e| {
                try self.buf.appendSlice(self.alloc, "\\begin{tcolorbox}[colback=red!5!white,colframe=red!75!black,title={Error}]\n");
                try escapeLatex(self.alloc, self.buf, e.message);
                try self.buf.appendSlice(self.alloc, "\n\\end{tcolorbox}\n\n");
            },

            .function_call => |fc| {
                try self.buf.appendSlice(self.alloc, "\\texttt{.");
                try escapeLatex(self.alloc, self.buf, fc.name);
                try self.buf.append(self.alloc, '}');
            },
        }
    }

    fn renderInline(self: *LaTeXRenderer, node: Node) Allocator.Error!void {
        try self.renderNode(node);
    }
};

/// Wrap body LaTeX into a complete compilable LaTeX document.
pub fn buildLaTeXDocument(
    alloc: Allocator,
    out: *std.ArrayList(u8),
    ctx: *const Context,
    body: []const u8,
) Allocator.Error!void {
    try out.appendSlice(alloc,
        \\% Generated by Quarkmint WebAssembly Engine
        \\\documentclass[11pt,a4paper]{article}
        \\\usepackage[utf8]{inputenc}
        \\\usepackage[margin=1in]{geometry}
        \\\usepackage{amsmath,amssymb}
        \\\usepackage{graphicx}
        \\\usepackage[export]{adjustbox}
        \\\usepackage{hyperref}
        \\\usepackage{ulem}
        \\\usepackage{listings}
        \\\usepackage{tcolorbox}
        \\\usepackage{xcolor}
        \\
        \\\lstset{
        \\  basicstyle=\ttfamily\small,
        \\  breaklines=true,
        \\  frame=single,
        \\  backgroundcolor=\color{black!5}
        \\}
        \\
    );

    // Metadata
    if (ctx.doc_info.title.len > 0) {
        try out.appendSlice(alloc, "\\title{");
        try escapeLatex(alloc, out, ctx.doc_info.title);
        try out.appendSlice(alloc, "}\n");
    }

    if (ctx.doc_info.author.len > 0) {
        try out.appendSlice(alloc, "\\author{");
        try escapeLatex(alloc, out, ctx.doc_info.author);
        try out.appendSlice(alloc, "}\n");
    }

    if (ctx.doc_info.date.len > 0) {
        try out.appendSlice(alloc, "\\date{");
        try escapeLatex(alloc, out, ctx.doc_info.date);
        try out.appendSlice(alloc, "}\n");
    }

    try out.appendSlice(alloc,
        \\
        \\\begin{document}
        \\
    );

    if (ctx.doc_info.title.len > 0) {
        try out.appendSlice(alloc, "\\maketitle\n\n");
    }

    try out.appendSlice(alloc, body);

    try out.appendSlice(alloc,
        \\
        \\\end{document}
        \\
    );
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

test "latex — escape special characters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var buf: std.ArrayList(u8) = .empty;
    try escapeLatex(alloc, &buf, "100% of $5 & #1 {foo_bar}");
    try std.testing.expectEqualStrings("100\\% of \\$5 \\& \\#1 \\{foo\\_bar\\}", buf.items);
}

test "latex — heading and paragraph rendering" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const ctx = try Context.init(alloc, .{});
    var buf: std.ArrayList(u8) = .empty;
    var renderer = LaTeXRenderer.init(alloc, &buf, &ctx);

    const nodes = [_]Node{
        .{ .heading = .{ .level = 1, .text = "Introduction" } },
        .{ .paragraph = "Hello, world!" },
        .{ .math_span = "E=mc^2" },
    };

    try renderer.renderAll(&nodes);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\\section{Introduction}") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "Hello, world!") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "$E=mc^2$") != null);
}
