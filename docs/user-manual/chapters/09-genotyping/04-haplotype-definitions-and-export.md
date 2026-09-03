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
    MHC genotyping is a newer part of Lungfish, and a bundled MCM MHC example
    dataset is not part of this manual yet. The definition IDs, target lists, and
    export paths below are illustrative, meant to show how the editors and
    exporters behave rather than to be reproduced file for file.

!!! note "Who this chapter is for"
    This chapter is written for the analyst who maintains the calling rules and
    ships results onward. If you are a student or a bench scientist, the part
    you are most likely to need is the LabKey export at the end, for when a
    reviewed result has to land in a shared database.

## What it is

A haplotype definition is the rulebook that turns observed allele targets into
named M-family calls. It lists, for each family and each locus, the defining
targets that support it. The genotyping run applies a definition set to your
reads. This chapter is about editing that rulebook and getting the reviewed
result out of Lungfish. Definition sets live in `.lungfishmhcref` bundles and in
your project, and they are deterministic: the same reads and the same definition
set produce the same calls, every time.

Three tasks sit in this chapter. Editing definitions changes how families are
named. AI-assisted haplotyping drafts definition changes for a human to accept
or reject. Export moves the reviewed result into a spreadsheet or a LabKey server
(LabKey is a database platform many labs use to store and share experimental
results). Editing and export are deterministic: run them again and the output
does not move. The AI step is the one exception, an advisory draft rather than a
settled result, and the chapter keeps flagging that difference as it goes.

Come back to this chapter when the calling rules
themselves need attention, or when a reviewed cohort is ready to leave Lungfish.
The one rule to carry all the way through it is to treat anything the AI panels
produce as a draft you sign off on, never as a call in its own right.

## What you will learn

By the time you finish, editing a named haplotype definition from its marker
columns should feel routine. You will know exactly what AI Discovery and AI
Refinement do and, just as important, what they leave untouched. You will also be
able to send a reviewed bundle out as XLSX, CSV, TSV, a samples-across pivot
workbook, or LabKey-ready CSV.

## Named haplotypes and defining targets

A definition set is organised by locus and by family. Each of the six loci
(MHC-A, MHC-E, MHC-B, MHC-DR, MHC-DQ, and MHC-DP) lists the M-families it can
call, and each family at that locus names its defining targets. A defining target
is an allele-target ID whose presence, at credible read support, is evidence for
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
loci down one axis and its families across the marker columns, one column per
family, so you can see which targets define which family at a glance.

<!-- planned: haplotype-definition-editor -->

Add or remove defining targets for a family, set the family display color, and
edit the definition ID, assay, and species fields. Each definition also carries a
required **Allele prefix**, and a save stays blocked until it is filled in. At
each locus two fields sit side by side: **Locus** is the display name the call
shows, while **Source** is the locus the reads were called against, and the two
can differ. Built-in definition sets are read-only, so to change one you
duplicate it into your project scope first and edit the copy. To turn an edited
definition into a reference bundle you can genotype against, supply a reference
FASTA when you save, which pairs the rules with the allele sequences they name.

Each named haplotype carries a **Requires N of M** stepper that sets its minimum
matches: how many of its defining targets must be observed at credible support
before the family is called, from one up to the full count of targets listed. A
read-only diagnostic allele matrix sits alongside the editor so you can see that
rule bite. Its rows are haplotype definitions, and its columns are Sample, Locus,
Call, Haplotype, an Obs/Req/Total triple, and Status, followed by one column per
diagnostic target carrying that target's unique-read count. Status reads Called,
Observed support, or Not observed. The matrix only reports: it changes no calls.

The same operations are available headless under `lungfish haplotypes`: `list`,
`validate`, and `save`, plus `export`, `import`, `duplicate`, and `delete` for
moving a definition between JSON files and the project scope, and
`bundle-create`, `bundle-save`, and `bundle-replace-reference` for writing
definitions and their reference FASTA into a `.lungfishmhcref` bundle.

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
workbook revision: a separate, dated draft analysis that leaves your original
definitions untouched, carrying its own provenance (a record of which inputs,
tools, and settings produced it) and review metadata for you to check before you
rely on it. This is the important boundary: the AI output is a proposal to accept
or reject, not a replacement for the `.lungfishmhcref` definition sets that drive
deterministic calling. From the command line the same workflow is `lungfish
genotype ai-haplotyping`, with `--preview-prompt` to render the request without
contacting a provider at all.

