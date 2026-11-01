import React, { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { ChevronRight, Eye, Layers3, LocateFixed, Minus, Plus } from "lucide-react";
import type { Graph, GraphEdge, GraphNode, Scene } from "./types";
import { iconFor } from "./icons";
import { edgeCategory } from "./edges";

type Props = {
  graph: Graph;
  scene: Scene;
  selectedId: string | null;
  focusNodeId?: string | null;
  focusToken?: number;
  storyMode?: boolean;
  focusNodes?: string[];
  revealIds?: string[];
  newEdgeIds?: string[];
  dimOnSelect?: boolean;
  showAll?: boolean;
  onSelect: (id: string | null) => void;
  onEnter: (id: string) => void;
  onLens: (id: string) => void;
};

type Viewport = { x: number; y: number; scale: number };

const PAD = 90;

function fitViewport(scene: Scene, width: number, height: number, pad = PAD * 1.25): Viewport {
  if (!width || !height) return { x: 0, y: 0, scale: 1 };
  const avail = width;
  const scale = Math.min((avail - pad) / scene.width, (height - pad) / scene.height, 1.2);
  const s = Math.max(0.22, scale);
  return {
    x: (avail - scene.width * s) / 2,
    y: (height - scene.height * s) / 2,
    scale: s,
  };
}

function NodeCard({
  node,
  sceneNode,
  selected,
  dimmed,
  isNew,
  storyMode,
  onSelect,
  onEnter,
}: {
  node: GraphNode;
  sceneNode: Scene["nodes"][number];
  selected: boolean;
  dimmed: boolean;
  isNew: boolean;
  storyMode?: boolean;
  onSelect: (id: string) => void;
  onEnter: (id: string) => void;
}) {
  const Icon = iconFor(node.kind);
  const isTarget = node.kind === "target" || node.kind === "system";
  return (
    <button
      type="button"
      className={[
        "node-card",
        `kind-${node.kind}`,
        selected ? "selected" : "",
        dimmed ? "dimmed" : "",
        sceneNode.boundary ? "boundary" : "",
        node.context ? "context" : "",
        node.optional ? "optional" : "",
        isTarget ? "is-target" : "",
        isNew ? "new-node" : "",
      ].filter(Boolean).join(" ")}
      style={{ left: sceneNode.x, top: sceneNode.y, width: sceneNode.w, height: sceneNode.h }}
      onPointerDown={(e) => e.stopPropagation()}
      onClick={(e) => {
        e.stopPropagation();
        onSelect(node.id);
      }}
      onDoubleClick={(e) => {
        e.stopPropagation();
        if (!storyMode) onEnter(node.id);
      }}
      aria-pressed={selected}
      title={`${node.title}${node.subtitle ? ` — ${node.subtitle}` : ""}`}
    >
      <div className="node-head">
        <span className="node-icon"><Icon size={15} strokeWidth={1.7} /></span>
        <span className="node-kind">{node.kind}</span>
        {sceneNode.boundary ? <span className="node-boundary">linked</span> : null}
      </div>
      <div className="node-title">{node.title}</div>
      <div className="node-subtitle">{node.subtitle}</div>
      {isTarget && node.summary ? <div className="node-summary">{node.summary}</div> : null}
      <div className="node-foot">
        <span className="node-badges">
          {node.badges.slice(0, 3).map((b) => (
            <span key={b} className={`badge badge-${b}`}>{b}</span>
          ))}
        </span>
        {node.childCount ? (
          <span className="node-count"><Layers3 size={12} /> {node.childCount}</span>
        ) : node.hasChildren ? (
          <span className="node-count"><ChevronRight size={13} /></span>
        ) : null}
      </div>
    </button>
  );
}

function EdgeLayer({
  scene,
  graph,
  selectedId,
  labelEdgeIds,
  newEdgeIds,
  visibleIds,
}: {
  scene: Scene;
  graph: Graph;
  selectedId: string | null;
  labelEdgeIds?: string[];
  newEdgeIds?: string[];
  visibleIds?: Set<string>;
}) {
  const [hover, setHover] = useState<string | null>(null);
  const byId = useMemo(() => new Map(scene.nodes.map((n) => [n.id, n])), [scene.nodes]);
  const paths = useMemo(() => {
    const raw = scene.edges
      .map((e) => {
        const a = byId.get(e.from);
        const b = byId.get(e.to);
        if (!a || !b) return null;
        if (visibleIds && (!visibleIds.has(e.from) || !visibleIds.has(e.to))) return null;
        const acx = a.x + a.w / 2;
        const acy = a.y + a.h / 2;
        const bcx = b.x + b.w / 2;
        const bcy = b.y + b.h / 2;
        const horizontal = Math.abs(bcx - acx) >= Math.abs(bcy - acy) * 0.8;
        let sx: number, sy: number, tx: number, ty: number;
        if (horizontal) {
          const right = bcx >= acx;
          sx = right ? a.x + a.w : a.x;
          sy = acy;
          tx = right ? b.x : b.x + b.w;
          ty = bcy;
        } else {
          const down = bcy >= acy;
          sx = acx;
          sy = down ? a.y + a.h : a.y;
          tx = bcx;
          ty = down ? b.y : b.y + b.h;
        }
        const dx = Math.max(50, Math.abs(tx - sx) * 0.52);
        const dy = Math.max(40, Math.abs(ty - sy) * 0.52);
        const c1x = horizontal ? sx + (tx > sx ? dx : -dx) : sx;
        const c1y = horizontal ? sy : sy + (ty > sy ? dy : -dy);
        const c2x = horizontal ? tx - (tx > sx ? dx : -dx) : tx;
        const c2y = horizontal ? ty : ty - (ty > sy ? dy : -dy);
        return {
          edge: e,
          d: `M ${sx} ${sy} C ${c1x} ${c1y}, ${c2x} ${c2y}, ${tx} ${ty}`,
          points: [sx, sy, c1x, c1y, c2x, c2y, tx, ty] as const,
          category: edgeCategory(e.type),
          touches: selectedId === e.from || selectedId === e.to,
        };
      })
      .filter(Boolean) as {
        edge: GraphEdge;
        d: string;
        points: readonly [number, number, number, number, number, number, number, number];
        category: string;
        touches: boolean;
      }[];

    const at = (p: readonly number[], t: number) => {
      const u = 1 - t;
      return {
        x: u * u * u * p[0] + 3 * u * u * t * p[2] + 3 * u * t * t * p[4] + t * t * t * p[6],
        y: u * u * u * p[1] + 3 * u * u * t * p[3] + 3 * u * t * t * p[5] + t * t * t * p[7],
      };
    };
    const tangent = (p: readonly number[], t: number) => {
      const u = 1 - t;
      return {
        x: 3 * u * u * (p[2] - p[0]) + 6 * u * t * (p[4] - p[2]) + 3 * t * t * (p[6] - p[4]),
        y: 3 * u * u * (p[3] - p[1]) + 6 * u * t * (p[5] - p[3]) + 3 * t * t * (p[7] - p[5]),
      };
    };
    const hitsNode = (box: { x: number; y: number; w: number; h: number }, n: Scene["nodes"][number]) =>
      box.x < n.x + n.w + 4 && box.x + box.w > n.x - 4 && box.y < n.y + n.h + 4 && box.y + box.h > n.y - 4;
    const placed: { x: number; y: number; w: number; h: number }[] = [];
    const candidates = [0.5, 0.4, 0.6, 0.3, 0.7];

    return raw.map((path) => {
      let label: { text: string; x: number; y: number } | null = null;
      const text = path.edge.label ? String(path.edge.label) : "";
      if (text) {
        const w = text.length * 6.2 + 10;
        const h = 13;
        for (const t of candidates) {
          const p = at(path.points, t);
          const tan = tangent(path.points, t);
          const len = Math.hypot(tan.x, tan.y) || 1;
          const nx = -tan.y / len;
          const ny = tan.x / len;
          // Keep the label clear of the line itself: move it by half its
          // projected width plus a margin, not a fixed pixel offset.
          const lineClear = Math.abs(nx) * (w / 2) + Math.abs(ny) * (h / 2) + 5;
          const offsets = [-lineClear, lineClear, 0, -lineClear - 12, lineClear + 12];
          for (const offset of offsets) {
            const x = p.x + nx * offset;
            const y = p.y + ny * offset;
            const box = { x: x - w / 2, y: y - h / 2, w, h };
            if (box.x < 4 || box.y < 4 || box.x + w > scene.width - 4 || box.y + h > scene.height - 4) continue;
            if (scene.nodes.some((n) => hitsNode(box, n))) continue;
            if (placed.some((p) => box.x < p.x + p.w + 3 && box.x + box.w > p.x - 3 && box.y < p.y + p.h + 3 && box.y + box.h > p.y - 3)) continue;
            placed.push(box);
            label = { text, x, y };
            break;
          }
          if (label) break;
        }
      }
      return { ...path, label };
    });
  }, [scene.edges, scene.nodes, scene.width, scene.height, byId, selectedId, visibleIds]);


  return (
    <svg className="edge-layer" width={scene.width} height={scene.height} aria-hidden="true">
      <defs>
        {["traffic", "auth", "storage", "updates", "config", "ops"].map((c) => (
          <marker
            key={c}
            id={`arrow-${c}`}
            viewBox="0 0 10 10"
            refX="9"
            refY="5"
            markerWidth="6"
            markerHeight="6"
            orient="auto-start-reverse"
          >
            <path d="M 0 0 L 10 5 L 0 10 z" fill={`var(--edge-${c})`} />
          </marker>
        ))}
      </defs>
      <g>
        {paths.map(({ edge, d, category, touches, label }) => {
          const dim = selectedId ? !touches : false;
          const active = hover === edge.id;
          return (
            <g key={edge.id} className={`edge-group ${dim ? "dimmed" : ""} ${touches ? "touches" : ""}`}>
              <path className="edge-hit" d={d} onMouseEnter={() => setHover(edge.id)} onMouseLeave={() => setHover(null)} />
              <path
                className={`edge-path cat-${category} ${touches ? "selected" : ""} ${newEdgeIds?.includes(edge.id) ? "new-edge" : ""}`}
                d={d}
                markerEnd={`url(#arrow-${category})`}
              />
              {label && (active || touches || labelEdgeIds?.includes(edge.id)) ? (
                <text className="edge-label" x={label.x} y={label.y} textAnchor="middle" dominantBaseline="middle">
                  {label.text}
                </text>
              ) : null}
            </g>
          );
        })}
      </g>
    </svg>
  );
}

export function Canvas({
  graph,
  scene,
  selectedId,
  focusNodeId,
  focusToken,
  storyMode,
  focusNodes,
  revealIds,
  newEdgeIds,
  dimOnSelect = true,
  showAll,
  onSelect,
  onEnter,
  onLens,
}: Props) {
  const containerRef = useRef<HTMLDivElement>(null);
  const [size, setSize] = useState({ w: 0, h: 0 });
  const [vp, setVp] = useState<Viewport>({ x: 0, y: 0, scale: 1 });
  const [transition, setTransition] = useState(false);
  const [panning, setPanning] = useState(false);
  const [legend, setLegend] = useState(true);
  const [sceneKey, setSceneKey] = useState(scene.id);
  const [entering, setEntering] = useState(false);
  const drag = useRef<{ x: number; y: number; vx: number; vy: number; moved: boolean } | null>(null);
  const clickTimer = useRef<number | null>(null);
  const lastFit = useRef<string>("");

  useLayoutEffect(() => {
    const el = containerRef.current;
    if (!el) return;
    const ro = new ResizeObserver(() => {
      setSize({ w: el.clientWidth, h: el.clientHeight });
    });
    ro.observe(el);
    setSize({ w: el.clientWidth, h: el.clientHeight });
    return () => ro.disconnect();
  }, []);

  const fit = useCallback(
    (animate = false) => {
      const inset = storyMode && window.innerWidth > 1000 ? 450 : 0;
      const next = fitViewport(scene, Math.max(360, size.w - inset), size.h, storyMode ? 54 : PAD * 1.25);
      setTransition(animate);
      setVp(next);
      if (animate) setTimeout(() => setTransition(false), 320);
    },
    [scene, size.w, size.h, storyMode],
  );

  useLayoutEffect(() => {
    if (!size.w || !size.h) return;
    const layout = storyMode ? (window.innerWidth > 1000 ? "right" : "sheet") : "scene";
    const key = `${layout}:${scene.id}`;
    if (lastFit.current === key) return;
    lastFit.current = key;
    const inset = storyMode && window.innerWidth > 1000 ? 450 : 0;
    setVp(fitViewport(scene, Math.max(360, size.w - inset), size.h, storyMode ? 54 : PAD * 1.25));
    setSceneKey(scene.id);
    setEntering(true);
    const t = setTimeout(() => setEntering(false), 380);
    return () => clearTimeout(t);
  }, [scene.id, size.w, size.h, storyMode]);

  useEffect(() => {
    if (storyMode || !focusNodeId || !focusToken) return;
    const n = scene.nodes.find((x) => x.id === focusNodeId);
    if (!n) return;
    const scale = Math.max(0.85, Math.min(1.35, vp.scale));
    const inset = window.innerWidth > 720 ? 400 : 0;
    setTransition(true);
    setVp({
      x: (size.w - inset) / 2 - (n.x + n.w / 2) * scale,
      y: size.h / 2 - (n.y + n.h / 2) * scale,
      scale,
    });
    setTimeout(() => setTransition(false), 560);
  }, [focusToken, focusNodeId, scene.nodes, size.w, size.h]);

  useEffect(() => {
    const el = containerRef.current;
    if (!el) return;
    const onWheel = (e: WheelEvent) => {
      e.preventDefault();
      const rect = el.getBoundingClientRect();
      const mx = e.clientX - rect.left;
      const my = e.clientY - rect.top;
      const factor = Math.exp(-e.deltaY * 0.0013);
      setVp((prev) => {
        const nextScale = Math.max(0.22, Math.min(2.6, prev.scale * factor));
        const k = nextScale / prev.scale;
        return { scale: nextScale, x: mx - (mx - prev.x) * k, y: my - (my - prev.y) * k };
      });
    };
    el.addEventListener("wheel", onWheel, { passive: false });
    return () => el.removeEventListener("wheel", onWheel);
  }, []);

  const onPointerDown = (e: React.PointerEvent) => {
    if ((e.target as HTMLElement).closest(".node-card, button, .legend, .zoom-controls")) return;
    drag.current = { x: e.clientX, y: e.clientY, vx: vp.x, vy: vp.y, moved: false };
    setPanning(true);
    (e.currentTarget as HTMLElement).setPointerCapture(e.pointerId);
  };
  const onPointerMove = (e: React.PointerEvent) => {
    if (!drag.current) return;
    const dx = e.clientX - drag.current.x;
    const dy = e.clientY - drag.current.y;
    if (Math.abs(dx) + Math.abs(dy) > 3) drag.current.moved = true;
    setVp((prev) => ({ ...prev, x: drag.current!.vx + dx, y: drag.current!.vy + dy }));
  };
  const onPointerUp = (e: React.PointerEvent) => {
    if (drag.current && !drag.current.moved) {
      if (clickTimer.current) window.clearTimeout(clickTimer.current);
      onSelect(null);
    }
    drag.current = null;
    setPanning(false);
    try { (e.currentTarget as HTMLElement).releasePointerCapture(e.pointerId); } catch { /* noop */ }
  };

  const deferSelect = (id: string) => {
    if (clickTimer.current) window.clearTimeout(clickTimer.current);
    if (storyMode) { onSelect(id); return; }
    // Let a double-click land before the inspector covers the card.
    clickTimer.current = window.setTimeout(() => onSelect(id), 190);
  };

  const enter = (id: string) => {
    if (clickTimer.current) window.clearTimeout(clickTimer.current);
    if (storyMode) { onSelect(id); return; }
    const node = graph.nodes[id];
    if (!node) return;
    if (node.action?.type === "lens") {
      onLens(node.action.id);
      return;
    }
    if (graph.scenes[id]) {
      const sn = scene.nodes.find((x) => x.id === id);
      if (sn) {
        const scale = Math.min(2.15, Math.max(1.5, vp.scale * 1.55));
        setTransition(true);
        setVp({
          x: size.w / 2 - (sn.x + sn.w / 2) * scale,
          y: size.h / 2 - (sn.y + sn.h / 2) * scale,
          scale,
        });
        setTimeout(() => {
          setTransition(false);
          onEnter(id);
        }, 235);
        return;
      }
      onEnter(id);
    } else {
      onSelect(id);
    }
  };

  const selectedNeighbors = useMemo(() => {
    if (!dimOnSelect || !selectedId || !scene.nodes.some((n) => n.id === selectedId)) return null;
    const set = new Set<string>([selectedId]);
    for (const e of scene.edges) {
      if (e.from === selectedId) set.add(e.to);
      if (e.to === selectedId) set.add(e.from);
    }
    if (set.size === 1) return null;
    return set;
  }, [selectedId, scene.edges, scene.nodes, dimOnSelect]);

  const sceneNodeIds = new Set(scene.nodes.map((n) => n.id));
  const storyVisible = new Set<string>(scene.nodes.map((n) => n.id));

  const shownZones = storyMode
    ? scene.zones.filter((z) => scene.nodes.some((n) => {
        if (!storyVisible.has(n.id)) return false;
        const cx = n.x + n.w / 2;
        const cy = n.y + n.h / 2;
        return cx >= z.x && cx <= z.x + z.w && cy >= z.y && cy <= z.y + z.h;
      }))
    : scene.zones;

  if (size.w > 0 && size.w <= 1000) {
    const ordered = [...scene.nodes];
    return (
      <div className={`mobile-canvas ${storyMode ? "story-mobile-canvas" : ""}`}>
        <div className="mobile-scene-head">
          <div className="canvas-eyebrow">{storyMode ? "Chapter" : scene.kind === "lens" ? "Lens" : "Scene"}</div>
          <h1>{scene.title}</h1>
          {scene.subtitle ? <p>{scene.subtitle}</p> : null}
          <span>{scene.nodes.length} nodes · {scene.edges.length} links</span>
        </div>
        <div className="mobile-list">
          {ordered.map((sn) => {
            const n = graph.nodes[sn.id];
            if (!n) return null;
            const Icon = iconFor(n.kind);
            const canEnter = !!graph.scenes[n.id] || n.action?.type === "lens";
            return (
              <div key={sn.id} className={`mobile-card kind-${n.kind} ${selectedId === sn.id ? "selected" : ""}`}>
                <button type="button" className="mobile-card-main" onClick={() => { onSelect(sn.id); if (n.action?.type === "lens") onLens(n.action.id); }}>
                  <span className="mobile-icon"><Icon size={16} /></span>
                  <span className="mobile-text">
                    <strong>{n.title}</strong>
                    <em>{n.subtitle || n.kind}</em>
                    <span className="mobile-badges">
                      {n.badges.slice(0, 3).map((b) => <span key={b} className={`badge badge-${b}`}>{b}</span>)}
                    </span>
                  </span>
                  {n.childCount ? <span className="mobile-count">{n.childCount}</span> : null}
                </button>
                {canEnter && !storyMode ? (
                  <button type="button" className="mobile-open" onClick={() => n.action?.type === "lens" ? onLens(n.action.id) : onEnter(n.id)}>
                    Open <ChevronRight size={14} />
                  </button>
                ) : null}
              </div>
            );
          })}
        </div>
      </div>
    );
  }

  return (
    <div
      ref={containerRef}
      className={`canvas ${storyMode ? "story-canvas" : ""} ${panning ? "panning" : ""} ${entering ? "scene-entering" : ""}`}
      onPointerDown={onPointerDown}
      onPointerMove={onPointerMove}
      onPointerUp={onPointerUp}
      onPointerCancel={onPointerUp}
      style={{
        backgroundSize: `${Math.max(14, 26 * vp.scale)}px ${Math.max(14, 26 * vp.scale)}px`,
        backgroundPosition: `${vp.x}px ${vp.y}px`,
      }}
    >
      {!storyMode ? (
        <div className="canvas-title">
          <div>
            <div className="canvas-eyebrow">{storyMode ? "Chapter" : scene.kind === "lens" ? "Lens" : "Scene"}</div>
            <h1>{scene.title}</h1>
            {scene.subtitle ? <p>{scene.subtitle}</p> : null}
          </div>
          <div className="scene-meta">{scene.nodes.length} nodes · {scene.edges.length} links</div>
        </div>
      ) : null}

      <div
        className={`world ${transition ? "animate" : ""} ${entering ? "enter" : ""}`}
        style={{ transform: `translate3d(${vp.x}px, ${vp.y}px, 0) scale(${vp.scale})` }}
        key={sceneKey}
      >
        {shownZones.map((z) => (
          <div key={z.id} className="zone" style={{ left: z.x, top: z.y, width: z.w, height: z.h }}>
            <span className="zone-label">{z.label}</span>
          </div>
        ))}
        <EdgeLayer scene={scene} graph={graph} selectedId={selectedId} labelEdgeIds={storyMode ? newEdgeIds : undefined} newEdgeIds={newEdgeIds} visibleIds={storyMode ? storyVisible : undefined} />
        {scene.nodes.map((sn) => {
          const node = graph.nodes[sn.id];
          if (!node) return null;
          if (storyMode && !storyVisible.has(sn.id)) return null;
          return (
            <NodeCard
              key={sn.id}
              node={node}
              sceneNode={sn}
              selected={selectedId === sn.id}
              dimmed={!!selectedNeighbors && !selectedNeighbors.has(sn.id)}
              isNew={storyMode ? !!revealIds?.includes(sn.id) : false}
              storyMode={storyMode}
              onSelect={deferSelect}
              onEnter={enter}
            />
          );
        })}
      </div>

      {!selectedId && !storyMode ? (
        <div className="canvas-hint">Click a card to inspect · double-click to enter</div>
      ) : null}

      <div className="zoom-controls">
        <button type="button" aria-label="Zoom out" onClick={() => setVp((p) => ({ ...p, scale: Math.max(0.22, p.scale / 1.18) }))}><Minus size={16} /></button>
        <button type="button" className="zoom-value" onClick={() => fit(true)} title="Fit scene">{Math.round(vp.scale * 100)}%</button>
        <button type="button" aria-label="Zoom in" onClick={() => setVp((p) => ({ ...p, scale: Math.min(2.6, p.scale * 1.18) }))}><Plus size={16} /></button>
        <button type="button" aria-label="Fit scene" onClick={() => fit(true)}><LocateFixed size={16} /></button>
      </div>

      {!storyMode && legend ? (
        <div className="legend">
          <div className="legend-head">
            <span><Eye size={13} /> Relation lens</span>
            <button type="button" onClick={() => setLegend(false)} aria-label="Hide legend">×</button>
          </div>
          <div className="legend-grid">
            {["traffic", "auth", "storage", "updates", "config", "ops"].map((c) => (
              <span key={c} className="legend-item"><i className={`legend-dot dot-${c}`} />{c}</span>
            ))}
          </div>
        </div>
      ) : !storyMode ? (
        <button type="button" className="legend-toggle" onClick={() => setLegend(true)}><Eye size={14} /> Legend</button>
      ) : null}

      {scene.nodes.length === 0 ? (
        <div className="empty-scene">
          <p>No sceneable children were discovered for this part yet.</p>
          <span>It may be a leaf, or it may need a narrative card. Open its source from the panel.</span>
        </div>
      ) : null}
    </div>
  );
}
