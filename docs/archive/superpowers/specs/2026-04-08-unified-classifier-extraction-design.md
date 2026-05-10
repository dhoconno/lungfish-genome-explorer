# Unified Classifier Extraction Design

**Date:** 2026-04-08
**Status:** Approved, ready for implementation plan
**Branch:** `feature/batch-aggregated-classifier-views`

## Goal

Replace the four existing classifier read extraction surfaces (EsViritu "Extract FASTQ…" wizard, TaxTriage "Extract FASTQ…" wizard, NAO-MGS "Extract FASTQ…" wizard, Kraken2 "Extract Reads for Taxon…" sheet) with **one unified extraction dialog** that handles all 5 classifier tools (EsViritu, TaxTriage, Kraken2, NAO-MGS, NVD) and offers four destinations: Save as Bundle, Save to File, Copy to Clipboard, Share (via `NSSharingServicePicker`).

Every classifier view gets exactly **one new context menu item** — "Extract Reads…" — that opens this dialog with the current row selection pre-loaded.

The entire pipeline is backed by a new `ClassifierReadResolver` actor that uses `samtools view` with the same duplicate-filter flag as the "Unique Reads" column in the UI, so extracted read counts *structurally cannot* disagree with what the user sees in the table. The CLI `lungfish extract reads --by-classifier` strategy is a thin wrapper over the same resolver, and a CLI/GUI round-trip equivalence test harness ensures both paths stay in lockstep.

As part of the same change set, fix a regression in EsViritu's "Extract FASTQ…" button where bundles created from a disk-loaded result landed in `.lungfish/.tmp/` instead of the project root.

## Non-Goals

- No changes to the `TaxonomyExtractionPipeline` engine (still the Kraken2 backend; its UI wrapper `TaxonomyExtractionSheet` is the thing being deleted, not the pipeline itself).
- No changes to the `MarkdupService` or the upstream dedup flag policy.
- No new viewport classes; this is a surgical addition + deletion on the existing classifier result views.

## Motivation

Today's extraction surface is a mess of duplication:

- **EsViritu**, **TaxTriage**, and **NAO-MGS** each have their own "Extract FASTQ…" button and their own hand-assembled `BAMRegionExtractionConfig` + `ReadExtractionService.extractByBAMRegion` + `createBundle` call chain. Same logic, three copies.
- **Kraken2** has a completely separate "Extract Reads for Taxon…" wizard (`TaxonomyExtractionSheet`) that calls `TaxonomyExtractionPipeline` — a fourth extraction path.
- **NAO-MGS** has a single-row "Copy Unique Reads as FASTQ" context menu item backed by a direct SQLite query. Nothing like it exists on the other four tools.
- **NVD** has no bundle-extract capability at all.

This fragmentation has produced the exact regression the user asked for help with: EsViritu's "Extract FASTQ…" button silently writes bundles to a temporary directory because the per-VC code fell into a stale fallback path. With four parallel implementations, any fix has to be applied four times, and tests have to be written four times. They rarely are.

Worse, the duplicate-flag filter used by the extraction code (`samtools view -F 1024` = `-F 0x400`) differs by one bit from the filter used by the `MarkdupService.countReads` call that populates the "Unique Reads" column (`-F 0x404`, which additionally excludes unmapped reads). A user who selects a row showing "Unique Reads: 47" and clicks Extract gets an FASTQ containing ~53 reads because unmapped reads in the region slip past the extraction filter. Count and sequences silently disagree.

**Solution:** one pipeline, one filter, one dialog, one CLI surface. Structurally impossible for count and sequences to disagree.

## Architecture

Three layers, bottom-up.

### 1. Workflow layer — `ClassifierReadResolver` + supporting types

New files in `Sources/LungfishWorkflow/Extraction/`:

- `ClassifierReadResolver.swift` — `public actor` that dispatches a classifier tool + row selection + destination to either a BAM-backed samtools pipeline (4 tools) or the Kraken2 classified-FASTQ pipeline (1 tool).
- `ClassifierRowSelector.swift` — `public struct` value type carrying the minimal information needed to identify rows across tools.
- `ExtractionDestination.swift` — `public enum` of the 4 destinations + result outcome.

