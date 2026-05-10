# "From Reads to Variants" Chapter Artifacts — Design Spec

**Date:** 2026-04-24
**Status:** Draft for review
**Scope:** Spec 3 of 3 in the "From reads to variants" documentation program
**Related specs:** Spec 1 (`2026-04-24-repo-rename-lungfish-genome-explorer-design.md`), Spec 2 (`2026-04-24-bam-primer-trim-and-primer-scheme-bundles-design.md`)

---

## 1. Context

The Lungfish User Manual's pilot chapter, `docs/user-manual/chapters/04-variants/01-reading-a-vcf.md`, teaches the reader how to read a VCF that has been handed to them. It was written under the constraint that Lungfish did not yet support mapping or variant calling in-app. Both now exist. The pilot will be retired and replaced with a single functional-use-case chapter that walks the reader end-to-end from obtaining sequencing reads to reading the variants they produced themselves.

The chapter's target fixture workflow is:

1. Download the SARS-CoV-2 reference from NCBI, in-app.
2. Download paired-end QIASeq Direct amplicon reads from SRA (`SRR36291587`), in-app.
3. Import (or select the built-in) QIASeq Direct primer scheme.
4. Map the reads to the reference with minimap2.
5. Primer-trim the resulting BAM using `ivar trim` and the QIASeq scheme.
6. Call variants with iVar and separately with LoFreq, to produce two VCFs over the same reference.
7. Open both VCFs in the variant browser side-by-side and interpret the agreement and disagreement between the callers.

Steps 5 and 6 (for iVar) depend on Spec 2 landing. Steps 1, 2, 3 (for un-bundled BED import), 4, and 6 (for LoFreq) work in the shipped app today. This spec defines the preparation of the documentation fixture project so that, when Spec 2 merges, the chapter can be written against real, verified artifacts with no open questions about tool behavior.

This spec is strictly preparation. It does not produce chapter prose or screenshots.

## 2. Goals and non-goals

### Goals

- Populate `/Users/dho/Downloads/Lungfish Docs.lungfish` with the real artifacts the chapter will reference: reference FASTA bundle, SRA reads bundle, (interim) primer BED, mapped BAM, LoFreq VCF.
- After Spec 2 merges, extend the populated project with the primer-trimmed BAM and the iVar VCF.
- Verify every step of the workflow end-to-end against the shipped app build at `build/Release/Lungfish.app` (path relative to the repository root, which is renamed to `lungfish-genome-explorer` by Spec 1).
- Capture prep notes (`TRACK2-PREP-NOTES.md` inside the project folder) recording exact menu paths, UI quirks, surprises, and any app bugs surfaced.
- Snapshot the verified project into a version-controlled fixture location once stable.

### Non-goals

