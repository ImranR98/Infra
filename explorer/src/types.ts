export type GraphNode = {
  id: string;
  kind: string;
  title: string;
  subtitle?: string;
  summary?: string;
  body?: string;
  parent?: string;
  tags: string[];
  badges: string[];
  facts: { label: string; value: string; mono?: boolean }[];
  source?: { path: string; line: number; endLine?: number; key: string } | null;
  decisions?: { id: string; title: string; body: string }[];
  childCount?: number;
  hasChildren?: boolean;
  sceneId?: string;
  context?: boolean;
  optional?: boolean;
  action?: { type: string; id: string };
  resource?: { kind: string; name: string; namespace?: string };
};

export type GraphEdge = {
  id: string;
  from: string;
  to: string;
  type: string;
  label?: string;
};

export type SceneNode = {
  id: string;
  boundary?: boolean;
  x: number;
  y: number;
  w: number;
  h: number;
  lane: string;
};

export type Zone = { id: string; label: string; members?: string[]; x: number; y: number; w: number; h: number };

export type Scene = {
  id: string;
  title: string;
  subtitle?: string;
  kind: string;
  lensId?: string;
  nodes: SceneNode[];
  edges: GraphEdge[];
  zones: Zone[];
  width: number;
  height: number;
};

export type Lens = { id: string; title: string; subtitle: string; sceneId: string; count: number };

export type StoryNode = {
  id: string;
  isNew: boolean;
  x: number;
  y: number;
  w: number;
  h: number;
  lane: string;
};

export type StoryStep = {
  id: string;
  number: number;
  stage: string;
  title: string;
  body: string;
  deepDive: string;
  recap: boolean;
  reveal: string[];
  focus: string[];
  visibleNodes: StoryNode[];
  edges: GraphEdge[];
  newEdges: GraphEdge[];
  zones: Zone[];
  code: { path: string; summary: string; source: { path: string; line: number; endLine?: number; key: string } }[];
  width: number;
  height: number;
};

export type TourSummary = {
  id: string;
  title: string;
  subtitle: string;
  description: string;
  duration: string;
  recommended: boolean;
  chapters: string[];
};

export type Story = {
  title: string;
  subtitle: string;
  cover: { kicker?: string; title?: string; intro?: string; startLabel?: string; resumeLabel?: string };
  stages: string[];
  steps: StoryStep[];
  tours: TourSummary[];
  width: number;
  height: number;
};

export type TourStep = { focus: string; title: string; body: string };

export type Tour = {
  id: string;
  title: string;
  description?: string;
  steps: TourStep[];
  file?: string;
};

export type Graph = {
  schemaVersion: number;
  generatedAt: string;
  gitSha: string;
  scope: { primary: string[]; context: string[]; mentions: string[] };
  nodes: Record<string, GraphNode>;
  edges: GraphEdge[];
  scenes: Record<string, Scene>;
  lenses: Lens[];
  tours: Tour[];
  decisions: { id: string; title: string; body: string; appliesTo: string[]; file: string }[];
  story: Story | null;
  stats: { nodes: number; edges: number; scenes: number; files: number; decisions: number; tours: number; storySteps?: number };
};
