import { example } from "./example";
import type { ModuleSource } from "./preview/protocol";

export interface Draft {
  source: string;
  modules: ModuleSource[];
  name: string;
}
const key = "unicode-inference.draft.v1";

export function loadDraft(): Draft {
  try {
    const saved: unknown = JSON.parse(localStorage.getItem(key) ?? "null");
    if (
      saved &&
      typeof saved === "object" &&
      "source" in saved &&
      typeof saved.source === "string" &&
      "name" in saved &&
      typeof saved.name === "string" &&
      "modules" in saved &&
      Array.isArray(saved.modules)
    ) {
      const modules = saved.modules.filter((entry): entry is ModuleSource =>
        Boolean(
          entry &&
          typeof entry === "object" &&
          typeof entry.path === "string" &&
          typeof entry.source === "string",
        ),
      );
      return { source: saved.source, name: saved.name, modules };
    }
  } catch {
    /* Storage is optional in private or restricted browsing sessions. */
  }
  return { source: example, name: "example.md", modules: [] };
}

export function saveDraft(draft: Draft): void {
  try {
    localStorage.setItem(key, JSON.stringify(draft));
  } catch {
    /* Editing and previewing still work if browser storage is unavailable. */
  }
}
