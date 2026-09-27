/**
 * worker.js — Quarkmint Universal Web Worker & Background Compiler
 *
 * Provides non-blocking, sub-millisecond document compilation in a dedicated
 * Web Worker (browser) or Worker thread (Node.js). Can be loaded directly
 * from GitHub raw content or local deployment.
 *
 * Raw GitHub Wasm URL:
 *   https://raw.githubusercontent.com/hassaanmaqsood/qdwasm/main/docs/quarkmint.wasm
 * GitHub Pages CDN URL:
 *   https://hassaanmaqsood.github.io/quarkmint/quarkmint.wasm
 */

const DEFAULT_WASM_URLS = [
  './quarkmint.wasm',
  './docs/quarkmint.wasm',
  './zig-out/lib/quarkmint.wasm',
  'https://hassaanmaqsood.github.io/quarkmint/quarkmint.wasm',
  'https://raw.githubusercontent.com/hassaanmaqsood/qdwasm/main/docs/quarkmint.wasm',
];

// ── 1. Minimal Freestanding Wasm Engine Wrapper ──────────────────────────────

export function createQuarkmintEngine(wasmExports) {
  const {
    memory,
    alloc_buffer,
    free_buffer,
    compile,
    compile_fragment,
    compile_latex,
    compile_latex_fragment,
    parse_and_render,
    last_compile_len,
    last_result_len,
    register_virtual_file,
    clear_virtual_files,
  } = wasmExports;

  const enc = new TextEncoder();
  const dec = new TextDecoder('utf-8');

  function executeCompile(markdownSource, standalone, isLatex = false) {
    const srcBytes = enc.encode(markdownSource);
    const srcLen = srcBytes.byteLength;

    const inPtr = alloc_buffer(srcLen);
    if (!inPtr) throw new Error('quarkmint: Out of memory allocating input buffer');

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
      throw new Error('quarkmint: Compilation returned empty buffer');
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

  function parseAst(markdownSource) {
    const srcBytes = enc.encode(markdownSource);
    const srcLen = srcBytes.byteLength;

    const inPtr = alloc_buffer(srcLen);
    if (!inPtr) throw new Error('quarkmint: Out of memory allocating input buffer');

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

  return {
    compile: (src) => executeCompile(src, true, false),
    compileFragment: (src) => executeCompile(src, false, false),
    compileLatex: (src) => executeCompile(src, true, true),
    compileLatexFragment: (src) => executeCompile(src, false, true),
    parse: parseAst,
    setFile,
    clearFiles: clear_virtual_files,
  };
}

// ── 2. Universal Wasm Fetcher ────────────────────────────────────────────────

export async function fetchAndInstantiateWasm(customUrlOrBytes) {
  if (customUrlOrBytes instanceof ArrayBuffer || customUrlOrBytes instanceof Uint8Array) {
    const { instance } = await WebAssembly.instantiate(customUrlOrBytes, {});
    return createQuarkmintEngine(instance.exports);
  }

  const urlsToTry = customUrlOrBytes
    ? [customUrlOrBytes, ...DEFAULT_WASM_URLS]
    : DEFAULT_WASM_URLS;

  let lastError = null;

  for (const candidate of urlsToTry) {
    try {
      if (typeof process !== 'undefined' && process.versions?.node && !candidate.startsWith('http')) {
        const fs = await import('node:fs');
        if (fs.existsSync(candidate)) {
          const bytes = fs.readFileSync(candidate);
          const { instance } = await WebAssembly.instantiate(bytes, {});
          return createQuarkmintEngine(instance.exports);
        }
      } else {
        const res = await fetch(candidate);
        if (res.ok) {
          const bytes = await res.arrayBuffer();
          const { instance } = await WebAssembly.instantiate(bytes, {});
          return createQuarkmintEngine(instance.exports);
        }
      }
    } catch (err) {
      lastError = err;
    }
  }

  throw new Error(`quarkmint: Failed to load WebAssembly module. Last error: ${lastError?.message || lastError}`);
}

// ── 3. Worker Message Dispatcher ─────────────────────────────────────────────

let engineInstance = null;
let initPromise = null;

async function ensureEngine(wasmUrlOrBytes) {
  if (engineInstance) return engineInstance;
  if (!initPromise) {
    initPromise = fetchAndInstantiateWasm(wasmUrlOrBytes).then((engine) => {
      engineInstance = engine;
      return engine;
    });
  }
  return initPromise;
}

export async function handleWorkerMessage(message) {
  const { id, type, markdown, options = {}, path, content, wasmUrl, wasmBytes } = message || {};

  try {
    const engine = await ensureEngine(wasmBytes || wasmUrl);
    const start = performance.now();

    let result;
    switch (type) {
      case 'init':
        return { id, success: true, initialized: true };

      case 'compile':
        result = options.standalone !== false
          ? engine.compile(markdown)
          : engine.compileFragment(markdown);
        break;

      case 'compileFragment':
        result = engine.compileFragment(markdown);
        break;

      case 'compileLatex':
        result = options.standalone !== false
          ? engine.compileLatex(markdown)
          : engine.compileLatexFragment(markdown);
        break;

      case 'compileLatexFragment':
        result = engine.compileLatexFragment(markdown);
        break;

      case 'parse':
        result = engine.parse(markdown);
        break;

      case 'setFile':
        engine.setFile(path, content);
        return { id, success: true };

      case 'clearFiles':
        engine.clearFiles();
        return { id, success: true };

      default:
        throw new Error(`quarkmint worker: Unknown command type "${type}"`);
    }

    const durationMs = performance.now() - start;
    return { id, success: true, result, durationMs };
  } catch (err) {
    return { id, success: false, error: err?.message || String(err) };
  }
}

// ── 4. Web Worker / Node worker_threads Auto-Binding ─────────────────────────

const isWebWorker = typeof self !== 'undefined' && typeof window === 'undefined' && typeof self.postMessage === 'function';

if (isWebWorker) {
  self.addEventListener('message', async (e) => {
    const res = await handleWorkerMessage(e.data);
    self.postMessage(res);
  });
} else if (typeof process !== 'undefined' && process.versions?.node) {
  try {
    const { parentPort } = await import('node:worker_threads');
    if (parentPort) {
      parentPort.on('message', async (data) => {
        const res = await handleWorkerMessage(data);
        parentPort.postMessage(res);
      });
    }
  } catch (_) {}
}

// ── 5. Client Helper Class ───────────────────────────────────────────────────

export class QuarkmintWorkerClient {
  constructor(worker) {
    this.worker = worker;
    this.reqId = 0;
    this.pending = new Map();

    const onMessage = (event) => {
      const data = event.data || event;
      if (!data || data.id === undefined) return;
      const resolver = this.pending.get(data.id);
      if (resolver) {
        this.pending.delete(data.id);
        if (data.success) {
          resolver.resolve(data.result !== undefined ? data.result : data);
        } else {
          resolver.reject(new Error(data.error || 'Worker error'));
        }
      }
    };

    if (this.worker.addEventListener) {
      this.worker.addEventListener('message', onMessage);
    } else if (this.worker.on) {
      this.worker.on('message', onMessage);
    }
  }

  send(type, payload = {}) {
    return new Promise((resolve, reject) => {
      const id = ++this.reqId;
      this.pending.set(id, { resolve, reject });
      this.worker.postMessage({ id, type, ...payload });
    });
  }

  init(wasmUrl) {
    return this.send('init', { wasmUrl });
  }

  compile(markdown, options = {}) {
    return this.send('compile', { markdown, options });
  }

  compileFragment(markdown) {
    return this.send('compileFragment', { markdown });
  }

  compileLatex(markdown, options = {}) {
    return this.send('compileLatex', { markdown, options });
  }

  compileLatexFragment(markdown) {
    return this.send('compileLatexFragment', { markdown });
  }

  parse(markdown) {
    return this.send('parse', { markdown });
  }

  setFile(path, content) {
    return this.send('setFile', { path, content });
  }

  clearFiles() {
    return this.send('clearFiles');
  }

  terminate() {
    if (this.worker.terminate) this.worker.terminate();
  }

  /**
   * Spawns a worker from raw GitHub script or local path safely without CORS issues.
   */
  static async create(options = {}) {
    const {
      wasmUrl = 'https://hassaanmaqsood.github.io/quarkmint/quarkmint.wasm',
      workerUrl = 'https://raw.githubusercontent.com/hassaanmaqsood/qdwasm/main/worker.js',
    } = options;

    if (typeof window !== 'undefined') {
      // Browser environment: fetch worker code and instantiate as Blob to prevent cross-origin errors
      let scriptCode;
      try {
        const res = await fetch(workerUrl);
        scriptCode = await res.text();
      } catch (_) {
        // Fallback to local import if fetch fails
        scriptCode = `import '${workerUrl}';`;
      }
      const blob = new Blob([scriptCode], { type: 'application/javascript' });
      const blobUrl = URL.createObjectURL(blob);
      const worker = new Worker(blobUrl, { type: 'module' });
      const client = new QuarkmintWorkerClient(worker);
      await client.init(wasmUrl);
      return client;
    } else if (typeof process !== 'undefined' && process.versions?.node) {
      // Node.js environment: worker_threads
      const { Worker } = await import('node:worker_threads');
      const path = await import('node:path');
      const fs = await import('node:fs');

      let workerPath = workerUrl;
      if (workerUrl.startsWith('http')) {
        // In Node, if workerUrl is remote, check local worker.js first
        const localWorker = path.resolve('worker.js');
        if (fs.existsSync(localWorker)) {
          workerPath = localWorker;
        }
      }

      const worker = new Worker(workerPath);
      const client = new QuarkmintWorkerClient(worker);
      await client.init(wasmUrl);
      return client;
    }

    throw new Error('Unsupported runtime for QuarkmintWorkerClient');
  }
}
