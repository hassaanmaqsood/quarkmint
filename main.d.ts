export interface QuarkmintEngine {
  compile(markdownSource: string): string;
  compileFragment(markdownSource: string): string;
  compileLatex(markdownSource: string): string;
  compileLatexFragment(markdownSource: string): string;
  compilePdf(markdownSource: string, options?: { engine?: 'auto' | 'pdflatex.wasm' | 'system'; wasmUrl?: string }): Promise<Uint8Array>;
  parse(markdownSource: string): { nodes: any[] };
  setFile(filePath: string, content: string): void;
  clearFiles(): void;
}

export function loadQuarkmint(wasmPath?: string): Promise<QuarkmintEngine>;
export function loadQdwasm(wasmPath?: string): Promise<QuarkmintEngine>;
export function createQuarkmintEngine(exports: any): QuarkmintEngine;
export function createQuarkdownEngine(exports: any): QuarkmintEngine;
export function attachLivePreview(
  textarea: HTMLTextAreaElement,
  output: HTMLElement | HTMLIFrameElement,
  engine: QuarkmintEngine,
  standalone?: boolean
): void;
