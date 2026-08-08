# Repo Audit Findings — 2026-08-08

Produced by the Phase 1 audit workflow (26 finders, paired adversarial verification, two-judge expert panel). See the design spec `docs/superpowers/specs/2026-08-08-repo-review-refactor-design.md`.

Raw counts: 37 inventory rows, 60 raw findings, 56 confirmed, 4 refuted.

Status legend: each finding's fix status is tracked in the results report at campaign end.


## Confirmed findings (D2 responsiveness / D3 correctness / D4 structure)

### F14 [D2/high/user-visible/effort-M] @MainActor annotation-import service runs full GFF/BED parse, SHA256 hashing, and provenance I/O synchronously on the main thread

`Sources/LungfishWorkflow/Bundles/ReferenceBundleAnnotationImportService.swift:139`

ReferenceBundleAnnotationImportService is declared @MainActor (line 57), and attachAnnotationTrack(sourceURL:bundleURL:trackID:trackName:) is called directly on that actor. The method performs, with no Task.detached / background hop anywhere in the call chain: AnnotationDatabase.createFromBED (line 190, fully synchronous), directory copy of the entire provenance directory for rollback (ProvenanceLayoutSnapshot.capture, line 78), full-file SHA256 hashing of the source annotation file, the manifest, and the output database via ProvenanceRecorder.sha256(of:) (fileSnapshot, line 622), and multiple JSON encode/decode + atomic writes (loadProvenanceLog, writeProvenance, writeCanonicalProvenance). Only createFromGFF3 is awaited (async); createFromBED and everything else runs inline on MainActor.

**Suggested fix:** Hop off MainActor for the actual import work: make attachAnnotationTrack a free async function or run its body via Task.detached / an actor, publishing only the final result back to MainActor. Ensure createFromBED and the hashing/provenance-writing helpers execute off the main thread.

### F17 [D2/high/user-visible/effort-M] @MainActor NativeBundleBuilder.build() performs synchronous whole-file I/O on the main thread

`Sources/LungfishWorkflow/Native/NativeBundleBuilder.swift:21`

NativeBundleBuilder is declared @MainActor (line 21) and is an ObservableObject that drives bundle-build progress UI. Its async build() pipeline calls a chain of plain (non-async, non-nonisolated) private methods that do heavy synchronous file I/O directly on the main actor: parseFASTAForChromosomes (line 1311) reads the entire input FASTA into memory with FileHandle.readDataToEndOfFile(), decodes it as one UTF-8 String, and splits it into a full line array via content.components(separatedBy: .newlines) before iterating; clipBEDCoordinates (line 1589) and countVariantsInVCF (line 1683) do the same String(contentsOf:)+components(separatedBy:) whole-file read/split pattern for BED and VCF files; bundleOutputFileRecords (line 492) walks the entire staged bundle tree with FileManager.enumerator and calls resourceValues per file synchronously. None of these methods are marked nonisolated or dispatched off the main actor, and none use FileHandle-based streaming/chunked reads. For a large reference genome FASTA (tens to hundreds of MB, e.g. a full chromosome or bacterial/viral pangenome build) or a VCF with millions of variant lines, each of these calls blocks the main thread for a duration proportional to file size, freezing the entire app UI (including the progress bar this same object is supposed to be updating) during 'Build Reference Bundle' operations.

**Suggested fix:** Move the FASTA/BED/VCF parsing and enumeration helpers (parseFASTAForChromosomes, clipBEDCoordinates, countVariantsInVCF, bundleOutputFileRecords, uniqueExistingFileURLs) to nonisolated functions or a separate non-MainActor helper type, and use streaming line-by-line reads (e.g. FileHandle async bytes/lines, matching the streaming pattern already used elsewhere in ONTGenotyping like URL.multiFileLinesAutoDecompressing) instead of loading whole files into memory and splitting on newlines. Only the @Published progress/status updates need to stay on the MainActor.

### F36 [D3/high/user-visible/effort-S] samtools view stdout/stderr pipe deadlock in streamSAMView

`Sources/LungfishWorkflow/Mapping/MappingSummaryBuilder.swift:161`

streamSAMView spawns `samtools view <bam>` with both stdout and stderr connected to separate Pipes, then calls `stdoutPipe.fileHandleForReading.readDataToEndOfFile()` synchronously (fully draining stdout) BEFORE reading stderr at all. macOS pipe buffers are ~64KB. Any real BAM's SAM text output will exceed that almost immediately, and if samtools also writes anything material to stderr while stdout is still being drained (e.g. index/warning messages), the child process can block on a full stderr pipe while nothing is reading it (this thread is still blocked inside the stdout read). Both sides then wait on each other and the call only unblocks via the timeout-driven `process.terminate()`. Every sibling call site in the same module tree (NativeToolRunner.runProcess, ManagedMappingPipeline.runCondaToolStreamingStdout, GATKPipelineExecutor.runGATKProcess, PBAAClusteringPipeline.runProcess) explicitly avoids this by draining stdout and stderr concurrently on separate background threads/DispatchGroup before waiting on the process. This function reintroduces the classic sequential-pipe-read deadlock the rest of the codebase was written to avoid.

**Suggested fix:** Drain stdoutPipe and stderrPipe concurrently (e.g. two DispatchQueue.global().async blocks joined with a DispatchGroup, as done in GATKPipelineExecutor/PBAAClusteringPipeline) before calling process.waitUntilExit(), instead of reading stdout to completion first.

### F37 [D3/high/user-visible/effort-S] PBAA nextflow process launch has no Task-cancellation wiring

`Sources/LungfishWorkflow/PBAA/PBAAClusteringPipeline.swift:594`

runProcess (used by ProcessPBAANextflowRunner.run for the PBAA clustering `nextflow run` invocation) wraps the Process launch in a plain withCheckedThrowingContinuation with no withTaskCancellationHandler and no registration with NativeProcessRegistry/ProcessTreeTerminator. Every comparable long-running-process helper elsewhere in this same source tree (NativeToolRunner.runProcess/runWithFileOutput, ManagedMappingPipeline.runCondaToolStreamingStdout, FullLengthONTMHCAlignmentProcessRunner.execute) wires withTaskCancellationHandler to terminate the child process tree on Task cancellation. Here, if the enclosing Task is cancelled (e.g. user cancels the PBAA clustering operation from the UI), the nextflow process and its descendants keep running to completion untracked and are never killed — the async call simply keeps awaiting until the process exits on its own.

**Suggested fix:** Wrap the continuation in withTaskCancellationHandler, register the Process with a cancellation handle (e.g. NativeProcessCancellationHandle/ProcessTreeTerminator as used in ManagedMappingPipeline), and terminate the process tree in onCancel, mirroring the pattern already used by ManagedMappingPipeline.runCondaToolStreamingStdout in the same module.

### F38 [D3/high/user-visible/effort-S] SQLite bind_text uses SQLITE_STATIC (nil) with temporary NSString pointer -- use-after-free

`Sources/LungfishIO/Bundles/AnnotationDatabase+Mutation.swift:40`

insertAnnotation/updateAnnotation (and helpers in AnnotationDatabase+Building.swift, AnnotationDatabase+Query.swift, AnnotationDatabase.swift -- 39 call sites total) call sqlite3_bind_text(stmt, i, (str as NSString).utf8String, -1, nil). Passing `nil` as the destructor tells SQLite to use SQLITE_STATIC semantics: it does NOT copy the string bytes and instead keeps a raw pointer into the temporary NSString's internal buffer, expecting that memory to remain valid until sqlite3_step()/sqlite3_reset() runs. Each `(str as NSString)` is a short-lived Swift temporary whose ARC-guaranteed lifetime only covers its own bind-call expression, not the several subsequent bind calls and the later sqlite3_step() call. Every other SQLite wrapper in this module (VariantDatabaseSQLiteSupport.swift, AlignmentMetadataDatabase.swift, MultipleSequenceAlignmentBundle+SQLite.swift, PhylogeneticTreeIndexWriter.swift, EsVirituDatabase.swift) deliberately defines and uses a SQLITE_TRANSIENT destructor constant for exactly this reason -- AnnotationDatabase is the sole outlier still using SQLITE_STATIC with a temporary.

**Suggested fix:** Define `private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)` (as already done elsewhere in the module) and pass it as the destructor argument to every sqlite3_bind_text call across AnnotationDatabase.swift, AnnotationDatabase+Mutation.swift, AnnotationDatabase+Building.swift, and AnnotationDatabase+Query.swift.

### F39 [D3/high/user-visible/effort-M] commitImportTransaction() ignores COMMIT/BEGIN failures, silently continuing after data loss

`Sources/LungfishIO/Bundles/VariantDatabase+CreateFromVCF.swift:441`

commitImportTransaction() calls sqlite3_exec(db, "COMMIT", ...); on failure it only logs a warning and issues a ROLLBACK (discarding all rows inserted since the last successful commit), then proceeds as if nothing happened -- it does not throw, does not set a failure flag, and does not abort createFromVCF(). Likewise the subsequent "BEGIN TRANSACTION" (line ~461) on reopen only logs on failure. Because callers (memoryPressureFlush, rotateImportTransactionIfNeeded, the final commit at line 1021, and the per-chromosome partition commit at line 991) never check the return value, a COMMIT failure partway through a large VCF import (e.g. disk full, I/O error, or SQLITE_BUSY) silently drops already-parsed variants while the import continues to completion and reports success with `import_variant_count` reflecting only the un-rolled-back subset -- the caller has no way to know the resulting .lungfishref variant database is missing data.

**Suggested fix:** Have commitImportTransaction() return a Bool (or throw) reflecting COMMIT/BEGIN success, and propagate failure out of createFromVCF() as a VariantDatabaseError so the caller sees an explicit failure instead of a silently truncated database.

### F41 [D3/high/user-visible/effort-S] Stale-write race in NAO-MGS on-demand miniBAM materialization fallback

`Sources/LungfishNaoMgsUI/NaoMgsResultViewController.swift:1315`

In loadMiniBAMsAsync's fallback path (when the sample's BAM hasn't been materialized yet), a Task.detached captures `capturedIndex` and, after materializing, writes into `self.miniBAMControllers[capturedIndex]` on the main queue with only an array-bounds check (`capturedIndex < self.miniBAMControllers.count`) and a `weak self` check — there is no generation/cancellation guard tied to the enclosing `miniBAMLoadingTask`. `buildMiniBAMList()` (line ~1377) fully clears and rebuilds `miniBAMControllers` on every new selection/reload, and `loadMiniBAMsAsync` cancels the previous `miniBAMLoadingTask` on every call, but this inner detached task ignores both: it isn't cancelled when the outer task is cancelled, and it doesn't check any generation token before mutating the (possibly rebuilt-for-a-different-sample) controller array. Compare with the sibling code path 40 lines above (`bamReferenceLengthLoadTask` in TaxTriageResultViewController.swift:2465) and other detached tasks in this same file (e.g. line 2465-2483 pattern), which correctly capture and re-check a generation UUID before applying results.

**Suggested fix:** Capture the outer Task's identity or a per-load generation token (similar to `bamReferenceLengthLoadGeneration` used elsewhere in the sibling TaxTriage controller) before entering the Task.detached fallback, and re-check it inside the DispatchQueue.main.async block before indexing into `self.miniBAMControllers`. Also check `Task.isCancelled` if converting the outer `Task { }` context into a cancellable that the fallback observes.

### F5 [D2/high/user-visible/effort-L] Full recursive filesystem scan runs synchronously on @MainActor on every sidebar refresh

`Sources/LungfishApp/Views/Sidebar/SidebarViewController.swift:930`

reloadFromFilesystem(notifyUnchangedSelectionRefresh:) calls buildRootItems(from:) -> buildSidebarTree(from:isRoot:), which recursively walks the entire project directory tree on the main thread: FileManager.contentsOfDirectory at every directory level (SidebarViewController.swift:1484, 1463, 1811, 2034, 2058, 2174, 2239), plus per-node fileExists probes, JSON sidecar decodes (Data(contentsOf:) + JSONDecoder at lines 1994, 2006, 2017, 2159, 2219, 2284), and isMetagenomicsResultDirectory's per-directory fileExists probing (lines 1661-1719). This runs on EVERY full reload: initial openProject, any filesystem-watcher-triggered full reload (kFSEventStreamEventFlagMustScanSubDirs, root-level changes, Analyses/ changes), after move/copy operations, and drag-and-drop. For a project with many samples/analyses/derivatives this blocks the main thread and freezes the whole UI (including menu bar and window dragging) for the scan duration.

