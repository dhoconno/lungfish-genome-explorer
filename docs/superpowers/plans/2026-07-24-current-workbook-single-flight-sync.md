# Current Workbook Single-Flight Synchronization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make genotype `current.xlsx` updates dirty-aware and single-flight, add “Update and View Current Excel Version,” and prevent transient workbook publication locks from rejecting analyst annotations.

**Architecture:** A versioned workflow-layer fingerprint records the exact semantic inputs represented by each workbook revision. An app-layer per-bundle coordinator deduplicates idle, bundle-switch, and update-and-view requests, while the genotype controller defers only transient lock-conflicted matrix mutations and retries them after publication. The existing crash-safe workbook service and strict scientific validation remain authoritative.

**Tech Stack:** Swift 6, AppKit, SwiftUI, Swift Concurrency, CryptoKit SHA-256, XCTest, existing Lungfish provenance and workbook transaction services.

---

## File Structure

- Create `Sources/LungfishWorkflow/ONTGenotyping/GenotypeCurrentWorkbookInputFingerprint.swift`
  - Canonical fingerprint input, digest generation, and recorded-provenance lookup.
- Create `Sources/LungfishApp/Services/GenotypeCurrentWorkbookSyncCoordinator.swift`
  - Per-bundle single-flight state machine, 90-second idle scheduling, follow-up coalescing, and update-and-view behavior.
- Create `Tests/LungfishWorkflowTests/GenotypeCurrentWorkbookInputFingerprintTests.swift`
  - Fingerprint determinism, semantic dirtiness, and provenance lookup.
- Create `Tests/LungfishAppTests/GenotypeCurrentWorkbookSyncCoordinatorTests.swift`
  - Single-flight, dirty/current, follow-up, view, and failure behavior.
- Modify `Sources/LungfishWorkflow/ONTGenotyping/GenotypeWorkbookRevisionService.swift`
  - Record the immutable input fingerprint and resolved sync intent in workbook provenance.
- Modify `Sources/LungfishCLI/Commands/FastqUpdateCurrentWorkbookSubcommand.swift`
  - Accept and propagate fingerprint and sync-intent options for reproducible CLI execution.
- Modify `Sources/LungfishApp/Services/GenotypeCurrentWorkbookUpdateExecutionService.swift`
  - Propagate fingerprint and sync intent to the CLI.
- Modify `Sources/LungfishApp/Views/MainWindow/MainSplitViewController+ContentDisplay.swift`
  - Route controller requests through the coordinator and keep the controller alive through deferred mutation flush.
- Modify `Sources/LungfishApp/Views/Viewer/ViewerViewController+Genotype.swift`
  - Request bundle-switch synchronization before removing a genotype controller.
- Modify `Sources/LungfishGenotypeUI/GenotypeResultViewController.swift`
  - Use a 90-second idle trigger, expose sync intents, defer transient lock-conflicted matrix commands, and update button/status behavior.
- Modify `Sources/LungfishGenotypeUI/GenotypeResultDocumentSection.swift`
  - Render “Update and View Current Excel Version” and synchronization states in the Document inspector.
- Modify `Sources/LungfishApp/Views/Inspector/InspectorViewController+PublicAPI.swift`
  - Populate the inspector state from fingerprint currentness and coordinator state.
- Modify relevant existing tests in `Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift`, `Tests/LungfishAppTests/GenotypeCurrentWorkbookUpdateExecutionServiceTests.swift`, and `Tests/LungfishCLITests/FastqGenotypingCommandTests.swift`.

### Task 1: Versioned Workbook Input Fingerprint

**Files:**
- Create: `Sources/LungfishWorkflow/ONTGenotyping/GenotypeCurrentWorkbookInputFingerprint.swift`
- Create: `Tests/LungfishWorkflowTests/GenotypeCurrentWorkbookInputFingerprintTests.swift`

- [ ] **Step 1: Write failing determinism and dirtiness tests**

