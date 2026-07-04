---
title: Haplotype Definitions, AI-Assisted Haplotyping, and Export
chapter_id: 09-genotyping/04-haplotype-definitions-and-export
audience: analyst
prereqs: [09-genotyping/03-reading-the-genotype-comparison]
estimated_reading_min: 11
task: Define and edit named haplotypes, run AI-assisted haplotype discovery and refinement, and export genotype results to XLSX, CSV, TSV, and LabKey.
tags: [genotyping, mhc, haplotype, definitions, ai-haplotyping, export, labkey]
tools: []
entry_points:
  - "Tools > Haplotype Definitions..."
  - "Genotype viewport > Haplotype Definitions"
  - "Genotype viewport > AI Discovery / AI Refinement"
  - "Genotype viewport > Export"
  - "CLI: lungfish haplotypes"
  - "CLI: lungfish genotype ai-haplotyping"
  - "CLI: lungfish genotype export-xlsx"
  - "CLI: lungfish genotype export-labkey"
shots: []
planned_shots:
  - id: haplotype-definition-editor
    caption: "The Haplotype Definitions editor with aligned marker columns and the defining targets for one named M-family haplotype."
  - id: haplotype-ai-discovery
    caption: "The AI Discovery panel proposing a haplotype definition from genotype evidence, with the analyst review controls before publishing a revision."
  - id: genotype-export-dialog
    caption: "The genotype Export dialog with the XLSX, CSV, TSV, and samples-across pivot options."
  - id: genotype-labkey-export
    caption: "The LabKey export producing LabKey-ready CSV files from the reviewed genotype bundle."
illustrations: []
glossary_refs: [haplotype, mhc, genotype, ai-assistant, labkey]
features_refs: [genotype.haplotype-definitions, genotype.ai-haplotyping, genotype.export]
fixtures_refs: []
brand_reviewed: true
lead_approved: false
---

!!! note "Newer workflow area"
    MHC genotyping is a newer part of Lungfish, and no MCM MHC example dataset
    ships with this manual yet. Definition IDs, target lists, and export paths
    below are illustrative examples that show how the editors and exporters
    behave, not a fixture you can reproduce file for file.

## What it is

A haplotype definition is the rulebook that turns observed allele targets into
named M-family calls. It lists, for each family and each locus, the defining
targets that support it. The genotyping run applies a definition set to your
reads; this chapter is about editing that rulebook and getting the reviewed
result out of Lungfish. Definition sets live in `.lungfishmhcref` bundles and in
your project, and they are deterministic: the same reads and the same definition
set produce the same calls.

Three tasks sit in this chapter. Editing definitions changes how families are
named. AI-assisted haplotyping proposes definition changes for a human to accept
or reject. Export moves the reviewed result into a spreadsheet or a LabKey
server. The first and third are deterministic. The middle one is advisory, and
this chapter is careful to keep that line visible.

So what should you do with this: edit definitions when the calling rules need to
change, treat the AI panels as a drafting aid you review, and export through the
format that matches where the results are going next.

## What you will learn

By the end of this chapter you will be able to open and edit a named haplotype
definition from its marker columns, run AI Discovery or AI Refinement and
understand what they do and do not change, and export a reviewed bundle to XLSX,
CSV, TSV, the samples-across pivot workbook, or LabKey-ready CSV.

## Named haplotypes and defining targets

A definition set is organised by locus and by family. Each of the six loci
(MHC-A, MHC-E, MHC-B, MHC-DR, MHC-DQ, and MHC-DP) lists the M-families it can
call, and each family at that locus names its defining targets. A defining target
is a MiSeq target ID whose presence, at credible read support, is evidence for
that family. Some families are called from a single distinctive target; others
need a combination, and some targets are shared across families and only resolve
in context.

The editor also carries the metadata that lets Lungfish pick the right set
automatically: a definition ID, an assay label, a species code such as MCM, a
version, and a per-family display color. Those fields are how a run matches your
reads to the correct rulebook rather than guessing.

## Procedure

### Step 1. Define and edit named haplotypes

