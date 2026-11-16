# Inference live preview

A private npm project built with TypeScript, React, Vite, CodeMirror, and KaTeX. Edit Markdown on the left and see the rendered document on the right. Inference rules, grammars, equations, and inline expressions use the real Haskell Wasm compiler in a browser worker. The app has no backend.

## Run locally

Use Node 22.12+ (or Node 24+) and npm. From the repository root:

```sh
cd frontend
npm ci
npm run dev
```

Open the local URL printed by Vite, normally `http://127.0.0.1:5173`. The editor starts with a working example and restores your last draft from browser storage.

The first launch prepares `public/wasm/inference.wasm` and matching `bindings.mjs`. If the VS Code extension's artifacts already exist, it copies them. Otherwise it runs `stack build` and the shared Wasm build script; this needs Stack and the repository's Nix toolchain and may download compiler dependencies. Subsequent launches reuse the artifacts. After changing Haskell sources, run:

```sh
npm run build:wasm
```

You can supply prebuilt artifacts with `INFERENCE_WASM_ARTIFACTS=/absolute/path/to/artifacts npm run dev`. That directory must contain both matching files. No Haskell toolchain is needed in that case.

The inference compiler requires browser support for [WebAssembly JavaScript Promise Integration](https://v8.dev/blog/jspi), available in current Chrome, Edge, and Firefox. Unsupported browsers show a message when inference input is present; ordinary Markdown and KaTeX still work.

## Editing

The preview updates after a 150 ms typing pause. Invalid inference input retains the last successful preview and shows clickable source errors. Later notation declarations apply throughout the document. Double-click a rendered inference block or expression to return to its source line. On narrow screens, use the Markdown and Preview tabs.

The continuous preview uses typography inspired by LaTeX papers: Computer Modern-style fonts from KaTeX, a centered title, numbered sections, justified paragraphs, and unboxed mathematical displays. Content flows directly in the preview pane without page boundaries, shadows, or pagination.

Ordinary math supports `$…$`, `$$…$$`, `\(…\)`, and `\[…\]`. KaTeX styles and fonts are bundled locally. Math inside code fences stays literal.

````markdown
# Functions

Ordinary math: $e^{i\pi}+1=0$.

The type `A → B`{.inference} is a function type.

```{.inference rule_set="Application"}
Γ ⊢ e₁ : A → B
Γ ⊢ e₂ : A
──────────────────── T-App
Γ ⊢ e₁ e₂ : B
```

```inference-notation
infixr:60 "→"
notation:50 Γ:51 "⊢" e:51 ":" A:51
```
````

Use `kind=bnf`, `kind=equation`, or `kind=expr` on an inference fence for the other block formats. Both bare fence names and Pandoc-style attributes work. Markdown uses CommonMark with tables and strikethrough plus the inference syntax; this is not a full Pandoc reader.

**Open** accepts one Markdown document and optional `.notation` files. Select them together, or add notation files later. Modules are registered by filename, so write `import "types.notation"` and select `types.notation`. Files selected later replace modules with the same name. The browser does not watch disk changes or retain directory paths; reopen changed modules and use flat filenames for this initial editor. Opening another Markdown document replaces the current document and its module set.

Source and imported modules are saved in local browser storage. Compilation happens locally. Raw Markdown HTML is escaped, notation HTML overrides are ignored, and KaTeX runs with `trust: false`. Markdown images and links can still access their specified URLs.

## Build and check

```sh
npm run build
npm run preview
```

Serve the generated `dist/` directory using any static HTTP server. Relative asset paths also support a deployment under a subdirectory. Keep the `wasm/` directory with the generated JavaScript and CSS. Opening `index.html` directly with `file://` is not supported.

```sh
npm run check
npm test
npm run format:check
npx playwright install chromium
npm run test:browser
```

For an existing Chrome/Chromium installation, skip the browser download and run `CHROMIUM_EXECUTABLE_PATH=/path/to/chrome npm run test:browser`. Browser tests build and serve the production app, run the real Wasm compiler, and cover live updates, Unicode diagnostics, imports, persistence, and mobile layout. Screenshots are saved to `test-results/desktop.png` and `test-results/mobile.png`.

This project has its own `package.json` and lockfile and is marked `private: true`. It shares the pure Markdown adapter and protocol types in `../vscode-extension/src/` and the Wasm build script, so keep it inside this checkout. Installing the extension's npm dependencies is unnecessary. Generated Wasm files, build output, and test artifacts are ignored by Git.
