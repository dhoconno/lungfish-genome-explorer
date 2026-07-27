# Project Storage Lifecycle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop future hidden-data accumulation and provide a safe, previewed, provenance-complete way to move proven legacy Lungfish work products to Trash.

**Architecture:** Low-level identity, marker, fsync, and no-follow removal primitives live in LungfishIO; project scanning, journaling, cleanup execution, and provenance live in LungfishWorkflow; the app owns only window-scoped coordination and native presentation. Automatic cleanup operates only on the current owned path, while legacy cleanup always requires classification, preview, and confirmation.

**Tech Stack:** Swift 6, Foundation, Darwin filesystem APIs, AppKit, XCTest, Lungfish canonical provenance.

---

### Task 1: Make owned work-directory markers durable and authoritative

**Files:**
- Create: `Sources/LungfishIO/Storage/DurableAtomicFileStore.swift`
- Create: `Sources/LungfishIO/Storage/OwnedWorkDirectoryMarker.swift`
- Create: `Sources/LungfishIO/Storage/OwnedRunLock.swift`
- Create: `Sources/LungfishWorkflow/Storage/ProjectOperationHistoryWriter.swift`
- Create: `Tests/LungfishIOTests/OwnedWorkDirectoryMarkerTests.swift`
- Create: `Tests/LungfishIOTests/OwnedRunLockTests.swift`
- Create: `Tests/LungfishWorkflowTests/ProjectOperationHistoryWriterTests.swift`
- Modify: `Sources/LungfishIO/Bundles/ProjectTempDirectory.swift:118-290`
- Modify: `Tests/LungfishIOTests/ProjectTempDirectoryTests.swift`

- [x] **Step 1: Write failing identity and marker tests**

Assert schema, project and child device/inode, run UUID, process-start and boot identity, completion state, lock path, Keep Intermediates, tool/version, atomic creation, parent fsync, rollback on marker failure, PID reuse rejection, symlink/special-file rejection, and automatic refusal of unmarked legacy children.

Also assert a shared nonblocking run-lock can be acquired/probed by full-length
and miSeq workflows, and a shared operation-history writer exclusively creates
append-only UUID directories with atomic/fsynced payloads.

- [x] **Step 2: Run tests and verify RED**

Run: `swift test --filter 'OwnedWorkDirectoryMarkerTests|OwnedRunLockTests|ProjectOperationHistoryWriterTests|ProjectTempDirectoryTests'`

Expected: compile failure because the authoritative marker types do not exist.

- [x] **Step 3: Implement durable creation**

```swift
public struct OwnedWorkDirectoryMarker: Codable, Equatable, Sendable {
    public static let schemaVersion = 2
    public let projectIdentity: FileSystemObjectIdentity
    public let directoryIdentity: FileSystemObjectIdentity
    public let runID: UUID
    public let processStartTime: UInt64
    public let bootSessionID: String
    public let state: State
    public let lockRelativePath: String?
    public let keepIntermediates: Bool
    public let toolName: String
    public let toolVersion: String
}
```

Create the directory, obtain no-follow identities, write a temporary sorted JSON marker with exclusive creation, fsync file, rename exclusively, fsync parent, and remove the new directory if any step fails. Route every project-local `ProjectTempDirectory.create` overload through this path.

Move the reusable flock/nonblocking-probe behavior out of the full-length-only
lock into `OwnedRunLock`, and make `ProjectOperationHistoryWriter` the single
durable path/layout authority reused by failure envelopes, storage journals,
and disposition receipts.

- [x] **Step 4: Run tests and verify GREEN**

Run: `swift test --filter 'OwnedWorkDirectoryMarkerTests|OwnedRunLockTests|ProjectOperationHistoryWriterTests|ProjectTempDirectoryTests'`

Expected: all selected tests pass.

- [x] **Step 5: Commit**

```bash
git add Sources/LungfishIO/Storage Sources/LungfishWorkflow/Storage/ProjectOperationHistoryWriter.swift Sources/LungfishIO/Bundles/ProjectTempDirectory.swift Tests/LungfishIOTests Tests/LungfishWorkflowTests/ProjectOperationHistoryWriterTests.swift
git commit -m "feat: attest owned project work directories"
```

