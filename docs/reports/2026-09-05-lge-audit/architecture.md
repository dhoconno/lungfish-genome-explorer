# Architecture, concurrency, AppKit, and persistence audit

Audited 2026-09-05 at commit `13e114087b1c0a994ad1d957ce7d71b963e5575d`. This is a read-only source audit; only this report was created. No builds, tests, app launches, benchmark runs, or scientific workflows were executed by this auditor. Findings marked confirmed are established by traced control flow; this does not mean a runtime reproduction was performed. The parent audit coordinates validation separately.

## Assessment

The project has meaningful architectural foundations: Core/IO/Workflow separation, several feature-specific UI modules, window-owned sessions, identity/generation checks, background filesystem scanning, operation routing context, and targeted behavioral tests. The central weakness is uneven adoption of those foundations. Older application entry points still use process-global documents, fire-and-forget cancellation, synchronous storage calls, and ad hoc recovery code. The most urgent work is to fix lifetime and durability contracts, then make those contracts uniform. A broad framework rewrite is unnecessary.

Priority meanings: P1 = high-consequence correctness/data-integrity issue to fix before relying on the affected behavior; P2 = bounded correctness or responsiveness defect; P3 = design/coverage improvement. These priorities are local to this report and may be normalized by the parent audit.

| ID | Priority | Finding | Evidence classification |
|---|---|---|---|
| ARCH-01 | P1 | Cancellation releases a bundle lock before the writer and its cleanup stop | Confirmed interleaving; actual VCF-import caller traced |
| ARCH-02 | P1 | Failed database rollback can delete the only recovery copy | Confirmed failure-path defect |
| ARCH-03 | P2 | Project open mutates storage before validating the project or respecting read-only warning | Confirmed control flow |
| ARCH-04 | P2 | Project restoration eagerly reconstructs all sequence content on MainActor | Confirmed blocking work; latency unmeasured |
| ARCH-05 | P2 | External document loads can overwrite newer selection/project state | Confirmed missing lifetime gate at application entry point |
| ARCH-06 | P2 | Global document notifications leak window-local documents; projectless facade retains old project | Confirmed state-routing defects |
| ARCH-07 | P2 | Root filesystem change silently permanently removes project refresh subscriptions | Confirmed lifecycle gap |
| ARCH-08 | P2 | Variant mutations copy and hash complete databases synchronously in AppKit actions | Confirmed blocking work; latency unmeasured |
| ARCH-09 | P2 | Future project format/schema versions are accepted for writing | Confirmed guard omission; future-version damage is a risk |
| ARCH-10 | P3 | Large controller responsibilities and independent file transactions increase change risk | Design assessment, not a defect inferred from size |

## Findings and remediation

### ARCH-01 — Cancellation is a request, but the operation center treats it as completion

**Evidence.** [OperationCenter.swift:711](/Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishKit/OperationCenter.swift:711) marks an operation cancelling, dispatches its synchronous `onCancel` callback, and schedules `finishCancellation` as soon as that callback returns. [OperationCenter.swift:776](/Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishKit/OperationCenter.swift:776) changes the row to cancelled and unlocks the bundle at line 783. The callback contract is `@Sendable () -> Void`, not an acknowledgement that work has drained.

This is not just a hypothetical API misuse. [AppDelegate+ImportCenter.swift:1065](/Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishApp/App/AppDelegate+ImportCenter.swift:1065) registers a bundle-targeted VCF import whose cancellation callback at line 1072 only flips a flag. The independent helper loop checks that flag periodically, terminates the child, and waits for its actual exit at [line 1585](/Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishApp/App/AppDelegate+ImportCenter.swift:1585). Cancellation cleanup later deletes the output database at [line 1375](/Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishApp/App/AppDelegate+ImportCenter.swift:1375). The database path is derived deterministically from source name and bundle at lines 1089–1092.

**Failure scenario.** Start an import, cancel, then restart the same import after its operation row says cancelled. The bundle is already available to the second operation while the first helper may still be exiting. The original cancellation cleanup can delete the database being created by the replacement operation. Even when no second job starts, “cancelled” and the reported wall time precede actual process exit and cleanup.