```swift
func testFingerprintIsDeterministicAcrossInputOrdering() throws {
    let first = try GenotypeCurrentWorkbookInputFingerprint.make(
        calls: [callB, callA],
        includedLoci: ["MHC-B", "MHC-A"],
        annotationSidecar: sidecar,
        candidateArtifacts: artifacts
    )
    let second = try GenotypeCurrentWorkbookInputFingerprint.make(
        calls: [callA, callB],
        includedLoci: ["MHC-A", "MHC-B"],
        annotationSidecar: sidecar,
        candidateArtifacts: artifacts
    )
    XCTAssertEqual(first, second)
}

func testFingerprintChangesWhenAWorkbookInputChanges() throws {
    let before = try makeFingerprint(sidecar: .empty(generatedAt: ""))
    var edited = GenotypeAnnotationSidecar.empty(generatedAt: "")
    edited.matrixComments = [.init(target: target, body: "review", author: "analyst", timestamp: timestamp)]
    XCTAssertNotEqual(before, try makeFingerprint(sidecar: edited))
}
```

- [ ] **Step 2: Run the fingerprint tests and verify RED**

Run:

```bash
swift test --skip-update --filter GenotypeCurrentWorkbookInputFingerprintTests
```

Expected: compilation fails because `GenotypeCurrentWorkbookInputFingerprint` does not exist.

- [ ] **Step 3: Implement canonical fingerprint generation**

```swift
public struct GenotypeCurrentWorkbookInputFingerprint: Codable, Equatable, Sendable {
    public static let schemaVersion = 1
    public let schemaVersion: Int
    public let sha256: String

    public static func make(
        calls: [GenotypeWorkbookHaplotypeCall],
        includedLoci: [String],
        annotationSidecar: GenotypeAnnotationSidecar?,
        candidateArtifacts: ONTMHCCandidateArtifactManifest?
    ) throws -> Self {
        let canonical = CanonicalInput(
            schemaVersion: schemaVersion,
            calls: calls.sorted(by: canonicalCallOrder),
            includedLoci: Array(Set(includedLoci)).sorted(),
            annotationSidecar: annotationSidecar,
            candidateArtifacts: canonicalArtifacts(candidateArtifacts)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let digest = SHA256.hash(data: try encoder.encode(canonical))
        return Self(schemaVersion: schemaVersion, sha256: digest.map { String(format: "%02x", $0) }.joined())
    }
}
```

The private canonical artifact representation must include every declared artifact’s path, checksum, size, and schema version, sorted by path. The call comparator must order sample, canonical locus, haplotype 1, haplotype 2, status, then notes.

- [ ] **Step 4: Add recorded-provenance lookup tests and implementation**

```swift
func testRecordedFingerprintReadsLatestCurrentRevisionProvenance() throws {
    let recorded = try GenotypeCurrentWorkbookInputFingerprint.recorded(
        in: manifest,
        bundleURL: bundleURL
    )
    XCTAssertEqual(recorded, expected)
}
```

Read the latest revision matching `manifest.currentWorkbookPath`, resolve its `provenancePath`, decode `ProvenanceEnvelope`, and read the explicit options `currentWorkbookInputFingerprint` and `currentWorkbookInputFingerprintSchemaVersion`. Missing or unsupported values return `nil`.

- [ ] **Step 5: Run tests and commit**

```bash
swift test --skip-update --filter GenotypeCurrentWorkbookInputFingerprintTests
git add Sources/LungfishWorkflow/ONTGenotyping/GenotypeCurrentWorkbookInputFingerprint.swift Tests/LungfishWorkflowTests/GenotypeCurrentWorkbookInputFingerprintTests.swift
git commit -m "feat: fingerprint current workbook inputs"
```

Expected: all fingerprint tests pass.

### Task 2: Record Fingerprint and Sync Intent in Provenance

