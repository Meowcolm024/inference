import { build } from "esbuild";
import { access, copyFile, mkdir } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { resolve } from "node:path";

const root = fileURLToPath(new URL("..", import.meta.url));
for (const name of ["inference.wasm", "bindings.mjs"]) {
  try {
    await access(resolve(root, "artifacts", name));
  } catch {
    throw new Error(`Missing artifacts/${name}. Run npm run build:wasm first.`);
  }
}
await mkdir(resolve(root, "dist/wasm"), { recursive: true });
for (const name of ["inference.wasm", "bindings.mjs"]) {
  await copyFile(
    resolve(root, "artifacts", name),
    resolve(root, "dist/wasm", name),
  );
}
await copyFile(resolve(root, "../LICENSE"), resolve(root, "LICENSE"));
await build({
  absWorkingDir: root,
  entryPoints: { extension: "src/extension.ts", worker: "src/worker.ts" },
  outdir: "dist",
  outExtension: { ".js": ".cjs" },
  bundle: true,
  platform: "node",
  target: "node22",
  format: "cjs",
  external: ["vscode"],
  sourcemap: true,
  logLevel: "info",
});
await build({
  absWorkingDir: root,
  entryPoints: ["src/webview.ts"],
  outfile: "dist/webview.js",
  bundle: true,
  platform: "browser",
  target: "es2022",
  logLevel: "info",
});