```swift
public enum ClassifierTool: String, Sendable, CaseIterable {
    case esviritu, taxtriage, kraken2, naomgs, nvd
}

public struct ClassifierRowSelector: Sendable {
    public var sampleId: String?            // per-sample BAM grouping (nil for single-sample)
    public var accessions: [String]         // samtools view regions (BAM-backed tools)
    public var taxIds: [Int]                // Kraken2 only
}

public enum ExtractionDestination: Sendable {
    case file(URL)                                              // raw FASTQ/FASTA
    case bundle(projectRoot: URL,
                displayName: String,
                metadata: ExtractionMetadata)                   // .lungfishfastq bundle
    case clipboard(format: CopyFormat, cap: Int)                // GUI-only
    case share(tempDirectory: URL)                              // for NSSharingServicePicker
}

public enum CopyFormat: String, Sendable { case fasta, fastq }

public enum ExtractionOutcome: Sendable {
    case file(URL, readCount: Int)
    case bundle(URL, readCount: Int)
    case clipboard(byteCount: Int, readCount: Int)
    case share(URL, readCount: Int)
}

public struct ExtractionOptions: Sendable {
    public let format: CopyFormat
    public let includeUnmappedMates: Bool

    /// The samtools `-F` exclude-flag mask.
    ///
    /// - `0x404` (default): excludes PCR/optical duplicates AND unmapped reads.
    ///   Matches the `MarkdupService.countReads` filter used to populate
    ///   the "Unique Reads" column in classifier tables. This is the
    ///   semantic the user expects: extracted count == displayed count.
    /// - `0x400` (when `includeUnmappedMates == true`): excludes duplicates
    ///   only, keeping unmapped mates of mapped pairs. Useful when the user
    ///   wants both reads from a pair even if one didn't align.
    public var samtoolsExcludeFlags: Int {
        includeUnmappedMates ? 0x400 : 0x404
    }
}

public actor ClassifierReadResolver {
    public init(toolRunner: NativeToolRunner = .shared)

    public func resolveAndExtract(
        tool: ClassifierTool,
        resultPath: URL,
        selections: [ClassifierRowSelector],
        options: ExtractionOptions,
        destination: ExtractionDestination,
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> ExtractionOutcome

    /// Cheap pre-flight count used for size-guard and dialog estimates.
    ///
    /// Does NOT extract reads; just runs `samtools view -c` with the
    /// appropriate flag. Returns 0 for empty selections.
    public func estimateReadCount(
        tool: ClassifierTool,
        resultPath: URL,
        selections: [ClassifierRowSelector],
        options: ExtractionOptions
    ) async throws -> Int

    /// Walks up from `resultPath` to find the enclosing project root.
    /// Falls back to `resultPath.deletingLastPathComponent()` if no
    /// `.lungfish/` marker is found.
    public static func resolveProjectRoot(from resultPath: URL) -> URL
}
```

**Per-tool dispatch is a binary split:**

```swift
switch tool {
case .esviritu, .taxtriage, .naomgs, .nvd:
    return try await extractViaBAM(
        tool: tool,
        selections: selections,
        resultPath: resultPath,
        options: options,
        destination: destination,
        progress: progress
    )
case .kraken2:
    return try await extractViaKraken2(
        selections: selections,
        resultPath: resultPath,
        options: options,
        destination: destination,
        progress: progress
    )
}
```

`extractViaBAM` is **one function** shared across 4 tools:

1. Groups selectors by `sampleId`.
2. For each sample: looks up the BAM URL via `bamPathForSample(tool:sampleId:resultPath:)` (one tool-specific SQL query per tool — ~8 lines each).
3. Runs `samtools view -F <flags> -b <bam> <regions...>` → temp BAM, then `samtools fastq` → temp FASTQ per sample.
4. Concatenates per-sample FASTQs.
5. Writes the final output to the destination-appropriate location.

`extractViaKraken2` wraps the existing `TaxonomyExtractionPipeline.extract(config:tree:)` exactly as the soon-to-be-deleted `TaxonomyExtractionSheet` does today. Include-children is always `true` (the only sensible semantic; no toggle).

**Destination handling** happens after the FASTQ is materialized:

- `.file(url)` → move the temp FASTQ to `url`.
- `.bundle(projectRoot, displayName, metadata)` → call the existing `ReadExtractionService.createBundle(from:sourceName:selectionDescription:metadata:in:)`, writing the bundle to the resolved project root.
- `.clipboard(format, cap)` → read back up to `cap` records via `FASTQReader`, convert to FASTA if requested, return in the outcome for the caller to write to `NSPasteboard`.
- `.share(tempDirectory)` → move the temp FASTQ into a stable location under `tempDirectory/shares/<uuid>/`, return the URL for the caller to hand to `NSSharingServicePicker`.

Only the clipboard path is size-capped. Bundle, file, and share destinations extract the full unique-read set.

### 2. CLI layer — `--by-classifier` strategy in `ExtractReadsCommand`

Modified file: `Sources/LungfishCLI/Commands/ExtractReadsCommand.swift`.

Adds a 4th strategy flag alongside `--by-id`, `--by-region`, `--by-db`:

