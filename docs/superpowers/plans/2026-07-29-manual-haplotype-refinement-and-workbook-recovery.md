# Manual Haplotype Refinement and Workbook Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver compact, legible manual-haplotype curation with evidence-aware compare-and-copy, and make workbook publication recover safely and traceably from the observed exFAT zero-byte-file cleanup failure.

**Architecture:** Keep the two risk domains separate. In `LungfishIO`, extend the exclusive-rename fallback with held source and reservation witnesses, then let workbook cleanup adopt the detached path identity only under the narrow zero-byte regular-file contract; in `LungfishWorkflow` and the CLI/app bridge, distinguish committed-with-cleanup-warning from a blocking preflight failure and record every command attempt. In `LungfishGenotypeUI`, keep the existing shared genotype-only ONT/miSeq matrix and editor, add presentation-only disclosure and transient column minima, derive evidence/comparison snapshots directly from the matrix projection, and swap the trailing workbench mode without remounting the assignment editor.

**Tech Stack:** Swift 6.2, AppKit, SwiftUI, Combine, Darwin/POSIX file descriptors, CryptoKit, ArgumentParser, XCTest, openpyxl workbook runtime, Lungfish provenance envelopes.

---

## File map

### Files to create

- `Sources/LungfishWorkflow/ONTGenotyping/GenotypeWorkbookUpdateAttemptRecorder.swift` — compact per-command attempt receipt and reproducibility provenance writer.
- `Sources/LungfishGenotypeUI/GenotypeSampleComparisonModel.swift` — value-semantic evidence rows, stable-identity union, source filtering/cache, annotation indicators, and staging confirmation state.
- `Sources/LungfishGenotypeUI/GenotypeSampleComparisonPanel.swift` — responsive Evidence / Compare & Copy trailing-pane UI.
- `Tests/LungfishIOTests/PortableExclusiveRenameTests.swift` — native/fallback mechanism and held-witness race tests.
- `Tests/LungfishIOTests/ONTGenotypeWorkbookCleanupStateTests.swift` — low-level cleanup ordering, inode rebasing, and substitution defenses through a LungfishIO test hook.
- `Tests/LungfishGenotypeUITests/GenotypeSampleComparisonModelTests.swift` — ordering, identity, FN/FP/comment, caching, and staging contracts.
- `Tests/LungfishGenotypeUITests/GenotypeSampleComparisonPanelTests.swift` — mounted responsive/accessibility/control-identity tests.
- `scripts/verify-workbook-cleanup-exfat.sh` — opt-in, disposable verification on a caller-supplied real exFAT scratch root.

### Files to modify

- `Sources/LungfishIO/Storage/PortableExclusiveRename.swift` — reporting API, held descriptors, and final pre-rename witness validation.
- `Sources/LungfishIO/Bundles/ONTGenotypeWorkbookCleanupState.swift` — safe non-directory detach and narrow zero-byte inode-rebase acceptance.
- `Sources/LungfishIO/Bundles/ONTGenotypeWorkbookUpdateTransaction.swift` — preserve structured cleanup warnings and expose recovery context.
- `Sources/LungfishWorkflow/ONTGenotyping/GenotypeWorkbookRevisionService.swift` — outcome-returning update entry point, preflight/committed distinction, and attempt recording.
- `Sources/LungfishCLI/Commands/FastqUpdateCurrentWorkbookSubcommand.swift` — warning-aware JSON/stderr, zero exit for a committed workbook, and failure-attempt recording.
- `Sources/LungfishApp/Services/GenotypeCurrentWorkbookUpdateExecutionService.swift` — decode the CLI payload and show `Completed — cleanup pending`.
- `Sources/LungfishGenotypeUI/GenotypeManualHaplotypeAssignmentBand.swift` — approved disclosure label/help/default and assignment measurement.
- `Sources/LungfishGenotypeUI/GenotypeResultDisplayState.swift` — collapsed initial presentation state only.
- `Sources/LungfishGenotypeUI/GenotypeComparisonMatrixView.swift` — disclosure state preservation, transient auto-fit minima, ordered evidence projection, and selective remeasurement.
- `Sources/LungfishGenotypeUI/GenotypeSampleCurationWorkbenchView.swift` — remove the 640-point cap and host a mode-switching trailing region.
- `Sources/LungfishGenotypeUI/GenotypeSupportedAllelesPanel.swift` — two-column evidence contract.
- `Sources/LungfishGenotypeUI/GenotypeManualHaplotypeEditor.swift` — Compare & Copy action, visible export action, staged-copy messaging/confirmation.
- `Sources/LungfishGenotypeUI/GenotypeResultViewController.swift` — exact matrix-order evidence, call-support explanation, comparison source snapshots, and workbench wiring.
- `Tests/LungfishWorkflowTests/GenotypeWorkbookRevisionServiceTests.swift`
- `Tests/LungfishCLITests/FastqGenotypingCommandTests.swift`
- `Tests/LungfishAppTests/GenotypeCurrentWorkbookUpdateExecutionServiceTests.swift`
- `Tests/LungfishGenotypeUITests/GenotypeManualHaplotypeAccessibilityTests.swift`
- `Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift`
- `Tests/LungfishGenotypeUITests/GenotypeSupportedAllelesPanelTests.swift`
- `Tests/LungfishGenotypeUITests/GenotypeManualHaplotypeEditorTests.swift`
- `Tests/LungfishGenotypeUITests/GenotypeManualHaplotypePerformanceTests.swift`

## Shared test command convention

All SwiftPM commands run from the worktree root with writable module caches:

```bash
mkdir -p /tmp/lungfish-clang-cache /tmp/lungfish-swift-cache
CLANG_MODULE_CACHE_PATH=/tmp/lungfish-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/lungfish-swift-cache \
swift test --disable-sandbox --filter PortableExclusiveRenameTests
```

Every RED step must fail for the named missing behavior, not for compilation,
fixture, sandbox, signing, or managed-runtime setup. Every GREEN step must show
zero failures in the named filter before its commit.

### Task 1: Portable exclusive rename with held witnesses

**Files:**
- Create: `Tests/LungfishIOTests/PortableExclusiveRenameTests.swift`
- Modify: `Sources/LungfishIO/Storage/PortableExclusiveRename.swift`

- [ ] **Step 1: Add reporting and witness regression tests**

Add these tests:

```swift
@testable import LungfishIO
import Darwin
import XCTest

final class PortableExclusiveRenameTests: XCTestCase {
    func testReportingWrapperIdentifiesNativeAndReservationFallback() throws
    func testFallbackWithoutBorrowedWitnessOpensHoldsAndClosesItsSourceDescriptor() throws
    func testFallbackValidatesButNeverClosesBorrowedSourceDescriptor() throws
    func testFallbackHoldsAndRevalidatesRegularSourceAndReservation() throws
    func testFallbackRejectsSourceNameSubstitutionAfterReservation() throws
    func testFallbackRejectsReservationNameSubstitutionBeforeRename() throws
    func testFallbackAfterFinalValidationRaceLeavesDetectionToCallerPostRenameWitness() throws
    func testFallbackFailureRemovesOnlyItsVerifiedReservation() throws
    func testFallbackPreservesPrimaryErrnoAcrossDescriptorAndReservationCleanup() throws
    func testLegacyIntegerWrapperPreservesExistingCallContract() throws
}
```

The first test injects a native primitive that returns success and a second
primitive that returns `ENOTSUP`, then asserts `.nativeExclusive` and
`.reservationFallback`. The source-substitution test replaces the source name
from an injected `afterReservationCreated` checkpoint and asserts status `-1`,
`errno == ESTALE`, and preservation of both replacement and original held
file. The reservation-substitution test moves the random reservation aside,
puts a sentinel at its name, and asserts the sentinel survives. The legacy
test calls `renameatxNP` and asserts its result remains exactly `0`/`-1`. The
after-final-validation test swaps the source inside that exact checkpoint,
asserts ordinary rename can complete across the documented syscall gap, and
proves the returned fallback outcome contains enough mechanism information for
the cleanup caller's mandatory post-rename held-descriptor/path check to reject
the detached replacement. The errno test injects close/unlink side effects and
asserts the original `ESTALE`, `EEXIST`, or rename errno is restored last.

- [ ] **Step 2: Run the RED test**

Run:

```bash
CLANG_MODULE_CACHE_PATH=/tmp/lungfish-clang-cache SWIFTPM_MODULECACHE_OVERRIDE=/tmp/lungfish-swift-cache \
swift test --disable-sandbox --filter PortableExclusiveRenameTests
```

Expected: FAIL because the reporting API, mechanism enum, source witness, and
fallback checkpoints do not exist.

- [ ] **Step 3: Add the reporting API without changing legacy callers**

Add these internal contracts beside the public integer wrapper:

```swift
extension PortableExclusiveRename {
    enum Mechanism: String, Equatable, Sendable {
        case nativeExclusive = "renameatx_np"
        case reservationFallback = "reservation-renameat"
    }

    struct Outcome: Equatable, Sendable {
        let status: Int32
        let mechanism: Mechanism
    }

    struct RegularSourceWitness {
        let descriptor: Int32       // borrowed; caller retains ownership
        let expected: stat
    }

    struct Operations {
        var nativeRename: @Sendable (Int32, UnsafePointer<CChar>, Int32, UnsafePointer<CChar>, UInt32) -> Int32
        var ordinaryRename: @Sendable (Int32, UnsafePointer<CChar>, Int32, UnsafePointer<CChar>) -> Int32
        var afterReservationCreated: @Sendable () -> Void = {}
        var afterFinalWitnessValidation: @Sendable () -> Void = {}
    }

    static func renameatxNPReporting(
        _ sourceParent: Int32,
        _ sourceName: UnsafePointer<CChar>,
        _ destinationParent: Int32,
        _ destinationName: UnsafePointer<CChar>,
        _ flags: UInt32,
        sourceWitness: RegularSourceWitness? = nil,
        operations: Operations = .darwin
    ) -> Outcome
}
```

