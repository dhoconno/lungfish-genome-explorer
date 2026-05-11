# Foundations Documentation Alignment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Correct the Foundations manual section so it is scientifically accurate, honest about `v0.4.0-alpha.12` app behavior, and ready to serve as the review template for later manual sections.

**Architecture:** Execute as a documentation-first pass. Product claims are verified before prose changes; unsupported claims are narrowed or converted into follow-up issues instead of silently implying the feature works. App code changes are out of scope unless the user explicitly promotes a manifest item from documentation correction to implementation.

**Tech Stack:** Markdown, MkDocs/Read the Docs, Swift source/test grep, targeted SwiftPM tests only if a follow-up implementation is approved.

---

## File Structure

**Modify after approval:**

- `docs/user-manual/chapters/01-foundations/01-what-is-a-genome.md`
- `docs/user-manual/chapters/01-foundations/02-sequencing-reads.md`
- `docs/user-manual/chapters/01-foundations/03-amplicon-vs-shotgun.md`
- `docs/user-manual/chapters/01-foundations/04-alignment-files.md`
- `docs/user-manual/chapters/01-foundations/05-variants-and-vcf.md`
- `docs/user-manual/chapters/01-foundations/06-the-lungfish-project.md`
- `docs/user-manual/chapters/01-foundations/07-plugin-packs.md`
- `docs/user-manual/chapters/01-foundations/08-provenance-and-reproducibility.md`
- `docs/user-manual/chapters/01-foundations/09-shared-projects.md`
- `docs/user-manual/build/scripts/lint/rules/` only if adding a tiny docs guard fits the existing lint style

**Create after approval if product gaps remain:**

- `docs/issues/2026-05-10-foundations-provenance-export-gaps.md`
- `docs/issues/2026-05-10-foundations-operations-panel-gaps.md`
- `docs/issues/2026-05-10-foundations-coordinate-parser-gap.md`
- `docs/issues/2026-05-10-foundations-shared-projects-gui-gap.md`
- `docs/issues/2026-05-10-foundations-plugin-pack-doc-sync.md`
- `docs/issues/2026-05-10-foundations-active-issue-reconciliation.md`

**Do not modify in this plan without separate approval:**

- `Sources/`
- `Tests/`
- release artifacts under `build/Release/`

## Task 1: Scientific Correctness Patch

**Files:**

- Modify: `docs/user-manual/chapters/01-foundations/01-what-is-a-genome.md`
- Modify: `docs/user-manual/chapters/01-foundations/02-sequencing-reads.md`
- Modify: `docs/user-manual/chapters/01-foundations/03-amplicon-vs-shotgun.md`
- Modify: `docs/user-manual/chapters/01-foundations/04-alignment-files.md`
- Modify: `docs/user-manual/chapters/01-foundations/05-variants-and-vcf.md`

- [ ] **Step 1: Verify current lines before editing**

Run:

```bash
nl -ba docs/user-manual/chapters/01-foundations/01-what-is-a-genome.md | sed -n '24,88p'
nl -ba docs/user-manual/chapters/01-foundations/03-amplicon-vs-shotgun.md | sed -n '24,104p'
```

Expected: the D614G and shotgun-depth claims listed in the manifest are still present.

- [ ] **Step 2: Replace the D614G example**

In `01-what-is-a-genome.md`, replace the `21618 C>T` example with prose equivalent to:

```markdown
For example, `MN908947.3:23403 A>G` means: use the SARS-CoV-2 Wuhan-Hu-1 reference sequence `MN908947.3`; go to base 23,403; the reference base is `A`; and the sample has `G` there. That nucleotide change is the classic spike D614G example.
```

Expected: the chapter no longer labels `21618 C>T` as D614G.

- [ ] **Step 3: Tighten genome terminology**

In `01-what-is-a-genome.md`, adjust the introduction so it says:

```markdown
A genome is the complete genetic sequence carried by an organism, virus, organelle, plasmid, or other biological entity being analyzed. Most cells carry a genome, and most viral particles carry a viral genome, but real biology has exceptions; the useful idea is that the genome is the reference sequence for the entity you are studying.
```