```
lungfish extract reads --by-classifier \
    --tool {esviritu|taxtriage|kraken2|naomgs|nvd} \
    --result <path-to-result-directory-or-db> \
    [--sample <sample-id>]...              # required for batch; repeatable
    [--taxon <taxid>]...                   # kraken2 only
    [--accession <acc>]...                 # non-kraken2 tools
    [--format {fastq|fasta}]               # default fastq
    [--include-unmapped-mates]             # default off; BAM-backed tools only
    [--bundle]                             # write as .lungfishfastq bundle
    [--bundle-name <name>]                 # bundle display name
    -o <output-path>
```

**Selector assembly:** `--sample X` opens a new selector group; subsequent `--accession`/`--taxon` flags attach to that group until the next `--sample` (or end of args). If no `--sample` is specified, all accessions/taxons form a single selector with `sampleId: nil`.

**Validation matrix:**

- Exactly one of `--by-id`, `--by-region`, `--by-db`, `--by-classifier` (extends existing mutual exclusion).
- `--by-classifier` requires `--tool` and `--result`.
- `--tool esviritu|taxtriage|naomgs|nvd` requires at least one `--accession`.
- `--tool kraken2` requires at least one `--taxon`, rejects `--include-unmapped-mates` (no concept for FASTQ-based extraction).
- `--format` defaults to `fastq`; `fasta` triggers FASTQ→FASTA conversion post-extraction.
- `--include-unmapped-mates` is Kraken2-rejected and otherwise optional; defaults off.

**Backwards compatibility for the existing `--by-region` strategy:**

`ReadExtractionService.extractByBAMRegion` gains a new parameter:

```swift
public func extractByBAMRegion(
    config: BAMRegionExtractionConfig,
    flagFilter: Int = 0x400,   // unchanged default — keeps --by-region's behavior
    progress: (@Sendable (Double, String) -> Void)? = nil
) async throws -> ExtractionResult
```

The default `0x400` preserves existing behavior for `lungfish extract reads --by-region` and for any other call site. The new `--by-classifier` path always passes `0x404` explicitly (or `0x400` when `--include-unmapped-mates` is set). The `--by-region` strategy gains an `--exclude-unmapped` flag for users who want count-matching semantics from the lower-level primitive.

### 3. GUI layer — unified dialog + orchestrator

New files in `Sources/LungfishApp/Views/Metagenomics/`:

- `ClassifierExtractionDialog.swift` — the unified dialog (`NSViewController` hosted in an `NSPanel`).
- `TaxonomyReadExtractionAction.swift` — `@MainActor` singleton orchestrating dialog → resolver → destination → UI feedback.

Four test-seam protocols live in `TaxonomyReadExtractionAction.swift`:

```swift
public protocol AlertPresenting: Sendable {
    func present(_ alert: NSAlert, on window: NSWindow) async -> NSApplication.ModalResponse
}

public protocol SavePanelPresenting: Sendable {
    func present(suggestedName: String, on window: NSWindow) async -> URL?
}

public protocol SharingServicePresenting: Sendable {
    func present(items: [Any], relativeTo view: NSView, preferredEdge: NSRectEdge)
}

public protocol PasteboardWriting: Sendable {
    func setString(_ string: String)
}
```

Each has a default implementation that wraps AppKit; tests inject mocks.

**Dialog UI:**

```
┌─────────────────────────────────────────────────────┐
│  Extract Reads                                      │
│                                                     │
│  Selected: 3 assemblies from 2 samples              │
│            ≈ 1,240 unique reads                     │
│                                                     │
│  Format:        ◉ FASTQ    ○ FASTA                  │
│                                                     │
│  Reads to include:                                  │
│    ☑ Include unmapped mates of mapped pairs         │
│       (+ ~180 reads)                                │
│                                                     │
│  Destination:   ◉ Save as Bundle                    │
│                 ○ Save to File…                     │
│                 ○ Copy to Clipboard (unavailable)   │
│                 ○ Share…                            │
│                                                     │
│  Name:  [sarscov2_NC_001803_extract          ]      │
│                                                     │
│                     [ Cancel ]  [ Create Bundle ]   │
└─────────────────────────────────────────────────────┘
```

Behavior notes:

- **Format picker** — FASTQ / FASTA radio buttons. Selecting FASTA re-runs the pre-flight estimate (unchanged count, but different serialized byte size).
- **Include unmapped mates toggle** — live-updates the "+ ~N reads" delta via a second pre-flight `samtools view -c -f 4 -F 0x400` count. Hidden entirely for Kraken2.
- **Destination radios** — 4 options. "Copy to Clipboard" is **disabled with a tooltip** when `estimatedReadCount > TaxonomyReadExtractionAction.clipboardReadCap` (10 000). Tooltip: "Too many reads to fit on the clipboard. Choose Save to File, Save as Bundle, or Share instead."
- **Name field** — visible for Save as Bundle (sidebar name) and Save to File (default filename). Hidden for Copy to Clipboard and Share.
- **Primary button label** — destination-aware: "Create Bundle" / "Save" / "Copy" / "Share". `.return` always activates.
- **Cancel button** — always visible, `.escape` always activates.
- **Progress display** — once the user clicks the primary button, the controls disable and a progress bar + status label replace the destination picker. Cancel stays enabled and routes to the underlying Task's cancellation.

**`TaxonomyReadExtractionAction` public API:**

```swift
@MainActor
public final class TaxonomyReadExtractionAction {
    public static let shared = TaxonomyReadExtractionAction()

    /// Soft cap beyond which the clipboard destination is disabled.
    public static let clipboardReadCap = 10_000

    public struct Context {
        public let tool: ClassifierTool
        public let resultPath: URL
        public let selections: [ClassifierRowSelector]
        public let suggestedName: String
    }

    /// Opens the unified extraction dialog for the given context.
    public func present(context: Context, hostWindow: NSWindow)

    // Test seams — internal visibility, injected by tests
    var alertPresenter: AlertPresenting = DefaultAlertPresenter()
    var savePanelPresenter: SavePanelPresenting = DefaultSavePanelPresenter()
    var sharingServicePresenter: SharingServicePresenting = DefaultSharingServicePresenter()
    var pasteboard: PasteboardWriting = DefaultPasteboard()
    var resolverFactory: @Sendable () -> ClassifierReadResolver = { ClassifierReadResolver() }
}
```

The method is synchronous and non-throwing — all async work happens inside a detached Task with progress + completion reported through `OperationCenter` and the dialog's own UI state. Errors surface as `NSAlert.beginSheetModal(for:)` on the host window.

### Per-classifier view controller wiring (the bespoke code floor)

Each of the 5 classifier result view controllers has exactly **three** pieces of tool-specific code:

1. **Selection-to-selector mapping** — a private method on the VC that reads its selected rows and builds `[ClassifierRowSelector]`. Different per tool because the row types differ (`ViralDetectionItem` / `TaxonNode` / `TaxTriageTableRow` / `NaoMgsTaxonSummaryRow` / `NvdBlastHit`). ~15 lines per VC.

2. **Menu item installation** — one new `NSMenuItem` with title "Extract Reads…" wired to a selector that calls `TaxonomyReadExtractionAction.shared.present(...)`. ~5 lines per VC.

3. **Deletion of old per-VC extraction code** — each VC's existing `presentExtractionSheet` / `contextExtractFASTQ` / `TaxonomyExtractionSheet` presentation code is deleted. Net negative per VC.

**No per-VC resolver code, no per-VC BAMRegionExtractionConfig code, no per-VC createBundle code.** The VC's entire contribution is "here's my selection, here's my tool ID, here's where my result lives." Everything else is the resolver's job.

**Target metric:** ≤ 40 lines of tool-specific code per classifier (menu wiring + selector mapping + selector helper). Enforced by the simplification-pass gate at the end of Phase 5.

## Data Flow

```
User right-clicks in a classifier table with N rows selected
        │
        ▼
Context menu rebuilt; "Extract Reads…" item enabled iff selection non-empty
        │
        ▼
Click → VC glue method builds [ClassifierRowSelector] from selected rows
        │
        ▼
VC calls TaxonomyReadExtractionAction.shared.present(context:, hostWindow:)
        │
        ▼
Action presents ClassifierExtractionDialog as a sheet on hostWindow
        │
        ▼
Dialog runs initial pre-flight count via ClassifierReadResolver.estimateReadCount
  (two counts: main flag filter + unmapped-mates delta)
        │
        ▼
User toggles format / unmapped-mates / destination; dialog live-updates
  the estimated read count and the "Copy to Clipboard" disabled state
        │
        ▼
User clicks primary button (destination-aware label)
        │
        ▼
Dialog disables controls, shows progress bar, starts Task.detached:
  OperationCenter.start(
    title: "Extract Reads — <Tool>",
    operationType: .taxonomyExtraction,
    cliCommand: "lungfish extract reads --by-classifier --tool <x> --result <path>
                 --sample A --accession X --format fastq
                 [--include-unmapped-mates] [--bundle --bundle-name <name>]
                 -o <output-path>"
  )

  let resolver = TaxonomyReadExtractionAction.shared.resolverFactory()
  let outcome = try await resolver.resolveAndExtract(
      tool: context.tool,
      resultPath: context.resultPath,
      selections: context.selections,
      options: dialogOptions,
      destination: dialogDestination,
      progress: { fraction, message in
          // Main-dispatched update to OperationCenter + dialog progress bar
      }
  )
        │
        ▼
Back on MainActor: dialog dismisses, OperationCenter.complete, and:
  - .file → reveal in Finder on success (if user set that preference)
  - .bundle → sidebar reload, scroll to new bundle
  - .clipboard → NSPasteboard.setString, show "Copied N reads" confirmation
  - .share → present NSSharingServicePicker anchored to the dialog's share button
            (dialog stays visible briefly so picker has an anchor view)
```