Implement `renameatxNP` as
`renameatxNPReporting(sourceParent, sourceName, destinationParent, destinationName, flags).status`.
Keep directory fallback behavior unchanged.
For every fallback regular-file rename, open the source internally with
`O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC` when `sourceWitness` is nil,
capture its pre-reservation `fstat`, hold it through `renameat`, and close only
that owned descriptor. When a borrowed witness is supplied, validate its
descriptor and expected metadata against the source pathname before reserving,
hold but never close it, then perform the same final validation. Hold the
reservation descriptor through `renameat`; after reservation and immediately
before rename:

```swift
guard sameIdentityAndMetadata(
        name: sourceName,
        parent: sourceParent,
        descriptor: resolvedWitness.descriptor,
        expected: resolvedWitness.expected
      ),
      sameIdentity(
        name: destinationName,
        parent: destinationParent,
        descriptor: reservationDescriptor,
        expected: reservationInfo
      ) else {
    removeReservationIfUnchanged(
        parent: destinationParent,
        name: destinationName,
        expected: reservationInfo
    )
    errno = ESTALE
    return .init(status: -1, mechanism: .reservationFallback)
}
```

Compare device, inode, `S_IFMT`, size, mode permission bits, and nanosecond
mtime/ctime metadata. Retry interrupted `fstat`, `fstatat`, and `renameat`
operations only for `EINTR`. Invoke `afterFinalWitnessValidation` only after
both name/descriptor checks and immediately before ordinary `renameat`; it is an
internal injected checkpoint used to prove the unavoidable syscall-sized race
in cleanup tests. Document that post-validation gap and the
cooperative-lock/random-name trust boundary in the source comment. On every
failure path, save the primary errno before closing an owned source/reservation
descriptor or removing a verified reservation, and restore that primary errno
immediately before returning.

- [ ] **Step 4: Run the GREEN test and existing store tests**

Run:

```bash
CLANG_MODULE_CACHE_PATH=/tmp/lungfish-clang-cache SWIFTPM_MODULECACHE_OVERRIDE=/tmp/lungfish-swift-cache \
swift test --disable-sandbox --filter PortableExclusiveRenameTests
CLANG_MODULE_CACHE_PATH=/tmp/lungfish-clang-cache SWIFTPM_MODULECACHE_OVERRIDE=/tmp/lungfish-swift-cache \
swift test --disable-sandbox --filter DurableAtomicFileStoreTests
```

Expected: both filters PASS; existing destination and directory fallback tests
remain green.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishIO/Storage/PortableExclusiveRename.swift \
  Tests/LungfishIOTests/PortableExclusiveRenameTests.swift
git commit -m "fix: witness portable exclusive rename fallback"
```

### Task 2: Workbook cleanup recovery, outcome semantics, and attempt provenance

**Files:**
- Create: `Sources/LungfishWorkflow/ONTGenotyping/GenotypeWorkbookUpdateAttemptRecorder.swift`
- Create: `Tests/LungfishIOTests/ONTGenotypeWorkbookCleanupStateTests.swift`
- Create: `scripts/verify-workbook-cleanup-exfat.sh`
- Modify: `Sources/LungfishIO/Bundles/ONTGenotypeWorkbookCleanupState.swift`
- Modify: `Sources/LungfishIO/Bundles/ONTGenotypeWorkbookUpdateTransaction.swift`
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/GenotypeWorkbookRevisionService.swift`
- Modify: `Sources/LungfishCLI/Commands/FastqUpdateCurrentWorkbookSubcommand.swift`
- Modify: `Sources/LungfishApp/Services/GenotypeCurrentWorkbookUpdateExecutionService.swift`
- Test: `Tests/LungfishWorkflowTests/GenotypeWorkbookRevisionServiceTests.swift`
- Test: `Tests/LungfishCLITests/FastqGenotypingCommandTests.swift`
- Test: `Tests/LungfishAppTests/GenotypeCurrentWorkbookUpdateExecutionServiceTests.swift`

- [ ] **Step 1: Add reachable low-level cleanup RED tests**

Create `ONTGenotypeWorkbookCleanupStateTests` with `@testable import
LungfishIO`. Test the internal cleanup state store through an explicit
`ONTGenotypeWorkbookCleanupOperations` value passed into the internal recovery
entry point:

```swift
final class ONTGenotypeWorkbookCleanupStateTests: XCTestCase {
    func testZeroByteRebaseClassifierAcceptsDifferingBeforeAndAgreedPostSnapshots() throws
    func testFallbackCleanupAcceptsOnlyWitnessedZeroByteRegularFileInodeRebase() throws
    func testFallbackCleanupRejectsNonzeroRegularFileInodeRebase() throws
    func testFallbackCleanupRejectsZeroByteMetadataChangeBeforeDetach() throws
    func testFallbackCleanupRejectsDirectorySymlinkAndSpecialEntryRebase() throws
    func testFallbackCleanupRejectsSourceSubstitutionBeforeDetach() throws
    func testFallbackCleanupRejectsMetadataIdenticalSourceSubstitutionAfterFinalValidationBeforeRename() throws
    func testFallbackCleanupRejectsTombstoneSubstitutionBeforeUnlink() throws
    func testCleanupOrderingHasNoCallbackBetweenFinalTombstoneWitnessAndUnlink() throws
}
```

The operations value must inject the reporting rename primitive and named
checkpoints; tests must not attempt to reach a private helper from the Workflow
module:

```swift
struct ONTGenotypeWorkbookCleanupOperations {
    var renameExclusive:
        (Int32, UnsafePointer<CChar>, Int32, UnsafePointer<CChar>,
         UInt32, PortableExclusiveRename.RegularSourceWitness?)
        -> PortableExclusiveRename.Outcome
    var checkpoint: (String) throws -> Void
    static let darwin: Self
}
```

Thread this value from the internal
`recoverIfNeededAssumingLock(for:attestationRootURL:cleanupFailureInjector:cleanupOperations:)`
overload through
`recoverCleanupStateIfPresent`, `completeProvenTransactionRootCleanup`, and
`removeContentsNoFollow`. The existing public overload supplies `.darwin`, so
production callers and source compatibility remain unchanged.
Keep the first test synthetic and filesystem-independent: construct
`before`, `postDescriptor`, and `postPath` stat snapshots with a different
pre-detach inode but matching post-detach identities and stable zero-byte
metadata, and assert the internal pure rebase classifier accepts them. The
remaining filesystem tests verify syscall/checkpoint ordering and substitution
defenses; the explicit real-exFAT test below verifies the same classification
against the target filesystem.

- [ ] **Step 2: Add workflow outcome and convergence RED tests**

Keep service/publication behavior tests in
`GenotypeWorkbookRevisionServiceTests`:

```swift
func testSchemaThreeCleanupPendingRecoveryFinishesThenPublishesLatestAssignments() throws
func testCommittedCleanupFailureReturnsSuccessWarningAndDoesNotCreateSecondRetiredGeneration() throws
func testPreflightCleanupFailureBlocksWithoutCreatingWorkbookGeneration() throws
func testCleanupPendingWarningPersistenceFailureAfterCommitIsSuccessWarning() throws
func testLegacyManifestWrapperAndPublicOutcomeReturnSameManifest() throws
func testLegacyManifestWrapperReturnsCommittedManifestWhenCleanupRemainsPending() throws
func testRecoveryConvergesBeforeNewGenerationAndAcquiresPublicationLockOnlyOnce() throws
func testEveryWorkbookAttemptWritesIndependentExitStatusAndInputProvenance() throws
func testRealExFATZeroByteCleanupRecoveryWhenExplicitRootProvided() throws
```

exact final-validation race test uses
`PortableExclusiveRename.Operations.afterFinalWitnessValidation`: move the
original zero-byte file aside, install a metadata-identical zero-byte
replacement at the source name, allow `renameat` to detach that replacement,
then assert held-source/tombstone post-rename identity mismatch stops cleanup
before unlink and retains both objects for recovery. This is distinct from the
ordinary before-detach substitution test, which fails at the second source-name
revalidation.

Use the existing `pausedCommittedWorkbookCleanup` fixture for schema-3 state.
Use the service's injected `workbookCleanupFailureInjector` for deterministic
preflight versus finalization outcomes. Low-level fallback substitution is
already deterministic in the LungfishIO tests and is not reimplemented through
an unreachable Workflow closure. The
real-exFAT test must:

```swift
guard let rawRoot = ProcessInfo.processInfo.environment[
    "LUNGFISH_REAL_EXFAT_TEST_ROOT"
] else { throw XCTSkip("Set LUNGFISH_REAL_EXFAT_TEST_ROOT for real exFAT verification.") }
let root = URL(fileURLWithPath: rawRoot, isDirectory: true)
// Create only a UUID child, verify the test owns it, and remove only that child.
```

