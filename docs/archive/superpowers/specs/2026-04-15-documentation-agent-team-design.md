# Documentation Agent Team — Design Spec

**Date:** 2026-04-15
**Status:** Draft for review
**Scope:** Sub-project 1 of 3 in the Lungfish Documentation Program
**Follow-ons:** Sub-project 2 (written manual pipeline — remaining chapters), Sub-project 3 (narrated video pipeline)

---

## 1. Program context

The Lungfish Documentation Program produces a user manual and supporting materials that help scientists work with deep-sequencing data and analyses using the Lungfish Genome Explorer, without assuming bioinformatics jargon fluency. The program has three sub-projects, run in order:

1. **Agent team & chapter architecture** *(this spec)* — the team that writes the manual, the repository layout they work in, the build pipeline for MkDocs + InDesign, and one pilot chapter that proves the whole pipeline end-to-end.
2. **Written manual pipeline** — the remaining chapters, using the pipeline from sub-project 1.
3. **Narrated video pipeline** — short screen-capture videos with ElevenLabs text-to-speech narration, reusing the same Computer Use screenshot recipes where applicable.

Each sub-project gets its own spec and implementation plan. Sub-projects 2 and 3 are out of scope for this document.

## 2. Goals & non-goals

### Goals

- Design a small, focused team of Claude Code subagents with non-overlapping responsibilities that together produce chapter-quality documentation.
- Establish a single-source-of-truth document tree (`docs/user-manual/`) that builds to both a ReadTheDocs-style MkDocs site and an Adobe InDesign manual.
- Define a screenshot pipeline where every screenshot is specified by a replayable recipe driven by Computer Use against reproducible, provenance-tracked fixtures.
- Enforce Lungfish brand identity mechanically (a linter) and editorially (the Brand Copy Editor agent).
- Ship one pilot chapter, end-to-end, as the hard gate for sub-project completion.

### Non-goals

- Writing the full manual (sub-project 2).
- Video production, storyboarding, or ElevenLabs integration (sub-project 3).
- Aligning the Lungfish app's runtime color palette to the brand manual (noted as a discoverable tension in §11, item 4).
- Hosting decisions for the MkDocs site (ReadTheDocs.org vs. GitHub Pages — deferred to sub-project 2 once the output stabilises).
- Printed PDF sign-off (InDesign exports PDF trivially; this is a later packaging concern).

## 3. Audience

The user manual's primary audience is **bench scientists** who want to work with deep-sequencing data and downstream analyses but are not comfortable with bioinformatics jargon. Secondary audiences are **analysts** (comfortable with file formats and command line) and **power-users** (plugin authors, CLI users). Every chapter declares its target tier in frontmatter; no chapter references a tier the reader has not been primed for.

## 4. Agent roster

Six agents. Five are delivered as Claude Code subagent definitions in `.claude/agents/`; the sixth (Video Producer) is a stub for sub-project 3.

### 4.1 Documentation Lead (architect & gatekeeper)

- **Inputs:** `Sources/` overview, `docs/design/*`, `features.yaml`, brand guide, pilot-chapter feedback.
- **Outputs:** `docs/user-manual/ARCHITECTURE.md` (TOC, audience mapping, prerequisite graph, rationale); chapter stubs (frontmatter + `<!-- SHOT: id -->` markers); chapter-level gate approvals written to `reviews/<chapter>/<date>-lead.md`.
- **Authority:** the only agent that writes to `ARCHITECTURE.md`. Owns gate 1 (chapter stub approval, surfaces to user) and gate 2 (final chapter approval, surfaces to user).

### 4.2 Code Cartographer

- **Inputs:** `Sources/*`, `docs/design/*`, `MEMORY.md`, app sidebar / Import Center structure, `docs/design/viewport-interface-classes.md`.
- **Outputs:** `docs/user-manual/features.yaml` — a structured inventory of every user-reachable feature, with entry points, inputs, outputs, related source files, and viewport-interface class. Refreshed when code changes; diffed to decide which chapters need refresh.
- **Authority:** the only agent that writes to `features.yaml`. Writes for other agents, not for readers.

### 4.3 Bioinformatics Educator