Cancellation: `OperationCenter.setCancelCallback` wires to the Task handle. The resolver's per-sample loop calls `Task.checkCancellation()`. Temp directories are `defer`-cleaned by the resolver; share-destination files are NOT cleaned (they persist in `.lungfish/.tmp/shares/` for the sweeper to collect).

## Edge Cases

| Situation | Behavior |
|---|---|
| Mixed assembly + contig rows selected (EsViritu) | Assemblies expand to constituent contig accessions in the VC's selector mapping; union all per sample. |
| Multi-sample selection across samples with different BAMs | One samtools invocation per sample, outputs concatenated. Progress: `(samplesProcessed / totalSamples, "Extracting sample X…")`. |
| Sample BAM missing from the tool's DB (corrupted import) | Resolver throws `ExtractionError.bamNotFound(sampleId)`. Dialog shows an error alert with the affected sample ID. No silent skip. |
| Kraken2 selection at "root" or "unclassified" with millions of reads | Pre-flight catches via `cladeReads` sum; clipboard radio disables. |
| Empty selection at dialog-open time | Dialog refuses to open; menu item disabled via `validateMenuItem`. |
| `samtools` missing or unusable | `ExtractionError.samtoolsFailed` bubbles; NSAlert via `beginSheetModal` (not `runModal`, per macOS 26 rules). |
| Kraken2 `classified.fastq` missing | Resolver throws `ExtractionError.kraken2OutputMissing`. Dialog shows actionable error. |
| Project directory not writable | `ProjectTempDirectory.create` throws; same alert path. |
| Task cancellation mid-extraction | `setCancelCallback → task.cancel()`, `Task.checkCancellation()` in resolver loop, `defer` cleans temp. Dialog returns to the pre-extraction state. |
| Zero reads extracted despite non-zero pre-flight estimate | Non-blocking "No reads extracted — try different selection" alert. No destination action taken. |
| Host window closed mid-extraction | Extraction continues in the Task; on completion, outcome is stored in `~/Downloads/lungfish-extracted-reads-<timestamp>.fastq` and a user notification posted. Applies to all destinations that were "attached" to a now-dead window. |
| FASTQ→FASTA conversion for a read without quality scores | FASTA emission is trivially valid (no quality needed). No edge case. |
| Share destination when user dismisses `NSSharingServicePicker` without picking | File remains in `.lungfish/.tmp/shares/`; no action taken. Temp sweeper collects it later. |
| User picks Share but no sharing services available (rare) | `NSSharingServicePicker` returns empty; dialog shows "No sharing services configured — choose a different destination." |

## Bundle Extract Regression Fix

Fixed centrally by the new design. The root cause was that `EsVirituResultViewController.presentExtractionSheet` derived `projectURL` exclusively from `esVirituConfig?.outputDirectory`, which is nil when the result is loaded from disk. The entire `presentExtractionSheet` method is being **deleted** in this change — replaced by calling `TaxonomyReadExtractionAction.shared.present(...)`, which routes through `ClassifierReadResolver.resolveProjectRoot(from: resultPath)`. That method walks up from the result path to find the enclosing `.lungfish/` project marker, regardless of whether any per-VC config field is set.

**Primary regression test:** `testExtractionDialog_esviritu_loadedFromDisk_bundleLandsInProjectRoot`. Construct a VC via `configureFromDatabase(db, resultURL:)` against a fixture project, open the dialog programmatically, extract to bundle, assert the bundle appears under the project's standard bundle location (not under `.lungfish/.tmp/`).

The test fails against the current branch tip before the fix lands.

## File Layout

### New source files (5)

```
Sources/LungfishWorkflow/Extraction/ClassifierReadResolver.swift
Sources/LungfishWorkflow/Extraction/ClassifierRowSelector.swift
Sources/LungfishWorkflow/Extraction/ExtractionDestination.swift
Sources/LungfishApp/Views/Metagenomics/ClassifierExtractionDialog.swift
Sources/LungfishApp/Views/Metagenomics/TaxonomyReadExtractionAction.swift
```

### Deleted source files (2)

