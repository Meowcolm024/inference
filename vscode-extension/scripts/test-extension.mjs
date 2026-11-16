import { runTests } from "@vscode/test-electron";
import { build } from "esbuild";
import { cp, mkdir, mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("..", import.meta.url));
await build({
  absWorkingDir: root,
  entryPoints: ["test/extension.integration.ts"],
  outfile: "dist/extension-test.cjs",
  platform: "node",
  format: "cjs",
  bundle: true,
  external: ["vscode"],
  target: "node22",
});
const temporary = await mkdtemp(join(tmpdir(), "inference-extension-"));
try {
  const workspace = join(temporary, "workspace");
  await mkdir(workspace);
  await cp(resolve(root, "../example"), join(workspace, "example"), {
    recursive: true,
  });
  await runTests({
    extensionDevelopmentPath: root,
    extensionTestsPath: resolve(root, "dist/extension-test.cjs"),
    vscodeExecutablePath: process.env.VSCODE_EXECUTABLE_PATH,
    extensionTestsEnv: {
      INFERENCE_TEST_RESULT: join(temporary, "result.json"),
    },
    launchArgs: [
      workspace,
      "--disable-extensions",
      "--disable-workspace-trust",
      "--skip-welcome",
      "--skip-release-notes",
      "--disable-gpu",
      "--no-sandbox",
      `--user-data-dir=${join(temporary, "profile")}`,
      `--extensions-dir=${join(temporary, "extensions")}`,
    ],
  });
  const result = JSON.parse(
    await readFile(join(temporary, "result.json"), "utf8"),
  );
  console.log(
    `Verified ${result.checks} checks inside the VS Code extension host.`,
  );
} finally {
  await rm(temporary, { recursive: true, force: true });
}
