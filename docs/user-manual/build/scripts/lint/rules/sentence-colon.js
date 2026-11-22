import { report, proseText } from "./severity.js";

// A colon may end a short lead-in immediately before a list, table, or code
// block. Anywhere else in prose it is a joiner and is banned.
const LEAD_IN_FOLLOWERS = new Set(["list", "table", "code"]);
const TIME_OR_RATIO = /\d:\d/g;
const URL_TOKEN = /\b[a-z][a-z0-9+.-]*:\/\/\S+/gi;

export default function sentenceColon() {
  return (tree, file) => {
    walk(tree);

    function walk(parent) {
      if (!parent.children) return;
      parent.children.forEach((node, i) => {
        if (node.type === "paragraph" || node.type === "heading" || node.type === "tableCell") {
          check(node, follower(parent.children, i));
        }
        if (node.type !== "code" && node.type !== "html") walk(node);
      });
    }

    // The follower of a paragraph is the next sibling that is not one of the
    // <!-- SHOT: id --> screenshot marker nodes remark parses as `html`.
    function follower(siblings, i) {
      let j = i + 1;
      while (siblings[j] && siblings[j].type === "html") j++;
      return siblings[j];
    }

    function check(node, next) {
      const text = proseText(node).replace(URL_TOKEN, "").replace(TIME_OR_RATIO, "  ");
      const trimmed = text.trimEnd();
      const colons = [...trimmed].filter((c) => c === ":").length;
      if (colons === 0) return;
      const endsWithColon = trimmed.endsWith(":");
      const followerOk = next && LEAD_IN_FOLLOWERS.has(next.type);
      const allowedLeadIn = node.type === "paragraph" && endsWithColon && followerOk;
      let banned = allowedLeadIn ? colons - 1 : colons;
      // A settings paragraph opens with its registry label in bold, and some
      // labels carry a trailing colon because the app draws them that way
      // ("Threads:"). STYLE.md drops that colon (**Threads.**), but chapters
      // written before that rule keep it (**Threads:.**). Colons inside that
      // leading bold label are the label, not prose, and are not counted.
      const lead = node.type === "paragraph" ? node.children?.[0] : null;
      if (lead && lead.type === "strong") {
        const labelColons = [...proseText(lead)].filter((c) => c === ":").length;
        banned = Math.max(0, banned - labelColons);
      }
      for (let k = 0; k < banned; k++) {
        report(file, "colon inside a sentence. Use a period and a new sentence, or restructure. A colon may only end a lead-in line right before a list, table, or code block.", node);
      }
    }
  };
}