It creates a disposable workbook fixture containing a zero-byte
`CR1178.unmatched-blast-rescue.tsv`, interrupts after committed manifest,
recovers cleanup, applies a changed manual assignment, and asserts:

- old cleanup state/attestation are retired;
- `finished-committed-cleanup` exists;
- exactly one new workbook revision is created;
- `current.xlsx`, manifest, and provenance hashes agree;
- the new manual label is present in the workbook;
- no retired full generation remains.

- [ ] **Step 3: Add CLI/app RED tests for warning, provenance, and payload validation**

Add:

```swift
// FastqGenotypingCommandTests
func testUpdateCurrentWorkbookCommittedCleanupWarningExitsZeroAndReportsWarningPayload() throws
func testUpdateCurrentWorkbookPreflightCleanupFailureExitsNonzeroAndRecordsAttempt() throws
func testUpdateCurrentWorkbookDecodeFailureRecordsAttemptWithAvailableInputDescriptor() throws
func testUpdateCurrentWorkbookTransformFailureRecordsAttemptAndOpenpyxlRuntime() throws
func testUpdateCurrentWorkbookCleanNoOpRecordsSuccessfulAttempt() throws
func testEachValidBundleTerminalPathCreatesExactlyOneExclusiveAttemptDirectory() throws
func testValidBundleInvalidOptionRecordsExactArgvAndNormalizedCommand() throws

// GenotypeCurrentWorkbookUpdateExecutionServiceTests
func testCommittedWorkbookCleanupWarningCompletesOperationAndReturnsWorkbook() async throws
func testBlockingPreflightRecoveryFailureKeepsOperationFailedAndDoesNotOpenWorkbook() async throws
func testLegacySuccessPayloadWithoutCleanupFieldsRemainsCompatible() async throws
func testMalformedSuccessPayloadFailsOperationWithoutOpeningWorkbook() async throws
func testMismatchedOrEscapingPayloadPathsFailOperationWithoutOpeningWorkbook() async throws
```

The warning payload contract is:

```swift
{
  "bundlePath": "/Volumes/test/analysis.lungfishgenotype",
  "currentWorkbookPath": "/Volumes/test/analysis.lungfishgenotype/artifacts/workbooks/current.xlsx",
  "manifestPath": "/Volumes/test/analysis.lungfishgenotype/manifest.json",
  "cleanupPending": true,
  "warning": "Workbook updated; retired-generation cleanup pending."
}
```

The app test asserts `.completed`, detail
`"Completed — cleanup pending"`, a warning log, and the current workbook output
URL. The blocking test asserts exit nonzero and the exact user-facing sentence
from the spec. The legacy payload contains only the three historical paths and
must decode with `cleanupPending == false`. Malformed JSON, a mismatched bundle
path, a noncanonical current workbook/manifest path, a symlink, or any path
outside the requested bundle must turn an exit-0 process into a failed
operation and must not return/open a workbook.

- [ ] **Step 4: Run all Task 2 tests RED**

Run:

```bash
CLANG_MODULE_CACHE_PATH=/tmp/lungfish-clang-cache SWIFTPM_MODULECACHE_OVERRIDE=/tmp/lungfish-swift-cache \
swift test --disable-sandbox --filter GenotypeWorkbookRevisionServiceTests
CLANG_MODULE_CACHE_PATH=/tmp/lungfish-clang-cache SWIFTPM_MODULECACHE_OVERRIDE=/tmp/lungfish-swift-cache \
swift test --disable-sandbox --filter ONTGenotypeWorkbookCleanupStateTests
CLANG_MODULE_CACHE_PATH=/tmp/lungfish-clang-cache SWIFTPM_MODULECACHE_OVERRIDE=/tmp/lungfish-swift-cache \
swift test --disable-sandbox --filter FastqGenotypingCommandTests
CLANG_MODULE_CACHE_PATH=/tmp/lungfish-clang-cache SWIFTPM_MODULECACHE_OVERRIDE=/tmp/lungfish-swift-cache \
swift test --disable-sandbox --filter GenotypeCurrentWorkbookUpdateExecutionServiceTests
```

Expected: the new tests FAIL because cleanup still compares the pre-rename inode
unconditionally and the revision/CLI/app layers expose only success or thrown
error.

- [ ] **Step 5: Implement witnessed cleanup detach with exact ordering**

In `removeContentsNoFollow`, use this exact regular-file sequence:

1. `openat` the original source name with
   `O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC`, then `fstat` and retain
   that descriptor/metadata.
2. Only after the descriptor exists, invoke the existing
   `before-workbook-cleanup-nondirectory-detach:<path>` injector.
3. Pass the borrowed witness into the reporting rename; its fallback
   exclusively creates and holds the random reservation descriptor, then
   revalidates source name/held source descriptor and reservation name/held
   reservation descriptor immediately before ordinary `renameat`.
4. After rename, require `fstatat(originalName, AT_SYMLINK_NOFOLLOW)` to fail
   with exactly `ENOENT`. Any surviving/reappearing original name is a hard
   failure.
5. `fstat` the still-held source descriptor and `fstatat` the detached path.
   Pass the pre-detach, post-descriptor, and post-path snapshots to an internal
   pure classifier. Require exact post-descriptor/post-path
   device/inode/type agreement. Only then may the narrow
   fallback/regular/zero-byte/stable-metadata rebase allowance choose that
   agreed identity as the tombstone witness.
6. Invoke the existing pre-unlink injector before final validation. Then
   revalidate held source descriptor and tombstone path against the chosen
   tombstone identity.
7. Perform `unlinkat` immediately after that final validation with no injected
   callback, actor hop, allocation hook, or user code between witness and
   unlink. This is the final name-based syscall trust boundary.
8. Close the borrowed cleanup source descriptor only after unlink success or
   the failure path has preserved the entry; retain the primary errno.

Call `renameatxNPReporting(descriptor, source, descriptor, destination,
UInt32(RENAME_EXCL), sourceWitness: witness)`. Preserve exact identity for
native exclusive rename, directories, nonzero files, and metadata changes.
Factor the rebase decision into an internal pure classifier whose inputs are
the `before`, `postDescriptor`, and `postPath` stat snapshots plus mechanism
and original-name absence. For fallback zero-byte regular files, accept an
inode rebase only when:

```swift
outcome.mechanism == .reservationFallback
&& before.st_size == 0
&& detached.st_size == 0
&& sameStableMetadata(before, detached)
&& originalNameIsAbsent
&& sameKernelIdentity(openSourceDescriptor, detachedPathAfterRename)
```

Adopt the agreed post-rename descriptor/path device+inode as the tombstone
witness. Immediately before `unlinkat`, revalidate both descriptor and path
against it. If exFAT leaves the descriptor on the former inode, fail closed.
Never directly unlink the original name and never follow a link. Directories
continue through the existing directory-only traversal. Inode rebasing for
symlinks and special entries remains unsupported, but their existing
exact-identity detach/revalidate/unlink behavior is preserved unchanged; they
cannot enter the new rebase allowance.

- [ ] **Step 6: Introduce an injected, outcome-returning service without breaking callers**

Add:

```swift
public struct GenotypeWorkbookRevisionOutcome: Sendable {
    public let manifest: ONTGenotypeResultBundleManifest
    public let cleanupPendingWarning: String?
    public init(
        manifest: ONTGenotypeResultBundleManifest,
        cleanupPendingWarning: String?
    )
}

public func applyHaplotypeOverridesWithOutcome(
    _ calls: [GenotypeWorkbookHaplotypeCall],
    annotationSidecarURL: URL?,
    into bundleURL: URL,
    annotationOnly: Bool = false,
    includedLoci: [String] = [],
    fingerprintInputs: GenotypeWorkbookFingerprintInputs? = nil,
    provenanceContext: GenotypeWorkbookRevisionProvenanceContext? = nil,
    projectionMode: GenotypeWorkbookHaplotypeProjectionMode = .haplotyped,
    attempt: GenotypeWorkbookUpdateAttemptHandle? = nil
) throws -> GenotypeWorkbookRevisionOutcome
```

Keep the existing argument-for-argument
`applyHaplotypeOverrides` method returning
`ONTGenotypeResultBundleManifest` as a source-compatible wrapper that calls
`applyHaplotypeOverridesWithOutcome` and returns `.manifest`. In the outcome
method:

- add a service initializer property
  `workbookCleanupFailureInjector: (@Sendable (String) throws -> Void)?`;
  pass it to both the initial
  `recoverIfNeededAssumingLock(for:attestationRootURL:cleanupFailureInjector:)`
  preflight and
  `finalizeCommittedTransactionAssumingLock(_:for:attestationRootURL:cleanupFailureInjector:)`;
  do not acquire a second workbook publication lock in either route;
- preflight `recoverIfNeededAssumingLock` failure throws the expanded blocking
  explanation and creates no stage/generation;
- once the revised manifest is durably committed, catch both structured
  `.cleanupPendingWarning` and
  `.cleanupPendingWarningPersistenceFailure`, return the committed manifest plus
  `"Workbook updated; retired-generation cleanup pending."`, and retain cleanup
  state;
- the same two errors during preflight remain blocking/nonzero because this
  invocation has not committed a workbook;
- do not begin a new publication while a cleanup-pending generation exists;
- a later successful preflight recovery writes the normal terminal receipt,
  retires state/attestation, then proceeds with the newest inputs.