**Suggested fix:** Move the directory-tree build (buildRootItems/buildSidebarTree and its JSON sidecar decodes) to a background Task/actor, returning the built [SidebarItem] tree to the main actor for the outlineView.reloadData() + selection-restore step only. Guard with a generation counter so a stale in-flight scan started before a newer openProject/reload doesn't clobber it.

### F1 [D2/med/user-visible/effort-S] readAtPoint does full linear scan of cachedPackedReads on every mouseMoved

`Sources/LungfishApp/Views/Viewer/SequenceViewerView+Tooltips.swift:854`

mouseMoved (SequenceViewerView+Tooltips.swift:43) calls readAtPoint on essentially every mouse-move event over the alignment track. readAtPoint iterates the entire cachedPackedReads array with `for (row, read) in cachedPackedReads where row == rowIndex` — a full O(N) scan filtered by a `where` clause instead of pre-bucketing reads by row. cachedPackedReads can hold up to maxReadsPerTrack entries (250,000 when limitReadRowsSetting is on, unbounded otherwise per SequenceViewerView+Alignment.swift:632). In a densely-covered BAM region at packed/base tier, every mouse-move re-scans the full read list purely to find hits in one row, causing hover lag/stutter while panning the mouse over reads.

**Suggested fix:** Bucket cachedPackedReads by row (e.g. [Int: [AlignedRead]] or an array-of-arrays indexed by row) when reads are packed in SequenceViewerView+Rendering.swift, so readAtPoint can index directly into rowIndex instead of scanning every entry. Alternatively maintain a sorted-by-row array and binary-search/slice the row range.

### F12 [D2/med/user-visible/effort-M] AI assistant region/gene queries block MainActor with synchronous SQLite calls

`Sources/LungfishApp/Services/AI/AIToolRegistry.swift:376`

AIToolRegistry is @MainActor. In executeSearchVariants, the query-string and no-filter branches correctly wrap their VariantDatabase SQLite work in Task.detached (lines 360-374 and 450-464) to avoid blocking the main thread. But the region-filtered branches (lines 376-382 and 413-419) call `index.queryVariantsInRegion(...)` directly on `AnnotationSearchIndex` (also @MainActor, at Services/AnnotationSearchIndex.swift:507-536 etc.), which runs its SQLite query synchronously in-line. executeGetGeneDetails (lines 611, 630, 636) and executeSearchAnnotations-style callers show the same inconsistency: `searchIndex.search(...)`, `queryVariantCountInRegion(...)`, and `queryVariantsInRegion(...)` all execute synchronously on the main actor while sibling code paths in the same file explicitly detach equivalent SQLite work.

**Suggested fix:** Wrap the AnnotationSearchIndex query calls (search, queryVariantsInRegion, queryVariantCountInRegion, queryAnnotationsInRegion) in Task.detached the same way the VariantDatabase calls already are, or make AnnotationSearchIndex's query methods async and internally hop off MainActor for the actual SQLite execution, so a single AI tool call can't stall the UI while the query runs.

### F15 [D2/med/user-visible/effort-S] Plugin pack tool-requirement status checks run serially instead of concurrently

`Sources/LungfishWorkflow/Conda/PluginPackStatusService.swift:327`

computeStatus(for:) loops `for requirement in pack.toolRequirements { toolStatuses.append(await evaluate(requirement, bootstrapReady: bootstrapReady)) }`. evaluate() (line 851) spawns a subprocess-based smoke test with up to Self.smokeTestMaxAttempts retries (runSmokeTest, line 986) per tool requirement, plus filesystem checks and conda-meta JSON scans. For packs with multiple tools this serializes N subprocess round-trips instead of running them concurrently via a TaskGroup. This service backs status(for:), which is called synchronously-awaited from wizard sheets (AssemblyWizardSheet, BAMVariantCallingCatalog, FASTQOperationsCatalog) and PluginManagerViewModel before displaying tool-readiness UI, so users wait on the sum of all tools' smoke-test latency rather than the max.

**Suggested fix:** Replace the serial for-loop with a TaskGroup that evaluates all toolRequirements concurrently and collects results, preserving output order.

### F21 [D2/med/user-visible/effort-S] Genotype matrix search filter has no debounce, unlike the equivalent BatchTableView/ViralDetectionTableView filters

`Sources/LungfishGenotypeUI/GenotypeComparisonMatrixView.swift:1830`

