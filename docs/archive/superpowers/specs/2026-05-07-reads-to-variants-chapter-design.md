# Reads-to-Variants Chapter and Supporting Engineering — Design Spec

**Date:** 2026-05-07
**Status:** Draft for review
**Scope:** End-to-end SARS-CoV-2 chapter (NCBI download → SRA reads → mapping → primer-trim → iVar + LoFreq variant calls → cross-caller comparison) plus the Lungfish engineering work that has to land first.
**Supersedes:** `2026-04-24-reads-to-variants-chapter-artifacts-design.md` (prep-only spec; this one folds the prep into the same plan as the prose).

---

## 1. Context

The user manual currently has two short variant chapters under `docs/user-manual/chapters/04-variants/`:

1. `01-reading-a-vcf.md` — interpret a VCF that someone hands you, against the small `sarscov2-clinical` fixture (about 100 read pairs).
2. `02-calling-variants-from-a-bam.md` — primer-trim and iVar-call the same fixture's BAM.

Both are short and pedagogically thin, because they were written when Lungfish could not fetch reads, could not map them, and could not primer-trim a BAM. The app has since gained NCBI download, SRA download, in-app minimap2 mapping, the QIASeqDIRECT-SARS2 primer scheme, and a variant-calling dialog. The chapters do not yet teach what the app can do.

This spec replaces both chapters with a single end-to-end chapter that walks a bench scientist from raw NCBI/SRA accessions to two side-by-side VCF tracks they called themselves with two different callers, on a real (not toy) SARS-CoV-2 dataset.

The chapter cannot be written against the shipped app today, because three concrete defects block the workflow. This spec covers those fixes, plus the chapter, as one unit of work.

## 2. Goals and non-goals

### Goals

- **One end-to-end chapter** at `docs/user-manual/chapters/04-variants/01-reads-to-variants.md` that replaces the two existing chapters, walks the reader through the full workflow on `SRR36291587` against `MN908947.3`, and ends with a side-by-side comparison of iVar and LoFreq variant tracks.
- **Three fixes inside Lungfish** so the chapter's workflow runs to completion on the shipped app: a Swift TSV-to-VCF converter for iVar output, a CLI command to attach a fresh mapping result to a reference bundle, and an SRA download default that does not silently fail.
- **Test coverage** for each new piece, plus an end-to-end CLI integration test that runs the full workflow against a smaller fixture.
- **GUI parity** for the iVar options exposed by the new converter (`--ignore-strand-bias`, `--consensus-af`, `--merge-af-threshold`, `--bad-quality-threshold`).
- **Screenshot and artifact instructions** the user can follow by hand, since computer-use screenshotting against a complex app has been unreliable.

### Non-goals

- Documenting other manual sections (sequences, alignments, classification, assembly). Those are separate chapters.
- Adding new variant callers or new primer schemes.
- Changing the variant browser viewport. The browser already renders multi-caller VCFs over a shared reference; the chapter teaches the existing surface.
- Any change to LoFreq's pipeline path. LoFreq already produces standards-compliant VCF and works end-to-end today.
- Native re-implementation of `samtools`, `bcftools`, `tabix`. The pipeline keeps its current managed-tool model.

## 3. The three Lungfish fixes

### 3.1 iVar TSV-to-VCF converter (Swift, in-process)

#### Problem

The pipeline at `Sources/LungfishWorkflow/Variants/ViralVariantCallingPipeline.swift:570` passes `--output-format vcf` to `ivar variants`. iVar 1.4.4 (the latest release, Feb 2025) does not accept that flag. Verified two ways: the binary's own help lists only TSV output, and the upstream `ivar.cpp` master branch uses plain `getopt` with `variants_opt_str = "p:t:q:m:r:g:Gh?"`. There is no `--output-format` option, no `getopt_long` call, and no VCF emit code anywhere in iVar. Calling iVar with that flag produces `illegal option -- -` and an empty output. `bcftools sort` then fails on the missing input, so the whole pipeline returns an error and the variant track never lands.

#### Fix

Add a Swift implementation of iVar's TSV-to-VCF conversion at parity with `nf-core/viralrecon`'s `ivar_variants_to_vcf.py`. The reference Python script is the operational standard for the SARS-CoV-2 community and a known-good comparison target.

