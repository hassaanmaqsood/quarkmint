/**
 * main.js — Quarkmint WebAssembly Engine & Integration
 *
 * Direct browser and Node.js client for Quarkmint-Wasm.
 * Provides zero-allocation, sub-millisecond document compilation directly in Wasm.
 *
 * API surface exported from the Wasm module:
 *   alloc_buffer(size: u32) → ?[*]u8
 *   free_buffer(ptr: ?[*]u8, size: u32) → void
 *   parse_and_render(ptr: [*]u8, len: u32) → [*]u8
 *   compile(ptr: [*]u8, len: u32) → [*]u8
 *   compile_fragment(ptr: [*]u8, len: u32) → [*]u8
 *   compile_latex(ptr: [*]u8, len: u32) → [*]u8
 *   compile_latex_fragment(ptr: [*]u8, len: u32) → [*]u8
 *   last_result_len() → u32
 *   last_compile_len() → u32
 *   register_virtual_file(p_ptr, p_len, c_ptr, c_len) → void
 *   clear_virtual_files() → void
 */

// ── 1. Load the Wasm module ───────────────────────────────────────────────────

export async function loadQuarkmint(wasmPath = './zig-out/lib/quarkmint.wasm') {
  let wasmBytes;
  if (typeof process !== 'undefined' && process.versions && process.versions.node) {
    const fs = await import('node:fs');
    wasmBytes = fs.readFileSync(wasmPath);
  } else {
    const res = await fetch(wasmPath);
    wasmBytes = await res.arrayBuffer();
  }
  const { instance } = await WebAssembly.instantiate(wasmBytes, {});
  return createQuarkmintEngine(instance.exports);
}

// Backward-compatible alias
export const loadQdwasm = loadQuarkmint;

// ── 2. Engine wrapper ─────────────────────────────────────────────────────────

