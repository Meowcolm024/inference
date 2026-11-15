import * as vscode from "vscode";
import { randomBytes } from "node:crypto";
import { posix } from "node:path";
import { Compiler } from "./compiler";
import { parseMarkdown, sourceOffset, type MarkdownDocument } from "./markdown";
import { loadModules, modulePath } from "./modules";
import type {
  CompilerDiagnostic,
  MappedSource,
  SourceLocation,
} from "./protocol";
import { previewHtml } from "./shell";

interface Issue {
  message: string;
  uri: vscode.Uri;
  range: vscode.Range;
  diagnostic: vscode.Diagnostic;
}
export interface PreviewState {
  uri: string;
  revision: number;
  status: "loading" | "ok" | "invalid" | "error";
  html: string;
  message: string;
}

class Preview implements vscode.Disposable {
  private panel?: vscode.WebviewPanel;
  private document?: vscode.TextDocument;
  private compiler?: Compiler;
  private timer?: ReturnType<typeof setTimeout>;
  private revision = 0;
  private dependencies = new Set<string>();
  private issues: Issue[] = [];
  private readonly diagnostics =
    vscode.languages.createDiagnosticCollection("unicode-inference");
  private readonly subscriptions: vscode.Disposable[] = [];
  private watcher?: vscode.FileSystemWatcher;
  private root?: vscode.Uri;
  private ready = false;
  private lastGoodHtml = "";
  state?: PreviewState;

  constructor(private readonly context: vscode.ExtensionContext) {
    this.subscriptions.push(
      this.diagnostics,
      vscode.workspace.onDidChangeTextDocument((event) => {
        if (
          event.document === this.document ||
          this.dependencies.has(event.document.uri.toString())
        )
          this.schedule();
      }),
      vscode.workspace.onDidCloseTextDocument((document) => {
        if (this.dependencies.has(document.uri.toString())) this.schedule();
      }),
      vscode.workspace.onDidChangeConfiguration((event) => {
        if (event.affectsConfiguration("inference", this.document?.uri)) {
          this.setRoot();
          this.schedule();
        }
      }),
    );
  }

  open(document: vscode.TextDocument): void {
    if (this.document?.uri.toString() !== document.uri.toString()) {
      this.revision++;
      this.state = undefined;
      this.lastGoodHtml = "";
      this.dependencies.clear();
      this.diagnostics.clear();
      this.issues = [];
    }
    this.document = document;
    this.setRoot();
    if (!this.panel) {
      this.compiler = new Compiler(
        vscode.Uri.joinPath(this.context.extensionUri, "dist").fsPath,
      );
      this.panel = vscode.window.createWebviewPanel(
        "unicodeInference",
        "Inference Preview",
        { viewColumn: vscode.ViewColumn.Beside, preserveFocus: true },
        {
          enableScripts: true,
          retainContextWhenHidden: true,
          localResourceRoots: [
            vscode.Uri.joinPath(this.context.extensionUri, "dist"),
            vscode.Uri.joinPath(this.context.extensionUri, "media"),
          ],
        },
      );
      this.ready = false;
      this.panel.webview.html = this.webviewHtml(this.panel.webview);
      this.panel.webview.onDidReceiveMessage(
        (message: { type?: string; index?: number; line?: number }) => {
          if (message.type === "ready") {
            this.ready = true;
            this.publish();
          }
          if (
            message.type === "diagnostic" &&
            Number.isInteger(message.index)
          ) {
            const issue = this.issues[message.index!];
            if (issue) void this.reveal(issue.uri, issue.range);
          }
          if (
            message.type === "source" &&
            Number.isInteger(message.line) &&
            this.document
          ) {
            const line = Math.max(
              0,
              Math.min(message.line!, this.document.lineCount - 1),
            );
            void this.reveal(
              this.document.uri,
              new vscode.Range(line, 0, line, 0),
            );
          }
        },
        undefined,
        this.subscriptions,
      );
      this.panel.onDidDispose(
        () => this.close(),
        undefined,
        this.subscriptions,
      );
    } else this.panel.reveal(vscode.ViewColumn.Beside, true);
    this.panel.title = `Inference · ${posix.basename(document.uri.path)}`;
    this.schedule(0);
  }

  private setRoot(): void {
    if (!this.document) return;
    const folder =
      vscode.workspace.getWorkspaceFolder(this.document.uri)?.uri ??
      (this.document.uri.scheme === "untitled"
        ? vscode.workspace.workspaceFolders?.[0]?.uri
        : undefined) ??
      vscode.Uri.joinPath(this.document.uri, "..");
    const setting = vscode.workspace
      .getConfiguration("inference", this.document.uri)
      .get<string>("moduleRoot", "");
    const root = setting ? vscode.Uri.joinPath(folder, setting) : folder;
    if (this.root?.toString() === root.toString()) return;
    this.root = root;
    this.watcher?.dispose();
    this.watcher = vscode.workspace.createFileSystemWatcher(
      new vscode.RelativePattern(root, "**/*"),
    );
    const changed = (uri: vscode.Uri) => {
      if (this.dependencies.has(uri.toString())) this.schedule();
    };
    this.watcher.onDidChange(changed);
    this.watcher.onDidCreate(changed);
    this.watcher.onDidDelete(changed);
  }

