# inference

`inference` typesets Unicode inference rules, BNF grammars, equations, and mathematical expressions. It supports user-defined mixfix notation and reusable notation modules. The Haskell CLI rewrites LaTeX source or filters Pandoc Markdown and Org for LaTeX and HTML output. The same compiler powers live Markdown previews in the browser and VS Code.

## Installation

Install Stack and Nix, then clone the repository and run `stack build` from its root. The default Stack configuration uses Nix to supply Pandoc. Use `stack exec inference -- --help` to see the CLI options.

## Quick start

Render the simply typed lambda calculus example to HTML with Pandoc.

```sh
stack exec pandoc -- -f markdown+inline_code_attributes -t html5 -s --mathml \
  --filter=inference example/stlc.md -o stlc.html
```

To process a LaTeX document with `inference` environments, use source mode. The resulting file can be compiled with a TeX installation that includes `mathpartir`.

```sh
stack exec inference -- --source < example/stlc.tex > stlc-processed.tex
```

For rule syntax, BNF, equations, notation imports, and backend templates, follow the [tutorial](docs/TUTORIAL.md).

## Live preview

- **Browser.** With Node.js and npm, run `npm ci` and `npm run dev` from `frontend/`. The setup guide covers supported runtimes and Wasm build requirements. [Browser setup](frontend/README.md)
- **VS Code.** Install the VSIX, open `example/stlc.md` with the repository root as the workspace, and run **Unicode Inference: Open Live Preview**. [Extension setup and packaging](vscode-extension/README.md)

## Project resources

- Examples for [STLC](example/stlc.md), [System F with products](example/system-f.tex), and [untyped lambda calculus](example/untyped-lambda.tex).
- [Design](docs/DESIGN.md), [implementation plan and roadmap](docs/IMPLEMENTATION-PLAN.md), and [Wasm compiler API](docs/WASM.md).
- Run `stack test` for the Haskell suite. [Wasm smoke test](docs/WASM.md#build-and-smoke-test) · [Browser tests](frontend/README.md#build-and-check) · [Extension tests](vscode-extension/README.md#build-and-debug)
