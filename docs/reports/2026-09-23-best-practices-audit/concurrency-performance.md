# Concurrency, AppKit Correctness and Performance Audit (PERF)

Date: 2026-09-23. HEAD a1f439076. Reviewer area: Swift concurrency, AppKit correctness, performance.

## Scope, method and limits

**Scope.** Swift 6 concurrency hygiene, main-thread blocking, cancellation and child-process cleanup, stale async results, custom drawing, memory, deprecated macOS APIs, FSEvents and timers. Sources only (`Sources/`, ~700K lines). Tests were not reviewed except where a test seam leaks into production types.

**Method.**
- Pattern inventory with grep and small Python scanners over `Sources/` (counts below). Every finding was then opened and traced by hand from the UI entry point or public API down to the blocking call.
- Isolation was established from the enclosing declaration (`@MainActor` class, `actor`, `nonisolated static`, `Task {}` inherited isolation, `withCheckedThrowingContinuation` body executing on the caller's executor).
- Cheap standalone measurements in the session scratchpad (no SwiftPM, no app build):
  - SHA-256 over a 1 GiB file with Python `hashlib` (OpenSSL, ARM SHA extensions): **0.48 s per GiB** warm cache.
  - `SELECT DISTINCT chromosome FROM variants ORDER BY chromosome` on a synthetic 5M-row table with the app's `idx_variants_region` index: **0.12 s**, plan `SCAN variants USING COVERING INDEX`.
  - `/bin/ps -o stat= -p <pid>` spawn: **2.3 ms**. `/bin/ps -Ao pid=,ppid=` spawn: **24.9 ms**.
  - System SQLite compile options: `THREADSAFE=2` (multi-thread, not serialized), so connection sharing is only safe with `SQLITE_OPEN_FULLMUTEX`.

**Limits.** No build, no app launch, no Instruments. Nothing below is "Confirmed" in the sense of reproducing a hang in the running app. Measured numbers are component costs used to size the traced paths. One finding (PERF-09 pan redraw) is explicitly Suspected and needs a frame counter to verify.

### Concurrency inventory (Sources/, excluding Tests)

| Pattern | Count | Assessment |
|---|---|---|
| `@unchecked Sendable` | 219 | 73 lock-guarded classes, 32 immutable, 17 structs/enums/extensions, 81 with mutable `var` and no visible lock. Sampled the 81: most are pipeline/service classes whose `var`s are only set in `init` or are per-run boxes joined by a group/semaphore before read. Two racy boxes found (PERF-14). |
| `nonisolated(unsafe)` | 55 | ~20 are test probes/debug counters as mutable statics on production types (PERF-16). ~10 are `deinit`-reachable timer/observer handles (acceptable). Regex literals in `SRAAccessionParser` are fine. |
| `MainActor.assumeIsolated` | 405 | Scanned all 405 for an enclosing main hop. 30 lacked one within 4 lines, and every one of those traced to a `DispatchWorkItem` or panel completion that is scheduled on main. No crash-risk misuse found. |
| `Task.detached` | 211 | Used correctly as an off-main hop in most UI code. 32 blocking waits (`waitUntilExit`, `group.wait`) sit inside async contexts (PERF-02, PERF-12). |
| `Task { @MainActor` | 93 | Scanned for use from GCD callbacks. Zero violations of the project rule. |
| `DispatchQueue.main.async` | 390 | Mostly the sanctioned `main.async { assumeIsolated }` idiom. |
| `DispatchSemaphore` / `group.wait` | 6 / 5 | All off-main. Helper-mode `semaphore.wait()` in `BAMImportHelper`/`MetagenomicsImportHelper` is a process entry point, acceptable. |
| `Process.waitUntilExit()` | 100 | 25 are wait-before-read on a pipe. Traced the ones that matter: stderr-only or small outputs, so no live deadlock found. |
| Deprecated APIs | `lockFocus` 0, `runModal` 3 real, `wantsLayer` 2, `UserDefaults.synchronize` 0 (the 9 `synchronize()` hits are `FileHandle` fsync) | PERF-16 |

The package is Swift 6 language mode (`swift-tools-version: 6.2`, no `swiftLanguageMode(.v5)` downgrade, 11 `@preconcurrency` imports), so the compiler enforces data-race safety everywhere except the escape hatches above.

## Executive summary

The concurrency foundations are better than the velocity would suggest. The package builds in Swift 6 mode, the `main.async { assumeIsolated }` rule is followed consistently, closures stored on long-lived objects use `[weak self]` almost without exception, and several hard problems have been solved well: the FSEvents watcher, the off-main sidebar scan with generation guards, off-draw read packing in the sequence viewer, paged classifier row loading, and SQLite connections opened `FULLMUTEX` with statement-local lifetimes.

The defects are concentrated at the seams where a later feature bypassed the good machinery. The most user-visible ones are main-thread freezes that scale with data size: alignment scientific actions SHA-256 the entire BAM on the main actor twice per click (PERF-01), the TaxTriage batch unique-read pass runs directory walks and `samtools` on the main actor (PERF-03), and eight post-import call sites still run the full recursive project scan synchronously (PERF-05). The second theme is a hidden serialization: `NativeToolRunner.shared` is an actor, and two of its methods block that actor for the whole lifetime of the child process, so one long `pigz` or variant-calling pipeline stalls every other native-tool call in the app (PERF-02).

One finding crosses into scientific correctness. The "unique reads" figures shown and persisted for TaxTriage and EsViritu are computed from at most 100,000 parsed reads per contig, after buffering up to 500 MB of SAM text, so high-abundance taxa are silently undercounted (PERF-04). That should be triaged with the science reviewer as P0.

Memory problems are specific rather than systemic: exporting annotations from a reference bundle decompresses and parses the whole genome into a `String` (PERF-06), and oriented virtual-FASTQ materialization loads the orient map twice into `Set<String>` of every read ID (PERF-08). Rendering is mostly careful. The MSA view is the exception with per-cell `NSAttributedString` creation and tooltip churn inside `draw(_:)`, and the MSA gutter computes its source-coordinate range from the wrong width (PERF-10).

Overall: fix five or six targeted seams and the app's responsiveness on large human or macaque datasets improves substantially. No architectural rewrite is needed.

## Preserve (do not "fix" these away)

- [FileSystemWatcher.swift](Sources/LungfishApp/Services/FileSystemWatcher.swift:269): stream setup on a private queue because `FSEventStreamCreate` can wedge, a token registry instead of raw `self` pointers in `FSEventStreamContext.info` ([:140](Sources/LungfishApp/Services/FileSystemWatcher.swift:140)), classification off-main with burst coalescing ([:563](Sources/LungfishApp/Services/FileSystemWatcher.swift:563)), and per-volume stream policy ([:79](Sources/LungfishApp/Services/FileSystemWatcher.swift:79)). This is exemplary.
- The async sidebar reload: detached scan over `Sendable` nodes, generation re-check with no `await` before mutation, UI state captured at apply time ([SidebarViewController.swift:1182](Sources/LungfishApp/Views/Sidebar/SidebarViewController.swift:1182)), and the surgical incremental subtree diff ([:1465](Sources/LungfishApp/Views/Sidebar/SidebarViewController.swift:1465)). PERF-05 asks callers to use this path more, not to change it.
- [OperationCenter.cancel](Sources/LungfishKit/OperationCenter.swift:704) runs `onCancel` on a global queue, so cancellation never blocks the main thread. The operations panel coalesces row reloads ([OperationsPanelController.swift:232](Sources/LungfishApp/Views/Operations/OperationsPanelController.swift:232)).
- Sequence viewer read packing is moved out of `draw(_:)` into a keyed background pack ([SequenceViewerView+Rendering.swift:505](Sources/LungfishApp/Views/Viewer/SequenceViewerView+Rendering.swift:505)), with a `GlyphCache` and a colour cache in [ReadTrackRenderer.swift:929](Sources/LungfishApp/Views/Viewer/ReadTrackRenderer.swift:929). Fetches use generation tokens and a read budget ([SequenceViewerView+Alignment.swift:700](Sources/LungfishApp/Views/Viewer/SequenceViewerView+Alignment.swift:700)).
- [AlignmentDataProvider.runSamtoolsProcessBudgeted](Sources/LungfishIO/Bundles/AlignmentDataProvider.swift:1270): streaming reader with record and byte budgets, SIGKILL plus reap on timeout. This is the model PERF-04 should adopt.
- [ProcessTreeTerminator](Sources/LungfishWorkflow/Native/ProcessTreeTerminator.swift:15) semantics (SIGTERM descendants first, SIGSTOP the root to stop new forks, then SIGKILL) are correct. PERF-11 is about its cost, not its logic.
- Classifier SQLite classes open with `SQLITE_OPEN_FULLMUTEX` and keep statements local ([TaxTriageDatabase.swift:224](Sources/LungfishIO/Formats/TaxTriage/TaxTriageDatabase.swift:224)). TaxTriage row loading is paged off-main with a generation UUID ([TaxTriageResultViewController.swift:2789](Sources/LungfishTaxTriageUI/TaxTriageResultViewController.swift:2789)).
- `NativeToolRunner.run` uses `terminationHandler` plus EOF joins rather than blocking, and [CLIVariantCallingRunner.swift:410](Sources/LungfishApp/Services/CLIVariantCallingRunner.swift:410) awaits exit and both EOFs with `async let`. These are the templates for PERF-02, PERF-12 and PERF-14.
- [GzipSupport.waitBounded](Sources/LungfishIO/Compression/GzipSupport.swift:601) with a concurrent stderr drain, written after a real 54-minute gate hang.

## Findings

| ID | Priority | Title | Confidence | Effort |
|---|---|---|---|---|
| PERF-01 | P1 | Alignment scientific actions SHA-256 the whole BAM, index and reference on the main actor, twice per action | Traced (hash throughput measured) | S |
| PERF-02 | P1 | `NativeToolRunner.shared` actor is blocked for the full runtime of `runWithFileOutput` / `runPipeline` children | Traced | M |
| PERF-03 | P1 | TaxTriage batch unique-read pass runs directory walks, file parsing and `samtools` on the main actor, then an O(n^2) table sync per organism | Traced | M |
| PERF-04 | P0 (science-adjacent) | Unique-read counts for TaxTriage and EsViritu are capped at 100,000 parsed reads per contig after buffering up to 500 MB of SAM | Traced | M |
| PERF-05 | P1 | Eight post-import and post-operation call sites run the full recursive project scan synchronously on the main thread | Traced | S |
| PERF-06 | P1 | "Export annotations" and multi-source sequence export decompress and parse the entire genome into memory | Traced | S |
| PERF-07 | P2 | Result and bundle selection opens SQLite databases and runs scans and JSON decodes on the main thread | Traced (query cost measured) | M |
| PERF-08 | P2 | Oriented virtual-FASTQ materialization loads the orient map twice as whole `String`s into two `Set<String>` of all read IDs | Traced | S |
| PERF-09 | P2 | Loading-badge animation invalidates the whole sequence viewer at 18 fps, and horizontal pan redraw is a trailing debounce | Traced / Suspected | S |
| PERF-10 | P2 | MSA drawing allocates an attributed string per residue and re-registers tooltips inside `draw(_:)`, and the gutter numbers use the gutter's width | Traced | S-M |
| PERF-11 | P2 | Process-tree termination spawns `ps` per PID per loop, and quit terminates roots serially on the main thread | Traced (spawn cost measured) | S |
| PERF-12 | P2 | Blocking waits pin cooperative-pool threads for tool lifetimes | Traced / Suspected impact | M |
| PERF-13 | P2 | Import helper cancellation signals only the helper root and polls with `Thread.sleep` | Traced / Suspected orphaning | S |
| PERF-14 | P3 | Racy output-drain idioms (CondaManager 100 ms "drain delay", `readerGroup.enter` inside `readabilityHandler`) | Suspected | S |
| PERF-15 | P3 | Operation log entries are unbounded per operation | Traced | S |
| PERF-16 | P3 | Remaining `runModal`, redundant timer-to-main hops, and test probes as `nonisolated(unsafe)` statics in production types | Traced | S |

---

### PERF-01 (P1) Alignment scientific actions hash whole BAMs on the main actor, twice per action

**Evidence.**
- [AlignmentScientificActionCoordinator](Sources/LungfishApp/Views/Viewer/AlignmentScientificActionCoordinator.swift:92) is `@MainActor`. Its default `validator` is the synchronous closure `{ try $0.validateCurrentSnapshots() }` ([:114](Sources/LungfishApp/Views/Viewer/AlignmentScientificActionCoordinator.swift:114)).
- The validator is called synchronously before and after staging: consensus ([:169](Sources/LungfishApp/Views/Viewer/AlignmentScientificActionCoordinator.swift:169), [:181](Sources/LungfishApp/Views/Viewer/AlignmentScientificActionCoordinator.swift:181)), region extraction gate 1 and gate 2 ([:304](Sources/LungfishApp/Views/Viewer/AlignmentScientificActionCoordinator.swift:304), [:308](Sources/LungfishApp/Views/Viewer/AlignmentScientificActionCoordinator.swift:308)), selected-read extraction ([:330](Sources/LungfishApp/Views/Viewer/AlignmentScientificActionCoordinator.swift:330), [:339](Sources/LungfishApp/Views/Viewer/AlignmentScientificActionCoordinator.swift:339)).
- [AlignmentActionContext.validateCurrentSnapshots](Sources/LungfishApp/Views/Viewer/AlignmentActionContext.swift:186) calls `ProvenanceFileHasher.sha256` on the alignment, the index and the decoding reference ([:212](Sources/LungfishApp/Views/Viewer/AlignmentActionContext.swift:212)). The hasher streams the full file ([ProvenanceFileHasher.swift](Sources/LungfishWorkflow/Provenance/ProvenanceFileHasher.swift:22)).
- By contrast, the initial snapshot is correctly hashed in `Task.detached` ([ReferenceBundleViewportController.swift:1706](Sources/LungfishApp/Views/Results/Reference/ReferenceBundleViewportController.swift:1706)). Only re-validation landed on main.

**Impact.** Measured SHA-256 throughput is about 2 GiB/s warm. A 6 GB human or macaque whole-genome BAM costs about 3 s per gate on a warm SSD and 15-60 s on an external or exFAT volume. Region extraction runs two gates, so the user sees a spinning cursor for 6 s up to a minute, twice, after clicking "Extract reads". Nothing can be cancelled while the main thread is inside the hash.

**Recommendation.**
- Make `Validator` `@Sendable (AlignmentActionContext) async throws -> Void` and run the hash in `Task.detached`, passing `Task.checkCancellation` as the hasher's `cancellationCheck`.
- Replace the second full hash with a cheap identity check (inode, size, `contentModificationDate`, and `st_ino` + `st_dev`) recorded with the snapshot. Rehash only when the cheap identity changed. The scientific guarantee (input not modified between staging and publication) is kept at a fraction of the cost.
- Consider caching the SHA-256 per (path, inode, size, mtime) in the context so that repeated actions on the same BAM do not rehash.

**Acceptance test.** Unit test with an injected slow hasher asserting that `extractRegion` does not execute the hasher on the main thread (`Thread.isMainThread == false` probe). Manual: extract a region from a 5 GB BAM, and the UI remains responsive, with the operation row showing "Verifying input".

**Effort.** S.

---

### PERF-02 (P1) `NativeToolRunner.shared` is blocked for the lifetime of child processes

**Evidence.**
- `NativeToolRunner` is an `actor` with a process-wide singleton ([NativeToolRunner.swift:606](Sources/LungfishWorkflow/Native/NativeToolRunner.swift:606), [:610](Sources/LungfishWorkflow/Native/NativeToolRunner.swift:610)).
- `runWithFileOutput` is actor-isolated. Its `withCheckedThrowingContinuation` body executes synchronously on the calling executor, which is the actor, and it runs `process.waitUntilExit()` followed by `drainGroup.wait()` inside that body ([:1079](Sources/LungfishWorkflow/Native/NativeToolRunner.swift:1079), [:1137](Sources/LungfishWorkflow/Native/NativeToolRunner.swift:1137)). The body uses `self.logger` ([:1163](Sources/LungfishWorkflow/Native/NativeToolRunner.swift:1163)), which confirms it is actor-isolated.
- `runPipeline` has the same shape ([:1409](Sources/LungfishWorkflow/Native/NativeToolRunner.swift:1409), waits at [:1500](Sources/LungfishWorkflow/Native/NativeToolRunner.swift:1500)), as does `runPipelineWithFileOutput` ([:1565](Sources/LungfishWorkflow/Native/NativeToolRunner.swift:1565), wait at [:1681](Sources/LungfishWorkflow/Native/NativeToolRunner.swift:1681)).
- `run` itself does not block. It uses `terminationHandler` ([:969](Sources/LungfishWorkflow/Native/NativeToolRunner.swift:969)).
- Callers default to `.shared`: [FASTQDerivativeService.swift:44](Sources/LungfishApp/Services/FASTQDerivativeService.swift:44), [ClassifierReadResolver.swift:54](Sources/LungfishWorkflow/Extraction/ClassifierReadResolver.swift:54), [FASTQBatchImporter.swift:2137](Sources/LungfishWorkflow/Ingestion/FASTQBatchImporter.swift:2137), and 66 `NativeToolRunner.shared` references in total. Blocking callers include pigz compression of whole FASTQs ([FASTQBatchImporter.swift:2368](Sources/LungfishWorkflow/Ingestion/FASTQBatchImporter.swift:2368)) and the viral variant-calling pipelines ([ViralVariantCallingPipeline.swift:719](Sources/LungfishWorkflow/Variants/ViralVariantCallingPipeline.swift:719)).

**Impact.** While one import compresses a 20 GB FASTQ with `pigz` through `runWithFileOutput`, every other feature that awaits `NativeToolRunner.shared` (read extraction, BAM filtering, `findTool` calls, the second sample of a batch) queues behind it. The user sees a second operation sit at "Starting" until an unrelated one finishes. Parallel batch code that assumes concurrency gets none, and the actor also pins a cooperative thread for the duration.

**Recommendation.**
- Rewrite `runWithFileOutput`, `runPipeline` and `runPipelineWithFileOutput` on the `run` template: launch processes, set `terminationHandler` on the last stage, drain pipes with `readabilityHandler` or background readers, and resume the continuation from a join of (exit, stdout EOF, stderr EOF). No `waitUntilExit` or `DispatchGroup.wait` inside actor-isolated code.
- Alternatively mark the process-running helpers `nonisolated` and execute the blocking section on a dedicated `DispatchQueue` (not the cooperative pool) that resumes the continuation.
- Add a debug assertion helper `assertNotBlockingActor()` used in these helpers during tests.

**Acceptance test.** Test that starts `runWithFileOutput` for `/bin/sleep 2` (or an injectable fake tool) and concurrently calls `NativeToolRunner.shared.run(... /usr/bin/true ...)`. The second call must return in well under 2 s. Existing cancellation tests must still pass.

**Effort.** M (three methods plus cancellation/timeout parity).

---

### PERF-03 (P1) TaxTriage batch unique-read pass runs heavy work on the main actor

**Evidence.**
- `TaxTriageResultViewController` is `@MainActor` ([TaxTriageResultViewController.swift:174](Sources/LungfishTaxTriageUI/TaxTriageResultViewController.swift:174)). `scheduleBatchPerSampleUniqueReadComputation` creates `Task { [weak self] in ... }` ([:1938](Sources/LungfishTaxTriageUI/TaxTriageResultViewController.swift:1938)), which inherits main-actor isolation.
- Inside that task, per sample and on the main thread:
  - recursive `FileManager.enumerator` walks, twice ([:1949](Sources/LungfishTaxTriageUI/TaxTriageResultViewController.swift:1949), [:1963](Sources/LungfishTaxTriageUI/TaxTriageResultViewController.swift:1963), implementation [:1644](Sources/LungfishTaxTriageUI/TaxTriageResultViewController.swift:1644))
  - `String(contentsOf:)` parse of GCF mapping files ([:1668](Sources/LungfishTaxTriageUI/TaxTriageResultViewController.swift:1668))
  - `samtools view -H` via `Process`, `readDataToEndOfFile`, `waitUntilExit` ([:1981](Sources/LungfishTaxTriageUI/TaxTriageResultViewController.swift:1981) to [:1989](Sources/LungfishTaxTriageUI/TaxTriageResultViewController.swift:1989)). Stderr goes to an unread `Pipe()`, so a noisy samtools could also wedge the main thread.
- After each organism it calls `syncUniqueReadsToFlatTable()` ([:2043](Sources/LungfishTaxTriageUI/TaxTriageResultViewController.swift:2043)), which loops every (organism, sample) pair and linearly scans `allBatchGroupRows` twice per pair ([:2240](Sources/LungfishTaxTriageUI/TaxTriageResultViewController.swift:2240) to [:2267](Sources/LungfishTaxTriageUI/TaxTriageResultViewController.swift:2267)). That is O(organisms x samples x rows) per organism, O(n^3) overall, on main.
- Persistence (`persistDeduplicatedReadCounts`, `updateBatchManifestUniqueReads`) writes JSON on main at the end ([:2050](Sources/LungfishTaxTriageUI/TaxTriageResultViewController.swift:2050)).

**Impact.** Opening a TaxTriage batch of 48 samples with deep per-sample output trees produces repeated multi-hundred-millisecond stalls while the user is trying to scroll the table, then the table repaints once per organism. On network or exFAT volumes the enumerator walks alone can take seconds each.

**Recommendation.**
- Move the per-sample discovery (index resolution, GCF parse, BAM header parse) into a `nonisolated static` function executed in `Task.detached`, returning a `Sendable` snapshot. The existing `parseBamReferenceLengthsSnapshot` ([:2307](Sources/LungfishTaxTriageUI/TaxTriageResultViewController.swift:2307)) already shows the pattern.
- Build a `[String: TaxTriageRow]` index keyed by `"sample\tnormalizedOrganism"` once, and update only the changed keys. Coalesce table reloads to at most one per 250 ms.
- Drain samtools stdout and stderr concurrently, or reuse `AlignmentDataProvider.runSamtoolsProcess`.

**Acceptance test.** A threading-probe test (the codebase already uses `threadingProbe` seams) asserting that the discovery closure runs off-main. A unit test that `syncUniqueReadsToFlatTable` performs O(changed keys) updates. Manual: open a 48-sample batch and scroll during computation without hitches.

**Effort.** M.

---

### PERF-04 (P0, science-adjacent) Unique-read counts are capped at 100,000 reads per contig

**Evidence.**
- `AlignmentDataProvider.fetchReads` defaults `maxReads: 100_000` ([AlignmentDataProvider.swift:430](Sources/LungfishIO/Bundles/AlignmentDataProvider.swift:430)). It uses the unbudgeted `runSamtools`, which buffers all of stdout up to `maxStdoutSize = 500 MB` ([:1173](Sources/LungfishIO/Bundles/AlignmentDataProvider.swift:1173), [:1230](Sources/LungfishIO/Bundles/AlignmentDataProvider.swift:1230)), then converts to `String` and parses with `SAMParser.parse(..., maxReads:)`, which stops at the cap ([SAMParser.swift:266](Sources/LungfishIO/Formats/SAM/SAMParser.swift:266)).
- Unique-read computations fetch the entire contig with the default cap and dedup the parsed reads:
  - TaxTriage single result ([TaxTriageResultViewController.swift:1881](Sources/LungfishTaxTriageUI/TaxTriageResultViewController.swift:1881)) and batch ([:2026](Sources/LungfishTaxTriageUI/TaxTriageResultViewController.swift:2026)).
  - EsViritu ([EsVirituResultViewController.swift:1021](Sources/LungfishEsVirituUI/EsVirituResultViewController.swift:1021)).
- `AlignedRead.deduplicatedReadCount` returns at most `reads.count` ([AlignedReadDedup.swift:19](Sources/LungfishCore/Models/AlignedReadDedup.swift:19)), so the value is at most 100,000 regardless of true depth.
- The TaxTriage batch path persists these values to `batch-unique-reads.json` and the batch manifest ([TaxTriageResultViewController.swift:2054](Sources/LungfishTaxTriageUI/TaxTriageResultViewController.swift:2054)). The comment there says "no capping against TSV read count", which shows the authors believed the number was exact.

**Impact.** For any taxon with more than 100,000 mapped primary reads on one accession (common for the dominant organism in a clinical sample), the displayed and cached "Unique Reads" is an undercount computed from the first 100,000 reads in coordinate order. Those reads also cluster at the start of the contig, which makes the duplicate rate unrepresentative. Separately, each call can allocate about 500 MB of `Data`, then the same again as `String`, then `AlignedRead` objects with sequence and quality strings, only to read three fields. Batch mode runs this serially across every organism and sample.

**Recommendation.**
- Add a dedicated streaming counter in LungfishIO, for example `AlignmentDataProvider.countUniqueReadStarts(chromosome:excludeFlags:)`. It streams `samtools view` output in 64 KB chunks, parses only FLAG, POS, CIGAR (for the end) and strand, and inserts a packed `UInt64` key into a `Set<UInt64>`. There is no read cap and memory is bounded by distinct positions.
- Alternatively use `samtools markdup -s` statistics or `samtools view -c -F 0xD04` on a duplicate-marked BAM when one exists.
- Invalidate existing `batch-unique-reads.json` caches (version the cache schema) so capped values are recomputed.
- Route this finding to the scientific-correctness reviewer for confirmation and labelling.

**Acceptance test.** Fixture BAM with 250,000 reads at 150,000 distinct start/end/strand keys on one contig. The counter returns 150,000 and peak RSS stays under 100 MB. Regression test that old cache files with the prior schema are ignored.

**Effort.** M.

---

### PERF-05 (P1) Synchronous full project scans on the main thread after imports and operations

**Evidence.**
- Public `reloadFromFilesystem()` ([SidebarViewController.swift:1099](Sources/LungfishApp/Views/Sidebar/SidebarViewController.swift:1099)) calls the private synchronous variant, which runs `SidebarProjectScanner.scanRootNodes` on the main actor ([:1224](Sources/LungfishApp/Views/Sidebar/SidebarViewController.swift:1224) to [:1242](Sources/LungfishApp/Views/Sidebar/SidebarViewController.swift:1242)).
- The scan is a full recursive walk with per-bundle manifest JSON decodes ([SidebarProjectScanner.swift:92](Sources/LungfishApp/Views/Sidebar/SidebarProjectScanner.swift:92), JSON decodes at [:780](Sources/LungfishApp/Views/Sidebar/SidebarProjectScanner.swift:780) to [:804](Sources/LungfishApp/Views/Sidebar/SidebarProjectScanner.swift:804), [:925](Sources/LungfishApp/Views/Sidebar/SidebarProjectScanner.swift:925)). Its own header comment says it exists so the scan "can run off" main.
- Eight callers still use the synchronous path, all on main:
  - [AppDelegate.swift:271](Sources/LungfishApp/App/AppDelegate.swift:271) (`refreshSidebarAndSelectImportedURL`, after every import)
  - [AppDelegate+SequenceMenu.swift:588](Sources/LungfishApp/App/AppDelegate+SequenceMenu.swift:588) and [:825](Sources/LungfishApp/App/AppDelegate+SequenceMenu.swift:825)
  - [AppDelegate+Classification.swift:2690](Sources/LungfishApp/App/AppDelegate+Classification.swift:2690)
  - [MainSplitViewController+GenomicsDisplay.swift:1536](Sources/LungfishApp/Views/MainWindow/MainSplitViewController+GenomicsDisplay.swift:1536)
  - [WorkflowOperationExecutionService.swift:120](Sources/LungfishApp/Services/WorkflowOperationExecutionService.swift:120)
  - [SidebarViewController+MenuDelegate.swift:509](Sources/LungfishApp/Views/Sidebar/SidebarViewController+MenuDelegate.swift:509)

**Impact.** The good async path (the one FSEvents drives) was built because this walk blocked the main thread. Every import completion, classification completion and workflow completion still pays that cost on main. It grows with project size: a project with a few hundred FASTQ bundles and demux trees can take hundreds of milliseconds to seconds, longer on exFAT.

**Recommendation.** Replace the eight call sites with `reloadFromFilesystemAsync(...)` and chain the follow-up (`selectItem(forURL:)`) on the returned task: `await sidebar.reloadFromFilesystemAsync(...)?.value; sidebar.selectItem(forURL: url)`. Then make the synchronous variant `internal` for tests only, or delete it. Where the caller only needs one new item, prefer the incremental `updateSidebar` path.

**Acceptance test.** Grep gate in CI: no production caller of `reloadFromFilesystem()`. Test: after `refreshSidebarAndSelectImportedURL`, the imported item is selected, and a threading probe on `SidebarProjectScanner.scanRootNodes` never fires on main.

**Effort.** S.

---

### PERF-06 (P1) Annotation export and multi-source sequence export load the whole genome into memory

**Evidence.**
- `loadSequencesForExport` for a `.lungfishref` decompresses a gzipped genome with `GzipInputStream.readAll()`, which returns the whole decompressed file as one `String` ([AppDelegate+ImportCenter.swift:3118](Sources/LungfishApp/App/AppDelegate+ImportCenter.swift:3118) to [:3125](Sources/LungfishApp/App/AppDelegate+ImportCenter.swift:3125), [GzipSupport.swift:268](Sources/LungfishIO/Compression/GzipSupport.swift:268)). It writes that string back to a temp file, then parses every sequence with `FASTAReader.readAll()` ([:3132](Sources/LungfishApp/App/AppDelegate+ImportCenter.swift:3132)), and loads all annotations with `limit: Int.max` ([:3147](Sources/LungfishApp/App/AppDelegate+ImportCenter.swift:3147)).
- The "export annotations as GFF3" action calls this and discards the sequences: `let (_, annotations) = try await self.loadSequencesForExport(from: bundleURL)` ([:3253](Sources/LungfishApp/App/AppDelegate+ImportCenter.swift:3253)).
- Multi-source sequence export also uses it ([:2695](Sources/LungfishApp/App/AppDelegate+ImportCenter.swift:2695)). A single reference bundle correctly takes a streaming path ([:2671](Sources/LungfishApp/App/AppDelegate+ImportCenter.swift:2671)).

**Impact.** For a human or rhesus macaque reference (about 3 Gbp), exporting annotations holds the decompressed `Data` (3 GB), the `String` (3 GB), and parsed `Sequence` objects (3 GB or more), which comes to 9-12 GB peak. On a 16 GB Mac that means heavy swap or a jetsam kill, just to write a GFF3 that never needed the sequence.

**Recommendation.**
- Split `loadSequencesForExport` into `loadAnnotationsForExport(bundleURL:)`, which touches only the annotation database, and a sequence loader.
- For multi-source sequence export, stream each source through the same writer used by `performReferenceBundleSequenceExport`, using `GzipInputStream` line iteration rather than `readAll()`.
- Deprecate `GzipInputStream.readAll()` for anything that can be a genome. Keep it only for small sidecars.

**Acceptance test.** Test with a fake bundle whose genome path points to a large sparse gzip and whose annotation DB has 10 records. GFF3 export succeeds without opening the genome file (probe on the FASTA reader). Peak RSS test optional.

**Effort.** S.

---

### PERF-07 (P2) Selection-driven SQLite opens, scans and JSON decodes on the main thread

**Evidence.**
- Classifier selection opens the database on main and configures synchronously: `EsVirituDatabase(at:)` and `TaxTriageDatabase(at:)` in [MainSplitViewController+ClassifierDisplay.swift:396](Sources/LungfishApp/Views/MainWindow/MainSplitViewController+ClassifierDisplay.swift:396) and [:449](Sources/LungfishApp/Views/MainWindow/MainSplitViewController+ClassifierDisplay.swift:449). Then `db.fetchSamples()` runs on main ([TaxTriageResultViewController.swift:2675](Sources/LungfishTaxTriageUI/TaxTriageResultViewController.swift:2675)).
- The same selection decodes `MetagenomicsBatchResultStore.loadEsViritu(from:)` twice and a per-sample result sidecar on main ([MainSplitViewController+ClassifierDisplay.swift:416](Sources/LungfishApp/Views/MainWindow/MainSplitViewController+ClassifierDisplay.swift:416), [:431](Sources/LungfishApp/Views/MainWindow/MainSplitViewController+ClassifierDisplay.swift:431)).
- `SequenceViewerView.setReferenceBundle` opens every variant database on main and runs `sampleCount()` and `allChromosomes()` ([SequenceViewerView.swift:2270](Sources/LungfishApp/Views/Viewer/SequenceViewerView.swift:2270) to [:2283](Sources/LungfishApp/Views/Viewer/SequenceViewerView.swift:2283)). `allChromosomes` is `SELECT DISTINCT chromosome ... ORDER BY chromosome` ([VariantDatabase+Metadata.swift:69](Sources/LungfishIO/Bundles/VariantDatabase+Metadata.swift:69)), and its cache is per instance, so each open pays it again. The code's own comment acknowledges the slower `MAX(position)` scan was moved off main, but this one was not.

**Impact.** Measured 0.12 s for DISTINCT on 5M rows warm. A cohort VCF with 30-50M variant rows across a few tracks costs roughly 1-2 s on bundle open, cold cache more. Classifier selection costs are smaller individually but stack with PERF-05 after an operation completes.

**Recommendation.**
- Store `chromosomes` and `sample_count` in the variant DB `metadata` table at import time and read them in O(1). Fall back to the scan only off-main.
- Open classifier databases and decode manifests inside a detached task keyed by a selection generation, as the TaxTriage row pager already does. Pass a ready snapshot to `display*FromDatabase`.
- Load each manifest once per selection.

**Acceptance test.** Threading-probe tests that `VariantDatabase.init` and `computeAllChromosomes` are not called on main during `setReferenceBundle`. Import test asserting that the metadata keys are written.

**Effort.** M.

---

### PERF-08 (P2) Orient-map materialization holds every read ID twice

**Evidence.** `FASTQOrientMapFile.loadForwardReadIDs` and `loadRCReadIDs` each read the whole `orient-map.tsv` with `String(contentsOf:)`, split it into lines and build a `Set<String>` ([FASTQDerivativeFileIO.swift:45](Sources/LungfishIO/Formats/FASTQ/FASTQDerivativeFileIO.swift:45) to [:67](Sources/LungfishIO/Formats/FASTQ/FASTQDerivativeFileIO.swift:67)). Every materialization path calls both back to back ([FASTQDerivativeService+Materialization.swift:127](Sources/LungfishApp/Services/FASTQDerivativeService+Materialization.swift:127), [:195](Sources/LungfishApp/Services/FASTQDerivativeService+Materialization.swift:195), [:215](Sources/LungfishApp/Services/FASTQDerivativeService+Materialization.swift:215)), and so does the CLI ([FASTQCLIMaterializer.swift:280](Sources/LungfishWorkflow/Extraction/FASTQCLIMaterializer.swift:280)).

**Impact.** For a 20M-read orient derivative (read IDs around 50 bytes), each load is about 1 GB file text plus split substrings, and the combined sets are 2-3 GB. The file is read twice. Materialization runs before classifiers (per project memory), so this sits on the critical path of every oriented-bundle analysis.

**Recommendation.** One streaming pass that returns only the reverse-complement set. Anything not in it and present in the read-ID list is forward, so the forward set is redundant. Stream with the existing line iterator instead of `String(contentsOf:)`. For very large sets, store read IDs as 64-bit hashes with a collision check, or sort the orient map and merge-join against the sorted FASTQ.

**Acceptance test.** Unit test that the materializer output is byte-identical with and without the forward set. Memory test on a 2M-line synthetic map that peak allocation is at most one set.

**Effort.** S.

---

### PERF-09 (P2) Sequence viewer: full-view invalidation for a badge, and pan redraw debounced

**Evidence.**
- While reads or depth are fetching, a repeating 18 Hz timer calls `setNeedsDisplay(self.bounds)` on the whole `SequenceViewerView` to animate a loading badge ([SequenceViewerView.swift:1307](Sources/LungfishApp/Views/Viewer/SequenceViewerView.swift:1307) to [:1318](Sources/LungfishApp/Views/Viewer/SequenceViewerView.swift:1318)). Every tick re-runs the whole `draw(_:)`: ruler, annotations, variants, coverage, and the per-frame `cachedAlignedReads.lazy.prefix(50_000)` span scan ([SequenceViewerView+Rendering.swift:452](Sources/LungfishApp/Views/Viewer/SequenceViewerView+Rendering.swift:452)).
- Horizontal pan: each scroll event invalidates and recreates a 1/60 s one-shot timer, whose callback then hops again through `DispatchQueue.main.async` before invalidating ([SequenceViewerView+Interaction.swift:1838](Sources/LungfishApp/Views/Viewer/SequenceViewerView+Interaction.swift:1838) to [:1850](Sources/LungfishApp/Views/Viewer/SequenceViewerView+Interaction.swift:1850)). The comment says "coalesce redraw at 60fps", but the code is a trailing debounce. **Suspected**: with trackpad momentum events arriving faster than 16.7 ms, the timer is reset before it fires, and the view redraws late or only when the gesture slows.

**Impact.** Fetches are the slow moments, so burning main-thread draw time at 18 fps during them lengthens the time to show data. Pan may feel sticky on 120 Hz displays.

**Recommendation.**
- Draw the badge in a dedicated small overlay view (or `NSProgressIndicator`) and invalidate only that rect.
- Replace the pan debounce with a throttle: set a `pendingPanRedraw` flag and invalidate immediately if more than one frame has passed, or drive redraws from `NSView.displayLink(target:selector:)` (macOS 14+) while a gesture is active. Drop the redundant `main.async` hop.
- Cache `maxReadSpan` with the read set generation instead of recomputing it every frame.

**Acceptance test.** Instrumented test counting `draw(_:)` invocations: during a fetch, zero full-view draws per timer tick. During a synthetic burst of 100 scroll events at 8 ms spacing, at least one redraw per 17 ms.

**Effort.** S.

---

### PERF-10 (P2) MSA rendering costs and a gutter numbering bug

**Evidence.**
- Every residue cell calls `drawText`, which allocates an `NSMutableParagraphStyle`, an attributes dictionary and an `NSAttributedString`, then lays it out with `draw(in:)` ([MultipleSequenceAlignmentViewController.swift:4139](Sources/LungfishApp/Views/Viewer/MultipleSequenceAlignmentViewController.swift:4139) to [:4156](Sources/LungfishApp/Views/Viewer/MultipleSequenceAlignmentViewController.swift:4156), called from `drawResidue` at [:4071](Sources/LungfishApp/Views/Viewer/MultipleSequenceAlignmentViewController.swift:4071)). `residueColor` also allocates `withAlphaComponent` colours per cell ([:4080](Sources/LungfishApp/Views/Viewer/MultipleSequenceAlignmentViewController.swift:4080)). At letter zoom a 1600 x 1000 viewport is roughly 130 x 50 = 6,500 attributed strings per frame.
- The row gutter calls `removeAllToolTips()` and then `addToolTip` for every visible row inside `draw(_:)` ([:2962](Sources/LungfishApp/Views/Viewer/MultipleSequenceAlignmentViewController.swift:2962), [:3017](Sources/LungfishApp/Views/Viewer/MultipleSequenceAlignmentViewController.swift:3017)). Mutating tooltip and tracking state during drawing is an AppKit anti-pattern and runs on every scroll frame.
- Correctness: the gutter's source-coordinate range uses the gutter's own `bounds.width` ([:3096](Sources/LungfishApp/Views/Viewer/MultipleSequenceAlignmentViewController.swift:3096) to [:3101](Sources/LungfishApp/Views/Viewer/MultipleSequenceAlignmentViewController.swift:3101)). The gutter is 232 pt wide ([:29](Sources/LungfishApp/Views/Viewer/MultipleSequenceAlignmentViewController.swift:29), [:930](Sources/LungfishApp/Views/Viewer/MultipleSequenceAlignmentViewController.swift:930)), not the width of the alignment canvas. So the "first-last" source coordinates shown per row cover only the first ~232/columnWidth visible columns, not the whole visible window.
- `rectFor(row:alignmentColumn:)` does `displayedColumns.firstIndex(of:)`, O(columns) per call ([:3556](Sources/LungfishApp/Views/Viewer/MultipleSequenceAlignmentViewController.swift:3556)).

**Impact.** Scroll jank at letter zoom on large alignments. The per-row coordinate range in the gutter under-reports the visible span whenever the canvas is wider than the gutter, which is almost always.

**Recommendation.**
- Precompute one `NSAttributedString` or `CTLine` per (residue, weight, colour) and cache colours per scheme. The sequence viewer's `GlyphCache` can be reused.
- Register gutter tooltips in `updateTrackingAreas` or when rows or offsets change, not in `draw(_:)`, or implement `view(_:stringForToolTip:point:userData:)` with a single full-bounds tooltip rect that resolves the row from the point.
- Pass the canvas viewport width into the gutter (`visibleCanvasWidth`) and use it for the numbering window.
- Keep a `[alignmentColumn: displayIndex]` dictionary alongside `displayedColumns`.

**Acceptance test.** Unit test: with gutter width 232 and canvas width 1200 at column width 12, the gutter range for a gapless row equals the canvas's first and last visible columns. Draw-count test: `addToolTip` is not called from `draw(_:)`.

**Effort.** S-M.

---

### PERF-11 (P2) Process-tree termination is expensive and serial at quit

**Evidence.**
- `processExists(pid:)` spawns `/bin/ps -o stat= -p <pid>` to detect zombies ([ProcessTreeTerminator.swift:21](Sources/LungfishWorkflow/Native/ProcessTreeTerminator.swift:21) to [:50](Sources/LungfishWorkflow/Native/ProcessTreeTerminator.swift:50)). `descendantProcessIDs(of:)` spawns `/bin/ps -Ao pid=,ppid=` for each call ([:52](Sources/LungfishWorkflow/Native/ProcessTreeTerminator.swift:52)).
- `terminate(rootPID:)` calls `processExists` per PID while signalling, sleeps the grace period (0.5 s default), then `expandWithDescendants` calls `descendantProcessIDs` once per PID, and `waitForPIDsToExit` repeats that expansion plus `processExists` in a loop for up to 0.25 s ([:150](Sources/LungfishWorkflow/Native/ProcessTreeTerminator.swift:150) to [:196](Sources/LungfishWorkflow/Native/ProcessTreeTerminator.swift:196)).
- `applicationWillTerminate` calls `NativeProcessRegistry.shared.terminateAll(gracePeriod: 0.5)` on the main thread ([AppDelegate.swift:775](Sources/LungfishApp/App/AppDelegate.swift:775)), which terminates each registered root serially ([ProcessTreeTerminator.swift:220](Sources/LungfishWorkflow/Native/ProcessTreeTerminator.swift:220)).

**Impact.** Measured `ps -Ao` at 25 ms and `ps -p` at 2.3 ms. A root with 6 descendants costs about 0.5 s grace plus roughly 7 x 25 ms per expansion, repeated inside the wait loop, so around 1 s per root. Quitting with four running tools takes about 4 s of main-thread time after the user presses Cmd-Q, and the app looks hung. Cancelling one operation is off-main (good) but still spawns dozens of `ps` processes.

**Recommendation.**
- Replace `ps` with `proc_listchildpids` / `proc_pidinfo(PROC_PIDTBSDINFO)` from `libproc` (zombie state is `pbi_status == SZOMB`). No subprocess, microseconds per call.
- Take one process-table snapshot per iteration and derive all descendants from it, instead of one snapshot per PID.
- In `terminateAll`, send SIGTERM to every tree first, sleep the grace period once, then SIGKILL survivors, so N roots cost one grace period. Run it off-main with a bounded wait in `applicationShouldTerminate` (`.terminateLater`, then `reply(toApplicationShouldTerminate:)`).

**Acceptance test.** Existing ProcessTreeTerminator tests pass unchanged. New test: `terminateAll` over 4 fake roots each with 3 children finishes in under 0.8 s total, and no `/bin/ps` is launched (probe via an injectable process lister).

**Effort.** S.

---

### PERF-12 (P2) Blocking waits pin cooperative-pool threads

**Evidence.** A scanner found 32 `waitUntilExit`/`wait()` calls inside `async` functions or `Task` closures. Beyond PERF-02, the important ones:
- `FASTQIngestionService.runCLISubprocess` blocks in `process.waitUntilExit()` inside an async function for the whole import ([FASTQIngestionService.swift:1514](Sources/LungfishApp/Services/FASTQIngestionService.swift:1514)).
- `AlignmentDataProvider.runSamtools` runs `runSamtoolsProcess` in `Task.detached`, which blocks on `group.wait(timeout:)` for up to 30-60 s ([AlignmentDataProvider.swift:1186](Sources/LungfishIO/Bundles/AlignmentDataProvider.swift:1186), [:1248](Sources/LungfishIO/Bundles/AlignmentDataProvider.swift:1248)). `Task.detached` runs on the same cooperative pool as everything else.
- `ToolProvisioner`, `AppleContainerRuntime.runAndWait`, `DockerRuntime.exec`, `GATKPipelineExecutor.run`, `IlluminaAmpliconPairMerger.runProcess` (full list reproducible with the scanner in Method).

**Impact.** Suspected rather than observed. The cooperative pool is sized to the core count. A batch import of several samples plus viewer fetches and TaxTriage or EsViritu dedup loops (PERF-04 calls `fetchReads` serially per contig) can occupy most pool threads with blocked waits. Symptoms would be other async work (search index, sidebar scans, detached hashing) stalling with no CPU use. The main thread is unaffected because it is not in the pool.

**Recommendation.** Adopt one `ProcessExecution` utility in LungfishWorkflow that is fully async: `terminationHandler` resumes a continuation, output is drained by `readabilityHandler` or a dedicated reader thread, and cancellation uses `withTaskCancellationHandler`. `CLIVariantCallingRunner` already implements this shape ([CLIVariantCallingRunner.swift:410](Sources/LungfishApp/Services/CLIVariantCallingRunner.swift:410)). Where blocking code must stay, run it on a dedicated serial or concurrent `DispatchQueue`, not in `Task.detached`.

**Acceptance test.** Stress test that launches `ProcessInfo.activeProcessorCount + 2` concurrent 2-second fake tool runs through the new utility and asserts an unrelated `Task.detached { 1 + 1 }` completes in under 100 ms.

**Effort.** M (utility S, migration incremental).

---

### PERF-13 (P2) Helper-subprocess cancellation signals only the root

**Evidence.**
- The VCF import helper loop polls every 100 ms and calls `process.terminate()` on cancel ([AppDelegate+ImportCenter.swift:1709](Sources/LungfishApp/App/AppDelegate+ImportCenter.swift:1709) to [:1717](Sources/LungfishApp/App/AppDelegate+ImportCenter.swift:1717)). Two sibling helper loops do the same ([:1903](Sources/LungfishApp/App/AppDelegate+ImportCenter.swift:1903), [:2087](Sources/LungfishApp/App/AppDelegate+ImportCenter.swift:2087)), as does [BAMImportHelperClient.swift:190](Sources/LungfishApp/Services/BAMImportHelperClient.swift:190).
- The helper spawns `bcftools view` and `bcftools index` children ([VCFImportHelper.swift:727](Sources/LungfishApp/App/VCFImportHelper.swift:727), [:766](Sources/LungfishApp/App/VCFImportHelper.swift:766)) and blocks on them. `Process.terminate()` sends SIGTERM to the helper only, and those helpers are not registered in `NativeProcessRegistry`.
- Orphaning is **Suspected**. No SIGTERM handler was found that forwards to children, so a `bcftools view` on a large chromosome would continue writing into a staging directory that the parent is deleting.

**Impact.** A cancelled cohort VCF import can leave `bcftools` running for minutes, using CPU and disk, and the "Cancelled" state is not truthful. Quitting during such an import leaves orphans because the helper is not in the registry.

**Recommendation.** Register helper processes with `NativeProcessRegistry` and use `ProcessTreeTerminator.terminate(rootProcess:)` (after PERF-11) on cancel. Replace the `Thread.sleep` polling with a `terminationHandler` plus a cancellation callback.

**Acceptance test.** Integration test with a fake helper that spawns `sleep 30` as a child. After cancel, no process with the child's PID exists within 1 s.

**Effort.** S.

---

### PERF-14 (P3) Racy output-drain idioms

**Evidence.**
- `CondaManager.runTool` and the micromamba runner append to `nonisolated(unsafe) NSMutableData` buffers from `readabilityHandler`, then read them 100 ms after `terminationHandler` fires, "to let any remaining readabilityHandler callbacks drain" ([CondaManager.swift:1094](Sources/LungfishWorkflow/Conda/CondaManager.swift:1094) to [:1146](Sources/LungfishWorkflow/Conda/CondaManager.swift:1146), [:1474](Sources/LungfishWorkflow/Conda/CondaManager.swift:1474) to [:1506](Sources/LungfishWorkflow/Conda/CondaManager.swift:1506)). A time delay is not a happens-before edge: a late handler can append while the reader converts the buffer (a data race on `NSMutableData`), and output still in the pipe after 100 ms is lost.
- The helper runner calls `readerGroup.enter()` inside the `readabilityHandler` ([AppDelegate+ImportCenter.swift:1681](Sources/LungfishApp/App/AppDelegate+ImportCenter.swift:1681)), so `readerGroup.wait()` can return before a dispatched-but-not-started handler enters, and then `readDataToEndOfFile` races that handler on the same handle.

**Impact.** Low today: `runTool` callers mostly parse version and help text ([DatabaseRegistry.swift:1392](Sources/LungfishWorkflow/Databases/DatabaseRegistry.swift:1392), [ClassificationPipeline.swift:175](Sources/LungfishWorkflow/Metagenomics/ClassificationPipeline.swift:175)). This becomes a wrong-answer bug the day someone uses `runTool` stdout for data.

**Recommendation.** Migrate both to the PERF-12 utility: drain until EOF on each pipe, join (exit, stdout EOF, stderr EOF), and only then read the buffers. Delete the 100 ms delays.

**Acceptance test.** Test running a fake tool that writes 1 MB to stdout and exits immediately. `runTool` returns all 1,048,576 bytes, 100 of 100 runs.

**Effort.** S.

---

### PERF-15 (P3) Unbounded per-operation log history

**Evidence.** `OperationCenter.Item.logEntries` grows without a cap through `log` and `updateWithLog` ([OperationCenter.swift:171](Sources/LungfishKit/OperationCenter.swift:171), [:498](Sources/LungfishKit/OperationCenter.swift:498), [:569](Sources/LungfishKit/OperationCenter.swift:569)). There are 132 `OperationCenter.shared.log(` call sites, some carrying full stderr of each tool invocation ([AppDelegate+ImportCenter.swift:1123](Sources/LungfishApp/App/AppDelegate+ImportCenter.swift:1123)). `hasWarnings` scans the array linearly ([:188](Sources/LungfishKit/OperationCenter.swift:188)), and items persist until "Clear Completed".

**Impact.** Minor memory growth in long sessions, plus linear scans on each row refresh. Not user-visible yet.

**Recommendation.** Cap entries per item (for example 2,000, keeping the first 100 and the last 1,900 with a "N entries elided" marker), truncate individual messages over 64 KB with the full text going to the failure report store, and cache `hasWarnings` as a stored flag.

**Acceptance test.** Unit test that 10,000 `log` calls leave at most 2,000 entries and `hasWarnings` stays correct.

**Effort.** S.

---

### PERF-16 (P3) Remaining deprecated modal APIs, redundant hops, and test seams in production types

**Evidence.**
- App-modal `runModal` where a sheet is expected: the matrix comment editor ([GenotypeComparisonMatrixView.swift:3823](Sources/LungfishGenotypeUI/GenotypeComparisonMatrixView.swift:3823)) and the Primer3 folder chooser ([Primer3ResultsView.swift:154](Sources/LungfishApp/Views/PrimerAnalysis/Primer3ResultsView.swift:154)). `ProjectLockResolutionDialog` uses `runModal` only when no window exists ([ProjectLockResolutionDialog.swift:141](Sources/LungfishApp/App/ProjectLockResolutionDialog.swift:141)), which is acceptable.
- Timers scheduled on the main run loop re-hop through `DispatchQueue.main.async` before `assumeIsolated` ([SequenceViewerView+Interaction.swift:1840](Sources/LungfishApp/Views/Viewer/SequenceViewerView+Interaction.swift:1840), [OperationsPanelController.swift:337](Sources/LungfishApp/Views/Operations/OperationsPanelController.swift:337), [HoverTooltipView.swift:331](Sources/LungfishApp/Views/Viewer/HoverTooltipView.swift:331), [ProgressOverlayView.swift:82](Sources/LungfishApp/Views/Viewer/ProgressOverlayView.swift:82)). The timer callback is already on main (compare the correct usage at [SequenceViewerView.swift:1311](Sources/LungfishApp/Views/Viewer/SequenceViewerView.swift:1311)). The extra hop adds a run-loop turn of latency.
- Mutable static test probes on production types: for example [ProvenanceInspectorViewModel.swift:592](Sources/LungfishApp/Views/Inspector/ProvenanceInspectorViewModel.swift:592), [SequenceViewerView+Interaction.swift:1643](Sources/LungfishApp/Views/Viewer/SequenceViewerView+Interaction.swift:1643), [VariantDatabase+CreateFromVCF.swift:18](Sources/LungfishIO/Bundles/VariantDatabase+CreateFromVCF.swift:18), and [GenotypeOutlineView.swift:647](Sources/LungfishGenotypeUI/GenotypeOutlineView.swift:647). They are read from background threads without synchronization. They are harmless in production only while nothing writes them.
- `wantsLayer = true` at [AnnotationTableDrawerView.swift:747](Sources/LungfishApp/Views/Viewer/AnnotationTableDrawerView.swift:747) and [HoverTooltipView.swift:195](Sources/LungfishApp/Views/Viewer/HoverTooltipView.swift:195). This is a no-op on macOS 26 and conflicts with the project's own macOS 26 rules.

**Recommendation.** Convert the two `runModal` sites to `beginSheetModal`. Call `MainActor.assumeIsolated` directly in main-run-loop timer blocks. Move probes behind `#if DEBUG` or into an injected `TestHooks` value guarded by a lock (`Mutex` from Synchronization). Delete the `wantsLayer` lines.

**Acceptance test.** Grep gates: no `runModal()` outside the documented fallback, and no `nonisolated(unsafe) static var` outside `#if DEBUG`.

**Effort.** S.

## Proposed work packages

Ordered by user-visible impact per unit of risk. Each package is independently reviewable.

| # | Package | Findings | Files touched | Depends on | Risk |
|---|---|---|---|---|---|
| WP1 | **Unique-read counting correctness** | PERF-04, the counting half of PERF-03 | `AlignmentDataProvider.swift` (new streaming counter), `AlignedReadDedup.swift`, `TaxTriageResultViewController.swift`, `EsVirituResultViewController.swift`, cache schema version | Science reviewer sign-off on the dedup key definition | Medium: changes displayed numbers, so it needs a release note and cache invalidation |
| WP2 | **Main-thread freezes on scientific actions and sidebar refresh** | PERF-01, PERF-05 | `AlignmentScientificActionCoordinator.swift`, `AlignmentActionContext.swift`, `SidebarViewController.swift` plus 7 caller files | None | Low: both have working async templates in the codebase |
| WP3 | **Unblock `NativeToolRunner` and a shared async process utility** | PERF-02, PERF-12, PERF-14 | `NativeToolRunner.swift`, new `ProcessExecution.swift` in LungfishWorkflow, `CondaManager.swift`, `FASTQIngestionService.swift`, `AlignmentDataProvider.swift` (non-budgeted path) | None, but land before WP5 | Medium: touches every native tool path. Keep the existing cancellation and timeout test suite green and add the concurrency test from PERF-02 |
| WP4 | **TaxTriage off-main discovery and table sync** | PERF-03 (remaining), PERF-07 classifier half | `TaxTriageResultViewController.swift`, `MainSplitViewController+ClassifierDisplay.swift` | WP1 (same functions) | Low-medium |
| WP5 | **Process termination cost and helper cancellation** | PERF-11, PERF-13 | `ProcessTreeTerminator.swift`, `AppDelegate.swift` (terminate flow), `AppDelegate+ImportCenter.swift`, `BAMImportHelperClient.swift`, `MetagenomicsImportHelperClient.swift` | WP3 helps but is not required | Medium: quit path. Test with real child trees |
| WP6 | **Memory: exports and orient maps** | PERF-06, PERF-08 | `AppDelegate+ImportCenter.swift` (export loaders), `GzipSupport.swift` (doc and deprecation of `readAll` for genomes), `FASTQDerivativeFileIO.swift`, `FASTQDerivativeService+Materialization.swift`, `FASTQCLIMaterializer.swift` | None | Low |
| WP7 | **Variant DB metadata and viewer open path** | PERF-07 viewer half | `VariantDatabase+Metadata.swift`, `VariantDatabase+CreateFromVCF.swift` (write metadata), `SequenceViewerView.swift` | None. Existing DBs need an off-main fallback | Low-medium: schema addition must be backward compatible |
| WP8 | **Rendering polish** | PERF-09, PERF-10 | `SequenceViewerView.swift`, `SequenceViewerView+Interaction.swift`, `MultipleSequenceAlignmentViewController.swift` | None | Low. Verify visually with the Computer Use GUI pass the project requires |
| WP9 | **Hygiene** | PERF-15, PERF-16 | `OperationCenter.swift`, the two `runModal` sites, probe declarations | None | Low |

### Do not fix (accept)

- **The 219 `@unchecked Sendable` and 405 `assumeIsolated` counts as such.** Sampling found them overwhelmingly correct. A blanket "remove `@unchecked`" campaign would churn hundreds of files for little safety gain. Fix only the racy boxes in PERF-14. When touching a lock-guarded box, migrating `NSLock` to `Mutex` is a fine opportunistic change, but it is not a work package.
- **Semaphores in helper-mode entry points** ([BAMImportHelper.swift:52](Sources/LungfishApp/App/BAMImportHelper.swift:52), [MetagenomicsImportHelper.swift:81](Sources/LungfishApp/App/MetagenomicsImportHelper.swift:81)). They block a process's synchronous `main` while an async task runs, which is the standard bridge.
- **Wait-before-read on stderr-only pipes around `gzip`** (for example [CountedFASTQMaterializer.swift:248](Sources/LungfishWorkflow/FASTQ/CountedFASTQMaterializer.swift:248), [DemultiplexingPipeline.swift:2690](Sources/LungfishWorkflow/Demultiplex/DemultiplexingPipeline.swift:2690)). `gzip` writes a few bytes of stderr at most, so this cannot deadlock. Migrate these only if WP3's utility makes it free.
- **`FileHandle.synchronize()` calls.** These are fsync on output files, which is intentional durability, not the deprecated `UserDefaults.synchronize`.
- **NSSplitView delegate methods** in [FASTQDatasetViewController.swift:2878](Sources/LungfishApp/Views/Viewer/FASTQDatasetViewController.swift:2878), [AssemblyResultViewController.swift:681](Sources/LungfishAssemblyUI/AssemblyResultViewController.swift:681) and [ReferenceBundleViewportController.swift:1953](Sources/LungfishApp/Views/Results/Reference/ReferenceBundleViewportController.swift:1953). They sit on plain `NSSplitView`s, where they are supported. The macOS 26 rule applies only to `NSSplitViewController`, and the main window correctly avoids them ([MainSplitViewController+ShellLayout.swift:658](Sources/LungfishApp/Views/MainWindow/MainSplitViewController+ShellLayout.swift:658)).
- **Whole-file `Data(contentsOf:)` for manifests and small sidecars** (about 300 sites). These are kilobyte-sized JSON files. Only genome- or read-scale loads (PERF-06, PERF-08) matter.