export function createQuarkmintEngine(exports) {
  const {
    memory,
    alloc_buffer,
    free_buffer,
    parse_and_render,
    compile,
    compile_fragment,
    compile_latex,
    compile_latex_fragment,
    last_result_len,
    last_compile_len,
    register_virtual_file,
    clear_virtual_files,
  } = exports;

  const enc = new TextEncoder();
  const dec = new TextDecoder('utf-8');

  /**
   * Internal helper to execute a compilation step.
   */
  function executeCompile(markdownSource, standalone, isLatex = false) {
    const srcBytes = enc.encode(markdownSource);
    const srcLen = srcBytes.byteLength;

    const inPtr = alloc_buffer(srcLen);
    if (!inPtr) throw new Error('quarkmint: OOM allocating input buffer');

    new Uint8Array(memory.buffer, inPtr, srcLen).set(srcBytes);

    let outPtr;
    if (isLatex) {
      outPtr = standalone
        ? (compile_latex ? compile_latex(inPtr, srcLen) : null)
        : (compile_latex_fragment ? compile_latex_fragment(inPtr, srcLen) : null);
    } else {
      outPtr = standalone
        ? compile(inPtr, srcLen)
        : compile_fragment(inPtr, srcLen);
    }

    const outLen = last_compile_len();
    if (!outPtr || !outLen) {
      free_buffer(inPtr, srcLen);
      throw new Error('quarkmint: compilation returned empty buffer');
    }

    const rawBytes = new Uint8Array(memory.buffer, outPtr, outLen);
    const output = dec.decode(
      rawBytes[rawBytes.length - 1] === 0
        ? rawBytes.subarray(0, rawBytes.length - 1)
        : rawBytes
    );

    free_buffer(outPtr, outLen);
    free_buffer(inPtr, srcLen);
    return output;
  }

  /**
   * Compile markdown into a complete, standalone HTML5 document.
   * @param {string} markdownSource
   * @returns {string} Full HTML5 document with embedded CSS.
   */
  function compileDocument(markdownSource) {
    return executeCompile(markdownSource, true, false);
  }

  /**
   * Compile markdown into an HTML body fragment (no doctype or shell).
   * @param {string} markdownSource
   * @returns {string} HTML body fragment.
   */
  function compileBodyFragment(markdownSource) {
    return executeCompile(markdownSource, false, false);
  }

  /**
   * Compile markdown into a complete, standalone LaTeX document.
   * @param {string} markdownSource
   * @returns {string} Standalone LaTeX source code.
   */
  function compileLatexDocument(markdownSource) {
    return executeCompile(markdownSource, true, true);
  }

  /**
   * Compile markdown into a LaTeX body fragment.
   * @param {string} markdownSource
   * @returns {string} LaTeX body fragment.
   */
  function compileLatexBodyFragment(markdownSource) {
    return executeCompile(markdownSource, false, true);
  }

  /**
   * Parse markdown and return the parsed JSON AST.
   * @param {string} markdownSource
   * @returns {object} { nodes: Node[] }
   */
  function parseAst(markdownSource) {
    const srcBytes = enc.encode(markdownSource);
    const srcLen = srcBytes.byteLength;

    const inPtr = alloc_buffer(srcLen);
    if (!inPtr) throw new Error('quarkmint: OOM allocating input buffer');

    new Uint8Array(memory.buffer, inPtr, srcLen).set(srcBytes);

    const outPtr = parse_and_render(inPtr, srcLen);
    const outLen = last_result_len();

    if (!outPtr || !outLen) {
      free_buffer(inPtr, srcLen);
      throw new Error('quarkmint: parse_and_render returned null');
    }

    const rawBytes = new Uint8Array(memory.buffer, outPtr, outLen);
    const jsonStr = dec.decode(
      rawBytes[rawBytes.length - 1] === 0
        ? rawBytes.subarray(0, rawBytes.length - 1)
        : rawBytes
    );

    free_buffer(outPtr, outLen);
    free_buffer(inPtr, srcLen);

    return JSON.parse(jsonStr);
  }

  /**
   * Register a virtual file in Wasm memory for `.include` calls.
   * @param {string} filePath
   * @param {string} content
   */
  function setFile(filePath, content) {
    const pBytes = enc.encode(filePath);
    const cBytes = enc.encode(content);

    const pPtr = alloc_buffer(pBytes.byteLength);
    new Uint8Array(memory.buffer, pPtr, pBytes.byteLength).set(pBytes);

    const cPtr = alloc_buffer(cBytes.byteLength);
    new Uint8Array(memory.buffer, cPtr, cBytes.byteLength).set(cBytes);

    register_virtual_file(pPtr, pBytes.byteLength, cPtr, cBytes.byteLength);

    free_buffer(cPtr, cBytes.byteLength);
    free_buffer(pPtr, pBytes.byteLength);
  }

  /**
   * Compile markdown to PDF using either pdflatex.wasm or local system TeX engines.
   * @param {string} markdownSource
   * @param {object} [options]
   * @param {'pdflatex.wasm'|'system'|'auto'} [options.engine='auto']
   * @returns {Promise<Uint8Array>}
   */
  async function compilePdf(markdownSource, options = {}) {
    const latex = compileLatexDocument(markdownSource);
    const engine = options.engine || 'auto';

    // 1. Try system engine if requested or in Node environment with local TeX
    if ((engine === 'system' || engine === 'auto') && typeof process !== 'undefined' && process.versions?.node) {
      const { spawnSync } = await import('node:child_process');
      const fs = await import('node:fs');
      const path = await import('node:path');
      const os = await import('node:os');

      const compilers = ['tectonic', 'pdflatex', 'xelatex'];
      for (const cmd of compilers) {
        const check = spawnSync('which', [cmd]);
        if (check.status === 0) {
          const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'quarkmint-tex-'));
          const texFile = path.join(tmpDir, 'document.tex');
          const pdfFile = path.join(tmpDir, 'document.pdf');
          fs.writeFileSync(texFile, latex);

          if (cmd === 'tectonic') {
            spawnSync('tectonic', [texFile, '-o', tmpDir]);
          } else {
            spawnSync(cmd, ['-interaction=nonstopmode', '-output-directory', tmpDir, texFile]);
          }

          if (fs.existsSync(pdfFile)) {
            const pdfBytes = fs.readFileSync(pdfFile);
            fs.rmSync(tmpDir, { recursive: true, force: true });
            return new Uint8Array(pdfBytes);
          }
          fs.rmSync(tmpDir, { recursive: true, force: true });
        }
      }
      if (engine === 'system') {
        throw new Error('No local LaTeX compiler found (pdflatex, xelatex, tectonic).');
      }
    }

    // 2. pdflatex.wasm runner (in-browser or fallback)
    return runPdfLatexWasm(latex, options);
  }

  return {
    compile: compileDocument,
    compileFragment: compileBodyFragment,
    compileLatex: compileLatexDocument,
    compileLatexFragment: compileLatexBodyFragment,
    compilePdf,
    parse: parseAst,
    setFile,
    clearFiles: clear_virtual_files,
  };
}

export const createQuarkdownEngine = createQuarkmintEngine;

// ── 3. CLI Example Run ────────────────────────────────────────────────────────