**Files:**
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/GenotypeWorkbookRevisionService.swift`
- Modify: `Sources/LungfishCLI/Commands/FastqUpdateCurrentWorkbookSubcommand.swift`
- Modify: `Sources/LungfishApp/Services/GenotypeCurrentWorkbookUpdateExecutionService.swift`
- Modify: `Tests/LungfishWorkflowTests/GenotypeWorkbookRevisionServiceTests.swift`
- Modify: `Tests/LungfishCLITests/FastqGenotypingCommandTests.swift`
- Modify: `Tests/LungfishAppTests/GenotypeCurrentWorkbookUpdateExecutionServiceTests.swift`

- [ ] **Step 1: Write failing propagation and provenance tests**

```swift
XCTAssertEqual(
    envelope.options.explicit["currentWorkbookInputFingerprint"],
    .string(fingerprint.sha256)
)
XCTAssertEqual(
    envelope.options.explicit["currentWorkbookInputFingerprintSchemaVersion"],
    .integer(fingerprint.schemaVersion)
)
XCTAssertEqual(envelope.options.explicit["currentWorkbookSyncIntent"], .string("update-and-view"))
```

CLI and app-service tests must also assert `--input-fingerprint`, `--input-fingerprint-schema`, and `--sync-intent` appear exactly once.

- [ ] **Step 2: Run the focused tests and verify RED**

```bash
swift test --skip-update --filter 'GenotypeWorkbookRevisionServiceTests|FastqGenotypingCommandTests|GenotypeCurrentWorkbookUpdateExecutionServiceTests'
```

Expected: new assertions fail because the options are absent.

- [ ] **Step 3: Extend the provenance context**

```swift
public enum GenotypeCurrentWorkbookSyncIntent: String, Codable, Sendable {
    case automaticIdle = "automatic-idle"
    case bundleSwitch = "bundle-switch"
    case updateAndView = "update-and-view"
}

public struct GenotypeWorkbookRevisionProvenanceContext: Equatable, Sendable {
    // existing properties
    public let inputFingerprint: GenotypeCurrentWorkbookInputFingerprint?
    public let syncIntent: GenotypeCurrentWorkbookSyncIntent?
}
```

Merge these values into `additionalExplicitOptions` at the call to `importRevisedWorkbook`. Keep them absent for legacy callers rather than inventing values.

- [ ] **Step 4: Add CLI options and app-service propagation**

```swift
@Option(name: .customLong("input-fingerprint"))
var inputFingerprint: String?

@Option(name: .customLong("input-fingerprint-schema"))
var inputFingerprintSchema: Int?

@Option(name: .customLong("sync-intent"))
var syncIntent: GenotypeCurrentWorkbookSyncIntent?
```

Validate that fingerprint and schema are either both present or both absent. Include all resolved values in argv/provenance. `GenotypeCurrentWorkbookUpdateExecutionService.run` receives `fingerprint` and `syncIntent` and generates these CLI arguments.

- [ ] **Step 5: Run tests and commit**

```bash
swift test --skip-update --filter 'GenotypeWorkbookRevisionServiceTests|FastqGenotypingCommandTests|GenotypeCurrentWorkbookUpdateExecutionServiceTests'
git add Sources/LungfishWorkflow/ONTGenotyping/GenotypeWorkbookRevisionService.swift Sources/LungfishCLI/Commands/FastqUpdateCurrentWorkbookSubcommand.swift Sources/LungfishApp/Services/GenotypeCurrentWorkbookUpdateExecutionService.swift Tests/LungfishWorkflowTests/GenotypeWorkbookRevisionServiceTests.swift Tests/LungfishCLITests/FastqGenotypingCommandTests.swift Tests/LungfishAppTests/GenotypeCurrentWorkbookUpdateExecutionServiceTests.swift
git commit -m "feat: attest current workbook input fingerprint"
```

Expected: focused workflow, CLI, and app-service tests pass.

### Task 3: Per-Bundle Single-Flight Coordinator

**Files:**
- Create: `Sources/LungfishApp/Services/GenotypeCurrentWorkbookSyncCoordinator.swift`
- Create: `Tests/LungfishAppTests/GenotypeCurrentWorkbookSyncCoordinatorTests.swift`

- [ ] **Step 1: Write failing state-machine tests**

```swift
func testConcurrentRequestsShareOneUpdate() async throws {
    let coordinator = makeCoordinator()
    coordinator.markDirty(request)
    async let idle = coordinator.synchronize(request, intent: .automaticIdle, openAfterSuccess: false)
    async let view = coordinator.synchronize(request, intent: .updateAndView, openAfterSuccess: true)
    _ = try await (idle, view)
    XCTAssertEqual(runner.invocationCount, 1)
    XCTAssertEqual(opener.openedURLs, [currentWorkbookURL])
}