The converter is a new file `Sources/LungfishWorkflow/Variants/IVarTSVToVCFConverter.swift`. The pipeline calls it after `ivar variants` writes its `.tsv`, replacing the (broken) `--output-format vcf` invocation. The converter writes `ivar.raw.vcf` exactly where the existing pipeline expects it, so the downstream `bcftools sort` → `bgzip` → `tabix` → SQLite-import chain is unchanged.

#### Required behavior

The converter implements all five behaviors of the viralrecon script.

1. **Per-row transcription.** One iVar TSV row maps to one VCF row by default. INFO carries `TYPE=SNP|INS|DEL`. FORMAT carries the per-site numbers (`GT:DP:REF_DP:REF_RV:REF_QUAL:ALT_DP:ALT_RV:ALT_QUAL:ALT_FREQ`, plus `MERGED_AF:MERGED_DP` on merged rows).

2. **Indel anchoring.** iVar writes insertions as `+ATC` and deletions as `-ATC` in the ALT column. VCF 4.2 requires anchored alleles. The converter rewrites these:
   - Insertion: `REF` stays as the iVar reference base; `ALT` becomes `REF + inserted bases`.
   - Deletion: `REF` becomes `REF + deleted bases`; `ALT` becomes the iVar reference base alone.
   No FASTA lookup is needed because iVar's TSV already gives the anchor base in the `REF` column.

3. **Header emission.** `##fileformat=VCFv4.2`, `##source=iVar 1.4.4 (TSV-to-VCF: Lungfish <version>)`, one `##contig=<ID=...,length=...>` per chromosome from the indexed FASTA, the FORMAT/INFO/FILTER declarations the viralrecon script emits, and the `#CHROM` line.

4. **Codon-aware haplotype merging.** Adjacent SNPs whose `REF_CODON` or `ALT_CODON` agree are grouped, all `2^n` REF/ALT combinations are enumerated, and `merge_rule_check` validates each combination using the AF rules below. Two outputs are written:
   - The primary VCF (`ivar.raw.vcf`) carries the consensus haplotypes (combinations whose AFs are all above `--consensus-af`, default 0.75).
   - A sibling `_all_hap.vcf` carries every viable combination. The pipeline keeps both so a future "show all haplotypes" toggle in the variant browser has data to render. For now, only the primary file feeds downstream stages.

   `merge_rule_check` keeps a combination if any of:
   - All AFs in the group are above `--consensus-af`.
   - All AFs in the group are between 0.4 and 0.6 inclusive.
   - The maximum pairwise AF distance in the group is below `--merge-af-threshold` (default 0.25).

   Otherwise the combination is split and each variant is evaluated individually; rows where `AF > --consensus-af` survive, the rest fall through to the `_all_hap.vcf` only.

   This requires `ivar variants` to be invoked with a real GFF (it currently gets `/dev/null`). Section 3.1.5 covers that.

5. **Strand-bias filter.** Fisher's exact test on the 2×2 table `[[REF_DP - REF_RV, REF_RV], [ALT_DP - ALT_RV, ALT_RV]]`, two-sided, p < 0.05 fails the `sb` filter. Implemented natively using `Foundation.lgamma` for the hypergeometric tail; the 2×2 case has a closed form and does not need an iterative test. The `--ignore-strand-bias` flag disables it; the Lungfish pipeline defaults `--ignore-strand-bias` to **true** because the chapter's whole context is amplicon data, where strand bias from primer placement is structural, not informative. The dialog and CLI both expose the flag.

The FILTER column carries semicolon-separated codes:
- `ft` if the iVar TSV `PASS` column is `FALSE`.
- `bq` if `ALT_QUAL` is below `--bad-quality-threshold` (default 20).
- `sb` if Fisher fails and strand bias is not being ignored.
- `PASS` if all three pass.

#### Configuration surface

Five options. All four numeric/boolean ones flow to both the GUI dialog and the CLI; the fifth (`--pass-only`) is internal to the converter and not user-facing for now.

| Option | Default | GUI label | CLI flag |
|---|---|---|---|
| Consensus AF threshold | 0.75 | "Consensus allele frequency" | `--consensus-af` |
| Merge AF distance | 0.25 | "Merge AF distance" | `--merge-af-threshold` |
| Bad-quality threshold | 20 | "Minimum ALT quality" | `--bad-quality-threshold` |
| Ignore strand bias | true | "Ignore strand bias (recommended for amplicons)" | `--ignore-strand-bias` |

