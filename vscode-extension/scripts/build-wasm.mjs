import { spawnSync } from "node:child_process";
import { mkdir } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { resolve } from "node:path";

const root = fileURLToPath(new URL("../..", import.meta.url));
const output = resolve(root, "vscode-extension/artifacts");
await mkdir(output, { recursive: true });
const script = `set -eu
cd wasm
wasm32-wasi-cabal update
wasm32-wasi-cabal build exe:inference-wasm
inference_binary=$(wasm32-wasi-cabal list-bin exe:inference-wasm)
inference_libdir=$(wasm32-wasi-ghc --print-libdir)
cp "$inference_binary" "$INFERENCE_WASM_OUTPUT/inference.wasm"
node "$inference_libdir/post-link.mjs" -i "$inference_binary" -o "$INFERENCE_WASM_OUTPUT/bindings.mjs"
`;
const insideToolchain =
  spawnSync("wasm32-wasi-ghc", ["--numeric-version"], { stdio: "ignore" })
    .status === 0;
const result = spawnSync(
  insideToolchain ? "bash" : "nix",
  insideToolchain
    ? ["-c", script]
    : ["develop", "path:.", "--command", "bash", "-c", script],
  {
    cwd: root,
    stdio: "inherit",
    env: { ...process.env, INFERENCE_WASM_OUTPUT: output },
  },
);
if (result.error) throw result.error;
process.exitCode = result.status ?? 1;