Several flags shape that run. Choose the provider with `--provider openai` (the
default) or `--provider anthropic`, set the mode with `--mode ai-discovery` or
`--mode ai-refinement`, and override the provider's default model with `--model`.
Credentials resolve in a fixed order: the `OPENAI_API_KEY` or `ANTHROPIC_API_KEY`
environment variable first, then the matching key held in the app keychain. To
route OpenAI traffic through Azure, pass `--azure-openai-endpoint` and
`--azure-openai-deployment` (or set `AZURE_OPENAI_ENDPOINT`,
`AZURE_OPENAI_DEPLOYMENT`, and `AZURE_OPENAI_API_KEY`); that path is OpenAI-only,
and the deployment name stands in for the model. For OpenAI reasoning models,
`--reasoning-effort` accepts none, minimal, low, medium, high, or xhigh.

You can preview a discovery prompt without a bundle at all:
`--preview-prompt --input-table <file>` builds the request from a long-form
genotype table, with `--input-format` selecting auto, csv, tsv, or json. That
table path is discovery-only. A published run prints a JSON summary naming the
new draft and its state, with fields `revisionID`, `reviewState`, `callCount`,
`discoveredDefinitionCount`, and `provenancePath` so a script can find the
revision and its provenance record.

### Step 3. Export to XLSX, CSV, and TSV

Export when the reviewed result needs to leave Lungfish for a spreadsheet or a
report. The genotype viewport offers a single in-app export: the Audit lens
carries an **Export Excel View...** button that always writes the coloured XLSX
matrix, capturing the visible rows, the active support filters, and the on-screen
fill and border colours. There is no in-app format picker. That XLSX export is a
self-describing workbook: a Matrix sheet of the sample-by-locus calls colored
with the family palette, a Legend sheet that decodes the colors, an Overrides
sheet of analyst-applied call changes, and an Audit Log sheet of the recorded
actions. CSV, TSV, and the samples-across pivot workbook come only from the
command line.

<!-- planned: genotype-export-dialog -->

The samples-across pivot workbook transposes the layout so samples run across the
columns and alleles run down the rows, which is the orientation many downstream
spreadsheets expect. The Filtered Pivot button at the foot of the Inspector's
Genotype Display section writes a copy of the result's current workbook with
only the pivot sheet changed: allele values below the Min Reads and Min Percent
filters shown above it are blanked, each row's Total and observation count are
recomputed, and rows left empty are removed. Every other sheet and all
formatting are carried through unchanged. The copy is a one-way export, so edits
made to it in Excel never flow back into the result. All of these exports are
read-only with respect to the bundle: they never modify the calls or the
annotations. The headless exporters are `lungfish genotype export-xlsx` for the
coloured matrix, `lungfish genotype export-pivot-xlsx` for the filtered pivot
workbook (with `--min-reads`, `--min-percent`, `--percent-basis` and an optional
`--source-workbook`), and the general
`lungfish genotype export`, whose `--export-format` defaults to `xlsx` and also
accepts `csv` or `tsv`. That general form takes a repeatable `--sample` to
restrict the matrix to named samples, an `--active-haplotype-definition` to
resolve calls against a chosen definition set, and an `--annotations` sidecar,
and it refuses to overwrite an existing file unless you pass `--force`.

### Step 4. Export LabKey-ready CSV files

When results feed a LabKey server, export the LabKey-ready CSV set rather than a
single workbook. It writes several long-format CSV files, one row per fact (each
row records one small fact: one sample, one allele, one count). That long shape is
what a database loads most easily, with stable headers and standard escaping so an
ingestion step can load them directly. The set covers the final post-override
haplotype calls, the per-sample per-allele read counts, the analyst overrides,
the audit trail, and the saved cohorts.

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
