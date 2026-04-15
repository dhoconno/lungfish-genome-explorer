import { visit } from "unist-util-visit";

const BANNED = [
  /\brevolutionary\b/i,
  /\bbreakthrough\b/i,
  /\bpowerful\b/i,
  /\bcutting[- ]edge\b/i,
  /\bAI[- ]powered\b/i,
  /\bgame[- ]changing\b/i,
  /\bunleash(es|ed)?\b/i,
  /\bleverages?\b/i,
];

// "next-generation" is allowed only in NGS context; flag otherwise. We approximate by
// allowing it when the same paragraph contains "sequencing" or "NGS".
const NEXT_GEN = /\bnext[- ]generation\b/i;
const NGS_CONTEXT = /\b(sequencing|NGS)\b/i;

const SENTENCE_BANG = /[A-Za-z0-9)]\!(\s|$)/;

export default function voice() {
  return (tree, file) => {
    visit(tree, "paragraph", (node) => {
      const text = collect(node);
      for (const pat of BANNED) {
        if (pat.test(text)) file.message(`Marketing voice: '${text.match(pat)[0]}'`, node);
      }
      if (NEXT_GEN.test(text) && !NGS_CONTEXT.test(text)) {
        file.message(`'next-generation' outside NGS context`, node);
      }
      if (SENTENCE_BANG.test(text)) {
        file.message(`sentence-terminal '!' in body prose`, node);
      }
    });
  };
}

function collect(node) {
  if (node.type === "text") return node.value;
  if (node.type === "inlineCode") return ""; // skip inline code
  if (!node.children) return "";
  return node.children.map(collect).join(" ");
}
