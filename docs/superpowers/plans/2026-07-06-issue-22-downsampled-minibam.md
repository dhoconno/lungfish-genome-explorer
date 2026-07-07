# Issue #22 — TaxTriage Shows No miniBAMs / Unique Reads on Downsampled Data — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.
> **Read `docs/superpowers/specs/2026-07-06-weekly-issues-master-spec.md` first**, especially §1.7 (virtual FASTQ bundles / materialization) and §2.2.
> **DIAGNOSIS-FIRST plan.** Two competing root causes exist; Task 1 decides which. Do not pre-commit to a fix.

**Goal:** When TaxTriage (and other classifiers) run on a downsampled bundle, they produce miniBAMs and unique-read counts identical in kind to a full-dataset run.

**Architecture:** A downsampled bundle is a **virtual `.subset` bundle**: on disk it holds only `read-ids.txt` + `preview.fastq` (~1000 reads) + a derived manifest — NOT the full 100k reads. `FASTQBundle.resolvePrimaryFASTQURL` returns `preview.fastq` for such a bundle, which must never reach a classifier. The app is supposed to materialize the full downsampled FASTQ (reconstruct 100k reads from root + read-IDs) before running TaxTriage, via `resolveInputFiles` → `FASTQDerivativeService.shared.materializeDatasetFASTQ`. Research found the TaxTriage path DOES call `resolveInputFiles`, AND separately found that `TaxTriagePipeline.collectOutputFiles` has **no branch that harvests `.bam`/miniBAM/unique-read files**. So the bug is one of: **(H1)** materialization silently fails/returns preview for downsampled bundles, so TaxTriage runs on ~1000 reads and produces nothing meaningful; or **(H2)** materialization works and TaxTriage produces BAMs/unique-reads, but the output collector discards them. These have different fixes.

**Tech Stack:** Swift 6.2, Nextflow (TaxTriage runs `jhuapl-bio/taxtriage`), samtools, XCTest.

## Global Constraints

- Build/test/serialization/green-bar per master spec §1.3–§1.4.
- Materialized temp dirs cleaned via `defer`.
- OperationCenter `update` + `log` on the run.
- Commit trailer: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

## Acceptance criteria

1. A written finding identifying H1 vs H2 (or both) with evidence.
2. Running TaxTriage on a downsampled bundle produces miniBAMs and unique-read counts (visible in the TaxTriage result UI and collected artifacts), matching a full-dataset run in kind.
3. Regression test(s) covering the fixed path.
4. Suite is GREEN.

## Key files

- `Sources/LungfishIO/Formats/FASTQ/FASTQBundle.swift` (`resolvePrimaryFASTQURL` ~lines 89–104; preview filtering ~362–366; `fullPayloadFASTQURL` ~248–257; `isDerivedBundle` ~172–177)
- `Sources/LungfishIO/Formats/FASTQ/FASTQDerivativePayload.swift` (`.subset(readIDListFilename:)` ~lines 9–32; `isSubsetOperation` ~91–108)
- `Sources/LungfishApp/Services/FASTQDerivativeService+Materialization.swift` (`materializeDatasetFASTQ` ~lines 16–27)
- `Sources/LungfishWorkflow/Extraction/FASTQCLIMaterializer.swift` (subset materialization ~lines 44–212, `.subset` case ~188–212)
- `Sources/LungfishApp/App/AppDelegate+Classification.swift` (TaxTriage orchestration ~1391–1617; `resolveInputFiles` ~213–249; per-sample materialize loop ~1436–1461)
- `Sources/LungfishWorkflow/TaxTriage/TaxTriagePipeline.swift` (`collectOutputFiles` ~1125–1194 — NO bam branch; Nextflow launch ~336–350)
- `Sources/LungfishWorkflow/TaxTriage/TaxTriageConfig.swift` (`TaxTriageSample.fastq1/.fastq2` mutable)

---

### Task 1 (DIAGNOSIS — do before any fix): H1 vs H2

**Files:** read-only + a report. No production change.

