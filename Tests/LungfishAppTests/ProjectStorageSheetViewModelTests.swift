import AppKit
import LungfishIO
import LungfishWorkflow
import XCTest
@testable import LungfishApp

@MainActor
final class ProjectStorageSheetViewModelTests: XCTestCase {
    private final class ValueBox<Value> {
        var value: Value

        init(_ value: Value) {
            self.value = value
        }
    }

    private final class LockedBoolRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Bool] = []

        func record(_ value: Bool) {
            lock.withLock {
                values.append(value)
            }
        }

        var snapshot: [Bool] {
            lock.withLock { values }
        }
    }

    private final class LockedURLRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [URL] = []

        func record(_ value: URL) {
            lock.withLock {
                values.append(value)
            }
        }

        var snapshot: [URL] {
            lock.withLock { values }
        }
    }

    private final class OverlappingScanHarness: @unchecked Sendable {
        private let lock = NSLock()
        private let laterResult: ProjectStorageScanResult
        private var invocationCount = 0
        private var firstContinuation:
            CheckedContinuation<ProjectStorageScanResult, Never>?

        init(laterResult: ProjectStorageScanResult) {
            self.laterResult = laterResult
        }

        func scan() async -> ProjectStorageScanResult {
            let invocation = lock.withLock {
                invocationCount += 1
                return invocationCount
            }
            guard invocation == 1 else { return laterResult }
            return await withCheckedContinuation { continuation in
                lock.withLock {
                    firstContinuation = continuation
                }
            }
        }

        var hasStartedFirstScan: Bool {
            lock.withLock { firstContinuation != nil }
        }

        func resumeFirst(with result: ProjectStorageScanResult) {
            let continuation = lock.withLock {
                let value = firstContinuation
                firstContinuation = nil
                return value
            }
            continuation?.resume(returning: result)
        }
    }

    private final class DeferredCleanupHarness: @unchecked Sendable {
        private let lock = NSLock()
        private var storedInvocation:
            ProjectStorageCoordinator.CleanupInvocation?
        private var continuation:
            CheckedContinuation<ProjectStorageCoordinator.CleanupOutcome, Never>?

        func wait(
            for invocation: ProjectStorageCoordinator.CleanupInvocation
        ) async -> ProjectStorageCoordinator.CleanupOutcome {
            await withCheckedContinuation { continuation in
                lock.withLock {
                    storedInvocation = invocation
                    self.continuation = continuation
                }
            }
        }

        var invocation: ProjectStorageCoordinator.CleanupInvocation? {
            lock.withLock { storedInvocation }
        }

        func resume(with outcome: ProjectStorageCoordinator.CleanupOutcome) {
            let continuation = lock.withLock {
                let value = self.continuation
                self.continuation = nil
                return value
            }
            continuation?.resume(returning: outcome)
        }
    }

    private final class DeferredScanResultHarness: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation:
            CheckedContinuation<ProjectStorageScanResult, Never>?

        func wait() async -> ProjectStorageScanResult {
            await withCheckedContinuation { continuation in
                lock.withLock {
                    self.continuation = continuation
                }
            }
        }

        var isWaiting: Bool {
            lock.withLock { continuation != nil }
        }

        func resume(with result: ProjectStorageScanResult) {
            let continuation = lock.withLock {
                let value = self.continuation
                self.continuation = nil
                return value
            }
            continuation?.resume(returning: result)
        }
    }

    private final class SecondIdentityReadBarrier: @unchecked Sendable {
        private let lock = NSLock()
        private let releaseSecondRead = DispatchSemaphore(value: 0)
        private var readCount = 0
        private var secondReadWaiting = false

        func read(_ url: URL) throws -> FileSystemObjectIdentity {
            let shouldWait = lock.withLock {
                readCount += 1
                if readCount == 2 {
                    secondReadWaiting = true
                    return true
                }
                return false
            }
            if shouldWait {
                releaseSecondRead.wait()
            }
            return try FileSystemObjectIdentity.noFollow(url)
        }

        var isSecondReadWaiting: Bool {
            lock.withLock { secondReadWaiting }
        }

        func resumeSecondRead() {
            releaseSecondRead.signal()
        }
    }

    @MainActor
    private final class MainActorDeliveryBarrier {
        private var continuation: CheckedContinuation<Void, Never>?

        var isWaiting: Bool {
            continuation != nil
        }

        func wait() async {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }

        func resume() {
            let continuation = continuation
            self.continuation = nil
            continuation?.resume()
        }
    }

    private let projectURL = URL(
        fileURLWithPath: "/tmp/Storage Project.lungfish",
        isDirectory: true
    )
    private let projectIdentity = FileSystemObjectIdentity(
        device: 41,
        inode: 73
    )

    func testSafeDefaultsSelectOnlyIndividuallyProvenRemovableEntries() {
        let completed = entry(
            path: ".completed-work",
            category: .workflowStaging,
            logical: 10,
            allocated: 20,
            classification: .removable(
                .completedOwnedWork,
                reason: "Completed and unlocked."
            )
        )
        let orphaned = entry(
            path: ".tmp/orphaned",
            category: .temporary,
            logical: 30,
            allocated: 40,
            classification: .removable(
                .conclusivelyOrphanedOwnedWork,
                reason: "Owner is conclusively gone."
            )
        )
        let unsafeCodes: [ProjectStorageClassification.Code] = [
            .retainedWorkbookRevision, .missingOwnershipMarker,
            .invalidOwnershipMarker, .explicitlyRetained, .liveProcess,
            .heldLock, .unsafeLock, .liveOperationHistory,
            .unsafeFileSystemObject, .identityChanged,
            .ambiguousWorkbookArchive, .liveWorkbookAuthority,
            .unknownOwnedPattern, .inspectionFailed,
        ]
        let unsafe = unsafeCodes.enumerated().map { index, code in
            entry(
                path: "unsafe-\(index)",
                category: .temporary,
                logical: 100,
                allocated: 200,
                classification: .notRemovable(
                    code,
                    reason: "Not individually proven removable."
                )
            )
        }
        let model = makeModel()

        model.receiveScanResult(
            .init(
                projectIdentity: projectIdentity,
                entries: [completed, orphaned] + unsafe
            )
        )

        XCTAssertEqual(model.selectedEntryIDs, Set([completed.id, orphaned.id]))
        XCTAssertEqual(model.selectedAllocatedBytes, 60)
        XCTAssertEqual(model.selectedLogicalBytes, 40)
    }

    func testLegacyWorkflowReviewEntriesAreCheckableButStartUnchecked() {
        let legacy = entry(
            path: ".legacy.lungfishgenotype.run-staging-"
                + UUID().uuidString,
            category: .workflowStaging,
            logical: 100,
            allocated: 80,
            classification: .reviewRequired(
                .legacyUnverifiedOwnedWork,
                reason: "Review this older workflow folder."
            )
        )
        let model = makeModel()

        model.receiveScanResult(
            .init(
                projectIdentity: projectIdentity,
                entries: [legacy]
            )
        )

        XCTAssertTrue(model.selectedEntryIDs.isEmpty)
        let section = try! XCTUnwrap(
            model.categorySections.first(where: {
                $0.kind == .legacyWorkflowReview
            })
        )
        XCTAssertTrue(section.isCheckable)
        XCTAssertEqual(section.entries, [legacy])
        XCTAssertEqual(
            model.cleanupStatusText(for: legacy),
            "Review required"
        )

        model.toggleSelection(for: legacy.id)
        XCTAssertEqual(model.selectedEntryIDs, [legacy.id])
    }

    func testCategoryHierarchyAndLocalizedLogicalAllocatedValues() {
        let workbook = entry(
            path: ".archive.lungfishgenotype",
            category: .workbookArchive,
            logical: 2_000_000,
            allocated: 1_048_576
        )
        let staging = entry(
            path: ".analysis-work",
            category: .workflowStaging,
            logical: 4_000_000,
            allocated: 2_097_152
        )
        let temporary = entry(
            path: ".tmp/run",
            category: .temporary,
            logical: 8_000_000,
            allocated: 4_194_304
        )
        let held = entry(
            path: ".tmp/live",
            category: .temporary,
            classification: .notRemovable(
                .heldLock,
                reason: "The workflow lock is held."
            )
        )
        let model = makeModel()

        model.receiveScanResult(
            .init(
                projectIdentity: projectIdentity,
                entries: [temporary, workbook, staging, held]
            )
        )

        XCTAssertEqual(
            model.categorySections.map(\.title),
            [
                "Completed workbook publication archives",
                "Orphaned workflow staging data",
                "Legacy workflow staging — review before moving",
                "Temporary files",
                "Not Removable",
            ]
        )
        XCTAssertEqual(model.categorySections.flatMap(\.entries).count, 4)
        XCTAssertEqual(
            model.logicalSizeText(for: workbook),
            ProjectStorageSheetViewModel.localizedByteCount(
                workbook.logicalBytes
            )
        )
        XCTAssertEqual(
            model.allocatedSizeText(for: workbook),
            ProjectStorageSheetViewModel.localizedByteCount(
                workbook.allocatedBytes
            )
        )
        XCTAssertEqual(
            model.cleanupButtonTitle,
            "Move \(model.selectedAllocatedSizeText) to Trash"
        )
        XCTAssertTrue(model.estimatedTotalDescription.contains("estimated"))
        XCTAssertTrue(
            model.estimatedTotalDescription.contains(
                model.selectedAllocatedSizeText
            )
        )
        XCTAssertTrue(
            model.estimatedTotalDescription.contains(
                ProjectStorageSheetViewModel.localizedByteCount(
                    model.selectedLogicalBytes
                )
            )
        )
        XCTAssertTrue(model.estimatedTotalDescription.contains("Trash"))
        XCTAssertEqual(
            model.modifiedDateText(for: workbook),
            ProjectStorageSheetViewModel.localizedDate(
                workbook.modificationDate
            )
        )
    }

    func testIdentityBindingBecomesStaleAndDisablesScanAndCleanup() {
        let bindingIsCurrent = ValueBox(true)
        let model = makeModel(bindingIsCurrent: {
            bindingIsCurrent.value
        })
        model.receiveScanResult(
            .init(
                projectIdentity: projectIdentity,
                entries: [entry(path: ".tmp/run", category: .temporary)]
            )
        )
        XCTAssertTrue(model.canScan)
        XCTAssertTrue(model.canCleanup)

        bindingIsCurrent.value = false
        model.revalidateBinding()

        XCTAssertTrue(model.isStale)
        XCTAssertFalse(model.canScan)
        XCTAssertFalse(model.canCleanup)
        XCTAssertEqual(
            model.statusMessage,
            "This window no longer owns the project used for this storage review."
        )
    }

    func testMismatchedScanIdentityIsRejectedWithoutChangingSelection() {
        let model = makeModel()
        let wrongIdentity = FileSystemObjectIdentity(device: 41, inode: 99)

        model.receiveScanResult(
            .init(
                projectIdentity: wrongIdentity,
                entries: [entry(path: ".tmp/wrong", category: .temporary)]
            )
        )

        XCTAssertTrue(model.isStale)
        XCTAssertTrue(model.entries.isEmpty)
        XCTAssertTrue(model.selectedEntryIDs.isEmpty)
    }

    func testReturnNeverRequestsCleanupAndEscapeCancelsAndCloses() {
        var cleanupRequests = 0
        var closeRequests = 0
        var cancellations = 0
        let model = makeModel(
            requestCleanup: { cleanupRequests += 1 },
            requestClose: { closeRequests += 1 },
            requestCancellation: { cancellations += 1 }
        )
        model.receiveScanResult(
            .init(
                projectIdentity: projectIdentity,
                entries: [entry(path: ".tmp/run", category: .temporary)]
            )
        )

        XCTAssertTrue(model.handleReturnKey())
        XCTAssertEqual(cleanupRequests, 0)

        XCTAssertTrue(model.handleEscapeKey())
        XCTAssertEqual(cleanupRequests, 0)
        XCTAssertEqual(cancellations, 1)
        XCTAssertEqual(closeRequests, 1)
    }

    func testScanCancellationFailsClosedWithoutInventedPartialRows() {
        let model = makeModel()
        model.beginScanning()
        model.receiveScanProgress(
            progress(visited: 8, path: ".tmp/partial")
        )

        model.receiveScanCancellation()

        XCTAssertTrue(model.entries.isEmpty)
        XCTAssertFalse(model.hasPartialScanResults)
        XCTAssertTrue(model.canRetryScan)
        XCTAssertEqual(model.statusMessage, "Scan cancelled.")
    }

    func testRescanCancellationDiscardsEarlierRowsInsteadOfCallingThemPartial() {
        let model = makeModel()
        model.receiveScanResult(
            .init(
                projectIdentity: projectIdentity,
                entries: [entry(path: ".tmp/old", category: .temporary)]
            )
        )

        model.beginScanning()
        model.receiveScanCancellation()

        XCTAssertTrue(model.entries.isEmpty)
        XCTAssertTrue(model.selectedEntryIDs.isEmpty)
        XCTAssertFalse(model.hasPartialScanResults)
        XCTAssertEqual(model.statusMessage, "Scan cancelled.")
    }

    func testCancelledScanShowsNativeRetryScanActionAndRequestsFreshScan() throws {
        var retryRequests = 0
        let model = makeModel(
            requestRetryScan: { retryRequests += 1 }
        )
        model.beginScanning()
        model.receiveScanCancellation()
        let controller = ProjectStorageSheetViewController(viewModel: model)
        let retryScan = try XCTUnwrap(
            controller.view.descendant(
                matching: ProjectStorageAccessibilityID.retryScanButton
            ) as? NSButton
        )

        XCTAssertFalse(retryScan.isHidden)
        XCTAssertTrue(retryScan.isEnabled)
        retryScan.performClick(nil)

        XCTAssertEqual(retryRequests, 1)
    }

    func testEscapeDuringScanStopsScanWithoutClosingThenAllowsRetry() {
        var closeRequests = 0
        var cancellationRequests = 0
        let model = makeModel(
            requestClose: { closeRequests += 1 },
            requestCancellation: { cancellationRequests += 1 }
        )
        model.beginScanning()

        XCTAssertTrue(model.handleEscapeKey())
        XCTAssertEqual(cancellationRequests, 1)
        XCTAssertEqual(closeRequests, 0)
        XCTAssertEqual(model.statusMessage, "Stopping scan…")

        model.receiveScanCancellation()
        XCTAssertTrue(model.canRetryScan)
        XCTAssertEqual(closeRequests, 0)
    }

    func testProgressDeliveryIsThrottledButFinalProgressIsDelivered() {
        let model = makeModel(progressThrottleInterval: 1)
        let first = progress(visited: 1, path: ".tmp/a")
        let second = progress(visited: 2, path: ".tmp/b")
        let final = progress(visited: 3, path: ".tmp/c")

        model.beginScanning()
        model.receiveScanProgress(first, now: 10)
        model.receiveScanProgress(second, now: 10.1)
        XCTAssertEqual(model.scanProgress, first)

        model.receiveScanProgress(final, now: 11.1)
        XCTAssertEqual(model.scanProgress, final)
    }

    func testAcceptedScanProgressIsVisibleLocalizedAndCoalescedForVoiceOver()
        throws
    {
        let model = makeModel(progressThrottleInterval: 1)
        var changeCount = 0
        model.onChange = { changeCount += 1 }
        let first = ProjectStorageScanProgress(
            visitedFileSystemObjects: 1_234,
            classifiedEntries: 56,
            logicalBytes: 1_000,
            allocatedBytes: 2_000,
            currentRelativePath: ".tmp/current-run"
        )
        let suppressed = ProjectStorageScanProgress(
            visitedFileSystemObjects: 1_235,
            classifiedEntries: 57,
            logicalBytes: 1_100,
            allocatedBytes: 2_100,
            currentRelativePath: ".tmp/suppressed"
        )
        let delivered = ProjectStorageScanProgress(
            visitedFileSystemObjects: 2_345,
            classifiedEntries: 67,
            logicalBytes: 3_000,
            allocatedBytes: 4_000,
            currentRelativePath: ".tmp/delivered"
        )

        model.beginScanning()
        changeCount = 0
        model.receiveScanProgress(first, now: 10)
        let firstStatus = model.statusMessage
        XCTAssertEqual(changeCount, 1)
        XCTAssertTrue(
            firstStatus.contains(
                NumberFormatter.localizedString(
                    from: NSNumber(value: first.visitedFileSystemObjects),
                    number: .decimal
                )
            )
        )
        XCTAssertTrue(
            firstStatus.contains(
                NumberFormatter.localizedString(
                    from: NSNumber(value: first.classifiedEntries),
                    number: .decimal
                )
            )
        )
        XCTAssertTrue(
            firstStatus.contains(
                ProjectStorageSheetViewModel.localizedByteCount(
                    first.allocatedBytes
                )
            )
        )
        XCTAssertTrue(
            firstStatus.contains(
                ProjectStorageSheetViewModel.localizedByteCount(
                    first.logicalBytes
                )
            )
        )
        XCTAssertTrue(firstStatus.contains(first.currentRelativePath))

        model.receiveScanProgress(suppressed, now: 10.1)
        XCTAssertEqual(changeCount, 1)
        XCTAssertEqual(model.statusMessage, firstStatus)

        model.receiveScanProgress(delivered, now: 11.1)
        XCTAssertEqual(changeCount, 2)
        XCTAssertTrue(
            model.statusMessage.contains(delivered.currentRelativePath)
        )

        let controller = ProjectStorageSheetViewController(viewModel: model)
        let status = try XCTUnwrap(
            controller.view.descendant(
                matching: ProjectStorageAccessibilityID.status
            ) as? NSTextField
        )
        XCTAssertEqual(status.stringValue, model.statusMessage)
        XCTAssertEqual(status.accessibilityLabel(), model.statusMessage)
    }

    func testVoiceOverProgressAnnouncementsFollowAcceptedThrottleUpdates() {
        let model = makeModel(progressThrottleInterval: 0.1)
        var announcements: [String] = []
        let now = ValueBox<TimeInterval>(10)
        let controller = ProjectStorageSheetViewController(
            viewModel: model,
            progressAnnouncementThrottleInterval: 1,
            progressAnnouncementNow: { now.value },
            progressAnnouncementHandler: {
                announcements.append($0)
            }
        )
        _ = controller.view
        model.beginScanning()
        let first = progress(visited: 1, path: ".tmp/first")
        let suppressed = progress(visited: 2, path: ".tmp/suppressed")
        let delivered = progress(visited: 3, path: ".tmp/delivered")

        model.receiveScanProgress(first, now: 10)
        now.value = 10.11
        model.receiveScanProgress(suppressed, now: 10.11)
        XCTAssertEqual(model.scanProgress, suppressed)
        XCTAssertEqual(announcements.count, 1)

        now.value = 11.01
        model.receiveScanProgress(delivered, now: 11.01)

        XCTAssertEqual(announcements.count, 2)
        XCTAssertTrue(announcements[0].contains(first.currentRelativePath))
        XCTAssertTrue(announcements[1].contains(delivered.currentRelativePath))

        now.value = 11.05
        model.receiveScanFailure(
            NSError(
                domain: "ProjectStorageTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Inspection failed."]
            )
        )
        XCTAssertEqual(announcements.count, 3)
        XCTAssertTrue(announcements[2].contains("Inspection failed."))
    }

    func testRevalidationProgressIsVisibleBusyAndVoiceOverCoalesced()
        throws
    {
        let failed = entry(path: ".tmp/retry", category: .temporary)
        let model = makeModel(progressThrottleInterval: 0)
        model.receiveScanResult(
            .init(projectIdentity: projectIdentity, entries: [failed])
        )
        let result = executionResult(
            entries: [failed],
            states: [.failed],
            trashDestinationPath: "/Users/test/.Trash/unused",
            summaryURL: URL(fileURLWithPath: "/project/history/summary.json"),
            provenanceURL:
                URL(fileURLWithPath: "/project/history/provenance.json")
        )
        model.receiveCleanupResult(
            summary: result.summary,
            summaryURL: result.summaryURL,
            provenanceURL: result.provenanceURL
        )
        var announcements: [String] = []
        let now = ValueBox<TimeInterval>(10)
        let controller = ProjectStorageSheetViewController(
            viewModel: model,
            progressAnnouncementThrottleInterval: 1,
            progressAnnouncementNow: { now.value },
            progressAnnouncementHandler: { announcements.append($0) }
        )
        let root = controller.view
        let indicator = try XCTUnwrap(
            root.descendant(
                matching: ProjectStorageAccessibilityID.progress
            ) as? NSProgressIndicator
        )
        let cancel = try XCTUnwrap(
            root.descendant(
                matching: ProjectStorageAccessibilityID.cancelButton
            ) as? NSButton
        )

        model.retryFailed()
        let first = progress(visited: 1, path: ".tmp/first")
        let coalesced = progress(visited: 2, path: ".tmp/coalesced")
        let delivered = progress(visited: 3, path: ".tmp/delivered")
        model.receiveScanProgress(first, now: 10)
        now.value = 10.11
        model.receiveScanProgress(coalesced, now: 10.11)

        XCTAssertEqual(model.state, .revalidating)
        XCTAssertEqual(model.scanProgress, coalesced)
        XCTAssertFalse(indicator.isHidden)
        XCTAssertEqual(cancel.title, "Stop")
        XCTAssertEqual(announcements.count, 1)
        XCTAssertTrue(
            announcements.first?.contains(first.currentRelativePath) == true
        )

        now.value = 11.01
        model.receiveScanProgress(delivered, now: 11.01)

        XCTAssertEqual(announcements.count, 2)
        XCTAssertTrue(
            announcements.last?.contains(delivered.currentRelativePath)
                == true
        )

        now.value = 11.05
        model.receiveRevalidationCancellation()

        XCTAssertEqual(model.state, .finished)
        XCTAssertEqual(announcements.count, 3)
        XCTAssertTrue(
            announcements.last?.contains("Revalidation stopped") == true
        )
    }

    func testQueuedRevalidationProgressAfterStopIsIgnored()
        async throws
    {
        let failed = entry(path: ".tmp/retry", category: .temporary)
        var cancellationRequests = 0
        let model = makeModel(
            progressThrottleInterval: 0,
            requestCancellation: { cancellationRequests += 1 }
        )
        model.receiveScanResult(
            .init(projectIdentity: projectIdentity, entries: [failed])
        )
        let summaryURL = URL(
            fileURLWithPath: "/project/history/initial-summary.json"
        )
        let provenanceURL = URL(
            fileURLWithPath: "/project/history/initial-provenance.json"
        )
        receiveFailedCleanup(
            on: model,
            projectURL: projectURL,
            projectIdentity: projectIdentity,
            failedEntry: failed,
            summaryURL: summaryURL,
            provenanceURL: provenanceURL
        )
        var announcements: [String] = []
        let controller = ProjectStorageSheetViewController(
            viewModel: model,
            progressAnnouncementThrottleInterval: 1,
            progressAnnouncementHandler: { announcements.append($0) }
        )
        let root = controller.view
        let cancel = try XCTUnwrap(
            root.descendant(
                matching: ProjectStorageAccessibilityID.cancelButton
            ) as? NSButton
        )
        let barrier = MainActorDeliveryBarrier()
        let lateProgress = progress(
            visited: 77,
            path: ".tmp/queued-before-stop"
        )

        model.retryFailed()
        let queuedDelivery = Task { @MainActor in
            await barrier.wait()
            model.receiveScanProgress(lateProgress)
        }
        while !barrier.isWaiting {
            await Task.yield()
        }

        XCTAssertTrue(model.handleEscapeKey())
        XCTAssertEqual(cancellationRequests, 1)
        XCTAssertEqual(model.statusMessage, "Stopping revalidation…")
        XCTAssertFalse(cancel.isEnabled)
        barrier.resume()
        await queuedDelivery.value

        XCTAssertEqual(model.state, .revalidating)
        XCTAssertNil(model.scanProgress)
        XCTAssertEqual(model.statusMessage, "Stopping revalidation…")
        XCTAssertFalse(cancel.isEnabled)
        XCTAssertTrue(announcements.isEmpty)

        model.receiveRevalidationCancellation()

        XCTAssertEqual(model.state, .finished)
        XCTAssertEqual(model.entries, [failed])
        XCTAssertEqual(model.failedEntries, [failed])
        XCTAssertEqual(model.receiptURL, summaryURL)
        XCTAssertEqual(model.provenanceURL, provenanceURL)
        XCTAssertTrue(model.canRetryFailed)
        XCTAssertEqual(cancel.title, "Done")
        XCTAssertEqual(announcements.count, 1)
        XCTAssertTrue(
            announcements.first?.contains("Revalidation stopped") == true
        )
    }

    func testPartialCleanupEnablesRetryFailedAndReceiptTrashRevealActions() {
        let succeeded = entry(path: ".tmp/a", category: .temporary)
        let failed = entry(path: ".tmp/b", category: .temporary)
        var retried: [ProjectStorageEntry] = []
        var stateObservedByRetry: ProjectStorageSheetViewModel.State?
        var modelReference: ProjectStorageSheetViewModel?
        var revealed: [URL] = []
        let receipt = URL(fileURLWithPath: "/project/history/summary.json")
        let provenance = URL(
            fileURLWithPath: "/project/history/provenance.json"
        )
        let trash = "/Users/test/.Trash/.tmp-a"
        let model = makeModel(
            requestRetryFailed: {
                retried = $0
                stateObservedByRetry = modelReference?.state
            },
            requestReveal: { revealed.append($0) }
        )
        modelReference = model
        model.receiveScanResult(
            .init(
                projectIdentity: projectIdentity,
                entries: [succeeded, failed]
            )
        )
        let result = executionResult(
                entries: [succeeded, failed],
                states: [.movedToTrash, .failed],
                trashDestinationPath: trash,
                summaryURL: receipt,
                provenanceURL: provenance
            )
        model.receiveCleanupResult(
            summary: result.summary,
            summaryURL: result.summaryURL,
            provenanceURL: result.provenanceURL
        )

        XCTAssertTrue(model.canRetryFailed)
        XCTAssertFalse(model.canCleanup)
        XCTAssertEqual(model.failedEntries, [failed])
        XCTAssertTrue(model.statusMessage.contains("1 item"))
        model.retryFailed()
        XCTAssertEqual(retried, [failed])
        XCTAssertEqual(stateObservedByRetry, .revalidating)
        XCTAssertEqual(model.state, .revalidating)
        XCTAssertFalse(model.canRetryFailed)
        XCTAssertFalse(model.canCleanup)
        XCTAssertFalse(model.canScan)
        retried.removeAll()
        model.retryFailed()
        XCTAssertTrue(retried.isEmpty)

        XCTAssertTrue(model.canRevealReceipt)
        model.revealReceipt()
        model.revealTrashDestination(for: succeeded.id)
        XCTAssertEqual(
            revealed,
            [receipt, URL(fileURLWithPath: trash)]
        )
        XCTAssertEqual(model.cleanupItems.count, 2)
        XCTAssertEqual(
            model.cleanupStatusText(for: succeeded),
            "Moved to Trash"
        )
        XCTAssertEqual(
            model.cleanupStatusText(for: failed),
            "Failed: Trash unavailable."
        )
    }

    func testEscapeDuringFailedEntryRevalidationCancelsWithoutClosing() {
        let failed = entry(path: ".tmp/failed", category: .temporary)
        var closeRequests = 0
        var cancellationRequests = 0
        let model = makeModel(
            requestClose: { closeRequests += 1 },
            requestCancellation: { cancellationRequests += 1 }
        )
        model.receiveScanResult(
            .init(
                projectIdentity: projectIdentity,
                entries: [failed]
            )
        )
        let result = executionResult(
            entries: [failed],
            states: [.failed],
            trashDestinationPath: "/Users/test/.Trash/unused",
            summaryURL: URL(fileURLWithPath: "/project/history/summary.json"),
            provenanceURL:
                URL(fileURLWithPath: "/project/history/provenance.json")
        )
        model.receiveCleanupResult(
            summary: result.summary,
            summaryURL: result.summaryURL,
            provenanceURL: result.provenanceURL
        )

        model.retryFailed()
        XCTAssertEqual(model.state, .revalidating)
        XCTAssertTrue(model.handleEscapeKey())

        XCTAssertEqual(cancellationRequests, 1)
        XCTAssertEqual(closeRequests, 0)
        XCTAssertEqual(model.statusMessage, "Stopping revalidation…")
    }

    func testPartialCleanupReportsMovedBytesCountsAndNoPermanentDeletion() {
        let succeeded = entry(
            path: ".tmp/moved",
            category: .temporary,
            logical: 10_000,
            allocated: 12_000
        )
        let failed = entry(
            path: ".tmp/failed",
            category: .temporary,
            logical: 90_000,
            allocated: 99_000
        )
        let model = makeModel()
        model.receiveScanResult(
            .init(
                projectIdentity: projectIdentity,
                entries: [succeeded, failed]
            )
        )
        let result = executionResult(
            entries: [succeeded, failed],
            states: [.movedToTrash, .failed],
            trashDestinationPath: "/Users/test/.Trash/moved",
            summaryURL: URL(fileURLWithPath: "/project/history/summary.json"),
            provenanceURL: URL(
                fileURLWithPath: "/project/history/provenance.json"
            )
        )

        model.receiveCleanupResult(
            summary: result.summary,
            summaryURL: result.summaryURL,
            provenanceURL: result.provenanceURL
        )

        let movedSize = ProjectStorageSheetViewModel.localizedByteCount(
            succeeded.allocatedBytes
        )
        let failedSize = ProjectStorageSheetViewModel.localizedByteCount(
            failed.allocatedBytes
        )
        XCTAssertEqual(model.selectedEntryIDs, [failed.id])
        XCTAssertTrue(
            model.statusMessage.contains(
                "\(movedSize) removed from the project."
            )
        )
        XCTAssertFalse(model.statusMessage.contains(failedSize))
        XCTAssertTrue(model.statusMessage.contains("1 item moved to Trash"))
        XCTAssertTrue(model.statusMessage.contains("1 item failed"))
        XCTAssertTrue(model.statusMessage.contains("Empty the Trash"))
        XCTAssertTrue(
            model.statusMessage.contains("No permanent deletion was used.")
        )
    }

    func testCleanupResultMatchesReceiptItemsBySourcePath() {
        let moved = entry(
            path: ".tmp/fasta-preview",
            category: .temporary,
            logical: 10_000,
            allocated: 12_000
        )
        let model = makeModel()
        model.receiveScanResult(
            .init(projectIdentity: projectIdentity, entries: [moved])
        )
        let trashPath = "/Users/test/.Trash/fasta-preview"
        let receiptItemID = UUID()

        model.receiveCleanupResult(
            summary: .init(
                cleanupID: UUID(),
                projectRoot: projectURL.path,
                projectIdentity: projectIdentity,
                state: .completed,
                items: [
                    .init(
                        itemID: receiptItemID,
                        sourceRelativePath: moved.relativePath,
                        state: .movedToTrash,
                        quarantineRelativePath: nil,
                        trashDestinationPath: trashPath,
                        reason: nil
                    ),
                ],
                startedAt: Date(timeIntervalSince1970: 10),
                completedAt: Date(timeIntervalSince1970: 11),
                exitStatus: 0,
                wallTimeSeconds: 1,
                stderr: ""
            ),
            summaryURL: URL(fileURLWithPath: "/project/history/summary.json"),
            provenanceURL: URL(
                fileURLWithPath: "/project/history/provenance.json"
            )
        )

        XCTAssertEqual(model.removedAllocatedBytes, moved.allocatedBytes)
        XCTAssertEqual(model.cleanupItems[moved.id]?.itemID, receiptItemID)
        XCTAssertEqual(
            model.trashDestinationURLs[moved.id],
            URL(fileURLWithPath: trashPath)
        )
        XCTAssertEqual(model.cleanupStatusText(for: moved), "Moved to Trash")
    }

    func testDuplicateCleanupItemIdentifiersFailSafely() {
        let source = entry(path: ".tmp/duplicate", category: .temporary)
        let duplicateItems = [
            ProjectStorageCleanupExecutionSummary.Item(
                itemID: source.id,
                sourceRelativePath: source.relativePath,
                state: .failed,
                quarantineRelativePath: nil,
                trashDestinationPath: nil,
                reason: "First"
            ),
            ProjectStorageCleanupExecutionSummary.Item(
                itemID: source.id,
                sourceRelativePath: source.relativePath,
                state: .failed,
                quarantineRelativePath: nil,
                trashDestinationPath: nil,
                reason: "Duplicate"
            ),
        ]
        XCTAssertThrowsError(
            try ProjectStorageSheetViewModel.validatedCleanupItems(
                duplicateItems
            )
        )
        let model = makeModel()
        model.receiveScanResult(
            .init(projectIdentity: projectIdentity, entries: [source])
        )
        model.receiveCleanupResult(
            summary: .init(
                cleanupID: UUID(),
                projectRoot: projectURL.path,
                projectIdentity: projectIdentity,
                state: .failed,
                items: duplicateItems,
                startedAt: Date(timeIntervalSince1970: 10),
                completedAt: Date(timeIntervalSince1970: 11),
                exitStatus: 1,
                wallTimeSeconds: 1,
                stderr: "Duplicate."
            ),
            summaryURL: URL(fileURLWithPath: "/project/summary.json"),
            provenanceURL: URL(fileURLWithPath: "/project/provenance.json")
        )

        XCTAssertEqual(model.state, .failed)
        XCTAssertTrue(model.cleanupItems.isEmpty)
        XCTAssertTrue(model.statusMessage.contains("duplicate"))
    }

    func testAllocatedAndLogicalTotalsSaturateInsteadOfOverflowing() {
        let model = makeModel()
        model.receiveScanResult(
            .init(
                projectIdentity: projectIdentity,
                entries: [
                    entry(
                        path: ".tmp/huge",
                        category: .temporary,
                        logical: .max,
                        allocated: .max
                    ),
                    entry(
                        path: ".tmp/extra",
                        category: .temporary,
                        logical: 1,
                        allocated: 1
                    ),
                ]
            )
        )

        XCTAssertEqual(model.selectedLogicalBytes, .max)
        XCTAssertEqual(model.selectedAllocatedBytes, .max)
    }

    func testReadOnlyRecommendedProjectCanPreviewButCannotMove() {
        let model = makeModel(
            allowsCleanup: false
        )
        model.receiveScanResult(
            .init(
                projectIdentity: projectIdentity,
                entries: [entry(path: ".tmp/run", category: .temporary)]
            )
        )

        XCTAssertTrue(model.canScan)
        XCTAssertFalse(model.canCleanup)
        XCTAssertEqual(
            model.cleanupDisabledReason,
            "This project is read-only recommended. Storage can be reviewed, but items cannot be moved."
        )
    }

    func testLateScanResultIsRejectedAfterBindingGenerationInvalidates() {
        let currentGeneration = ValueBox<UInt64>(5)
        let model = makeModel(
            bindingGeneration: 5,
            bindingIsCurrent: { currentGeneration.value == 5 }
        )
        model.beginScanning()
        currentGeneration.value = 6

        model.receiveScanResult(
            .init(
                projectIdentity: projectIdentity,
                entries: [entry(path: ".tmp/late", category: .temporary)]
            )
        )

        XCTAssertTrue(model.isStale)
        XCTAssertTrue(model.entries.isEmpty)
        XCTAssertFalse(model.canCleanup)
    }

    func testCoordinatorAllowsOnlyOneSheetPerOriginatingWindow() {
        let window = NSWindow()
        XCTAssertTrue(
            ProjectStorageCoordinator.testingClaimPresentation(on: window)
        )
        XCTAssertFalse(
            ProjectStorageCoordinator.testingClaimPresentation(on: window)
        )
        ProjectStorageCoordinator.testingReleasePresentation(on: window)
        XCTAssertTrue(
            ProjectStorageCoordinator.testingClaimPresentation(on: window)
        )
        ProjectStorageCoordinator.testingReleasePresentation(on: window)
    }

    func testProgrammaticSheetCloseCannotBypassCoordinatorCleanup()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ProjectStorageSheetLifecycleTests-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try DocumentManager.shared.createProject(
            at: root.appendingPathComponent(
                "Lifecycle.lungfish",
                isDirectory: true
            ),
            name: "Lifecycle"
        )
        let session = ProjectSession()
        try session.openProject(at: project.url)
        let controller = MainWindowController(projectSession: session)
        defer { controller.close() }
        let presentingWindow = try XCTUnwrap(controller.window)
        let identity = try FileSystemObjectIdentity.noFollow(project.url)
        let completionCount = ValueBox(0)
        let scanEvents = LockedBoolRecorder()
        let operations = ProjectStorageCoordinator.Operations(
            scan: { _, _ in
                scanEvents.record(false)
                return try await withTaskCancellationHandler {
                    try await Task.sleep(for: .seconds(5))
                    return ProjectStorageScanResult(
                        projectIdentity: identity,
                        entries: []
                    )
                } onCancel: {
                    scanEvents.record(true)
                }
            }
        )
        let coordinator = ProjectStorageCoordinator(
            presentingWindow: presentingWindow,
            controller: controller,
            projectURL: project.url,
            projectIdentity: identity,
            generation: 0,
            generationProvider: { 0 },
            operations: operations,
            completion: { completionCount.value += 1 }
        )

        XCTAssertTrue(coordinator.present())
        let sheet = try XCTUnwrap(coordinator.presentedSheetWindow)
        XCTAssertFalse(sheet.styleMask.contains(.closable))
        while scanEvents.snapshot.isEmpty {
            await Task.yield()
        }

        sheet.close()

        while !scanEvents.snapshot.contains(true) {
            await Task.yield()
        }
        XCTAssertTrue(presentingWindow.sheets.isEmpty)
        XCTAssertEqual(completionCount.value, 1)
        XCTAssertTrue(scanEvents.snapshot.contains(true))
        XCTAssertTrue(
            ProjectStorageCoordinator.testingClaimPresentation(
                on: presentingWindow
            )
        )
        ProjectStorageCoordinator.testingReleasePresentation(
            on: presentingWindow
        )
    }

    func testCleanupCompositionRecordsActualGUIWorkflowAndResolvedSafetyOptions() {
        let removable = entry(path: ".tmp/run", category: .temporary)
        let invocation = ProjectStorageCoordinator.cleanupInvocation(
            projectURL: projectURL,
            projectIdentity: projectIdentity,
            selectedEntries: [removable],
            appArgv: ["/Applications/Lungfish.app/Contents/MacOS/Lungfish"],
            appVersion: "9.1.0",
            cleanupID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            startedAt: Date(timeIntervalSince1970: 10)
        )

        XCTAssertEqual(invocation.workflowName, "Manage Project Storage")
        XCTAssertEqual(invocation.workflowVersion, "9.1.0")
        XCTAssertEqual(invocation.toolName, "Lungfish")
        XCTAssertEqual(invocation.toolVersion, "9.1.0")
        XCTAssertEqual(
            invocation.argv,
            ["/Applications/Lungfish.app/Contents/MacOS/Lungfish"]
        )
        XCTAssertNil(invocation.durableReplayArgv)
        XCTAssertEqual(
            invocation.options.explicit["trigger"],
            .string("user-requested")
        )
        XCTAssertEqual(
            invocation.options.explicit["action"],
            .string("move-to-trash")
        )
        XCTAssertEqual(
            invocation.options.explicit["selectedRelativePaths"],
            .array([.string(".tmp/run")])
        )
        XCTAssertEqual(
            invocation.options.resolvedDefaults["permanentDeleteFallback"],
            .boolean(false)
        )
        XCTAssertEqual(
            invocation.options.explicit["estimatedAllocatedBytes"],
            .integer(4_096)
        )
    }

    func testViewControllerUsesNativeOutlineAndVoiceOverMetadata() throws {
        _ = NSApplication.shared
        let model = makeModel()
        let notRemovable = entry(
            path: ".tmp/live",
            category: .temporary,
            classification: .notRemovable(
                .heldLock,
                reason: "The workflow lock is held."
            )
        )
        model.receiveScanResult(
            .init(
                projectIdentity: projectIdentity,
                entries: [
                    entry(path: ".tmp/run", category: .temporary),
                    notRemovable,
                ]
            )
        )
        let controller = ProjectStorageSheetViewController(viewModel: model)
        let root = controller.view

        let outline = try XCTUnwrap(
            root.descendant(
                matching: ProjectStorageAccessibilityID.outline
            ) as? NSOutlineView
        )
        let cleanup = try XCTUnwrap(
            root.descendant(
                matching: ProjectStorageAccessibilityID.cleanupButton
            ) as? NSButton
        )
        let cancel = try XCTUnwrap(
            root.descendant(
                matching: ProjectStorageAccessibilityID.cancelButton
            ) as? NSButton
        )

        XCTAssertEqual(
            outline.accessibilityLabel(),
            "Project storage categories and entries"
        )
        XCTAssertTrue(
            (outline.accessibilityHelp() ?? "").contains("logical")
        )
        XCTAssertEqual(cleanup.keyEquivalent, "")
        XCTAssertEqual(
            cleanup.accessibilityLabel(),
            "Move selected project storage entries to Trash"
        )
        XCTAssertTrue(
            (cleanup.accessibilityHelp() ?? "").contains("Empty the Trash")
        )
        XCTAssertEqual(cancel.keyEquivalent, "\u{1b}")

        let removableEntry = try XCTUnwrap(
            model.entries.first(where: \.classification.isRemovable)
        )
        let entryID =
            ProjectStorageAccessibilityID.entryCheckboxPrefix
            + removableEntry.id.uuidString.lowercased()
        let entryCheckbox = try XCTUnwrap(
            (0..<outline.numberOfRows).lazy.compactMap { row in
                outline.view(
                    atColumn: 0,
                    row: row,
                    makeIfNecessary: true
                )?.descendant(matching: entryID) as? NSButton
            }.first
        )
        let rowLabel = entryCheckbox.accessibilityLabel() ?? ""
        XCTAssertTrue(rowLabel.contains("run"))
        XCTAssertTrue(rowLabel.contains(model.selectedAllocatedSizeText))
        XCTAssertTrue(rowLabel.contains("checked"))
        XCTAssertTrue(rowLabel.contains("Proven removable"))
        XCTAssertTrue(rowLabel.contains("Completed and unlocked."))

        let unsafeModel = makeModel()
        unsafeModel.receiveScanResult(
            .init(
                projectIdentity: projectIdentity,
                entries: [notRemovable]
            )
        )
        let unsafeController = ProjectStorageSheetViewController(
            viewModel: unsafeModel
        )
        let unsafeOutline = try XCTUnwrap(
            unsafeController.view.descendant(
                matching: ProjectStorageAccessibilityID.outline
            ) as? NSOutlineView
        )
        let notRemovableRow = try XCTUnwrap(
            (0..<unsafeOutline.numberOfRows).lazy.compactMap { row in
                unsafeOutline.view(
                    atColumn: 0,
                    row: row,
                    makeIfNecessary: true
                ) as? NSTextField
            }.first {
                $0.stringValue == "live"
            }
        )
        let notRemovableLabel =
            notRemovableRow.accessibilityLabel() ?? ""
        XCTAssertTrue(notRemovableLabel.contains("live"))
        XCTAssertTrue(
            notRemovableLabel.contains(
                model.allocatedSizeText(for: notRemovable)
            )
        )
        XCTAssertTrue(notRemovableLabel.contains("not checkable"))
        XCTAssertTrue(notRemovableLabel.contains("The workflow lock is held."))
    }

    func testCategoryRowsAnnounceCountsTotalsSelectionAndSafety() throws {
        let first = entry(
            path: ".tmp/first",
            category: .temporary,
            logical: 1_000,
            allocated: 2_000
        )
        let second = entry(
            path: ".tmp/second",
            category: .temporary,
            logical: 3_000,
            allocated: 4_000
        )
        let held = entry(
            path: ".tmp/held",
            category: .temporary,
            logical: 5_000,
            allocated: 6_000,
            classification: .notRemovable(
                .heldLock,
                reason: "The workflow lock is held."
            )
        )
        let model = makeModel()
        model.receiveScanResult(
            .init(
                projectIdentity: projectIdentity,
                entries: [first, second, held]
            )
        )
        model.toggleSelection(for: second.id)
        let controller = ProjectStorageSheetViewController(viewModel: model)
        let root = controller.view
        let outline = try XCTUnwrap(
            root.descendant(
                matching: ProjectStorageAccessibilityID.outline
            ) as? NSOutlineView
        )
        let temporaryID =
            ProjectStorageAccessibilityID.categoryCheckboxPrefix
            + ProjectStorageSheetViewModel.CategorySection.Kind
                .temporary.rawValue
        let temporary = try XCTUnwrap(
            (0..<outline.numberOfRows).lazy.compactMap { row in
                outline.view(
                    atColumn: 0,
                    row: row,
                    makeIfNecessary: true
                )?.descendant(matching: temporaryID) as? NSButton
            }.first
        )
        let temporaryLabel = temporary.accessibilityLabel() ?? ""

        XCTAssertEqual(temporary.state, .mixed)
        XCTAssertTrue(temporaryLabel.contains("Temporary files"))
        XCTAssertTrue(
            temporaryLabel.contains(
                ProjectStorageSheetViewModel.localizedCount(2)
            )
        )
        XCTAssertTrue(
            temporaryLabel.contains(
                ProjectStorageSheetViewModel.localizedByteCount(6_000)
            )
        )
        XCTAssertTrue(
            temporaryLabel.contains(
                ProjectStorageSheetViewModel.localizedByteCount(4_000)
            )
        )
        XCTAssertTrue(temporaryLabel.contains("partially selected"))
        XCTAssertTrue(
            temporaryLabel.contains("individually proven removable")
        )

        let notRemovableID =
            ProjectStorageAccessibilityID.categoryCheckboxPrefix
            + ProjectStorageSheetViewModel.CategorySection.Kind
                .notRemovable.rawValue
        let notRemovable = try XCTUnwrap(
            (0..<outline.numberOfRows).lazy.compactMap { row in
                outline.view(
                    atColumn: 0,
                    row: row,
                    makeIfNecessary: true
                )?.descendant(matching: notRemovableID) as? NSTextField
            }.first
        )
        let notRemovableLabel = notRemovable.accessibilityLabel() ?? ""
        XCTAssertTrue(notRemovableLabel.contains("Not Removable"))
        XCTAssertTrue(
            notRemovableLabel.contains(
                ProjectStorageSheetViewModel.localizedCount(1)
            )
        )
        XCTAssertTrue(
            notRemovableLabel.contains(
                ProjectStorageSheetViewModel.localizedByteCount(6_000)
            )
        )
        XCTAssertTrue(
            notRemovableLabel.contains(
                ProjectStorageSheetViewModel.localizedByteCount(5_000)
            )
        )
        XCTAssertTrue(notRemovableLabel.contains("not checkable"))
        XCTAssertTrue(notRemovableLabel.contains("not removable"))
    }

    func testReadOnlyExplanationIsVisibleInSheet() throws {
        let model = makeModel(allowsCleanup: false)
        model.receiveScanResult(
            .init(
                projectIdentity: projectIdentity,
                entries: [entry(path: ".tmp/run", category: .temporary)]
            )
        )
        let controller = ProjectStorageSheetViewController(viewModel: model)
        let status = try XCTUnwrap(
            controller.view.descendant(
                matching: ProjectStorageAccessibilityID.status
            ) as? NSTextField
        )

        XCTAssertTrue(status.stringValue.contains("read-only recommended"))
        XCTAssertTrue(
            (status.accessibilityLabel() ?? status.stringValue)
                .contains("read-only recommended")
        )
    }

    func testRevealInTrashRequiresSelectingSuccessfulResultRow() throws {
        let succeeded = entry(path: ".tmp/a", category: .temporary)
        let failed = entry(path: ".tmp/b", category: .temporary)
        var revealed: [URL] = []
        let trash = "/Users/test/.Trash/.tmp-a"
        let model = makeModel(requestReveal: { revealed.append($0) })
        model.receiveScanResult(
            .init(
                projectIdentity: projectIdentity,
                entries: [succeeded, failed]
            )
        )
        let result = executionResult(
            entries: [succeeded, failed],
            states: [.movedToTrash, .failed],
            trashDestinationPath: trash,
            summaryURL: URL(fileURLWithPath: "/project/history/summary.json"),
            provenanceURL: URL(
                fileURLWithPath: "/project/history/provenance.json"
            )
        )
        model.receiveCleanupResult(
            summary: result.summary,
            summaryURL: result.summaryURL,
            provenanceURL: result.provenanceURL
        )
        let controller = ProjectStorageSheetViewController(viewModel: model)
        let root = controller.view
        let outline = try XCTUnwrap(
            root.descendant(
                matching: ProjectStorageAccessibilityID.outline
            ) as? NSOutlineView
        )
        let revealTrash = try XCTUnwrap(
            root.descendant(
                matching: ProjectStorageAccessibilityID.revealTrashButton
            ) as? NSButton
        )

        XCTAssertFalse(revealTrash.isHidden)
        XCTAssertFalse(revealTrash.isEnabled)
        revealTrash.performClick(nil)
        XCTAssertTrue(revealed.isEmpty)

        let checkboxID =
            ProjectStorageAccessibilityID.entryCheckboxPrefix
            + succeeded.id.uuidString.lowercased()
        let successfulRow = try XCTUnwrap(
            (0..<outline.numberOfRows).first { row in
                outline.view(
                    atColumn: 0,
                    row: row,
                    makeIfNecessary: true
                )?.descendant(matching: checkboxID) != nil
            }
        )
        outline.selectRowIndexes(
            IndexSet(integer: successfulRow),
            byExtendingSelection: false
        )

        XCTAssertTrue(revealTrash.isEnabled)
        revealTrash.performClick(nil)
        XCTAssertEqual(revealed, [URL(fileURLWithPath: trash)])

        let failedCheckboxID =
            ProjectStorageAccessibilityID.entryCheckboxPrefix
            + failed.id.uuidString.lowercased()
        let failedRow = try XCTUnwrap(
            (0..<outline.numberOfRows).first { row in
                outline.view(
                    atColumn: 0,
                    row: row,
                    makeIfNecessary: true
                )?.descendant(matching: failedCheckboxID) != nil
            }
        )
        outline.selectRowIndexes(
            IndexSet(integer: failedRow),
            byExtendingSelection: false
        )
        XCTAssertFalse(revealTrash.isEnabled)
    }

    func testSidebarContextScopeRequiresSingleSuccessfullyOwnedProjectRoot() {
        let root = SidebarItem(
            title: "Storage Project",
            type: .project,
            url: projectURL
        )
        let child = SidebarItem(
            title: "Imports",
            type: .folder,
            url: projectURL.appendingPathComponent("Imports")
        )

        XCTAssertTrue(
            SidebarViewController.canManageProjectStorage(
                selectedItems: [root],
                currentProjectURL: projectURL,
                ownedProjectURL: projectURL
            )
        )
        XCTAssertFalse(
            SidebarViewController.canManageProjectStorage(
                selectedItems: [child],
                currentProjectURL: projectURL,
                ownedProjectURL: projectURL
            )
        )
        XCTAssertFalse(
            SidebarViewController.canManageProjectStorage(
                selectedItems: [root, child],
                currentProjectURL: projectURL,
                ownedProjectURL: projectURL
            )
        )
        XCTAssertFalse(
            SidebarViewController.canManageProjectStorage(
                selectedItems: [root],
                currentProjectURL: projectURL,
                ownedProjectURL: nil
            )
        )
    }

    func testDetachedStorageWorkerRunsOffMain() async {
        let ranOnMain = await ProjectStorageCoordinator
            .testingRunDetached { Thread.isMainThread }
        XCTAssertFalse(ranOnMain)
    }

    func testDefaultCoordinatorScannerActuallyRunsOffMain() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ProjectStorageCoordinatorTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let temporary = root.appendingPathComponent(
            ".tmp",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: temporary,
            withIntermediateDirectories: true
        )
        try Data("fixture".utf8).write(
            to: temporary.appendingPathComponent("unowned.tmp")
        )
        let threads = LockedBoolRecorder()

        _ = try await ProjectStorageCoordinator.Operations().scan(root) {
            _ in threads.record(Thread.isMainThread)
        }

        XCTAssertFalse(threads.snapshot.isEmpty)
        XCTAssertTrue(threads.snapshot.allSatisfy { !$0 })
    }

    func testAcceptedScanProgressPerformsNoCanonicalOrIdentityFilesystemIO()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ProjectStorageIdentityBoundaryTests-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try DocumentManager.shared.createProject(
            at: root.appendingPathComponent(
                "Identity.lungfish",
                isDirectory: true
            ),
            name: "Identity"
        )
        let identity = try FileSystemObjectIdentity.noFollow(project.url)
        let session = ProjectSession()
        try session.openProject(at: project.url)
        let controller = MainWindowController(projectSession: session)
        defer { controller.close() }
        let canonicalReads = LockedBoolRecorder()
        let identityReads = LockedBoolRecorder()
        let deferredResult = DeferredScanResultHarness()
        let operations = ProjectStorageCoordinator.Operations(
            scan: { _, progress in
                progress(
                    .init(
                        visitedFileSystemObjects: 1,
                        classifiedEntries: 0,
                        logicalBytes: 0,
                        allocatedBytes: 0,
                        currentRelativePath: ".tmp/one"
                    )
                )
                progress(
                    .init(
                        visitedFileSystemObjects: 2,
                        classifiedEntries: 0,
                        logicalBytes: 0,
                        allocatedBytes: 0,
                        currentRelativePath: ".tmp/two"
                    )
                )
                return await deferredResult.wait()
            },
            canonicalizeProjectURL: { url in
                canonicalReads.record(Thread.isMainThread)
                return url.standardizedFileURL.resolvingSymlinksInPath()
            },
            readProjectIdentity: { url in
                identityReads.record(Thread.isMainThread)
                return try FileSystemObjectIdentity.noFollow(url)
            }
        )
        let coordinator = ProjectStorageCoordinator(
            presentingWindow: try XCTUnwrap(controller.window),
            controller: controller,
            projectURL: project.url,
            projectIdentity: identity,
            generation: 0,
            generationProvider: { 0 },
            operations: operations,
            completion: {}
        )

        XCTAssertTrue(coordinator.present())
        while !deferredResult.isWaiting
            || coordinator.viewModel.scanProgress == nil {
            await Task.yield()
        }

        XCTAssertEqual(canonicalReads.snapshot, [false])
        XCTAssertEqual(identityReads.snapshot, [false])
        deferredResult.resume(
            with: .init(projectIdentity: identity, entries: [])
        )
        while coordinator.viewModel.state == .scanning {
            await Task.yield()
        }

        XCTAssertEqual(coordinator.viewModel.state, .ready)
        XCTAssertEqual(canonicalReads.snapshot, [false])
        XCTAssertEqual(identityReads.snapshot, [false, false])
        _ = coordinator.viewModel.handleEscapeKey()
    }

    func testSymlinkOpenedProjectUsesCapturedCanonicalAuthorityForScan()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ProjectStorageSymlinkAuthorityTests-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let project = try DocumentManager.shared.createProject(
            at: root.appendingPathComponent(
                "Authority.lungfish",
                isDirectory: true
            ),
            name: "Authority"
        )
        let alias = root.appendingPathComponent(
            "Alias.lungfish",
            isDirectory: true
        )
        try FileManager.default.createSymbolicLink(
            at: alias,
            withDestinationURL: project.url
        )
        let canonical = alias.standardizedFileURL.resolvingSymlinksInPath()
        let identity = try FileSystemObjectIdentity.noFollow(canonical)
        let session = ProjectSession()
        try session.openProject(at: alias)
        XCTAssertEqual(session.projectURL?.standardizedFileURL.path, alias.path)
        let controller = MainWindowController(projectSession: session)
        defer { controller.close() }
        let scannedURLs = LockedURLRecorder()
        let coordinator = ProjectStorageCoordinator(
            presentingWindow: try XCTUnwrap(controller.window),
            controller: controller,
            projectURL: alias,
            projectIdentity: identity,
            generation: 0,
            generationProvider: { 0 },
            operations: .init(
                scan: { url, _ in
                    scannedURLs.record(url)
                    return .init(projectIdentity: identity, entries: [])
                }
            ),
            completion: {}
        )

        XCTAssertTrue(coordinator.present())
        while coordinator.viewModel.state == .scanning {
            await Task.yield()
        }

        XCTAssertEqual(coordinator.viewModel.state, .ready)
        XCTAssertEqual(scannedURLs.snapshot, [canonical])
        XCTAssertEqual(coordinator.viewModel.boundProjectURL, canonical)
        _ = coordinator.viewModel.handleEscapeKey()
    }

    func testSupersededRetryScanCannotRunCleanupOrOverwriteNewerScan()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ProjectStorageRetryGenerationTests-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try DocumentManager.shared.createProject(
            at: root.appendingPathComponent(
                "Retry.lungfish",
                isDirectory: true
            ),
            name: "Retry"
        )
        let identity = try FileSystemObjectIdentity.noFollow(project.url)
        let session = ProjectSession()
        try session.openProject(at: project.url)
        let controller = MainWindowController(projectSession: session)
        defer { controller.close() }
        let failed = entry(
            path: ".tmp/failed",
            category: .temporary
        )
        let newerResult = ProjectStorageScanResult(
            projectIdentity: identity,
            entries: []
        )
        let scans = OverlappingScanHarness(laterResult: newerResult)
        let cleanupCalls = LockedBoolRecorder()
        let operations = ProjectStorageCoordinator.Operations(
            scan: { _, _ in await scans.scan() },
            cleanup: { _ in
                cleanupCalls.record(true)
                throw NSError(
                    domain: "UnexpectedCleanup",
                    code: 1
                )
            }
        )
        let coordinator = ProjectStorageCoordinator(
            presentingWindow: try XCTUnwrap(controller.window),
            controller: controller,
            projectURL: project.url,
            projectIdentity: identity,
            generation: 0,
            generationProvider: { 0 },
            operations: operations,
            completion: {}
        )
        coordinator.viewModel.receiveScanResult(
            .init(projectIdentity: identity, entries: [failed])
        )
        coordinator.viewModel.receiveCleanupResult(
            summary: .init(
                cleanupID: UUID(),
                projectRoot: project.url.path,
                projectIdentity: identity,
                state: .completedWithFailures,
                items: [
                    .init(
                        itemID: failed.id,
                        sourceRelativePath: failed.relativePath,
                        state: .failed,
                        quarantineRelativePath: nil,
                        trashDestinationPath: nil,
                        reason: "Trash unavailable."
                    ),
                ],
                startedAt: Date(timeIntervalSince1970: 10),
                completedAt: Date(timeIntervalSince1970: 11),
                exitStatus: 1,
                wallTimeSeconds: 1,
                stderr: "Trash unavailable."
            ),
            summaryURL: project.url.appendingPathComponent("summary.json"),
            provenanceURL:
                project.url.appendingPathComponent("provenance.json")
        )

        coordinator.viewModel.retryFailed()
        while !scans.hasStartedFirstScan {
            await Task.yield()
        }
        coordinator.viewModel.receiveScanCancellation()
        coordinator.viewModel.retryScan()
        while coordinator.viewModel.state == .scanning {
            await Task.yield()
        }
        XCTAssertEqual(coordinator.viewModel.state, .ready)

        scans.resumeFirst(
            with: .init(projectIdentity: identity, entries: [failed])
        )
        for _ in 0..<10 {
            await Task.yield()
        }

        XCTAssertEqual(coordinator.viewModel.state, .ready)
        XCTAssertTrue(coordinator.viewModel.entries.isEmpty)
        XCTAssertTrue(cleanupCalls.snapshot.isEmpty)
        coordinator.invalidate()
    }

    func testRetryFailedRevalidationRelaysLocalizedProgress()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ProjectStorageRetryProgressTests-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try DocumentManager.shared.createProject(
            at: root.appendingPathComponent(
                "RetryProgress.lungfish",
                isDirectory: true
            ),
            name: "Retry Progress"
        )
        let identity = try FileSystemObjectIdentity.noFollow(project.url)
        let session = ProjectSession()
        try session.openProject(at: project.url)
        let controller = MainWindowController(projectSession: session)
        defer { controller.close() }
        let failed = entry(path: ".tmp/retry", category: .temporary)
        let expectedProgress = ProjectStorageScanProgress(
            visitedFileSystemObjects: 1_234,
            classifiedEntries: 56,
            logicalBytes: 1_000,
            allocatedBytes: 2_000,
            currentRelativePath: ".tmp/current-revalidation"
        )
        let deferredScan = DeferredScanResultHarness()
        let coordinator = ProjectStorageCoordinator(
            presentingWindow: try XCTUnwrap(controller.window),
            controller: controller,
            projectURL: project.url,
            projectIdentity: identity,
            generation: 0,
            generationProvider: { 0 },
            operations: .init(
                scan: { _, progress in
                    progress(expectedProgress)
                    return await deferredScan.wait()
                }
            ),
            completion: {}
        )
        coordinator.viewModel.receiveScanResult(
            .init(projectIdentity: identity, entries: [failed])
        )
        let originalSummaryURL = project.url.appendingPathComponent(
            "initial-summary.json"
        )
        let originalProvenanceURL = project.url.appendingPathComponent(
            "initial-provenance.json"
        )
        coordinator.viewModel.receiveCleanupResult(
            summary: .init(
                cleanupID: UUID(),
                projectRoot: project.url.path,
                projectIdentity: identity,
                state: .completedWithFailures,
                items: [
                    .init(
                        itemID: failed.id,
                        sourceRelativePath: failed.relativePath,
                        state: .failed,
                        quarantineRelativePath: nil,
                        trashDestinationPath: nil,
                        reason: "Initial failure."
                    ),
                ],
                startedAt: Date(timeIntervalSince1970: 8),
                completedAt: Date(timeIntervalSince1970: 9),
                exitStatus: 1,
                wallTimeSeconds: 1,
                stderr: "Initial failure."
            ),
            summaryURL: originalSummaryURL,
            provenanceURL: originalProvenanceURL
        )

        coordinator.viewModel.retryFailed()
        while !deferredScan.isWaiting {
            await Task.yield()
        }
        for _ in 0..<1_000
        where coordinator.viewModel.scanProgress == nil {
            await Task.yield()
        }

        XCTAssertEqual(coordinator.viewModel.state, .revalidating)
        XCTAssertEqual(coordinator.viewModel.scanProgress, expectedProgress)
        XCTAssertTrue(
            coordinator.viewModel.statusMessage.contains(
                ProjectStorageSheetViewModel.localizedCount(
                    expectedProgress.visitedFileSystemObjects
                )
            )
        )
        XCTAssertTrue(
            coordinator.viewModel.statusMessage.contains(
                ProjectStorageSheetViewModel.localizedByteCount(
                    expectedProgress.allocatedBytes
                )
            )
        )
        XCTAssertTrue(
            coordinator.viewModel.statusMessage.contains(
                expectedProgress.currentRelativePath
            )
        )
        XCTAssertEqual(
            coordinator.viewModel.receiptURL,
            originalSummaryURL
        )
        XCTAssertEqual(
            coordinator.viewModel.provenanceURL,
            originalProvenanceURL
        )

        deferredScan.resume(
            with: .init(projectIdentity: identity, entries: [])
        )
        while coordinator.viewModel.state == .revalidating {
            await Task.yield()
        }
        coordinator.invalidate()
    }

    func testStopDuringRetryRevalidationRetainsFailedResultAndCanRetryAgain()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ProjectStorageRetryStopTests-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try DocumentManager.shared.createProject(
            at: root.appendingPathComponent(
                "RetryStop.lungfish",
                isDirectory: true
            ),
            name: "Retry Stop"
        )
        let identity = try FileSystemObjectIdentity.noFollow(project.url)
        let session = ProjectSession()
        try session.openProject(at: project.url)
        let controller = MainWindowController(projectSession: session)
        defer { controller.close() }
        let failed = entry(path: ".tmp/retry", category: .temporary)
        let scanStarts = LockedBoolRecorder()
        let cleanupCalls = LockedBoolRecorder()
        let coordinator = ProjectStorageCoordinator(
            presentingWindow: try XCTUnwrap(controller.window),
            controller: controller,
            projectURL: project.url,
            projectIdentity: identity,
            generation: 0,
            generationProvider: { 0 },
            operations: .init(
                scan: { _, _ in
                    scanStarts.record(true)
                    try await Task.sleep(for: .seconds(5))
                    return .init(
                        projectIdentity: identity,
                        entries: [failed]
                    )
                },
                cleanup: { _ in
                    cleanupCalls.record(true)
                    throw NSError(
                        domain: "UnexpectedCleanup",
                        code: 1
                    )
                }
            ),
            completion: {}
        )
        coordinator.viewModel.receiveScanResult(
            .init(projectIdentity: identity, entries: [failed])
        )
        let originalSummaryURL = project.url.appendingPathComponent(
            "initial-summary.json"
        )
        let originalProvenanceURL = project.url.appendingPathComponent(
            "initial-provenance.json"
        )
        coordinator.viewModel.receiveCleanupResult(
            summary: .init(
                cleanupID: UUID(),
                projectRoot: project.url.path,
                projectIdentity: identity,
                state: .completedWithFailures,
                items: [
                    .init(
                        itemID: failed.id,
                        sourceRelativePath: failed.relativePath,
                        state: .failed,
                        quarantineRelativePath: nil,
                        trashDestinationPath: nil,
                        reason: "Initial failure."
                    ),
                ],
                startedAt: Date(timeIntervalSince1970: 8),
                completedAt: Date(timeIntervalSince1970: 9),
                exitStatus: 1,
                wallTimeSeconds: 1,
                stderr: "Initial failure."
            ),
            summaryURL: originalSummaryURL,
            provenanceURL: originalProvenanceURL
        )
        let originalCleanupItems = coordinator.viewModel.cleanupItems

        coordinator.viewModel.retryFailed()
        while scanStarts.snapshot.count < 1 {
            await Task.yield()
        }
        XCTAssertTrue(coordinator.viewModel.handleEscapeKey())
        while coordinator.viewModel.state == .revalidating {
            await Task.yield()
        }

        XCTAssertEqual(coordinator.viewModel.state, .finished)
        XCTAssertEqual(coordinator.viewModel.entries, [failed])
        XCTAssertEqual(coordinator.viewModel.failedEntries, [failed])
        XCTAssertEqual(coordinator.viewModel.receiptURL, originalSummaryURL)
        XCTAssertEqual(
            coordinator.viewModel.provenanceURL,
            originalProvenanceURL
        )
        XCTAssertEqual(
            coordinator.viewModel.cleanupItems,
            originalCleanupItems
        )
        XCTAssertTrue(coordinator.viewModel.canRetryFailed)
        XCTAssertTrue(
            coordinator.viewModel.statusMessage.contains(
                "Revalidation stopped"
            )
        )
        XCTAssertTrue(
            coordinator.viewModel.statusMessage.contains(
                "failed entries remain available"
            )
        )
        XCTAssertFalse(
            coordinator.viewModel.statusMessage.contains("Cleanup failed")
        )
        XCTAssertTrue(cleanupCalls.snapshot.isEmpty)

        coordinator.viewModel.retryFailed()
        for _ in 0..<1_000 where scanStarts.snapshot.count < 2 {
            await Task.yield()
        }
        XCTAssertEqual(scanStarts.snapshot.count, 2)
        XCTAssertEqual(coordinator.viewModel.state, .revalidating)
        XCTAssertFalse(coordinator.viewModel.canRetryFailed)
        coordinator.invalidate()
    }

    func testStopDuringSecondRetryAuthorityReadCannotStartCleanup()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ProjectStorageRetryAuthorityStopTests-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try DocumentManager.shared.createProject(
            at: root.appendingPathComponent(
                "RetryAuthorityStop.lungfish",
                isDirectory: true
            ),
            name: "Retry Authority Stop"
        )
        let identity = try FileSystemObjectIdentity.noFollow(project.url)
        let session = ProjectSession()
        try session.openProject(at: project.url)
        let controller = MainWindowController(projectSession: session)
        defer { controller.close() }
        let failed = entry(path: ".tmp/retry", category: .temporary)
        let identityReads = SecondIdentityReadBarrier()
        let cleanupCalls = LockedBoolRecorder()
        let coordinator = ProjectStorageCoordinator(
            presentingWindow: try XCTUnwrap(controller.window),
            controller: controller,
            projectURL: project.url,
            projectIdentity: identity,
            generation: 0,
            generationProvider: { 0 },
            operations: .init(
                scan: { _, _ in
                    .init(projectIdentity: identity, entries: [failed])
                },
                cleanup: { _ in
                    cleanupCalls.record(true)
                    throw CancellationError()
                },
                readProjectIdentity: { url in
                    try identityReads.read(url)
                }
            ),
            completion: {}
        )
        coordinator.viewModel.receiveScanResult(
            .init(projectIdentity: identity, entries: [failed])
        )
        let summaryURL = project.url.appendingPathComponent(
            "initial-summary.json"
        )
        let provenanceURL = project.url.appendingPathComponent(
            "initial-provenance.json"
        )
        receiveFailedCleanup(
            on: coordinator.viewModel,
            projectURL: project.url,
            projectIdentity: identity,
            failedEntry: failed,
            summaryURL: summaryURL,
            provenanceURL: provenanceURL
        )
        let originalCleanupItems = coordinator.viewModel.cleanupItems

        coordinator.viewModel.retryFailed()
        while !identityReads.isSecondReadWaiting {
            await Task.yield()
        }
        XCTAssertTrue(coordinator.viewModel.handleEscapeKey())
        XCTAssertEqual(
            coordinator.viewModel.statusMessage,
            "Stopping revalidation…"
        )
        identityReads.resumeSecondRead()
        while coordinator.viewModel.state == .revalidating {
            await Task.yield()
        }
        for _ in 0..<1_000 {
            if !cleanupCalls.snapshot.isEmpty
                && coordinator.viewModel.state != .cleaning {
                break
            }
            await Task.yield()
        }

        XCTAssertTrue(cleanupCalls.snapshot.isEmpty)
        XCTAssertEqual(coordinator.viewModel.state, .finished)
        XCTAssertEqual(coordinator.viewModel.entries, [failed])
        XCTAssertEqual(coordinator.viewModel.failedEntries, [failed])
        XCTAssertEqual(coordinator.viewModel.receiptURL, summaryURL)
        XCTAssertEqual(coordinator.viewModel.provenanceURL, provenanceURL)
        XCTAssertEqual(
            coordinator.viewModel.cleanupItems,
            originalCleanupItems
        )
        XCTAssertTrue(coordinator.viewModel.canRetryFailed)
        XCTAssertTrue(
            coordinator.viewModel.statusMessage.contains(
                "Revalidation stopped"
            )
        )
        coordinator.invalidate()
    }

    func testRetryRevalidationScanErrorRetainsFailedResult()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ProjectStorageRetryErrorTests-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try DocumentManager.shared.createProject(
            at: root.appendingPathComponent(
                "RetryError.lungfish",
                isDirectory: true
            ),
            name: "Retry Error"
        )
        let identity = try FileSystemObjectIdentity.noFollow(project.url)
        let session = ProjectSession()
        try session.openProject(at: project.url)
        let controller = MainWindowController(projectSession: session)
        defer { controller.close() }
        let failed = entry(path: ".tmp/retry", category: .temporary)
        let cleanupCalls = LockedBoolRecorder()
        let coordinator = ProjectStorageCoordinator(
            presentingWindow: try XCTUnwrap(controller.window),
            controller: controller,
            projectURL: project.url,
            projectIdentity: identity,
            generation: 0,
            generationProvider: { 0 },
            operations: .init(
                scan: { _, _ in
                    throw NSError(
                        domain: "RetryRevalidationTests",
                        code: 17,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Fresh inspection unavailable.",
                        ]
                    )
                },
                cleanup: { _ in
                    cleanupCalls.record(true)
                    throw NSError(
                        domain: "UnexpectedCleanup",
                        code: 1
                    )
                }
            ),
            completion: {}
        )
        coordinator.viewModel.receiveScanResult(
            .init(projectIdentity: identity, entries: [failed])
        )
        let originalSummaryURL = project.url.appendingPathComponent(
            "initial-summary.json"
        )
        let originalProvenanceURL = project.url.appendingPathComponent(
            "initial-provenance.json"
        )
        coordinator.viewModel.receiveCleanupResult(
            summary: .init(
                cleanupID: UUID(),
                projectRoot: project.url.path,
                projectIdentity: identity,
                state: .completedWithFailures,
                items: [
                    .init(
                        itemID: failed.id,
                        sourceRelativePath: failed.relativePath,
                        state: .failed,
                        quarantineRelativePath: nil,
                        trashDestinationPath: nil,
                        reason: "Initial failure."
                    ),
                ],
                startedAt: Date(timeIntervalSince1970: 8),
                completedAt: Date(timeIntervalSince1970: 9),
                exitStatus: 1,
                wallTimeSeconds: 1,
                stderr: "Initial failure."
            ),
            summaryURL: originalSummaryURL,
            provenanceURL: originalProvenanceURL
        )

        coordinator.viewModel.retryFailed()
        while coordinator.viewModel.state == .revalidating {
            await Task.yield()
        }

        XCTAssertEqual(coordinator.viewModel.state, .finished)
        XCTAssertEqual(coordinator.viewModel.entries, [failed])
        XCTAssertEqual(coordinator.viewModel.failedEntries, [failed])
        XCTAssertEqual(coordinator.viewModel.receiptURL, originalSummaryURL)
        XCTAssertEqual(
            coordinator.viewModel.provenanceURL,
            originalProvenanceURL
        )
        XCTAssertTrue(coordinator.viewModel.canRetryFailed)
        XCTAssertTrue(
            coordinator.viewModel.statusMessage.contains(
                "Revalidation failed"
            )
        )
        XCTAssertTrue(
            coordinator.viewModel.statusMessage.contains(
                "Fresh inspection unavailable."
            )
        )
        XCTAssertTrue(
            coordinator.viewModel.statusMessage.contains(
                "failed entries remain available"
            )
        )
        XCTAssertFalse(
            coordinator.viewModel.statusMessage.contains("Cleanup failed")
        )
        XCTAssertTrue(cleanupCalls.snapshot.isEmpty)
        coordinator.invalidate()
    }

    func testStopDuringCleanupAcceptsRecoveredDurableOutcome() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ProjectStorageRecoveredStopTests-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try DocumentManager.shared.createProject(
            at: root.appendingPathComponent(
                "Recovered.lungfish",
                isDirectory: true
            ),
            name: "Recovered"
        )
        let identity = try FileSystemObjectIdentity.noFollow(project.url)
        let session = ProjectSession()
        try session.openProject(at: project.url)
        let controller = MainWindowController(projectSession: session)
        defer { controller.close() }
        let failed = entry(path: ".tmp/failed", category: .temporary)
        let cleanup = DeferredCleanupHarness()
        let coordinator = ProjectStorageCoordinator(
            presentingWindow: try XCTUnwrap(controller.window),
            controller: controller,
            projectURL: project.url,
            projectIdentity: identity,
            generation: 0,
            generationProvider: { 0 },
            operations: .init(
                cleanup: { invocation in
                    await cleanup.wait(for: invocation)
                }
            ),
            completion: {}
        )
        coordinator.viewModel.receiveScanResult(
            .init(projectIdentity: identity, entries: [failed])
        )

        coordinator.viewModel.beginCleanup()
        while cleanup.invocation == nil {
            await Task.yield()
        }
        XCTAssertTrue(coordinator.viewModel.handleEscapeKey())
        let invocation = try XCTUnwrap(cleanup.invocation)
        let summaryURL = project.url.appendingPathComponent(
            "execution-summary.json"
        )
        let provenanceURL = project.url.appendingPathComponent(
            "execution-provenance.json"
        )
        cleanup.resume(
            with: .init(
                cleanupID: invocation.cleanupID,
                summary: .init(
                    cleanupID: invocation.cleanupID,
                    projectRoot: project.url.path,
                    projectIdentity: identity,
                    state: .completedWithFailures,
                    items: [
                        .init(
                            itemID: failed.id,
                            sourceRelativePath: failed.relativePath,
                            state: .failed,
                            quarantineRelativePath: nil,
                            trashDestinationPath: nil,
                            reason: "Stopped after durable partial work."
                        ),
                    ],
                    startedAt: Date(timeIntervalSince1970: 10),
                    completedAt: Date(timeIntervalSince1970: 11),
                    exitStatus: 130,
                    wallTimeSeconds: 1,
                    stderr: "Cancelled."
                ),
                summaryURL: summaryURL,
                provenanceURL: provenanceURL
            )
        )
        while coordinator.viewModel.state == .cleaning {
            await Task.yield()
        }

        XCTAssertEqual(coordinator.viewModel.state, .finished)
        XCTAssertEqual(coordinator.viewModel.receiptURL, summaryURL)
        XCTAssertEqual(coordinator.viewModel.provenanceURL, provenanceURL)
        XCTAssertEqual(coordinator.viewModel.failedEntries, [failed])
        XCTAssertTrue(coordinator.viewModel.canRetryFailed)
        coordinator.invalidate()
    }

    func testStopDuringRetryCleanupAcceptsRecoveredDurableOutcome()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ProjectStorageRecoveredRetryTests-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try DocumentManager.shared.createProject(
            at: root.appendingPathComponent(
                "RecoveredRetry.lungfish",
                isDirectory: true
            ),
            name: "Recovered Retry"
        )
        let identity = try FileSystemObjectIdentity.noFollow(project.url)
        let session = ProjectSession()
        try session.openProject(at: project.url)
        let controller = MainWindowController(projectSession: session)
        defer { controller.close() }
        let failed = entry(path: ".tmp/retry", category: .temporary)
        let cleanup = DeferredCleanupHarness()
        let coordinator = ProjectStorageCoordinator(
            presentingWindow: try XCTUnwrap(controller.window),
            controller: controller,
            projectURL: project.url,
            projectIdentity: identity,
            generation: 0,
            generationProvider: { 0 },
            operations: .init(
                scan: { _, _ in
                    .init(projectIdentity: identity, entries: [failed])
                },
                cleanup: { invocation in
                    await cleanup.wait(for: invocation)
                }
            ),
            completion: {}
        )
        coordinator.viewModel.receiveScanResult(
            .init(projectIdentity: identity, entries: [failed])
        )
        coordinator.viewModel.receiveCleanupResult(
            summary: .init(
                cleanupID: UUID(),
                projectRoot: project.url.path,
                projectIdentity: identity,
                state: .completedWithFailures,
                items: [
                    .init(
                        itemID: failed.id,
                        sourceRelativePath: failed.relativePath,
                        state: .failed,
                        quarantineRelativePath: nil,
                        trashDestinationPath: nil,
                        reason: "Initial failure."
                    ),
                ],
                startedAt: Date(timeIntervalSince1970: 8),
                completedAt: Date(timeIntervalSince1970: 9),
                exitStatus: 1,
                wallTimeSeconds: 1,
                stderr: "Initial failure."
            ),
            summaryURL: project.url.appendingPathComponent(
                "initial-summary.json"
            ),
            provenanceURL: project.url.appendingPathComponent(
                "initial-provenance.json"
            )
        )

        coordinator.viewModel.retryFailed()
        while cleanup.invocation == nil {
            await Task.yield()
        }
        XCTAssertEqual(coordinator.viewModel.state, .cleaning)
        XCTAssertTrue(coordinator.viewModel.handleEscapeKey())
        let invocation = try XCTUnwrap(cleanup.invocation)
        let recoveredSummaryURL = project.url.appendingPathComponent(
            "retry-summary.json"
        )
        cleanup.resume(
            with: .init(
                cleanupID: invocation.cleanupID,
                summary: .init(
                    cleanupID: invocation.cleanupID,
                    projectRoot: project.url.path,
                    projectIdentity: identity,
                    state: .completedWithFailures,
                    items: [
                        .init(
                            itemID: failed.id,
                            sourceRelativePath: failed.relativePath,
                            state: .failed,
                            quarantineRelativePath: nil,
                            trashDestinationPath: nil,
                            reason: "Retry stopped with durable receipt."
                        ),
                    ],
                    startedAt: Date(timeIntervalSince1970: 10),
                    completedAt: Date(timeIntervalSince1970: 11),
                    exitStatus: 130,
                    wallTimeSeconds: 1,
                    stderr: "Cancelled."
                ),
                summaryURL: recoveredSummaryURL,
                provenanceURL: project.url.appendingPathComponent(
                    "retry-provenance.json"
                )
            )
        )
        while coordinator.viewModel.state == .cleaning {
            await Task.yield()
        }

        XCTAssertEqual(coordinator.viewModel.state, .finished)
        XCTAssertEqual(
            coordinator.viewModel.receiptURL,
            recoveredSummaryURL
        )
        XCTAssertTrue(coordinator.viewModel.canRetryFailed)
        coordinator.invalidate()
    }

    func testSupersededCleanupCannotApplyRecoveredDurableOutcome()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ProjectStorageSupersededRecoveryTests-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try DocumentManager.shared.createProject(
            at: root.appendingPathComponent(
                "Superseded.lungfish",
                isDirectory: true
            ),
            name: "Superseded"
        )
        let identity = try FileSystemObjectIdentity.noFollow(project.url)
        let session = ProjectSession()
        try session.openProject(at: project.url)
        let controller = MainWindowController(projectSession: session)
        defer { controller.close() }
        let selected = entry(path: ".tmp/selected", category: .temporary)
        let cleanup = DeferredCleanupHarness()
        let cleanupReturned = LockedBoolRecorder()
        let completionCount = ValueBox(0)
        let coordinator = ProjectStorageCoordinator(
            presentingWindow: try XCTUnwrap(controller.window),
            controller: controller,
            projectURL: project.url,
            projectIdentity: identity,
            generation: 0,
            generationProvider: { 0 },
            operations: .init(
                scan: { _, _ in
                    .init(projectIdentity: identity, entries: [])
                },
                cleanup: { invocation in
                    let outcome = await cleanup.wait(for: invocation)
                    cleanupReturned.record(true)
                    return outcome
                }
            ),
            completion: { completionCount.value += 1 }
        )
        coordinator.viewModel.receiveScanResult(
            .init(projectIdentity: identity, entries: [selected])
        )

        coordinator.viewModel.beginCleanup()
        while cleanup.invocation == nil {
            await Task.yield()
        }
        let invocation = try XCTUnwrap(cleanup.invocation)
        coordinator.viewModel.receiveScanCancellation()
        coordinator.viewModel.retryScan()
        while coordinator.viewModel.state == .scanning {
            await Task.yield()
        }
        XCTAssertEqual(coordinator.viewModel.state, .ready)
        cleanup.resume(
            with: .init(
                cleanupID: invocation.cleanupID,
                summary: .init(
                    cleanupID: invocation.cleanupID,
                    projectRoot: project.url.path,
                    projectIdentity: identity,
                    state: .completed,
                    items: [],
                    startedAt: Date(timeIntervalSince1970: 10),
                    completedAt: Date(timeIntervalSince1970: 11),
                    exitStatus: 0,
                    wallTimeSeconds: 1,
                    stderr: ""
                ),
                summaryURL:
                    project.url.appendingPathComponent("stale-summary.json"),
                provenanceURL:
                    project.url.appendingPathComponent("stale-provenance.json")
            )
        )
        while cleanupReturned.snapshot.isEmpty {
            await Task.yield()
        }
        for _ in 0..<100 {
            await Task.yield()
        }

        XCTAssertEqual(coordinator.viewModel.state, .ready)
        XCTAssertNil(coordinator.viewModel.receiptURL)
        XCTAssertEqual(completionCount.value, 0)
        coordinator.invalidate()
    }

    func testCancellationRecoveryUsesNewestPairedVerifiedReceipt() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ProjectStorageRecoveryTests-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let cleanupID = UUID()
        let pairedSummary = ProjectStorageCleanupExecutionSummary(
            cleanupID: cleanupID,
            projectRoot: projectURL.path,
            projectIdentity: projectIdentity,
            state: .failed,
            items: [],
            startedAt: Date(timeIntervalSince1970: 10),
            completedAt: Date(timeIntervalSince1970: 11),
            exitStatus: 130,
            wallTimeSeconds: 1,
            stderr: "Cancelled."
        )
        let newerUnpairedSummary = ProjectStorageCleanupExecutionSummary(
            cleanupID: cleanupID,
            projectRoot: projectURL.path,
            projectIdentity: projectIdentity,
            state: .failed,
            items: [],
            startedAt: Date(timeIntervalSince1970: 12),
            completedAt: Date(timeIntervalSince1970: 13),
            exitStatus: 130,
            wallTimeSeconds: 1,
            stderr: "Cancelled."
        )
        let pairedSummaryURL = directory.appendingPathComponent(
            "execution-summary-00000001.json"
        )
        let pairedSummaryData = try ProvenanceJSON.encoder.encode(
            pairedSummary
        )
        try pairedSummaryData.write(to: pairedSummaryURL)
        let provenance = ProvenanceEnvelope(
            id: cleanupID,
            workflowName: "Manage Project Storage",
            toolName: "Lungfish",
            outputs: [
                .init(
                    path: pairedSummaryURL.path,
                    checksumSHA256:
                        try ProvenanceFileHasher.sha256(of: pairedSummaryURL),
                    fileSize: UInt64(pairedSummaryData.count),
                    format: .json,
                    role: .output
                ),
            ]
        )
        try ProvenanceJSON.encoder.encode(provenance).write(
            to: directory.appendingPathComponent(
                "execution-provenance-00000001.json"
            )
        )
        try ProvenanceJSON.encoder.encode(newerUnpairedSummary).write(
            to: directory.appendingPathComponent(
                "execution-summary-00000002.json"
            )
        )

        let outcome = try ProjectStorageCoordinator
            .testingLatestPublishedCleanupOutcome(
                operationDirectoryURL: directory,
                expectedOperationDirectoryIdentity:
                    try FileSystemObjectIdentity.noFollow(directory),
                cleanupID: cleanupID
            )

        XCTAssertEqual(
            outcome.summaryURL.lastPathComponent,
            "execution-summary-00000001.json"
        )
        XCTAssertEqual(
            outcome.provenanceURL.lastPathComponent,
            "execution-provenance-00000001.json"
        )
        XCTAssertEqual(outcome.cleanupID, cleanupID)
    }

    func testCancellationRecoveryRejectsMissingSummaryOutputDescriptor()
        throws
    {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ProjectStorageMissingDescriptorTests-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let cleanupID = UUID()
        let summary = ProjectStorageCleanupExecutionSummary(
            cleanupID: cleanupID,
            projectRoot: projectURL.path,
            projectIdentity: projectIdentity,
            state: .failed,
            items: [],
            startedAt: Date(timeIntervalSince1970: 10),
            completedAt: Date(timeIntervalSince1970: 11),
            exitStatus: 130,
            wallTimeSeconds: 1,
            stderr: "Cancelled."
        )
        try ProvenanceJSON.encoder.encode(summary).write(
            to: directory.appendingPathComponent(
                "execution-summary-00000001.json"
            )
        )
        try ProvenanceJSON.encoder.encode(
            ProvenanceEnvelope(
                id: cleanupID,
                workflowName: "Manage Project Storage",
                toolName: "Lungfish"
            )
        ).write(
            to: directory.appendingPathComponent(
                "execution-provenance-00000001.json"
            )
        )

        XCTAssertThrowsError(
            try ProjectStorageCoordinator
                .testingLatestPublishedCleanupOutcome(
                    operationDirectoryURL: directory,
                    expectedOperationDirectoryIdentity:
                        try FileSystemObjectIdentity.noFollow(directory),
                    cleanupID: cleanupID
                )
        )
    }

    func testCancellationRecoveryRejectsTamperedSummaryDescriptor() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ProjectStorageTamperedDescriptorTests-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let cleanupID = UUID()
        let summaryURL = directory.appendingPathComponent(
            "execution-summary-00000001.json"
        )
        let summary = ProjectStorageCleanupExecutionSummary(
            cleanupID: cleanupID,
            projectRoot: projectURL.path,
            projectIdentity: projectIdentity,
            state: .failed,
            items: [],
            startedAt: Date(timeIntervalSince1970: 10),
            completedAt: Date(timeIntervalSince1970: 11),
            exitStatus: 130,
            wallTimeSeconds: 1,
            stderr: "Cancelled."
        )
        let originalData = try ProvenanceJSON.encoder.encode(summary)
        try originalData.write(to: summaryURL)
        let provenance = ProvenanceEnvelope(
            id: cleanupID,
            workflowName: "Manage Project Storage",
            toolName: "Lungfish",
            outputs: [
                .init(
                    path: summaryURL.path,
                    checksumSHA256:
                        try ProvenanceFileHasher.sha256(of: summaryURL),
                    fileSize: UInt64(originalData.count),
                    format: .json,
                    role: .output
                ),
            ]
        )
        try ProvenanceJSON.encoder.encode(provenance).write(
            to: directory.appendingPathComponent(
                "execution-provenance-00000001.json"
            )
        )
        let tampered = ProjectStorageCleanupExecutionSummary(
            cleanupID: cleanupID,
            projectRoot: projectURL.path,
            projectIdentity: projectIdentity,
            state: .failed,
            items: [],
            startedAt: Date(timeIntervalSince1970: 10),
            completedAt: Date(timeIntervalSince1970: 11),
            exitStatus: 130,
            wallTimeSeconds: 1,
            stderr: "Tampered after publication."
        )
        try ProvenanceJSON.encoder.encode(tampered).write(to: summaryURL)

        XCTAssertThrowsError(
            try ProjectStorageCoordinator
                .testingLatestPublishedCleanupOutcome(
                    operationDirectoryURL: directory,
                    expectedOperationDirectoryIdentity:
                        try FileSystemObjectIdentity.noFollow(directory),
                    cleanupID: cleanupID
                )
        )
    }

    func testCancellationRecoveryRejectsDescriptorForDifferentSummaryPath()
        throws
    {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ProjectStorageWrongDescriptorPathTests-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let cleanupID = UUID()
        let summaryURL = directory.appendingPathComponent(
            "execution-summary-00000001.json"
        )
        let summary = ProjectStorageCleanupExecutionSummary(
            cleanupID: cleanupID,
            projectRoot: projectURL.path,
            projectIdentity: projectIdentity,
            state: .failed,
            items: [],
            startedAt: Date(timeIntervalSince1970: 10),
            completedAt: Date(timeIntervalSince1970: 11),
            exitStatus: 130,
            wallTimeSeconds: 1,
            stderr: "Cancelled."
        )
        let summaryData = try ProvenanceJSON.encoder.encode(summary)
        try summaryData.write(to: summaryURL)
        let provenance = ProvenanceEnvelope(
            id: cleanupID,
            workflowName: "Manage Project Storage",
            toolName: "Lungfish",
            outputs: [
                .init(
                    path: directory.appendingPathComponent(
                        "different-summary.json"
                    ).path,
                    checksumSHA256:
                        try ProvenanceFileHasher.sha256(of: summaryURL),
                    fileSize: UInt64(summaryData.count),
                    format: .json,
                    role: .output
                ),
            ]
        )
        try ProvenanceJSON.encoder.encode(provenance).write(
            to: directory.appendingPathComponent(
                "execution-provenance-00000001.json"
            )
        )

        XCTAssertThrowsError(
            try ProjectStorageCoordinator
                .testingLatestPublishedCleanupOutcome(
                    operationDirectoryURL: directory,
                    expectedOperationDirectoryIdentity:
                        try FileSystemObjectIdentity.noFollow(directory),
                    cleanupID: cleanupID
                )
        )
    }

    func testCancellationRecoveryRejectsSymlinkedOperationDirectory()
        throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ProjectStorageSymlinkedRecoveryDirectoryTests-"
                    + UUID().uuidString,
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let actualDirectory = root.appendingPathComponent(
            "actual",
            isDirectory: true
        )
        let operationDirectory = root.appendingPathComponent(
            "operation",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: actualDirectory,
            withIntermediateDirectories: false
        )
        try FileManager.default.createSymbolicLink(
            at: operationDirectory,
            withDestinationURL: actualDirectory
        )
        let cleanupID = UUID()
        try writeCancellationReceiptPair(
            in: actualDirectory,
            descriptorDirectory: operationDirectory,
            cleanupID: cleanupID
        )

        XCTAssertThrowsError(
            try ProjectStorageCoordinator
                .testingLatestPublishedCleanupOutcome(
                    operationDirectoryURL: operationDirectory,
                    expectedOperationDirectoryIdentity:
                        try FileSystemObjectIdentity.noFollow(
                            actualDirectory
                        ),
                    cleanupID: cleanupID
                )
        )
    }

    func testCancellationRecoveryRejectsSymlinkedSummary() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ProjectStorageSymlinkedRecoverySummaryTests-"
                    + UUID().uuidString,
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let cleanupID = UUID()
        let pair = try writeCancellationReceiptPair(
            in: directory,
            cleanupID: cleanupID
        )
        let target = directory.appendingPathComponent(
            "summary-target.json"
        )
        try FileManager.default.moveItem(at: pair.summaryURL, to: target)
        try FileManager.default.createSymbolicLink(
            at: pair.summaryURL,
            withDestinationURL: target
        )

        XCTAssertThrowsError(
            try ProjectStorageCoordinator
                .testingLatestPublishedCleanupOutcome(
                    operationDirectoryURL: directory,
                    expectedOperationDirectoryIdentity:
                        try FileSystemObjectIdentity.noFollow(directory),
                    cleanupID: cleanupID
                )
        )
    }

    func testCancellationRecoveryRejectsSymlinkedProvenance() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ProjectStorageSymlinkedRecoveryProvenanceTests-"
                    + UUID().uuidString,
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let cleanupID = UUID()
        let pair = try writeCancellationReceiptPair(
            in: directory,
            cleanupID: cleanupID
        )
        let target = directory.appendingPathComponent(
            "provenance-target.json"
        )
        try FileManager.default.moveItem(at: pair.provenanceURL, to: target)
        try FileManager.default.createSymbolicLink(
            at: pair.provenanceURL,
            withDestinationURL: target
        )

        XCTAssertThrowsError(
            try ProjectStorageCoordinator
                .testingLatestPublishedCleanupOutcome(
                    operationDirectoryURL: directory,
                    expectedOperationDirectoryIdentity:
                        try FileSystemObjectIdentity.noFollow(directory),
                    cleanupID: cleanupID
                )
        )
    }

    private func makeModel(
        bindingGeneration: UInt64 = 0,
        bindingIsCurrent: @escaping @MainActor () -> Bool = { true },
        progressThrottleInterval: TimeInterval = 0.1,
        allowsCleanup: Bool = true,
        requestCleanup: @escaping @MainActor () -> Void = {},
        requestClose: @escaping @MainActor () -> Void = {},
        requestCancellation: @escaping @MainActor () -> Void = {},
        requestRetryScan: @escaping @MainActor () -> Void = {},
        requestRetryFailed:
            @escaping @MainActor ([ProjectStorageEntry]) -> Void = { _ in },
        requestReveal: @escaping @MainActor (URL) -> Void = { _ in }
    ) -> ProjectStorageSheetViewModel {
        ProjectStorageSheetViewModel(
            projectURL: projectURL,
            projectIdentity: projectIdentity,
            bindingGeneration: bindingGeneration,
            progressThrottleInterval: progressThrottleInterval,
            allowsCleanup: allowsCleanup,
            bindingIsCurrent: bindingIsCurrent,
            requestCleanup: requestCleanup,
            requestClose: requestClose,
            requestCancellation: requestCancellation,
            requestRetryScan: requestRetryScan,
            requestRetryFailed: requestRetryFailed,
            requestReveal: requestReveal
        )
    }

    private func entry(
        path: String,
        category: ProjectStorageEntry.Category,
        logical: UInt64 = 1_000,
        allocated: UInt64 = 4_096,
        classification: ProjectStorageClassification = .removable(
            .completedOwnedWork,
            reason: "Completed and unlocked."
        )
    ) -> ProjectStorageEntry {
        ProjectStorageEntry(
            projectIdentity: projectIdentity,
            relativePath: path,
            identity: .init(
                device: projectIdentity.device,
                inode: UInt64(bitPattern: Int64(path.hashValue))
            ),
            category: category,
            logicalBytes: logical,
            allocatedBytes: allocated,
            modificationDate: Date(timeIntervalSince1970: 100),
            classification: classification
        )
    }

    private func progress(
        visited: UInt64,
        path: String
    ) -> ProjectStorageScanProgress {
        .init(
            visitedFileSystemObjects: visited,
            classifiedEntries: visited,
            logicalBytes: visited * 10,
            allocatedBytes: visited * 20,
            currentRelativePath: path
        )
    }

    private func executionResult(
        entries: [ProjectStorageEntry],
        states: [ProjectStorageCleanupDispositionRecord.State],
        trashDestinationPath: String,
        summaryURL: URL,
        provenanceURL: URL
    ) -> (
        summary: ProjectStorageCleanupExecutionSummary,
        summaryURL: URL,
        provenanceURL: URL
    ) {
        let items = zip(entries, states).map { entry, state in
            ProjectStorageCleanupExecutionSummary.Item(
                itemID: entry.id,
                sourceRelativePath: entry.relativePath,
                state: state,
                quarantineRelativePath: nil,
                trashDestinationPath:
                    state == .movedToTrash
                    ? trashDestinationPath
                    : nil,
                reason: state == .failed ? "Trash unavailable." : nil
            )
        }
        return (
            summary: .init(
                cleanupID: UUID(),
                projectRoot: projectURL.path,
                projectIdentity: projectIdentity,
                state: .completedWithFailures,
                items: items,
                startedAt: Date(timeIntervalSince1970: 10),
                completedAt: Date(timeIntervalSince1970: 11),
                exitStatus: 1,
                wallTimeSeconds: 1,
                stderr: "Trash unavailable."
            ),
            summaryURL: summaryURL,
            provenanceURL: provenanceURL
        )
    }

    private func receiveFailedCleanup(
        on model: ProjectStorageSheetViewModel,
        projectURL: URL,
        projectIdentity: FileSystemObjectIdentity,
        failedEntry: ProjectStorageEntry,
        summaryURL: URL,
        provenanceURL: URL
    ) {
        model.receiveCleanupResult(
            summary: .init(
                cleanupID: UUID(),
                projectRoot: projectURL.path,
                projectIdentity: projectIdentity,
                state: .completedWithFailures,
                items: [
                    .init(
                        itemID: failedEntry.id,
                        sourceRelativePath: failedEntry.relativePath,
                        state: .failed,
                        quarantineRelativePath: nil,
                        trashDestinationPath: nil,
                        reason: "Initial failure."
                    ),
                ],
                startedAt: Date(timeIntervalSince1970: 8),
                completedAt: Date(timeIntervalSince1970: 9),
                exitStatus: 1,
                wallTimeSeconds: 1,
                stderr: "Initial failure."
            ),
            summaryURL: summaryURL,
            provenanceURL: provenanceURL
        )
    }

    @discardableResult
    private func writeCancellationReceiptPair(
        in directory: URL,
        descriptorDirectory: URL? = nil,
        cleanupID: UUID
    ) throws -> (summaryURL: URL, provenanceURL: URL) {
        let summaryURL = directory.appendingPathComponent(
            "execution-summary-00000001.json"
        )
        let descriptorSummaryURL = (descriptorDirectory ?? directory)
            .appendingPathComponent("execution-summary-00000001.json")
        let provenanceURL = directory.appendingPathComponent(
            "execution-provenance-00000001.json"
        )
        let summary = ProjectStorageCleanupExecutionSummary(
            cleanupID: cleanupID,
            projectRoot: projectURL.path,
            projectIdentity: projectIdentity,
            state: .failed,
            items: [],
            startedAt: Date(timeIntervalSince1970: 10),
            completedAt: Date(timeIntervalSince1970: 11),
            exitStatus: 130,
            wallTimeSeconds: 1,
            stderr: "Cancelled."
        )
        let summaryData = try ProvenanceJSON.encoder.encode(summary)
        try summaryData.write(to: summaryURL)
        let provenance = ProvenanceEnvelope(
            id: cleanupID,
            workflowName: "Manage Project Storage",
            toolName: "Lungfish",
            outputs: [
                .init(
                    path: descriptorSummaryURL.path,
                    checksumSHA256:
                        try ProvenanceFileHasher.sha256(of: summaryURL),
                    fileSize: UInt64(summaryData.count),
                    format: .json,
                    role: .output
                ),
            ]
        )
        try ProvenanceJSON.encoder.encode(provenance).write(
            to: provenanceURL
        )
        return (summaryURL, provenanceURL)
    }
}

private extension NSView {
    func descendant(matching identifier: String) -> NSView? {
        if accessibilityIdentifier() == identifier {
            return self
        }
        return subviews.lazy.compactMap {
            $0.descendant(matching: identifier)
        }.first
    }
}
