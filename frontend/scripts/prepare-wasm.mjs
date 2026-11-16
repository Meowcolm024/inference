import { access, copyFile, mkdir } from "node:fs/promises";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { resolve } from "node:path";

const root = fileURLToPath(new URL("../..", import.meta.url));
const artifacts = process.env.INFERENCE_WASM_ARTIFACTS
  ? resolve(process.env.INFERENCE_WASM_ARTIFACTS)
  : resolve(root, "vscode-extension/artifacts");
const destination = resolve(root, "frontend/public/wasm");
const names = ["inference.wasm", "bindings.mjs"];
let missing = false;
for (const name of names) {
  try {
    await access(resolve(artifacts, name));
  } catch {
    missing = true;
  }
}
if (missing || process.argv.includes("--build")) {
  if (process.env.INFERENCE_WASM_ARTIFACTS) {
    throw new Error(
      "INFERENCE_WASM_ARTIFACTS must contain inference.wasm and matching bindings.mjs.",
    );
  }
  console.log(
    "Building the shared Wasm compiler. The first build downloads the GHC toolchain.",
  );
  for (const [command, args] of [
    ["stack", ["build"]],
    [
      process.execPath,
      [resolve(root, "vscode-extension/scripts/build-wasm.mjs")],
    ],
  ]) {
    const result = spawnSync(command, args, { cwd: root, stdio: "inherit" });
    if (result.error) throw result.error;
    if (result.status !== 0) process.exit(result.status ?? 1);
  }
}
await mkdir(destination, { recursive: true });
for (const name of names)
  await copyFile(resolve(artifacts, name), resolve(destination, name));
console.log("Wasm preview assets are ready.");
