---
name: quarkmint
description: Sub-millisecond Turing-complete Markdown, LaTeX, and AST compilation engine using freestanding WebAssembly. Load directly from raw GitHub or GitHub Pages without local toolchains or Zig installations. Use when needing fast document typesetting, math formula rendering (KaTeX/LaTeX), academic paper formatting, custom macros (.function, .set, .box), or background Web Worker execution.
---

# Quarkmint AI Agent Skill

**Quarkmint** (`qdwasm`) is a sub-millisecond, Turing-complete Markdown typesetting engine written in Zig and compiled to freestanding WebAssembly (`wasm32-freestanding`). It requires **zero runtime dependencies, zero libc, zero WASI**, and exposes **zero imports** to the JavaScript host.

This skill equips AI agents to fetch, instantiate, and execute Quarkmint directly from raw GitHub content and GitHub Actions artifacts across browser runtimes, Web Workers, and Node.js environments without cloning the repository or installing local Zig toolchains.

---

## 1. Remote Raw GitHub & CDN Endpoints

All binaries and scripts are continuously built and verified via GitHub Actions (`ci.yml` and `pages.yml`). Use the following live URLs:

| Asset | Primary CDN (GitHub Pages / CORS Allowed) | Fallback (Raw GitHub Content) | Size / MIME |
| :--- | :--- | :--- | :--- |
| **Wasm Binary** | `https://hassaanmaqsood.github.io/quarkmint/quarkmint.wasm` | `https://raw.githubusercontent.com/hassaanmaqsood/qdwasm/main/docs/quarkmint.wasm` | ~129 KB (`application/wasm`) |
| **Web Worker** | `https://hassaanmaqsood.github.io/quarkmint/worker.js` | `https://raw.githubusercontent.com/hassaanmaqsood/qdwasm/main/worker.js` | ~8 KB (`text/javascript`) |
| **ESM Engine** | `https://hassaanmaqsood.github.io/quarkmint/app.js` | `https://raw.githubusercontent.com/hassaanmaqsood/qdwasm/main/main.js` | ~13 KB (`text/javascript`) |

> [!NOTE]
> For browser applications, use `https://hassaanmaqsood.github.io/quarkmint/quarkmint.wasm` as it serves `access-control-allow-origin: *` and the correct `application/wasm` MIME type. For Node.js or curl environments, both URLs are equally suitable.

---

## 2. Quickstart Recipes for AI Agents

### Recipe A: Zero-Install Standalone Node.js Runner
An agent can execute this pattern in any Node.js environment (v18+) without running `npm install` or touching the disk:

```javascript
// Run directly in Node.js
const wasmUrl = 'https://raw.githubusercontent.com/hassaanmaqsood/qdwasm/main/docs/quarkmint.wasm';
const res = await fetch(wasmUrl);
const wasmBytes = await res.arrayBuffer();

// Freestanding Wasm requires 0 imports: pass empty object {}
const { instance } = await WebAssembly.instantiate(wasmBytes, {});
const {
  memory, alloc_buffer, free_buffer,
  compile, compile_latex, parse_and_render,
  last_compile_len, last_result_len
} = instance.exports;

const enc = new TextEncoder();
const dec = new TextDecoder('utf-8');

function renderQuarkmint(markdown, isLatex = false) {
  const bytes = enc.encode(markdown);
  const inPtr = alloc_buffer(bytes.byteLength);
  new Uint8Array(memory.buffer, inPtr, bytes.byteLength).set(bytes);

  const outPtr = isLatex ? compile_latex(inPtr, bytes.byteLength) : compile(inPtr, bytes.byteLength);
  const outLen = last_compile_len();

  const raw = new Uint8Array(memory.buffer, outPtr, outLen);
  // Strip trailing null terminator if present
  const output = dec.decode(raw[raw.length - 1] === 0 ? raw.subarray(0, -1) : raw);

  free_buffer(outPtr, outLen);
  free_buffer(inPtr, bytes.byteLength);
  return output;
}

// Example usage:
const doc = `
.docname {Quantum Simulation}
.docauthor {Agent Antigravity}

# Hamiltonian Formulation
$$\\hat{H} = \\sum_{i} \\sigma_i^x \\sigma_{i+1}^x + h \\sum_i \\sigma_i^z$$

.box {Coherence Observation}
Decoherence rate is bounded by $T_2^* \\ge 85\\,\\mu\\text{s}$.
`;

console.log(renderQuarkmint(doc)); // Outputs standalone HTML5 with embedded CSS
console.log(renderQuarkmint(doc, true)); // Outputs standalone LaTeX
```

---

### Recipe B: In-Browser Web Worker (Non-Blocking UI)

Browsers block `new Worker('https://raw.githubusercontent.com/...')` due to cross-origin security restrictions. Use the **Blob URL pattern** to load the worker directly from raw GitHub without CORS errors:

```javascript
// In your browser application or iframe
async function initQuarkmintWorker() {
  const workerScriptUrl = 'https://raw.githubusercontent.com/hassaanmaqsood/qdwasm/main/worker.js';
  const wasmUrl = 'https://hassaanmaqsood.github.io/quarkmint/quarkmint.wasm';

  // 1. Fetch worker code as text and create Blob URL
  const scriptText = await fetch(workerScriptUrl).then(r => r.text());
  const blob = new Blob([scriptText], { type: 'application/javascript' });
  const blobUrl = URL.createObjectURL(blob);

  // 2. Instantiate worker module
  const worker = new Worker(blobUrl, { type: 'module' });

  // 3. Initialize with remote Wasm module
  let reqId = 0;
  const pending = new Map();

  worker.onmessage = (e) => {
    const { id, success, result, error } = e.data;
    const p = pending.get(id);
    if (!p) return;
    pending.delete(id);
    if (success) p.resolve(result);
    else p.reject(new Error(error));
  };

  function send(type, payload) {
    return new Promise((resolve, reject) => {
      const id = ++reqId;
      pending.set(id, { resolve, reject });
      worker.postMessage({ id, type, ...payload });
    });
  }

  await send('init', { wasmUrl });

  return {
    compile: (markdown, standalone = true) => send('compile', { markdown, options: { standalone } }),
    compileFragment: (markdown) => send('compileFragment', { markdown }),
    compileLatex: (markdown, standalone = true) => send('compileLatex', { markdown, options: { standalone } }),
    parse: (markdown) => send('parse', { markdown }),
    setFile: (path, content) => send('setFile', { path, content }),
    clearFiles: () => send('clearFiles', {}),
    terminate: () => worker.terminate(),
  };
}

// Usage:
const qm = await initQuarkmintWorker();
const html = await qm.compile('# Hello from Background Thread!\n\n$E = mc^2$');
document.getElementById('preview-frame').srcdoc = html;
```

---

### Recipe C: Node.js Multi-Threaded Compilation (`node:worker_threads`)

When running in Node.js backend pipelines, batch processing thousands of documents across threads:

```javascript
import { Worker } from 'node:worker_threads';
import { fileURLToPath } from 'node:url';

// Fetch worker.js if not local, or import directly
import { QuarkmintWorkerClient } from './worker.js';

const client = await QuarkmintWorkerClient.create({
  wasmUrl: 'https://raw.githubusercontent.com/hassaanmaqsood/qdwasm/main/docs/quarkmint.wasm',
  workerUrl: './worker.js'
});

const html = await client.compile('# High Throughput Compilation');
const latex = await client.compileLatex('# LaTeX Export');
const ast = await client.parse('# AST Structure');

console.log('Compiled document length:', html.length);
client.terminate();
```

---

### Recipe D: Document Structure & AST Extraction

Quarkmint provides zero-allocation AST serialization. Use `parse()` to analyze document structure, extract mathematical formulas, or summarize headers:

```javascript
const ast = await qm.parse(`
# Introduction
Here is equation: $E = mc^2$

## Experimental Setup
.box {Warning} High voltage!
`);

// Returns clean JSON AST:
// {
//   "nodes": [
//     { "type": "heading", "level": 1, "text": "Introduction" },
//     { "type": "paragraph", "children": [...] },
//     { "type": "heading", "level": 2, "text": "Experimental Setup" },
//     { "type": "box", "title": "Warning", ... }
//   ]
// }
```

---

### Recipe E: Virtual Filesystem for Multi-File Documents (`.include`)

Quarkmint allows assembling complex multi-chapter books or papers directly in memory without disk I/O:

```javascript
// Register virtual sub-files into Wasm memory
qm.setFile('chapters/ch1.qmd', `
# Chapter 1: Foundations
Core theorems and proofs.
`);

qm.setFile('chapters/ch2.qmd', `
# Chapter 2: Implementation
Detailed experimental apparatus.
`);

// Main master document
const master = `
.docname {Complete Thesis}
.docauthor {Dr. Researcher}

.include {chapters/ch1.qmd}
.include {chapters/ch2.qmd}
`;

const fullHtml = await qm.compile(master);
```

---

## 3. WebAssembly ABI Specification

The freestanding Wasm module exports exactly 12 symbols:

| Export Function | Signature | Description |
| :--- | :--- | :--- |
| `memory` | `WebAssembly.Memory` | Linear memory (64 KB initial pages). |
| `alloc_buffer` | `(size: u32) -> u32` | Allocates `size` bytes in the internal heap and returns a byte pointer. Returns `0` on OOM. |
| `free_buffer` | `(ptr: u32, size: u32) -> void` | Frees an allocated buffer of `size` bytes. **Must be called for both input and output buffers.** |
| `compile` | `(ptr: u32, len: u32) -> u32` | Compiles Markdown to a complete standalone HTML5 document (with CSS). |
| `compile_fragment` | `(ptr: u32, len: u32) -> u32` | Compiles Markdown to an HTML body fragment (no `<!DOCTYPE>` or `<html>`). |
| `compile_latex` | `(ptr: u32, len: u32) -> u32` | Compiles Markdown to a complete standalone LaTeX document (`\documentclass{article}`). |
| `compile_latex_fragment` | `(ptr: u32, len: u32) -> u32` | Compiles Markdown to a LaTeX body fragment. |
| `last_compile_len` | `() -> u32` | Returns the byte length of the last `compile*` output. |
| `parse_and_render` | `(ptr: u32, len: u32) -> u32` | Parses Markdown and returns a JSON AST string pointer. |
| `last_result_len` | `() -> u32` | Returns the byte length of the last `parse_and_render` output. |
| `register_virtual_file` | `(p_ptr: u32, p_len: u32, c_ptr: u32, c_len: u32) -> void` | Registers an in-memory virtual file path and content for `.include`. |
| `clear_virtual_files` | `() -> void` | Clears all registered virtual files. |

---

## 4. Worker Protocol Specification (`worker.js`)

When communicating with `worker.js`, messages follow a standard request-response protocol:

### Request Message Format:
```typescript
interface WorkerRequest {
  id: number;                          // Unique request ID
  type: 'init' | 'compile' | 'compileFragment' | 'compileLatex' | 'compileLatexFragment' | 'parse' | 'setFile' | 'clearFiles';
  markdown?: string;                   // Input source
  options?: { standalone?: boolean };  // Default: true
  path?: string;                       // For setFile
  content?: string;                    // For setFile
  wasmUrl?: string;                    // Optional override URL
}
```

### Response Message Format:
```typescript
interface WorkerResponse {
  id: number;                          // Matching request ID
  success: boolean;                    // true if succeeded
  result?: string | object;            // HTML, LaTeX string, or AST object
  durationMs?: number;                 // Sub-millisecond timing telemetry
  error?: string;                      // Present if success === false
}
```

---

## 5. Quarkmint Language & Syntax Cheat Sheet

| Feature | Syntax | Output / Effect |
| :--- | :--- | :--- |
| **Document Metadata** | `.docname {Title}`<br/>`.docauthor {Author}`<br/>`.docdate {2026-09-27}`<br/>`.doctype {paper}` | Injected into HTML `<head>` / header banner and LaTeX document preamble. |
| **Abstract** | `.abstract { Summary text... }` | Formatted academic abstract block. |
| **Inline Math** | `$E = mc^2$` | KaTeX math span in HTML / `$E=mc^2$` in LaTeX. |
| **Display Math** | `$$\int_0^\infty e^{-x^2} dx = \frac{\sqrt{\pi}}{2}$$` | Centered display equation block. |
| **Note Boxes** | `.box {Theorem 1} Content here` | Styled rounded card with colored accent border. |
| **Admonitions** | `.info {Info notice}`<br/>`.warning {Caution}`<br/>`.danger {Critical notice}`<br/>`.success {Completed}` | Color-coded alert boxes with status accents. |
| **Quotes** | `.quote {Quoted text}` | Modern styled blockquote. |
| **Variables** | `.set {version 0.2.0}`<br/>`Version is $version.` | In-place variable declaration and interpolation. |
| **Functions / Macros** | `.function {badge text color} <span style="background:$color">$text</span>`<br/>`.badge {Active} {#10b981}` | User-defined reusable components with argument substitution. |
| **Layout Grids** | `.row`<br/>`.box {Card 1}`<br/>`.col`<br/>`.box {Card 2}` | Responsive CSS flexbox columns. |
| **File Includes** | `.include {subdoc.qmd}` | Inlines virtual or filesystem documents. |

---

## 6. Agent Troubleshooting & Edge Cases

1. **Avoid Browser Worker CORS Block**:
   - Never do: `new Worker('https://raw.githubusercontent.com/...')`.
   - Always fetch script text and pass `URL.createObjectURL(new Blob([code], { type: 'application/javascript' }))`.

2. **Always Free Wasm Pointers**:
   - Both input (`inPtr`) and output (`outPtr`) must be released using `free_buffer(ptr, len)`. Quarkmint's allocator prevents leaks, but uncollected buffers will consume linear memory.

3. **Trailing Null Byte Check**:
   - Certain Wasm builds may append a terminating `\0` byte. Always check:
     `const clean = raw[raw.length - 1] === 0 ? raw.subarray(0, -1) : raw;`

4. **Empty Buffer Handling**:
   - If `last_compile_len() === 0` or pointer is null, handle as compilation syntax error or empty input.