- [ ] **Step 1: Create a downsampled bundle from a fixture.** In the app (or via CLI), import a FASTQ dataset large enough to downsample (or synthesize one by concatenating the SARS-CoV-2 fixture reads many times to exceed the downsample target), then run the downsample operation to produce a `.subset` bundle. Confirm on disk it contains `read-ids.txt` + `preview.fastq` + derived manifest (i.e. it is virtual).

- [ ] **Step 2: Test materialization directly (settles H1).** Call the materialization path on that downsampled bundle and inspect the produced FASTQ's read count with `seqkit stats -T`. Either:
  - Via a unit/integration test that calls `FASTQDerivativeService.shared.materializeDatasetFASTQ(fromBundle:tempDirectory:progress:)` (app-layer) or `FASTQCLIMaterializer.materialize(bundleURL:tempDirectory:progress:)` (workflow-layer) on the downsampled bundle and asserts the output has the full downsampled count (e.g. 100k), NOT ~1000.
  - If the count is ~1000 (preview) → **H1 confirmed** (materialization is returning/using preview for downsampled bundles). If the count is the full downsampled number → **H1 rejected**, materialization works.

- [ ] **Step 3: Test output collection (settles H2).** Run TaxTriage on the downsampled bundle end to end (debug app or CLI). After the Nextflow run, `find` the TaxTriage output directory for `*.bam` and unique-read/"tass"/metrics files. If BAMs exist on disk but the TaxTriage result object has no miniBAMs → **H2 confirmed** (`collectOutputFiles` discards them). Cross-check by reading `collectOutputFiles` (~1125–1194): confirm there is no `ext == "bam"` branch and no unique-read harvesting.

- [ ] **Step 4: Compare with a full-dataset run.** Run TaxTriage on the SAME reads as a **full** (non-downsampled) bundle. Do miniBAMs/unique-reads appear then? If they appear for full but not downsampled AND materialization is correct (H1 rejected), the divergence is downstream of materialization — likely the TaxTriage samplesheet/args differ for the two, or the Nextflow pipeline skips BAM generation below a read-count threshold. Record which.

- [ ] **Step 5: Write the finding.** Create `docs/reports/2026-07-06-downsampled-minibam-diagnosis.md` recording the materialized read count, whether BAMs exist on disk, whether the collector harvests them, and the confirmed hypothesis (H1, H2, or both). Recommend the matching Task 2 option. Commit `docs: diagnose downsampled miniBAM gap (issue #22)`.

---

### Task 2A: Fix materialization for downsampled bundles (if H1)

**Files:** `Sources/LungfishApp/Services/FASTQDerivativeService+Materialization.swift`, `Sources/LungfishWorkflow/Extraction/FASTQCLIMaterializer.swift`, and the TaxTriage input-resolution loop in `AppDelegate+Classification.swift`.

**Interfaces:**
- Consumes: `FASTQDerivativePayload.subset(readIDListFilename:)`; the derived manifest.
- Produces: `materializeDatasetFASTQ` reconstructs the full downsampled FASTQ (all read-IDs in `read-ids.txt`), never the preview.

- [ ] **Step 1: Write the failing test.** In `Tests/LungfishWorkflowTests/FASTQCLIMaterializerTests.swift` (create/extend): build a small root bundle with N reads, create a `.subset` bundle selecting a known K < N of them, materialize it, and assert the output has exactly K reads (paired: K pairs). This will FAIL if the code path uses preview or mis-resolves the read-ID list.

```swift
func testSubsetBundleMaterializesFullSelectedReadsNotPreview() async throws {
    // Arrange: root bundle with 50 reads; subset selecting 20 by ID.
    // Act: materialize the subset bundle.
    // Assert: seqkit/stats on output == 20 reads (NOT the ~1000 preview count,
    // and NOT the full 50).
}
```
(Flesh out arrange/act using the existing materializer test helpers in the file; if none exist, construct the bundle on disk in a temp dir using `FASTQDerivativeService` subset creation.)

- [ ] **Step 2: Run — expect FAIL** (materialized count wrong).

