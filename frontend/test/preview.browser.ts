import { expect, test, type Page } from "@playwright/test";

async function edit(page: Page, source: string) {
  const editor = page.getByRole("textbox", { name: "Markdown source" });
  await editor.click();
  await editor.press("ControlOrMeta+A");
  await page.keyboard.insertText(source);
}

test("the default document renders real Wasm rules and KaTeX side by side", async ({
  page,
}) => {
  const errors: string[] = [];
  page.on("pageerror", (error) => errors.push(error.message));
  await page.goto("/");
  await expect(page.getByRole("status")).toHaveText("Live");
  await expect(
    page.getByRole("heading", { name: "A small type system" }),
  ).toBeVisible();
  await expect(page.locator(".inference-block")).toHaveCount(2);
  await expect(page.locator(".inference-block").first()).toContainText("T-App");
  await expect(page.locator(".katex")).toHaveCount(2);
  const source = await page
    .getByRole("region", { name: "Markdown editor" })
    .boundingBox();
  const preview = await page
    .getByRole("region", { name: "Rendered preview" })
    .boundingBox();
  expect(source!.x + source!.width).toBe(preview!.x);
  await page.screenshot({ path: "test-results/desktop.png", fullPage: true });
  expect(errors).toEqual([]);
});

test("typing updates math and persists the latest document across reloads", async ({
  page,
}) => {
  await page.goto("/");
  await expect(page.getByRole("status")).toHaveText("Live");
  await edit(page, "# Edited live\n\n$\\sqrt{2}$\n\n$$a^2+b^2=c^2$$");
  await expect(
    page.getByRole("heading", { name: "Edited live" }),
  ).toBeVisible();
  await expect(page.locator(".katex")).toHaveCount(2);
  await expect
    .poll(() =>
      page.evaluate(() => localStorage.getItem("unicode-inference.draft.v1")),
    )
    .toContain("Edited live");
  await page.reload();
  await expect(
    page.getByRole("heading", { name: "Edited live" }),
  ).toBeVisible();
  await expect(page.getByRole("status")).toHaveText("Live");
});

test("invalid inference preserves the last preview, selects Unicode errors, and recovers", async ({
  page,
}) => {
  await page.goto("/");
  await expect(page.getByRole("status")).toHaveText("Live");
  const source = "> ```inference\n> ─\n> 𝛤 @\n> ```";
  await edit(page, source);
  await expect(page.getByRole("alert")).toContainText(
    "Showing the last valid preview",
  );
  await expect(
    page.getByRole("heading", { name: "A small type system" }),
  ).toBeVisible();
  await page.locator(".diagnostic-link").first().click();
  await expect
    .poll(() => page.evaluate(() => window.getSelection()?.toString()))
    .toBe("@");
  await edit(page, source.replace(" @", ""));
  await expect(page.getByRole("status")).toHaveText("Live");
  await expect(page.getByRole("alert")).toHaveCount(0);
  await expect(page.locator(".inference-block")).toContainText("𝛤");
});

test("opened notation files affect expressions and updated declarations", async ({
  page,
}) => {
  await page.goto("/");
  const markdown =
    '`A → B`{.inference}\n\n```inference-notation\nimport "types.notation"\n```';
  const input = page.getByLabel("Open Markdown and notation files");
  await input.setInputFiles([
    {
      name: "test.md",
      mimeType: "text/markdown",
      buffer: Buffer.from(markdown),
    },
    {
      name: "types.notation",
      mimeType: "text/plain",
      buffer: Buffer.from(
        'infixr:60 "→"\n  html => "<script>window.bad=true</script>"',
      ),
    },
  ]);
  await expect(page.getByRole("status")).toHaveText("Live");
  await expect(page.locator(".inference-inline")).toContainText("A → B");
  expect(await page.evaluate(() => Reflect.get(window, "bad"))).toBeUndefined();
  await input.setInputFiles({
    name: "types.notation",
    mimeType: "text/plain",
    buffer: Buffer.from('infixr:-1 "→"'),
  });
  await expect(page.getByRole("alert")).toContainText("types.notation");
  await input.setInputFiles({
    name: "types.notation",
    mimeType: "text/plain",
    buffer: Buffer.from('infixr:60 "→"'),
  });
  await expect(page.getByRole("status")).toHaveText("Live");
  await expect(page.getByRole("alert")).toHaveCount(0);
});

test("later notation edits update earlier expressions and rapid edits settle on the latest source", async ({
  page,
}) => {
  await page.goto("/");
  await expect(page.getByRole("status")).toHaveText("Live");
  const source =
    '`A → B`{.inference}\n\n```inference-notation\ninfixr:60 "→"\n```';
  await edit(page, source);
  await expect(page.locator(".inference-inline")).toHaveCount(1);
  await expect(page.locator(".inference-inline")).toContainText("A → B");
  await edit(page, source.replace("infixr:60", "infixr:-1"));
  await expect(page.getByRole("alert")).toBeVisible();
  await edit(page, source);
  await edit(page, "# Latest revision\n\n$z$ and `z`{.inference}");
  await expect(
    page.getByRole("heading", { name: "Latest revision" }),
  ).toBeVisible();
  await expect(page.getByRole("status")).toHaveText("Live");
  await expect(page.locator(".inference-inline")).toContainText("z");
  await expect(page.getByRole("alert")).toHaveCount(0);
});

test("copy buttons use the LaTeX for the displayed preview", async ({
  context,
  page,
}) => {
  await context.grantPermissions(["clipboard-read", "clipboard-write"]);
  await page.goto("/");
  await expect(page.getByRole("status")).toHaveText("Live");
  const source =
    "# Clipboard fixture\n\n`x`{.inference}\n\n```inference\n────\nx\n```";
  await edit(page, source);
  await expect(
    page.getByRole("heading", { name: "Clipboard fixture" }),
  ).toBeVisible();
  const inlineCopy = page.locator(".inference-inline").getByRole("button", {
    name: "Copy as LaTeX",
  });
  const blockCopy = page.locator(".inference-block").getByRole("button", {
    name: "Copy as LaTeX",
  });
  const clipboard = () => page.evaluate(() => navigator.clipboard.readText());
  await inlineCopy.click();
  await expect.poll(clipboard).toBe("x");
  await expect(page.getByText("LaTeX copied", { exact: true })).toBeVisible();
  await blockCopy.click();
  await expect.poll(clipboard).toContain("\\begin{mathpar}");
  await edit(page, source.replace("`x`", "`y`").replace("────\nx", "x"));
  await expect(page.getByRole("alert")).toContainText("last valid preview");
  await inlineCopy.click();
  await expect.poll(clipboard).toBe("x");
});

test("narrow screens switch between source and preview without overflowing", async ({
  page,
}) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto("/");
  await expect(
    page.getByRole("textbox", { name: "Markdown source" }),
  ).toBeVisible();
  await page.getByRole("button", { name: "Preview", exact: true }).click();
  await expect(page.getByRole("status")).toHaveText("Live");
  await expect(
    page.getByRole("heading", { name: "A small type system" }),
  ).toBeVisible();
  expect(
    await page.evaluate(
      () => document.documentElement.scrollWidth <= innerWidth,
    ),
  ).toBe(true);
  await page.screenshot({ path: "test-results/mobile.png", fullPage: true });
  await page.getByRole("button", { name: "Markdown", exact: true }).click();
  await edit(page, "# On mobile\n\n$x$");
  await page.getByRole("button", { name: "Preview", exact: true }).click();
  await expect(page.getByRole("heading", { name: "On mobile" })).toBeVisible();
});