### Task 2: Replace workbook archives with cleanup-pending recovery

**Files:**
- Create: `Sources/LungfishIO/Bundles/ONTGenotypeWorkbookCleanupState.swift`
- Modify: `Sources/LungfishIO/Bundles/ONTGenotypeWorkbookUpdateTransaction.swift:500-700,1324-1345`
- Modify: `Tests/LungfishWorkflowTests/GenotypeWorkbookRevisionServiceTests.swift:1770-1810`

- [x] **Step 1: Replace the archive expectation with failing state-machine tests**

Cover committed, prepared-discard, rollback, and manual-save-winner branches with injected faults after detach, after state durability, after marker removal, and during quarantine traversal. Assert no permanent generation archive remains, a valid generation is always authoritative, and cleanup retry cannot delete a substituted inode.

Traversal failure must also durably record and surface a storage warning naming
the retained quarantine and retry state.

- [x] **Step 2: Run the focused test and verify RED**

Run: `swift test --filter GenotypeWorkbookRevisionServiceTests/testAutomaticFinalizationDetachesAndRemovesRetiredGeneration`

Expected: failure because the code creates `.lungfish-workbook-generation-archive-*`.

- [x] **Step 3: Implement the cleanup-pending state machine**

Rename the proven retired root exclusively to `.lungfish-workbook-cleanup-pending-<transactionID>`, fsync the parent, durably record source/quarantine identities and terminal decision, then retire marker/attestation. Recursive removal targets only the detached quarantine and never follows symlinks. Recovery processes cleanup state even when the original transaction marker is gone.

- [x] **Step 4: Run all workbook recovery tests**

Run: `swift test --filter GenotypeWorkbookRevisionServiceTests`

Expected: all selected tests pass.

- [x] **Step 5: Commit**

```bash
git add Sources/LungfishIO/Bundles/ONTGenotypeWorkbookCleanupState.swift Sources/LungfishIO/Bundles/ONTGenotypeWorkbookUpdateTransaction.swift Tests/LungfishWorkflowTests/GenotypeWorkbookRevisionServiceTests.swift
git commit -m "fix: reclaim retired workbook generations safely"
```

### Task 3: Correct full-length and miSeq work-directory lifecycles

**Files:**
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCGenotypingPipeline.swift:880-1105,5605-5635`
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/ONTBarcodeDemuxGenotypingPipeline.swift:900-980`
- Modify: `Sources/LungfishCLI/Commands/FastqGenotypingSubcommand.swift`
- Modify: `Sources/LungfishCLI/Commands/FastqONTBarcodeGenotypingSubcommand.swift`
- Modify: `Sources/LungfishApp/Services/WorkflowOperationExecutionService.swift`
- Modify: `Sources/LungfishApp/Views/WorkflowOperations/WorkflowOperationDialogState.swift`
- Modify: `Sources/LungfishApp/Views/WorkflowOperations/WorkflowOperationsDialog.swift`
- Create: `Tests/LungfishAppTests/WorkflowKeepIntermediatesOptionTests.swift`
- Test: `Tests/LungfishWorkflowTests/FullLengthONTMHCGenotypingPipelineTests.swift`
- Test: `Tests/LungfishWorkflowTests/ONTBarcodeDemuxGenotypingPipelineTests.swift`
- Test: `Tests/LungfishCLITests/FastqGenotypingCommandTests.swift`

- [x] **Step 1: Write failing lifecycle and append-only failure tests**

Assert default success/failure removes large derived FASTQ roots after compact diagnostics are durable, explicit Keep Intermediates retains them, every sibling root shares the run UUID/lock marker, cleanup errors name exact paths, later runs never delete prior failure envelopes, miSeq preserves final evidence BAM/BAI, and miSeq no longer swallows `.amplicon-genotyping` cleanup failure.

Assert all related markers transition durably from active to completed or
failed only after the matching final/failure provenance is durable, and a later
run records supersession without rewriting prior history. Add UI assertions for
a genotype-workflow-only **Keep Intermediates** checkbox with help text
explaining disk cost and diagnostic use.

