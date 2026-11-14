# Wasm compiler and web editor

The GHC Wasm wrapper in `wasm/` reuses the Haskell compiler and HTML renderer. The browser editor and worker integration are proposed.

## Build and smoke test

From the repository root, enter the toolchain shell with `nix develop path:.`. Run the following in that shell.

```sh
cd wasm
wasm32-wasi-cabal build exe:inference-wasm
binary=$(wasm32-wasi-cabal list-bin exe:inference-wasm)
node "$(wasm32-wasi-ghc --print-libdir)/post-link.mjs" -i "$binary" -o dist-newstyle/bindings.mjs
npm install --prefix dist-newstyle --ignore-scripts @bjorn3/browser_wasi_shim@0.4.2
node smoke.mjs "$binary" dist-newstyle/bindings.mjs \
  dist-newstyle/node_modules/@bjorn3/browser_wasi_shim/dist/index.js
```

## Compiler API

Export one worker-local function, `compilePreview(requestJson: string): Promise<string>`, from an initialized Wasm reactor. The worker owns the instance and uses GHC's JavaScript bindings and a browser WASI runtime. The main thread sends and receives the decoded objects below with `postMessage`.

```ts
type Attr = {
  id: string;
  classes: string[];
  pairs: [string, string][];
};

type Item = {
  key: string;
  kind: "notation" | "block" | "inline";
  attr: Attr;
  source: string;
};

type PreviewRequest = {
  revision: number;
  items: Item[];
  modules: { path: string; source: string }[];
};

type Location = {
  source: { item: string } | { module: string };
  start: { line: number; column: number };
  end: { line: number; column: number };
};

type Diagnostic = {
  code: string;
  message: string;
  location: Location | null;
  related: { message: string; location: Location }[];
};

type PreviewResponse =
  | { revision: number; status: "ok"; fragments: { key: string; html: string }[] }
  | { revision: number; status: "invalid"; diagnostics: Diagnostic[] }
  | { revision: number | null; status: "error"; message: string };
```

Send items in document order. Keys identify occurrences within a revision, including when author IDs repeat. Keep attribute pairs ordered and pass them through to the Haskell option parser. Each successful response has one fragment per renderable item. Notation items contribute to the scope and produce no fragment. The initial implementation can return the first compiler error and its related locations. Use the error response for malformed requests or runtime failures.

The wrapper builds one notation scope from all declarations and imports, then parses sections and inline expressions against that scope in document order. It uses `renderHtml` and `renderHtmlExpression` with the HTML templates. The in-memory `NotationResolver` resolves nested imports relative to the importing module, normalizes aliases for deduplication, and reports missing modules and paths that escape the project root.

Locations use one-based lines and Unicode code-point columns with exclusive ends. The Markdown adapter keeps a map from each extracted body to document offsets. Account for stripped container prefixes, fence indentation, inline whitespace normalization, and conversion to the editor's UTF-16 offsets. Imported diagnostics identify the project file directly.

## Extracting Pandoc inference items

Prototype with `markdown-it` and `@mdit/plugin-attrs` configured with `rule: ["fence", "inline"]`. A local probe of this plugin and `markdown-it-attrs` confirmed both expose IDs, classes, quoted values with spaces, and attributes on inline code. Both expose fence line ranges but leave inline code offsets unset. Both consumed `{=html}` without retaining the raw format, so capture the original fence info before attribute processing. [Plugin rules](https://mdit-plugins.github.io/attrs.html) · [markdown-it-attrs](https://www.npmjs.com/package/markdown-it-attrs)

Use the same token tree for extraction and preview. Let the tokenizer handle fence boundaries and nesting. Add an adapter for source offsets, bare inference fence names, and Pandoc-specific edge cases. `pandoc-wasm` is another option if the preview needs Pandoc's full reader. Measure its startup cost and check source positions before choosing it. [Pandoc Wasm](https://github.com/pandoc/pandoc-wasm)

1. Read `#id`, `.class`, and ordered `key=value` pairs from the plugin's fence token. Recognize the bare `inference` and `inference-notation` info strings as classes. Keep the logical fence body as literal text, including Unicode rule bars, line breaks, and relative indentation.
2. Classify `.inference-notation` as a declaration and `.inference` as a content block, with declaration precedence when both classes occur. Leave `kind` and `rule_set` validation to Haskell. For inline code, parse an attribute list immediately after the closing backticks and extract spans with `.inference`. Preserve the tokenizer's normalized code text and its offset map.
3. Keep ordinary code tokens on the Markdown rendering path. Pandoc class-marked inference fences correspond to `CodeBlock` nodes. The distinct `{=format}` syntax creates raw content such as `RawBlock` and does not mark inference input. Report malformed inference attributes at the opener while allowing the rest of the Markdown to preview.

Compare extraction fixtures with native `pandoc -f markdown -t json`. Check attribute decoding, both fence characters, longer fences containing examples, list and quote nesting, inline backtick runs, and `{=html}` fences. Document any reader differences as the supported Markdown subset. [Pandoc fenced code attributes](https://pandoc.org/MANUAL.html#extension-fenced_code_attributes) · [Inline code attributes](https://pandoc.org/MANUAL.html#extension-inline_code_attributes) · [Raw attributes](https://pandoc.org/MANUAL.html#extension-raw_attribute)

## Web frontend

- **Markdown editor.** Use a source editor with undo, syntax highlighting, and clickable diagnostics. Show Markdown and preview side by side on wide screens and as switchable panes on narrow screens. A project file list lets users open imported notation files.
- **Live preview.** Debounce changes to the document or its module files and compile the full set of inference items so a later declaration can update earlier rules. Discard responses from superseded revisions. Render Markdown prose and ordinary math through the Markdown pipeline and insert inference fragments at the matching token nodes. Show diagnostics alongside the last successful inference preview while an edit is invalid.
- **Unicode input.** Support native typing, paste, and IME composition. Add an editor command for a searchable symbol picker and explicit completions such as `\vdash` → `⊢`, `\to` → `→`, `\lambda` → `λ`, and `\sub1` → `₁`. Include `─` and an action to insert a full rule bar. Apply replacements on acceptance as one undoable edit and suspend completions during IME composition.
- **Preview rendering.** Disable raw Markdown HTML in the initial editor. Sanitize compiler fragments before DOM insertion because HTML templates can contain markup. Allow the tags and layout properties used by the renderer, with a CSS property and value allowlist for inline styles.

Start with the STLC Markdown example and its notation module. Verify that editing a later declaration updates an earlier rule, an imported-file error opens the correct location, Unicode completion inserts literal source text, and the preview recovers after an invalid edit.