Expected: the chapter no longer implies every cell and every viral particle always carries a full copy.

- [ ] **Step 4: Correct SARS-CoV-2 "chromosome" wording**

In `01-what-is-a-genome.md`, change the SARS-CoV-2 example to describe `MN908947.3` as:

```markdown
a single positive-sense RNA genome, represented in reference files with DNA alphabet conventions
```

Expected: the chapter does not call SARS-CoV-2 a chromosome.

- [ ] **Step 5: Correct shotgun-depth arithmetic**

In `03-amplicon-vs-shotgun.md`, replace the low-abundance calculation with:

```markdown
If viral reads make up 0.01% of a shotgun library, then one viral read is expected about once per 10,000 total reads. A 30 kb viral genome needs about 200 perfectly distributed 150 bp reads for 1x nominal coverage, so the back-of-envelope total is about 2 million reads before losses from host depletion, duplicates, mapping, uneven coverage, and quality filters.
```

Expected: the calculation is dimensionally clear and no longer says one read requires 300 million reads.

- [ ] **Step 6: Reframe Q-score and pair-count claims**

In `02-sequencing-reads.md`, change broad claims so they say:

```markdown
For Illumina-style short reads, Q30 bases are usually strong evidence, but base qualities are only one input. Mapping quality, depth, strand balance, read position, duplicate handling, and platform-specific calibration all affect whether a variant is credible.
```

Expected: the chapter no longer teaches Q30/Q20 as universal pass/fail rules.

- [ ] **Step 7: Fix amplicon workflow order and strand-bias guidance**

In `03-amplicon-vs-shotgun.md`, `04-alignment-files.md`, and `05-variants-and-vcf.md`, make the workflow order explicit:

```markdown
In Lungfish, primer trimming for ARTIC-style amplicon data is a BAM-level operation after alignment and before variant calling.
```

Also replace categorical strand-bias statements with:

```markdown
Amplicon protocols can create strand and pool imbalances, so a strand-bias flag is a reason to inspect the pileup and protocol context rather than an automatic reason to discard or keep the call.
```

Expected: the manual no longer says primer trimming is the first analysis step or that `sb` can usually be ignored.

- [ ] **Step 8: Correct primer scheme and BAM/VCF precision**

In `03-amplicon-vs-shotgun.md`, make the primer scheme example clear:

```markdown
A BED row records primer coordinates and labels. Primer sequences live in a companion FASTA/TSV or in extra scheme-specific columns when the scheme provides them.
```

In `04-alignment-files.md`, change "one row per read" to:

```markdown
A BAM contains one alignment record per mapped segment or reported alignment. A single sequenced read can have primary, secondary, supplementary, or mate records; the FLAG column tells tools how each record should be interpreted.
```

In `05-variants-and-vcf.md`, add:

```markdown
VCF fields are defined by the header and by the caller. In Lungfish-normalized viral VCFs, `AF` is intended to mean read-level variant allele fraction, but human, cohort, pooled, or caller-native files can use `AF`, `GT`, `QUAL`, and `FILTER` differently.
```

Expected: expert readers are not taught overbroad BED, BAM, or VCF semantics.

- [ ] **Step 9: Run docs string checks**

Run:

```bash
rg -n "21618 C>T|single chromosome|300 million reads|every particle of every virus" docs/user-manual/chapters/01-foundations
```

Expected: no matches for obsolete wording.

## Task 2: App/CLI Claim Audit and Prose Narrowing

**Files:**

- Modify: `docs/user-manual/chapters/01-foundations/01-what-is-a-genome.md`
- Modify: `docs/user-manual/chapters/01-foundations/04-alignment-files.md`
- Modify: `docs/user-manual/chapters/01-foundations/05-variants-and-vcf.md`
- Modify: `docs/user-manual/chapters/01-foundations/06-the-lungfish-project.md`
- Modify: `docs/user-manual/chapters/01-foundations/07-plugin-packs.md`
- Modify: `docs/user-manual/chapters/01-foundations/09-shared-projects.md`