- [ ] **Step 3: Fix.** In the `.subset` case of `FASTQCLIMaterializer` (and/or `materializeDatasetFASTQ`), ensure it (a) resolves the ROOT full FASTQ (not the subset bundle's preview), (b) filters it by the subset's `read-ids.txt`, and (c) writes all selected reads. Make sure the app-side `resolveInputFiles` loop in `AppDelegate+Classification.swift` (~1436–1461) substitutes the materialized URL into `resolvedConfig.samples[i].fastq1/.fastq2` and that the materialized path — not `preview.fastq` — is what TaxTriage receives. Guard against `resolvePrimaryFASTQURL` returning preview by routing downsampled/derived bundles through materialization explicitly (check `FASTQBundle.isDerivedBundle`).

- [ ] **Step 4: Run — expect PASS.**

- [ ] **Step 5: Commit** `fix(taxtriage): materialize full downsampled reads before classification`.

---

### Task 2B: Harvest miniBAMs and unique reads in the collector (if H2)

**Files:** `Sources/LungfishWorkflow/TaxTriage/TaxTriagePipeline.swift` (`collectOutputFiles` ~1125–1194); `TaxTriageResult` struct.

**Interfaces:**
- Consumes: files discovered under `config.outputDirectory`.
- Produces: `TaxTriageResult` gains collected `bamFiles: [URL]` (miniBAMs) and unique-read artifacts, surfaced to the UI the same way a full run's are.

- [ ] **Step 1: Write the failing test.** In `Tests/LungfishWorkflowTests/TaxTriageOutputCollectionTests.swift` (create): create a temp dir mimicking a TaxTriage output tree containing a `*.bam` (and its `.bai`) and a unique-reads TSV; call the collection/categorization function; assert the result includes the BAM in a `bamFiles`/miniBAM collection and the unique-reads file. This FAILS because no bam branch exists.

- [ ] **Step 2: Run — expect FAIL.**

- [ ] **Step 3: Fix.** Add a `.bam` (and `.bai`) branch to the file categorization loop in `collectOutputFiles`, and a unique-reads branch (match the filename pattern TaxTriage uses — confirm the exact pattern from Task 1 Step 3's `find`). Add the collected fields to `TaxTriageResult`. Wire them to the same UI surface a full run uses (the TaxTriage result view in `LungfishTaxTriageUI`). Ensure the `TaxTriageOutputArtifactPolicy.filterRetainedOutputFiles` does not strip BAMs (check that policy; if it whitelists extensions, add bam/bai).

- [ ] **Step 4: Run — expect PASS.**

- [ ] **Step 5: GUI verification.** Run TaxTriage on a downsampled bundle in `.build/debug/Lungfish` via computer-use; confirm miniBAMs and unique-read counts now appear in the TaxTriage result view. Screenshot.

- [ ] **Step 6: Commit** `fix(taxtriage): collect miniBAM and unique-read outputs`.

---

### Task 2C: Pipeline-threshold or samplesheet parity (if Task 1 Step 4 found divergence)

- [ ] If full runs produce BAMs but downsampled do not, and materialization + collection are both correct, inspect the Nextflow launch args / samplesheet built for each (`buildNextflowLaunchArguments`, samplesheet construction). Ensure the downsampled run passes identical BAM-generating flags. If the upstream `jhuapl-bio/taxtriage` pipeline gates miniBAM generation on a read-count or a specific flag, set that flag for all runs. Add an assertion test on the built argument vector that the miniBAM/alignment flag is present regardless of dataset size. Commit `fix(taxtriage): request alignment outputs for downsampled runs`.

---

### Final verification

- [ ] Diagnosis report committed, referenced in issue #22.
- [ ] `swift build/test --package-path <worktree> --skip-update` → clean + GREEN.
- [ ] Downsampled TaxTriage run now shows miniBAMs + unique reads (screenshot in issue #22).
- [ ] Sanity: a full-dataset TaxTriage run still works (no regression from collector/materializer changes).

## Self-review checklist

- Spec coverage: diagnosis (Task 1), the three mutually-exclusive fix options keyed to the finding (2A/2B/2C) → criteria mapped.
- No placeholders: each option has a concrete failing test and a specific fix location.
- Type consistency: new `TaxTriageResult` fields (`bamFiles`, unique-reads) named once and used consistently in collector + UI.
- Materialization must never feed `preview.fastq` to a classifier (master spec §1.7) — verified in Task 2A Step 3.
