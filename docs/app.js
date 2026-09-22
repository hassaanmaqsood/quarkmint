/**
 * app.js — Quarkmint Interactive Browser Playground
 *
 * Direct client-side WebAssembly execution with zero server dependencies.
 */

// ── Document Presets ─────────────────────────────────────────────────────────

const PRESETS = {
  academic: `.docname {Quantum Coherence in 2D Superconducting Lattices}
.docauthor {Dr. Hassaan Maqsood, Quantum Nanoelectronics Laboratory}
.docdate {2026-09-23}
.doctype {paper}

.abstract {
This paper investigates non-equilibrium quasiparticle dynamics in engineered two-dimensional superconducting circuits. Using low-temperature spectroscopy, we demonstrate sub-microsecond state transitions with coherence times exceeding $T_2^* > 85\\,\\mu\\text{s}$.
}

# 1. Introduction

Superconducting qubits have emerged as a premier architecture for scalable quantum processors. The Hamiltonian governing a transmon coupled to an LC transmission line is modeled as:

$$
\\hat{H} = 4E_C(\\hat{n} - n_g)^2 - E_J \\cos\\hat{\\varphi} + \\hbar\\omega_r\\left(\\hat{a}^\\dagger\\hat{a} + \\frac{1}{2}\\right)
$$

Where $E_C$ represents the charging energy and $E_J$ is the Josephson tunneling energy.

.box {Theorem 1 (Coherence Bound)}
For any non-Markovian dissipative bath coupled via operator $\\hat{A}$, the decoherence rate $\\Gamma_2$ satisfies:
$$\\Gamma_2 = \\frac{1}{2T_1} + \\frac{1}{T_\\phi} \\ge \\frac{1}{2T_1}$$
where $T_1$ is the relaxation time and $T_\\phi$ is the pure dephasing time.

# 2. Experimental Hamiltonian Matrix

The discretized density matrix for the two-qubit ground state subspace is represented as:

$$
\\rho = \\begin{bmatrix}
0.94 & 0.02 + 0.01i & 0.01 & 0.00 \\\\
0.02 - 0.01i & 0.03 & 0.01 & 0.00 \\\\
0.01 & 0.01 & 0.02 & 0.00 \\\\
0.00 & 0.00 & 0.00 & 0.01
\\end{bmatrix}
$$

.quote {
"The ultimate test of quantum advantage is not just speed, but verifiable fidelity under ambient thermal noise." — Prof. E. H. Walker
}

# 3. Observations & Conclusion

- [x] Resonator frequency calibrated at $f_r = 6.425\\,\\text{GHz}$
- [x] Qubit transition frequency verified at $f_{01} = 4.812\\,\\text{GHz}$
- [ ] Multi-qubit parity readout optimization (in progress)

All simulations and document formatting were compiled in sub-millisecond WebAssembly using **Quarkmint**.
`,

  functions: `.docname {Programmable Markdown with Quarkmint}
.docauthor {Hassaan Maqsood}
.docdate {2026-09-23}

# Programmable Macros & Functions

Quarkmint extends standard Markdown into a **Turing-complete typesetting language** with lexical variables and user-defined functions.

.set {projectName Quarkmint}
.set {version 0.2.0}

## Variable Interpolation

This document is powered by **$projectName** version **$version**.

## Custom Component Functions

.function {badge text color} <span style="background: $color; color: #ffffff; padding: 2px 10px; border-radius: 9999px; font-weight: 600; font-size: 0.82em; display: inline-block;">$text</span>

.function {metric label val} <div style="display: inline-block; padding: 10px 16px; margin: 4px; border-radius: 8px; background: rgba(16,185,129,0.08); border: 1px solid rgba(16,185,129,0.3);"><div style="font-size: 0.75rem; color: #64748b; text-transform: uppercase;">$label</div><div style="font-size: 1.25rem; font-weight: 700; color: #059669;">$val</div></div>

.badge {Zero Heap Allocation} {#10b981}
.badge {Freestanding Wasm} {#2563eb}
.badge {Turing Complete} {#7c3aed}

### Compiler Telemetry

.metric {Average Latency} {94 µs}
.metric {Throughput} {10,600 docs/s}
.metric {Binary Size} {129 KB}

.box {Scoped Evaluation}
Variables declared inside blocks remain lexically isolated, preventing global state pollution!
`,

  math: `.docname {Mathematical Physics Handbook}
.docauthor {Quarkmint Mathematics Suite}
.docdate {2026-09-23}

# Mathematical Physics in Quarkmint

Quarkmint renders mathematical expressions directly into clean HTML and also compiles to pristine **LaTeX** documents.

## Fundamental Physics Equations

### Maxwell's Field Equations
$$
\\nabla \\cdot \\mathbf{E} = \\frac{\\rho}{\\varepsilon_0}, \\quad
\\nabla \\cdot \\mathbf{B} = 0
$$
$$
\\nabla \\times \\mathbf{E} = -\\frac{\\partial \\mathbf{B}}{\\partial t}, \\quad
\\nabla \\times \\mathbf{B} = \\mu_0\\mathbf{J} + \\mu_0\\varepsilon_0\\frac{\\partial \\mathbf{E}}{\\partial t}
$$

### General Relativity & Einstein Field Equations
$$
G_{\\mu\\nu} + \\Lambda g_{\\mu\\nu} = \\frac{8\\pi G}{c^4} T_{\\mu\\nu}
$$

### Gaussian Integral & Gamma Function
$$
\\int_{-\\infty}^{\\infty} e^{-x^2} dx = \\sqrt{\\pi}, \\qquad \\Gamma(z) = \\int_0^\\infty x^{z-1} e^{-x} dx
$$

## Linear Algebra & Matrices

$$
\\mathbf{A} = \\begin{pmatrix}
a_{11} & a_{12} & \\cdots & a_{1n} \\\\
a_{21} & a_{22} & \\cdots & a_{2n} \\\\
\\vdots & \\vdots & \\ddots & \\vdots \\\\
a_{m1} & a_{m2} & \\cdots & a_{mn}
\\end{pmatrix}
$$
`,

  layout: `.docname {Modern Bento Grid & Layout Showcase}
.docauthor {Quarkmint Design Engine}
.docdate {2026-09-23}

# Modern Document Layouts

Quarkmint natively supports structured containers, multi-column grids, and notification boxes.

.box {Overview}
Built-in layout primitives make it easy to create beautiful documentation, dashboards, and research reports.

.row
.col
.box {⚡ Sub-Millisecond Speed}
Compiles complex documents in approximately **94 microseconds** in WebAssembly.
.col
.box {📦 100% Freestanding}
Zero OS dependencies, zero libc, zero WASI runtime requirements.
.col
.box {📐 Dual Engine}
Compiles directly to HTML5 and production-ready LaTeX with one click.

# Admonition & Alert Styles

.info {This is an informational notice describing best practices.}

.warning {Please ensure your compiler target is set to wasm32-freestanding.}

.danger {Never allocate memory across Wasm boundaries without explicit bridge cleanup.}
`,

  minimal: `.docname {Quickstart Document}
.docauthor {Hassaan Maqsood}
.docdate {2026-09-23}

# Hello Quarkmint!

Welcome to **Quarkmint**, the sub-millisecond Markdown typesetting engine running in freestanding WebAssembly.

- Fast, reproducible typesetting
- Inline math: $e^{i\\pi} + 1 = 0$
- User-defined macros & functions
- Dual HTML5 & LaTeX generation
`
};