- [ ] **Step 1: Audit project and plugin claims**

Run:

```bash
rg -n "PluginPack\\(|id: \"variant-calling\"|id: \"read-mapping\"|AnalysesFolder|ReferenceSequenceFolder|PrimerSchemesFolder|Plugin Manager" Sources Tests
```

Expected: evidence for current plugin pack contents, `Analyses/`, Reference Sequences, Primer Schemes, and Plugin Manager UI.

- [ ] **Step 2: Update project folder description**

In `06-the-lungfish-project.md`, replace the "five sidebar folders" framing with:

```markdown
A Lungfish project is a folder-backed workspace. The most common top-level areas are `Imports/`, `Downloads/`, `Reference Sequences/`, `Primer Schemes/`, and `Analyses/`. Some are created when the project is created; others appear the first time a workflow needs them.
```

Expected: the chapter includes `Analyses/` and does not imply every folder always exists from project creation.

- [ ] **Step 3: Narrow coordinate-string support**

In `01-what-is-a-genome.md`, replace "anywhere it asks for a location" with:

```markdown
When a Lungfish tool asks for a genomic region, use the format shown by that tool and keep the reference accession visible in the surrounding context.
```

Expected: no broad app-wide parser claim remains.

- [ ] **Step 4: Reconcile mapper and BAM wording**

In `04-alignment-files.md`, keep the supported mapper list if it matches code, but replace "always reads and writes BAMs, never SAMs" and "every BAM" with:

```markdown
Current GUI workflows store alignments as indexed BAM or CRAM-backed tracks. Some command-line tools and intermediate stages may use SAM or unindexed files briefly, but bundle-owned alignment tracks should have an index before Lungfish offers region-level browsing.
```

Expected: user-facing storage guidance stays useful without overstating internals.

- [ ] **Step 5: Refresh plugin pack table from code**

In `07-plugin-packs.md`, update the pack table from `PluginPack.builtIn` and `third-party-tools-lock.json`. The variant-calling row must distinguish `iVar`, `LoFreq`, `Medaka`, `Clair3`, `bcftools` support, and any installed-but-not-first-class tools. Replace any unverified OS wording with the release-supported macOS requirement from the release settings.

Expected: table matches `Sources/LungfishWorkflow/Conda/PluginPack.swift` and release metadata.

- [ ] **Step 6: Reconcile caller and GATK status**

Audit current variant surfaces with:

```bash
rg -n "case clair3|case bcftools|GATK|variants phase|HaplotypeCaller|WhatsHap|BAMVariantCallingToolID" Sources Tests docs/issues
```

Then update Foundations so each tool is labeled as one of:

```markdown
GUI-supported, CLI-supported, installed as a managed tool, command-plan only, or tracked as a first-class product gap.
```

Expected: LoFreq/iVar/Medaka/Clair3/bcftools/GATK wording no longer conflicts across chapters.

- [ ] **Step 7: Keep shared-project limits explicit**

In `09-shared-projects.md`, preserve the current limitation that GUI warnings/read-only mode are future behavior, and verify the CLI examples with:

```bash
swift run lungfish-cli project --help
```

Expected: the chapter teaches CLI locking only where implemented and keeps GUI multi-user work as a future issue.

- [ ] **Step 8: Capture project portability caveat**

In `06-the-lungfish-project.md`, replace any "copy to another Mac and everything works" implication with:

```markdown
Project data, bundles, logs, and provenance travel with the project folder. Re-running workflows on another Mac also requires a compatible Lungfish version, installed plugin packs, and any external databases referenced by the project.
```

Expected: portability is accurate without undermining project-folder usefulness.

## Task 3: Provenance Chapter Refresh

**Files:**

- Modify: `docs/user-manual/chapters/01-foundations/08-provenance-and-reproducibility.md`
- Create, only if needed: `docs/issues/2026-05-10-foundations-provenance-export-gaps.md`

