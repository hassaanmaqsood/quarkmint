//! build.zig — Quarkmint WebAssembly & Native Build System
//!
//! Build modes:
//!   `zig build`         → compiles src/wasm.zig → zig-out/lib/quarkmint.wasm
//!                       → compiles src/main.zig → zig-out/bin/quarkmint
//!   `zig build test`    → compiles & runs native test suite (leak-checked)
//!
//! Target: wasm32-freestanding (no libc, no OS, no WASI)
//! Zig version: 0.16.x

const std = @import("std");

pub fn build(b: *std.Build) void {
    // ── Native test step ──────────────────────────────────────────────────────
    // All modules expose `test` blocks. We compile them as a native executable
    // so std.testing.allocator can detect leaks.
    const test_step = b.step("test", "Run the native unit-test suite");

    const native_target = b.standardTargetOptions(.{});

    const modules = [_][]const u8{
        "src/tokens.zig",
        "src/lexer.zig",
        "src/ast.zig",
        "src/parser.zig",
        "src/value.zig",
        "src/coercion.zig",
        "src/scope.zig",
        "src/context.zig",
        "src/evaluator.zig",
        "src/stdlib.zig",
        "src/html.zig",
        "src/math.zig",
        "src/renderer.zig",
        "src/latex.zig",
        "src/graph.zig",
        "src/lsp.zig",
        "src/post.zig",
        "src/wasm.zig",
    };

    for (modules) |src| {
        const mod = b.createModule(.{
            .root_source_file = b.path(src),
            .target = native_target,
            .optimize = .Debug,
        });
        const t = b.addTest(.{
            .root_module = mod,
        });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }

    // ── WebAssembly shared-library step ───────────────────────────────────────
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
        .abi = .none,
    });

    const wasm_mod = b.createModule(.{
        .root_source_file = b.path("src/wasm.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
    });

    const wasm_lib = b.addExecutable(.{
        .name = "quarkmint",
        .root_module = wasm_mod,
    });

    // freestanding Wasm: no entry point, export everything marked `export fn`
    wasm_lib.entry = .disabled;
    wasm_lib.rdynamic = true;

    // Export to zig-out/lib/quarkmint.wasm
    const install_wasm = b.addInstallArtifact(wasm_lib, .{
        .dest_dir = .{ .override = .lib },
    });

    b.default_step.dependOn(&install_wasm.step);

    // ── Native CLI executable step ────────────────────────────────────────────
    const cli_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = native_target,
        .optimize = .ReleaseFast,
    });

    const cli_exe = b.addExecutable(.{
        .name = "quarkmint",
        .root_module = cli_mod,
    });

    const install_cli = b.addInstallArtifact(cli_exe, .{
        .dest_dir = .{ .override = .bin },
    });

    b.default_step.dependOn(&install_cli.step);
}
