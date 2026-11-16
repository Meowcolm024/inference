import type { ModuleSource } from "../../../vscode-extension/src/protocol";

export type {
  ModuleSource,
  PreviewRequest,
  PreviewResponse,
} from "../../../vscode-extension/src/protocol";

export interface BrowserRequest {
  revision: number;
  source: string;
  modules: ModuleSource[];
}

export interface PreviewIssue {
  message: string;
  start: number;
  end: number;
  line: number;
  column: number;
  module?: string;
}

export interface PreviewContent {
  html: string;
  latexByKey: Map<string, string>;
}

export type BrowserResponse =
  | ({ revision: number; status: "ok"; elapsed: number } & PreviewContent)
  | {
      revision: number;
      status: "invalid";
      html: string;
      issues: PreviewIssue[];
    }
  | { revision: number; status: "error"; message: string };

export type WorkerMessage =
  | { type: "initialize"; assetRoot: string }
  | { type: "compile"; request: BrowserRequest };
