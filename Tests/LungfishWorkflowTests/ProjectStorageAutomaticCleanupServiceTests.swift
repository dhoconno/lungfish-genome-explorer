import Foundation
import LungfishIO
import XCTest
@testable import LungfishWorkflow

final class ProjectStorageAutomaticCleanupServiceTests: XCTestCase {
    func testPeriodicCleanupSelectsOnlyProvenTemporaryOwnedWork() async {
        let project = URL(fileURLWithPath: "/tmp/Automatic.lungfish")
        let entries = [
            entry(
                path: ".tmp/completed",
                category: .temporary,
                classification: .removable(
                    .completedOwnedWork,
                    reason: "terminal"
                )
            ),
            entry(
                path: ".tmp/orphan",
                category: .temporary,
                classification: .removable(
                    .conclusivelyOrphanedOwnedWork,
                    reason: "dead process and unlocked"
                )
            ),
            entry(
                path: ".tmp/live",
                category: .temporary,
                classification: .notRemovable(
                    .liveProcess,
                    reason: "live"
                )
            ),
            entry(
                path: ".tmp/unmarked",
                category: .temporary,
                classification: .notRemovable(
                    .missingOwnershipMarker,
                    reason: "unmarked"
                )
            ),
            entry(
                path: ".run-staging",
                category: .workflowStaging,
                classification: .removable(
                    .completedOwnedWork,
                    reason: "terminal"
                )
            ),
        ]
        let captured = InvocationRecorder()
        let service = ProjectStorageAutomaticCleanupService(
            operations: .init(
                scan: { _ in
                    ProjectStorageScanResult(
                        projectIdentity: .init(device: 1, inode: 2),
                        entries: entries
                    )
                },
                executeSelected: { invocation in
                    captured.record(invocation)
                    return executionResult(
                        project: project,
                        cleanupID: invocation.cleanupID,
                        paths: invocation.selectedEntries.map(\.relativePath)
                    )
                },
                makeCleanupID: {
                    UUID(
                        uuidString:
                            "11111111-2222-4333-8444-555555555555"
                    )!
                },
                now: { Date(timeIntervalSince1970: 100) },
                runtimeIdentity: { .init(appVersion: "9.0") },
                toolVersion: { "9.0" }
            )
        )

        let result = await service.run(projectURL: project)

        XCTAssertEqual(result.state, .completed)
        XCTAssertEqual(result.scannedEntryCount, 5)
        XCTAssertEqual(result.selectedEntryCount, 2)
        XCTAssertEqual(
            captured.value?.selectedEntries.map(\.relativePath),
            [".tmp/completed", ".tmp/orphan"]
        )
    }

    func testNoEligibleEntriesDoesNotPrepareOrExecuteCleanup() async {
        let project = URL(fileURLWithPath: "/tmp/Automatic.lungfish")
        let executionCount = Counter()
        let service = ProjectStorageAutomaticCleanupService(
            operations: .init(
                scan: { _ in
                    .init(
                        projectIdentity: .init(device: 1, inode: 2),
                        entries: [
                            entry(
                                path: ".tmp/live",
                                category: .temporary,
                                classification: .notRemovable(
                                    .liveProcess,
                                    reason: "live"
                                )
                            ),
                        ]
                    )
                },
                executeSelected: { invocation in
                    executionCount.increment()
                    return executionResult(
                        project: project,
                        cleanupID: invocation.cleanupID,
                        paths: []
                    )
                }
            )
        )

        let result = await service.run(projectURL: project)

        XCTAssertEqual(result.state, .noEligibleEntries)
        XCTAssertEqual(result.scannedEntryCount, 1)
        XCTAssertEqual(result.selectedEntryCount, 0)
        XCTAssertEqual(executionCount.value, 0)
        XCTAssertNil(result.provenanceURL)
        XCTAssertNil(result.summaryURL)
    }

