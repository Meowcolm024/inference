import { katex } from "@mdit/plugin-katex";
import {
  parseMarkdown,
  sourceOffset,
} from "../../../vscode-extension/src/markdown";
import type {
  SourceLocation,
  MappedSource,
} from "../../../vscode-extension/src/protocol";
import type {
  BrowserRequest,
  BrowserResponse,
  PreviewIssue,
  PreviewRequest,
  PreviewResponse,
} from "./protocol";

export type Compile = (request: PreviewRequest) => Promise<PreviewResponse>;

export async function renderPreview(
  input: BrowserRequest,
  compile: Compile,
): Promise<BrowserResponse> {
  const started = performance.now();
  const parsed = parseMarkdown(input.source, (md) =>
    md.use(katex, {
      delimiters: "all",
      throwOnError: false,
      trust: false,
      strict: "ignore",
      maxExpand: 1000,
      maxSize: 20,
    }),
  );
  const locate = (
    location: SourceLocation | null,
    message: string,
  ): PreviewIssue => {
    let source: MappedSource | undefined;
    let module: string | undefined;
    if (location && "item" in location.source)
      source = parsed.sources.get(location.source.item);
    if (location && "module" in location.source) {
      module = location.source.module;
      const text =
        input.modules.find((entry) => entry.path === module)?.source ?? "";
      source = {
        text,
        offsets: Array.from({ length: text.length + 1 }, (_, index) => index),
      };
    }
    const start = source && location ? sourceOffset(source, location.start) : 0;
    const end = source && location ? sourceOffset(source, location.end) : start;
    const before = (module ? (source?.text ?? "") : input.source)
      .slice(0, start)
      .split("\n");
    return {
      message,
      start,
      end,
      line: before.length,
      column: Array.from(before.at(-1) ?? "").length + 1,
      module,
    };
  };
  if (parsed.diagnostics.length) {
    return {
      revision: input.revision,
      status: "invalid",
      html: parsed.render([]),
      issues: parsed.diagnostics.map((problem) => {
        const before = input.source.slice(0, problem.start).split("\n");
        return {
          ...problem,
          line: before.length,
          column: Array.from(before.at(-1) ?? "").length + 1,
        };
      }),
    };
  }
  // Ordinary Markdown and KaTeX can preview without loading the Wasm reactor.
  if (!parsed.items.length)
    return {
      revision: input.revision,
      status: "ok",
      html: parsed.render([]),
      elapsed: performance.now() - started,
    };
  const result = await compile({
    revision: input.revision,
    ignoreHtmlTemplates: true,
    items: parsed.items,
    modules: input.modules,
  });
  if (result.status === "error")
    return {
      revision: input.revision,
      status: "error",
      message: result.message,
    };
  if (result.status === "invalid") {
    return {
      revision: input.revision,
      status: "invalid",
      html: parsed.render([]),
      issues: result.diagnostics.flatMap((diagnostic) => [
        locate(diagnostic.location, diagnostic.message),
        ...diagnostic.related.map((related) =>
          locate(related.location, related.message),
        ),
      ]),
    };
  }
  return {
    revision: input.revision,
    status: "ok",
    html: parsed.render(result.fragments),
    elapsed: performance.now() - started,
  };
}
