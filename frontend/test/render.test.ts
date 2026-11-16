import assert from "node:assert/strict";
import { test } from "node:test";
import { renderPreview, type Compile } from "../src/preview/render";

const unexpectedCompile: Compile = async () => {
  throw new Error("Ordinary Markdown must not load Wasm.");
};

test("Markdown and KaTeX render without loading the inference compiler", async () => {
  const result = await renderPreview(
    {
      revision: 1,
      source: "# Mathematics\n\n$x^2$ and \\(y\\).\n\n$$\n\\frac{1}{2}\n$$",
      modules: [],
    },
    unexpectedCompile,
  );
  assert.equal(result.status, "ok");
  if (result.status !== "ok") return;
  assert.match(result.html, /<h1>Mathematics<\/h1>/);
  assert.equal((result.html.match(/class="katex"/g) ?? []).length, 3);
  assert.match(result.html, /class="katex-display"/);
});

test("math delimiters stay literal inside code and HTML stays inert", async () => {
  const result = await renderPreview(
    {
      revision: 2,
      source:
        "`$x$`\n\n```text\n$$y$$\n```\n\n<script>alert(1)</script>\n\n$\\href{javascript:alert(1)}{x}$",
      modules: [],
    },
    unexpectedCompile,
  );
  assert.equal(result.status, "ok");
  if (result.status !== "ok") return;
  assert.match(result.html, /<code>\$x\$<\/code>/);
  assert.match(result.html, /\$\$y\$\$/);
  assert.match(result.html, /&lt;script&gt;/);
  assert.doesNotMatch(result.html, /<script|href="javascript:/);
});

test("inference and KaTeX share the Markdown tree and templates are disabled", async () => {
  const source =
    '$x$ and `A → B`{.inference}\n\n```inference-notation\nimport "types.notation"\n```';
  const modules = [{ path: "types.notation", source: 'infixr:60 "→"' }];
  const latex = String.raw`A \to B`;
  const result = await renderPreview(
    { revision: 3, source, modules },
    async (request) => {
      assert.equal(request.ignoreHtmlTemplates, true);
      assert.equal(request.includeLatex, true);
      assert.deepEqual(request.modules, modules);
      assert.deepEqual(
        request.items.map((item) => item.kind),
        ["inline", "notation"],
      );
      return {
        revision: request.revision,
        status: "ok",
        fragments: [
          { key: request.items[0].key, html: "<span>A → B</span>", latex },
        ],
      };
    },
  );
  assert.equal(result.status, "ok");
  if (result.status !== "ok") return;
  assert.match(result.html, /class="katex"/);
  assert.match(result.html, /<span>A → B<\/span>/);
  assert.match(result.html, /data-copy-latex="item-0"/);
  assert.equal(result.latexByKey.get("item-0"), latex);
  assert.equal(result.html.includes(latex), false);
  assert.doesNotMatch(result.html, /import &quot;/);
});

test("compiler Unicode locations map through quoted fences to source selections", async () => {
  const source = "> ```inference\n> ─\n> 𝛤 @\n> ```";
  const result = await renderPreview(
    { revision: 4, source, modules: [] },
    async (request) => ({
      revision: request.revision,
      status: "invalid",
      diagnostics: [
        {
          code: "parse",
          message: "Unexpected @",
          related: [],
          location: {
            source: { item: request.items[0].key },
            start: { line: 2, column: 3 },
            end: { line: 2, column: 4 },
          },
        },
      ],
    }),
  );
  assert.equal(result.status, "invalid");
  if (result.status !== "invalid") return;
  assert.deepEqual(result.issues[0], {
    message: "Unexpected @",
    start: source.indexOf("@"),
    end: source.indexOf("@") + 1,
    line: 3,
    column: 5,
    module: undefined,
  });
});

test("malformed inference attributes do not reach the compiler", async () => {
  const result = await renderPreview(
    {
      revision: 5,
      source: '```{.inference rule_set="unclosed}\n─\nx\n```',
      modules: [],
    },
    unexpectedCompile,
  );
  assert.equal(result.status, "invalid");
  if (result.status === "invalid")
    assert.match(result.issues[0].message, /Unclosed/);
});
