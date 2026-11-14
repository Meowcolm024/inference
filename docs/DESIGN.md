# A Unicode Inference-Rule Typesetter

A Haskell library and command-line tool for typesetting Unicode inference rules, BNF productions, and equations. The notation design draws on Lean 4. The primary inputs are LaTeX environments and attributed code blocks and inline code spans in Pandoc JSON documents.

Conceptually, it sits somewhere between Ott, Lean's notation parser, and a lightweight document preprocessor, without attempting to understand the semantics of the mathematical language.

The [implementation plan](IMPLEMENTATION-PLAN.md) records the implemented features, current test coverage, and remaining work.

Sections 1–5 describe implemented behavior. Section 6 describes planned extensions.

## 1. Example input

The source format uses `inference-notation` for declarations and `inference` for rule sets. Source mode rewrites these environments before the document is passed to LaTeX.

```
\begin{inference-notation}
infixr:60 " → " => "\to"
notation:50 Γ:51 "⊢" e:51 ":" A:51 => Γ " \vdash " e " : " A
infix:55  " : " => ":"
infixl:52 " , " => ","
notation:56 "λ" x:atom ":" A:0 "." e:56 => "\lambda " x " : " A ".\," e
notation:10 e:11 "term" => e "\;\mathsf{term}"
\end{inference-notation}

\begin{inference}[rule_set=Syntax]
──────────────────── S-Var
x term
\end{inference}

\begin{inference}[rule_set=Typing]
Γ, x : A ⊢ e : B
──────────────────── T-Abs
Γ ⊢ λ x : A . e : A → B

Γ ⊢ e₁ : A → B
Γ ⊢ e₂ : A
──────────────────── T-App
Γ ⊢ e₁ e₂ : B
\end{inference}
```

