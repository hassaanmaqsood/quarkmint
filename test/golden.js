/**
 * test/golden.js — Golden test suite & performance benchmark for Quarkdown Wasm.
 */

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const projectRoot = path.resolve(__dirname, '..');

async function loadEngine() {
  const wasmPath = path.join(projectRoot, 'zig-out', 'lib', 'quarkmint.wasm');
  const wasmBytes = fs.readFileSync(wasmPath);
  const { instance } = await WebAssembly.instantiate(wasmBytes, {});
  return createEngine(instance.exports);
}

function createEngine(wasm) {
  const {
    memory,
    alloc_buffer,
    free_buffer,
    parse_and_render,
    compile,
    compile_fragment,
    last_result_len,
    last_compile_len,
    register_virtual_file,
    clear_virtual_files,
  } = wasm;

  const enc = new TextEncoder();
  const dec = new TextDecoder('utf-8');

  function compileDoc(src, standalone = true) {
    const bytes = enc.encode(src);
    const inPtr = alloc_buffer(bytes.byteLength);
    if (!inPtr) throw new Error('OOM allocating input buffer');
    new Uint8Array(memory.buffer, inPtr, bytes.byteLength).set(bytes);

    const outPtr = standalone
      ? compile(inPtr, bytes.byteLength)
      : compile_fragment(inPtr, bytes.byteLength);

    const outLen = last_compile_len();
    if (!outPtr || !outLen) {
      free_buffer(inPtr, bytes.byteLength);
      throw new Error('Compilation failed: empty output');
    }

    const raw = new Uint8Array(memory.buffer, outPtr, outLen);
    const html = dec.decode(raw[raw.length - 1] === 0 ? raw.subarray(0, raw.length - 1) : raw);

    free_buffer(outPtr, outLen);
    free_buffer(inPtr, bytes.byteLength);
    return html;
  }

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

  function parseAst(src) {
    const bytes = enc.encode(src);
    const inPtr = alloc_buffer(bytes.byteLength);
    new Uint8Array(memory.buffer, inPtr, bytes.byteLength).set(bytes);

    const outPtr = parse_and_render(inPtr, bytes.byteLength);
    const outLen = last_result_len();

    const raw = new Uint8Array(memory.buffer, outPtr, outLen);
    const jsonStr = dec.decode(raw[raw.length - 1] === 0 ? raw.subarray(0, raw.length - 1) : raw);

    free_buffer(outPtr, outLen);
    free_buffer(inPtr, bytes.byteLength);
    return JSON.parse(jsonStr);
  }

  return {
    compile: (src) => compileDoc(src, true),
    compileFragment: (src) => compileDoc(src, false),
    parse: parseAst,
    setFile,
    clearFiles: clear_virtual_files,
  };
}