- Writing the chapter's prose. That's the Bioinformatics Educator's work, downstream.
- Capturing screenshots. Screenshot Scout's work, downstream.
- Automating the workflow for CI replay. The project itself is the artifact.
- Packaging the fixture for distribution (the Screenshot Scout later creates replayable recipes; this spec doesn't).

## 3. The fixture project

Location during prep: `/Users/dho/Downloads/Lungfish Docs.lungfish`.

The project folder, once fully populated, contains:

```
Lungfish Docs.lungfish/
  metadata.json
  Downloads/
    MN908947.3.lungfishref/                  # reference downloaded from NCBI
    SRR36291587.lungfishfastq/               # reads downloaded from SRA
  Primer Schemes/                            # populated after Spec 2 merges
    QIASeqDIRECT-SARS2.lungfishprimers/      # copied from built-in
  Analyses/
    SRR36291587.minimap2.lungfishmapping/
    SRR36291587.primertrim.lungfishmapping/  # populated after Spec 2 merges
    SRR36291587.lofreq.lungfishvariants/
    SRR36291587.ivar.lungfishvariants/       # populated after Spec 2 merges
  TRACK2-PREP-NOTES.md
```

The reference lives in `Downloads/` because that's where the app persists NCBI downloads; no separate copy in `Reference Sequences/` is made in Phase A. If the app's Mapping wizard requires the reference to live under `Reference Sequences/` specifically, Track 2 notes that and performs whatever copy or import the UI surfaces.

## 4. Two phases

Track 2 runs in two phases, separated by Spec 2's merge.

### 4.1 Phase A (pre-merge, starts immediately)

What can be done against the shipped app today, without waiting on Spec 2:

1. **Download reference.** In-app, File → Download from NCBI → `MN908947.3`. Verify it lands in `Downloads/` as a `.lungfishref` bundle. Record in notes: which accession form the app persists, whether both `MN908947.3` and `NC_045512.2` aliases are recorded, how the bundle's display name is formatted.
2. **Download reads.** In-app, via SRA search/import (SRA accession `SRR36291587`). Verify it lands as a paired `.lungfishfastq` bundle with 85,199 read pairs and intact pairing. Record in notes: exact UI flow, download time range, any caching behavior.
3. **Mapping.** In-app, run the Mapping wizard with reads = `SRR36291587`, reference = `MN908947.3`, mapper = minimap2. Pick the preset appropriate to Illumina short reads. Verify: output is a `.lungfishmapping` bundle in `Analyses/`, BAM is sorted and indexed, coverage is sane across the genome (spot-check at the 5', middle, and 3' ends of the reference), provenance records reads + reference + tool + version.
4. **LoFreq variant call.** In-app, run the Variant Calling dialog against the mapped BAM, picker = LoFreq. Verify: VCF lands in `Analyses/` as `SRR36291587.lofreq.lungfishvariants`, variant browser opens it, provenance chain is intact from reads → BAM → VCF.
5. **Prep notes.** Populate `TRACK2-PREP-NOTES.md` with everything observed: menu paths, wait times, UI quirks, any errors or confusing states. This file is the chapter author's primary source for procedural accuracy.

Phase A does not involve a primer BED at all: mapping runs against the un-trimmed reads, and LoFreq does not require primer-trimmed input. The primer scheme enters the workflow only in Phase B, once Spec 2's built-in bundle ships.

Phase A's "done" state: reads and reference downloaded, un-trimmed BAM mapped, LoFreq VCF called, notes written. At this point the only steps the chapter will cover that are not yet runnable are primer-trim and iVar call.

### 4.2 Phase B (post-Spec-2-merge)

Starts when Spec 2 merges to `main` and the canonical `QIASeqDIRECT-SARS2.lungfishprimers` bundle is shipped built-in.

1. **Select the built-in primer scheme.** In-app, from the BAM primer-trim dialog, pick the built-in `QIASeqDIRECT-SARS2` scheme. Verify the dialog copies it into the project's `Primer Schemes/` folder or references it in place, per whatever mechanism Spec 2 settles on.
2. **Primer-trim BAM.** Run the new Primer-trim BAM operation against the un-trimmed mapping bundle using the QIASeq scheme. Verify: output BAM is sorted, indexed, and carries the expected provenance metadata (`operation: primer-trim`, scheme name, ivar_trim args, timestamp).
3. **iVar variant call.** Run Variant Calling against the primer-trimmed BAM, picker = iVar. Verify: the `ivarPrimerTrimConfirmed` checkbox is auto-checked-and-disabled with the expected caption. VCF lands in `Analyses/`.
4. **Cross-caller comparison.** Open both `SRR36291587.ivar.lungfishvariants` and `SRR36291587.lofreq.lungfishvariants` in the variant browser over the same reference. Note: concordant sites (both callers flag), iVar-exclusive sites, LoFreq-exclusive sites. This disagreement is the teaching moment of the chapter; the prep notes capture what it looks like concretely.
5. **Update prep notes.** Append Phase B observations. The notes now cover the full workflow.
6. **Snapshot.** Copy the verified project into a version-controlled location: `docs/user-manual/fixtures/reads-to-variants-project/`. This is the fixture the chapter will reference and the Screenshot Scout will replay from.

## 5. Verification checklists

### 5.1 Phase A done

- [ ] `Downloads/MN908947.3.lungfishref/` exists, opens in Lungfish without error, displays the expected 29,903-bp sequence.
- [ ] `Downloads/SRR36291587.lungfishfastq/` exists, shows 85,199 read pairs in the inspector, reads are paired-end.
- [ ] `Analyses/SRR36291587.minimap2.lungfishmapping/` exists, BAM is sorted and indexed (sanity-check via inspector), coverage is present across the genome.
- [ ] `Analyses/SRR36291587.lofreq.lungfishvariants/` exists, VCF opens in the variant browser over the `MN908947.3` reference.
- [ ] `TRACK2-PREP-NOTES.md` contains Phase A observations: menu paths, UI quirks, surprises.

### 5.2 Phase B done

- [ ] `Primer Schemes/QIASeqDIRECT-SARS2.lungfishprimers/` is present (mechanism per Spec 2).
- [ ] `Analyses/SRR36291587.primertrim.lungfishmapping/` exists, BAM is sorted and indexed, provenance sidecar records the primer-trim operation.
- [ ] `Analyses/SRR36291587.ivar.lungfishvariants/` exists; the Variant Calling dialog's auto-confirm checkbox behaved as expected.
- [ ] Both VCFs open side-by-side in the variant browser over the same reference without conflict.
- [ ] `TRACK2-PREP-NOTES.md` has been extended with Phase B observations and a summary of where the two callers agreed and disagreed.
- [ ] Project snapshotted to `docs/user-manual/fixtures/reads-to-variants-project/`.

## 6. Worktree strategy

The user has reported that the previous "cannot run app from worktree due to missing JRE dylibs" restriction has been fixed. As the first step of Track 2, verify this by running one Java-backed tool (e.g., Clumpify or a BBTools operation) from within the Track 2 worktree and confirming it works. If verified, Track 2 runs entirely in a worktree (`track2-docs-artifacts`). If not, escalate to the user and fall back to running in the main repo with appropriate safeguards.

The app used for Track 2 verification is the shipped Release build, not a worktree-local build, so the restriction may not apply in practice even if the repair turns out to be incomplete. The worktree is used primarily for writing prep notes, committing the project snapshot, and any supporting scripts; the app launches against its own installed Resources regardless of which directory the shell is in.

## 7. Risks

- **SRA reachability.** SRA can be slow or transiently unavailable. Retry policy: fail with a clear error rather than fall back silently. If SRA is truly down, pause Track 2 and resume when it recovers.
- **SRR36291587 download size surprises.** The SRA page reports 21.7 MB, but actual on-disk size after fastq-dump can be several times that. Budget disk space accordingly.
- **Mapping preset mismatch.** The Mapping wizard may default to a preset (`sr`, `map-ont`, `map-pb`) that isn't ideal for Illumina short reads from an amplicon panel. Test: run once with the default, once with an explicit Illumina-short preset if the default doesn't produce sane coverage. Record the preferred choice in prep notes.
- **App UI changes between Phase A and Phase B.** Spec 2's work may alter dialogs the chapter will screenshot. If a Phase A artifact becomes visually stale by Phase B (e.g., the variant calling dialog's checkbox section gets a new caption), Phase B re-captures the relevant notes.
- **Project snapshotting churn.** The `Lungfish Docs.lungfish` folder is in `~/Downloads/`; moving it into the repo as a fixture means binary files (FASTQ, BAM, VCF) land in git. Use Git LFS if the repo already uses it; otherwise, decide per-artifact whether to commit the file or include a short script that re-derives it on demand. The mapping BAM and both VCFs are small (< 10 MB combined for this fixture); the reads are 21.7 MB compressed. The reference is < 100 KB. Recommendation: commit the reference and VCFs directly; script the reads download and mapping so that a fresh checkout can regenerate them deterministically. Final decision deferred to Phase B snapshot time.