    func testExecutionUsesAuditableAutomaticPolicyAndStableSelectionOrder()
        async
    {
        let project = URL(fileURLWithPath: "/tmp/A Project.lungfish")
        let captured = InvocationRecorder()
        let service = ProjectStorageAutomaticCleanupService(
            operations: .init(
                scan: { _ in
                    .init(
                        projectIdentity: .init(device: 7, inode: 8),
                        entries: [
                            entry(
                                path: ".tmp/z",
                                category: .temporary,
                                classification: .removable(
                                    .completedOwnedWork,
                                    reason: "terminal"
                                )
                            ),
                            entry(
                                path: ".tmp/a",
                                category: .temporary,
                                classification: .removable(
                                    .completedOwnedWork,
                                    reason: "terminal"
                                )
                            ),
                        ]
                    )
                },
                executeSelected: { invocation in
                    captured.record(invocation)
                    return executionResult(
                        project: project,
                        cleanupID: invocation.cleanupID,
                        paths: invocation.selectedEntries.map(\.relativePath)
                    )
                },
                makeCleanupID: {
                    UUID(
                        uuidString:
                            "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE"
                    )!
                },
                now: { Date(timeIntervalSince1970: 123) },
                processArgv: {
                    ["/Applications/Lungfish.app/Lungfish", "--debug"]
                },
                runtimeIdentity: { .init(appVersion: "8.1") },
                toolVersion: { "8.1" }
            )
        )

        _ = await service.run(projectURL: project)
        let invocation = captured.value

        XCTAssertEqual(
            invocation?.selectedEntries.map(\.relativePath),
            [".tmp/a", ".tmp/z"]
        )
        XCTAssertEqual(
            invocation?.argv,
            [
                "/Applications/Lungfish.app/Lungfish",
                "--debug",
            ]
        )
        XCTAssertNil(invocation?.durableReplayArgv)
        XCTAssertEqual(
            invocation?.options.explicit["trigger"],
            .string("periodic")
        )
        XCTAssertEqual(
            invocation?.options.explicit["selectedRelativePaths"],
            .array([.string(".tmp/a"), .string(".tmp/z")])
        )
        XCTAssertEqual(
            invocation?.options.resolvedDefaults["category"],
            .string("temporary")
        )
        XCTAssertEqual(
            invocation?.options.resolvedDefaults["permanentDeleteFallback"],
            .boolean(false)
        )
        XCTAssertEqual(invocation?.runtimeIdentity.appVersion, "8.1")
        XCTAssertEqual(invocation?.startedAt, Date(timeIntervalSince1970: 123))
    }

    func testDurableDispositionFailuresBecomeRetryWarnings() async {
        let project = URL(fileURLWithPath: "/tmp/Automatic.lungfish")
        let service = ProjectStorageAutomaticCleanupService(
            operations: .init(
                scan: { _ in
                    .init(
                        projectIdentity: .init(device: 1, inode: 2),
                        entries: [
                            entry(
                                path: ".tmp/a",
                                category: .temporary,
                                classification: .removable(
                                    .completedOwnedWork,
                                    reason: "terminal"
                                )
                            ),
                        ]
                    )
                },
                executeSelected: { invocation in
                    let summary = ProjectStorageCleanupExecutionSummary(
                        cleanupID: invocation.cleanupID,
                        projectRoot: project.path,
                        projectIdentity: invocation.projectIdentity,
                        state: .completedWithFailures,
                        items: [
                            .init(
                                itemID: UUID(),
                                sourceRelativePath: ".tmp/a",
                                state: .quarantineRetained,
                                quarantineRelativePath: ".tmp/pending",
                                trashDestinationPath: nil,
                                reason: "Trash was unavailable."
                            ),
                        ],
                        startedAt: invocation.startedAt,
                        completedAt: invocation.startedAt,
                        exitStatus: 1,
                        wallTimeSeconds: 0,
                        stderr: "Trash was unavailable."
                    )
                    return .init(
                        summary: summary,
                        summaryURL: project.appendingPathComponent(
                            "summary.json"
                        ),
                        provenanceURL: project.appendingPathComponent(
                            "provenance.json"
                        )
                    )
                }
            )
        )

        let result = await service.run(projectURL: project)

        XCTAssertEqual(result.state, .retryRecommended)
        XCTAssertEqual(result.warnings.count, 1)
        XCTAssertEqual(result.warnings.first?.relativePath, ".tmp/a")
        XCTAssertEqual(
            result.warnings.first?.message,
            "Trash was unavailable."
        )
        XCTAssertNotNil(result.summaryURL)
        XCTAssertNotNil(result.provenanceURL)
    }

