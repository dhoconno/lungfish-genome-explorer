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
- Modify: `Sources/LungfishWorkflow/Storage/ProjectStorageScanner.swift`
- Create: `Tests/LungfishWorkflowTests/ProjectStorageAutomaticCleanupServiceTests.swift`
- Modify: `Tests/LungfishWorkflowTests/ProjectStorageScannerTests.swift`
- Modify: `Tests/LungfishAppTests/ProjectTempCleanupTests.swift`
- Modify: `Tests/LungfishAppTests/MainWindowSessionRoutingTests.swift`

- [x] **Step 1: Write failing no-mutation and owned-child tests**

Assert opening a project performs no scan or cleanup; periodic cleanup runs off-main and only handles terminal, marker-owned, unlocked, non-retained children; live/unknown/unmarked/unsafe entries remain; disposition provenance and retry warnings are recorded.

Also assert an active marker from a conclusively dead process/boot identity is
handled as an orphan only after the full Task 4 proof; a reused PID, unknown
boot identity, held lock, retained marker, or matching live operation remains.

- [x] **Step 2: Run tests and verify RED**

Run: `swift test --filter 'ProjectTempCleanupTests|MainWindowSessionRoutingTests'`

Expected: failure because current project open calls `cleanAll`.

- [x] **Step 3: Remove production calls to whole-root/age-only deletion**

Keep compatibility methods deprecated if necessary, but route production
cleanup through `ProjectStorageAutomaticCleanupService`. The service classifies
individual owned children, acquires the shared lock, revalidates identity
without following links, writes a durable disposition receipt through the
shared operation-history writer, performs verified removal, and records
retryable warnings. Project open performs no storage mutation.

- [x] **Step 4: Run tests and verify GREEN**

Run: `swift test --filter 'ProjectStorageAutomaticCleanupServiceTests|ProjectTempCleanupTests|MainWindowSessionRoutingTests|ProjectTempDirectoryTests'`

Expected: all selected tests pass.

Verification:

- `ProjectStorageAutomaticCleanupServiceTests|ProjectStorageScannerTests`:
  24 tests passed.
- `ProjectStorageAutomaticCleanupServiceTests|ProjectTempCleanupTests|MainWindowSessionRoutingTests`:
  40 tests passed.
- Independent specification review: 58 focused tests passed and
  `SPEC READY YES`.
- Independent quality review: 40 focused tests passed and
  `QUALITY READY YES`.
- The combined command built successfully and all 40 Task 7 service/app tests
  passed. The legacy `ProjectTempDirectoryTests` executed 15 tests successfully
  and reported 21 managed-environment failures because this sandbox denies
  `sysctl kern.bootsessionuuid` with `EPERM`; those failures are unrelated to
  this diff and were reproduced by both reviewers.

- [x] **Step 5: Commit**

```bash
git add Sources/LungfishWorkflow/Storage/ProjectStorageAutomaticCleanupService.swift Sources/LungfishWorkflow/Storage/ProjectStorageScanner.swift Sources/LungfishApp/App/AppDelegate.swift Sources/LungfishIO/Bundles/ProjectTempDirectory.swift Tests/LungfishWorkflowTests/ProjectStorageAutomaticCleanupServiceTests.swift Tests/LungfishWorkflowTests/ProjectStorageScannerTests.swift Tests/LungfishAppTests/ProjectTempCleanupTests.swift Tests/LungfishAppTests/MainWindowSessionRoutingTests.swift
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

- [x] **Step 1: Write failing menu, scope, and view-model tests**

Assert File → Manage Project Storage…, project-root-only context command, window/project identity binding, safe default checks, estimated allocated total, Return not destructive, Escape cancel, localized values, VoiceOver labels, cancellable progress, partial results, Retry Failed, and receipt/Trash reveal actions.

- [x] **Step 2: Run tests and verify RED**

Run: `swift test --filter 'ProjectStorageSheetViewModelTests|AppShellAccessibilityTests|MainMenuStructureTests'`

Expected: missing type/menu-title failures.

Evidence: the focused test command failed at compile time with missing
`ProjectStorageSheetViewModel`, coordinator/controller, selector, and
accessibility identifiers. Subsequent focused RED tests captured scan
fail-closed behavior, read-only guidance, selection-bound Trash reveal,
scan retry, complete row accessibility labels, and newest-paired cancellation
receipt recovery before their implementations.

- [x] **Step 3: Implement native asynchronous sheet**

Use an `NSOutlineView` for category/entry rows. Scan and descriptor preparation off-main; throttle progress on the main actor. Bind coordinator lifetime to immutable window/project identity and disable stale actions after project change.

- [x] **Step 4: Run app tests and verify GREEN**

Run: `swift test --filter 'ProjectStorageSheetViewModelTests|AppShellAccessibilityTests|MainMenuStructureTests|ProjectTempCleanupTests'`

Expected: all selected tests pass.

Review follow-up RED tests covered localized visible scan progress, a separate
one-second coalescing throttle for VoiceOver progress announcements with
immediate terminal announcements, complete category-row accessibility
metadata, and moved-byte/result summaries captured before failed-entry
reselection.

Evidence: the exact focused command passed 62 tests with zero failures.
`swift test --filter ProjectStorageCleanupProvenanceTests` additionally passed
15 provenance safety tests with zero failures.

- [x] **Step 5: Commit**

```bash
git add Sources/LungfishApp/Services/ProjectStorageCoordinator.swift Sources/LungfishApp/Views/ProjectStorage Sources/LungfishApp/App Sources/LungfishApp/Views/Sidebar Tests/LungfishAppTests
git commit -m "feat: add project storage management sheet"
```

### Task 9: Verify storage safety and performance

Task 9 has two verification authorities:

- **Deterministic CI gates** prove safety, cancellation, no hashing during
  preview, bounded retained scanner state, off-main execution, throttling,
  instrumentation balance, and complete cleanup provenance. They use injected
  clocks, limits, and event recorders and contain no wall-clock performance
  assertions.
- **Controlled-machine Release gates** prove the 100 ms maximum main-thread
  stall and the memory budget. A shared hosted runner may report these metrics,
  but it is never the release authority for either absolute budget.

The exact Task 9 skip matrix applies **only** to tests introduced in these
three new classes:

```text
ProjectStorageScannerLargeTreeTests
ProjectStorageCleanupPreparationLargeTreeTests
ProjectStoragePerformanceTests
```

Never apply that matrix to a pre-existing test. Pre-existing suites may already
have legitimate environment-dependent skips for the real Trash adapter,
openpyxl, case-sensitive volumes, optional fixtures/tools, network access, or
performance hardware. Those skips are accepted only when their full test-name,
reason, and multiplicity exactly match a same-machine base-commit run as
specified in Steps 7 and 9.

**Files:**
- Create:
  `Sources/LungfishWorkflow/Storage/ProjectStorageInstrumentation.swift`
  — storage-specific `OSSignposter` intervals and injectable counters.
- Modify:
  `Sources/LungfishWorkflow/Storage/ProjectStorageScanner.swift`
  — emit scan metrics and cap retained hard-link metadata.
- Modify:
  `Sources/LungfishWorkflow/Storage/ProjectStorageModels.swift`
  — add the visible `.resourceLimitExceeded` fail-closed classification code.
- Modify:
  `Sources/LungfishWorkflow/Storage/ProjectStorageCleanupReceiptWriter.swift`
  — emit descriptor-preparation metrics, including reused and computed hashes.
- Modify:
  `Sources/LungfishApp/Services/ProjectStorageCoordinator.swift`
  — inject the relay clock and instrument bounded main-actor commits.
- Modify: `Package.swift`
  — add `LungfishTestSupport` to `LungfishWorkflowTests` and
  `LungfishAppTests`.
- Create:
  `Tests/Support/LungfishTestSupport/ProjectStorageLargeTreeFixture.swift`
  — deterministic runtime-generated fixture profiles plus an independently
  implemented on-disk enumeration oracle shared by Workflow and App tests.
- Create:
  `Tests/LungfishWorkflowTests/Fixtures/ProcessMemorySampler.swift`
  — Darwin resident-footprint sampling with arm, stop, and join barriers for
  the isolated Release gate.
- Create:
  `Tests/LungfishWorkflowTests/ProjectStorageScannerLargeTreeTests.swift`
  — scaled scanner safety, hard-link, cancellation, and instrumentation tests.
- Create:
  `Tests/LungfishWorkflowTests/ProjectStorageCleanupPreparationLargeTreeTests.swift`
  — scaled descriptor-preparation and provenance tests.
- Create:
  `Tests/LungfishAppTests/ProjectStoragePerformanceTests.swift`
  — runtime project-open, off-main, throttling, and Release stall tests.
- Create:
  `scripts/verification/project-storage-task9-skip-policy.json`
  — exact base SHA plus the new-test class and skip matrix.
- Create:
  `scripts/verification/compare_project_storage_skips.py`
  — fail-closed serial-console skip parsing and exact multiset comparison.
- Create:
  `scripts/verification/run_project_storage_skip_comparison.sh`
  — same-machine detached-worktree base/candidate suite runner.
- Create:
  `scripts/tests/test_project_storage_skip_comparison.py`
  — parser, inherited-skip, strict-new-test, and regression tests.
- Modify: `.github/workflows/ci.yml`
  — add the deterministic storage gate to the existing fast job; do not make a
  shared hosted runner the Release authority.
- Create: `docs/verification/project-storage-lifecycle.md`
  — exact fixture, environment, command, timing, memory, signpost, safety, and
  provenance evidence.

- [ ] **Step 1: Write failing instrumentation and hard-link-bound tests**

Use this public semantic surface in
`ProjectStorageInstrumentation.swift` so Workflow code, App code, and tests use
the same interval and counter names:

```swift
public struct ProjectStorageInstrumentation: Sendable {
    public enum Phase: String, Sendable, Equatable {
        case scan = "ProjectStorage.Scan"
        case descriptorPreparation =
            "ProjectStorage.DescriptorPreparation"
        case mainActorCommit = "ProjectStorage.MainActorCommit"
    }

