import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";

const [binary, bindings, shim] = process.argv.slice(2);
const { WASI, File, OpenFile, ConsoleStdout } = await import(pathToFileURL(resolve(shim)));
const wasi = new WASI([], [], [
  new OpenFile(new File([])),
  ConsoleStdout.lineBuffered(console.log),
  ConsoleStdout.lineBuffered(console.error),
]);
const { default: imports } = await import(pathToFileURL(resolve(bindings)));
const exports = {};
const { instance } = await WebAssembly.instantiate(await readFile(binary), {
  wasi_snapshot_preview1: wasi.wasiImport,
  ghc_wasm_jsffi: imports(exports),
});
Object.assign(exports, instance.exports);
wasi.initialize(instance);

const request = String.raw`{
  "revision": 7,
  "items": [
    {"key":"rule","kind":"block","attr":{"id":"","classes":["inference"],"pairs":[]},"source":"──── Base\nA → B"},
    {"key":"inline","kind":"inline","attr":{"id":"","classes":["inference"],"pairs":[]},"source":"A → B"},
    {"key":"notation","kind":"notation","attr":{"id":"","classes":["inference-notation"],"pairs":[]},"source":"import \"arrow.notation\""}
  ],
  "modules":[{"path":"arrow.notation","source":"infixr:60 \"→\"\n  html => lhs \" <b>→</b> \" rhs"}]
}`;
const result = JSON.parse(await exports.compilePreview(request));
assert.equal(result.revision, 7);
assert.equal(result.status, "ok", JSON.stringify(result));
assert.deepEqual(result.fragments.map(({ key }) => key), ["rule", "inline"]);
assert.match(result.fragments[0].html, /border-top/);
for (const { html } of result.fragments) assert.match(html, /<b>→<\/b>/);

const invalid = JSON.parse(await exports.compilePreview(request.replace("──── Base\\nA → B", "A → B")));
assert.equal(invalid.status, "invalid", JSON.stringify(invalid));
assert.deepEqual(invalid.diagnostics[0].location.source, { item: "rule" });

const malformed = JSON.parse(await exports.compilePreview("{"));
assert.equal(malformed.status, "error");
console.log("Wasm preview smoke test passed.");
