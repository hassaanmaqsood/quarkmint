//! main.zig — Quarkdown CLI (Native executable).
//!
//! Provides the command line interface for:
//!   - Compiling documents to HTML, LaTeX, and PDF
//!   - Quarkdoc static site generator (`qdwasm doc`)
//!   - Language Server Protocol daemon (`qdwasm lsp`)
//!   - Subdocument graph analysis and cycle checking (`qdwasm graph`)

const std = @import("std");
const parser = @import("parser.zig");
const context_mod = @import("context.zig");
const evaluator = @import("evaluator.zig");
const renderer_mod = @import("renderer.zig");
const latex_mod = @import("latex.zig");
const post = @import("post.zig");
const stdlib = @import("stdlib.zig");
const graph_mod = @import("graph.zig");
const lsp_mod = @import("lsp.zig");
const doc_mod = @import("doc.zig");

const Context = context_mod.Context;
const Renderer = renderer_mod.Renderer;
const LaTeXRenderer = latex_mod.LaTeXRenderer;
const Allocator = std.mem.Allocator;

pub const VERSION = "0.2.0";

const Usage =
    \\Usage: quarkmint [options] <input.qmd>
    \\       quarkmint doc <input_dir> -o <output_dir>
    \\       quarkmint lsp
    \\       quarkmint graph <input.qmd> [--dot|--json]
    \\
    \\Commands:
    \\  <input.qmd>             Compile a single Quarkmint document (HTML default)
    \\  doc <dir>               Compile a directory of docs into an SSG website
    \\  lsp                     Start the Language Server Protocol (LSP) server
    \\  graph <file>            Analyze and output subdocument dependency graph
    \\
    \\Options:
    \\  -o, --output <file>     Output file path (default: stdout or <input>.html/.tex/.pdf)
    \\  --latex                 Emit LaTeX instead of HTML
    \\  --pdf                   Compile directly to PDF (via tectonic, pdflatex, xelatex, or wasm)
    \\  --engine <name>         TeX compiler engine: tectonic, pdflatex, xelatex, wasm (default: auto)
    \\  --fragment              Emit body fragment only (no document shell)
    \\  --dot                   Emit Graphviz DOT format for graph command
    \\  --json                  Emit JSON format for graph command
    \\  -v, --version           Print version and exit
    \\  -h, --help              Print this help text and exit
    \\
;