**Remediation.** Keep the lease while cancelling. Make the worker acknowledge completion only after child processes, streams, publication, and cleanup have terminated. Prefer an operation handle with `requestCancellation()` and an awaited `finished` result, or an explicit worker-owned terminal callback. Cancellation signaling must not itself release the lease. Cleanup should be tied to operation-owned staging identities, not a shared deterministic final pathname. Preserve the cancelled outcome even if a worker's final callback races with the request.

**Acceptance.** A deterministic worker held at a barrier remains the active lock holder after cancel. A second operation on the bundle is rejected until the old worker acknowledges exit and cleanup. Releasing that barrier transitions to cancelled once, then admits the replacement. Delay old cleanup deliberately and prove it cannot remove the replacement's output. Validate child termination latency and process exit, not just operation-row state.

### ARCH-02 — Rollback failures are swallowed and backups are discarded

**Evidence.** [VariantDeletionMutationService.swift:102](/Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishApp/Services/VariantDeletionMutationService.swift:102) creates backups and unconditionally removes the backup directory in `defer`. On a mutation/provenance failure it invokes `restore` at line 154. [The restore implementation:285](/Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishApp/Services/VariantDeletionMutationService.swift:285) removes the original database and copies the backup back, suppressing both errors with `try?`.

[VariantSampleMetadataImportService.swift:71](/Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishApp/Services/VariantSampleMetadataImportService.swift:71) uses the same unconditional backup cleanup, with an equivalent suppressed-error restoration at [line 283](/Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishApp/Services/VariantSampleMetadataImportService.swift:283). It also removes/restores WAL/SHM sidecars independently. The deletion service copies only the database file at line 279.

**Failure scenario.** Provenance writing fails after database mutation. Rollback successfully unlinks the changed database but cannot copy the backup because the target volume fills, disconnects, or denies a subsequent write. The caller receives only the original error; `defer` then deletes the surviving backup in the temporary directory. This loses both the target and its recovery copy. A process crash between unlink and copy also leaves the final path missing.

**Additional reliability risk.** These services back up or replace database files while the view retains search-index database handles: [AnnotationTableDrawerView.swift:2930](/Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishApp/Views/Viewer/AnnotationTableDrawerView.swift:2930). Raw file copying is not a database-level snapshot protocol; replacing a pathname does not rebind already-open connections. WAL consistency and the outcome with active readers/writers require a focused reproduction; they are not claimed as observed corruption here.

**Remediation.** Use a shared mutation transaction with an explicit recovery state. Retain recovery artifacts if restoration fails, return both primary and recovery errors, and present the recovery location to the user. Avoid remove-then-copy publication. Establish exclusive mutation ownership and coordinated reader invalidation/reopening; use a SQLite-supported snapshot/backup strategy where a live database must be copied. Couple mutation and provenance publication in the same recoverable commit protocol.

**Acceptance.** Inject failure into provenance write, original removal, restore copy, sidecar restoration, and final rename. At every boundary, reopening yields either the complete old state or complete new state; otherwise an intact recovery artifact and explicit recovery-required result remain. Existing [rollback test:67](/Users/dho/Documents/lungfish-genome-explorer/Tests/LungfishAppTests/VariantDeletionMutationServiceTests.swift:67) checks provenance failure followed by successful restoration, but does not exercise restoration failure or a retained live reader. Add those behavioral cases.

### ARCH-03 — Opening an invalid or locked project is not a read-only inspection

**Evidence.** [ProjectFile.swift:165](/Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishCore/Storage/ProjectFile.swift:165) checks only that the URL is a directory, then constructs `ProjectStore` at line 176 before loading metadata at line 179. [ProjectStore.swift:112](/Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishCore/Storage/ProjectStore.swift:112) creates the directory, may move a legacy database and sidecars, opens with `READWRITE | CREATE`, sets WAL pragmas, and initializes schema. [ProjectSession.swift:25](/Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishApp/StateManagement/ProjectSession.swift:25) evaluates a read-only warning but always uses this same writable opener. [AppDelegate.swift:434](/Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishApp/App/AppDelegate.swift:434) additionally performs analysis-directory migration before opening/evaluating the session.

