import { visit } from "unist-util-visit";
import yaml from "yaml";

const REQUIRED = [
  "title", "chapter_id", "audience", "prereqs", "estimated_reading_min",
  "shots", "glossary_refs", "features_refs", "fixtures_refs",
  "brand_reviewed", "lead_approved",
];
const AUDIENCES = new Set(["bench-scientist", "analyst", "power-user"]);
const SHOT_RE = /<!--\s*SHOT:\s*([a-z0-9][a-z0-9-]*)\s*-->/g;

export default function frontmatter() {
  return (tree, file) => {
    let fm = null;
    visit(tree, "yaml", (node) => { fm = node; });
    if (!fm) {
      file.message("chapter is missing YAML frontmatter");
      return;
    }

    let data;
    try { data = yaml.parse(fm.value); } catch (e) {
      file.message(`frontmatter YAML parse error: ${e.message}`, fm);
      return;
    }

    for (const key of REQUIRED) {
      if (!(key in data)) file.message(`missing required key: ${key}`, fm);
    }

    if (data.audience && !AUDIENCES.has(data.audience)) {
      file.message(`audience must be one of: ${[...AUDIENCES].join(", ")}`, fm);
    }

    const declaredShots = new Set((data.shots ?? []).map((s) => s.id));
    const usedShots = new Set();
    visit(tree, "html", (node) => {
      for (const m of node.value.matchAll(SHOT_RE)) usedShots.add(m[1]);
    });

    for (const id of declaredShots) {
      if (!usedShots.has(id)) file.message(`shot '${id}' declared in frontmatter but no <!-- SHOT: ${id} --> marker in body`, fm);
    }
    for (const id of usedShots) {
      if (!declaredShots.has(id)) file.message(`<!-- SHOT: ${id} --> marker has no matching entry in frontmatter shots[]`);
    }
  };
}