Tests inject failure at a preflight cleanup checkpoint before staging and at a
finalization cleanup checkpoint after `finalManifestCommitted = true`; they
assert deterministic nonzero versus exit-0 behavior. The convergence test
counts lock acquisition, stage creation, cleanup state, quarantine generations,
and revisions: one lock acquisition, no stage/new generation on blocked
preflight, complete state retirement before the next stage, exactly one new
revision after recovery, and no cleanup-pending artifacts afterward. Add a
public-client compile/use assertion for both outcome properties and a legacy
wrapper test proving identical manifest/error behavior for unaffected callers.
Also test the wrapper's intentionally lossy post-commit warning behavior:
because its return type cannot express a warning, it returns the committed
manifest while cleanup-pending state remains available for the next preflight
recovery; it must not convert that committed success into a throw.
The CLI passes its public attempt handle into the outcome method; the service
adds manifest/source-workbook/reviewable-catalog descriptors, Python/openpyxl
runtime identity, and committed outputs as they become available. Legacy/app
callers omit it via the default nil without changing behavior.

- [ ] **Step 7: Record every valid-bundle command attempt with complete provenance**

Implement:

```swift
struct GenotypeWorkbookUpdateAttemptReceipt: Codable, Sendable {
    let schemaVersion: Int
    let attemptID: String
    let startedAt: Date
    let completedAt: Date
    let wallTimeSeconds: Double
    let argv: [String]
    let reproducibleCommand: String
    let resolvedOptions: [String: String]
    let runtimeIdentity: [String: String]
    let attemptedInputPaths: [String]
    let inputs: [ProvenanceFileDescriptor]
    let outputs: [ProvenanceFileDescriptor]
    let exitStatus: Int
    let stderr: String?
    let cleanupPendingWarning: String?
}
```

Make `GenotypeWorkbookUpdateAttemptRecorder` and its begin/finalize handle
public in `LungfishWorkflow`, so the CLI—not a test-only private helper—owns the
whole invocation lifecycle. Refactor `run`/`runResolved` so the CLI resolves and
validates the bundle path first, starts the attempt immediately afterward, and
only then validates every other command option (including attestation options),
resolves the managed Python/openpyxl runtime, or opens/decodes calls and
annotations. An invalid
non-bundle target has no safe bundle authority and does not create a receipt;
every invocation whose target is a valid bundle does.

```swift
let attempt = try recorder.begin(
    bundleURL: bundleURL,
    argv: argvProvider(), // CommandLine.arguments in production
    attemptedInputPaths: rawAttemptedInputPaths
)
try attempt.recordResolvedOptions(resolvedAttemptOptions)
```

Inject the argv provider in tests; production passes exact, unmodified
`CommandLine.arguments`. The recorder stores both that argv array and a
normalized, shell-escaped reproducible command derived from it. Tests assert
exact argv preservation, deterministic command normalization, and that invalid
options for an otherwise valid bundle still create exactly one exit-1 attempt
receipt. Call `recordResolvedOptions` only after validation succeeds; failed
validation still finalizes the already-started receipt with the raw attempted
paths and available option diagnostics.

The handle records start time and a UUID attempt ID. Exactly one terminal call
must occur on every path: immutable input open/read failure, JSON decode or
semantic validation failure, preflight recovery failure, Python/openpyxl
transform failure, unchanged clean no-op, fully clean publication,
committed-cleanup warning (including warning-persistence failure), and
cancellation. `defer` asserts finalization happened; a secondary provenance
failure is surfaced as a blocking provenance defect while preserving the
primary error text in stderr.

The recorder writes the JSON receipt and a
`ProvenanceEnvelope` under
`artifacts/workbooks/updates/attempts/<attempt-id>/`. Use
an exclusively created UUID directory (`mkdirat`, mode 0700, retry a UUID
collision; never replace an existing attempt), `DurableAtomicFileStore`, and
sorted JSON. Record:

- exact `CommandLine.arguments` (or the test-injected equivalent) and the
  normalized, shell-escaped reproducible command;
- all explicit options plus resolved defaults: annotation path/absence,
  `annotationOnly`, projection mode, ordered included loci, sync intent,
  fingerprint and schemas, reviewable-row catalog options;
- CLI tool name/version, app version/build, source/git commit when embedded,
  OS/kernel/architecture, process/runtime identity, managed Python executable,
  conda environment/prefix, Python and openpyxl versions when resolution
  succeeds;
- attempted input paths even when open/decode fails, plus immutable
  `ProvenanceFileDescriptor` path/size/SHA-256 for every successfully read
  calls, annotation, fingerprint catalog, source workbook, and manifest input;
- final workbook, manifest, warning/terminal receipt, and scientific
  provenance output descriptors when they exist;
- start/completion, wall time, exit status, useful stderr, and the
  cleanup-pending warning.

A failed preflight retry gets its own exit-1 record; decode and transform
failures get independent exit-1 records; a clean no-op and committed warning
record exit 0. Do not rewrite or contradict the prior transaction/scientific
revision provenance.

- [ ] **Step 8: Wire CLI and Operations semantics with validated payloads**

Have `FastqUpdateCurrentWorkbookSubcommand` call the outcome API, emit the
warning to stderr at `[100%]`, encode optional
`cleanupPending`/`warning`, finalize attempt provenance, and return normally for
either committed cleanup warning. On any failure, finalize the same attempt
with exit 1 before throwing.

Decode stdout in `GenotypeCurrentWorkbookUpdateExecutionService` with a
backward-compatible payload whose warning fields default to false/nil. Require
valid JSON after trimming process chatter, then validate without following
links:

```swift
payload.bundlePath.standardizedFileURL == requestedBundle.standardizedFileURL
payload.currentWorkbookPath == canonicalCurrentWorkbookPathInsideRequestedBundle
payload.manifestPath == canonicalManifestPathInsideRequestedBundle
```

Require both output files to be regular, nonsymlink entries beneath the
requested bundle. Reject malformed JSON, missing historical fields, mismatch,
path traversal, symlink, and outside paths even when the process exits zero.
Do not complete the Operation or return/open a workbook on rejection. When a
validated payload has `cleanupPending == true`,
complete the operation with detail `"Completed — cleanup pending"`, log
`"Workbook updated; retired-generation cleanup pending."`, and return the
workbook URL.

- [ ] **Step 9: Add the hardened real-exFAT runner**

Create an executable script that requires an explicit scratch root:

```bash
#!/bin/bash
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(git -C "$script_dir/.." rev-parse --show-toplevel)"
cd "$repo_root"
mkdir -p /tmp/lungfish-clang-cache /tmp/lungfish-swift-cache
test_root="${LUNGFISH_EXFAT_TEST_ROOT:?Set LUNGFISH_EXFAT_TEST_ROOT to a disposable directory on exFAT}"
root_real="$(cd "$test_root" && pwd -P)"
[[ "$root_real" != / && "$root_real" != "$repo_root" ]]
[[ "$root_real" != *.lungfish && "$root_real" != *.lungfishgenotype ]]
[[ -d "$root_real" && ! -L "$test_root" ]]
[[ "$(stat -f '%u' "$root_real")" == "$(id -u)" ]]
filesystem="$(diskutil info "$root_real" | awk -F: '/File System Personality/ {gsub(/^[ \t]+/, "", $2); print $2}')"
[[ "$filesystem" == ExFAT* ]] || { echo "Not exFAT: $filesystem" >&2; exit 64; }
scratch="$(mktemp -d "$root_real/lungfish-workbook-recovery.XXXXXX")"
scratch_real="$(cd "$scratch" && pwd -P)"
[[ "$(dirname "$scratch_real")" == "$root_real" ]]
[[ "$(basename "$scratch_real")" == lungfish-workbook-recovery.* ]]
[[ "$(stat -f '%u' "$scratch_real")" == "$(id -u)" ]]
cleanup() {
  [[ -n "${scratch_real:-}" && -d "$scratch_real" && ! -L "$scratch_real" ]]
  [[ "$(dirname "$scratch_real")" == "$root_real" ]]
  [[ "$(basename "$scratch_real")" == lungfish-workbook-recovery.* ]]
  [[ "$(stat -f '%u' "$scratch_real")" == "$(id -u)" ]]
  rm -rf -- "$scratch_real"
}
trap cleanup EXIT
LUNGFISH_REAL_EXFAT_TEST_ROOT="$scratch" \
CLANG_MODULE_CACHE_PATH=/tmp/lungfish-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/lungfish-swift-cache \
swift test --disable-sandbox \
  --filter GenotypeWorkbookRevisionServiceTests/testRealExFATZeroByteCleanupRecoveryWhenExplicitRootProvided
```

The XCTest independently resolves the passed scratch root, rejects root,
symlink, non-owned, or bundle-suffixed paths, uses `statfs` to require an actual
`exfat` filesystem, creates its own nested
`lungfish-xctest-<UUID>` directory with exclusive ownership, places the entire
fixture beneath that nested directory, and deletes only that nested UUID after
verifying exact parent containment and ownership. The script then removes only
its separately verified scratch directory. Neither layer accepts a
`.lungfish`/`.lungfishgenotype` path.

- [ ] **Step 10: Run GREEN verification, including convergence**

Run the four Task 2 filters again. Then, with user-authorized access to a
disposable directory on the affected mounted volume:

```bash
LUNGFISH_EXFAT_TEST_ROOT=/Volumes/iWES_WNPRC/.lungfish-exfat-verification \
  ./scripts/verify-workbook-cleanup-exfat.sh
```

