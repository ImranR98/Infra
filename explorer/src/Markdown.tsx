import React from "react";
import type { GraphNode } from "./types";

type Props = {
  text: string;
  nodes: Record<string, GraphNode>;
  onEntity?: (id: string) => void;
  compact?: boolean;
};

function renderInline(
  text: string,
  nodes: Record<string, GraphNode>,
  onEntity?: (id: string) => void,
  key = "i",
): React.ReactNode[] {
  const re = /(\[\[[^\]]+\]\]|`[^`]+`|\*\*[^*]+\*\*|\[[^\]]+\]\([^)]+\))/g;
  const out: React.ReactNode[] = [];
  let last = 0;
  let m: RegExpExecArray | null;
  let i = 0;
  while ((m = re.exec(text))) {
    if (m.index > last) out.push(text.slice(last, m.index));
    const token = m[0];
    if (token.startsWith("[[") && token.endsWith("]]")) {
      const id = token.slice(2, -2).trim();
      const node = nodes[id];
      out.push(
        <button
          key={`${key}-e${i++}`}
          type="button"
          className="md-entity"
          onClick={() => onEntity?.(id)}
          title={node ? node.title : id}
        >
          {node ? node.title : id}
        </button>,
      );
    } else if (token.startsWith("`")) {
      out.push(<code key={`${key}-c${i++}`}>{token.slice(1, -1)}</code>);
    } else if (token.startsWith("**")) {
      out.push(<strong key={`${key}-b${i++}`}>{token.slice(2, -2)}</strong>);
    } else {
      const lm = token.match(/^\[([^\]]+)\]\(([^)]+)\)$/);
      if (lm) {
        out.push(
          <a key={`${key}-a${i++}`} href={lm[2]} target="_blank" rel="noreferrer">
            {lm[1]}
          </a>,
        );
      } else {
        out.push(token);
      }
    }
    last = re.lastIndex;
  }
  if (last < text.length) out.push(text.slice(last));
  return out;
}

export function Markdown({ text, nodes, onEntity, compact }: Props) {
  const lines = text.replace(/\r/g, "").split("\n");
  const blocks: React.ReactNode[] = [];
  let i = 0;
  let key = 0;

  const isList = (l: string) => /^\s*[-*]\s+/.test(l);
  const isOrdered = (l: string) => /^\s*\d+\.\s+/.test(l);

  while (i < lines.length) {
    const line = lines[i];
    if (!line.trim()) {
      i++;
      continue;
    }
    if (line.trim().startsWith("```")) {
      const lang = line.trim().slice(3).trim();
      const code: string[] = [];
      i++;
      while (i < lines.length && !lines[i].trim().startsWith("```")) {
        code.push(lines[i]);
        i++;
      }
      i++;
      blocks.push(
        <pre className="md-code" key={key++}>
          <code data-lang={lang}>{code.join("\n")}</code>
        </pre>,
      );
      continue;
    }
    const h = line.match(/^(#{1,4})\s+(.+)$/);
    if (h) {
      const level = h[1].length;
      const Tag = (`h${Math.min(level + 1, 5)}` as keyof React.JSX.IntrinsicElements);
      blocks.push(React.createElement(Tag, { key: key++ }, renderInline(h[2], nodes, onEntity, `h${key}`)));
      i++;
      continue;
    }
    if (/^\s*>\s?/.test(line)) {
      const quote: string[] = [];
      while (i < lines.length && /^\s*>\s?/.test(lines[i])) {
        quote.push(lines[i].replace(/^\s*>\s?/, ""));
        i++;
      }
      blocks.push(
        <blockquote key={key++}>{renderInline(quote.join(" "), nodes, onEntity, `q${key}`)}</blockquote>,
      );
      continue;
    }
    if (isList(line)) {
      const items: string[] = [];
      while (i < lines.length && isList(lines[i])) {
        items.push(lines[i].replace(/^\s*[-*]\s+/, ""));
        i++;
      }
      blocks.push(
        <ul key={key++}>
          {items.map((item, n) => (
            <li key={n}>{renderInline(item, nodes, onEntity, `l${key}-${n}`)}</li>
          ))}
        </ul>,
      );
      continue;
    }
    if (isOrdered(line)) {
      const items: string[] = [];
      while (i < lines.length && isOrdered(lines[i])) {
        items.push(lines[i].replace(/^\s*\d+\.\s+/, ""));
        i++;
      }
      blocks.push(
        <ol key={key++}>
          {items.map((item, n) => (
            <li key={n}>{renderInline(item, nodes, onEntity, `o${key}-${n}`)}</li>
          ))}
        </ol>,
      );
      continue;
    }
    if (/^---+$/.test(line.trim())) {
      blocks.push(<hr key={key++} />);
      i++;
      continue;
    }
    const para: string[] = [line.trim()];
    i++;
    while (
      i < lines.length &&
      lines[i].trim() &&
      !/^(#{1,4})\s+/.test(lines[i]) &&
      !lines[i].trim().startsWith("```") &&
      !isList(lines[i]) &&
      !isOrdered(lines[i]) &&
      !/^\s*>\s?/.test(lines[i])
    ) {
      para.push(lines[i].trim());
      i++;
    }
    blocks.push(<p key={key++}>{renderInline(para.join(" "), nodes, onEntity, `p${key}`)}</p>);
  }

  return <div className={compact ? "markdown compact" : "markdown"}>{blocks}</div>;
}
