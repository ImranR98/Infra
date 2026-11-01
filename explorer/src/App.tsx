import React, { useEffect, useState } from "react";
import { AlertTriangle, Boxes } from "lucide-react";
import type { Graph } from "./types";
import { TourApp } from "./TourApp";

export default function App() {
  const [graph, setGraph] = useState<Graph | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [theme, setTheme] = useState<"dark" | "light">(() => {
    const saved = localStorage.getItem("infra-explorer-theme");
    if (saved === "dark" || saved === "light") return saved;
    return "dark";
  });

  useEffect(() => {
    document.documentElement.dataset.theme = theme;
    localStorage.setItem("infra-explorer-theme", theme);
    document.querySelector('meta[name="theme-color"]')?.setAttribute("content", theme === "dark" ? "#0b0d10" : "#f4f5f7");
  }, [theme]);

  useEffect(() => {
    fetch(`${import.meta.env.BASE_URL}data/graph.json`)
      .then((r) => {
        if (!r.ok) throw new Error(`HTTP ${r.status} loading graph`);
        return r.json() as Promise<Graph>;
      })
      .then(setGraph)
      .catch((e) => setError(String(e)));
  }, []);

  if (error) {
    return (
      <div className="boot boot-error">
        <div className="boot-mark"><AlertTriangle size={22} /></div>
        <h1>Could not load the tours</h1>
        <p>{error}</p>
        <p className="muted">Run <code>npm --prefix explorer run map</code>, then reload.</p>
      </div>
    );
  }

  if (!graph) {
    return (
      <div className="boot">
        <div className="boot-mark"><Boxes size={22} /></div>
        <h1>Infra tours</h1>
        <p>Compiling the tours from the repo…</p>
        <div className="boot-line"><i /></div>
      </div>
    );
  }

  return (
    <TourApp
      graph={graph}
      theme={theme}
      onTheme={() => setTheme(theme === "dark" ? "light" : "dark")}
    />
  );
}
