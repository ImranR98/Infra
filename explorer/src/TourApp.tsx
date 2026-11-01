import React, { useEffect, useMemo, useRef, useState } from "react";
import {
  ArrowLeft,
  ArrowRight,
  BookOpen,
  Check,
  ChevronLeft,
  ChevronRight,
  Clock3,
  Code2,
  FileCode2,
  Moon,
  RotateCcw,
  Sun,
  X,
} from "lucide-react";
import type { Graph, GraphNode, Scene, StoryStep, TourSummary } from "./types";
import { Canvas } from "./Canvas";
import { Markdown } from "./Markdown";
import { SourceModal } from "./SourceModal";
import { iconFor } from "./icons";

type Props = {
  graph: Graph;
  theme: "dark" | "light";
  onTheme: () => void;
};

const progressKey = "infra-explorer-tour-progress";
const completeKey = "infra-explorer-tour-complete";

function readProgress(): Record<string, number> {
  try { return JSON.parse(localStorage.getItem(progressKey) || "{}"); } catch { return {}; }
}
function readComplete(): string[] {
  try { const v = JSON.parse(localStorage.getItem(completeKey) || "[]"); return Array.isArray(v) ? v : []; } catch { return []; }
}
function writeProgress(p: Record<string, number>) { localStorage.setItem(progressKey, JSON.stringify(p)); }
function writeComplete(c: string[]) { localStorage.setItem(completeKey, JSON.stringify(c)); }

function sceneForChapter(chapter: StoryStep, tourId: string): Scene {
  return {
    id: `tour-${tourId}-${chapter.id}`,
    title: chapter.title,
    subtitle: chapter.stage,
    kind: "tour",
    nodes: chapter.visibleNodes,
    edges: chapter.edges,
    zones: chapter.zones,
    width: chapter.width,
    height: chapter.height,
  };
}

function TourTopBar({
  tour, step, index, total, theme, onTheme, onLibrary, onRestart,
}: {
  tour: TourSummary; step: StoryStep; index: number; total: number; theme: "dark" | "light";
  onTheme: () => void; onLibrary: () => void; onRestart: () => void;
}) {
  return (
    <header className="topbar story-topbar">
      <div className="topbar-left">
        <button type="button" className="icon-button" onClick={onLibrary} aria-label="Back to tours"><ChevronLeft size={17} /></button>
        <span className="story-mark"><BookOpen size={16} /></span>
        <div className="brand-text">
          <strong className="story-title-full">{tour.title}</strong>
          <strong className="story-title-short">{tour.title}</strong>
          <em>{tour.subtitle || "guided tour"}</em>
        </div>
      </div>
      <div className="story-topbar-progress">
        <span>{index + 1} / {total}</span>
        <div className="story-progress-track"><i style={{ width: `${((index + 1) / total) * 100}%` }} /></div>
        <span>{step.stage}</span>
      </div>
      <div className="topbar-actions">
        <button type="button" className="icon-button" onClick={onRestart} aria-label="Restart this tour" title="Restart tour"><RotateCcw size={16} /></button>
        <button type="button" className="icon-button" onClick={onTheme} aria-label="Toggle theme">
          {theme === "dark" ? <Sun size={16} /> : <Moon size={16} />}
        </button>
      </div>
    </header>
  );
}

function TourRail({ chapters, current, onJump }: { chapters: StoryStep[]; current: number; onJump: (i: number) => void }) {
  return (
    <aside className="story-rail">
      <div className="story-rail-kicker">This tour</div>
      <div className="story-chapters">
        {chapters.map((s, i) => {
          const done = i < current;
          return (
            <button key={s.id} type="button" className={`story-chapter ${i === current ? "active" : ""} ${done ? "done" : ""}`} disabled={i > current} onClick={() => onJump(i)}>
              <span className="story-chapter-num">{done ? <Check size={12} /> : i + 1}</span>
              <span className="story-chapter-text"><strong>{s.title}</strong><em>{s.stage}</em></span>
            </button>
          );
        })}
      </div>
      <div className="story-rail-note">
        <ChevronRight size={11} /> Continue to advance.
      </div>
    </aside>
  );
}

