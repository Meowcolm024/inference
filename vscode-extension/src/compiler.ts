import { Worker } from "node:worker_threads";
import { join } from "node:path";
import type { PreviewRequest, PreviewResponse } from "./protocol";

interface Job {
  request: PreviewRequest;
  resolve: (response: PreviewResponse | null) => void;
}

// Keep at most one running and one queued revision; typing cannot flood Wasm.
export class Compiler {
  private worker?: Worker;
  private running?: Job;
  private queued?: Job;
  private timeout?: ReturnType<typeof setTimeout>;
  private disposed = false;
  constructor(private readonly directory: string) {}

  compile(request: PreviewRequest): Promise<PreviewResponse | null> {
    if (this.disposed) return Promise.resolve(null);
    return new Promise((resolve) => {
      const job = { request, resolve };
      if (this.running) {
        this.queued?.resolve(null);
        this.queued = job;
      } else this.start(job);
    });
  }

  private start(job: Job): void {
    this.running = job;
    if (!this.worker) {
      const worker = new Worker(join(this.directory, "worker.cjs"), {
        workerData: { directory: join(this.directory, "wasm") },
      });
      this.worker = worker;
      worker.on("message", (response: PreviewResponse) => {
        if (this.worker === worker) this.finish(response);
      });
      worker.on("error", (error) => {
        if (this.worker === worker) this.fail(error.message);
      });
      worker.on("exit", (code) => {
        if (this.worker === worker)
          this.fail(`Preview worker exited (${code}).`);
      });
    }
    this.timeout = setTimeout(
      () =>
        this.fail(
          "Preview compilation timed out. Edit the document to try again.",
        ),
      30_000,
    );
    this.worker.postMessage(job.request);
  }

  private finish(response: PreviewResponse): void {
    clearTimeout(this.timeout);
    this.running?.resolve(response);
    this.running = undefined;
    const next = this.queued;
    this.queued = undefined;
    if (next) this.start(next);
  }

  private fail(message: string): void {
    const worker = this.worker;
    this.worker = undefined;
    void worker?.terminate();
    this.finish({
      revision: this.running?.request.revision ?? null,
      status: "error",
      message,
    });
  }

  dispose(): void {
    this.disposed = true;
    clearTimeout(this.timeout);
    this.running?.resolve(null);
    this.queued?.resolve(null);
    this.running = this.queued = undefined;
    const worker = this.worker;
    this.worker = undefined;
    void worker?.terminate();
  }
}
