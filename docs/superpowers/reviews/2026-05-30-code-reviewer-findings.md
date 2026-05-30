# Code Reviewer Findings — Swift/AppKit Engineering (Correctness & Concurrency)

**Reviewer lens:** correctness bugs, concurrency hazards, error handling, force-unwraps,
`%s`/`String(format:)` traps, MainActor/GCD dispatch discipline, `Sendable`, provenance integrity.
**Date:** 2026-05-30 · **Branch:** `codex/12s-amplicon-matching`

> Persisted by the orchestrator from the code-reviewer agent's returned findings (the
> code-reviewer agent type is read-only and could not write this file itself). Content is the
> agent's verbatim report.

## Summary

Counts: **1 P0**, **4 P1**, **4 P2**.

Overall correctness/concurrency health is **high**. Both workflows are written in idiomatic
strict-concurrency Swift 6.2. The dangerous patterns the brief warns about are largely absent:
- **No `%s`-with-Swift-String SIGSEGV bugs.** Every `String(format:)` with a string argument uses
  `%@` (e.g. `FastqTwelveSMatchSubcommand.swift:142`, `FastqTwelveSReferenceBundleSubcommand.swift:79`);
  numeric formats use `%d`/`%.6f`/`%02x` correctly.
- **MainActor/GCD dispatch discipline is followed.** The one background→UI path scrutinized
  closely (`ViewerViewController+TwelveS.swift:64-128`) uses the prescribed `Task.detached` +
  `DispatchQueue.main.async { MainActor.assumeIsolated { ... } }` idiom verbatim, with
  `nonisolated static` helpers. All `Task { @MainActor in }` occurrences in scope are spawned from
  already-`@MainActor` controllers (legal).
- **Provenance is thorough.** Every data-writing path writes a canonical `.lungfish-provenance.json`
  via `ProvenanceWriter`, and the GUI execution service shells out to `lungfish-cli` and verifies
  provenance after each run, calling both `OperationCenter.start/log/updateWithLog/complete`
  (`WorkflowOperationExecutionService.swift:217-282`, `285-363`).
- **Force-unwraps are safe** (`classifier.swift:276` short-circuit-guarded;
  `TwelveSResultExportWorkflow.swift:721` range-bounded A-Z scalar).

**12S surface:** clean for this lens except the cross-workflow filter divergence (P1) and minor
maintainability items (P2). The classifier's rolling-hash exact-match and indel-only alignment are
bounds-correct; result-bundle TSV parsing has proper typed error handling.

**MHC genotyping surface:** one genuine **P0 data-loss / per-sample-isolation hazard in the
multi-bundle Illumina batch path** (sample-ID collision), plus a batch-provenance labeling gap (P1)
and the same filter divergence (P1).

## Findings