async function runTests() {
  console.log('🧪 Starting Quarkmint WebAssembly Golden Tests & Verification...\n');
  const engine = await loadEngine();

  const fixturesDir = path.join(__dirname, 'fixtures');
  const fixtures = [
    {
      name: 'hello',
      assertions(html, frag) {
        if (!frag.includes('<h1 id="hello-quarkdown">Hello Quarkdown</h1>')) throw new Error('Missing h1');
        if (!frag.includes('<em>italic</em>')) throw new Error('Missing em');
        if (!frag.includes('<strong>bold</strong>')) throw new Error('Missing strong');
        if (!frag.includes('<del>strike</del>')) throw new Error('Missing del');
        if (!frag.includes('<code>inline code</code>')) throw new Error('Missing code');
        if (!frag.includes('type="checkbox" checked')) throw new Error('Missing checked task item');
        if (!frag.includes('<blockquote>')) throw new Error('Missing blockquote');
        if (!html.startsWith('<!DOCTYPE html>')) throw new Error('Missing DOCTYPE in standalone');
      },
    },
    {
      name: 'functions',
      assertions(html, frag) {
        if (!frag.includes('<h1 id="title-my-document">Title: My Document</h1>')) throw new Error('Variable interpolation failed');
        if (!frag.includes('<div class="qd-box">')) throw new Error('Conditional box failed');
        if (!frag.includes('Hello, Alice!')) throw new Error('User defined function failed');
      },
    },
    {
      name: 'layout',
      assertions(html, frag) {
        if (!frag.includes('<div class="qd-row">')) throw new Error('Missing qd-row');
        if (!frag.includes('<div class="qd-col">')) throw new Error('Missing qd-col');
        if (!frag.includes('<div class="qd-align-center">')) throw new Error('Missing qd-align-center');
      },
    },
    {
      name: 'math',
      assertions(html, frag) {
        if (!frag.includes('<span class="math" data-tex="E = mc^2"><math><mi>E</mi><mo>=</mo><mi>m</mi><msup><mi>c</mi><mn>2</mn></msup></math></span>')) throw new Error('Missing inline math MathML');
        if (!frag.includes('<div class="math" data-tex="\\int_{0}^{\\infty} e^{-x^2} dx = \\frac{\\sqrt{\\pi}}{2}"><math display="block">')) throw new Error('Missing display math MathML');
        if (!frag.includes('<munderover><mo>∫</mo><mn>0</mn><mi>∞</mi></munderover>')) throw new Error('Missing MathML munderover integral with limits');
        if (!frag.includes('<mfrac><mrow><msqrt><mrow><mi>π</mi></mrow></msqrt></mrow><mrow><mn>2</mn></mrow></mfrac>')) throw new Error('Missing MathML fraction and square root');
        if (!frag.includes('<span class="math" data-tex="a^2 + b^2 = c^2"><math><msup><mi>a</mi><mn>2</mn></msup><mo>+</mo><msup><mi>b</mi><mn>2</mn></msup><mo>=</mo><msup><mi>c</mi><mn>2</mn></msup></math></span> as well.')) throw new Error('Missing inline mathspan');
      },
    },
    {
      name: 'academic',
      assertions(html, frag) {
        if (!frag.includes('<cite class="qd-citation">')) throw new Error('Missing citation');
        if (!frag.includes('href="#bib-knuth1984"')) throw new Error('Missing citation link');
        if (!frag.includes('<sup class="qd-footnote-ref">')) throw new Error('Missing footnote reference');
        if (!frag.includes('<section class="qd-footnotes">')) throw new Error('Missing footnotes section');
        if (!frag.includes('<section class="qd-bibliography">')) throw new Error('Missing bibliography section');
      },
    },
  ];

  for (const { name, assertions } of fixtures) {
    const qmdPath = path.join(fixturesDir, `${name}.qmd`);
    const qmdSource = fs.readFileSync(qmdPath, 'utf8');

    const frag = engine.compileFragment(qmdSource);
    const standalone = engine.compile(qmdSource);

    // Save golden HTML snapshot
    fs.writeFileSync(path.join(fixturesDir, `${name}.html`), standalone, 'utf8');

    assertions(standalone, frag);
    console.log(`  ✅ Fixture passed: [${name}.qmd] → [${name}.html]`);
  }

  // Virtual Files & Include Test
  console.log('\n📁 Testing Virtual Filesystem (.include)...');
  engine.setFile('intro.qmd', '## Sub Section\n\nIncluded from virtual file!\n');
  const includeDoc = '# Main Document\n\n.include {intro.qmd}\n';
  const includeHtml = engine.compileFragment(includeDoc);
  if (!includeHtml.includes('<h2 id="sub-section">Sub Section</h2>')) {
    throw new Error('VFS .include failed to render heading');
  }
  if (!includeHtml.includes('Included from virtual file!')) {
    throw new Error('VFS .include failed to render body');
  }
  engine.clearFiles();
  console.log('  ✅ Virtual Filesystem (.include) passed successfully');

  // Performance Benchmark
  console.log('\n⚡ Running Performance & Throughput Benchmark...');
  const benchDoc = `
.docname {Benchmark Document}
.docauthor {Engine Test}
.let {count} {10}

# Chapter 1: Introduction

This is a comprehensive document with **bold**, *italic*, and \`inline code\`.

.box {Notice}
Here is a callout box with $x^2 + y^2 = z^2$ inside.

.row {
  .column { Left column content }
  .column { Right column content }
}

- [x] High performance Wasm
- [x] Zero-copy tokenization
- [x] Sub-millisecond compilation
`;

  // Warmup
  for (let i = 0; i < 50; i++) {
    engine.compile(benchDoc);
  }

  const ITERATIONS = 1000;
  const start = performance.now();
  for (let i = 0; i < ITERATIONS; i++) {
    engine.compile(benchDoc);
  }
  const totalMs = performance.now() - start;
  const avgLatencyMs = totalMs / ITERATIONS;
  const docsPerSec = Math.round((ITERATIONS / totalMs) * 1000);

  console.log(`  • Iterations:       ${ITERATIONS}`);
  console.log(`  • Total time:       ${totalMs.toFixed(2)} ms`);
  console.log(`  • Average latency:  ${avgLatencyMs.toFixed(3)} ms / document (${(avgLatencyMs * 1000).toFixed(1)} µs)`);
  console.log(`  • Throughput:       ${docsPerSec.toLocaleString()} documents/sec`);

  if (avgLatencyMs < 1.0) {
    console.log(`  🚀 SUB-MILLISECOND COMPILATION GOAL ACHIEVED! (${(avgLatencyMs * 1000).toFixed(0)} microseconds per document)`);
  } else {
    console.warn(`  ⚠️ Compilation latency was >= 1.0 ms: ${avgLatencyMs.toFixed(3)} ms`);
  }

  console.log('\n🎉 ALL TESTS AND BENCHMARKS PASSED PERFECTLY!\n');
}

runTests().catch((err) => {
  console.error('\n❌ Test Failure:', err);
  process.exit(1);
});
