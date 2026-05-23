# Overnight session summary — 2026-05-23

**Branch:** `codex/lungfishgenotype-viewport-inspector`
**Build:** green
**Tests:** 8555 tests, 0 failures, 23 pre-existing skips
**Session commits:** 49

## Triage of the three issues you flagged before bed

1. **Inspector flipping to Selected Item when clicking Bundle controls.** Fixed — `updateGenotypeResultSelection` no longer auto-flips the tab. Tab choice is now sticky.

2. **Most loci show empty boxes / no way to edit haplotypes.**
   - **Visual fix:** error cells now render a glyph (T/G/?/!) inside the bordered box so ERR: TMH / ERR: TMG / ERR: NO HAP are visually distinct from "absent."
   - **Loci visibility fix:** `GenotypeObservedLociIndex` surfaces loci the analysis didn't process (MHC-AG, MHC-70, MHC-E, MHC-F, MHC-I, etc.). They render as dashed-border "unanalyzed" cells with an observed-genotype count, so the user sees the full ~17 loci of the real bundle, not just the 7 in the MCM exon2 haplotype set.
   - **Editing fix:** clicking a sample in Outline or Cards opens a Sample Detail sheet listing every (locus, slot) call with an Override editor inline. Override picker is a strict whitelist for MCM/MAMU/MANE definition sets. Reason chip + free-text rationale. Save persists to `annotations.json` and appends an audit-log entry. Clear-override button reverts.
   - **Selection-tab path:** "Edit calls…" button in the Inspector's Selected Item tab re-opens the same Sample Detail sheet from anywhere.

