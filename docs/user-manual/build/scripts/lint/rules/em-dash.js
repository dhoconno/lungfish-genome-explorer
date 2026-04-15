import { visitParents } from "unist-util-visit-parents";

const EM_DASH = /\u2014/; // U+2014

// Node types whose text content is visible prose. Flag em dashes here.
const PROSE_TYPES = new Set(["text", "heading", "link", "linkReference", "emphasis", "strong"]);

// Ancestor types that shelter content from the rule (code contexts).
function isInCode(ancestors) {
  return ancestors.some(
    (a) => a.type === "inlineCode" || a.type === "code" || a.type === "html",
  );
}

export default function emDash() {
  return (tree, file) => {
    visitParents(tree, (node, ancestors) => {
      if (!PROSE_TYPES.has(node.type)) return;
      if (isInCode(ancestors)) return;

      // For container node types (heading, link, etc.) we only check their
      // own value if present; child text nodes are handled when they are
      // visited individually as "text" nodes.
      const value = node.value;
      if (typeof value === "string" && EM_DASH.test(value)) {
        file.message(
          "em dash (U+2014) in prose. Use a period, or use an en dash (U+2013) for numeric ranges.",
          node,
        );
      }
    });
  };
}
