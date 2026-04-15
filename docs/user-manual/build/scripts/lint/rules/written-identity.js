import { visitParents } from "unist-util-visit-parents";

const BAD_CAPS = /\bLUNGFISH\b/;
const BAD_MIXED = /\bLungFish\b/;
const BAD_SPACED = /\bLung Fish\b/;
const BAD_LOWER = /(?<![`./\-_/])\blungfish\b(?!\.)/;

export default function writtenIdentity() {
  return (tree, file) => {
    visitParents(tree, "text", (node, ancestors) => {
      if (ancestors.some((a) => a.type === "inlineCode" || a.type === "code" || a.type === "blockquote")) {
        return;
      }
      const v = node.value;
      if (BAD_CAPS.test(v)) file.message("LUNGFISH — use 'Lungfish'", node);
      if (BAD_MIXED.test(v)) file.message("LungFish — use 'Lungfish'", node);
      if (BAD_SPACED.test(v)) file.message("Lung Fish — use 'Lungfish'", node);
      if (BAD_LOWER.test(v)) file.message("lowercase 'lungfish' — use 'Lungfish'", node);
    });
  };
}