```
Sources/LungfishApp/Views/Metagenomics/TaxonomyExtractionSheet.swift          (~365 lines)
Sources/LungfishApp/Views/Metagenomics/ClassifierExtractionSheet.swift        (~91 lines)
```

`TaxonomyExtractionPipeline.swift` and `TaxonomyExtractionConfig.swift` are **not** deleted — the pipeline remains the Kraken2 backend (wrapped by `ClassifierReadResolver.extractViaKraken2`), and its `TaxonomyExtractionConfig` struct is the pipeline's internal input shape. The resolver constructs that struct from a `[ClassifierRowSelector]` internally; callers of the resolver never see it.

### Modified source files (8)

```
Sources/LungfishWorkflow/Extraction/ReadExtractionService.swift
  + flagFilter: Int parameter on extractByBAMRegion (default 0x400, backwards-compat)

Sources/LungfishCLI/Commands/ExtractReadsCommand.swift
  + --by-classifier flag and option group
  + validate() matrix extension
  + runByClassifier() strategy function
  + --include-unmapped-mates flag
  + --exclude-unmapped flag for --by-region
  + strategyLabel / strategyParameters cases

Sources/LungfishApp/Views/Metagenomics/EsVirituResultViewController.swift
  - delete presentExtractionSheet and all related extract-sheet code
  - delete hand-assembled BAMRegionExtractionConfig + service calls
  + add selection→selector helper
  + wire "Extract Reads…" menu item and action-bar button to TaxonomyReadExtractionAction

Sources/LungfishApp/Views/Metagenomics/ViralDetectionTableView.swift
  + "Extract Reads…" menu item in buildContextMenu
  + validateMenuItem case
  + onExtractRequested callback type change (now passes [ClassifierRowSelector])

Sources/LungfishApp/Views/Metagenomics/TaxTriageResultViewController.swift
  - delete existing contextExtractFASTQ extraction code
  - delete existing menu item on TaxTriageOrganismTableView
  + "Extract Reads…" menu item, selection→selector helper, wiring

Sources/LungfishApp/Views/Metagenomics/NaoMgsResultViewController.swift
  - delete existing "Copy Unique Reads as FASTQ" single-row context menu item
  - delete existing contextExtractFASTQ extraction code
  + "Extract Reads…" menu item, selection→selector helper, wiring

Sources/LungfishApp/Views/Metagenomics/NvdResultViewController.swift
  + "Extract Reads…" menu item, selection→selector helper, wiring

Sources/LungfishApp/Views/Metagenomics/TaxonomyViewController.swift         (Kraken2)
  - delete TaxonomyExtractionSheet presentation code
  - delete onExtractConfirmed callback chain
  + "Extract Reads…" menu item on TaxonomyTableView
  + selection→selector helper, wiring
```

### New test files (6)

```
Tests/LungfishWorkflowTests/Extraction/ClassifierReadResolverTests.swift
Tests/LungfishCLITests/ExtractReadsByClassifierCLITests.swift
Tests/LungfishAppTests/ClassifierExtractionDialogTests.swift
Tests/LungfishAppTests/ClassifierExtractionInvariantTests.swift
Tests/LungfishAppTests/ClassifierExtractionMenuWiringTests.swift
Tests/LungfishAppTests/ClassifierCLIRoundTripTests.swift
```

Plus a shared test helper:

```
Tests/LungfishAppTests/TestSupport/ClassifierExtractionFixtures.swift
  — builds minimal per-tool fixtures under Tests/Fixtures/classifier-results/.
```

### Test fixture additions

Under `Tests/Fixtures/classifier-results/`:

- `esviritu/` — SQLite DB + per-sample BAM+BAI, 10 reads across 2 accessions.
- `taxtriage/` — SQLite with organism_to_accessions + BAM, 5 organisms.
- `kraken2/` — classified.fastq + kraken2_output.txt + minimal taxonomy, 8 reads across 3 taxa.
- `naomgs/` — SQLite + materialized BAM (synthesized via NaoMgsBamMaterializer in a pre-test hook), 5 hits.
- `nvd/` — SQLite + BAM whose references are contig names, 4 contigs.

Each fixture < 100 KB. Tests complete in < 200 ms per test on clean CI.

## Testing Strategy

Three layers, each one catching what the next layer below misses. The invariant suite is the strongest regression guard.

### Layer A: Invariant tests (`ClassifierExtractionInvariantTests`)

Parameterized across all 5 classifiers. These are the tests that must never fail as the codebase evolves — they guard user-facing behavior, not implementation details.