| ID | Severity | Surface | Location (file:line) | Problem | Evidence | Suggested fix | Effort |
|----|----------|---------|----------------------|---------|----------|-------------|--------|
| CR-01 | **P0** | MHC | `Sources/LungfishWorkflow/ONTGenotyping/ONTBarcodeDemuxGenotypingPipeline.swift:832-866` (`resolveIlluminaSampleInputs`) | In the simultaneous multi-bundle Illumina batch path, per-input sample IDs are derived by `sampleID(from:)` (lines 892-901), which collapses every run of non-alphanumeric characters to a single `_`/`-`. Two distinct input bundles can sanitize to the **same** sample ID, with no dedup/uniquing. The collision (a) overwrites the staged FASTQ (data loss), (b) creates duplicate rows/keys in the sample-definitions CSV and manifest, and (c) makes the Python `query-prefix` assignment merge two samples' reads into one, destroying per-sample isolation. | `prefixedFASTQURL` is `"\(safeFilenameStem(sampleID)).sample-prefixed.fastq"` (line 850-851) — identical for colliding IDs, so the second `writeSamplePrefixedFASTQ` (line 868) overwrites the first. The manifest `samples` array (807-815) and definitions CSV (801-802) get duplicate `sample` entries; `assign_query_prefix` (2199-2205) keys solely on the prefix, so reads from both bundles collapse into one sample's counts. e.g. `Hilo-A.lungfishfastq` and `Hilo_A.lungfishfastq` both → `Hilo_A`. | Detect duplicate sanitized sample IDs and either throw a clear error or disambiguate by appending the source-bundle stem / an index. Make `prefixedFASTQURL` unique per source URL (e.g. include a hash of `url.path`). Validate unique `samples` before writing the manifest. | M |
| CR-02 | P1 | cross-cutting | `Sources/LungfishApp/Services/WorkflowLibrary.swift:227-230` | `WorkflowLibraryEnablementStore.defaultEnabledWorkflowIDs` includes `twelveSAmpliconMatchingID`, so 12S is enabled by default. Product intent is opt-in. | `defaultEnabledWorkflowIDs: Set<String> = [ FASTQOperationToolID.ontGenotyping.rawValue, WorkflowLibraryCatalog.twelveSAmpliconMatchingID ]` (227-230); `loadEnabledWorkflowIDs` returns this set on first launch (377-382). | Remove `twelveSAmpliconMatchingID` from `defaultEnabledWorkflowIDs`. | S |
| CR-03 | P1 | cross-cutting | `Sources/LungfishApp/Views/Results/Genotype/GenotypeResultViewController.swift:2493,2506`; `GenotypeCohortSummaryPanelView.swift:14-15,99-102`; vs 12S `TwelveSResultDisplaySection`→`TwelveSResultDisplayState` | Same intent ("suppress/flag low-abundance noise") implemented two divergent ways. 12S uses an interactive, live Inspector filter (`displayState.minimumExactReads`/`minimumUnresolvedReads`, CLI-backed). MHC uses a hardcoded absolute `belowThresholdValue = 5_000` that only flags samples in the cohort panel — non-adjustable, not an interactive filter, not on `GenotypeResultDisplayState`, no CLI backing. | `let belowThresholdValue = 5_000` (2493, 2506); `GenotypeResultDisplayState` exposes `minimumSupportPercent` but no absolute minimum-reads filter; 12S `TwelveSResultExportConfiguration` exposes `minimumExactReads`/`minimumUnresolvedReads`. | Converge on a shared "minimum reads" Inspector idiom: add editable minimum-reads control on `GenotypeResultDisplayState` mirroring `TwelveSResultDisplayState.minimumExactReads`; drive the cohort flag from it. | M |
| CR-04 | P1 | MHC | `Sources/LungfishWorkflow/ONTGenotyping/ONTBarcodeDemuxGenotypingPipeline.swift:1869-1876` (`writeBundleManifest`) | Batch (multi-bundle Illumina) runs write `AnalysisMetadata(... isBatch: false ...)` unconditionally; the provenance envelope has no batch/sample-count field beyond `inputFileCount`. A multi-sample batch run is mislabeled as single-sample. | `isBatch: false` is a constant (1872); only multiplicity signal is `"inputFileCount"` (1614). | Set `isBatch` based on `resolvedMode == .illuminaPaired && inputFASTQURLs.count > 1`; surface sample count in provenance options. | S |
| CR-05 | P1 | MHC | `Sources/LungfishCLI/Commands/FastqGenotypingSubcommand.swift:107-111` + `ONTBarcodeDemuxGenotypingPipeline.swift:979-1019` | `.lungfishmhcref` consume-side wiring is only partial. CLI resolves the bundle's *default* haplotype definition when `--haplotype-definition` is omitted, and the pipeline resolves FASTA + a bundled definition by ID, but there is no path to genotype against **all** definitions paired in the bundle; a multi-definition bundle silently uses just one. | `effectiveHaplotypeDefinition = haplotypeDefinition ?? bundledDefaultHaplotype?.id` (109) only picks default; `bundledHaplotypeDefinitionSet` (pipeline 1327-1340) resolves a single set. | Confirm intended semantics (single default vs all). If multiple, allow selecting/iterating bundle definitions; document default selection. | M |
| CR-06 | P2 | 12S | `Sources/LungfishWorkflow/TwelveS/TwelveSAmpliconMatchingWorkflow.swift:1012-1015` | File-scope free function `zip<T,U>(_:_:) -> (T,U)?` shadows `Swift.zip` for the whole file. Works today (only used at 818 for two optional Dates), but a future sequence-`zip` call would silently bind to the optional version. | Defined 1012-1015; only call site 818. | Rename to `zipOptionals` or inline `if let a, let b` at the call site. | S |
| CR-07 | P2 | 12S/MHC | `TwelveSAmpliconMatchingWorkflow.swift:957-977`, `TwelveSReferenceBundleBuilder.swift:366-386`, `MHCAmpliconReferenceBundleBuilder.swift:427-447`, `HaplotypeDefinitionCommandService.swift:749-769` | TSV escaping and provenance directory-checksum logic duplicated across three 12S files and both bundle builders + the haplotype service. | `directoryChecksum`/`directorySize` appear identically in all four files. | Extract a shared `ProvenanceDirectoryDescriptor` + TSV escape/parse utility into LungfishIO. | M |
| CR-08 | P2 | 12S | `Sources/LungfishWorkflow/TwelveS/TwelveSChimeraReview.swift:157-172` (`parseUCHIMEOutput`) | The UCHIME parser scans **all** tab fields for a literal `"y"`/`"n"`/`"chimera"` token rather than the designated uchimeout column; a label/score field containing a lone `y`/`n` could misclassify. | `lowercasedFields.contains("y") || lowercasedFields.contains("chimera")` (165-166) inspects every field. | Parse the specific uchimeout column index per the vsearch `--uchimeout` spec. | S |
| CR-09 | P2 | MHC | `Sources/LungfishApp/Views/WorkflowOperations/HaplotypeDefinitionManagerWindowController.swift:304-348` (`createMHCReferenceBundle`) | Detached bundle-create task captures `self` strongly and hops back via `await MainActor.run`. `@MainActor` hops are correct (no isolation violation) but the strong capture keeps the VM alive for the whole build and diverges from the controller's synchronous `perform { }` helper. | 322-347: `Task.detached(priority:.userInitiated) { ... await MainActor.run { self.isWorking = false; self.reload() ... } }`; other mutations route through `perform(_:)` (392-399). | Capture `[weak self]` and guard inside the `MainActor.run` blocks; or add an async variant of `perform`. | S |