fn writeStdout(msg: []const u8) void {
    if (@import("builtin").os.tag == .linux) {
        _ = std.os.linux.write(1, msg.ptr, msg.len);
    } else {
        std.debug.print("{s}", .{msg});
    }
}

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const io = init.io;
    const cwd = std.Io.Dir.cwd();

    var args = init.minimal.args.iterate();

    // Skip argv[0]
    _ = args.next();

    var input_path: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;
    var emit_latex: bool = false;
    var emit_pdf: bool = false;
    var is_fragment: bool = false;
    var engine_name: ?[]const u8 = null;
    var is_dot: bool = false;
    var is_json: bool = false;

    var is_doc_cmd: bool = false;
    var is_lsp_cmd: bool = false;
    var is_graph_cmd: bool = false;
    var doc_in_dir: ?[]const u8 = null;
    var doc_out_dir: ?[]const u8 = null;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            writeStdout(Usage);
            return;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--version")) {
            writeStdout("quarkmint version " ++ VERSION ++ "\n");
            return;
        } else if (std.mem.eql(u8, arg, "lsp")) {
            is_lsp_cmd = true;
        } else if (std.mem.eql(u8, arg, "doc")) {
            is_doc_cmd = true;
            doc_in_dir = args.next();
        } else if (std.mem.eql(u8, arg, "graph")) {
            is_graph_cmd = true;
            input_path = args.next();
        } else if (std.mem.eql(u8, arg, "--latex")) {
            emit_latex = true;
        } else if (std.mem.eql(u8, arg, "--pdf")) {
            emit_pdf = true;
        } else if (std.mem.eql(u8, arg, "--fragment")) {
            is_fragment = true;
        } else if (std.mem.eql(u8, arg, "--dot")) {
            is_dot = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            is_json = true;
        } else if (std.mem.eql(u8, arg, "--engine")) {
            engine_name = args.next();
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            if (is_doc_cmd) {
                doc_out_dir = args.next();
            } else {
                output_path = args.next();
            }
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            if (input_path == null) {
                input_path = arg;
            }
        }
    }

    if (is_lsp_cmd) {
        try lsp_mod.runStdio(alloc);
        return;
    }

    if (is_doc_cmd) {
        const in_dir = doc_in_dir orelse {
            std.debug.print("Error: missing input directory for 'doc' command\n\n{s}", .{Usage});
            return error.InvalidArguments;
        };
        const out_dir = doc_out_dir orelse "site";

        var ssg = doc_mod.Quarkdoc.init(alloc, io, in_dir, out_dir);
        defer ssg.deinit();

        try ssg.build();
        std.debug.print("Quarkdoc built static site successfully at '{s}'\n", .{out_dir});
        return;
    }

    if (is_graph_cmd) {
        const file_path = input_path orelse {
            std.debug.print("Error: missing input file for 'graph' command\n\n{s}", .{Usage});
            return error.InvalidArguments;
        };

        var graph = graph_mod.DocumentGraph.init(alloc);
        defer graph.deinit();

        try graph.buildFromFile(io, file_path);

        if (try graph.detectCycle()) |cycle| {
            std.debug.print("Warning: Circular include cycle detected: ", .{});
            for (cycle.items, 0..) |item, i| {
                if (i > 0) std.debug.print(" -> ", .{});
                std.debug.print("{s}", .{item});
            }
            std.debug.print("\n", .{});
            var c = cycle;
            c.deinit(alloc);
        }

        var out_buf = std.ArrayList(u8).empty;
        defer out_buf.deinit(alloc);

        if (is_json) {
            try graph.toJson(&out_buf);
        } else {
            try graph.toDot(&out_buf);
        }

        writeStdout(out_buf.items);
        writeStdout("\n");
        return;
    }

    const in_file = input_path orelse {
        std.debug.print("Error: No input file specified.\n\n{s}", .{Usage});
        return error.InvalidArguments;
    };

    // Read input file
    const src = try cwd.readFileAlloc(io, in_file, alloc, .unlimited);
    defer alloc.free(src);

    stdlib.register();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var parse_res = try parser.parse(a, src);
    defer parse_res.deinit();

    var ctx = try Context.init(a, .{ .standalone = !is_fragment });
    defer ctx.deinit();

    const eval_nodes = try evaluator.evaluate(&ctx, parse_res.nodes.items);

    if (emit_pdf) {
        // Compile LaTeX first, then compile to PDF
        var body_buf = std.ArrayList(u8).empty;
        defer body_buf.deinit(a);
        var renderer = LaTeXRenderer.init(a, &body_buf, &ctx);
        try renderer.renderAll(eval_nodes.items);

        var tex_buf = std.ArrayList(u8).empty;
        defer tex_buf.deinit(a);
        try latex_mod.buildLaTeXDocument(a, &tex_buf, &ctx, body_buf.items);

        const out_pdf = output_path orelse blk: {
            const base = if (std.mem.endsWith(u8, in_file, ".qmd"))
                in_file[0 .. in_file.len - 4]
            else if (std.mem.endsWith(u8, in_file, ".md"))
                in_file[0 .. in_file.len - 3]
            else
                in_file;
            break :blk try std.fmt.allocPrint(alloc, "{s}.pdf", .{base});
        };
        defer if (output_path == null) alloc.free(out_pdf);

        try compilePdfFromLatex(alloc, io, tex_buf.items, out_pdf, engine_name);
        std.debug.print("Generated PDF: {s}\n", .{out_pdf});
        return;
    } else if (emit_latex) {
        var body_buf = std.ArrayList(u8).empty;
        defer body_buf.deinit(a);
        var renderer = LaTeXRenderer.init(a, &body_buf, &ctx);
        try renderer.renderAll(eval_nodes.items);

        var out_buf = std.ArrayList(u8).empty;
        defer out_buf.deinit(a);

        if (!is_fragment) {
            try latex_mod.buildLaTeXDocument(a, &out_buf, &ctx, body_buf.items);
        } else {
            out_buf = body_buf;
        }

        if (output_path) |out_file_path| {
            const out_f = try cwd.createFile(io, out_file_path, .{});
            defer out_f.close(io);
            try out_f.writeStreamingAll(io, out_buf.items);
            std.debug.print("Generated LaTeX: {s}\n", .{out_file_path});
        } else {
            writeStdout(out_buf.items);
        }
    } else {
        // HTML output
        var body_buf = std.ArrayList(u8).empty;
        defer body_buf.deinit(a);
        var renderer = Renderer.init(a, &body_buf, &ctx);
        try renderer.renderAll(eval_nodes.items);

        var out_buf = std.ArrayList(u8).empty;
        defer out_buf.deinit(a);

        if (!is_fragment) {
            try post.buildDocument(a, &out_buf, &ctx, body_buf.items);
        } else {
            out_buf = body_buf;
        }

        if (output_path) |out_file_path| {
            const out_f = try cwd.createFile(io, out_file_path, .{});
            defer out_f.close(io);
            try out_f.writeStreamingAll(io, out_buf.items);
            std.debug.print("Generated HTML: {s}\n", .{out_file_path});
        } else {
            writeStdout(out_buf.items);
        }
    }
}