- [x] **Step 2: Run tests and verify RED**

Run: `swift test --filter 'FullLengthONTMHCGenotypingPipelineTests|ONTBarcodeDemuxGenotypingPipelineTests'`

Expected: new assertions fail because stale receipts are removed and miSeq cleanup uses `try?`.

- [x] **Step 3: Implement one explicit lifecycle policy**

Add `keepIntermediates` to miSeq request/CLI/app resolved options, including the
deprecated amplicon command wrapper. Expose it in the workflow dialog only for
the two MHC genotype workflows with clear help text. Adopt `OwnedRunLock` in
both pipelines. Create all transient roots with authoritative markers. After
final artifact and provenance durability, durably transition every marker and
remove current-run transient roots unless retained. On failure, first publish
an append-only envelope through `ProjectOperationHistoryWriter`, transition
markers to failed, then clean payloads and append disposition/errors. Replace
`removeStaleFailureReceipts` with supersession metadata that never deletes old
envelopes.

- [x] **Step 4: Run workflow, CLI, and provenance tests**

Run: `swift test --filter 'FullLengthONTMHCGenotypingPipelineTests|ONTBarcodeDemuxGenotypingPipelineTests|FastqGenotypingCommandTests|WorkflowKeepIntermediatesOptionTests|ScientificCLIProvenanceCoverageTests'`

Expected: all selected tests pass.

- [x] **Step 5: Commit**

```bash
git add Sources/LungfishWorkflow/ONTGenotyping Sources/LungfishCLI/Commands/FastqGenotypingSubcommand.swift Sources/LungfishCLI/Commands/FastqONTBarcodeGenotypingSubcommand.swift Sources/LungfishApp/Services/WorkflowOperationExecutionService.swift Sources/LungfishApp/Views/WorkflowOperations Tests
git commit -m "fix: bound MHC genotyping intermediate storage"
```

### Task 4: Build streaming project storage classification

**Files:**
- Create: `Sources/LungfishWorkflow/Storage/ProjectStorageModels.swift`
- Create: `Sources/LungfishWorkflow/Storage/ProjectStorageScanner.swift`
- Create: `Sources/LungfishWorkflow/Storage/ProjectStorageLegacyWorkbookClassifier.swift`
- Create: `Tests/LungfishWorkflowTests/ProjectStorageScannerTests.swift`
- Modify: `Sources/LungfishIO/Bundles/ONTGenotypeWorkbookUpdateTransaction.swift`

- [x] **Step 1: Write failing scanner/classifier tests**

Cover exact owned patterns, individual `.tmp` children, archive proof against exactly one retained live revision, lock-held and ambiguous entries, explicit retention, symlinks/special files, live bundles, operation history exclusion, logical/allocated byte counts, hard-link deduplication, cancellation, and incremental progress. Unknown entries must appear as not removable with a reason.

Legacy archive fixtures explicitly include normal finalization without a
receipt, prepared generation, manual-save winner, receipt/transaction-ID
disagreement, tampered name/content, missing live bundle, duplicate live
candidates, and a live attestation claim.

For ordinary project-temp children left active by a process crash, classify
them orphan-removable only when the marker's boot/process-start identity is
conclusively dead, the recorded lock is not held, directory identity still
matches, Keep Intermediates is false, and no operation-history record claims
live work. PID absence or age alone is insufficient.

- [x] **Step 2: Run tests and verify RED**

Run: `swift test --filter ProjectStorageScannerTests`

Expected: compile failure because scanner types do not exist.

- [x] **Step 3: Implement bounded, no-hash preview scanning**

```swift
public struct ProjectStorageEntry: Identifiable, Sendable {
    public enum Category: Sendable { case workbookArchive, workflowStaging, temporary }
    public let id: UUID
    public let relativePath: String
    public let identity: FileSystemObjectIdentity
    public let category: Category
    public let logicalBytes: UInt64
    public let allocatedBytes: UInt64
    public let classification: Classification
}
```