    func testPublishedCancellationPreservesReceiptAndDispositionContext()
        async
    {
        let project = URL(fileURLWithPath: "/tmp/Automatic.lungfish")
        let summaryURL = project.appendingPathComponent(
            "execution-summary-00000001.json"
        )
        let provenanceURL = project.appendingPathComponent(
            "execution-provenance-00000001.json"
        )
        let service = ProjectStorageAutomaticCleanupService(
            operations: .init(
                scan: { _ in
                    .init(
                        projectIdentity: .init(device: 1, inode: 2),
                        entries: [
                            entry(
                                path: ".tmp/moved",
                                category: .temporary,
                                classification: .removable(
                                    .completedOwnedWork,
                                    reason: "terminal"
                                )
                            ),
                            entry(
                                path: ".tmp/skipped",
                                category: .temporary,
                                classification: .removable(
                                    .completedOwnedWork,
                                    reason: "terminal"
                                )
                            ),
                        ]
                    )
                },
                executeSelected: { invocation in
                    let summary = ProjectStorageCleanupExecutionSummary(
                        cleanupID: invocation.cleanupID,
                        projectRoot: project.path,
                        projectIdentity: invocation.projectIdentity,
                        state: .completedWithFailures,
                        items: [
                            .init(
                                itemID: UUID(),
                                sourceRelativePath: ".tmp/moved",
                                state: .movedToTrash,
                                quarantineRelativePath: nil,
                                trashDestinationPath: "/Trash/moved",
                                reason: nil
                            ),
                            .init(
                                itemID: UUID(),
                                sourceRelativePath: ".tmp/skipped",
                                state: .skipped,
                                quarantineRelativePath: nil,
                                trashDestinationPath: nil,
                                reason:
                                    "Cleanup cancelled before this item."
                            ),
                        ],
                        startedAt: invocation.startedAt,
                        completedAt: invocation.startedAt,
                        exitStatus: 130,
                        wallTimeSeconds: 0,
                        stderr: "Project storage cleanup cancelled."
                    )
                    throw
                        ProjectStorageAutomaticCleanupPublishedCancellation(
                            result: .init(
                                summary: summary,
                                summaryURL: summaryURL,
                                provenanceURL: provenanceURL
                            )
                        )
                }
            )
        )

        let result = await service.run(projectURL: project)

        XCTAssertEqual(result.state, .cancelled)
        XCTAssertEqual(result.selectedEntryCount, 2)
        XCTAssertEqual(result.summaryURL, summaryURL)
        XCTAssertEqual(result.provenanceURL, provenanceURL)
        XCTAssertEqual(
            result.warnings,
            [
                .init(
                    relativePath: ".tmp/skipped",
                    message: "Cleanup cancelled before this item."
                ),
            ]
        )
    }

    func testScanFailureIsNonDestructiveAndRequestsRetry() async {
        struct ScanFailure: LocalizedError {
            var errorDescription: String? { "scan unavailable" }
        }
        let executionCount = Counter()
        let recordedFailure = FailureInvocationRecorder()
        let summaryURL = URL(fileURLWithPath: "/tmp/failure.json")
        let provenanceURL = URL(
            fileURLWithPath: "/tmp/failure-provenance.json"
        )
        let service = ProjectStorageAutomaticCleanupService(
            operations: .init(
                scan: { _ in throw ScanFailure() },
                executeSelected: { _ in
                    executionCount.increment()
                    throw ScanFailure()
                },
                recordFailure: {
                    recordedFailure.record($0)
                    return .init(
                        summaryURL: summaryURL,
                        provenanceURL: provenanceURL
                    )
                }
            )
        )

        let result = await service.run(
            projectURL: URL(fileURLWithPath: "/tmp/Automatic.lungfish")
        )

        XCTAssertEqual(result.state, .retryRecommended)
        XCTAssertEqual(executionCount.value, 0)
        XCTAssertEqual(result.warnings.singleValue?.message, "scan unavailable")
        XCTAssertEqual(result.summaryURL, summaryURL)
        XCTAssertEqual(result.provenanceURL, provenanceURL)
        XCTAssertEqual(recordedFailure.value?.errorMessage, "scan unavailable")
        XCTAssertEqual(recordedFailure.value?.toolName, "Lungfish")
        XCTAssertEqual(recordedFailure.value?.argv, CommandLine.arguments)
        XCTAssertNil(recordedFailure.value?.durableReplayArgv)
    }