var g_tmp_counter: u64 = 0;

fn compilePdfFromLatex(
    alloc: Allocator,
    io: std.Io,
    latex_source: []const u8,
    out_pdf_path: []const u8,
    preferred_engine: ?[]const u8,
) !void {
    const cwd = std.Io.Dir.cwd();
    g_tmp_counter +%= 1;
    const pid = if (@import("builtin").os.tag == .linux) std.os.linux.getpid() else 1234;
    const tmp_dir_name = try std.fmt.allocPrint(alloc, "/tmp/quarkmint-tex-{d}-{d}", .{ pid, g_tmp_counter });
    defer alloc.free(tmp_dir_name);

    try cwd.createDirPath(io, tmp_dir_name);
    defer cwd.deleteTree(io, tmp_dir_name) catch {};

    const tex_file_path = try std.fs.path.join(alloc, &[_][]const u8{ tmp_dir_name, "document.tex" });
    defer alloc.free(tex_file_path);

    const generated_pdf_path = try std.fs.path.join(alloc, &[_][]const u8{ tmp_dir_name, "document.pdf" });
    defer alloc.free(generated_pdf_path);

    const f = try cwd.createFile(io, tex_file_path, .{});
    try f.writeStreamingAll(io, latex_source);
    f.close(io);

    const engines = if (preferred_engine) |pe|
        &[_][]const u8{pe}
    else
        &[_][]const u8{ "tectonic", "pdflatex", "xelatex" };

    var compiled = false;
    for (engines) |engine| {
        if (std.mem.eql(u8, engine, "tectonic")) {
            const res = std.process.run(alloc, io, .{
                .argv = &[_][]const u8{ "tectonic", tex_file_path, "-o", tmp_dir_name },
            }) catch continue;
            defer alloc.free(res.stdout);
            defer alloc.free(res.stderr);
            if (res.term == .exited and res.term.exited == 0) {
                compiled = true;
                break;
            }
        } else if (std.mem.eql(u8, engine, "pdflatex") or std.mem.eql(u8, engine, "xelatex")) {
            const out_dir_arg = try std.fmt.allocPrint(alloc, "-output-directory={s}", .{tmp_dir_name});
            defer alloc.free(out_dir_arg);

            const res = std.process.run(alloc, io, .{
                .argv = &[_][]const u8{ engine, "-interaction=nonstopmode", out_dir_arg, tex_file_path },
            }) catch continue;
            defer alloc.free(res.stdout);
            defer alloc.free(res.stderr);
            if (res.term == .exited and res.term.exited == 0) {
                compiled = true;
                break;
            }
        } else if (std.mem.eql(u8, engine, "wasm")) {
            std.debug.print("Note: Wasm TeX compilation invoked from native CLI. Run via Node/browser runner or ensure pdflatex.wasm CLI runner is installed.\n", .{});
        }
    }

    if (!compiled) {
        std.debug.print("Error: Could not compile PDF. No suitable LaTeX engine (tectonic, pdflatex, xelatex) succeeded.\n", .{});
        return error.PdfCompilationFailed;
    }

    // Copy generated PDF to out_pdf_path
    try cwd.copyFile(generated_pdf_path, cwd, out_pdf_path, io, .{});
}