## 8. What Track 2 deliberately does not produce

- Chapter prose.
- Screenshots.
- Replayable screenshot recipes.
- Automated CI jobs that re-run the workflow.

Those are the downstream work of the Bioinformatics Educator, the Screenshot Scout, and the Documentation Lead, respectively. Track 2 produces the artifact substrate they depend on.

## 9. "Done" criteria

### 9.1 For Phase A

- Every checkbox in §5.1 is ticked.
- `TRACK2-PREP-NOTES.md` is committed to the worktree (even though the project folder itself is not yet in the repo).

### 9.2 For Phase B

- Every checkbox in §5.2 is ticked.
- `TRACK2-PREP-NOTES.md` is updated and committed.
- The project snapshot exists at `docs/user-manual/fixtures/reads-to-variants-project/` or an equivalent location, per the §7 snapshotting decision.

### 9.3 For the track as a whole

- The chapter author has a verified, reproducible project to write against.
- Every step the chapter will describe has been exercised against the shipped app and documented.

## 10. Deliverables

- Prep notes: `TRACK2-PREP-NOTES.md` inside the `Lungfish Docs.lungfish` project.
- A Phase A commit in the worktree recording Phase A completion (the notes, plus any supporting scripts).
- A Phase B commit in the worktree recording Phase B completion and the snapshot.
- No new app code (if any app bugs are surfaced during prep, they are logged as separate tickets, not fixed in Track 2).