// ── WebAssembly Engine Loader ──────────────────────────────────────────────────

class QuarkmintRunner {
  constructor() {
    this.exports = null;
    this.memory = null;
    this.enc = new TextEncoder();
    this.dec = new TextDecoder('utf-8');
  }

  async init(wasmUrl = './quarkmint.wasm') {
    const res = await fetch(wasmUrl);
    if (!res.ok) throw new Error(`Failed to fetch Wasm module from ${wasmUrl}: HTTP ${res.status}`);
    const bytes = await res.arrayBuffer();
    const { instance } = await WebAssembly.instantiate(bytes, {});
    this.exports = instance.exports;
    this.memory = this.exports.memory;
  }

  compile(markdown, standalone = true) {
    const { alloc_buffer, free_buffer, compile, compile_fragment, last_compile_len } = this.exports;
    const srcBytes = this.enc.encode(markdown);
    const inPtr = alloc_buffer(srcBytes.byteLength);
    if (!inPtr) throw new Error('Wasm OOM allocating input buffer');

    new Uint8Array(this.memory.buffer, inPtr, srcBytes.byteLength).set(srcBytes);

    const outPtr = standalone ? compile(inPtr, srcBytes.byteLength) : compile_fragment(inPtr, srcBytes.byteLength);
    const outLen = last_compile_len();

    if (!outPtr || !outLen) {
      free_buffer(inPtr, srcBytes.byteLength);
      throw new Error('Compilation returned empty buffer');
    }

    const raw = new Uint8Array(this.memory.buffer, outPtr, outLen);
    const html = this.dec.decode(raw[raw.length - 1] === 0 ? raw.subarray(0, raw.length - 1) : raw);

    free_buffer(outPtr, outLen);
    free_buffer(inPtr, srcBytes.byteLength);
    return html;
  }