- **Inputs:** chapter plan from the Lead, `features.yaml`, the file formats and analyses relevant to the chapter.
- **Outputs:** chapter body Markdown (primers, procedures); glossary entries in `GLOSSARY.md`; fixture `README.md` files (co-owned with Cartographer — see §7).
- **Authority:** primary author of chapter `.md` files. Brand Copy Editor may edit the same file for brand fidelity and must record changes in `reviews/` (see §4.5 and §6.2). Responsible for fixing lint failures and re-entering the pipeline (see §5).

### 4.4 Screenshot Scout

- **Inputs:** chapter drafts containing `<!-- SHOT: id -->` markers; the Lungfish app running on the user's machine; fixture data.
- **Outputs:** `assets/screenshots/<chapter>/<id>.png` + `assets/recipes/<chapter>/<id>.yaml`; optional `<id>.diff-report.md` when perceptual-hash diffs against a previous capture exceed a threshold.
- **Authority:** the only agent that writes under `assets/screenshots/` and `assets/recipes/`. Drives the app via the `computer-use` MCP.

### 4.5 Brand Copy Editor

- **Inputs:** assembled chapter draft with screenshots; `lungfish_brand_style_guide.md` (via memory) and `STYLE.md`.
- **Outputs:** edits applied to the chapter `.md` (brand fidelity only — voice, palette references, typography, captions); `reviews/<chapter>/<date>-brand.md` summarising every change and its rationale. Flips `brand_reviewed: true` in frontmatter.
- **Authority:** may edit chapter `.md` files for brand fidelity (see §6.2). Flips `brand_reviewed`. Does not touch `lead_approved`. Does not rewrite structure, procedures, or primers — those belong to the Educator; a disagreement routes back through the Lead.

### 4.6 Video Producer *(stub — sub-project 3)*

Placeholder persona file. Not invoked in sub-project 1.

### 4.7 Ground rules (all agents)

- Inputs are files; outputs are files. No implicit state passed between agent invocations.
- Each agent has a persona file under `.claude/agents/` defining voice constraints, file conventions, tool-access lists, and "never do" lists.
- Ownership boundaries above are strict. An agent that reaches into another's output tree is a bug.

## 5. Artifact flow (pipeline)

The team runs as a linear pipeline (Approach A, Documentation Lead as gatekeeper). Two gates per chapter surface to the user; all other handoffs are agent-to-agent through files.

```
            ┌───────────────────────────────────┐
Cartographer│ 1. features.yaml (refreshed when  │
            │    code changes)                  │
            └──────────────────┬────────────────┘
                               ▼
            ┌───────────────────────────────────┐
Lead        │ 2. ARCHITECTURE.md + chapter stub │ ◄── USER GATE 1
            │    (frontmatter + SHOT markers)   │
            └──────────────────┬────────────────┘
                               ▼
            ┌───────────────────────────────────┐
Educator    │ 3. chapter body (primers,         │
            │    procedures, glossary updates)  │
            └──────────────────┬────────────────┘
                               ▼
            ┌───────────────────────────────────┐
Scout       │ 4. screenshots + recipes          │
            │    (one per SHOT marker)          │
            └──────────────────┬────────────────┘
                               ▼
            ┌───────────────────────────────────┐
Lint        │ 5. lint-chapter.sh must pass      │ ◄── blocks Editor
            │    (brand + frontmatter checks)   │
            └──────────────────┬────────────────┘
                               ▼
            ┌───────────────────────────────────┐
Brand Editor│ 6. voice/palette/typography pass  │
            │    flips brand_reviewed: true     │
            └──────────────────┬────────────────┘
                               ▼
            ┌───────────────────────────────────┐
Lead        │ 7. gate review → lead_approved    │ ◄── USER GATE 2
            └───────────────────────────────────┘
```

**Lint blocks the Brand Copy Editor.** The Editor only runs on a lint-green chapter. If the linter (step 5) fails, the chapter returns to the Educator (step 3) for fixes and re-enters the pipeline. Screenshots from step 4 are preserved across loops unless their `<!-- SHOT: id -->` markers changed. Keeps agent roles non-overlapping and makes the Educator responsible for their own output quality.

