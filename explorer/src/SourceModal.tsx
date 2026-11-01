import React, { useEffect, useMemo, useRef, useState } from "react";
import { Check, Copy, FileCode2, X } from "lucide-react";
import hljs from "highlight.js/lib/core";
import bash from "highlight.js/lib/languages/bash";
import yaml from "highlight.js/lib/languages/yaml";
import json from "highlight.js/lib/languages/json";
import ini from "highlight.js/lib/languages/ini";
import dockerfile from "highlight.js/lib/languages/dockerfile";
import python from "highlight.js/lib/languages/python";
import xml from "highlight.js/lib/languages/xml";
import markdown from "highlight.js/lib/languages/markdown";
import javascript from "highlight.js/lib/languages/javascript";
import typescript from "highlight.js/lib/languages/typescript";
import plaintext from "highlight.js/lib/languages/plaintext";
import type { GraphNode } from "./types";

hljs.registerLanguage("bash", bash);
hljs.registerLanguage("yaml", yaml);
hljs.registerLanguage("json", json);
hljs.registerLanguage("ini", ini);
hljs.registerLanguage("dockerfile", dockerfile);
hljs.registerLanguage("python", python);
hljs.registerLanguage("xml", xml);
hljs.registerLanguage("markdown", markdown);
hljs.registerLanguage("javascript", javascript);
hljs.registerLanguage("typescript", typescript);
hljs.registerLanguage("plaintext", plaintext);

const cache = new Map<string, string>();

function languageFor(path: string) {
  const ext = path.split(".").pop()?.toLowerCase() || "";
  if (["sh", "bash"].includes(ext) || path.endsWith("Dockerfile")) return "bash";
  if (["yaml", "yml"].includes(ext)) return "yaml";
  if (ext === "json") return "json";
  if (["env", "conf", "service", "timer"].includes(ext)) return "ini";
  if (ext === "py") return "python";
  if (ext === "xml") return "xml";
  if (ext === "md") return "markdown";
  if (ext === "js" || ext === "mjs") return "javascript";
  if (ext === "ts" || ext === "tsx") return "typescript";
  return "plaintext";
}

export function SourceModal({ node, onClose }: { node: GraphNode; onClose: () => void }) {
  const [text, setText] = useState<string | null>(null);
  const shellRef = useRef<HTMLDivElement>(null);
  const [error, setError] = useState<string | null>(null);
  const [copied, setCopied] = useState(false);
  const lineRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    shellRef.current?.focus();
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") { e.stopPropagation(); onClose(); }
    };
    window.addEventListener("keydown", onKey, true);
    return () => window.removeEventListener("keydown", onKey, true);
  }, [onClose]);

  useEffect(() => {
    let alive = true;
    setText(null);
    setError(null);
    if (!node.source?.key) {
      setError("No source is attached to this node.");
      return;
    }
    const cached = cache.get(node.source.key);
    if (cached !== undefined) {
      setText(cached);
      return;
    }
    fetch(`${import.meta.env.BASE_URL}snippets/${node.source.key}.json`)
      .then((r) => {
        if (!r.ok) throw new Error(`HTTP ${r.status}`);
        const type = r.headers.get("content-type") || "";
        if (!type.includes("application/json")) {
          throw new Error("Source snippet is missing. Restart the dev server after regenerating the map, or rebuild the site.");
        }
        return r.json() as Promise<{ path: string; text: string }>;
      })
      .then((data) => {
        cache.set(node.source!.key, data.text);
        if (alive) setText(data.text);
      })
      .catch((e) => { if (alive) setError(String(e)); });
    return () => { alive = false; };
  }, [node.source?.key]);

  const rendered = useMemo(() => {
    if (text === null) return null;
    const lang = languageFor(node.source?.path || "");
    let html: string;
    try {
      html = hljs.highlight(text, { language: lang }).value;
    } catch {
      html = hljs.highlight(text, { language: "plaintext" }).value;
    }
    return html.split("\n");
  }, [text, node.source?.path]);

  useEffect(() => {
    if (lineRef.current) lineRef.current.scrollIntoView({ block: "center" });
  }, [rendered]);

  const copy = () => {
    if (!node.source) return;
    navigator.clipboard?.writeText(node.source.path).then(() => {
      setCopied(true);
      setTimeout(() => setCopied(false), 1200);
    });
  };

  const start = node.source?.line || 1;
  const end = node.source?.endLine || start;

  return (
    <div className="source-backdrop" onMouseDown={onClose}>
      <div
        ref={shellRef}
        className="source-modal"
        tabIndex={-1}
        onMouseDown={(e) => e.stopPropagation()}
        onKeyDown={(e) => { if (e.key === "Escape") { e.stopPropagation(); onClose(); } }}
      >
        <header className="source-head">
          <div className="source-title">
            <FileCode2 size={17} />
            <div>
              <strong>{node.source?.path || node.title}</strong>
              <span>lines {start}{end !== start ? `–${end}` : ""} · {node.kind}</span>
            </div>
          </div>
          <div className="source-actions">
            <button type="button" className="secondary-button small" onClick={copy}>
              {copied ? <Check size={14} /> : <Copy size={14} />} {copied ? "Copied" : "Copy path"}
            </button>
            <button type="button" className="icon-button" onClick={onClose} aria-label="Close source"><X size={17} /></button>
          </div>
        </header>
        <div className="source-body">
          {error ? <div className="source-error">{error}</div> : null}
          {!error && rendered === null ? <div className="source-loading">Loading source…</div> : null}
          {rendered ? (
            <div className="source-code">
              {rendered.map((line, i) => {
                const n = i + 1;
                const hot = n >= start && n <= end;
                return (
                  <div
                    key={n}
                    ref={n === start ? lineRef : undefined}
                    className={`source-line ${hot ? "hot" : ""}`}
                  >
                    <span className="source-ln">{n}</span>
                    <span className="source-text" dangerouslySetInnerHTML={{ __html: line || " " }} />
                  </div>
                );
              })}
            </div>
          ) : null}
        </div>
        <footer className="source-foot">
          <span>Rendered from the working tree at build time. Comments are part of the map.</span>
          <span>{rendered ? `${rendered.length} lines` : ""}</span>
        </footer>
      </div>
    </div>
  );
}
