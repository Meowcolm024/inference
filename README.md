# inference

`inference` is a Haskell library and CLI for typesetting Unicode inference rules, BNF productions, and equations inside LaTeX documents. The parser produces a source-spanned AST and supports user-defined mixfix notation, infix associativity, per-hole precedence, and left-associative application by juxtaposition. Identifiers can include subscripts and superscripts such as `Γᵢ` and `eⁿ⁺¹`.

## Input

Formation, typing, and reduction rules share the same format. Write one premise per line, a separator made of `─` characters with an optional label, and one conclusion. An axiom starts with the separator. Separate rule blocks with a blank line.

Put rule sets in `inference` environments and declarations in `inference-notation` environments. Each delimiter takes its own line. Set `rule_set` on an opening delimiter to put the rules in a captioned figure. Untitled rule sets render as bare `mathpar` groups. Notation declarations apply throughout the file.

```text
\begin{inference-notation}
infixr:60 "→"
notation:50 Γ:51 "⊢" e:51 ":" A:51
\end{inference-notation}

\begin{inference}[rule_set=Typing]
Γ ⊢ e₁ : A → B
Γ ⊢ e₂ : A
──────────────────── T-App
Γ ⊢ e₁ e₂ : B
\end{inference}
```

Set `kind=bnf` or `kind=equation` on an `inference` environment to select another body grammar. Omit `kind` for inference rules. Options are separated by commas. Brace a caption containing a comma, as in `rule_set={Types, terms}`.

```text
\begin{inference-notation}
infix:53 "="
\end{inference-notation}

\begin{inference}[kind=bnf,rule_set=Syntax]
--- Terms
e,f ::= x | e₁ e₂
      | f (e x)
\end{inference}

\begin{inference}[kind=equation,rule_set=Equations]
f x = y -- if x = y

x = x
\end{inference}
```

In BNF, `::=` and `|` are grammar keywords. Start each group with a name after three or more dashes, and separate groups with a blank line. Rows beginning with `|` continue the preceding production. The renderer preserves row breaks, omits the leading bar, and aligns the alternatives in the same column regardless of source indentation.

In equations, the first outer `=` is a grammar keyword. Both sides use the shared notation table. A whitespace-separated `--` introduces a guard, and an initial `if` is rendered upright. Guard conditions use ordinary notation, so the equality declaration above is needed for `x = y` inside the guard. Blank source rows remain separated in the output. Parentheses and mixfix delimiters protect separators inside expressions.

## Run the CLI

By default, `inference` runs as a Pandoc JSON filter. Use Pandoc Markdown or Org as input and `latex`, `html`, `html4`, or `html5` as output.

```sh
stack build
stack exec pandoc -- --from=markdown --to=latex --filter=inference example/stlc.md -o notes.tex
stack exec pandoc -- --from=markdown --to=html5 --standalone --mathml --filter=inference example/stlc.md -o notes.html
```

