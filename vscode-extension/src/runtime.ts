import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { WASI, File, OpenFile, ConsoleStdout } from "@bjorn3/browser_wasi_shim";
import type { PreviewRequest, PreviewResponse } from "./protocol";

export async function createCompiler(
  directory: string,
): Promise<(request: PreviewRequest) => Promise<PreviewResponse>> {
  if (
    typeof Reflect.get(WebAssembly, "Suspending") !== "function" ||
    typeof Reflect.get(WebAssembly, "promising") !== "function"
  ) {
    throw new Error(
      "The preview needs WebAssembly JavaScript Promise Integration. Update VS Code and its remote server, or use a current Node 24 release for standalone tests.",
    );
  }
  const wasi = new WASI(
    [],
    [],
    [
      new OpenFile(new File([])),
      ConsoleStdout.lineBuffered(console.log),
      ConsoleStdout.lineBuffered(console.error),
    ],
  );
  const { default: imports } = await import(
    pathToFileURL(join(directory, "bindings.mjs")).href
  );
  const exports: WebAssembly.Exports & {
    compilePreview?: (json: string) => Promise<string>;
  } = {};
  const binary = await readFile(join(directory, "inference.wasm"));
  const { instance } = await WebAssembly.instantiate(binary, {
    wasi_snapshot_preview1: wasi.wasiImport,
    ghc_wasm_jsffi: imports(exports),
  });
  Object.assign(exports, instance.exports);
  wasi.initialize(instance as Parameters<typeof wasi.initialize>[0]);
  if (!exports.compilePreview)
    throw new Error("The Wasm compiler does not export compilePreview.");
  return async (request) =>
    JSON.parse(
      await exports.compilePreview!(JSON.stringify(request)),
    ) as PreviewResponse;
}
