import { useEffect, useRef, useState, type ChangeEvent } from "react";
import { Editor, type SelectionRequest } from "./Editor";
import { loadDraft, saveDraft } from "./draft";
import { usePreview } from "./preview/usePreview";
import type { PreviewIssue } from "./preview/protocol";

export default function App() {
  const [draft, setDraft] = useState(loadDraft);
  const [selection, setSelection] = useState<SelectionRequest>();
  const [mobilePane, setMobilePane] = useState<"source" | "preview">("source");
  const [fileError, setFileError] = useState("");
  const fileInput = useRef<HTMLInputElement>(null);
  const selectionId = useRef(0);
  const preview = usePreview(draft.source, draft.modules, draft.name);

  useEffect(() => {
    const timer = setTimeout(() => saveDraft(draft), 300);
    return () => clearTimeout(timer);
  }, [draft]);

  const reveal = (issue: Pick<PreviewIssue, "start" | "end">) => {
    setMobilePane("source");
    setSelection({
      start: issue.start,
      end: issue.end,
      request: ++selectionId.current,
    });
  };
  const openFiles = async (event: ChangeEvent<HTMLInputElement>) => {
    const files = Array.from(event.target.files ?? []);
    event.target.value = "";
    try {
      const contents = await Promise.all(
        files.map(async (file) => ({
          name: file.name,
          source: await file.text(),
        })),
      );
      const markdown = contents.find((file) =>
        /\.(md|markdown)$/i.test(file.name),
      );
      const notation = contents.filter((file) =>
        /\.notation$/i.test(file.name),
      );
      setDraft((previous) => {
        const modules = new Map(
          (markdown ? [] : previous.modules).map((module) => [
            module.path,
            module,
          ]),
        );
        for (const file of notation)
          modules.set(file.name, { path: file.name, source: file.source });
        return {
          source: markdown?.source ?? previous.source,
          name: markdown?.name ?? previous.name,
          modules: [...modules.values()],
        };
      });
      setFileError("");
    } catch (error) {
      setFileError(`Could not open the selected files: ${String(error)}`);
    }
  };
  const status =
    preview.status === "ok"
      ? "Live"
      : preview.status === "loading"
        ? "Updating"
        : "Error";

  return (
    <div className="app">
      <header className="app-header">
        <span className="app-name">
          <span className="app-mark" aria-hidden="true">
            ⊢
          </span>
          Inference
        </span>
        <span className="filename" title={draft.name}>
          {draft.name}
        </span>
        <div className="toolbar-actions">
          <span className={`live-status ${preview.status}`} role="status">
            <i aria-hidden="true" />
            {status}
          </span>
          <button
            className="open-button"
            onClick={() => fileInput.current?.click()}
            aria-label="Open files"
            title="Open Markdown and notation files"
          >
            <svg
              width="16"
              height="16"
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              strokeWidth="1.5"
              strokeLinejoin="round"
              aria-hidden="true"
            >
              <path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v9a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2Z" />
            </svg>
            Open
          </button>
        </div>
        <input
          ref={fileInput}
          className="file-input"
          type="file"
          accept=".md,.markdown,.notation"
          multiple
          aria-label="Open Markdown and notation files"
          onChange={(event) => void openFiles(event)}
        />
      </header>
      {fileError && (
        <div className="file-error" role="alert">
          {fileError}
        </div>
      )}
      <nav className="mobile-tabs" aria-label="Editor view">
        <button
          aria-pressed={mobilePane === "source"}
          onClick={() => setMobilePane("source")}
        >
          Markdown
        </button>
        <button
          aria-pressed={mobilePane === "preview"}
          onClick={() => setMobilePane("preview")}
        >
          Preview
        </button>
      </nav>
      <main className={`workspace show-${mobilePane}`}>
        <section className="editor-pane" aria-label="Markdown editor">
          <Editor
            source={draft.source}
            selection={selection}
            onChange={(source) =>
              setDraft((previous) => ({ ...previous, source }))
            }
          />
        </section>
        <section className="preview-pane" aria-label="Rendered preview">
          {(preview.issues.length > 0 || preview.message) && (
            <aside
              className="diagnostics"
              aria-label="Preview errors"
              role="alert"
            >
              <div className="diagnostic-heading">
                <span className="error-mark" aria-hidden="true">
                  !
                </span>
                <strong>
                  {preview.stale
                    ? "Showing the last valid preview"
                    : "Preview error"}
                </strong>
              </div>
              {preview.message && <p>{preview.message}</p>}
              {preview.issues.map((issue, index) =>
                issue.module ? (
                  <p key={index}>
                    <span className="error-location">
                      {issue.module}:{issue.line}:{issue.column}
                    </span>{" "}
                    {issue.message}
                  </p>
                ) : (
                  <button
                    key={index}
                    className="diagnostic-link"
                    onClick={() => reveal(issue)}
                  >
                    <span className="error-location">
                      Line {issue.line}:{issue.column}
                    </span>
                    <span>{issue.message}</span>
                    <span aria-hidden="true">↗</span>
                  </button>
                ),
              )}
            </aside>
          )}
          <div className="preview-scroll">
            {!preview.html && preview.status === "loading" ? (
              <div className="loading-preview">Rendering…</div>
            ) : (
              <article
                className="rendered-document"
                aria-label="Document preview"
                onDoubleClick={(event) => {
                  const target =
                    event.target instanceof Element
                      ? event.target.closest<HTMLElement>("[data-source-line]")
                      : null;
                  if (!target) return;
                  const line = Number(target.dataset.sourceLine);
                  if (!Number.isInteger(line)) return;
                  const start = draft.source
                    .split("\n")
                    .slice(0, line)
                    .reduce((offset, text) => offset + text.length + 1, 0);
                  reveal({ start, end: start });
                }}
                dangerouslySetInnerHTML={{ __html: preview.html }}
              />
            )}
          </div>
        </section>
      </main>
    </div>
  );
}