Use streaming directory enumeration, `lstat`, `(device,inode)` hard-link
accounting, and `st_blocks * 512`. Skip descendants of live Lungfish bundles
and `.lungfish-operation-history`. Probe `OwnedRunLock` and a narrow public,
fail-closed workbook publication-lock/archive inspection API rather than
duplicating private attestation rules.

- [x] **Step 4: Run tests and verify GREEN**

Run: `swift test --filter ProjectStorageScannerTests`

Expected: all scanner tests pass.

- [x] **Step 5: Commit**

```bash
git add Sources/LungfishWorkflow/Storage Sources/LungfishIO/Bundles/ONTGenotypeWorkbookUpdateTransaction.swift Tests/LungfishWorkflowTests/ProjectStorageScannerTests.swift
git commit -m "feat: classify reclaimable project storage"
```

### Task 5: Add durable cleanup journal and provenance preparation

**Files:**
- Create: `Sources/LungfishWorkflow/Storage/ProjectStorageCleanupJournal.swift`
- Create: `Sources/LungfishWorkflow/Storage/ProjectStorageCleanupReceiptWriter.swift`
- Create: `Tests/LungfishWorkflowTests/ProjectStorageCleanupProvenanceTests.swift`

- [x] **Step 1: Write failing inventory/provenance tests**

Assert sorted file inventory, relative path, logical/allocated size, SHA-256 reuse from attested descriptors, hashing only after confirmation, deterministic tree digest, complete argv/options/defaults/runtime/status/wall/errors, fsynced journal/receipt, and zero mutation on cancellation or durability failure.

Use a backward-compatible embedded cleanup inventory rather than changing
`ProvenanceFileDescriptor`:

```swift
public struct ProjectStorageCleanupInventoryEntry: Codable, Equatable, Sendable {
    public let relativePath: String
    public let logicalSize: UInt64
    public let allocatedSize: UInt64
    public let sha256: String
    public let device: UInt64
    public let inode: UInt64
}
```

Add encode/decode tests for both the cleanup journal and canonical provenance
resolved-parameter representation.

- [x] **Step 2: Run tests and verify RED**

Run: `swift test --filter ProjectStorageCleanupProvenanceTests`

Expected: compile failure because journal and receipt writers do not exist.

- [x] **Step 3: Implement preparation under operation history**

Write `<project>/.lungfish-operation-history/storage-cleanups/<UUID>/journal.json` and canonical provenance with exclusive atomic publication and directory fsync. Inventory regular files without following links, reuse exact attested hashes, hash remaining files cancellably, and compute an aggregate digest over canonical sorted descriptors.

- [x] **Step 4: Run tests and verify GREEN**

Run: `swift test --filter ProjectStorageCleanupProvenanceTests`

Expected: all provenance tests pass.

- [x] **Step 5: Commit**

```bash
git add Sources/LungfishWorkflow/Storage Tests/LungfishWorkflowTests/ProjectStorageCleanupProvenanceTests.swift
git commit -m "feat: journal project storage cleanup provenance"
```

### Task 6: Implement crash-recoverable Trash execution

**Files:**
- Create: `Sources/LungfishWorkflow/Storage/ProjectStorageCleanupExecutor.swift`
- Create: `Tests/LungfishWorkflowTests/ProjectStorageCleanupExecutorTests.swift`

- [x] **Step 1: Write failing executor tests with injected filesystem seams**

Cover identity and classification revalidation, lock acquisition after preview, exclusive same-parent detach to `.lungfish-trash-pending-*`, parent/journal fsync, platform Trash only after detach, safe restore, retained quarantine when restore is unsafe, crash before/after Trash, restart finalization, cancellation between items, partial results, read-only volumes, and no permanent-delete fallback.

- [x] **Step 2: Run tests and verify RED**

Run: `swift test --filter ProjectStorageCleanupExecutorTests`

Expected: compile failure because the executor does not exist.

- [x] **Step 3: Implement the identity-bound executor**

Use a project-identity-keyed actor for one mutation per project. Hold the relevant workflow/publication lock through revalidation, exclusive detach, Trash, and durable journal result. Invoke `FileManager.trashItem(at:resultingItemURL:)` only on the detached quarantine. Restore only if the original name is free and the recorded identity remains safe.