  compileLatex(markdown, standalone = true) {
    const { alloc_buffer, free_buffer, compile_latex, compile_latex_fragment, last_compile_len } = this.exports;
    if (!compile_latex) return '% LaTeX output not available in this build';

    const srcBytes = this.enc.encode(markdown);
    const inPtr = alloc_buffer(srcBytes.byteLength);
    if (!inPtr) throw new Error('Wasm OOM allocating input buffer');

    new Uint8Array(this.memory.buffer, inPtr, srcBytes.byteLength).set(srcBytes);

    const outPtr = standalone ? compile_latex(inPtr, srcBytes.byteLength) : compile_latex_fragment(inPtr, srcBytes.byteLength);
    const outLen = last_compile_len();

    if (!outPtr || !outLen) {
      free_buffer(inPtr, srcBytes.byteLength);
      throw new Error('Compilation returned empty buffer');
    }

    const raw = new Uint8Array(this.memory.buffer, outPtr, outLen);
    const tex = this.dec.decode(raw[raw.length - 1] === 0 ? raw.subarray(0, raw.length - 1) : raw);

    free_buffer(outPtr, outLen);
    free_buffer(inPtr, srcBytes.byteLength);
    return tex;
  }

  parseAst(markdown) {
    const { alloc_buffer, free_buffer, parse_and_render, last_result_len } = this.exports;
    const srcBytes = this.enc.encode(markdown);
    const inPtr = alloc_buffer(srcBytes.byteLength);
    if (!inPtr) throw new Error('Wasm OOM allocating input buffer');

    new Uint8Array(this.memory.buffer, inPtr, srcBytes.byteLength).set(srcBytes);

    const outPtr = parse_and_render(inPtr, srcBytes.byteLength);
    const outLen = last_result_len();

    if (!outPtr || !outLen) {
      free_buffer(inPtr, srcBytes.byteLength);
      throw new Error('Parse returned empty buffer');
    }

    const raw = new Uint8Array(this.memory.buffer, outPtr, outLen);
    const jsonStr = this.dec.decode(raw[raw.length - 1] === 0 ? raw.subarray(0, raw.length - 1) : raw);

    free_buffer(outPtr, outLen);
    free_buffer(inPtr, srcBytes.byteLength);

    try {
      return JSON.parse(jsonStr);
    } catch (_) {
      return { raw: jsonStr };
    }
  }
}

// ── Application Initialization ────────────────────────────────────────────────

const runner = new QuarkmintRunner();
let debounceTimer = null;
let currentTab = 'preview';
let latestCompiledHtml = '';
let latestCompiledLatex = '';
let latestAstJson = '';