  private schedule(delay?: number): void {
    if (!this.panel || !this.document) return;
    clearTimeout(this.timer);
    const revision = ++this.revision;
    // Invalidate old results immediately, before the debounce or filesystem reads.
    this.state = {
      uri: this.document.uri.toString(),
      revision,
      status: "loading",
      html: this.state?.html ?? "",
      message: "Updating preview…",
    };
    this.publish();
    const wait =
      delay ??
      vscode.workspace
        .getConfiguration("inference", this.document.uri)
        .get<number>("previewDelay", 150);
    this.timer = setTimeout(() => void this.update(revision), wait);
  }

  private async update(revision: number): Promise<void> {
    const document = this.document;
    const root = this.root;
    if (!document || !root || !this.compiler) return;
    const input = document.getText();
    const parsed = parseMarkdown(input);
    try {
      const loaded = await loadModules(parsed.items, async (path) => {
        const uri = vscode.Uri.joinPath(root, path);
        // Observe edits even if a new dependency is still being read.
        if (this.current(revision)) this.dependencies.add(uri.toString());
        const open = vscode.workspace.textDocuments.find(
          (candidate) => candidate.uri.toString() === uri.toString(),
        );
        if (open) return open.getText();
        try {
          return new TextDecoder("utf-8", { fatal: true }).decode(
            await vscode.workspace.fs.readFile(uri),
          );
        } catch {
          return undefined;
        }
      });
      if (!this.current(revision)) return;
      this.dependencies = new Set(
        Array.from(loaded.dependencies, (path) =>
          vscode.Uri.joinPath(root, path).toString(),
        ),
      );
      const moduleSources = new Map(
        loaded.modules.map((module) => [module.path, module.source]),
      );
      if (parsed.diagnostics.length) {
        this.setIssues(
          parsed.diagnostics.map((problem) => {
            const range = new vscode.Range(
              document.positionAt(problem.start),
              document.positionAt(problem.end),
            );
            const diagnostic = new vscode.Diagnostic(
              range,
              problem.message,
              vscode.DiagnosticSeverity.Error,
            );
            diagnostic.source = "Unicode Inference";
            return {
              uri: document.uri,
              range,
              message: problem.message,
              diagnostic,
            };
          }),
        );
        this.complete(
          revision,
          "invalid",
          "Fix the highlighted inference attributes to update the preview.",
          parsed,
        );
        return;
      }
      const response = await this.compiler.compile({
        revision,
        ignoreHtmlTemplates: true,
        items: parsed.items,
        modules: loaded.modules,
      });
      if (!response || !this.current(revision)) return;
      if (response.status === "ok") {
        this.setIssues([]);
        this.lastGoodHtml = parsed.render(response.fragments);
        this.state = {
          uri: document.uri.toString(),
          revision,
          status: "ok",
          html: this.lastGoodHtml,
          message: "Live preview",
        };
        this.publish();
      } else if (response.status === "invalid") {
        const issues = response.diagnostics.map((diagnostic) =>
          this.compilerIssue(diagnostic, parsed, document, root, moduleSources),
        );
        this.setIssues(issues);
        this.complete(
          revision,
          "invalid",
          "Fix the highlighted error to update the preview.",
          parsed,
        );
      } else {
        this.setIssues([]);
        this.complete(revision, "error", response.message, parsed);
      }
    } catch (error) {
      if (this.current(revision)) {
        this.setIssues([]);
        this.complete(
          revision,
          "error",
          `Could not update the preview: ${String(error)}`,
          parsed,
        );
      }
    }
  }