    public enum Outcome: String, Sendable, Equatable {
        case success
        case cancelled
        case failure
    }

    public enum Counter: String, Sendable, Equatable {
        case visitedObjects
        case candidateEntries
        case trackedHardLinkIdentities
        case retainedScannerRecords
        case reusedHashes
        case computedHashes
        case mainActorCommits
    }

    public struct Interval: Sendable, Equatable {
        public let id: UUID
        public let phase: Phase
    }

    public enum Event: Sendable, Equatable {
        case began(Interval)
        case counted(Counter, UInt64, intervalID: UUID)
        case ended(Interval, Outcome)
    }

    public init(record: @escaping @Sendable (Event) -> Void)
    public func begin(_ phase: Phase) -> Interval
    public func count(
        _ counter: Counter,
        _ value: UInt64,
        in interval: Interval
    )
    public func end(_ interval: Interval, outcome: Outcome)
    public static func production(
        subsystem: String
    ) -> ProjectStorageInstrumentation
}
```

The production factory uses `OSSignposter`, category `ProjectStorage`, and the
three exact static interval names above. Scanner and receipt preparation use
`LogSubsystem.workflow`; App main-actor commits use `LogSubsystem.app`.
Signposts and counters contain counts and outcomes only—never project paths,
sample names, or scientific filenames. Tests use the recording initializer
instead of querying `OSLogStore`, which is nondeterministic under the macOS CI
sandbox.

Add these failing tests first:

```text
ProjectStorageScannerLargeTreeTests
  testLargeTreeScanEmitsBalancedScanInstrumentation
  testHardLinkTrackingBudgetFailsClosed

ProjectStorageCleanupPreparationLargeTreeTests
  testLargePreparationEmitsBalancedDescriptorPreparationInstrumentation

ProjectStoragePerformanceTests
  testLargePreviewEmitsBalancedMainActorCommitInstrumentation
```

These four RED tests use minimal local temporary trees and the existing App
project factory; they do not depend on the shared large-tree fixture introduced
in Step 3.

Run:

```bash
swift test --filter \
  'ProjectStorageScannerLargeTreeTests|ProjectStorageCleanupPreparationLargeTreeTests|ProjectStoragePerformanceTests'