func testNewGenerationDuringUpdateProducesOneFollowUp() async throws {
    runner.suspendFirstInvocation()
    coordinator.markDirty(first)
    let firstTask = Task { try await coordinator.synchronize(first, intent: .automaticIdle) }
    coordinator.markDirty(second)
    coordinator.markDirty(third)
    runner.resumeFirstInvocation()
    _ = try await firstTask.value
    XCTAssertEqual(runner.invocationCount, 2)
    XCTAssertEqual(runner.fingerprints, [first.fingerprint, third.fingerprint])
}
```

- [ ] **Step 2: Run coordinator tests and verify RED**

```bash
swift test --skip-update --filter GenotypeCurrentWorkbookSyncCoordinatorTests
```

Expected: compilation fails because the coordinator does not exist.

- [ ] **Step 3: Implement coordinator states and injected dependencies**

```swift
@MainActor
final class GenotypeCurrentWorkbookSyncCoordinator {
    enum Phase: Equatable { case current, dirty, updating, dirtyWhileUpdating, failed(String) }

    struct Request: Sendable {
        let bundleURL: URL
        let calls: [GenotypeWorkbookHaplotypeCall]
        let includedLoci: [String]
        let annotationSidecarURL: URL?
        let annotationOnly: Bool
        let fingerprint: GenotypeCurrentWorkbookInputFingerprint
        let routeContext: OperationRouteContext?
    }

    private struct Entry {
        var liveRequest: Request
        var generation: UInt64
        var publishingGeneration: UInt64?
        var task: Task<Void, Error>?
        var openAfterSuccess = false
        var phase: Phase
    }
}
```

Inject an update closure and workbook opener closure. Key entries by `bundleURL.standardizedFileURL.path`. A clean request compares `request.fingerprint` with the recorded fingerprint and opens without calling the update closure. Dirty requests share one task. Completion loops once more only when `generation > publishingGeneration`.

- [ ] **Step 4: Add 90-second resettable idle scheduling tests and implementation**

Use an injected scheduler in tests. `markDirty` cancels the prior token and schedules `.automaticIdle` after `90_000_000_000` nanoseconds. Repeated edits leave one live token. Automatic failures do not immediately reschedule.

- [ ] **Step 5: Run tests and commit**

```bash
swift test --skip-update --filter GenotypeCurrentWorkbookSyncCoordinatorTests
git add Sources/LungfishApp/Services/GenotypeCurrentWorkbookSyncCoordinator.swift Tests/LungfishAppTests/GenotypeCurrentWorkbookSyncCoordinatorTests.swift
git commit -m "feat: serialize current workbook synchronization"
```

Expected: all coordinator tests pass.

### Task 4: Defer Transient Lock-Conflicted Matrix Mutations

**Files:**
- Modify: `Sources/LungfishGenotypeUI/GenotypeResultViewController.swift`
- Modify: `Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift`

- [ ] **Step 1: Write a failing edit-during-publication test**

```swift
func testCommentLockConflictDefersWithoutAlertAndReplaysAfterRelease() throws {
    let controller = configuredController(publicationLockHeld: true)
    controller.editMatrixComment(.init(targets: [target], intent: .upsert(body: "long review")))
    XCTAssertEqual(controller.testingDeferredMatrixMutationCount, 1)
    XCTAssertNil(controller.testingLastPresentedError)

    releasePublicationLock()
    controller.testingFireDeferredMutationRetry()

    XCTAssertEqual(loadSidecar().resolvedMatrixComments[target]?.body, "long review")
    XCTAssertEqual(controller.testingDeferredMatrixMutationCount, 0)
    XCTAssertTrue(controller.testingCurrentWorkbookNeedsRefresh)
}
```

Add equivalent review and style coverage plus an assertion that non-lock errors still reach the normal error handler.

- [ ] **Step 2: Run viewport tests and verify RED**

```bash
swift test --skip-update --filter 'GenotypeResultViewportTests/testCommentLockConflictDefersWithoutAlertAndReplaysAfterRelease'
```

Expected: test fails because the lock error is presented and no deferred queue exists.

- [ ] **Step 3: Add typed deferred mutation commands**

```swift
private enum DeferredMatrixMutation {
    case style(GenotypeMatrixStyleRequest)
    case review(GenotypeMatrixReviewRequest)
    case comment(GenotypeMatrixCommentRequest)
}