    func testProductionFailureRecorderWritesCompleteProvenance() async throws {
        struct ScanFailure: LocalizedError {
            var errorDescription: String? { "scan unavailable" }
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AutomaticCleanupFailure-\(UUID().uuidString)",
                isDirectory: true
            )
        let project = root.appendingPathComponent(
            "Project.lungfish",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: project,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let service = ProjectStorageAutomaticCleanupService(
            operations: .init(
                scan: { _ in throw ScanFailure() },
                processArgv: { ["/Applications/Lungfish.app/Lungfish"] },
                runtimeIdentity: {
                    .init(
                        appVersion: "9.0",
                        executablePath:
                            "/Applications/Lungfish.app/Lungfish"
                    )
                },
                toolVersion: { "9.0" }
            )
        )

        let result = await service.run(
            projectURL: project,
            trigger: .userRequested
        )
        let summaryURL = try XCTUnwrap(result.summaryURL)
        let provenanceURL = try XCTUnwrap(result.provenanceURL)
        let provenance = try ProvenanceJSON.decoder.decode(
            ProvenanceEnvelope.self,
            from: Data(contentsOf: provenanceURL)
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: summaryURL.path))
        XCTAssertEqual(provenance.exitStatus, 1)
        XCTAssertEqual(provenance.stderr, "scan unavailable")
        XCTAssertEqual(provenance.toolName, "Lungfish")
        XCTAssertEqual(
            provenance.workflowName,
            "Project Temporary Storage Cleanup Failure"
        )
        XCTAssertEqual(
            provenance.argv,
            ["/Applications/Lungfish.app/Lungfish"]
        )
        XCTAssertNil(provenance.durableReplayArgv)
        XCTAssertEqual(
            provenance.options.explicit["trigger"],
            .string("user-requested")
        )
        XCTAssertEqual(
            provenance.outputs.singleValue?.checksumSHA256?.count,
            64
        )
        XCTAssertNotNil(provenance.outputs.singleValue?.fileSize)
    }
}

private final class InvocationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage:
        ProjectStorageAutomaticCleanupService.Invocation?

    var value: ProjectStorageAutomaticCleanupService.Invocation? {
        lock.withLock { storage }
    }

    func record(
        _ invocation: ProjectStorageAutomaticCleanupService.Invocation
    ) {
        lock.withLock { storage = invocation }
    }
}

private final class FailureInvocationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage:
        ProjectStorageAutomaticCleanupService.FailureInvocation?

    var value:
        ProjectStorageAutomaticCleanupService.FailureInvocation?
    {
        lock.withLock { storage }
    }

    func record(
        _ invocation:
            ProjectStorageAutomaticCleanupService.FailureInvocation
    ) {
        lock.withLock { storage = invocation }
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int { lock.withLock { storage } }

    func increment() {
        lock.withLock { storage += 1 }
    }
}

private func entry(
    path: String,
    category: ProjectStorageEntry.Category,
    classification: ProjectStorageClassification
) -> ProjectStorageEntry {
    ProjectStorageEntry(
        projectIdentity: .init(device: 1, inode: 2),
        relativePath: path,
        identity: .init(
            device: 3,
            inode: UInt64(abs(path.hashValue)) + 1
        ),
        category: category,
        logicalBytes: 10,
        allocatedBytes: 10,
        modificationDate: Date(timeIntervalSince1970: 1),
        classification: classification
    )
}

private func executionResult(
    project: URL,
    cleanupID: UUID,
    paths: [String]
) -> ProjectStorageCleanupExecutionResult {
    .init(
        summary: .init(
            cleanupID: cleanupID,
            projectRoot: project.path,
            projectIdentity: .init(device: 1, inode: 2),
            state: .completed,
            items: paths.map {
                .init(
                    itemID: UUID(),
                    sourceRelativePath: $0,
                    state: .movedToTrash,
                    quarantineRelativePath: nil,
                    trashDestinationPath: "/Trash/\($0)",
                    reason: nil
                )
            },
            startedAt: Date(timeIntervalSince1970: 1),
            completedAt: Date(timeIntervalSince1970: 2),
            exitStatus: 0,
            wallTimeSeconds: 1,
            stderr: ""
        ),
        summaryURL: project.appendingPathComponent("summary.json"),
        provenanceURL: project.appendingPathComponent("provenance.json")
    )
}

private extension Collection {
    var singleValue: Element? {
        count == 1 ? first : nil
    }
}
