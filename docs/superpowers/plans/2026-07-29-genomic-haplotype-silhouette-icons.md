# Genomic Haplotype Silhouette Icons Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce a project-local comparison sheet showing ten distinct genomic haplotype silhouette icon concepts.

**Architecture:** Generate one raster comparison sheet from the approved visual brief, then inspect the output at full size and as a small thumbnail. Keep the generated artifact separate from application code so a chosen concept can be converted into a deterministic vector asset later.

**Tech Stack:** OpenAI built-in image generation, PNG, local visual inspection

## Global Constraints

- Match the compact, monochrome visual language of macOS SF Symbols.
- Use solid black silhouettes on a plain white background.
- Favor paired genomic tracks and locus patterns over a generic DNA helix.
- Include exactly ten visibly distinct concepts in an evenly spaced 5-by-2 sheet.
- Keep the icon artwork free of text; small numbers may appear outside each icon for selection.
- Do not modify application code or transform scientific data.

---

### Task 1: Generate and Validate the Comparison Sheet

**Files:**
- Create: `docs/design/haplotype-silhouette-concepts.png`

**Interfaces:**
- Consumes: `docs/superpowers/specs/2026-07-29-genomic-haplotype-silhouette-icons-design.md`
- Produces: one reviewable PNG comparison sheet

- [x] **Step 1: Generate the sheet**

Use the built-in image-generation tool with this production prompt:

```text
Use case: logo-brand
Asset type: native macOS genomics application icon concept sheet
Primary request: Create exactly ten distinct silhouette icon concepts for “genomic haplotype,” arranged as an evenly spaced 5-column by 2-row comparison sheet.
Concepts in reading order: paired segmented genomic tracks; offset allele blocks; paired tracks with one variant notch; recombinant crossover tracks; braided paired strands; split chromosome bar; mirrored locus ladders; linked variant beads; stacked genomic ribbons; abstract H-shaped haplotype monogram.
Style/medium: crisp vector-like solid black glyphs, compact rounded geometry, consistent apparent stroke weight, inspired by the restraint and optical balance of native macOS SF Symbols without copying any existing symbol.
Composition/framing: one centered icon per equal white cell with generous padding; concepts must remain distinguishable at 16–32 px; place only small numerals 1–10 beneath the cells, outside the glyph artwork.
Color palette: pure black icons on pure white.
Constraints: exactly ten icons; every icon must be a single-color silhouette; visually coherent family; no title; no captions other than the selection numerals.
Avoid: DNA double helix clichés, letters inside the first nine icons, color, gray, gradients, shadows, texture, 3D, borders, watermarks, decorative flourishes, microscopic detail, extra icons.
```

- [x] **Step 2: Save the artifact**

Copy the generated PNG to `docs/design/haplotype-silhouette-concepts.png` without overwriting an unrelated existing asset. If that path exists, use `docs/design/haplotype-silhouette-concepts-v2.png`.

- [x] **Step 3: Inspect full-size output**

Confirm all of the following visually:

- exactly ten cells and ten glyphs
- correct 5-by-2 order
- black-only glyphs on white
- no titles, captions, watermarks, or unintended text
- each glyph is materially different from its neighbors

- [x] **Step 4: Inspect small-size readability**

Create a temporary 320-pixel-wide preview and confirm the icons remain separable. If the set fails either inspection, regenerate once with one targeted correction describing the observed failure.

- [x] **Step 5: Report the deliverable**

Show the final PNG inline, link its absolute project path, identify the generation mode as the built-in image tool, and provide the final prompt.
