import assert from "node:assert/strict";
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright-core";
import { previewHtml } from "../src/shell";
import { parseMarkdown } from "../src/markdown";
import { loadModules } from "../src/modules";
import { createCompiler } from "../src/runtime";

const previewDocument = parseMarkdown(
  await readFile(new URL("../../example/stlc.md", import.meta.url), "utf8"),
);
const loaded = await loadModules(previewDocument.items, async (path) =>
  readFile(new URL(`../../${path}`, import.meta.url), "utf8"),
);
const compile = await createCompiler(
  fileURLToPath(new URL("../artifacts", import.meta.url)),
);
const result = await compile({
  revision: 1,
  ignoreHtmlTemplates: true,
  items: previewDocument.items,
  modules: loaded.modules,
});
assert.equal(result.status, "ok");
if (result.status !== "ok")
  throw new Error("Could not compile the preview fixture.");
const html = previewDocument.render(result.fragments);
const script = await readFile(new URL("../dist/webview.js", import.meta.url));
const style = await readFile(new URL("../media/preview.css", import.meta.url));
const server = createServer((request, response) => {
  if (request.url === "/webview.js") {
    response.setHeader("Content-Type", "text/javascript");
    response.end(script);
  } else if (request.url === "/preview.css") {
    response.setHeader("Content-Type", "text/css");
    response.end(style);
  } else {
    response.setHeader("Content-Type", "text/html");
    response.end(
      previewHtml("/webview.js", "/preview.css", "'self'", "preview-test"),
    );
  }
});
await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
const address = server.address();
assert.ok(address && typeof address !== "string");
let browser;
try {
  browser = await chromium.launch({
    executablePath: process.env.CHROMIUM_EXECUTABLE_PATH ?? "google-chrome",
    headless: true,
    args: ["--no-sandbox"],
  });
  const page = await browser.newPage({
    viewport: { width: 720, height: 1000 },
    deviceScaleFactor: 1,
  });
  const errors: string[] = [];
  page.on("pageerror", (error) => errors.push(error.message));
  await page.addInitScript({
    content: `
    window.messages = [];
    window.acquireVsCodeApi = function () {
      return {
        postMessage: function (value) { window.messages.push(value); },
        getState: function () { return {}; },
        setState: function () {}
      };
    };
  `,
  });
  await page.goto(`http://127.0.0.1:${address.port}`);
  await page.waitForFunction(() =>
    (window as unknown as { messages: { type: string }[] }).messages.some(
      (message) => message.type === "ready",
    ),
  );
  await page.evaluate(() => {
    const colors = {
      "editor-background": "#18181b",
      "editor-foreground": "#e4e4e7",
      "panel-border": "#34343c",
      descriptionForeground: "#a1a1aa",
      "textLink-foreground": "#87b7eb",
      "textCodeBlock-background": "#242429",
    };
    for (const [name, color] of Object.entries(colors))
      document.documentElement.style.setProperty(`--vscode-${name}`, color);
  });
  await page.evaluate(
    (html) =>
      window.postMessage({
        type: "preview",
        revision: 1,
        status: "ok",
        message: "Live preview",
        html,
        issues: [],
      }),
    html,
  );
  await page.locator("#indicator.ok").waitFor();
  assert.equal(
    await page.locator("h1").textContent(),
    "Simply typed lambda calculus",
  );
  assert.equal(await page.locator(".inference-block").count(), 4);
  assert.ok((await page.locator(".inference-inline").count()) > 15);
  assert.equal(await page.locator("#content script").count(), 0);
  await page.screenshot({
    path: fileURLToPath(new URL("../artifacts/preview.png", import.meta.url)),
    fullPage: true,
  });
  await page.locator(".inference-block").first().dblclick();
  await page.waitForFunction(() =>
    (window as unknown as { messages: { type: string }[] }).messages.some(
      (message) => message.type === "source",
    ),
  );
  await page.evaluate(
    (html) =>
      window.postMessage({
        type: "preview",
        revision: 2,
        status: "invalid",
        message: "Showing the last successful preview.",
        html,
        issues: [
          {
            file: "example/stlc.notation",
            line: 1,
            column: 8,
            message: "Expected a precedence.",
          },
        ],
      }),
    html,
  );
  await page.getByRole("button", { name: /Expected a precedence/ }).click();
  await page.waitForFunction(() =>
    (window as unknown as { messages: { type: string }[] }).messages.some(
      (message) => message.type === "diagnostic",
    ),
  );
  await page.evaluate(() =>
    window.postMessage({
      type: "preview",
      revision: 1,
      status: "ok",
      message: "STALE",
      html: "STALE",
      issues: [],
    }),
  );
  assert.equal(
    await page.locator("h1").textContent(),
    "Simply typed lambda calculus",
  );
  assert.deepEqual(errors, []);
  console.log(
    "Webview checks passed: real compiler output, CSP, rendering, source navigation, diagnostic clicks, and stale revisions.",
  );
} finally {
  await browser?.close();
  await new Promise<void>((resolve, reject) =>
    server.close((error) => (error ? reject(error) : resolve())),
  );
}
