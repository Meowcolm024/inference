import MarkdownIt, { type Token } from "markdown-it";
import type {
  AdapterDiagnostic,
  Attributes,
  Item,
  MappedSource,
  SourcePosition,
} from "./protocol";

interface InferenceMeta extends Record<string, unknown> {
  key?: string;
  kind?: Item["kind"];
  attr?: Attributes;
  inlineOffsets?: number[];
  attributeStart?: number;
  error?: string;
  line?: number;
}

export interface MarkdownDocument {
  items: Item[];
  sources: Map<string, MappedSource>;
  diagnostics: AdapterDiagnostic[];
  render(fragments: { key: string; html: string }[]): string;
}

type ParsedAttributes = { attr: Attributes; end: number } | { error: string };

// Preserve ordered pairs (including duplicates) for the Haskell option parser.
export function parseAttributes(input: string, start = 0): ParsedAttributes {
  const attr: Attributes = { id: "", classes: [], pairs: [] };
  let pos = start;
  if (input[pos++] !== "{")
    return { error: "Expected an attribute list enclosed in braces." };
  while (pos < input.length) {
    while (/\s/.test(input[pos] ?? "") && pos < input.length) pos++;
    if (input[pos] === "}") return { attr, end: pos + 1 };
    const marker = input[pos];
    if (marker === "." || marker === "#") {
      const name = /^[^\s{}=]+/.exec(input.slice(++pos))?.[0];
      if (!name)
        return { error: "Expected a name after the attribute marker." };
      pos += name.length;
      if (marker === ".") attr.classes.push(name);
      else attr.id = name;
      continue;
    }
    const name = /^[^\s{}=]+/.exec(input.slice(pos))?.[0];
    if (!name)
      return {
        error: "Expected a class, identifier, or name=value attribute.",
      };
    pos += name.length;
    if (input[pos++] !== "=") return { error: `Expected '=' after '${name}'.` };
    let value = "";
    const quote = input[pos];
    if (quote === '"' || quote === "'") {
      pos++;
      while (pos < input.length && input[pos] !== quote) {
        if (
          input[pos] === "\\" &&
          (input[pos + 1] === quote || input[pos + 1] === "\\")
        )
          pos++;
        value += input[pos++];
      }
      if (input[pos++] !== quote)
        return { error: `Unclosed quoted value for '${name}'.` };
    } else {
      value = /^[^\s{}]+/.exec(input.slice(pos))?.[0] ?? "";
      pos += value.length;
      if (!value) return { error: `Expected a value for '${name}'.` };
    }
    attr.pairs.push([name, value]);
  }
  return { error: "Unclosed inference attribute list." };
}

function classify(attr: Attributes): Item["kind"] | undefined {
  if (attr.classes.includes("inference-notation")) return "notation";
  if (attr.classes.includes("inference")) return "block";
  return undefined;
}

function inferenceInfo(info: string): ParsedAttributes | undefined {
  const trimmed = info.trim();
  if (trimmed.startsWith("{=")) return undefined;
  const bare = /^(inference(?:-notation)?)(?=\s|$)/.exec(trimmed);
  const attributes = bare ? trimmed.slice(bare[0].length).trim() : trimmed;
  if (
    !bare &&
    !/(?:^|[\s{])\.inference(?:-notation)?(?=[\s}]|$)/.test(attributes)
  )
    return undefined;
  if (bare && !attributes)
    return {
      attr: { id: "", classes: [bare[1]], pairs: [] },
      end: info.length,
    };
  const parsed = parseAttributes(attributes);
  if ("error" in parsed) return parsed;
  if (attributes.slice(parsed.end).trim())
    return { error: "Unexpected text after inference attributes." };
  if (bare) parsed.attr.classes.unshift(bare[1]);
  return parsed;
}

function normalize(input: string): MappedSource {
  let text = "";
  const offsets: number[] = [];
  for (let pos = 0; pos < input.length; pos++) {
    offsets.push(pos);
    if (input[pos] === "\r") {
      text += "\n";
      if (input[pos + 1] === "\n") pos++;
    } else text += input[pos] === "\0" ? "\uFFFD" : input[pos];
  }
  offsets.push(input.length);
  return { text, offsets };
}