private func deferIfPublicationLockHeld(
    _ error: Error,
    mutation: DeferredMatrixMutation
) -> Bool {
    guard case .lockHeld = error as? ONTGenotypeWorkbookUpdateRecoveryError else { return false }
    deferredMatrixMutations.append(mutation)
    currentWorkbookUpdateStatus = "Saving annotation after the workbook update finishes."
    scheduleDeferredMatrixMutationRetry()
    return true
}
```

Each matrix mutation catch block calls this helper before presenting an error. Retry in submission order after 500 milliseconds. If the lock is still held, keep the command and reschedule. On success, refresh matrix/audit state and allow the normal 90-second dirty notification. Do not defer unsafe-lock, stale-revision, read-only, or validation errors.

- [ ] **Step 4: Run viewport tests and commit**

```bash
swift test --skip-update --filter GenotypeResultViewportTests
git add Sources/LungfishGenotypeUI/GenotypeResultViewController.swift Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift
git commit -m "fix: defer annotations during workbook publication"
```

Expected: all viewport tests pass and the lock-cadence regression is green.

### Task 5: Route UI Triggers Through the Coordinator

**Files:**
- Modify: `Sources/LungfishGenotypeUI/GenotypeResultViewController.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeResultDocumentSection.swift`
- Modify: `Sources/LungfishApp/Views/Inspector/InspectorViewController+PublicAPI.swift`
- Modify: `Sources/LungfishApp/Views/MainWindow/MainSplitViewController+ContentDisplay.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/ViewerViewController+Genotype.swift`
- Modify: `Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift`
- Modify: `Tests/LungfishAppTests/MappingViewportRoutingTests.swift`

- [ ] **Step 1: Write failing button, clean-open, and bundle-switch tests**

```swift
XCTAssertEqual(controller.testingCurrentWorkbookActionTitle, "Update and View Current Excel Version")
controller.testingRequestCurrentWorkbookUpdateAndView()
XCTAssertEqual(request.intent, .updateAndView)
XCTAssertTrue(request.openAfterSuccess)

