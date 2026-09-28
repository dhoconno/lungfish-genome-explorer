import { visit } from "unist-util-visit";

const MAX_ITEMS = 5;       // max items per list
const MAX_LISTS = 2;       // max lists per section, where a section is an H2 or H3

export default function bulletCap() {
  return (tree, file) => {
    // --- Rule 1: per-list item cap ---
    visit(tree, "list", (node) => {
      if (node.children.length > MAX_ITEMS) {
        file.message(
          `list has ${node.children.length} items. Cap is ${MAX_ITEMS} per list. Split into multiple lists or use a table.`,
          node,
        );
      }
    });

    // --- Rule 2: per-section list count cap ---
    // Walk top-level children in document order, segmenting by headings. The
    // counter resets at every H2 and every H3, because the rule exists to stop
    // a wall of bullets inside one stretch of prose a reader takes in at once,
    // and an H3 starts such a stretch just as an H2 does. Before 2026-09-27
    // only H2 reset it, which penalised a page whose H2 is a container for
    // several independent H3 items (a study-questions tier, for instance).
    let listsInSection = 0;

    for (const child of tree.children) {
      if (child.type === "heading" && (child.depth === 2 || child.depth === 3)) {
        listsInSection = 0;
        continue;
      }
      if (child.type === "list") {
        listsInSection += 1;
        if (listsInSection > MAX_LISTS) {
          file.message(
            `${listsInSection}${ordinalSuffix(listsInSection)} list in this section. Cap is ${MAX_LISTS} lists per H2 or H3 section. Restructure with subheadings or prose.`,
            child,
          );
        }
      }
    }
  };
}

function ordinalSuffix(n) {
  if (n === 2) return "nd";
  if (n === 3) return "rd";
  return "th";
}
