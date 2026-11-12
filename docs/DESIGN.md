# A Unicode Inference-Rule Typesetter

A Haskell library and command-line tool for typesetting Unicode inference rules, BNF productions, and equations. The notation design draws on Lean 4. The primary inputs are LaTeX environments and attributed code blocks and inline code spans in Pandoc JSON documents.

Conceptually, it sits somewhere between Ott, Lean's notation parser, and a lightweight document preprocessor, without attempting to understand the semantics of the mathematical language.

The [implementation plan](IMPLEMENTATION-PLAN.md) sequences the work for the parser, renderer, CLI, and optional Pandoc integration.

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
| Block kinds    | Inference rules by default, or `kind=bnf` / `kind=equation` |
| Expressions    | Extensible notation parser                   |
| Notation       | Lean 4-inspired precedence and associativity |
| Output         | LaTeX today, with an HTML backend proposed |
| Integration    | Pandoc JSON filter with native block and inline code attributes |
| Implementation | Haskell library and standalone CLI via Stack |

The length of the horizontal separator has no semantic significance.

A rule occupies a block of consecutive nonblank lines. Write zero or more premises, a separator, and exactly one conclusion. A rule without premises is an axiom. The separator starts with one or more `─` characters and may carry a label after whitespace. The parser trims surrounding whitespace on each line and preserves the label's internal spacing. A whitespace-only line separates a rule from the next block. The parser accepts LF, CRLF, and a last line without a line ending.

The renderer uses `{ }` as the premise argument for an axiom so `mathpartir` draws the rule bar.

Inside `inference-notation`, write one `notation:`, `infix:`, `infixl:`, or `infixr:` declaration per line, optionally followed by indented backend template clauses. Whitespace before the colon is allowed. The parser collects and validates all declarations before parsing rule expressions, so a rule can use notation declared later in the document.

Source spans use one-based line and column coordinates with an exclusive end. Columns count Unicode code points, including tabs. Diagnostics report the offending token or a point at the end of the relevant line, along with both declaration spans when a notation use is ambiguous.

Syntax can be presented as formation rules or as BNF productions. The block kind selects the body parser and renderer. All kinds share the document-wide notation table for their mathematical expressions.

### Source environments

Use `\begin{inference}[rule_set=Title]` and `\end{inference}` for a captioned block. The optional `kind` selects BNF or equation syntax. Omitting `kind` selects the existing inference-rule format. Commas separate options outside balanced braces, as in `[kind=bnf,rule_set=Syntax]`. A `rule_set` value is nonempty plain text with surrounding whitespace trimmed. Use braces for a value containing a comma, such as `rule_set={Types, terms}`. Report unknown kinds, unknown options, and duplicate options at their source spans.

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
  html => Γ "<mo>⊢</mo>" e "<mo>:</mo>" A
  lean => "HasType " Γ " " e " " A