Expected: all filters PASS; the real exFAT test proves its fixture's `statfs`
type is exFAT and exits 0; XCTest removes only its nested UUID and the runner
removes only its verified scratch child. Workflow convergence assertions prove
cleanup state is terminal before one subsequent revision, no second retired
generation exists, and publication lock acquisition never self-conflicts.
Never point either layer at or modify
`/Volumes/iWES_WNPRC/32355/32355.lungfish`.

- [ ] **Step 11: Commit**

```bash
git add Sources/LungfishIO/Bundles/ONTGenotypeWorkbookCleanupState.swift \
  Sources/LungfishIO/Bundles/ONTGenotypeWorkbookUpdateTransaction.swift \
  Sources/LungfishWorkflow/ONTGenotyping/GenotypeWorkbookRevisionService.swift \
  Sources/LungfishWorkflow/ONTGenotyping/GenotypeWorkbookUpdateAttemptRecorder.swift \
  Sources/LungfishCLI/Commands/FastqUpdateCurrentWorkbookSubcommand.swift \
  Sources/LungfishApp/Services/GenotypeCurrentWorkbookUpdateExecutionService.swift \
  Tests/LungfishIOTests/ONTGenotypeWorkbookCleanupStateTests.swift \
  Tests/LungfishWorkflowTests/GenotypeWorkbookRevisionServiceTests.swift \
  Tests/LungfishCLITests/FastqGenotypingCommandTests.swift \
  Tests/LungfishAppTests/GenotypeCurrentWorkbookUpdateExecutionServiceTests.swift \
  scripts/verify-workbook-cleanup-exfat.sh
git commit -m "fix: recover workbook cleanup safely on exfat"
```

### Task 3: Clear, collapsed manual-haplotype disclosure

**Files:**
- Modify: `Sources/LungfishGenotypeUI/GenotypeManualHaplotypeAssignmentBand.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeResultDisplayState.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeComparisonMatrixView.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeResultViewController.swift`
- Test: `Tests/LungfishGenotypeUITests/GenotypeManualHaplotypeAccessibilityTests.swift`
- Test: `Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift`

- [ ] **Step 1: Add disclosure RED tests**

Add:

```swift
func testDisclosureNamesManualHaplotypesSevenLociAndExplainsRows() throws
func testNewBundleStartsCollapsedAndExpansionRemainsWindowBundlePresentationState() throws
func testCollapseRemovesSevenRowsAndPreservesSemanticViewportState() throws
func testDisclosureLabelWrapsAtTwoHundredPercentTextWithoutClipping() throws
```

Assert exact label `"Manual haplotypes (7 loci)"`, exact accessibility help
from the spec, Space/Return and accessibility press toggling, one-row collapsed
height versus eight-row expanded height, and no annotation-sidecar/audit write.
Capture top row ID/within-row offset, selected targets, horizontal leading
sample/offset, sort, filter, and visibility before both transitions and assert
equality afterward.

- [ ] **Step 2: Run RED**

Run:

```bash
CLANG_MODULE_CACHE_PATH=/tmp/lungfish-clang-cache SWIFTPM_MODULECACHE_OVERRIDE=/tmp/lungfish-swift-cache \
swift test --disable-sandbox --filter GenotypeManualHaplotypeAccessibilityTests
CLANG_MODULE_CACHE_PATH=/tmp/lungfish-clang-cache SWIFTPM_MODULECACHE_OVERRIDE=/tmp/lungfish-swift-cache \
swift test --disable-sandbox --filter GenotypeResultViewportTests/testNewBundleStartsCollapsed
```

Expected: FAIL because the current label is `Haplotype Assignments` and the
default display state is expanded.

- [ ] **Step 3: Implement presentation-only disclosure**

Set `GenotypeResultDisplayState.manualHaplotypeBandExpanded = false`. In
`GenotypeResultViewController.configure`, change the store lookup fallback from:

```swift
manualHaplotypeBandDisclosureStore?.expansion(for: result.bundleURL) ?? true
```

to:

```swift
manualHaplotypeBandDisclosureStore?.expansion(for: result.bundleURL) ?? false
```

Update the nearby comment to say a newly viewed eligible bundle is collapsed
and only an existing window/bundle presentation entry restores expansion.
Retain the existing window-owned, bundle-keyed
`GenotypeManualHaplotypeBandDisclosureStore` without persistence to annotations.
Configure one disclosure button:

```swift
title = "Manual haplotypes (7 loci)"
setAccessibilityLabel("Manual haplotypes (7 loci)")
setAccessibilityHelp(
  "Shows seven locus-level manual haplotype assignment rows below the sample names."
)
```

Use `GenotypeManualHaplotypeHeaderLayout.manualHeight` to remove all seven row
heights when collapsed. Wrap the label, include the triangle and label in one
hit/focus target, and route Space/Return to `performClick`. Around the header
height transition, use the existing semantic anchor capture/restore helpers so
selection, top row, horizontal anchor, sort, and filters do not move.

- [ ] **Step 4: Run GREEN and commit**

Run both Task 3 filters; expected PASS.

```bash
git add Sources/LungfishGenotypeUI/GenotypeManualHaplotypeAssignmentBand.swift \
  Sources/LungfishGenotypeUI/GenotypeResultDisplayState.swift \
  Sources/LungfishGenotypeUI/GenotypeComparisonMatrixView.swift \
  Sources/LungfishGenotypeUI/GenotypeResultViewController.swift \
  Tests/LungfishGenotypeUITests/GenotypeManualHaplotypeAccessibilityTests.swift \
  Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift
git commit -m "feat: collapse manual haplotype matrix rows"
```

### Task 4: Transient sample-column auto-fit

**Files:**
- Modify: `Sources/LungfishGenotypeUI/GenotypeManualHaplotypeAssignmentBand.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeComparisonMatrixView.swift`
- Test: `Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift`
- Test: `Tests/LungfishGenotypeUITests/GenotypeManualHaplotypePerformanceTests.swift`

- [ ] **Step 1: Add auto-fit RED tests**

Add:

```swift
func testExpandedBandAutoFitsEachSampleToWidestCompleteAssignmentPair() throws
func testAutoFitNeverOverwritesStoredUserPreferredWidth() throws
func testCollapseRestoresUserOrHeaderWidth() throws
func testTypographyRemeasuresAllVisibleSamplesOnceAndSaveRemeasuresOnlyChangedSample() throws
func testSingleSaveRemeasuresOnlyChangedSample() throws
func testTypingDraftDoesNotResizeColumnsOrRebuildProjection() throws
```

Use a 128-scalar label and assert the full `H1 · H2` attributed-string width
plus six-point cell insets fits. Resize a sample manually, expand/collapse, and
assert the preferred baseline remains unchanged. Instrument measurement counts,
column rebuild count, and projection count.

- [ ] **Step 2: Run RED**

Run:

```bash
CLANG_MODULE_CACHE_PATH=/tmp/lungfish-clang-cache SWIFTPM_MODULECACHE_OVERRIDE=/tmp/lungfish-swift-cache \
swift test --disable-sandbox --filter GenotypeResultViewportTests/testExpandedBandAutoFits
CLANG_MODULE_CACHE_PATH=/tmp/lungfish-clang-cache SWIFTPM_MODULECACHE_OVERRIDE=/tmp/lungfish-swift-cache \
swift test --disable-sandbox --filter GenotypeManualHaplotypePerformanceTests/testSingleSaveRemeasuresOnlyChangedSample
```

Expected: FAIL because assignment text is currently truncated inside the
existing column width and auto-fit/user width are not distinct.

- [ ] **Step 3: Implement measurement and transient minima**

Add a value-semantic measurement helper:

```swift
struct GenotypeManualHaplotypeColumnMeasurement {
    static func requiredWidth(
        values: [String],
        sampleTitle: String,
        retainedReadTitle: String?,
        font: NSFont,
        headerFont: NSFont,
        inset: CGFloat = 6
    ) -> CGFloat
}
```

Keep the existing `sampleColumnWidthsByStableID` as the sole user-preferred
baseline. Do not add or rename a second user-width dictionary. Add only the
transient measurement dictionary:

```swift
private var manualHaplotypeTransientMinimumWidths: [String: CGFloat] = [:]
```

The effective width is:

```swift
max(headerWidth, sampleColumnWidthsByStableID[sample] ?? 68,
    displayState.manualHaplotypeBandExpanded
      ? manualHaplotypeTransientMinimumWidths[sample] ?? 0 : 0)
```

Do not assign programmatic auto-fit widths through
`captureStableSampleColumnState`; guard with
`isApplyingManualHaplotypeAutoFit`. Put that guard at the top of the entire
`tableViewColumnDidResize` production callback, before
`captureColumnTypographyBaselines`, `captureStableSampleColumnState`, geometry
updates, or persistence, so programmatic width notifications cannot contaminate
either typography or user baselines. Expansion and typography changes make one
`O(visible samples × 7)` pass. `applyManualHaplotypeAssignments` measures only
`changedSamples`. Editor keystrokes do nothing because only successful
persistence invokes that method. Recompute band geometry without rebuilding
columns/projection.

- [ ] **Step 4: Run GREEN and commit**

Run the two named tests plus
`GenotypeManualHaplotypePerformanceTests`; expected PASS.