**Failure scenario.** Opening a `.lungfish` directory missing `metadata.json` creates a `.project.db` before throwing and falling back to filesystem browsing. Opening an older project with an active external lock can initiate migration before the UI has established its warning state. The comment that opening is deliberately read-only at AppDelegate line 476 is therefore too broad. This does not imply every ordinary open writes scientific payload bytes; the creation/migration paths are the concrete problem.

**Remediation.** Separate `create`, `inspect`, `openReadOnly`, and `openWritable/migrate`. Validate metadata and compatibility before any write; pass an effective access mode through all storage layers. Inspect lock state before migration and fail closed for mutation when another writer owns the project. Explicit migration should have a recoverable transaction and provenance when it transforms scientific data.

**Acceptance.** Snapshot the directory tree, sizes, and checksums before opening malformed, future-version, externally locked, and valid read-only projects. An inspection/fallback open leaves those snapshots unchanged. Writable migration is exercised separately and cannot run under a conflicting lease.

### ARCH-04 — Project open and restoration perform unbounded sequence reconstruction on MainActor

**Evidence.** [ProjectSession.swift:23](/Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishApp/StateManagement/ProjectSession.swift:23) synchronously calls the MainActor-isolated `ProjectDocumentLoader`. [DocumentManager.swift:16](/Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishApp/App/DocumentManager.swift:16) lists every stored sequence, reconstructs its full content, builds a `Sequence`, and loads all annotations before returning. [ProjectFile.swift:257](/Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishCore/Storage/ProjectFile.swift:257) forwards to [ProjectStore.swift:560](/Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishCore/Storage/ProjectStore.swift:560), which loads the original and version history and applies all diffs. [AppDelegate.swift:1556](/Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishApp/App/AppDelegate.swift:1556) repeats this synchronously for each restored window, including multiple windows on the same project.

**Impact.** Large database-backed projects block menu handling and window interaction during open; memory scales with all loaded content and, for independently opened sessions, can multiply by window count. The newer filesystem/streaming paths do not fix this legacy database path. No stall duration or memory figure was measured.

**Remediation.** Load a small project/catalog snapshot first, then hydrate selected content off the main actor through a storage actor or serial worker. Keep UI reference objects on MainActor, but transfer immutable content snapshots. Share underlying project data/cache by canonical project identity while retaining per-window selection and navigation. Bound cache cost and cancel/discard hydration when session identity changes.

**Acceptance.** A large synthetic project opens its shell before full content materializes, a main-run-loop heartbeat continues throughout, and only selected documents are hydrated. Opening two windows does not duplicate a full-project eager load. Switching projects while a slow read is in progress cannot publish into the replacement session. Report measured UI latency and peak memory against a defined fixture rather than adding an arbitrary universal threshold.

### ARCH-05 — External file opens bypass the selection/session lifetime gates

**Evidence.** [AppDelegate.swift:1723](/Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishApp/App/AppDelegate.swift:1723) starts an untracked task, awaits `DocumentManager.shared.loadDocument`, then unconditionally displays it in the captured viewer. There is no cancellation handle, generation token, current-project check, or current-selection check at publication. [DocumentManager.swift:426](/Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishApp/App/DocumentManager.swift:426) appends the load into whichever global document state exists at completion and makes it active. [ViewerViewController.swift:3070](/Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishApp/Views/Viewer/ViewerViewController.swift:3070) switches content mode and hides other views, so a late result visibly replaces the current selection. Failure alerts at AppDelegate line 1743 use the then-current main window, which may differ from the initiating window.

**Failure scenario.** Externally open a slow file in window A, then select another item or open project B in the same window before parsing finishes. The original task eventually replaces the newer viewport and inserts a document into global state belonging to a later project. Two concurrent file opens can finish out of order. If the user moves focus to another window, the failure sheet can appear there instead.

