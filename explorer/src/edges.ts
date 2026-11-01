export const edgeCategory = (type: string): string => {
  if (["routes-to", "routes-through", "tunnels-to", "forwards-to", "exposes", "selects", "reaches", "provides", "feeds"].includes(type)) return "traffic";
  if (["guarded-by", "protects", "presents", "authenticates", "observes"].includes(type)) return "auth";
  if (["mounts", "provisioned-by", "bound-to", "backs-up", "pinned-to", "pins", "stores-on"].includes(type)) return "storage";
  if (["tracked-by", "updates", "configured-by", "drives", "opens-prs", "tracks", "queries", "builds"].includes(type)) return "updates";
  if (["reads-config", "uses-config", "uses-secret", "configures"].includes(type)) return "config";
  return "ops";
};

export const edgeLabel = (type: string) => type.replace(/-/g, " ");