if (typeof process !== 'undefined' && process.argv && process.argv[1]?.endsWith('main.js')) {
  (async () => {
    try {
      const qd = await loadQuarkmint();

      const sampleDoc = `\\
.docname {Quarkmint Showcase}
.docauthor {Hassaan Maqsood}
.docdate {2026-09-23}

# Welcome to Quarkmint

Quarkmint is an ultra-fast, **Turing-complete** Markdown typesetting engine running directly in freestanding WebAssembly.

.box {Core Capabilities}
- Zero-copy token stream with zero heap allocation during lexing
- Lexical scoping & user-defined functions
- Sub-millisecond compilation (~94 µs latency)
- Fast mathematical typesetting: $E = mc^2$ and $\\int_0^\\infty e^{-x^2} dx = \\frac{\\sqrt{\\pi}}{2}$
- Responsive modern CSS embedded directly in the binary

.function {badge text} <span style="background: #10b981; color: #fff; padding: 2px 10px; border-radius: 9999px; font-weight: 600; font-size: 0.85em;">$text</span>

.badge {Compiled in Sub-Millisecond Wasm!}
`;

      console.log('🌱 --- Compiling Quarkmint Document ---');
      const start = performance.now();
      const html = qd.compile(sampleDoc);
      const elapsed = (performance.now() - start).toFixed(3);
      console.log(`Compiled standalone document in ${elapsed} ms! (${html.length} bytes)`);

      const texStart = performance.now();
      const tex = qd.compileLatex(sampleDoc);
      const texElapsed = (performance.now() - texStart).toFixed(3);
      console.log(`Compiled standalone LaTeX in ${texElapsed} ms! (${tex.length} bytes)`);

      const ast = qd.parse(sampleDoc);
      console.log(`Parsed AST successfully with ${ast.nodes.length} nodes.\\n`);
    } catch (err) {
      console.error('Error running Quarkmint Wasm:', err);
    }
  })();
}


/**
 * Run pdflatex.wasm in Web or Node environment.
 * Uses a minimal WebAssembly TeX engine (~14MB) or CDN-backed engine.
 */
async function runPdfLatexWasm(latexSource, options = {}) {
  // 1. If running in browser and engine is already on window
  if (typeof window !== 'undefined' && window.pdfTeXEngine) {
    const engine = new window.pdfTeXEngine();
    await engine.loadEngine();
    engine.writeMemFSFile('document.tex', latexSource);
    await engine.runLaTeX('document.tex');
    const pdfData = engine.readMEMFSFile('document.pdf');
    return new Uint8Array(pdfData);
  }

  // 2. If running in browser and need to load from CDN
  if (typeof window !== 'undefined' && typeof document !== 'undefined') {
    const cdnUrl = options.wasmUrl || 'https://cdn.jsdelivr.net/npm/swiftlatex@1.0.0/dist/swiftlatex.min.js';
    await new Promise((resolve, reject) => {
      const script = document.createElement('script');
      script.src = cdnUrl;
      script.onload = resolve;
      script.onerror = () => reject(new Error('Failed to load pdflatex.wasm engine from CDN: ' + cdnUrl));
      document.head.appendChild(script);
    });
    if (window.pdfTeXEngine) {
      return runPdfLatexWasm(latexSource, options);
    }
  }

  // 3. Node.js dynamic import fallback
  try {
    // Try standard pdflatex.wasm module if installed
    const pdflatex = await import('pdflatex.wasm');
    if (pdflatex.compile) {
      return await pdflatex.compile(latexSource);
    }
  } catch (_) {
    // Module not found or failed to load
  }

  throw new Error(
    'pdflatex.wasm engine is not available. Please install tectonic, pdflatex, or xelatex locally, or provide pdflatex.wasm.'
  );
}

// ── 4. Browser Live Preview Helper ────────────────────────────────────────────

/**
 * Attach live-preview compilation to an HTML input/textarea and render to target element.
 *
 * @param {HTMLTextAreaElement} textarea - Source input element
 * @param {HTMLElement|HTMLIFrameElement} output - Target container or iframe
 * @param {object} qd - Engine returned by loadQdwasm()
 * @param {boolean} [standalone=false] - Whether to render full document or fragment
 */
export function attachLivePreview(textarea, output, qd, standalone = false) {
  let debounceTimer;

  const render = () => {
    try {
      if (standalone && output.tagName === 'IFRAME') {
        const fullHtml = qd.compile(textarea.value);
        output.srcdoc = fullHtml;
      } else {
        const fragment = qd.compileFragment(textarea.value);
        output.innerHTML = fragment;
      }
    } catch (e) {
      if (output.tagName === 'IFRAME') {
        output.srcdoc = `<pre style="color: crimson;">${e}</pre>`;
      } else {
        output.innerHTML = `<div class="qd-error">${e}</div>`;
      }
    }
  };

  textarea.addEventListener('input', () => {
    clearTimeout(debounceTimer);
    debounceTimer = setTimeout(render, 40); // 40ms debounce: sub-frame responsiveness
  });

  render();
}
