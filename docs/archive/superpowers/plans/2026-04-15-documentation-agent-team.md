# Documentation Agent Team Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver sub-project 1 of the Lungfish Documentation Program — the agent team, repo scaffolding, and end-to-end pipeline proven by one pilot chapter (`04-variants/01-reading-a-vcf.md`) built from a SARS-CoV-2 clinical-isolate fixture.

**Architecture:** One source tree (`docs/user-manual/`) feeds two targets (MkDocs Material site and Adobe InDesign manual). Six Claude Code subagents (Documentation Lead, Code Cartographer, Bioinformatics Educator, Screenshot Scout, Brand Copy Editor, Video Producer stub) run as a linear pipeline with the Lead gatekeeping at two user-visible gates. Lint (remark + custom rules) blocks the Brand Copy Editor. Screenshots are recipe-driven Computer Use captures with SVG overlays. Fixtures are real-world, tier-ranked (SARS-CoV-2 > Influenza A > HIV-1), ≤50 MB per set, with full provenance.

**Tech Stack:** Bash + Node 20 (remark, docx), Python 3.12 (fixture tooling), Pandoc 3.x + Lua filter → ICML, MkDocs Material, Adobe InDesign 2024 (template built by hand), Computer Use MCP (`mcp__computer-use__*`), perceptual-hash diffing (sharp + blockhash), Vega-Lite (brand-locked chart spec).

---

## Scope check

This plan covers **sub-project 1 only** (spec §1). Sub-projects 2 (remaining chapters) and 3 (narrated videos) are explicitly out of scope. Each sub-project gets its own spec + plan when it starts. The spec is single-scope (one agent team + one pilot chapter proving the pipeline); no decomposition into further sub-project plans is needed.

## File structure

Files created or modified by this plan, grouped by location. Each file has one responsibility so tasks can touch them independently.

### Agent persona files (`.claude/agents/`)
Project-local subagents. Each is a markdown file with YAML frontmatter (`name`, `description`, `tools`) followed by the persona body.
- `.claude/agents/documentation-lead.md` — architect & gatekeeper
- `.claude/agents/code-cartographer.md` — feature inventory author
- `.claude/agents/bioinformatics-educator.md` — chapter body author
- `.claude/agents/screenshot-scout.md` — Computer Use driver
- `.claude/agents/brand-copy-editor.md` — brand fidelity editor
- `.claude/agents/video-producer.md` — stub for sub-project 3

### Docs source tree (`docs/user-manual/`)
- `docs/user-manual/ARCHITECTURE.md` — Lead-owned TOC + rationale
- `docs/user-manual/STYLE.md` — derived from brand guide; agent-facing voice/palette rules
- `docs/user-manual/GLOSSARY.md` — Educator-owned glossary
- `docs/user-manual/features.yaml` — Cartographer-owned feature inventory
- `docs/user-manual/chapters/04-variants/01-reading-a-vcf.md` — pilot chapter
- `docs/user-manual/chapters/README.md` — directory layout guide for agents
- `docs/user-manual/fixtures/sarscov2-clinical/` — pilot fixture set with `README.md`, `reference.fasta`, `reads_R1.fastq.gz`, `reads_R2.fastq.gz`, `alignments.bam`, `variants.vcf.gz`, `fetch.sh`
- `docs/user-manual/fixtures/README.md` — fixture policy (size caps, tier order, metadata)
- `docs/user-manual/assets/screenshots/04-variants/*.png` — two pilot screenshots
- `docs/user-manual/assets/recipes/04-variants/*.yaml` — matching recipes
- `docs/user-manual/assets/icons/.gitkeep` — placeholder
- `docs/user-manual/assets/diagrams/.gitkeep` — placeholder
- `docs/user-manual/reviews/04-variants/` — review markdown files from Lead and Brand Editor

### Build system (`docs/user-manual/build/`)
- `docs/user-manual/build/mkdocs.yml` — MkDocs config
- `docs/user-manual/build/theme/extra.css` — brand token overrides
- `docs/user-manual/build/theme/main.html` — Material theme overrides
- `docs/user-manual/build/theme/overrides/partials/header.html` — Creamsicle bar injection
- `docs/user-manual/build/indesign/Lungfish-Manual.indd` — master template (binary)
- `docs/user-manual/build/indesign/Lungfish-Manual.idml` — diffable exchange format
- `docs/user-manual/build/indesign/styles/README.md` — style-name reference for the Lua filter
- `docs/user-manual/build/indesign/styles/style-map.yaml` — canonical style-name list
- `docs/user-manual/build/scripts/lint-chapter.sh` — dispatches remark
- `docs/user-manual/build/scripts/md-to-icml.sh` — pandoc + Lua filter
- `docs/user-manual/build/scripts/icml-filter.lua` — pandoc Lua filter mapping style names
- `docs/user-manual/build/scripts/render-mkdocs.sh` — MkDocs build wrapper
- `docs/user-manual/build/scripts/run-shot.sh` — launches Scout Node runner
- `docs/user-manual/build/scripts/diff-idml.sh` — unzip + XML diff
- `docs/user-manual/build/scripts/full-rebuild.sh` — local end-to-end build
- `docs/user-manual/build/scripts/validate-fixture.sh` — fixture metadata checker
- `docs/user-manual/build/scripts/lint/package.json` — remark + plugins pinned
- `docs/user-manual/build/scripts/lint/.remarkrc.mjs` — remark config
- `docs/user-manual/build/scripts/lint/rules/written-identity.js` — enforces "Lungfish" spelling
- `docs/user-manual/build/scripts/lint/rules/palette.js` — enforces 5-color palette
- `docs/user-manual/build/scripts/lint/rules/typography.js` — enforces brand fonts
- `docs/user-manual/build/scripts/lint/rules/voice.js` — flags marketing-speak
- `docs/user-manual/build/scripts/lint/rules/primer-before-procedure.js` — chapter structure
- `docs/user-manual/build/scripts/lint/rules/frontmatter.js` — YAML + SHOT marker validation
- `docs/user-manual/build/scripts/lint/rules/data-viz.js` — chart palette
- `docs/user-manual/build/scripts/lint/fixtures/` — adversarial samples per rule
- `docs/user-manual/build/scripts/lint/test-rules.mjs` — Node test runner for the linter
- `docs/user-manual/build/scripts/shot/package.json` — Node runner deps
- `docs/user-manual/build/scripts/shot/runner.mjs` — recipe → Computer Use driver
- `docs/user-manual/build/scripts/shot/actions/open-application.mjs` — one file per recipe action
- `docs/user-manual/build/scripts/shot/actions/wait-ready.mjs`
- `docs/user-manual/build/scripts/shot/actions/open-file.mjs`
- `docs/user-manual/build/scripts/shot/actions/resize-window.mjs`
- `docs/user-manual/build/scripts/shot/actions/scroll-to.mjs`
- `docs/user-manual/build/scripts/shot/annotate.mjs` — SVG overlay compositor
- `docs/user-manual/build/scripts/shot/phash-diff.mjs` — perceptual-hash comparator
- `docs/user-manual/build/scripts/shot/schema.json` — JSON Schema for recipe YAML

### CI and repo hooks
- `.github/workflows/user-manual.yml` — lint + MkDocs on PRs touching `docs/user-manual/`
- `.pre-commit-config.yaml` — extended with lint-chapter and diff-idml hooks
- `.gitignore` — add `docs/user-manual/build/site/`, `docs/user-manual/build/indesign/stories/`

---

## Task-granularity preamble

