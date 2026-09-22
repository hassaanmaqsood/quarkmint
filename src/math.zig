//! math.zig — Native TeX to MathML Core converter for Quarkdown.
//!
//! Provides a zero-dependency, zero-allocation-where-possible recursive-descent
//! translator from TeX/LaTeX mathematical notation into modern MathML Core (<math>).
//!
//! Enables native browser math typesetting (Chrome 109+, Safari, Firefox, Edge)
//! with ZERO external JavaScript, ZERO CSS downloads, and sub-millisecond speed.

const std = @import("std");
const html = @import("html.zig");

const Allocator = std.mem.Allocator;

// ─────────────────────────────────────────────────────────────────────────────
// Symbol & Greek Dictionary
// ─────────────────────────────────────────────────────────────────────────────

const SymbolMapping = struct {
    name: []const u8,
    symbol: []const u8,
    is_operator: bool = false,
    is_big_op: bool = false,
};

const SYMBOLS = [_]SymbolMapping{
    // Greek lowercase
    .{ .name = "alpha", .symbol = "α" },
    .{ .name = "beta", .symbol = "β" },
    .{ .name = "gamma", .symbol = "γ" },
    .{ .name = "delta", .symbol = "δ" },
    .{ .name = "epsilon", .symbol = "ε" },
    .{ .name = "varepsilon", .symbol = "ε" },
    .{ .name = "zeta", .symbol = "ζ" },
    .{ .name = "eta", .symbol = "η" },
    .{ .name = "theta", .symbol = "θ" },
    .{ .name = "vartheta", .symbol = "ϑ" },
    .{ .name = "iota", .symbol = "ι" },
    .{ .name = "kappa", .symbol = "κ" },
    .{ .name = "lambda", .symbol = "λ" },
    .{ .name = "mu", .symbol = "μ" },
    .{ .name = "nu", .symbol = "ν" },
    .{ .name = "xi", .symbol = "ξ" },
    .{ .name = "pi", .symbol = "π" },
    .{ .name = "varpi", .symbol = "ϖ" },
    .{ .name = "rho", .symbol = "ρ" },
    .{ .name = "varrho", .symbol = "ϱ" },
    .{ .name = "sigma", .symbol = "σ" },
    .{ .name = "varsigma", .symbol = "ς" },
    .{ .name = "tau", .symbol = "τ" },
    .{ .name = "upsilon", .symbol = "υ" },
    .{ .name = "phi", .symbol = "φ" },
    .{ .name = "varphi", .symbol = "ϕ" },
    .{ .name = "chi", .symbol = "χ" },
    .{ .name = "psi", .symbol = "ψ" },
    .{ .name = "omega", .symbol = "ω" },

    // Greek uppercase
    .{ .name = "Gamma", .symbol = "Γ" },
    .{ .name = "Delta", .symbol = "Δ" },
    .{ .name = "Theta", .symbol = "Θ" },
    .{ .name = "Lambda", .symbol = "Λ" },
    .{ .name = "Xi", .symbol = "Ξ" },
    .{ .name = "Pi", .symbol = "Π" },
    .{ .name = "Sigma", .symbol = "Σ" },
    .{ .name = "Upsilon", .symbol = "Υ" },
    .{ .name = "Phi", .symbol = "Φ" },
    .{ .name = "Psi", .symbol = "Ψ" },
    .{ .name = "Omega", .symbol = "Ω" },

    // Math Constants & Operators
    .{ .name = "infty", .symbol = "∞" },
    .{ .name = "partial", .symbol = "∂" },
    .{ .name = "nabla", .symbol = "∇" },
    .{ .name = "hbar", .symbol = "ħ" },
    .{ .name = "pm", .symbol = "±", .is_operator = true },
    .{ .name = "mp", .symbol = "∓", .is_operator = true },
    .{ .name = "times", .symbol = "×", .is_operator = true },
    .{ .name = "div", .symbol = "÷", .is_operator = true },
    .{ .name = "cdot", .symbol = "⋅", .is_operator = true },
    .{ .name = "circ", .symbol = "∘", .is_operator = true },
    .{ .name = "bullet", .symbol = "•", .is_operator = true },
    .{ .name = "star", .symbol = "⋆", .is_operator = true },

    // Relations
    .{ .name = "leq", .symbol = "≤", .is_operator = true },
    .{ .name = "le", .symbol = "≤", .is_operator = true },
    .{ .name = "geq", .symbol = "≥", .is_operator = true },
    .{ .name = "ge", .symbol = "≥", .is_operator = true },
    .{ .name = "neq", .symbol = "≠", .is_operator = true },
    .{ .name = "ne", .symbol = "≠", .is_operator = true },
    .{ .name = "approx", .symbol = "≈", .is_operator = true },
    .{ .name = "sim", .symbol = "∼", .is_operator = true },
    .{ .name = "equiv", .symbol = "≡", .is_operator = true },
    .{ .name = "ll", .symbol = "≪", .is_operator = true },
    .{ .name = "gg", .symbol = "≫", .is_operator = true },

    // Set Theory & Logic
    .{ .name = "in", .symbol = "∈", .is_operator = true },
    .{ .name = "notin", .symbol = "∉", .is_operator = true },
    .{ .name = "ni", .symbol = "∋", .is_operator = true },
    .{ .name = "subset", .symbol = "⊂", .is_operator = true },
    .{ .name = "subseteq", .symbol = "⊆", .is_operator = true },
    .{ .name = "supset", .symbol = "⊃", .is_operator = true },
    .{ .name = "supseteq", .symbol = "⊇", .is_operator = true },
    .{ .name = "cup", .symbol = "∪", .is_operator = true },
    .{ .name = "cap", .symbol = "∩", .is_operator = true },
    .{ .name = "setminus", .symbol = "∖", .is_operator = true },
    .{ .name = "forall", .symbol = "∀", .is_operator = true },
    .{ .name = "exists", .symbol = "∃", .is_operator = true },
    .{ .name = "neg", .symbol = "¬", .is_operator = true },
    .{ .name = "lor", .symbol = "∨", .is_operator = true },
    .{ .name = "land", .symbol = "∧", .is_operator = true },
    .{ .name = "emptyset", .symbol = "∅" },

    // Arrows
    .{ .name = "leftarrow", .symbol = "←", .is_operator = true },
    .{ .name = "gets", .symbol = "←", .is_operator = true },
    .{ .name = "rightarrow", .symbol = "→", .is_operator = true },
    .{ .name = "to", .symbol = "→", .is_operator = true },
    .{ .name = "leftrightarrow", .symbol = "↔", .is_operator = true },
    .{ .name = "Leftarrow", .symbol = "⇐", .is_operator = true },
    .{ .name = "Rightarrow", .symbol = "⇒", .is_operator = true },
    .{ .name = "implies", .symbol = "⇒", .is_operator = true },
    .{ .name = "Leftrightarrow", .symbol = "⇔", .is_operator = true },
    .{ .name = "iff", .symbol = "⇔", .is_operator = true },
    .{ .name = "uparrow", .symbol = "↑", .is_operator = true },
    .{ .name = "downarrow", .symbol = "↓", .is_operator = true },

    // Big Operators (with limits)
    .{ .name = "sum", .symbol = "∑", .is_operator = true, .is_big_op = true },
    .{ .name = "prod", .symbol = "∏", .is_operator = true, .is_big_op = true },
    .{ .name = "coprod", .symbol = "∐", .is_operator = true, .is_big_op = true },
    .{ .name = "int", .symbol = "∫", .is_operator = true, .is_big_op = true },
    .{ .name = "iint", .symbol = "∬", .is_operator = true, .is_big_op = true },
    .{ .name = "iiint", .symbol = "∭", .is_operator = true, .is_big_op = true },
    .{ .name = "oint", .symbol = "∮", .is_operator = true, .is_big_op = true },
    .{ .name = "bigcup", .symbol = "⋃", .is_operator = true, .is_big_op = true },
    .{ .name = "bigcap", .symbol = "⋂", .is_operator = true, .is_big_op = true },

    // Standard Named Functions
    .{ .name = "sin", .symbol = "sin", .is_operator = true },
    .{ .name = "cos", .symbol = "cos", .is_operator = true },
    .{ .name = "tan", .symbol = "tan", .is_operator = true },
    .{ .name = "arcsin", .symbol = "arcsin", .is_operator = true },
    .{ .name = "arccos", .symbol = "arccos", .is_operator = true },
    .{ .name = "arctan", .symbol = "arctan", .is_operator = true },
    .{ .name = "sinh", .symbol = "sinh", .is_operator = true },
    .{ .name = "cosh", .symbol = "cosh", .is_operator = true },
    .{ .name = "tanh", .symbol = "tanh", .is_operator = true },
    .{ .name = "sec", .symbol = "sec", .is_operator = true },
    .{ .name = "csc", .symbol = "csc", .is_operator = true },
    .{ .name = "cot", .symbol = "cot", .is_operator = true },
    .{ .name = "exp", .symbol = "exp", .is_operator = true },
    .{ .name = "ln", .symbol = "ln", .is_operator = true },
    .{ .name = "log", .symbol = "log", .is_operator = true },
    .{ .name = "lg", .symbol = "lg", .is_operator = true },
    .{ .name = "lim", .symbol = "lim", .is_operator = true, .is_big_op = true },
    .{ .name = "max", .symbol = "max", .is_operator = true, .is_big_op = true },
    .{ .name = "min", .symbol = "min", .is_operator = true, .is_big_op = true },
    .{ .name = "sup", .symbol = "sup", .is_operator = true, .is_big_op = true },
    .{ .name = "inf", .symbol = "inf", .is_operator = true, .is_big_op = true },
    .{ .name = "det", .symbol = "det", .is_operator = true },
    .{ .name = "gcd", .symbol = "gcd", .is_operator = true },
    .{ .name = "deg", .symbol = "deg", .is_operator = true },
    .{ .name = "dim", .symbol = "dim", .is_operator = true },

    // Ellipses & Dots
    .{ .name = "dots", .symbol = "…" },
    .{ .name = "cdots", .symbol = "⋯", .is_operator = true },
    .{ .name = "ldots", .symbol = "…" },
    .{ .name = "vdots", .symbol = "⋮" },
    .{ .name = "ddots", .symbol = "⋱" },
};

