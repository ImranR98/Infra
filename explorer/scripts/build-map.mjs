import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import { execFileSync } from "node:child_process";
import YAML from "yaml";

const HERE = path.dirname(new URL(import.meta.url).pathname);
const ROOT = path.resolve(HERE, "../..");
const OUT_DATA = path.join(HERE, "../public/data");
const OUT_SOURCE = path.join(HERE, "../public/snippets");
const CONTENT = path.join(HERE, "../content");

const nodes = new Map();
const edges = new Map();
const fileToNode = new Map();
const sources = new Map();
const cards = [];
const decisions = [];
const tours = [];

const now = new Date().toISOString();
const gitSha = (() => {
  try {
    return execFileSync("git", ["rev-parse", "--short", "HEAD"], { cwd: ROOT, encoding: "utf8" }).trim();
  } catch {
    return "unknown";
  }
})();

/* ------------------------------------------------------------------ */
/* utilities                                                           */
/* ------------------------------------------------------------------ */

const read = (rel) => fs.readFileSync(path.join(ROOT, rel), "utf8");
const exists = (rel) => fs.existsSync(path.join(ROOT, rel));
const lines = (text) => text.split("\n");
const clean = (s) => s.replace(/\r/g, "");

function slug(s) {
  return String(s)
    .toLowerCase()
    .replace(/[^a-z0-9._-]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 120);
}

function titleize(s) {
  const special = {
    nfs: "NFS",
    k3s: "K3s",
    dscpln: "D$CPLN",
    "open-webui": "Open WebUI",
    "crowdsec-web-ui": "CrowdSec Web UI",
    "homeassistant": "Home Assistant",
    "opencanary": "OpenCanary",
    "qbittorrent": "qBittorrent",
    "navidrome": "Navidrome",
    "opodsync": "Opodsync",
    "immich": "Immich",
    "frigate": "Frigate",
    "jellyfin": "Jellyfin",
    "authelia": "Authelia",
    "traefik": "Traefik",
    "renovate": "Renovate",
    "alloy": "Alloy",
  };
  if (special[s]) return special[s];
  return s
    .replace(/-/g, " ")
    .replace(/\b\w/g, (c) => c.toUpperCase());
}

function findLine(text, needle) {
  const idx = text.indexOf(needle);
  if (idx < 0) return 1;
  return text.slice(0, idx).split("\n").length;
}