**Remediation.** Route every external-open request through a per-window document coordinator using the same generation/identity discipline already present in sidebar loads. Separate loading from registration; registration and display must happen only after validating the originating session and request. Define whether concurrent opens queue or last-request-wins. Attach errors and progress to the originating request/window.

**Acceptance.** With a controllable delayed loader, perform A-then-B, project switch, window close, and window-focus switch. Late A must not replace B, append to the wrong project, clear B's progress, or present a sheet on an unrelated window.

### ARCH-06 — Window-local document ownership remains process-global in several paths

**Evidence.** Each split controller subscribes to the global document-loaded notification with no object filter at [MainSplitViewController.swift:772](/Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift:772). [MainSplitViewController+MultiDocument.swift:237](/Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishApp/Views/MainWindow/MainSplitViewController+MultiDocument.swift:237) adds every externally located document to its own Open Documents section without checking an originating window/session. Its containment test at line 253 compares string prefixes rather than path components.

Separately, [DocumentManager.swift:304](/Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishApp/App/DocumentManager.swift:304) does not clear `activeProject` when asked to mirror a projectless session if an old project is already set. [AppDelegate.swift:1512](/Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishApp/App/AppDelegate.swift:1512) calls this when a window becomes main. Legacy consumers still fallback to that singleton project, including [MainSplitViewController+MultiDocument.swift:481](/Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishApp/Views/MainWindow/MainSplitViewController+MultiDocument.swift:481).

**Failure scenarios.** Opening a standalone document in A adds it to B's Open Documents section. A file under `/tmp/project.lungfish-backup/` is incorrectly classified as being inside `/tmp/project.lungfish/`, so it is omitted from Open Documents even though the project watcher cannot surface it. Focusing a projectless window after a project window leaves legacy code observing the previous project; the wrong-project write risk depends on which downstream action is used and is not asserted as universally reachable.

**Remediation.** Make document membership a session-owned collection and publish typed events carrying a window/session ID. Keep any compatibility facade read-only and exactly reflective of the current session, including `nil`; eliminate singleton fallbacks from mutations. Use a single shared component-aware containment helper, with a deliberate symlink policy.

**Acceptance.** Open unrelated projects in A/B plus a projectless window C. Loading an external document in A changes only A's membership. Focus C and verify the compatibility facade has no project. Exercise sibling-prefix paths and symlink aliases. Session selection tests should include membership changes, not only independent active-document pointers.

### ARCH-07 — Root-change events silently terminate all refresh subscriptions

**Evidence.** [FileSystemWatcher.swift:516](/Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishApp/Services/FileSystemWatcher.swift:516) stops watching on a root-change event and invokes `onRootChanged`. The shared coordinator maps that to `removeWatcher`; [ProjectFilesystemRefreshCoordinator.swift:144](/Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishApp/Services/ProjectFilesystemRefreshCoordinator.swift:144) drops the watcher and every subscription without delivering a terminal/root-unavailable event. [SidebarViewController.swift:848](/Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishApp/Views/Sidebar/SidebarViewController.swift:848) receives only changed paths and therefore retains its stale subscription ID and displayed project. Registration happens on `openProject`, not automatically after invalidation.

**Failure scenario.** A project directory is renamed/moved, its volume disappears, or its root is replaced. Watchers stop, but the sidebar can remain visually normal and no longer receives updates. Restoring a directory at the old path does not restore the subscription. This can leave multiple project windows stale until explicit reopening.

**Remediation.** Model terminal watcher states in the coordinator's event type. Notify each subscriber before removing the watcher; mark the project unavailable/replaced, reconcile current identity, and offer or perform an appropriate rebind. Distinguish the same project moved from a different directory created at the old path.

**Acceptance.** Simulate root rename/removal/replacement with two subscribers. Both receive a state transition and stop advertising live refresh. Rebinding restores exactly one shared watcher and both subscriptions. A replacement directory with a different filesystem identity must not silently become the original project.

### ARCH-08 — Variant edit UI actions do full database backup/hash work on MainActor