## 6. Repository layout

All documentation lives under `docs/user-manual/` in the existing repo. One folder, one source of truth, feeds both MkDocs and InDesign.

```
docs/user-manual/
├── ARCHITECTURE.md              # Lead-owned: TOC, audience map, prereq graph, rationale
├── STYLE.md                     # derived from brand guide — voice/palette rules agents enforce
├── GLOSSARY.md                  # Educator-owned; referenced by chapters
├── features.yaml                # Cartographer-owned; feature inventory
├── chapters/
│   ├── 01-foundations/
│   ├── 02-sequences/
│   ├── 03-alignments/
│   ├── 04-variants/
│   │   └── 01-reading-a-vcf.md  # PILOT CHAPTER
│   ├── 05-classification/
│   ├── 06-assembly/
│   └── appendices/
├── fixtures/                    # docs-only, real-world, small
│   └── sarscov2-clinical/
│       ├── README.md            # source, license, citation, size
│       ├── reference.fasta
│       ├── reads_R1.fastq.gz
│       ├── reads_R2.fastq.gz
│       ├── alignments.bam
│       ├── variants.vcf.gz
│       └── fetch.sh             # optional, for on-demand large files
├── assets/
│   ├── screenshots/<chapter>/<id>.png
│   ├── recipes/<chapter>/<id>.yaml
│   ├── diagrams/<chapter>/<id>.svg
│   └── icons/                   # 2px-stroke brand icon set
├── build/
│   ├── mkdocs.yml
│   ├── theme/                   # Material theme overrides, brand tokens
│   ├── indesign/
│   │   ├── Lungfish-Manual.indd # master template (binary, committed)
│   │   ├── Lungfish-Manual.idml # diffable exchange format (committed)
│   │   └── styles/              # ICML paragraph/character style references
│   └── scripts/
│       ├── md-to-icml.sh        # pandoc → ICML pipeline
│       ├── render-mkdocs.sh
│       ├── run-shot.sh <recipe> # replays a Computer Use recipe
│       ├── lint-chapter.sh
│       ├── diff-idml.sh         # IDML XML diff for review
│       └── full-rebuild.sh      # local end-to-end build
└── reviews/
    └── <chapter>/<date>-<agent>.md
```

### 6.1 Chapter file anatomy

Every chapter `.md` file has YAML frontmatter. The frontmatter is validated by the linter.

```yaml
---
title: Reading a VCF file
chapter_id: 04-variants/01-reading-a-vcf
audience: bench-scientist              # bench-scientist | analyst | power-user
prereqs: [02-sequences/01-opening-a-fasta]
estimated_reading_min: 8
shots:
  - id: vcf-open-dialog
    caption: "The Open dialog filtered to VCF files."
  - id: vcf-variant-table
    caption: "A loaded VCF showing variants aligned to reference."
glossary_refs: [VCF, REF, ALT, genotype]
features_refs: [import.vcf, viewport.variant-browser]
fixtures_refs: [sarscov2-clinical]
brand_reviewed: false
lead_approved: false
---
```

### 6.2 Ownership rules

- `ARCHITECTURE.md` — Documentation Lead only.
- `features.yaml` — Code Cartographer only.
- `chapters/**/*.md` — Bioinformatics Educator is primary author. Brand Copy Editor may edit for brand fidelity, must flip `brand_reviewed` and record changes in `reviews/<chapter>/<date>-brand.md`. No other agent writes to chapter files.
- `assets/screenshots/`, `assets/recipes/` — Screenshot Scout only.
- `GLOSSARY.md` — Bioinformatics Educator only.
- `fixtures/*/README.md` — Cartographer + Educator (co-owned; see §7).
- `reviews/` — written by the reviewing agent.

## 7. Fixture curation policy

### 7.1 Required metadata

Every fixture set must have a `README.md` containing:

- Source (accession, DOI, URL).
- License (must permit redistribution in this repo).
- Citation block (BibTeX or equivalent) that chapters include when the fixture appears.
- Total size, per-file size.
- Notes on how the files are internally consistent (reads align to reference, variants called from reads, etc.).

