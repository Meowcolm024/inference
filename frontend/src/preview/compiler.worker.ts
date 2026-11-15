import { WASI, File, OpenFile, ConsoleStdout } from "@bjorn3/browser_wasi_shim";
import { renderPreview, type Compile } from "./render";
import type { WorkerMessage, PreviewResponse } from "./protocol";

async function initialize(assetRoot: string): Promise<Compile> {
  if (
    typeof Reflect.get(WebAssembly, "Suspending") !== "function" ||
    typeof Reflect.get(WebAssembly, "promising") !== "function"
  ) {
    throw new Error(
      "This browser cannot run the inference compiler. Try a current version of Chrome, Edge, or Firefox.",
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
  const bindingsUrl = new URL("bindings.mjs", assetRoot).href;
  const [{ default: imports }, response] = await Promise.all([
    import(/* @vite-ignore */ bindingsUrl),
    fetch(new URL("inference.wasm", assetRoot)),
  ]);
  if (!response.ok)
    throw new Error(
      `Could not load the inference compiler (${response.status}).`,
    );
  const exports: WebAssembly.Exports & {
    compilePreview?: (json: string) => Promise<string>;
  } = {};
  const { instance } = await WebAssembly.instantiate(
    await response.arrayBuffer(),
    {
      wasi_snapshot_preview1: wasi.wasiImport,
      ghc_wasm_jsffi: imports(exports),
    },
  );
  Object.assign(exports, instance.exports);
  wasi.initialize(instance as Parameters<typeof wasi.initialize>[0]);
  if (!exports.compilePreview)
    throw new Error(
      "The inference compiler is missing its preview entry point.",
    );
  return async (request) =>
    JSON.parse(
      await exports.compilePreview!(JSON.stringify(request)),
    ) as PreviewResponse;
}

let assetRoot = "";
let compiler: Promise<Compile> | undefined;
let previous = Promise.resolve();
self.onmessage = ({ data }: MessageEvent<WorkerMessage>) => {
  if (data.type === "initialize") {
    assetRoot = data.assetRoot;
    return;
  }
  const request = data.request;
  previous = previous.then(async () => {
    try {
      const compile: Compile = async (input) => {
        compiler ??= initialize(assetRoot);
        return (await compiler)(input);
      };
      self.postMessage(await renderPreview(request, compile));
    } catch (error) {
      self.postMessage({
        revision: request.revision,
        status: "error",
        message: error instanceof Error ? error.message : String(error),
      });
    }
  });
};
