export const example = `# A small type system

Simply typed lambda calculus with function types.

## Typing rules

The judgment \`Γ ⊢ e : A\`{.inference} says that term
\`e\`{.inference} has type \`A\`{.inference} in context
\`Γ\`{.inference}.

\`\`\`{.inference rule_set="Function application"}
Γ ⊢ e₁ : A → B
Γ ⊢ e₂ : A
──────────────────── T-App
Γ ⊢ e₁ e₂ : B
\`\`\`

## Mathematics

Euler’s identity: $e^{i\\pi}+1=0$.

The sum of the first *n* positive integers is

$$
\\sum_{k=1}^{n} k = \\frac{n(n+1)}{2}
$$

## Syntax

\`\`\`{.inference kind=bnf}
--- Types
A,B ::= ι | A → B

--- Terms
e ::= x | e₁ e₂ | λ x : A . e
\`\`\`

\`\`\`inference-notation
infixr:60 "→"
notation:50 Γ:51 "⊢" e:51 ":" A:51
notation:56 "λ" x:atom ":" A:0 "." e:56
\`\`\`
`;