These plumb through `BundleVariantCallingRequest` (already exists; gain four new fields), `BAMVariantCallingDialogState` (gain matching `@Published` fields), `BAMVariantCallingToolPanes.swift` (a new "iVar Options" group below the existing primer-trim acknowledgement, `Sources/LungfishApp/Views/BAM/BAMVariantCallingToolPanes.swift:91` is the anchor for the insertion), and `VariantsCommand.CallSubcommand` (gain four matching `@Option`s).

#### GFF passthrough

`ViralVariantCallingPipeline.swift` currently passes `-g /dev/null` to `ivar variants`. With `/dev/null` the `REF_CODON`/`ALT_CODON`/`POS_AA` columns are blank, and the codon merger has nothing to group on. The fix is to extract the GFF3 from the reference bundle's annotation database into a temp file and pass that path to `ivar variants` instead. The bundle's annotation SQLite already exposes a "dump as GFF3" path (`Sources/LungfishWorkflow/Annotation/`). If the bundle has no annotations attached (rare for SARS-CoV-2 but possible for arbitrary bundles), the converter falls back to per-row transcription with the codon merger disabled, and emits a `##LungfishNote=` header line so the consumer knows.

### 3.2 `lungfish bam adopt-mapping` CLI subcommand

#### Problem

The CLI today can map FASTQ to a reference (`lungfish map`) and produces a loose mapping-result directory. It cannot then attach that mapping result to a `.lungfishref` bundle as an alignment track. That last step is GUI-only — the in-app Mapping wizard performs the attachment as part of its dialog flow. Because GUI testing is flaky for agents, the chapter cannot be reliably exercised end-to-end without the GUI in front of a human.

#### Fix

Add `lungfish bam adopt-mapping`, a new subcommand under the existing `bam` group. It takes a `--mapping-result` directory and a `--bundle`, and attaches the mapping result's sorted, indexed BAM to the bundle as a fresh alignment track. The implementation is a thin wrapper over `PreparedAlignmentAttachmentService` (the same service `bam primer-trim` uses to adopt a primer-trimmed BAM at `Sources/LungfishCLI/Commands/BAMPrimerTrimSubcommand.swift:347`).

#### Surface

```
lungfish bam adopt-mapping
    --bundle <ref-bundle.lungfishref>
    --mapping-result <mapping-dir>
    --name "<display name>"
    [--track-id <override>]
```

Defaults:
- `--track-id` auto-generated as `aln_<UUID>` (matches existing convention).
- The BAM is moved (not copied) into `<bundle>/alignments/<track-id>/<track-id>.bam`. The mapping-result directory is left in place but its `sorted.bam` is replaced with a symlink so a subsequent `lungfish map --resume`-style flow does not re-run.
- A provenance sidecar is written carrying the source mapping-result's `mapping-provenance.json` content so the bundle records mapper version, command line, and reads → reference checksums.

This is the minimum CLI surface needed for the chapter's workflow to be reproducible from the shell. It does not (yet) replicate every option the GUI Mapping wizard exposes — secondary alignment retention, MAPQ filtering, and so on are already on `lungfish bam filter` and stay there.

### 3.3 SRA download default fallback

#### Problem

`lungfish fetch sra download SRR36291587` fails with the default ENA path:

```
Error: Network error: Download failed: Could not download FASTQ files from ENA for SRR36291587. Attempted URLs: https://ftp.sra.ebi.ac.uk/vol1/fastq/SRR362/087/SRR36291587/SRR36291587_1.fastq.gz, https://ftp.sra.ebi.ac.uk/vol1/fastq/SRR362/087/SRR36291587/SRR36291587_2.fastq.gz
```

The same accession works fine with `--use-toolkit`. The ENA file layout for SRR36291587 differs from what the URL builder expects (probably because the run is recent enough that ENA's mirror has not finished propagating, or because ENA's path scheme has changed). A user following the chapter on the shipped app will hit this failure on their first download attempt.

#### Fix

When the ENA path fails with a 404 or "could not download" error, automatically retry with the SRA Toolkit path. Surface the fallback in the progress output (`Falling back to SRA Toolkit (prefetch + fasterq-dump)…`) so the user sees what is happening and how long it will take. If the toolkit also fails, surface both errors. The `--use-toolkit` flag remains an explicit override.

