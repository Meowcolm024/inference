import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { test } from "node:test";
import { parseAttributes, parseMarkdown, sourceOffset } from "../src/markdown";

test("extracts the complete STLC tutorial in document order", async () => {
  const document = parseMarkdown(
    await readFile(new URL("../../example/stlc.md", import.meta.url), "utf8"),
  );
  assert.equal(document.diagnostics.length, 0);
  assert.equal(
    document.items.filter((item) => item.kind === "block").length,
    4,
  );
  assert.ok(
    document.items.filter((item) => item.kind === "inline").length > 15,
  );
  assert.equal(document.items.at(-1)?.kind, "notation");
  const fragments = document.items
    .filter((item) => item.kind !== "notation")
    .map((item) => ({ key: item.key, html: "<b>compiled</b>" }));
  const html = document.render(fragments);
  assert.match(html, /<h1>Simply typed lambda calculus/);
  assert.match(html, /<b>compiled<\/b>/);
  assert.doesNotMatch(html, /import &quot;example/);
});

test("keeps duplicate pairs and quoted values for compiler validation", () => {
  const parsed = parseAttributes(
    '{#rules .inference kind=bnf rule_set="Types, terms" kind=expr}',
  );
  assert.ok("attr" in parsed);
  assert.deepEqual(parsed.attr, {
    id: "rules",
    classes: ["inference"],
    pairs: [
      ["kind", "bnf"],
      ["rule_set", "Types, terms"],
      ["kind", "expr"],
    ],
  });
});

test("handles both fence markers, bare names, raw fences, and longer example fences", () => {
  const document = parseMarkdown(
    [
      "~~~inference",
      "─",
      "x",
      "~~~",
      "",
      "```{.inference .inference-notation}",
      'infixr:60 "→"',
      "```",
      "",
      "```{=html}",
      "<script>alert(1)</script>",
      "```",
      "",
      "````markdown",
      "```{.inference}",
      "not a rule",
      "```",
      "````",
    ].join("\n"),
  );
  assert.deepEqual(
    document.items.map((item) => item.kind),
    ["block", "notation"],
  );
  assert.match(document.render([]), /&lt;script&gt;/);
  assert.doesNotMatch(document.render([]), /<script>/);
});

test("maps nested blockquotes and lists through CRLF and supplementary Unicode", () => {
  const input =
    "# Title\r\n\r\n> - ```{.inference}\r\n>   ─\r\n>   𝛤 @\r\n>   ```\r\n";
  const document = parseMarkdown(input);
  assert.equal(document.items.length, 1);
  assert.equal(document.items[0].source, "─\n𝛤 @\n");
  const source = document.sources.get(document.items[0].key)!;
  assert.equal(
    sourceOffset(source, { line: 2, column: 3 }),
    input.indexOf("@"),
  );
  assert.equal(
    sourceOffset(source, { line: 2, column: 4 }),
    input.indexOf("@") + 1,
  );
});

test("maps indented fences and a diagnostic at the end of a line", () => {
  const input = "  ```{.inference}\n    ─\n    x @\n  ```";
  const document = parseMarkdown(input);
  const source = document.sources.get(document.items[0].key)!;
  assert.equal(
    sourceOffset(source, { line: 2, column: 5 }),
    input.indexOf("@"),
  );
  assert.equal(
    sourceOffset(source, { line: 2, column: 6 }),
    input.indexOf("@") + 1,
  );
});

test("maps normalized inline code with backtick runs and stripped spaces", () => {
  const input =
    "> **Type `` 𝛤\n> @ ``{#type .inference}**, and `x`{.inference}.";
  const document = parseMarkdown(input);
  assert.deepEqual(
    document.items.map((item) => item.source),
    ["𝛤 @", "x"],
  );
  const first = document.sources.get(document.items[0].key)!;
  assert.equal(sourceOffset(first, { line: 1, column: 3 }), input.indexOf("@"));
  assert.equal(
    sourceOffset(first, { line: 1, column: 4 }),
    input.indexOf("@") + 1,
  );
  assert.match(
    document.render([{ key: document.items[0].key, html: "RESULT" }]),
    /id="type"/,
  );
});

test("repeated inline text and duplicate author IDs have independent occurrence keys", () => {
  const input = "`𝛤 @`{#same .inference} and `𝛤 @`{#same .inference}";
  const document = parseMarkdown(input);
  assert.notEqual(document.items[0].key, document.items[1].key);
  const second = document.sources.get(document.items[1].key)!;
  assert.equal(
    sourceOffset(second, { line: 1, column: 3 }),
    input.lastIndexOf("@"),
  );
});

test("does not extract inline examples in ordinary fenced or indented code", () => {
  const document = parseMarkdown(
    "```text\n`x`{.inference}\n```\n\n    `y`{.inference}\n\n`z` ordinary",
  );
  assert.equal(document.items.length, 0);
});

test("malformed inference attributes have source locations", () => {
  for (const input of [
    '```{.inference kind="bnf}\nx\n```',
    '`x`{.inference kind="bad}',
  ]) {
    const document = parseMarkdown(input);
    assert.equal(document.diagnostics.length, 1);
    assert.ok(document.diagnostics[0].end > document.diagnostics[0].start);
  }
});

test("raw Markdown HTML and injected IDs remain inert", () => {
  const document = parseMarkdown(
    '<script>alert(1)</script>\n\n`x`{#evil\"onclick .inference}',
  );
  const html = document.render(
    document.items.map((item) => ({ key: item.key, html: "x" })),
  );
  assert.doesNotMatch(html, /<script>|id="evil"onclick/);
  assert.match(html, /&lt;script&gt;/);
});

test("successive renders do not reuse fragments from an earlier render", () => {
  const document = parseMarkdown("`x`{.inference}");
  assert.match(
    document.render([{ key: document.items[0].key, html: "FIRST" }]),
    /FIRST/,
  );
  assert.doesNotMatch(document.render([]), /FIRST/);
});

test("table cells retain independent inline locations and escaped pipes", () => {
  const input =
    "| Left | Right |\n| --- | --- |\n| `𝛤 @`{.inference} | `𝛤 @`{.inference} |\n| `x \\| y`{.inference} | plain |";
  const document = parseMarkdown(input);
  assert.deepEqual(
    document.items.map((item) => item.source),
    ["𝛤 @", "𝛤 @", "x | y"],
  );
  const second = document.sources.get(document.items[1].key)!;
  assert.equal(
    sourceOffset(second, { line: 1, column: 3 }),
    input.lastIndexOf("@"),
  );
  const pipe = document.sources.get(document.items[2].key)!;
  assert.equal(
    sourceOffset(pipe, { line: 1, column: 3 }),
    input.indexOf("\\|") + 1,
  );
});