```

Expected: FAIL because the instrumentation type and injection points do not
exist. The four new test methods compile only after their test files contain
the minimal local fixture helpers described above.

- [ ] **Step 2: Implement instrumentation and the declared metadata bound**

Add instrumentation injection with production defaults to
`ProjectStorageScanner`, `ProjectStorageCleanupReceiptWriter.Operations`, and
`ProjectStorageCoordinator.Operations`. Each interval ends exactly once with
`.success`, `.cancelled`, or `.failure`. Emit counters at stable boundaries,
not one production signpost event per file.

Use this production hard-link bound:

```swift
static let maximumTrackedHardLinkIdentities = 65_536
```

The scanner's internal test initializer accepts
`maximumTrackedHardLinkIdentities`, defaulting to that production constant.
The boundary test passes `16` and creates 17 distinct multiply-linked
identities; it must not create 65,537 hard-link groups in CI.

When a previously unseen multiply-linked `(device, inode)` would exceed the
active limit:

1. stop measuring that candidate;
2. classify it `.notRemovable(.resourceLimitExceeded, ...)`;
3. report allocated bytes as zero for that candidate so reclaimable space is
   never overstated;
4. show the exact reason
   `"Hard-link identity tracking exceeded the 65,536-entry safety limit."`
   when the production limit is active, substituting the injected limit in
   tests;
5. preserve already classified entries and keep the dictionary at or below the
   active cap.

Do not evict an earlier identity or continue with approximate deduplication.
The 65,536 cap and visible fail-closed classification are the declared defense
for this release; a disk-backed identity table is outside Task 9.

In `ProjectStorageCoordinator.ProgressRelay`, replace direct uptime reads with
an injected `@Sendable () -> TimeInterval` defaulting to
`ProcessInfo.processInfo.systemUptime`. Instrument only the small main-actor
reconciliation calls (`receiveScanProgress`, `receiveScanResult`,
cancellation, and failure), not the detached scan itself.

Run the Step 1 command again.

Expected: PASS. Success, cancellation, and failure paths have balanced
intervals; the 17th identity against a test cap of 16 fails closed without
growing retained state. The only permitted skip is
`testHardLinkTrackingBudgetFailsClosed` for exact `EOPNOTSUPP`, `ENOTSUP`, or
`EXDEV`; no other skip is accepted.

- [ ] **Step 3: Add the shared deterministic fixture profiles**

Add `LungfishTestSupport` to both test-target dependency arrays in
`Package.swift`, then import it from the Workflow and App test files.
`ProjectStorageLargeTreeFixture` exposes exactly:

```swift
public enum Profile: Sendable {
    case ciSemantic
    case releaseRepresentative
}
```

All numeric file and identity counts below are **profile totals**, not
per-candidate counts. `ciSemantic` creates:

- three exact owned candidates using durable ownership markers;
- 1,536 ordinary non-hard-linked files, exactly 512 per candidate, at a maximum
  depth of six levels below each candidate root;
- 128 within-candidate hard-link identities, distributed 43, 43, and 42 by
  candidate; each identity has exactly two candidate directory entries;
- 128 cross-candidate hard-link identities; identity `i` has one entry in
  candidate `i mod 3` and one in candidate `(i + 1) mod 3`;
- 128 candidate-to-survivor hard-link identities, distributed 43, 43, and 42
  candidate entries, with exactly one second entry under a surviving
  non-candidate root;
- 32 sparse 64 MiB files, distributed 11, 11, and 10 by candidate and created
  with `ftruncate`;
- 2,048 decoy objects total under `.lungfish-operation-history`.

`releaseRepresentative` creates:

- eight exact owned candidates;
- 32,768 ordinary non-hard-linked files, exactly 4,096 per candidate, at the
  same maximum depth of six;
- 682 within-candidate hard-link identities, distributed
  86, 86, 85, 85, 85, 85, 85, and 85; each has two candidate entries;
- 683 cross-candidate hard-link identities; identity `i` has one entry in
  candidate `i mod 8` and one in candidate `(i + 1) mod 8`;
- 683 candidate-to-survivor hard-link identities, distributed
  86, 86, 86, 85, 85, 85, 85, and 85 candidate entries, with one second entry
  under a surviving non-candidate root;
- 128 sparse 1 GiB files, exactly 16 per candidate, created with `ftruncate`;
- 16,384 operation-history decoys total.

A decoy-object total counts every descendant directory entry under
`.lungfish-operation-history`, including decoy directories and files but
excluding the `.lungfish-operation-history` root itself. Generate the same
deterministic directory/file ratio and relative-name sequence from the fixed
seed for both profiles.

The ordinary-file totals exclude sparse files, ownership markers, directories,
and every hard-link directory entry. Hard-link totals count inode identities:
each identity contributes exactly two directory entries. The CI profile
therefore has 768 hard-link directory entries total (640 in candidates and 128
in the survivor root); the Release profile has 4,096 total (3,413 in
candidates and 683 in the survivor root).

Define `visitedObjects` as logical directory-enumerator yields at the scanner's
two exact increment sites:

1. once immediately after each `discoverCandidates` project-enumerator yield,
   before history/candidate pruning or any conditional `lstat`; and
2. once immediately after each `measureTree` candidate-subtree-enumerator
   yield, before that entry's `lstat`.

The project root and a candidate root's separate root measurement are not
increments. The `.lungfish-operation-history` root is included at the first
site and its descendants are excluded because that yielded root is pruned
before `lstat`. Candidate roots are counted at the first site; their descendants
are counted at the second after discovery prunes them. Every yielded hard-link
directory entry is included. Document this logical-yield definition beside the
production counter and never describe it as an `lstat` count.

Use fixed relative names and seed `0x4C554E4746495348`; only the outer temporary
directory may contain a UUID. The builder exposes a base-tree operation and a
separate hard-link-overlay operation so hard-link-independent tests do not skip
on filesystems without hard-link support.

Implement `ProjectStorageFixtureOracle` independently of the builder and
scanner. It performs its own two-pass logical walk: a project-discovery pass
that counts every yielded URL before applying the same documented pruning
boundaries, followed by one candidate-subtree pass per discovered candidate
that counts each descendant yield. It uses `lstat` only to derive file type,
identity, link multiplicity, and logical/allocated metadata—not to decide the
visited count. It derives visited/candidate counts, relative paths,
`(device, inode)` multiplicities, external sentinel checksums, and sizes. The
fixture builder must not return expected scan totals. Tests compare scanner
output both to the declared profile constants and to this independent
enumeration; they never compare it only to self-reported fixture metadata.
Record `statfs` filesystem type and block size. Never assert a fixed sparse-file
`st_blocks` value.

The only ordinary-CI hard-link skip errnos are `EOPNOTSUPP`, `ENOTSUP`, and
`EXDEV`, reported as
`hard-link-unavailable: errno=<integer> (<symbol>)`. Only these
hard-link-dependent tests may skip for one of those errnos:

```text
testCISemanticFixtureHasExactTopology
testLargeTreeHardLinksAreDeduplicatedAcrossCandidateBoundaries
testLargeTreeExternalHardLinkSurvivorIsNotCreditedAsReclaimable
testHardLinkTrackingBudgetFailsClosed
testLargePreparationReusesAttestedDescriptorsAndHashesEachUnattestedInodeOnce
```

All other deterministic tests build the base tree without the hard-link
overlay and may not skip for filesystem capability. Controlled Release
verification is incomplete, not passed, when the full hard-link overlay cannot
be created.

Run:

```bash
swift test --filter ProjectStorageScannerLargeTreeTests
```

Expected: `testReleaseRepresentativeConfigurationIsExact` passes without
constructing the Release tree. `testCISemanticFixtureHasExactTopology` may skip
only for `EOPNOTSUPP`, `ENOTSUP`, or `EXDEV` with exact errno; among the Step 1
tests, only `testHardLinkTrackingBudgetFailsClosed` has the same permitted
skip. No other skip is accepted, and no test checks elapsed time.

- [ ] **Step 4: Add deterministic scaled scanner safety tests**

Add these exact tests to
`Tests/LungfishWorkflowTests/ProjectStorageScannerLargeTreeTests.swift`:

```text
testCISemanticFixtureHasExactTopology
testReleaseRepresentativeConfigurationIsExact
testLargeTreeScanStreamsWithoutReadingOrHashingPayloads
testLargeTreeHardLinksAreDeduplicatedAcrossCandidateBoundaries
testLargeTreeExternalHardLinkSurvivorIsNotCreditedAsReclaimable
testLargeTreeCancellationReturnsNoPartialResultAndMutatesNothing
testLargeTreeCandidateReplacementDuringScanFailsClosed
testLargeOperationHistoryTreeIsSkippedAndNeverOffered
testLargeTreeScanEmitsBalancedScanInstrumentation
testHardLinkTrackingBudgetFailsClosed
testRetainedScannerStateMatchesDeclaredComplexityBound
testReleaseRepresentativeScanMemoryDeltaIsAtMost96MiB
```

Every test except the Release memory test is deterministic. The memory test
throws `XCTSkip` only when `LUNGFISH_RUN_STORAGE_PERF` is absent, accepts the
exact `warmup` and `memory` modes defined in Step 10, and fails on any other
value:

- preview emits zero computed-hash events and succeeds with an unreadable sparse
  payload;
- allocated totals use runtime `lstat` expectations;
- external surviving links are not credited as reclaimable;
- cancellation at several injected visit counts returns no result and changes
  no sentinel checksum, path, size, or identity;
- operation-history objects are neither candidates nor measured descendants;
- project or candidate replacement fails closed;
- peak tracked hard-link identities never exceeds the active cap;
- explicit retained records never exceed result entries plus discovered
  candidates plus tracked hard-link identities and constant traversal state.

Run:

```bash
swift test --filter \
  'ProjectStorageScannerLargeTreeTests|ProjectStorageScannerTests'
```

Expected: PASS. The exact permitted skips are:

- `testReleaseRepresentativeScanMemoryDeltaIsAtMost96MiB` when
  `LUNGFISH_RUN_STORAGE_PERF` is absent;
- `testCISemanticFixtureHasExactTopology`,
  `testLargeTreeHardLinksAreDeduplicatedAcrossCandidateBoundaries`,
  `testLargeTreeExternalHardLinkSurvivorIsNotCreditedAsReclaimable`, and
  `testHardLinkTrackingBudgetFailsClosed` only for exact `EOPNOTSUPP`,
  `ENOTSUP`, or `EXDEV`.

No other skip is accepted from
`ProjectStorageScannerLargeTreeTests`. Hard-link-independent new tests use the
base tree and must still run. Any skip from the pre-existing
`ProjectStorageScannerTests` is recorded but is judged only by the Step 9
same-machine base comparison, not by the new-test matrix.

- [ ] **Step 5: Add deterministic descriptor-preparation and provenance tests**

Add these exact tests to
`Tests/LungfishWorkflowTests/ProjectStorageCleanupPreparationLargeTreeTests.swift`:

```text
testLargePreparationReusesAttestedDescriptorsAndHashesEachUnattestedInodeOnce
testLargePreparationCancellationBeforePublicationMutatesNoSelectedRoot
testLargePreparationEmitsBalancedDescriptorPreparationInstrumentation
testLargePreparationWritesCompleteCanonicalProvenance
```

Use modest non-sparse payloads for files that must actually be hashed and exact
attestations for large sparse payloads. Verify that one multiply-linked inode
is hashed once, attested checksums are reused, cancellation before publication
leaves selected roots and prior operation-history evidence unchanged, and
operation-history output points at final stored payloads.

The canonical provenance assertion covers every repository requirement:

- executed workflow/tool name and version;
- actual argv or durable replay argv;
- visible selections and resolved defaults;
- conda/container/runtime identity when applicable;
- final project, input, output, journal, and provenance paths rather than only
  staging paths;
- sorted descriptors with SHA-256 and file size;
- exit status, wall time, and useful failure/stderr detail.

Run:

```bash
swift test --filter \
  'ProjectStorageCleanupPreparationLargeTreeTests|ProjectStorageCleanupProvenanceTests|ProjectStoragePublishedCleanupOutcomeReaderTests'