// DOM Elements
const editor = document.getElementById('markdown-input');
const presetSelect = document.getElementById('preset-select');
const previewFrame = document.getElementById('preview-frame');
const latexOutput = document.getElementById('latex-output');
const astOutput = document.getElementById('ast-output');
const rawOutput = document.getElementById('raw-output');
const statLatency = document.getElementById('stat-latency');
const statThroughput = document.getElementById('stat-throughput');
const editorStats = document.getElementById('editor-stats');
const btnCopy = document.getElementById('btn-copy');
const btnDownload = document.getElementById('btn-download');
const btnFormat = document.getElementById('btn-format');
const toastEl = document.getElementById('toast');

function showToast(message) {
  if (!toastEl) return;
  toastEl.textContent = message;
  toastEl.classList.add('show');
  setTimeout(() => toastEl.classList.remove('show'), 2200);
}

function updateWordCount(text) {
  const words = text.trim() ? text.trim().split(/\\s+/).length : 0;
  const chars = text.length;
  if (editorStats) {
    editorStats.textContent = `${words} words • ${chars} chars`;
  }
}

function renderDocument() {
  const source = editor.value;
  updateWordCount(source);

  try {
    const t0 = performance.now();
    latestCompiledHtml = runner.compile(source, true);
    const t1 = performance.now();
    const elapsedMs = t1 - t0;
    const elapsedUs = Math.round(elapsedMs * 1000);

    // Update telemetry
    if (statLatency) {
      statLatency.textContent = elapsedUs < 1000 ? `${elapsedUs} µs` : `${elapsedMs.toFixed(2)} ms`;
    }
    if (statThroughput) {
      const docsPerSec = Math.round(1000 / Math.max(elapsedMs, 0.01));
      statThroughput.textContent = `${docsPerSec.toLocaleString()} docs/s`;
    }

    // Update Preview Iframe
    if (previewFrame) {
      previewFrame.srcdoc = latestCompiledHtml;
      setTimeout(renderIframeKatex, 30);
    }

    // Update Raw HTML
    if (rawOutput) {
      rawOutput.textContent = latestCompiledHtml;
    }

    // Update LaTeX
    if (currentTab === 'latex' || !latestCompiledLatex) {
      try {
        latestCompiledLatex = runner.compileLatex(source, true);
        if (latexOutput) latexOutput.textContent = latestCompiledLatex;
      } catch (texErr) {
        if (latexOutput) latexOutput.textContent = '% LaTeX compilation error: ' + texErr.message;
      }
    }

    // Update AST
    if (currentTab === 'ast') {
      try {
        const ast = runner.parseAst(source);
        latestAstJson = JSON.stringify(ast, null, 2);
        if (astOutput) astOutput.textContent = latestAstJson;
      } catch (astErr) {
        if (astOutput) astOutput.textContent = '// AST error: ' + astErr.message;
      }
    }
  } catch (err) {
    if (previewFrame) {
      previewFrame.srcdoc = `<div style="font-family: monospace; color: #ef4444; padding: 2rem;">
        <h3>Compilation Error</h3>
        <pre>${err.message || err}</pre>
      </div>`;
    }
  }
}

function handleTabSwitch(tabName) {
  currentTab = tabName;
  document.querySelectorAll('.tab-btn').forEach(btn => {
    btn.classList.toggle('active', btn.dataset.tab === tabName);
  });

  document.querySelectorAll('.view-panel').forEach(panel => {
    panel.classList.toggle('active', panel.id === `panel-${tabName}`);
  });

  if (tabName === 'latex' && !latexOutput.textContent) {
    latestCompiledLatex = runner.compileLatex(editor.value, true);
    latexOutput.textContent = latestCompiledLatex;
  } else if (tabName === 'ast') {
    const ast = runner.parseAst(editor.value);
    latestAstJson = JSON.stringify(ast, null, 2);
    astOutput.textContent = latestAstJson;
  }
}

// Event Listeners
editor.addEventListener('input', () => {
  clearTimeout(debounceTimer);
  debounceTimer = setTimeout(renderDocument, 30);
});

presetSelect.addEventListener('change', (e) => {
  const key = e.target.value;
  if (PRESETS[key]) {
    editor.value = PRESETS[key];
    latestCompiledLatex = '';
    latestAstJson = '';
    renderDocument();
    showToast(`Loaded "${e.target.selectedOptions[0].text}" preset`);
  }
});