No fixture lands without complete metadata. This is mechanically enforced by the linter.

### 7.2 Size discipline

- ≤10 MB per file.
- ≤50 MB per fixture set.
- Files larger than these caps are not committed. If a chapter needs them, the fixture ships a `fetch.sh` that pulls from a pinned NCBI/ENA URL and caches locally.

### 7.3 Pathogen tiers

When choosing a fixture for a new chapter, the Cartographer + Educator prefer pathogens in this order:

1. **SARS-CoV-2** — default workhorse. Small monopartite RNA genome (~30 kb), extensive public data, trivial reads-align-to-reference coherence. Use for: foundational chapters, alignment, variant calling, classification baselines.
2. **Influenza A** — eight-segment RNA genome. Pedagogically unique path into multi-sequence / chromosome-like handling at small scale. Use for: chapters illustrating multi-sequence FASTA, per-segment coverage, per-segment variants — a stepping stone to vertebrate chromosomes without a multi-GB genome.
3. **HIV-1** — small genome with overlapping reading frames and spliced transcripts (Tat and Rev each use two exons separated by a large intron). Pedagogically unique path into exon/intron handling, splicing, and CDS-vs-mRNA distinction at viral scale.

Deviation from this tier list requires a sentence of justification in the fixture's `README.md`.

### 7.4 Pilot fixture

Sub-project 1 delivers exactly one fixture set: `fixtures/sarscov2-clinical/`, curated for the pilot chapter and usable by future alignment, classification, and variant chapters. A **clinical isolate** is used deliberately rather than a wastewater sample so the pilot chapter teaches the canonical single-organism VCF (clean SNPs relative to reference, unambiguous sample identity). Wastewater VCFs carry low-frequency variants, mixed lineages, dropout regions, and allele-frequency reasoning that the reader should not encounter on first exposure to the format; those complications get their own chapter in sub-project 2 (likely co-located with Classification or as a standalone "Working with environmental / mixed-population samples" chapter).

## 8. Screenshot pipeline

### 8.1 Recipes are the source of truth

Every screenshot is specified by a YAML recipe under `assets/recipes/<chapter>/<id>.yaml`. The Scout's job is to translate a recipe into a PNG and refine the recipe (including any fallbacks used). If the UI changes, we re-run the recipe. If the recipe cannot resolve, it fails with a diff report.

### 8.2 Recipe schema

```yaml
id: vcf-variant-table
chapter: 04-variants/01-reading-a-vcf
caption: "A loaded VCF showing variants aligned to reference."
viewport_class: variant-browser                # from viewport-interface-classes.md
app_state:
  fixture: docs/user-manual/fixtures/sarscov2-clinical
  open_files:
    - reference: "{fixture}/reference.fasta"
    - variants:  "{fixture}/variants.vcf.gz"
  window_size: [1600, 1000]
  appearance: light                            # light | dark; brand default light
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
  mode: viewport                               # viewport | window | region
  region: [0, 60, 1600, 900]
annotations:
  - type: callout
    target: ref-column
    text: "REF — the reference base"
  - type: bracket
    region: [430, 200, 550, 260]
post:
  retina: true
  format: png
```

### 8.3 Scout execution loop

1. Launch the app in a clean state. `build/scripts/run-shot.sh` starts a debug build with a throwaway `~/Library/Application Support/Lungfish` directory populated from recipe fixtures. Same profile every run.
2. Request access via `mcp__computer-use__request_access` with `["Lungfish"]` only. Never browsers or terminals.
3. Execute steps — each recipe step maps to one Computer Use tool call. Prefer `open -a Lungfish <path>` via Bash over clicking through NSOpenPanel.
4. Capture at 2× retina, crop per recipe.
5. Compose annotations as SVG overlays post-capture (not in-app). Raw screenshot stays refreshable.
6. Perceptual-hash diff against previous PNG; large diff without a recipe change writes `<id>.diff-report.md` for Lead review.
7. Write outputs.

### 8.4 Deterministic state

Every recipe points at a fixture in `docs/user-manual/fixtures/`. Two runs on two days produce byte-comparable PNGs modulo pixel noise. No recipe may depend on user-specific state.