```

Expected: PASS. Provenance remains complete at scale, cancellation recovery
retains descriptor-bound no-follow security, and preview writes no provenance
artifact because it creates or transforms no scientific output. The only
permitted skip is
`testLargePreparationReusesAttestedDescriptorsAndHashesEachUnattestedInodeOnce`
for exact `EOPNOTSUPP`, `ENOTSUP`, or `EXDEV`; no other skip from
`ProjectStorageCleanupPreparationLargeTreeTests` is accepted. Skips from the
pre-existing cleanup-provenance and outcome-reader classes are judged only by
the Step 9 same-machine base comparison.

- [ ] **Step 6: Add deterministic App boundary tests**

Add these exact tests to
`Tests/LungfishAppTests/ProjectStoragePerformanceTests.swift`:

```text
testProjectOpenDoesNotInvokeAutomaticStorageCleanup
testProjectOpenLeavesStorageFixtureUnchanged
testDefaultScanAuthorityAndCleanupPreparationWorkersRunOffMainThread
testProgressRelayBoundsMainActorDeliveryCountWithInjectedClock
testLargePreviewEmitsBalancedMainActorCommitInstrumentation
testLargePreviewMaximumMainThreadStallIsUnder100Milliseconds
```

The first five are normal CI gates. Split project-open evidence into three
claims and do not let one seam overclaim another:

1. Execute `AppDelegate.openProject` against the hard-link-free `ciSemantic`
   base tree, install the existing `projectStorageAutomaticCleanupRunner`
   recorder, and assert zero automatic-cleanup calls before return and after
   one main-run-loop turn. This recorder proves only that automatic cleanup was
   not invoked during the runtime open check; it does not claim that no delayed
   timer was installed.
2. Independently snapshot every fixture entry before open and after the
   main-run-loop turn. The snapshot contains sorted relative path, file type,
   `(device, inode)`, link count, logical and allocated size, nanosecond mtime
   and ctime, and SHA-256 for regular non-sparse contents. For sparse files,
   also record the hole/data extent map and hash every allocated extent without
   reading holes. Assert exact equality to prove project open did not mutate
   the storage fixture.
3. Retain
   `ProjectTempCleanupTests.testProjectOpenDoesNotCallCleanupOrScan` as the
   source-boundary test proving the `openProject` method has no direct
   `ProjectStorageScanner` or cleanup call. The runtime recorder is not
   described as proof that no arbitrary traversal occurred.

Use this exact source-compatibility choice: retain an explicit zero-argument
`ProjectStorageCoordinator.Operations.init()` whose body is
`self = .production()`. Keep the existing labeled test-injection initializer as
a separate overload with `scan` required and its remaining parameters
defaulted, so every current `Operations(scan: ...)` call still compiles and
`Operations()` is unambiguous. Do not modify
`Tests/LungfishAppTests/ProjectStorageSheetViewModelTests.swift`; its existing
zero-argument production-scan test and labeled injection tests are the
compatibility regression and are included in the Step 6 command.

Add an explicit
`Operations.production(workerObserver:cancellationPropagationObserver:beforeExecutorGuard:)`
factory used by the real coordinator. All three seams default to no-ops. The
worker observer receives these exact phases:

```text
ProjectStorageWorkerPhase.authorityCanonicalizationAndIdentity
ProjectStorageWorkerPhase.scanTraversal
ProjectStorageWorkerPhase.cleanupPreparation
```

Invoke the first observer inside the actual detached
`currentAuthorityProjectURL` closure, the second immediately before the default
`ProjectStorageScanner().scan`, and thread the third through the default
cleanup closure into `performCleanup`, invoking it immediately before the call
to `prepareConfirmedCleanup`. After `runDetachedCancellable` calls
`worker.cancel()` in its real cancellation handler, invoke
`cancellationPropagationObserver`. Invoke the throwing `beforeExecutorGuard`
after receipt preparation returns and immediately before constructing/calling
`ProjectStorageCleanupExecutor`; its production default does nothing. None of
these seams records paths.

`testDefaultScanAuthorityAndCleanupPreparationWorkersRunOffMainThread` creates
that production factory without overriding scan, cleanup, canonicalization,
identity, receipt preparation, or executor construction. It drives one real
preview and begins one confirmed cleanup against a fresh small owned fixture
whose `.lungfish-operation-history/storage-cleanups` collection is absent. Its
`.cleanupPreparation` observer records `pthread_main_np()`, signals a reached
barrier, and blocks immediately before `prepareConfirmedCleanup`.

After the reached barrier, the test invokes the real coordinator/sheet cancel
path, waits for `cancellationPropagationObserver` to confirm that cancellation
reached the detached worker, and only then releases the preparation barrier.
The writer's existing first statement,
`try operations.cancellationCheck()`, must observe cancellation and throw
before it opens the project or creates staging. The test then waits for the
coordinator operation to settle.

Set `beforeExecutorGuard` to record an unexpected hit and throw before any
executor or Trash adapter can run. Assert it was never hit. Compare independent
before/after snapshots of the selected source, its identity/checksum, the
operation-history tree, every possible journal path below the absent
`storage-cleanups` collection, and any quarantine path; require exact equality
or continued absence. Together with the zero executor-boundary hits, assert no
source, journal, operation-history, quarantine, or Trash mutation. Require at
least one observation for every exact worker phase and
`pthread_main_np() == 0` for every one. An arbitrary injected scan/cleanup
closure, a cleanup allowed to reach Trash, or releasing the barrier before
cancellation propagation does not satisfy this test.

Drive the progress relay with its injected clock: for a virtual one-second
burst, require no more than the first delivery plus ten 100 ms deliveries and
the terminal commit. Do not sleep in deterministic tests.

The sixth test throws `XCTSkip` only when `LUNGFISH_RUN_STORAGE_PERF` is absent,
accepts the exact `timing` mode defined in Step 10, and fails on any other
value. Skipping it in ordinary CI does not verify the 100 ms requirement.

Run:

```bash
swift test --filter \
  'ProjectStoragePerformanceTests|ProjectStorageSheetViewModelTests|ProjectTempCleanupTests'