```bash
git add Sources/LungfishGenotypeUI/GenotypeManualHaplotypeAssignmentBand.swift \
  Sources/LungfishGenotypeUI/GenotypeComparisonMatrixView.swift \
  Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift \
  Tests/LungfishGenotypeUITests/GenotypeManualHaplotypePerformanceTests.swift
git commit -m "feat: auto-fit expanded manual haplotype columns"
```

### Task 5: Exact-order evidence, explanatory support status, and visible export

**Files:**
- Modify: `Sources/LungfishGenotypeUI/GenotypeSampleCurationWorkbenchView.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeSupportedAllelesPanel.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeManualHaplotypeEditor.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeResultViewController.swift`
- Test: `Tests/LungfishGenotypeUITests/GenotypeSupportedAllelesPanelTests.swift`
- Test: `Tests/LungfishGenotypeUITests/GenotypeManualHaplotypeAccessibilityTests.swift`
- Test: `Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift`

- [ ] **Step 1: Add workbench refinement RED tests**

Add:

```swift
func testEvidenceRowsUseExactCurrentMatrixOrderWithoutSecondSort() throws
func testEvidenceTableContainsOnlyAlleleAndReadSupport() throws
func testEvidenceRetainsProvisionalExonTwoAndAnnotationPresentation() throws
func testCallSupportCheckStatesAndExplanationMatchThresholdContract() throws
func testPublishedSelectedSampleStateRowsUseCallSupportCheckAndTwoColumnEvidence() throws
func testExportAllHaplotypeAssignmentsIsVisibleSecondaryActionWithExistingCallback() throws
func testWideWorkbenchFillsAvailableWidthWithoutEditorCapOrDeadCenterGap() throws
```

Feed evidence in deliberately non-locus/non-read order and assert the rendered
accessibility sequence is unchanged. Assert exact row accessibility:
`"Mafa-A1*018:01:01:01, read support 712."` Assert no visible/accessibility
headers for Locus, Alignments, or Support. Test threshold boundaries
999/1,000 retained reads and 19/20 alignments plus zero calls.

- [ ] **Step 2: Run RED**

Run:

```bash
CLANG_MODULE_CACHE_PATH=/tmp/lungfish-clang-cache SWIFTPM_MODULECACHE_OVERRIDE=/tmp/lungfish-swift-cache \
swift test --disable-sandbox --filter GenotypeSupportedAllelesPanelTests
CLANG_MODULE_CACHE_PATH=/tmp/lungfish-clang-cache SWIFTPM_MODULECACHE_OVERRIDE=/tmp/lungfish-swift-cache \
swift test --disable-sandbox --filter GenotypeResultViewportTests/testEvidenceRowsUseExactCurrentMatrixOrder
CLANG_MODULE_CACHE_PATH=/tmp/lungfish-clang-cache SWIFTPM_MODULECACHE_OVERRIDE=/tmp/lungfish-swift-cache \
swift test --disable-sandbox --filter GenotypeManualHaplotypeAccessibilityTests/testExportAllHaplotypeAssignments
```

Expected: FAIL because the controller applies a second sort, five columns are
rendered, `QC: OK` is unexplained, export is a one-item menu, and the editor is
capped at 640 points.

- [ ] **Step 3: Simplify evidence and preserve matrix order**

Change the presentation contract to:

```swift
struct GenotypeSupportedAllelePresentation: Identifiable, Equatable {
    let id: String
    let allele: String
    let readSupport: String
    var accessibilityLabel: String {
        "\(allele), read support \(readSupport)."
    }
}
```

Keep preview limit 12 and the separate virtualized all-rows popover. Render only
`Allele` and right-aligned `Read support`; compact rows use the same two values.
Delete `sortedVisibleSampleAlleleDetails`; consume
`comparisonMatrix.visibleSampleAlleleDetails(sample:)` directly. Preserve the
existing `alleleDisplayLabel` path so candidate, extension, annotation, and
`Provisional exon 2` presentation survives.

Update both the visible selected-sample workbench and the published
`GenotypeResultSelectionState.detailRows` assembled by
`showSingleSampleColumnSelection`. Replace old `QC`, Locus, Unique Reads,
Alignments, and Support state rows with `Call-support check` plus the same
ordered Allele / Read support pairs exposed visually. This keeps Inspector and
accessibility/selection consumers consistent with the bottom pane.

- [ ] **Step 4: Replace QC with the support-check model and explanation**

Add:

```swift
enum GenotypeCallSupportCheck: Equatable {
    case meetsThresholds, lowSupport, reviewNeeded
    static func evaluate(callCount: Int, retainedReads: Int, alignments: Int) -> Self
    var title: String
    var explanation: String
}
```

Evaluate from full sample totals, not the currently filtered evidence
projection:

```swift
let sampleCallCount = result.calls.lazy.filter { $0.sample == sample }.count
let check = GenotypeCallSupportCheck.evaluate(
    callCount: sampleCallCount,
    retainedReads: summary.passedUniqueReads,
    alignments: summary.passedAlignments
)
```

Search, thresholds, row visibility, and matrix sorting must not change this
sample-total check. Candidate/evidence preview row count is not `callCount`.
Use exact titles `Meets thresholds`, `Low support`, and `Review needed`.
Render metric label `Call-support check`; place the full explanation visibly
below the metrics with wrapping and use the same text as accessibility help.
State explicitly that the check is not analyst approval or confirmation that
haplotype assignments are correct.

- [ ] **Step 5: Fix workbench width and export**

Remove the side-by-side `assignmentView.width <= 640` constraint. Keep minimum
420, evidence minimum 300, and preferred 62/38 distribution so both regions
fill available width. Replace the pop-up menu with a visible secondary button:

```swift
Button("Export All Haplotype Assignments…") { model.export() }
    .accessibilityIdentifier("manual-haplotype-export-all")
```

Keep the existing `onExport -> exportManualDefinitions()` provenance-producing
path unchanged. A mounted test clicks the visible button once and asserts the
existing callback fires exactly once. Do not add a second export implementation,
attempt recorder, or provenance envelope; the existing export callback remains
the sole provenance authority.

- [ ] **Step 6: Run GREEN and commit**

Run all three Task 5 filters; expected PASS.

```bash
git add Sources/LungfishGenotypeUI/GenotypeSampleCurationWorkbenchView.swift \
  Sources/LungfishGenotypeUI/GenotypeSupportedAllelesPanel.swift \
  Sources/LungfishGenotypeUI/GenotypeManualHaplotypeEditor.swift \
  Sources/LungfishGenotypeUI/GenotypeResultViewController.swift \
  Tests/LungfishGenotypeUITests/GenotypeSupportedAllelesPanelTests.swift \
  Tests/LungfishGenotypeUITests/GenotypeManualHaplotypeAccessibilityTests.swift \
  Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift
git commit -m "feat: refine manual haplotype evidence workbench"
```

### Task 6: Stable-identity comparison model

**Files:**
- Create: `Sources/LungfishGenotypeUI/GenotypeSampleComparisonModel.swift`
- Create: `Tests/LungfishGenotypeUITests/GenotypeSampleComparisonModelTests.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeComparisonMatrixView.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeManualHaplotypeEditor.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeResultViewController.swift`

- [ ] **Step 1: Add comparison-model RED tests**

Create tests:

```swift
func testUnionKeepsTargetMatrixOrderThenAppendsSourceOnlyMatrixOrder()
func testStableRowIdentityNotDisplayLabelDeterminesSharedRelationship()
func testFalseNegativeUsesFNAndAnnotationsHaveTextIndicatorsAndAccessibleLabels()
func testSelectorIncludesHiddenSamplesAndExcludesCurrentSample()
func testSourceSearchUsesCachedCandidatesWithoutBuildingEveryComparison()
func testSelectingOneSourceBuildsOnlyOneVisibleRowComparison()
func testCopyStagesAllFourteenSlotsIncludingBlanksWithoutSaving()
func testDirtyDraftRequiresNamedConfirmationAndCancelIsByteForByteNoOp()
func testPendingSourceIsRetainedAcrossConfirmationAndConfirmStagesExactlyOnce()
func testStagedStatusIsVisibleAndClearsOnlyOnNextSourceOrSave()
```

Include duplicate display labels with different candidate cluster IDs, source
false-negative with no reads, target false-positive and comment, hidden source
sample, and blank source slots.

- [ ] **Step 2: Run RED**

Run:

```bash
CLANG_MODULE_CACHE_PATH=/tmp/lungfish-clang-cache SWIFTPM_MODULECACHE_OVERRIDE=/tmp/lungfish-swift-cache \
swift test --disable-sandbox --filter GenotypeSampleComparisonModelTests
```

Expected: FAIL because the comparison model/types do not exist.

- [ ] **Step 3: Define the ordered evidence and comparison contracts**

Implement:

```swift
struct GenotypeSampleEvidenceRow: Identifiable, Equatable, Sendable {
    struct Indicators: OptionSet, Equatable, Sendable {
        let rawValue: UInt8
        static let falsePositive = Indicators(rawValue: 1 << 0)
        static let falseNegative = Indicators(rawValue: 1 << 1)
        static let comment = Indicators(rawValue: 1 << 2)
    }
    let id: GenotypeCandidateMatrixRowID
    let allele: String
    let readSupport: Int?
    let indicators: Indicators
    let accessibilityLabel: String
}

struct GenotypeSampleComparisonRow: Identifiable, Equatable, Sendable {
    enum Relationship: Equatable, Sendable { case shared, targetOnly, sourceOnly }
    let id: GenotypeCandidateMatrixRowID
    let allele: String
    let targetReadSupport: String  // count, FN, or —
    let sourceReadSupport: String
    let relationship: Relationship
    let indicatorSummary: String?
}
```