### 8.5 Brand treatment

Screenshots sit on Cream backgrounds. Light appearance is default (brand uses Cream, not pure white). Dark-mode screenshots sit on a Deep Ink containment panel. Annotation callouts and brackets use Creamsicle at 2px stroke per the brand manual's iconography rules.

## 9. Chapter architecture (scaffolding for the Lead)

The Lead produces the final TOC as a deliverable (gate 1 for each chapter). The scaffolding below is the starting brief, not the final order.

### 9.1 Three-part structure

- **Part I — Foundations.** Format primers, concept primers. Not app features.
- **Part II — Working with the App.** App features, ordered simple → complex.
- **Part III — Reference.** Glossary, keyboard map, troubleshooting, appendices.

### 9.2 Prerequisite graph, not strict linear order

Chapter frontmatter declares `prereqs: [...]`. The Lead validates that no chapter refers to concepts the reader has not met. MkDocs nav is a topological sort of this graph. InDesign cross-references use the same graph.

### 9.3 Provisional Part I scaffolding

1. What is a genome browser, and why this one?
2. Sequencing data at a glance (reads, references, coordinates).
3. File formats you will meet (FASTA, FASTQ, BAM/CRAM, VCF, GFF/BED) — one short primer each.
4. Databases and accessions (NCBI, ENA, SRA, GenBank).
5. How analyses fit together (reads → alignment → variants → classification).

### 9.4 Provisional Part II scaffolding

Ordered by the five viewport interface classes in `docs/design/viewport-interface-classes.md`.

6. Sequences (FASTA/FASTQ) — opening, inspecting, the sequence viewer.
7. Alignments (BAM/CRAM) — importing, reading the pileup, coverage.
8. Variants (VCF) — the variant browser, interpreting REF/ALT/GT.
9. Classification (Kraken2, EsViritu, TaxTriage, NAO-MGS) — the taxonomy browser, BLAST verification. Tool-specific variations are callouts, not separate chapters.
10. Assembly (SPAdes, MEGAHIT) — running an assembly, reading the contig viewer.
11. Downloads & imports — NCBI download, Import Center.
12. Operations panel & pipelines — running jobs, watching progress, derivatives.

### 9.5 Provisional Part III scaffolding

13. Keyboard & mouse reference.
14. Troubleshooting — symptoms → causes → fixes.
15. Glossary.
16. Appendices — installation, CLI companion, plugin authoring (power-user tier).

### 9.6 Deliberate absences

- No "Installation" chapter in Part I. It lives in Appendix A and is linked forward.
- No per-tool chapter for each classifier. Kraken2 / EsViritu / TaxTriage / NAO-MGS share one chapter organized around the taxonomy-browser viewport.

## 10. Build pipeline

### 10.1 One source, two targets

```
                        docs/user-manual/chapters/**/*.md
                             + fixtures + screenshots
                                      │
                ┌─────────────────────┴─────────────────────┐
                ▼                                           ▼
   build/scripts/render-mkdocs.sh              build/scripts/md-to-icml.sh
                │                                           │
                ▼                                           ▼
       site/ (HTML + theme)                       build/indesign/stories/*.icml
                │                                           │
                ▼                                           ▼
   RTD / GitHub Pages                    Linked stories in Lungfish-Manual.indd
```

### 10.2 Lint before anything else

`lint-chapter.sh <chapter.md>` enforces brand-guide invariants and must pass before the Brand Copy Editor runs. Rules:

- **Written-identity lint** — flags `LUNGFISH`, `LungFish`, `Lung Fish`, `lungfish` outside code fences and attributed quotes.
- **Palette lint** — any hex color in prose or embedded SVG must be in the five-color palette: Creamsicle `#EE8B4F`, Peach `#F6B088`, Deep Ink `#1F1A17`, Cream `#FAF4EA`, Warm Grey `#8A847A`.
- **Typography lint** — any inline `<style>` or HTML style attribute must use Space Grotesk / Inter / IBM Plex Mono. Prose never specifies a font.
- **Voice heuristics** — flags marketing-speak patterns (`revolutionary`, `breakthrough`, `powerful`, `cutting-edge`, `AI-powered`, `!` at sentence end). Flags jargon density above a per-paragraph threshold.
- **Primer-before-procedure rule** — every chapter's first `## Procedure` section must be preceded by `## What it is` or `## Why this matters`.
- **Frontmatter validation** — every `<!-- SHOT: id -->` marker has a matching `shots[].id`; every `prereqs[]` resolves; every `glossary_refs[]` resolves.
- **Data-viz lint** — embedded charts use only palette colors, never red-amber-green.

