# Simply typed lambda calculus

The simply typed lambda calculus assigns types to variables, functions, and function applications. This example uses one base type $\iota$ and function types $A \to B$.

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

`S-Base` introduces $\iota$. `S-Arrow` says that any two types form a function type. The arrow associates to the right, so $A \to B \to C$ means $A \to (B \to C)$.

## Typing terms

Read $\Gamma \vdash e : A$ as “in context $\Gamma$, term $e$ has type $A$.” The context records the types of variables in scope.

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

For example, assume $x : \iota$. By `T-Var`, the body $x$ has type $\iota$. Then `T-Abs` discharges the assumption, giving the identity function its type in the empty context.

$$
\emptyset \vdash \lambda x : \iota.\,x : \iota \to \iota
$$

## Source notation

These declarations give the rule blocks their notation and LaTeX templates. The typing judgment is one mixfix pattern with holes for the context, term, and type. Application uses juxtaposition, as in `e₁ e₂`.

```{.inference-notation}
infixr:60 " → " => "\to"
infix:55  " : " => ":"
notation:53 x:atom ":" A:54 "∈" Γ:51 => x " : " A " \in " Γ
infix:53  " ∉ " => "\notin"
infixl:52 " , " => ","
notation:50 Γ:51 "⊢" e:51 ":" A:51 => Γ " \vdash " e " : " A
notation:56 "λ" x:atom ":" A:0 "." e:56 => "\lambda " x " : " A ".\," e
notation:10 A:11 "type" => A "\;\mathsf{type}"
```

The Markdown fences use the [Pandoc filter format](../docs/DESIGN.md#4-pandoc-json-filter). After `stack build`, render this tutorial from the repository root.

```sh
stack exec pandoc -- --from=markdown --to=latex --filter=inference example/stlc.md -o stlc.tex
```

To process the complete standalone document, use source mode. The result already loads `mathpartir` and is ready for a LaTeX engine. [LaTeX source](stlc.tex)

```sh
stack exec inference -- --source < example/stlc.tex > rules.tex
```