**Evidence.** [AnnotationTableDrawerView.swift:2921](/Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishApp/Views/Viewer/AnnotationTableDrawerView.swift:2921) and [line 2958](/Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishApp/Views/Viewer/AnnotationTableDrawerView.swift:2958) directly call synchronous mutation services from AppKit action completion handlers. Those services copy each entire target database and compute input/output provenance descriptors before returning ([VariantDeletionMutationService.swift:102](/Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishApp/Services/VariantDeletionMutationService.swift:102), lines 130–147). Failure paths only log and return at drawer lines 2945–2947 and 2980–2982.

**Impact.** Deleting even a small selection can block the entire app proportional to total database size, not selected-row count. A failure can leave the user with no visible explanation. This is distinct from the rollback correctness issue in ARCH-02: moving unsafe rollback to a worker would improve responsiveness but would not make it safe.

**Remediation.** Run the recoverable mutation transaction on an owned storage worker with an operation lease, bounded progress updates, and cancellation acknowledgement. Snapshot target identities before leaving MainActor; validate session/generation before updating the view. Surface a recoverable error after failure, including rollback status. Coordinate retained readers as part of the same work.

**Acceptance.** A synthetic large database mutation keeps the main run loop responsive, reports progress, and updates only the initiating still-current view. Provenance or restore failures produce a user-visible result. Test a project switch and a competing writer during the operation.

### ARCH-09 — Project version declarations are decoded but not enforced

**Evidence.** `ProjectMetadata.formatVersion` is decoded at [ProjectFile.swift:368](/Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishCore/Storage/ProjectFile.swift:368), but `open` never checks it; `incompatibleVersion` exists at line 446 without being used in the open path. [ProjectStore.swift:239](/Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishCore/Storage/ProjectStore.swift:239) migrates lower schema versions but does not reject a `user_version` greater than the supported version. [ProjectFile.swift:345](/Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishCore/Storage/ProjectFile.swift:345) saves only known fields with the current format version.

**Scenario/risk.** A newer app writes a project that retains enough old fields/tables to decode. This older binary can open it writable and later rewrite metadata, silently discarding fields unknown to its model and relabeling the format. Acceptance of the future version is confirmed; an actual future schema with destructive incompatibility was not available and was not fabricated.

**Remediation.** Validate metadata and database versions before mutable initialization. Return a clear unsupported-newer-format error or deliberately limited read-only compatibility mode. Make schema upgrades transactional and explicit; do not silently downgrade format metadata.

**Acceptance.** Mutate only version fields in disposable fixtures to values above the supported versions. The application refuses writable open and leaves all bytes unchanged. Known versions and supported migration fixtures continue to load.

### ARCH-10 — Reduce concentrated controller responsibilities after fixing contracts

At this revision the source inventory contains 1,397 Swift files: 465 in LungfishApp, 376 in Workflow, 202 in IO, and 56 in the genotype UI leaf. Large files include `GenotypeResultViewController.swift` (12,168 lines), `GenotypeComparisonMatrixView.swift` (8,603), `AnnotationTableDrawerView.swift` (5,344), and `ViewerViewController.swift` (4,222). These counts are context, not proof of poor runtime behavior.

The traced defects arise at boundaries inside these controllers: external-open task ownership, global notification routing, user actions directly invoking storage, and mixed recovery conventions. Splitting arbitrary line ranges into extensions would preserve those problems. Extract coordinators around explicit invariants: document request lifetime, mutation ownership, commit/recovery, and per-window state. Keep AppKit for mature table/outline/viewer components and SwiftUI for suitable settings/sheets; no evidence supports replacing either UI framework wholesale.

**Acceptance.** A coordinator can be exercised with controlled async completion and fault injection without starting an app or inspecting source text. Controllers translate user intent and render immutable state; they do not own raw database publication or infer request ownership from the current key window. Conversion is incremental and must preserve existing view behavior.

## Positive patterns to preserve and extend