function CodeExplained({ chapter, onSource }: { chapter: StoryStep; onSource: (n: GraphNode) => void }) {
  if (!chapter.code.length) return null;
  return (
    <section className="story-code">
      <div className="story-code-head"><Code2 size={14} /> Code explained</div>
      {chapter.code.map((c) => (
        <button key={c.path} type="button" className="story-code-row" onClick={() => onSource({
          id: `code:${c.path}`,
          kind: "file",
          title: c.path,
          subtitle: c.summary,
          tags: [],
          badges: [],
          facts: [],
          source: c.source,
        })}>
          <span className="story-code-icon"><FileCode2 size={14} /></span>
          <span className="story-code-text">
            <strong>{c.path}</strong>
            <em>{c.summary || "Source for this chapter."}</em>
          </span>
          <ChevronRight size={13} />
        </button>
      ))}
    </section>
  );
}

function NodeDefinition({ node, onSource }: { node: GraphNode; onSource: (n: GraphNode) => void }) {
  const Icon = iconFor(node.kind);
  return (
    <div className="story-definition">
      <div className="story-definition-head">
        <span className={`panel-icon kind-${node.kind}`}><Icon size={16} /></span>
        <div><strong>{node.title}</strong><em>{node.subtitle}</em></div>
      </div>
      {node.summary ? <p className="story-definition-summary">{node.summary}</p> : null}
      {node.facts.length ? (
        <dl className="facts story-facts">
          {node.facts.slice(0, 6).map((f, i) => (
            <div key={`${f.label}-${i}`} className="fact-row"><dt>{f.label}</dt><dd className={f.mono ? "mono" : ""}>{f.value}</dd></div>
          ))}
        </dl>
      ) : null}
      {node.source ? (
        <div className="story-definition-actions">
          <button type="button" className="secondary-button small" onClick={() => onSource(node)}><FileCode2 size={14} /> Open source</button>
        </div>
      ) : null}
    </div>
  );
}

function ChapterPanel({
  graph, step, index, total, selected, onSelect, onBack, onNext, onSource, onFinish,
}: {
  graph: Graph; step: StoryStep; index: number; total: number; selected: GraphNode | null;
  onSelect: (id: string | null) => void; onBack: () => void; onNext: () => void;
  onSource: (n: GraphNode) => void; onFinish: () => void;
}) {
  const ref = useRef<HTMLDivElement>(null);
  const selectedRef = useRef<HTMLDivElement>(null);
  useEffect(() => { ref.current?.scrollTo({ top: 0 }); }, [step.id]);
  useEffect(() => { if (selected) selectedRef.current?.scrollIntoView({ block: "nearest", behavior: "smooth" }); }, [selected?.id]);
  const last = index === total - 1;
  return (
    <aside className="panel story-panel" ref={ref}>
      <div className="story-panel-scroll">
        <div className="story-kicker">Chapter {index + 1} · {step.stage}</div>
        <h2>{step.title}</h2>
        <div className="story-body prose"><Markdown text={step.body} nodes={graph.nodes} /></div>
        {step.reveal.length ? (
          <div className="story-new">
            <div className="story-new-label">New in this chapter</div>
            <div className="story-new-chips">
              {step.reveal.map((id) => {
                const n = graph.nodes[id];
                if (!n) return null;
                const Icon = iconFor(n.kind);
                return <button key={id} type="button" className={`story-chip kind-${n.kind}`} onClick={() => onSelect(id)}><Icon size={13} /> {n.title}</button>;
              })}
            </div>
          </div>
        ) : null}
        <CodeExplained chapter={step} onSource={onSource} />
        {step.deepDive ? (
          <details className="story-deep">
            <summary>Go deeper</summary>
            <div className="prose"><Markdown text={step.deepDive} nodes={graph.nodes} /></div>
          </details>
        ) : null}
        {selected ? (
          <div className="story-selected" ref={selectedRef}>
            <div className="story-selected-head"><span>Selected node</span><button type="button" className="icon-button" onClick={() => onSelect(null)} aria-label="Clear selection"><X size={14} /></button></div>
            <NodeDefinition node={selected} onSource={onSource} />
          </div>
        ) : <p className="story-click-hint">Click a card to inspect it. Continue to advance.</p>}
      </div>
      <div className="story-panel-footer">
        <button type="button" className="secondary-button" onClick={onBack}><ArrowLeft size={15} /> Back</button>
        <span className="story-step-count">{index + 1} / {total}</span>
        {last ? (
          <button type="button" className="primary-button" onClick={onFinish}>Finish tour <Check size={15} /></button>
        ) : (
          <button type="button" className="primary-button" onClick={onNext}>Continue <ArrowRight size={15} /></button>
        )}
      </div>
    </aside>
  );
}