```

Expected: PASS. The only permitted skip from the new
`ProjectStoragePerformanceTests` class is
`testLargePreviewMaximumMainThreadStallIsUnder100Milliseconds` when
`LUNGFISH_RUN_STORAGE_PERF` is absent. The five deterministic App tests use no
hard-link overlay and permit no filesystem-capability skip. Skips from the
pre-existing `ProjectStorageSheetViewModelTests` or `ProjectTempCleanupTests`
are judged only by the Step 9 same-machine base comparison.

- [ ] **Step 7: Add the deterministic storage gate to CI**

Before the first Task 9 implementation edit, record the clean integrated base
commit that contains Task 8, Task 10, and this plan. Write that exact
40-character SHA into
`scripts/verification/project-storage-task9-skip-policy.json` as
`baselineSHA`. The policy also contains the three exact new class names and
the exact new-test skip matrix from Steps 3–6. The base must be the direct
parent of the later Task 9 implementation commit.

Implement `compare_project_storage_skips.py` to parse retained combined
stdout/stderr from serial XCTest console runs. Support the current toolchain's
`Test Case '<identifier>' ... skipped` and
`Test skipped - <reason>` forms plus the known Darwin/corelibs identifier and
diagnostic-prefix variants. A reason may span lines; preserve its complete
text, spaces, paths, tool names, and errno, normalizing only CRLF to LF.

Pair each skipped test event to exactly one reason using the explicit test
identifier when present and otherwise the active serial test case bounded by
its started/skipped records. Canonicalize the result as the exact multiset tuple
`(XCTest test identifier, complete reason, occurrence count)`. Fail closed if:

- a `Test Case ... skipped` event has zero or multiple possible reasons;
- a `Test skipped -` reason has zero or multiple possible skipped events;
- the paired-record count differs from the selected suite's terminal
  `Executed ... with <N> test(s) skipped` count;
- the raw log or final selected-suite (`Selected tests` or `All tests`) terminal
  summary is absent or appears truncated; or
- the recorded Swift test or `tee` exit status is nonzero.

After structural validation, the comparator:

1. asserts the base console log contains no test from a new Task 9 class;
2. partitions implementation skips by the three exact new class names;
3. requires the complete pre-existing implementation skip multiset to equal
   the base multiset, failing on any added, removed, reason-changed, or
   count-changed tuple;
4. validates only the new-class partition against the strict Task 9 matrix;
5. writes a JSON report containing raw-log checksums/sizes/statuses, terminal
   summary counts, both multisets, new-test decisions, and the
   machine/environment fingerprint.

Its `--policy <path> --print-baseline-sha` mode prints only the validated
40-character `baselineSHA` for workflow use.

Implement `run_project_storage_skip_comparison.sh` with exact suites
`ci-focused`, `focused`, `scientific`, and `full`. It validates the literal
base and implementation SHAs, their parent relationship, and the clean caller
tree. For each suite it creates one explicit temporary worktree path, checks out
the base there, runs and copies out the base raw log/status, removes the
worktree, then checks out the implementation at the **same path**, runs and
copies out the implementation raw log/status, and removes it on exit. This
keeps cwd-derived skip reasons stable while still running base first on the
same machine and inherited environment. The two serial `swift test` argv arrays
are byte-for-byte identical and contain no report-output option.

Use a Bash script that explicitly executes `set -o pipefail` alongside
`errexit` and `nounset`. Around each test pipeline, disable `errexit` only long
enough to run:

```bash
set -o pipefail
set +e
"${task9_swift_test_argv[@]}" 2>&1 | tee "$task9_raw_log"
task9_pipeline_status=("${PIPESTATUS[@]}")
task9_swift_status="${task9_pipeline_status[0]}"
task9_tee_status="${task9_pipeline_status[1]}"
set -e
```

Write both statuses to a sidecar and copy the raw `.log` plus sidecar out
before removing or swapping the worktree. The comparator receives both
statuses; any nonzero value fails even if the console resembles a passing run.
If the base command fails, retain its log/status and emit a fail-closed JSON
report rather than attempting to classify the run as a skip match.

Record Swift, Xcode, macOS, architecture, filesystem, and the presence or
absence of relevant optional tools/environment flags in the report without
recording secrets.
Permit no package/tool installation, environment-variable change, or unrelated
test command between the paired base and implementation invocations. Mark the
runner executable.
Copy the two raw logs to
`.build/project-storage-skip-comparison/<suite>-base.log` and
`<suite>-implementation.log` in the caller tree for retention, alongside their
status sidecars.

The `ci-focused` command embedded in the runner is exactly:

```bash
swift test --no-parallel --filter \
  'ProjectStorageScannerLargeTreeTests|ProjectStorageScannerTests|ProjectStorageCleanupPreparationLargeTreeTests|ProjectStorageCleanupProvenanceTests|ProjectStoragePublishedCleanupOutcomeReaderTests|ProjectStorageAutomaticCleanupServiceTests|ProjectStoragePerformanceTests|ProjectTempCleanupTests'
```

Unit-test the helper with representative captured serial logs from the current
toolchain plus supported identifier/diagnostic variants, multiline reasons,
spaces and checkout paths, duplicate skip occurrences, unchanged inherited
Trash/openpyxl/case-sensitive-volume/optional fixture/tool/network/performance
skips, and every strict new-test allowance. Add fail-closed cases for missing or
ambiguous event/reason pairing, unmatched reasons, summary-count disagreement,
missing terminal summary/truncation, nonzero Swift/`tee` status, added/removed/
reason-changed/count-changed inherited skips, and forbidden new-test skips.
Run:

```bash
python3 -m unittest scripts.tests.test_project_storage_skip_comparison
```

Expected: PASS with zero helper-test skips.

In `.github/workflows/ci.yml`, ensure checkout uses full history. The
deterministic project-storage step discovers the implementation commit as the
commit that added the policy file, reads `baselineSHA` from that file, and
invokes the runner with `--suite ci-focused`. Upload both retained raw console
logs, both status sidecars, and the JSON comparison report. Do not set
`LUNGFISH_RUN_STORAGE_PERF`. Configure the artifact-upload step with
`if: always()` so a fail-closed base or implementation command still retains
every artifact that was produced.

Use this exact run block:

```yaml
      - name: Compare deterministic project-storage skips
        run: |
          task9_implementation_sha="$(git log --diff-filter=A --format=%H -1 -- scripts/verification/project-storage-task9-skip-policy.json)"
          task9_base_sha="$(python3 scripts/verification/compare_project_storage_skips.py --policy scripts/verification/project-storage-task9-skip-policy.json --print-baseline-sha)"
          scripts/verification/run_project_storage_skip_comparison.sh \
            --suite ci-focused \
            --base-sha "$task9_base_sha" \
            --implementation-sha "$task9_implementation_sha" \
            --report .build/project-storage-skip-comparison/ci-focused-report.json
```

Expected CI result: the strict new-test partition permits
`testReleaseRepresentativeScanMemoryDeltaIsAtMost96MiB` and
`testLargePreviewMaximumMainThreadStallIsUnder100Milliseconds` because the
Release variable is absent. Its exact filesystem-capability skips are
`testCISemanticFixtureHasExactTopology`,
`testLargeTreeHardLinksAreDeduplicatedAcrossCandidateBoundaries`,
`testLargeTreeExternalHardLinkSurvivorIsNotCreditedAsReclaimable`,
`testHardLinkTrackingBudgetFailsClosed`, and
`testLargePreparationReusesAttestedDescriptorsAndHashesEachUnattestedInodeOnce`,
each only for `EOPNOTSUPP`, `ENOTSUP`, or `EXDEV` with exact errno. No other
new Task 9 test may skip. Any inherited pre-existing skip—including legitimate
Trash, openpyxl, case-sensitive-volume, optional fixture/tool, network, or
performance skips—passes only when its exact name, reason, and count match the
base console log. Thus CI remains strict for new tests without falsely
rejecting an unchanged inherited skip.

- [ ] **Step 8: Commit the Task 9 implementation before collecting evidence**

After Steps 1–7 are green under their exact skip policy, commit only the
implementation, fixtures, tests, and CI wiring:

```bash
git add \
  Package.swift \
  .github/workflows/ci.yml \
  Sources/LungfishWorkflow/Storage/ProjectStorageInstrumentation.swift \
  Sources/LungfishWorkflow/Storage/ProjectStorageScanner.swift \
  Sources/LungfishWorkflow/Storage/ProjectStorageModels.swift \
  Sources/LungfishWorkflow/Storage/ProjectStorageCleanupReceiptWriter.swift \
  Sources/LungfishApp/Services/ProjectStorageCoordinator.swift \
  Tests/Support/LungfishTestSupport/ProjectStorageLargeTreeFixture.swift \
  Tests/LungfishWorkflowTests/Fixtures/ProcessMemorySampler.swift \
  Tests/LungfishWorkflowTests/ProjectStorageScannerLargeTreeTests.swift \
  Tests/LungfishWorkflowTests/ProjectStorageCleanupPreparationLargeTreeTests.swift \
  Tests/LungfishAppTests/ProjectStoragePerformanceTests.swift \
  scripts/verification/project-storage-task9-skip-policy.json \
  scripts/verification/compare_project_storage_skips.py \
  scripts/verification/run_project_storage_skip_comparison.sh \
  scripts/tests/test_project_storage_skip_comparison.py
