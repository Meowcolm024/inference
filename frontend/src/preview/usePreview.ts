import { useEffect, useRef, useState } from "react";
import { PreviewClient } from "./client";
import type { ModuleSource, PreviewContent, PreviewIssue } from "./protocol";

export interface PreviewState extends PreviewContent {
  status: "loading" | "ok" | "invalid" | "error";
  issues: PreviewIssue[];
  message: string;
  stale: boolean;
}

const emptyContent: PreviewContent = { html: "", latexByKey: new Map() };

export function usePreview(
  source: string,
  modules: ModuleSource[],
  documentId: string,
): PreviewState {
  const [state, setState] = useState<PreviewState>({
    status: "loading",
    ...emptyContent,
    issues: [],
    message: "",
    stale: false,
  });
  const client = useRef<PreviewClient | null>(null);
  const revision = useRef(0);
  const lastGood = useRef<PreviewContent | null>(null);
  const previousDocument = useRef(documentId);

  useEffect(() => {
    client.current = new PreviewClient();
    return () => {
      client.current?.dispose();
      client.current = null;
    };
  }, []);

  useEffect(() => {
    const current = ++revision.current;
    const changedDocument = documentId !== previousDocument.current;
    previousDocument.current = documentId;
    if (changedDocument) lastGood.current = null;
    setState((previous) => ({
      ...previous,
      status: "loading",
      ...(changedDocument ? emptyContent : {}),
      issues: [],
      message: "",
    }));
    const timer = setTimeout(() => {
      void client.current
        ?.compile({ revision: current, source, modules })
        .then((response) => {
          if (!response || current !== revision.current) return;
          if (response.status === "ok") {
            const content = {
              html: response.html,
              latexByKey: response.latexByKey,
            };
            lastGood.current = content.html ? content : null;
            setState({
              status: "ok",
              ...content,
              issues: [],
              message: "",
              stale: false,
            });
          } else if (response.status === "invalid") {
            setState({
              status: "invalid",
              ...(lastGood.current ?? { ...emptyContent, html: response.html }),
              issues: response.issues,
              message: "",
              stale: Boolean(lastGood.current),
            });
          } else {
            setState({
              status: "error",
              ...(lastGood.current ?? emptyContent),
              issues: [],
              message: response.message,
              stale: Boolean(lastGood.current),
            });
          }
        })
        .catch((error) => {
          if (current === revision.current)
            setState({
              status: "error",
              ...(lastGood.current ?? emptyContent),
              issues: [],
              message: String(error),
              stale: Boolean(lastGood.current),
            });
        });
    }, 150);
    return () => {
      clearTimeout(timer);
      revision.current++;
    };
  }, [source, modules, documentId]);

  return state;
}
