import frontmatter from "remark-frontmatter";
import writtenIdentity from "./rules/written-identity.js";
import palette from "./rules/palette.js";
import typography from "./rules/typography.js";
import voice from "./rules/voice.js";
import primerBeforeProcedure from "./rules/primer-before-procedure.js";
import frontmatterRule from "./rules/frontmatter.js";
import dataViz from "./rules/data-viz.js";

export default {
  plugins: [
    [frontmatter, ["yaml"]],
    writtenIdentity,
    palette,
    typography,
    voice,
    primerBeforeProcedure,
    frontmatterRule,
    dataViz,
  ],
};