function TourLibrary({
  graph, progress, complete, onStart, theme, onTheme,
}: {
  graph: Graph; progress: Record<string, number>; complete: string[];
  onStart: (tour: TourSummary) => void; theme: "dark" | "light"; onTheme: () => void;
}) {
  const story = graph.story!;
  return (
    <div className="tour-library">
      <header className="tour-library-top">
        <div className="story-cover-brand"><span className="brand-mark"><i /><i /><i /></span><span>Infra tours</span></div>
        <button type="button" className="icon-button" onClick={onTheme} aria-label="Toggle theme">{theme === "dark" ? <Sun size={16} /> : <Moon size={16} />}</button>
      </header>
      <main className="tour-library-main">
        <div className="tour-library-kicker">Guided tours</div>
        <h1>{story.title}</h1>
        <p className="tour-library-intro">{story.subtitle} Pick a tour and use Continue to advance. The recommended tour covers the full request path; the others go deeper on one layer.</p>
        <div className="tour-grid">
          {story.tours.map((tour) => {
            const idx = progress[tour.id] ?? 0;
            const done = complete.includes(tour.id);
            const started = idx > 0;
            return (
              <button key={tour.id} type="button" className={`tour-card ${tour.recommended ? "recommended" : ""}`} onClick={() => onStart(tour)}>
                <div className="tour-card-top">
                  <span className="tour-card-icon"><BookOpen size={16} /></span>
                  <span className="tour-card-meta">
                    {tour.recommended ? <span className="tour-recommended">Recommended</span> : null}
                    <span className="tour-card-duration"><Clock3 size={12} /> {tour.duration}</span>
                  </span>
                </div>
                <div className="tour-card-title">{tour.title}</div>
                <div className="tour-card-sub">{tour.subtitle}</div>
                <p>{tour.description}</p>
                <div className="tour-card-foot">
                  <span>{tour.chapters.length} chapters</span>
                  {done ? <span className="tour-done"><RotateCcw size={11} /> Replay</span> : started ? <span className="tour-resume">Resume · {idx + 1}/{tour.chapters.length}</span> : <span>Start <ChevronRight size={12} /></span>}
                </div>
                {started && !done ? <div className="tour-card-progress"><i style={{ width: `${(idx / tour.chapters.length) * 100}%` }} /></div> : null}
              </button>
            );
          })}
        </div>
      </main>
    </div>
  );
}

