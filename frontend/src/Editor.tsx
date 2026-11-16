import { useEffect, useRef } from "react";
import CodeMirror, { type ReactCodeMirrorRef } from "@uiw/react-codemirror";
import { markdown } from "@codemirror/lang-markdown";
import { EditorSelection, Prec } from "@codemirror/state";
import { EditorView, keymap } from "@codemirror/view";
import { HighlightStyle, syntaxHighlighting } from "@codemirror/language";
import { AbbreviationProvider } from "@leanprover/unicode-input";
import { tags } from "@lezer/highlight";

const abbreviations = new AbbreviationProvider({
  abbreviationCharacter: "\\",
  customTranslations: {},
  eagerReplacementEnabled: false,
}).getSymbolsByAbbreviation();

function expandAbbreviation(view: EditorView, delimiter: string) {
  if (view.composing) return false;

  const { state } = view;
  let expanded = false;
  const changes = state.changeByRange((range) => {
    const line = state.doc.lineAt(range.from);
    const prefix = line.text.slice(0, range.from - line.from);
    const abbreviation = /(?:^|[^\\])(?:\\\\)*\\([^\\\s]+)$/.exec(prefix)?.[1];

    if (
      range.empty &&
      abbreviation &&
      Object.hasOwn(abbreviations, abbreviation)
    ) {
      const symbol = abbreviations[abbreviation];
      const from = range.from - abbreviation.length - 1;
      const cursor = symbol.indexOf("$CURSOR");
      const insert = symbol.replace("$CURSOR", "") + delimiter;
      expanded = true;
      return {
        changes: { from, to: range.to, insert },
        range: EditorSelection.cursor(
          from + (cursor < 0 ? insert.length : cursor),
        ),
      };
    }

    if (!delimiter) return { range };
    return {
      changes: { from: range.from, to: range.to, insert: delimiter },
      range: EditorSelection.cursor(range.from + delimiter.length),
    };
  });

  if (!expanded) return false;
  view.dispatch({ ...changes, userEvent: "input.type", scrollIntoView: true });
  return true;
}

const theme = EditorView.theme(
  {
    "&": { height: "100%", background: "transparent", color: "#374151" },
    ".cm-scroller": {
      fontFamily: "'SFMono-Regular', Consolas, 'Liberation Mono', monospace",
      fontSize: "13px",
      lineHeight: "1.75",
      overflow: "auto",
    },
    ".cm-content": { padding: "28px 0 48px", caretColor: "#3b5d83" },
    ".cm-line": { paddingLeft: "12px", paddingRight: "32px" },
    ".cm-gutters": {
      background: "transparent",
      border: "none",
      color: "#929ba8",
      paddingLeft: "12px",
      fontSize: "11px",
    },
    ".cm-gutterElement": { paddingRight: "8px", minWidth: "32px" },
    ".cm-activeLineGutter": { background: "transparent", color: "#475569" },
    ".cm-activeLine": { background: "transparent" },
    "&.cm-focused .cm-activeLine": { background: "#edf1f6" },
    ".cm-cursor": { borderLeftColor: "#3b5d83" },
    "&.cm-focused .cm-selectionBackground, .cm-selectionBackground": {
      background: "#dbe6f3",
    },
    ".cm-foldPlaceholder": {
      background: "#e9edf2",
      border: "none",
      color: "#62748b",
    },
    ".cm-searchMatch": { background: "#f6e9b3" },
    ".cm-panels": { background: "#f1f3f6", color: "#374151" },
    "&.cm-focused": { outline: "none" },
  },
  { dark: false },
);

const highlight = HighlightStyle.define([
  { tag: tags.heading, color: "#334b65", fontWeight: "600" },
  { tag: tags.processingInstruction, color: "#7c8797" },
  { tag: tags.monospace, color: "#4b685d" },
  { tag: tags.link, color: "#3d6591" },
  { tag: tags.quote, color: "#6e7c8e", fontStyle: "italic" },
  { tag: tags.strong, color: "#273546", fontWeight: "600" },
  { tag: tags.emphasis, color: "#685f7a", fontStyle: "italic" },
]);

const extensions = [
  markdown(),
  Prec.high(
    keymap.of([
      { key: "Space", run: (view) => expandAbbreviation(view, " ") },
      { key: "Tab", run: (view) => expandAbbreviation(view, "") },
    ]),
  ),
  EditorView.lineWrapping,
  theme,
  syntaxHighlighting(highlight),
  EditorView.contentAttributes.of({
    "aria-label": "Markdown source",
    spellcheck: "false",
  }),
];

export interface SelectionRequest {
  start: number;
  end: number;
  request: number;
}

export function Editor({
  source,
  onChange,
  selection,
}: {
  source: string;
  onChange: (source: string) => void;
  selection?: SelectionRequest;
}) {
  const editor = useRef<ReactCodeMirrorRef>(null);
  useEffect(() => {
    const view = editor.current?.view;
    if (!view || !selection) return;
    const anchor = Math.min(selection.start, view.state.doc.length);
    const head = Math.min(
      Math.max(selection.end, anchor),
      view.state.doc.length,
    );
    view.dispatch({ selection: { anchor, head }, scrollIntoView: true });
    view.focus();
  }, [selection]);
  return (
    <CodeMirror
      ref={editor}
      value={source}
      height="100%"
      className="source-editor"
      extensions={extensions}
      theme="none"
      onChange={onChange}
      basicSetup={{
        lineNumbers: true,
        foldGutter: false,
        highlightActiveLine: true,
        highlightSelectionMatches: false,
        autocompletion: false,
      }}
    />
  );
}