The implementation lives in `Sources/LungfishWorkflow/Fetch/SRADownloadService.swift` (or the file that currently builds the ENA URL — the `fetch sra download` subcommand at `Sources/LungfishCLI/Commands/FetchCommand.swift:375` calls into a workflow service; the retry logic lives there). One unit test for the fallback path, one integration test that exercises both branches against a local mock server, since CI cannot reach SRA reliably.

## 4. Testing strategy

Every fix in section 3 ships with tests. Where the test name is plural it indicates a group, not a single function.

### 4.1 TSV-to-VCF converter

- **Unit tests** in `Tests/LungfishWorkflowTests/IVarTSVToVCFConverterTests.swift`:
  - Indel anchoring: insertion `+ATC`, deletion `-ATC`, multiple-base deletion, edge case where REF is already multi-base.
  - Header emission: contig lines for one-chromosome and multi-chromosome FASTAs, `##LungfishNote=` when GFF is missing.
  - Per-row SNP transcription: every column of a hand-built 5-row TSV maps to the right VCF cell.
  - Fisher 2×2 strand-bias: tabulated values from `scipy.stats.fisher_exact` for ten contingency tables, p-values match within 1e-9.
  - `merge_rule_check`: all-above-consensus passes, 0.4–0.6 band passes, distance-below-merge passes, mixed group splits.
  - Codon merge: two adjacent SNPs sharing a codon produce one merged row in primary, four (one per haplotype) in `_all_hap.vcf`.