btnFormat.addEventListener('click', () => {
  editor.value = PRESETS.minimal;
  renderDocument();
  showToast('Reset to minimal template');
});

document.querySelectorAll('.tab-btn').forEach(btn => {
  btn.addEventListener('click', () => handleTabSwitch(btn.dataset.tab));
});

btnCopy.addEventListener('click', async () => {
  let contentToCopy = latestCompiledHtml;
  let label = 'HTML';

  if (currentTab === 'latex') {
    if (!latestCompiledLatex) latestCompiledLatex = runner.compileLatex(editor.value, true);
    contentToCopy = latestCompiledLatex;
    label = 'LaTeX';
  } else if (currentTab === 'ast') {
    if (!latestAstJson) latestAstJson = JSON.stringify(runner.parseAst(editor.value), null, 2);
    contentToCopy = latestAstJson;
    label = 'AST JSON';
  }

  try {
    await navigator.clipboard.writeText(contentToCopy);
    showToast(`Copied ${label} to clipboard!`);
  } catch (_) {
    showToast('Failed to copy to clipboard');
  }
});

btnDownload.addEventListener('click', () => {
  const isLatex = currentTab === 'latex';
  const content = isLatex
    ? (latestCompiledLatex || runner.compileLatex(editor.value, true))
    : latestCompiledHtml;
  const filename = isLatex ? 'document.tex' : 'document.html';
  const mime = isLatex ? 'text/x-tex' : 'text/html';

  const blob = new Blob([content], { type: mime });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = filename;
  document.body.appendChild(a);
  a.click();
  document.body.removeChild(a);
  URL.revokeObjectURL(url);
  showToast(`Downloaded ${filename}`);
});

const btnPdf = document.getElementById('btn-pdf');
if (btnPdf) {
  btnPdf.addEventListener('click', () => {
    const frame = document.getElementById('preview-frame');
    try {
      if (frame && frame.contentWindow) {
        frame.contentWindow.focus();
        frame.contentWindow.print();
        showToast('Opening PDF print dialog (select "Save as PDF")...');
        return;
      }
    } catch (_) {}

    // Fallback if iframe sandbox restrictions apply
    const printWin = window.open('', '_blank');
    if (printWin) {
      printWin.document.write(latestCompiledHtml);
      printWin.document.close();
      printWin.focus();
      setTimeout(() => {
        printWin.print();
      }, 250);
      showToast('Opening PDF print window...');
    } else {
      showToast('Please allow popups to export PDF');
    }
  });
}

function renderIframeKatex() {
  if (!previewFrame) return;
  try {
    const doc = previewFrame.contentDocument || previewFrame.contentWindow.document;
    if (!doc || !doc.body) return;

    // Ensure KaTeX stylesheet is present in the iframe
    if (!doc.querySelector('link[href*="katex"]')) {
      const link = doc.createElement('link');
      link.rel = 'stylesheet';
      link.href = 'https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.css';
      doc.head.appendChild(link);
    }

    const doRender = (retries = 30) => {
      if (typeof window.katex !== 'undefined') {
        doc.querySelectorAll('.math').forEach((el) => {
          const tex = el.getAttribute('data-tex');
          if (tex && !el.dataset.katexRendered) {
            try {
              window.katex.render(tex, el, {
                displayMode: el.tagName === 'DIV',
                throwOnError: false,
              });
              el.dataset.katexRendered = 'true';
            } catch (_) {}
          }
        });
      } else if (retries > 0) {
        setTimeout(() => doRender(retries - 1), 50);
      }
    };
    doRender();
  } catch (_) {}
}

if (previewFrame) {
  previewFrame.addEventListener('load', renderIframeKatex);
}

// Bootstrap application
(async () => {
  try {
    await runner.init('./quarkmint.wasm');
    editor.value = PRESETS.academic;
    renderDocument();
    showToast('🌱 Quarkmint WebAssembly Engine Ready!');
  } catch (err) {
    console.error('Initialization error:', err);
    showToast('Error loading WebAssembly: ' + err.message);
  }
})();
