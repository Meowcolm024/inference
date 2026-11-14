# Simply typed lambda calculus

The simply typed lambda calculus assigns types to variables, functions, and function applications. This example uses one base type `ι`{.inference} and function types `A → B`{.inference}.

## Syntax

```{.inference kind=bnf rule_set="STLC syntax"}
--- Types
A, B ::= ι | A → B

--- Terms
e ::= x | λ x : A . e | e₁ e₂

--- Contexts
Γ ::= ∅ | Γ, x : A
```

Here `x`{.inference} ranges over variable names, and `e₁`{.inference} and `e₂`{.inference} range over terms. A context is empty or extends an existing context with a variable binding. The typing rules below specify when that extension is valid.

## Reading a rule

Each line above the bar is a premise. The line below is the conclusion, and the name to the right of the bar labels the rule. A rule with no premises is an axiom.

```{.inference rule_set="Type formation"}
──────────────────────────── S-Base
ι type

A type
B type
──────────────────────────── S-Arrow
A → B type
```

`S-Base` introduces `ι`{.inference}. `S-Arrow` says that any two types form a function type. The arrow associates to the right, so `A → B → C`{.inference} means `A → (B → C)`{.inference}.

## Typing terms

Read `Γ ⊢ e : A`{.inference} as “in context `Γ`{.inference}, term `e`{.inference} has type `A`{.inference}.” The context records the types of variables in scope.

```{.inference rule_set="Typing rules"}
x : A ∈ Γ
──────────────────────────── T-Var
Γ ⊢ x : A

x ∉ dom Γ
Γ, x : A ⊢ e : B
──────────────────────────── T-Abs
Γ ⊢ λ x : A . e : A → B

Γ ⊢ e₁ : A → B
Γ ⊢ e₂ : A
──────────────────────────── T-App
Γ ⊢ e₁ e₂ : B
```

`T-Var` looks up a variable in the context. `T-Abs` checks the body with a fresh parameter added to the context. `T-App` checks that the argument has the function's input type, then gives the application the function's output type.

For example, assume `x : ι`{.inference}. By `T-Var`, the body `x`{.inference} has type `ι`{.inference}. Then `T-Abs` discharges the assumption, giving the identity function its type in the empty context.

$$
\emptyset \vdash \lambda x : \iota.\,x : \iota \to \iota
$$

## Source notation

The grammar, rules, and inline expressions share the declarations and templates in [stlc.notation](stlc.notation). The import is relative to the repository root when running the command below. The typing judgment is one mixfix pattern with holes for the context, term, and type. Application uses juxtaposition, as in `e₁ e₂`{.inference}.

```{.inference-notation}
import "example/stlc.notation"
```

The Markdown fences and inline expressions use the [Pandoc filter format](../docs/DESIGN.md#4-pandoc-json-filter). After `stack build`, render this tutorial from the repository root.

```sh
stack exec pandoc -- --from=markdown+inline_code_attributes --to=latex --filter=inference example/stlc.md -o stlc.tex
```

To process the complete standalone document, use source mode. The result already loads `mathpartir` and is ready for a LaTeX engine. [LaTeX source](stlc.tex)

```sh
stack exec inference -- --source < example/stlc.tex > rules.tex
```