Edit a definition when the calling rules need to change: a new allele joins the
panel, or a family's defining targets need adjusting. Open the editor from
**Tools > Haplotype Definitions...**, or from the Haplotype Definitions control
in the genotype viewport. The editor opens as a sheet showing the definition's
loci down one axis and its families across the marker columns, so you can see
which targets define which family at a glance.

<!-- planned: haplotype-definition-editor -->

Add or remove defining targets for a family, set the family display color, and
edit the definition ID, assay, and species fields. Built-in definition sets are
read-only, so to change one you duplicate it into your project scope first and
edit the copy. To turn an edited definition into a reference bundle you can
genotype against, supply a reference FASTA when you save, which pairs the rules
with the allele sequences they name. The same operations are available headless
under `lungfish haplotypes` (for example `list`, `validate`, `save`, and
`bundle-create`).

### Step 2. Run AI-assisted haplotype discovery and refinement

The two AI panels help you draft definitions and revisit hard calls, and they are
advisory. Open them from AI Discovery or AI Refinement in the genotype viewport.
AI Discovery proposes a candidate haplotype definition from the genotype
evidence. AI Refinement re-examines existing calls, and you can scope it to every
sample or to the unresolved calls only.

<!-- planned: haplotype-ai-discovery -->

Both panels use a bring-your-own-key provider: you supply credentials for an
AI provider such as OpenAI or Anthropic, and the request runs against that
provider. A run does not overwrite your deterministic definitions. It appends a
validated workbook revision, a versioned analysis carrying its own provenance and
review metadata, which you review before you rely on it. This is the important
boundary: the AI output is a proposal to accept or reject, not a replacement for
the `.lungfishmhcref` definition sets that drive deterministic calling. From the
command line the same workflow is `lungfish genotype ai-haplotyping`, with
`--preview-prompt` to render the request without contacting a provider at all.

### Step 3. Export to XLSX, CSV, and TSV

Export when the reviewed result needs to leave Lungfish for a spreadsheet or a
report. Open the Export control in the genotype viewport and choose a format. The
XLSX export is a self-describing workbook: a Matrix sheet of the sample-by-locus
calls colored with the family palette, a Legend sheet that decodes the colors, an
Overrides sheet of analyst-applied call changes, and an Audit Log sheet of the
recorded actions. CSV and TSV write the same matrix as plain text for a scripting
step.

<!-- planned: genotype-export-dialog -->

A fourth shape, the samples-across pivot workbook, transposes the layout so
samples run across the columns and alleles run down the rows, which is the
orientation many downstream spreadsheets expect. All of these exports are
read-only with respect to the bundle: they never modify the calls or the
annotations. The headless equivalents are `lungfish genotype export-xlsx`,
`lungfish genotype export-pivot-xlsx`, and `lungfish genotype export` with
`--export-format csv` or `tsv`.

### Step 4. Export LabKey-ready CSV files

When results feed a LabKey server, export the LabKey-ready CSV set rather than a
single workbook. It writes several long-format CSV files, one row per fact, with
stable headers and standard escaping so an ingestion step can load them directly.
The set covers the final post-override haplotype calls, the per-sample per-allele
read counts, the analyst overrides, the audit trail, and the saved cohorts.

<!-- planned: genotype-labkey-export -->

The haplotype calls in these files reflect your overrides merged over the
pipeline result, so LabKey receives the active, reviewed call rather than the raw
pipeline output. The command-line form is `lungfish genotype export-labkey` with
a bundle path and an output directory.

## Interpretation

The dividing line to keep in mind is deterministic versus advisory. Your edited
definitions and every export are deterministic: rerun them and you get the same
result, which is what makes them safe to script and to hand to a database. The AI
panels are a drafting aid whose output you read, validate, and accept before it
counts. If an exported call looks wrong, the fix is upstream: adjust the
definition or the override, then re-export. The export never invents a call it
was not given.

## Next

Return to
[Reading the Genotype Comparison Viewport](03-reading-the-genotype-comparison.md)
to review calls before a final export, or to
[What Is Amplicon MHC Genotyping](01-what-is-mhc-genotyping.md) for the concepts
behind the definitions you just edited.
