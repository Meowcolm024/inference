import { escapeHtml } from "./markdown";

export function previewHtml(
  script: string,
  style: string,
  resourceSource: string,
  nonce: string,
): string {
  return `<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src ${resourceSource} 'unsafe-inline'; script-src 'nonce-${nonce}'; img-src data:;">
<link rel="stylesheet" href="${escapeHtml(style)}"><title>Inference Preview</title></head>
<body><header><div class="title"><span class="indicator" id="indicator"></span><strong>Inference</strong><span class="badge">LIVE</span></div><p id="status" role="status">Starting preview…</p></header>
<section id="issues" aria-label="Compiler diagnostics" hidden></section><main id="content"><p class="empty">Compiling your document…</p></main>
<script nonce="${nonce}" src="${escapeHtml(script)}"></script></body></html>`;
}