Expose
`comparisonMatrix.visibleSampleEvidenceRows(sample:)` in exact current
`visibleRows` order. Include an unsupported row only for an applicable false
negative. Resolve FP/FN/comment indicators from current matrix indexes. Do not
sort in the controller.

- [ ] **Step 4: Implement lazy source selection and staging state**

Implement `@MainActor final class GenotypeSampleComparisonModel:
ObservableObject` with:

```swift
init(targetSample: String,
     targetRows: [GenotypeSampleEvidenceRow],
     candidates: [GenotypeManualHaplotypeEditorModel.CopyCandidate],
     rowsForSource: @escaping (String) -> [GenotypeSampleEvidenceRow],
     isDraftDirty: @escaping () -> Bool,
     stageAssignments: @escaping (String) -> Void)
func updateSearch(_ query: String)
func selectSource(_ sample: String?)
func requestUseAssignments()
func confirmUseAssignments()
func cancelUseAssignments()
func refreshTargetRows(_ rows: [GenotypeSampleEvidenceRow])
```

Precompute only normalized candidate search keys/completeness. Build the union
for the selected source only using ID dictionaries:

```swift
let targetIDs = Set(targetRows.map(\.id))
let orderedIDs = targetRows.map(\.id)
    + sourceRows.lazy.map(\.id).filter { !targetIDs.contains($0) }
```

Use the existing typed `GenotypeCandidateMatrixRowID` end-to-end; do not
serialize a second `"candidate:"`/`"known:"` string identity in the UI model.
The factual summary counts shared/target-only/source-only. Read dirty state only
through the injected `isDraftDirty` closure at request time. If dirty, retain a
typed pending-copy state containing the exact selected source and publish
confirmation text naming that source and stating all fourteen slots, including
blanks, replace the draft. Cancel sets pending state to nil and must not call
any draft method. Confirm atomically consumes the retained pending source before
calling the staging closure, so repeated button/dialog actions stage exactly
once. Confirm invokes the existing `copyAssignments(from:)`, sets a published,
visibly rendered status
`"Assignments staged from \(source)."`, and does not call save, sidecar, CLI, or
matrix projection. A clean draft stages directly through the same one-shot
consume path. Selecting another source or completing Save clears the status;
responsive layout and evidence refresh do not.

- [ ] **Step 5: Run GREEN and commit**

Run the model filter and the existing
`GenotypeManualHaplotypeEditorTests`; expected PASS.

```bash
git add Sources/LungfishGenotypeUI/GenotypeSampleComparisonModel.swift \
  Sources/LungfishGenotypeUI/GenotypeComparisonMatrixView.swift \
  Sources/LungfishGenotypeUI/GenotypeManualHaplotypeEditor.swift \
  Sources/LungfishGenotypeUI/GenotypeResultViewController.swift \
  Tests/LungfishGenotypeUITests/GenotypeSampleComparisonModelTests.swift
git commit -m "feat: model evidence-aware haplotype comparison"
```

### Task 7: Responsive Compare & Copy workbench UI

**Files:**
- Create: `Sources/LungfishGenotypeUI/GenotypeSampleComparisonPanel.swift`
- Create: `Tests/LungfishGenotypeUITests/GenotypeSampleComparisonPanelTests.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeSampleCurationWorkbenchView.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeManualHaplotypeEditor.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeResultViewController.swift`
- Test: `Tests/LungfishGenotypeUITests/GenotypeManualHaplotypeAccessibilityTests.swift`
- Test: `Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift`

- [ ] **Step 1: Add mounted comparison UI RED tests**

Add:

```swift
func testCompareAndCopyActionSwitchesTrailingPaneWithoutRemountingEditor()
func testSourceSelectorIsSearchableKeyboardNavigableAndShowsCompleteness()
func testComparisonTableUsesWordsAndIndicatorsInMatrixOrder()
func testCompactAndTwoHundredPercentRowsReflowWithoutChangingControlIdentity()
func testUseAssignmentsStagesOnlyAfterDirtyDraftConfirmation()
func testCancellingDirtyConfirmationPreservesDraftExactly()
func testEvidenceRefreshPreservesEditorDraftIdentityAndFocus()
func testSortSearchThresholdAndManualVisibilityEachRefreshEvidenceWithoutRemount()
func testEvidenceCompareEvidenceCycleKeepsBothModeTreesAndControlsIdentical()
func testTwoHundredPercentModeCyclePreservesSelectorUseButtonDraftAndFocus()
```

Mount at widths 420, 779, 841, 1,200, and at 200% content text. Assert the
source selector, comparison model, Use button, assignment model, and actual
combo-box object identities remain stable across reflow. Assert Shared is
visible text, absent is `—`, false negative is `FN`, and accessibility includes
every FP/FN/comment meaning.

- [ ] **Step 2: Run RED**

Run:

```bash
CLANG_MODULE_CACHE_PATH=/tmp/lungfish-clang-cache SWIFTPM_MODULECACHE_OVERRIDE=/tmp/lungfish-swift-cache \
swift test --disable-sandbox --filter GenotypeSampleComparisonPanelTests
```

Expected: FAIL because the panel and workbench mode do not exist.

- [ ] **Step 3: Build one stable trailing-pane controller**

Implement:

```swift
@MainActor
final class GenotypeSampleCurationTrailingModel: ObservableObject {
    enum Mode: Equatable { case evidence, compareAndCopy }
    @Published var mode: Mode = .evidence
    @Published private(set) var evidenceSnapshot: GenotypeSupportedAllelesSnapshot
    let comparison: GenotypeSampleComparisonModel
    func refreshEvidence(
        target: GenotypeSupportedAllelesSnapshot,
        comparisonTargetRows: [GenotypeSampleEvidenceRow],
        selectedSourceRows: [GenotypeSampleEvidenceRow]?
    )
}
```

`GenotypeSampleComparisonPanel` renders a mode picker/header, searchable source
selector, completeness, factual summary, virtualized union list, and
`Use [sample] Assignments`. Use a custom SwiftUI `Layout`
(`GenotypeSampleComparisonRowLayout`) to place the same allele, relationship,
target support, and source support subviews in columns or stacked rows. Do not
use `ViewThatFits`, duplicate compact/wide branches, or separate selectors.
Allele labels wrap. Each row combines visible text/icon annotation indicators
with a complete accessibility label. Use a confirmation dialog bound to the
model's pending confirmation; Cancel performs no mutation.

Mount Evidence and Compare & Copy once in a single stable trailing
`NSHostingView` and keep both SwiftUI mode trees alive in a clipped overlay.
Only the active tree supplies the container's measured height; the inactive
tree remains mounted at opacity zero and is disabled, non-hit-testable, and
accessibility-hidden (`disabled(true)`, `allowsHitTesting(false)`,
`accessibilityHidden(true)`) rather than conditionally destroyed. Width and
200% typography changes only change the custom Layout's
placements; selector, Use button, mode control, comparison model, assignment
editor, draft, and focused `NSComboBox` identities remain stable through
Evidence → Compare & Copy → Evidence cycles.

- [ ] **Step 4: Wire the workbench and editor action**

Replace editor label `Copy from Sample…` with `Compare & Copy…`; its callback
sets trailing mode `.compareAndCopy` rather than copying. The trailing pane
defaults to Evidence and offers a clear Back to Evidence action. The controller
passes all other analysis samples—including hidden columns—as selector
candidates, while `rowsForSource` queries only the selected source against the
current matrix row projection. Add one matrix callback:

```swift
var onVisibleProjectionChanged: (() -> Void)?
```

Invoke it after every committed visible-projection change: sort descriptor,
native/shared search, minimum reads, minimum percent/basis, locus/quick filter,
manual row visibility, and manual sample visibility. Invoke only after
`visibleRows`/indexes settle, never per keystroke before the committed search
projection. The controller responds by calling the persistent trailing model's
`refreshEvidence`; it updates the published evidence snapshot, target
comparison rows, and only the currently selected source rows. It must not
replace the hosting view, trailing model, comparison model, editor model, or
draft. Tests drive sort, search, threshold, and manual visibility separately
and assert new exact matrix ordering plus stable host/editor/combo identity and
focus after each trigger.

- [ ] **Step 5: Run GREEN and integration tests**

Run:

```bash
CLANG_MODULE_CACHE_PATH=/tmp/lungfish-clang-cache SWIFTPM_MODULECACHE_OVERRIDE=/tmp/lungfish-swift-cache \
swift test --disable-sandbox --filter GenotypeSampleComparisonPanelTests
CLANG_MODULE_CACHE_PATH=/tmp/lungfish-clang-cache SWIFTPM_MODULECACHE_OVERRIDE=/tmp/lungfish-swift-cache \
swift test --disable-sandbox --filter GenotypeManualHaplotypeAccessibilityTests
CLANG_MODULE_CACHE_PATH=/tmp/lungfish-clang-cache SWIFTPM_MODULECACHE_OVERRIDE=/tmp/lungfish-swift-cache \
swift test --disable-sandbox --filter GenotypeResultViewportTests/testSelectedSampleWorkbench
```

Expected: PASS with no CLI invocation, sidecar mutation, save, projection
rebuild, or editor remount while browsing/comparing/staging.