- [ ] **Step 1: Find representative current sidecars**

Run:

```bash
find Tests -name '*provenance*.json' -o -name '*.provenance.json' | sort | head -n 40
```

Expected: at least one current sidecar or test fixture is available for schema comparison.

- [ ] **Step 2: Audit provenance export implementation**

Run:

```bash
rg -n "exportProvenance|ProvenanceExport|exportShell|exportNextflow|exportSnakemake|exportMethods|provenance verify" Sources Tests docs/user-manual/chapters/appendices/cli-reference.md
```

Expected: implemented export formats and CLI verification commands are visible.

- [ ] **Step 3: Rewrite the provenance guarantee**

Replace broad "every operation" language with:

```markdown
For supported scientific workflows that create, import, transform, export, or wrap data, Lungfish records reproducibility provenance with the output. The alpha contract is strict for new workflows: missing provenance is a defect, not an optional enhancement. Older paths are being audited, so when the manual names a workflow it should also be possible to find the sidecar or bundle provenance it writes.
```

Expected: the chapter matches the repository provenance requirement without falsely guaranteeing unaudited legacy paths.

- [ ] **Step 4: Refresh the JSON example**

Replace the example sidecar with either a real current sidecar excerpt or an explicitly labeled simplified example containing these fields:

```json
{
  "workflowName": "lungfish example workflow",
  "toolVersion": "0.4.0-alpha.12",
  "command": "lungfish ...",
  "inputs": [],
  "outputs": [],
  "runtime": {},
  "exitStatus": 0
}
```

Expected: readers are not taught a stale authoritative schema.

- [ ] **Step 5: Add helper and migration provenance requirements**

Ensure `08-provenance-and-reproducibility.md` and `09-shared-projects.md` state that helper/converter steps and migrations that rewrite scientific data record:

```markdown
tool or workflow name and version, exact argv or reproducible command, resolved defaults, runtime identity, input/output paths, checksums, file sizes, exit status, wall time, and useful stderr.
```

Expected: the Foundations section reflects the repo-level provenance contract for iVar TSV-to-VCF conversion, workflow exports, imports, extraction, classifier outputs, FASTQ transformations, and migrations.

- [ ] **Step 6: File product gaps instead of overclaiming**

If the audit does not prove a described export shape, create `docs/issues/2026-05-10-foundations-provenance-export-gaps.md` with acceptance criteria for the missing behavior.

Expected: the manual only describes implemented provenance export behavior, and missing export packaging is tracked.

## Task 4: Help, Operations Panel, and UX Claims

**Files:**

- Modify: `docs/user-manual/chapters/01-foundations/06-the-lungfish-project.md`
- Modify: `docs/user-manual/chapters/01-foundations/08-provenance-and-reproducibility.md`
- Create, only if needed: `docs/issues/2026-05-10-foundations-operations-panel-gaps.md`

- [ ] **Step 1: Verify menu claims statically**

Run:

```bash
rg -n "Show Operations Panel|Lungfish User Manual|Report a Problem|Help > Search|exportProvenance|Operations Panel" Sources/LungfishApp Tests/LungfishAppTests Tests/LungfishXCUITests
```

Expected: implemented menu items can be distinguished from aspirational prose.

- [ ] **Step 2: Narrow Operations Panel persistence**

If persistence across relaunch and background continuation after window close are not proven, replace those claims with:

```markdown
The Operations Panel shows live long-running jobs for the current session. Completed workflows write files, logs, and provenance that remain with the project after the job finishes.
```

Expected: the panel is no longer described as more persistent than verified behavior.

- [ ] **Step 3: Narrow Help menu wording**

If Help search/report anchoring is not verified, replace the paragraph with:

```markdown
The user manual is available from the app's Help menu and from the project README. When a workflow has a dedicated manual chapter, the chapter title in this guide is the stable reference.
```

Expected: no nonexistent Help workflow is taught.

- [ ] **Step 4: File UX follow-up if needed**

If the product gap matters, create an issue with acceptance criteria for Help search, report-problem metadata, and Operations Panel persistence.

