import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { test } from "node:test";
import { createCompiler } from "../src/runtime";
import { Compiler } from "../src/compiler";
import { parseMarkdown, sourceOffset } from "../src/markdown";
import { loadModules } from "../src/modules";
import type { PreviewRequest } from "../src/protocol";

const compile = await createCompiler(
  fileURLToPath(new URL("../artifacts", import.meta.url)),
);
const request = (source: string, revision = 1): PreviewRequest => ({
  revision,
  ignoreHtmlTemplates: true,
  items: parseMarkdown(source).items,
  modules: [],
});

test("real Wasm renders the STLC tutorial with its imported module", async () => {
  const source = await readFile(
    new URL("../../example/stlc.md", import.meta.url),
    "utf8",
  );
  const document = parseMarkdown(source);
  const loaded = await loadModules(document.items, async (path) =>
    readFile(new URL(`../../${path}`, import.meta.url), "utf8"),
  );
  const result = await compile({
    revision: 7,
    ignoreHtmlTemplates: true,
    items: document.items,
    modules: loaded.modules,
  });
  assert.equal(result.status, "ok", JSON.stringify(result));
  if (result.status !== "ok") return;
  assert.equal(
    result.fragments.length,
    document.items.filter((item) => item.kind !== "notation").length,
  );
  const html = document.render(result.fragments);
  assert.match(html, /border-top:1px/);
  assert.match(html, /<table/);
  assert.match(html, /T-App/);
});

test("later notation edits affect earlier expressions and raw HTML templates are ignored", async () => {
  const source =
    '`A → B`{.inference}\n\n```inference-notation\ninfixr:60 "→"\n  html => "<script>bad()</script>"\n```';
  const result = await compile(request(source));
  assert.equal(result.status, "ok");
  if (result.status === "ok") {
    assert.match(result.fragments[0].html, /→/);
    assert.doesNotMatch(result.fragments[0].html, /<script>/);
  }
  const changed = await compile(
    request(source.replace("infixr:60", "infixr:-1"), 2),
  );
  assert.equal(changed.status, "invalid");
  const repaired = await compile(request(source, 3));
  assert.equal(repaired.status, "ok");
});

test("real compiler diagnostics map Unicode and container prefixes to editor offsets", async () => {
  const source = "> ```inference\n> ─\n> 𝛤 @\n> ```";
  const document = parseMarkdown(source);
  const result = await compile(request(source));
  assert.equal(result.status, "invalid");
  if (result.status !== "invalid") return;
  const location = result.diagnostics[0].location!;
  assert.ok("item" in location.source);
  assert.equal(
    sourceOffset(document.sources.get(location.source.item)!, location.start),
    source.indexOf("@"),
  );
});

test("import diagnostics identify the imported file", async () => {
  const input = request(
    '```inference-notation\nimport "nested/bad.notation"\n```',
  );
  input.modules = [{ path: "nested/bad.notation", source: 'infixr:-1 "→"' }];
  const result = await compile(input);
  assert.equal(result.status, "invalid");
  if (result.status === "invalid")
    assert.deepEqual(result.diagnostics[0].location?.source, {
      module: "nested/bad.notation",
    });
});

test("worker keeps only the latest queued revision and can be disposed", async () => {
  const worker = new Compiler(
    fileURLToPath(new URL("../dist", import.meta.url)),
  );
  try {
    const first = worker.compile(request("`x`{.inference}", 1));
    const second = worker.compile(request("`y`{.inference}", 2));
    const latest = worker.compile(request("`z`{.inference}", 3));
    assert.equal(await second, null);
    assert.equal((await first)?.status, "ok");
    assert.equal((await latest)?.revision, 3);
  } finally {
    worker.dispose();
  }
  assert.equal(await worker.compile(request("", 4)), null);
});