```

For backend clauses on infix declarations, use `lhs` and `rhs` for the two operands. The legacy inline `=>` still supplies a LaTeX template, with its existing operator-only shorthand for infix declarations. Allow at most one template per backend per notation. Report duplicate clauses, including a `latex =>` clause alongside an inline template, and unknown hole references at their source spans.

LaTeX and HTML fall back to rendering literals and recursively rendered arguments in pattern order. LaTeX translates Unicode characters in atoms and literals through its character-keyed map, for example `→` to `\to` and `ι` to `\iota`. HTML uses Unicode in escaped MathML tokens. Each backend handles grouping and spacing. An explicit template replaces that backend's fallback for the notation.

Other backends require an explicit template for each notation application they render. Report a missing mapping at the use site and include the notation's declaration location. Unused declarations may omit those mappings. The same clauses work in local declarations and imported modules.

### Notation tokens and atoms

Collect the notation declarations before tokenizing rule expressions. After trimming surrounding whitespace, each quoted pattern literal must be either one identifier or a contiguous sequence of symbol or punctuation characters. Parentheses are reserved for grouping.

- Read a complete identifier before checking the notation table. Identifiers start with a Unicode letter or `_`. They can continue with letters, combining marks, decimal digits, `_`, common subscript and superscript digits, signs, and parentheses, and Unicode primes. This includes Agda-style names such as `Γᵢ`, `eⁿ⁺¹`, and `x⁽ᵅ⁻¹⁾`. An exact match with a declared word literal is a keyword. Any other identifier is an atom. For example, declaring `term` reserves `term` while `terminal` remains an atom. Write `λ x` with a space because `λx` is one identifier. [Agda Unicode input](https://agda.readthedocs.io/en/stable/tools/emacs-mode.html#unicode-input)
- At a symbol or punctuation character, take the longest declared symbolic literal that matches. For example, `<=` wins over `<` when both are declared. If no literal matches, a single character in the Unicode Math Symbol category (`Sm`), such as `∅`, is an atom. Report a lexical error for characters that match none of these rules.

Notation tokens enter expressions through their declared patterns. They are excluded from the atom positions used by application.

### Standalone notation modules

Allow a plain UTF-8 file to contain the same declarations as an `inference-notation` block, without environment delimiters. A module can also import other notation modules. For example, an `inference-notation` block in LaTeX, Markdown, or Org could contain the following directive.

```text
import "notation/stlc.notation"
```

The directive and file extension are proposed syntax. Resolve document imports relative to a configurable project directory, defaulting to the process working directory. This gives LaTeX stdin and Pandoc JSON the same behavior, since either input may arrive without a source filename. Resolve imports inside a module relative to that module's directory.

All imported and local declarations share the document-wide notation scope. Load each resolved file once per document, including when several modules import it. Import order grants no precedence. Apply the same validation and ambiguity rules to imported and local patterns and report both declaration locations when relevant. Missing modules and import cycles produce diagnostics at the import directives, with the import chain for context. Imported declarations may carry backend templates under the same rules as local declarations.

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

Pandoc reads and writes the document and runs `inference` between those steps using `--filter`. The CLI defaults to filter mode. It reads a JSON document AST from stdin, takes the target format from its first argument, and writes the resulting AST as JSON to stdout. The source syntax rework applies to `--source`. The Pandoc filter reads attributed code blocks and inline code spans. The CLI uses `Text.Pandoc.JSON.toJSONFilter` from `pandoc-types` for the filter protocol. [Pandoc JSON filter protocol](https://pandoc.org/filters.html) · [`Text.Pandoc.JSON` source](https://github.com/jgm/pandoc-types/blob/1.23.1.2/src/Text/Pandoc/JSON.hs)

With `inference` on `PATH`, select the Markdown or Org reader explicitly.

```sh
pandoc notes.md --from=markdown --to=latex --filter=inference --output=notes.tex
pandoc notes.org --from=org --to=latex --filter=inference --output=notes.tex
```

For standalone LaTeX, add `--standalone --include-in-header=mathpartir.tex`, with `\usepackage{mathpartir}` in that header file.

Each Pandoc code block with class `inference` supplies one block. The optional `rule_set` attribute supplies its figure caption, and `kind` selects the same body grammar as in source mode. For example, Markdown uses `{.inference kind=bnf rule_set="Syntax"}` and Org uses `#+BEGIN_SRC inference :kind bnf :rule_set "Syntax"`. Use `kind=equation` or `:kind equation` for equations. The fence boundaries delimit the body. [Pandoc Markdown reader](https://github.com/jgm/pandoc/blob/3.7.0.2/src/Text/Pandoc/Readers/Markdown.hs#L637-L668)

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

For `html`, `html4`, and `html5`, the filter uses the same two passes and inserts HTML fragments with inline styles. Inference rules use Unicode expressions and CSS for the rule bar and premise layout. BNF and equations use tables. The filter hides declaration blocks and preserves IDs on rendered rule blocks. An explicit `html` template supplies raw markup for its notation.

Pass the document AST through unchanged for other targets or when the target argument is absent. On invalid JSON, an incompatible AST version, or a rule compilation error, report the failure on stderr and exit with a nonzero status. For rule diagnostics, include the block identifier or ordinal and the block-relative source span.

### Inline expressions

