# Unicode Inference for VS Code

Preview Unicode inference rules, BNF grammars, equations, and inline expressions while editing Markdown. The extension bundles the project's Haskell compiler as WebAssembly; using the extension needs no Haskell, Pandoc, Nix, or server.

## Use

Use desktop VS Code 1.103 or newer. Install the `.vsix` with **Extensions: Install from VSIX…**. Open a Markdown document, then run **Unicode Inference: Open Live Preview** from the Command Palette or click the preview icon in the editor title bar.

The preview opens beside the source and updates after a 150 ms typing pause. It stays attached to that document while you edit its imported notation files. Run the command on another Markdown document to switch the preview.

- Rules, BNF, equations, and display expressions use the same notation as the CLI.
- Attributed inline code, such as `` `A → B`{.inference} ``, renders in the surrounding prose.
- Later notation declarations apply to earlier expressions.
- Imported modules update from unsaved editor buffers and filesystem changes, including creation of a missing module.
- Errors appear in **Problems** and as clickable messages above the preview. Invalid edits retain the last successful rendering.
- Double-click a rendered rule or expression to reveal its source line.
- **Unicode Inference: Insert Rule Bar** inserts a Unicode separator. Markdown snippets start with `inference-rule`, `inference-notation`, and `inference-expr`.

Try `example/stlc.md` with the repository root open as the workspace.

## Settings

| Setting                  | Default | Meaning                                                                                                                                                   |
| ------------------------ | ------- | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `inference.previewDelay` | `150`   | Typing debounce in milliseconds, from 0 to 2000.                                                                                                          |
| `inference.moduleRoot`   | `""`    | Import root relative to the Markdown document's workspace folder. Empty uses that folder; without a workspace, imports use the Markdown file's directory. |

Imports inside a module resolve relative to that module. As in the Wasm API, paths must stay within the selected module root. Each preview compiles one document's complete notation scope.

## Supported Markdown

The preview uses Markdown-it's CommonMark syntax with tables and strikethrough, plus Pandoc-style inference attributes:

````markdown
```{.inference rule_set="Application"}
Γ ⊢ e₁ : A → B
Γ ⊢ e₂ : A
──────────────────── T-App
Γ ⊢ e₁ e₂ : B
```

The type `A → B`{.inference} associates to the right.

```inference-notation
infixr:60 "→"
notation:50 Γ:51 "⊢" e:51 ":" A:51
```
````

Both backtick and tilde fences work, including fences inside lists and blockquotes. Bare `inference` and `inference-notation` fence names work too. Attribute lists support IDs, classes, and ordered `key=value` pairs with quoted values. Rule kinds and options are validated by Haskell. Inline backtick runs and normalized whitespace follow Markdown-it; diagnostic locations account for container prefixes, CRLF, and Unicode code points.

The supported subset omits Org, LaTeX documents, Pandoc citations, dollar-delimited math, and general-purpose attributed Markdown elements. Raw `{=format}` fences stay code. Raw Markdown HTML is escaped, and HTML notation overrides are ignored through `ignoreHtmlTemplates: true`. External images and navigation are disabled; local anchor links work.

The Wasm reactor needs JavaScript Promise Integration. Desktop VS Code 1.103 introduced [Electron 37 and Chromium 138](https://code.visualstudio.com/updates/v1_103), which includes the [JSPI API](https://v8.dev/blog/jspi). Remote workspaces also need a server runtime with this feature; older servers show an upgrade message. A browser-only extension host is not included. This version was tested with desktop VS Code 1.119 and Node 24.21.

## Build and debug

Use Node 24.21 or newer. From this directory:

```sh
npm ci
cd .. && stack build && cd vscode-extension
npm run build:wasm
npm run build
npm run check
npm test
npm run test:wasm
npm run package
```

`build:wasm` uses the repository's Nix flake unless `wasm32-wasi-ghc` is already on `PATH`. It updates the cross compiler's Hackage index, builds the existing `wasm/` target, and generates matching JavaScript bindings. The first build downloads the toolchain and dependencies. `artifacts/` and `dist/` are generated and ignored by Git. Rebuild Wasm after changing Haskell code; TypeScript changes only need `npm run build`. Packaging fails if the Wasm artifacts are missing.

Open this directory in VS Code and press **F5** to start the Extension Development Host. The launch configuration opens the repository as its workspace. Open `example/stlc.md` there and run the preview command.

Additional checks:

```sh
npm run format:check
npm run test:extension
CHROMIUM_EXECUTABLE_PATH=/path/to/chrome npm run test:webview
```

The extension-host test uses an isolated temporary workspace and profile. It downloads a test VS Code by default; set `VSCODE_EXECUTABLE_PATH` to an existing **application executable** to reuse an installation. Do not point it at the `bin/code` CLI launcher. On NixOS the application is typically under the VS Code store path at `lib/vscode/code`. The webview test uses an installed Chromium/Chrome and writes `artifacts/preview.png`.

## Implementation

`src/markdown.ts` extracts inference items and maps their Unicode coordinates back to editor offsets. `src/modules.ts` loads only the transitive import graph. `src/compiler.ts` keeps one running and one latest queued request in a worker thread, where `src/runtime.ts` initializes GHC's Wasm reactor and its WASI shim. The preview checks revisions again before publishing results, so stale work cannot overwrite a newer edit.

`src/extension.ts` manages the panel, file watchers, unsaved buffers, and VS Code diagnostics. The webview uses a restrictive content security policy and the editor's theme colors. Runtime assets are bundled into the VSIX; no network access is needed for compilation.

See the [VS Code webview API](https://code.visualstudio.com/api/extension-guides/webview) and [extension testing guide](https://code.visualstudio.com/api/working-with-extensions/testing-extension) for the host integration conventions.