export function TourApp({ graph, theme, onTheme }: Props) {
  const story = graph.story;
  if (!story) return null;
  const [active, setActive] = useState<string | null>(null);
  const [index, setIndex] = useState(0);
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [sourceNode, setSourceNode] = useState<GraphNode | null>(null);
  const [progress, setProgress] = useState<Record<string, number>>(readProgress);
  const [complete, setComplete] = useState<string[]>(readComplete);
  const [focusToken] = useState(0);

  const chapterMap = useMemo(() => new Map(story.steps.map((s) => [s.id, s])), [story.steps]);
  const tour = active ? story.tours.find((t) => t.id === active) : null;
  const chapters = tour ? tour.chapters.map((id) => chapterMap.get(id)).filter(Boolean) as StoryStep[] : [];
  const step = active ? chapters[index] : null;
  const selected = selectedId ? graph.nodes[selectedId] || null : null;
  const scene = useMemo(() => step && tour ? sceneForChapter(step, tour.id) : null, [step, tour]);

  const save = (tourId: string, i: number) => {
    const next = { ...progress, [tourId]: i };
    setProgress(next); writeProgress(next);
  };
  const start = (t: TourSummary) => {
    const i = complete.includes(t.id) ? 0 : progress[t.id] ?? 0;
    setActive(t.id); setIndex(Math.min(i, t.chapters.length - 1)); setSelectedId(null);
    history.pushState({}, "", `#/tour/${t.id}/${Math.min(i, t.chapters.length - 1) + 1}`);
  };
  const go = (i: number) => {
    if (!tour || !chapters.length) return;
    const next = Math.max(0, Math.min(chapters.length - 1, i));
    setIndex(next); setSelectedId(null); save(tour.id, next);
    history.pushState({}, "", `#/tour/${tour.id}/${next + 1}`);
  };
  const library = () => { setActive(null); setSelectedId(null); history.pushState({}, "", "#/tours"); };
  const finish = () => {
    if (!tour) return;
    const next = [...new Set([...complete, tour.id])];
    setComplete(next); writeComplete(next);
    library();
  };
  const restart = () => { if (!tour) return; save(tour.id, 0); setIndex(0); setSelectedId(null); };

  useEffect(() => {
    const apply = () => {
      const m = location.hash.match(/^#\/tour\/([^/]+)\/(\d+)$/);
      if (!m) { setActive(null); setSelectedId(null); return; }
      const t = story.tours.find((x) => x.id === m[1]);
      if (!t) { setActive(null); return; }
      const i = Math.max(0, Math.min(t.chapters.length - 1, Number(m[2]) - 1));
      setActive(t.id); setIndex(i); setSelectedId(null);
      setProgress((prev) => {
        const next = { ...prev, [t.id]: i };
        writeProgress(next);
        return next;
      });
    };
    apply();
    window.addEventListener("popstate", apply);
    window.addEventListener("hashchange", apply);
    return () => {
      window.removeEventListener("popstate", apply);
      window.removeEventListener("hashchange", apply);
    };
  }, [story.tours]);

  if (!active || !tour || !step || !scene) {
    return <TourLibrary graph={graph} progress={progress} complete={complete} onStart={start} theme={theme} onTheme={onTheme} />;
  }

  return (
    <div className="app story-app">
      <TourTopBar tour={tour} step={step} index={index} total={chapters.length} theme={theme} onTheme={onTheme} onLibrary={library} onRestart={restart} />
      <div className="story-stage-strip">
        {[...new Set(chapters.map((chapter) => chapter.stage))].map((stage, i, stages) => {
          const activeIndex = stages.indexOf(step.stage);
          return (
            <React.Fragment key={stage}>
              {i > 0 ? <span className="story-stage-sep" /> : null}
              <span className={`story-stage ${stage === step.stage ? "current" : ""} ${i < activeIndex ? "done" : ""}`}>{stage}</span>
            </React.Fragment>
          );
        })}
      </div>
      <div className="shell story-shell">
        <TourRail chapters={chapters} current={index} onJump={go} />
        <main className="story-stage-canvas">
          <Canvas
            graph={graph}
            scene={scene}
            selectedId={selectedId}
            focusToken={focusToken}
            revealIds={step.reveal}
            newEdgeIds={step.edges.map((e) => e.id)}
            dimOnSelect={false}
            showAll
            storyMode
            onSelect={setSelectedId}
            onEnter={() => {}}
            onLens={() => {}}
          />
          <ChapterPanel
            graph={graph}
            step={step}
            index={index}
            total={chapters.length}
            selected={selected}
            onSelect={setSelectedId}
            onBack={() => index === 0 ? library() : go(index - 1)}
            onNext={() => go(index + 1)}
            onSource={setSourceNode}
            onFinish={finish}
          />
        </main>
      </div>
      {sourceNode ? <SourceModal node={sourceNode} onClose={() => setSourceNode(null)} /> : null}
    </div>
  );
}