- The package dependency graph separates UI from the CLI and keeps Sparkle on the app executable. Feature-specific UI leaves and `LungfishKit` provide usable extraction boundaries; avoid introducing dependencies back from Core/IO to AppKit.
- [AsyncRequestGate.swift:7](/Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishApp/StateManagement/AsyncRequestGate.swift:7) provides a small identity/generation primitive. [MultiDocument.swift:109](/Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishApp/Views/MainWindow/MainSplitViewController+MultiDocument.swift:109) already validates selection generation around awaited loads. Extend that pattern to external-open paths instead of inventing another cancellation system.
- [ProjectStorageCoordinator.swift:205](/Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishApp/Services/ProjectStorageCoordinator.swift:205) validates window/controller/session/scope/generation and project path, with separately injected operations and identity readers. This is a concrete model for routing long-running work safely.
- `ProjectSessionRegistry` canonicalizes symlinks for project peers and retains window-local selection. `ProjectWindowStateStore` writes an explicit versioned envelope atomically. `ProjectFilesystemRefreshCoordinator` shares one watcher across project windows, and `FileSystemWatcher` drains FSEvents off the main thread. Preserve those designs while adding root invalidation handling.
- [GenotypeAnnotationPublicationCoordinator.swift:53](/Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishGenotypeUI/GenotypeAnnotationPublicationCoordinator.swift:53) acquires a publication lock, uses no-follow file access, stages/renames individual files, fsyncs, and includes rollback errors. These are stronger exception-safety practices than the variant mutation services. This audit does **not** certify its two-file publication as crash-atomic; that requires a separate crash/recovery review.
- `GenotypeManualHaplotypeDraftCoordinator` models transition reasons and draft revisions and deduplicates pending decisions. The app's quit path performs more deliberate draft preparation than a generic close-with-unsaved-state implementation. Preserve this behavior during controller extraction.
- `ProjectStore` uses explicit transactions for sequence/version writes, foreign keys, transient SQLite binds, and checked query completion. `VariantDatabase` checks required tables/columns and schema version. These positive checks should also exist at project-open boundaries.

## Suggested implementation sequence

1. **Contain data-integrity exposure:** fix operation cancellation acknowledgement and retain recovery artifacts on rollback failure. Add deterministic race/failure tests before broad refactoring. Review other `task.cancel()` and flag-only callbacks under the same operation-center contract.
2. **Establish one writable-project contract:** validate/access-mode decisions before storage initialization, explicit migration, unsupported-format rejection, and reader/writer ownership for mutable bundle databases.
3. **Complete per-window ownership:** a session-owned document catalog and external-open coordinator, scoped events, elimination of global mutation fallbacks, component-aware URL containment.
4. **Make expensive storage work asynchronous:** catalog-first project opening, selected-content hydration, and worker-owned mutation transactions. Measure event-loop responsiveness and memory with fixed synthetic fixtures.
5. **Finish lifecycle recovery:** watcher invalidation/rebinding, missing-volume recovery, and UI errors tied to the originating window. Then extract large controller subsystems along the now-tested boundaries.

## Coverage and limits

Read the package manifest; project store/file/session/registry/window-state implementations; application open/restore/close routing; DocumentManager/DocumentLoader; key main-split and viewer document paths; filesystem watcher/coordinator/sidebar registration; operation-center state and locking; one complete signal-only cancellation path through helper termination and cleanup; variant metadata/deletion transaction services and their UI callers; and representative draft/publication/storage coordinators. Examined relevant tests for existing coverage but did not execute them.

This is a representative, traced architectural audit, not a line-by-line review of all 1,397 Swift files. It does not certify all `@unchecked Sendable` classes, SQLite progress-handler synchronization, every SwiftUI invalidation path, accessibility, rendering performance, Objective-C lifetime edges, every process runner, or all filesystem race defenses. Those require targeted runtime instrumentation and additional focused reviews. Scientific algorithm correctness and operational workflow tuning were outside this auditor's scope. Missing provenance remains a blocking defect under the supplied project instructions; all recommended storage/migration refactors must preserve final payload identity and provenance together.
