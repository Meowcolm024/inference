import type { BrowserRequest, BrowserResponse } from "./protocol";

interface Job {
  request: BrowserRequest;
  resolve: (response: BrowserResponse | null) => void;
}

export class PreviewClient {
  private worker?: Worker;
  private active?: Job;
  private queued?: Job;
  private timer?: ReturnType<typeof setTimeout>;
  private disposed = false;

  compile(request: BrowserRequest): Promise<BrowserResponse | null> {
    if (this.disposed) return Promise.resolve(null);
    return new Promise((resolve) => {
      const job = { request, resolve };
      if (this.active) {
        this.queued?.resolve(null);
        this.queued = job;
      } else this.start(job);
    });
  }

  private start(job: Job): void {
    this.active = job;
    if (!this.worker) {
      const worker = new Worker(
        new URL("./compiler.worker.ts", import.meta.url),
        { type: "module" },
      );
      this.worker = worker;
      worker.postMessage({
        type: "initialize",
        assetRoot: new URL(`${import.meta.env.BASE_URL}wasm/`, document.baseURI)
          .href,
      });
      worker.onmessage = ({ data }: MessageEvent<BrowserResponse>) => {
        if (this.worker === worker) this.finish(data);
      };
      worker.onerror = () => {
        if (this.worker === worker)
          this.fail(
            "The preview worker could not run. Try reloading the page.",
          );
      };
    }
    this.timer = setTimeout(
      () =>
        this.fail(
          "This document took too long to compile. Edit the source to try again.",
        ),
      30_000,
    );
    this.worker.postMessage({ type: "compile", request: job.request });
  }

  private finish(response: BrowserResponse): void {
    clearTimeout(this.timer);
    this.active?.resolve(response);
    this.active = undefined;
    const next = this.queued;
    this.queued = undefined;
    if (next) this.start(next);
  }

  private fail(message: string): void {
    this.worker?.terminate();
    this.worker = undefined;
    this.finish({
      revision: this.active?.request.revision ?? 0,
      status: "error",
      message,
    });
  }

  dispose(): void {
    this.disposed = true;
    clearTimeout(this.timer);
    this.active?.resolve(null);
    this.queued?.resolve(null);
    this.active = this.queued = undefined;
    this.worker?.terminate();
    this.worker = undefined;
  }
}
