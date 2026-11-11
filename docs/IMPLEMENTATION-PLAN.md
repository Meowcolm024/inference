# Implementation plan

The Haskell library and CLI read UTF-8 inference rules and write LaTeX fragments with `mathpar` groups. The [design](DESIGN.md) shows the notation and output. The CLI defaults to Pandoc JSON filter mode for Markdown and Org documents.

## Stages

1. **Specify the rule format.** Document separator recognition, optional labels, zero or more premises, one conclusion, blank lines, and the initial expression subset. Define source-span coordinates and the diagnostic kinds for malformed input. Keep the first fixture set small enough to exercise all of these decisions.
2. **Build a standalone slice.** Parse rule structure with Megaparsec and render rules with simple atoms. Preserve input spans for diagnostics. Wire the library into the `inference` executable with stdin input, LaTeX on stdout, and diagnostics on stderr with a failing exit status.
3. **Add mixfix expressions and application.** Validate declarations, lower the infix shorthands to the same pattern representation, and tokenize rule expressions using the declared literals. Use a Pratt parser with patterns that start at a literal and patterns that extend a left operand. Add a built-in application rule that consumes atom or parenthesized arguments at higher precedence than declared notation. Give application its own AST node and preserve notation identities and arguments on declared forms. Use the [STLC example](../example/stlc.tex) as the v0 end-to-end fixture for mixfix abstraction and typing judgments, postfix classifiers, and application.
4. **Move standalone source mode to LaTeX environments.** Scan for `inference` and `inference-notation`, preserving the text between them verbatim. Collect declarations across the document, then parse and render each rule set through the existing compiler. Use `rule_set` from the opening delimiter as the optional figure caption. Preserve notation bodies as LaTeX comments. Use the `.tex` examples as end-to-end fixtures for this syntax.
5. **Add the Pandoc JSON filter.** Make filter mode the default for `inference` and use `--source` for LaTeX input on stdin. Use `toJSONFilter` from `pandoc-types` for JSON I/O and handle Pandoc's target-format argument. For `latex`, collect `inference-notation` blocks in a first pass. In a second pass, replace declaration blocks in place with LaTeX comments and render each `inference` block with its optional `rule_set` caption. Preserve surrounding content and metadata. Pass other targets through. Send diagnostics to stderr with a block identifier or ordinal and a block-relative span. Use an external `pandoc` executable for Markdown and Org end-to-end tests. [Pandoc JSON filter protocol](https://pandoc.org/filters.html)
6. **Add BNF and equation block kinds.** Dispatch body parsing and rendering using `kind` in source options or Pandoc attributes. Model BNF as named syntax groups separated by blank lines, preserving production rows and continuation indentation. Treat every dash-label prefix longer than two dashes equally. Align equation rows and render optional guards with their `--` markers removed. Reject dash labels and dividers in equation blocks.
7. **Extend output when examples require it.** Add a Unicode printer before promising round trips. Consider imports, HTML, and structured AST export separately so each can evolve against the same expression AST.

## Proposed libraries

Use the existing Stack `lts-24.60` snapshot and add dependencies to `package.yaml` as each stage needs them. The proposed packages are available in the [LTS 24.60 snapshot](https://www.stackage.org/lts-24.60).

| Scope | Packages | Use |
| --- | --- | --- |
| Compiler | `text`, `containers`, `megaparsec` | Unicode input and output, notation lookup tables, source parsing and offsets |
| CLI | `bytestring`, `optparse-applicative` | Explicit UTF-8 decoding at the I/O boundary, command-line arguments and help |
| Tests | `tasty`, `tasty-hunit`, `tasty-quickcheck`, `tasty-golden` | Test runner, structural assertions, generated properties, and LaTeX golden files |
| CLI filter mode | `pandoc-types` | Pandoc AST types, traversal, and JSON filter I/O |

## Test strategy

| Layer | Coverage |
| --- | --- |
| Rule syntax fixtures | Cover axioms, multiple premises, named and unnamed rules, separator lengths, line endings, and Unicode identifiers. |
| Source environments | Cover titled and untitled blocks, empty bodies, forward notation declarations, and diagnostics for nested, mismatched, or unclosed environments. Check that surrounding LaTeX is copied verbatim, declarations become comments, and an omitted `kind` selects one `mathpar` group with an escaped caption when present. |
| Block kinds and layout | Check named BNF groups separated by blank lines, category lists, alternatives, and continuation rows, including that `∀ X . A` stays on its indented second row. Check that `--- Types` and `--------------- Types` name equivalent groups and that `Contexts` starts a separate group after a blank line. Check equation alignment, guarded and unguarded rows, and removal of `--` from displayed guards. Assert diagnostics for missing BNF group names or productions, labels without separating blank lines, orphan continuations, equation dash labels, unknown kinds, missing equation sides, and empty guards. |
| Diagnostics | Assert diagnostic kind and primary span for missing conclusions, malformed separators, missing mixfix delimiters, ambiguous patterns, and invalid template references. Include a multibyte character before an error to check the coordinate convention. |
| Expression tokens | Check that `term` is a declared keyword and `terminal` is an atom, `λ x` starts with a keyword while `λx` is one atom, `∅` is an atom, and declared `<=` wins over `<`. |
| Expression parsing | Assert tree shape for prefix and postfix patterns, infix associativity, and nested mixfix delimiters. Check that `Γ ⊢ λ x : A . e : A → B` has a lambda in the judgment's term hole and an arrow in its type hole. Check that `x : A` parses as a binding and `x : A → B ∈ Γ, y : C` parses as a lookup with an arrow type and an extended context. Check that `f x y` groups left, `f(x)` matches `f (x)`, and postfix `term` in `e₁ e₂ term` classifies the whole application. |
| Rendering and CLI | Compare complete `mathpar` fragments for axioms and multiple premises. Cover escaping in labels, correct grouping, and subscripts. Test `--source` with a complete LaTeX document and a fragment. Check UTF-8 decoding failures and output streams on parse failure. Generate golden output through the test runner and review each diff individually. |
| Properties | Generate valid inputs to check rule structure and separator-length invariance. Once the Unicode printer exists, test parse/print equivalence ignoring source metadata and formatting idempotence. |
| Pandoc JSON filter | Test JSON input and output, malformed JSON, incompatible AST versions, and pass-through for other targets. Use `pandoc --filter` to check Markdown and Org `kind` selection, `rule_set` captions, and forward notation declarations. Check that every declaration line appears in place as a LaTeX comment and the following content renders. Check that rule errors produce a nonzero exit, block-relative diagnostics on stderr, and no JSON on stdout. |

Use `ormolu` for Haskell formatting and run `stack build` and `stack test` before finishing a stage. Add a failing fixture before fixing a bug. Once the LaTeX backend is usable, add a smoke test that wraps a generated fragment in a minimal document and compiles it in a job with TeX and `mathpartir` installed. Keep the regular Haskell suite independent of TeX.
