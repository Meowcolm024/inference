import { posix } from "node:path";
import type { Item, ModuleSource } from "./protocol";

export interface LoadedModules {
  modules: ModuleSource[];
  dependencies: Set<string>;
}

// The root is the same virtual project root used by wasm/Preview.hs.
export function modulePath(
  importer: string | undefined,
  requested: string,
): string | undefined {
  if (posix.isAbsolute(requested) || requested.includes("\0")) return undefined;
  const path = posix.normalize(
    posix.join(importer ? posix.dirname(importer) : "", requested),
  );
  if (path === ".." || path.startsWith("../") || path === ".") return undefined;
  return path;
}

export async function loadModules(
  items: Item[],
  read: (path: string) => Promise<string | undefined>,
): Promise<LoadedModules> {
  const modules: ModuleSource[] = [];
  const dependencies = new Set<string>();
  const visit = async (source: string, importer?: string): Promise<void> => {
    for (const line of source.split(/\r?\n/)) {
      const requested = /^\s*import\s+"([^"\0\r]+)"\s*$/.exec(line)?.[1];
      if (!requested) continue;
      const path = modulePath(importer, requested);
      if (!path || dependencies.has(path)) continue;
      dependencies.add(path);
      const body = await read(path);
      if (body === undefined) continue; // Let Haskell locate the missing import.
      modules.push({ path, source: body });
      await visit(body, path);
    }
  };
  for (const item of items)
    if (item.kind === "notation") await visit(item.source);
  return { modules, dependencies };
}