- [x] **Step 4: Run tests and verify GREEN**

Run: `swift test --filter 'ProjectStorageCleanupExecutorTests|ProjectStorageCleanupProvenanceTests'`

Expected: all selected tests pass.

Evidence (2026-07-27): the combined executor, scanner, lock, and cleanup
provenance suite executed 68 tests with 0 failures and 1 expected skip for the
real macOS Trash adapter in the managed sandbox. The implementation was
independently reviewed with `SPEC READY: YES` and `QUALITY READY: YES`,
including fail-closed run/workbook locking, cross-process serialization,
identity revalidation, durable crash recovery, partial results, cancellation,
and provenance error reporting.

- [x] **Step 5: Commit**

```bash
git add Sources/LungfishWorkflow/Storage/ProjectStorageCleanupExecutor.swift Tests/LungfishWorkflowTests/ProjectStorageCleanupExecutorTests.swift
git commit -m "feat: move proven project storage safely to Trash"
```

### Task 7: Remove destructive project-open and age-only cleanup

**Files:**
- Modify: `Sources/LungfishApp/App/AppDelegate.swift:740-815`
- Modify: `Sources/LungfishIO/Bundles/ProjectTempDirectory.swift:251-290`
- Create: `Sources/LungfishWorkflow/Storage/ProjectStorageAutomaticCleanupService.swift`
- Create: `Tests/LungfishWorkflowTests/ProjectStorageAutomaticCleanupServiceTests.swift`
- Modify: `Tests/LungfishAppTests/ProjectTempCleanupTests.swift`
- Modify: `Tests/LungfishAppTests/MainWindowSessionRoutingTests.swift`

- [ ] **Step 1: Write failing no-mutation and owned-child tests**

Assert opening a project performs no scan or cleanup; periodic cleanup runs off-main and only handles terminal, marker-owned, unlocked, non-retained children; live/unknown/unmarked/unsafe entries remain; disposition provenance and retry warnings are recorded.

Also assert an active marker from a conclusively dead process/boot identity is
handled as an orphan only after the full Task 4 proof; a reused PID, unknown
boot identity, held lock, retained marker, or matching live operation remains.

- [ ] **Step 2: Run tests and verify RED**

Run: `swift test --filter 'ProjectTempCleanupTests|MainWindowSessionRoutingTests'`

Expected: failure because current project open calls `cleanAll`.

- [ ] **Step 3: Remove production calls to whole-root/age-only deletion**

Keep compatibility methods deprecated if necessary, but route production
cleanup through `ProjectStorageAutomaticCleanupService`. The service classifies
individual owned children, acquires the shared lock, revalidates identity
without following links, writes a durable disposition receipt through the
shared operation-history writer, performs verified removal, and records
retryable warnings. Project open performs no storage mutation.

- [ ] **Step 4: Run tests and verify GREEN**

Run: `swift test --filter 'ProjectStorageAutomaticCleanupServiceTests|ProjectTempCleanupTests|MainWindowSessionRoutingTests|ProjectTempDirectoryTests'`