Illustrative LaTeX output using the `mathpartir` package. [Mathpartir documentation](https://ctan.org/pkg/mathpartir)

```
% infixr:60 " → " => "\to"
% notation:50 Γ:51 "⊢" e:51 ":" A:51 => Γ " \vdash " e " : " A
% infix:55  " : " => ":"
% infixl:52 " , " => ","
% notation:56 "λ" x:atom ":" A:0 "." e:56 => "\lambda " x " : " A ".\," e
% notation:10 e:11 "term" => e "\;\mathsf{term}"

\begin{figure}
\begin{mathpar}
\inferrule*[right=S-Var]{ }{x\;\mathsf{term}}
\end{mathpar}
\caption{Syntax}
\end{figure}

\begin{figure}
\begin{mathpar}
\inferrule*[right=T-Abs]
  {\Gamma, x : A \vdash e : B}
  {\Gamma \vdash \lambda x : A.\,e : A \to B}

\inferrule*[right=T-App]
  {\Gamma \vdash e_1 : A \to B \\
   \Gamma \vdash e_2 : A}
  {\Gamma \vdash e_1\,e_2 : B}
\end{mathpar}
\caption{Typing}
\end{figure}
```

The [simply typed lambda calculus example](../example/stlc.tex) shows a complete LaTeX source document. The `S-*` rules use the postfix operators `type`, `term`, and `ctx` to classify expressions. The `T-*` rules use the mixfix judgment `Γ ⊢ e : A`, which captures the context, term, and type as separate holes. The variable rule uses the mixfix lookup `x : A ∈ Γ`. It shares `:` with the binding notation `x : A` and requires the `∈` delimiter to complete the lookup pattern. In the example, `x` ranges over variable names, `Γ` is a well-formed context in typing rules, and `dom Γ` denotes the set of names bound in it.

The [explicit System F example](../example/system-f.tex) adds universal types, type abstraction `Λ X . e`, type application `e [ A ]`, and products with pairs and projections. `Δ` lists type variables and `Γ` lists term bindings. In the type application rule, `B [ A / X ]` denotes capture-avoiding substitution of `A` for `X` in `B`. [System F lecture notes](https://mathstat.dal.ca/~selinger/papers/lambdanotes.pdf)

The [untyped lambda calculus example](../example/untyped-lambda.tex) presents syntax as BNF, capture-avoiding substitution as guarded equations, and full β-reduction as inference rules. It uses `→` for one step and `↠` for zero or more steps. Terms are considered up to α-equivalence. In the substitution equations, `FV e` is the set of free variables of `e`, and the postfix guard `z fresh` requires a name absent from the terms and binders involved. [Lambda calculus lecture notes](https://mathstat.dal.ca/~selinger/papers/lambdanotes.pdf)

## 2. Core design decisions

| Component      | Design                                       |
| -------------- | -------------------------------------------- |
| Input          | LaTeX environments and Pandoc JSON code blocks with shared Unicode bodies |
| Rule structure | One premise per line                         |
| Rule separator | Unicode horizontal line `────`               |
| Rule names     | Written after the separator                  |
| Rule sets      | `inference` environments with optional `rule_set` captions |
| Block kinds    | Inference rules by default, with `kind=bnf`, `kind=equation`, and `kind=expr` / `kind=expr` |
| Expressions    | Extensible notation parser                   |
| Notation       | Lean 4-inspired precedence and associativity |
| Output         | LaTeX and HTML |
| Integration    | Pandoc JSON filter with native block and inline code attributes |
| Implementation | Haskell library and standalone CLI via Stack |

The length of the horizontal separator has no semantic significance.

A rule occupies a block of consecutive nonblank lines. Write zero or more premises, a separator, and exactly one conclusion. A rule without premises is an axiom. The separator starts with one or more `─` characters and may carry a label after whitespace. The parser trims surrounding whitespace on each line and preserves the label's internal spacing. A whitespace-only line separates a rule from the next block. The parser accepts LF, CRLF, and a last line without a line ending.

The renderer uses `{ }` as the premise argument for an axiom so `mathpartir` draws the rule bar.

Inside `inference-notation`, write one `notation:`, `infix:`, `infixl:`, or `infixr:` declaration per line, optionally followed by indented backend template clauses. Whitespace before the colon is allowed. The parser collects and validates all declarations before parsing rule expressions, so a rule can use notation declared later in the document.

Source spans use one-based line and column coordinates with an exclusive end. Columns count Unicode code points, including tabs. Diagnostics report the offending token or a point at the end of the relevant line, along with both declaration spans when a notation use is ambiguous.

Syntax can be presented as formation rules or as BNF productions. The block kind selects the body parser and renderer. All kinds share the document-wide notation table for their mathematical expressions.

### Source environments

Use `\begin{inference}[rule_set=Title]` and `\end{inference}` for a captioned block. The optional `kind` selects BNF, equations, or a display expression. Omitting `kind` selects the existing inference-rule format. Commas separate options outside balanced braces, as in `[kind=bnf,rule_set=Syntax]`. A `rule_set` value is nonempty plain text with surrounding whitespace trimmed. Use braces for a value containing a comma, such as `rule_set={Types, terms}`. Report unknown kinds, unknown options, and duplicate options at their source spans.

Use `\begin{inference-notation}` and `\end{inference-notation}` for declarations. Put each delimiter on its own line. The compiler reads the bodies literally, applying the selected body grammar rather than expanding TeX macros. Report diagnostics for nested source environments, mismatched closing delimiters, and missing closing delimiters.

Render each nonempty inference-rule block as one `mathpar` group. BNF and equation blocks use the layouts below. Wrap any titled block in `figure` and put the escaped `rule_set` text in `\caption{…}` below its content. Empty blocks produce no output. Replace each `inference-notation` environment in place with its body as LaTeX comments, prefixing each line with `% ` and ending the replacement with a newline. Source mode copies surrounding LaTeX verbatim, including blank lines and line endings, so its input can be a fragment or a complete document.

### Reserved dash lines

Reserve a line that starts, after indentation, with three or more consecutive ASCII `-` characters followed by whitespace or the end of the line. In BNF, this prefix introduces the name of the syntax group below it. The dash count has no semantic meaning once it exceeds two. For example, `--- Types` and `--------------- Types` name the same syntax group.

Interpret these lines through the BNF group grammar below. Equation blocks reject dash labels and dividers at the marker's source span. The prefix stays reserved in other body grammars.

Equation guards use exactly two dashes, `--`, followed by whitespace. The guard delimiter cannot consume the prefix of a longer dash run. Inference-rule bars continue to use Unicode `─`.

### BNF blocks

```text
\begin{inference}[kind=bnf,rule_set=Syntax]
--------------- Types
A,B ::= ι | A → B | X
                        | ∀ X . A

--------------- Contexts
Γ ::= ∅ | Γ, x : A
\end{inference}
```

Each BNF group starts with a dash label and contains one or more productions. The text after the dashes names the syntax described by those productions. In the example, `Types` names the first group and `Contexts` names the second. Render each escaped name with its own productions, retaining the group order.

A blank or whitespace-only line ends a group. The next nonblank line starts a new group with its own dash label. The closing environment also ends the current group. Report an empty name, a name without productions, or a new group label without a preceding blank line as an error.

A production starts with one or more comma-separated category names, then `::=`, then alternatives separated by `|`. A line whose first nonwhitespace character is `|` continues the preceding production within the same group. Report a continuation without a preceding production as an error.

The tokens `::=` and `|` are keywords of the BNF grammar at the outer level and need no notation declarations. Recognize them before parsing the alternatives as notation expressions. Delimiters consumed inside parentheses or a nested mixfix form belong to that expression. Category names are displayed metavariables. The typesetter records the productions for rendering.

Keep each group's name, production rows, and alternatives in the AST. Each source production row yields one output row, so `∀ X . A` stays on the second row. The backend chooses horizontal spacing and alignment independently of source indentation and spaces. The LaTeX backend omits the leading `|` on continuation rows and keeps separators between alternatives on the same row. Blank lines delimit named groups.

### Equation blocks

```text
\begin{inference}[kind=equation,rule_set=Substitution]
x [e/y] = e -- if x = y
x [e/y] = x
\end{inference}
```

Each nonblank source line supplies one equation row. The first outer `=` is an equation keyword and needs no notation declaration. Split there into a left and a right expression. A whitespace-separated `--` at the outer level starts an optional guard. Parse both sides with the shared notation table. For a guard beginning with `if`, render that word upright and parse the remaining condition as an expression. The guard condition can contain its own equality notation.

Render rows in source order with aligned equality signs and a separate guard column. The first example row displays `x [e/y] = e` followed by `if x = y`. The `--` marker supplies layout metadata and is omitted from the LaTeX output. The second row has an empty guard column. Preserve explicit row breaks and blank-row separation. Rows are independent displayed equations with optional conditions.

The BNF and equation examples use the corresponding arrow, quantifier, substitution, and equality notations declared in `inference-notation`. Report an empty side or an empty guard at the relevant source span.

### Display expression blocks

Use `kind=expr` to display one Unicode expression with the shared notation table and backend templates.

```text
\begin{inference}[kind=expr]
∅ ⊢ λ x : ι . x : ι → ι
\end{inference}
```

In Pandoc Markdown, put the expression inside a fence with `{.inference kind=expr}`. The body has at most one nonblank line. A second nonblank line is an error, and an empty body produces no output. The expression grammar handles every token, including any declared equality notation. LaTeX emits display math and HTML emits a centered block with the rendered Unicode expression. The usual optional `rule_set` caption applies.

## 3. Notation system

V0 supports Lean 4-style mixfix declarations. A pattern contains quoted literal tokens and named expression holes, each with a minimum precedence. The declaration's own precedence determines where the resulting expression can appear. An optional `=>` clause supplies an inline LaTeX template made of quoted fragments and references to the holes. [Lean 4 notation reference](https://lean-lang.org/doc/reference/latest/Notations-and-Macros/Notations/)

```
infixr:60 " → "
notation:20 "if" c:0 "then" t:0 "else" f:20 => "\mathbf{if}\;" c "\;\mathbf{then}\;" t "\;\mathbf{else}\;" f
```

Patterns begin with a literal or with a single left-hand hole followed by a literal. V0 requires a literal between consecutive holes. A delimiter such as `then` ends the preceding hole at the current nesting level. In `Γ ⊢ λ x : A . e : A → B`, the lambda pattern consumes the first `:` and the judgment consumes the second. `infix`, `infixl`, and `infixr` are shorthand for mixfix patterns with operand precedences derived from associativity. A pattern consisting of one hole followed by one literal defines a postfix operator. Reject ambiguous parses and report the competing declarations.

Precedences are nonnegative decimal integers. A hole specifies either a minimum precedence or `atom`. Hole names must be unique within a pattern. When supplied, the mixfix template after `=>` contains one or more quoted fragments or references to holes in that pattern. An infix declaration takes one quoted operator and may supply a quoted LaTeX fragment after `=>` to render between its operands. At precedence `p`, the left and right operand minimums are respectively `p, p+1` for `infixl`, `p+1, p` for `infixr`, and `p+1, p+1` for nonassociative `infix`. In quoted text, `\"` and `\\` escape a quote and a backslash. Other backslashes are preserved, including the ones in LaTeX commands.

### Rendering notation

Attach an override to a notation with an indented clause of the form `backend => template`. Each clause occupies one line immediately below the declaration. Templates contain quoted backend fragments and references to the notation's holes.

```text
notation:50 Γ:51 "⊢" e:51 ":" A:51
  latex => Γ " \vdash " e " : " A
  html => Γ " <span>⊢</span> " e " : " A
```

For backend clauses on infix declarations, use `lhs` and `rhs` for the two operands. The legacy inline `=>` still supplies a LaTeX template, with its existing operator-only shorthand for infix declarations. Allow at most one template per backend per notation. Report duplicate clauses, including a `latex =>` clause alongside an inline template, and unknown hole references at their source spans.

LaTeX and HTML fall back to rendering literals and recursively rendered arguments in pattern order. LaTeX translates Unicode characters in atoms and literals through its character-keyed map, for example `→` to `\to` and `ι` to `\iota`. HTML emits escaped Unicode text. Explicit HTML template fragments are inserted as raw markup and are intended for trusted source. Each backend handles grouping and spacing. An explicit template replaces that backend's fallback for the notation.

The same clauses work in local declarations and imported modules.

### Notation tokens and atoms

Collect the notation declarations before tokenizing rule expressions. After trimming surrounding whitespace, each quoted pattern literal must be either one identifier or a contiguous sequence of symbol or punctuation characters. Parentheses are reserved for grouping.

- Read a complete identifier before checking the notation table. Identifiers start with a Unicode letter or `_`. They can continue with letters, combining marks, decimal digits, `_`, common subscript and superscript digits, signs, and parentheses, and Unicode primes. This includes Agda-style names such as `Γᵢ`, `eⁿ⁺¹`, and `x⁽ᵅ⁻¹⁾`. An exact match with a declared word literal is a keyword. Any other identifier is an atom. For example, declaring `term` reserves `term` while `terminal` remains an atom. Write `λ x` with a space because `λx` is one identifier. [Agda Unicode input](https://agda.readthedocs.io/en/stable/tools/emacs-mode.html#unicode-input)
- At a symbol or punctuation character, take the longest declared symbolic literal that matches. For example, `<=` wins over `<` when both are declared. If no literal matches, a single character in the Unicode Math Symbol category (`Sm`), such as `∅`, is an atom. Report a lexical error for characters that match none of these rules.

Notation tokens enter expressions through their declared patterns. They are excluded from the atom positions used by application.

### Standalone notation modules

A plain UTF-8 module file contains the same declarations as an `inference-notation` block, without environment delimiters. A module can also import other notation modules. For example, an `inference-notation` block in LaTeX, Markdown, or Org can consist of just this directive.

```text
import "stlc.notation"
```

Write one import per line, with a nonempty quoted relative path. A module file contains UTF-8 notation declarations, backend template clauses, imports, and blank lines. The `.notation` extension is conventional. Resolve document imports relative to the process working directory or the directory supplied with `--module-root`. LaTeX stdin and Pandoc JSON do not provide the document path to the filter. Resolve transitive imports relative to the importing module's directory.

All imported and local declarations share the document-wide notation scope. Load each canonical file once per document, including when several modules import it. Import order grants no precedence. Apply the same validation and ambiguity rules to imported and local patterns and report both declaration locations when relevant. Missing modules and import cycles produce diagnostics at the import directives, with the import chain for context. Imported declarations may carry backend templates under the same rules as local declarations.

### Application

Juxtaposition is a built-in expression form with its own AST node. It binds more tightly than any declared notation and associates to the left. The function can be an atom, a parenthesized expression, or an earlier application. Each argument is an atom or a parenthesized expression. A hole annotated `atom` accepts the same forms as an argument. Grouping parentheses restart parsing at precedence `0`. The LaTeX renderer separates the function and argument with a thin space.

| Input | Grouping |
| --- | --- |
| `f x y` | `(f x) y` |
| `f (g x)` | `f` applied to the whole `g x` |
| `f x → g y` | `(f x) → (g y)` |
| `f (λ x : A . x)` | `f` applied to the whole abstraction |
| `e₁ e₂ term` | `(e₁ e₂) term`, with `term` declared postfix |

Application uses token boundaries, so `f(x)` and `f (x)` have the same grouping, while `fx` is one identifier. A literal awaited by an enclosing notation, such as `then` in `if f x then …`, ends the hole before the parser tries to read another argument.

## 4. Pandoc JSON filter

Pandoc reads and writes the document and runs `inference` between those steps using `--filter`. The CLI defaults to filter mode. It reads a JSON document AST from stdin, takes the target format from its first argument, and writes the resulting AST as JSON to stdout. Use `--source` for standalone LaTeX rewriting. The Pandoc filter reads attributed code blocks and inline code spans. The CLI uses `Text.Pandoc.JSON.toJSONFilter` from `pandoc-types` for the filter protocol. [Pandoc JSON filter protocol](https://pandoc.org/filters.html) · [`Text.Pandoc.JSON` source](https://github.com/jgm/pandoc-types/blob/1.23.1.2/src/Text/Pandoc/JSON.hs)

With `inference` on `PATH`, select the Markdown or Org reader explicitly.

```sh
pandoc notes.md --from=markdown --to=latex --filter=inference --output=notes.tex
pandoc notes.org --from=org --to=latex --filter=inference --output=notes.tex
```

For standalone LaTeX, add `--standalone --include-in-header=mathpartir.tex`, with `\usepackage{mathpartir}` in that header file.

Each Pandoc code block with class `inference` supplies one block. The optional `rule_set` attribute supplies its figure caption, and `kind` selects the same body grammar as in source mode. For example, Markdown uses `{.inference kind=bnf rule_set="Syntax"}` and Org uses `#+BEGIN_SRC inference :kind bnf :rule_set "Syntax"`. Use `kind=equation` or `:kind equation` for equations, and `kind=expr` or `:kind expr` for display expressions. The fence boundaries delimit the body. [Pandoc Markdown reader](https://github.com/jgm/pandoc/blob/3.7.0.2/src/Text/Pandoc/Readers/Markdown.hs#L637-L668)

````
```{.inference rule_set="Typing rules"}
Γ ⊢ e₁ : A → B
Γ ⊢ e₂ : A
──────────────────── T-App
Γ ⊢ e₁ e₂ : B
```
````

In Org, use an `inference` source block with a `:rule_set` argument. The Org reader exposes the language as the block class and the argument as an attribute. For a quoted value, use the text inside the quotes as the caption. [Org source block syntax](https://orgmode.org/manual/Structure-of-Code-Blocks.html)

```org
#+BEGIN_SRC inference :rule_set "Typing rules"
Γ ⊢ e₁ : A → B
Γ ⊢ e₂ : A
──────────────────── T-App
Γ ⊢ e₁ e₂ : B
#+END_SRC
```

Notation declarations can live in separate blocks marked `inference-notation`.

````
```{.inference-notation}
infixr:60 " → " => "\to"
notation:50 Γ:51 "⊢" e:51 ":" A:51 => Γ " \vdash " e " : " A
```
````

In Org, the corresponding notation block opens with `#+BEGIN_SRC inference-notation` and closes with `#+END_SRC`. For the `latex` target, the filter first collects document-wide notation from `inference-notation` blocks. In the second pass, it replaces each declaration block in place with a `RawBlock` tagged `latex`, prefixing every source line with `% ` and ending the block with a newline. The declarations remain visible in the generated `.tex` source as comments.

The second pass also replaces each `inference` block with a `RawBlock` tagged `latex`, dispatching to the body parser and renderer selected by `kind`. Each nonempty inference-rule block produces a separate `mathpar` group even when two blocks share a title. Other blocks and document metadata stay in the AST. Markdown and Org are the supported readers. Pandoc's JSON filter protocol supplies the target format and AST without identifying the reader.

For `html`, `html4`, and `html5`, the filter uses the same two passes and inserts HTML fragments with inline styles. Inference rules use Unicode expressions and CSS for the rule bar and premise layout. BNF and equations use tables. The filter hides declaration blocks and preserves IDs on rendered inference blocks. An explicit `html` template supplies raw markup for its notation.

Pass the document AST through unchanged for other targets or when the target argument is absent. On invalid JSON, an incompatible AST version, or a rule compilation error, report the failure on stderr and exit with a nonzero status. For rule diagnostics, include the block identifier or ordinal and the block-relative source span.

### Inline expressions

In Pandoc Markdown, write an inline code span with the `.inference` class. The reader exposes this syntax through its `inline_code_attributes` extension. [Pandoc inline code attributes](https://pandoc.org/MANUAL.html#extension-inline_code_attributes)

```markdown
The type `A → B`{.inference} has domain `A`{.inference}.
```

The filter recognizes Pandoc `Code` nodes with the `inference` class. Each contains one Unicode expression and uses the document-wide notation declarations and backend templates, including declarations later in the document. Inline code has no declaration or block grammar. Rule bars, BNF productions, equation rows, and notation declarations belong in their respective blocks. Operators such as `=` follow the shared expression grammar and carry no equation layout meaning.

For LaTeX, replace the code with an inline math node containing the rendered expression. For HTML targets, insert the escaped Unicode expression and any explicit HTML template markup inline. Preserve the identifier, other classes, and key-value attributes in a surrounding span when present. Leave ordinary inline code and unsupported targets unchanged. Diagnostics identify the inline code by identifier or ordinal, highlight the expression-relative span, and include the original locations of competing notation declarations.

## 5. Reader, AST, and backend architecture

The two input adapters share a notation loader, body and expression parsers, and a backend-independent syntax AST. Each adapter preserves its host document and assembles the rendered replacements.

```text
LaTeX environments ─┐
                    ├→ Notation scope + shared parsers → Sections and expressions
Pandoc JSON nodes ──┘                                     ├→ LaTeX
                                                          └→ HTML
```

| Layer | Current implementation |
| --- | --- |
| LaTeX input | The environment scanner extracts notation and inference bodies. The source parser builds a `SourceDocument` with ordered chunks for literal LaTeX, original notation text, and parsed sections. `renderSourceLatex` copies literal chunks and replaces the marked environments. |
| Pandoc input | `app/Inference/Pandoc.hs` walks attributed code blocks and inline code nodes. `Inference.Blocks` parses block bodies and calls the selected renderer per section. The adapter also parses inline expressions with the same notation scope. It inserts the resulting Pandoc nodes while preserving the surrounding document and metadata. |
| Notation scope | `Inference.Modules.loadNotationScope` resolves the import graph before content parsing and returns declarations, templates, and a function that maps declaration diagnostics to their original locations. A `NotationResolver` returns a stable identity and a separate read action, allowing the loader to detect cycles and repeated imports before reading. The CLI supplies a filesystem resolver with canonical paths. Tests can supply an in-memory resolver. |
| Syntax | `Document` holds notation definitions and sections. Each section has an optional caption and a typed body for inference rules, BNF, equations, or a display expression. The bodies share a source-spanned `Expr` for Unicode atoms, grouping, application, and notation applications with IDs and arguments. |
| Templates | `BackendTemplates` stores templates separately from the AST, keyed by backend and notation ID. The compiler normalizes inline `=>` to a LaTeX template. Renderers select their entries with `templatesFor`. |

The LaTeX backend emits `mathpar` groups, array layouts for BNF and equations, and display math for expression blocks. The HTML backend emits escaped Unicode expressions and uses inline CSS for layout, with tables for BNF and equations. Both backends handle captions and apply their own notation overrides.

LaTeX diagnostics use document coordinates. Pandoc diagnostics use the block or inline identifier or ordinal with coordinates relative to its body. Competing declarations can point to a different block or an imported file.

## 6. Future extensions

A future compilation API can return the ordered, parsed inference content and backend templates before rendering. Associate each item with a document-local occurrence key so host adapters can reinsert results even when user-supplied IDs repeat. This would let callers render the same parsed content to multiple backends and provide a basis for an explicit fragment export.

A Unicode printer can preserve expression grouping and the row boundaries of BNF and equations. LaTeX source could also gain an inline `\inference{…}` form once the scanner handles balanced braces, comments, and verbatim regions.

### Metavariable declarations and checking

Add an opt-in semantic pass after parsing and before language export. Let authors declare metavariable families and their syntactic categories. In STLC, for example, `A` and `B` range over types, `e` over terms, `x` over variable names, and `Γ` over contexts. Define how declarations cover indexed forms such as `e₁` and `e₂` as part of the declaration syntax.

Resolve schematic occurrences to their declarations across rule premises and conclusions, BNF productions, and equations and guards. Report duplicate declarations and undeclared metavariables in positions identified as schematic. Check category compatibility where a production or a declared notation hole gives an expected category. Report mismatches at the use site with the relevant declaration location. Specify how authors distinguish metavariables from literal atoms and set declaration scope before enforcing those checks. Existing typesetting can continue to use the parsed AST. Exporters can consume the checked representation with resolved metavariable identities and categories.

### Language export

Treat Agda, Haskell, and Lean as separate exporters. Start with one exporter and a documented subset. Require an explicit backend template for each notation application the exporter emits. For a missing mapping, report the use site and the declaration location. Build on the checked metavariables and add the binding, constructor, and target-language naming information needed to generate declarations and judgments.

### Browser editor and live preview

A browser Markdown adapter would extract attributed inference fences and inline code with their source positions. A Web Worker would call a small GHC Wasm wrapper around the shared compiler and HTML renderer. The wrapper would accept ordered inference items and an in-memory module map, then return HTML fragments and structured diagnostics keyed by occurrence. The browser would render the surrounding Markdown and map diagnostic spans back to editor lines.

Debounce edits and compile the inference items together so changes to notation update earlier uses. Discard results from superseded edits. Sanitize preview HTML before inserting it into the DOM, including markup from explicit HTML templates.

## 7. Guiding principles

The project should remain:

- Notation-oriented by default. Semantic checks use declarations supplied by the author.
- Lightweight. No need to declare a complete object-language grammar merely to typeset a few rules.
- Extensible. Notation is user-defined, not hardcoded into the parser.
- Document-friendly. Rules should look natural when written in plain text and integrate smoothly with Pandoc.
- Backend-independent. The internal AST should leave room for future proof-assistant integration.

The initial goal is not to build another Ott. It is to build a pleasant little mathematical notation compiler that might, rather accidentally, grow into a useful tool for formalizing programming-language metatheory.
