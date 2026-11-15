declare function acquireVsCodeApi(): {
  postMessage(message: unknown): void;
  getState(): { scroll?: number } | undefined;
  setState(state: unknown): void;
};
const vscode = acquireVsCodeApi();
const content = document.getElementById("content")!;
const statusText = document.getElementById("status")!;
const indicator = document.getElementById("indicator")!;
const issues = document.getElementById("issues")!;
let revision = -1;
let previousHtml = "";

window.addEventListener("message", (event) => {
  const message = event.data;
  if (message.type !== "preview" || message.revision < revision) return;
  revision = message.revision;
  statusText.textContent = message.message;
  indicator.className = `indicator ${message.status}`;
  content.setAttribute("aria-busy", String(message.status === "loading"));
  if (message.html !== previousHtml) {
    const scroll = window.scrollY || vscode.getState()?.scroll || 0;
    content.innerHTML = message.html;
    previousHtml = message.html;
    window.scrollTo(0, scroll);
  }
  issues.replaceChildren();
  for (const [index, issue] of (message.issues ?? []).entries()) {
    const button = document.createElement("button");
    button.className = "diagnostic";
    button.textContent = `${issue.file}:${issue.line}:${issue.column} — ${issue.message}`;
    button.addEventListener("click", () =>
      vscode.postMessage({ type: "diagnostic", index }),
    );
    issues.append(button);
  }
  issues.hidden = issues.childElementCount === 0;
});
content.addEventListener("dblclick", (event) => {
  const target =
    event.target instanceof Element
      ? event.target.closest<HTMLElement>("[data-source-line]")
      : null;
  if (target)
    vscode.postMessage({
      type: "source",
      line: Number(target.dataset.sourceLine),
    });
});
// Markdown links stay inside the preview only when they identify a local anchor.
content.addEventListener("click", (event) => {
  const link =
    event.target instanceof Element ? event.target.closest("a") : null;
  if (link && !link.getAttribute("href")?.startsWith("#"))
    event.preventDefault();
});
window.addEventListener(
  "scroll",
  () => vscode.setState({ scroll: window.scrollY }),
  { passive: true },
);
vscode.postMessage({ type: "ready" });