// Markdown strips quote/list prefixes, fence indentation, and heading markers.
// Match each logical line to its physical line before converting to UTF-16.
function mapLines(
  content: string,
  source: MappedSource,
  firstLine: number,
  lastLine: number,
): MappedSource {
  const physical = source.text.split("\n");
  const starts: number[] = [];
  let offset = 0;
  for (const line of physical) {
    starts.push(offset);
    offset += line.length + 1;
  }
  const offsets: number[] = [];
  let lineNumber = firstLine;
  let end = starts[firstLine] ?? source.text.length;
  const logical = content.split("\n");
  for (let index = 0; index < logical.length; index++) {
    const line = logical[index];
    const raw = physical[lineNumber] ?? "";
    let column = raw.lastIndexOf(line);
    if (column < 0) {
      // A tab partially removed by a container can become leading spaces.
      const body = line.trimStart();
      column = Math.max(0, raw.lastIndexOf(body)) - (line.length - body.length);
    }
    for (let char = 0; char < line.length; char++) {
      const original =
        (starts[lineNumber] ?? source.text.length) + Math.max(0, column + char);
      offsets.push(
        source.offsets[original] ?? source.offsets[source.text.length],
      );
    }
    end = Math.min(
      source.text.length,
      (starts[lineNumber] ?? source.text.length) +
        Math.max(0, column + line.length),
    );
    if (index < logical.length - 1) offsets.push(source.offsets[end]);
    lineNumber = Math.min(lineNumber + 1, lastLine);
  }
  offsets.push(source.offsets[end] ?? source.offsets[source.text.length]);
  return { text: content, offsets };
}

export function sourceOffset(
  source: MappedSource,
  position: SourcePosition,
): number {
  const lines = source.text.split("\n");
  const lineIndex = Math.max(0, Math.min(position.line - 1, lines.length - 1));
  let offset = 0;
  for (let line = 0; line < lineIndex; line++) offset += lines[line].length + 1;
  offset += Array.from(lines[lineIndex])
    .slice(0, Math.max(0, position.column - 1))
    .join("").length;
  return source.offsets[Math.min(offset, source.offsets.length - 1)] ?? 0;
}

// Table cells have no token.map. Locate them from left to right within the
// row, retaining the source backslash for a pipe escaped by Markdown's table rule.
function mapTableCell(
  content: string,
  source: MappedSource,
  line: number,
  from: number,
): { mapped: MappedSource; next: number } {
  const lines = source.text.split("\n");
  const raw = lines[line] ?? "";
  const start = lines
    .slice(0, line)
    .reduce((offset, text) => offset + text.length + 1, 0);
  let unescaped = "";
  const columns: number[] = [];
  for (let column = 0; column < raw.length; column++) {
    if (raw[column] === "\\" && raw[column + 1] === "|") column++;
    columns.push(column);
    unescaped += raw[column];
  }
  columns.push(raw.length);
  const searchFrom = columns.findIndex((column) => column >= from);
  const found = unescaped.indexOf(content, Math.max(0, searchFrom));
  if (found < 0)
    return { mapped: mapLines(content, source, line, line), next: raw.length };
  return {
    mapped: {
      text: content,
      offsets: columns
        .slice(found, found + content.length + 1)
        .map((column) => source.offsets[start + column]),
    },
    next: columns[found + content.length],
  };
}