### 10.3 MkDocs theme

Material for MkDocs theme restyled with brand tokens (not rebuilt):

- `--md-primary-fg-color` → Creamsicle `#EE8B4F`
- `--md-accent-fg-color` → Creamsicle
- `--md-default-bg-color` → Cream `#FAF4EA`
- `--md-typeset-color` → Deep Ink `#1F1A17`
- `--md-code-bg-color` → a warm Cream tint
- Headings: Space Grotesk (Google Fonts)
- Body: Inter
- Code: IBM Plex Mono
- CSS `::after` rule adds the 4–6px Creamsicle bar below every `h1`.

Admonitions restyled: backgrounds in Peach, text in Deep Ink. Charts use Vega-Lite with a brand-locked theme spec. No red-amber-green.

### 10.4 InDesign round-trip

Pandoc runs each chapter through a Lua filter to emit ICML with style names matching the template (`H1`, `H2`, `H3`, `Body`, `Caption`, `Code`, `Callout`, `Glossary Term`). The template (`Lungfish-Manual.indd`) is built once, by hand, with:

- Master pages: Cover (Deep Ink field), Contents (Cream with Creamsicle title), Body (Cream, disc-bulleted headings, Creamsicle bar under H1), Back Cover.
- Paragraph styles mapped to the brand type scale.
- Character styles for inline code (IBM Plex Mono), glossary terms, UI labels.
- Object styles for callout boxes, screenshot frames, caption blocks, the Creamsicle bar.

Re-running the export swaps text without touching style definitions or master pages. Missing styles fail the import loudly.

### 10.5 IDML as the diffable sibling

The `.indd` is binary and committed as-is; `.idml` is the diffable exchange format. A pre-commit hook runs `diff-idml.sh` (unzip IDML → diff the XML) so reviewers without InDesign can see template changes.

### 10.6 CI and local builds

- CI runs the linter + MkDocs build on every PR touching `docs/user-manual/`.
- InDesign export and Computer Use screenshot runs are macOS-and-interactive-only; they run locally via `build/scripts/full-rebuild.sh`.

## 11. Risks & open questions

1. **InDesign automation is touchy.** Pandoc → ICML is well-trodden but the first round-trip often needs a designer pass. Mitigation: the template is built by hand; we budget a spike in the plan for the first real chapter going through the export.
2. **Computer Use permissions on macOS.** Screenshotting requires accessibility + screen-recording permissions; for an unsigned debug build, the user re-grants perms after every rebuild. Mitigation: `run-shot.sh` pins a stable DerivedData path; may push us toward a signed debug build for doc generation.
3. **Fixture curation is load-bearing.** Finding a ≤10 MB paired-end FASTQ that is real, well-known, redistributable, and scientifically coherent is a small project. Mitigation: Cartographer + Educator spike on the *pilot* fixture early in sub-project 1 (this delivers one fixture — see §14). If that spike reveals curation is harder than expected, sub-project 2's plan allocates a dedicated milestone for the remaining pathogen-tier fixtures.
4. **Brand palette conflict.** Brand manual specifies Creamsicle `#EE8B4F`; app currently uses `#D47B3A` "Lungfish Orange" in `docs/design/palette.md`. Docs use Creamsicle. Aligning the app's runtime palette is out of scope for this sub-project but noted as a discoverable tension — confirm with user before changing the app's runtime palette.
5. **Voice drift across chapters.** Brand Copy Editor is the main defence. Mitigation: pilot chapter becomes a canonical voice reference in `STYLE.md`; later chapters are linted against it stylometrically as a stretch goal.
6. **The Lead agent has the hardest job.** Persona file is load-bearing and will need 2–3 iterations before we trust it. Mitigation: chapter plan reviewed at gate 1 before any writing.
7. **No CI for the full pipeline on day one.** InDesign export and Computer Use screenshots cannot run in headless CI. Mitigation: `full-rebuild.sh` locally, CI for the subset that can be automated.

