import { parentPort, workerData } from "node:worker_threads";
import { createCompiler } from "./runtime";
import type { PreviewRequest } from "./protocol";

const compiler = createCompiler(workerData.directory);
let previous = Promise.resolve();
parentPort?.on("message", (request: PreviewRequest) => {
  previous = previous.then(async () => {
    try {
      parentPort?.postMessage(await (await compiler)(request));
    } catch (error) {
      parentPort?.postMessage({
        revision: request.revision,
        status: "error",
        message: String(error),
      });
    }
  });
});
// Initialization may fail before the first request arrives.
void compiler.catch(() => undefined);