git commit -m "test: verify project storage lifecycle safety"
test -z "$(git status --porcelain)"
git rev-parse --verify 'HEAD^'
git rev-parse --verify 'HEAD^{commit}'
```

Expected: one clean implementation commit. Do not create
`docs/verification/project-storage-lifecycle.md` yet. Copy the exact
40-character base SHA printed by the penultimate command and implementation SHA
printed by the final command. Confirm the base literal equals the policy
`baselineSHA` and is the integrated Task 8 + Task 10 + plan commit. Every
same-machine skip-comparison block below assigns both literals and validates
their format/existence/direct-parent relationship; every other independent
validation block reassigns the implementation literal. All blocks check HEAD
and cleanliness without relying on prior shell state. The later evidence
commit names both literal SHAs and cannot claim to have tested itself.

- [ ] **Step 9: Verify the exact implementation SHA with deterministic suites**

For **each** suite, the runner first executes the exact command at the base SHA
and then executes the same argv at the implementation SHA on the same machine
and inherited environment. The complete strict skip set for only the new Task
9 classes is:

- `testReleaseRepresentativeScanMemoryDeltaIsAtMost96MiB` and
  `testLargePreviewMaximumMainThreadStallIsUnder100Milliseconds`, only because
  `LUNGFISH_RUN_STORAGE_PERF` is absent;
- `testCISemanticFixtureHasExactTopology`,
  `testLargeTreeHardLinksAreDeduplicatedAcrossCandidateBoundaries`,
  `testLargeTreeExternalHardLinkSurvivorIsNotCreditedAsReclaimable`,
  `testHardLinkTrackingBudgetFailsClosed`, and
  `testLargePreparationReusesAttestedDescriptorsAndHashesEachUnattestedInodeOnce`,
  only with `hard-link-unavailable: errno=<integer> (<symbol>)` for
  `EOPNOTSUPP`, `ENOTSUP`, or `EXDEV`.

No other new Task 9 test may skip. Separately, the comparator requires every
pre-existing skip name, full reason, and count to be exactly equal between base
and implementation. An inherited skip is neither rejected merely for existing
nor silently accepted if it changes.

The runner embeds these exact argv arrays and executes each unchanged in the
base worktree first and implementation worktree second:

```bash
# focused
swift test --no-parallel --filter \
  'ProjectStorageScannerLargeTreeTests|ProjectStorageCleanupPreparationLargeTreeTests|ProjectStorageScannerTests|ProjectStorageCleanupProvenanceTests|ProjectStoragePublishedCleanupOutcomeReaderTests|ProjectStorageCleanupExecutorTests|ProjectStorageAutomaticCleanupServiceTests|ProjectTempCleanupTests|ProjectStoragePerformanceTests'

# scientific
swift test --no-parallel --filter \
  'ProjectTempDirectoryTests|GenotypeWorkbookRevisionServiceTests|FullLengthONTMHCGenotypingPipelineTests|ONTBarcodeDemuxGenotypingPipelineTests|ProjectStorage'

# full
swift test --no-parallel
```

Run the deterministic storage/provenance gate:

```bash
task9_base_sha='<paste exact 40-character base SHA printed by Step 8>'
task9_implementation_sha='<paste exact 40-character SHA printed by Step 8>'
for task9_sha in "$task9_base_sha" "$task9_implementation_sha"; do
  test "${#task9_sha}" -eq 40
  case "$task9_sha" in
    *[!0-9a-f]*) exit 1 ;;
  esac
  git cat-file -e "${task9_sha}^{commit}"
done
test "$(git rev-parse "${task9_implementation_sha}^")" = "$task9_base_sha"
test "$(git rev-parse HEAD)" = "$task9_implementation_sha"
test -z "$(git status --porcelain)"
scripts/verification/run_project_storage_skip_comparison.sh \
  --suite focused \
  --base-sha "$task9_base_sha" \
  --implementation-sha "$task9_implementation_sha" \
  --report .build/project-storage-skip-comparison/focused-report.json
```

Expected: both exact `focused` commands PASS; the new-test partition matches
the strict matrix; and the complete inherited skip multiset is unchanged.
Existing Trash or other platform skips are allowed only through that exact
equality.

Run the scientific/storage regression:

```bash
task9_base_sha='<paste exact 40-character base SHA printed by Step 8>'
task9_implementation_sha='<paste exact 40-character SHA printed by Step 8>'
for task9_sha in "$task9_base_sha" "$task9_implementation_sha"; do
  test "${#task9_sha}" -eq 40
  case "$task9_sha" in
    *[!0-9a-f]*) exit 1 ;;
  esac
  git cat-file -e "${task9_sha}^{commit}"
done
test "$(git rev-parse "${task9_implementation_sha}^")" = "$task9_base_sha"
test "$(git rev-parse HEAD)" = "$task9_implementation_sha"
test -z "$(git status --porcelain)"
scripts/verification/run_project_storage_skip_comparison.sh \
  --suite scientific \
  --base-sha "$task9_base_sha" \
  --implementation-sha "$task9_implementation_sha" \
  --report .build/project-storage-skip-comparison/scientific-report.json
```

Expected: both exact `scientific` commands PASS, the strict new-test matrix
passes, and every pre-existing skip tuple is unchanged. Existing openpyxl,
optional fixture/tool, or network skips are accepted only when the baseline has
the identical tuple and count.

Run the full Swift suite:

```bash
task9_base_sha='<paste exact 40-character base SHA printed by Step 8>'
task9_implementation_sha='<paste exact 40-character SHA printed by Step 8>'
for task9_sha in "$task9_base_sha" "$task9_implementation_sha"; do
  test "${#task9_sha}" -eq 40
  case "$task9_sha" in
    *[!0-9a-f]*) exit 1 ;;
  esac
  git cat-file -e "${task9_sha}^{commit}"
done
test "$(git rev-parse "${task9_implementation_sha}^")" = "$task9_base_sha"
test "$(git rev-parse HEAD)" = "$task9_implementation_sha"
test -z "$(git status --porcelain)"
scripts/verification/run_project_storage_skip_comparison.sh \
  --suite full \
  --base-sha "$task9_base_sha" \
  --implementation-sha "$task9_implementation_sha" \
  --report .build/project-storage-skip-comparison/full-report.json
```

Expected: both exact `full` commands PASS, the strict new-test matrix passes,
and all pre-existing skip tuples and counts are identical. This comparison
explicitly carries forward unchanged case-sensitive-volume, Trash, openpyxl,
optional fixture/tool/network, and pre-existing performance skips without
broadening the new-test policy.

Run packaging validation:

```bash
task9_base_sha='<paste exact 40-character base SHA printed by Step 8>'
task9_implementation_sha='<paste exact 40-character SHA printed by Step 8>'
for task9_sha in "$task9_base_sha" "$task9_implementation_sha"; do
  test "${#task9_sha}" -eq 40
  case "$task9_sha" in
    *[!0-9a-f]*) exit 1 ;;
  esac
  git cat-file -e "${task9_sha}^{commit}"
done
test "$(git rev-parse "${task9_implementation_sha}^")" = "$task9_base_sha"
test "$(git rev-parse HEAD)" = "$task9_implementation_sha"
test -z "$(git status --porcelain)"
python3 -m unittest \
  scripts.tests.test_release_smoke \
  scripts.tests.test_sparkle_release_packaging \
  scripts.tests.test_project_storage_skip_comparison