## Surfaces explicitly clean for this lens

- **12S classifier** (`TwelveSAmpliconReadClassifier.swift`): rolling-hash exact matching bounds-correct
  (window end ≤ `read.count - minimumSoftClipBases`; `read[start+length]` guarded by `start < lastStart`),
  hash hits verified with `bytesEqual`, `indelOnlyDistance` DFS correctly pruned. `withTaskGroup` merges
  deterministically. `Sendable` throughout.
- **12S reference index / metadata builder**: gz handling, header parsing, SHA-keyed enrichment, MIDORI
  priority sort sound; typed `missingColumn` errors.
- **12S result bundle**: typed `missingColumn`/`invalidInteger`/`unknownTarget` errors,
  `requiredInt`/`optionalInt` guards, count matrix validated against target IDs. No force-unwraps in parse.
- **12S export**: atomic writes, `defer`/`catch` cleanup of partial outputs + sidecar, escaped hand-rolled
  XLSX, `/usr/bin/zip` checks `terminationStatus`.
- **12S FASTQ reader**: `AsyncThrowingStream` with `onTermination` cancellation and truncation detection.
- **12S BLAST flow** (`ViewerViewController+TwelveS.swift`): textbook background→MainActor discipline;
  CLI-backed with provenance verification; cancel wired.
- **MHC reference bundle model/builder**: atomic manifest writes, default-definition membership
  validation, force-overwrite + rollback `catch`, canonical provenance.
- **Haplotype command service**: `replaceReferenceFASTA` snapshots prior data and rolls back on failure
  (337-385); built-in-write guards; schema-version bump on edit. `Sendable` struct.
- **Format registry** (`FormatIdentifier.swift`): both `.lungfish12sref` and `.lungfishmhcref` registered
  consistently alongside `.lungfishref`.
- **SampleMetadataResolver**: pure value types, layered precedence with empty-cell-preserving merge,
  robust CSV quoting, typed errors. `Sendable`.
- **GUI execution service**: both 12S and genotyping paths shell out to `lungfish-cli`, verify provenance,
  call the full `OperationCenter` lifecycle.

## Top findings recap

1. **CR-01 (P0):** multi-bundle Illumina genotyping has no sample-ID collision guard — two bundles whose
   names sanitize to the same ID overwrite each other's staged FASTQ and get reads merged by the
   query-prefix demux: silent data loss + broken per-sample isolation. Only P0.
2. **CR-02 (P1):** 12S ships enabled by default; intent is opt-in.
3. **CR-03 (P1):** low-abundance filtering diverges — 12S interactive CLI-backed filter vs MHC hardcoded `5_000`.
4. **CR-04 (P1):** batch Illumina runs mislabeled `isBatch: false`.
5. **CR-05 (P1):** `.lungfishmhcref` consume-side only auto-selects the manifest default definition.
6. **P2s (CR-06..09):** `Swift.zip`-shadowing function, duplicated TSV/provenance helpers, fragile UCHIME
   parser, strong-`self` detached task.

No `%s`/SIGSEGV bugs, no illegal background→MainActor dispatch, no provenance gaps, no crashing
force-unwraps found.