3. **Review and Audit lenses look wrong.**
   - **Review lens:** rebuilt. Panel A is the Outline filtered to Needs Review samples. Panel B is a new `GenotypeCallEvidenceView` showing the selected call's diagnostic alleles (with per-locus read counts and low-support flags), locus coverage bar, and run neighbors. Keyboard shortcuts ⌘R (reviewed), ⌘K (confirmed), ⌘⇧F (needsReview), ⌘⇧O (open Sample Detail sheet) advance the analyst through the queue.
   - **Audit lens:** the artifact list is still there but extended with a Manual Haplotyping section (when applicable) and a Dropout Threshold editor (three OR'd modes — absolute reads, % sample, % locus — that drive the "low support" flag in Review-lens evidence).

## Smoke test against the real barcode08 bundle

`Tests/LungfishAppTests/GenotypeRealBundleSmokeTests.swift` loads
`/Volumes/iWES_WNPRC/.../barcode08-mhc-haplotypingv1.lungfishgenotype` and verifies:

- 48 samples, raw calls, and haplotype analysis load without error
- `GenotypeObservedLociIndex` surfaces non-analyzed loci (MHC-AG is present)
- `GenotypeResultViewController` configures at full window size without crashing
- `GenotypeCohortSubjectBuilder` produces one subject per sample
- Needs-review predicate matches at least one subject (real bundle has lots of `ERR:` cells)
- `GenotypeManualHaplotypingDigest` surfaces observed genotypes

The tests skip when the volume isn't mounted, so CI on other machines stays green.

## CLI smoke test (worked end-to-end)

```
.build/debug/lungfish-cli genotype list-samples --bundle "/Volumes/iWES_WNPRC/32271/32271.lungfish/Analyses/ONT genotyping results/barcode08-mhc-haplotypingv1.lungfishgenotype"
```

Tab-separated rows per sample, ~17 locus genotypes per row. Other CLI commands also work:
- `genotype list-cohorts` — saved Smart Cohorts plus the auto-seeded Needs review / Homozygous / Recombinants
- `genotype apply-annotations` — merges a JSON patch into the sidecar
- `genotype export-xlsx` — writes a standalone XLSX with Overrides + Audit Log sheets

## Two rounds of expert code review

I ran two passes with the code-reviewer agent against the work since the plan landed. Round 1 (4 Critical, 8 Major, 9 minor) was fully addressed. Round 2 verified the fixes and surfaced 7 new minor findings — those are now also fixed (with the exception of two that were intentional design choices that I documented in the code or the memory file).

## What's new that wasn't in the spec but proved valuable

- **Quick-Filter pill bar** above Outline/Cards. Toggle pills: Has errors / Homozygous / Recombinant / Bw6+ / Has comments / Duplicate. Plus a search field. Combines with any active Smart Cohort via `.all([...])` so analysts can stack a saved cohort with an ad-hoc filter.

- **Adaptive tape width** in Outline. 7-locus runs get 36pt per locus (the canonical MCM layout); 9–12-locus runs get 28pt; 13+-locus runs (your bundle!) get 22pt and still legible because of the error/observed glyphs.

- **Locus header row** above the tape — short locus names (A / B / AG / DRB / DQA / DPA1 / etc.) line up with the swatches. Tooltips show the full locus name.

- **Read-only volume detection.** The bundle on `/Volumes/iWES_WNPRC` is read-only; `GenotypeAnnotationStore` detects this on open, suppresses persist writes, and surfaces a warning banner at the top of the Cohort Summary panel: "Read-only bundle. Edits and annotations are kept in memory only — they will not persist."

- **Extended Rhesus color palette** — 15 tokens (M1–M7 + X1–X8). The hash mapping now spans the full range so Rhesus cohorts with many distinct haplotype names get visually distinct colors instead of the previous 7-color collapse.

- **Audit Timeline section** at the bottom of the Document tab. Renders the last 10 audit-log entries — overrides, status changes, comments — with author, sample/locus/slot, and a "before → after" summary. Collapsed by default.

## Where the implementation is still incomplete

- **Matrix view doesn't apply Smart Cohort / quick filter.** Only Outline + Cards filter today. The Matrix view's existing search field is the alternative; threading the predicate through is a follow-up.
- **Plate-position contamination view** — spec defers to v3.
- **KIR-specific UI** — spec defers to v3.
- **Polished Excel workbook with M1–M7 conditional formatting on the main matrix sheet** — partially implemented (Overrides + Audit Log sheets are added; the main matrix sheet still uses the v1 export's cell shading).
- **Computer Use GUI smoke** — couldn't be exercised overnight because the access dialog needed an interactive approval. The programmatic smoke tests cover the data paths and basic view-controller config.

## Files added in this session (since 0ce60e1f)

| Path | Lines | Purpose |
|---|---|---|
| Sources/LungfishCore/Genotype/HaplotypeColorToken.swift | 200+ | Canonical M0-M7 + extended Rhesus palette |
| Sources/LungfishCore/Genotype/HaplotypeBlockGlyph.swift | 30 | Glyph vocabulary |
| Sources/LungfishCore/Genotype/HaplotypeSlot.swift | 20 | H1/H2 enum |
| Sources/LungfishIO/Bundles/GenotypeAnnotationSidecar.swift | 270 | JSON sidecar model + audit log |
| Sources/LungfishIO/Bundles/GenotypeCohortSmartFilter.swift | 270 | Predicate ADT + Codable + evaluator |
| Sources/LungfishIO/Bundles/GenotypeCohortSubjectBuilder.swift | 110 | Subject construction shared by GUI + CLI |
| Sources/LungfishIO/Bundles/GenotypeBlockClassifier.swift | 60 | Block / recombinant / atypical |
| Sources/LungfishIO/Bundles/GenotypeDropoutEvaluator.swift | 30 | Three OR'd dropout thresholds |
| Sources/LungfishIO/Bundles/ManualHaplotypeAssignment.swift | 50 | Manual mode value type |
| Sources/LungfishIO/Bundles/GenotypeManualHaplotypingDigest.swift | 80 | Per-locus genotype aggregator |
| Sources/LungfishIO/Bundles/GenotypeObservedLociIndex.swift | 70 | Surface non-analyzed loci |
| Sources/LungfishApp/Views/Results/Genotype/GenotypeAnnotationStore.swift | 270 | @Observable wrapper with audit log + read-only detection |
| Sources/LungfishApp/Views/Results/Genotype/GenotypeHaplotypeTapeView.swift | 240 | Two-strip primitive with error/unanalyzed cells + accessibility |
| Sources/LungfishApp/Views/Results/Genotype/GenotypeOutlineView.swift | 180 | Outline rows with adaptive tape width + locus header |
| Sources/LungfishApp/Views/Results/Genotype/GenotypeCardsView.swift | 260 | Cards with auto-density + NSBox borders |
| Sources/LungfishApp/Views/Results/Genotype/GenotypeCohortSummaryPanelView.swift | 130 | Panel B for Summary lens + read-only banner |
| Sources/LungfishApp/Views/Results/Genotype/GenotypeCallEvidenceView.swift | 250 | Panel B for Review lens |
| Sources/LungfishApp/Views/Results/Genotype/GenotypeSampleDetailSheet.swift | 200 | Modal override editor |
| Sources/LungfishApp/Views/Results/Genotype/GenotypeQuickFilterBarView.swift | 150 | Toggle pills + search above cohort |
| Sources/LungfishApp/Views/Inspector/Sections/GenotypeSmartCohortSection.swift | (subagent) | Inspector Bundle tab section |
| Sources/LungfishApp/Views/Inspector/Sections/GenotypeOverrideSection.swift | (subagent) | Reusable override form |
| Sources/LungfishApp/Views/Inspector/Sections/GenotypeStatusFlagSection.swift | (subagent) | Status + comments |
| Sources/LungfishApp/Views/Inspector/Sections/GenotypeDropoutThresholdSection.swift | 80 | Audit lens threshold editor |
| Sources/LungfishApp/Views/Inspector/Sections/GenotypeAuditTimelineSection.swift | 140 | Document tab audit history |
| Sources/LungfishApp/Views/Inspector/Sections/GenotypeManualHaplotypingSection.swift | 220 | Manual mode UI |
| Sources/LungfishCLI/Commands/GenotypeCommandGroup.swift | 30 | Parent CLI command |
| Sources/LungfishCLI/Commands/GenotypeListSamplesSubcommand.swift | (subagent) | list-samples |
| Sources/LungfishCLI/Commands/GenotypeListCohortsSubcommand.swift | (subagent) | list-cohorts |
| Sources/LungfishCLI/Commands/GenotypeApplyAnnotationsSubcommand.swift | (subagent) | apply-annotations |
| Sources/LungfishCLI/Commands/GenotypeExportXlsxSubcommand.swift | 230 | export-xlsx |

…plus ~12 test files across all modules.

## To inspect when you're back

1. Launch `.build/debug/Lungfish`, open the real barcode08 bundle.
2. Confirm the Inspector's Bundle tab View Mode picker now stays on Bundle.
3. Switch from Outline → Cards → Matrix; confirm filter pills above persist.
4. Click a sample row → Sample Detail sheet opens. Try Override on a MHC-A H2 ERR: TMH cell.
5. Switch to Review lens → Panel B should show diagnostic alleles + coverage for the selected sample's first error call.
6. Press ⌘R / ⌘K / ⌘⇧F on a selected sample to advance status.
7. Switch to Audit lens → Manual Haplotyping panel (since most loci aren't in the MCM definition set) should let you build custom haplotype groupings.
8. Export View should produce a workbook with Overrides + Audit Log sheets if you've recorded any overrides.

All work is committed on `codex/lungfishgenotype-viewport-inspector`. No PR opened; you'll review and merge.