- **Invariant I1 — menu item visible:** For every classifier view, when at least one row is selected, the context menu contains a visible `Extract Reads…` item. 5 tests.
- **Invariant I2 — menu item enabled:** Same conditions, item has `isEnabled == true`. 5 tests.
- **Invariant I3 — click wiring:** Invoking the menu item via `NSApp.sendAction` calls `TaxonomyReadExtractionAction.shared.present` with non-empty `selections` matching the selected rows. 5 tests.
- **Invariant I4 — count-sequence agreement:** For every BAM-backed classifier and every destination, the number of records in the extracted FASTQ equals the Unique Reads count shown in the UI for the same selection. Exercises all 4 destinations via parameterized fixtures. ~5 test functions × 4 BAM-backed tools × 4 destinations = 80 conceptual cases collapsed into ~8 test functions via `XCTContext.runActivity`.
- **Invariant I5 — samtools flag dispatch:** The resolver's `extractViaBAM` uses `-F 0x404` when `includeUnmappedMates == false` and `-F 0x400` when `true`. Parameterized × 4 BAM-backed tools = 2 test functions.
- **Invariant I6 — clipboard cap enforcement:** When `estimatedReadCount > clipboardReadCap`, the dialog's "Copy to Clipboard" radio is disabled with a non-empty tooltip. 1 test.
- **Invariant I7 — CLI/GUI round-trip equivalence:** For every classifier, the CLI command string logged by the GUI during extraction, when passed through `ExtractReadsSubcommand.parse(...)` and `.run()` against the same fixture, produces a FASTQ byte-identical (or record-set-identical after sorting by ID) to the GUI's output. 5 tests.

**Total Layer A: ~32 test functions / ~100 conceptual cases.**

### Layer B: Functional UI + dialog tests

`ClassifierExtractionDialogTests.swift`:

- Dialog: format picker FASTQ/FASTA round-trip.
- `testDialog_unmappedMatesToggle_updatesEstimateLive` — toggling the checkbox re-runs the estimate.
- `testDialog_kraken2_hidesUnmappedMatesToggle` — Kraken2 hides the row entirely.
- `testDialog_clipboardRadioDisabledOverCap` — 15 k estimate → disabled + tooltip.
- `testDialog_destinationBundle_buttonLabelCreateBundle`
- `testDialog_destinationFile_buttonLabelSaveAndNameFieldVisible`
- `testDialog_destinationClipboard_buttonLabelCopyAndNameFieldHidden`
- `testDialog_destinationShare_buttonLabelShareAndNameFieldHidden`
- `testDialog_cancelDismissesWithoutInvokingResolver`
- `testDialog_primaryButtonDisablesControlsAndShowsProgress`
- `testDialog_midExtractionCancelRoutesToTaskCancellation`
- `testDialog_resolverErrorShowsAlertAndReEnablesControls`

`ClassifierExtractionMenuWiringTests.swift`:

- One test per classifier VC (5 total) asserting the menu item presents the dialog with the expected `Context`.

**Total Layer B: ~17 tests.**

### Layer C: Unit tests

`ClassifierReadResolverTests.swift`:

- `testExtractViaBAM_esviritu_regionsProduceDedupedFASTQ`
- `testExtractViaBAM_taxtriage_samePatternAsEsviritu`
- `testExtractViaBAM_naomgs_samePatternViaMaterializedBAM`
- `testExtractViaBAM_nvd_contigNameAsRegion`
- `testExtractViaBAM_multiSample_concatenatesOutputs`
- `testExtractViaBAM_missingBAM_throwsBamNotFound`
- `testExtractViaBAM_filterMatchesMarkdupCount` — canary for Invariant I4
- `testExtractViaKraken2_unchangedSemantics`
- `testExtractViaKraken2_includeChildrenAlwaysTrue`
- `testResolveProjectRoot_fromResultPath_walksUp`
- `testResolveProjectRoot_noMarker_fallsBackToParent`
- `testEstimateReadCount_matchesActualExtractionCount`
- `testEstimateReadCount_returnsZeroForEmptySelection`
- `testCancellation_cleansTempDir`
- `testDestination_file_movesFASTQToRequestedPath`
- `testDestination_bundle_createsLungfishfastqBundle`
- `testDestination_clipboard_returnsSerializedString`
- `testDestination_share_movesFileToStableLocation`
- `testFASTQToFASTA_convertsRecordsCorrectly`
- `testFASTQToFASTA_handlesLongReads`

`ExtractReadsByClassifierCLITests.swift`:

- `testParse_byClassifier_esviritu_requiresAccession`
- `testParse_byClassifier_kraken2_requiresTaxon`
- `testParse_byClassifier_kraken2_rejectsIncludeUnmappedMates`
- `testParse_byClassifier_nonKraken2_acceptsIncludeUnmappedMates`
- `testParse_byClassifier_multipleStrategiesFails`
- `testParse_byClassifier_perSampleSelection_groupsAccessions`
- `testParse_byClassifier_bundleFlag`
- `testParse_byClassifier_formatFasta`
- `testRun_byClassifier_esviritu_endToEnd`
- `testRun_byClassifier_kraken2_endToEnd`
- `testRun_byClassifier_formatFasta_endToEnd`
- `testRun_byClassifier_bundle_endToEnd`
- `testParse_byRegion_excludeUnmapped_flagFilter0x404`
- `testParse_byRegion_default_flagFilter0x400`
- `testReadExtractionService_extractByBAMRegion_defaultFlagFilter_unchanged`

**Total Layer C: ~35 tests.**

### Test count rollup

- Layer A (invariants): 7 invariants, ~32 test functions, ~100 conceptual cases
- Layer B (functional UI + dialog): ~17 tests
- Layer C (unit): ~35 tests
- **Total: ~85 tests**

### Performance budget

- Invariant suite (Layer A) must run in **under 5 seconds total** so it's runnable before every commit.
- Per-test fixture setup < 50 ms.
- Full new-test run < 30 seconds on clean CI.

### What the tests prevent

- Menu item renamed, deleted, or hidden → Invariants I1 and I2 fail.
- Menu item disconnected from its action → Invariant I3 fails.
- Samtools flag filter drift → Invariant I4 fails on ALL destinations simultaneously, pointing directly at the extraction code.
- Anyone adding a new classifier without wiring the new menu item → a parameterized test failure names the tool.
- CLI and GUI drift → Invariant I7 fails with a byte-diff of the two FASTQs.
- Dialog UI regressions (wrong label, wrong button, missing field) → Layer B tests fail specifically.

## Review Gate Architecture

Because the user has flagged silent regressions in this area as a repeat pain point, every implementation phase ends with a **four-step gate** that cannot be skipped:

1. **Adversarial Review #1** — an independent subagent reads the phase's code, compares it to the spec, and writes a report at `docs/superpowers/reviews/2026-04-08-unified-classifier-extraction/phase-N-review-1.md`. The reviewer's charter is explicitly adversarial: find bugs, missed spec requirements, silent regressions, test gaps, fragile patterns, dead code, anything that will break under future change. The reviewer has write access to the review file and read access to the phase's commits.

2. **Simplification Pass** — a separate subagent reads the review, the phase's code, and any prior phase's code, and refactors to eliminate duplication, extract shared helpers, delete anything the review identified as dead, and address every review comment with either a fix (preferred) or a documented "wontfix" justification in the review file. This subagent has write access to the source tree.

3. **Adversarial Review #2** — a **fresh** subagent with no prior conversation context, not allowed to read `phase-N-review-1.md` until after forming its own independent assessment. Its charter is: independently re-challenge the design and implementation, AND verify the simplification didn't introduce new issues. Writes to `phase-N-review-2.md`.

4. **Build + test gate** — `swift build --build-tests` clean, all new tests for the phase passing, all existing 1400+ tests still passing.

A phase is not complete until all four gates pass. Phase N+1 cannot start until Phase N is complete. Review files are committed to git with the phase; the audit trail exists permanently.

**Specific metric for Phase 5 (per-VC wiring):** the simplification pass must report "lines of tool-specific code per classifier" and show that number is ≤ 40. If it exceeds 40 for any classifier, the simplification pass has failed.

## Open Questions

None — all clarifications resolved during brainstorm across 5 rounds of iteration.

## References

- Design spec predecessor (commit `a82d098`): earlier version of this spec before unification, deleted bundles, and invariant suite
- Existing CLI command: `Sources/LungfishCLI/Commands/ExtractReadsCommand.swift`
- Existing extraction service: `Sources/LungfishWorkflow/Extraction/ReadExtractionService.swift`
- Existing Kraken2 extraction pipeline: `Sources/LungfishWorkflow/Metagenomics/TaxonomyExtractionPipeline.swift`
- Existing NAO-MGS "Copy Unique Reads" single-row reference implementation: `Sources/LungfishApp/Views/Metagenomics/NaoMgsResultViewController.swift:1883` (menu build) and `:1979` (handler) — both to be deleted
- MarkdupService flag policy: `docs/superpowers/specs/2026-04-08-markdup-service-design.md`
- `OperationCenter.buildCLICommand` for stamping reproducible commands (in `DownloadCenter.swift`)
- `ProjectTempDirectory.create(prefix:in:)` for temp directory management
- macOS 26 API rules in MEMORY.md: `beginSheetModal` not `runModal`, GCD main queue dispatch pattern for background callbacks
- Viewport interface classes: `docs/design/viewport-interface-classes.md` — this change unifies extraction across the Taxonomy Browser viewport class
