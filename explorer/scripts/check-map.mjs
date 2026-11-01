import fs from "node:fs";
import path from "node:path";

const here = path.dirname(new URL(import.meta.url).pathname);
const graphPath = path.join(here, "../public/data/graph.json");
const sourceDir = path.join(here, "../public/snippets");
const graph = JSON.parse(fs.readFileSync(graphPath, "utf8"));
const errors = [];
const warnings = [];

const nodeIds = new Set(Object.keys(graph.nodes));
for (const [id, node] of Object.entries(graph.nodes)) {
  if (node.parent && !nodeIds.has(node.parent)) errors.push(`node ${id} has missing parent ${node.parent}`);
  const factLabels = new Set();
  for (const fact of node.facts || []) {
    const key = fact.label.toLowerCase();
    if (factLabels.has(key)) errors.push(`node ${id} duplicate fact ${fact.label}`);
    factLabels.add(key);
  }
  if (node.source) {
    if (!node.source.path || !node.source.key) errors.push(`node ${id} has malformed source`);
    if (!fs.existsSync(path.join(sourceDir, `${node.source.key}.json`))) errors.push(`node ${id} source missing: ${node.source.path}`);
  }
}

const edgeIds = new Set();
for (const edge of graph.edges) {
  if (!nodeIds.has(edge.from)) errors.push(`edge ${edge.id} missing from ${edge.from}`);
  if (!nodeIds.has(edge.to)) errors.push(`edge ${edge.id} missing to ${edge.to}`);
  if (edgeIds.has(edge.id)) errors.push(`duplicate edge ${edge.id}`);
  edgeIds.add(edge.id);
}

for (const [id, scene] of Object.entries(graph.scenes)) {
  if (id !== "system" && !id.startsWith("lens/") && !nodeIds.has(id)) errors.push(`scene ${id} has no node`);
  const seen = new Set();
  for (const sn of scene.nodes) {
    if (!nodeIds.has(sn.id)) errors.push(`scene ${id} missing node ${sn.id}`);
    if (seen.has(sn.id)) errors.push(`scene ${id} duplicate node ${sn.id}`);
    seen.add(sn.id);
    if (!Number.isFinite(sn.x) || !Number.isFinite(sn.y)) errors.push(`scene ${id} node ${sn.id} has bad layout`);
  }
  for (const edge of scene.edges) {
    if (!seen.has(edge.from) || !seen.has(edge.to)) errors.push(`scene ${id} edge ${edge.id} points outside scene`);
  }
}

if (graph.story) {
  const chapterIds = new Set(graph.story.steps.map((s) => s.id));
  for (const tour of graph.story.tours || []) {
    for (const id of tour.chapters) if (!chapterIds.has(id)) errors.push(`tour ${tour.id} missing chapter ${id}`);
  }
  const inTour = new Set();
  const recommended = (graph.story.tours || []).filter((t) => t.recommended);
  if (recommended.length !== 1) errors.push(`story must have exactly one recommended tour, found ${recommended.length}`);
  for (const tour of graph.story.tours || []) {
    if (!tour.chapters.length) errors.push(`tour ${tour.id} has no chapters`);
    if (new Set(tour.chapters).size !== tour.chapters.length) errors.push(`tour ${tour.id} repeats a chapter`);
    for (const id of tour.chapters) {
      inTour.add(id);
      if (!chapterIds.has(id)) errors.push(`tour ${tour.id} missing chapter ${id}`);
    }
  }
  for (const step of graph.story.steps) {
    const seen = new Set();
    if (!step.visibleNodes.length) errors.push(`story ${step.id} has no visible nodes`);
    if (!step.code.length) errors.push(`story ${step.id} has no code list`);
    if (!inTour.has(step.id)) errors.push(`story ${step.id} is not in any tour`);
    for (const n of step.visibleNodes) {
      if (!nodeIds.has(n.id)) errors.push(`story ${step.id} missing node ${n.id}`);
      if (seen.has(n.id)) errors.push(`story ${step.id} repeats node ${n.id}`);
      seen.add(n.id);
      if (!Number.isFinite(n.x) || !Number.isFinite(n.y) || !Number.isFinite(n.w) || !Number.isFinite(n.h)) errors.push(`story ${step.id} node ${n.id} has bad layout`);
      if (n.x < 0 || n.y < 0 || n.x + n.w > step.width + 0.5 || n.y + n.h > step.height + 0.5) errors.push(`story ${step.id} node ${n.id} is outside the scene`);
    }
    const nodes = step.visibleNodes;
    for (let i = 0; i < nodes.length; i++) {
      for (let j = i + 1; j < nodes.length; j++) {
        const a = nodes[i];
        const b = nodes[j];
        if (a.x < b.x + b.w && a.x + a.w > b.x && a.y < b.y + b.h && a.y + a.h > b.y) errors.push(`story ${step.id} nodes overlap: ${a.id}, ${b.id}`);
      }
    }
    for (const edge of step.edges) {
      if (!nodeIds.has(edge.from)) errors.push(`story ${step.id} edge from missing ${edge.from}`);
      if (!nodeIds.has(edge.to)) errors.push(`story ${step.id} edge to missing ${edge.to}`);
      if (!seen.has(edge.from) || !seen.has(edge.to)) errors.push(`story ${step.id} edge ${edge.id} points outside the scene`);
      if (edge.label != null && typeof edge.label !== "string") errors.push(`story ${step.id} edge ${edge.id} label is not a string`);
    }
    for (const id of step.focus) if (!nodeIds.has(id)) errors.push(`story ${step.id} focus missing ${id}`);
    for (const zone of step.zones) {
      const members = nodes.filter((n) => (zone.members || []).includes(n.id));
      if (!members.length) errors.push(`story ${step.id} zone ${zone.id} has no members`);
      for (const n of members) {
        if (n.x < zone.x || n.y < zone.y || n.x + n.w > zone.x + zone.w + 0.5 || n.y + n.h > zone.y + zone.h + 0.5) errors.push(`story ${step.id} zone ${zone.id} does not contain ${n.id}`);
      }
    }
    for (const c of step.code) {
      if (!fs.existsSync(path.join(here, "../..", c.path))) errors.push(`story ${step.id} code path missing: ${c.path}`);
      if (!c.source?.key || !fs.existsSync(path.join(sourceDir, `${c.source.key}.json`))) errors.push(`story ${step.id} code source missing: ${c.path}`);
    }
  }
}

for (const tour of graph.tours) {
  if (!tour.steps.length) errors.push(`tour ${tour.id} has no valid steps`);
  for (const step of tour.steps) if (!nodeIds.has(step.focus)) errors.push(`tour ${tour.id} missing focus ${step.focus}`);
}

const topLevel = Object.values(graph.nodes).filter((n) => ["target", "group", "component"].includes(n.kind));
const unexplained = topLevel.filter((n) => !n.summary && !n.body);
if (unexplained.length) warnings.push(`${unexplained.length} top-level nodes have no narrative`);

console.log(`check: ${nodeIds.size} nodes, ${edgeIds.size} edges, ${graph.story?.steps.length || 0} chapters, ${graph.story?.tours.length || 0} guided tours, ${graph.scenes ? Object.keys(graph.scenes).length : 0} scenes`);
if (warnings.length) console.log(`warnings:\n  ${warnings.join("\n  ")}`);
if (errors.length) {
  console.error(`errors:\n  ${errors.join("\n  ")}`);
  process.exit(1);
}