viewer.hideGenotypeResultView()
XCTAssertEqual(syncSpy.intents, [.bundleSwitch])
```

Inspector tests must assert that current, dirty, updating, and failed status text map to the approved copy and that read-only current workbooks remain viewable.

- [ ] **Step 2: Run focused UI tests and verify RED**

```bash
swift test --skip-update --filter 'GenotypeResultViewportTests|MappingViewportRoutingTests'
```

Expected: title and bundle-switch intent assertions fail.

- [ ] **Step 3: Replace callback parameters with a request intent**

```swift
public struct GenotypeCurrentWorkbookUIRequest: Sendable {
    public let bundleURL: URL
    public let calls: [GenotypeWorkbookHaplotypeCall]
    public let includedLoci: [String]
    public let annotationOnly: Bool
    public let intent: GenotypeCurrentWorkbookSyncIntent
    public let openAfterSuccess: Bool
    public let fingerprint: GenotypeCurrentWorkbookInputFingerprint
}
```

The controller’s 90-second scheduler emits `.automaticIdle`; the primary button emits `.updateAndView`; a new public `requestCurrentWorkbookSyncForBundleSwitch()` emits `.bundleSwitch` only when dirty. Remove the old 350-millisecond automatic publication behavior.

- [ ] **Step 4: Wire the app coordinator and external opener**

`MainSplitViewController+ContentDisplay` forwards requests to the coordinator. The coordinator update closure invokes `GenotypeCurrentWorkbookUpdateExecutionService`; its opener calls `NSWorkspace.shared.open(url)`. `ViewerViewController.hideGenotypeResultView` asks the current controller for bundle-switch sync before removal. The in-flight task retains the necessary request/state independently of the viewport.

- [ ] **Step 5: Update both Current Workbook surfaces**

```swift
Button("Update and View Current Excel Version") {
    onCurrentWorkbookUpdateRequested?()
}
.help("Open the current workbook immediately when current; otherwise update it once and open the successful revision.")
```

The AppKit Artifacts lens uses the same title and action. Status copy comes from coordinator phase rather than annotation counts alone.

- [ ] **Step 6: Run tests and commit**

```bash
swift test --skip-update --filter 'GenotypeResultViewportTests|MappingViewportRoutingTests|GenotypeCurrentWorkbookSyncCoordinatorTests'
git add Sources/LungfishGenotypeUI/GenotypeResultViewController.swift Sources/LungfishGenotypeUI/GenotypeResultDocumentSection.swift Sources/LungfishApp/Views/Inspector/InspectorViewController+PublicAPI.swift Sources/LungfishApp/Views/MainWindow/MainSplitViewController+ContentDisplay.swift Sources/LungfishApp/Views/Viewer/ViewerViewController+Genotype.swift Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift Tests/LungfishAppTests/MappingViewportRoutingTests.swift
git commit -m "feat: update and view current genotype workbook"
```

Expected: all focused UI and coordinator tests pass.

### Task 6: Integration, Performance, and Real-Bundle Verification

**Files:**
- Modify: `Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift`
- Modify: `Tests/LungfishAppTests/GenotypeCurrentWorkbookSyncCoordinatorTests.swift`
- Modify: `Tests/LungfishWorkflowTests/GenotypeWorkbookRevisionServiceTests.swift`
- Modify: `docs/superpowers/reports/2026-07-24-genotype-matrix-review-annotations-verification.md`

- [ ] **Step 1: Add the cadence and performance regressions**

Test a comment after an automatic update starts, verify it is ultimately audited, and assert one follow-up update. Add a representative fingerprint benchmark and assert repeated dirty notifications retain one timer and one follow-up marker.

- [ ] **Step 2: Run all relevant suites**

```bash
swift test --skip-update --filter 'GenotypeCurrentWorkbookInputFingerprintTests|GenotypeWorkbookRevisionServiceTests|GenotypeCurrentWorkbookSyncCoordinatorTests|GenotypeCurrentWorkbookUpdateExecutionServiceTests|FastqGenotypingCommandTests|GenotypeResultViewportTests|MappingViewportRoutingTests'
```

Expected: zero failures.

- [ ] **Step 3: Reproduce against a copied real bundle**

Create an explicit temporary copy of the reported bundle on `/Volumes/iWES_WNPRC`, run the worktree CLI with `--annotation-only`, fingerprint, schema, and sync-intent arguments, and verify:

```text
Unified Genotype Pivot!CP152 = [87]
font italic = true
font color = FF767676
invalid legacy Mafa-B*070:01:01:03_0nt_nov count remains 2
provenance currentWorkbookInputFingerprint equals the supplied fingerprint
original current.xlsx SHA-256 remains 13a78b65f32950ce917f66c19cc8d5d9028f7c21a6828e04dd6c4fe93262d706
```

Move the explicit temporary copy to the volume Trash after verification.

- [ ] **Step 4: Request independent code review**

Ask a reviewer to focus on single-flight guarantees, fingerprint completeness, deferred-edit durability, scientific provenance, and absence of main-thread blocking. Fix every Critical or Important issue and rerun affected tests.

- [ ] **Step 5: Update verification report and commit**

Record exact commands, test counts, benchmark results, copied-bundle evidence, and the verified commit.

```bash
git add Tests docs/superpowers/reports/2026-07-24-genotype-matrix-review-annotations-verification.md
git commit -m "test: verify single-flight workbook synchronization"
```

### Task 7: Build and Launch the Debug App

**Files:**
- Generated: `build/Debug/Lungfish.app`
- Generated: `build/logs/build-app-debug-*.log`

- [ ] **Step 1: Verify the worktree and commit state**

```bash
git diff --check
git status --short
```

Expected: no uncommitted source changes.

- [ ] **Step 2: Quit every running Lungfish instance**

Resolve all processes matching `^.*/Lungfish.app/Contents/MacOS/Lungfish$`, verify their executable paths, and send `TERM`. Confirm none remain.

- [ ] **Step 3: Build the debug app**

```bash
./scripts/build-app.sh --configuration debug --log-dir build/logs
```

Expected: build succeeds, bundle identifier is `com.lungfish.browser.debug`, and deep code-sign verification passes.

- [ ] **Step 4: Launch and verify one instance**

```bash
open -na build/Debug/Lungfish.app
```

Confirm exactly one matching process runs from this worktree and activate `com.lungfish.browser.debug`.

- [ ] **Step 5: Final handoff**

Report the running PID, commit, test counts, copied-bundle result, original bundle checksum, and the 90-second idle plus bundle-switch behavior.
