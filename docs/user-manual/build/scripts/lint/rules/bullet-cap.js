import { visit } from "unist-util-visit";

const MAX_ITEMS = 5;       // max items per list
const MAX_LISTS = 2;       // max lists per H2 section

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

    // --- Rule 2: per-H2-section list count cap ---
    // Walk top-level children in document order, segmenting by depth-2 headings.
    // Counter resets at every new H2.
    let listsInSection = 0;

    for (const child of tree.children) {
      if (child.type === "heading" && child.depth === 2) {
        listsInSection = 0;
        continue;
      }
      if (child.type === "list") {
        listsInSection += 1;
        if (listsInSection > MAX_LISTS) {
          file.message(
            `${listsInSection}${ordinalSuffix(listsInSection)} list in this H2 section. Cap is ${MAX_LISTS} lists per section. Restructure with subheadings or prose.`,
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
