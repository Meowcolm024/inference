export interface Attributes {
  id: string;
  classes: string[];
  pairs: [string, string][];
}
export interface Item {
  key: string;
  kind: "notation" | "block" | "inline";
  attr: Attributes;
  source: string;
}
export interface ModuleSource {
  path: string;
  source: string;
}
export interface PreviewRequest {
  revision: number;
  ignoreHtmlTemplates: true;
  includeLatex?: true;
  items: Item[];
  modules: ModuleSource[];
}
export interface SourcePosition {
  line: number;
  column: number;
}
export interface SourceLocation {
  source: { item: string } | { module: string };
  start: SourcePosition;
  end: SourcePosition;
}
export interface CompilerDiagnostic {
  code: string;
  message: string;
  location: SourceLocation | null;
  related: { message: string; location: SourceLocation }[];
}
export interface PreviewFragment {
  key: string;
  html: string;
  latex?: string;
}

export type PreviewResponse =
  | {
      revision: number;
      status: "ok";
      fragments: PreviewFragment[];
    }
  | { revision: number; status: "invalid"; diagnostics: CompilerDiagnostic[] }
  | { revision: number | null; status: "error"; message: string };

export interface MappedSource {
  text: string;
  offsets: number[];
}
export interface AdapterDiagnostic {
  message: string;
  start: number;
  end: number;
}