- **Parity test** in `Tests/LungfishIntegrationTests/IVarConverterViralReconParityTests.swift`:
  - Fixture: `Tests/Fixtures/ivar-converter-parity/sarscov2-srr36291587.tsv` (the iVar TSV from this spec's CLI validation), plus the GFF3 from the MN908947.3 bundle, plus the FASTA index.
  - Run the Swift converter and the upstream `ivar_variants_to_vcf.py` (installed as a CI step from the nf-core/viralrecon repo at a pinned commit).
  - Diff the two `ivar.raw.vcf` outputs after stripping cosmetic header lines (`##fileDate`, `##source`, command-line traces). All other lines, including `_all_hap.vcf` rows, must match byte-for-byte.
  - The fixture is committed; the Python script is not (CI installs it once and discards it).

### 4.2 `bam adopt-mapping`

- **Unit test** for argument validation (missing flags, bad bundle path, mapping-result missing `sorted.bam`).
- **Integration test** in `Tests/LungfishIntegrationTests/BAMAdoptMappingIntegrationTests.swift`:
  - Use the existing `sarscov2-clinical` fixture's `reads_R1.fastq.gz` and `reads_R2.fastq.gz`.
  - Run `lungfish map` against the fixture's reference, get a mapping-result directory.
  - Run `lungfish bam adopt-mapping --bundle <fresh bundle> --mapping-result <dir> --name "test track"`.
  - Assert: bundle manifest gains one `alignments[]` entry with the right name and ID, the BAM lives at the expected path, the index is alongside, the provenance sidecar carries the mapping JSON.
- **CLI integration** is the test that exercises the full chapter workflow on the small fixture (section 4.4). `bam adopt-mapping` is in the path; if it breaks, that test fails first.

### 4.3 SRA download fallback

- **Unit test** for the retry decision logic against a mock `URLSession` that returns 404 on the ENA URL pattern.
- **Integration test** behind a `LUNGFISH_LIVE_SRA_TESTS=1` env var: actually downloads `SRR36291587` and confirms both the auto-fallback path and the explicit `--use-toolkit` path complete. Skipped in CI by default.

### 4.4 End-to-end CLI integration test

A new test at `Tests/LungfishIntegrationTests/ReadsToVariantsEndToEndTests.swift` exercises every step the chapter describes, using the existing `sarscov2-clinical` fixture (the small one, not the SRR36291587 one — keeps the test under a few seconds).

The test:

1. `lungfish bundle create` from `reference.fasta`.
2. `lungfish map` against `reads_R1.fastq.gz` + `reads_R2.fastq.gz`.
3. `lungfish bam adopt-mapping` to attach the mapping result.
4. `lungfish bam primer-trim` with the QIASeqDIRECT-SARS2 scheme.
5. `lungfish variants call --caller ivar --ivar-primer-trimmed`.
6. `lungfish variants call --caller lofreq` against the un-trimmed alignment.
7. Assert: bundle has one reference, two alignment tracks (mapped, primer-trimmed), two variant tracks (iVar, LoFreq). VCFs exist and are tabix-indexed. iVar VCF passes `bcftools view --no-version`. LoFreq VCF passes the same. Both have at least one `PASS` row each.

This test is the regression net for the chapter. If any of the three fixes regress, this test fails on the next run.

## 5. The chapter

`docs/user-manual/chapters/04-variants/01-reads-to-variants.md` replaces `01-reading-a-vcf.md` and `02-calling-variants-from-a-bam.md`. Old chapter files are deleted in the same commit; their `chapter_id` references in `features.yaml` are updated; `docs/user-manual/index.md` and `docs/user-manual/chapters/04-variants/index.md` are updated to point at the new file.

### 5.1 Audience and tier

Tier: `bench-scientist`. The reader has done some sequencing and knows what a FASTA, FASTQ, BAM, and VCF are at the file-shape level, but has not necessarily called variants themselves before. The chapter assumes Lungfish is installed and the read-mapping plus variant-calling plugin packs are provisioned (`lungfish conda install read-mapping variant-calling`).

### 5.2 Frontmatter

```yaml
title: From Reads to Variants
chapter_id: 04-variants/01-reads-to-variants
audience: bench-scientist
prereqs: []
estimated_reading_min: 18
shots:
  - id: ncbi-download-dialog
    caption: "Downloading the SARS-CoV-2 reference from NCBI."
  - id: sra-download-dialog
    caption: "Pulling SRR36291587 from SRA."
  - id: mapping-wizard
    caption: "Mapping reads to MN908947.3 with minimap2."
  - id: primer-trim-dialog
    caption: "Primer-trimming with the QIASeqDIRECT-SARS2 scheme."
  - id: variant-call-dialog-ivar
    caption: "Calling variants with iVar against the primer-trimmed alignment."
  - id: variant-call-dialog-lofreq
    caption: "Calling variants with LoFreq against the un-trimmed alignment."
  - id: variant-tables-side-by-side
    caption: "Both VCF tracks open in the variant browser."
  - id: cross-caller-comparison
    caption: "Where iVar and LoFreq agree and where they disagree."
glossary_refs: [VCF, REF, ALT, genotype, allele-frequency, variant-caller, primer-trim, primer-scheme, amplicon, SRA, codon, strand-bias]
features_refs: [import.vcf, viewport.variant-browser, variants.call, bam.primer-trim, fetch.ncbi, fetch.sra, map]
fixtures_refs: [sarscov2-srr36291587]
brand_reviewed: false
lead_approved: false
```

### 5.3 Structure

The chapter follows the manual's standard "primer → why → procedure → interpretation → next steps" arc. Approximate length 3500–4500 words, structured as:

- `## What it is` — what the workflow produces (two VCFs over the same reference, one per caller) and what each ingredient is.
- `## Why this matters` — the choices a chapter reader makes that bake into a final call set, the role of primer-trim for amplicon data, the value of cross-caller comparison.
- `## Before you start` — plugin packs to install, expected disk and time budget (~250 MB temp, ~5 minutes wall clock for the full workflow on a recent Apple Silicon Mac), how to verify provisioning.
- `## Procedure` — eight numbered steps, each with one shot reference where useful. The steps mirror the end-to-end CLI test in section 4.4 but described as a GUI tutorial.
- `## Interpreting what you see` — the comparison section. What rows agree, what rows are iVar-only, what rows are LoFreq-only, and what each pattern usually means biologically. Includes the codon-merge teaching moment (adjacent SNPs in spike's RBD that iVar groups into a single haplotype row).
- `## Next steps` — pointers to deeper chapters that do not yet exist, plus a sentence on how to run this same flow against the user's own reads.

### 5.4 Style constraints

Brand voice as the floor, per `docs/user-manual/STYLE.md`:
- No em dashes in chapter prose.
- Bullet lists capped at 5 items, at most 2 lists per H2.
- Lungfish in title case; never "LUNGFISH" or "lungfish" lowercase in prose.
- Five-color palette only in any embedded figures.

Where an existing phrase from `01-reading-a-vcf.md` or `02-calling-variants-from-a-bam.md` reads cleanly in the new chapter's flow, it is reused verbatim; otherwise it is dropped, not paraphrased.

### 5.5 Fixture

The chapter references a new fixture at `docs/user-manual/fixtures/sarscov2-srr36291587/` containing:

- `README.md` — accession, citation, license, exact `lungfish` commands the chapter walks through.
- A short script `regenerate.sh` that re-runs the full workflow from accessions and produces the artifacts. Committed but not run as part of CI.

The 21.7 MB compressed FASTQ from SRA is **not** committed. The reference (~30 KB), the iVar TSV converted to VCF (~30 KB), and the LoFreq VCF (~10 KB) **are** committed, so a chapter reader can compare their own results against the canonical ones without re-downloading the reads. The mapping BAM (~16 MB after primer-trim) is not committed; the script regenerates it.

### 5.6 Screenshot capture protocol

The user takes screenshots by hand on a real workstation. The chapter author (Claude, in a future session) writes one short prompt per shot, telling the user:

- Which window to be in (active project, sidebar selection, specific dialog open).
- Which menu/sidebar/inspector items should be visible.
- Which interaction state to capture (e.g., "Inputs section expanded, Advanced Options collapsed, primer-trim acknowledgement showing the auto-detected caption").
- Which window dimensions to use (uniform 1280×800 unless a wider table is needed).
- Where to save the file (`docs/user-manual/assets/screenshots/04-variants/<shot-id>.png`).

The instructions live in `docs/user-manual/chapters/04-variants/01-reads-to-variants-shotlist.md` (a sibling file, not committed to the published manual) and are written after the chapter prose is in place, so each shot's caption matches the surrounding text. The user runs through the shot list once, saves the PNGs, and commits them.

## 6. Sequencing and dependencies

The work has to land in this order:

1. **TSV-to-VCF converter** (section 3.1). Without this, no iVar output exists for the chapter. Includes the GFF passthrough fix.
2. **GUI dialog parity for new iVar options** (section 3.1, `BAMVariantCallingToolPanes.swift`). The dialog's options must match the CLI before the chapter screenshots iVar's settings panel.
3. **`bam adopt-mapping`** (section 3.2). Without this, the end-to-end CLI integration test cannot run, and the chapter author has no way to confirm the workflow before writing prose.
4. **SRA download fallback** (section 3.3). Without this, a reader hitting the chapter's first download step gets a confusing error. Lower priority than 1–3 because there is a workaround (`--use-toolkit`), but ships in the same release as the chapter.
5. **End-to-end CLI integration test** (section 4.4). Lands with step 3 and exercises 1–3.
6. **Chapter prose** (section 5). Uses 1–4 to walk a real workflow.
7. **Screenshot shotlist** (section 5.6). Drafted alongside prose, executed by the user after prose is reviewed.

Steps 1, 2, and 3 are mostly independent and could be done in parallel by separate agents in an executing-plans flow.

## 7. What this spec does not produce

- New variant callers, new primer schemes, or changes to the variant browser viewport.
- A primer scheme picker change. The existing built-in QIASeqDIRECT-SARS2 scheme is what the chapter uses.
- Documentation for any chapter outside `04-variants/`. Other sections of the manual stay in their current placeholder state.
- A CI job that runs the chapter's full workflow against live SRA. The end-to-end test uses the small committed fixture.

## 8. Risks and mitigations

- **Parity test against viralrecon flakes.** The Python script is not pinned upstream; nf-core could change it. Mitigation: pin to a specific commit SHA in CI, refresh annually.
- **iVar 1.5 ships with native VCF output.** If it does, this whole spec becomes legacy. Mitigation: the converter is one isolated file; a future commit can make it a fallback for old iVar and let new iVar emit VCF directly. Cost of writing the converter now is bounded; cost of waiting for an upstream that may never ship is unbounded.
- **Codon merge produces output that the variant browser cannot render.** Risk that a `MERGED_AF` field with multi-value semantics surprises the browser's parser. Mitigation: the integration test in section 4.4 opens both VCFs in a headless variant browser and asserts no parse warnings. If warnings appear, suppress codon merging in the primary VCF and put it in the `_all_hap.vcf` only, until the browser learns the field.
- **`bam adopt-mapping` collides with existing GUI behavior.** The GUI's Mapping wizard does its own attachment; if both code paths grow apart, the chapter's CLI flow and GUI flow may produce subtly different bundle states. Mitigation: both call `PreparedAlignmentAttachmentService` directly. A regression test asserts bundle-state equivalence.
- **SRA download for SRR36291587 stops working entirely.** ENA and the SRA Toolkit are both upstream services. If both go down, the chapter's first step fails. Mitigation: the chapter mentions this risk in `## Before you start` and points the reader at the committed reference + downstream artifacts so they can still follow the variant-calling half of the chapter against the small fixture.

## 9. Done criteria

- All four code changes (TSV-to-VCF converter with GFF passthrough, GUI dialog options, `bam adopt-mapping`, SRA fallback) are merged on main.
- All tests in section 4 are passing in CI.
- The chapter file at `docs/user-manual/chapters/04-variants/01-reads-to-variants.md` is committed, brand-reviewed, and lead-approved.
- The shotlist file is committed; the user has captured every shot; PNGs are committed under `docs/user-manual/assets/screenshots/04-variants/`.
- `docs/user-manual/index.md` and `docs/user-manual/chapters/04-variants/index.md` reflect the new chapter and the deletion of the two old chapters.
- One sentence in `CHANGELOG.md` calls out the new iVar VCF output and the new `bam adopt-mapping` command for users following older guides.

## 10. Known follow-ups

These items came out of the post-implementation code review. They are tracked here so they don't get lost, but they are deliberately out of scope for the chapter PR. None block merging the chapter.

### I4 — `bam adopt-mapping` hardcodes `sorted.bam` (resolved by `ec14ba65`)

The `Fix provenance gaps in reads-to-variants workflows` commit (ec14ba65) replaced the bare attach with a provenance-aware adoption path that records the source `mapping-provenance.json` from the mapping result directory and writes an `adopt-mapping-provenance.json` sidecar next to the adopted BAM. The hardcoded filenames remain because `lungfish map` always emits `sorted.bam` and `sorted.bam.bai`, and the producer-side contract is now also exercised by the new integration tests. If a future `lungfish map --output-name` flag ever ships, the next maintainer will need to plumb that through here as `--bam` / `--bai` overrides; nothing about today's surface forces the issue.

### I6 — `commandLine` for the iVar caller always shows `-g <missing>` (resolved by `ec14ba65`)

The placeholder `commandLine(...)` now consults `plannedIVarGFFURL(workingDirectory:)`, which inspects the bundle manifest's annotations and returns the planned GFF location when annotations exist (or `nil` when they do not). The recorded command line therefore reflects what the run actually does. The runtime path in `runCaller(...)` already used the resolved `gffURL`; this closes the symmetry on the placeholder side.

### Source line for produced VCFs now carries iVar and Lungfish versions

`ViralVariantCallingPipeline.runCaller(...)` builds the converter's `sourceLine` as `"iVar <version> (TSV-to-VCF: Lungfish <version>)"`, where the iVar version comes from `nativeToolVersion(for: .ivar)` and the Lungfish version from `WorkflowRun.currentAppVersion`. The parity test strips `##source=` lines before diffing against the Python reference, so this is invisible to that gate. Closes Suggestion 8 from the original review.

### I8+ — Suggestions from the review (non-blocking)

These are quality-of-life improvements that the review raised. They are listed here so the next person who touches the affected file has the context.

- **Consolidate the strand-bias filter math.** The Fisher one-sided greater path lives in `FisherExactTest.oneSidedGreaterPValue` and the production filter pre-computes a constant for the marginals. The two-sided variant could share that constant via a small private helper. Refactor only; no behavior change.
- **Tighten the `IVarTSVToVCFConverter.Options.gffMissingNote` plumbing.** Today the converter takes a `Bool` and emits a header note when true. A typed enum (`.gffPresent`, `.gffMissing(reason:)`) would make the call sites self-documenting and let the chapter regression test assert on the reason string. Cosmetic.
- **Stop logging `BundleManifest.load` failures at warning level for un-annotated bundles.** The new `exportBundleGFFIfAvailable` already special-cases the empty-annotations case and logs only on actual manifest-load failures, which is correct. If we observe noisy warnings in practice we should drop those to `debug`.
- **`SRAService.downloadFASTQWithFallback` could expose a typed event** rather than a `String` callback. Today the only consumer is the CLI. If the GUI's `OperationCenter` ever wants to render the fallback as a structured row note, a typed enum (`.attemptingENA`, `.fallingBackToToolkit(reason:)`) is more future-proof. The current string is enough for the chapter.