  private compilerIssue(
    problem: CompilerDiagnostic,
    parsed: MarkdownDocument,
    document: vscode.TextDocument,
    root: vscode.Uri,
    modules: Map<string, string>,
  ): Issue {
    const locate = (location: SourceLocation | null): vscode.Location => {
      let uri = document.uri;
      let source: MappedSource | undefined;
      if (location && "item" in location.source)
        source = parsed.sources.get(location.source.item);
      if (location && "module" in location.source) {
        const path = modulePath(undefined, location.source.module);
        if (path) {
          uri = vscode.Uri.joinPath(root, path);
          const text = modules.get(path) ?? "";
          source = {
            text,
            offsets: Array.from(
              { length: text.length + 1 },
              (_, index) => index,
            ),
          };
        }
      }
      if (!source || !location)
        return new vscode.Location(uri, new vscode.Range(0, 0, 0, 0));
      const position = (offset: number): vscode.Position => {
        const text =
          uri.toString() === document.uri.toString()
            ? document.getText()
            : source!.text;
        const before = text.slice(0, offset).split("\n");
        return new vscode.Position(before.length - 1, before.at(-1)!.length);
      };
      return new vscode.Location(
        uri,
        new vscode.Range(
          position(sourceOffset(source, location.start)),
          position(sourceOffset(source, location.end)),
        ),
      );
    };
    const location = locate(problem.location);
    const diagnostic = new vscode.Diagnostic(
      location.range,
      problem.message,
      vscode.DiagnosticSeverity.Error,
    );
    diagnostic.source = "Unicode Inference";
    diagnostic.code = problem.code;
    diagnostic.relatedInformation = problem.related.map(
      (related) =>
        new vscode.DiagnosticRelatedInformation(
          locate(related.location),
          related.message,
        ),
    );
    return {
      uri: location.uri,
      range: location.range,
      message: problem.message,
      diagnostic,
    };
  }

  private setIssues(issues: Issue[]): void {
    this.issues = issues;
    this.diagnostics.clear();
    const grouped = new Map<
      string,
      { uri: vscode.Uri; diagnostics: vscode.Diagnostic[] }
    >();
    for (const issue of issues) {
      const key = issue.uri.toString();
      const group = grouped.get(key) ?? { uri: issue.uri, diagnostics: [] };
      group.diagnostics.push(issue.diagnostic);
      grouped.set(key, group);
    }
    for (const group of grouped.values())
      this.diagnostics.set(group.uri, group.diagnostics);
  }

  private current(revision: number): boolean {
    return Boolean(this.panel) && revision === this.revision;
  }

  private complete(
    revision: number,
    status: "invalid" | "error",
    message: string,
    parsed: MarkdownDocument,
  ): void {
    const previous = this.lastGoodHtml;
    this.state = {
      uri: this.document!.uri.toString(),
      revision,
      status,
      html: previous || parsed.render([]),
      message: `${message}${previous ? " Showing the last successful preview." : ""}`,
    };
    this.publish();
  }

  private publish(): void {
    if (!this.ready || !this.state) return;
    void this.panel?.webview.postMessage({
      type: "preview",
      ...this.state,
      issues: this.issues.map((issue) => ({
        message: issue.message,
        file: vscode.workspace.asRelativePath(issue.uri),
        line: issue.range.start.line + 1,
        column: issue.range.start.character + 1,
      })),
    });
  }

  private async reveal(uri: vscode.Uri, range: vscode.Range): Promise<void> {
    const editor = await vscode.window.showTextDocument(uri, {
      viewColumn: vscode.ViewColumn.One,
      selection: range,
    });
    editor.revealRange(
      range,
      vscode.TextEditorRevealType.InCenterIfOutsideViewport,
    );
  }

  private webviewHtml(webview: vscode.Webview): string {
    const nonce = randomBytes(16).toString("hex");
    const script = webview.asWebviewUri(
      vscode.Uri.joinPath(this.context.extensionUri, "dist/webview.js"),
    );
    const style = webview.asWebviewUri(
      vscode.Uri.joinPath(this.context.extensionUri, "media/preview.css"),
    );
    return previewHtml(
      script.toString(),
      style.toString(),
      webview.cspSource,
      nonce,
    );
  }

  private close(): void {
    this.revision++;
    clearTimeout(this.timer);
    this.panel = undefined;
    this.document = undefined;
    this.state = undefined;
    this.lastGoodHtml = "";
    this.ready = false;
    this.compiler?.dispose();
    this.compiler = undefined;
    this.watcher?.dispose();
    this.watcher = undefined;
    this.root = undefined;
    this.dependencies.clear();
    this.setIssues([]);
  }

  dispose(): void {
    this.panel?.dispose();
    this.close();
    for (const subscription of this.subscriptions) subscription.dispose();
  }
}

export function activate(context: vscode.ExtensionContext): {
  getPreviewState: () => PreviewState | undefined;
} {
  const preview = new Preview(context);
  context.subscriptions.push(
    preview,
    vscode.commands.registerCommand(
      "inference.openPreview",
      async (uri?: vscode.Uri) => {
        const document = uri
          ? await vscode.workspace.openTextDocument(uri)
          : vscode.window.activeTextEditor?.document;
        if (!document || document.languageId !== "markdown") {
          void vscode.window.showInformationMessage(
            "Open a Markdown document to preview its inference rules.",
          );
          return;
        }
        preview.open(document);
      },
    ),
    vscode.commands.registerCommand("inference.insertRuleBar", () =>
      vscode.window.activeTextEditor?.insertSnippet(
        new vscode.SnippetString("──────────────────── ${1:Rule}"),
      ),
    ),
  );
  return {
    getPreviewState: () => (preview.state ? { ...preview.state } : undefined),
  };
}
