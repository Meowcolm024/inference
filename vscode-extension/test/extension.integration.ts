import assert from "node:assert/strict";
import { writeFile } from "node:fs/promises";
import * as vscode from "vscode";
import type { PreviewState } from "../src/extension";

export async function run(): Promise<void> {
  const extension = vscode.extensions.getExtension<{
    getPreviewState(): PreviewState | undefined;
  }>("RIvance.unicode-inference");
  assert.ok(extension, "Extension is loaded");
  const api = await extension.activate();
  const root = vscode.workspace.workspaceFolders![0].uri;
  const uri = vscode.Uri.joinPath(root, "example/stlc.md");
  const document = await vscode.workspace.openTextDocument(uri);
  await vscode.window.showTextDocument(document);
  await vscode.commands.executeCommand("inference.openPreview");

  const waitFor = async (
    status: PreviewState["status"],
    after = 0,
  ): Promise<PreviewState> => {
    const deadline = Date.now() + 20_000;
    while (Date.now() < deadline) {
      const state = api.getPreviewState();
      if (state && state.status === status && state.revision > after)
        return state;
      if (state?.status === "error") assert.fail(state.message);
      await new Promise((resolve) => setTimeout(resolve, 50));
    }
    assert.fail(
      `Timed out waiting for ${status}; current state: ${JSON.stringify(api.getPreviewState())}`,
    );
  };
  const replace = async (
    target: vscode.TextDocument,
    source: string,
  ): Promise<void> => {
    const edit = new vscode.WorkspaceEdit();
    edit.replace(
      target.uri,
      new vscode.Range(
        target.positionAt(0),
        target.positionAt(target.getText().length),
      ),
      source,
    );
    assert.ok(await vscode.workspace.applyEdit(edit));
  };

  const initial = await waitFor("ok");
  assert.match(initial.html, /T-App/);
  assert.match(initial.html, /border-top:1px/);
  console.log("PASS: opens and renders the STLC tutorial through Wasm");

  const original = document.getText();
  await replace(document, original.replace("T-App", "Application-live"));
  const edited = await waitFor("ok", initial.revision);
  assert.match(edited.html, /Application-live/);
  assert.ok(document.isDirty);
  console.log("PASS: unsaved Markdown edits update the preview");

  const module = await vscode.workspace.openTextDocument(
    vscode.Uri.joinPath(root, "example/stlc.notation"),
  );
  const moduleSource = module.getText();
  await replace(module, moduleSource.replace("infixr:60", "infixr:-1"));
  const invalid = await waitFor("invalid", edited.revision);
  assert.equal(invalid.html, edited.html, "keeps the last successful preview");
  assert.ok(
    vscode.languages
      .getDiagnostics(module.uri)
      .some((problem) => problem.source === "Unicode Inference"),
  );
  console.log(
    "PASS: unsaved imported-file errors appear in Problems and preserve the preview",
  );

  await replace(module, moduleSource);
  const repaired = await waitFor("ok", invalid.revision);
  assert.equal(
    vscode.languages
      .getDiagnostics(module.uri)
      .filter((problem) => problem.source === "Unicode Inference").length,
    0,
  );
  console.log(
    "PASS: fixing a module clears diagnostics and recovers the preview",
  );

  await replace(document, "> ```inference\n> ─\n> 𝛤 @\n> ```");
  const unicodeError = await waitFor("invalid", repaired.revision);
  const diagnostic = vscode.languages
    .getDiagnostics(uri)
    .find((problem) => problem.source === "Unicode Inference");
  assert.ok(diagnostic);
  assert.equal(document.getText(diagnostic.range), "@");
  assert.equal(
    diagnostic.range.start.character,
    5,
    "VS Code columns count UTF-16 units",
  );
  console.log("PASS: compiler errors select the exact Unicode source token");

  await replace(
    document,
    '```inference-notation\nimport "created.notation"\n```\n\n`A → B`{.inference}',
  );
  const missing = await waitFor("invalid", unicodeError.revision);
  await vscode.workspace.fs.writeFile(
    vscode.Uri.joinPath(root, "created.notation"),
    new TextEncoder().encode('infixr:60 "→"'),
  );
  const created = await waitFor("ok", missing.revision);
  assert.match(created.html, /→/);
  console.log("PASS: creating a missing module on disk refreshes the preview");

  // The queued revision must not overwrite the final edit.
  await replace(document, "`old`{.inference}");
  await replace(document, "`latest`{.inference}");
  const latest = await waitFor("ok", created.revision);
  assert.match(latest.html, /latest/);
  assert.doesNotMatch(latest.html, />old</);
  console.log("PASS: rapid edits show the latest revision");

  await document.save();
  await module.save();
  await vscode.commands.executeCommand("workbench.action.closeAllEditors");
  await writeFile(
    process.env.INFERENCE_TEST_RESULT!,
    JSON.stringify({ checks: 7 }),
  );
  console.log("All VS Code integration checks passed.");
}