## 12. Deliverables (sub-project 1)

1. **Agent persona files** under `.claude/agents/`:
   - `documentation-lead.md`
   - `code-cartographer.md`
   - `bioinformatics-educator.md`
   - `screenshot-scout.md`
   - `brand-copy-editor.md`
   - `video-producer.md` *(stub)*
2. **Scaffolded `docs/user-manual/` tree** per §6, with `ARCHITECTURE.md` (Lead-produced), `STYLE.md` (derived from brand guide), empty `GLOSSARY.md`, initial `features.yaml` (Cartographer-produced), empty `chapters/`, `fixtures/`, `assets/`, `build/`, `reviews/`.
3. **Toolchain** under `build/scripts/`:
   - `lint-chapter.sh`
   - `md-to-icml.sh`
   - `render-mkdocs.sh`
   - `run-shot.sh`
   - `diff-idml.sh`
   - `full-rebuild.sh`
   - Pre-commit wiring + CI check.
4. **MkDocs theme** restyled with brand tokens; a "Hello, Lungfish" index page verifying the theme end-to-end.
5. **InDesign template** (`Lungfish-Manual.indd` + `Lungfish-Manual.idml`) with master pages, paragraph/character/object styles, and the Creamsicle bar object style. Built once by hand from the brand manual.
6. **Pilot fixture** `fixtures/sarscov2-clinical/` with complete provenance, license, citation, ≤50 MB, internally coherent. Clinical isolate chosen to keep pedagogy clean; wastewater complications are a later chapter's concern (§7.4).
7. **Pilot chapter** `chapters/04-variants/01-reading-a-vcf.md`, shipped end-to-end: primer, procedure, screenshots via recipes, glossary entries, lint-green, Brand Editor passed, Lead-approved, rendered to MkDocs, exported to InDesign.

## 13. Success criteria

- Pilot chapter renders correctly in MkDocs and InDesign from the same Markdown source.
- Re-running the pipeline on the pilot from a clean checkout produces byte-identical outputs modulo timestamps and pixel noise.
- Changing one word in the chapter Markdown and re-exporting updates both MkDocs and InDesign without touching any template or style file.
- The linter catches every invariant in `lungfish_brand_style_guide.md` that can be mechanically checked, verified with adversarial fixtures that violate each rule.
- Lead gates 1 and 2 surface as explicit review files in `reviews/`, not buried in agent transcripts.

## 14. Hard gates

- **Pilot chapter is the hard gate.** If `chapters/04-variants/01-reading-a-vcf.md` does not land cleanly through every stage, sub-project 1 is not done.
- **Fixture curation is part of sub-project 1**, not deferred. The Cartographer + Educator produce one curated fixture set as a deliverable. What we learn from it decides whether sub-project 2 needs its own fixture-curation milestone.

## 15. What this spec defers

- Chapters beyond the pilot (sub-project 2).
- Video storyboarding, ElevenLabs integration, screen recording (sub-project 3).
- Aligning the app's runtime palette to the brand manual.
- Hosting choice for the MkDocs site.
- Printed PDF sign-off.
- Stylometric voice linting beyond the baseline heuristics in §10.2.

---

## Appendix A — References

- **Brand guide (memory):** `lungfish_brand_style_guide.md` — canonical voice, typography, palette, messaging, design-system rules.
- **Project memory:** `MEMORY.md` — project patterns, gotchas, viewport interface classes reference.
- **Viewport interface classes:** `docs/design/viewport-interface-classes.md` — the five viewport classes that structure Part II chapters.
- **App internal palette doc:** `docs/design/palette.md` — currently conflicts with the brand manual (see §11, item 4).
- **Brand manual source:** `/Users/dho/Downloads/Lungfish_Brand_Identity_Manual (1).docx`.