```

Expected: PASS with zero skips.

- [ ] **Step 10: Run controlled-machine Release timing, memory, and signposts**

The release authority is a named, fixed Apple-silicon Mac recorded in
`docs/verification/project-storage-lifecycle.md`. A shared `macos-26` hosted
runner may upload informational metrics but cannot approve either absolute
budget. Reassign and validate the literal clean implementation SHA in every
independent command block.

The memory test recognizes `LUNGFISH_RUN_STORAGE_PERF=warmup` and
`LUNGFISH_RUN_STORAGE_PERF=memory`. Its warm-up mode constructs the full
`releaseRepresentative` fixture and runs one scan, but does not report a
measured trial. Run that warm-up in its own `swift test` process:

```bash
task9_implementation_sha='<paste exact 40-character SHA printed by Step 8>'
test "${#task9_implementation_sha}" -eq 40
case "$task9_implementation_sha" in
  *[!0-9a-f]*) exit 1 ;;
esac
git cat-file -e "${task9_implementation_sha}^{commit}"
test "$(git rev-parse HEAD)" = "$task9_implementation_sha"
test -z "$(git status --porcelain)"
LUNGFISH_RUN_STORAGE_PERF=warmup \
SWIFT_DETERMINISTIC_HASHING=1 \
swift test -c release --filter \
  'ProjectStorageScannerLargeTreeTests/testReleaseRepresentativeScanMemoryDeltaIsAtMost96MiB'
```

Then run exactly three measured trials, each in a fresh `swift test` process:

```bash
for task9_memory_trial in 1 2 3; do
  task9_implementation_sha='<paste exact 40-character SHA printed by Step 8>'
  test "${#task9_implementation_sha}" -eq 40
  case "$task9_implementation_sha" in
    *[!0-9a-f]*) exit 1 ;;
  esac
  git cat-file -e "${task9_implementation_sha}^{commit}"
  test "$(git rev-parse HEAD)" = "$task9_implementation_sha"
  test -z "$(git status --porcelain)"
  LUNGFISH_RUN_STORAGE_PERF=memory \
  LUNGFISH_STORAGE_PERF_TRIAL="$task9_memory_trial" \
  SWIFT_DETERMINISTIC_HASHING=1 \
  swift test -c release --filter \
    'ProjectStorageScannerLargeTreeTests/testReleaseRepresentativeScanMemoryDeltaIsAtMost96MiB'
done
```

Memory mode requires `LUNGFISH_STORAGE_PERF_TRIAL` to be exactly `1`, `2`, or
`3` and prints it in the structured result; a missing or different value fails
the test.

Each measured process follows this exact protocol:

1. construct the full fixture, then sample the baseline Darwin
   `phys_footprint` **before any scan in that process**;
2. start the sampler at an interval no greater than 1 ms and wait for an armed
   barrier that is fulfilled only after the sampling thread is running and has
   stored its first successful sample;
3. start exactly one scanner invocation;
4. continue sampling through scanner completion while retaining the scan result
   strongly, request and acknowledge one terminal sample, then signal stop;
5. wait for a stop/join barrier before releasing the result or reading samples;
6. fail the test on a sampler API error, an unacknowledged arm/terminal/join
   barrier, or zero samples;
7. define peak as `max(baseline, all sampled footprints)` and report that
   trial's baseline, peak, sample count, and `peak - baseline` delta. The
   three-trial budget uses the largest baseline-to-peak delta; samples are
   never pooled across processes.

Enforce for all three measured processes:

```text
maximum incremental resident footprint <= 96 MiB
peak tracked hard-link identities <= 65,536
computed preview hashes == 0
```

For timing, `testLargePreviewMaximumMainThreadStallIsUnder100Milliseconds`
recognizes `LUNGFISH_RUN_STORAGE_PERF=timing`. Construct the full
`releaseRepresentative` fixture before the preflight and outside every measured
preview interval. First run a two-second, 10 ms-cadence main-queue heartbeat
preflight and require maximum idle latency below 20 ms. Then run five preview
trials serially against the actual default scan path. For every trial:

1. create a 10 ms-cadence heartbeat source and wait for an explicit armed
   barrier before starting preview;
2. assign every cadence deadline a monotonic sequence and record its scheduled
   deadline and actual execution time;
3. at the terminal main-actor commit, atomically record the
   `terminalDeadlineWatermark`: the greatest scheduled sequence whose deadline
   is less than or equal to the terminal-commit time;
4. keep the source active until every scheduled deadline through that watermark
   has an execution acknowledgement, including callbacks delayed by the
   terminal commit;
5. after all through-watermark acknowledgements, require and record at least one
   additional heartbeat execution whose actual execution time is after the
   terminal commit, then stop and join the heartbeat;
6. require a nonzero through-watermark sample count and acknowledged arm,
   watermark drain, post-terminal execution, and join barriers.

Run:

```bash
task9_implementation_sha='<paste exact 40-character SHA printed by Step 8>'
test "${#task9_implementation_sha}" -eq 40
case "$task9_implementation_sha" in
  *[!0-9a-f]*) exit 1 ;;
esac
git cat-file -e "${task9_implementation_sha}^{commit}"
test "$(git rev-parse HEAD)" = "$task9_implementation_sha"
test -z "$(git status --porcelain)"
LUNGFISH_RUN_STORAGE_PERF=timing \
SWIFT_DETERMINISTIC_HASHING=1 \
swift test -c release --filter \
  'ProjectStoragePerformanceTests/testLargePreviewMaximumMainThreadStallIsUnder100Milliseconds'
```

For each trial, compute latency only from deadlines with sequence less than or
equal to `terminalDeadlineWatermark`; the required post-terminal execution is a
drain/liveness proof and is not added to the measured set if its deadline is
after the watermark. Enforce the maximum individual through-watermark
heartbeat delay across all five trials, not a mean or percentile:

```text
maximum main-thread delay < 100 ms
```

Controlled skip classification is exact:

- missing `LUNGFISH_RUN_STORAGE_PERF` skips
  `testReleaseRepresentativeScanMemoryDeltaIsAtMost96MiB` and
  `testLargePreviewMaximumMainThreadStallIsUnder100Milliseconds` only in
  ordinary CI, with reason prefix `storage-perf-disabled:`;
- either controlled test may skip for `EOPNOTSUPP`, `ENOTSUP`, or `EXDEV` while
  constructing the full controlled fixture, with reason
  `storage-perf-incomplete: link errno=<integer> (<symbol>)`; this makes the
  controlled run **incomplete**, never passed;
- preflight latency at least 20 ms makes the timing test skip with
  `storage-perf-inconclusive: idle-preflight-max-ns=<value>` and makes the run
  **inconclusive**;
- an unarmed heartbeat, missing terminal watermark, incomplete
  through-watermark acknowledgement set, missing post-terminal execution,
  unjoined source, or zero through-watermark samples makes the timing test skip
  with reason prefix
  `storage-perf-inconclusive: heartbeat-` and makes the run
  **inconclusive**, never passed;
- sampler errors, sampler barrier failures, or zero memory samples are test
  failures, not skips;
- with a healthy controlled environment, no skip is a pass. Budget breaches
  are product failures and thresholds or fixtures are not relaxed.

Build and observe real Release signposts using a separate, unmeasured
representative fixture:

```bash
task9_implementation_sha='<paste exact 40-character SHA printed by Step 8>'
test "${#task9_implementation_sha}" -eq 40
case "$task9_implementation_sha" in
  *[!0-9a-f]*) exit 1 ;;
esac
git cat-file -e "${task9_implementation_sha}^{commit}"
test "$(git rev-parse HEAD)" = "$task9_implementation_sha"
test -z "$(git status --porcelain)"
swift build -c release --product Lungfish
log stream --signpost --style compact \
  --predicate \
  '(subsystem == "com.lungfish.workflow" OR subsystem == "com.lungfish.app") AND category == "ProjectStorage"'