Expected: missing UX is visible without blocking the doc correction.

## Task 5: Active Issue Reconciliation

**Files:**

- Modify: `docs/issues/2026-05-09-followups-from-evaluation-sweep.md`
- Modify: `docs/issues/2026-05-09-technical-gaps-from-documentation.md`
- Modify: `docs/issues/2026-05-09-docs-039-gatk-first-class-integration.md`
- Create, only if needed: `docs/issues/2026-05-10-foundations-active-issue-reconciliation.md`

- [ ] **Step 1: Audit active issue statements against current source**

Run:

```bash
rg -n "dead code|Workflow Builder|GATK|Clair3|Freyja|provenance|plugin pack|not currently" docs/issues Sources Tests
```

Expected: stale issue claims are visible alongside source/test evidence.

- [ ] **Step 2: Update or split stale active issues**

Apply concrete status notes where source/tests show drift. Start with these known candidates:

```markdown
**Status 2026-05-10:** Partially addressed. Current source exposes `Tools > Workflow Builder...` and `.lungfishflow` save/export paths. Remaining gap: verify which Workflow Builder actions are product-ready and update the manual or issue scope accordingly.

**Status 2026-05-10:** Partially addressed. Clair3 is present in the managed `variant-calling` pack and accepted by current variant-calling source/tests. Remaining gap: clarify whether each Clair3 path is GUI-supported, CLI-supported, or only installed as a managed tool.

**Status 2026-05-10:** Partially addressed. GATK command construction, execution/provenance paths, and phased workflow planning now exist in source/tests. Remaining gap: keep docs-039 as the first-class human germline product scope and stop describing all GATK behavior as dry-run only.
```

Expected: no active issue tells future agents that implemented behavior is still absent.

- [ ] **Step 3: Keep unresolved expert-review issues salient**

If a finding remains open and relevant, leave it active and point to the Foundations manifest item instead of moving it to `docs/archive/`.

Expected: active issue files are trustworthy inputs to the next implementation pass.

## Task 6: Verification and Review Handoff

**Files:**

- Modify: documentation and issue files from Tasks 1-5 only.

- [ ] **Step 1: Run Markdown/link smoke**

Run:

```bash
export DYLD_FALLBACK_LIBRARY_PATH=/opt/homebrew/lib:${DYLD_FALLBACK_LIBRARY_PATH:-}
ENABLE_PDF_EXPORT=0 mkdocs build -f docs/user-manual/build/mkdocs.yml -d /Users/dho/Documents/lungfish-genome-explorer/.docs-site/user-manual-foundations-review
```

Expected: MkDocs exits 0. Any existing warnings are reviewed so new broken links are not introduced.

- [ ] **Step 2: Run targeted stale-string checks**

Run:

```bash
rg -n "21618 C>T|single chromosome|300 million reads|current ARTIC primer set|five sidebar folders|anywhere it asks for a location" docs/user-manual/chapters/01-foundations
```

Expected: no matches unless the text is explicitly discussing a corrected historical error.

- [ ] **Step 3: Check git diff**

Run:

```bash
git diff -- docs/user-manual/chapters/01-foundations docs/issues docs/superpowers
git diff --check
```

Expected: only approved docs/planning/issue files changed; whitespace check passes.

- [ ] **Step 4: Commit only after user approval**

Run after approval:

```bash
git add docs/user-manual/chapters/01-foundations docs/issues docs/superpowers
git commit -m "docs: align foundations manual with alpha behavior"
```

Expected: one focused documentation commit.

## Self-Review Checklist

- [ ] Every P0 item from the manifest maps to Task 1.
- [ ] Every P1 app/manual mismatch maps to Tasks 2-4.
- [ ] Every issue-reconciliation finding maps to Task 5 or a deliberate deferral.
- [ ] No plan step requires app-code edits without separate user approval.
- [ ] Provenance wording remains strict for new scientific workflows.
- [ ] The plan leaves `main` and release artifacts untouched.