Expected: all selected tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishWorkflow/Storage/ProjectStorageAutomaticCleanupService.swift Sources/LungfishApp/App/AppDelegate.swift Sources/LungfishIO/Bundles/ProjectTempDirectory.swift Tests/LungfishWorkflowTests/ProjectStorageAutomaticCleanupServiceTests.swift Tests/LungfishAppTests/ProjectTempCleanupTests.swift Tests/LungfishAppTests/MainWindowSessionRoutingTests.swift
git commit -m "fix: stop deleting project temp data on open"
```

### Task 8: Add Manage Project Storage UI

**Files:**
- Create: `Sources/LungfishApp/Services/ProjectStorageCoordinator.swift`
- Create: `Sources/LungfishApp/Views/ProjectStorage/ProjectStorageSheetViewModel.swift`
- Create: `Sources/LungfishApp/Views/ProjectStorage/ProjectStorageSheetViewController.swift`
- Create: `Tests/LungfishAppTests/ProjectStorageSheetViewModelTests.swift`
- Modify: `Sources/LungfishApp/App/MainMenu.swift:285-295`
- Modify: `Sources/LungfishApp/App/AppDelegate.swift:899-960`
- Modify: `Sources/LungfishApp/App/XCUIAccessibilityIdentifiers.swift:202`
- Modify: `Sources/LungfishApp/Views/Sidebar/SidebarViewController+MenuDelegate.swift:16-100`
- Modify: `Tests/LungfishAppTests/AppShellAccessibilityTests.swift`
- Modify: `Tests/LungfishAppTests/MainMenuStructureTests.swift`

- [ ] **Step 1: Write failing menu, scope, and view-model tests**

Assert File → Manage Project Storage…, project-root-only context command, window/project identity binding, safe default checks, estimated allocated total, Return not destructive, Escape cancel, localized values, VoiceOver labels, cancellable progress, partial results, Retry Failed, and receipt/Trash reveal actions.

- [ ] **Step 2: Run tests and verify RED**

Run: `swift test --filter 'ProjectStorageSheetViewModelTests|AppShellAccessibilityTests|MainMenuStructureTests'`

Expected: missing type/menu-title failures.

- [ ] **Step 3: Implement native asynchronous sheet**

Use an `NSOutlineView` for category/entry rows. Scan and descriptor preparation off-main; throttle progress on the main actor. Bind coordinator lifetime to immutable window/project identity and disable stale actions after project change.

- [ ] **Step 4: Run app tests and verify GREEN**

Run: `swift test --filter 'ProjectStorageSheetViewModelTests|AppShellAccessibilityTests|MainMenuStructureTests|ProjectTempCleanupTests'`

Expected: all selected tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishApp/Services/ProjectStorageCoordinator.swift Sources/LungfishApp/Views/ProjectStorage Sources/LungfishApp/App Sources/LungfishApp/Views/Sidebar Tests/LungfishAppTests
git commit -m "feat: add project storage management sheet"
```

### Task 9: Verify storage safety and performance

**Files:**
- Create: `Tests/LungfishWorkflowTests/Fixtures/ProjectStorageLargeTreeFixture.swift`
- Create: `Tests/LungfishAppTests/ProjectStoragePerformanceTests.swift`
- Create: `docs/verification/project-storage-lifecycle.md`

- [ ] **Step 1: Add and run synthetic large-tree performance tests**

Generate sparse/small files and hard links at test time. Assert bounded memory
and signposts in workflow tests; assert no synchronous project-open traversal
and under 100 ms maximum main-thread slice in
`ProjectStoragePerformanceTests`.

Run: `swift test --filter 'ProjectStorageScannerTests|ProjectStorageCleanupExecutorTests|ProjectTempCleanupTests|ProjectStoragePerformanceTests'`

Expected: all selected tests pass within their budgets.

- [ ] **Step 2: Run full focused safety suite**

Run: `swift test --filter 'ProjectTempDirectoryTests|GenotypeWorkbookRevisionServiceTests|FullLengthONTMHCGenotypingPipelineTests|ONTBarcodeDemuxGenotypingPipelineTests|ProjectStorage'`

Expected: all selected tests pass.

- [ ] **Step 3: Record verification and commit**

Record test counts, fault points, timing/memory measurements, filesystem identity behavior, and evidence-artifact preservation.

```bash
git add Tests/LungfishWorkflowTests/Fixtures/ProjectStorageLargeTreeFixture.swift Tests/LungfishAppTests/ProjectStoragePerformanceTests.swift docs/verification/project-storage-lifecycle.md
git commit -m "test: verify project storage lifecycle safety"
```

- [ ] **Step 4: Run the full suite and release validation**

Run: `swift test`

Expected: the full Swift suite passes with no unexpected failures.

Run:

`python3 -m unittest scripts.tests.test_release_smoke scripts.tests.test_sparkle_release_packaging`

Expected: both release-validation test modules pass. Record the exact output in
the verification document. Do not publish, notarize, tag, or upload a release
as part of this feature plan.
