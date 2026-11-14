# Implementation plan

The [design](DESIGN.md) documents the current syntax, architecture, and extension points.

## Implemented

| Area | Current behavior |
| --- | --- |
| Syntax and AST | Source-spanned inference rules, named BNF groups with continuation rows, guarded equations, and single-expression display blocks. Mixfix notation supports per-hole precedence, infix associativity, and left-associative application. |
| LaTeX source mode | The CLI reads UTF-8 from stdin with `--source`, rewrites the two recognized environments, and copies surrounding LaTeX verbatim. It emits notation declarations as comments and uses `rule_set` for figure captions. |
| Pandoc JSON filter | Default CLI mode. Recognizes attributed code blocks and inline code, using the shared parsers and document-wide notation. Supports `latex`, `html`, `html4`, and `html5`. Other targets pass through. |
| Renderers and templates | LaTeX uses mathpartir, display math, aligned layouts, and Unicode-to-LaTeX conversion. HTML uses escaped Unicode and inline CSS. Both fall back to notation pattern order and accept per-notation backend overrides. Inline `=>` is LaTeX shorthand. |
| Notation modules | Both adapters resolve transitive imports through `Inference.Modules`. The CLI resolves document imports from `--module-root` or the working directory and nested imports from the importing module. The loader deduplicates by canonical identity before reading and locates import and declaration diagnostics. The STLC examples share a module. |

## Current dependencies

The project uses Stack with the `lts-24.60` snapshot. Dependencies are declared in `package.yaml`.

| Scope | Packages |
| --- | --- |
| Library | text, containers, megaparsec, filepath, transformers |
| CLI | bytestring, containers, directory, filepath, optparse-applicative, pandoc-types, text, transformers |
| Test framework | tasty, tasty-hunit, tasty-quickcheck, tasty-golden |

## Current test coverage

| Suite | Coverage |
| --- | --- |
| `ParserTests` | Rule structure, line endings, precedence, application, nested delimiters, Unicode token boundaries, backend clause validation, and diagnostic spans. |
| `BlockTests` and `SourceTests` | BNF row preservation, equation guards and blank rows, display expressions, block options, literal LaTeX pass-through, and source diagnostics. |
| `LaTeXTests` | Golden fragments, Unicode and script mappings, escaping, and backend override selection. |
| `FilterTests` | Pandoc AST transformation, mixed block kinds, HTML layout, forward notation, inline attributes, and block-relative diagnostics. |
| `ModuleTests` | In-memory and filesystem resolution, transitive imports, one read per identity, imported templates, cycles, missing modules, and declaration locations. |

## Future work

1. **Separate compilation from host replacement.** Return parsed sections and inline expressions with occurrence keys and backend templates before rendering. Reuse the existing parsers and module loader. Test equivalent inputs through both readers and render a single parsed result through LaTeX and HTML. Use this API as the basis for explicit fragment export.
2. **Add a Unicode printer.** Preserve grouping and structured row breaks. Test parse/print equivalence after removing source metadata and check that a second print produces the same text.
3. **Extend LaTeX inline support.** Evaluate a braced inline command after the scanner can handle balanced arguments and skip comments and verbatim regions.
4. **Declare and check metavariables.** Define declaration syntax, scope, indexed families, and how schematic positions are identified. Add an opt-in pass over the shared AST that resolves metavariables and checks category constraints where available. Use STLC to test valid uses across premises and conclusions, indexed names, literal atoms, duplicate declarations, undeclared uses, and category mismatches with source spans.
5. **Prototype a language exporter.** Choose one of Agda, Haskell, or Lean and document its supported subset. Consume the checked representation from stage 4. Require explicit mappings for used notation and test missing mappings with application and declaration locations. Identify the remaining binding and naming metadata needed for declarations and judgments.
6. **Add end-to-end smoke tests.** Exercise the CLI with the external Pandoc executable for Markdown and Org. Compile a generated LaTeX fragment in a separate job with TeX and mathpartir. Keep the regular Haskell suite independent of TeX.
7. **Prototype a Wasm editor.** Cross-build the library with GHC's `wasm32-wasi` toolchain and test a small worker-callable wrapper in a browser. Add a Markdown editor with a debounced HTML preview and an in-memory notation resolver. Use the STLC example to check forward notation edits, imported modules, and diagnostics mapped to editor lines.

Use `ormolu` for Haskell formatting and run `stack build` and `stack test` for Haskell changes.
