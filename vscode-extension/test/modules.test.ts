import assert from "node:assert/strict";
import { test } from "node:test";
import { loadModules, modulePath } from "../src/modules";
import { parseMarkdown } from "../src/markdown";

test("loads only transitive imports, normalizes aliases, and stops cycles", async () => {
  const items = parseMarkdown(
    '```inference-notation\nimport "nested/a.notation"\nimport "./b.notation"\n```',
  ).items;
  const files = new Map([
    ["nested/a.notation", 'import "../b.notation"'],
    ["b.notation", 'import "nested/a.notation"\ninfixr:60 "→"'],
  ]);
  const reads: string[] = [];
  const loaded = await loadModules(items, async (path) => {
    reads.push(path);
    return files.get(path);
  });
  assert.deepEqual(reads, ["nested/a.notation", "b.notation"]);
  assert.equal(loaded.modules.length, 2);
});

test("tracks missing files so their creation can trigger a new preview", async () => {
  const items = parseMarkdown(
    '```inference-notation\nimport "missing.notation"\n```',
  ).items;
  const loaded = await loadModules(items, async () => undefined);
  assert.equal(loaded.modules.length, 0);
  assert.deepEqual([...loaded.dependencies], ["missing.notation"]);
});

test("does not read paths escaping the virtual module root", async () => {
  const items = parseMarkdown(
    '```inference-notation\nimport "../secret"\nimport "/absolute"\n```',
  ).items;
  await loadModules(items, async () => {
    assert.fail("Must not read outside the module root");
  });
  assert.equal(modulePath("a/b.notation", "../c.notation"), "c.notation");
  assert.equal(modulePath(undefined, "a/../../secret"), undefined);
});