fn lookupSymbol(name: []const u8) ?SymbolMapping {
    for (SYMBOLS) |sym| {
        if (std.mem.eql(u8, sym.name, name)) return sym;
    }
    return null;
}

// ─────────────────────────────────────────────────────────────────────────────
// TeX Math Parser & MathML Generator
// ─────────────────────────────────────────────────────────────────────────────

pub const MathRenderer = struct {
    alloc: Allocator,
    src: []const u8,
    pos: usize = 0,
    out: *std.ArrayList(u8),

    pub fn init(alloc: Allocator, out: *std.ArrayList(u8), src: []const u8) MathRenderer {
        return .{
            .alloc = alloc,
            .src = src,
            .pos = 0,
            .out = out,
        };
    }

    fn peek(self: *MathRenderer) ?u8 {
        if (self.pos < self.src.len) return self.src[self.pos];
        return null;
    }

    fn advance(self: *MathRenderer) void {
        if (self.pos < self.src.len) self.pos += 1;
    }

    fn skipWhitespace(self: *MathRenderer) void {
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                self.pos += 1;
            } else {
                break;
            }
        }
    }

    /// Convert the TeX math string into MathML Core.
    pub fn render(self: *MathRenderer, is_block: bool) Allocator.Error!void {
        if (is_block) {
            try self.out.appendSlice(self.alloc, "<math display=\"block\">");
        } else {
            try self.out.appendSlice(self.alloc, "<math>");
        }

        try self.parseExpression(null);

        try self.out.appendSlice(self.alloc, "</math>");
    }

    fn parseExpression(self: *MathRenderer, end_char: ?u8) Allocator.Error!void {
        while (self.pos < self.src.len) {
            self.skipWhitespace();
            if (self.pos >= self.src.len) break;

            const c = self.src[self.pos];
            if (end_char) |ec| {
                if (c == ec) break;
            }
            if (c == '}' or c == ']' or c == '&') break;
            if (c == '\\' and self.pos + 1 < self.src.len and self.src[self.pos + 1] == '\\') break;

            try self.parseTerm();
        }
    }

    fn parseTerm(self: *MathRenderer) Allocator.Error!void {
        self.skipWhitespace();
        if (self.pos >= self.src.len) return;

        // Remember starting pos to detect big operators
        const start_pos = self.pos;
        var is_big_op = false;
        if (self.src[start_pos] == '\\') {
            var p = start_pos + 1;
            while (p < self.src.len and std.ascii.isAlphabetic(self.src[p])) : (p += 1) {}
            const cmd = self.src[start_pos + 1 .. p];
            if (lookupSymbol(cmd)) |sym| {
                if (sym.is_big_op) is_big_op = true;
            }
        }

        var base_buf: std.ArrayList(u8) = .empty;
        var sub_buf: std.ArrayList(u8) = .empty;
        var sup_buf: std.ArrayList(u8) = .empty;

        var sub_renderer = MathRenderer{ .alloc = self.alloc, .src = self.src, .pos = self.pos, .out = &base_buf };
        try sub_renderer.parseAtom();
        self.pos = sub_renderer.pos;

        // Check for scripts: `_` and `^` in either order
        var has_sub = false;
        var has_sup = false;

        while (true) {
            self.skipWhitespace();
            if (self.pos >= self.src.len) break;

            if (self.src[self.pos] == '_' and !has_sub) {
                has_sub = true;
                self.pos += 1;
                var script_r = MathRenderer{ .alloc = self.alloc, .src = self.src, .pos = self.pos, .out = &sub_buf };
                try script_r.parseScript();
                self.pos = script_r.pos;
            } else if (self.src[self.pos] == '^' and !has_sup) {
                has_sup = true;
                self.pos += 1;
                var script_r = MathRenderer{ .alloc = self.alloc, .src = self.src, .pos = self.pos, .out = &sup_buf };
                try script_r.parseScript();
                self.pos = script_r.pos;
            } else {
                break;
            }
        }

        if (has_sub and has_sup) {
            if (is_big_op) {
                try self.out.appendSlice(self.alloc, "<munderover>");
                try self.out.appendSlice(self.alloc, base_buf.items);
                try self.out.appendSlice(self.alloc, sub_buf.items);
                try self.out.appendSlice(self.alloc, sup_buf.items);
                try self.out.appendSlice(self.alloc, "</munderover>");
            } else {
                try self.out.appendSlice(self.alloc, "<msubsup>");
                try self.out.appendSlice(self.alloc, base_buf.items);
                try self.out.appendSlice(self.alloc, sub_buf.items);
                try self.out.appendSlice(self.alloc, sup_buf.items);
                try self.out.appendSlice(self.alloc, "</msubsup>");
            }
        } else if (has_sub) {
            if (is_big_op) {
                try self.out.appendSlice(self.alloc, "<munder>");
                try self.out.appendSlice(self.alloc, base_buf.items);
                try self.out.appendSlice(self.alloc, sub_buf.items);
                try self.out.appendSlice(self.alloc, "</munder>");
            } else {
                try self.out.appendSlice(self.alloc, "<msub>");
                try self.out.appendSlice(self.alloc, base_buf.items);
                try self.out.appendSlice(self.alloc, sub_buf.items);
                try self.out.appendSlice(self.alloc, "</msub>");
            }
        } else if (has_sup) {
            if (is_big_op) {
                try self.out.appendSlice(self.alloc, "<mover>");
                try self.out.appendSlice(self.alloc, base_buf.items);
                try self.out.appendSlice(self.alloc, sup_buf.items);
                try self.out.appendSlice(self.alloc, "</mover>");
            } else {
                try self.out.appendSlice(self.alloc, "<msup>");
                try self.out.appendSlice(self.alloc, base_buf.items);
                try self.out.appendSlice(self.alloc, sup_buf.items);
                try self.out.appendSlice(self.alloc, "</msup>");
            }
        } else {
            try self.out.appendSlice(self.alloc, base_buf.items);
        }
    }

    fn parseScript(self: *MathRenderer) Allocator.Error!void {
        self.skipWhitespace();
        if (self.pos >= self.src.len) return;

        if (self.src[self.pos] == '{') {
            self.pos += 1;
            try self.parseExpression('}');
            if (self.pos < self.src.len and self.src[self.pos] == '}') self.pos += 1;
        } else {
            try self.parseAtom();
        }
    }

    fn parseAtom(self: *MathRenderer) Allocator.Error!void {
        self.skipWhitespace();
        if (self.pos >= self.src.len) return;

        const c = self.src[self.pos];

        // 1. Group `{ ... }`
        if (c == '{') {
            self.pos += 1;
            try self.out.appendSlice(self.alloc, "<mrow>");
            try self.parseExpression('}');
            try self.out.appendSlice(self.alloc, "</mrow>");
            if (self.pos < self.src.len and self.src[self.pos] == '}') self.pos += 1;
            return;
        }

        // 2. TeX Command `\`
        if (c == '\\') {
            try self.parseCommand();
            return;
        }

        // 3. Numbers `0-9`
        if (std.ascii.isDigit(c)) {
            const start = self.pos;
            while (self.pos < self.src.len and (std.ascii.isDigit(self.src[self.pos]) or self.src[self.pos] == '.')) : (self.pos += 1) {}
            const num = self.src[start..self.pos];
            try self.out.appendSlice(self.alloc, "<mn>");
            try self.out.appendSlice(self.alloc, num);
            try self.out.appendSlice(self.alloc, "</mn>");
            return;
        }

        // 4. Identifiers (letters)
        if (std.ascii.isAlphabetic(c)) {
            self.pos += 1;
            const s = [_]u8{c};
            try self.out.appendSlice(self.alloc, "<mi>");
            try self.out.appendSlice(self.alloc, &s);
            try self.out.appendSlice(self.alloc, "</mi>");
            return;
        }

        // 5. Operators & Delimiters
        self.pos += 1;
        switch (c) {
            '=', '+', '-', '*', '/', '<', '>', ',', ';', '!' => {
                const s = [_]u8{c};
                try self.out.appendSlice(self.alloc, "<mo>");
                try html.escapeText(self.alloc, self.out, &s);
                try self.out.appendSlice(self.alloc, "</mo>");
            },
            '(', ')', '[', ']' => {
                const s = [_]u8{c};
                try self.out.appendSlice(self.alloc, "<mo>");
                try self.out.appendSlice(self.alloc, &s);
                try self.out.appendSlice(self.alloc, "</mo>");
            },
            '|' => {
                try self.out.appendSlice(self.alloc, "<mo>|</mo>");
            },
            else => {
                const s = [_]u8{c};
                try self.out.appendSlice(self.alloc, "<mo>");
                try html.escapeText(self.alloc, self.out, &s);
                try self.out.appendSlice(self.alloc, "</mo>");
            },
        }
    }

    fn parseCommand(self: *MathRenderer) Allocator.Error!void {
        self.pos += 1; // skip `\`
        if (self.pos >= self.src.len) return;

        const c = self.src[self.pos];

        // Non-alpha single-character commands like `\,`, `\{`, `\}`, `\|`
        if (!std.ascii.isAlphabetic(c)) {
            self.pos += 1;
            switch (c) {
                '{' => try self.out.appendSlice(self.alloc, "<mo>{</mo>"),
                '}' => try self.out.appendSlice(self.alloc, "<mo>}</mo>"),
                '|' => try self.out.appendSlice(self.alloc, "<mo>∥</mo>"),
                ',' => try self.out.appendSlice(self.alloc, "<mspace width=\"0.166em\"/>"),
                ':' => try self.out.appendSlice(self.alloc, "<mspace width=\"0.222em\"/>"),
                ';' => try self.out.appendSlice(self.alloc, "<mspace width=\"0.278em\"/>"),
                ' ' => try self.out.appendSlice(self.alloc, "<mspace width=\"0.25em\"/>"),
                '!' => try self.out.appendSlice(self.alloc, "<mspace width=\"-0.166em\"/>"),
                '\\' => try self.out.appendSlice(self.alloc, "<mo>\\</mo>"),
                else => {
                    const s = [_]u8{c};
                    try self.out.appendSlice(self.alloc, "<mo>");
                    try html.escapeText(self.alloc, self.out, &s);
                    try self.out.appendSlice(self.alloc, "</mo>");
                },
            }
            return;
        }

        // Alpha command
        const start = self.pos;
        while (self.pos < self.src.len and std.ascii.isAlphabetic(self.src[self.pos])) : (self.pos += 1) {}
        const cmd = self.src[start..self.pos];

        // ── Fraction: \frac{a}{b} ─────────────────────────────────────────────
        if (std.mem.eql(u8, cmd, "frac") or std.mem.eql(u8, cmd, "dfrac") or std.mem.eql(u8, cmd, "tfrac")) {
            try self.out.appendSlice(self.alloc, "<mfrac>");

            try self.out.appendSlice(self.alloc, "<mrow>");
            try self.parseScript();
            try self.out.appendSlice(self.alloc, "</mrow>");

            try self.out.appendSlice(self.alloc, "<mrow>");
            try self.parseScript();
            try self.out.appendSlice(self.alloc, "</mrow>");

            try self.out.appendSlice(self.alloc, "</mfrac>");
            return;
        }

        // ── Square Root & N-th Root: \sqrt{x}, \sqrt[n]{x} ───────────────────
        if (std.mem.eql(u8, cmd, "sqrt")) {
            self.skipWhitespace();
            if (self.pos < self.src.len and self.src[self.pos] == '[') {
                self.pos += 1;
                var index_buf: std.ArrayList(u8) = .empty;
                var idx_r = MathRenderer{ .alloc = self.alloc, .src = self.src, .pos = self.pos, .out = &index_buf };
                try idx_r.parseExpression(']');
                self.pos = idx_r.pos;
                if (self.pos < self.src.len and self.src[self.pos] == ']') self.pos += 1;

                try self.out.appendSlice(self.alloc, "<mroot><mrow>");
                try self.parseScript();
                try self.out.appendSlice(self.alloc, "</mrow><mrow>");
                try self.out.appendSlice(self.alloc, index_buf.items);
                try self.out.appendSlice(self.alloc, "</mrow></mroot>");
            } else {
                try self.out.appendSlice(self.alloc, "<msqrt><mrow>");
                try self.parseScript();
                try self.out.appendSlice(self.alloc, "</mrow></msqrt>");
            }
            return;
        }

        // ── Accents: \hat, \bar, \vec, \dot, \ddot, \tilde ───────────────────
        if (std.mem.eql(u8, cmd, "vec")) return self.renderAccent("→");
        if (std.mem.eql(u8, cmd, "hat")) return self.renderAccent("^");
        if (std.mem.eql(u8, cmd, "bar") or std.mem.eql(u8, cmd, "overline")) return self.renderAccent("¯");
        if (std.mem.eql(u8, cmd, "dot")) return self.renderAccent("˙");
        if (std.mem.eql(u8, cmd, "ddot")) return self.renderAccent("¨");
        if (std.mem.eql(u8, cmd, "tilde") or std.mem.eql(u8, cmd, "widetilde")) return self.renderAccent("~");

        // ── Text Commands: \text, \mathrm, \operatorname ───────────────────────
        if (std.mem.eql(u8, cmd, "text") or std.mem.eql(u8, cmd, "mathrm") or std.mem.eql(u8, cmd, "operatorname")) {
            self.skipWhitespace();
            if (self.pos < self.src.len and self.src[self.pos] == '{') {
                self.pos += 1;
                const txt_start = self.pos;
                while (self.pos < self.src.len and self.src[self.pos] != '}') : (self.pos += 1) {}
                const txt = self.src[txt_start..self.pos];
                if (self.pos < self.src.len and self.src[self.pos] == '}') self.pos += 1;

                try self.out.appendSlice(self.alloc, "<mtext>");
                try html.escapeText(self.alloc, self.out, txt);
                try self.out.appendSlice(self.alloc, "</mtext>");
                return;
            }
        }

        // ── Font Formatting: \mathbf, \mathit, \mathbb, \mathcal ─────────────
        if (std.mem.eql(u8, cmd, "mathbf")) return self.renderStyle("bold");
        if (std.mem.eql(u8, cmd, "mathit")) return self.renderStyle("italic");
        if (std.mem.eql(u8, cmd, "mathbb")) return self.renderStyle("double-struck");
        if (std.mem.eql(u8, cmd, "mathcal")) return self.renderStyle("script");

        // ── Delimiters: \left( ... \right) ───────────────────────────────────
        if (std.mem.eql(u8, cmd, "left")) {
            self.skipWhitespace();
            var open_char: []const u8 = "(";
            if (self.pos < self.src.len) {
                open_char = self.src[self.pos .. self.pos + 1];
                self.pos += 1;
            }
            try self.out.appendSlice(self.alloc, "<mrow><mo>");
            try html.escapeText(self.alloc, self.out, open_char);
            try self.out.appendSlice(self.alloc, "</mo>");

            // Scan until \right
            while (self.pos < self.src.len) {
                self.skipWhitespace();
                if (self.pos + 6 <= self.src.len and std.mem.eql(u8, self.src[self.pos .. self.pos + 6], "\\right")) {
                    self.pos += 6;
                    self.skipWhitespace();
                    var close_char: []const u8 = ")";
                    if (self.pos < self.src.len) {
                        close_char = self.src[self.pos .. self.pos + 1];
                        self.pos += 1;
                    }
                    try self.out.appendSlice(self.alloc, "<mo>");
                    try html.escapeText(self.alloc, self.out, close_char);
                    try self.out.appendSlice(self.alloc, "</mo></mrow>");
                    return;
                }
                try self.parseTerm();
            }
            try self.out.appendSlice(self.alloc, "</mrow>");
            return;
        }

        // ── Matrices & Tables: \begin{matrix}, \begin{pmatrix}, \begin{bmatrix}
        if (std.mem.eql(u8, cmd, "begin")) {
            try self.parseMatrix();
            return;
        }

        // ── Symbols Dictionary Lookup ─────────────────────────────────────────
        if (lookupSymbol(cmd)) |sym| {
            if (sym.is_operator or sym.is_big_op) {
                try self.out.appendSlice(self.alloc, "<mo>");
                try self.out.appendSlice(self.alloc, sym.symbol);
                try self.out.appendSlice(self.alloc, "</mo>");
            } else {
                try self.out.appendSlice(self.alloc, "<mi>");
                try self.out.appendSlice(self.alloc, sym.symbol);
                try self.out.appendSlice(self.alloc, "</mi>");
            }
            return;
        }

        // ── Spacing commands ──────────────────────────────────────────────────
        if (std.mem.eql(u8, cmd, "quad")) {
            try self.out.appendSlice(self.alloc, "<mspace width=\"1em\"/>");
            return;
        }
        if (std.mem.eql(u8, cmd, "qquad")) {
            try self.out.appendSlice(self.alloc, "<mspace width=\"2em\"/>");
            return;
        }

        // Fallback for unknown commands: emit as <mi> or <mtext>
        try self.out.appendSlice(self.alloc, "<mi>");
        try html.escapeText(self.alloc, self.out, cmd);
        try self.out.appendSlice(self.alloc, "</mi>");
    }

    fn renderAccent(self: *MathRenderer, accent_sym: []const u8) Allocator.Error!void {
        try self.out.appendSlice(self.alloc, "<mover><mrow>");
        try self.parseScript();
        try self.out.appendSlice(self.alloc, "</mrow><mo>");
        try self.out.appendSlice(self.alloc, accent_sym);
        try self.out.appendSlice(self.alloc, "</mo></mover>");
    }

    fn renderStyle(self: *MathRenderer, style_name: []const u8) Allocator.Error!void {
        try self.out.appendSlice(self.alloc, "<mstyle mathvariant=\"");
        try self.out.appendSlice(self.alloc, style_name);
        try self.out.appendSlice(self.alloc, "\">");
        try self.parseScript();
        try self.out.appendSlice(self.alloc, "</mstyle>");
    }

    fn parseMatrix(self: *MathRenderer) Allocator.Error!void {
        self.skipWhitespace();
        var env_name: []const u8 = "matrix";
        if (self.pos < self.src.len and self.src[self.pos] == '{') {
            self.pos += 1;
            const start = self.pos;
            while (self.pos < self.src.len and self.src[self.pos] != '}') : (self.pos += 1) {}
            env_name = self.src[start..self.pos];
            if (self.pos < self.src.len and self.src[self.pos] == '}') self.pos += 1;
        }

        const is_paren = std.mem.eql(u8, env_name, "pmatrix");
        const is_bracket = std.mem.eql(u8, env_name, "bmatrix");

        if (is_paren) try self.out.appendSlice(self.alloc, "<mrow><mo>(</mo>");
        if (is_bracket) try self.out.appendSlice(self.alloc, "<mrow><mo>[</mo>");

        try self.out.appendSlice(self.alloc, "<mtable><mtr><mtd>");

        const end_marker = "\\end{";
        while (self.pos < self.src.len) {
            self.skipWhitespace();
            if (self.pos + end_marker.len <= self.src.len and std.mem.eql(u8, self.src[self.pos .. self.pos + end_marker.len], end_marker)) {
                // Skip \end{...}
                while (self.pos < self.src.len and self.src[self.pos] != '}') : (self.pos += 1) {}
                if (self.pos < self.src.len and self.src[self.pos] == '}') self.pos += 1;
                break;
            }

            if (self.src[self.pos] == '&') {
                self.pos += 1;
                try self.out.appendSlice(self.alloc, "</mtd><mtd>");
                continue;
            }

            if (self.src[self.pos] == '\\' and self.pos + 1 < self.src.len and self.src[self.pos + 1] == '\\') {
                self.pos += 2;
                try self.out.appendSlice(self.alloc, "</mtd></mtr><mtr><mtd>");
                continue;
            }

            try self.parseTerm();
        }

        try self.out.appendSlice(self.alloc, "</mtd></mtr></mtable>");

        if (is_paren) try self.out.appendSlice(self.alloc, "<mo>)</mo></mrow>");
        if (is_bracket) try self.out.appendSlice(self.alloc, "<mo>]</mo></mrow>");
    }
};