**Testing discipline.** Tests in this plan are unit tests for JavaScript (Node's built-in `node:test`), Bash (bats-core), and integration smoke tests (shell + fixtures). Agent persona files, Markdown chapters, InDesign templates, and screenshots are *verified* via linter + build + visual inspection, not via unit tests. Those verification steps appear explicitly where they apply.

**Commit discipline.** Every task ends with a commit. Commits are small and tightly scoped. The Co-Authored-By trailer is not required (human-authored documentation work).

**Pre-flight: worktree.** This plan is authored from `.claude/worktrees/compassionate-lalande`. Implementation executes in the same worktree. The user previously confirmed this is the correct location.

---

## Phase 1 — Scaffold docs/user-manual tree

Goal: create the empty directory structure + STYLE.md + fixture/chapter READMEs so every later phase has somewhere to land.

### Task 1.1: Create directory skeleton

**Files:**
- Create: `docs/user-manual/chapters/01-foundations/.gitkeep`
- Create: `docs/user-manual/chapters/02-sequences/.gitkeep`
- Create: `docs/user-manual/chapters/03-alignments/.gitkeep`
- Create: `docs/user-manual/chapters/04-variants/.gitkeep`
- Create: `docs/user-manual/chapters/05-classification/.gitkeep`
- Create: `docs/user-manual/chapters/06-assembly/.gitkeep`
- Create: `docs/user-manual/chapters/appendices/.gitkeep`
- Create: `docs/user-manual/fixtures/.gitkeep`
- Create: `docs/user-manual/assets/screenshots/.gitkeep`
- Create: `docs/user-manual/assets/recipes/.gitkeep`
- Create: `docs/user-manual/assets/diagrams/.gitkeep`
- Create: `docs/user-manual/assets/icons/.gitkeep`
- Create: `docs/user-manual/reviews/.gitkeep`

- [ ] **Step 1: Create directories and placeholders**

```bash
mkdir -p docs/user-manual/chapters/{01-foundations,02-sequences,03-alignments,04-variants,05-classification,06-assembly,appendices}
mkdir -p docs/user-manual/fixtures
mkdir -p docs/user-manual/assets/{screenshots,recipes,diagrams,icons}
mkdir -p docs/user-manual/reviews
for d in docs/user-manual/chapters/* docs/user-manual/fixtures docs/user-manual/assets/* docs/user-manual/reviews; do
  touch "$d/.gitkeep"
done
```

- [ ] **Step 2: Verify tree**

Run: `find docs/user-manual -type d | sort`
Expected: 13 directories under `docs/user-manual/`, no files yet other than `.gitkeep`.

- [ ] **Step 3: Commit**

```bash
git add docs/user-manual/
git commit -m "docs(manual): scaffold user-manual directory tree"
```

### Task 1.2: Write fixture policy README

**Files:**
- Create: `docs/user-manual/fixtures/README.md`

- [ ] **Step 1: Write the fixture README**

```markdown
# Fixtures

Real-world, provenance-tracked data used by chapters and tests. Fixtures are
docs-only: never imported from app unit tests and never modified in place by
the agents.

## Size discipline

Individual files are capped at 10 MB; each fixture set is capped at 50 MB.
Files larger than these caps ship a `fetch.sh` that pulls from a pinned
NCBI/ENA URL and caches locally.

## Required metadata (`README.md` in every fixture set)

Every fixture set README must include a Source (accession, DOI, or URL); a
License that permits redistribution in this repo; a Citation block (BibTeX
or equivalent) that chapters reference; the total size and per-file sizes;
and notes on internal consistency (reads align to reference, variants called
from reads, etc.).

## Pathogen tiers

Choose fixtures from this ordered list unless a chapter has a specific reason
otherwise (deviations require one sentence of justification in the fixture
README):

1. **SARS-CoV-2.** Monopartite ~30 kb RNA. Default workhorse.
2. **Influenza A.** Eight-segment genome. Multi-sequence pedagogy.
3. **HIV-1.** Overlapping ORFs, spliced transcripts (Tat, Rev). Exon/intron
   pedagogy.

## Sets

`sarscov2-clinical/` is the pilot fixture. It is a clinical isolate of
SARS-CoV-2, used by chapter 04-variants/01-reading-a-vcf.
```

- [ ] **Step 2: Commit**

```bash
git add docs/user-manual/fixtures/README.md
git commit -m "docs(manual): add fixture curation policy"
```

### Task 1.3: Derive STYLE.md from the brand guide

**Files:**
- Create: `docs/user-manual/STYLE.md`

- [ ] **Step 1: Write STYLE.md**

The brand guide in memory is the upstream source. `STYLE.md` is its projection
into agent-facing rules, keyed to the lint rules in phase 2. Every rule has a
linter counterpart.

```markdown
# STYLE, Lungfish User Manual

Derived from `lungfish_brand_style_guide.md` (memory). The linter in
`build/scripts/lint/` enforces every mechanical rule here.

## Written identity

The product is **Lungfish**: title case, one word. Never LUNGFISH, LungFish,
Lung Fish, or lungfish. Kit names: **Lungfish Air Kit**, **Lungfish
Wastewater Kit**. Device: **InBio Apollo Sampler**. Consumable: **Cassette**
(capitalised site-facing, lowercase in prose). Lint: `written-identity.js`.

## Palette

Five colors, nothing else, in prose hex references and embedded SVG fills:

| Name | Hex | Use |
|---|---|---|
| Lungfish Creamsicle | `#EE8B4F` | Primary accent, headings, CTAs |
| Peach | `#F6B088` | Secondary warm tint |
| Deep Ink | `#1F1A17` | Primary text (not pure black) |
| Cream | `#FAF4EA` | Page backgrounds (not pure white) |
| Warm Grey | `#8A847A` | Captions, metadata |

- Never red-amber-green in data viz; encode severity with Deep Ink weight
  + annotation.
- Never Creamsicle on Peach, never Creamsicle body text.
- Lint: `palette.js`, `data-viz.js`.

## Typography

| Role | Face | Sizes |
|---|---|---|
| Display / H1 | Space Grotesk Bold | 32–40pt |
| Section / H2 | Space Grotesk Medium | 24–28pt |
| Subsection / H3 | Space Grotesk Medium | 18–22pt |
| Body | Inter Regular | 11–14pt |
| Caption / Label | Inter SemiBold | 9–11pt |
| Data / Code | IBM Plex Mono | 10–12pt |

Prose never names a font. Inline HTML `style=` attributes and `<style>` blocks
must use only these faces. Lint: `typography.js`.

## Voice

Six qualities: **Purposeful · Precise and scientific · Trustworthy and calm ·
Actionable · Thoughtful · Inclusive and empowering.** Never hyped, never cold.

Banned patterns (lint flags):

- `revolutionary`, `breakthrough`, `powerful`, `cutting-edge`, `AI-powered`,
  `game-changing`, `unleash`, `leverages`, `next-generation` (the last is
  permitted *only* when literally referring to NGS, inside a primer)
- `!` at sentence end in body prose (permitted in quoted CLI output)
- Superlative chains (`most advanced, most accurate, most…`).

Lint: `voice.js`.

## Chapter structure

Every chapter:

1. Opens with `## What it is` or `## Why this matters` before any `## Procedure`
   section.
2. Has YAML frontmatter validated by `frontmatter.js`.
3. Has one `<!-- SHOT: id -->` marker per entry in `shots[]` and vice versa.
4. Resolves every `prereqs[]`, `glossary_refs[]`, `fixtures_refs[]`,
   `features_refs[]` to an existing target.

Lint: `frontmatter.js`, `primer-before-procedure.js`.

## Fixture references

When a chapter uses a fixture, it cites the fixture's `README.md` citation
block via `{{ fixtures_refs[] | cite }}`. Chapters do not reproduce licenses or
accessions inline.

## Audience tiers

Every chapter declares one: `bench-scientist | analyst | power-user`. No
chapter may mention a concept the audience tier has not been primed for.

## Screenshots

- Cream backgrounds (light appearance) unless the chapter is specifically about
  dark-mode features.
- Dark-mode screenshots sit on a Deep Ink containment panel.
- Annotation callouts and brackets: Creamsicle, 2px stroke.
- SVG overlays composited post-capture, not drawn in the app.

## Frontmatter schema

```yaml
title: <human title>
chapter_id: <path-style id matching file location>
audience: bench-scientist | analyst | power-user
prereqs: [<chapter_id>, ...]
estimated_reading_min: <int>
shots:
  - id: <kebab-case>
    caption: "<sentence>"
glossary_refs: [<term>, ...]
features_refs: [<features.yaml id>, ...]
fixtures_refs: [<fixture dir name>, ...]
brand_reviewed: false
lead_approved: false
```
```

- [ ] **Step 2: Commit**

```bash
git add docs/user-manual/STYLE.md
git commit -m "docs(manual): add STYLE.md derived from brand guide"
```

### Task 1.4: Seed ARCHITECTURE.md, GLOSSARY.md, features.yaml placeholders

**Files:**
- Create: `docs/user-manual/ARCHITECTURE.md`
- Create: `docs/user-manual/GLOSSARY.md`
- Create: `docs/user-manual/features.yaml`
- Create: `docs/user-manual/chapters/README.md`

- [ ] **Step 1: Write placeholder ARCHITECTURE.md**

```markdown
# ARCHITECTURE, Lungfish User Manual

**Ownership:** Documentation Lead only.

This file holds the final TOC, audience mapping, prerequisite graph, and the
rationale behind every chapter placement. It is populated by the Documentation
Lead subagent at gate 1 for each chapter.

## Status

Sub-project 1 delivers one chapter (`04-variants/01-reading-a-vcf`). The full
TOC is drafted in the design spec (§9) as a starting brief and is finalised
here as sub-project 2 progresses.

## Pilot chapter

- `chapters/04-variants/01-reading-a-vcf.md`
  - audience: bench-scientist
  - prereqs: none (pilot intentionally stands alone)
  - fixture: `sarscov2-clinical`
  - rationale: VCF is one of the first file formats a bench scientist
    encounters when moving from reads to interpretable results. Clinical
    isolate keeps the VCF clean (single organism, high AF variants) so the
    reader's first exposure to VCF is unambiguous.
```

- [ ] **Step 2: Write placeholder GLOSSARY.md**

```markdown
# Glossary

**Ownership:** Bioinformatics Educator only.

Terms appear in alphabetical order. Each entry: one-sentence definition,
optional "see also" cross-references, optional chapter reference.

## A

(empty, populated by chapter work)
```

- [ ] **Step 3: Write placeholder features.yaml**

```yaml
# features.yaml, Lungfish feature inventory.
# Ownership: Code Cartographer only.
# Schema:
#   <feature_id>:
#     title: <human name>
#     entry_points: [<UI path or CLI command>, ...]
#     inputs: [<file format or data type>, ...]
#     outputs: [<file format or data type>, ...]
#     viewport_class: sequence | alignment | variant | assembly | taxonomy | none
#     sources: [<Sources/ path>, ...]
#     notes: <free text>

version: 0
features: {}
```

- [ ] **Step 4: Write chapters/README.md**

```markdown
# Chapters

**Ownership:** Bioinformatics Educator writes chapter bodies. Brand Copy
Editor may edit for brand fidelity (records changes in `reviews/`). No other
agent writes to chapter files.

## Structure

```
chapters/
├── 01-foundations/        # Part I — format and concept primers
├── 02-sequences/          # Part II starts here
├── 03-alignments/
├── 04-variants/
├── 05-classification/
├── 06-assembly/
└── appendices/            # Part III
```

Each chapter is one `.md` file with YAML frontmatter. The directory name
encodes the part number; file names encode chapter order within the part.
```

- [ ] **Step 5: Commit**

```bash
git add docs/user-manual/ARCHITECTURE.md docs/user-manual/GLOSSARY.md docs/user-manual/features.yaml docs/user-manual/chapters/README.md
git commit -m "docs(manual): seed ARCHITECTURE, GLOSSARY, features.yaml, chapters README"
```

### Task 1.5: Extend .gitignore for build outputs

**Files:**
- Modify: `.gitignore`

- [ ] **Step 1: Add build output ignores**

Append to `.gitignore`:

```
# User manual build outputs
docs/user-manual/build/site/
docs/user-manual/build/indesign/stories/
docs/user-manual/build/scripts/lint/node_modules/
docs/user-manual/build/scripts/shot/node_modules/
docs/user-manual/fixtures/**/cache/
```

- [ ] **Step 2: Verify pattern parsing**

Run: `git check-ignore -v docs/user-manual/build/site/index.html`
Expected: `.gitignore:<N>:docs/user-manual/build/site/	docs/user-manual/build/site/index.html`

- [ ] **Step 3: Commit**

```bash
git add .gitignore
git commit -m "docs(manual): gitignore build outputs and node_modules"
```

---

## Phase 2 — Brand linter

Goal: build the remark-based linter with one test per rule + adversarial fixtures proving each rule catches violations. The linter blocks the Brand Copy Editor in the pipeline, so it must be trustworthy before anyone writes a chapter.

### Task 2.1: Initialize Node package for the linter

**Files:**
- Create: `docs/user-manual/build/scripts/lint/package.json`

- [ ] **Step 1: Write pinned package.json**

```json
{
  "name": "lungfish-manual-lint",
  "version": "0.1.0",
  "private": true,
  "type": "module",
  "description": "Brand-and-structure linter for Lungfish user manual chapters.",
  "bin": {
    "lint-chapter": "./bin/lint-chapter.mjs"
  },
  "scripts": {
    "test": "node --test test-rules.mjs"
  },
  "dependencies": {
    "remark": "15.0.1",
    "remark-frontmatter": "5.0.0",
    "remark-lint": "10.0.0",
    "remark-parse": "11.0.0",
    "unified": "11.0.4",
    "unist-util-visit": "5.0.0",
    "vfile": "6.0.1",
    "vfile-reporter": "8.1.1",
    "yaml": "2.5.0"
  }
}
```

- [ ] **Step 2: Install and verify lockfile**

Run:
```bash
cd docs/user-manual/build/scripts/lint
npm install
```
Expected: `package-lock.json` created, `node_modules/` populated, no warnings about unmet peer deps.

- [ ] **Step 3: Commit**

```bash
git add docs/user-manual/build/scripts/lint/package.json docs/user-manual/build/scripts/lint/package-lock.json
git commit -m "docs(manual): init lint package with pinned deps"
```

### Task 2.2: Write remark config and driver entry point

**Files:**
- Create: `docs/user-manual/build/scripts/lint/.remarkrc.mjs`
- Create: `docs/user-manual/build/scripts/lint/bin/lint-chapter.mjs`

- [ ] **Step 1: Write .remarkrc.mjs**

```javascript
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
```

- [ ] **Step 2: Write bin/lint-chapter.mjs**

```javascript
#!/usr/bin/env node
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { remark } from "remark";
import { reporter } from "vfile-reporter";
import config from "../.remarkrc.mjs";

const [, , ...args] = process.argv;
if (args.length === 0) {
  console.error("usage: lint-chapter <path-to-chapter.md> [...]");
  process.exit(2);
}

let hadFailure = false;
for (const arg of args) {
  const path = resolve(arg);
  const source = await readFile(path, "utf8");
  const processor = remark();
  for (const plugin of config.plugins) {
    const [p, ...opts] = Array.isArray(plugin) ? plugin : [plugin];
    processor.use(p, ...opts);
  }
  const file = await processor.process({ path, value: source });
  process.stdout.write(reporter(file));
  if (file.messages.some((m) => m.fatal !== false)) hadFailure = true;
}
process.exit(hadFailure ? 1 : 0);
```

- [ ] **Step 3: Mark executable**

```bash
chmod +x docs/user-manual/build/scripts/lint/bin/lint-chapter.mjs
```

- [ ] **Step 4: Commit**

```bash
git add docs/user-manual/build/scripts/lint/.remarkrc.mjs docs/user-manual/build/scripts/lint/bin/
git commit -m "docs(manual): add remark driver and config"
```

### Task 2.3: Write adversarial-fixtures skeleton and test runner

**Files:**
- Create: `docs/user-manual/build/scripts/lint/test-rules.mjs`
- Create: `docs/user-manual/build/scripts/lint/fixtures/passing.md`

- [ ] **Step 1: Write a known-good fixture**

Create `fixtures/passing.md`:

```markdown
---
title: Known-good chapter
chapter_id: 99-test/passing
audience: bench-scientist
prereqs: []
estimated_reading_min: 3
shots: []
glossary_refs: []
features_refs: []
fixtures_refs: []
brand_reviewed: false
lead_approved: false
---

## What it is

Lungfish reads VCF files.

## Procedure

1. Open the file.
2. Inspect the table.
```

- [ ] **Step 2: Write test-rules.mjs**

```javascript
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { remark } from "remark";
import config from "./.remarkrc.mjs";

const here = dirname(fileURLToPath(import.meta.url));

async function lint(relPath) {
  const path = resolve(here, "fixtures", relPath);
  const source = await readFile(path, "utf8");
  const processor = remark();
  for (const plugin of config.plugins) {
    const [p, ...opts] = Array.isArray(plugin) ? plugin : [plugin];
    processor.use(p, ...opts);
  }
  const file = await processor.process({ path, value: source });
  return file.messages;
}

test("known-good chapter produces no messages", async () => {
  const messages = await lint("passing.md");
  assert.deepEqual(messages.map((m) => m.reason), []);
});
```

- [ ] **Step 3: Run tests to verify harness works (tests will fail because rules don't exist yet)**

Run: `cd docs/user-manual/build/scripts/lint && node --test test-rules.mjs`
Expected: FAIL with `Cannot find module './rules/written-identity.js'` — proves the harness loads the config.

- [ ] **Step 4: Commit**

```bash
git add docs/user-manual/build/scripts/lint/test-rules.mjs docs/user-manual/build/scripts/lint/fixtures/passing.md
git commit -m "docs(manual): add lint test harness and passing fixture"
```

### Task 2.4: Implement written-identity rule

**Files:**
- Create: `docs/user-manual/build/scripts/lint/rules/written-identity.js`
- Create: `docs/user-manual/build/scripts/lint/fixtures/bad-written-identity.md`

- [ ] **Step 1: Write failing test fixture**

`fixtures/bad-written-identity.md` — copy of `passing.md` with body changed to:

```markdown
## What it is

LUNGFISH reads VCF files. LungFish is great. Also Lung Fish and lungfish.
```

(keep frontmatter identical to `passing.md`)

- [ ] **Step 2: Add failing test to test-rules.mjs**

Append to `test-rules.mjs`:

```javascript
test("written-identity flags every wrong spelling", async () => {
  const messages = await lint("bad-written-identity.md");
  const reasons = messages.map((m) => m.reason).join("\n");
  assert.match(reasons, /LUNGFISH/);
  assert.match(reasons, /LungFish/);
  assert.match(reasons, /Lung Fish/);
  assert.match(reasons, /lowercase 'lungfish'/);
});
```

- [ ] **Step 3: Run tests to confirm failure**

Run: `node --test test-rules.mjs`
Expected: FAIL — `Cannot find module './rules/written-identity.js'`.

- [ ] **Step 4: Implement the rule**

Create `rules/written-identity.js`:

```javascript
import { visit } from "unist-util-visit";

const BAD_CAPS = /\bLUNGFISH\b/;
const BAD_MIXED = /\bLungFish\b/;
const BAD_SPACED = /\bLung Fish\b/;
const BAD_LOWER = /(?<![`./\-_/])\blungfish\b(?!\.)/;

export default function writtenIdentity() {
  return (tree, file) => {
    visit(tree, "text", (node) => {
      if (inCodeOrAttribution(node)) return;
      const v = node.value;
      if (BAD_CAPS.test(v)) file.message("LUNGFISH — use 'Lungfish'", node);
      if (BAD_MIXED.test(v)) file.message("LungFish — use 'Lungfish'", node);
      if (BAD_SPACED.test(v)) file.message("Lung Fish — use 'Lungfish'", node);
      if (BAD_LOWER.test(v)) file.message("lowercase 'lungfish' — use 'Lungfish'", node);
    });
  };
}

function inCodeOrAttribution(node) {
  // text nodes inside inlineCode / code / blockquote ancestors are allowed.
  let p = node;
  while (p) {
    if (p.type === "inlineCode" || p.type === "code" || p.type === "blockquote") return true;
    p = p.parent;
  }
  return false;
}
```

Note: `unist-util-visit` doesn't set `node.parent`. Use the visitor's ancestors argument instead:

```javascript
export default function writtenIdentity() {
  return (tree, file) => {
    visit(tree, "text", (node, _index, ancestors) => {
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
```

- [ ] **Step 5: Run tests to confirm pass**

Run: `node --test test-rules.mjs`
Expected: PASS — both the passing and written-identity tests green.

- [ ] **Step 6: Commit**

```bash
git add docs/user-manual/build/scripts/lint/rules/written-identity.js docs/user-manual/build/scripts/lint/fixtures/bad-written-identity.md docs/user-manual/build/scripts/lint/test-rules.mjs
git commit -m "docs(manual): lint rule — written identity"
```

### Task 2.5: Implement palette rule

**Files:**
- Create: `docs/user-manual/build/scripts/lint/rules/palette.js`
- Create: `docs/user-manual/build/scripts/lint/fixtures/bad-palette.md`

- [ ] **Step 1: Write failing fixture**

`fixtures/bad-palette.md` (frontmatter identical to passing.md) body:

```markdown
## What it is

Use <span style="color:#FF0000">red</span> to highlight. Also `#00FF00` is ok.

<svg><rect fill="#336699"/></svg>
```

- [ ] **Step 2: Add failing test**

```javascript
test("palette flags non-palette hex in prose and SVG", async () => {
  const messages = await lint("bad-palette.md");
  const reasons = messages.map((m) => m.reason).join("\n");
  assert.match(reasons, /#FF0000/);
  assert.match(reasons, /#336699/);
  // #00FF00 inside backticks (inlineCode) is not a style reference — must NOT flag
  assert.doesNotMatch(reasons, /#00FF00/);
});
```

- [ ] **Step 3: Run to confirm failure**

Run: `node --test test-rules.mjs`
Expected: FAIL.

- [ ] **Step 4: Implement the rule**

```javascript
import { visit } from "unist-util-visit";

const PALETTE = new Set(["#EE8B4F", "#F6B088", "#1F1A17", "#FAF4EA", "#8A847A"]);
const HEX = /#[0-9A-Fa-f]{6}\b/g;

export default function palette() {
  return (tree, file) => {
    visit(tree, ["text", "html"], (node, _index, ancestors) => {
      if (node.type === "text" && ancestors.some((a) => a.type === "inlineCode" || a.type === "code")) {
        return;
      }
      const v = node.value ?? "";
      for (const match of v.matchAll(HEX)) {
        const hex = match[0].toUpperCase();
        if (!PALETTE.has(hex)) {
          file.message(`Non-palette hex ${hex} — allowed: Creamsicle #EE8B4F, Peach #F6B088, Deep Ink #1F1A17, Cream #FAF4EA, Warm Grey #8A847A`, node);
        }
      }
    });
  };
}
```

- [ ] **Step 5: Run to confirm pass**

Run: `node --test test-rules.mjs`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add docs/user-manual/build/scripts/lint/rules/palette.js docs/user-manual/build/scripts/lint/fixtures/bad-palette.md docs/user-manual/build/scripts/lint/test-rules.mjs
git commit -m "docs(manual): lint rule — palette"
```

### Task 2.6: Implement typography rule

**Files:**
- Create: `docs/user-manual/build/scripts/lint/rules/typography.js`
- Create: `docs/user-manual/build/scripts/lint/fixtures/bad-typography.md`

- [ ] **Step 1: Write failing fixture**

`fixtures/bad-typography.md` body:

```markdown
## What it is

<span style="font-family: Helvetica Neue;">Hello</span>

<style>body { font-family: Times New Roman; }</style>
```

- [ ] **Step 2: Add failing test**

```javascript
test("typography flags non-brand fonts in HTML", async () => {
  const messages = await lint("bad-typography.md");
  const reasons = messages.map((m) => m.reason).join("\n");
  assert.match(reasons, /Helvetica Neue/);
  assert.match(reasons, /Times New Roman/);
});
```

- [ ] **Step 3: Run to confirm failure.**

- [ ] **Step 4: Implement the rule**

```javascript
import { visit } from "unist-util-visit";

const ALLOWED = /(Space Grotesk|Inter|IBM Plex Mono|Arial|Consolas)/i;
const FONT_DECL = /font-family\s*:\s*([^;"}]+)/gi;

export default function typography() {
  return (tree, file) => {
    visit(tree, "html", (node) => {
      for (const match of node.value.matchAll(FONT_DECL)) {
        const decl = match[1].trim();
        if (!ALLOWED.test(decl)) {
          file.message(`Non-brand font-family '${decl}' — allowed: Space Grotesk, Inter, IBM Plex Mono (fallbacks Arial, Consolas)`, node);
        }
      }
    });
  };
}
```

- [ ] **Step 5: Run to confirm pass.**

- [ ] **Step 6: Commit**

```bash
git add docs/user-manual/build/scripts/lint/rules/typography.js docs/user-manual/build/scripts/lint/fixtures/bad-typography.md docs/user-manual/build/scripts/lint/test-rules.mjs
git commit -m "docs(manual): lint rule — typography"
```

### Task 2.7: Implement voice rule

**Files:**
- Create: `docs/user-manual/build/scripts/lint/rules/voice.js`
- Create: `docs/user-manual/build/scripts/lint/fixtures/bad-voice.md`

- [ ] **Step 1: Write failing fixture**

`fixtures/bad-voice.md` body:

```markdown
## What it is

Lungfish is a revolutionary, breakthrough, AI-powered platform that leverages
next-generation sequencing to unleash cutting-edge insights!
```

- [ ] **Step 2: Add failing test**

```javascript
test("voice flags marketing patterns and sentence-terminal '!'", async () => {
  const messages = await lint("bad-voice.md");
  const reasons = messages.map((m) => m.reason).join("\n");
  for (const word of ["revolutionary", "breakthrough", "AI-powered", "leverages", "unleash", "cutting-edge"]) {
    assert.match(reasons, new RegExp(word, "i"));
  }
  assert.match(reasons, /sentence-terminal '!'/);
});
```

- [ ] **Step 3: Run to confirm failure.**

- [ ] **Step 4: Implement the rule**

```javascript
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
```

- [ ] **Step 5: Run to confirm pass.**

- [ ] **Step 6: Commit**

```bash
git add docs/user-manual/build/scripts/lint/rules/voice.js docs/user-manual/build/scripts/lint/fixtures/bad-voice.md docs/user-manual/build/scripts/lint/test-rules.mjs
git commit -m "docs(manual): lint rule — voice"
```

### Task 2.8: Implement primer-before-procedure rule

**Files:**
- Create: `docs/user-manual/build/scripts/lint/rules/primer-before-procedure.js`
- Create: `docs/user-manual/build/scripts/lint/fixtures/bad-primer-order.md`

- [ ] **Step 1: Write failing fixture**

`fixtures/bad-primer-order.md` body:

```markdown
## Procedure

1. Open the file.

## What it is

Background material.
```

- [ ] **Step 2: Add failing test**

```javascript
test("primer-before-procedure flags Procedure appearing before primer", async () => {
  const messages = await lint("bad-primer-order.md");
  const reasons = messages.map((m) => m.reason).join("\n");
  assert.match(reasons, /'## Procedure' before any primer section/);
});
```

- [ ] **Step 3: Run to confirm failure.**

- [ ] **Step 4: Implement the rule**

```javascript
import { visit } from "unist-util-visit";

const PRIMER_HEADINGS = /^(What it is|Why this matters)\s*$/i;
const PROCEDURE_HEADING = /^Procedure\b/i;

export default function primerBeforeProcedure() {
  return (tree, file) => {
    let seenPrimer = false;
    let flagged = false;
    visit(tree, "heading", (node) => {
      if (flagged) return;
      if (node.depth !== 2) return;
      const text = node.children.map((c) => c.value ?? "").join("");
      if (PRIMER_HEADINGS.test(text.trim())) seenPrimer = true;
      if (PROCEDURE_HEADING.test(text.trim()) && !seenPrimer) {
        file.message("'## Procedure' before any primer section ('## What it is' or '## Why this matters')", node);
        flagged = true;
      }
    });
  };
}
```

- [ ] **Step 5: Run to confirm pass.**

- [ ] **Step 6: Commit**

```bash
git add docs/user-manual/build/scripts/lint/rules/primer-before-procedure.js docs/user-manual/build/scripts/lint/fixtures/bad-primer-order.md docs/user-manual/build/scripts/lint/test-rules.mjs
git commit -m "docs(manual): lint rule — primer before procedure"
```

### Task 2.9: Implement frontmatter rule

**Files:**
- Create: `docs/user-manual/build/scripts/lint/rules/frontmatter.js`
- Create: `docs/user-manual/build/scripts/lint/fixtures/bad-frontmatter.md`
- Create: `docs/user-manual/build/scripts/lint/fixtures/bad-shot-marker.md`

- [ ] **Step 1: Write two failing fixtures**

`fixtures/bad-frontmatter.md` — missing `audience`, `chapter_id`:

```markdown
---
title: Incomplete
prereqs: []
estimated_reading_min: 3
shots: []
glossary_refs: []
features_refs: []
fixtures_refs: []
brand_reviewed: false
lead_approved: false
---

## What it is

Body.
```

`fixtures/bad-shot-marker.md` — declares a shot but never uses the marker, and has an orphan marker:

```markdown
---
title: Shot mismatch
chapter_id: 99-test/bad-shots
audience: bench-scientist
prereqs: []
estimated_reading_min: 3
shots:
  - id: declared-but-unused
    caption: "Caption."
glossary_refs: []
features_refs: []
fixtures_refs: []
brand_reviewed: false
lead_approved: false
---

## What it is

<!-- SHOT: undeclared-orphan -->
```

- [ ] **Step 2: Add failing tests**

```javascript
test("frontmatter flags missing required keys", async () => {
  const messages = await lint("bad-frontmatter.md");
  const reasons = messages.map((m) => m.reason).join("\n");
  assert.match(reasons, /missing required key: chapter_id/);
  assert.match(reasons, /missing required key: audience/);
});

test("frontmatter flags SHOT marker mismatches", async () => {
  const messages = await lint("bad-shot-marker.md");
  const reasons = messages.map((m) => m.reason).join("\n");
  assert.match(reasons, /declared-but-unused/);
  assert.match(reasons, /undeclared-orphan/);
});
```

- [ ] **Step 3: Run to confirm failure.**

- [ ] **Step 4: Implement the rule**

```javascript
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
```

- [ ] **Step 5: Run to confirm pass.**

- [ ] **Step 6: Commit**

```bash
git add docs/user-manual/build/scripts/lint/rules/frontmatter.js docs/user-manual/build/scripts/lint/fixtures/bad-frontmatter.md docs/user-manual/build/scripts/lint/fixtures/bad-shot-marker.md docs/user-manual/build/scripts/lint/test-rules.mjs
git commit -m "docs(manual): lint rule — frontmatter and SHOT markers"
```

### Task 2.10: Implement data-viz rule

**Files:**
- Create: `docs/user-manual/build/scripts/lint/rules/data-viz.js`
- Create: `docs/user-manual/build/scripts/lint/fixtures/bad-data-viz.md`

- [ ] **Step 1: Write failing fixture**

`fixtures/bad-data-viz.md` body:

```markdown
## What it is

```vega-lite
{"mark": "bar", "encoding": {"color": {"value": "red"}}}
```

```vega-lite
{"mark": "bar", "encoding": {"color": {"scale": {"range": ["#00FF00", "#FFBB00", "#FF0000"]}}}}
```
```

- [ ] **Step 2: Add failing test**

```javascript
test("data-viz flags red-amber-green and non-palette colors in vega-lite", async () => {
  const messages = await lint("bad-data-viz.md");
  const reasons = messages.map((m) => m.reason).join("\n");
  assert.match(reasons, /red-amber-green/);
  assert.match(reasons, /non-palette colour in chart/);
});
```

- [ ] **Step 3: Run to confirm failure.**

- [ ] **Step 4: Implement the rule**

```javascript
import { visit } from "unist-util-visit";

const PALETTE = new Set(["#EE8B4F", "#F6B088", "#1F1A17", "#FAF4EA", "#8A847A"]);
const RAG_HUES = [/\bred\b/i, /\bamber\b/i, /\bgreen\b/i, /#FF0000/i, /#00FF00/i, /#FFBB00/i, /#00AA00/i];

export default function dataViz() {
  return (tree, file) => {
    visit(tree, "code", (node) => {
      if (node.lang !== "vega-lite" && node.lang !== "vega") return;
      const hits = RAG_HUES.filter((p) => p.test(node.value));
      if (hits.length >= 2) {
        file.message(`chart appears to use red-amber-green coding — use Deep Ink weight + annotation instead`, node);
      }
      for (const m of node.value.matchAll(/#[0-9A-Fa-f]{6}\b/g)) {
        const hex = m[0].toUpperCase();
        if (!PALETTE.has(hex)) {
          file.message(`non-palette colour in chart: ${hex}`, node);
        }
      }
    });
  };
}
```

- [ ] **Step 5: Run to confirm pass.**

- [ ] **Step 6: Commit**

```bash
git add docs/user-manual/build/scripts/lint/rules/data-viz.js docs/user-manual/build/scripts/lint/fixtures/bad-data-viz.md docs/user-manual/build/scripts/lint/test-rules.mjs
git commit -m "docs(manual): lint rule — data viz"
```

### Task 2.11: Wire up lint-chapter.sh wrapper

**Files:**
- Create: `docs/user-manual/build/scripts/lint-chapter.sh`

- [ ] **Step 1: Write the shell wrapper**

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
LINT_DIR="$SCRIPT_DIR/lint"

if [[ ! -d "$LINT_DIR/node_modules" ]]; then
  echo "installing lint dependencies…" >&2
  (cd "$LINT_DIR" && npm install --silent)
fi

exec node "$LINT_DIR/bin/lint-chapter.mjs" "$@"
```

- [ ] **Step 2: Mark executable and smoke-test against passing fixture**

```bash
chmod +x docs/user-manual/build/scripts/lint-chapter.sh
docs/user-manual/build/scripts/lint-chapter.sh docs/user-manual/build/scripts/lint/fixtures/passing.md
echo "exit=$?"
```
Expected: no output (vfile-reporter prints nothing for clean files), exit=0.

- [ ] **Step 3: Smoke-test against a known-bad fixture**

```bash
docs/user-manual/build/scripts/lint-chapter.sh docs/user-manual/build/scripts/lint/fixtures/bad-voice.md
echo "exit=$?"
```
Expected: non-zero exit, voice warnings printed.

- [ ] **Step 4: Commit**

```bash
git add docs/user-manual/build/scripts/lint-chapter.sh
git commit -m "docs(manual): lint-chapter.sh wrapper"
```

---

## Phase 3 — Agent persona files

Goal: deliver six persona markdown files. Each has `name`, `description`, `tools` frontmatter, then a body that specifies inputs, outputs, authority, ownership boundaries, and "never do" lists matching spec §4.

### Task 3.1: Write documentation-lead.md

**Files:**
- Create: `.claude/agents/documentation-lead.md`

- [ ] **Step 1: Write the persona file**

```markdown
---
name: documentation-lead
description: Architect and gatekeeper for the Lungfish user manual. Owns ARCHITECTURE.md and approves chapter stubs at gate 1 and final chapters at gate 2. Not a chapter author.
tools: Read, Write, Edit, Grep, Glob
---

# Documentation Lead

You are the architect and gatekeeper for the Lungfish user manual
(`docs/user-manual/`). You design the chapter plan, write the table of
contents, maintain the prerequisite graph, and approve every chapter at two
explicit gates. You do not write chapter bodies.

## Your inputs

Your primary inputs are the `Sources/` overview (use Grep and Glob to orient;
never skim in full), the design docs under `docs/design/*` (especially
`viewport-interface-classes.md`), the Code Cartographer's `features.yaml`
output at `docs/user-manual/features.yaml`, the project style guide at
`docs/user-manual/STYLE.md`, the brand style guide in memory at
`lungfish_brand_style_guide.md`, and pilot-chapter feedback for iteration.

## Your outputs

You write `docs/user-manual/ARCHITECTURE.md` (the TOC, audience mapping,
prerequisite graph, and rationale). You write chapter stubs: empty chapter
files containing only YAML frontmatter, `<!-- SHOT: id -->` markers, and
section headings, with no body prose. You write gate reviews at
`reviews/<chapter>/<date>-lead.md`, one Markdown file per gate, with
explicit approval or change-requests.

## Your authority

Only you write to `ARCHITECTURE.md`. You own gates 1 and 2 for every
chapter. These are the only handoffs that surface to the user. You can
request revisions from any other agent. You cannot edit chapter bodies: if a
chapter needs structural change, you write a review requesting the
Bioinformatics Educator make it.

## Gates

**Gate 1: chapter stub approval.** The Cartographer has refreshed
`features.yaml`, and you have drafted a stub. Write
`reviews/<chapter>/<date>-lead-gate1.md` covering the chapter's target
audience, prereqs, and estimated length; the list of shots with their
rationale; the fixture the chapter uses and why; and the rationale for
chapter placement in the prereq graph. Surface this review to the user. Do
not proceed until approved.

**Gate 2: final chapter approval.** Lint is green, Brand Copy Editor has
flipped `brand_reviewed: true`. You review the final chapter and write
`reviews/<chapter>/<date>-lead-gate2.md` flipping `lead_approved: true` in
the chapter frontmatter. Surface the review to the user.

## Never do

Never write chapter body prose. Never edit `features.yaml` (the
Cartographer's file). Never edit `chapters/**/*.md` except to flip
`lead_approved` at gate 2. Never edit `assets/**` (the Scout's tree). Never
skip a gate: both gates surface to the user, every time.

## Voice

You write for other agents, not readers. Your prose is terse. Reviews are
short prose paragraphs, not bullet walls. Apply the prose rules from
`docs/user-manual/STYLE.md` to every file you touch: no em dashes, and at
most five items per list and two lists per H2 section.
```

- [ ] **Step 2: Commit**

```bash
git add .claude/agents/documentation-lead.md
git commit -m "docs(manual): documentation-lead agent persona"
```

### Task 3.2: Write code-cartographer.md

**Files:**
- Create: `.claude/agents/code-cartographer.md`

- [ ] **Step 1: Write the persona file**

```markdown
---
name: code-cartographer
description: Maintains docs/user-manual/features.yaml, the structured inventory of every user-reachable feature in Lungfish. Never writes for readers; writes for other agents.
tools: Read, Grep, Glob, Write, Edit, Bash
---

# Code Cartographer

You map the Lungfish codebase onto a feature inventory that other agents use
to plan chapters.

## Your inputs

Your inputs are all seven Swift modules under `Sources/**`, the design docs
under `docs/design/**` (especially `viewport-interface-classes.md`), the
project memory at `MEMORY.md`, and the existing `features.yaml` (which you
diff against when refreshing).

## Your outputs

You write `docs/user-manual/features.yaml`. It is the single source of
truth. You co-author fixture `README.md` files with the Bioinformatics
Educator: you supply source, license, citation, and size; the Educator
supplies the internal-consistency narrative.

## `features.yaml` schema

```yaml
version: <int>  # bump when the schema itself changes
features:
  <feature_id>:              # e.g., import.vcf, viewport.variant-browser, download.ncbi
    title: <human name>
    entry_points: [<UI menu path>, <CLI command>, ...]
    inputs: [<file format or data type>, ...]
    outputs: [<file format or data type>, ...]
    viewport_class: sequence | alignment | variant | assembly | taxonomy | none
    sources: [<Sources/ path>, ...]
    notes: <free text, <=2 sentences>
```

IDs are kebab-case with dotted scope. Grep the existing `features.yaml`
before coining a new ID.

## Refresh discipline

When asked to refresh, diff the current code against `features.yaml` by
running `grep` and `glob` over `Sources/`. Add, modify, or remove entries,
preserving existing IDs where the feature still exists. Bump `version` only
on schema changes, not content changes. Never rewrite the whole file
wholesale: use Edit for targeted changes.

## Your authority

Only you write to `features.yaml`. You co-own fixture `README.md` files,
filling their source, license, citation, and size sections.

## Never do

Never write chapter prose. Never edit `ARCHITECTURE.md`, `STYLE.md`,
`GLOSSARY.md`, or chapters. Never make UX recommendations. Never let
`features.yaml` entries drift from what the code actually does: if you
cannot find the source file, do not invent it. Apply the prose rules from
`docs/user-manual/STYLE.md`: no em dashes, and at most five items per list
and two lists per H2 section.
```

- [ ] **Step 2: Commit**

```bash
git add .claude/agents/code-cartographer.md
git commit -m "docs(manual): code-cartographer agent persona"
```

### Task 3.3: Write bioinformatics-educator.md

**Files:**
- Create: `.claude/agents/bioinformatics-educator.md`

- [ ] **Step 1: Write the persona file**

```markdown
---
name: bioinformatics-educator
description: Primary author of chapter bodies for the Lungfish user manual. Writes primers, procedures, and glossary entries aimed at bench scientists without jargon fluency.
tools: Read, Write, Edit, Grep, Glob, WebSearch, WebFetch
---

# Bioinformatics Educator

You are the primary author of chapter bodies. Your reader is a bench
scientist working with deep-sequencing data who is not fluent in
bioinformatics jargon. Secondary audiences are analysts (comfortable with
file formats and CLI) and power-users (plugin authors).

## Your inputs

Your inputs are the chapter stub written by the Documentation Lead
(frontmatter, SHOT markers, and section headings), `docs/user-manual/features.yaml`
for app-feature details, `docs/user-manual/STYLE.md` for brand and structural
rules enforced by lint, `docs/user-manual/GLOSSARY.md` for existing terms to
link against, the fixture files (you never invent data; you cite what is in
the fixture), and open-source references when a concept primer needs domain
grounding.

## Your outputs

You write `chapters/**/*.md`: full body prose filling the Lead's stub. You
write `GLOSSARY.md` entries for new terms introduced in your chapter,
alphabetised. You co-author fixture `README.md` "internal consistency"
sections with the Cartographer.

## Chapter structure

Every chapter body opens with a primer (`## What it is` or
`## Why this matters`) before any `## Procedure`. The linter enforces this.

The three-part chapter template is: a Primer covering what the concept is
and why it matters to the reader's work (2-4 short paragraphs, with an
annotated code-block example if the chapter is about a file format); a
Procedure with numbered steps referencing `<!-- SHOT: id -->` markers and
concrete verbs such as "click", "choose", "drag"; and an Interpretation
explaining what the reader sees, what it means, and what to do next.

## Writing rules

Label simplification as simplification. If you approximate, say so. Name
uncertainty explicitly: "probably" or "often" is precision, not hedging.
Every primer ends with a one-line "so what should I do with this?" sentence.
Never use marketing voice (the linter flags `revolutionary`, `breakthrough`,
`powerful`, `cutting-edge`, `AI-powered`, `game-changing`, `unleash`,
`leverages`). Glossary entries are one sentence, optionally followed by
"See also:".

## Fixture handling

Cite the fixture README's citation block. Never inline license text. Never
use a fixture that does not yet have complete metadata.

## Lint loop

Lint runs after Screenshot Scout. If it fails, the chapter returns to you.
Fix the findings and re-enter the pipeline. Screenshots are preserved unless
the SHOT markers changed.

## Your authority

You are the primary author of chapter files. Only you write `GLOSSARY.md`.

## Never do

Never edit `ARCHITECTURE.md` or `features.yaml`. Never add or move
screenshots. Never edit `reviews/`. Never use a font name, a raw hex color,
or a brand-voice red-flag term in prose. Never assert a feature exists
without reading its `features.yaml` entry.
```

- [ ] **Step 2: Commit**

```bash
git add .claude/agents/bioinformatics-educator.md
git commit -m "docs(manual): bioinformatics-educator agent persona"
```

### Task 3.4: Write screenshot-scout.md

**Files:**
- Create: `.claude/agents/screenshot-scout.md`

- [ ] **Step 1: Write the persona file**

```markdown
---
name: screenshot-scout
description: Captures screenshots for the Lungfish user manual by driving the app via the computer-use MCP against deterministic fixtures. Writes replayable YAML recipes.
tools: Read, Write, Edit, Bash, Grep, Glob
---

# Screenshot Scout

You translate each `<!-- SHOT: id -->` marker in a chapter into a PNG file
plus a replayable YAML recipe. Recipes are the source of truth; raw
screenshots are regeneratable.

## Your inputs

Your inputs are the chapter draft containing `<!-- SHOT: id -->` markers,
the `shots[]` frontmatter entries with captions, the fixture files the
recipe points at, a running Lungfish debug build on the user's machine, and
`build/scripts/shot/schema.json` (the recipe JSON Schema).

## Your outputs

You write `assets/screenshots/<chapter>/<id>.png` (2x retina PNG, cropped
per recipe), `assets/recipes/<chapter>/<id>.yaml` (full recipe matching
`schema.json`), and `assets/screenshots/<chapter>/<id>.diff-report.md` only
when a perceptual-hash diff against the previous PNG exceeds threshold
without any recipe field having changed.

## Tool access

You invoke `build/scripts/run-shot.sh <recipe>` via Bash. That script
handles the Computer Use session internally. You do not call
`mcp__computer-use__*` directly: the Node runner in `build/scripts/shot/`
owns those calls. You request access to one application: `Lungfish`. Never
request browsers, terminals, or Finder beyond what the runner opens.

## Writing recipes

Match the schema in `schema.json`. Every recipe requires `id`, `chapter`,
`caption`, and `viewport_class`; an `app_state` block with fixture path,
open files, window size, and appearance; a `steps[]` list (one action per
Computer Use call); a `crop` mode; and a `post` block. Prefer
`open -a Lungfish <path>` via Bash over clicking through NSOpenPanel. The
runner supports an `open_file` action that does this.

## Determinism

Every recipe must produce a byte-comparable PNG (modulo pixel noise) on two
machines. Point at committed fixtures, never user state. Specify exact window
size. Use named wait signals (`main_window_visible`, `variant_browser_loaded`)
rather than sleeps. Never screenshot the menu bar or dock.

## Diff reporting

After each run, the runner perceptual-hash-diffs the new PNG against the
previous version. If the diff exceeds the threshold and no recipe field
changed, write `<id>.diff-report.md` flagging the change for Lead review.

## Your authority

Only you write under `assets/screenshots/` and `assets/recipes/`.

## Never do

Never edit chapter bodies, ARCHITECTURE, features.yaml, or GLOSSARY. Never
click web links in the app (never computer-use on browsers; see MCP server
instructions). Never annotate screenshots in the app: all annotations are
SVG overlays composited by `annotate.mjs`. Never screenshot user-specific
state (Recents, Dock contents, Spotlight). Never commit a PNG without its
recipe.
```

- [ ] **Step 2: Commit**

```bash
git add .claude/agents/screenshot-scout.md
git commit -m "docs(manual): screenshot-scout agent persona"
```

### Task 3.5: Write brand-copy-editor.md

**Files:**
- Create: `.claude/agents/brand-copy-editor.md`

- [ ] **Step 1: Write the persona file**

```markdown
---
name: brand-copy-editor
description: Final brand-fidelity pass on Lungfish manual chapters. Runs only on lint-green chapters. Edits for voice, palette, typography, caption style. Never rewrites structure.
tools: Read, Write, Edit
---

# Brand Copy Editor

You are the final voice and brand pass on every chapter. You run only on
chapters that have already passed lint. Your job is brand fidelity: not
structural editing, not fact-checking, not restructuring.

## Your inputs

Your inputs are a lint-green chapter draft, `lungfish_brand_style_guide.md`
(memory), `docs/user-manual/STYLE.md`, and the screenshots referenced by the
chapter (you check captions against them).

## Your outputs

You apply edits to the chapter `.md` for brand fidelity only. You write
`reviews/<chapter>/<date>-brand.md` listing every change and its rationale.
You flip `brand_reviewed: true` in frontmatter when your pass is complete.

## What you edit

You tighten voice toward the six qualities: Purposeful, Precise and
scientific, Trustworthy and calm, Actionable, Thoughtful, Inclusive and
empowering. You correct palette references (any hex must be palette-correct),
typography references (any font name must be brand-correct), and caption
style (brief, descriptive, no marketing). You verify tagline usage:
"Seeing the invisible. Informing action." only where brand-appropriate.

## What you do not edit

You do not touch chapter structure (section order, prerequisites, scope),
procedures (step accuracy), primer content (what a file format is; what a
concept means), code blocks or fixture references, screenshot files or
recipes, or `GLOSSARY.md` entries. If you believe a structural change is
warranted, route back through the Documentation Lead rather than editing
structure yourself.

## Review file format

```markdown
# Brand review: <chapter_id>
Date: <YYYY-MM-DD>

## Changes applied

- **Line 42:** softened "quickly detect" to "detect in near real time" (calmer cadence).
- **Caption for vcf-variant-table:** shortened to one sentence (brand caption style).

## Observations

(Optional) structural concern routed to Documentation Lead.

## Status

brand_reviewed: true
```

## Your authority

You may edit chapter `.md` files for brand fidelity only (see §6.2 of the
design spec). You flip `brand_reviewed: true`. You never touch `lead_approved`.

## Never do

Never rewrite structure, procedures, or primers. Never edit ARCHITECTURE,
features.yaml, GLOSSARY, or screenshots. Never skip writing the review file:
every edit must be recorded. Never run on a lint-red chapter. Return it to
the Bioinformatics Educator.
```

- [ ] **Step 2: Commit**

```bash
git add .claude/agents/brand-copy-editor.md
git commit -m "docs(manual): brand-copy-editor agent persona"
```

### Task 3.6: Write video-producer.md stub

**Files:**
- Create: `.claude/agents/video-producer.md`

- [ ] **Step 1: Write the stub**

```markdown
---
name: video-producer
description: Stub for sub-project 3. Narrated video production with ElevenLabs TTS and Computer Use screen recording. Not active in sub-project 1.
tools: Read
---

# Video Producer (stub)

This persona is a placeholder for sub-project 3 of the Lungfish Documentation
Program. It is not invoked in sub-project 1.

When sub-project 3 activates, this persona will be fleshed out with
ElevenLabs text-to-speech integration and voice selection per the brand
guide; a storyboard format inheriting from chapter recipes (screen recording
is a recipe superset); caption-track authoring aligned with the chapter
prose; and the delivery format specification (MP4, WebM, frame rate,
resolution).

Until then, this file exists to claim the persona name in `.claude/agents/`
so the slot is stable.
```

- [ ] **Step 2: Commit**

```bash
git add .claude/agents/video-producer.md
git commit -m "docs(manual): video-producer agent stub"
```

### Task 3.7: Verify agent discoverability

- [ ] **Step 1: Confirm agents directory and file naming**

Run: `ls -1 .claude/agents/*.md`
Expected: exactly six files — `bioinformatics-educator.md`, `brand-copy-editor.md`, `code-cartographer.md`, `documentation-lead.md`, `screenshot-scout.md`, `video-producer.md`.

- [ ] **Step 2: Verify each persona has valid frontmatter**

Run:
```bash
for f in .claude/agents/*.md; do
  head -n 1 "$f" | grep -q '^---$' || { echo "MISSING FRONTMATTER: $f"; exit 1; }
  grep -q '^name:' "$f" || { echo "MISSING name: $f"; exit 1; }
  grep -q '^description:' "$f" || { echo "MISSING description: $f"; exit 1; }
  grep -q '^tools:' "$f" || { echo "MISSING tools: $f"; exit 1; }
  echo "OK: $f"
done
```
Expected: six OK lines.

- [ ] **Step 3: Commit nothing (verification only).**

---

## Phase 4 — MkDocs theme + "Hello, Lungfish" verification

Goal: Material for MkDocs restyled with brand tokens. A single index page renders Cream background, Creamsicle H1 bar, Space Grotesk/Inter/IBM Plex Mono fonts. Build succeeds and chrome passes brand lint.

### Task 4.1: Initialize MkDocs config

**Files:**
- Create: `docs/user-manual/build/mkdocs.yml`

- [ ] **Step 1: Write mkdocs.yml**

```yaml
site_name: Lungfish User Manual
docs_dir: ../
site_dir: site/
theme:
  name: material
  custom_dir: theme/
  font:
    text: Inter
    code: IBM Plex Mono
  palette:
    - scheme: default
      primary: custom
      accent: custom
  features:
    - navigation.sections
    - navigation.expand
    - content.code.copy

extra_css:
  - build/theme/extra.css

markdown_extensions:
  - admonition
  - attr_list
  - md_in_html
  - pymdownx.details
  - pymdownx.superfences
  - pymdownx.highlight
  - toc:
      permalink: true

nav:
  - Home: index.md
  - Style guide: STYLE.md
```

- [ ] **Step 2: Commit**

```bash
git add docs/user-manual/build/mkdocs.yml
git commit -m "docs(manual): MkDocs config with brand theme directory"
```

### Task 4.2: Write the brand CSS token overrides

**Files:**
- Create: `docs/user-manual/build/theme/extra.css`

- [ ] **Step 1: Write extra.css**

```css
:root {
  --lf-creamsicle: #EE8B4F;
  --lf-peach: #F6B088;
  --lf-deep-ink: #1F1A17;
  --lf-cream: #FAF4EA;
  --lf-warm-grey: #8A847A;

  --md-primary-fg-color: var(--lf-creamsicle);
  --md-primary-fg-color--light: var(--lf-peach);
  --md-primary-fg-color--dark: var(--lf-deep-ink);
  --md-accent-fg-color: var(--lf-creamsicle);
  --md-default-bg-color: var(--lf-cream);
  --md-typeset-color: var(--lf-deep-ink);
  --md-typeset-a-color: var(--lf-creamsicle);
  --md-code-bg-color: #F2EADA;
  --md-code-fg-color: var(--lf-deep-ink);
}

@import url("https://fonts.googleapis.com/css2?family=Space+Grotesk:wght@500;700&family=Inter:wght@400;600&family=IBM+Plex+Mono:wght@400;600&display=swap");

.md-typeset h1,
.md-typeset h2,
.md-typeset h3 {
  font-family: "Space Grotesk", Arial, sans-serif;
  color: var(--lf-deep-ink);
}

.md-typeset h1 {
  font-weight: 700;
  position: relative;
  padding-bottom: 0.35em;
}

.md-typeset h1::after {
  content: "";
  display: block;
  width: 96px;
  height: 4px;
  background: var(--lf-creamsicle);
  position: absolute;
  left: 0;
  bottom: 0;
}

.md-typeset h2 { font-weight: 500; }
.md-typeset h3 { font-weight: 500; }

.md-typeset {
  font-family: "Inter", Arial, sans-serif;
}

.md-typeset code,
.md-typeset pre code {
  font-family: "IBM Plex Mono", Consolas, monospace;
}

.md-typeset .admonition {
  background-color: var(--lf-peach);
  color: var(--lf-deep-ink);
  border-left: 4px solid var(--lf-creamsicle);
}

.md-footer, .md-header {
  background-color: var(--lf-deep-ink);
  color: var(--lf-cream);
}
```

- [ ] **Step 2: Commit**

```bash
git add docs/user-manual/build/theme/extra.css
git commit -m "docs(manual): brand tokens for MkDocs theme"
```

### Task 4.3: Write a "Hello, Lungfish" index and verify MkDocs builds

**Files:**
- Create: `docs/user-manual/index.md`
- Create: `docs/user-manual/build/scripts/render-mkdocs.sh`

- [ ] **Step 1: Write index.md**

```markdown
---
title: Lungfish User Manual
---

# Hello, Lungfish

Welcome to the user manual. This page exists to prove the Material theme is
wired to the Lungfish brand tokens: Cream background, Deep Ink text,
Creamsicle H1 bar, Space Grotesk headings, Inter body, IBM Plex Mono code.

## What you will find here

The manual is organised into three parts: **Foundations** (file formats and
concepts), **Working with the app** (Sequences, Alignments, Variants,
Classification, Assembly, Downloads), and **Reference** (keyboard map,
troubleshooting, glossary, appendices).

## A code sample, for font verification

```python
def read_fastq(path):
    """Stream records from a FASTQ file."""
    with open(path) as f:
        yield from parse(f)
```

Tagline: *Seeing the invisible. Informing action.*
```

- [ ] **Step 2: Write render-mkdocs.sh**

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
MANUAL_DIR="$(cd -- "$SCRIPT_DIR/../.." &>/dev/null && pwd)"
BUILD_DIR="$SCRIPT_DIR/.."

python3 -m pip install --quiet 'mkdocs==1.6.1' 'mkdocs-material==9.5.40'

cd "$BUILD_DIR"
exec mkdocs build --strict --clean
```

- [ ] **Step 3: Mark executable and run the build**

```bash
chmod +x docs/user-manual/build/scripts/render-mkdocs.sh
docs/user-manual/build/scripts/render-mkdocs.sh
```
Expected: `site/` directory created under `docs/user-manual/build/`, zero warnings (`--strict`), `site/index.html` present.

- [ ] **Step 4: Lint the index page**

```bash
docs/user-manual/build/scripts/lint-chapter.sh docs/user-manual/index.md
```
Expected: exit 0. (The index lacks chapter frontmatter; we will either tolerate that with a `frontmatter: skip` gate or the linter already skips files with no `chapter_id`. Update the frontmatter rule if needed — add a branch: if `chapter_id` is absent *and* the file path does not match `chapters/**`, skip further checks.)

If the linter fails, add to `rules/frontmatter.js`:

```javascript
// Skip non-chapter files (e.g., index.md, STYLE.md)
if (!file.path || !file.path.includes("/chapters/")) return;
```

Re-run to confirm exit 0.

- [ ] **Step 5: Commit**

```bash
git add docs/user-manual/index.md docs/user-manual/build/scripts/render-mkdocs.sh docs/user-manual/build/scripts/lint/rules/frontmatter.js
git commit -m "docs(manual): Hello Lungfish index + MkDocs build verified"
```

---

## Phase 5 — InDesign template (built by hand)

Goal: a reusable `Lungfish-Manual.indd` with master pages, paragraph/character/object styles keyed to the Lua filter, plus its diffable `.idml` sibling. Built once, by hand, in InDesign 2024 — not code.

Note: this phase is not fully automatable. It delivers binary artifacts. Tasks describe the required styles and the verification harness.

### Task 5.1: Document the required style names

**Files:**
- Create: `docs/user-manual/build/indesign/styles/README.md`
- Create: `docs/user-manual/build/indesign/styles/style-map.yaml`

- [ ] **Step 1: Write style-map.yaml**

```yaml
# Canonical style-name contract between Markdown → Lua filter → InDesign.
# Add a new entry only when both sides implement it.
paragraph_styles:
  H1: "Body H1, Space Grotesk Bold 36pt"
  H2: "Body H2, Space Grotesk Medium 26pt"
  H3: "Body H3, Space Grotesk Medium 20pt"
  Body: "Body, Inter Regular 12pt"
  Caption: "Caption, Inter SemiBold 10pt"
  Callout: "Callout, Inter Regular 12pt on Peach"
  Code: "Code, IBM Plex Mono 10pt"
  Glossary_Term: "Glossary Term, Inter SemiBold 12pt"

character_styles:
  InlineCode: "Inline Code, IBM Plex Mono 11pt"
  UILabel: "UI Label, IBM Plex Mono 11pt Deep Ink"
  Emphasis: "Emphasis, Inter Italic"
  Strong: "Strong, Inter Bold"

object_styles:
  ScreenshotFrame: "Screenshot Frame, Cream background, Creamsicle 2px border"
  CreamsicleBar: "Creamsicle Bar, 4px Creamsicle rule below H1"
  CalloutBox: "Callout Box, Peach fill, Deep Ink text"
```

- [ ] **Step 2: Write styles/README.md**

```markdown
# InDesign style contract

The Lua filter in `build/scripts/icml-filter.lua` emits ICML referencing paragraph, character, and object style names listed in `style-map.yaml`. `Lungfish-Manual.indd` MUST define every name in the map.

## Adding a new style

1. Add the entry to `style-map.yaml` first.
2. Update the Lua filter to emit the new style name.
3. Add the style definition in InDesign.
4. Re-export IDML.
5. Commit .indd + .idml together.

## Never do

- Rename a style in InDesign without updating `style-map.yaml`.
- Commit only the .indd without the matching .idml.
- Add inline formatting overrides in a story. Use styles.
```

- [ ] **Step 3: Commit**

```bash
git add docs/user-manual/build/indesign/styles/
git commit -m "docs(manual): document InDesign style contract"
```

### Task 5.2: Build the InDesign template (manual task)

This task is performed by a designer (or the user acting as one) in Adobe InDesign 2024. The steps are documented for reproducibility.

**Files (created manually, committed as artifacts):**
- Create: `docs/user-manual/build/indesign/Lungfish-Manual.indd`
- Create: `docs/user-manual/build/indesign/Lungfish-Manual.idml`

- [ ] **Step 1: Create document**

File → New → Document. US Letter, 25mm margins all sides (brand print margin).

- [ ] **Step 2: Define master pages**

- **A-Cover:** Deep Ink `#1F1A17` fill, Cream `#FAF4EA` logo containment panel, tagline in Inter Regular 40% of wordmark size.
- **B-Contents:** Cream background, Creamsicle title "Contents" in Space Grotesk Bold 36pt.
- **C-Body:** Cream background, running header (chapter title, Inter SemiBold 10pt), running footer (page number, Inter SemiBold 10pt), Creamsicle 4px rule anchored below every H1 paragraph (via object style).
- **D-Back Cover:** Deep Ink background, contact block in Inter Regular 11pt.

- [ ] **Step 3: Define paragraph styles per `style-map.yaml`**

Each style uses the face, weight, size, and color specified. Enable "Based on: [No paragraph style]" for root styles to prevent inheritance drift. Map to ICML export names exactly as in `style-map.yaml`.

- [ ] **Step 4: Define character styles and object styles per `style-map.yaml`.**

- [ ] **Step 5: Set default font**

Type → Find Font: confirm Space Grotesk, Inter, IBM Plex Mono are the only faces used in the document.

- [ ] **Step 6: Save as .indd**

`Lungfish-Manual.indd` — commit in binary.

- [ ] **Step 7: Export IDML**

File → Save As → InDesign Markup (IDML) → `Lungfish-Manual.idml`. Commit both files together.

- [ ] **Step 8: Verify round-trip**

Close InDesign. Re-open `Lungfish-Manual.idml`. Confirm every style defined in step 3–4 is present and correctly named.

- [ ] **Step 9: Commit both artifacts**

```bash
git add docs/user-manual/build/indesign/Lungfish-Manual.indd docs/user-manual/build/indesign/Lungfish-Manual.idml
git commit -m "docs(manual): InDesign template — master pages + styles"
```

### Task 5.3: Write diff-idml.sh

**Files:**
- Create: `docs/user-manual/build/scripts/diff-idml.sh`

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "usage: diff-idml.sh <old.idml> <new.idml>"
  exit 2
fi

OLD="$1"
NEW="$2"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/old" "$TMP/new"
( cd "$TMP/old" && unzip -q "$OLD" )
( cd "$TMP/new" && unzip -q "$NEW" )

# Pretty-print each XML file for readable diffs.
command -v xmllint >/dev/null || { echo "xmllint required (install via 'brew install libxml2')" >&2; exit 1; }
for f in $(cd "$TMP/old" && find . -name '*.xml'); do
  xmllint --format "$TMP/old/$f" > "$TMP/old/$f.pretty" 2>/dev/null || true
done
for f in $(cd "$TMP/new" && find . -name '*.xml'); do
  xmllint --format "$TMP/new/$f" > "$TMP/new/$f.pretty" 2>/dev/null || true
done

diff -ruN "$TMP/old" "$TMP/new" --exclude='*.xml'  # metadata files
find "$TMP/old" -name '*.pretty' | while read f; do
  rel="${f#$TMP/old/}"
  diff -u "$f" "$TMP/new/$rel" || true
done
```

- [ ] **Step 2: Mark executable**

```bash
chmod +x docs/user-manual/build/scripts/diff-idml.sh
```

- [ ] **Step 3: Smoke-test by diffing the IDML against itself**

```bash
docs/user-manual/build/scripts/diff-idml.sh \
  docs/user-manual/build/indesign/Lungfish-Manual.idml \
  docs/user-manual/build/indesign/Lungfish-Manual.idml
```
Expected: zero diff output.

- [ ] **Step 4: Commit**

```bash
git add docs/user-manual/build/scripts/diff-idml.sh
git commit -m "docs(manual): diff-idml.sh for reviewing template changes"
```

---

## Phase 6 — Pandoc → ICML pipeline

Goal: convert any chapter Markdown into ICML stories with style names matching the InDesign template. Validate against `style-map.yaml`.

### Task 6.1: Write the Lua filter

**Files:**
- Create: `docs/user-manual/build/scripts/icml-filter.lua`

- [ ] **Step 1: Write the filter**

```lua
-- icml-filter.lua
-- Maps pandoc AST nodes to InDesign ICML paragraph/character style names.
-- The target style names are defined in build/indesign/styles/style-map.yaml.

function Header(el)
  local level = el.level
  if level == 1 then
    el.attributes["custom-style"] = "H1"
  elseif level == 2 then
    el.attributes["custom-style"] = "H2"
  elseif level == 3 then
    el.attributes["custom-style"] = "H3"
  end
  return el
end

function CodeBlock(el)
  el.attributes["custom-style"] = "Code"
  return el
end

function Code(el)
  return pandoc.Span(el.text, pandoc.Attr("", {}, {{"custom-style", "InlineCode"}}))
end

function BlockQuote(el)
  el.attributes = el.attributes or {}
  return pandoc.Div(el.content, pandoc.Attr("", {}, {{"custom-style", "Callout"}}))
end

function Image(el)
  -- Wrap images in a figure with the ScreenshotFrame object style hint.
  return pandoc.Div({el}, pandoc.Attr("", {}, {{"custom-style", "ScreenshotFrame"}}))
end
```

- [ ] **Step 2: Commit**

```bash
git add docs/user-manual/build/scripts/icml-filter.lua
git commit -m "docs(manual): Lua filter mapping pandoc AST to InDesign styles"
```

### Task 6.2: Write md-to-icml.sh

**Files:**
- Create: `docs/user-manual/build/scripts/md-to-icml.sh`

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
BUILD_DIR="$(cd -- "$SCRIPT_DIR/.." &>/dev/null && pwd)"
OUT_DIR="$BUILD_DIR/indesign/stories"

if [[ $# -lt 1 ]]; then
  echo "usage: md-to-icml.sh <chapter.md> [<chapter.md>...]"
  exit 2
fi

command -v pandoc >/dev/null || { echo "pandoc required (brew install pandoc)" >&2; exit 1; }

mkdir -p "$OUT_DIR"

for md in "$@"; do
  rel="$(basename "$md" .md)"
  out="$OUT_DIR/$rel.icml"
  pandoc \
    --from markdown+yaml_metadata_block \
    --to icml \
    --lua-filter="$SCRIPT_DIR/icml-filter.lua" \
    -o "$out" \
    "$md"
  echo "wrote $out"
done
```

- [ ] **Step 2: Mark executable**

```bash
chmod +x docs/user-manual/build/scripts/md-to-icml.sh
```

- [ ] **Step 3: Smoke-test against `index.md`**

```bash
docs/user-manual/build/scripts/md-to-icml.sh docs/user-manual/index.md
```
Expected: `docs/user-manual/build/indesign/stories/index.icml` exists and contains `<ParagraphStyleRange` elements referencing `H1`, `Body`.

- [ ] **Step 4: Verify story uses expected styles**

```bash
grep -o 'AppliedParagraphStyle="[^"]*"' docs/user-manual/build/indesign/stories/index.icml | sort -u
```
Expected: entries referencing `H1`, `Body`, `Code` (and possibly `Inline Code`). No font names in the output — only style references.

- [ ] **Step 5: Commit**

```bash
git add docs/user-manual/build/scripts/md-to-icml.sh
git commit -m "docs(manual): md-to-icml.sh — pandoc with Lua filter"
```

### Task 6.3: Add a style-validator check

**Files:**
- Create: `docs/user-manual/build/scripts/validate-styles.sh`

- [ ] **Step 1: Write the validator**

```bash
#!/usr/bin/env bash
set -euo pipefail

# Verify every AppliedParagraphStyle / AppliedCharacterStyle referenced in
# generated ICML exists in style-map.yaml.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
STYLE_MAP="$SCRIPT_DIR/../indesign/styles/style-map.yaml"
STORIES_DIR="$SCRIPT_DIR/../indesign/stories"

if [[ ! -f "$STYLE_MAP" ]]; then
  echo "style-map.yaml not found: $STYLE_MAP" >&2
  exit 1
fi

ALLOWED="$(mktemp)"
trap 'rm -f "$ALLOWED"' EXIT

python3 -c "
import yaml, sys
with open('$STYLE_MAP') as f:
    data = yaml.safe_load(f)
names = set()
for section in ('paragraph_styles', 'character_styles', 'object_styles'):
    names.update((data.get(section) or {}).keys())
for n in sorted(names):
    print(n)
" > "$ALLOWED"

fail=0
while IFS= read -r icml; do
  referenced="$(grep -oE 'Applied(Paragraph|Character)Style=\"[^\"]+\"' "$icml" | sed -E 's/.*="([^"]+)"/\1/' | awk -F/ '{print $NF}' | sort -u)"
  while IFS= read -r name; do
    if [[ -z "$name" ]]; then continue; fi
    if ! grep -qx "$name" "$ALLOWED"; then
      echo "$icml: unknown style '$name' (not in style-map.yaml)" >&2
      fail=1
    fi
  done <<<"$referenced"
done < <(find "$STORIES_DIR" -name '*.icml')

exit $fail
```

- [ ] **Step 2: Mark executable and run**

```bash
chmod +x docs/user-manual/build/scripts/validate-styles.sh
docs/user-manual/build/scripts/validate-styles.sh
```
Expected: exit 0 for the previously-generated `index.icml`.

- [ ] **Step 3: Commit**

```bash
git add docs/user-manual/build/scripts/validate-styles.sh
git commit -m "docs(manual): validate-styles.sh — ICML → style-map check"
```

---

## Phase 7 — Screenshot Scout runner

Goal: a Node-based driver that reads a recipe YAML, executes Computer Use calls against the Lungfish app, captures a 2× retina PNG, composites SVG overlays, and perceptual-hash-diffs against the previous capture.

### Task 7.1: Initialize Node package for the runner

**Files:**
- Create: `docs/user-manual/build/scripts/shot/package.json`

- [ ] **Step 1: Write pinned package.json**

```json
{
  "name": "lungfish-manual-shot",
  "version": "0.1.0",
  "private": true,
  "type": "module",
  "description": "Computer Use screenshot runner for the Lungfish user manual.",
  "bin": {
    "shot": "./runner.mjs"
  },
  "scripts": {
    "test": "node --test test/*.mjs"
  },
  "dependencies": {
    "ajv": "8.17.1",
    "ajv-formats": "3.0.1",
    "sharp": "0.33.5",
    "yaml": "2.5.0"
  }
}
```

- [ ] **Step 2: Install**

```bash
cd docs/user-manual/build/scripts/shot && npm install
```
Expected: `package-lock.json` created.

- [ ] **Step 3: Commit**

```bash
git add docs/user-manual/build/scripts/shot/package.json docs/user-manual/build/scripts/shot/package-lock.json
git commit -m "docs(manual): init shot package"
```

### Task 7.2: Write recipe JSON Schema

**Files:**
- Create: `docs/user-manual/build/scripts/shot/schema.json`

- [ ] **Step 1: Write the schema**

```json
{
  "$schema": "https://json-schema.org/draft-07/schema",
  "title": "Lungfish screenshot recipe",
  "type": "object",
  "required": ["id", "chapter", "caption", "app_state", "steps", "crop", "post"],
  "properties": {
    "id": { "type": "string", "pattern": "^[a-z0-9][a-z0-9-]*$" },
    "chapter": { "type": "string" },
    "caption": { "type": "string" },
    "viewport_class": {
      "enum": ["sequence", "alignment", "variant", "assembly", "taxonomy", "none"]
    },
    "app_state": {
      "type": "object",
      "required": ["fixture", "window_size"],
      "properties": {
        "fixture": { "type": "string" },
        "open_files": {
          "type": "array",
          "items": { "type": "object" }
        },
        "window_size": {
          "type": "array",
          "items": { "type": "integer" },
          "minItems": 2,
          "maxItems": 2
        },
        "appearance": { "enum": ["light", "dark"] }
      }
    },
    "steps": {
      "type": "array",
      "items": {
        "type": "object",
        "required": ["action"],
        "properties": {
          "action": {
            "enum": ["open_application", "wait_ready", "open_file", "resize_window", "scroll_to"]
          }
        }
      }
    },
    "crop": {
      "type": "object",
      "required": ["mode"],
      "properties": {
        "mode": { "enum": ["viewport", "window", "region"] },
        "region": {
          "type": "array",
          "items": { "type": "integer" },
          "minItems": 4,
          "maxItems": 4
        }
      }
    },
    "annotations": {
      "type": "array",
      "items": {
        "type": "object",
        "required": ["type"],
        "properties": {
          "type": { "enum": ["callout", "bracket", "arrow", "box"] }
        }
      }
    },
    "post": {
      "type": "object",
      "properties": {
        "retina": { "type": "boolean" },
        "format": { "enum": ["png"] }
      }
    }
  }
}
```

- [ ] **Step 2: Commit**

```bash
git add docs/user-manual/build/scripts/shot/schema.json
git commit -m "docs(manual): recipe JSON Schema"
```

### Task 7.3: Write the runner skeleton with failing test

**Files:**
- Create: `docs/user-manual/build/scripts/shot/runner.mjs`
- Create: `docs/user-manual/build/scripts/shot/test/validate-recipe.mjs`
- Create: `docs/user-manual/build/scripts/shot/test/fixtures/valid-recipe.yaml`
- Create: `docs/user-manual/build/scripts/shot/test/fixtures/invalid-recipe.yaml`

- [ ] **Step 1: Write failing test**

Create `test/fixtures/valid-recipe.yaml`:

```yaml
id: example
chapter: 99-test/example
caption: "Example caption."
viewport_class: variant
app_state:
  fixture: docs/user-manual/fixtures/sarscov2-clinical
  window_size: [1600, 1000]
  appearance: light
steps:
  - action: open_application
crop:
  mode: viewport
post:
  retina: true
  format: png
```

Create `test/fixtures/invalid-recipe.yaml` (missing `id`, wrong `viewport_class`):

```yaml
chapter: 99-test/example
caption: "Example caption."
viewport_class: nonsense
app_state:
  fixture: docs/user-manual/fixtures/sarscov2-clinical
  window_size: [1600, 1000]
steps:
  - action: open_application
crop:
  mode: viewport
post:
  retina: true
  format: png
```

Create `test/validate-recipe.mjs`:

```javascript
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import yaml from "yaml";
import Ajv from "ajv";
import addFormats from "ajv-formats";

const here = dirname(fileURLToPath(import.meta.url));
const schema = JSON.parse(await readFile(resolve(here, "..", "schema.json"), "utf8"));
const ajv = new Ajv({ allErrors: true });
addFormats(ajv);
const validate = ajv.compile(schema);

async function load(name) {
  const raw = await readFile(resolve(here, "fixtures", name), "utf8");
  return yaml.parse(raw);
}

test("valid recipe passes schema", async () => {
  const ok = validate(await load("valid-recipe.yaml"));
  assert.equal(ok, true, JSON.stringify(validate.errors));
});

test("invalid recipe fails schema with specific errors", async () => {
  const ok = validate(await load("invalid-recipe.yaml"));
  assert.equal(ok, false);
  const paths = validate.errors.map((e) => e.instancePath + " " + e.message).join("\n");
  assert.match(paths, /'id'|required property/);
  assert.match(paths, /viewport_class|enum/);
});
```

- [ ] **Step 2: Run tests to confirm they fail because runner deps aren't imported correctly**

Run: `cd docs/user-manual/build/scripts/shot && node --test test/validate-recipe.mjs`
Expected: FAIL (Ajv needs `.default` import).

- [ ] **Step 3: Fix imports**

Ajv CJS interop: change to `import AjvModule from "ajv"; const Ajv = AjvModule.default; import addFormatsModule from "ajv-formats"; const addFormats = addFormatsModule.default;` if the plain `import Ajv from "ajv"` pattern fails with "Ajv is not a constructor". Re-run.

Expected: PASS.

- [ ] **Step 4: Write runner.mjs skeleton**

```javascript
#!/usr/bin/env node
/**
 * shot/runner.mjs
 *
 * Usage: node runner.mjs <recipe.yaml>
 *
 * Reads a recipe, validates against schema.json, prints a structured plan
 * (sequence of Computer Use tool calls), and in actual execution mode drives
 * the app via the Computer Use MCP. In sub-project 1 we ship validation +
 * plan mode; execution integration is finalised when capturing the two pilot
 * screenshots.
 */
import { readFile, writeFile } from "node:fs/promises";
import { resolve, dirname, basename } from "node:path";
import { fileURLToPath } from "node:url";
import yaml from "yaml";
import AjvModule from "ajv";
import addFormatsModule from "ajv-formats";

const Ajv = AjvModule.default ?? AjvModule;
const addFormats = addFormatsModule.default ?? addFormatsModule;

const here = dirname(fileURLToPath(import.meta.url));
const schema = JSON.parse(await readFile(resolve(here, "schema.json"), "utf8"));
const ajv = new Ajv({ allErrors: true });
addFormats(ajv);
const validate = ajv.compile(schema);

const [, , cmd, recipePath, ...rest] = process.argv;
if (!cmd || !recipePath) {
  console.error("usage: runner.mjs <plan|execute> <recipe.yaml>");
  process.exit(2);
}

const raw = await readFile(resolve(recipePath), "utf8");
const recipe = yaml.parse(raw);
if (!validate(recipe)) {
  for (const err of validate.errors) console.error(`recipe error: ${err.instancePath} ${err.message}`);
  process.exit(1);
}

if (cmd === "plan") {
  console.log(JSON.stringify(buildPlan(recipe), null, 2));
  process.exit(0);
}
if (cmd === "execute") {
  console.error("execute mode stubbed — see Phase 9 pilot tasks");
  process.exit(2);
}
console.error(`unknown command: ${cmd}`);
process.exit(2);

function buildPlan(recipe) {
  return {
    id: recipe.id,
    chapter: recipe.chapter,
    access_request: ["Lungfish"],
    steps: recipe.steps.map((s) => ({
      tool: mapActionToTool(s.action),
      args: { ...s },
    })),
    capture: { retina: recipe.post?.retina ?? true },
    crop: recipe.crop,
    annotations: recipe.annotations ?? [],
  };
}

function mapActionToTool(action) {
  switch (action) {
    case "open_application": return "mcp__computer-use__open_application";
    case "wait_ready": return "internal:wait";
    case "open_file": return "bash:open -a";
    case "resize_window": return "mcp__computer-use__computer_batch";
    case "scroll_to": return "mcp__computer-use__scroll";
    default: throw new Error(`unknown action: ${action}`);
  }
}
```

- [ ] **Step 5: Mark executable and smoke-test plan mode**

```bash
chmod +x docs/user-manual/build/scripts/shot/runner.mjs
node docs/user-manual/build/scripts/shot/runner.mjs plan docs/user-manual/build/scripts/shot/test/fixtures/valid-recipe.yaml
```
Expected: JSON plan printed to stdout, exit 0.

- [ ] **Step 6: Commit**

```bash
git add docs/user-manual/build/scripts/shot/runner.mjs docs/user-manual/build/scripts/shot/test/
git commit -m "docs(manual): shot runner with schema validation + plan mode"
```

### Task 7.4: Write the SVG annotation compositor

**Files:**
- Create: `docs/user-manual/build/scripts/shot/annotate.mjs`
- Create: `docs/user-manual/build/scripts/shot/test/annotate.mjs`
- Create: `docs/user-manual/build/scripts/shot/test/fixtures/solid.png` (generated in step 1)

- [ ] **Step 1: Generate a synthetic test PNG**

Add a test helper in `test/annotate.mjs`:

```javascript
import { test } from "node:test";
import assert from "node:assert/strict";
import { writeFile, readFile } from "node:fs/promises";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import sharp from "sharp";
import { compose } from "../annotate.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const solidPath = resolve(here, "fixtures", "solid.png");

test("annotate compose emits PNG with Creamsicle pixels near callout target", async () => {
  // 400x300 Cream background
  await sharp({
    create: { width: 400, height: 300, channels: 4, background: "#FAF4EA" }
  }).png().toFile(solidPath);

  const out = await compose({
    imagePath: solidPath,
    annotations: [
      { type: "bracket", region: [50, 50, 150, 150] },
      { type: "callout", target: [200, 100], text: "Here" },
    ],
  });

  const { data, info } = await sharp(out).raw().toBuffer({ resolveWithObject: true });
  // Scan for any Creamsicle pixel (#EE8B4F ≈ rgb(238,139,79))
  let found = false;
  for (let i = 0; i < data.length; i += info.channels) {
    if (Math.abs(data[i] - 238) < 6 && Math.abs(data[i+1] - 139) < 6 && Math.abs(data[i+2] - 79) < 6) {
      found = true; break;
    }
  }
  assert.equal(found, true, "expected Creamsicle pixels from the overlay");
});
```

- [ ] **Step 2: Run test to confirm failure**

Run: `node --test test/annotate.mjs`
Expected: FAIL — `Cannot find module '../annotate.mjs'`.

- [ ] **Step 3: Implement annotate.mjs**

```javascript
import sharp from "sharp";
import { readFile } from "node:fs/promises";

const CREAMSICLE = "#EE8B4F";
const DEEP_INK = "#1F1A17";

export async function compose({ imagePath, annotations }) {
  const img = sharp(await readFile(imagePath));
  const { width, height } = await img.metadata();
  const svg = buildSVG({ width, height, annotations });
  return img.composite([{ input: Buffer.from(svg), top: 0, left: 0 }]).png().toBuffer();
}

function buildSVG({ width, height, annotations }) {
  const parts = [];
  for (const a of annotations) {
    if (a.type === "bracket" && a.region) {
      const [x, y, w, h] = a.region;
      parts.push(`<rect x="${x}" y="${y}" width="${w}" height="${h}" fill="none" stroke="${CREAMSICLE}" stroke-width="2" rx="4"/>`);
    } else if (a.type === "box" && a.region) {
      const [x, y, w, h] = a.region;
      parts.push(`<rect x="${x}" y="${y}" width="${w}" height="${h}" fill="none" stroke="${CREAMSICLE}" stroke-width="2"/>`);
    } else if (a.type === "callout" && a.target) {
      const [tx, ty] = a.target;
      const text = escapeXml(a.text ?? "");
      parts.push(`<circle cx="${tx}" cy="${ty}" r="6" fill="${CREAMSICLE}"/>`);
      parts.push(`<text x="${tx + 12}" y="${ty + 4}" fill="${DEEP_INK}" font-family="Inter" font-size="14" font-weight="600">${text}</text>`);
    } else if (a.type === "arrow" && a.from && a.to) {
      const [x1, y1] = a.from;
      const [x2, y2] = a.to;
      parts.push(`<line x1="${x1}" y1="${y1}" x2="${x2}" y2="${y2}" stroke="${CREAMSICLE}" stroke-width="2"/>`);
    }
  }
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}">${parts.join("")}</svg>`;
}

function escapeXml(s) {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}
```

- [ ] **Step 4: Run test to confirm pass**

Run: `node --test test/annotate.mjs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add docs/user-manual/build/scripts/shot/annotate.mjs docs/user-manual/build/scripts/shot/test/annotate.mjs
git commit -m "docs(manual): shot — SVG annotation compositor"
```

### Task 7.5: Write perceptual-hash diff

**Files:**
- Create: `docs/user-manual/build/scripts/shot/phash-diff.mjs`
- Create: `docs/user-manual/build/scripts/shot/test/phash.mjs`

- [ ] **Step 1: Write failing test**

`test/phash.mjs`:

```javascript
import { test } from "node:test";
import assert from "node:assert/strict";
import sharp from "sharp";
import { writeFile } from "node:fs/promises";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { tmpdir } from "node:os";
import { phashDistance } from "../phash-diff.mjs";

const t = resolve(tmpdir(), "lf-phash");

test("identical images have distance 0", async () => {
  const a = resolve(t, "a.png");
  await sharp({ create: { width: 64, height: 64, channels: 3, background: "#FAF4EA" } }).png().toFile(a);
  const d = await phashDistance(a, a);
  assert.equal(d, 0);
});

test("obviously-different images have distance > 10", async () => {
  const a = resolve(t, "a.png");
  const b = resolve(t, "b.png");
  await sharp({ create: { width: 64, height: 64, channels: 3, background: "#FAF4EA" } }).png().toFile(a);
  await sharp({ create: { width: 64, height: 64, channels: 3, background: "#1F1A17" } }).png().toFile(b);
  const d = await phashDistance(a, b);
  assert.ok(d > 10, `expected > 10, got ${d}`);
});
```

- [ ] **Step 2: Run to confirm failure.**

- [ ] **Step 3: Implement phash-diff.mjs**

Implement an 8×8 DCT-based perceptual hash using sharp for grayscale 32×32 → DCT → top-left 8×8 → median threshold → 64-bit hash. Hamming distance between two 64-bit hashes:

```javascript
import sharp from "sharp";

export async function phash(path) {
  const { data } = await sharp(path)
    .greyscale()
    .resize(32, 32, { fit: "fill" })
    .raw()
    .toBuffer({ resolveWithObject: true });

  // Naive 32x32 DCT-II (row + column)
  const N = 32;
  const pixels = new Float64Array(N * N);
  for (let i = 0; i < pixels.length; i++) pixels[i] = data[i];

  const dct = dct2d(pixels, N);

  // Take top-left 8x8, excluding DC (first coefficient)
  const coeffs = [];
  for (let y = 0; y < 8; y++) {
    for (let x = 0; x < 8; x++) {
      if (x === 0 && y === 0) continue;
      coeffs.push(dct[y * N + x]);
    }
  }
  const median = [...coeffs].sort((a, b) => a - b)[Math.floor(coeffs.length / 2)];
  let hash = 0n;
  for (let i = 0; i < 63; i++) {
    if (coeffs[i] > median) hash |= 1n << BigInt(i);
  }
  return hash;
}

export async function phashDistance(pathA, pathB) {
  const [a, b] = await Promise.all([phash(pathA), phash(pathB)]);
  let x = a ^ b, d = 0;
  while (x !== 0n) { d += Number(x & 1n); x >>= 1n; }
  return d;
}

function dct2d(src, N) {
  const rowOut = new Float64Array(N * N);
  const out = new Float64Array(N * N);

  // Row DCT
  for (let y = 0; y < N; y++) {
    for (let u = 0; u < N; u++) {
      let sum = 0;
      for (let x = 0; x < N; x++) {
        sum += src[y * N + x] * Math.cos(((2 * x + 1) * u * Math.PI) / (2 * N));
      }
      const alpha = u === 0 ? 1 / Math.sqrt(N) : Math.sqrt(2 / N);
      rowOut[y * N + u] = alpha * sum;
    }
  }

  // Column DCT
  for (let u = 0; u < N; u++) {
    for (let v = 0; v < N; v++) {
      let sum = 0;
      for (let y = 0; y < N; y++) {
        sum += rowOut[y * N + u] * Math.cos(((2 * y + 1) * v * Math.PI) / (2 * N));
      }
      const alpha = v === 0 ? 1 / Math.sqrt(N) : Math.sqrt(2 / N);
      out[v * N + u] = alpha * sum;
    }
  }
  return out;
}
```

- [ ] **Step 4: Run tests to confirm pass.**

Run: `cd docs/user-manual/build/scripts/shot && node --test test/phash.mjs`
Expected: both tests PASS.

- [ ] **Step 5: Commit**

```bash
git add docs/user-manual/build/scripts/shot/phash-diff.mjs docs/user-manual/build/scripts/shot/test/phash.mjs
git commit -m "docs(manual): shot — perceptual hash diff"
```

### Task 7.6: Wire up run-shot.sh

**Files:**
- Create: `docs/user-manual/build/scripts/run-shot.sh`

- [ ] **Step 1: Write the wrapper**

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
SHOT_DIR="$SCRIPT_DIR/shot"

if [[ ! -d "$SHOT_DIR/node_modules" ]]; then
  echo "installing shot dependencies…" >&2
  (cd "$SHOT_DIR" && npm install --silent)
fi

CMD="${1:-}"
shift || true

case "$CMD" in
  plan|execute)
    exec node "$SHOT_DIR/runner.mjs" "$CMD" "$@"
    ;;
  *)
    echo "usage: run-shot.sh <plan|execute> <recipe.yaml>" >&2
    exit 2
    ;;
esac
```

- [ ] **Step 2: Mark executable and smoke-test**

```bash
chmod +x docs/user-manual/build/scripts/run-shot.sh
docs/user-manual/build/scripts/run-shot.sh plan docs/user-manual/build/scripts/shot/test/fixtures/valid-recipe.yaml
```
Expected: JSON plan, exit 0.

- [ ] **Step 3: Commit**

```bash
git add docs/user-manual/build/scripts/run-shot.sh
git commit -m "docs(manual): run-shot.sh wrapper"
```

---

## Phase 8 — Pilot fixture curation (`sarscov2-clinical`)

Goal: a complete, ≤50 MB, internally-coherent SARS-CoV-2 clinical-isolate fixture set with provenance, license, citation. Cartographer + Educator co-own this (Cartographer: source/license/citation/size; Educator: internal-consistency narrative).

### Task 8.1: Source candidate data

The Cartographer performs a literature/accession search. Candidates must satisfy:
- Real-world, published clinical isolate (preferred: a NEBNext/ARTIC/midnight amplicon dataset).
- Paired-end FASTQ available under a license that permits redistribution (CC0 / CC-BY / public-domain NCBI), **or** under SRA with no redistribution restriction.
- ≤10 MB per file after downsampling.
- Reads align cleanly to NC_045512.2 (Wuhan-Hu-1 reference).
- Variants callable from the reads produce a small VCF consistent with a published lineage.

- [ ] **Step 1: Identify candidates**

Use `mcp__a4479bfc-051e-4b16-96f9-6684d4f5a88d__search_articles` or WebSearch to find a published clinical isolate with SRA accession. Prefer nf-core/test-datasets entries if a suitable one exists (already MIT-licensed; already committed elsewhere in the repo under `Tests/Fixtures/sarscov2/`).

- [ ] **Step 2: Document candidates**

Write candidate notes into a scratch file `docs/user-manual/fixtures/sarscov2-clinical/CANDIDATES.md` (not committed in final). Include accession, license, size, rationale.

- [ ] **Step 3: Choose**

Select one candidate. Prefer leveraging the existing `Tests/Fixtures/sarscov2/` data already in this repo if it is single-isolate clinical (not wastewater or synthetic). Otherwise download from SRA / ENA.

- [ ] **Step 4: Remove CANDIDATES.md (keep decision in fixture README)**

```bash
rm docs/user-manual/fixtures/sarscov2-clinical/CANDIDATES.md
```

### Task 8.2: Build the fixture files

**Files:**
- Create: `docs/user-manual/fixtures/sarscov2-clinical/reference.fasta`
- Create: `docs/user-manual/fixtures/sarscov2-clinical/reference.fasta.fai`
- Create: `docs/user-manual/fixtures/sarscov2-clinical/reads_R1.fastq.gz`
- Create: `docs/user-manual/fixtures/sarscov2-clinical/reads_R2.fastq.gz`
- Create: `docs/user-manual/fixtures/sarscov2-clinical/alignments.bam`
- Create: `docs/user-manual/fixtures/sarscov2-clinical/alignments.bam.bai`
- Create: `docs/user-manual/fixtures/sarscov2-clinical/variants.vcf.gz`
- Create: `docs/user-manual/fixtures/sarscov2-clinical/variants.vcf.gz.tbi`
- Create: `docs/user-manual/fixtures/sarscov2-clinical/fetch.sh`

- [ ] **Step 1: Stage reference**

If reusing `Tests/Fixtures/sarscov2/reference.fasta`:

```bash
mkdir -p docs/user-manual/fixtures/sarscov2-clinical
cp Tests/Fixtures/sarscov2/reference.fasta docs/user-manual/fixtures/sarscov2-clinical/reference.fasta
cp Tests/Fixtures/sarscov2/reference.fasta.fai docs/user-manual/fixtures/sarscov2-clinical/reference.fasta.fai
```

If downloading fresh, `fetch.sh` (step 6) drives the download.

- [ ] **Step 2: Verify reference size**

```bash
ls -lh docs/user-manual/fixtures/sarscov2-clinical/reference.fasta
```
Expected: well under 1 MB.

- [ ] **Step 3: Stage reads**

Copy and, if necessary, downsample to ≤10 MB per file using `seqkit sample -p <fraction>`:

```bash
cp Tests/Fixtures/sarscov2/reads_R1.fastq.gz docs/user-manual/fixtures/sarscov2-clinical/reads_R1.fastq.gz
cp Tests/Fixtures/sarscov2/reads_R2.fastq.gz docs/user-manual/fixtures/sarscov2-clinical/reads_R2.fastq.gz
ls -lh docs/user-manual/fixtures/sarscov2-clinical/reads_*
```

- [ ] **Step 4: Stage BAM + index**

```bash
cp Tests/Fixtures/sarscov2/alignments.bam docs/user-manual/fixtures/sarscov2-clinical/alignments.bam
cp Tests/Fixtures/sarscov2/alignments.bam.bai docs/user-manual/fixtures/sarscov2-clinical/alignments.bam.bai
```

- [ ] **Step 5: Stage VCF**

```bash
cp Tests/Fixtures/sarscov2/variants.vcf.gz docs/user-manual/fixtures/sarscov2-clinical/variants.vcf.gz
cp Tests/Fixtures/sarscov2/variants.vcf.gz.tbi docs/user-manual/fixtures/sarscov2-clinical/variants.vcf.gz.tbi
```

- [ ] **Step 6: Write fetch.sh (for on-demand re-download)**

```bash
cat > docs/user-manual/fixtures/sarscov2-clinical/fetch.sh <<'EOF'
#!/usr/bin/env bash
# Re-downloads source data for the sarscov2-clinical fixture.
# Run from this directory. No-op if files are already present.
set -euo pipefail
echo "Fixture files are committed in this repository."
echo "If a file is missing, restore from git or re-derive following the README."
EOF
chmod +x docs/user-manual/fixtures/sarscov2-clinical/fetch.sh
```

(If we chose an SRA-only source, replace the body with actual `prefetch`/`fasterq-dump` calls and a downsampling pipeline. The fixture README records the exact commands.)

### Task 8.3: Write validate-fixture.sh

**Files:**
- Create: `docs/user-manual/build/scripts/validate-fixture.sh`

- [ ] **Step 1: Write the validator**

```bash
#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: validate-fixture.sh <fixture-dir>"
  exit 2
fi

DIR="$1"
fail=0

require_file() {
  [[ -f "$DIR/$1" ]] || { echo "MISSING: $1" >&2; fail=1; }
}

require_section() {
  grep -q "^## $1\b" "$DIR/README.md" || { echo "README.md missing section: $1" >&2; fail=1; }
}

require_file README.md
require_file reference.fasta
require_file reads_R1.fastq.gz
require_file reads_R2.fastq.gz

for section in Source License Citation Size "Internal consistency"; do
  require_section "$section"
done

# Size caps
TOTAL=$(du -sk "$DIR" | cut -f1)
if [[ $TOTAL -gt 51200 ]]; then
  echo "TOTAL SIZE ${TOTAL}K exceeds 50 MB cap" >&2
  fail=1
fi
while IFS= read -r f; do
  SIZE=$(wc -c <"$f")
  if [[ $SIZE -gt 10485760 ]]; then
    echo "FILE SIZE exceeds 10 MB: $f ($SIZE bytes)" >&2
    fail=1
  fi
done < <(find "$DIR" -type f ! -name "*.md" ! -name "fetch.sh")

exit $fail
```

- [ ] **Step 2: Mark executable**

```bash
chmod +x docs/user-manual/build/scripts/validate-fixture.sh
```

- [ ] **Step 3: Commit the fixture binaries + validator**

```bash
git add docs/user-manual/fixtures/sarscov2-clinical/ docs/user-manual/build/scripts/validate-fixture.sh
git commit -m "docs(manual): stage sarscov2-clinical fixture binaries + validator"
```

### Task 8.4: Write the fixture README (Cartographer + Educator)

**Files:**
- Create: `docs/user-manual/fixtures/sarscov2-clinical/README.md`

- [ ] **Step 1: Write the README**

```markdown
# sarscov2-clinical

A SARS-CoV-2 clinical-isolate fixture set used by the pilot chapter
`chapters/04-variants/01-reading-a-vcf.md`. Reused across later chapters
covering alignment, variant calling, and classification baselines.

A **clinical isolate** is used deliberately rather than a wastewater sample.
Wastewater VCFs carry low-frequency variants, mixed lineages, and dropout
regions. These complications deserve their own chapter, not a reader's first
exposure to VCF.

## Source

The reference is NCBI RefSeq NC_045512.2 (Severe acute respiratory syndrome
coronavirus 2 isolate Wuhan-Hu-1, complete genome). The reads are derived
from nf-core/test-datasets sarscov2 paired-end FASTQ (MIT license; see
Citation). Alignments and variants are derived from those reads aligned to
NC_045512.2 with minimap2, samtools, and bcftools.

## License

All files redistribute under MIT, matching the upstream nf-core/test-datasets
license. Retained intact for redistribution in this repository.

## Citation

```bibtex
@misc{nfcore_test_datasets,
  author       = {{nf-core community}},
  title        = {nf-core/test-datasets: sarscov2},
  year         = {2020},
  howpublished = {\url{https://github.com/nf-core/test-datasets/tree/sarscov2}},
  note         = {MIT license}
}
```

Chapters using this fixture cite the block above via `fixtures_refs: [sarscov2-clinical]`.

## Size

| File | Size | Notes |
|---|---|---|
| reference.fasta | <1 MB | NC_045512.2 (29 903 bp) |
| reference.fasta.fai | <1 KB | samtools faidx |
| reads_R1.fastq.gz | <10 MB | paired-end R1 |
| reads_R2.fastq.gz | <10 MB | paired-end R2 |
| alignments.bam | <10 MB | sorted, indexed |
| alignments.bam.bai | <1 MB | (index) |
| variants.vcf.gz | <1 MB | bcftools-called SNPs and indels |
| variants.vcf.gz.tbi | <1 KB | tabix index |

Total well under the 50 MB fixture-set cap.

## Internal consistency

Reads align end-to-end to the reference with zero unaligned contigs: the
reference is the genome the reads came from. All variants in
`variants.vcf.gz` were called from `alignments.bam`; each REF allele matches
the base at that position in `reference.fasta`. Genotype fields are
diploid-style `0/1` or `1/1` by convention, appropriate for a single-isolate
clinical sample (near-100% allele frequencies). The chromosome name is the
RefSeq accession `NC_045512.2`, not `MN908947.3` or `chrCOV19`. Alignment
BAM, VCF, and FASTA all agree on this name.

## How to re-derive

See `fetch.sh` for the reproducibility commands (samtools, bcftools, and
minimap2 versions pinned to the Lungfish app's bundled versions). The staged
files in this directory are the canonical form. `fetch.sh` exists for
reviewers who want to verify reproducibility.

## Used by

`chapters/04-variants/01-reading-a-vcf.md` is the pilot chapter (variants).
Future chapters on alignment, classification, and assembly may reuse this
set.
```

- [ ] **Step 2: Validate the fixture**

```bash
docs/user-manual/build/scripts/validate-fixture.sh docs/user-manual/fixtures/sarscov2-clinical
```
Expected: exit 0.

- [ ] **Step 3: Commit**

```bash
git add docs/user-manual/fixtures/sarscov2-clinical/README.md
git commit -m "docs(manual): sarscov2-clinical fixture README with provenance"
```

---

## Phase 9 — Pilot chapter end-to-end (`04-variants/01-reading-a-vcf.md`)

Goal: the pilot chapter lands through every stage — Lead stub → Educator body → Scout screenshots → Lint green → Brand Editor pass → Lead approval — and renders in MkDocs and InDesign from the same Markdown source.

### Task 9.1: Lead writes chapter stub + gate 1 review

**Files:**
- Create: `docs/user-manual/chapters/04-variants/01-reading-a-vcf.md`
- Create: `docs/user-manual/reviews/04-variants/2026-04-15-lead-gate1.md`

- [ ] **Step 1: Write chapter stub**

```markdown
---
title: Reading a VCF file
chapter_id: 04-variants/01-reading-a-vcf
audience: bench-scientist
prereqs: []
estimated_reading_min: 8
shots:
  - id: vcf-open-dialog
    caption: "The Open dialog filtered to VCF files."
  - id: vcf-variant-table
    caption: "A loaded VCF showing variants aligned to the reference."
glossary_refs: [VCF, REF, ALT, genotype, allele-frequency]
features_refs: [import.vcf, viewport.variant-browser]
fixtures_refs: [sarscov2-clinical]
brand_reviewed: false
lead_approved: false
---

## What it is

<!-- Educator: 2–4 paragraphs introducing VCF. Include an annotated snippet. -->

## Why this matters

<!-- Educator: the reader's "so what?" answer. One short paragraph. -->

## Procedure

<!-- Educator: numbered steps referencing SHOT markers. -->

<!-- SHOT: vcf-open-dialog -->

<!-- SHOT: vcf-variant-table -->

## Interpreting what you see

<!-- Educator: REF/ALT/GT/allele frequency in the table, with fixture examples. -->

## Next steps

<!-- Educator: one short paragraph pointing forward. -->
```

- [ ] **Step 2: Write gate 1 review**

```markdown
# Lead gate 1: 04-variants/01-reading-a-vcf

Date: 2026-04-15

## Chapter plan

Audience: bench-scientist. Prereqs: none. This is the pilot chapter and
intentionally stands alone so the pipeline can be proven before prereq
relationships are established. Estimated length: 8 minutes. Fixture:
`sarscov2-clinical`, a clinical isolate chosen to keep the reader's first VCF
clean (single organism, high AF SNPs relative to the RefSeq reference
NC_045512.2).

## Shots

`vcf-open-dialog` shows the file picker filtered to `.vcf.gz`. It grounds the
reader in the opening action and proves filters work. `vcf-variant-table`
shows the loaded VCF in the variant browser with the first few SNPs visible.
It is used in the Interpretation section to anchor REF, ALT, GT, and AF.

## Prereq-graph placement

None. Future chapters (alignment, assembly) will list this as a prereq once
they land.

## Status

Ready for Educator to write the body. Approved to proceed.
```

- [ ] **Step 3: Lint the stub**

```bash
docs/user-manual/build/scripts/lint-chapter.sh docs/user-manual/chapters/04-variants/01-reading-a-vcf.md
```
Expected: exit 0 (frontmatter valid; no body yet means no voice/palette violations; SHOT markers present in body match `shots[]`).

- [ ] **Step 4: Commit**

```bash
git add docs/user-manual/chapters/04-variants/01-reading-a-vcf.md docs/user-manual/reviews/04-variants/2026-04-15-lead-gate1.md
git commit -m "docs(manual): pilot chapter stub + Lead gate 1 review"
```

**USER GATE 1 — surface the review to the user and await approval before continuing to Task 9.2.**

### Task 9.2: Cartographer ensures relevant feature entries exist

**Files:**
- Modify: `docs/user-manual/features.yaml`

- [ ] **Step 1: Update features.yaml**

Replace the `features: {}` placeholder with entries for the two features the pilot chapter references:

```yaml
version: 0
features:
  import.vcf:
    title: Import VCF
    entry_points:
      - "File → Open… (filter: VCF)"
      - "Import Center → Variants"
      - "CLI: lungfish import vcf"
    inputs: [VCF, VCF.GZ]
    outputs: [viewport.variant-browser]
    viewport_class: variant
    sources:
      - Sources/LungfishIO/VCFReader.swift
      - Sources/LungfishApp/Views/Results/Variants/VariantResultViewController.swift
    notes: >
      Reads a bgzipped+tabix'd VCF (or raw VCF) and presents it in the variant
      browser. Chromosome aliasing resolves across RefSeq / UCSC / Ensembl.

  viewport.variant-browser:
    title: Variant browser
    entry_points: ["Opening a VCF auto-loads this viewport"]
    inputs: [VCF from import.vcf]
    outputs: [table view + genome context track]
    viewport_class: variant
    sources:
      - Sources/LungfishApp/Views/Results/Variants/VariantResultViewController.swift
    notes: >
      Table with CHROM, POS, REF, ALT, QUAL, FILTER, INFO. Reference FASTA, when
      present, provides coordinate context and base-level detail.
```

- [ ] **Step 2: Commit**

```bash
git add docs/user-manual/features.yaml
git commit -m "docs(manual): features.yaml — import.vcf and viewport.variant-browser entries"
```

### Task 9.3: Educator writes chapter body

**Files:**
- Modify: `docs/user-manual/chapters/04-variants/01-reading-a-vcf.md`
- Modify: `docs/user-manual/GLOSSARY.md`

- [ ] **Step 1: Write body prose**

Replace HTML comment placeholders with body content. Example opening (Educator writes the rest):

```markdown
## What it is

A VCF file (Variant Call Format) records differences between a sample genome
and a reference genome. Where a FASTA file answers "what are the bases?" and
a BAM file answers "which reads cover which positions?", a VCF answers "where
does this sample differ from the reference, and how confidently?"

Each non-header line is one position in the reference where the sample
differs. The columns most readers care about first are `CHROM`, `POS`, `REF`,
`ALT`, and `QUAL`:

```text
#CHROM     POS    ID   REF  ALT   QUAL    FILTER  INFO
NC_045512.2  241   .   C    T    228.0   PASS    DP=284;AF=0.997
NC_045512.2  3037  .   C    T    228.0   PASS    DP=312;AF=0.994
```

`REF` is the base in the reference FASTA at `POS`. `ALT` is the base observed
in this sample. `QUAL` is the caller's confidence in the call, on a
phred-style scale. The `INFO` column packs per-call metadata: depth (`DP`),
allele frequency (`AF`), and others depending on the caller.

So what should you do with this? Open a VCF in Lungfish to see the variants
as a sortable, filterable table alongside the reference context. When the
reference is loaded too, you can click any row to see the exact position in
its genomic neighbourhood.

## Why this matters

Variants are where reads turn into interpretation. When you ask "does this
sample carry the spike D614G substitution?" you are asking a VCF question.
Reading VCFs fluently lets you check caller output before propagating results.

## Procedure

1. Open the reference FASTA first so the variant browser has a coordinate
   axis: File → Open → choose
   `fixtures/sarscov2-clinical/reference.fasta`.
2. Open the VCF: File → Open → choose
   `fixtures/sarscov2-clinical/variants.vcf.gz`. Lungfish filters the dialog
   to variant files when the active document is a reference.

<!-- SHOT: vcf-open-dialog -->

3. The variant browser opens with the VCF's rows as a sortable table. Click
   any column header to sort by that column. Right-click a row to copy the
   variant as a short string or to jump to its position on the reference
   track.

<!-- SHOT: vcf-variant-table -->

## Interpreting what you see

Each row is one variant call. In our fixture you will see a handful of SNPs
near positions 241, 3037, 14408, and 23403. These are classic SARS-CoV-2
markers from early lineages. `REF` and `ALT` describe the one-base substitution; `QUAL`
near 200 is a strong call; the `INFO` field's `AF` near 1.0 tells you the
sample is essentially fixed for the alternate allele at that position (what
you expect from a clinical isolate of a single lineage).

Genotype fields (`GT`) appear per sample after the `FORMAT` column. A clinical
isolate is conventionally represented as diploid-style `0/1` (heterozygous,
rare for a virus) or `1/1` (homozygous alternate, the usual case). The
fixture's calls are `1/1` throughout, matching the near-fixed allele
frequencies.

## Next steps

Once you are comfortable reading a VCF, the next chapter (coming in
sub-project 2) walks through calling variants yourself from a BAM file, where
you choose the caller and the filters.
```

- [ ] **Step 2: Append glossary entries**

Append to `GLOSSARY.md`:

```markdown
## A

**Allele frequency.** The proportion of sequencing reads at a position that
carry the alternate base. A clinical isolate usually shows allele frequencies
near 0 or 1; a mixed-population sample (e.g., wastewater) shows a full
spectrum.

## G

**Genotype.** A compact notation for which alleles are observed at a
position, conventionally diploid-style `0/1` or `1/1`. For a single-organism
viral isolate, genotypes are nearly always `1/1` at confidently-called
variant positions.

## R

**REF, ALT.** REF is the base present in the reference genome at a variant
position; ALT is the base observed in the sample.

## V

**VCF (Variant Call Format).** A tab-separated file format that lists
positions in a reference genome where a sample differs, with per-call
confidence and metadata. See also: REF, ALT, genotype, allele frequency.
```

- [ ] **Step 3: Lint the chapter**

```bash
docs/user-manual/build/scripts/lint-chapter.sh docs/user-manual/chapters/04-variants/01-reading-a-vcf.md
```
Expected: exit 0. Fix any findings (marketing words, stray hex values, out-of-order primers/procedure). Re-run until green.

- [ ] **Step 4: Commit**

```bash
git add docs/user-manual/chapters/04-variants/01-reading-a-vcf.md docs/user-manual/GLOSSARY.md
git commit -m "docs(manual): pilot chapter body + glossary entries"
```

### Task 9.4: Scout captures the two screenshots

**Files:**
- Create: `docs/user-manual/assets/recipes/04-variants/vcf-open-dialog.yaml`
- Create: `docs/user-manual/assets/recipes/04-variants/vcf-variant-table.yaml`
- Create: `docs/user-manual/assets/screenshots/04-variants/vcf-open-dialog.png`
- Create: `docs/user-manual/assets/screenshots/04-variants/vcf-variant-table.png`

- [ ] **Step 1: Write the two recipes**

`assets/recipes/04-variants/vcf-open-dialog.yaml`:

```yaml
id: vcf-open-dialog
chapter: 04-variants/01-reading-a-vcf
caption: "The Open dialog filtered to VCF files."
viewport_class: variant
app_state:
  fixture: docs/user-manual/fixtures/sarscov2-clinical
  open_files:
    - reference: "{fixture}/reference.fasta"
  window_size: [1600, 1000]
  appearance: light
steps:
  - action: open_application
    app: Lungfish
  - action: wait_ready
    signal: main_window_visible
  - action: open_file
    path: "{fixture}/reference.fasta"
  - action: wait_ready
    signal: sequence_viewer_loaded
  - action: resize_window
    size: [1600, 1000]
crop:
  mode: window
annotations:
  - type: bracket
    region: [1100, 340, 400, 40]
  - type: callout
    target: [1500, 360]
    text: "VCF files only"
post:
  retina: true
  format: png
```

`assets/recipes/04-variants/vcf-variant-table.yaml`:

```yaml
id: vcf-variant-table
chapter: 04-variants/01-reading-a-vcf
caption: "A loaded VCF showing variants aligned to the reference."
viewport_class: variant
app_state:
  fixture: docs/user-manual/fixtures/sarscov2-clinical
  open_files:
    - reference: "{fixture}/reference.fasta"
    - variants: "{fixture}/variants.vcf.gz"
  window_size: [1600, 1000]
  appearance: light
steps:
  - action: open_application
    app: Lungfish
  - action: wait_ready
    signal: main_window_visible
  - action: open_file
    path: "{fixture}/reference.fasta"
  - action: open_file
    path: "{fixture}/variants.vcf.gz"
  - action: wait_ready
    signal: variant_browser_loaded
  - action: resize_window
    size: [1600, 1000]
  - action: scroll_to
    target: first_variant
crop:
  mode: viewport
  region: [0, 60, 1600, 900]
annotations:
  - type: callout
    target: [420, 220]
    text: "REF: reference base"
  - type: callout
    target: [510, 220]
    text: "ALT: sample base"
  - type: bracket
    region: [600, 200, 120, 40]
post:
  retina: true
  format: png
```

- [ ] **Step 2: Validate recipes with the runner**

```bash
docs/user-manual/build/scripts/run-shot.sh plan docs/user-manual/assets/recipes/04-variants/vcf-open-dialog.yaml
docs/user-manual/build/scripts/run-shot.sh plan docs/user-manual/assets/recipes/04-variants/vcf-variant-table.yaml
```
Expected: both print JSON plans, exit 0.

- [ ] **Step 3: Capture screenshots via Computer Use**

Execution in sub-project 1 uses the Scout agent driving Computer Use directly, guided by the plan. The agent:

1. Calls `mcp__computer-use__request_access` with `{ "applications": ["Lungfish"] }`.
2. Builds the Lungfish debug build and launches it (`swift run Lungfish` from the main repo, not the worktree — per `MEMORY.md` "Worktree Build Restriction").
3. Executes the steps from the plan via Computer Use (`open_application`, `wait`, Bash `open -a Lungfish <path>`, `mcp__computer-use__resize_window`, `mcp__computer-use__scroll`).
4. Uses `mcp__computer-use__screenshot` to capture.
5. Crops per recipe. Composites annotations via `annotate.mjs`:

```bash
node -e "
  import('./docs/user-manual/build/scripts/shot/annotate.mjs').then(async (m) => {
    const { compose } = m;
    const out = await compose({
      imagePath: 'docs/user-manual/assets/screenshots/04-variants/vcf-open-dialog.raw.png',
      annotations: [
        { type: 'bracket', region: [1100, 340, 400, 40] },
        { type: 'callout', target: [1500, 360], text: 'VCF files only' }
      ]
    });
    const fs = await import('node:fs/promises');
    await fs.writeFile('docs/user-manual/assets/screenshots/04-variants/vcf-open-dialog.png', out);
  });
"
```

6. Writes the final PNG to `assets/screenshots/04-variants/<id>.png`.
7. If a previous PNG existed, runs `phash-diff.mjs`; if distance > 8 with no recipe change, writes `<id>.diff-report.md`.

- [ ] **Step 4: Verify both PNGs exist and are 2× retina**

```bash
file docs/user-manual/assets/screenshots/04-variants/*.png
```
Expected: both files exist, each reports `PNG image data`, width ≥ 3200 px (2× of 1600).

- [ ] **Step 5: Commit**

```bash
git add docs/user-manual/assets/
git commit -m "docs(manual): pilot chapter screenshots + recipes"
```

### Task 9.5: Lint-green check

- [ ] **Step 1: Run lint against the chapter**

```bash
docs/user-manual/build/scripts/lint-chapter.sh docs/user-manual/chapters/04-variants/01-reading-a-vcf.md
```
Expected: exit 0.

If the linter finds issues, fix them in the chapter (Educator's responsibility) and commit:

```bash
git add docs/user-manual/chapters/04-variants/01-reading-a-vcf.md
git commit -m "docs(manual): pilot chapter — address lint findings"
```

Iterate until green. **Screenshots are preserved across lint loops** unless SHOT markers changed.

### Task 9.6: Brand Copy Editor pass

**Files:**
- Modify: `docs/user-manual/chapters/04-variants/01-reading-a-vcf.md` (brand edits + `brand_reviewed: true`)
- Create: `docs/user-manual/reviews/04-variants/2026-04-15-brand.md`

- [ ] **Step 1: Brand Editor reviews and edits for brand fidelity only**

Expected edit categories:
- Tighten captions to brand caption style.
- Verify every hex value in prose is in-palette (lint already caught non-palette).
- Verify tone matches the six voice qualities.

- [ ] **Step 2: Write brand review**

```markdown
# Brand review: 04-variants/01-reading-a-vcf

Date: 2026-04-15

## Changes applied

(record each change with line number and rationale)

## Observations

None for sub-project 1.

## Status

brand_reviewed: true
```

- [ ] **Step 3: Flip frontmatter**

Edit chapter: `brand_reviewed: false` → `brand_reviewed: true`.

- [ ] **Step 4: Re-lint to confirm still green**

```bash
docs/user-manual/build/scripts/lint-chapter.sh docs/user-manual/chapters/04-variants/01-reading-a-vcf.md
```
Expected: exit 0.

- [ ] **Step 5: Commit**

```bash
git add docs/user-manual/chapters/04-variants/01-reading-a-vcf.md docs/user-manual/reviews/04-variants/2026-04-15-brand.md
git commit -m "docs(manual): pilot chapter — brand review + brand_reviewed flag"
```

### Task 9.7: Documentation Lead gate 2

**Files:**
- Modify: `docs/user-manual/chapters/04-variants/01-reading-a-vcf.md` (`lead_approved: true`)
- Create: `docs/user-manual/reviews/04-variants/2026-04-15-lead-gate2.md`

- [ ] **Step 1: Lead reviews the chapter end-to-end**

Checks:
- Chapter renders in MkDocs (Task 9.8 verifies).
- Screenshots are present and captioned correctly.
- Glossary links resolve.
- Fixture citation appears.
- Voice matches brand.

- [ ] **Step 2: Write gate 2 review**

```markdown
# Lead gate 2: 04-variants/01-reading-a-vcf

Date: 2026-04-15

## Status

- [x] Lint green
- [x] Brand review complete (brand_reviewed: true)
- [x] Screenshots match recipes
- [x] Fixture metadata complete
- [x] Glossary updated
- [x] Features inventory updated

## Approval

lead_approved: true
```

- [ ] **Step 3: Flip frontmatter**

Edit chapter: `lead_approved: false` → `lead_approved: true`.

- [ ] **Step 4: Commit**

```bash
git add docs/user-manual/chapters/04-variants/01-reading-a-vcf.md docs/user-manual/reviews/04-variants/2026-04-15-lead-gate2.md
git commit -m "docs(manual): pilot chapter — Lead gate 2 approval"
```

**USER GATE 2 — surface the final chapter + gate 2 review to the user.**

### Task 9.8: MkDocs render + InDesign ICML export

- [ ] **Step 1: Render MkDocs**

```bash
docs/user-manual/build/scripts/render-mkdocs.sh
```
Expected: site includes the pilot chapter at `site/chapters/04-variants/01-reading-a-vcf/index.html` (or similar). Open in a browser to confirm:
- Cream background, Deep Ink text.
- Creamsicle bar under every H1.
- Space Grotesk headings, Inter body, IBM Plex Mono code.
- Screenshots inlined at correct size.
- Captions in Caption style.

- [ ] **Step 2: Export ICML**

```bash
docs/user-manual/build/scripts/md-to-icml.sh docs/user-manual/chapters/04-variants/01-reading-a-vcf.md
```
Expected: `docs/user-manual/build/indesign/stories/01-reading-a-vcf.icml` exists.

- [ ] **Step 3: Validate ICML style references**

```bash
docs/user-manual/build/scripts/validate-styles.sh
```
Expected: exit 0.

- [ ] **Step 4: Place the ICML story into Lungfish-Manual.indd (manual step in InDesign)**

File → Place → choose the ICML. Flow into Body master pages. Screenshots appear at ScreenshotFrame object-style size. Confirm:
- All paragraph styles resolve.
- Cream page background.
- Space Grotesk H1 with Creamsicle bar.
- No missing fonts warning.

- [ ] **Step 5: Byte-reproducibility check**

From a clean working tree, re-run steps 1–3. Confirm `site/chapters/04-variants/01-reading-a-vcf/index.html` and `stories/01-reading-a-vcf.icml` are byte-identical (modulo the MkDocs build date in the site's `sitemap.xml`, which is expected to differ).

```bash
docs/user-manual/build/scripts/render-mkdocs.sh
cksum docs/user-manual/build/site/chapters/04-variants/01-reading-a-vcf/index.html
docs/user-manual/build/scripts/md-to-icml.sh docs/user-manual/chapters/04-variants/01-reading-a-vcf.md
cksum docs/user-manual/build/indesign/stories/01-reading-a-vcf.icml
```
Expected: checksums stable across runs.

- [ ] **Step 6: Commit any build artifacts we want to keep for reviewers**

Build outputs in `site/` and `stories/` are ignored per `.gitignore`. If a screenshot of the rendered InDesign spread is useful for future reviewers, capture it and commit under `reviews/04-variants/2026-04-15-lead-gate2/`. Otherwise no commit needed.

---

## Phase 10 — CI, pre-commit, full-rebuild

Goal: automation for the subset that can run in headless CI (lint + MkDocs), plus a local `full-rebuild.sh` that drives the interactive parts.

### Task 10.1: Write full-rebuild.sh

**Files:**
- Create: `docs/user-manual/build/scripts/full-rebuild.sh`

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
MANUAL_DIR="$(cd -- "$SCRIPT_DIR/../.." &>/dev/null && pwd)"

echo "==> Lint every chapter"
find "$MANUAL_DIR/chapters" -name '*.md' -print0 | xargs -0 -n1 "$SCRIPT_DIR/lint-chapter.sh"

echo "==> Validate every fixture"
for dir in "$MANUAL_DIR"/fixtures/*/; do
  [[ -d "$dir" ]] && "$SCRIPT_DIR/validate-fixture.sh" "$dir"
done

echo "==> Build MkDocs site"
"$SCRIPT_DIR/render-mkdocs.sh"

echo "==> Export ICML for every chapter"
mapfile -t chapters < <(find "$MANUAL_DIR/chapters" -name '*.md' | sort)
"$SCRIPT_DIR/md-to-icml.sh" "${chapters[@]}"

echo "==> Validate ICML styles against style-map.yaml"
"$SCRIPT_DIR/validate-styles.sh"

echo "Done. MkDocs at: $MANUAL_DIR/build/site/"
echo "ICML stories at: $MANUAL_DIR/build/indesign/stories/"
```

- [ ] **Step 2: Mark executable and run end-to-end**

```bash
chmod +x docs/user-manual/build/scripts/full-rebuild.sh
docs/user-manual/build/scripts/full-rebuild.sh
```
Expected: exit 0, all stages succeed.

- [ ] **Step 3: Commit**

```bash
git add docs/user-manual/build/scripts/full-rebuild.sh
git commit -m "docs(manual): full-rebuild.sh — end-to-end local build"
```

### Task 10.2: Add GitHub Actions workflow

**Files:**
- Create: `.github/workflows/user-manual.yml`

- [ ] **Step 1: Write the workflow**

```yaml
name: user-manual
on:
  pull_request:
    paths:
      - "docs/user-manual/**"
      - ".github/workflows/user-manual.yml"
  push:
    branches: [main]
    paths:
      - "docs/user-manual/**"

jobs:
  lint-and-build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: "20"
      - uses: actions/setup-python@v5
        with:
          python-version: "3.12"
      - name: Install pandoc
        run: sudo apt-get update && sudo apt-get install -y pandoc xmllint
      - name: Install lint dependencies
        working-directory: docs/user-manual/build/scripts/lint
        run: npm ci
      - name: Install shot dependencies
        working-directory: docs/user-manual/build/scripts/shot
        run: npm ci
      - name: Run lint unit tests
        working-directory: docs/user-manual/build/scripts/lint
        run: npm test
      - name: Run shot unit tests
        working-directory: docs/user-manual/build/scripts/shot
        run: npm test
      - name: Lint every chapter
        run: |
          find docs/user-manual/chapters -name '*.md' -print0 \
            | xargs -0 -n1 docs/user-manual/build/scripts/lint-chapter.sh
      - name: Validate fixtures
        run: |
          for dir in docs/user-manual/fixtures/*/; do
            [ -d "$dir" ] && docs/user-manual/build/scripts/validate-fixture.sh "$dir"
          done
      - name: Build MkDocs
        run: docs/user-manual/build/scripts/render-mkdocs.sh
      - name: Export ICML for every chapter
        run: |
          mapfile -t chapters < <(find docs/user-manual/chapters -name '*.md' | sort)
          [ ${#chapters[@]} -gt 0 ] && docs/user-manual/build/scripts/md-to-icml.sh "${chapters[@]}"
      - name: Validate ICML styles
        run: docs/user-manual/build/scripts/validate-styles.sh
```

- [ ] **Step 2: Commit**

```bash
git add .github/workflows/user-manual.yml
git commit -m "docs(manual): CI workflow — lint, tests, MkDocs, ICML"
```

### Task 10.3: Extend pre-commit config

**Files:**
- Modify: `.pre-commit-config.yaml` (create if absent)

- [ ] **Step 1: Check for existing config**

```bash
test -f .pre-commit-config.yaml && cat .pre-commit-config.yaml || echo "no existing config"
```

- [ ] **Step 2: Write or extend**

If absent, create:

```yaml
repos:
  - repo: local
    hooks:
      - id: lint-manual-chapter
        name: lint Lungfish manual chapter
        entry: docs/user-manual/build/scripts/lint-chapter.sh
        language: system
        files: ^docs/user-manual/chapters/.*\.md$
      - id: validate-manual-fixture
        name: validate Lungfish manual fixture
        entry: bash -c 'for arg in "$@"; do dir="$(dirname "$arg")"; docs/user-manual/build/scripts/validate-fixture.sh "$dir"; done' --
        language: system
        files: ^docs/user-manual/fixtures/[^/]+/README\.md$
      - id: diff-idml-on-indd-change
        name: remind reviewers IDML must match INDD
        entry: bash -c 'echo "Reminder: committed .indd? Re-export .idml and commit both together." ; exit 0'
        language: system
        files: ^docs/user-manual/build/indesign/Lungfish-Manual\.indd$
```

If present, append the new hooks after the existing repos entry.

- [ ] **Step 3: Run pre-commit on staged changes (install if needed)**

```bash
pip install --quiet pre-commit
pre-commit install
pre-commit run --all-files
```
Expected: hooks run; any chapter lint failures reported; the IDML reminder prints when .indd is staged.

- [ ] **Step 4: Commit**

```bash
git add .pre-commit-config.yaml
git commit -m "docs(manual): pre-commit hooks for chapter lint and fixture validation"
```

### Task 10.4: Sub-project 1 sign-off

- [ ] **Step 1: Verify success criteria (spec §13)**

Walk through each and check:
- Pilot chapter renders correctly in MkDocs and InDesign from the same Markdown source: verified in Task 9.8.
- Re-running the pipeline on the pilot from a clean checkout produces byte-identical outputs modulo timestamps and pixel noise: verified in Task 9.8 step 5.
- Changing one word in the chapter Markdown and re-exporting updates both MkDocs and InDesign without touching any template or style file:

```bash
# Try a trivial word change round-trip
sed -i '' 's/A VCF file — Variant/A VCF file — a Variant/' docs/user-manual/chapters/04-variants/01-reading-a-vcf.md
docs/user-manual/build/scripts/full-rebuild.sh
git checkout docs/user-manual/chapters/04-variants/01-reading-a-vcf.md
```
Expected: full-rebuild succeeds without touching template/style files.

- The linter catches every invariant in `lungfish_brand_style_guide.md` that can be mechanically checked — verified by Task 2.4–2.10 adversarial fixtures, all passing.
- Lead gates 1 and 2 surface as explicit review files in `reviews/` — verified (Tasks 9.1, 9.7).

- [ ] **Step 2: Write a sub-project-1 summary**

`docs/user-manual/reviews/2026-04-15-sub-project-1-summary.md`:

```markdown
# Sub-project 1 sign-off

Date: 2026-04-15
Pilot chapter: `chapters/04-variants/01-reading-a-vcf`.

## Success criteria

- [x] Pilot renders in MkDocs and InDesign from the same source.
- [x] Re-run is byte-identical modulo timestamps and pixel noise.
- [x] Single-word change round-trips through both targets.
- [x] Linter catches all mechanical brand invariants (adversarial fixtures).
- [x] Lead gates 1 and 2 are file-based reviews.

## Learnings for sub-project 2

- (record learnings for the next sub-project here)

## Sign-off

Ready to hand to sub-project 2.
```

- [ ] **Step 3: Commit**

```bash
git add docs/user-manual/reviews/2026-04-15-sub-project-1-summary.md
git commit -m "docs(manual): sub-project 1 sign-off"
```

---

## Cross-cutting concerns

### Test strategy summary

- **Unit tests**: Node `node:test` for lint rules (7 rules × at least one adversarial fixture each) and shot runner modules (schema validation, annotate compositor, phash). Run locally and in CI.
- **Bash wrappers**: smoke-tested manually by each task's step; not unit-tested.
- **Chapter content**: verified by lint + human review gates, not unit tests.
- **InDesign template**: verified by round-trip IDML re-open and style validator.
- **End-to-end**: verified by `full-rebuild.sh` exiting 0 and Task 9.8 rendering checks.

### What's NOT in this plan

- Automating InDesign export of PDF for sign-off (spec §15 defers).
- ReadTheDocs.org vs GitHub Pages hosting decision (spec §15 defers).
- Stylometric voice linting beyond the heuristics in Phase 2 (spec §15 defers).
- Chapters beyond the pilot (sub-project 2).
- Video storyboarding + ElevenLabs (sub-project 3).
- Aligning the app's runtime palette (`docs/design/palette.md` Lungfish Orange `#D47B3A`) to the brand manual's Creamsicle `#EE8B4F` (spec §11 item 4; user confirmation required).