export function escapeHtml(value: string): string {
  return value.replace(
    /[&<>"']/g,
    (char) =>
      ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[
        char
      ]!,
  );
}

export function parseMarkdown(
  input: string,
  configure?: (markdown: InstanceType<typeof MarkdownIt>) => void,
): MarkdownDocument {
  const source = normalize(input);
  const md = new MarkdownIt({ html: false, linkify: false });
  configure?.(md);
  md.inline.ruler.before("backticks", "inference_code", (state, silent) => {
    const start = state.pos;
    if (state.src[start] !== "`") return false;
    const marker = /^`+/.exec(state.src.slice(start))![0];
    let close = start + marker.length;
    let found = false;
    while (
      (close = state.src.indexOf("`", close)) >= 0 &&
      close < state.posMax
    ) {
      const run = /^`+/.exec(state.src.slice(close))![0];
      if (run.length === marker.length) {
        found = true;
        break;
      }
      close += run.length;
    }
    if (!found) return false;
    const after = close + marker.length;
    if (state.src[after] !== "{") return false;
    const rest = state.src.slice(after, state.posMax);
    if (!/^[^}\n]*\.inference(?=[\s}]|$)/.test(rest)) return false;
    const parsed = parseAttributes(state.src, after);
    if (silent) return false;
    const token = state.push("code_inline", "code", 0);
    const raw = state.src.slice(start + marker.length, close);
    let content = raw.replace(/\n/g, " ");
    let trim = 0;
    if (/^ .* $/.test(content) && /[^ ]/.test(content)) {
      content = content.slice(1, -1);
      trim = 1;
    }
    token.content = content;
    token.markup = marker;
    token.meta = {
      inlineOffsets: Array.from(
        { length: content.length + 1 },
        (_, index) => start + marker.length + trim + index,
      ),
      attributeStart: after,
      ...("error" in parsed
        ? { error: parsed.error }
        : { attr: parsed.attr, kind: "inline" }),
    } satisfies InferenceMeta;
    state.pos = "error" in parsed ? after : parsed.end;
    return true;
  });

  const tokens = md.parse(source.text, {});
  const items: Item[] = [];
  const sources = new Map<string, MappedSource>();
  const diagnostics: AdapterDiagnostic[] = [];
  const add = (token: Token, meta: InferenceMeta, mapped: MappedSource) => {
    if (!meta.kind || !meta.attr) return;
    const key = `item-${items.length}`;
    meta.key = key;
    token.meta = meta;
    items.push({
      key,
      kind: meta.kind,
      attr: meta.attr,
      source: token.content,
    });
    sources.set(key, mapped);
  };
  let rowLine = 0;
  let rowColumn = 0;
  for (const token of tokens) {
    if (token.map) {
      rowLine = token.map[0];
      rowColumn = 0;
    }
    const [first, last] = token.map ?? [rowLine, rowLine + 1];
    if (token.type === "fence") {
      const parsed = inferenceInfo(token.info);
      if (!parsed) continue;
      if ("error" in parsed) {
        const opener = mapLines(
          source.text.split("\n")[first],
          source,
          first,
          first,
        );
        diagnostics.push({
          message: parsed.error,
          start: opener.offsets[0],
          end: opener.offsets.at(-1)!,
        });
      } else {
        add(
          token,
          { attr: parsed.attr, kind: classify(parsed.attr), line: first },
          mapLines(token.content, source, first + 1, last),
        );
      }
    }
    if (token.type === "inline") {
      const cell = token.map
        ? undefined
        : mapTableCell(token.content, source, rowLine, rowColumn);
      if (cell) rowColumn = cell.next;
      const parent =
        cell?.mapped ?? mapLines(token.content, source, first, last);
      for (const child of token.children ?? []) {
        const meta = child.meta as InferenceMeta | null;
        if (!meta?.inlineOffsets) continue;
        const mapped = {
          text: child.content,
          offsets: meta.inlineOffsets.map(
            (offset) => parent.offsets[offset] ?? parent.offsets.at(-1)!,
          ),
        };
        if (meta.error) {
          const start = parent.offsets[meta.attributeStart ?? 0];
          diagnostics.push({ message: meta.error, start, end: start + 1 });
        } else add(child, { ...meta, line: first }, mapped);
      }
    }
  }

  const fallbackRules = {
    fence: md.renderer.rules.fence!,
    code_inline: md.renderer.rules.code_inline!,
  };
  return {
    items,
    sources,
    diagnostics,
    render(fragments) {
      const rendered = new Map(
        fragments.map((fragment) => [fragment.key, fragment.html]),
      );
      for (const type of ["fence", "code_inline"] as const) {
        const fallback = fallbackRules[type];
        md.renderer.rules[type] = (all, index, options, env, self) => {
          const token = all[index];
          const meta = token.meta as InferenceMeta | null;
          if (meta?.kind === "notation") return "";
          const html = meta?.key ? rendered.get(meta.key) : undefined;
          if (html === undefined)
            return fallback(all, index, options, env, self);
          const tag = type === "fence" ? "div" : "span";
          const id = meta?.attr?.id ? ` id="${escapeHtml(meta.attr.id)}"` : "";
          const classes =
            meta?.attr?.classes
              .filter((name) => name !== "inference")
              .join(" ") ?? "";
          return `<${tag}${id} class="inference-${type === "fence" ? "block" : "inline"} ${escapeHtml(classes)}" data-source-line="${meta?.line ?? 0}">${html}</${tag}>`;
        };
      }
      return md.renderer.render(tokens, md.options, {});
    },
  };
}