/// High-level function: converts TeX formula into MathML Core HTML byte stream.
pub fn renderTeXToMathML(alloc: Allocator, out: *std.ArrayList(u8), tex: []const u8, is_block: bool) Allocator.Error!void {
    const trimmed = std.mem.trim(u8, tex, " \t\r\n");
    var renderer = MathRenderer.init(alloc, out, trimmed);
    try renderer.render(is_block);
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

test "math — basic arithmetic and superscript" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var buf: std.ArrayList(u8) = .empty;
    try renderTeXToMathML(alloc, &buf, "E = mc^2", false);

    const res = buf.items;
    try std.testing.expect(std.mem.startsWith(u8, res, "<math>"));
    try std.testing.expect(std.mem.indexOf(u8, res, "<mi>E</mi><mo>=</mo><mi>m</mi><msup><mi>c</mi><mn>2</mn></msup>") != null);
    try std.testing.expect(std.mem.endsWith(u8, res, "</math>"));
}

test "math — fraction and square root" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var buf: std.ArrayList(u8) = .empty;
    try renderTeXToMathML(alloc, &buf, "\\frac{\\sqrt{\\pi}}{2}", true);

    const res = buf.items;
    try std.testing.expect(std.mem.startsWith(u8, res, "<math display=\"block\">"));
    try std.testing.expect(std.mem.indexOf(u8, res, "<mfrac>") != null);
    try std.testing.expect(std.mem.indexOf(u8, res, "<msqrt><mrow><mi>π</mi></mrow></msqrt>") != null);
    try std.testing.expect(std.mem.indexOf(u8, res, "<mn>2</mn>") != null);
    try std.testing.expect(std.mem.endsWith(u8, res, "</math>"));
}

test "math — integral with limits" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var buf: std.ArrayList(u8) = .empty;
    try renderTeXToMathML(alloc, &buf, "\\int_{0}^{\\infty} e^{-x^2} dx", true);

    const res = buf.items;
    try std.testing.expect(std.mem.indexOf(u8, res, "<munderover><mo>∫</mo><mn>0</mn><mi>∞</mi></munderover>") != null);
    try std.testing.expect(std.mem.indexOf(u8, res, "<msup><mi>e</mi>") != null);
}

test "math — matrix with brackets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var buf: std.ArrayList(u8) = .empty;
    try renderTeXToMathML(alloc, &buf, "\\begin{pmatrix} a & b \\\\ c & d \\end{pmatrix}", true);

    const res = buf.items;
    try std.testing.expect(std.mem.indexOf(u8, res, "<mo>(</mo><mtable><mtr><mtd><mi>a</mi></mtd><mtd><mi>b</mi></mtd></mtr><mtr><mtd><mi>c</mi></mtd><mtd><mi>d</mi></mtd></mtr></mtable><mo>)</mo>") != null);
}