function commentBlockAbove(text, line) {
  const arr = lines(text);
  let i = Math.max(0, line - 2);
  const out = [];
  while (i >= 0 && arr[i].trim() === "") i--;
  while (i >= 0) {
    const t = arr[i].trim();
    if (!t.startsWith("#")) break;
    out.unshift(t.replace(/^#\s?/, ""));
    i--;
  }
  return out.join("\n").trim();
}

function leadingComment(text) {
  const arr = lines(text);
  const out = [];
  let started = false;
  for (const raw of arr.slice(0, 90)) {
    const t = raw.trim();
    if (!started && t === "") continue;
    if (t.startsWith("#")) {
      started = true;
      out.push(t.replace(/^#\s?/, ""));
      continue;
    }
    if (t === "{{/*" || t.startsWith("{{/*")) {
      started = true;
      out.push(t.replace(/^\{\{\/\*\s?/, ""));
      continue;
    }
    if (started && (t.endsWith("*/}}") || t === "*/}}" || t.startsWith("*/}}"))) {
      out.push(t.replace(/\*\/\}\}\s*$/, ""));
      break;
    }
    if (started) break;
    if (!t.startsWith("#") && !t.startsWith("{{-")) break;
  }
  return out.join("\n").trim();
}

function extractDesc(text) {
  const arr = lines(text);
  const start = arr.findIndex((l) => l.startsWith("# DESC:"));
  if (start < 0) return leadingComment(text);
  const out = [arr[start].replace(/^# DESC:\s?/, "")];
  for (let i = start + 1; i < arr.length; i++) {
    const t = arr[i];
    if (t.startsWith("#")) out.push(t.replace(/^#\s?/, ""));
    else if (t.trim() === "" && out.join("\n").length < 900) {
      // Stop at the first blank after the DESC block.
      break;
    } else break;
  }
  return out.join("\n").trim();
}

function sourceKey(rel) {
  return Buffer.from(rel).toString("base64url");
}

function sourceRef(rel, line = 1, endLine = line) {
  if (!exists(rel)) return null;
  return { path: rel, line, endLine, key: sourceKey(rel) };
}

function addNode(input) {
  if (!input.id) throw new Error("node id required");
  const n = {
    kind: "concept",
    title: input.id,
    tags: [],
    badges: [],
    facts: [],
    ...input,
  };
  n.tags = [...new Set(n.tags)].filter(Boolean);
  n.badges = [...new Set(n.badges)].filter(Boolean);
  const current = nodes.get(n.id);
  if (current) {
    Object.assign(current, {
      ...n,
      facts: mergeFacts(current.facts, n.facts),
      tags: [...new Set([...(current.tags || []), ...(n.tags || [])])],
      badges: [...new Set([...(current.badges || []), ...(n.badges || [])])],
      summary: n.summary || current.summary,
      body: n.body || current.body,
    });
  } else {
    nodes.set(n.id, n);
  }
  return nodes.get(n.id);
}

function mergeFacts(current = [], incoming = []) {
  const byLabel = new Map();
  for (const fact of current) byLabel.set(fact.label.toLowerCase(), fact);
  for (const fact of incoming) byLabel.set(fact.label.toLowerCase(), fact);
  return [...byLabel.values()];
}

function addEdge(from, to, type, label = "", extra = {}) {
  if (!from || !to || from === to) return;
  const id = `${from}->${to}:${type}`;
  if (edges.has(id)) return;
  edges.set(id, { id, from, to, type, label, ...extra });
}

function addFact(node, label, value, mono = false) {
  if (value === undefined || value === null || value === "") return;
  node.facts.push({ label, value: String(value), mono });
}

/* ------------------------------------------------------------------ */
/* source index                                                        */
/* ------------------------------------------------------------------ */

const SKIP_PREFIXES = [
  "config/",
  "current_target/",
  "state_backups/",
  "explorer/node_modules/",
  "explorer/dist/",
  "explorer/public/",
  ".git/",
  ".agents/",
];
const TEXT_EXT = new Set([
  ".sh", ".yaml", ".yml", ".json", ".md", ".tpl", ".py", ".conf",
  ".service", ".timer", ".xml", ".env", ".example", ".txt", ".toml",
]);

function trackedFiles() {
  return execFileSync("git", ["ls-files", "-co", "--exclude-standard"], { cwd: ROOT, encoding: "utf8" })
    .split("\n")
    .filter(Boolean)
    .filter((f) => !SKIP_PREFIXES.some((p) => f.startsWith(p)))
    .filter((f) => !f.endsWith("compose.private.yaml"))
    .filter((f) => !f.endsWith("/compose/.env"))
    .filter((f) => {
      const base = path.basename(f);
      if (base === "Dockerfile" || base === "Chart.yaml") return true;
      const ext = path.extname(f);
      return TEXT_EXT.has(ext);
    })
    .filter((f) => {
      try {
        return fs.statSync(path.join(ROOT, f)).size < 250_000;
      } catch {
        return false;
      }
    });
}

function indexSources(files) {
  // Overwrite in place. Removing and recreating the directory makes Vite's
  // public-dir cache serve the SPA fallback for snippets generated while the
  // dev server is running.
  fs.mkdirSync(OUT_SOURCE, { recursive: true });
  for (const rel of files) {
    const text = clean(read(rel));
    sources.set(rel, text);
    const key = sourceKey(rel);
    fs.writeFileSync(path.join(OUT_SOURCE, `${key}.json`), JSON.stringify({ path: rel, text }));
  }
}

/* ------------------------------------------------------------------ */
/* top-level graph                                                     */
/* ------------------------------------------------------------------ */

const LANE_ORDER = ["external", "entry", "runtime", "data", "security", "config", "ops", "source"];

const appCats = YAML.parse(read("explorer/content/app-categories.yaml"));
const appCategory = new Map();
for (const [cat, items] of Object.entries(appCats.srv0 || {})) {
  for (const item of items) appCategory.set(item, cat);
}

const baseCategories = {
  network: ["gateway", "edge-certs", "traefik", "cert-manager"],
  storage: ["nfs-server", "host-volumes", "csi-driver-nfs"],
  security: ["authelia", "crowdsec", "crowdsec-cert-roll", "crowdsec-web-ui", "falco", "app-egress", "namespaces"],
  observability: ["monitoring", "ntfy"],
  cluster: ["descheduler", "system-upgrade-controller", "system-upgrade", "generic-device-plugin"],
  access: ["vpn"],
  updates: ["renovate"],
};
const baseCategory = new Map();
for (const [cat, items] of Object.entries(baseCategories)) {
  for (const item of items) baseCategory.set(item, cat);
}

function addTargets() {
  addNode({
    id: "system",
    kind: "system",
    title: "Infra guided tours",
    subtitle: "srv0 · vps0",
    summary:
      "Eight linear tours of the homelab. Two machines are the subject: vps0, the public edge, and srv0, the home Kubernetes cluster. Other machines appear only where they explain a dependency.",
    tags: ["primary"],
    facts: [
      { label: "Primary targets", value: "srv0, vps0" },
      { label: "Explorer", value: "build-time graph from tracked files", mono: true },
    ],
    lane: "runtime",
  });

  addNode({
    id: "srv0",
    kind: "target",
    title: "srv0",
    parent: "system",
    subtitle: "K3s control plane · home cluster",
    summary:
      "The main home server. A single-node K3s control plane runs the platform components and the app catalog; a Compose sidecar owns the public-exposure tunnel client.",
    tags: ["primary", "network", "storage", "auth", "updates"],
    facts: [
      { label: "Orchestrator", value: "K3s + Helm charts" },
      { label: "Namespace", value: "base (platform) / apps (workloads)" },
      { label: "Exposure", value: "LAN/VPN + public-exposure tunnel" },
      { label: "Storage", value: "NFS (nfs-apps) + static host paths" },
      { label: "Pinned by", value: "infra.local/hostpath-main, infra.local/external-exposed" },
    ],
    lane: "runtime",
  });

  addNode({
    id: "vps0",
    kind: "target",
    title: "vps0",
    parent: "system",
    subtitle: "Public edge · Docker Compose",
    summary:
      "The public VPS. Traefik terminates public TLS, Authelia and CrowdSec guard the public/cloud zones, and the public-exposure WireGuard hub forwards home traffic to srv0.",
    tags: ["primary", "network", "auth", "updates"],
    facts: [
      { label: "Orchestrator", value: "Docker Compose" },
      { label: "Edge", value: "Traefik + Let's Encrypt (TLS-ALPN-01)" },
      { label: "Tunnel", value: "public-exposure WireGuard hub" },
    ],
    lane: "runtime",
  });

  addNode({
    id: "concept/about",
    kind: "concept",
    title: "About this map",
    subtitle: "scope · how to explore",
    parent: "system",
    summary: "A map compiled from the repo. srv0 and vps0 are the subject; other machines are context.",
    tags: ["primary"],
    lane: "ops",
  });

  addNode({
    id: "external/internet",
    kind: "external",
    title: "Internet",
    parent: "system",
    subtitle: "public traffic",
    summary: "Public HTTP/HTTPS traffic lands on vps0. The home cluster is reachable from the edge only through the public-exposure tunnel.",
    tags: ["network"],
    lane: "external",
  });

  addNode({
    id: "srv0/base",
    kind: "group",
    parent: "srv0",
    title: "Platform · base",
    subtitle: "K3s base namespace",
    summary:
      "Repo-owned cluster foundation: Gateway/TLS, storage, auth and security, observability, node lifecycle, and the update controller.",
    tags: ["platform", "storage", "auth", "network", "observability"],
    lane: "runtime",
  });

  addNode({
    id: "srv0/apps",
    kind: "group",
    parent: "srv0",
    title: "Apps",
    subtitle: "K3s apps namespace",
    summary:
      "The app catalog. Each app is a template file that owns its resources, routes, storage, and security posture.",
    tags: ["apps", "storage", "auth"],
    lane: "runtime",
  });

  addNode({
    id: "srv0/cluster",
    kind: "group",
    parent: "srv0",
    title: "Cluster & hardware",
    subtitle: "K3s control plane · nodes · accelerators",
    summary:
      "Node provisioning, static labels, optional worker nodes, and hardware resources exposed through the generic device plugin.",
    tags: ["cluster", "updates"],
    lane: "runtime",
  });

  addNode({
    id: "srv0/compose",
    kind: "group",
    parent: "srv0",
    title: "Compose sidecar",
    subtitle: "public-exposure client",
    summary:
      "A small Compose project on srv0. It owns the WireGuard client interface that carries public traffic into the cluster.",
    tags: ["network"],
    lane: "runtime",
  });

  addNode({
    id: "srv0/ops",
    kind: "group",
    parent: "srv0",
    title: "Operations",
    subtitle: "updates · backups · CI · access",
    summary:
      "The recurring work that keeps the system alive: Renovate, state backups, CI, remote access, and the shared deploy/validate tooling.",
    tags: ["updates", "storage", "auth", "observability"],
    lane: "ops",
  });

  addNode({
    id: "vps0/edge",
    kind: "group",
    parent: "vps0",
    title: "Edge & security",
    subtitle: "Traefik · Authelia · CrowdSec · tunnel",
    summary:
      "The public entry point. Traefik routes by host, Authelia handles SSO, CrowdSec watches traffic, and the WireGuard hub forwards home hostnames to srv0.",
    tags: ["network", "auth"],
    lane: "runtime",
  });

  addNode({
    id: "vps0/apps",
    kind: "group",
    parent: "vps0",
    title: "Public & cloud apps",
    subtitle: "Compose services",
    summary:
      "Public apps on the base domain and SSO-protected apps on the cloud domain. All images are Renovate-owned.",
    tags: ["apps", "updates"],
    lane: "runtime",
  });

  addNode({
    id: "vps0/ops",
    kind: "group",
    parent: "vps0",
    title: "Operations",
    subtitle: "monitoring · pruning · archive agent",
    summary:
      "Operational sidecars on the VPS: uptime, logs, image pruning, and the optional D$CPLN archive agent.",
    tags: ["ops", "storage"],
    lane: "ops",
  });

  const baseGroups = {
    network: "Network & TLS",
    storage: "Storage",
    security: "Auth & security",
    observability: "Observability",
    cluster: "Cluster lifecycle",
    access: "Remote access",
    updates: "Updates",
  };
  for (const [cat, title] of Object.entries(baseGroups)) {
    addNode({
      id: `srv0/base/${cat}`,
      kind: "group",
      title,
      subtitle: "platform components",
      parent: "srv0/base",
      tags: ["platform"],
      lane: cat === "network" ? "entry" : cat === "storage" ? "data" : cat === "security" ? "security" : cat === "observability" ? "ops" : "runtime",
      summary: `Platform components grouped under ${title}.`,
      subtitle: ({
        network: "Gateway · certificates · Traefik",
        storage: "NFS · CSI · host paths",
        security: "Authelia · CrowdSec · Falco",
        observability: "Alloy · Prometheus · Loki · ntfy",
        cluster: "nodes · device plugin · upgrades",
        access: "tunnel · VPN · preboot",
        updates: "Renovate",
      })[cat] || "platform",
    });
  }

  for (const cat of ["media", "home", "arr", "productivity", "tools", "dscpln", "security"]) {
    addNode({
      id: `srv0/apps/${cat}`,
      kind: "group",
      title: titleize(cat),
      parent: "srv0/apps",
      tags: ["apps"],
      lane: "runtime",
      summary: `Applications grouped for navigation.`,
      subtitle: ({
        media: "photos · video · NVR",
        home: "home automation · sync · RDP",
        arr: "indexers · downloads · requests",
        productivity: "docs · feeds · files",
        tools: "agents · UI · logs",
        dscpln: "archive · tasks · ledger",
        security: "honeypot",
      })[cat] || "apps",
    });
  }

  addNode({
    id: "srv0/ops/renovate",
    kind: "group",
    title: "Renovate",
    subtitle: "six-hourly runner · manual Infra gate",
    parent: "srv0/ops",
    summary:
      "The split update plane: a pure six-hourly CronJob opens PRs, app non-major PRs auto-merge after test, and the renovate-pr-ops skill handles the Infra refresh and approval batch.",
    tags: ["updates", "observability"],
    lane: "ops",
  });
  addNode({
    id: "concept/renovate-pr-ops",
    kind: "concept",
    title: "renovate-pr-ops skill",
    subtitle: "cross-repo Renovate gate",
    parent: "srv0/ops/renovate",
    summary:
      "The cross-repo workflow: handles app exceptions, waits for the app image publish, creates a Job from the suspended renovate-infra CronJob, and presents the Infra PRs for approval.",
    tags: ["updates", "ops"],
    lane: "ops",
  });

  addNode({
    id: "srv0/ops/backups",
    kind: "group",
    title: "State backups",
    subtitle: "restic · Task Runner · restore",
    parent: "srv0/ops",
    summary:
      "Backup-only routine in the D$CPLN Task Runner. One encrypted restic repository captures auto-backup PVCs and Compose state; restore is a manual script.",
    tags: ["storage", "backup"],
    lane: "ops",
  });
  addNode({
    id: "concept/backups/restic-repository",
    kind: "concept",
    title: "Restic repository",
    subtitle: "encrypted · deduplicated · off-app restore",
    parent: "srv0/ops/backups",
    summary: "One restic repository under state_backups/restic. It holds auto-backup PVCs and the srv0/vps0 Compose state; restore is a standalone script.",
    tags: ["storage", "backup"],
    facts: [
      { label: "Location", value: "state_backups/restic" },
      { label: "Retention", value: "restic forget --keep-last N --prune" },
      { label: "Restore", value: "scripts/restic-restore.sh", mono: true },
    ],
    lane: "data",
  });
  addEdge("srv0/ops/backups", "concept/backups/restic-repository", "writes", "restic");
  addEdge("concept/backups/restic-repository", "script/restic-restore", "restored-by", "manual");

  addNode({
    id: "srv0/ops/ci",
    kind: "group",
    title: "CI",
    subtitle: "GitHub Actions",
    parent: "srv0/ops",
    summary: "GitHub Actions checks and the NFS server image pipeline.",
    tags: ["updates"],
    lane: "ops",
  });
  addNode({
    id: "srv0/ops/access",
    kind: "group",
    title: "Remote access",
    subtitle: "tunnel · VPN · preboot",
    parent: "srv0/ops",
    summary:
      "How the machines are reached when the LAN is not available: the public-exposure client, AmneziaWG, and initramfs LUKS unlock.",
    tags: ["network", "auth"],
    lane: "ops",
  });
  addNode({
    id: "srv0/ops/tooling",
    kind: "group",
    title: "Deploy tooling",
    subtitle: "validate · compose · deploy",
    parent: "srv0/ops",
    summary: "The shared scripts that prepare config, validate a target, and deploy it.",
    tags: ["ops"],
    lane: "ops",
  });
  addNode({
    id: "srv0/ops/decisions",
    kind: "group",
    title: "Decisions",
    subtitle: "accepted tradeoffs",
    parent: "srv0/ops",
    summary: "Current design decisions and accepted tradeoffs, attached to the components they affect.",
    tags: ["decisions"],
    lane: "ops",
  });

  // Lens entry points on the root map.
  for (const [id, title, sub, tags] of [
    ["updates", "Updates", "Renovate · images · charts", ["updates"]],
    ["storage", "Storage", "NFS · PVCs · backups", ["storage", "backup"]],
    ["auth", "Auth", "Authelia · CrowdSec · routes", ["auth", "network"]],
    ["observability", "Observability", "Alloy · Prometheus · Loki · ntfy", ["observability"]],
  ]) {
    addNode({
      id: `concept/lens/${id}`,
      kind: "lens",
      title,
      subtitle: sub,
      parent: "system",
      summary: `Open the ${title.toLowerCase()} lens: a cross-cutting view of the system.`,
      tags,
      lane: "ops",
      action: { type: "lens", id },
    });
  }

  addEdge("external/internet", "vps0", "routes-to", "443");
  addEdge("vps0", "srv0", "tunnels-to", "public-exposure");
  addEdge("external/internet", "vps0", "reaches", "public edge");
  addEdge("srv0", "srv0/ops", "runs", "operations");
  addEdge("vps0", "vps0/ops", "runs", "operations");
  addEdge("vps0/edge", "srv0", "tunnels-to", "home.$BASE_SERVICES_DOMAIN");
  addEdge("srv0", "srv0/base", "runs", "platform");
  addEdge("srv0", "srv0/apps", "runs", "apps");
  addEdge("srv0", "srv0/cluster", "runs", "cluster");
  addEdge("srv0", "srv0/compose", "runs", "sidecar");
  addEdge("vps0", "vps0/edge", "runs", "edge");
  addEdge("vps0", "vps0/apps", "runs", "apps");
  addEdge("srv0/ops", "srv0/ops/renovate", "includes", "updates");
  addEdge("srv0/ops", "srv0/ops/backups", "includes", "backups");
  addEdge("srv0/ops", "srv0/ops/ci", "includes", "CI");
  addEdge("srv0/ops", "srv0/ops/access", "includes", "access");
  addEdge("srv0/ops", "srv0/ops/tooling", "includes", "tooling");
  addEdge("srv0/ops", "srv0/ops/decisions", "includes", "decisions");
  addEdge("srv0/ops/renovate", "srv0/config/values", "reads-config", "paths");
  addEdge("srv0/ops/backups", "srv0/config/values", "reads-config", "paths");
  addEdge("srv0/ops/tooling", "srv0/config/values", "reads-config", "values");
  addEdge("srv0/ops/access", "srv0/config/values", "reads-config", "tunnel");
  addEdge("srv0/ops/ci", "config/VARS", "reads-config", "tokens");
  addEdge("srv0/ops/renovate", "config/VARS", "reads-config", "tokens");
  for (const cat of ["media", "home", "arr", "productivity", "tools", "dscpln", "security"]) {
    addEdge("srv0/apps", `srv0/apps/${cat}`, "groups", cat);
  }
  addEdge("srv0/apps", "srv0/base", "depends-on", "platform");
  addEdge("srv0/base/security", "srv0/base/network", "guards", "edge");
  addEdge("srv0/base/cluster", "srv0/base/network", "hosts", "edge");
  addEdge("srv0/base/observability", "srv0/base", "observes", "platform");
  addEdge("srv0/base/storage", "srv0/base/cluster", "pinned-by", "hostpath-main");
  addEdge("srv0/cluster", "srv0/base", "hosts", "platform");
  addEdge("srv0/ops", "srv0/apps", "manages", "apps");
  addEdge("srv0/ops", "srv0/base", "observes", "platform");
  addEdge("srv0/compose", "srv0/base", "feeds", "edge");
  addEdge("vps0/edge", "vps0/apps", "routes-to", "public apps");
  addEdge("vps0/ops", "vps0/edge", "observes", "edge");
  addEdge("srv0", "concept/lens/updates", "observed-by", "Renovate");
  addEdge("srv0", "concept/lens/storage", "observed-by", "NFS");
  addEdge("srv0", "concept/lens/auth", "observed-by", "Authelia");
  addEdge("vps0", "concept/lens/auth", "observed-by", "Authelia");
  addEdge("srv0", "concept/lens/observability", "observed-by", "monitoring");
}

/* ------------------------------------------------------------------ */
/* Helm / Kubernetes discovery                                         */
/* ------------------------------------------------------------------ */

function helmRender(release, chart, namespace) {
  const values = chart.includes("k3s-apps")
    ? "targets/srv0/k3s-apps/values.yaml"
    : "targets/srv0/k3s-base/values.yaml";
  const args = [
    "template", release, chart,
    "-n", namespace,
    "-f", values,
    "-f", "targets/srv0/config_template/values.yaml",
  ];
  return execFileSync("helm", args, { cwd: ROOT, encoding: "utf8", maxBuffer: 40 * 1024 * 1024 });
}

function parseRendered(text, chartDir) {
  const out = [];
  const chunks = text.split(/\n(?=# Source: )/);
  for (const raw of chunks) {
    const sourceMatch = raw.match(/^# Source:\s*(.+)$/m);
    if (!sourceMatch) continue;
    const source = sourceMatch[1].trim();
    const rel = path.join(chartDir, source.replace(/^[^/]+\//, ""));
    const body = raw.replace(/^# Source:\s*.+$/m, "").trim();
    if (!body || !/^\s*(apiVersion|kind):/m.test(body)) continue;
    let docs;
    try {
      docs = YAML.parseAllDocuments(body);
    } catch {
      continue;
    }
    for (const d of docs) {
      let doc;
      try {
        doc = d.toJS();
      } catch {
        continue;
      }
      if (!doc) continue;
      if (doc.kind === "List" && Array.isArray(doc.items)) {
        for (const item of doc.items) out.push({ doc: item, rel });
      } else {
        out.push({ doc, rel });
      }
    }
  }
  return out;
}

function resourceKindSlug(kind) {
  return {
    PersistentVolumeClaim: "pvc",
    PersistentVolume: "pv",
    StorageClass: "storageclass",
    NetworkPolicy: "netpol",
    ServiceAccount: "serviceaccount",
    ClusterRole: "clusterrole",
    ClusterRoleBinding: "clusterrolebinding",
    Role: "role",
    RoleBinding: "rolebinding",
    HelmChart: "helmchart",
    HTTPRoute: "httproute",
    CronJob: "cronjob",
    DaemonSet: "daemonset",
    StatefulSet: "statefulset",
    Deployment: "deployment",
    ConfigMap: "configmap",
    Secret: "secret",
    Certificate: "certificate",
    Gateway: "gateway",
    Middleware: "middleware",
    Service: "service",
    Job: "job",
  }[kind] || slug(kind);
}

function laneForKind(kind) {
  if (["HTTPRoute", "Gateway", "Certificate", "Middleware", "Service", "Ingress"].includes(kind)) return "entry";
  if (["PersistentVolumeClaim", "PersistentVolume", "StorageClass", "ConfigMap", "Secret"].includes(kind)) return "data";
  if (["NetworkPolicy", "ClusterRole", "ClusterRoleBinding", "Role", "RoleBinding", "ServiceAccount"].includes(kind)) return "security";
  if (["CronJob", "Job"].includes(kind)) return "ops";
  if (["HelmChart"].includes(kind)) return "runtime";
  return "runtime";
}

function tagsForKind(kind) {
  const tags = [];
  if (["PersistentVolumeClaim", "PersistentVolume", "StorageClass"].includes(kind)) tags.push("storage");
  if (["HTTPRoute", "Gateway", "Service", "Middleware", "Certificate"].includes(kind)) tags.push("network");
  if (["Middleware", "NetworkPolicy", "ServiceAccount", "Role", "ClusterRole"].includes(kind)) tags.push("security");
  if (["CronJob", "Job"].includes(kind)) tags.push("schedule");
  if (kind === "HelmChart") tags.push("updates");
  return tags;
}

const k8s = [];
const k8sIndex = new Map();
const resourceId = new Map();

function registerResource(doc, component, rel, text) {
  const meta = doc.metadata || {};
  const name = meta.name || "unnamed";
  const ns = meta.namespace || "";
  const kind = doc.kind || "Resource";
  const rid = `${component.id}/${resourceKindSlug(kind)}/${slug(name)}`;
  let id = rid;
  if (nodes.has(id) && nodes.get(id).parent !== component.id) id = `${rid}-${slug(ns || "default")}`;
  let n = nodes.get(id);
  const line = findLine(text, `name: ${name}`);
  if (!n) {
    n = addNode({
      id,
      kind: "resource",
      title: name,
      subtitle: `${kind}${ns ? ` · ${ns}` : ""}`,
      parent: component.id,
      summary: commentBlockAbove(text, line),
      source: sourceRef(rel, line, line),
      tags: tagsForKind(kind),
      lane: laneForKind(kind),
    });
  }
  n.resource = { kind, name, namespace: ns, doc };
  const prefix = {
    Gateway: "Gateway", Middleware: "Middleware", Service: "Service",
    PersistentVolumeClaim: "PVC", PersistentVolume: "PV", StorageClass: "StorageClass",
    ConfigMap: "Config", Secret: "Secret", NetworkPolicy: "NetworkPolicy",
    ServiceAccount: "ServiceAccount", Role: "Role", RoleBinding: "RoleBinding",
    ClusterRole: "ClusterRole", ClusterRoleBinding: "ClusterRoleBinding",
    Certificate: "Certificate", Job: "Job", CronJob: "CronJob",
  }[kind];
  if (prefix) n.title = `${prefix} ${name}`;
  k8s.push({ id, component, doc, rel, text, node: n });
  k8sIndex.set(`${ns}/${kind}/${name}`, n);
  k8sIndex.set(`${kind}/${name}`, n);
  resourceId.set(doc, n.id);
  return n;
}

function parseValuesContent(vc) {
  if (!vc || typeof vc !== "string") return null;
  try {
    return YAML.parse(vc);
  } catch {
    return null;
  }
}

function addValuesTree(parent, values, rel, text, prefix = "") {
  if (!values || typeof values !== "object" || Array.isArray(values)) return;
  const keys = Object.keys(values).slice(0, 22);
  if (!keys.length) return;
  const valuesNode = addNode({
    id: `${parent.id}/values`,
    kind: "config",
    title: "Chart values",
    subtitle: `${keys.length} top-level keys`,
    parent: parent.id,
    summary: "The chart-owned configuration surface. The chart's internal pods are not in this repo; these are the values that shape them.",
    source: parent.source,
    tags: ["config", "updates"],
    lane: "config",
  });
  addEdge(parent.id, valuesNode.id, "configures", "valuesContent");
  for (const key of keys) {
    const value = values[key];
    const line = findLine(text, `${prefix}${key}:`);
    const type = Array.isArray(value) ? "list" : value === null ? "null" : typeof value;
    const vn = addNode({
      id: `${valuesNode.id}/${slug(key)}`,
      kind: "config",
      title: key,
      subtitle: type,
      parent: valuesNode.id,
      summary: commentBlockAbove(text, line),
      source: sourceRef(rel, line, line),
      tags: ["config"],
      lane: "config",
    });
    addFact(vn, "Type", type);
    if (value && typeof value === "object" && !Array.isArray(value)) {
      addFact(vn, "Keys", Object.keys(value).slice(0, 8).join(", "));
    } else if (typeof value === "string" || typeof value === "number" || typeof value === "boolean") {
      addFact(vn, "Value", String(value).slice(0, 160), true);
    }
  }
}

function addImagesFromText(node, text, rel) {
  const found = new Set();
  const patterns = [
    /image:\s*["']?([^\s"']+:[^\s"']+)["']?/g,
    /repository:\s*["']?([^\s"']+)["']?\s*\n\s*tag:\s*["']?([^\s"']+)["']?/g,
  ];
  for (const re of patterns) {
    let m;
    while ((m = re.exec(text))) {
      const ref = m[2] ? `${m[1]}:${m[2]}` : m[1];
      if (!ref.includes("/") || ref.includes("{{") || ref.startsWith("oci://")) continue;
      found.add(ref);
    }
  }
  for (const ref of [...found].slice(0, 8)) {
    const [repo, tag = ""] = ref.split(":");
    const id = `${node.id}/image/${slug(ref)}`;
    const img = addNode({
      id,
      kind: "image",
      title: repo.split("/").pop() || repo,
      subtitle: tag,
      parent: node.id,
      summary: "Container image used by this component.",
      source: sourceRef(rel, findLine(text, ref), findLine(text, ref)),
      tags: ["updates"],
      lane: "runtime",
    });
    addFact(img, "Image", ref, true);
    addEdge(node.id, id, "uses-image", tag || "image");
  }
}

function buildK8s() {
  const base = helmRender("map-base", "targets/srv0/k3s-base", "base");
  const apps = helmRender("map-apps", "targets/srv0/k3s-apps", "apps");
  const resources = [
    ...parseRendered(base, "targets/srv0/k3s-base"),
    ...parseRendered(apps, "targets/srv0/k3s-apps"),
  ];

  // One file-scope component per template file.
  const components = new Map();
  for (const { doc, rel } of resources) {
    if (!doc.kind) continue;
    const isApps = rel.includes("/k3s-apps/");
    const stem = path.basename(rel, ".yaml");
    let componentId;
    let title;
    let parent;
    let lane;
    if (isApps) {
      const cat = appCategory.get(stem) || appCategory.get(stem.replace(/^hooks$/, "immich")) || "tools";
      const effectiveStem = stem === "hooks" ? "immich" : stem;
      componentId = `srv0/apps/${cat}/${effectiveStem}`;
      title = effectiveStem === "immich" ? "Immich" : titleize(effectiveStem);
      parent = `srv0/apps/${cat}`;
      lane = "runtime";
    } else {
      const cat = baseCategory.get(stem) || "cluster";
      componentId = `srv0/base/${stem}`;
      title = titleize(stem);
      parent = `srv0/base/${cat}`;
      lane = ["gateway", "edge-certs", "traefik", "cert-manager"].includes(stem)
        ? "entry"
        : ["nfs-server", "host-volumes", "csi-driver-nfs"].includes(stem)
          ? "data"
          : ["authelia", "crowdsec", "crowdsec-cert-roll", "crowdsec-web-ui", "falco", "app-egress", "namespaces"].includes(stem)
            ? "security"
            : ["monitoring", "ntfy"].includes(stem)
              ? "ops"
              : "runtime";
    }
    if (!components.has(componentId)) {
      const text = sources.get(rel) || read(rel);
      const c = addNode({
        id: componentId,
        kind: "component",
        title,
        subtitle: isApps ? "app · apps namespace" : "platform · base namespace",
        parent,
        summary: leadingComment(text),
        source: sourceRef(rel, 1, 1),
        tags: ["component", ...(isApps ? ["apps"] : ["platform"])],
        lane,
      });
      components.set(componentId, c);
    }
    const c = components.get(componentId);
    const text = sources.get(rel) || read(rel);
    if (!fileToNode.has(rel)) fileToNode.set(rel, c);
    registerResource(doc, c, rel, text);
  }

  // Resource details + nested container/values nodes.
  for (const entry of k8s) {
    const { doc, node, rel, text } = entry;
    const kind = doc.kind;
    const spec = doc.spec || {};
    const meta = doc.metadata || {};
    node.subtitle = `${kind}${meta.namespace ? ` · ${meta.namespace}` : ""}`;
    addFact(node, "Kind", kind);
    if (meta.namespace) addFact(node, "Namespace", meta.namespace);

    if (["Deployment", "StatefulSet", "DaemonSet", "Job", "CronJob"].includes(kind)) {
      const podSpec =
        kind === "CronJob"
          ? spec.jobTemplate?.spec?.template?.spec
          : spec.template?.spec;
      const containers = [
        ...(podSpec?.initContainers || []),
        ...(podSpec?.containers || []),
      ];
      if (kind === "CronJob") {
        addFact(node, "Schedule", `${spec.schedule || ""}${spec.timeZone ? ` (${spec.timeZone})` : ""}`, true);
        if (spec.concurrencyPolicy) addFact(node, "Concurrency", spec.concurrencyPolicy);
        if (spec.startingDeadlineSeconds) addFact(node, "Start deadline", `${spec.startingDeadlineSeconds}s`);
        if (spec.suspend !== undefined) addFact(node, "Suspended", String(spec.suspend));
        if (spec.jobTemplate?.spec?.activeDeadlineSeconds) addFact(node, "Active deadline", `${spec.jobTemplate.spec.activeDeadlineSeconds}s`);
        node.tags.push("schedule");
      }
      if (kind === "Deployment" || kind === "StatefulSet") {
        addFact(node, "Replicas", spec.replicas ?? 1);
      }
      if (podSpec?.nodeSelector && Object.keys(podSpec.nodeSelector).length) {
        addFact(node, "Node selector", Object.entries(podSpec.nodeSelector).map(([k, v]) => `${k}=${v}`).join(", "));
      }
      if (podSpec?.serviceAccountName) addFact(node, "Service account", podSpec.serviceAccountName);
      const images = [];
      for (const c of containers) {
        const cid = `${node.id}/container/${slug(c.name || "container")}`;
        const cn = addNode({
          id: cid,
          kind: "container",
          title: c.name || "container",
          subtitle: "container",
          parent: node.id,
          summary: "",
          source: sourceRef(rel, findLine(text, `- name: ${c.name}`), findLine(text, `- name: ${c.name}`)),
          tags: ["updates"],
          lane: "runtime",
        });
        addFact(cn, "Image", c.image || "", true);
        images.push(c.image);
        if (c.ports?.length) addFact(cn, "Ports", c.ports.map((p) => `${p.containerPort}/${p.protocol || "TCP"}`).join(", "));
        if (c.resources?.requests || c.resources?.limits) {
          const r = c.resources;
          addFact(cn, "Requests", Object.entries(r.requests || {}).map(([k, v]) => `${k}=${v}`).join(", "));
          addFact(cn, "Limits", Object.entries(r.limits || {}).map(([k, v]) => `${k}=${v}`).join(", "));
        }
        if (c.env) addFact(cn, "Env keys", c.env.map((e) => e.name).filter(Boolean).join(", "));
        addEdge(node.id, cid, "runs", c.name);
      }
      if (containers.length) node.tags.push("updates");
      if (images.some((i) => String(i).includes("infra.local/") || String(i).includes("rocm") || String(i).includes("openvino"))) {
        node.tags.push("gpu");
      }
    }

    if (kind === "CronJob") {
      const cmd = spec.jobTemplate?.spec?.template?.spec?.containers?.[0]?.command;
      if (cmd) addFact(node, "Command", cmd.join(" "), true);
    }

    if (kind === "HelmChart") {
      addFact(node, "Chart", spec.chart || "", true);
      if (spec.version) addFact(node, "Version", spec.version, true);
      if (spec.targetNamespace) addFact(node, "Target namespace", spec.targetNamespace);
      if (spec.failurePolicy) addFact(node, "Failure policy", spec.failurePolicy);
      const values = parseValuesContent(spec.valuesContent);
      if (values) {
        addValuesTree(node, values, rel, text);
        addImagesFromText(node, spec.valuesContent || "", rel);
      }
      node.tags.push("updates");
    }

    if (kind === "HTTPRoute") {
      const parents = (spec.parentRefs || []).map((p) => `${p.name}${p.sectionName ? `/${p.sectionName}` : ""}`);
      const hosts = spec.hostnames || [];
      const backends = [];
      const filters = [];
      for (const rule of spec.rules || []) {
        for (const b of rule.backendRefs || []) backends.push(`${b.name}${b.port ? `:${b.port}` : ""}`);
        for (const f of rule.filters || []) {
          if (f.extensionRef) filters.push(`${f.extensionRef.kind}/${f.extensionRef.name}`);
        }
      }
      if (hosts.length) addFact(node, "Hosts", hosts.join(", "));
      if (parents.length) addFact(node, "Parent", parents.join(", "));
      if (backends.length) addFact(node, "Backend", backends.join(", "));
      if (filters.length) addFact(node, "Filters", filters.join(", "));
      if (hosts.some((h) => h.includes("immich") || h.includes("home"))) node.tags.push("network");
      node.badges.push(hosts.length ? "route" : "internal");
    }

    if (kind === "Gateway") {
      const listeners = (spec.listeners || []).map((l) => `${l.name}:${l.port}/${l.protocol}`);
      addFact(node, "Listeners", listeners.join(", "));
      node.tags.push("network", "auth");
    }

    if (kind === "Service") {
      const ports = (spec.ports || []).map((p) => `${p.name || "port"}:${p.port}/${p.protocol || "TCP"}`);
      if (ports.length) addFact(node, "Ports", ports.join(", "));
      if (spec.type) addFact(node, "Type", spec.type);
      if (spec.selector) addFact(node, "Selector", Object.entries(spec.selector).map(([k, v]) => `${k}=${v}`).join(", "));
    }

    if (kind === "PersistentVolumeClaim") {
      addFact(node, "Size", spec.resources?.requests?.storage || "");
      addFact(node, "Storage class", spec.storageClassName || "");
      addFact(node, "Access", (spec.accessModes || []).join(", "));
      const auto = meta.labels?.["auto-backup"] === "true";
      if (auto) {
        node.tags.push("backup");
        node.badges.push("backup");
        addFact(node, "Backup", "auto-backup=true");
      }
    }

    if (kind === "PersistentVolume") {
      addFact(node, "Path", spec.local?.path || spec.hostPath?.path || "");
      addFact(node, "Capacity", spec.capacity?.storage || "");
      addFact(node, "Storage class", spec.storageClassName || "");
      const labels = spec.nodeAffinity?.required?.nodeSelectorTerms?.[0]?.matchExpressions || [];
      for (const e of labels) addFact(node, "Pinned by", `${e.key} ${e.operator} ${(e.values || []).join(",")}`);
    }

    if (kind === "StorageClass") {
      addFact(node, "Provisioner", spec.provisioner || "");
      addFact(node, "Reclaim", spec.reclaimPolicy || "");
      if (meta.annotations?.["storageclass.kubernetes.io/is-default-class"] === "true") addFact(node, "Default", "true");
      node.tags.push("storage");
    }

    if (kind === "ConfigMap" || kind === "Secret") {
      const keys = Object.keys({ ...(doc.data || {}), ...(doc.stringData || {}) });
      addFact(node, kind === "Secret" ? "Keys (names only)" : "Keys", keys.slice(0, 12).join(", "));
      if (kind === "Secret") node.tags.push("security");
    }

    if (kind === "NetworkPolicy") {
      addFact(node, "Types", (spec.policyTypes || []).join(", "));
      addFact(node, "Ingress rules", (spec.ingress || []).length);
      addFact(node, "Egress rules", (spec.egress || []).length);
      node.tags.push("security");
    }

    if (kind === "Middleware") {
      addFact(node, "Plugin", Object.keys(spec.plugin || {}).join(", ") || "built-in");
      node.tags.push("auth", "security");
      node.badges.push("auth");
    }

    if (kind === "Certificate") {
      addFact(node, "DNS names", (spec.dnsNames || []).join(", "));
      addFact(node, "Issuer", spec.issuerRef?.name || "");
      node.tags.push("auth", "network");
    }
  }

  // Cross-resource references.
  for (const entry of k8s) {
    const { node, doc } = entry;
    const spec = doc.spec || {};
    const ns = doc.metadata?.namespace || "";

    if (doc.kind === "HTTPRoute") {
      for (const p of spec.parentRefs || []) {
        const gw = k8sIndex.get(`${p.namespace || ns}/Gateway/${p.name}`) || k8sIndex.get(`Gateway/${p.name}`);
        if (gw) addEdge(node.id, gw.id, "routes-through", p.sectionName || "Gateway");
      }
      for (const rule of spec.rules || []) {
        for (const b of rule.backendRefs || []) {
          const svc = k8sIndex.get(`${b.namespace || ns}/Service/${b.name}`) || k8sIndex.get(`Service/${b.name}`);
          if (svc) addEdge(node.id, svc.id, "routes-to", b.name);
        }
        for (const f of rule.filters || []) {
          if (f.extensionRef) {
            const mw = k8sIndex.get(`${f.extensionRef.kind}/${f.extensionRef.name}`);
            if (mw) addEdge(node.id, mw.id, "guarded-by", f.extensionRef.name);
          }
        }
      }
    }

    if (doc.kind === "Service" && spec.selector) {
      for (const e of k8s) {
        if (!["Deployment", "StatefulSet", "DaemonSet"].includes(e.doc.kind)) continue;
        const labels = e.doc.spec?.template?.metadata?.labels || {};
        if (Object.entries(spec.selector).every(([k, v]) => labels[k] === v)) {
          addEdge(node.id, e.node.id, "selects", "labels");
        }
      }
    }

    if (["Deployment", "StatefulSet", "DaemonSet", "Job", "CronJob"].includes(doc.kind)) {
      const podSpec = doc.kind === "CronJob"
        ? spec.jobTemplate?.spec?.template?.spec
        : spec.template?.spec;
      for (const v of podSpec?.volumes || []) {
        if (v.persistentVolumeClaim?.claimName) {
          const pvc = k8sIndex.get(`${ns}/PersistentVolumeClaim/${v.persistentVolumeClaim.claimName}`) || k8sIndex.get(`PersistentVolumeClaim/${v.persistentVolumeClaim.claimName}`);
          if (pvc) addEdge(node.id, pvc.id, "mounts", v.name);
        }
        if (v.configMap?.name) {
          const cm = k8sIndex.get(`${ns}/ConfigMap/${v.configMap.name}`) || k8sIndex.get(`ConfigMap/${v.configMap.name}`);
          if (cm) addEdge(node.id, cm.id, "uses-config", v.name);
        }
        if (v.secret?.secretName) {
          const s = k8sIndex.get(`${ns}/Secret/${v.secret.secretName}`) || k8sIndex.get(`Secret/${v.secret.secretName}`);
          if (s) addEdge(node.id, s.id, "uses-secret", v.name);
        }
      }
      for (const c of [...(podSpec?.containers || []), ...(podSpec?.initContainers || [])]) {
        for (const e of c.env || []) {
          const ref = e.valueFrom?.secretKeyRef;
          if (ref) {
            const s = k8sIndex.get(`${ns}/Secret/${ref.name}`) || k8sIndex.get(`Secret/${ref.name}`);
            if (s) addEdge(node.id, s.id, "uses-secret", ref.name);
          }
        }
      }
    }

    if (doc.kind === "PersistentVolumeClaim") {
      if (spec.volumeName) {
        const pv = k8sIndex.get(`PersistentVolume/${spec.volumeName}`);
        if (pv) addEdge(node.id, pv.id, "bound-to", spec.volumeName);
      }
      if (spec.storageClassName) {
        const sc = k8sIndex.get(`StorageClass/${spec.storageClassName}`);
        if (sc) addEdge(node.id, sc.id, "provisioned-by", spec.storageClassName);
      }
    }

    if (doc.kind === "PersistentVolume") {
      const labels = spec.nodeAffinity?.required?.nodeSelectorTerms?.[0]?.matchExpressions || [];
      if (labels.some((e) => e.key === "infra.local/hostpath-main")) {
        addEdge(node.id, "srv0/cluster", "pinned-to", "hostpath-main");
      }
      if (labels.some((e) => e.key === "infra.local/external-exposed")) {
        addEdge(node.id, "srv0/cluster", "pinned-to", "external-exposed");
      }
    }

    if (doc.kind === "NetworkPolicy" && spec.podSelector) {
      for (const e of k8s) {
        if (!["Deployment", "StatefulSet", "DaemonSet"].includes(e.doc.kind)) continue;
        const labels = e.doc.spec?.template?.metadata?.labels || {};
        const sel = spec.podSelector.matchLabels || {};
        if (Object.keys(sel).length && Object.entries(sel).every(([k, v]) => labels[k] === v)) {
          addEdge(node.id, e.node.id, "protects", "podSelector");
        }
      }
    }

    if (doc.kind === "Gateway") {
      for (const l of spec.listeners || []) {
        for (const ref of l.tls?.certificateRefs || []) {
          const cert = k8sIndex.get(`${ref.namespace || ns}/Certificate/${ref.name}`) || k8sIndex.get(`Certificate/${ref.name}`);
          if (cert) addEdge(node.id, cert.id, "presents", l.name);
        }
      }
    }

    if (doc.kind === "CronJob") {
      const cmd = spec.jobTemplate?.spec?.template?.spec?.containers?.[0]?.command || [];
      const joined = cmd.join(" ");
      const m = joined.match(/(?:^|\/)(scripts\/[A-Za-z0-9._-]+\.sh)/);
      if (m) {
        const script = addNode({
          id: `script/${slug(m[1].replace(/^scripts\//, ""))}`,
          kind: "script",
          title: path.basename(m[1]),
          subtitle: "script",
          summary: "",
          source: sourceRef(m[1], 1, 1),
          tags: ["updates", "schedule"],
          lane: "ops",
        });
        addEdge(node.id, script.id, "runs", "command");
      }
    }
  }

  // For busy components, introduce a small "parts" level (Runtime, Data,
  // Security) so the first scene stays legible. The primary route/chart/
  // workload stays visible; the repetitive resources group one level down.
  for (const c of components.values()) {
    const kids = [...nodes.values()].filter((n) => n.parent === c.id && n.kind === "resource");
    if (kids.length <= 6) continue;
    const keep = new Set();
    for (const n of kids) {
      if (["HTTPRoute", "Gateway", "Certificate", "HelmChart"].includes(n.resource?.kind)) keep.add(n.id);
    }
    const workloads = kids.filter((n) => ["Deployment", "StatefulSet", "DaemonSet"].includes(n.resource?.kind));
    if (workloads.length) keep.add(workloads[0].id);
    const services = kids.filter((n) => n.resource?.kind === "Service");
    if (services.length === 1) keep.add(services[0].id);
    const rest = kids.filter((n) => !keep.has(n.id));
    const cats = {
      runtime: ["Deployment", "StatefulSet", "DaemonSet", "Job", "CronJob", "Service"],
      data: ["PersistentVolumeClaim", "PersistentVolume", "StorageClass", "ConfigMap", "Secret"],
      security: ["NetworkPolicy", "ServiceAccount", "Role", "RoleBinding", "ClusterRole", "ClusterRoleBinding"],
    };
    for (const [cat, kinds] of Object.entries(cats)) {
      const members = rest.filter((n) => kinds.includes(n.resource?.kind));
      if (members.length < 2) continue;
      const gid = `${c.id}/${cat}`;
      const g = addNode({
        id: gid,
        kind: "group",
        title: cat === "runtime" ? `${c.title} runtime` : cat === "data" ? `${c.title} data` : `${c.title} security`,
        subtitle: `${members.length} resources`,
        parent: c.id,
        summary: cat === "runtime"
          ? "Workloads and services that run this component."
          : cat === "data"
            ? "Claims, secrets, and configuration that carry its state."
            : "Network policies and RBAC that bound the component.",
        source: c.source,
        tags: [...c.tags, cat],
        lane: cat === "security" ? "security" : cat === "data" ? "data" : "runtime",
      });
      addFact(g, "Resources", members.length);
      for (const m of members) m.parent = gid;
      addEdge(c.id, gid, "groups", g.title);
    }
  }

  // Fill component facts/badges after their resources exist.
  for (const c of components.values()) {
    const children = [...nodes.values()].filter((n) => n.parent === c.id);
    addFact(c, "Resources", children.length);
    const routes = children.filter((n) => n.resource?.kind === "HTTPRoute");
    for (const r of routes) if (r.facts.find((f) => f.label === "Hosts")) c.tags.push("network");
    if (children.some((n) => n.resource?.kind === "PersistentVolumeClaim" || n.resource?.kind === "HelmChart" && n.tags.includes("storage"))) c.tags.push("storage");
    if (children.some((n) => n.tags.includes("auth"))) c.tags.push("auth");
    if (children.some((n) => n.tags.includes("security"))) c.tags.push("security");
    if (children.some((n) => n.tags.includes("schedule"))) c.tags.push("schedule");
    if (children.some((n) => n.tags.includes("updates")) || children.some((n) => n.resource?.kind === "HelmChart")) c.tags.push("updates");
    if (children.some((n) => n.tags.includes("backup"))) c.badges.push("backup");
    if (children.some((n) => n.facts.some((f) => /infra\.local\/(?:intel-gpu|amd-igpu|amd-dgpu|vaapi|conbee)/.test(f.value)))) c.badges.push("gpu");
    if (!c.summary) {
      const kinds = [...new Set(children.map((n) => n.resource?.kind).filter(Boolean))];
      c.summary = `${c.title} is a ${kinds.length ? kinds.join(", ") : "component"} in the ${c.parent.includes("/base") ? "platform" : "apps"} namespace.`;
    }
    c.tags = [...new Set(c.tags)];
  }
}

/* ------------------------------------------------------------------ */
/* Compose discovery                                                   */
/* ------------------------------------------------------------------ */

const vpsEdge = new Set([
  "public-exposure-server-wg", "public-exposure-watch", "dockerproxy", "authelia",
  "authelia-db", "traefik", "traefik-logrotate", "crowdsec", "crowdsec_web_ui",
]);
const vpsOps = new Set(["dozzle", "uptime", "dscpln-agent"]);

function serviceLine(text, name) {
  const arr = lines(text);
  const re = new RegExp(`^    ${name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}:\\s*$`);
  const idx = arr.findIndex((l) => re.test(l));
  return idx + 1;
}

function parseCompose(rel, target, groupFor) {
  const text = sources.get(rel) || read(rel);
  const doc = YAML.parse(text);
  if (!doc?.services) return;
  const topConfigs = doc.configs || {};
  for (const [name, svc] of Object.entries(doc.services)) {
    const line = serviceLine(text, name) || 1;
    const parent = groupFor(name);
    const id = `${target}/service/${slug(name)}`;
    const image = String(svc.image || "");
    const ports = Array.isArray(svc.ports) ? svc.ports.map(String) : [];
    const profiles = svc.profiles || [];
    const n = addNode({
      id,
      kind: "component",
      title: svc.container_name || name,
      subtitle: profiles.length ? `compose · profile ${profiles.join(", ")}` : "compose service",
      parent,
      summary: commentBlockAbove(text, line),
      source: sourceRef(rel, line, line),
      tags: ["apps", "updates"],
      lane: profiles.length ? "external" : "runtime",
    });
    addFact(n, "Image", image, true);
    if (ports.length) addFact(n, "Ports", ports.join(", "));
    if (svc.network_mode) addFact(n, "Network", svc.network_mode);
    if (svc.restart) addFact(n, "Restart", svc.restart);
    if (profiles.length) {
      addFact(n, "Profile", profiles.join(", "));
      n.badges.push("optional");
      n.optional = true;
    }
    if (svc.healthcheck) addFact(n, "Healthcheck", "configured");
    if (svc.depends_on) addFact(n, "Depends on", Object.keys(svc.depends_on).join(", "));
    if (svc.volumes) {
      n.tags.push("storage");
      addFact(n, "Volumes", svc.volumes.map((v) => (typeof v === "string" ? v : v.source)).filter(Boolean).join(", "));
    }
    if (image) addEdge(n.id, `${n.id}/image`, "uses-image", image.split(":").slice(-1)[0] || "image");
    if (image) {
      addNode({
        id: `${n.id}/image`,
        kind: "image",
        title: image.split("/").pop()?.split(":")[0] || "image",
        subtitle: image.split(":").slice(-1)[0] || "",
        parent: n.id,
        summary: "Container image for this service. Renovate owns the pin.",
        source: n.source,
        tags: ["updates"],
        lane: "runtime",
      });
    }
    if (svc.environment) {
      const keys = Array.isArray(svc.environment)
        ? svc.environment.map((e) => String(e).split("=")[0])
        : Object.keys(svc.environment);
      addFact(n, "Env keys", keys.slice(0, 12).join(", "));
    }

    // Traefik route labels become first-class nodes.
    const labels = Array.isArray(svc.labels)
      ? Object.fromEntries(svc.labels.map((l) => String(l).split(/=(.*)/s).slice(0, 2)))
      : svc.labels || {};
    const routers = new Map();
    for (const [k, v] of Object.entries(labels)) {
      const m = k.match(/^traefik\.http\.routers\.([^.]+)\.(.+)$/);
      if (!m) continue;
      if (!routers.has(m[1])) routers.set(m[1], {});
      routers.get(m[1])[m[2]] = String(v);
    }
    for (const [router, cfg] of routers) {
      const rid = `${id}/route/${slug(router)}`;
      const rule = cfg.rule || "";
      const host = rule.match(/Host\(`([^`]+)`\)/)?.[1] || router;
      const rn = addNode({
        id: rid,
        kind: "route",
        title: host,
        subtitle: router,
        parent: id,
        summary: "",
        source: sourceRef(rel, line, line),
        tags: ["network"],
        lane: "entry",
      });
      addFact(rn, "Rule", rule, true);
      if (cfg.entrypoints) addFact(rn, "Entrypoints", cfg.entrypoints);
      if (cfg.middlewares) {
        addFact(rn, "Middlewares", cfg.middlewares);
        if (cfg.middlewares.includes("authelia")) rn.tags.push("auth");
        if (cfg.middlewares.includes("crowdsec")) rn.tags.push("security");
        if (cfg.middlewares.includes("geoblock")) rn.tags.push("network");
      }
      if (cfg.service) addFact(rn, "Service", cfg.service);
      addEdge(id, rid, "exposes", router);
    }

    // Config objects used by the service.
    for (const c of svc.configs || []) {
      const source = typeof c === "string" ? c : c.source;
      if (!source) continue;
      const cid = `${target}/config/${slug(source)}`;
      const cn = addNode({
        id: cid,
        kind: "config",
        title: source,
        subtitle: "compose config",
        parent: name === "traefik" ? "vps0/edge" : parent,
        summary: "",
        source: sourceRef(rel, findLine(text, `${source}:`) || 1, 1),
        tags: ["config", "network"],
        lane: "config",
      });
      addEdge(id, cid, "uses-config", source);
    }
  }

  // Depends-on edges.
  for (const [name, svc] of Object.entries(doc.services)) {
    const id = `${target}/service/${slug(name)}`;
    for (const dep of Object.keys(svc.depends_on || {})) {
      addEdge(id, `${target}/service/${slug(dep)}`, "depends-on", dep);
    }
  }
  return doc;
}

function buildCompose() {
  const vpsText = sources.get("targets/vps0/compose/compose.yaml") || read("targets/vps0/compose/compose.yaml");
  parseCompose("targets/vps0/compose/compose.yaml", "vps0", (name) =>
    vpsEdge.has(name) ? "vps0/edge" : vpsOps.has(name) ? "vps0/ops" : "vps0/apps",
  );
  parseCompose("targets/srv0/compose/compose.yaml", "srv0", () => "srv0/compose");

  const doc = YAML.parse(vpsText);
  // Top-level configs are useful depth for the edge scene.
  for (const name of Object.keys(doc.configs || {})) {
    addNode({
      id: `vps0/config/${slug(name)}`,
      kind: "config",
      title: name,
      subtitle: "compose config (inlined)",
      parent: "vps0/edge",
      summary: "An inlined Compose config rendered from environment variables at container creation time.",
      source: sourceRef("targets/vps0/compose/compose.yaml", findLine(vpsText, `${name}:`) || 1, 1),
      tags: ["config", "network"],
      lane: "config",
    });
  }

  // Public-exposure relationship.
  addNode({
    id: "concept/public-exposure",
    kind: "concept",
    title: "Public-exposure tunnel",
    subtitle: "10.99.0.1 ↔ 10.99.0.2",
    parent: "vps0/edge",
    summary:
      "The WireGuard link between vps0 and srv0. vps0 DNATs selected public ports into the tunnel; srv0 runs a Compose sidecar that owns the client interface. Home hostnames are routed to srv0 without terminating TLS on vps0.",
    tags: ["network", "auth"],
    facts: [
      { label: "Hub", value: "vps0 · 10.99.0.1" },
      { label: "Client", value: "srv0 · 10.99.0.2" },
      { label: "MTU", value: "1340 (public path 1420)" },
      { label: "TLS", value: "passthrough to srv0 · PROXY protocol v2" },
    ],
    lane: "entry",
  });
  addEdge("vps0/service/public-exposure-server-wg", "concept/public-exposure", "provides", "hub");
  addEdge("concept/public-exposure", "srv0/service/public-exposure-client-wg", "tunnels-to", "client");
  addEdge("vps0/service/traefik", "concept/public-exposure", "forwards-to", "home.*");
  addEdge("concept/public-exposure", "srv0/base/gateway", "forwards-to", "10.99.0.2:8443");

  // Context nodes: only what srv0/vps0 need.
  addNode({
    id: "target/bigpc",
    kind: "target",
    title: "bigpc",
    subtitle: "optional K3s worker · RX 9070",
    parent: "srv0/cluster",
    summary:
      "Optional K3s worker; advertises the RX 9070 and runs Ollama. Its Compose stack also runs syncthing.",
    tags: ["cluster", "gpu", "context"],
    badges: ["optional", "gpu"],
    context: true,
    facts: [
      { label: "Role", value: "optional K3s worker" },
      { label: "Accelerator", value: "AMD RX 9070 → infra.local/amd-dgpu" },
      { label: "Scheduling", value: "scheduling-discouraged taint" },
      { label: "Relevant to", value: "Immich ML · Ollama · Frigate fallback" },
    ],
    lane: "external",
  });
  addEdge("srv0/cluster", "target/bigpc", "may-run-on", "optional worker");
  addEdge("target/bigpc", "srv0/apps/media/frigate", "can-run", "ROCm fallback");
  addEdge("target/bigpc", "srv0/apps/tools/ollama", "runs", "GPU");

  addNode({
    id: "target/rpi",
    kind: "target",
    title: "rpi",
    subtitle: "Pi 400 · go2rtc camera",
    parent: "srv0/apps/media/frigate",
    summary:
      "A Pi 400 running go2rtc; Frigate consumes its authenticated RTSP stream.",
    tags: ["context", "network"],
    badges: ["optional"],
    context: true,
    facts: [
      { label: "Role", value: "optional Frigate camera source" },
      { label: "Protocol", value: "RTSP" },
      { label: "Source", value: "targets/rpi/compose" },
    ],
    lane: "external",
  });
  addEdge("target/rpi", "srv0/apps/media/frigate", "provides-camera", "RTSP");

  addNode({
    id: "concept/compose-target",
    kind: "concept",
    title: "Other Compose targets",
    subtitle: "same wrapper, not covered here",
    parent: "vps0/ops",
    summary:
      "vps0 runs through scripts/compose.sh. Other machines can use the same Compose wrapper; for example, the pc target is another Compose stack. This map deliberately covers only srv0 and vps0, so those targets appear only as passing references.",
    tags: ["ops"],
    lane: "external",
  });
}

/* ------------------------------------------------------------------ */
/* Scripts                                                             */
/* ------------------------------------------------------------------ */

function scriptParent(rel) {
  if (rel === "scripts/renovate.sh" || rel === "scripts/repos.sh") return "srv0/ops/renovate";
  if (rel === "scripts/restic-restore.sh") return "srv0/ops/backups";
  if (rel.startsWith("scripts/k3s-") || rel === "scripts/update-node-ip.sh" || rel === "scripts/kubeconfig-unlock.sh" ||
      rel === "scripts/prereqs.sh" || rel === "scripts/init-config.sh") return "srv0/cluster";
  if (rel === "scripts/preboot.sh" || rel === "scripts/public-exposure-keygen.sh" ||
      rel === "scripts/wireguard.sh" || rel === "scripts/remote-access-client.sh") return "srv0/ops/access";
  if (rel === "scripts/render-vps0-authelia.sh") return "vps0/edge";
  if (rel.includes("k3s-base/files/")) {
    if (rel.includes("generic-device-plugin")) return "srv0/base/generic-device-plugin";
    if (rel.includes("ra-amneziawg")) return "srv0/base/vpn";
    return "srv0/base";
  }
  if (rel.includes("nfs-server-src")) return "srv0/base/nfs-server";
  if (rel.includes("vps0/compose/files")) {
    if (rel.includes("public-exposure")) return "vps0/service/public-exposure-server-wg";
    if (rel.includes("crowdsec")) return "vps0/service/crowdsec";
    return "vps0/edge";
  }
  if (rel.includes("srv0/compose/files")) return "srv0/service/public-exposure-client-wg";
  if (rel === "scripts/deploy.sh" || rel === "scripts/validate.sh" || rel === "scripts/compose.sh" ||
      rel === "scripts/common.sh" || rel === "scripts/config.sh" || rel === "scripts/repos.sh") return "srv0/ops/tooling";
  return "srv0/ops/tooling";
}

function shellPhases(text) {
  const arr = lines(text);
  const out = [];
  for (let i = 0; i < arr.length; i++) {
    const m = arr[i].match(/^\s*echo\s+"==>\s*(?:\[(\d+)\/(\d+)\])?\s*(.+?)"\s*$/);
    if (!m) continue;
    out.push({ line: i + 1, title: m[3].replace(/\$\{[^}]+\}/g, "…"), index: m[1] || String(out.length + 1) });
  }
  return out;
}

function buildScripts(files) {
  for (const rel of files) {
    if (!rel.endsWith(".sh")) continue;
    const text = sources.get(rel) || read(rel);
    const base = path.basename(rel);
    const desc = extractDesc(text);
    const parent = scriptParent(rel);
    const id = `script/${slug(rel.replace(/^scripts\//, "").replace(/\.sh$/, ""))}`;
    const n = addNode({
      id,
      kind: "script",
      title: base,
      subtitle: "shell script",
      parent,
      summary: desc || `Shell script at ${rel}.`,
      source: sourceRef(rel, 1, lines(text).length),
      tags: ["script"],
      lane: "ops",
    });
    const usageIdx = text.indexOf("usage()");
    if (usageIdx >= 0) {
      const usage = text.slice(usageIdx, usageIdx + 700);
      const body = usage.split("\n").filter((l) => l.includes("echo") && !l.includes("Usage:")).join("\n");
      if (body) addFact(n, "Usage", body.replace(/^\s*echo\s+"/gm, "").replace(/"\s*$/gm, "").replace(/\\n/g, "\n"), true);
    }
    if (rel.includes("renovate")) n.tags.push("updates");
    if (rel.includes("restic") || rel.includes("backup")) n.tags.push("storage", "backup");
    if (rel.includes("public-exposure") || rel.includes("wireguard") || rel.includes("remote-access")) n.tags.push("network");
    if (rel.includes("authelia")) n.tags.push("auth");
    if (rel.includes("k3s") || rel.includes("kubeconfig")) n.tags.push("cluster");

    fileToNode.set(rel, n);

    const phases = shellPhases(text);
    for (const p of phases) {
      const sid = `${id}/step/${slug(p.index + "-" + p.title)}`;
      const sn = addNode({
        id: sid,
        kind: "step",
        title: p.title,
        subtitle: `phase ${p.index}`,
        parent: id,
        summary: commentBlockAbove(text, p.line),
        source: sourceRef(rel, p.line, p.line),
        tags: ["step"],
        lane: "runtime",
      });
      addEdge(id, sid, "has-step", p.title);
    }

    // Scripts called by this script.
    const callRe = /(?:bash|source|\.)\s+["']?\$?\{?INFRA_ROOT\}?\/?(scripts\/[A-Za-z0-9._-]+\.sh)/g;
    let m;
    while ((m = callRe.exec(text))) {
      const target = m[1];
      addEdge(n.id, `script/${slug(target.replace(/^scripts\//, "").replace(/\.sh$/, ""))}`, "calls", path.basename(target));
    }
  }
}

/* ------------------------------------------------------------------ */
/* Config templates                                                    */
/* ------------------------------------------------------------------ */

function parseConfigFile(rel, kind, parent, layerId, layerTitle) {
  const text = sources.get(rel) || read(rel);
  const arr = lines(text);
  const sections = new Map();
  let section = null;
  let pending = [];
  const keys = [];
  for (let i = 0; i < arr.length; i++) {
    const l = arr[i];
    const sec = l.match(/^#\s*======\s*(.+?)\s*======\s*$/);
    if (sec) {
      section = sec[1];
      pending = [];
      if (!sections.has(section)) sections.set(section, []);
      continue;
    }
    if (l.trim().startsWith("#")) {
      pending.push(l.replace(/^#\s?/, ""));
      continue;
    }
    if (!l.trim()) continue;
    let m = l.match(/^([A-Z][A-Z0-9_]*):(?:\s*(.*))?$/);
    if (!m && kind === "env") m = l.match(/^([A-Z][A-Z0-9_]*)=(.*)$/);
    if (!m) {
      pending = [];
      continue;
    }
    const key = m[1];
    const val = (m[2] || "").replace(/\s+#.*$/, "").trim();
    const comments = pending.join("\n").trim();
    pending = [];
    if (!section) {
      section = "General";
      if (!sections.has(section)) sections.set(section, []);
    }
    const record = { key, val, line: i + 1, comments, section };
    sections.get(section).push(record);
    keys.push(record);
  }

  const layer = addNode({
    id: layerId,
    kind: "config",
    title: layerTitle,
    subtitle: `${keys.length} keys`,
    parent,
    summary: "The committed template is the public shape of configuration. Real values live in the gitignored config tree and are never read by this map.",
    source: sourceRef(rel, 1, 1),
    tags: ["config"],
    lane: "config",
  });
  addFact(layer, "Template", rel, true);
  addFact(layer, "Keys", keys.length);

  for (const [name, list] of sections) {
    const sid = `${layerId}/${slug(name)}`;
    const sn = addNode({
      id: sid,
      kind: "config",
      title: name,
      subtitle: `${list.length} keys`,
      parent: layerId,
      summary: "A configuration section from the committed template.",
      source: sourceRef(rel, findLine(text, `# ====== ${name}`) || 1, 1),
      tags: ["config"],
      lane: "config",
    });
    for (const k of list) {
      const kid = `${sid}/${slug(k.key)}`;
      k.nodeId = kid;
      const kn = addNode({
        id: kid,
        kind: "config",
        title: k.key,
        subtitle: "config key",
        parent: sid,
        summary: k.comments,
        source: sourceRef(rel, k.line, k.line),
        tags: ["config"],
        lane: "config",
      });
      addFact(kn, "Template value", k.val || "(empty)", true);
      const gen = (k.comments.match(/`([^`]+)`/) || [])[1] || (k.comments.match(/^#\s*(\S.*(?:openssl|docker|kubectl|authelia|mosquitto).*)$/m) || [])[1];
      if (gen) addFact(kn, "Generate", gen, true);
      if (/change_me|changeme|REPLACE_ME|<[^>]+>/.test(k.val)) kn.badges.push("required");
    }
  }
  return { layer, keys };
}

function buildConfigs() {
  const s = parseConfigFile("targets/srv0/config_template/values.yaml", "yaml", "srv0/ops", "srv0/config/values", "srv0 values.yaml");
  const v = parseConfigFile("targets/vps0/config_template/compose.env", "env", "vps0/ops", "vps0/config/compose", "vps0 compose.env");
  const vars = parseConfigFile("config_template/VARS.env", "env", "srv0/ops", "config/VARS", "Universal VARS.env");
  const all = [
    ...s.keys.map((k) => ({ ...k, layer: s.layer.id, scope: "srv0" })),
    ...v.keys.map((k) => ({ ...k, layer: v.layer.id, scope: "vps0" })),
    ...vars.keys.map((k) => ({ ...k, layer: vars.layer.id, scope: "all" })),
  ];
  return all;
}

/* ------------------------------------------------------------------ */
/* Renovate, workflows, systemd                                       */
/* ------------------------------------------------------------------ */

function buildRenovate() {
  const rel = "renovate.json";
  const text = sources.get(rel) || read(rel);
  let cfg;
  try {
    cfg = JSON.parse(text);
  } catch {
    return;
  }
  const n = addNode({
    id: "srv0/ops/renovate/config",
    kind: "config",
    title: "renovate.json",
    subtitle: "dependency policy",
    parent: "srv0/ops/renovate",
    summary:
      "Renovate's repository policy: built-in managers cover Kubernetes, Compose, and Dockerfiles; custom regex managers cover chart images, HelmChart versions, k3s plans, Traefik plugins, and pinned app integrations.",
    source: sourceRef(rel, 1, 1),
    tags: ["updates", "config"],
    facts: [
      { label: "Extends", value: (cfg.extends || []).join(", ") },
      { label: "Range strategy", value: cfg.rangeStrategy || "" },
      { label: "Automerge", value: String(cfg.automerge ?? false) },
      { label: "Custom managers", value: (cfg.customManagers || []).length },
      { label: "Package rules", value: (cfg.packageRules || []).length },
    ],
    lane: "config",
  });
  addFact(n, "Labels", (cfg.labels || []).join(", "));
  (cfg.customManagers || []).forEach((m, i) => {
    const id = `${n.id}/manager/${i + 1}`;
    const mnode = addNode({
      id,
      kind: "config",
      title: m.description ? m.description.split(/[.:(]/)[0].slice(0, 64) : `Manager ${i + 1}`,
      subtitle: m.datasourceTemplate || m.customType || "manager",
      parent: n.id,
      summary: m.description || "",
      source: sourceRef(rel, 1, 1),
      tags: ["updates", "config"],
      lane: "config",
    });
    addFact(mnode, "Type", m.customType || "");
    addFact(mnode, "Files", (m.managerFilePatterns || []).join(", "), true);
    addFact(mnode, "Datasource", m.datasourceTemplate || m.versioningTemplate || "");
    addEdge(n.id, id, "has-manager", mnode.title);
  });
  (cfg.packageRules || []).forEach((r, i) => {
    const id = `${n.id}/rule/${i + 1}`;
    const rnode = addNode({
      id,
      kind: "config",
      title: r.description ? r.description.split(/[.:(]/)[0].slice(0, 64) : `Rule ${i + 1}`,
      subtitle: r.groupName || (r.enabled === false ? "disabled" : "package rule"),
      parent: n.id,
      summary: r.description || "",
      source: sourceRef(rel, 1, 1),
      tags: ["updates", "config"],
      lane: "config",
    });
    if (r.matchUpdateTypes) addFact(rnode, "Update types", r.matchUpdateTypes.join(", "));
    if (r.matchFileNames) addFact(rnode, "Files", r.matchFileNames.join(", "));
    if (r.matchPackageNames) addFact(rnode, "Packages", r.matchPackageNames.join(", "));
    if (r.addLabels) addFact(rnode, "Labels", r.addLabels.join(", "));
    if (r.groupName) addFact(rnode, "Group", r.groupName);
    if (r.enabled === false) rnode.badges.push("disabled");
    addEdge(n.id, id, "has-rule", rnode.title);
  });
  addEdge(n.id, "srv0/base/renovate", "drives", "six-hourly");
  addEdge("srv0/ops/renovate", "concept/renovate-pr-ops", "manual-gate", "Infra PRs");
  addEdge("external/github", "concept/renovate-pr-ops", "publish", "image publish");
  addEdge("concept/renovate-pr-ops", "srv0/base/renovate/cronjob/renovate-infra", "creates-job", "on demand");
  addEdge("srv0/base/renovate", "srv0/ops/renovate", "configured-by", "renovate.json");

  addNode({
    id: "external/github",
    kind: "external",
    title: "GitHub",
    subtitle: "PRs · Actions · GHCR",
    parent: "srv0/ops/ci",
    summary: "Renovate opens PRs here, app CI runs tests and publishes images, and the Infra PRs stay behind the renovate-pr-ops approval gate.",
    tags: ["updates"],
    lane: "external",
  });
  addNode({
    id: "external/dockerhub",
    kind: "external",
    title: "Docker Hub",
    subtitle: "image metadata",
    parent: "srv0/ops/renovate",
    summary: "Used only for Renovate's registry lookups. Images themselves are pulled from their upstream registries.",
    tags: ["updates"],
    lane: "external",
  });
  addNode({
    id: "external/ghcr",
    kind: "external",
    title: "GHCR",
    subtitle: "first-party images",
    parent: "srv0/ops/renovate",
    summary: "Public GitHub Container Registry packages for first-party app images and the NFS server.",
    tags: ["updates"],
    lane: "external",
  });
  addEdge(n.id, "external/github", "opens-prs", "Renovate");
  addEdge(n.id, "external/ghcr", "tracks", "packages");
  addEdge(n.id, "external/dockerhub", "queries", "metadata");
}

function buildWorkflows(files) {
  for (const rel of files) {
    if (!rel.startsWith(".github/workflows/") || !rel.endsWith(".yml")) continue;
    const text = sources.get(rel) || read(rel);
    let wf;
    try {
      wf = YAML.parse(text);
    } catch {
      continue;
    }
    const base = path.basename(rel, ".yml");
    const id = `workflow/${slug(base)}`;
    const n = addNode({
      id,
      kind: "workflow",
      title: wf.name || base,
      subtitle: "GitHub Actions",
      parent: "srv0/ops/ci",
      summary: wf.run ? "" : "A GitHub Actions workflow that gates or publishes the repo.",
      source: sourceRef(rel, 1, lines(text).length),
      tags: ["updates", "ci"],
      lane: "ops",
    });
    addFact(n, "File", rel, true);
    addFact(n, "Triggers", Object.keys(wf.on || {}).join(", "));
    for (const [jobName, job] of Object.entries(wf.jobs || {})) {
      const jid = `${id}/job/${slug(jobName)}`;
      const jn = addNode({
        id: jid,
        kind: "job",
        title: job.name || jobName,
        subtitle: job.runs?.on || "job",
        parent: id,
        summary: "",
        source: sourceRef(rel, 1, 1),
        tags: ["ci"],
        lane: "runtime",
      });
      addFact(jn, "Runs on", job["runs-on"] || "");
      const steps = job.steps || [];
      addFact(jn, "Steps", steps.length);
      for (const [i, step] of steps.slice(0, 14).entries()) {
        const sid = `${jid}/step/${i + 1}`;
        const sn = addNode({
          id: sid,
          kind: "step",
          title: step.name || step.uses || String(step.run || "").split("\n")[0].slice(0, 52) || `Step ${i + 1}`,
          subtitle: step.uses ? "action" : "run",
          parent: jid,
          summary: "",
          source: sourceRef(rel, 1, 1),
          tags: ["ci"],
          lane: "runtime",
        });
        if (step.uses) addFact(sn, "Uses", step.uses, true);
        addEdge(jid, sid, "has-step", sn.title);
        const run = [step.run, step.with?.context, step.with?.file].filter(Boolean).join(" ");
        for (const m of run.matchAll(/scripts\/([A-Za-z0-9._-]+\.sh)/g)) {
          const sid2 = `script/${slug(m[1].replace(/\.sh$/, ""))}`;
          if (nodes.has(sid2)) addEdge(sn.id, sid2, "runs", m[1]);
        }
        if (step.with?.file?.includes("nfs-server-src")) addEdge(sn.id, "srv0/base/nfs-server", "builds", "image");
      }
      addEdge(n.id, jid, "has-job", jn.title);
    }
  }
}

function buildSystemd() {
  const rel = "targets/vps0/docker-prune/docker-image-prune.timer";
  if (!exists(rel)) return;
  const timerText = sources.get(rel) || read(rel);
  const serviceRel = "targets/vps0/docker-prune/docker-image-prune.service";
  const serviceText = sources.get(serviceRel) || read(serviceRel);
  const onCalendar = timerText.match(/OnCalendar=(.+)/)?.[1] || "monthly";
  const timer = addNode({
    id: "vps0/ops/docker-prune",
    kind: "timer",
    title: "docker image prune",
    subtitle: onCalendar,
    parent: "vps0/ops",
    summary: "Monthly systemd timer that prunes unused Docker images on vps0.",
    source: sourceRef(rel, 1, 1),
    tags: ["ops", "schedule", "storage"],
    facts: [{ label: "Schedule", value: onCalendar, mono: true }],
    lane: "ops",
  });
  const svc = addNode({
    id: "vps0/ops/docker-prune/service",
    kind: "step",
    title: "docker-image-prune.service",
    subtitle: "oneshot",
    parent: timer.id,
    summary: "",
    source: sourceRef(serviceRel, 1, 1),
    tags: ["ops"],
    lane: "runtime",
  });
  addFact(svc, "Exec", serviceText.match(/ExecStart=(.+)/)?.[1] || "", true);
  addEdge(timer.id, svc.id, "runs", "timer");
}

/* ------------------------------------------------------------------ */
/* Cards, decisions, tours                                             */
/* ------------------------------------------------------------------ */

function parseFrontmatter(text) {
  if (!text.startsWith("---\n")) return { data: {}, body: text };
  const end = text.indexOf("\n---\n", 4);
  if (end < 0) return { data: {}, body: text };
  const data = YAML.parse(text.slice(4, end)) || {};
  return { data, body: text.slice(end + 5).trim() };
}

function walk(dir) {
  if (!fs.existsSync(dir)) return [];
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap((e) =>
    e.isDirectory() ? walk(path.join(dir, e.name)) : [path.join(dir, e.name)],
  );
}

function buildCards() {
  for (const file of walk(path.join(CONTENT, "cards"))) {
    if (!file.endsWith(".md")) continue;
    const raw = fs.readFileSync(file, "utf8");
    const { data, body } = parseFrontmatter(raw);
    const card = { ...data, body, file: path.relative(ROOT, file) };
    if (data.appliesTo) {
      decisions.push(card);
      for (const id of data.appliesTo) {
        const n = nodes.get(id);
        if (!n) continue;
        n.decisions = n.decisions || [];
        n.decisions.push({ id: data.id, title: data.title || "Decision", body });
        n.tags.push("decisions");
      }
      continue;
    }
    if (data.id) {
      const n = nodes.get(data.id);
      if (n) {
        if (data.title) n.title = data.title;
        if (data.subtitle) n.subtitle = data.subtitle;
        if (data.summary) n.summary = data.summary;
        if (body) n.body = body;
        if (data.tags) n.tags = [...new Set([...n.tags, ...data.tags])];
        if (data.badges) n.badges = [...new Set([...n.badges, ...data.badges])];
        if (data.facts) for (const f of data.facts) addFact(n, f.label, f.value, f.mono);
      }
    }
    cards.push(card);
  }

  // Decision index nodes.
  for (const d of decisions) {
    const id = d.id || `decision/${slug(d.title || "decision")}`;
    const n = addNode({
      id,
      kind: "decision",
      title: d.title || "Decision",
      subtitle: "accepted tradeoff",
      parent: "srv0/ops/decisions",
      summary: d.body?.split("\n").find((l) => l.trim()) || "",
      source: sourceRef(d.file, 1, 1),
      tags: ["decisions"],
      lane: "config",
    });
    for (const target of d.appliesTo || []) {
      if (nodes.has(target)) addEdge(n.id, target, "affects", target);
    }
  }
}

function buildTours() {
  for (const file of walk(path.join(CONTENT, "tours"))) {
    if (!file.endsWith(".yaml") && !file.endsWith(".yml")) continue;
    const doc = YAML.parse(fs.readFileSync(file, "utf8"));
    if (!doc?.steps) continue;
    const steps = doc.steps.filter((s) => nodes.has(s.focus));
    if (!steps.length) continue;
    tours.push({ ...doc, steps, file: path.relative(ROOT, file) });
  }
  tours.sort((a, b) => (a.order || 99) - (b.order || 99) || a.title.localeCompare(b.title));
}

/* ------------------------------------------------------------------ */
/* Guided story                                                       */
/* ------------------------------------------------------------------ */

function storySize(n) {
  switch (n?.kind) {
    case "target": return { w: 230, h: 176 };
    case "system": return { w: 240, h: 158 };
    case "group": return { w: 190, h: 124 };
    case "component": return { w: 190, h: 146 };
    case "resource": return { w: 185, h: 146 };
    case "route": return { w: 185, h: 122 };
    case "script": return { w: 190, h: 134 };
    case "step": return { w: 185, h: 112 };
    case "config": return { w: 190, h: 130 };
    case "decision": return { w: 190, h: 130 };
    case "external": return { w: 165, h: 108 };
    case "concept": return { w: 190, h: 146 };
    case "workflow": return { w: 190, h: 122 };
    case "timer": return { w: 190, h: 120 };
    default: return { w: 190, h: 124 };
  }
}

function buildToursYaml() {
  const rel = "explorer/content/tours.yaml";
  if (!exists(rel)) return [];
  const doc = YAML.parse(read(rel));
  return (doc.tours || []).map((t) => ({
    id: t.id,
    title: t.title,
    subtitle: t.subtitle || "",
    description: t.description || "",
    duration: t.duration || "",
    recommended: !!t.recommended,
    chapters: t.chapters || [],
  }));
}

function buildStory() {
  const storyRel = "explorer/content/story.yaml";
  if (!exists(storyRel)) return null;
  const doc = YAML.parse(read(storyRel));
  const steps = [];

  for (const [index, step] of (doc.steps || []).entries()) {
    const flow = step.flow || [];
    const visible = [...new Set(flow.flat())];
    if (!visible.length) throw new Error(`chapter ${step.id} has no flow`);
    const cols = flow.map((col) => col.map((id) => {
      const n = nodes.get(id);
      if (!n) throw new Error(`chapter ${step.id} missing node ${id}`);
      return { id, node: n, size: storySize(n) };
    }));
    const gapX = Math.max(40, Number(step.gapX) || 64);
    const gapY = 22;
    const left = 34;
    const top = 86;
    const widths = cols.map((col) => Math.max(...col.map((x) => x.size.w)));
    const colHeights = cols.map((col) => col.reduce((h, x) => h + x.size.h, 0) + Math.max(0, col.length - 1) * gapY);
    const maxH = Math.max(...colHeights);
    let x = left;
    const positions = new Map();
    for (let c = 0; c < cols.length; c++) {
      const col = cols[c];
      let y = top + (maxH - colHeights[c]) / 2;
      for (const item of col) {
        positions.set(item.id, { x: x + (widths[c] - item.size.w) / 2, y, w: item.size.w, h: item.size.h });
        y += item.size.h + gapY;
      }
      x += widths[c] + gapX;
    }
    const sceneNodes = visible.map((id) => ({
      id,
      isNew: (step.reveal || []).includes(id),
      ...positions.get(id),
      lane: "runtime",
    }));
    const byId = new Map(sceneNodes.map((n) => [n.id, n]));
    const pad = 28;
    const zoneDefs = step.zones || [];
    const zones = zoneDefs.map((z) => {
      const members = (z.members || []).map((id) => byId.get(id)).filter(Boolean);
      if (!members.length) return null;
      const zx = Math.min(...members.map((n) => n.x)) - pad;
      const zy = Math.min(...members.map((n) => n.y)) - 34;
      const zr = Math.max(...members.map((n) => n.x + n.w)) + pad;
      const zb = Math.max(...members.map((n) => n.y + n.h)) + pad - 6;
      return { id: z.id, label: z.label, members: z.members, x: zx, y: zy, w: zr - zx, h: zb - zy };
    }).filter(Boolean);
    const edges = (step.edges || []).map((e, i) => {
      if (!nodes.has(e.from)) throw new Error(`chapter ${step.id} missing edge from ${e.from}`);
      if (!nodes.has(e.to)) throw new Error(`chapter ${step.id} missing edge to ${e.to}`);
      return { id: `chapter-${step.id}-${i}`, from: e.from, to: e.to, type: e.type || "related", label: e.label != null ? String(e.label) : "" };
    }).filter((e) => byId.has(e.from) && byId.has(e.to));
    const explicitCode = step.code || [];
    const code = explicitCode.length
      ? explicitCode.map((c) => {
          if (!exists(c.path)) throw new Error(`chapter ${step.id} missing code ${c.path}`);
          return { path: c.path, summary: c.summary || "", source: sourceRef(c.path, 1, 1) };
        })
      : [...new Map(visible.map((id) => {
          const n = nodes.get(id);
          if (!n?.source?.path) return null;
          return [n.source.path, {
            path: n.source.path,
            summary: (n.summary || n.title || "").split("\n")[0],
            source: n.source,
          }];
        }).filter(Boolean)).values()].slice(0, 6);
    const width = Math.max(520, x - gapX + left);
    const height = Math.max(360, top + maxH + 84);
    steps.push({
      id: step.id,
      number: index + 1,
      stage: step.stage || "",
      title: step.title || step.id,
      body: step.body || "",
      deepDive: step.deepDive || "",
      recap: !!step.recap,
      reveal: step.reveal || [],
      focus: step.focus || [],
      visibleNodes: sceneNodes,
      edges,
      newEdges: edges,
      zones,
      code,
      width,
      height,
    });
  }

  const tours = buildToursYaml();
  const chapterIds = new Set(steps.map((x) => x.id));
  for (const t of tours) {
    for (const id of t.chapters) {
      if (!chapterIds.has(id)) throw new Error(`tour ${t.id} references missing chapter ${id}`);
    }
  }
  return {
    title: doc.title,
    subtitle: doc.subtitle,
    cover: doc.cover || {},
    stages: doc.stages || [],
    steps,
    tours,
    width: 1740,
    height: 1200,
  };
}

/* ------------------------------------------------------------------ */
/* Scenes, lenses, layout                                             */
/* ------------------------------------------------------------------ */

function sizeFor(n) {
  if (n.w && n.h) return { w: n.w, h: n.h };
  switch (n.kind) {
    case "system": return { w: 280, h: 130 };
    case "target": return { w: 286, h: 156 };
    case "group": return { w: 224, h: 104 };
    case "component": return { w: 214, h: 96 };
    case "resource": return { w: 206, h: 88 };
    case "container": return { w: 196, h: 82 };
    case "route": return { w: 210, h: 84 };
    case "script": return { w: 224, h: 94 };
    case "step": return { w: 202, h: 78 };
    case "config": return { w: 214, h: 82 };
    case "decision": return { w: 224, h: 100 };
    case "lens": return { w: 190, h: 92 };
    case "workflow": return { w: 220, h: 92 };
    case "job": return { w: 200, h: 82 };
    case "external": return { w: 172, h: 92 };
    case "image": return { w: 190, h: 72 };
    case "timer": return { w: 204, h: 84 };
    default: return { w: 210, h: 86 };
  }
}

const LANE_LABELS = {
  external: "Context",
  entry: "Entry",
  runtime: "Runtime",
  data: "Data",
  security: "Security",
  config: "Configuration",
  ops: "Operations",
  source: "Source",
};

function defaultLane(n) {
  if (n.lane) return n.lane;
  if (n.kind === "external" || n.kind === "target") return "external";
  if (n.kind === "script" || n.kind === "timer" || n.kind === "workflow" || n.kind === "job") return "ops";
  if (n.kind === "config" || n.kind === "decision") return "config";
  if (n.kind === "route" || n.kind === "lens") return "entry";
  return "runtime";
}

function autoLayout(children) {
  const boundary = children.filter((c) => c.boundary);
  const main = children.filter((c) => !c.boundary);
  const laneMap = new Map();
  for (const c of main) {
    const n = nodes.get(c.id);
    if (!n) continue;
    const lane = defaultLane(n);
    if (!laneMap.has(lane)) laneMap.set(lane, []);
    laneMap.get(lane).push({ ...c, node: n, size: sizeFor(n) });
  }
  // A single ops item in a component scene reads better beside the runtime.
  if (laneMap.has("ops") && laneMap.get("ops").length === 1 && laneMap.has("runtime")) {
    laneMap.get("runtime").push(...laneMap.get("ops"));
    laneMap.delete("ops");
  }
  const present = LANE_ORDER.filter((l) => laneMap.has(l));
  const maxRows = 5;
  const gapX = 84;
  const gapY = 30;
  const top = 118;
  const zones = [];
  let x = 60;
  let maxH = 0;
  for (const lane of present) {
    const items = laneMap.get(lane).sort((a, b) => (a.node.order || 0) - (b.node.order || 0) || a.node.title.localeCompare(b.node.title));
    const cols = Math.max(1, Math.ceil(items.length / maxRows));
    const rows = Math.min(maxRows, items.length);
    const colWidth = Math.max(...items.map((i) => i.size.w)) + gapX;
    const laneW = cols * colWidth - gapX;
    const rowH = Math.max(...items.map((i) => i.size.h)) + gapY;
    const laneH = rows * rowH - gapY;
    const y0 = top + 20;
    for (let i = 0; i < items.length; i++) {
      const col = Math.floor(i / maxRows);
      const row = i % maxRows;
      const it = items[i];
      it.node.layout = {
        x: x + 26 + col * colWidth + (colWidth - it.size.w) / 2,
        y: y0 + row * rowH + (Math.max(...items.map((j) => j.size.h)) - it.size.h) / 2,
        w: it.size.w,
        h: it.size.h,
      };
    }
    zones.push({ id: lane, label: LANE_LABELS[lane] || lane, x, y: 58, w: laneW + 52, h: laneH + 70 });
    maxH = Math.max(maxH, laneH);
    x += laneW + 52 + gapX;
  }
  const mainWidth = Math.max(700, x - gapX + 40);
  let width = mainWidth;
  let height = top + maxH + 120;
  if (boundary.length) {
    const perRow = 6;
    const bw = Math.max(224, ...boundary.map((it) => nodes.get(it.id) ? sizeFor(nodes.get(it.id)).w : 0));
    const bh = Math.max(100, ...boundary.map((it) => nodes.get(it.id) ? sizeFor(nodes.get(it.id)).h : 0));
    const bgap = 22;
    const rows = Math.ceil(boundary.length / perRow);
    const boundaryWidth = Math.min(perRow, boundary.length) * (bw + bgap) - bgap;
    width = Math.max(width, boundaryWidth + 120);
    const by = top + maxH + 100;
    boundary.forEach((it, i) => {
      const n = nodes.get(it.id);
      if (!n) return;
      const row = Math.floor(i / perRow);
      const col = i % perRow;
      n.layout = {
        x: 60 + col * (bw + bgap) + (bw - sizeFor(n).w) / 2,
        y: by + row * (bh + bgap),
        w: sizeFor(n).w,
        h: sizeFor(n).h,
      };
    });
    const zh = rows * (bh + bgap) - bgap + 58;
    zones.push({ id: "linked", label: "Linked context", x: 38, y: by - 34, w: boundaryWidth + 46, h: zh });
    height = by + rows * (bh + bgap) + 50;
  }
  return { zones, width, height };
}

const manualLayouts = {
  system: {
    zones: [
      { id: "edge", label: "PUBLIC EDGE", x: 300, y: 142, w: 360, h: 220 },
      { id: "cluster", label: "HOME CLUSTER", x: 300, y: 390, w: 360, h: 250 },
      { id: "planes", label: "CROSS-CUTTING", x: 760, y: 120, w: 300, h: 540 },
    ],
    nodes: {
      "external/internet": { x: 440, y: 22, w: 172, h: 92 },
      vps0: { x: 340, y: 172, w: 286, h: 156 },
      srv0: { x: 340, y: 430, w: 286, h: 156 },
      "concept/lens/updates": { x: 810, y: 150, w: 190, h: 92 },
      "concept/lens/storage": { x: 810, y: 270, w: 190, h: 92 },
      "concept/lens/auth": { x: 810, y: 390, w: 190, h: 92 },
      "concept/lens/observability": { x: 810, y: 510, w: 190, h: 92 },
      "concept/about": { x: 70, y: 300, w: 208, h: 100 },
    },
    width: 1120,
    height: 720,
  },
  srv0: {
    zones: [
      { id: "platform", label: "PLATFORM", x: 300, y: 100, w: 290, h: 260 },
      { id: "apps", label: "APPS", x: 650, y: 100, w: 290, h: 260 },
      { id: "cluster", label: "CLUSTER", x: 300, y: 400, w: 290, h: 240 },
      { id: "compose", label: "SIDECAR", x: 650, y: 400, w: 290, h: 160 },
      { id: "ops", label: "OPERATIONS", x: 650, y: 590, w: 290, h: 170 },
    ],
    nodes: {
      "srv0/base": { x: 340, y: 150, w: 224, h: 104 },
      "srv0/apps": { x: 690, y: 150, w: 224, h: 104 },
      "srv0/cluster": { x: 340, y: 460, w: 224, h: 104 },
      "srv0/compose": { x: 690, y: 450, w: 224, h: 104 },
      "srv0/ops": { x: 690, y: 630, w: 224, h: 104 },
    },
    width: 1020,
    height: 820,
  },
  vps0: {
    zones: [
      { id: "edge", label: "EDGE", x: 300, y: 100, w: 320, h: 280 },
      { id: "apps", label: "APPS", x: 680, y: 100, w: 290, h: 280 },
      { id: "ops", label: "OPS", x: 680, y: 420, w: 290, h: 220 },
    ],
    nodes: {
      "vps0/edge": { x: 340, y: 160, w: 224, h: 104 },
      "vps0/apps": { x: 720, y: 160, w: 224, h: 104 },
      "vps0/ops": { x: 720, y: 470, w: 224, h: 104 },
      "srv0": { x: 40, y: 300, w: 286, h: 156 },
    },
    width: 1040,
    height: 720,
  },
};

function sceneFor(id, title, childIds, options = {}) {
  const childSet = new Set(childIds.map((c) => (typeof c === "string" ? c : c.id)));
  const edgeList = [...edges.values()].filter((e) =>
    childSet.has(e.from) && childSet.has(e.to) && (e.type !== "tracked-by" || options.keepTrackedBy),
  );
  const children = childIds.map((c) => (typeof c === "string" ? { id: c } : c));
  const manual = manualLayouts[id];
  let layout;
  let zones;
  if (manual) {
    for (const c of children) {
      const n = nodes.get(c.id);
      if (!n) continue;
      const pos = manual.nodes[c.id] || { x: 60, y: 60, w: sizeFor(n).w, h: sizeFor(n).h };
      n.layout = pos;
    }
    layout = { width: manual.width, height: manual.height };
    zones = manual.zones || [];
  } else {
    const result = autoLayout(children);
    layout = { width: result.width, height: result.height };
    zones = result.zones;
  }
  return {
    id,
    title,
    subtitle: options.subtitle || "",
    kind: options.kind || "containment",
    lensId: options.lensId,
    nodes: children.map((c) => {
      const n = nodes.get(c.id);
      if (!n) return null;
      return {
        id: n.id,
        boundary: !!c.boundary,
        x: n.layout.x,
        y: n.layout.y,
        w: n.layout.w,
        h: n.layout.h,
        lane: c.boundary ? "external" : defaultLane(n),
      };
    }).filter(Boolean),
    edges: edgeList,
    zones,
    ...layout,
  };
}

function buildScenes() {
  const scenes = new Map();
  scenes.set("system", sceneFor("system", "Infra", ["external/internet", "vps0", "srv0",
    "concept/lens/updates", "concept/lens/storage", "concept/lens/auth", "concept/lens/observability",
    "concept/about"],
    { subtitle: "srv0 + vps0 · click a card to inspect, double-click to enter" }));

  // Direct children for every non-leaf node.
  const byParent = new Map();
  for (const n of nodes.values()) {
    if (!n.parent) continue;
    if (!byParent.has(n.parent)) byParent.set(n.parent, []);
    byParent.get(n.parent).push(n);
  }

  for (const [parent, kids] of byParent) {
    const p = nodes.get(parent);
    if (!p || p.kind === "system") continue;
    if (kids.length === 0 || kids.length > 44) continue;
    const childIds = kids.map((k) => k.id);
    // Boundary nodes: important outside references.
    const boundary = new Map();
    for (const k of kids) {
      for (const e of edges.values()) {
        const other = e.from === k.id ? e.to : e.to === k.id ? e.from : null;
        if (!other || other === parent || childIds.includes(other) || !nodes.has(other)) continue;
        const on = nodes.get(other);
        if (on.context && on.parent !== parent) continue;
        if (kids.some((k) => on.parent === k.id)) continue;
        if (e.type === "tracked-by" && p.kind !== "component" && p.kind !== "resource") continue;
        if (on.kind === "component" && p.kind !== "component" && kids.every((k) => k.kind !== "component")) continue;
        if (on.kind === "component" && kids.length > 10) continue;
        const allowed = ["target", "group", "concept", "lens", "external", "component"];
        if (!allowed.includes(on.kind)) {
          if (!(on.kind === "resource" && ["Gateway", "StorageClass", "Middleware"].includes(on.resource?.kind))) continue;
        }
        boundary.set(other, (boundary.get(other) || 0) + 1);
      }
    }
    const boundaryIds = [...boundary.entries()].sort((a, b) => b[1] - a[1]).slice(0, 5).map(([id]) => id);
    const all = [...childIds, ...boundaryIds.map((id) => ({ id, boundary: true }))];
    const sub = p.kind === "target" ? p.subtitle : "";
    scenes.set(parent, sceneFor(parent, p.title, all, {
      subtitle: sub,
      keepTrackedBy: p.kind === "component" || p.kind === "resource",
    }));
  }

  // Lens scenes.
  const lensDefs = [
    {
      id: "updates",
      title: "Updates",
      subtitle: "Every image and chart is tracked · open a group for pins",
      include: ["srv0/base", "srv0/apps", "vps0/edge", "vps0/apps", "srv0/ops/renovate",
        "srv0/base/renovate", "srv0/ops/ci", "external/github", "external/ghcr",
        "external/dockerhub", "workflow/validate", "workflow/nfs-server-image"],
    },
    {
      id: "storage",
      title: "Storage",
      subtitle: "NFS backbone · host paths · backups",
      include: ["srv0/base/nfs-server", "srv0/base/host-volumes", "srv0/base/csi-driver-nfs",
        "srv0/base/csi-driver-nfs/storageclass/nfs-apps", "srv0/ops/backups", "script/restic-restore",
        "srv0/apps", "vps0/apps", "srv0/apps/media/immich", "srv0/apps/media/frigate",
        "srv0/apps/home/homeassistant", "srv0/apps/productivity/nextcloud",
        "srv0/apps/home/syncthing", "srv0/ops/backups", "srv0/apps/dscpln/dscpln-task-runner"],
    },
    {
      id: "auth",
      title: "Auth & security",
      subtitle: "Authelia · CrowdSec · routes · certificates",
      include: ["external/internet", "vps0", "vps0/edge", "vps0/apps",
        "vps0/service/authelia", "vps0/service/authelia-db", "vps0/service/crowdsec",
        "vps0/service/traefik", "srv0/base/authelia", "srv0/base/crowdsec",
        "srv0/base/crowdsec-web-ui", "srv0/base/traefik", "srv0/base/gateway",
        "srv0/base/edge-certs", "srv0/apps"],
    },
    {
      id: "observability",
      title: "Observability",
      subtitle: "Alloy · Prometheus · Loki · Grafana · ntfy · Falco",
      include: ["srv0/base/monitoring", "srv0/base/ntfy", "srv0/base/falco",
        "vps0/service/logtfy", "vps0/service/uptime", "vps0/service/dozzle",
        "srv0/ops/renovate", "srv0/ops/ci"],
    },
    {
      id: "schedule",
      title: "Schedule",
      subtitle: "CronJobs · timers · schedules",
      include: ["srv0/base/renovate", "srv0/base/renovate/cronjob/renovate-daily",
        "vps0/ops/docker-prune", "vps0/ops/docker-prune/service",
        "workflow/validate", "workflow/nfs-server-image", "srv0/ops/ci"],
    },
    {
      id: "network",
      title: "Network",
      subtitle: "Internet · edge · routes · tunnel · VPN",
      include: ["external/internet", "vps0", "srv0", "vps0/edge", "vps0/service/traefik",
        "vps0/service/public-exposure-server-wg", "concept/public-exposure",
        "srv0/service/public-exposure-client-wg", "srv0/base/gateway", "srv0/base/traefik",
        "srv0/base/vpn", "srv0/base/cert-manager"],
    },
    {
      id: "config",
      title: "Configuration",
      subtitle: "Template sections · consumers · generation commands",
      include: ["srv0/config/values", "vps0/config/compose", "config/VARS"],
    },
    {
      id: "decisions",
      title: "Decisions",
      subtitle: "Accepted tradeoffs attached to components",
      include: [],
    },
  ];
  const lenses = [];
  for (const def of lensDefs) {
    let ids = [...new Set(def.include)].filter((id) => nodes.has(id));
    if (def.id === "config") {
      // Layers and sections, not every key.
      ids = ["srv0/config/values", "vps0/config/compose", "config/VARS"].filter((id) => nodes.has(id));
    }
    if (def.id === "decisions") {
      ids = [...nodes.values()].filter((n) => n.kind === "decision").map((n) => n.id);
    }
    const sceneId = `lens/${def.id}`;
    scenes.set(sceneId, sceneFor(sceneId, def.title, ids, { kind: "lens", subtitle: def.subtitle, lensId: def.id }));
    lenses.push({ id: def.id, title: def.title, subtitle: def.subtitle, sceneId, count: ids.length });
  }

  return { scenes, lenses };
}

/* ------------------------------------------------------------------ */
/* summaries / badges                                                 */
/* ------------------------------------------------------------------ */

function finishNodes() {
  const byParent = new Map();
  for (const n of nodes.values()) {
    if (!n.parent) continue;
    if (!byParent.has(n.parent)) byParent.set(n.parent, []);
    byParent.get(n.parent).push(n);
  }
  for (const n of nodes.values()) {
    // Authored facts override generated facts with the same label; never render
    // the same field twice (e.g. two Orchestrator rows on vps0).
    const factMap = new Map();
    for (const fact of n.facts) factMap.set(fact.label.toLowerCase(), fact);
    n.facts = [...factMap.values()];
    const kids = byParent.get(n.id) || [];
    if (kids.length) {
      n.hasChildren = true;
      n.childCount = kids.length;
      if (!n.subtitle && n.kind === "group") n.subtitle = `${kids.length} components`;
    }
    if (!n.summary) {
      if (n.kind === "group") n.summary = `${n.title} groups ${kids.length} related components.`;
      else if (n.kind === "component") n.summary = `${n.title} component.`;
      else if (n.kind === "route") n.summary = "An exposed HTTP route.";
      else if (n.kind === "resource") n.summary = `${n.resource?.kind || "Kubernetes resource"} ${n.title}.`;
      else if (n.kind === "config") n.summary = "Configuration surface.";
      else n.summary = "";
    }
    // Badges from facts.
    const allFacts = n.facts.map((f) => `${f.label}=${f.value}`).join(" ");
    if (/public|websecure-proxy|home\.|Host\(/i.test(allFacts) && !n.badges.includes("public")) n.badges.push("public");
    if (/storageClass|nfs-apps|auto-backup/i.test(allFacts) && !n.badges.includes("storage")) n.badges.push("storage");
    if (/(?:intel-gpu|amd-igpu|amd-dgpu|vaapi|conbee)/.test(allFacts) && !n.badges.includes("gpu")) n.badges.push("gpu");
    if (n.tags.includes("auth") && !n.badges.includes("auth")) n.badges.push("auth");
    if (n.tags.includes("backup") && !n.badges.includes("backup")) n.badges.push("backup");
    if (n.tags.includes("schedule") && !n.badges.includes("schedule")) n.badges.push("schedule");
    n.badges = [...new Set(n.badges)].slice(0, 4);
  }
}

/* ------------------------------------------------------------------ */
/* main                                                               */
/* ------------------------------------------------------------------ */

function main() {
  const files = trackedFiles();
  indexSources(files);

  addTargets();
  buildK8s();
  buildCompose();
  buildScripts(files);
  const configKeys = buildConfigs();
  buildRenovate();
  buildWorkflows(files);
  buildSystemd();
  buildCards();
  buildTours();
  const story = buildStory();

  // Config usage edges. Scan every indexed file for key references.
  const keyIndex = new Map();
  for (const k of configKeys) {
    if (!nodes.has(k.nodeId)) continue;
    if (!keyIndex.has(k.key)) keyIndex.set(k.key, []);
    keyIndex.get(k.key).push({ id: k.nodeId, scope: k.scope });
  }
  // Compose files are shared by many services; attach config reads to the
  // target group so the key detail still lists a meaningful consumer.
  if (!fileToNode.has("targets/vps0/compose/compose.yaml")) fileToNode.set("targets/vps0/compose/compose.yaml", nodes.get("vps0"));
  if (!fileToNode.has("targets/srv0/compose/compose.yaml")) fileToNode.set("targets/srv0/compose/compose.yaml", nodes.get("srv0"));
  for (const [rel, text] of sources) {
    const consumer = fileToNode.get(rel);
    if (!consumer) continue;
    for (const [key, targets] of keyIndex) {
      if (!new RegExp(`(?:\\$\\{${key}\\}|\\.Values\\.${key}\\b|\\$${key}\\b|config_env\\s+\\S+\\s+${key}\\b)`).test(text)) continue;
      for (const t of targets) {
        if (t.scope === "all" || t.scope === consumer.id.split("/")[0] || consumer.id === "vps0" && t.scope === "vps0" || consumer.id === "srv0" && t.scope === "srv0") {
          addEdge(consumer.id, t.id, "reads-config", key);
        }
      }
    }
  }

  // Link workload/script nodes to images and Renovate update plane.
  for (const n of nodes.values()) {
    if (n.tags.includes("updates") && (n.kind === "component" || n.kind === "resource" || n.kind === "script" || n.kind === "container" || n.kind === "image")) {
      addEdge(n.id, "srv0/ops/renovate", "tracked-by", "Renovate");
    }
    if (n.kind === "resource" && n.resource?.kind === "HelmChart") {
      addEdge(n.id, "srv0/ops/renovate", "tracked-by", "chart version");
    }
  }

  // Roll resource-level relationships up to their components so group scenes
  // show meaningful connections without drawing every PVC edge.
  for (const e of [...edges.values()]) {
    const a = nodes.get(e.from);
    const b = nodes.get(e.to);
    if (!a || !b || !a.parent || !b.parent || a.parent === b.parent) continue;
    const oneResource = a.kind === "resource" || a.kind === "image" || a.kind === "container";
    const otherResource = b.kind === "resource" || b.kind === "script" || b.kind === "config";
    if (e.type === "tracked-by" || e.type === "reads-config") continue;
    if (oneResource && otherResource) {
      addEdge(a.parent, b.parent, "related", e.type);
    }
  }

  finishNodes();
  // The guided tours render their own chapters. No atlas scenes are emitted.
  const scenes = new Map();
  const lenses = [];

  // Ensure all edges point at real nodes.
  const cleanEdges = [...edges.values()].filter((e) => nodes.has(e.from) && nodes.has(e.to));

  // Attach scene id to nodes.
  for (const [id, scene] of scenes) {
    const n = nodes.get(id);
    if (n && id !== "system" && !id.startsWith("lens/")) n.sceneId = id;
  }

  const graph = {
    schemaVersion: 1,
    generatedAt: now,
    gitSha,
    scope: { primary: ["srv0", "vps0"], context: ["bigpc", "rpi"], mentions: ["pc"] },
    nodes: Object.fromEntries([...nodes.entries()].sort(([a], [b]) => a.localeCompare(b))),
    edges: cleanEdges,
    scenes: Object.fromEntries([...scenes.entries()].sort(([a], [b]) => a.localeCompare(b))),
    lenses,
    tours,
    decisions: decisions.map((d) => ({ id: d.id, title: d.title, body: d.body, appliesTo: d.appliesTo, file: d.file })),
    story,
    stats: {
      nodes: nodes.size,
      edges: cleanEdges.length,
      scenes: scenes.size,
      files: files.length,
      decisions: decisions.length,
      tours: tours.length,
      storySteps: story?.steps?.length || 0,
    },
  };

  fs.mkdirSync(OUT_DATA, { recursive: true });
  fs.writeFileSync(path.join(OUT_DATA, "graph.json"), JSON.stringify(graph, null, 0));
  console.log(
    `map: ${graph.stats.nodes} nodes, ${graph.stats.edges} edges, ` +
    `${story?.steps?.length || 0} chapters, ${story?.tours?.length || 0} guided tours, ` +
    `${graph.stats.decisions} decisions, ${graph.stats.files} files`,
  );
}

main();