For Org documents, use `--from=org` with `#+BEGIN_SRC inference` blocks. Both formats support a `rule_set` caption, a `kind` attribute, and separate `inference-notation` blocks. Select BNF with `{.inference kind=bnf}` in Markdown or `#+BEGIN_SRC inference :kind bnf` in Org. Use `equation` for equation blocks. Notation applies throughout the document, including to earlier blocks. Other output formats pass through unchanged. The [filter design](docs/DESIGN.md#4-pandoc-json-filter) shows both block syntaxes.

Use `--source` to rewrite inference environments in a LaTeX fragment or document.

```sh
stack exec inference -- --source < example/stlc.tex > stlc-processed.tex
pdflatex stlc-processed.tex
```

In source mode, the CLI reads UTF-8 from stdin and writes LaTeX to stdout. It preserves surrounding LaTeX and turns declaration lines into comments. Both modes report errors on stderr and exit with a nonzero status. Run `stack exec inference -- --help` for usage.

Each `.tex` example is a complete LaTeX document that loads `mathpartir`. You can pass the processed output directly to a LaTeX engine. When using source mode on a fragment, load `mathpartir` in the document that includes it.

```latex
\documentclass{article}
\usepackage{mathpartir}
\begin{document}
\input{fragment.tex}
\end{document}
```

Notation declarations can omit `=>`. LaTeX then renders literals and hole arguments in pattern order, translating common Greek letters, math symbols, and scripts in both atoms and notation literals. Other Unicode characters pass through and require support from the document's TeX engine and fonts. Use an explicit template such as `infixr:60 "→" => "\Rightarrow"` to override the default rendering.

The LaTeX mappings include directional arrows such as `↖` and `⇓`, PLFA reduction arrows such as `—→` and `—↠`, and symbols such as `ƛ`, `⊎`, and `⦂`. Blackboard-bold letters such as `ℕ`, `𝔹`, and `𝕒` render with `\mathbb`. Unicode primes can follow an identifier, as in `e′` and `e″`. [PLFA’s symbol inventory](https://plfa.inf.ed.ac.uk/Fonts/)

Declare operators and delimiters through notation as usual. For example, `notation:30 "⟦" e:0 "⟧"` renders `⟦ e ⟧` as double brackets.

Load `amssymb` for extended arrows and uppercase `\mathbb`, and `stmaryrd` for double brackets and symbols such as `⨟`. Lowercase `\mathbb` needs a font that provides lowercase glyphs, such as `bbold`. [AMS symbols](https://mirrors.ctan.org/fonts/amsfonts/doc/amssymb.pdf) · [St Mary’s Road symbols](https://tug.ctan.org/fonts/stmaryrd/stmaryrd.pdf) · [Blackboard-bold font](https://tug.ctan.org/fonts/bbold/bbold.pdf)

A notation can also have indented backend overrides immediately below its declaration. Use each backend name once per notation. An inline `=>` counts as a LaTeX override. Infix override clauses refer to the operands as `lhs` and `rhs`.

```text
infixr:60 "→"
  latex => lhs "\Rightarrow " rhs
  html => lhs " <span>→</span> " rhs
```

LaTeX and HTML each use their own override when present and otherwise render the pattern. HTML inference blocks use Unicode expressions and inline CSS. HTML template fragments are inserted as raw markup, so use them with trusted source documents. The `--mathml` option above controls ordinary Pandoc math.

## Use the library

`Inference.LaTeX.compileSource` rewrites a LaTeX `Text` input directly. Use `Inference.Parser.parseSource` to inspect its parsed chunks. Rules, BNF productions, and equations share a backend-independent expression AST that retains Unicode text, notation IDs, and arguments.

Use `parseSourceWithLatexTemplates` with `renderSourceLatex` to keep parsing and rendering separate. When parsing individual blocks, use `parseNotationBlockWithLatexTemplates` to obtain the syntax declarations and LaTeX templates, then pass the declarations to `parseBlockSection` and the templates to `renderLatex` alongside the assembled `Document`. Supply `mempty` for the templates to use pattern-based rendering throughout. Use `parseSourceWithTemplates` or `parseNotationBlockWithTemplates` to obtain overrides for all declared backends, and `Inference.Templates.templatesFor` to select one backend.

From the repository root, run `stack repl inference:lib` and enter these commands.

```haskell
import qualified Data.Text.IO as Text
import Inference.LaTeX (compileSource)
import Inference.Parser (formatDiagnostic)
source <- Text.readFile "example/stlc.tex"
either (Text.putStr . formatDiagnostic source) Text.putStr (compileSource source)
```

On invalid input, `formatDiagnostic` explains the error and highlights its location. For an ambiguous expression, it also highlights the competing declarations.

## Tests

Run `stack test` for parser, source rewriting, block layout, Pandoc filter, and LaTeX golden tests. `test/Spec.hs` is the entry point and assembles the separate test modules.

## Examples

- Untyped lambda calculus with BNF syntax, guarded substitution equations, and full β-reduction rules. [LaTeX source](example/untyped-lambda.tex)
- Simply typed lambda calculus. [Markdown tutorial](example/stlc.md) · [LaTeX source](example/stlc.tex)
- Explicit System F with products. [LaTeX source](example/system-f.tex)

## Roadmap

Planned work includes a Unicode printer and further output backends.

See the [design](docs/DESIGN.md) for the input grammar and the [implementation plan](docs/IMPLEMENTATION-PLAN.md) for the remaining stages.