`filterField.sendsSearchStringImmediately = true` (line 1045) wires `filterChanged(_:)` to fire the `action` on every keystroke, which calls `setFilterText` -> `applyFilterState` -> `applyFilterAndSort` (line 2108) synchronously on the main thread for every character typed. `applyFilterAndSort` runs an O(rows) filter closure (with `rowMatches`/`rowMatchesIdentity` string matching per row), an O(rows log rows) sort when a sort descriptor is active, `rebuildVisibleRowIndex()`, a diff-based table reload, scroll-anchor restore, and selection reconciliation — all per keystroke. This is inconsistent with the rest of the codebase: `Sources/LungfishKit/BatchTableView.swift:546` (`scheduleFilterApply`) and `Sources/LungfishEsVirituUI/ViralDetectionTableView.swift:639` (`setFilterText(_:debounce:)`) both debounce filter text before recomputing. On large MHC genotype comparison datasets (the app's primary genotype UI, many samples x loci), fast typing in the matrix filter field will stack up full filter/sort/reconcile passes and can make the field feel laggy.

**Suggested fix:** Add the same Task.sleep-based debounce pattern used in BatchTableView.scheduleFilterApply/ViralDetectionTableView.setFilterText(_:debounce:) around the call to applyFilterState/applyFilterAndSort triggered from filterChanged(_:), while still updating filterText/committedNativeFilterState synchronously so the text field itself stays responsive.

### F24 [D3/med/user-visible/effort-S] extractOverlappingReads swallows errors and results with no user feedback

`Sources/LungfishApp/Views/Viewer/ViewerViewController+Mapping.swift:259`

The `extractOverlappingReads(from:)` handler (invoked from the annotation right-click context menu's "Extract Overlapping Reads" action) runs `ReadExtractionService.extractByBAMRegion` in a detached Task with no `OperationCenter` registration. On failure it only writes to an os_log logger (`mappingDisplayLogger.error`) — no alert, no status bar message, no Operations Panel entry. On success the result is discarded (`_ = try await ...`) with no confirmation to the user either. Unlike essentially every other CLI/background action in this file (delete track, MSA export, taxonomy extraction, etc.), which all register an OperationCenter item and surface failures via `.fail()` + an NSAlert, this path is a dead end: a failed BAM extraction (missing samtools, permissions, disk full, invalid region) looks identical to a successful one from the user's perspective — nothing happens.

**Suggested fix:** Register an OperationCenter operation (start/complete/fail) around the extraction, and on catch present an NSAlert (or at least update the status bar) with the error description, mirroring the pattern used elsewhere in this file (e.g. runAnnotationTrackDeletion).

### F26 [D3/med/user-visible/effort-S] Mapped-reads-annotation progress calls OperationCenter.update() without .log()

`Sources/LungfishApp/Views/Inspector/InspectorViewController+TrimDuplicateWorkflows.swift:353`

The progressHandler for MappedReadsAnnotationService().convertMappedReads calls OperationCenter.shared.update(id:progress:detail:) directly instead of updateWithLog(...) or a paired .log() call. OperationCenter.update() (OperationCenter.swift:426-433) only mutates progress/detail; it does not append to items[index].logEntries. Per project convention (and confirmed by the OperationCenter implementation), pipeline ops must call BOTH update() and log() — without .log(), only materialization/completion steps persist in the expanded operation row's history, so users inspecting this operation's log after the fact see no intermediate progress messages.

**Suggested fix:** Replace the OperationCenter.shared.update(id:progress:detail:) call with OperationCenter.shared.updateWithLog(id:progress:detail:) (as done correctly elsewhere, e.g. MainSplitViewController+FASTQImport.swift:901), or add an explicit OperationCenter.shared.log(id:level:message:) call alongside it.

### F30 [D3/med/user-visible/effort-S] Reference-import progress stream calls OperationCenter.update() without .log()

`Sources/LungfishApp/App/AppDelegate+ImportCenter.swift:307`

In importReferenceSequenceFile (the FASTA/GenBank reference import flow), the progress callback passed to ReferenceBundleImportHelperLauncher.importAsReferenceBundleViaAppHelper calls only `OperationCenter.shared.update(id:progress:detail:)`, never `.log(...)`. Per OperationCenter's own contract (OperationCenter.swift `update` vs `updateWithLog`), plain `update()` only refreshes the visible progress/detail fields and does NOT append an `OperationLogEntry`; only `.log()`/`.updateWithLog()` persist entries into `items[index].logEntries`. Every intermediate progress message emitted during this potentially long-running import (network/CLI helper output) is therefore invisible once the user expands the operation row's history — the exact known gotcha documented in project memory ('Pipeline operations: call BOTH OperationCenter.update() AND .log()').

**Suggested fix:** Add a paired `OperationCenter.shared.log(id: opID, level: .info, message: message)` call alongside the `.update()` call in the progress closure (or switch to `.updateWithLog(...)`), matching the pattern already used in CLIImportRunner.swift and CLIMSAActionRunner.swift.

### F34 [D3/med/user-visible/effort-M] Greedy interval clustering can transitively merge non-overlapping reads

`Sources/LungfishWorkflow/Alignment/BestMappedReadsAnnotationService.swift:251`

`IntervalCluster.add` grows the cluster's `end` via `end = max(end, record.end0)` for every record folded in, and `overlaps` only checks against the cluster's current (monotonically growing) bounds — not against the individual records already in the cluster. A read A (positions 100-200) followed by read B (150-500) followed by read C (480-520) will all merge into one cluster even though A and C never overlap each other, because B bridges them. `selectBestRows` then treats the whole chain as a single genomic interval and picks one 'best' read to represent it, silently dropping/merging annotation rows for what should have been two distinct intervals.

**Suggested fix:** Track true overlap using an interval-tree/sweep approach, or re-validate overlap against all members of the cluster (not just the running max) before merging, or flush and restart a cluster whenever a record's start exceeds the cluster's minimal covering set boundary rather than its ever-growing max end.

### F4 [D2/med/user-visible/effort-M] fetchAnnotationBases/selectedFASTAOperationInput perform synchronous bundle file I/O on main thread from context-menu actions

`Sources/LungfishApp/Views/Viewer/SequenceViewerView+Interaction.swift:1332`

fetchAnnotationBases (line 1422) and selectedFASTAOperationInput (line 1304-1338) call bundle.fetchSequenceSync(region:) directly. That function (Sources/LungfishIO/Bundles/ReferenceBundle.swift:321-365) opens/reads the genome FASTA index and, for bgzip-backed genomes, constructs a SyncBgzipFASTAReader and decompresses blocks synchronously — real file I/O and decompression. These are invoked from @objc menu action handlers (copyAnnotationSequence, copyAnnotationComplement, copyAnnotationReverseComplement, runSelectedSequenceFASTAOperation) triggered by right-click context menu items, which run on the main thread via NSMenu.popUpContextMenu. For large annotations/selections or slow storage (network volume, hibernating disk) this blocks the UI thread and can hang app-wide input during the copy/extract action.

**Suggested fix:** Move the fetchSequenceSync call off the main thread (e.g. wrap in Task.detached and dispatch the resulting clipboard write back to main), or add a lightweight progress/beachball affordance if synchronous is intentional for small ranges; the existing async fetchSequence(region:) path in ReferenceBundle already exists and should be preferred here.

### F44 [D4/med/user-visible/effort-M] formatBytes duplicated ~8 times across LungfishApp with divergent, inconsistent output formats

`Sources/LungfishApp/App/AppDelegate.swift:1427`

At least 7 independent `formatBytes`/`formatFileSize` implementations exist scattered across LungfishApp with no shared helper in LungfishKit: AppDelegate.swift:1427 (hand-rolled KB/MB/GB math, `%.0f KB`/`%.1f MB`/`%.2f GB`), ProvenanceInspectorViewModel.swift:856 and :881 (two separate copies in the same file, both wrapping ByteCountFormatter), BundleBuildHelpers.swift:199 (ByteCountFormatter), AttachmentsSection.swift:92, PluginManagerView.swift:1158 (ByteCountFormatter with a comment explaining it's a free function to dodge @MainActor isolation), FASTQImportConfigSheet.swift:958, and NvdImportSheet.swift:370. The AppDelegate version produces materially different output than the ByteCountFormatter-based ones (different rounding/unit thresholds), so file sizes are formatted inconsistently depending on which dialog/section the user is viewing.

**Suggested fix:** Add a single `formatBytes` static helper to LungfishKit (or a Sendable free function usable from @MainActor view closures, matching the PluginManagerView pattern) and replace all ~7 call sites in LungfishApp with it.

### F51 [D4/med/user-visible/effort-M] SRAService duplicates NCBI eutils client logic without the API-key resolution NCBIService has

`Sources/LungfishCore/Services/NCBI/SRAService.swift:176`

SRAService.swift builds its own `https://eutils.ncbi.nlm.nih.gov/entrez/eutils/...` requests (fetchRunInfo at line 176, plus a search implementation) with its own retry loop, completely independent from `NCBIService` (Services/NCBI/NCBIService.swift) which shares the same base URL but resolves an NCBI API key via `NCBIAPIKeyResolver` (line 65) to raise the eutils rate limit from 3 req/s to 10 req/s. SRAService never references `NCBIAPIKeyResolver` or attaches an api_key query param, so all SRA searches are needlessly capped at the unauthenticated rate limit and the eutils request-building/retry code is maintained twice.

**Suggested fix:** Extract a shared NCBIEutilsClient (base URL, api_key attachment via NCBIAPIKeyResolver, retry/backoff policy) that both NCBIService and SRAService consume, or have SRAService route its efetch/esearch calls through NCBIService directly.

### F59 [D4/med/user-visible/effort-S] Deprecation message for 'conda extract' points to the wrong replacement flag

`Sources/LungfishCLI/Commands/CondaExtractCommand.swift:89`

`ExtractSubcommand.run()` (registered as `lungfish conda extract`) prints: "WARNING: 'lungfish conda extract' is deprecated. Use 'lungfish extract reads --by-id' instead." But `conda extract` performs Kraken2-taxonomy-based extraction (--taxid, --kraken-output, --include-children via TaxonomyExtractionPipeline). The actual functional replacement in `ExtractReadsSubcommand` (Sources/LungfishCLI/Commands/ExtractReadsCommand.swift) is `extract reads --by-classifier --tool kraken2 --taxon <id> --result <kraken-output>`, not `--by-id` (which extracts by literal read-ID list from a text file and has no taxonomy/kraken concept at all). A user following the printed guidance will hit `--tool is required with --by-classifier`-style errors or, worse, misuse `--by-id` with taxonomy IDs and get confusing validation failures.

**Suggested fix:** Change the deprecation string to reference '--by-classifier --tool kraken2' (or whichever flag combination is the true migration path), and add a short example showing --taxon/--result mapping from the old --taxid/--kraken-output flags.

### F6 [D2/med/user-visible/effort-M] Provenance sidecar lookup does synchronous multi-level filesystem walk + JSON decode on every sidebar selection

`Sources/LungfishApp/Views/Inspector/ProvenanceInspectorViewModel.swift:415`

InspectorViewController+Notifications.swift's selectionDidChange (called on every single sidebar click) invokes updateProvenanceTarget -> ProvenanceInspectorViewModel.load(item:), which synchronously calls ProvenanceRecorder.findProvenanceEnvelope(for:) (LungfishWorkflow/Provenance/ProvenanceRecorder.swift:266). That function walks up to 5 parent directories, at each level trying a bundle-output sidecar, several directorySidecarCandidates, and a mappingProvenanceCandidate — each candidate does a fileExists check and, on a hit, a full Data(contentsOf:) + JSONDecoder decode of a provenance envelope (which can include hundreds of file/step records; buildPresentState then further processes up to maximumDisplayedFileRows=500 rows and maximumDisplayedStepPaths=200). All of this runs synchronously on @MainActor with no debounce, so rapid arrow-key/click navigation through the sidebar serializes a burst of directory walks and JSON parses on the main thread, causing visible input lag while browsing.

**Suggested fix:** Debounce updateProvenanceTarget the same way sidebar content-selection is debounced (~100ms DispatchWorkItem pattern already used in MainSplitViewController+SidebarSelection.swift), and/or move findProvenanceEnvelope + envelope decode off the main actor into a Task with a generation counter so stale lookups from fast navigation are discarded instead of completed serially.

### F8 [D2/med/user-visible/effort-M] Synchronous recursive directory scan on main actor every time the FASTQ Operations dialog opens

`Sources/LungfishApp/Views/FASTQ/FASTQOperationDialogState.swift:195`

FASTQOperationDialogState.init (a @MainActor type) calls Self.projectBarcodeDefinitionCandidates(in: projectURL) synchronously at line 195. That static method (line 1534) uses FileManager.enumerator to recursively walk the entire project directory tree looking for .csv/.tsv/.txt files, resolving isDirectory/isRegularFile resource values for every entry along the way. This runs unconditionally on the main thread as part of dialog construction (FASTQOperationsDialogPresenter.swift:17), before the dialog is shown, for every FASTQ operation launched — not just barcode-related tools.

**Suggested fix:** Move the directory scan off the main actor: perform it in a Task.detached during/after presentation and populate projectBarcodeDefinitionCandidates asynchronously (defaulting to empty array until the scan completes), or lazily scan only when the barcode-definition picker is actually shown (FASTQOperationToolPanes.swift:221) rather than unconditionally in init.

### F47 [D4/med/effort-L] 9,331-line file with a single ~6,450-line struct plus 8 unrelated bolted-on types

`Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCGenotypingPipeline.swift:933`

FullLengthONTMHCGenotypingPipeline.swift is the largest file in the module (9,331 lines, 214 functions). The public struct FullLengthONTMHCGenotypingPipeline alone spans lines 933-7386 (>6,400 lines). The same file also defines FullLengthONTMHCPivotWorkbookBuilder, FullLengthONTMHCCandidateObservationNormalizer, FullLengthONTMHCUnmatchedSequenceNormalizer, FullLengthONTMHCBlastRescueParser, FullLengthONTMHCUnmatchedClosestMatchWorkbookBuilder, FullLengthONTMHCUnifiedPivotWorkbookBuilder, and FullLengthONTMHCXLSXPackageWriter — a pivot-table builder, two normalizers, a BLAST-output parser, and an XLSX serializer, all logically independent of the pipeline orchestration and of each other.

**Suggested fix:** Split into per-responsibility files following the pattern already used elsewhere in ONTGenotyping (e.g. GenotypeWorkbookRevisionService+OverrideScript.swift as an extension file): extract FullLengthONTMHCXLSXPackageWriter, the pivot/unmatched workbook builders, and the normalizer/parser enums into their own files. Keep the orchestration struct itself but consider decomposing its largest phases into helper types.

### F49 [D4/med/effort-M] Three near-identical hand-rolled Process()+readabilityHandler+continuation implementations in one file

`Sources/LungfishWorkflow/Conda/CondaManager.swift:1209`

CondaManager.swift independently reimplements the same Process/Pipe/readabilityHandler/withCheckedThrowingContinuation pattern three times: runMicromambaVersion (line 353-388, simple stdout/stderr via terminationHandler), the tool-run path at line 850 (with readabilityHandler-based streaming, NSMutableData buffers, cancellation handle), and runMicromamba at line 1209 (same streaming pattern but with its own continuationResumed guard and a 0.1s DispatchQueue.global().asyncAfter drain-delay hack instead of the cancellation-handle machinery used at line 850). The module already has a general-purpose actor, NativeToolRunner (Sources/LungfishWorkflow/Native/NativeToolRunner.swift), built for exactly this kind of process invocation, but CondaManager does not use it.

**Suggested fix:** Consolidate the three Process-invocation sites in CondaManager.swift into one internal helper (or route through NativeToolRunner if its API can be adapted for micromamba invocation), eliminating the duplicated buffering/cancellation/timing logic and the fragile fixed 0.1s drain delay at line 1250.

### F54 [D4/med/effort-S] Task{@MainActor} launched from GCD background closure in OperationCenter.cancel

`Sources/LungfishKit/OperationCenter.swift:709`

cancel(id:) dispatches onCancel() on DispatchQueue.global(qos:.userInitiated).async, then inside that background closure spawns `Task { @MainActor [weak self] in self?.finishCancellation(id: id) }` (line 711). This is exactly the banned pattern documented in project memory: launching Task{@MainActor} from a GCD background callback instead of using DispatchQueue.main.async + MainActor.assumeIsolated (the pattern correctly used elsewhere in this same file's neighbors, e.g. MiniBAMViewController.swift:611/857/868). It compiles because Task{@MainActor} technically hops correctly, but it is the specific anti-pattern the team has banned for consistency/audit reasons, in the shared kernel used by every leaf's cancel flow.

**Suggested fix:** Replace with DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.finishCancellation(id: id) } }, matching the pattern already used in MiniBAMViewController.swift and NaoMgsResultViewController.swift.

### F55 [D4/med/effort-L] GenotypeResultViewController.swift is a 12,048-line, 506-function god file

`Sources/LungfishGenotypeUI/GenotypeResultViewController.swift:1`

This single file (LungfishGenotypeUI leaf) is 12,048 lines with 506 functions and zero `// MARK:` section markers, mixing view setup, table/matrix rendering, manual haplotyping, export, persistence, filtering, and notification wiring in one type. It dwarfs every other leaf's main view controller (next largest is TaxTriageResultViewController at 5,084 lines) and impedes navigation, incremental compilation, and safe modification — any change risks touching unrelated responsibilities in the same file.

**Suggested fix:** Split along existing seams (many are already separate types like GenotypeManualHaplotypeDraftCoordinator, GenotypeOutlineView) — extract remaining cohesive chunks (export flow, persistence flow, filter/search wiring) into extension files or dedicated coordinator types within the same module, following the pattern already used for the smaller Genotype* helper files.

### F11 [D2/low/user-visible/effort-S] Primer and reference scans run sequentially instead of concurrently on wizard load

`Sources/LungfishApp/Views/Mapping/ViralReconWizardSheet.swift:380`

loadInitialData() awaits loadPrimerOptions() then loadReferences() one after another (lines 380-383), even though both are independent Task.detached filesystem scans (listBuiltInSchemes/PrimerSchemesFolder.listBundles and ReferenceSequenceScanner.scanAll) with no data dependency between them. This doubles the wizard's perceived load latency versus running them concurrently with async let.

**Suggested fix:** Replace the sequential awaits with `async let primers = loadPrimerOptions(); async let refs = loadReferences(); await primers; await refs` (or run both scans inside a single detached task group) so the wizard's initial directory scans overlap.

### F13 [D2/low/user-visible/effort-S] fetchAnnotations serially awaits each annotation track instead of fetching concurrently

`Sources/LungfishApp/Services/BundleDataProvider.swift:169`

BundleDataProvider is @MainActor and fetchAnnotations(chromosome:start:end:) loops over `manifest.annotations` and does `try await bundle.getAnnotations(trackId:region:)` once per track sequentially (line 171), each a separate SQLite region query. This is the exact 'MainActor hop inside a loop — serial await per iteration where a task group belongs' pattern: for a bundle with several annotation tracks (gene models, custom user tracks, primer schemes), latency for one viewport update is O(N tracks) round trips instead of O(1) via a concurrent fetch, and it runs on the main actor.

**Suggested fix:** Use withThrowingTaskGroup (or async let per track, bounded by track count) to fetch all tracks' annotations concurrently and merge results, rather than a sequential for-await loop.

### F16 [D2/low/user-visible/effort-M] Workflow library listing/saving does synchronous JSON decode/encode + hashing on the main thread

`Sources/LungfishWorkflow/Builder/WorkflowLibraryStore.swift:58`

WorkflowLibraryStore's static methods (listWorkflows, loadWorkflow, saveWorkflow, createWorkflow, renameWorkflow, duplicateWorkflow) are plain synchronous throwing functions with no actor isolation or async boundary. They are called directly from WorkflowBuilderViewController, a @MainActor NSSplitViewController (e.g. line 439 `workflowLibraryEntries = try WorkflowLibraryStore.listWorkflows(...)`, line 339 saveWorkflow, line 564/831 createWorkflow). listWorkflows decodes every .lungfishworkflow bundle's JSON in the directory synchronously; saveWorkflow does two JSON encodes, three atomic file writes, a version-history append/read, and SHA256 hashing of each written file (WorkflowLibraryStore.swift:99-137) — all inline on MainActor.

**Suggested fix:** Move WorkflowLibraryStore's disk-touching operations off the main actor (e.g. wrap calls in Task.detached from the view controller, or make the store an actor) and await the results before updating UI state.

### F18 [D2/low/user-visible/effort-S] decompressDeflate allocates a full 64KB output buffer per bgzip block regardless of requested range size

`Sources/LungfishIO/Formats/FASTA/BgzipIndexedFASTAReader.swift:453`

Both BgzipIndexedFASTAReader.decompressDeflate (actor, line 453) and SyncBgzipFASTAReader.decompressDeflate (line 700) always allocate `Data(count: Self.maxBlockSize)` (64KB) as the decompression output buffer for every single bgzip block read, even when only a few bytes are needed from that block (e.g. fetching a 10bp window near a block boundary). readUncompressedRange calls readAndDecompressBlock in a loop once per bgzip block spanning the requested region, so a viewport that scrolls through many small regions repeatedly allocates/zeroes 64KB Data buffers on the actor's executor for every fetch.

**Suggested fix:** Reuse a persistent scratch buffer across calls (stored actor/class property) sized once at maxBlockSize instead of allocating fresh Data per block, or size the buffer to the compression_decode_buffer's actual bound instead of a fixed max.

### F2 [D2/low/user-visible/effort-M] mouseMoved chains multiple unthrottled O(N) hit-tests every event

`Sources/LungfishApp/Views/Viewer/SequenceViewerView+Tooltips.swift:43`

mouseMoved runs a sequential chain of hit-test calls on every raw NSEvent.mouseMoved (no debounce/coalescing): isNearGutterEdge, sampleNameAtGutterPoint, genotypeTooltipAtPoint, readAtPoint, coverageDepthAtPoint, and annotationAtPoint/bundleAnnotationAtPoint, each potentially O(N) over its respective cache (genotype sites, packed reads, depth points, annotations). None of these results are cached/memoized between events, so panning the mouse across a busy view re-runs the full battery of scans at native event rate (often >60/sec), which is the primary contributor to the readAtPoint cost noted separately in this file.

**Suggested fix:** Coalesce mouseMoved handling behind a short throttle (e.g. only run hit-testing once per display refresh via a dirty flag/CVDisplayLink-aligned timer) or early-exit faster using cached spatial indices per track instead of linear scans, mirroring the row-bucketing fix suggested for readAtPoint.

### F20 [D2/low/user-visible/effort-S] collectProjectArtifacts calls FileManager.fileExists synchronously for every enumerated filesystem entry during a full project rebuild

`Sources/LungfishIO/Search/ProjectUniversalSearchIndex.swift:372`

rebuild() -> collectProjectArtifacts iterates a recursive FileManager.enumerator over the entire project directory and, for every single yielded URL, calls `fm.fileExists(atPath:isDirectory:)` (line 394) in addition to the properties already requested via includingPropertiesForKeys. This is a second synchronous stat() syscall per filesystem entry on top of the enumerator's own metadata fetch, and hasFile() (line 607-609) issues yet another fileExists call per candidate directory checked against classification-result.json/esviritu-result.json/etc. For large projects with many derivative/classification directories this multiplies syscalls substantially during a full re-index (called from rebuild(), which the class explicitly documents as 'full-refresh for correctness' and thus likely invoked on project open or after bulk changes).

**Suggested fix:** Request isDirectoryKey via includingPropertiesForKeys (already done) and read it via resourceValues(forKeys:) instead of a redundant fileExists(atPath:isDirectory:) call; batch the hasFile probes or cache directory listings instead of re-stating each candidate file individually.

### F22 [D2/low/user-visible/effort-S] Multi-contig selection fetches FASTA previews serially with await-in-loop instead of concurrently

`Sources/LungfishAssemblyUI/AssemblyResultViewController.swift:498`

In `showSelection(rows:)`, when more than one contig is selected, the code does `for name in selectedNames { ... try await catalog.sequenceFASTA(for: name, lineWidth: 70) ... }` (lines 500-505). Each iteration awaits sequentially, so selecting N contigs pays N sequential round-trips through `AssemblyContigCatalog.sequenceFASTA` (likely disk/DB-backed) instead of fetching them concurrently. For a multi-select of even a modest number of contigs this serializes I/O latency that a `withTaskGroup`/`async let` fan-out would parallelize, making the detail pane feel slow to populate after a large marquee/shift-click selection.

**Suggested fix:** Replace the serial for-loop with a task group (withThrowingTaskGroup or a bounded-concurrency variant) that fetches sequenceFASTA for all selectedNames concurrently, then reassembles results in the original order before joining them, while still checking `generation == selectionGeneration` before publishing.

### F23 [D2/low/user-visible/effort-S] Column-resize notification observer runs a full column scan on every live-drag tick with no throttling

`Sources/LungfishKit/MetadataColumnController.swift:296`

`installResizeObserver` registers for `NSTableView.columnDidResizeNotification`, which AppKit posts continuously while the user drags a column divider (not just on drag-end). The handler dispatches to `syncDisabledColumnsFromWidths()` (line 309) which iterates `tableView.tableColumns` on every notification and, when a metadata column's width crosses the disable threshold, calls `refreshColumns()` (line 222) which removes/re-adds table columns and calls `tableView.reloadData()`. For tables with many metadata columns and rows, this can insert a full column rebuild + reloadData into every frame of an in-progress column-resize drag.

**Suggested fix:** Coalesce the resize handling (e.g. only run the auto-hide check when the notification is columnDidResizeNotification with drag-ended state, or debounce via a short Task.sleep/DispatchQueue.main.async collapse) so the expensive `refreshColumns()`/`reloadData()` path runs once per drag gesture rather than once per drag tick.

### F25 [D3/low/user-visible/effort-S] Variant preset load has no generation guard against concurrent re-triggers

`Sources/LungfishApp/Views/Viewer/AnnotationTableDrawerView+TableView.swift:158`

`loadVariantPresetValuesIfNeeded()` guards entry with `variantPresetLoadState == .idle`, launches a `DispatchQueue.global` background query capturing `dbURLs`/`keys` at call time, and on completion (line 204-219) unconditionally writes `variantInfoPresetValues`/`selectedVariantPresetByKey`/`variantPresetLoadState` — there is no check that the captured `dbURLs`/`keys` still match the drawer's current `variantTrackDatabaseURLs`/`infoColumnKeys`. `AnnotationTableDrawerView+Columns.swift:777` resets `variantPresetLoadState = .idle` whenever a new bundle/track set loads, which lets a second `loadVariantPresetValuesIfNeeded()` call start while an earlier one (for a since-replaced track set) is still running in the background. Whichever background query finishes last wins, so a stale preset computation for a previously-displayed variant track can silently overwrite the presets for the currently displayed one after a quick bundle/track switch.

**Suggested fix:** Capture a generation counter (bumped alongside the `.idle` reset in Columns.swift:777) and check it in the completion closure before writing `variantInfoPresetValues`/`selectedVariantPresetByKey`/`variantPresetLoadState`, same pattern already used elsewhere in this file (e.g. `annotationScopeMetadataQueryGeneration`).

### F27 [D3/low/user-visible/effort-S] Filtered-alignment progress calls OperationCenter.update() without .log()

`Sources/LungfishApp/Views/Inspector/InspectorViewController+TrimDuplicateWorkflows.swift:476`

Same gap as the mapped-reads-annotation workflow: the progressHandler for BundleAlignmentFilterService().deriveFilteredAlignment calls only OperationCenter.shared.update(id:progress:detail:), never .log() or updateWithLog(). Intermediate progress text for this long-running filtered-alignment derivation never lands in the operation's persisted log history.

**Suggested fix:** Switch to OperationCenter.shared.updateWithLog(id:progress:detail:) or pair with an explicit .log() call.

### F28 [D3/low/user-visible/effort-S] GATK variant-calling attach-phase progress update skips .log()

`Sources/LungfishApp/Views/Inspector/InspectorViewController+VariantWorkflow.swift:227`

In launchGATKVariantCallingOperation, the mid-run progress update ("Attaching GATK variants to bundle...") calls only OperationCenter.shared.update(id:progress:detail:) with no accompanying .log() call, unlike the CLI-runner variant-calling path directly above it (lines 138-142) which routes every event through both update (via applyVariantCallingEvent) and an explicit .log(). This one status transition for the GATK pipeline is silently missing from the operation's log history.

**Suggested fix:** Add OperationCenter.shared.log(id: opID, level: .info, message: "Attaching GATK variants to bundle...") alongside the update() call, or switch to updateWithLog().

### F29 [D3/low/user-visible/effort-S] Reference-FASTA import progress handler calls update() without .log()

`Sources/LungfishApp/Views/MainWindow/MainSplitViewController+FASTQImport.swift:86`

The progress closure passed to ReferenceBundleImportHelperLauncher.importAsReferenceBundleViaAppHelper calls only OperationCenter.shared.update(id:progress:detail:); it never logs intermediate progress via .log() or updateWithLog(). All other progress-heavy operations in this same file (e.g. the ONT Fluidigm split at line 901) correctly use updateWithLog(). This operation's expanded row will show only the start/complete entries, not the import progression.

**Suggested fix:** Use OperationCenter.shared.updateWithLog(id: opID, progress: progress, detail: message) in place of the bare update() call.

### F31 [D3/low/user-visible/effort-S] Metagenomics import progress stream calls OperationCenter.update() without .log()

`Sources/LungfishApp/App/AppDelegate+ImportCenter.swift:737`

In the NAO-MGS/metagenomics import flow, the progress handler passed to MetagenomicsImportHelperClient.importViaCLI (which parses and forwards many structured progress events from the helper subprocess) calls only `OperationCenter.shared.update(id:progress:detail:)`. No `.log()` call accompanies it, so none of the streamed progress messages are recorded in the operation's log history, unlike the CLI*Runner files in Sources/LungfishApp/Services which consistently pair update with log for their streaming progress.

**Suggested fix:** Add `OperationCenter.shared.log(id: opID, level: .info, message: message)` next to the `.update()` call in this closure, or switch to `.updateWithLog(...)`.

### F32 [D3/low/user-visible/effort-M] Batch-import progress updates (multiple call sites) drop history via bare .update()

`Sources/LungfishApp/App/AppDelegate+ImportCenter.swift:1130`

Lines 1130, 1148, 1171, 1192, 1215, 1269, 2174, and 2408 in AppDelegate+ImportCenter.swift each call `OperationCenter.shared.update(id: opID, progress: clampedProgress, detail: displayMessage)` inside per-file progress callbacks for batch import/build operations, with no adjacent `.log()` call anywhere in the surrounding scope for that message stream. Unlike the CLI*Runner services (CLIImportRunner, CLIMSAActionRunner, CLITreeInferenceRunner, etc.) which consistently pair every streaming `.update()` with a `.log()`, these AppDelegate+ImportCenter call sites only ever update the visible progress bar/detail text, so the Operations Panel's expanded history for these operations is permanently incomplete.

**Suggested fix:** Audit each of these 8 call sites and add a paired `.log(id: opID, level: .info, message: displayMessage)` call, consistent with the pattern used in the Services/CLI*Runner.swift files.

### F33 [D3/low/user-visible/effort-S] Force-unwrapped Int() conversion on regex capture of external tool output

`Sources/LungfishWorkflow/Assembly/SPAdesOutputParser.swift:195`

`parseStageMarker` matches `/^K(\d+)$/` against a line from SPAdes stderr/log output (external process output, not app-controlled) and then does `let k = Int(kMatch.1)!`. While the regex guarantees the captured text is all digits, an arbitrarily long digit string (e.g. a corrupted/garbled log line, or a future SPAdes version emitting a huge k-mer-like token) would overflow `Int` and make `Int(...)` return nil, crashing the whole app via force unwrap while simply trying to render progress UI for an assembly run.

**Suggested fix:** Replace `Int(kMatch.1)!` with `guard let k = Int(kMatch.1) else { return SPAdesProgress(stage: .assembling, fraction: nil, message: inner) }` (or similar fallback) so malformed/oversized digit strings degrade gracefully instead of crashing.

### F45 [D4/low/user-visible/effort-M] formatCount duplicated 6+ times with inconsistent grouped-vs-abbreviated output

`Sources/LungfishApp/Views/Viewer/FASTQDatasetViewController.swift:2670`

`formatCount` is independently reimplemented in at least 6 files with two incompatible styles: grouped-decimal via NumberFormatter (VCFDatasetViewController.swift:358 using a cached `Self.countFormatter`, DocumentSection.swift:1505 constructing a fresh NumberFormatter per call) versus K/M-abbreviated (FASTQDatasetViewController.swift:2670, TaxonomySunburstView.swift:547, both identical `%.1fM`/`%.1fK` logic; BarcodeScoutSheet.swift:392 and FASTQChartViews.swift:273 similar). A count of 1,234 renders as "1,234" in some views and "1.2K" in others with no principled reason tied to context.

**Suggested fix:** Consolidate into one or two named LungfishKit helpers (e.g. `formatGroupedCount` and `formatAbbreviatedCount`) and have all call sites pick the appropriate one explicitly, removing the private per-file duplicates.

### F46 [D4/low/user-visible/effort-S] formatDuration duplicated with divergent output formats

`Sources/LungfishApp/Views/Inspector/Sections/DocumentSection.swift:1280`

`formatDuration` exists independently in ProvenanceSection.swift:470 (`%.2f s` / `%.1f min` / `%.2f hr`) and DocumentSection.swift:1280 (`%.0fs` under a minute, else `Xm Ys` with no space), plus a third free function `formatElapsedTime` in OperationsPanelController.swift:1546. All three format the same conceptual TimeInterval/Double duration for provenance/operation display but produce visibly different strings for the same input.

**Suggested fix:** Promote one duration formatter to LungfishKit and replace the two private per-file copies plus the OperationsPanelController free function.

### F52 [D4/low/user-visible/effort-S] Bundle isBundleURL checks are inconsistent: some use the shared ReferenceBundleEnvelope helper, others silently reimplement an extension-only check

`Sources/LungfishIO/Bundles/TwelveSAmpliconResultBundle.swift:7`

`ReferenceBundleEnvelope.isBundleURL(url:directoryExtension:manifestFilename:)` (Bundles/ReferenceBundleEnvelope.swift:40) was introduced as the canonical 'consume-side' bundle check that requires both a matching extension AND a manifest file on disk, distinct from a separate 'produce-side' `hasBundleExtension` that is extension-only. `TwelveSReferenceBundle.isBundleURL` and `MHCAmpliconReferenceBundle.isBundleURL` correctly delegate to it. But `TwelveSAmpliconResultBundle.isBundleURL` (line 7) and `ONTGenotypeResultBundle.isBundleURL` (ONTGenotypeResultBundle.swift:2060) each independently reimplement only the extension check (`url.pathExtension.lowercased() == directoryExtension`), silently skipping the manifest-presence guard the envelope pattern was designed to enforce. TwelveSAmpliconResultBundle.isBundleURL is used for consume-side identification (AppDelegate+ImportCenter.swift:909, ResultBundleSampleMetadataResolver.swift:61), so any directory that merely has a `.lungfish12s`/`.lungfishgenotype`-style extension but no manifest will be misidentified as a valid result bundle where the envelope-based bundles would correctly reject it.

**Suggested fix:** Route TwelveSAmpliconResultBundle.isBundleURL and ONTGenotypeResultBundle.isBundleURL through ReferenceBundleEnvelope.isBundleURL (adding a manifestFilename constant to each if missing) to match the convention already established for TwelveSReferenceBundle/MHCAmpliconReferenceBundle, and add hasBundleExtension for any produce-side-only callers.

### F7 [D2/low/user-visible/effort-L] buildSidebarTree does N synchronous JSON/fileExists probes per FASTQ bundle node during tree construction

`Sources/LungfishApp/Views/Sidebar/SidebarViewController.swift:1339`

For every .fastqBundle node, buildSidebarTree(from:isRoot:) synchronously calls FASTQBundle.processingState, FASTQBundle.loadDerivedManifest, FASTQBatchManifest.load, collectDemuxChildBundles (which itself recursively re-scans the whole demux/ subtree with FileManager.contentsOfDirectory), FASTQBundle.scanDerivatives, and an additional contentsOfDirectory scan for top-level .lungfishfastq bundles (lines 1463-1475) — plus collectNaoMgsResults and collectNvdResults per directory (each doing their own contentsOfDirectory + per-child JSON decode). Because this is called once per bundle node recursively for the whole project tree, cost scales as O(bundles × subtree size) of synchronous disk I/O, compounding the finding above but specifically flagging that even a partial/incremental rescan (updateSidebar's per-top-level-item buildSidebarTree call at line 1111) pays this full recursive cost for just one changed top-level item.

**Suggested fix:** Same remediation as the full-scan finding: hoist the whole build (both buildRootItems and the more targeted updateSidebar path) off the main actor, or at minimum cache per-bundle manifest/derivative scan results keyed by mtime so unrelated tree rebuilds don't re-read every sidecar.

### F9 [D2/low/user-visible/effort-S] NAO-MGS import validation scans filesystem synchronously on the main actor before the first await

`Sources/LungfishApp/Views/Metagenomics/NaoMgsImportSheet.swift:258`

validateResults(at:) launches a plain `Task { ... }` (not detached) from a SwiftUI View (implicitly @MainActor). Inside, `fm.fileExists(atPath:isDirectory:)` (line 264) and, for directories, `findVirusHitsFiles(in: url)` (line 268, which calls `fm.contentsOfDirectory` at line 311) execute synchronously before the task reaches its first `await parser.validateHeader(...)`. Because the Task inherits the caller's MainActor context and hasn't suspended yet, this directory listing runs on the main thread, blocking the UI while scanning the user-selected (potentially large) directory.

**Suggested fix:** Wrap the fileExists/findVirusHitsFiles work in Task.detached or hop off-actor before touching FileManager, mirroring the pattern already used in NvdImportSheet.swift's nvdScanDirectory free function.

### F10 [D2/low/effort-S] Disk-space precheck performs synchronous file I/O on the main actor before assembly starts

`Sources/LungfishApp/Views/Assembly/AssemblyConfigurationViewModel.swift:85`

checkDiskSpace(inputFiles:outputDirectory:) (line 761) is called directly from the @MainActor runValidated(request:) (line 85) and run(config:) (line 153) entry points, both invoked synchronously from the UI action that launches an assembly. It calls FileManager.default.attributesOfItem(atPath:) for every input file and outputDirectory.resourceValues(forKeys:) — all synchronous filesystem stats — before the background Task.detached is even created. For a handful of local FASTQ files this is fast, but it still adds avoidable main-thread I/O between the button click and the operation actually starting, and would scale poorly for larger input sets or network-mounted volumes.

**Suggested fix:** Move the disk-space check inside the Task.detached that performs the actual run, updating the OperationCenter entry and aborting with a failure state if insufficient space is found, rather than blocking the UI thread before the operation is registered.

### F3 [D2/low/effort-S] deinit invalidates trackLoadingAnimationTimer but not scrollRedrawTimer

`Sources/LungfishApp/Views/Viewer/SequenceViewerView.swift:964`

scrollWheel() (SequenceViewerView+Interaction.swift:1609-1610) schedules a one-shot 1/60s Timer stored in the `scrollRedrawTimer` property to coalesce pan redraws. deinit (SequenceViewerView.swift:964-967) invalidates trackLoadingAnimationTimer and removes NotificationCenter observers, but never calls scrollRedrawTimer?.invalidate(). If the view is torn down (e.g. closing the document/tab) within the ~16ms window after the last scroll event, the pending timer still fires later; its closure captures [weak self] so it no-ops safely, but the Timer keeps the RunLoop alive briefly and represents an uncancelled stored timer at teardown, inconsistent with the pattern used for the other timer just above it.

**Suggested fix:** Add `scrollRedrawTimer?.invalidate()` alongside `trackLoadingAnimationTimer?.invalidate()` in deinit.

### F42 [D4/low/effort-S] AIAssistantWindowController is dead code — never instantiated

`Sources/LungfishApp/Views/AI/AIAssistantPanel.swift:39`

`AIAssistantWindowController` (public class, lines 39-125, ~90 lines including a floating NSPanel setup, togglePanel/showPanel positioning logic, and an AIAssistantAccessibilityID.window identifier) is never constructed anywhere in the codebase. A repo-wide search for `AIAssistantWindowController(` finds zero call sites in Sources/ or Tests/. The actual AI assistant UI is embedded directly via `AIAssistantViewController(service:)` in `Sources/LungfishApp/Views/Inspector/InspectorView.swift:1301`, which bypasses the window-controller entirely. The floating-panel presentation path (including mainWindow-relative positioning/off-screen-clamping logic) is unreachable.

**Suggested fix:** Delete AIAssistantWindowController (lines 39-125) if the floating-panel presentation is confirmed abandoned in favor of the embedded Inspector panel, or wire it up if a floating AI assistant window was intended to ship. Verify with the feature owner before deleting since it defines its own accessibility identifier that may be referenced in UI tests.

### F43 [D4/low/effort-M] AppDelegate+ImportCenter.swift mixes import and export responsibilities, undermining its name

`Sources/LungfishApp/App/AppDelegate+ImportCenter.swift:2225`

The file is named/organized as the 'Import Center' (MARK: - Import Center URL-Accepting Methods at line 15) but roughly the last 1000 of its 3211 lines (from `exportSequences` at line 2225 through `showExportSuccess` at line 3200) implement sequence export, batch export, and viewer graphics export panels — a distinct responsibility with no import relationship. 23 import-related functions vs 17 export-related functions/references live in the same file.

**Suggested fix:** Extract the export-related methods (exportSequences, presentBatchSequenceExport, presentViewerGraphicsExportPanel, viewerExportData, viewerExportViewAndRect, showExportSuccess, and related helpers from ~line 2225-3211) into a new `AppDelegate+ExportCenter.swift`, mirroring the existing +ImportCenter/+ImportExport split pattern already present in the same directory.

### F48 [D4/low/effort-L] Second god-file: single struct spans ~3,600 lines, twin to +OverrideScript.swift (3,878 lines)

`Sources/LungfishWorkflow/ONTGenotyping/GenotypeWorkbookRevisionService.swift:148`

GenotypeWorkbookRevisionService (declared at line 148) runs to the end of a 3,780-line file, and its companion extension file GenotypeWorkbookRevisionService+OverrideScript.swift adds another 3,878 lines to the same type — together nearly 7,660 lines for one service. This mirrors the FullLengthONTMHCGenotypingPipeline pattern: a single type accreting most of a subsystem's logic rather than being decomposed into collaborating types.

**Suggested fix:** Identify cohesive sub-responsibilities (e.g. override-script generation, fingerprinting, provenance publication) and extract them into separate collaborator types rather than more same-type extension files, so each file stays reviewable and testable in isolation.

### F50 [D4/low/effort-M] RFC4180 CSV/TSV parser reimplemented 4 separate times instead of reusing shared DelimitedLineParser

`Sources/LungfishCore/Models/SampleMetadataResolver.swift:28`

LungfishCore already provides a public, quote-aware CSV/TSV field parser (`DelimitedLineParser.fields(in:delimiter:)` at SampleMetadataResolver.swift:28), correctly used by SampleMetadataStore.swift, FASTQBundleCSVMetadata.swift, and SRARunInfoCSVParser.swift. But at least four other sites reimplement RFC4180 quote-doubling CSV parsing independently: NvdResultParser.swift:513 (`parseCSVRow`), ONTGenotypeResultBundle.swift:3759 (`parseCSV`), VariantDatabase+SampleMetadata.swift:277 (`parseDelimitedLine`), and SRAAccessionParser.swift:65 (`parseCSV`). The VariantDatabase+SampleMetadata.swift version in particular has more convoluted quote-toggle state (`prevWasQuote` flag) than the shared parser and is a plausible source of divergent edge-case behavior (e.g. embedded delimiters right after a closing quote) versus the canonical implementation.

**Suggested fix:** Migrate the four independent parsers to call the existing `DelimitedLineParser.fields(in:delimiter:)` from LungfishCore, deleting the duplicated quote-handling loops. Add a regression test asserting all metadata/CSV import call sites share one implementation.

### F53 [D4/low/effort-S] SQLITE_TRANSIENT destructor constant redefined independently in 17 files

`Sources/LungfishIO/Formats/ClassifierSQLiteDatabaseSupport.swift:31`

The `unsafeBitCast(-1, to: sqlite3_destructor_type.self)` idiom for SQLite's SQLITE_TRANSIENT is copy-pasted as a private static constant in 17 separate files across LungfishIO/LungfishCore (ClassifierSQLiteDatabaseSupport.swift:31, NaoMgsDatabase.swift, NvdDatabase.swift, KrakenIndexDatabase.swift, Kraken2Database.swift, TaxTriageDatabase.swift, EsVirituDatabase.swift, ProjectUniversalSearchIndex+SQL.swift, NaoMgsBamMaterializer.swift, MultipleSequenceAlignmentBundle+SQLite.swift, VariantDatabaseSQLiteSupport.swift, GenBankRecordDatabase.swift, VariantDatabase+Cache.swift, AnnotationDatabase+Query.swift, AlignmentMetadataDatabase.swift, PhylogeneticTreeIndexWriter.swift, and LungfishCore/Storage/ProjectStore.swift:1038) instead of being defined once in a shared SQLite helper.

**Suggested fix:** Add a single `public let SQLITE_TRANSIENT: sqlite3_destructor_type` (or namespaced constant) to a shared SQLite-support file in LungfishCore and have all 17 sites reference it, removing the private redefinitions.

### F57 [D4/low/effort-S] Provenance popover card scaffold duplicated between NvdProvenanceView and NaoMgsProvenanceView

`Sources/LungfishNvdUI/NvdProvenanceView.swift:8`

NvdProvenanceView (53 lines) and NaoMgsProvenanceView (52 lines) both implement an identical card layout (VStack with title/Divider, private `provenanceRow(_:_:)` label/value HStack helper, private `formatDate(_:)` using a freshly-constructed DateFormatter, same .padding(12)/.frame(width:320)) with only the manifest fields and title text differing. This kernel-shaped presentation helper is copy-pasted rather than shared.

**Suggested fix:** Add a generic `ProvenancePanelView` (title + [(label,value)] rows) to LungfishKit that both leaves configure with their own manifest-derived rows, eliminating the duplicated provenanceRow/formatDate/layout boilerplate.

### F58 [D4/low/effort-M] defaultLeadingFraction(for:)/ensureBlastDrawer() duplicated across metagenomics leaves

`Sources/LungfishNaoMgsUI/NaoMgsResultViewController.swift:1`

defaultLeadingFraction(for layout: MetagenomicsPanelLayout) -> CGFloat is byte-identical across NaoMgsResultViewController, NvdResultViewController, and EsVirituResultViewController (case .detailLeading/.stacked -> 0.4, case .listLeading -> 0.6); TaxTriageResultViewController has a different mapping. Separately, ensureBlastDrawer() -> BlastResultsDrawerTab (constructs a BlastResultsDrawerContainerView, pins it to view edges and actionBar.topAnchor with a height constraint) is duplicated near-verbatim in the same three leaves. Since MetagenomicsPanelLayout and BlastResultsDrawerTab/Container are already kernel (LungfishKit) types, these per-leaf wrapper functions are prime candidates to become a shared default in LungfishKit rather than re-implemented per leaf.

**Suggested fix:** Add a default implementation of the leading-fraction mapping as a static/extension on MetagenomicsPanelLayout in LungfishKit (leaves can still override where UX intentionally differs, as TaxTriage does), and add a `BlastResultsDrawerTab.attach(to:above:)`-style kernel helper that leaves call instead of re-authoring the container+constraints block.

### F60 [D4/low/effort-S] GenotypeActiveHaplotypeAnalysisResolver is a zero-value pass-through wrapper used inconsistently

`Sources/LungfishCLI/Support/GenotypeActiveHaplotypeAnalysisResolver.swift:5`

The CLI-local `GenotypeActiveHaplotypeAnalysisResolver` enum simply forwards all three of its static methods unchanged to `LungfishWorkflow.GenotypeHaplotypeAnalysisResolver` (same signatures, same implementation, no CLI-specific logic added). Four call sites (GenotypeXlsxWorkbookWriter, GenotypeExportPivotXlsxSubcommand, GenotypeExportSubcommand, GenotypeExportXlsxSubcommand, GenotypeExportLabKeySubcommand) go through this indirection, while GenotypeAIHaplotypingSubcommand.swift calls `LungfishWorkflow.GenotypeHaplotypeAnalysisResolver` directly for the equivalent `resultByResolvingActiveAnalysis` operation. This split creates two names for the same capability in the same module with no functional difference, increasing the chance a future signature change in the workflow resolver is applied to only one of the two call patterns.

**Suggested fix:** Delete the wrapper and call LungfishWorkflow.GenotypeHaplotypeAnalysisResolver directly at all five call sites (matching the pattern already used in GenotypeAIHaplotypingSubcommand.swift), or if a CLI-specific seam is genuinely needed for testing, document why and add the one method GenotypeAIHaplotypingSubcommand needs.


## Multi-bundle behavior inventory (D1/D1b)

### Kraken2 Classification (ClassificationWizardSheet)

- Surface: `Sources/LungfishApp/App/AppDelegate+ToolsMenu.swift:206-231 (folder path) and :233-237 (sidebar multi-select) -> ClassificationWizardSheet.swift:154-156,578-606 -> AppDelegate+Classification.swift:43-54,713-1083`
- Multi-select possible: True; current behavior: **pooled**
- CLI: `conda classify --db <path> <files...>` — multi-input: multiple-args
- Correctly handles N>1: selectedFileURLs() preserves all sidebar selections into `preferredInputURLs`->`selectedInputURLs`; ClassificationWizardSheet groups them via MetagenomicsSampleGrouper into one ClassificationConfig per logical sample and emits `[ClassificationConfig]`; runClassification(configs:) dispatches to runClassificationBatch when count>1, running each sample serially and aggregating into one batch result directory with SQLite + summary TSV. This is the correct/expected pattern other tools should be compared against. CLI `conda classify` treats multiple positional files as one paired-end sample, not a batch — CLI has no batch-classify subcommand, so GUI batch mode has no CLI equivalent.

### EsViritu Detection (EsVirituWizardSheet)

- Surface: `AppDelegate+ToolsMenu.swift:233-237 -> EsVirituWizardSheet.swift:141-156,506-528 -> AppDelegate+Classification.swift:452-463,1086-1393`
- Multi-select possible: True; current behavior: **pooled**
- CLI: `esviritu detect --input <files...> --sample <name>` — multi-input: pooled-flag
- Same pattern as Kraken2: MetagenomicsSampleGrouper groups multiple selected bundles into per-sample EsVirituConfig entries; runEsViritu(configs:) batches via runEsVirituBatch when count>1, one EsViritu run per sample, aggregated batch directory + sqlite + summary TSV. Correctly supports N>1. CLI --input accepts multiple files but they are pooled into a single sample run, not split into per-sample batch runs like the GUI.

### TaxTriage (TaxTriageWizardSheet)

- Surface: `AppDelegate+ToolsMenu.swift:233-237 -> TaxTriageWizardSheet.swift:598-704 -> AppDelegate+Classification.swift:1399-1621`
- Multi-select possible: True; current behavior: **pooled**
- CLI: `taxtriage --input <files...>` — multi-input: multiple-args
- populateFromInitialFiles groups all selected input files (from multiple bundles) into a `samples` array by R1/R2 basename pairing; a single TaxTriageConfig carries the whole samples list and sourceBundleURLs (recorded when parentDirs.count>1) so cross-ref sidecars are written back into every contributing bundle after the run (writeTaxTriageCrossRefSidecars, line 1628). One Nextflow run processes all samples together. Correctly supports N>1 as a single pooled run, distinct from Kraken2/EsViritu's per-sample batch-of-runs model but still N-bundle-aware.

### Orient Reads (OrientWizardSheet + runOrientReads)

- Surface: `Sources/LungfishApp/Views/Metagenomics/OrientWizardSheet.swift:49-256; Sources/LungfishApp/App/AppDelegate+ToolsMenu.swift:1128 (runOrientReads)`
- Multi-select possible: False; current behavior: **first-only**
- DEAD CODE, not a live multi-bundle bug: grep confirms `OrientWizardSheet` is never instantiated anywhere in Sources/ and the private `runOrientReads(config:)` in AppDelegate+ToolsMenu.swift is never called. The live orient-reads path today is FASTQOperationDialogState/FASTQOperationToolPanes.swift (case .orientReads at lines 414-425, 737-739), which routes through the generic `pendingLaunchRequest`/`selectedInputURLs` mechanism shared by all FASTQOperationsDialog tools -- not this file. OrientWizardSheet.performRun() (line 240-255) does `inputFiles.first` and silently ignores the rest of `inputFiles`, so if this sheet were ever wired up with a multi-selection it would silently drop bundles 2..N with zero UI indication (no disabled state, no warning) -- flagging as a maintainability/trap-for-future-reviver finding given it's stale, unreferenced code sitting in the Metagenomics UI folder.

### NAO-MGS / NVD / CZ-ID Import Sheets

- Surface: `AppDelegate+ToolsMenu.swift:367-392 (NaoMgs), :441-466 (Nvd), :468-503 (CzId) -- all called with datasetURL/hardcoded nil, no sidebar-selection wiring`
- Multi-select possible: False; current behavior: **n/a**
- CLI: `import nvd <path> / import cz-id <path>` — multi-input: n/a
- By design, not a sidebar-multi-select surface: these three sheets are external-results importers -- the user browses to a single results directory/file via a file picker inside the sheet (NaoMgsImportSheet.swift selectedPath, similarly Nvd/CzId), completely independent of sidebar bundle selection. Sidebar selection state is never read or passed in. Excluded from the pooled/first-only/etc. taxonomy since there is no bundle-selection input to begin with; correctly out of scope for the D1 multi-bundle inventory as a 'not applicable' surface.

### Map Reads (minimap2 / BWA-MEM2 / Bowtie2 / BBMap)

- Surface: `Sources/LungfishApp/App/AppDelegate+ToolsMenu.swift:44-46,94-181,832 (showFASTQMappingOperations -> showFASTQOperationsDialog -> runManagedMapping); wizard: Sources/LungfishApp/Views/Mapping/MappingWizardSheet.swift:59-126; embed: Sources/LungfishApp/Views/FASTQ/FASTQOperationToolPanes.swift:13-21`
- Multi-select possible: True; current behavior: **pooled**
- CLI: `lungfish map` — multi-input: multiple-args
- Tools menu item has no selection-count enablement check; N>1 sidebar selection flows into state.selectedInputURLs -> MappingWizardSheet(inputFiles:) unchanged. buildRequest constructs ONE MappingRunRequest with inputFASTQURLs = ALL selected files pooled (paired-end detection just picks the first 2 files by convention). runManagedMapping (AppDelegate+ToolsMenu.swift:832) executes this single request directly via OperationCenter/Task.detached -- it does NOT go through FASTQOperationPlanner's per-input split logic (that split at FASTQOperationPlanner.swift:319-332 only fires for the separate pendingLaunchRequest/.derivative code path, which captureMappingRequest bypasses by setting pendingMappingRequest instead). Net effect: selecting 2+ unrelated FASTQ bundles and mapping produces ONE co-mapped BAM against one reference, not per-bundle BAMs, with zero warning. Read-group @RG SM/ID/LB/PU tags are derived from inputFiles.first only (MappingWizardSheet.swift:117), so the pooled BAM's header misattributes all reads to the first-selected sample. CLI 'lungfish map' (MapCommand.swift:36) takes multiple positional args but treats them as R1/R2 mate pairs of a single sample (paired-mode expects exactly 2), i.e. the CLI has no multi-sample batching either; GUI and CLI are consistent in NOT supporting true multi-bundle batch mapping, but the GUI gives no indication that pooling occurred.

### Genome Assembly (SPAdes / MEGAHIT / SKESA / Flye / Hifiasm) - main Tools menu entry

- Surface: `Sources/LungfishApp/App/AppDelegate+ToolsMenu.swift:48-50,94-181 (showFASTQAssemblyOperations -> showFASTQOperationsDialog -> pendingLaunchRequest .assemble path); wizard: Sources/LungfishApp/Views/Assembly/AssemblyWizardSheet.swift:55-117,699-727; planner: Sources/LungfishApp/Services/FASTQOperationPlanner.swift:334-355; embed: Sources/LungfishApp/Views/FASTQ/FASTQOperationToolPanes.swift:34-43`
- Multi-select possible: True; current behavior: **pooled**
- CLI: `lungfish assemble` — multi-input: multiple-args
- No selection-count enablement gate on the Tools menu item. Unlike mapping, this path DOES flow through FASTQOperationPlanner (captureAssemblyRequest sets pendingLaunchRequest = .assemble(request:, outputMode:), and AppDelegate's onRun handler dispatches pendingLaunchRequest through originSplit.runFASTQOperationLaunchRequest, which uses the planner). The planner's splitExecutionRequestsIfNeeded DOES special-case .assemble to split into N per-file assembly runs when outputMode==.perInput (the default) AND inputURLs.count>1 AND originalAssemblyRequest.pairedEnd==false (FASTQOperationPlanner.swift:338-343). However AssemblyWizardSheet computes pairedEnd=true (AssemblyWizardSheet.swift:708-712) whenever the pooled input list's R1/R2 files pair up 1:1 across ALL selected files with no unpaired stragglers -- exactly what happens when the user selects 2+ normal paired-end Illumina bundles together. In that (very common) case the split guard is false, execution falls through to the planner's `default:` case (line 391-392) which returns the ORIGINAL unsplit pooled request, so all selected bundles' reads get assembled together into one contig set under one project name -- silently co-assembling unrelated samples. Non-paired-end long-read tools (Flye/Hifiasm) separately reject N>1 inputs via a distinct UI validation message ('expects a single FASTQ input in v1', AssemblyWizardSheet.swift:216-219) rather than the planner split, so those tools DO block (disabled via canRun/validationMessage) rather than pool. CLI 'lungfish assemble' (AssembleCommand.swift:68) takes 1 or 2 positional args (--paired for R1/R2 of ONE sample); no multi-sample batch support, consistent with GUI intent for single-sample assembly but the GUI silently violates that intent for pooled paired-end multi-bundle selections.

### Reassemble... (sidebar context menu, reference-bundle re-run using stored provenance)

- Surface: `Sources/LungfishApp/Views/Sidebar/SidebarViewController+MenuDelegate.swift:116,141-146 (menu construction gate) and :752-801 (contextMenuReassemble handler); presenter: Sources/LungfishApp/Views/Assembly/AssemblyConfigurationViewController.swift:51-106`
- Multi-select possible: False; current behavior: **disabled**
- Menu construction explicitly wraps the 'Reassemble...' item in `if items.count == 1 && hasBundles` (line 116) and again checks bundle-has-assembly-provenance for that single item (line 142), so the item is entirely absent from the context menu whenever N>1 items are selected -- N>1 is unreachable for this specific action, not silently mishandled. The handler itself still defensively uses `items.first` (line 754) as a second-layer guard, consistent with single-item design.

### Viral Recon (nf-core/viralrecon SARS-CoV-2 pipeline)

- Surface: `Sources/LungfishApp/Views/Mapping/ViralReconWizardSheet.swift:5-16,649-714; capture: Sources/LungfishApp/Views/FASTQ/FASTQOperationDialogState.swift:899-910; embed: Sources/LungfishApp/Views/FASTQ/FASTQOperationToolPanes.swift:24-32`
- Multi-select possible: True; current behavior: **other (per-sample batch by design, not pooled)**
- Included for contrast, not a finding: ViralReconWizardInputPolicy.resolveInputs (ViralReconWizardSheet.swift:659-672) maps EACH selected URL independently into its own ViralReconResolvedInput (sampleName, fastqURLs, platform), producing a proper multi-sample array that nf-core/viralrecon consumes natively as a batch samplesheet. This is the one tool in scope where N>1 selection is intentionally and correctly supported as distinct per-sample entries in a single pipeline invocation, unlike Map/Assemble which silently pool bytes into one run.

### ONT/Illumina amplicon genotyping (fastq operations dialog, .ontGenotyping)

- Surface: `Sources/LungfishApp/Views/FASTQ/FASTQOperationDialogState.swift:1335-1360 (validation), :721-745 (config build), :1584-1590 (mode inference)`
- Multi-select possible: True; current behavior: **pooled**
- CLI: `lungfish-cli fastq genotype` — multi-input: multiple-args
- Genuine multi-bundle inventory fact, not a bug. When sidebar selection yields >1 input URL, ontGenotypingUsesPreparedSampleInputs flips true automatically (line 1584: selectedInputURLs.count > 1 => true), switching mode to .ontSampleBundles and passing the full selectedInputURLs array as inputFASTQURLs (line 725) — i.e. all selected FASTQ bundles are pooled into one batch genotyping run/report. Single-selection stays in .ontBarcodeDemux mode requiring exactly one dataset. Output is .fixedBatch (line 1973). CLI 'fastq genotype' takes [String] inputs and documents 'Sample-bundle modes accept multiple prepared per-sample bundles' — matches GUI behavior. No menu-level enablement check; dialog validates internally.

### MAFFT alignment (fastq operations dialog, .mafft, invoked from Tools > Alignment with sidebar selection as input source)

- Surface: `Sources/LungfishApp/Views/FASTQ/FASTQOperationDialogState.swift:752-776 (makeMSAAlignmentRequest), :1970 (.fixedBatch)`
- Multi-select possible: True; current behavior: **pooled**
- Multiple selected FASTA/reference bundles are pooled: inputSequenceURLs: selectedInputURLs passes ALL selected inputs into one MAFFT run (.fixedBatch mode, consistent with N-sequence MSA semantics). LOW-SEVERITY correctness/UX finding: the output bundle's default name is derived only from selectedInputURLs.first (line 757: 'selectedInputURLs.first?.deletingPathExtension().lastPathComponent ?? "MAFFT Alignment"'), so a 5-bundle selection silently produces an output named after just the first bundle (e.g. 'SampleA Alignment') even though it actually merges all 5 inputs. No functional data loss — the request itself correctly includes every selected URL — but the auto-generated name misrepresents the run's scope to the user reviewing project files/history later.

### Savont clustering (.savont) / pbaa clustering (.pbaa)

- Surface: `Sources/LungfishApp/Views/FASTQ/FASTQOperationDialogState.swift:1971 (.perInput), Sources/LungfishApp/Services/FASTQOperationPlanner.swift:64`
- Multi-select possible: True; current behavior: **silent-iterate**
- Correctly implemented per-bundle iteration (.perInput output mode): each selected FASTQ dataset is clustered independently, producing one result per input bundle. Verified as working design, not a bug.

### 12S Amplicon Matching workflow (WorkflowLibrary twelveSAmpliconMatchingItem, launched via WorkflowOperationsDialog with sidebar selection)

- Surface: `Sources/LungfishApp/Services/WorkflowSidebarInputSelection.swift:110-217 (resolve), Sources/LungfishApp/Services/WorkflowLibrary.swift:138-144`
- Multi-select possible: True; current behavior: **pooled**
- CLI: `lungfish-cli fastq 12s-match` — multi-input: multiple-args
- Multiple selected sidebar items (fastqBundle/folder/project) are deduplicated and pooled into directReadURLs/recursiveReadURLs (batch), with UI summary text explicitly stating 'They will run as one batch.' when >1 folder selected. Matches CLI 12s-match which takes [String] inputs. No bug found; correctly surfaced pooling.

### IQ-TREE tree inference (Phylogenetics)

- Surface: `Sources/LungfishApp/Views/Phylogenetics/IQTreeInferenceDialogPresenter.swift:10-47`
- Multi-select possible: False; current behavior: **n/a**
- Not a sidebar multi-select surface. Takes a single MultipleSequenceAlignmentTreeInferenceRequest scoped to one already-open MSA bundle (invoked from within the MSA viewer, not the sidebar context menu). One-tree-per-alignment is the correct/only sensible semantics here; N>1 sidebar selection is not applicable to this entry point.

### BAM primer trim (ivar-based)

- Surface: `Sources/LungfishApp/Views/BAM/BAMPrimerTrimDialogPresenter.swift:14-58, invoked from Sources/LungfishApp/Views/Inspector/InspectorViewController+TrimDuplicateWorkflows.swift:65`
- Multi-select possible: False; current behavior: **n/a**
- CLI: `lungfish-cli bam primer-trim (BAMPrimerTrimSubcommand)` — multi-input: n/a
- Not a sidebar multi-select surface. Scoped to a single bundle: ReferenceBundle passed in from the Inspector for the currently open/selected single bundle's alignment track — there is no path from sidebar N-bundle selection to this dialog. CLI --bundle option is likewise single-path only.

### BLAST verification (drawer)

- Surface: `Sources/LungfishApp/Views/Viewer/FASTACollectionViewController.swift:726 (ensureBlastDrawer), Sources/LungfishKit/BlastResultsDrawerContainerView.swift`
- Multi-select possible: False; current behavior: **n/a**
- CLI: `lungfish-cli blast verify` — multi-input: n/a
- Not a sidebar multi-select surface. Launched from the single open FASTA/taxonomy viewer's results drawer, scoped to the currently displayed sequence collection — no sidebar-selection code path reaches it.

### FASTQ Operations dialog (all categories: QC, demux, trim, decontam, read-processing, search/subset, alignment, mapping, assembly, clustering, classification-non-folder, genotyping)

- Surface: `Sources/LungfishApp/App/AppDelegate+ToolsMenu.swift:94-238 (showFASTQOperationsDialog), gatherFASTQOperationInputURLs:240-253, resolveFASTQOperationInputURLs:308-329`
- Multi-select possible: True; current behavior: **pooled**
- CLI: `lungfish conda classify <files...> (ClassifyCommand.swift) / lungfish map (MapCommand.swift)` — multi-input: multiple-args
- gatherFASTQOperationInputURLs calls sidebarController.selectedFileURLs() (returns ALL selected sidebar items' URLs, not just first) then resolveFASTQOperationInputURLs resolves+dedups each into an array passed as presentOperationsDialog(selectedInputURLs:). All N selected bundles/files are forwarded into the dialog as a single URL array (AppDelegate+ToolsMenu.swift:233-237). Whether the dialog then treats N URLs as 'batch' or 'paired R1/R2' or 'first-only' is decided inside FASTQOperationsDialogPresenter/the wizard view models (Sources/LungfishApp/Views/Operations/, Views/FASTQ/) which are OUT OF SCOPE for this slice — but the selection-plumbing itself is full pass-through, not first-only or disabled.

### Classification (Tools > Classify Reads, when selection includes at least one folder)

- Surface: `Sources/LungfishApp/App/AppDelegate+ToolsMenu.swift:206-231 (classificationFolderInput branch), Sources/LungfishApp/App/ClassificationFolderPrompt.swift:60-68, Sources/LungfishApp/Services/WorkflowSidebarInputSelection.swift:110-217`
- Multi-select possible: True; current behavior: **pooled**
- Only triggers when folderSelectionCount > 0 (at least one folder/project item selected). Pools every eligible FASTQ/FASTA sample found under the selected folder(s) — and other explicitly-selected non-folder bundles in the same selection are silently DROPPED from this path (WorkflowSidebarInputSelection.resolve only walks folder children for folder items; explicit fastqBundle items are also appended via appendDirect/appendRecursive at :161-169, so they ARE included together with folder contents — verified: explicit bundles union with folder-derived bundles in one pooled batch).

### Classification (Tools > Classify Reads, selection has NO folders — only explicit FASTQ/FASTA/reference bundles, N>1)

- Surface: `Sources/LungfishApp/App/AppDelegate+ToolsMenu.swift:206-237 (falls through to gatherFASTQOperationInputURLs since folderInput.folderSelectionCount == 0)`
- Multi-select possible: True; current behavior: **pooled**
- Falls through to the generic gatherFASTQOperationInputURLs/resolveFASTQOperationInputURLs path (same as other categories) which forwards ALL selected URLs, deduplicated, into the dialog. Downstream handling of the resulting selectedInputURLs.count for the classification tool specifically is decided in the dialog/view-model layer (out of scope) — the finding here is only that selection-plumbing does not disable, does not truncate to first, and does not silently drop bundles for this path.

### Workflow Operations (Tools > Workflow Library / launchWorkflowFromMenu)

- Surface: `Sources/LungfishApp/App/AppDelegate+ToolsMenu.swift:1292-1310 (showWorkflowOperations), resolveWorkflowSidebarInputSelectionForOperations:266-283`
- Multi-select possible: True; current behavior: **pooled**
- resolveWorkflowSidebarInputSelectionForOperations calls WorkflowSidebarInputSelection.resolve(items:projectURL:) over ALL selectedItems() (not just first). Result feeds WorkflowOperationsWindowController.show(selectedReadURLs:sidebarInputSelection:) as a full pooled batch, with summaryText() (WorkflowSidebarInputSelection.swift:88-108) explicitly telling the user e.g. '3 FASTQ bundles selected... They will run as one batch.' This is the most complete/correct multi-select handling in scope — genuinely designed for N>1.

### BAM Variant Calling (Tools > Call Variants, showBAMVariantCalling)

- Surface: `Sources/LungfishApp/App/AppDelegate+ToolsMenu.swift:81-92 (canShowBAMVariantCalling/showBAMVariantCalling), validated at Sources/LungfishApp/App/AppDelegate.swift:1767-1770`
- Multi-select possible: False; current behavior: **first-only**
- Does not read sidebar selection at all. Both the action and its validateMenuItem enablement check use split.viewerController.currentReferenceBundle (the single bundle currently open/displayed in the viewer), completely independent of what is selected in the sidebar. With N bundles selected, this command only ever affects whichever bundle happens to be the active viewer document — sidebar multi-selection is invisible to this tool.

### Sidebar context-menu FASTQ/classification tool launches

- Surface: `Sources/LungfishApp/Views/Sidebar/SidebarViewController+MenuDelegate.swift:16-120 (menuNeedsUpdate)`
- Multi-select possible: False; current behavior: **other (not applicable)**
- Right-click context menu (menuNeedsUpdate) never adds FASTQ-operation/classification/mapping menu items regardless of selection size — those tools are only reachable via the main Tools menu (the AppDelegate+ToolsMenu.swift path above). No multi-select ambiguity exists here because the surface simply isn't offered; recorded for completeness of the inventory since it was checked as part of tracing selection consumers.

### SidebarViewController.selectedItems() / selectedFileURLs() (shared primitives)

- Surface: `Sources/LungfishApp/Views/Sidebar/SidebarViewController+OutlineDataSource.swift:264-277, SidebarViewController.swift:2775-2784`
- Multi-select possible: True; current behavior: **pooled**
- Both correctly iterate outlineView.selectedRowIndexes and return ALL selected items/URLs (not first-only). selectedFileURL (singular, OutlineDataSource.swift:275-277) intentionally returns only the FIRST selected item with a URL — this is a distinct, deliberately single-item accessor used elsewhere (e.g. showWorkflowBuilder at AppDelegate+ToolsMenu.swift:1233 passes preferredSampleURL: sidebarController?.selectedFileURL, silently using only the first of N selected items for Workflow Builder's preferred-sample field with no indication to the user that only one of several selections was used).

### Workflow Builder preferred sample (Tools > Workflow Builder)

- Surface: `Sources/LungfishApp/App/AppDelegate+ToolsMenu.swift:1199-1242, specifically :1233 preferredSampleURL: sidebarController?.selectedFileURL`
- Multi-select possible: True; current behavior: **first-only**
- With N>1 sidebar items selected, only the first selected item with a non-nil url is used to seed the Workflow Builder's preferred sample; the other N-1 selected items are silently dropped with no user-facing indication multi-selection wasn't honored.

### outlineViewSelectionDidChange -> handleSelectionChange -> commitSelectionChange dispatch (selectionDelegate.sidebarDidSelectItem vs sidebarDidSelectItems)

- Surface: `Sources/LungfishApp/Views/Sidebar/SidebarViewController+OutlineDelegate.swift:146-233 (handleSelectionChange/commitSelectionChange)`
- Multi-select possible: True; current behavior: **other (branches on count)**
- commitSelectionChange explicitly branches at :219-223: items.count == 1 calls sidebarDidSelectItem(items.first), items.count > 1 calls sidebarDidSelectItems(items). This is correct dispatch, not a bug — recorded because it's the exact mechanism gating whether downstream single-item vs multi-item consumers (e.g. MainSplitViewController+SidebarSelection.swift, out of scope) ever see a multi-item callback at all. Default protocol extension for sidebarDidSelectItems (SidebarSelectionDelegate.swift:87-88) forwards to sidebarDidSelectItem(items.first) for any delegate that doesn't override it — so any selectionDelegate implementation that hasn't implemented sidebarDidSelectItems degrades silently to first-only for N>1 without a compile error or runtime warning.

### classify (Kraken2)

- Surface: `Sources/LungfishCLI/Commands/ClassifyCommand.swift:43-44,120-138,234`
- Multi-select possible: True; current behavior: **pooled**
- CLI: `lungfish conda classify <file1> [file2 ...] --db X` — multi-input: multiple-args
- @Argument var fastqFiles: [String] is variadic; CLIClassificationFolderResolver.expandInputArguments also expands directories (with --recursive). All resolved inputURLs feed a single ClassificationConfig.inputFiles (one Kraken2 run). --paired requires exactly 2 files; unpaired mode accepts any N>=1 and pools them into one run (multi-FASTQ-file pooling, not multi-bundle in the sidebar sense).

### assemble (SPAdes/MEGAHIT/etc.)

- Surface: `Sources/LungfishCLI/Commands/AssembleCommand.swift:68-69,133,424-450`
- Multi-select possible: False; current behavior: **error**
- CLI: `lungfish conda assemble <file1> [file2] --assembler X` — multi-input: multiple-args
- @Argument [String] but validateAssemblyInputTopology throws ManagedAssemblyPipelineError.unsupportedInputTopology unless pairedEnd&&count==2 or count==1 (flye/hifiasm require exactly 1). N>2 or unpaired N>1 is rejected outright, so effectively caps at 2 (paired) — no true multi-bundle/multi-file pooling beyond a single R1/R2 pair.

### map

- Surface: `Sources/LungfishCLI/Commands/MapCommand.swift:36,110-118,169-200`
- Multi-select possible: True; current behavior: **pooled**
- CLI: `lungfish conda map <file1> [file2 ...] --reference ref.fasta --mapper minimap2` — multi-input: multiple-args
- @Argument [String] fastqFiles; only pairedEnd is validated to require exactly 2, but no check rejects N>2 unpaired — those get materialized and fed through as executionInputURLs together. No per-bundle iteration/summary; behaves as a single pooled mapping job over all inputs.

### orient

- Surface: `Sources/LungfishCLI/Commands/OrientCommand.swift:43-46`
- Multi-select possible: False; current behavior: **disabled**
- CLI: `lungfish conda orient <file> --reference ref.fasta` — multi-input: none
- var fastqFile: String is a single scalar argument (not an array) — CLI has no multi-input support at all for orient, unlike classify/assemble/map.

### esviritu detect

- Surface: `Sources/LungfishCLI/Commands/EsVirituCommand.swift:69,148-149`
- Multi-select possible: True; current behavior: **pooled**
- CLI: `lungfish conda esviritu detect <file1> [file2 ...]` — multi-input: multiple-args
- var inputFiles: [String] = []; same pattern as classify — --paired requires exactly 2, otherwise all files pooled into a single EsViritu run.

### taxtriage run

- Surface: `Sources/LungfishCLI/Commands/TaxTriageCommand.swift:66-90`
- Multi-select possible: False; current behavior: **other (samplesheet-only batch)**
- CLI: `lungfish conda taxtriage run --input R1.fastq [--input2 R2.fastq] --sample NAME   OR   --samplesheet sheet.csv` — multi-input: n/a
- --input/--input2 are scalar Optional<String> (single sample only, no array). The ONLY way to process multiple samples in one invocation is --samplesheet (a CSV path, pre-existing user-authored batch file) — there is no CLI flag that accepts a list of FASTQ files or bundles directly, so this is structurally different from classify/esviritu/map's array-based pooling.

### nao-mgs import / summary

- Surface: `Sources/LungfishCLI/Commands/NaoMgsCommand.swift:60-61,362-363`
- Multi-select possible: False; current behavior: **other (n/a)**
- CLI: `lungfish conda nao-mgs import <dir-or-tsv>` — multi-input: none
- inputPath: String scalar. NAO-MGS isn't a classifier run command in this CLI — it's import/summary of externally-produced results directories, single path only. No multi-input concept applies.

### nvd import / summary

- Surface: `Sources/LungfishCLI/Commands/NvdCommand.swift:54-55,158-159`
- Multi-select possible: False; current behavior: **other (n/a)**
- CLI: `lungfish conda nvd import <dir>` — multi-input: none
- inputPath: String scalar, same import/summary pattern as nao-mgs — no run/classify subcommand exists in the CLI for NVD, so no multi-bundle question applies.

### genotype (FASTQ amplicon genotyping)

- Surface: `Sources/LungfishCLI/Commands/FastqGenotypingSubcommand.swift:12-13`
- Multi-select possible: True; current behavior: **per-bundle-results**
- CLI: `lungfish fastq genotype <bundle1> [bundle2 ...] --mode ont-sample-bundles` — multi-input: multiple-args
- var inputs: [String], help text explicitly documents 'Sample-bundle modes accept multiple prepared per-sample bundles' — genuine N-bundle CLI support, each bundle genotyped and reported per-sample.

### genotype cohort

- Surface: `Sources/LungfishCLI/Commands/FastqGenotypingSubcommand.swift:373-374 (FastqGenotypingCohortSubcommand)`
- Multi-select possible: True; current behavior: **pooled**
- CLI: `lungfish fastq genotype-cohort <bundle1> [bundle2 ...]` — multi-input: multiple-args
- var inputs: [String], help text: 'Each bundle must contain one prepared per-sample FASTQ' — a dedicated cohort subcommand exists specifically to pool/compare multiple bundles into one cohort report, distinct from the per-bundle genotype subcommand above.

### twelve-s match (12S)

- Surface: `Sources/LungfishCLI/Commands/FastqTwelveSMatchSubcommand.swift:13`
- Multi-select possible: True; current behavior: **other (needs deeper trace)**
- CLI: `lungfish fastq twelve-s-match <file1> [file2 ...]` — multi-input: multiple-args
- @Argument accepts file(s) plain or gzip; did not trace downstream pooling vs iteration in depth (out of the 12 finding budget) — flagged here only as an inventory fact that the CLI signature is variadic, unlike orient/taxtriage --input.

### blast / primer trim / bam primer-trim

- Surface: `Sources/LungfishCLI/Commands/BlastCommand.swift, PrimerCommand.swift, BAMPrimerTrimSubcommand.swift`
- Multi-select possible: False; current behavior: **other (no run/classify multi-input surface found)**
- CLI: `n/a` — multi-input: ?
- BlastCommand's top-level struct only exposes a VerifySubcommand (DB verification) in this scope; PrimerCommand only has an ImportSubcommand (primer scheme import, not a trim run against reads); BAMPrimerTrimSubcommand.PrimerTrimSubcommand operates on a single BAM. None of these three exposed a variadic multi-FASTQ/multi-bundle run argument in the code read — could not confirm a 'trim' classify-style command with N-file pooling within this scope; recommend a follow-up if BAM-level primer trim multi-input matters.


## Refuted claims (for the record)

- F19 computeStatistics's String-based record parser uses O(n) String += for wrapped FASTQ sequence/quality lines while the byte-oriented computeSummaryStatistics path avoids it (`Sources/LungfishIO/Formats/FASTQ/FASTQReader.swift`) — refuted: The factual claims check out: forEachRecord does use String += for wrapped sequence/quality lines (lines 258, 288), and computeSummaryStatistics (line 437+) is genuinely byte-oriented and avoids this. / The mechanism is real and unmitigated: forEachRecord (backing computeStatistics, the default interactive stats path) does accumulate currentSequence/currentQuality via String += across wrapped lines, 

- F35 Unsynchronized mutable state in RecipeStepTracker marked @unchecked Sendable (`Sources/LungfishWorkflow/Ingestion/FASTQBatchImporter.swift`) — refuted: Verified against the code: RecipeStepTracker is allocated fresh inside processSingleSample (line 827), scoped to a single sample's recipe execution, and processSingleSample is called sequentially in a / Confirmed the code matches the claim's description (unsynchronized var fields, @unchecked Sendable, mutated in @Sendable progress closure), but the claimed risk is speculative and already mitigated by

- F40 Empty GenomicRegion (start == end) underflows byteOffset calculation to a negative/out-of-range offset (`Sources/LungfishIO/Index/FASTAIndex.swift`) — refuted: The claim mischaracterizes the arithmetic. For region.start==0, region.end==0: startOffset = byteOffset(0, entry) = entry.offset (unchanged, correct). endOffset = byteOffset(-1, entry) + 1. Since byte / The claim's mechanism is wrong. For an empty region (start==end==N), byteOffset(for: region.end - 1) computes N-1's offset via truncating division and Swift's sign-following remainder (e.g. for N=0: l

- F56 resizeDetailContentToFit duplicated verbatim across three leaf modules (`Sources/LungfishNaoMgsUI/NaoMgsResultViewController.swift`) — refuted: The claim is factually wrong about a key detail: TaxTriageResultViewController.swift contains no resizeDetailContentToFit function at all (grep confirms zero matches), contradicting the claim's assert / The claim's central factual assertion is false. `resizeDetailContentToFit` does not exist anywhere in TaxTriageResultViewController.swift or any TaxTriage file (grep -rln across Sources confirms it), 
