//! graph.zig — Quarkdown Subdocument Dependency Graph & Cycle Detection.
//!
//! Analyzes document dependencies via `.include {path}` directives,
//! constructs the directed dependency graph, performs topological sorting,
//! detects circular dependencies, and emits DOT/JSON representations.

const std = @import("std");
const parser = @import("parser.zig");
const ast = @import("ast.zig");

const Allocator = std.mem.Allocator;
const Node = ast.Node;

pub const GraphError = error{
    CircularDependency,
    FileNotFound,
    OutOfMemory,
};

pub const DocumentNode = struct {
    path: []const u8,
    dependencies: std.ArrayList([]const u8),

    pub fn init(path: []const u8) DocumentNode {
        return .{
            .path = path,
            .dependencies = std.ArrayList([]const u8).empty,
        };
    }

    pub fn deinit(self: *DocumentNode, alloc: Allocator) void {
        self.dependencies.deinit(alloc);
    }
};

pub const DocumentGraph = struct {
    alloc: Allocator,
    arena: std.heap.ArenaAllocator,
    nodes: std.StringHashMap(DocumentNode),

    pub fn init(alloc: Allocator) DocumentGraph {
        return .{
            .alloc = alloc,
            .arena = std.heap.ArenaAllocator.init(alloc),
            .nodes = std.StringHashMap(DocumentNode).init(alloc),
        };
    }

    pub fn deinit(self: *DocumentGraph) void {
        self.nodes.deinit();
        self.arena.deinit();
    }

    /// Extract included document paths from raw Quarkdown source.
    pub fn extractIncludes(alloc: Allocator, source: []const u8) Allocator.Error![][]const u8 {
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        const a = arena.allocator();

        var parse_res = parser.parse(a, source) catch return &.{};
        defer parse_res.deinit();

        var includes = std.ArrayList([]const u8).empty;

        for (parse_res.nodes.items) |node| {
            switch (node) {
                .function_call => |fc| {
                    if (std.mem.eql(u8, fc.name, "include")) {
                        if (fc.args.items.len > 0) {
                            const inc_path = fc.args.items[0].value;
                            const copy = try alloc.dupe(u8, inc_path);
                            try includes.append(alloc, copy);
                        }
                    }
                },
                else => {},
            }
        }

        return includes.toOwnedSlice(alloc);
    }

    /// Build graph starting from an entry document in a Virtual File System (or test map).
    pub fn buildFromVfs(
        self: *DocumentGraph,
        entry_path: []const u8,
        vfs: *const std.StringHashMapUnmanaged([]const u8),
    ) GraphError!void {
        var visited = std.StringHashMap(void).init(self.alloc);
        defer visited.deinit();

        try self.traverseVfs(entry_path, vfs, &visited);
    }

    fn traverseVfs(
        self: *DocumentGraph,
        curr_path: []const u8,
        vfs: *const std.StringHashMapUnmanaged([]const u8),
        visited: *std.StringHashMap(void),
    ) GraphError!void {
        if (visited.contains(curr_path)) return;
        try visited.put(curr_path, {});

        const content = vfs.get(curr_path) orelse return error.FileNotFound;

        const a = self.arena.allocator();
        const path_copy = try a.dupe(u8, curr_path);
        var doc_node = DocumentNode.init(path_copy);

        const incs = extractIncludes(a, content) catch return error.OutOfMemory;

        for (incs) |inc| {
            try doc_node.dependencies.append(a, inc);
            try self.traverseVfs(inc, vfs, visited);
        }

        try self.nodes.put(path_copy, doc_node);
    }

    /// Build graph starting from a filesystem path.
    pub fn buildFromFile(
        self: *DocumentGraph,
        io: std.Io,
        entry_path: []const u8,
    ) !void {
        var visited = std.StringHashMap(void).init(self.alloc);
        defer visited.deinit();

        try self.traverseFs(io, entry_path, &visited);
    }

    fn traverseFs(
        self: *DocumentGraph,
        io: std.Io,
        curr_path: []const u8,
        visited: *std.StringHashMap(void),
    ) !void {
        if (visited.contains(curr_path)) return;
        try visited.put(curr_path, {});

        const a = self.arena.allocator();
        const content = std.Io.Dir.cwd().readFileAlloc(io, curr_path, a, .unlimited) catch return error.FileNotFound;

        const path_copy = try a.dupe(u8, curr_path);
        var doc_node = DocumentNode.init(path_copy);

        const incs = try extractIncludes(a, content);

        const parent_dir = std.fs.path.dirname(curr_path) orelse ".";

        for (incs) |inc| {
            const resolved_child = if (std.fs.path.isAbsolute(inc))
                try a.dupe(u8, inc)
            else
                try std.fs.path.join(a, &[_][]const u8{ parent_dir, inc });

            try doc_node.dependencies.append(a, resolved_child);
            try self.traverseFs(io, resolved_child, visited);
        }

        try self.nodes.put(path_copy, doc_node);
    }

    pub const Color = enum { white, gray, black };

    /// Detect cycle in the dependency graph using 3-color DFS.
    /// Returns the cycle nodes path if detected, or null if acyclic.
    pub fn detectCycle(self: *DocumentGraph) Allocator.Error!?std.ArrayList([]const u8) {
        var colors = std.StringHashMap(Color).init(self.alloc);
        defer colors.deinit();

        var cycle_path = std.ArrayList([]const u8).empty;

        var it = self.nodes.iterator();
        while (it.next()) |entry| {
            try colors.put(entry.key_ptr.*, .white);
        }

        it = self.nodes.iterator();
        while (it.next()) |entry| {
            const node_path = entry.key_ptr.*;
            if (colors.get(node_path) == .white) {
                if (try self.dfsCycle(node_path, &colors, &cycle_path)) {
                    return cycle_path;
                }
            }
        }

        cycle_path.deinit(self.alloc);
        return null;
    }

    fn dfsCycle(
        self: *DocumentGraph,
        curr: []const u8,
        colors: *std.StringHashMap(Color),
        cycle_path: *std.ArrayList([]const u8),
    ) Allocator.Error!bool {
        try colors.put(curr, .gray);
        try cycle_path.append(self.alloc, curr);

        if (self.nodes.get(curr)) |node| {
            for (node.dependencies.items) |dep| {
                const color = colors.get(dep) orelse .white;
                if (color == .gray) {
                    try cycle_path.append(self.alloc, dep);
                    return true;
                }
                if (color == .white) {
                    if (try self.dfsCycle(dep, colors, cycle_path)) {
                        return true;
                    }
                }
            }
        }

        _ = cycle_path.pop();
        try colors.put(curr, .black);
        return false;
    }

    /// Topologically sort the dependency graph (leaves/dependencies first).
    pub fn topologicalSort(self: *DocumentGraph) ![][]const u8 {
        if (try self.detectCycle()) |cycle| {
            var c = cycle;
            c.deinit(self.alloc);
            return error.CircularDependency;
        }

        var visited = std.StringHashMap(void).init(self.alloc);
        defer visited.deinit();

        var order = std.ArrayList([]const u8).empty;

        var it = self.nodes.iterator();
        while (it.next()) |entry| {
            try self.dfsTopo(entry.key_ptr.*, &visited, &order);
        }

        return order.toOwnedSlice(self.alloc);
    }

    fn dfsTopo(
        self: *DocumentGraph,
        curr: []const u8,
        visited: *std.StringHashMap(void),
        order: *std.ArrayList([]const u8),
    ) Allocator.Error!void {
        if (visited.contains(curr)) return;
        try visited.put(curr, {});

        if (self.nodes.get(curr)) |node| {
            for (node.dependencies.items) |dep| {
                try self.dfsTopo(dep, visited, order);
            }
        }

        try order.append(self.alloc, curr);
    }

    /// Render graph into Graphviz DOT language format.
    pub fn toDot(self: *DocumentGraph, out: *std.ArrayList(u8)) Allocator.Error!void {
        try out.appendSlice(self.alloc, "digraph QuarkdownDependencies {\n");
        try out.appendSlice(self.alloc, "  rankdir=LR;\n");
        try out.appendSlice(self.alloc, "  node [shape=box, fontname=\"Helvetica\", style=filled, fillcolor=\"#f1f5f9\"];\n");

        var it = self.nodes.iterator();
        while (it.next()) |entry| {
            const u = entry.key_ptr.*;
            for (entry.value_ptr.dependencies.items) |v| {
                try out.appendSlice(self.alloc, "  \"");
                try out.appendSlice(self.alloc, u);
                try out.appendSlice(self.alloc, "\" -> \"");
                try out.appendSlice(self.alloc, v);
                try out.appendSlice(self.alloc, "\";\n");
            }
        }

        try out.appendSlice(self.alloc, "}\n");
    }

    /// Render graph into JSON format.
    pub fn toJson(self: *DocumentGraph, out: *std.ArrayList(u8)) Allocator.Error!void {
        try out.appendSlice(self.alloc, "{\"nodes\":[");
        var it = self.nodes.iterator();
        var first_node = true;
        while (it.next()) |entry| {
            if (!first_node) try out.append(self.alloc, ',');
            first_node = false;
            try out.appendSlice(self.alloc, "{\"path\":\"");
            try out.appendSlice(self.alloc, entry.key_ptr.*);
            try out.appendSlice(self.alloc, "\",\"dependencies\":[");
            for (entry.value_ptr.dependencies.items, 0..) |dep, i| {
                if (i > 0) try out.append(self.alloc, ',');
                try out.append(self.alloc, '"');
                try out.appendSlice(self.alloc, dep);
                try out.append(self.alloc, '"');
            }
            try out.appendSlice(self.alloc, "]}");
        }
        try out.appendSlice(self.alloc, "]}");
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

test "graph — extract includes" {
    const src =
        \\# Main Document
        \\.include {chapter1.qmd}
        \\Some text.
        \\.include {chapter2.qmd}
    ;

    const incs = try DocumentGraph.extractIncludes(std.testing.allocator, src);
    defer {
        for (incs) |inc| std.testing.allocator.free(inc);
        std.testing.allocator.free(incs);
    }

    try std.testing.expectEqual(@as(usize, 2), incs.len);
    try std.testing.expectEqualStrings("chapter1.qmd", incs[0]);
    try std.testing.expectEqualStrings("chapter2.qmd", incs[1]);
}

test "graph — build, topo sort and cycle detection" {
    var graph = DocumentGraph.init(std.testing.allocator);
    defer graph.deinit();

    var vfs = std.StringHashMapUnmanaged([]const u8){};
    defer vfs.clearAndFree(std.testing.allocator);

    try vfs.put(std.testing.allocator, "main.qmd", "# Main\n.include {lib.qmd}\n");
    try vfs.put(std.testing.allocator, "lib.qmd", "# Lib\n.include {core.qmd}\n");
    try vfs.put(std.testing.allocator, "core.qmd", "# Core\n");

    try graph.buildFromVfs("main.qmd", &vfs);

    // Should have no cycle
    const cycle = try graph.detectCycle();
    try std.testing.expect(cycle == null);

    // Topological sort: core should come before lib, and lib before main
    const order = try graph.topologicalSort();
    defer std.testing.allocator.free(order);

    try std.testing.expectEqual(@as(usize, 3), order.len);
    try std.testing.expectEqualStrings("core.qmd", order[0]);
    try std.testing.expectEqualStrings("lib.qmd", order[1]);
    try std.testing.expectEqualStrings("main.qmd", order[2]);

    // DOT output test
    var dot: std.ArrayList(u8) = .empty;
    defer dot.deinit(std.testing.allocator);
    try graph.toDot(&dot);
    try std.testing.expect(std.mem.indexOf(u8, dot.items, "\"main.qmd\" -> \"lib.qmd\"") != null);
}

test "graph — detect circular dependency" {
    var graph = DocumentGraph.init(std.testing.allocator);
    defer graph.deinit();

    var vfs = std.StringHashMapUnmanaged([]const u8){};
    defer vfs.clearAndFree(std.testing.allocator);

    try vfs.put(std.testing.allocator, "a.qmd", ".include {b.qmd}\n");
    try vfs.put(std.testing.allocator, "b.qmd", ".include {a.qmd}\n");

    try graph.buildFromVfs("a.qmd", &vfs);

    const cycle = try graph.detectCycle();
    try std.testing.expect(cycle != null);
    if (cycle) |c| {
        var cycle_arr = c;
        cycle_arr.deinit(std.testing.allocator);
    }
}