```

While the stream is active, open the representative project and invoke
**Manage Project Storage…**. Require balanced `ProjectStorage.Scan`,
`ProjectStorage.DescriptorPreparation` when cleanup is confirmed, and
`ProjectStorage.MainActorCommit` intervals. Unit tests prove semantic emission;
this smoke proves the production `OSSignposter` sinks are wired. A missing or
unbalanced interval is a failure; there is no signpost-smoke skip. Do not
publish, notarize, tag, or upload a release.

- [ ] **Step 11: Record evidence and enforce stop conditions**

Only after running Steps 9–10, independently reassign and validate the literal
implementation SHA before authoring evidence:

```bash
task9_base_sha='<paste exact 40-character base SHA printed by Step 8>'
task9_implementation_sha='<paste exact 40-character SHA printed by Step 8>'
for task9_sha in "$task9_base_sha" "$task9_implementation_sha"; do
  test "${#task9_sha}" -eq 40
  case "$task9_sha" in
    *[!0-9a-f]*) exit 1 ;;
  esac
  git cat-file -e "${task9_sha}^{commit}"
done
test "$(git rev-parse "${task9_implementation_sha}^")" = "$task9_base_sha"
test "$(git rev-parse HEAD)" = "$task9_implementation_sha"
test -z "$(git status --porcelain)"
```

Then create
`docs/verification/project-storage-lifecycle.md` containing:

- the exact literal 40-character base and implementation SHAs, the policy
  `baselineSHA`, the direct-parent proof, every format/existence/HEAD/clean-tree
  assertion, and every command with complete pass/fail/skip counts;
- the `ci-focused`, `focused`, `scientific`, and `full` retained base and
  implementation raw console-log paths, checksums, file sizes, Swift/`tee`
  statuses, parsed terminal summaries, and JSON comparison reports;
- every pre-existing baseline skip and implementation skip as exact
  name/reason/count tuples, including unchanged Trash, openpyxl,
  case-sensitive-volume, optional fixture/tool, network, or performance skips;
- every new Task 9 skip and its strict policy decision, kept separate from the
  inherited-skip multisets;
- Swift, Xcode, and macOS versions;
- baseline/comparison machine fingerprints proving each pair used the same
  Swift, Xcode, macOS, architecture, relevant optional-tool/environment state,
  and filesystem, plus controlled machine name/model, CPU, RAM, build
  configuration, and filesystem type/block size;
- exact fixture profile, fixed seed, profile-total object counts, deterministic
  per-candidate distribution, depth, sparse sizes, hard-link entry/identity
  topology, and independent-oracle totals;
- separate warm-up process result and all three fresh memory-process trial IDs,
  baselines, maxima, deltas, sample counts, sampler cadence, and barrier
  acknowledgements;
- heartbeat preflight and all five timing trials, terminal deadline watermark,
  scheduled and actual counts through that watermark, arm/watermark-drain/
  post-terminal/join acknowledgements, and through-watermark individual and
  overall maxima;
- peak tracked identities, retained scanner records, and computed/reused hash
  counters;
- signpost transcript or retained trace location;
- cancellation, identity-replacement, symlink, no-follow, hard-link-cap, and
  operation-history fault points;
- project-open automatic-cleanup recorder result, independent before/after
  fixture snapshot, and direct-call source-boundary result as three separate
  claims;
- actual default-worker observations for authority, scan, and cleanup
  preparation, plus the preparation/cancellation/release barrier order, zero
  executor-boundary hits, and unchanged source/journal/operation-history/
  quarantine evidence;
- external sentinel and prior evidence-artifact preservation;
- checked provenance fields, attestation reuse, and final-payload path checks;
- every allowed skip or inconclusive result with exact test, errno/symbolic
  name, environment mode, or runner-health reason.

Stop and leave Task 9 incomplete if any of these occurs:

- either SHA literal is not exactly 40 lowercase hexadecimal characters, does
  not name a commit, the implementation parent differs from the base/policy
  SHA, implementation differs from HEAD, a required literal is omitted from a
  comparison block, or the tested tree is dirty;
- a base/implementation suite pair uses different test-selection argv,
  machine/tool/environment fingerprints, or does not run base first;
- either retained raw console log is missing/truncated, lacks the final selected
  suite summary, records a nonzero Swift/`tee` status, or its parsed skip count
  disagrees with that terminal summary;
- any skipped XCTest event or `Test skipped -` reason cannot be paired
  one-to-one, or a multiline reason is not preserved completely;
- any pre-existing skip is added, removed, changes full reason, or changes
  multiplicity between base and implementation;
- a required signpost interval is absent or unbalanced;
- preview hashes payload content or emits project/sample paths in diagnostics;
- the actual default scan, canonicalization, identity-read, or cleanup
  preparation worker runs on the main thread;
- the default-worker test releases its preparation barrier before real
  coordinator-task cancellation propagates, the writer passes its initial
  cancellation check, the executor/Trash boundary is reached, or any selected
  source, journal, operation-history, quarantine, or Trash state changes;
- project open invokes automatic storage cleanup during the runtime open check,
  its independent fixture snapshot changes, or the source guard finds a direct
  scanner/cleanup call;
- a timing heartbeat is not armed before preview, fails to record the terminal
  deadline watermark, lacks an acknowledgement for any deadline through the
  watermark, lacks a post-terminal execution, is not joined, or records zero
  through-watermark samples;
- idle preflight latency is at least 20 ms or timing measurement is incomplete
  (record **inconclusive**, never passed);
- any measured main-thread delay is at least 100 ms;
- the memory warm-up shares a process with a measured trial, fewer or more than
  three fresh measured processes run, or baseline is sampled after a scan;
- the memory sampler cadence exceeds 1 ms, any arm/terminal/join barrier fails,
  any sampler call errors, or a trial records zero samples;
- any Release baseline-to-maximum resident-footprint delta exceeds 96 MiB;
- hard-link tracking exceeds 65,536, its visible classification is missing, or
  reclaimable allocation is overstated;
- fixture/profile totals, deterministic distribution, hard-link entry
  semantics, logical-yield visited count, or independent oracle disagree;
- cancellation returns a partial removable result or mutates a selected root;
- operation history or evidence is offered, removed, or altered;
- descriptor-bound recovery accepts a symlink, replacement, unstable file, or
  semantically mismatched receipt;
- provenance omits a required field or points only at staging paths;
- hard links are unavailable on the controlled Release filesystem;
- a skip from a newly added Task 9 class is not one of the exact
  test/environment/errno cases above;
- a hosted-runner, unhealthy-runner, incomplete, or inconclusive result is
  treated as release authority;
- either base or implementation focused/scientific/full command, packaging,
  Release, or signpost command has an unexpected failure.

- [ ] **Step 12: Commit verification evidence separately**

The evidence document is the only change after the implementation SHA:

```bash
task9_base_sha='<paste exact 40-character base SHA printed by Step 8>'
task9_implementation_sha='<paste exact 40-character SHA printed by Step 8>'
for task9_sha in "$task9_base_sha" "$task9_implementation_sha"; do
  test "${#task9_sha}" -eq 40
  case "$task9_sha" in
    *[!0-9a-f]*) exit 1 ;;
  esac
  git cat-file -e "${task9_sha}^{commit}"
done
test "$(git rev-parse "${task9_implementation_sha}^")" = "$task9_base_sha"
test "$(git rev-parse HEAD)" = "$task9_implementation_sha"
test "$(git status --short)" = \
  "?? docs/verification/project-storage-lifecycle.md"
git add docs/verification/project-storage-lifecycle.md
test "$(git diff --cached --name-only)" = \
  "docs/verification/project-storage-lifecycle.md"
git commit -m "docs: record project storage lifecycle verification"
test "$(git rev-parse HEAD^)" = "$task9_implementation_sha"
test -z "$(git status --porcelain)"
```

Expected: a second, docs-only evidence commit whose parent is the tested Task 9
implementation commit and whose contents explicitly reference that parent SHA.
There is no circular claim that the evidence commit itself was the tested
tree, no unrelated file, and no release publication action.