- [ ] **Step 6: Commit**

```bash
git add Sources/LungfishGenotypeUI/GenotypeSampleComparisonPanel.swift \
  Sources/LungfishGenotypeUI/GenotypeSampleCurationWorkbenchView.swift \
  Sources/LungfishGenotypeUI/GenotypeManualHaplotypeEditor.swift \
  Sources/LungfishGenotypeUI/GenotypeResultViewController.swift \
  Tests/LungfishGenotypeUITests/GenotypeSampleComparisonPanelTests.swift \
  Tests/LungfishGenotypeUITests/GenotypeManualHaplotypeAccessibilityTests.swift \
  Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift
git commit -m "feat: add compare and copy haplotype workbench"
```

### Task 8: ONT/miSeq parity, performance budgets, and final verification

**Files:**
- Modify: `Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift`
- Modify: `Tests/LungfishGenotypeUITests/GenotypeManualHaplotypePerformanceTests.swift`
- Modify: `Tests/LungfishWorkflowTests/GenotypeWorkbookRevisionServiceTests.swift`
- Modify only if a shared-path defect is exposed:
  `Sources/LungfishGenotypeUI/GenotypeResultViewController.swift`
  `Sources/LungfishGenotypeUI/GenotypeComparisonMatrixView.swift`

- [ ] **Step 1: Add explicit assay-parity RED tests**

Add:

```swift
func testRefinedManualCurationParityForONTAndMiSeqGenotypeOnlyResults() throws
func testMiSeqProvisionalExonTwoEvidenceAndComparisonSurviveSaveAndRefresh() throws
func testHaplotypedMiSeqStillExcludesDisclosureEditorAndComparison() throws
func testHaplotypedONTStillExcludesDisclosureEditorAndComparison() throws
func testCompareSourceMayBeHiddenInBothEligibleGenotypeOnlyAssays() throws
```

For both explicit eligible workflow kinds assert collapsed disclosure,
expansion/auto-fit, evidence order, Compare & Copy, staging, save, immediate
header refresh, workbook dirty mark, and persisted sidecar parity. For miSeq
assert `_nov` remains labeled `Provisional exon 2` and is never resolved to a
named allele. For haplotyped miSeq assert none of the new manual controls mount.
Apply the same negative assertions to an explicitly haplotyped full-length ONT
result: neither haplotyped assay may mount disclosure, editor, comparison
model, or manual auto-fit.

- [ ] **Step 2: Add performance RED tests**

Add:

```swift
func testDisclosureAndTypographyMeasurementIsSamplesTimesSeven()
func testSingleSaveMeasurementIsSevenPerChangedSample()
func testScrollingPerformsNoAssignmentMeasurementOrComparisonWork()
func testComparisonSelectionIsLinearInVisibleRowsAndSearchDoesNotBuildSnapshots()
```

Put every counter and testing accessor inside `#if DEBUG`; release production
code must not retain instrumentation. Extend the representative release
benchmark to expanded/collapsed disclosure, evidence refresh, and
selected-source compare. Construct feature and otherwise-identical baseline
harnesses in the same process, alternate measurement order to reduce thermal
bias, warm each operation for at least 20 iterations, then collect at least 200
paired timed samples per operation after projection/layout caches settle.
Report sample count, p50, p95, p99, and paired regression per operation.
Enforce p95 ≤ 0.0167 s, p99 ≤ 0.0334 s, and ≤10% regression against the
otherwise-identical no-band/no-comparison baseline when
`LUNGFISH_RELEASE_PERFORMANCE_TEST=1`.

- [ ] **Step 3: Run RED and make only shared-path corrections**

Run:

```bash
CLANG_MODULE_CACHE_PATH=/tmp/lungfish-clang-cache SWIFTPM_MODULECACHE_OVERRIDE=/tmp/lungfish-swift-cache \
swift test --disable-sandbox --filter GenotypeResultViewportTests/testRefinedManualCurationParity
CLANG_MODULE_CACHE_PATH=/tmp/lungfish-clang-cache SWIFTPM_MODULECACHE_OVERRIDE=/tmp/lungfish-swift-cache \
swift test --disable-sandbox --filter GenotypeManualHaplotypePerformanceTests
```

Expected: parity tests should pass if Tasks 3–7 correctly reused the existing
eligibility path; any failure must be repaired in the shared controller/matrix
path, not by adding an assay-specific viewport fork. Performance tests may
initially fail until measurement/comparison counters are bounded.

- [ ] **Step 4: Run focused GREEN suites**

Run:

```bash
CLANG_MODULE_CACHE_PATH=/tmp/lungfish-clang-cache SWIFTPM_MODULECACHE_OVERRIDE=/tmp/lungfish-swift-cache \
swift test --disable-sandbox --filter PortableExclusiveRenameTests
CLANG_MODULE_CACHE_PATH=/tmp/lungfish-clang-cache SWIFTPM_MODULECACHE_OVERRIDE=/tmp/lungfish-swift-cache \
swift test --disable-sandbox --filter ONTGenotypeWorkbookCleanupStateTests
CLANG_MODULE_CACHE_PATH=/tmp/lungfish-clang-cache SWIFTPM_MODULECACHE_OVERRIDE=/tmp/lungfish-swift-cache \
swift test --disable-sandbox --filter GenotypeWorkbookRevisionServiceTests
CLANG_MODULE_CACHE_PATH=/tmp/lungfish-clang-cache SWIFTPM_MODULECACHE_OVERRIDE=/tmp/lungfish-swift-cache \
swift test --disable-sandbox --filter FastqGenotypingCommandTests
CLANG_MODULE_CACHE_PATH=/tmp/lungfish-clang-cache SWIFTPM_MODULECACHE_OVERRIDE=/tmp/lungfish-swift-cache \
swift test --disable-sandbox --filter GenotypeCurrentWorkbookUpdateExecutionServiceTests
CLANG_MODULE_CACHE_PATH=/tmp/lungfish-clang-cache SWIFTPM_MODULECACHE_OVERRIDE=/tmp/lungfish-swift-cache \
swift test --disable-sandbox --filter GenotypeManualHaplotype
CLANG_MODULE_CACHE_PATH=/tmp/lungfish-clang-cache SWIFTPM_MODULECACHE_OVERRIDE=/tmp/lungfish-swift-cache \
swift test --disable-sandbox --filter GenotypeSupportedAllelesPanelTests
CLANG_MODULE_CACHE_PATH=/tmp/lungfish-clang-cache SWIFTPM_MODULECACHE_OVERRIDE=/tmp/lungfish-swift-cache \
swift test --disable-sandbox --filter GenotypeSampleComparison
CLANG_MODULE_CACHE_PATH=/tmp/lungfish-clang-cache SWIFTPM_MODULECACHE_OVERRIDE=/tmp/lungfish-swift-cache \
swift test --disable-sandbox --filter GenotypeResultViewportTests
```

Expected: all focused filters PASS.

- [ ] **Step 5: Run release performance verification**

Run an optimized test build:

```bash
LUNGFISH_RELEASE_PERFORMANCE_TEST=1 \
CLANG_MODULE_CACHE_PATH=/tmp/lungfish-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/lungfish-swift-cache \
swift test -c release --disable-sandbox \
  --filter GenotypeManualHaplotypePerformanceTests
```

Expected: printed p95/p99 values meet 16.7/33.4 ms and each representative
interaction regresses no more than 10%.

- [ ] **Step 6: Run full verification and build the debug app**

Run:

```bash
CLANG_MODULE_CACHE_PATH=/tmp/lungfish-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/lungfish-swift-cache \
swift test --disable-sandbox
CLANG_MODULE_CACHE_PATH=/tmp/lungfish-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/lungfish-swift-cache \
swift build --disable-sandbox --arch arm64
./scripts/build-app.sh --configuration debug --skip-build
codesign --verify --deep --strict build/Debug/Lungfish.app
```

Expected: all non-environment-dependent tests PASS; any sandbox-only skips are
listed with their exact names and reason. Build and code-sign verification exit
0.

- [ ] **Step 7: Inspect provenance, repository state, and diff**

Verify a successful, committed-warning, recovered, and failed-preflight attempt
fixture. For each, inspect receipt/provenance JSON and assert exact argv,
resolved defaults, runtime, inputs/outputs with hashes/sizes, wall time, stderr
where useful, and correct exit status. Then run:

```bash
git diff --check
git status --short
git log --oneline --decorate -12
```

Expected: no whitespace errors; only intended implementation/test/doc files are
present; no generated workbook, analyst bundle, exFAT scratch, build artifact,
or managed runtime is staged.

- [ ] **Step 8: Commit final parity/performance tests**

```bash
git add Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift \
  Tests/LungfishGenotypeUITests/GenotypeManualHaplotypePerformanceTests.swift \
  Tests/LungfishWorkflowTests/GenotypeWorkbookRevisionServiceTests.swift
git commit -m "test: verify refined manual haplotype workflows"
```

- [ ] **Step 9: Request independent reviews before integration**

Use `superpowers:requesting-code-review` for:

1. filesystem safety/provenance review of Tasks 1–2;
2. UI/UX/accessibility review of Tasks 3–7;
3. final code-quality and performance review of the complete diff.

Resolve every blocking finding with a failing regression test first, rerun the
affected focused suite, then rerun Steps 4–7. Use
`superpowers:verification-before-completion` before reporting completion and
`superpowers:finishing-a-development-branch` for the merge/push handoff.