In Pandoc Markdown, write an inline code span with the `.inference` class. The reader exposes this syntax through its `inline_code_attributes` extension. [Pandoc inline code attributes](https://pandoc.org/MANUAL.html#extension-inline_code_attributes)

```markdown
The type `A → B`{.inference} has domain `A`{.inference}.
```

The filter recognizes Pandoc `Code` nodes with the `inference` class. Each contains one Unicode expression and uses the document-wide notation declarations and backend templates, including declarations later in the document. Inline code has no declaration or block grammar. Rule bars, BNF productions, equation rows, and notation declarations belong in their respective blocks. Operators such as `=` follow the shared expression grammar and carry no equation layout meaning.

For LaTeX, replace the code with an inline math node containing the rendered expression. For HTML targets, insert the escaped Unicode expression and any explicit HTML template markup inline. Preserve the identifier, other classes, and key-value attributes in a surrounding span when present. Leave ordinary inline code and unsupported targets unchanged. Diagnostics identify the inline code by identifier or ordinal, highlight the expression-relative span, and include the original locations of competing notation declarations.

A possible counterpart in LaTeX source mode is `\inference{expression}`, using the same expression parser and document-wide notation. Supporting it requires recognizing a braced macro argument in surrounding LaTeX, including balanced braces and escaped characters, and skipping comments and verbatim content. The environment scanner remains the entry point for LaTeX source mode.

## 5. Reader, AST, and backend architecture

Follow Pandoc's reader → AST → writer model at the level of the marked blocks. Pandoc or LaTeX owns the surrounding document. The inference compiler owns notation and the contents of the blocks it recognizes.

```text
LaTeX environment reader ─┐
                          ├→ Source blocks → Compiler → Inference document
Pandoc JSON block reader ─┘                              ├→ LaTeX renderer
                                                         ├→ HTML renderer
                                                         └→ Language exporters (future)
```

### Readers and document assembly

Each reader extracts the same ordered sequence of source blocks. A block carries a document-local key, its origin, and either a notation declaration body or a content body with attributes. The LaTeX reader recognizes the two environments and retains the intervening text for reinsertion. The Pandoc reader recognizes the two code block classes and keeps the enclosing Pandoc AST and metadata. Both hand raw body text and attributes to the same compiler. The existing `Inference.Blocks` input types are a starting point for this contract.

Use a key per occurrence to connect parsed sections, diagnostics, and rendered replacements to their source blocks. User-supplied identifiers can appear in diagnostics even if they are empty or repeated. A LaTeX origin maps body-relative spans back to file coordinates. A Pandoc origin records the identifier when present and the block ordinal, with spans relative to the code body. Related locations can point into a different block.

Keep assembly in the host adapter. The LaTeX adapter reinserts LaTeX fragments and declaration comments into the original text. The Pandoc adapter inserts the backend's fragments as appropriately tagged Pandoc blocks and returns the transformed AST to Pandoc. Preserve the current behavior of passing unsupported Pandoc targets through unchanged. An explicit fragment export can render the same inference document from either input without carrying its host prose across formats.

### Compiler and shared AST

The pure compiler first parses and validates all notation declarations available to the document, then parses content blocks in order with the resulting notation table. This allows forward references in both inputs. A shared module loader resolves imports for either reader and supplies the compiler with loaded sources and their origins. Keep filesystem I/O in the loader so compilation can also run against in-memory module sources. Return the compiled document and separate backend configuration. The current `compileBlocks` combines parsing with renderer callbacks. Replace that dependency with a compilation result that can be rendered more than once.

The inference document holds the notation definitions and ordered, keyed sections. Each section has an optional caption and a typed body for inference rules, BNF, or equations. The bodies share the expression AST for Unicode atoms, grouping, application, and notation applications identified by their notation and arguments. Retain source spans, BNF row boundaries, and equation guards. Delimiter locations, original declaration text for comments, and host document structure belong to the source layer.

Store templates in backend configuration keyed by backend and notation identity. Normalize the optional inline `=>` clause to the LaTeX entry for compatibility. Separate declarations keyed by a notation name could populate the same configuration in the future. The syntax AST and notation resolution are shared across targets.

### Backends

| Backend | Output and responsibilities |
| --- | --- |
| LaTeX | Emit `mathpar` rule groups, BNF and equation layouts, and figure captions. Render Unicode atoms and notation literals with a character-keyed mapping, applying explicit LaTeX templates where supplied. |
| HTML | Emit HTML fragments with MathML for expressions and rule structure, and use HTML for grouping and captions. Escape text and attributes, preserve BNF rows, and render notation in pattern order using its Unicode literals. Apply explicit HTML templates where supplied. |
| Agda, Haskell, Lean | Treat each as a separate exporter. A first exporter can handle an explicitly supported subset with declared mappings. Generating declarations, constructors, or judgments requires additional information about categories, binding, and names. Validate those requirements in an export step and report unsupported constructs with source spans. |

Let renderers consume the compiled document and their own configuration. For host replacement, render fragments keyed by section. Language exporters can inspect the whole document to emit imports or declarations once and order them by dependencies. Keep the entry points as ordinary Haskell functions until multiple backends demonstrate a need for a common interface.

## 6. Possible future extensions

Phase 1 — Standalone typesetter

Unicode rules, basic expression support, and LaTeX generation through a Haskell library and CLI.

Phase 2 — Pandoc integration

JSON filter using `pandoc-types` and Pandoc's command-line filter protocol.

Phase 3 — Shared compilation and HTML

Compile BNF, equations, and inference rules through the same pipeline for both readers. Add HTML and MathML rendering and add per-notation backend overrides.

Phase 4 — Structured metatheory

Metavariable declarations, syntactic categories, and constructor mappings. Export structured ASTs to Lean, Agda, or Haskell.

Phase 5 — Formalization support (optional)

Generate inductive judgments, inference-rule constructors, or proof scaffolding, approaching some of Ott's capabilities.

## 7. Guiding principles

The project should remain:

- Notation-oriented rather than semantics-oriented. It knows how to parse and render mathematical expressions, not what they mean.
- Lightweight. No need to declare a complete object-language grammar merely to typeset a few rules.
- Extensible. Notation is user-defined, not hardcoded into the parser.
- Document-friendly. Rules should look natural when written in plain text and integrate smoothly with Pandoc.
- Backend-independent. The internal AST should leave room for future proof-assistant integration.

The initial goal is not to build another Ott. It is to build a pleasant little mathematical notation compiler that might, rather accidentally, grow into a useful tool for formalizing programming-language metatheory.

Metavariable structure can be revisited if the project evolves into a more general metalanguage.
