import { useEffect, useRef, useState } from "react";
import { PreviewClient } from "./client";
import type { ModuleSource, PreviewIssue } from "./protocol";

export interface PreviewState {
  status: "loading" | "ok" | "invalid" | "error";
  html: string;
  issues: PreviewIssue[];
  message: string;
  stale: boolean;
}

export function usePreview(
  source: string,
  modules: ModuleSource[],
  documentId: string,
): PreviewState {
  const [state, setState] = useState<PreviewState>({
    status: "loading",
    html: "",
    issues: [],
    message: "",
    stale: false,
  });
  const client = useRef<PreviewClient | null>(null);
  const revision = useRef(0);
  const lastGood = useRef("");
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
    if (changedDocument) lastGood.current = "";
    setState((previous) => ({
      ...previous,
      status: "loading",
      html: changedDocument ? "" : previous.html,
      issues: [],
      message: "",
    }));
    const timer = setTimeout(() => {
      void client.current
        ?.compile({ revision: current, source, modules })
        .then((response) => {
          if (!response || current !== revision.current) return;
          if (response.status === "ok") {
            lastGood.current = response.html;
            setState({
              status: "ok",
              html: response.html,
              issues: [],
              message: "",
              stale: false,
            });
          } else if (response.status === "invalid") {
            setState({
              status: "invalid",
              html: lastGood.current || response.html,
              issues: response.issues,
              message: "",
              stale: Boolean(lastGood.current),
            });
          } else {
            setState({
              status: "error",
              html: lastGood.current,
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
              html: lastGood.current,
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
