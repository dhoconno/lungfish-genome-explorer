import CryptoKit
import Darwin
import Foundation
import LungfishIO
import XCTest
@testable import LungfishWorkflow

final class ProjectStorageCleanupExecutorTests: XCTestCase {
    private var root: URL!
    private var project: URL!
    private var candidate: URL!
    private var fakeTrash: URL!

    override func setUpWithError() throws {
        try initializeFixture()
    }

    private func initializeFixture() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ProjectStorageCleanupExecutorTests-\(UUID().uuidString)",
            isDirectory: true
        )
        project = root.appendingPathComponent(
            "Storage.lungfish",
            isDirectory: true
        )
        candidate = project.appendingPathComponent(
            ".analysis.lungfishgenotype.candidate-artifact-work",
            isDirectory: true
        )
        fakeTrash = root.appendingPathComponent(
            "Fake Trash",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: candidate,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: fakeTrash,
            withIntermediateDirectories: true
        )
        try bindCompletedMarker(to: candidate)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testExecutionConsumesAttestedPreparationAndTrashesOnlyQuarantine()
        async throws
    {
        try Data("payload".utf8).write(
            to: candidate.appendingPathComponent("payload.txt")
        )
        let prepared = try prepareCleanup(entries: [
            try storageEntry(for: candidate),
        ])
        let events = EventRecorder()
        let currentDisposition = StringRecorder()
        let stateGrowth = FileGrowthRecorder()
        let appendDescriptorChecks = Counter()
        let stateURL = operationDirectory(
            cleanupID: prepared.journal.cleanupID
        ).appendingPathComponent(
            ProjectStorageCleanupExecutor.stateFileName
        )
        let executor = ProjectStorageCleanupExecutor(
            operations: .init(
                cancellationCheck: {},
                acquireAssociatedLock: {
                    lockedProject,
                    lockedIdentity,
                    lockedCleanupID in
                    XCTAssertEqual(
                        lockedProject.standardizedFileURL,
                        self.project.standardizedFileURL
                    )
                    XCTAssertEqual(
                        lockedIdentity,
                        prepared.journal.projectIdentity
                    )
                    XCTAssertEqual(
                        lockedCleanupID,
                        prepared.journal.cleanupID
                    )
                    events.append("lock")
                    return { events.append("unlock") }
                },
                authoritativeScan: {
                    events.append("scan")
                    return try ProjectStorageScanner().scan(projectURL: $0)
                },
                beforeAppendDisposition: { record in
                    currentDisposition.append(record.state.rawValue)
                    events.append("record:\(record.state.rawValue)")
                },
                didOpenStateLog: { descriptor in
                    appendDescriptorChecks.increment()
                    let flags = Darwin.fcntl(descriptor, F_GETFL)
                    XCTAssertGreaterThanOrEqual(flags, 0)
                    XCTAssertNotEqual(flags & O_APPEND, 0)
                    var information = stat()
                    XCTAssertEqual(
                        Darwin.fstat(descriptor, &information),
                        0
                    )
                    XCTAssertEqual(
                        information.st_mode & S_IFMT,
                        S_IFREG
                    )
                },
                renameExclusive: {
                    sourceParent,
                    source,
                    destinationParent,
                    destination,
                    flags in
                    events.append("detach")
                    XCTAssertEqual(flags, UInt32(RENAME_EXCL))
                    return source.withCString { sourcePointer in
                        destination.withCString { destinationPointer in
                            Darwin.renameatx_np(
                                sourceParent,
                                sourcePointer,
                                destinationParent,
                                destinationPointer,
                                flags
                            )
                        }
                    }
                },
                syncFile: {
                    events.append("fsync-file")
                    return Darwin.fsync($0)
                },
                syncDirectory: {
                    events.append("fsync-directory")
                    return Darwin.fsync($0)
                },
                trashItem: { quarantine in
                    events.append("trash:\(quarantine.lastPathComponent)")
                    XCTAssertTrue(
                        quarantine.lastPathComponent.hasPrefix(
                            ".lungfish-trash-pending-"
                        )
                    )
                    XCTAssertFalse(
                        FileManager.default.fileExists(
                            atPath: self.candidate.path
                        )
                    )
                    let destination = self.fakeTrash.appendingPathComponent(
                        quarantine.lastPathComponent
                    )
                    try FileManager.default.moveItem(
                        at: quarantine,
                        to: destination
                    )
                    return destination
                },
                checkpoint: { checkpoint, _ in
                    switch checkpoint {
                    case .afterDispositionDurable:
                        try stateGrowth.record(stateURL)
                        events.append(
                            "durable:"
                                + (currentDisposition.last ?? "missing")
                        )
                    case .afterSummaryDurable:
                        events.append("summary-durable")
                    case .afterProvenanceDurable:
                        events.append("provenance-durable")
                    default:
                        break
                    }
                }
            )
        )

        let result = try await executor.execute(
            executionRequest(cleanupID: prepared.journal.cleanupID)
        )

        XCTAssertEqual(result.summary.state, .completed)
        XCTAssertEqual(
            result.summary.items.singleValue?.state,
            .movedToTrash
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: candidate.path))
        XCTAssertTrue(
            events.values.firstIndex(of: "lock")!
                < events.values.firstIndex(of: "scan")!
        )
        XCTAssertTrue(
            events.values.firstIndex(of: "record:detach-intent")!
                < events.values.firstIndex(of: "detach")!
        )
        XCTAssertTrue(
            events.values.firstIndex(of: "detach")!
                < events.values.firstIndex(of: "record:detached")!
        )
        XCTAssertTrue(
            events.values.firstIndex(of: "record:trash-intent")!
                < events.values.firstIndex {
                    $0.hasPrefix("trash:")
                }!
        )
        for state in [
            "detach-intent",
            "detached",
            "trash-intent",
            "moved-to-trash",
        ] {
            let recordIndex = try XCTUnwrap(
                events.values.firstIndex(of: "record:\(state)")
            )
            let nextRecord = events.values[
                events.values.index(after: recordIndex)...
            ].firstIndex { $0.hasPrefix("record:") }
                ?? events.values.endIndex
            let fileSync = try XCTUnwrap(
                events.values[
                    events.values.index(after: recordIndex)..<nextRecord
                ].firstIndex(of: "fsync-file"),
                "state \(state) must be file-fsynced"
            )
            XCTAssertNotNil(
                events.values[
                    events.values.index(after: fileSync)..<nextRecord
                ].firstIndex(of: "fsync-directory"),
                "state \(state) must be directory-fsynced"
            )
            XCTAssertNotNil(
                events.values[
                    events.values.index(after: fileSync)..<nextRecord
                ].firstIndex(of: "durable:\(state)"),
                "state \(state) needs an explicit durable boundary"
            )
        }
        XCTAssertTrue(
            events.values.firstIndex(of: "record:moved-to-trash")!
                < events.values.firstIndex(of: "summary-durable")!
        )
        XCTAssertTrue(
            events.values.firstIndex(of: "summary-durable")!
                < events.values.firstIndex(of: "provenance-durable")!
        )
        XCTAssertTrue(
            events.values.firstIndex(of: "provenance-durable")!
                < events.values.firstIndex(of: "unlock")!
        )
        XCTAssertEqual(stateGrowth.snapshots.count, 4)
        XCTAssertGreaterThanOrEqual(appendDescriptorChecks.value, 1)
        XCTAssertEqual(
            Set(stateGrowth.snapshots.map(\.identity)).count,
            1,
            "the append-only state log must retain one inode"
        )
        XCTAssertTrue(
            zip(
                stateGrowth.snapshots,
                stateGrowth.snapshots.dropFirst()
            ).allSatisfy { $0.size < $1.size },
            "every durable state append must strictly grow the same file"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: result.summaryURL.path)
        )
        let provenance = try ProvenanceEnvelopeReader.decodeCanonical(
            Data(contentsOf: result.provenanceURL)
        )
        XCTAssertEqual(provenance.argv, executionArgv)
        XCTAssertEqual(provenance.durableReplayArgv, executionArgv)
        XCTAssertEqual(provenance.runtimeIdentity, runtimeIdentity)
        XCTAssertEqual(provenance.exitStatus, 0)
        XCTAssertEqual(provenance.stderr, "")
        let journalProvenanceDescriptor = provenance.files.first {
            $0.path == prepared.journalURL.path
        }
        XCTAssertEqual(
            journalProvenanceDescriptor?.checksumSHA256?.count,
            64
        )
        XCTAssertGreaterThan(
            journalProvenanceDescriptor?.fileSize ?? 0,
            0
        )
        try assertCompleteExecutionProvenance(
            preparation: prepared,
            summary: result.summary
        )
    }

    func testDefaultAdapterUsesRecoverableSystemTrashAndNeverPermanentDelete()
        async throws
    {
        // Managed test sandboxes can deny the macOS Trash service even when
        // the test-owned source is writable. Skip only that OS-level access
        // denial; all other adapter failures remain test failures.
        let probe = root.appendingPathComponent(
            "system-trash-access-probe",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: probe,
            withIntermediateDirectories: false
        )
        var probeDestination: NSURL?
        do {
            try FileManager.default.trashItem(
                at: probe,
                resultingItemURL: &probeDestination
            )
            let destination = try XCTUnwrap(probeDestination as URL?)
            try FileManager.default.moveItem(at: destination, to: probe)
            try FileManager.default.removeItem(at: probe)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
            && error.code == CocoaError.fileWriteNoPermission.rawValue {
            throw XCTSkip(
                "The managed test sandbox denies access to the macOS Trash service."
            )
        }

        let locks = project.appendingPathComponent("locks", isDirectory: true)
        try FileManager.default.createDirectory(
            at: locks,
            withIntermediateDirectories: false
        )
        try rewriteMarker(
            at: candidate,
            lockRelativePath: "locks/default-adapter.lock"
        )
        try Data("default-trash".utf8).write(
            to: candidate.appendingPathComponent("payload.txt")
        )
        let prepared = try prepareCleanup(entries: [
            try storageEntry(for: candidate),
        ])

        let result = try await ProjectStorageCleanupExecutor().execute(
            executionRequest(cleanupID: prepared.journal.cleanupID)
        )

        let item = try XCTUnwrap(result.summary.items.singleValue)
        XCTAssertEqual(item.state, .movedToTrash)
        let destination = URL(
            fileURLWithPath:
                try XCTUnwrap(item.trashDestinationPath),
            isDirectory: true
        )
        var information = stat()
        XCTAssertEqual(Darwin.lstat(destination.path, &information), 0)
        XCTAssertEqual(information.st_mode & S_IFMT, S_IFDIR)
        XCTAssertEqual(
            try Data(
                contentsOf:
                    destination.appendingPathComponent("payload.txt")
            ),
            Data("default-trash".utf8)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: candidate.path))

        // Recover the test-owned item so the test does not litter the
        // user's Trash. The production executor must never perform this
        // cleanup or any permanent deletion.
        let recovered = root.appendingPathComponent(
            "Recovered default Trash item",
            isDirectory: true
        )
        try FileManager.default.moveItem(
            at: destination,
            to: recovered
        )
    }

    func testMissingOrTamperedPreparationAuthorityNeverMutatesSource()
        async throws
    {
        try Data("keep".utf8).write(
            to: candidate.appendingPathComponent("payload.txt")
        )
        let prepared = try prepareCleanup(entries: [
            try storageEntry(for: candidate),
        ])
        try FileManager.default.removeItem(at: prepared.provenanceURL)
        let trashCalls = Counter()
        let executor = ProjectStorageCleanupExecutor(
            operations: .init(
                trashItem: { _ in
                    trashCalls.increment()
                    throw CocoaError(.fileWriteUnknown)
                }
            )
        )

        await XCTAssertThrowsErrorAsync {
            try await executor.execute(
                self.executionRequest(
                    cleanupID: prepared.journal.cleanupID
                )
            )
        }

        XCTAssertEqual(trashCalls.value, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: candidate.path))

        let second = try prepareCleanup(
            entries: [try storageEntry(for: candidate)],
            cleanupID: UUID()
        )
        var journal = try JSONSerialization.jsonObject(
            with: Data(contentsOf: second.journalURL)
        ) as! [String: Any]
        journal["projectRoot"] = root.appendingPathComponent("forged").path
        try JSONSerialization.data(
            withJSONObject: journal,
            options: [.sortedKeys]
        ).write(to: second.journalURL)
        await XCTAssertThrowsErrorAsync {
            try await executor.execute(
                self.executionRequest(
                    cleanupID: second.journal.cleanupID
                )
            )
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: candidate.path))
    }

    func testHeldLockStaleClassificationAndInventoryMutationAreSkipped()
        async throws
    {
        try Data("original".utf8).write(
            to: candidate.appendingPathComponent("payload.txt")
        )
        let heldPreparation = try prepareCleanup(entries: [
            try storageEntry(for: candidate),
        ])
        enum LockFailure: Error { case held }
        let heldExecutor = ProjectStorageCleanupExecutor(
            operations: .init(
                acquireAssociatedLock: { _, _, _ in
                    throw LockFailure.held
                }
            )
        )
        let heldResult = try await heldExecutor.execute(
            executionRequest(
                cleanupID: heldPreparation.journal.cleanupID
            )
        )
        XCTAssertEqual(
            heldResult.summary.items.singleValue?.state,
            .skipped
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: candidate.path))

        let stalePreparation = try prepareCleanup(
            entries: [try storageEntry(for: candidate)],
            cleanupID: UUID()
        )
        try Data("mutated!".utf8).write(
            to: candidate.appendingPathComponent("payload.txt")
        )
        let staleResult = try await ProjectStorageCleanupExecutor()
            .execute(
                executionRequest(
                    cleanupID: stalePreparation.journal.cleanupID
                )
            )
        XCTAssertEqual(
            staleResult.summary.items.singleValue?.state,
            .skipped
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: candidate.path))
    }

    func testPublicDefaultAcquiresRecordedRunLockBeforeRevalidation()
        async throws
    {
        try Data("locked".utf8).write(
            to: candidate.appendingPathComponent("payload.txt")
        )
        let locks = project.appendingPathComponent("locks", isDirectory: true)
        try FileManager.default.createDirectory(
            at: locks,
            withIntermediateDirectories: false
        )
        let relativeLockPath = "locks/workflow.lock"
        try rewriteMarker(
            at: candidate,
            lockRelativePath: relativeLockPath
        )
        let prepared = try prepareCleanup(entries: [
            try storageEntry(for: candidate),
        ])
        let held = try OwnedRunLock.acquire(
            at: project.appendingPathComponent(relativeLockPath)
        )
        defer { held.release() }

        let result = try await ProjectStorageCleanupExecutor().execute(
            executionRequest(cleanupID: prepared.journal.cleanupID)
        )

        XCTAssertEqual(
            result.summary.items.singleValue?.state,
            .skipped
        )
        XCTAssertTrue(
            result.summary.items.singleValue?.reason?
                .localizedCaseInsensitiveContains("lock") == true
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: candidate.path))
        XCTAssertTrue(try pendingQuarantines().isEmpty)
    }

    func testPublicDefaultFailsClosedWithoutRecordedRunLock() async throws {
        try Data("unlocked-marker".utf8).write(
            to: candidate.appendingPathComponent("payload.txt")
        )
        let prepared = try prepareCleanup(entries: [
            try storageEntry(for: candidate),
        ])

        let result = try await ProjectStorageCleanupExecutor().execute(
            executionRequest(cleanupID: prepared.journal.cleanupID)
        )

        XCTAssertEqual(
            result.summary.items.singleValue?.state,
            .skipped
        )
        XCTAssertTrue(
            result.summary.items.singleValue?.reason?
                .localizedCaseInsensitiveContains("lock") == true
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: candidate.path))
        XCTAssertTrue(try pendingQuarantines().isEmpty)
    }

    func testProductionLocksArePerItemAndLockAwareScanStillDetachesUnlockedItem()
        async throws
    {
        let second = project.appendingPathComponent(
            ".second.lungfishgenotype.candidate-artifact-work",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: second,
            withIntermediateDirectories: false
        )
        try bindCompletedMarker(to: second)
        try Data("first".utf8).write(
            to: candidate.appendingPathComponent("payload.txt")
        )
        try Data("second".utf8).write(
            to: second.appendingPathComponent("payload.txt")
        )
        let locks = project.appendingPathComponent("locks", isDirectory: true)
        try FileManager.default.createDirectory(
            at: locks,
            withIntermediateDirectories: false
        )
        try rewriteMarker(
            at: candidate,
            lockRelativePath: "locks/first.lock"
        )
        try rewriteMarker(
            at: second,
            lockRelativePath: "locks/second.lock"
        )
        let prepared = try prepareCleanup(entries: [
            try storageEntry(for: candidate),
            try storageEntry(for: second),
        ])
        let held = try OwnedRunLock.acquire(
            at: project.appendingPathComponent("locks/first.lock")
        )
        defer { held.release() }

        let result = try await ProjectStorageCleanupExecutor(
            operations: .init(
                trashItem: { quarantine in
                    let destination = self.fakeTrash.appendingPathComponent(
                        quarantine.lastPathComponent
                    )
                    try FileManager.default.moveItem(
                        at: quarantine,
                        to: destination
                    )
                    return destination
                }
            ),
            usesProductionAssociatedLocks: true
        ).execute(
            executionRequest(cleanupID: prepared.journal.cleanupID)
        )

        let byPath = Dictionary(
            uniqueKeysWithValues: result.summary.items.map {
                ($0.sourceRelativePath, $0.state)
            }
        )
        XCTAssertEqual(
            byPath[String(candidate.path.dropFirst(project.path.count + 1))],
            .skipped
        )
        XCTAssertEqual(
            byPath[String(second.path.dropFirst(project.path.count + 1))],
            .movedToTrash
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: candidate.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
    }

    func testProductionProjectCleanupLockPrecedesStateMutation() async throws {
        try Data("payload".utf8).write(
            to: candidate.appendingPathComponent("payload.txt")
        )
        let locks = project.appendingPathComponent("locks", isDirectory: true)
        try FileManager.default.createDirectory(
            at: locks,
            withIntermediateDirectories: false
        )
        try rewriteMarker(
            at: candidate,
            lockRelativePath: "locks/run.lock"
        )
        let prepared = try prepareCleanup(entries: [
            try storageEntry(for: candidate),
        ])
        let globalLockURL = project
            .appendingPathComponent(
                ProjectOperationHistoryWriter.historyDirectoryName,
                isDirectory: true
            )
            .appendingPathComponent(".project-storage-cleanup.lock")
        let held = try OwnedRunLock.acquire(at: globalLockURL)
        defer { held.release() }

        await XCTAssertThrowsErrorAsync {
            try await ProjectStorageCleanupExecutor().execute(
                self.executionRequest(
                    cleanupID: prepared.journal.cleanupID
                )
            )
        }

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: operationDirectory(
                    cleanupID: prepared.journal.cleanupID
                ).appendingPathComponent(
                    ProjectStorageCleanupExecutor.stateFileName
                ).path
            )
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: candidate.path))
    }

    func testTrashFailureRestoresOnlyWhenOriginalNameIsFree()
        async throws
    {
        try Data("original".utf8).write(
            to: candidate.appendingPathComponent("payload.txt")
        )
        let prepared = try prepareCleanup(entries: [
            try storageEntry(for: candidate),
        ])
        enum TrashFailure: Error { case rejected }
        let restoredDurability = ExecutionDurabilityWitness()
        let restoring = ProjectStorageCleanupExecutor(
            operations: .init(
                beforeAppendDisposition: restoredDurability.begin,
                syncFile: restoredDurability.syncFile,
                syncDirectory: restoredDurability.syncDirectory,
                trashItem: { _ in throw TrashFailure.rejected },
                checkpoint: restoredDurability.checkpoint
            )
        )

        let restored = try await restoring.execute(
            executionRequest(cleanupID: prepared.journal.cleanupID)
        )

        XCTAssertEqual(
            restored.summary.items.singleValue?.state,
            .restoredAfterTrashFailure
        )
        XCTAssertNotEqual(restored.summary.exitStatus, 0)
        XCTAssertFalse(restored.summary.stderr.isEmpty)
        XCTAssertTrue(
            restored.summary.items.singleValue?.reason?
                .localizedCaseInsensitiveContains("trash") == true
        )
        XCTAssertEqual(
            try Data(
                contentsOf:
                    candidate.appendingPathComponent("payload.txt")
            ),
            Data("original".utf8)
        )
        try assertCompleteExecutionProvenance(
            preparation: prepared,
            summary: restored.summary
        )
        assertDurableCompletion(
            restoredDurability,
            terminalStates: [.restoredAfterTrashFailure]
        )

        let replacementPreparation = try prepareCleanup(
            entries: [try storageEntry(for: candidate)],
            cleanupID: UUID()
        )
        let retainedDurability = ExecutionDurabilityWitness()
        let retaining = ProjectStorageCleanupExecutor(
            operations: .init(
                beforeAppendDisposition: retainedDurability.begin,
                syncFile: retainedDurability.syncFile,
                syncDirectory: retainedDurability.syncDirectory,
                trashItem: { _ in
                    try FileManager.default.createDirectory(
                        at: self.candidate,
                        withIntermediateDirectories: false
                    )
                    try Data("replacement".utf8).write(
                        to:
                            self.candidate.appendingPathComponent(
                                "payload.txt"
                            )
                    )
                    throw TrashFailure.rejected
                },
                checkpoint: retainedDurability.checkpoint
            )
        )

        let retained = try await retaining.execute(
            executionRequest(
                cleanupID: replacementPreparation.journal.cleanupID
            )
        )

        XCTAssertEqual(
            retained.summary.items.singleValue?.state,
            .quarantineRetained
        )
        XCTAssertNotEqual(retained.summary.exitStatus, 0)
        XCTAssertFalse(retained.summary.stderr.isEmpty)
        XCTAssertEqual(
            try Data(
                contentsOf:
                    candidate.appendingPathComponent("payload.txt")
            ),
            Data("replacement".utf8)
        )
        let quarantine = try XCTUnwrap(
            retained.summary.items.singleValue?.quarantineRelativePath
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: project.appendingPathComponent(quarantine).path
            )
        )
        try assertCompleteExecutionProvenance(
            preparation: replacementPreparation,
            summary: retained.summary
        )
        assertDurableCompletion(
            retainedDurability,
            terminalStates: [.quarantineRetained]
        )
    }

    func testResumeAfterDetachAndAfterTrashIsIdempotent() async throws {
        try Data("payload".utf8).write(
            to: candidate.appendingPathComponent("payload.txt")
        )
        let detachedPreparation = try prepareCleanup(entries: [
            try storageEntry(for: candidate),
        ])
        enum SimulatedCrash: Error { case checkpoint }
        let crashingAfterDetach = ProjectStorageCleanupExecutor(
            operations: .init(
                checkpoint: { checkpoint, _ in
                    if checkpoint == .afterDetachBeforeRecord {
                        throw SimulatedCrash.checkpoint
                    }
                }
            )
        )
        await XCTAssertThrowsErrorAsync {
            try await crashingAfterDetach.execute(
                self.executionRequest(
                    cleanupID: detachedPreparation.journal.cleanupID
                )
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: candidate.path))
        XCTAssertEqual(try pendingQuarantines().count, 1)

        let trashCalls = Counter()
        let resumed = ProjectStorageCleanupExecutor(
            operations: .init(
                trashItem: { quarantine in
                    trashCalls.increment()
                    let destination =
                        self.fakeTrash.appendingPathComponent(
                            quarantine.lastPathComponent
                        )
                    try FileManager.default.moveItem(
                        at: quarantine,
                        to: destination
                    )
                    return destination
                }
            )
        )
        let recovered = try await resumed.execute(
            executionRequest(
                cleanupID: detachedPreparation.journal.cleanupID
            )
        )
        XCTAssertEqual(
            recovered.summary.items.singleValue?.state,
            .movedToTrash
        )
        XCTAssertEqual(trashCalls.value, 1)
        _ = try await resumed.execute(
            executionRequest(
                cleanupID: detachedPreparation.journal.cleanupID
            )
        )
        XCTAssertEqual(trashCalls.value, 1)

        try resetCandidate()
        try Data("second".utf8).write(
            to: candidate.appendingPathComponent("payload.txt")
        )
        let trashPreparation = try prepareCleanup(
            entries: [try storageEntry(for: candidate)],
            cleanupID: UUID()
        )
        let crashingAfterTrash = ProjectStorageCleanupExecutor(
            operations: .init(
                trashItem: { quarantine in
                    let destination =
                        self.fakeTrash.appendingPathComponent(
                            "post-trash-\(UUID().uuidString)"
                        )
                    try FileManager.default.moveItem(
                        at: quarantine,
                        to: destination
                    )
                    return destination
                },
                checkpoint: { checkpoint, _ in
                    if checkpoint == .afterTrashBeforeRecord {
                        throw SimulatedCrash.checkpoint
                    }
                }
            )
        )
        await XCTAssertThrowsErrorAsync {
            try await crashingAfterTrash.execute(
                self.executionRequest(
                    cleanupID: trashPreparation.journal.cleanupID
                )
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: candidate.path))
        XCTAssertTrue(try pendingQuarantines().isEmpty)
        let uncertainResumeTrashCalls = Counter()
        let outcomeDurability = ExecutionDurabilityWitness()
        let inferred = try await ProjectStorageCleanupExecutor(
            operations: .init(
                beforeAppendDisposition: outcomeDurability.begin,
                syncFile: outcomeDurability.syncFile,
                syncDirectory: outcomeDurability.syncDirectory,
                trashItem: { _ in
                    uncertainResumeTrashCalls.increment()
                    throw CocoaError(.fileWriteUnknown)
                },
                checkpoint: outcomeDurability.checkpoint
            )
        ).execute(
            executionRequest(
                cleanupID: trashPreparation.journal.cleanupID
            )
        )
        XCTAssertEqual(
            inferred.summary.items.singleValue?.state,
            .outcomeUnknown
        )
        XCTAssertEqual(uncertainResumeTrashCalls.value, 0)
        try assertCompleteExecutionProvenance(
            preparation: trashPreparation,
            summary: inferred.summary
        )
        assertDurableCompletion(
            outcomeDurability,
            terminalStates: [.outcomeUnknown]
        )
    }

    func testCancellationBetweenItemsRecordsPartialRecoverableResult()
        async throws
    {
        try Data("first".utf8).write(
            to: candidate.appendingPathComponent("payload.txt")
        )
        let second = project.appendingPathComponent(
            ".second.lungfishgenotype.candidate-artifact-work",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: second,
            withIntermediateDirectories: false
        )
        try bindCompletedMarker(to: second)
        try Data("second".utf8).write(
            to: second.appendingPathComponent("payload.txt")
        )
        let prepared = try prepareCleanup(entries: [
            try storageEntry(for: candidate),
            try storageEntry(for: second),
        ])
        let checks = Counter()
        let executor = ProjectStorageCleanupExecutor(
            operations: .init(
                cancellationCheck: {
                    if checks.incrementAndReturn() > 1 {
                        throw CancellationError()
                    }
                },
                trashItem: { quarantine in
                    let destination =
                        self.fakeTrash.appendingPathComponent(
                            quarantine.lastPathComponent
                        )
                    try FileManager.default.moveItem(
                        at: quarantine,
                        to: destination
                    )
                    return destination
                }
            )
        )

        await XCTAssertThrowsErrorAsync {
            try await executor.execute(
                self.executionRequest(
                    cleanupID: prepared.journal.cleanupID
                )
            )
        }

        XCTAssertNotEqual(
            FileManager.default.fileExists(atPath: candidate.path),
            FileManager.default.fileExists(atPath: second.path)
        )
        let completion = try latestSummary(
            cleanupID: prepared.journal.cleanupID
        )
        XCTAssertEqual(completion.state, .completedWithFailures)
        XCTAssertEqual(completion.exitStatus, 130)
        XCTAssertTrue(completion.stderr.contains("cancel"))
    }

    func testCancellationDuringFinalRevalidationPublishesSkippedReceipt()
        async throws
    {
        try Data("payload".utf8).write(
            to: candidate.appendingPathComponent("payload.txt")
        )
        let prepared = try prepareCleanup(entries: [
            try storageEntry(for: candidate),
        ])
        let scans = Counter()
        let executor = ProjectStorageCleanupExecutor(
            operations: .init(
                authoritativeScan: { project in
                    scans.increment()
                    if scans.value == 2 {
                        throw CancellationError()
                    }
                    return try ProjectStorageScanner().scan(
                        projectURL: project
                    )
                }
            )
        )

        await XCTAssertThrowsErrorAsync {
            try await executor.execute(
                self.executionRequest(
                    cleanupID: prepared.journal.cleanupID
                )
            )
        }

        let summary = try latestSummary(
            cleanupID: prepared.journal.cleanupID
        )
        XCTAssertEqual(summary.exitStatus, 130)
        XCTAssertEqual(summary.items.singleValue?.state, .skipped)
        XCTAssertTrue(
            summary.stderr.localizedCaseInsensitiveContains("cancel")
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: candidate.path))
        XCTAssertTrue(try pendingQuarantines().isEmpty)
    }

    func testDurabilityAndReadOnlyFailuresNeverCauseBroadDeletion()
        async throws
    {
        try Data("keep".utf8).write(
            to: candidate.appendingPathComponent("payload.txt")
        )
        let beforeDetach = try prepareCleanup(entries: [
            try storageEntry(for: candidate),
        ])
        enum DurabilityFailure: Error { case journal }
        let journalFailure = ProjectStorageCleanupExecutor(
            operations: .init(
                beforeAppendDisposition: { record in
                    if record.state == .detachIntent {
                        throw DurabilityFailure.journal
                    }
                }
            )
        )
        await XCTAssertThrowsErrorAsync {
            try await journalFailure.execute(
                self.executionRequest(
                    cleanupID: beforeDetach.journal.cleanupID
                )
            )
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: candidate.path))
        XCTAssertTrue(try pendingQuarantines().isEmpty)

        let readOnlyPreparation = try prepareCleanup(
            entries: [try storageEntry(for: candidate)],
            cleanupID: UUID()
        )
        let skippedDurability = ExecutionDurabilityWitness()
        let readOnly = ProjectStorageCleanupExecutor(
            operations: .init(
                beforeAppendDisposition: skippedDurability.begin,
                syncFile: skippedDurability.syncFile,
                syncDirectory: skippedDurability.syncDirectory,
                renameExclusive: { _, _, _, _, flags in
                    XCTAssertEqual(flags, UInt32(RENAME_EXCL))
                    errno = EROFS
                    return -1
                },
                checkpoint: skippedDurability.checkpoint
            )
        )
        let result = try await readOnly.execute(
            executionRequest(
                cleanupID: readOnlyPreparation.journal.cleanupID
            )
        )
        XCTAssertEqual(
            result.summary.items.singleValue?.state,
            .skipped
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: candidate.path))
        XCTAssertTrue(try pendingQuarantines().isEmpty)
        try assertCompleteExecutionProvenance(
            preparation: readOnlyPreparation,
            summary: result.summary
        )
        assertDurableCompletion(
            skippedDurability,
            terminalStates: [.skipped]
        )
    }

    func testPreparationAuthorityRequiresExactNoFollowCrossBoundPair()
        async throws
    {
        try Data("authority".utf8).write(
            to: candidate.appendingPathComponent("payload.txt")
        )
        let first = try prepareCleanup(entries: [
            try storageEntry(for: candidate),
        ])
        let second = try prepareCleanup(
            entries: [try storageEntry(for: candidate)],
            cleanupID: UUID()
        )
        let secondProvenance = try Data(contentsOf: second.provenanceURL)
        try secondProvenance.write(to: first.provenanceURL, options: .atomic)

        await assertExecutionRejectedWithoutSourceMutation(
            cleanupID: first.journal.cleanupID,
            expectedPayload: "authority"
        )

        let third = try prepareCleanup(
            entries: [try storageEntry(for: candidate)],
            cleanupID: UUID()
        )
        let fourth = try prepareCleanup(
            entries: [try storageEntry(for: candidate)],
            cleanupID: UUID()
        )
        try Data(contentsOf: fourth.journalURL).write(
            to: third.journalURL,
            options: .atomic
        )
        await assertExecutionRejectedWithoutSourceMutation(
            cleanupID: third.journal.cleanupID,
            expectedPayload: "authority"
        )

        for target in [
            "project",
            "history",
            "collection",
            "operation",
            "journal",
            "provenance",
        ] {
            try? FileManager.default.removeItem(at: root)
            try initializeFixture()
            try Data("authority".utf8).write(
                to: candidate.appendingPathComponent("payload.txt")
            )
            let prepared = try prepareCleanup(entries: [
                try storageEntry(for: candidate),
            ])
            let history = project.appendingPathComponent(
                ProjectOperationHistoryWriter.historyDirectoryName
            )
            let collection = history.appendingPathComponent(
                ProjectStorageCleanupReceiptWriter.collectionDirectoryName
            )
            let targetURL: URL
            switch target {
            case "project":
                targetURL = project
            case "history":
                targetURL = history
            case "collection":
                targetURL = collection
            case "operation":
                targetURL = prepared.operationDirectoryURL
            case "journal":
                targetURL = prepared.journalURL
            default:
                targetURL = prepared.provenanceURL
            }
            let retained = root.appendingPathComponent(
                "retained-\(target)",
                isDirectory: targetURL.pathExtension.isEmpty
            )
            try FileManager.default.moveItem(at: targetURL, to: retained)
            try FileManager.default.createSymbolicLink(
                at: targetURL,
                withDestinationURL: retained
            )
            await assertExecutionRejectedWithoutSourceMutation(
                cleanupID: prepared.journal.cleanupID,
                expectedPayload: "authority"
            )
        }

        try? FileManager.default.removeItem(at: root)
        try initializeFixture()
        try Data("authority".utf8).write(
            to: candidate.appendingPathComponent("payload.txt")
        )
        let nonregular = try prepareCleanup(entries: [
            try storageEntry(for: candidate),
        ])
        try FileManager.default.removeItem(at: nonregular.provenanceURL)
        try FileManager.default.createDirectory(
            at: nonregular.provenanceURL,
            withIntermediateDirectories: false
        )
        await assertExecutionRejectedWithoutSourceMutation(
            cleanupID: nonregular.journal.cleanupID,
            expectedPayload: "authority"
        )

        for leaf in ["journal", "provenance"] {
            for shape in ["directory", "fifo"] {
                try? FileManager.default.removeItem(at: root)
                try initializeFixture()
                try Data("authority".utf8).write(
                    to: candidate.appendingPathComponent("payload.txt")
                )
                let prepared = try prepareCleanup(entries: [
                    try storageEntry(for: candidate),
                ])
                let target = leaf == "journal"
                    ? prepared.journalURL
                    : prepared.provenanceURL
                try FileManager.default.removeItem(at: target)
                if shape == "directory" {
                    try FileManager.default.createDirectory(
                        at: target,
                        withIntermediateDirectories: false
                    )
                } else {
                    XCTAssertEqual(Darwin.mkfifo(target.path, 0o600), 0)
                }
                await assertExecutionRejectedWithoutSourceMutation(
                    cleanupID: prepared.journal.cleanupID,
                    expectedPayload: "authority"
                )
            }
        }

        try? FileManager.default.removeItem(at: root)
        try initializeFixture()
        try Data("authority".utf8).write(
            to: candidate.appendingPathComponent("payload.txt")
        )
        let expected = try prepareCleanup(entries: [
            try storageEntry(for: candidate),
        ])
        let foreign = try prepareCleanup(
            entries: [try storageEntry(for: candidate)],
            cleanupID: UUID()
        )
        try Data(contentsOf: foreign.journalURL).write(
            to: expected.journalURL,
            options: .atomic
        )
        try Data(contentsOf: foreign.provenanceURL).write(
            to: expected.provenanceURL,
            options: .atomic
        )
        let downstreamCalls = Counter()
        await XCTAssertThrowsErrorAsync {
            try await ProjectStorageCleanupExecutor(
                operations: .init(
                    acquireAssociatedLock: { _, _, _ in
                        downstreamCalls.increment()
                        return {}
                    },
                    authoritativeScan: { project in
                        downstreamCalls.increment()
                        return try ProjectStorageScanner().scan(
                            projectURL: project
                        )
                    },
                    renameExclusive: { _, _, _, _, _ in
                        downstreamCalls.increment()
                        errno = EPERM
                        return -1
                    },
                    trashItem: { _ in
                        downstreamCalls.increment()
                        throw CocoaError(.fileWriteUnknown)
                    }
                )
            ).execute(
                self.executionRequest(cleanupID: expected.journal.cleanupID)
            )
        }
        XCTAssertEqual(downstreamCalls.value, 0)
        XCTAssertEqual(
            try Data(
                contentsOf: candidate.appendingPathComponent("payload.txt")
            ),
            Data("authority".utf8)
        )

        try? FileManager.default.removeItem(at: root)
        try initializeFixture()
        try Data("authority".utf8).write(
            to: candidate.appendingPathComponent("payload.txt")
        )
        let local = try prepareCleanup(entries: [
            try storageEntry(for: candidate),
        ])
        let otherProject = root.appendingPathComponent(
            "Foreign.lungfish",
            isDirectory: true
        )
        let otherCandidate = otherProject.appendingPathComponent(
            ".foreign.lungfishgenotype.candidate-artifact-work",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: otherCandidate,
            withIntermediateDirectories: true
        )
        try bindCompletedMarker(
            to: otherCandidate,
            projectURL: otherProject
        )
        try Data("foreign".utf8).write(
            to: otherCandidate.appendingPathComponent("payload.txt")
        )
        let foreignSameID = try prepareCleanup(
            projectURL: otherProject,
            entries: [
                try storageEntry(
                    for: otherCandidate,
                    projectURL: otherProject
                ),
            ],
            cleanupID: local.journal.cleanupID
        )
        try Data(contentsOf: foreignSameID.journalURL).write(
            to: local.journalURL,
            options: .atomic
        )
        try Data(contentsOf: foreignSameID.provenanceURL).write(
            to: local.provenanceURL,
            options: .atomic
        )
        await assertExecutionRejectedWithoutSourceMutation(
            cleanupID: local.journal.cleanupID,
            expectedPayload: "authority"
        )

        try? FileManager.default.removeItem(at: root)
        try initializeFixture()
        try Data("authority".utf8).write(
            to: candidate.appendingPathComponent("payload.txt")
        )
        let wrongEnvelopeID = try prepareCleanup(entries: [
            try storageEntry(for: candidate),
        ])
        try ProvenanceJSON.encoder.encode(
            replacingPreparationEnvelopeID(
                wrongEnvelopeID.provenance,
                with: UUID()
            )
        ).write(
            to: wrongEnvelopeID.provenanceURL,
            options: .atomic
        )
        await assertExecutionRejectedWithoutSourceMutation(
            cleanupID: wrongEnvelopeID.journal.cleanupID,
            expectedPayload: "authority"
        )

        for field in ["path", "checksum", "size"] {
            try? FileManager.default.removeItem(at: root)
            try initializeFixture()
            try Data("authority".utf8).write(
                to: candidate.appendingPathComponent("payload.txt")
            )
            let prepared = try prepareCleanup(entries: [
                try storageEntry(for: candidate),
            ])
            let output = try XCTUnwrap(prepared.provenance.output)
            let replacement = ProvenanceFileDescriptor(
                path: field == "path"
                    ? prepared.operationDirectoryURL
                        .appendingPathComponent("other-journal.json").path
                    : output.path,
                checksumSHA256: field == "checksum"
                    ? String(repeating: "a", count: 64)
                    : output.checksumSHA256,
                fileSize: field == "size"
                    ? (output.fileSize ?? 0) + 1
                    : output.fileSize,
                format: output.format,
                role: output.role,
                originPath: output.originPath,
                sourceProvenancePath: output.sourceProvenancePath
            )
            let forged = replacingPreparationOutput(
                prepared.provenance,
                with: replacement
            )
            try ProvenanceJSON.encoder.encode(forged).write(
                to: prepared.provenanceURL,
                options: .atomic
            )
            await assertExecutionRejectedWithoutSourceMutation(
                cleanupID: prepared.journal.cleanupID,
                expectedPayload: "authority"
            )
        }

        try? FileManager.default.removeItem(at: root)
        try initializeFixture()
        try Data("authority".utf8).write(
            to: candidate.appendingPathComponent("payload.txt")
        )
        for leafRole in [
            ProjectStorageCleanupExecutor.PreparationFileRole.journal,
            .provenance,
        ] {
            try? FileManager.default.removeItem(at: root)
            try initializeFixture()
            try Data("authority".utf8).write(
                to: candidate.appendingPathComponent("payload.txt")
            )
            let swappedDuringRead = try prepareCleanup(entries: [
                try storageEntry(for: candidate),
            ])
            let target = leafRole == .journal
                ? swappedDuringRead.journalURL
                : swappedDuringRead.provenanceURL
            let original = try Data(contentsOf: target)
            let once = Flag()
            let swapping = ProjectStorageCleanupExecutor(
                operations: .init(
                    afterReadPreparationFile: { role in
                        guard role == leafRole, !once.value else { return }
                        once.set()
                        try original.write(
                            to: target,
                            options: .atomic
                        )
                    }
                )
            )
            await XCTAssertThrowsErrorAsync {
                try await swapping.execute(
                    self.executionRequest(
                        cleanupID: swappedDuringRead.journal.cleanupID
                    )
                )
            }
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: candidate.path)
            )
        }
    }

    func testFinalPreDetachGateRunsUnderLockAndRejectsNewKeepPolicy()
        async throws
    {
        try Data("payload".utf8).write(
            to: candidate.appendingPathComponent("payload.txt")
        )
        let prepared = try prepareCleanup(entries: [
            try storageEntry(for: candidate),
        ])
        let events = EventRecorder()
        let renameCalls = Counter()
        let trashCalls = Counter()
        let executor = ProjectStorageCleanupExecutor(
            operations: .init(
                acquireAssociatedLock: { _, _, _ in
                    events.append("lock")
                    return { events.append("unlock") }
                },
                authoritativeScan: {
                    events.append("scan")
                    return try ProjectStorageScanner().scan(projectURL: $0)
                },
                afterAuthorityVerified: { _ in
                    events.append("verified")
                    try self.rewriteMarkerKeepingIntermediates(
                        at: self.candidate
                    )
                },
                beforeAppendDisposition: { record in
                    events.append("record:\(record.state.rawValue)")
                },
                renameExclusive: { _, _, _, _, _ in
                    renameCalls.increment()
                    errno = EPERM
                    return -1
                },
                trashItem: { _ in
                    trashCalls.increment()
                    throw CocoaError(.fileWriteUnknown)
                }
            )
        )

        let result = try await executor.execute(
            executionRequest(cleanupID: prepared.journal.cleanupID)
        )

        XCTAssertEqual(
            result.summary.items.singleValue?.state,
            .skipped
        )
        XCTAssertTrue(
            result.summary.items.singleValue?.reason?
                .localizedCaseInsensitiveContains("keep") == true
        )
        XCTAssertEqual(renameCalls.value, 0)
        XCTAssertEqual(trashCalls.value, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: candidate.path))
        XCTAssertTrue(try pendingQuarantines().isEmpty)
        let values = events.values
        XCTAssertTrue(
            values.firstIndex(of: "lock")!
                < values.firstIndex(of: "scan")!
        )
        XCTAssertTrue(
            values.firstIndex(of: "scan")!
                < values.firstIndex(of: "verified")!
        )
        XCTAssertTrue(
            values.firstIndex(of: "verified")!
                < values.firstIndex(of: "record:skipped")!
        )
        XCTAssertTrue(
            values.firstIndex(of: "record:skipped")!
                < values.firstIndex(of: "unlock")!
        )

        try resetCandidate()
        try Data("stale".utf8).write(
            to: candidate.appendingPathComponent("payload.txt")
        )
        let stale = try prepareCleanup(
            entries: [try storageEntry(for: candidate)],
            cleanupID: UUID()
        )
        try Data("changed".utf8).write(
            to: candidate.appendingPathComponent("payload.txt")
        )
        let staleSeamCalls = Counter()
        let staleRenameCalls = Counter()
        let staleTrashCalls = Counter()
        let staleResult = try await ProjectStorageCleanupExecutor(
            operations: .init(
                afterAuthorityVerified: { _ in
                    staleSeamCalls.increment()
                },
                renameExclusive: { _, _, _, _, _ in
                    staleRenameCalls.increment()
                    errno = EPERM
                    return -1
                },
                trashItem: { _ in
                    staleTrashCalls.increment()
                    throw CocoaError(.fileWriteUnknown)
                }
            )
        ).execute(
            executionRequest(cleanupID: stale.journal.cleanupID)
        )
        XCTAssertEqual(
            staleResult.summary.items.singleValue?.state,
            .skipped
        )
        XCTAssertEqual(staleSeamCalls.value, 0)
        XCTAssertEqual(staleRenameCalls.value, 0)
        XCTAssertEqual(staleTrashCalls.value, 0)
        XCTAssertEqual(
            try Data(
                contentsOf:
                    candidate.appendingPathComponent("payload.txt")
            ),
            Data("changed".utf8)
        )
    }

    func testPostAuthoritySubstitutionSeamFailsClosedForEveryShape()
        async throws
    {
        enum Mutation {
            case replaceRoot
            case rewriteSameSize
            case metadataOnly
            case replaceFileWithSpecial
            case symlinkRoot
            case replaceParent
        }
        for mutation in [
            Mutation.replaceRoot,
            .rewriteSameSize,
            .metadataOnly,
            .replaceFileWithSpecial,
            .symlinkRoot,
            .replaceParent,
        ] {
            try resetCandidate()
            try Data("original".utf8).write(
                to: candidate.appendingPathComponent("payload.txt")
            )
            let prepared = try prepareCleanup(entries: [
                try storageEntry(for: candidate),
            ])
            let displaced = root.appendingPathComponent(
                "displaced-\(UUID().uuidString)",
                isDirectory: true
            )
            let seamCalls = Counter()
            let renameCalls = Counter()
            let trashCalls = Counter()
            let executor = ProjectStorageCleanupExecutor(
                operations: .init(
                    afterAuthorityVerified: { _ in
                        seamCalls.increment()
                        switch mutation {
                        case .replaceRoot:
                            try FileManager.default.moveItem(
                                at: self.candidate,
                                to: displaced
                            )
                            try FileManager.default.createDirectory(
                                at: self.candidate,
                                withIntermediateDirectories: false
                            )
                            try Data("replacement".utf8).write(
                                to: self.candidate.appendingPathComponent(
                                    "payload.txt"
                                )
                            )
                        case .rewriteSameSize:
                            try Data("mutated!".utf8).write(
                                to: self.candidate.appendingPathComponent(
                                    "payload.txt"
                                )
                            )
                        case .metadataOnly:
                            try FileManager.default.setAttributes(
                                [.posixPermissions: 0o600],
                                ofItemAtPath:
                                    self.candidate.appendingPathComponent(
                                        "payload.txt"
                                    ).path
                            )
                        case .replaceFileWithSpecial:
                            let payload =
                                self.candidate.appendingPathComponent(
                                    "payload.txt"
                                )
                            try FileManager.default.moveItem(
                                at: payload,
                                to: displaced
                            )
                            XCTAssertEqual(
                                Darwin.mkfifo(payload.path, 0o600),
                                0
                            )
                        case .symlinkRoot:
                            try FileManager.default.moveItem(
                                at: self.candidate,
                                to: displaced
                            )
                            try FileManager.default.createSymbolicLink(
                                at: self.candidate,
                                withDestinationURL: displaced
                            )
                        case .replaceParent:
                            try FileManager.default.moveItem(
                                at: self.project,
                                to: displaced
                            )
                            try FileManager.default.createDirectory(
                                at: self.project,
                                withIntermediateDirectories: false
                            )
                        }
                    },
                    renameExclusive: {
                        sourceParent,
                        source,
                        destinationParent,
                        destination,
                        flags in
                        renameCalls.increment()
                        XCTAssertEqual(flags, UInt32(RENAME_EXCL))
                        return source.withCString { sourcePointer in
                            destination.withCString { destinationPointer in
                                Darwin.renameatx_np(
                                    sourceParent,
                                    sourcePointer,
                                    destinationParent,
                                    destinationPointer,
                                    flags
                                )
                            }
                        }
                    },
                    trashItem: { _ in
                        trashCalls.increment()
                        throw CocoaError(.fileWriteUnknown)
                    }
                )
            )

            do {
                let result = try await executor.execute(
                    executionRequest(cleanupID: prepared.journal.cleanupID)
                )
                XCTAssertEqual(
                    result.summary.items.singleValue?.state,
                    .skipped
                )
            } catch {
                // Replacing the project root may make final result
                // publication impossible, but must still fail closed.
            }
            XCTAssertEqual(seamCalls.value, 1)
            XCTAssertEqual(renameCalls.value, 0)
            XCTAssertEqual(trashCalls.value, 0)
            XCTAssertTrue(try pendingQuarantines().isEmpty)
            switch mutation {
            case .replaceRoot, .symlinkRoot:
                XCTAssertEqual(
                    try Data(
                        contentsOf:
                            displaced.appendingPathComponent("payload.txt")
                    ),
                    Data("original".utf8)
                )
            case .rewriteSameSize:
                XCTAssertEqual(
                    try Data(
                        contentsOf:
                            candidate.appendingPathComponent("payload.txt")
                    ),
                    Data("mutated!".utf8)
                )
            case .metadataOnly:
                let permissions = try XCTUnwrap(
                    try FileManager.default.attributesOfItem(
                        atPath:
                            candidate.appendingPathComponent(
                                "payload.txt"
                            ).path
                    )[.posixPermissions] as? NSNumber
                )
                XCTAssertEqual(permissions.intValue & 0o777, 0o600)
            case .replaceFileWithSpecial:
                var information = stat()
                XCTAssertEqual(
                    Darwin.lstat(
                        candidate.appendingPathComponent(
                            "payload.txt"
                        ).path,
                        &information
                    ),
                    0
                )
                XCTAssertEqual(information.st_mode & S_IFMT, S_IFIFO)
                XCTAssertEqual(
                    try Data(contentsOf: displaced),
                    Data("original".utf8)
                )
            case .replaceParent:
                XCTAssertEqual(
                    try Data(
                        contentsOf:
                            displaced
                                .appendingPathComponent(
                                    candidate.lastPathComponent
                                )
                                .appendingPathComponent("payload.txt")
                    ),
                    Data("original".utf8)
                )
            }
            var displacedInformation = stat()
            if Darwin.lstat(displaced.path, &displacedInformation) == 0 {
                try FileManager.default.removeItem(at: displaced)
            }
            var candidateInformation = stat()
            if Darwin.lstat(candidate.path, &candidateInformation) == 0 {
                try? FileManager.default.removeItem(at: candidate)
            }
            if !FileManager.default.fileExists(atPath: project.path) {
                try FileManager.default.createDirectory(
                    at: project,
                    withIntermediateDirectories: true
                )
            }
        }
    }

    func testRenameBoundarySubstitutionIsNeverSentToTrash() async throws {
        try Data("original".utf8).write(
            to: candidate.appendingPathComponent("payload.txt")
        )
        let prepared = try prepareCleanup(entries: [
            try storageEntry(for: candidate),
        ])
        let displaced = root.appendingPathComponent(
            "displaced-original",
            isDirectory: true
        )
        let trashCalls = Counter()
        let executor = ProjectStorageCleanupExecutor(
            operations: .init(
                renameExclusive: {
                    parent,
                    source,
                    destinationParent,
                    destination,
                    flags in
                    try! FileManager.default.moveItem(
                        at: self.candidate,
                        to: displaced
                    )
                    try! FileManager.default.createDirectory(
                        at: self.candidate,
                        withIntermediateDirectories: false
                    )
                    try! Data("foreign".utf8).write(
                        to: self.candidate.appendingPathComponent(
                            "payload.txt"
                        )
                    )
                    return source.withCString { sourcePointer in
                        destination.withCString { destinationPointer in
                            Darwin.renameatx_np(
                                parent,
                                sourcePointer,
                                destinationParent,
                                destinationPointer,
                                flags
                            )
                        }
                    }
                },
                trashItem: { _ in
                    trashCalls.increment()
                    throw CocoaError(.fileWriteUnknown)
                }
            )
        )

        let result = try await executor.execute(
            executionRequest(cleanupID: prepared.journal.cleanupID)
        )

        let item = try XCTUnwrap(result.summary.items.singleValue)
        XCTAssertEqual(item.state, .outcomeUnknown)
        XCTAssertNotNil(item.quarantineRelativePath)
        XCTAssertEqual(trashCalls.value, 0)
        XCTAssertEqual(
            try Data(
                contentsOf: displaced.appendingPathComponent("payload.txt")
            ),
            Data("original".utf8)
        )
        let quarantine = project.appendingPathComponent(
            try XCTUnwrap(item.quarantineRelativePath)
        )
        XCTAssertEqual(
            try Data(
                contentsOf: quarantine.appendingPathComponent("payload.txt")
            ),
            Data("foreign".utf8)
        )
    }

    func testDetachUsesSameParentDirfdExactLeafAndDeterministicExclusiveQuarantine()
        async throws
    {
        try Data("payload".utf8).write(
            to: candidate.appendingPathComponent("payload.txt")
        )
        let prepared = try prepareCleanup(entries: [
            try storageEntry(for: candidate),
        ])
        let item = try XCTUnwrap(prepared.journal.items.singleValue)
        let expectedQuarantine =
            ".lungfish-trash-pending-"
            + prepared.journal.cleanupID.uuidString.lowercased()
            + "-" + item.id.uuidString.lowercased()
        let observed = StringRecorder()
        let executor = ProjectStorageCleanupExecutor(
            operations: .init(
                renameExclusive: {
                    sourceParent,
                    source,
                    destinationParent,
                    destination,
                    flags in
                    XCTAssertEqual(sourceParent, destinationParent)
                    XCTAssertEqual(source, self.candidate.lastPathComponent)
                    XCTAssertEqual(destination, expectedQuarantine)
                    XCTAssertEqual(flags, UInt32(RENAME_EXCL))
                    observed.append(destination)
                    return source.withCString { sourcePointer in
                        destination.withCString { destinationPointer in
                            Darwin.renameatx_np(
                                sourceParent,
                                sourcePointer,
                                destinationParent,
                                destinationPointer,
                                flags
                            )
                        }
                    }
                },
                trashItem: { quarantine in
                    let destination = self.fakeTrash.appendingPathComponent(
                        quarantine.lastPathComponent
                    )
                    try FileManager.default.moveItem(
                        at: quarantine,
                        to: destination
                    )
                    return destination
                }
            )
        )
        _ = try await executor.execute(
            executionRequest(cleanupID: prepared.journal.cleanupID)
        )
        XCTAssertEqual(observed.values, [expectedQuarantine])

        try resetCandidate()
        try Data("collision".utf8).write(
            to: candidate.appendingPathComponent("payload.txt")
        )
        let collisionPreparation = try prepareCleanup(
            entries: [try storageEntry(for: candidate)],
            cleanupID: UUID()
        )
        let collisionItem = try XCTUnwrap(
            collisionPreparation.journal.items.singleValue
        )
        let collisionName =
            ".lungfish-trash-pending-"
            + collisionPreparation.journal.cleanupID.uuidString.lowercased()
            + "-" + collisionItem.id.uuidString.lowercased()
        let collisionURL = project.appendingPathComponent(collisionName)
        try FileManager.default.createDirectory(
            at: collisionURL,
            withIntermediateDirectories: false
        )
        try Data("poison".utf8).write(
            to: collisionURL.appendingPathComponent("payload.txt")
        )

        let collision = try await ProjectStorageCleanupExecutor().execute(
            executionRequest(
                cleanupID: collisionPreparation.journal.cleanupID
            )
        )
        XCTAssertEqual(
            collision.summary.items.singleValue?.state,
            .skipped
        )
        XCTAssertEqual(
            try Data(
                contentsOf: collisionURL.appendingPathComponent("payload.txt")
            ),
            Data("poison".utf8)
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: candidate.path))
    }

    func testDurableStateMachineCrashRecoveryAndTask5BytesAreImmutable()
        async throws
    {
        try Data("payload".utf8).write(
            to: candidate.appendingPathComponent("payload.txt")
        )
        let prepared = try prepareCleanup(entries: [
            try storageEntry(for: candidate),
        ])
        let journalBefore = try Data(contentsOf: prepared.journalURL)
        let provenanceBefore = try Data(contentsOf: prepared.provenanceURL)
        enum SimulatedCrash: Error { case checkpoint }
        let crashing = ProjectStorageCleanupExecutor(
            operations: .init(
                checkpoint: { checkpoint, _ in
                    if checkpoint == .afterTrashIntentBeforeTrash {
                        throw SimulatedCrash.checkpoint
                    }
                }
            )
        )
        await XCTAssertThrowsErrorAsync {
            try await crashing.execute(
                self.executionRequest(
                    cleanupID: prepared.journal.cleanupID
                )
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: candidate.path))
        XCTAssertEqual(try pendingQuarantines().count, 1)

        let trashCalls = Counter()
        let resumed = ProjectStorageCleanupExecutor(
            operations: .init(
                trashItem: { quarantine in
                    trashCalls.increment()
                    let destination =
                        self.fakeTrash.appendingPathComponent(
                            quarantine.lastPathComponent
                        )
                    try FileManager.default.moveItem(
                        at: quarantine,
                        to: destination
                    )
                    return destination
                }
            )
        )
        let result = try await resumed.execute(
            executionRequest(cleanupID: prepared.journal.cleanupID)
        )
        XCTAssertEqual(
            result.summary.items.singleValue?.state,
            .movedToTrash
        )
        let recordsBeforeSecondExecution = try dispositionRecords(
            cleanupID: prepared.journal.cleanupID
        )
        XCTAssertEqual(
            recordsBeforeSecondExecution.map(\.state),
            [.detachIntent, .detached, .trashIntent, .movedToTrash]
        )
        let stateURL = operationDirectory(
            cleanupID: prepared.journal.cleanupID
        ).appendingPathComponent(
            ProjectStorageCleanupExecutor.stateFileName
        )
        let stateBeforeSecondExecution = try Data(contentsOf: stateURL)
        _ = try await resumed.execute(
            executionRequest(cleanupID: prepared.journal.cleanupID)
        )
        XCTAssertEqual(trashCalls.value, 1)
        XCTAssertEqual(
            try Data(contentsOf: stateURL),
            stateBeforeSecondExecution
        )
        XCTAssertEqual(try Data(contentsOf: prepared.journalURL), journalBefore)
        XCTAssertEqual(
            try Data(contentsOf: prepared.provenanceURL),
            provenanceBefore
        )

    }

    func testEveryMutationAndDispositionDurabilityBoundaryIsRecoverable()
        async throws
    {
        enum SimulatedCrash: Error { case checkpoint }
        let appendBoundaries: [
            ProjectStorageCleanupExecutor.Checkpoint
        ] = [
            .afterDispositionWriteBeforeFileSync,
            .afterDispositionFileSyncBeforeDirectorySync,
            .afterDispositionDurable,
        ]
        let dispositionStates: [
            ProjectStorageCleanupDispositionRecord.State
        ] = [
            .detachIntent,
            .detached,
            .trashIntent,
            .movedToTrash,
        ]
        for stateToFail in dispositionStates {
            for boundaryToFail in appendBoundaries {
                try? FileManager.default.removeItem(at: root)
                try initializeFixture()
                try Data("payload".utf8).write(
                    to: candidate.appendingPathComponent("payload.txt")
                )
                let prepared = try prepareCleanup(entries: [
                    try storageEntry(for: candidate),
                ])
                let currentState = StringRecorder()
                let trashCalls = Counter()
                let crashing = ProjectStorageCleanupExecutor(
                    operations: .init(
                        beforeAppendDisposition: {
                            currentState.append($0.state.rawValue)
                        },
                        trashItem: { quarantine in
                            trashCalls.increment()
                            let destination =
                                self.fakeTrash.appendingPathComponent(
                                    UUID().uuidString
                                )
                            try FileManager.default.moveItem(
                                at: quarantine,
                                to: destination
                            )
                            return destination
                        },
                        checkpoint: { checkpoint, _ in
                            if checkpoint == boundaryToFail,
                               currentState.last == stateToFail.rawValue {
                                throw SimulatedCrash.checkpoint
                            }
                        }
                    )
                )
                await XCTAssertThrowsErrorAsync(
                    {
                    try await crashing.execute(
                        self.executionRequest(
                            cleanupID: prepared.journal.cleanupID
                        )
                    )
                    },
                    message:
                        "\(stateToFail.rawValue) @ \(boundaryToFail)"
                )
                let resumed = try await ProjectStorageCleanupExecutor(
                    operations: .init(
                        trashItem: { quarantine in
                            trashCalls.increment()
                            let destination =
                                self.fakeTrash.appendingPathComponent(
                                    UUID().uuidString
                                )
                            try FileManager.default.moveItem(
                                at: quarantine,
                                to: destination
                            )
                            return destination
                        }
                    )
                ).execute(
                    executionRequest(
                        cleanupID: prepared.journal.cleanupID
                    )
                )
                XCTAssertEqual(
                    resumed.summary.items.singleValue?.state,
                    .movedToTrash,
                    "\(stateToFail.rawValue) @ \(boundaryToFail)"
                )
                XCTAssertEqual(
                    trashCalls.value,
                    1,
                    "\(stateToFail.rawValue) @ \(boundaryToFail)"
                )
            }
        }

        let mutationCheckpoints: [
            ProjectStorageCleanupExecutor.Checkpoint
        ] = [
            .afterDetachIntentBeforeRename,
            .afterDetachBeforeParentSync,
            .afterDetachParentSyncBeforeRecord,
            .afterDetachedRecordBeforeTrashIntent,
            .afterTrashIntentBeforeTrash,
            .afterTrashBeforeRecord,
        ]
        for checkpointToFail in mutationCheckpoints {
            try? FileManager.default.removeItem(at: root)
            try initializeFixture()
            try Data("payload".utf8).write(
                to: candidate.appendingPathComponent("payload.txt")
            )
            let prepared = try prepareCleanup(entries: [
                try storageEntry(for: candidate),
            ])
            let trashCalls = Counter()
            let crashing = ProjectStorageCleanupExecutor(
                operations: .init(
                    trashItem: { quarantine in
                        trashCalls.increment()
                        let destination =
                            self.fakeTrash.appendingPathComponent(
                                UUID().uuidString
                            )
                        try FileManager.default.moveItem(
                            at: quarantine,
                            to: destination
                        )
                        return destination
                    },
                    checkpoint: { checkpoint, _ in
                        if checkpoint == checkpointToFail {
                            throw SimulatedCrash.checkpoint
                        }
                    }
                )
            )
            await XCTAssertThrowsErrorAsync {
                try await crashing.execute(
                    self.executionRequest(
                        cleanupID: prepared.journal.cleanupID
                    )
                )
            }

            let resumed = try await ProjectStorageCleanupExecutor(
                operations: .init(
                    trashItem: { quarantine in
                        trashCalls.increment()
                        let destination =
                            self.fakeTrash.appendingPathComponent(
                                UUID().uuidString
                            )
                        try FileManager.default.moveItem(
                            at: quarantine,
                            to: destination
                        )
                        return destination
                    }
                )
            ).execute(
                executionRequest(cleanupID: prepared.journal.cleanupID)
            )
            XCTAssertEqual(
                resumed.summary.items.singleValue?.state,
                checkpointToFail == .afterTrashBeforeRecord
                    ? .outcomeUnknown
                    : .movedToTrash,
                "\(checkpointToFail)"
            )
            XCTAssertEqual(trashCalls.value, 1)
        }

        let restoreCheckpoints: [
            ProjectStorageCleanupExecutor.Checkpoint
        ] = [
            .afterTrashFailureBeforeRestore,
            .afterRestoreBeforeParentSync,
            .afterRestoreParentSyncBeforeRecord,
        ]
        for checkpointToFail in restoreCheckpoints {
            try? FileManager.default.removeItem(at: root)
            try initializeFixture()
            try Data("payload".utf8).write(
                to: candidate.appendingPathComponent("payload.txt")
            )
            let prepared = try prepareCleanup(entries: [
                try storageEntry(for: candidate),
            ])
            enum TrashFailure: Error { case rejected }
            let crashing = ProjectStorageCleanupExecutor(
                operations: .init(
                    trashItem: { _ in throw TrashFailure.rejected },
                    checkpoint: { checkpoint, _ in
                        if checkpoint == checkpointToFail {
                            throw SimulatedCrash.checkpoint
                        }
                    }
                )
            )
            await XCTAssertThrowsErrorAsync {
                try await crashing.execute(
                    self.executionRequest(
                        cleanupID: prepared.journal.cleanupID
                    )
                )
            }
            let resumedTrashCalls = Counter()
            let resumed = try await ProjectStorageCleanupExecutor(
                operations: .init(
                    trashItem: { _ in
                        resumedTrashCalls.increment()
                        throw TrashFailure.rejected
                    }
                )
            ).execute(
                executionRequest(cleanupID: prepared.journal.cleanupID)
            )
            XCTAssertEqual(
                resumedTrashCalls.value,
                0,
                "\(checkpointToFail)"
            )
            XCTAssertEqual(
                resumed.summary.items.singleValue?.state,
                .restoredAfterTrashFailure,
                "\(checkpointToFail)"
            )
            XCTAssertEqual(
                try Data(
                    contentsOf:
                        candidate.appendingPathComponent("payload.txt")
                ),
                Data("payload".utf8)
            )
        }

        try? FileManager.default.removeItem(at: root)
        try initializeFixture()
        try Data("payload".utf8).write(
            to: candidate.appendingPathComponent("payload.txt")
        )
        let retainedPreparation = try prepareCleanup(entries: [
            try storageEntry(for: candidate),
        ])
        enum TrashFailure: Error { case rejected }
        let retainedCrash = ProjectStorageCleanupExecutor(
            operations: .init(
                trashItem: { _ in
                    try FileManager.default.createDirectory(
                        at: self.candidate,
                        withIntermediateDirectories: false
                    )
                    try Data("replacement".utf8).write(
                        to: self.candidate.appendingPathComponent(
                            "payload.txt"
                        )
                    )
                    throw TrashFailure.rejected
                },
                checkpoint: { checkpoint, _ in
                    if checkpoint == .afterQuarantineRetainedBeforeRecord {
                        throw SimulatedCrash.checkpoint
                    }
                }
            )
        )
        await XCTAssertThrowsErrorAsync {
            try await retainedCrash.execute(
                self.executionRequest(
                    cleanupID: retainedPreparation.journal.cleanupID
                )
            )
        }
        let resumedTrashCalls = Counter()
        let retained = try await ProjectStorageCleanupExecutor(
            operations: .init(
                trashItem: { _ in
                    resumedTrashCalls.increment()
                    throw TrashFailure.rejected
                }
            )
        ).execute(
            executionRequest(
                cleanupID: retainedPreparation.journal.cleanupID
            )
        )
        XCTAssertEqual(resumedTrashCalls.value, 0)
        XCTAssertEqual(
            retained.summary.items.singleValue?.state,
            .quarantineRetained
        )
        XCTAssertEqual(
            try Data(
                contentsOf:
                    candidate.appendingPathComponent("payload.txt")
            ),
            Data("replacement".utf8)
        )

        for stateToFail in [
            ProjectStorageCleanupDispositionRecord.State.detachIntent,
            .detached,
            .trashIntent,
            .movedToTrash,
        ] {
            try? FileManager.default.removeItem(at: root)
            try initializeFixture()
            try Data("payload".utf8).write(
                to: candidate.appendingPathComponent("payload.txt")
            )
            let prepared = try prepareCleanup(entries: [
                try storageEntry(for: candidate),
            ])
            let failing = ProjectStorageCleanupExecutor(
                operations: .init(
                    beforeAppendDisposition: { record in
                        if record.state == stateToFail {
                            throw SimulatedCrash.checkpoint
                        }
                    },
                    trashItem: { quarantine in
                        let destination =
                            self.fakeTrash.appendingPathComponent(
                                UUID().uuidString
                            )
                        try FileManager.default.moveItem(
                            at: quarantine,
                            to: destination
                        )
                        return destination
                    }
                )
            )
            await XCTAssertThrowsErrorAsync {
                try await failing.execute(
                    self.executionRequest(
                        cleanupID: prepared.journal.cleanupID
                    )
                )
            }
            let sourceStillExists = FileManager.default.fileExists(
                atPath: candidate.path
            )
            let quarantineExists = !(try pendingQuarantines()).isEmpty
            XCTAssertTrue(
                sourceStillExists
                    || quarantineExists
                    || stateToFail == .movedToTrash,
                stateToFail.rawValue
            )
        }
    }

    func testSummaryAndProvenancePublicationCrashBoundariesResumeSafely()
        async throws
    {
        enum SimulatedCrash: Error { case checkpoint }
        let boundaries: [ProjectStorageCleanupExecutor.Checkpoint] = [
            .afterSummaryWriteBeforeFileSync,
            .afterSummaryFileSyncBeforeDirectorySync,
            .afterSummaryDirectorySyncBeforeDurable,
            .afterProvenanceWriteBeforeFileSync,
            .afterProvenanceFileSyncBeforeDirectorySync,
            .afterProvenanceDirectorySyncBeforeDurable,
        ]
        for boundary in boundaries {
            try? FileManager.default.removeItem(at: root)
            try initializeFixture()
            try Data("payload".utf8).write(
                to: candidate.appendingPathComponent("payload.txt")
            )
            let prepared = try prepareCleanup(entries: [
                try storageEntry(for: candidate),
            ])
            let initialTrashCalls = Counter()
            let crashing = ProjectStorageCleanupExecutor(
                operations: .init(
                    trashItem: { quarantine in
                        initialTrashCalls.increment()
                        let destination =
                            self.fakeTrash.appendingPathComponent(
                                UUID().uuidString
                            )
                        try FileManager.default.moveItem(
                            at: quarantine,
                            to: destination
                        )
                        return destination
                    },
                    checkpoint: { checkpoint, _ in
                        if checkpoint == boundary {
                            throw SimulatedCrash.checkpoint
                        }
                    }
                )
            )
            await XCTAssertThrowsErrorAsync {
                try await crashing.execute(
                    self.executionRequest(
                        cleanupID: prepared.journal.cleanupID
                    )
                )
            }
            XCTAssertEqual(initialTrashCalls.value, 1, "\(boundary)")

            let resumedTrashCalls = Counter()
            let resumed = try await ProjectStorageCleanupExecutor(
                operations: .init(
                    trashItem: { _ in
                        resumedTrashCalls.increment()
                        throw CocoaError(.fileWriteUnknown)
                    }
                )
            ).execute(
                executionRequest(cleanupID: prepared.journal.cleanupID)
            )
            XCTAssertEqual(resumedTrashCalls.value, 0, "\(boundary)")
            XCTAssertEqual(
                resumed.summary.items.singleValue?.state,
                .movedToTrash,
                "\(boundary)"
            )
            _ = try ProvenanceEnvelopeReader.decodeCanonical(
                Data(contentsOf: resumed.provenanceURL)
            )
            _ = try ProvenanceJSON.decoder.decode(
                ProjectStorageCleanupExecutionSummary.self,
                from: Data(contentsOf: resumed.summaryURL)
            )
            XCTAssertEqual(
                try Data(contentsOf: prepared.journalURL),
                try ProvenanceJSON.encoder.encode(prepared.journal)
            )
            XCTAssertEqual(
                try Data(contentsOf: prepared.provenanceURL),
                try ProvenanceJSON.encoder.encode(prepared.provenance)
            )
        }
    }

    func testEveryNonSuccessTerminalAppendBoundaryResumesExactOutcome()
        async throws
    {
        enum SimulatedCrash: Error { case checkpoint }
        enum TrashFailure: Error { case rejected }
        let boundaries: [ProjectStorageCleanupExecutor.Checkpoint] = [
            .afterDispositionWriteBeforeFileSync,
            .afterDispositionFileSyncBeforeDirectorySync,
            .afterDispositionDurable,
        ]
        let scenarios = [
            "restored",
            "retained",
            "skipped",
            "failed",
            "outcome-unknown",
            "cancellation",
        ]
        for scenario in scenarios {
            for boundary in boundaries {
                try? FileManager.default.removeItem(at: root)
                try initializeFixture()
                try Data("payload".utf8).write(
                    to: candidate.appendingPathComponent("payload.txt")
                )

                var secondCancellationItem: URL?
                if scenario == "cancellation" {
                    let second = project.appendingPathComponent(
                        ".second.lungfishgenotype.candidate-artifact-work",
                        isDirectory: true
                    )
                    try FileManager.default.createDirectory(
                        at: second,
                        withIntermediateDirectories: false
                    )
                    try bindCompletedMarker(to: second)
                    try Data("second".utf8).write(
                        to: second.appendingPathComponent("payload.txt")
                    )
                    secondCancellationItem = second
                }
                var selected = [try storageEntry(for: candidate)]
                if let secondCancellationItem {
                    selected.append(
                        try storageEntry(for: secondCancellationItem)
                    )
                }
                let prepared = try prepareCleanup(entries: selected)
                let journalBytes = try Data(
                    contentsOf: prepared.journalURL
                )
                let provenanceBytes = try Data(
                    contentsOf: prepared.provenanceURL
                )

                if scenario == "outcome-unknown" {
                    let stagingCrash = ProjectStorageCleanupExecutor(
                        operations: .init(
                            trashItem: { quarantine in
                                let destination =
                                    self.fakeTrash.appendingPathComponent(
                                        UUID().uuidString
                                    )
                                try FileManager.default.moveItem(
                                    at: quarantine,
                                    to: destination
                                )
                                return destination
                            },
                            checkpoint: { checkpoint, _ in
                                if checkpoint == .afterTrashBeforeRecord {
                                    throw SimulatedCrash.checkpoint
                                }
                            }
                        )
                    )
                    await XCTAssertThrowsErrorAsync {
                        try await stagingCrash.execute(
                            self.executionRequest(
                                cleanupID: prepared.journal.cleanupID
                            )
                        )
                    }
                }

                let targetState:
                    ProjectStorageCleanupDispositionRecord.State
                switch scenario {
                case "restored":
                    targetState = .restoredAfterTrashFailure
                case "retained":
                    targetState = .quarantineRetained
                case "skipped", "cancellation":
                    targetState = .skipped
                case "failed":
                    targetState = .failed
                default:
                    targetState = .outcomeUnknown
                }
                let currentState = StringRecorder()
                let shouldCancel = Flag()
                let checkpoint:
                    @Sendable (
                        ProjectStorageCleanupExecutor.Checkpoint,
                        UUID
                    ) throws -> Void = { observed, _ in
                        if observed == boundary,
                           currentState.last == targetState.rawValue {
                            throw SimulatedCrash.checkpoint
                        }
                    }
                let crashing: ProjectStorageCleanupExecutor
                switch scenario {
                case "restored":
                    crashing = ProjectStorageCleanupExecutor(
                        operations: .init(
                            beforeAppendDisposition: {
                                currentState.append($0.state.rawValue)
                            },
                            trashItem: { _ in
                                throw TrashFailure.rejected
                            },
                            checkpoint: checkpoint
                        )
                    )
                case "retained":
                    crashing = ProjectStorageCleanupExecutor(
                        operations: .init(
                            beforeAppendDisposition: {
                                currentState.append($0.state.rawValue)
                            },
                            trashItem: { _ in
                                try FileManager.default.createDirectory(
                                    at: self.candidate,
                                    withIntermediateDirectories: false
                                )
                                throw TrashFailure.rejected
                            },
                            checkpoint: checkpoint
                        )
                    )
                case "skipped":
                    crashing = ProjectStorageCleanupExecutor(
                        operations: .init(
                            beforeAppendDisposition: {
                                currentState.append($0.state.rawValue)
                            },
                            renameExclusive: { _, _, _, _, _ in
                                errno = EROFS
                                return -1
                            },
                            checkpoint: checkpoint
                        )
                    )
                case "failed":
                    crashing = ProjectStorageCleanupExecutor(
                        operations: .init(
                            beforeAppendDisposition: {
                                currentState.append($0.state.rawValue)
                            },
                            authoritativeScan: { _ in
                                throw TrashFailure.rejected
                            },
                            checkpoint: checkpoint
                        )
                    )
                case "cancellation":
                    crashing = ProjectStorageCleanupExecutor(
                        operations: .init(
                            cancellationCheck: {
                                if shouldCancel.value {
                                    throw CancellationError()
                                }
                            },
                            beforeAppendDisposition: {
                                currentState.append($0.state.rawValue)
                            },
                            afterAuthorityVerified: { _ in
                                shouldCancel.set()
                            },
                            trashItem: { quarantine in
                                let destination =
                                    self.fakeTrash.appendingPathComponent(
                                        UUID().uuidString
                                    )
                                try FileManager.default.moveItem(
                                    at: quarantine,
                                    to: destination
                                )
                                return destination
                            },
                            checkpoint: checkpoint
                        )
                    )
                default:
                    crashing = ProjectStorageCleanupExecutor(
                        operations: .init(
                            beforeAppendDisposition: {
                                currentState.append($0.state.rawValue)
                            },
                            trashItem: { _ in
                                throw TrashFailure.rejected
                            },
                            checkpoint: checkpoint
                        )
                    )
                }

                await XCTAssertThrowsErrorAsync(
                    {
                    try await crashing.execute(
                        self.executionRequest(
                            cleanupID: prepared.journal.cleanupID
                        )
                    )
                    },
                    message: "\(scenario) @ \(boundary)"
                )

                let resumedTrashCalls = Counter()
                let resumed = try await ProjectStorageCleanupExecutor(
                    operations: .init(
                        trashItem: { _ in
                            resumedTrashCalls.increment()
                            throw TrashFailure.rejected
                        }
                    )
                ).execute(
                    executionRequest(
                        cleanupID: prepared.journal.cleanupID
                    )
                )
                XCTAssertEqual(
                    resumedTrashCalls.value,
                    0,
                    "\(scenario) @ \(boundary)"
                )
                if scenario == "cancellation" {
                    XCTAssertEqual(
                        resumed.summary.items.filter {
                            $0.state == .movedToTrash
                        }.count,
                        1
                    )
                    XCTAssertEqual(
                        resumed.summary.items.filter {
                            $0.state == .skipped
                        }.count,
                        1
                    )
                } else {
                    XCTAssertEqual(
                        resumed.summary.items.singleValue?.state,
                        targetState,
                        "\(scenario) @ \(boundary)"
                    )
                }
                XCTAssertEqual(
                    try Data(contentsOf: prepared.journalURL),
                    journalBytes
                )
                XCTAssertEqual(
                    try Data(contentsOf: prepared.provenanceURL),
                    provenanceBytes
                )
            }
        }
    }

    func testTornTamperedOrSymlinkedExecutionLogFailsClosed()
        async throws
    {
        enum SimulatedCrash: Error { case checkpoint }
        for mutation in [
            "torn",
            "tampered",
            "symlink",
            "cleanup-id",
            "item-id",
            "project-identity",
            "quarantine-path",
            "quarantine-identity",
            "state-sequence",
        ] {
            try? FileManager.default.removeItem(at: root)
            try initializeFixture()
            try Data("payload".utf8).write(
                to: candidate.appendingPathComponent("payload.txt")
            )
            let prepared = try prepareCleanup(entries: [
                try storageEntry(for: candidate),
            ])
            let crashing = ProjectStorageCleanupExecutor(
                operations: .init(
                    checkpoint: { checkpoint, _ in
                        if checkpoint
                            == .afterDetachedRecordBeforeTrashIntent {
                            throw SimulatedCrash.checkpoint
                        }
                    }
                )
            )
            await XCTAssertThrowsErrorAsync {
                try await crashing.execute(
                    self.executionRequest(
                        cleanupID: prepared.journal.cleanupID
                    )
                )
            }
            let stateURL = operationDirectory(
                cleanupID: prepared.journal.cleanupID
            ).appendingPathComponent(
                ProjectStorageCleanupExecutor.stateFileName
            )
            switch mutation {
            case "torn":
                let descriptor = Darwin.open(
                    stateURL.path,
                    O_WRONLY | O_APPEND | O_CLOEXEC
                )
                XCTAssertGreaterThanOrEqual(descriptor, 0)
                let torn = Data(#"{"torn":"#.utf8)
                let written = torn.withUnsafeBytes { bytes in
                    Darwin.write(
                        descriptor,
                        bytes.baseAddress,
                        bytes.count
                    )
                }
                XCTAssertEqual(written, torn.count)
                XCTAssertEqual(Darwin.fsync(descriptor), 0)
                Darwin.close(descriptor)
            case "tampered":
                var data = try Data(contentsOf: stateURL)
                data[data.startIndex] ^= 0x01
                try data.write(to: stateURL, options: .atomic)
            case "symlink":
                let retained = root.appendingPathComponent("state.jsonl")
                try FileManager.default.moveItem(at: stateURL, to: retained)
                try FileManager.default.createSymbolicLink(
                    at: stateURL,
                    withDestinationURL: retained
                )
            default:
                var lines = [UInt8](try Data(contentsOf: stateURL))
                    .split(separator: UInt8(0x0a))
                    .map { Data($0) }
                let targetIndex = lines.index(before: lines.endIndex)
                var object = try XCTUnwrap(
                    JSONSerialization.jsonObject(
                        with: lines[targetIndex]
                    ) as? [String: Any]
                )
                switch mutation {
                case "cleanup-id":
                    object["cleanupID"] = UUID().uuidString.lowercased()
                case "item-id":
                    object["itemID"] = UUID().uuidString.lowercased()
                case "project-identity":
                    object["projectIdentity"] = [
                        "device": NSNumber(value: 9_999_991),
                        "inode": NSNumber(value: 9_999_992),
                    ]
                case "quarantine-path":
                    object["quarantineRelativePath"] =
                        ".lungfish-trash-pending-forged"
                case "quarantine-identity":
                    object["quarantineIdentity"] = [
                        "device": NSNumber(value: 9_999_993),
                        "inode": NSNumber(value: 9_999_994),
                    ]
                default:
                    object["state"] = "moved-to-trash"
                }
                lines[targetIndex] = try JSONSerialization.data(
                    withJSONObject: object,
                    options: [.sortedKeys]
                )
                var canonicalJSONLines = Data()
                for line in lines {
                    canonicalJSONLines.append(line)
                    canonicalJSONLines.append(0x0a)
                }
                try canonicalJSONLines.write(
                    to: stateURL,
                    options: .atomic
                )
            }
            let trashCalls = Counter()
            await XCTAssertThrowsErrorAsync {
                try await ProjectStorageCleanupExecutor(
                    operations: .init(
                        trashItem: { _ in
                            trashCalls.increment()
                            throw CocoaError(.fileWriteUnknown)
                        }
                    )
                ).execute(
                    self.executionRequest(
                        cleanupID: prepared.journal.cleanupID
                    )
                )
            }
            XCTAssertEqual(trashCalls.value, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: candidate.path))
        }
    }

    func testCrashBetweenItemsResumesWithoutTrashingFirstItemTwice()
        async throws
    {
        try Data("first".utf8).write(
            to: candidate.appendingPathComponent("payload.txt")
        )
        let second = project.appendingPathComponent(
            ".second.lungfishgenotype.candidate-artifact-work",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: second,
            withIntermediateDirectories: false
        )
        try bindCompletedMarker(to: second)
        try Data("second".utf8).write(
            to: second.appendingPathComponent("payload.txt")
        )
        let prepared = try prepareCleanup(entries: [
            try storageEntry(for: candidate),
            try storageEntry(for: second),
        ])
        enum SimulatedCrash: Error { case checkpoint }
        let terminalItems = Counter()
        let trashCalls = Counter()
        let crashing = ProjectStorageCleanupExecutor(
            operations: .init(
                trashItem: { quarantine in
                    trashCalls.increment()
                    let destination =
                        self.fakeTrash.appendingPathComponent(
                            UUID().uuidString
                        )
                    try FileManager.default.moveItem(
                        at: quarantine,
                        to: destination
                    )
                    return destination
                },
                checkpoint: { checkpoint, _ in
                    if checkpoint == .afterItemTerminalBeforeNext,
                       terminalItems.incrementAndReturn() == 1 {
                        throw SimulatedCrash.checkpoint
                    }
                }
            )
        )
        await XCTAssertThrowsErrorAsync {
            try await crashing.execute(
                self.executionRequest(
                    cleanupID: prepared.journal.cleanupID
                )
            )
        }
        let resumed = try await ProjectStorageCleanupExecutor(
            operations: .init(
                trashItem: { quarantine in
                    trashCalls.increment()
                    let destination =
                        self.fakeTrash.appendingPathComponent(
                            UUID().uuidString
                        )
                    try FileManager.default.moveItem(
                        at: quarantine,
                        to: destination
                    )
                    return destination
                }
            )
        ).execute(
            executionRequest(cleanupID: prepared.journal.cleanupID)
        )
        XCTAssertEqual(
            resumed.summary.items.filter {
                $0.state == .movedToTrash
            }.count,
            2
        )
        XCTAssertEqual(trashCalls.value, 2)
    }

    func testRestoreCrashAndQuarantineSubstitutionNeverOverwriteOrTrashForeignBytes()
        async throws
    {
        try Data("payload".utf8).write(
            to: candidate.appendingPathComponent("payload.txt")
        )
        let prepared = try prepareCleanup(entries: [
            try storageEntry(for: candidate),
        ])
        enum TrashFailure: Error { case rejected }
        enum SimulatedCrash: Error { case checkpoint }
        let crashingRestore = ProjectStorageCleanupExecutor(
            operations: .init(
                trashItem: { _ in throw TrashFailure.rejected },
                checkpoint: { checkpoint, _ in
                    if checkpoint == .afterRestoreBeforeRecord {
                        throw SimulatedCrash.checkpoint
                    }
                }
            )
        )
        await XCTAssertThrowsErrorAsync {
            try await crashingRestore.execute(
                self.executionRequest(
                    cleanupID: prepared.journal.cleanupID
                )
            )
        }
        let restoreResumeTrashCalls = Counter()
        let restored = try await ProjectStorageCleanupExecutor(
            operations: .init(
                trashItem: { _ in
                    restoreResumeTrashCalls.increment()
                    throw TrashFailure.rejected
                }
            )
        ).execute(
            executionRequest(cleanupID: prepared.journal.cleanupID)
        )
        XCTAssertEqual(
            restored.summary.items.singleValue?.state,
            .restoredAfterTrashFailure
        )
        XCTAssertEqual(restoreResumeTrashCalls.value, 0)
        XCTAssertEqual(
            try Data(
                contentsOf:
                    candidate.appendingPathComponent("payload.txt")
            ),
            Data("payload".utf8)
        )

        try resetCandidate()
        try Data("original".utf8).write(
            to: candidate.appendingPathComponent("payload.txt")
        )
        let substitutedPreparation = try prepareCleanup(
            entries: [try storageEntry(for: candidate)],
            cleanupID: UUID()
        )
        let detachedCrash = ProjectStorageCleanupExecutor(
            operations: .init(
                checkpoint: { checkpoint, _ in
                    if checkpoint == .afterDetachBeforeRecord {
                        throw SimulatedCrash.checkpoint
                    }
                }
            )
        )
        await XCTAssertThrowsErrorAsync {
            try await detachedCrash.execute(
                self.executionRequest(
                    cleanupID: substitutedPreparation.journal.cleanupID
                )
            )
        }
        let quarantineName = try XCTUnwrap(pendingQuarantines().singleValue)
        let quarantineURL = project.appendingPathComponent(quarantineName)
        let displaced = root.appendingPathComponent(
            "real-quarantine",
            isDirectory: true
        )
        try FileManager.default.moveItem(at: quarantineURL, to: displaced)
        try FileManager.default.createDirectory(
            at: quarantineURL,
            withIntermediateDirectories: false
        )
        try Data("foreign".utf8).write(
            to: quarantineURL.appendingPathComponent("payload.txt")
        )
        let trashCalls = Counter()
        let substituted = try await ProjectStorageCleanupExecutor(
            operations: .init(
                trashItem: { _ in
                    trashCalls.increment()
                    throw TrashFailure.rejected
                }
            )
        ).execute(
            executionRequest(
                cleanupID: substitutedPreparation.journal.cleanupID
            )
        )
        XCTAssertEqual(trashCalls.value, 0)
        XCTAssertEqual(
            substituted.summary.items.singleValue?.state,
            .outcomeUnknown
        )
        XCTAssertTrue(
            substituted.summary.items.singleValue?.reason?
                .localizedCaseInsensitiveContains("identity") == true
                || substituted.summary.items.singleValue?.reason?
                    .localizedCaseInsensitiveContains("unknown") == true
        )
        XCTAssertEqual(
            try Data(
                contentsOf: quarantineURL.appendingPathComponent("payload.txt")
            ),
            Data("foreign".utf8)
        )
        XCTAssertEqual(
            try Data(
                contentsOf: displaced.appendingPathComponent("payload.txt")
            ),
            Data("original".utf8)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: candidate.path))
    }

    func testCancellationFinishesCurrentItemAndPublishesCompletePartialProvenance()
        async throws
    {
        try Data("first".utf8).write(
            to: candidate.appendingPathComponent("payload.txt")
        )
        let second = project.appendingPathComponent(
            ".second.lungfishgenotype.candidate-artifact-work",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: second,
            withIntermediateDirectories: false
        )
        try bindCompletedMarker(to: second)
        try Data("second".utf8).write(
            to: second.appendingPathComponent("payload.txt")
        )
        let prepared = try prepareCleanup(entries: [
            try storageEntry(for: candidate),
            try storageEntry(for: second),
        ])
        let shouldCancel = Flag()
        let trashCalls = Counter()
        let cancellationDurability = ExecutionDurabilityWitness()
        let executor = ProjectStorageCleanupExecutor(
            operations: .init(
                cancellationCheck: {
                    if shouldCancel.value {
                        throw CancellationError()
                    }
                },
                afterAuthorityVerified: { _ in shouldCancel.set() },
                beforeAppendDisposition:
                    cancellationDurability.begin,
                syncFile: cancellationDurability.syncFile,
                syncDirectory: cancellationDurability.syncDirectory,
                trashItem: { quarantine in
                    trashCalls.increment()
                    let destination =
                        self.fakeTrash.appendingPathComponent(
                            quarantine.lastPathComponent
                        )
                    try FileManager.default.moveItem(
                        at: quarantine,
                        to: destination
                    )
                    return destination
                },
                checkpoint: cancellationDurability.checkpoint
            )
        )

        await XCTAssertThrowsErrorAsync {
            try await executor.execute(
                self.executionRequest(
                    cleanupID: prepared.journal.cleanupID
                )
            )
        }

        let summary = try latestSummary(
            cleanupID: prepared.journal.cleanupID
        )
        XCTAssertEqual(summary.exitStatus, 130)
        XCTAssertEqual(
            summary.items.filter { $0.state == .movedToTrash }.count,
            1
        )
        XCTAssertEqual(
            summary.items.filter { $0.state == .skipped }.count,
            1
        )
        let moved = try XCTUnwrap(
            summary.items.first { $0.state == .movedToTrash }
        )
        let untouched = try XCTUnwrap(
            summary.items.first { $0.state == .skipped }
        )
        XCTAssertEqual(
            moved.sourceRelativePath,
            prepared.journal.items[0].sourceRelativePath
        )
        XCTAssertEqual(
            untouched.sourceRelativePath,
            prepared.journal.items[1].sourceRelativePath
        )
        XCTAssertTrue(
            untouched.reason?
                .localizedCaseInsensitiveContains("cancel") == true
        )
        XCTAssertNotNil(moved.trashDestinationPath)
        XCTAssertEqual(trashCalls.value, 1)
        XCTAssertTrue(try pendingQuarantines().isEmpty)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath:
                    project.appendingPathComponent(
                        moved.sourceRelativePath
                    ).path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath:
                    project.appendingPathComponent(
                        untouched.sourceRelativePath
                    ).path
            )
        )
        let provenance = try latestExecutionProvenance(
            cleanupID: prepared.journal.cleanupID
        )
        XCTAssertEqual(provenance.exitStatus, 130)
        XCTAssertEqual(provenance.argv, executionArgv)
        XCTAssertEqual(provenance.runtimeIdentity, runtimeIdentity)
        XCTAssertTrue(provenance.stderr?.contains("cancel") == true)
        XCTAssertTrue(
            provenance.files.contains {
                $0.path == prepared.journalURL.path
                    && $0.role == .input
                    && $0.checksumSHA256?.count == 64
            }
        )
        XCTAssertTrue(
            provenance.files.contains {
                $0.path == prepared.provenanceURL.path
                    && $0.role == .input
                    && $0.checksumSHA256?.count == 64
            }
        )
        XCTAssertNotNil(
            provenance.options.resolvedDefaults["cleanupDispositions"]
        )
        try assertCompleteExecutionProvenance(
            preparation: prepared,
            summary: summary
        )
        assertDurableCompletion(
            cancellationDurability,
            terminalStates: [.movedToTrash, .skipped]
        )
    }

    func testOrdinaryExecutionFailurePublishesDurableFailureProvenanceBeforeThrow()
        async throws
    {
        try Data("payload".utf8).write(
            to: candidate.appendingPathComponent("payload.txt")
        )
        let prepared = try prepareCleanup(entries: [
            try storageEntry(for: candidate),
        ])
        enum ScanFailure: Error { case unavailable }
        let failureDurability = ExecutionDurabilityWitness()
        let executor = ProjectStorageCleanupExecutor(
            operations: .init(
                beforeAppendDisposition: failureDurability.begin,
                syncFile: failureDurability.syncFile,
                syncDirectory: failureDurability.syncDirectory,
                authoritativeScan: { _ in
                    throw ScanFailure.unavailable
                },
                checkpoint: failureDurability.checkpoint
            )
        )

        await XCTAssertThrowsErrorAsync {
            try await executor.execute(
                self.executionRequest(
                    cleanupID: prepared.journal.cleanupID
                )
            )
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: candidate.path))
        XCTAssertTrue(try pendingQuarantines().isEmpty)
        let summary = try latestSummary(
            cleanupID: prepared.journal.cleanupID
        )
        XCTAssertEqual(summary.state, .failed)
        XCTAssertNotEqual(summary.exitStatus, 0)
        XCTAssertTrue(
            summary.stderr.localizedCaseInsensitiveContains("scan")
                || summary.stderr.localizedCaseInsensitiveContains(
                    "unavailable"
                )
        )
        XCTAssertEqual(
            summary.items.singleValue?.state,
            .failed
        )
        XCTAssertFalse(
            summary.items.singleValue?.reason?
                .trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty ?? true
        )
        try assertCompleteExecutionProvenance(
            preparation: prepared,
            summary: summary
        )
        assertDurableCompletion(
            failureDurability,
            terminalStates: [.failed]
        )
    }

    func testSameProjectExecutionsSerializeAndPoisonousSiblingsAreUntouched()
        async throws
    {
        try Data("first".utf8).write(
            to: candidate.appendingPathComponent("payload.txt")
        )
        let second = project.appendingPathComponent(
            ".second.lungfishgenotype.candidate-artifact-work",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: second,
            withIntermediateDirectories: false
        )
        try bindCompletedMarker(to: second)
        try Data("second".utf8).write(
            to: second.appendingPathComponent("payload.txt")
        )
        let firstPreparation = try prepareCleanup(entries: [
            try storageEntry(for: candidate),
        ])
        let secondPreparation = try prepareCleanup(
            entries: [try storageEntry(for: second)],
            cleanupID: UUID()
        )
        let aliasAnchor = project.appendingPathComponent(
            ".identity-alias-anchor",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: aliasAnchor,
            withIntermediateDirectories: false
        )
        let alternateProjectSpelling = URL(
            fileURLWithPath:
                aliasAnchor.appendingPathComponent("..").path,
            isDirectory: true
        )
        XCTAssertNotEqual(
            alternateProjectSpelling.path,
            project.path
        )
        XCTAssertEqual(
            try FileSystemObjectIdentity.noFollow(
                alternateProjectSpelling
            ),
            try FileSystemObjectIdentity.noFollow(project)
        )
        let outside = root.appendingPathComponent("outside.txt")
        try Data("outside".utf8).write(to: outside)
        let poison = project.appendingPathComponent(
            ".lungfish-trash-pending-poison"
        )
        try FileManager.default.createSymbolicLink(
            at: poison,
            withDestinationURL: outside
        )
        let poisonFile = project.appendingPathComponent(
            ".lungfish-trash-pending-regular"
        )
        try Data("poison-file".utf8).write(to: poisonFile)
        let poisonDirectory = project.appendingPathComponent(
            ".lungfish-trash-pending-directory",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: poisonDirectory,
            withIntermediateDirectories: false
        )
        try Data("poison-directory".utf8).write(
            to: poisonDirectory.appendingPathComponent("payload")
        )
        let poisonFIFO = project.appendingPathComponent(
            ".lungfish-trash-pending-fifo"
        )
        XCTAssertEqual(
            Darwin.mkfifo(poisonFIFO.path, S_IRUSR | S_IWUSR),
            0
        )
        let foreignHistory = operationDirectory(
            cleanupID: UUID()
        )
        try FileManager.default.createDirectory(
            at: foreignHistory,
            withIntermediateDirectories: true
        )
        try Data("foreign-history".utf8).write(
            to: foreignHistory.appendingPathComponent("payload")
        )
        let probe = ActiveProbe()
        let operations = ProjectStorageCleanupExecutor.Operations(
            afterAuthorityVerified: { _ in
                probe.enter()
                usleep(75_000)
                probe.leave()
            },
            trashItem: { quarantine in
                let destination =
                    self.fakeTrash.appendingPathComponent(
                        UUID().uuidString
                    )
                try FileManager.default.moveItem(
                    at: quarantine,
                    to: destination
                )
                return destination
            }
        )
        let firstRequest = executionRequest(
            cleanupID: firstPreparation.journal.cleanupID
        )
        let secondRequest = executionRequest(
            projectURL: alternateProjectSpelling,
            cleanupID: secondPreparation.journal.cleanupID
        )
        async let first = ProjectStorageCleanupExecutor(
            operations: operations
        ).execute(firstRequest)
        async let secondResult = ProjectStorageCleanupExecutor(
            operations: operations
        ).execute(secondRequest)
        _ = try await (first, secondResult)

        XCTAssertEqual(probe.maximum, 1)
        XCTAssertEqual(try Data(contentsOf: outside), Data("outside".utf8))
        var poisonInformation = stat()
        XCTAssertEqual(Darwin.lstat(poison.path, &poisonInformation), 0)
        XCTAssertEqual(poisonInformation.st_mode & S_IFMT, S_IFLNK)
        XCTAssertEqual(try Data(contentsOf: poisonFile), Data("poison-file".utf8))
        XCTAssertEqual(
            try Data(
                contentsOf:
                    poisonDirectory.appendingPathComponent("payload")
            ),
            Data("poison-directory".utf8)
        )
        XCTAssertEqual(Darwin.lstat(poisonFIFO.path, &poisonInformation), 0)
        XCTAssertEqual(poisonInformation.st_mode & S_IFMT, S_IFIFO)
        XCTAssertEqual(
            try Data(
                contentsOf: foreignHistory.appendingPathComponent("payload")
            ),
            Data("foreign-history".utf8)
        )
    }

    func testDifferentProjectIdentitiesExecuteConcurrently() async throws {
        try Data("first".utf8).write(
            to: candidate.appendingPathComponent("payload.txt")
        )
        let firstPreparation = try prepareCleanup(entries: [
            try storageEntry(for: candidate),
        ])
        let otherProject = root.appendingPathComponent(
            "Other.lungfish",
            isDirectory: true
        )
        let otherCandidate = otherProject.appendingPathComponent(
            ".other.lungfishgenotype.candidate-artifact-work",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: otherCandidate,
            withIntermediateDirectories: true
        )
        try bindCompletedMarker(
            to: otherCandidate,
            projectURL: otherProject
        )
        try Data("other".utf8).write(
            to: otherCandidate.appendingPathComponent("payload.txt")
        )
        let otherEntry = try storageEntry(
            for: otherCandidate,
            projectURL: otherProject
        )
        let otherPreparation = try prepareCleanup(
            projectURL: otherProject,
            entries: [otherEntry],
            cleanupID: UUID()
        )
        let barrier = TwoPartyBarrier()
        let operations = ProjectStorageCleanupExecutor.Operations(
            afterAuthorityVerified: { _ in
                XCTAssertTrue(barrier.arrive())
            },
            trashItem: { quarantine in
                let destination =
                    self.fakeTrash.appendingPathComponent(
                        UUID().uuidString
                    )
                try FileManager.default.moveItem(
                    at: quarantine,
                    to: destination
                )
                return destination
            }
        )
        let firstRequest = executionRequest(
            projectURL: project,
            cleanupID: firstPreparation.journal.cleanupID
        )
        let otherRequest = executionRequest(
            projectURL: otherProject,
            cleanupID: otherPreparation.journal.cleanupID
        )
        async let first = ProjectStorageCleanupExecutor(
            operations: operations
        ).execute(firstRequest)
        async let other = ProjectStorageCleanupExecutor(
            operations: operations
        ).execute(otherRequest)
        _ = try await (first, other)
        XCTAssertEqual(barrier.arrivals, 2)
    }

    func testIdentityGatePromptlyRemovesCancelledWaiterAndAdvancesNext()
        async throws
    {
        let gate = ProjectStorageCleanupIdentityGate()
        let identity = FileSystemObjectIdentity(device: 901, inode: 902)
        try await gate.acquire(identity)
        let cancelledEntered = Flag()
        let cancelled = Task {
            try await gate.acquire(identity)
            cancelledEntered.set()
            await gate.release(identity)
        }
        for _ in 0..<20 {
            await Task.yield()
        }

        cancelled.cancel()
        let cancelledCompleted = Flag()
        Task {
            _ = await cancelled.result
            cancelledCompleted.set()
        }
        for _ in 0..<200 where !cancelledCompleted.value {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(
            cancelledCompleted.value,
            "A cancelled identity-gate waiter must finish before the holder releases."
        )

        let followingEntered = Flag()
        let following = Task {
            try await gate.acquire(identity)
            followingEntered.set()
            await gate.release(identity)
        }
        for _ in 0..<20 {
            await Task.yield()
        }
        XCTAssertFalse(followingEntered.value)

        await gate.release(identity)
        try await following.value
        let cancelledResult = await cancelled.result

        XCTAssertFalse(cancelledEntered.value)
        guard case .failure(let error) = cancelledResult else {
            return XCTFail("The cancelled waiter unexpectedly acquired the gate.")
        }
        XCTAssertTrue(error is CancellationError)
        XCTAssertTrue(followingEntered.value)
    }

    private var executionArgv: [String] {
        [
            "lungfish-project-storage",
            "execute",
            project.path,
        ]
    }

    private var runtimeIdentity: ProvenanceRuntimeIdentity {
        .init(
            appVersion: "7.2.0",
            executablePath: "/Applications/Lungfish.app/Lungfish",
            processIdentifier: 99,
            operatingSystemVersion: "macOS",
            architecture: "arm64",
            gitRevision: "abc123",
            user: "analyst",
            condaEnvironment: "none",
            condaPrefix: "/none",
            pluginPack: "builtin",
            containerImage: nil,
            containerDigest: nil
        )
    }

    private func executionRequest(
        cleanupID: UUID
    ) -> ProjectStorageCleanupExecutionRequest {
        executionRequest(projectURL: project, cleanupID: cleanupID)
    }

    private func executionRequest(
        projectURL: URL,
        cleanupID: UUID
    ) -> ProjectStorageCleanupExecutionRequest {
        let argv = [
            "lungfish-project-storage",
            "execute",
            projectURL.path,
        ]
        return .init(
            projectURL: projectURL,
            cleanupID: cleanupID,
            argv: argv,
            durableReplayArgv: argv,
            options: .init(
                explicit: ["confirmed": .boolean(true)],
                defaults: ["permanentDeleteFallback": .boolean(false)],
                resolvedDefaults: [
                    "permanentDeleteFallback": .boolean(false),
                ]
            ),
            runtimeIdentity: runtimeIdentity,
            startedAt: Date(timeIntervalSince1970: 200)
        )
    }

    private func prepareCleanup(
        entries: [ProjectStorageEntry],
        cleanupID: UUID = UUID()
    ) throws -> ProjectStorageCleanupPreparation {
        try prepareCleanup(
            projectURL: project,
            entries: entries,
            cleanupID: cleanupID
        )
    }

    private func prepareCleanup(
        projectURL: URL,
        entries: [ProjectStorageEntry],
        cleanupID: UUID = UUID()
    ) throws -> ProjectStorageCleanupPreparation {
        try ProjectStorageCleanupReceiptWriter(
            operations: .init(
                cancellationCheck: {},
                now: { Date(timeIntervalSince1970: 104) }
            )
        ).prepareConfirmedCleanup(
            .init(
                cleanupID: cleanupID,
                projectURL: projectURL,
                projectIdentity:
                    try FileSystemObjectIdentity.noFollow(projectURL),
                selectedEntries: entries,
                workflowName: "Project Storage Cleanup",
                workflowVersion: "7.2.0",
                toolName: "lungfish-project-storage",
                toolVersion: "7.2.0",
                argv: [
                    "lungfish-project-storage",
                    "prepare",
                    projectURL.path,
                ] + entries.map(\.relativePath),
                durableReplayArgv: [
                    "lungfish-project-storage",
                    "prepare",
                    projectURL.path,
                ] + entries.map(\.relativePath),
                options: .init(
                    explicit: ["confirmed": .boolean(true)],
                    defaults: [
                        "permanentDeleteFallback": .boolean(false),
                    ],
                    resolvedDefaults: [
                        "permanentDeleteFallback": .boolean(false),
                    ]
                ),
                runtimeIdentity: runtimeIdentity,
                startedAt: Date(timeIntervalSince1970: 100)
            )
        )
    }

    private func bindCompletedMarker(
        to directory: URL,
        projectURL: URL? = nil
    ) throws {
        let markerProject = projectURL ?? project!
        try OwnedWorkDirectoryMarkerStore.bindExistingDirectory(
            directory,
            request: .init(
                projectURL: markerProject,
                parentDirectoryURL: markerProject,
                prefix: "unused-",
                runID: UUID(),
                processIdentity: .init(
                    processIdentifier: 1,
                    processStartTime: 1,
                    bootSessionID: UUID().uuidString
                ),
                state: .completed,
                lockRelativePath: nil,
                keepIntermediates: false,
                toolName: "cleanup-executor-test",
                toolVersion: "1"
            )
        )
    }

    private func storageEntry(for url: URL) throws -> ProjectStorageEntry {
        try storageEntry(for: url, projectURL: project)
    }

    private func storageEntry(
        for url: URL,
        projectURL: URL
    ) throws -> ProjectStorageEntry {
        let relativePath = String(
            url.path.dropFirst(projectURL.path.count + 1)
        )
        return try XCTUnwrap(
            ProjectStorageScanner().scan(projectURL: projectURL)
                .entries.first { $0.relativePath == relativePath }
        )
    }

    private func pendingQuarantines() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: project.path)
            .filter {
                $0.hasPrefix(".lungfish-trash-pending-")
            }
    }

    private func resetCandidate() throws {
        var information = stat()
        if Darwin.lstat(candidate.path, &information) == 0 {
            try FileManager.default.removeItem(at: candidate)
        }
        try FileManager.default.createDirectory(
            at: candidate,
            withIntermediateDirectories: false
        )
        try bindCompletedMarker(to: candidate)
    }

    private func rewriteMarkerKeepingIntermediates(
        at directory: URL
    ) throws {
        let current = try OwnedWorkDirectoryMarkerStore.load(
            from: directory,
            expectedProjectURL: project
        )
        let replacement = OwnedWorkDirectoryMarker(
            projectIdentity: current.projectIdentity,
            directoryIdentity: current.directoryIdentity,
            runID: current.runID,
            processIdentifier: current.processIdentifier,
            processStartTime: current.processStartTime,
            bootSessionID: current.bootSessionID,
            state: current.state,
            lockRelativePath: current.lockRelativePath,
            keepIntermediates: true,
            toolName: current.toolName,
            toolVersion: current.toolVersion
        )
        let markerURL = directory.appendingPathComponent(
            OwnedWorkDirectoryMarker.fileName
        )
        try ProvenanceJSON.encoder.encode(replacement).write(
            to: markerURL,
            options: .atomic
        )
    }

    private func rewriteMarker(
        at directory: URL,
        lockRelativePath: String?
    ) throws {
        let current = try OwnedWorkDirectoryMarkerStore.load(
            from: directory,
            expectedProjectURL: project
        )
        let replacement = OwnedWorkDirectoryMarker(
            projectIdentity: current.projectIdentity,
            directoryIdentity: current.directoryIdentity,
            runID: current.runID,
            processIdentifier: current.processIdentifier,
            processStartTime: current.processStartTime,
            bootSessionID: current.bootSessionID,
            state: current.state,
            lockRelativePath: lockRelativePath,
            keepIntermediates: current.keepIntermediates,
            toolName: current.toolName,
            toolVersion: current.toolVersion
        )
        try ProvenanceJSON.encoder.encode(replacement).write(
            to: directory.appendingPathComponent(
                OwnedWorkDirectoryMarker.fileName
            ),
            options: .atomic
        )
    }

    private func replacingPreparationOutput(
        _ original: ProvenanceEnvelope,
        with replacement: ProvenanceFileDescriptor
    ) -> ProvenanceEnvelope {
        ProvenanceEnvelope(
            schemaVersion: original.schemaVersion,
            id: original.id,
            createdAt: original.createdAt,
            workflowName: original.workflowName,
            workflowVersion: original.workflowVersion,
            toolName: original.toolName,
            toolVersion: original.toolVersion,
            githubReleaseVersion: original.githubReleaseVersion,
            tool: original.tool,
            argv: original.argv,
            durableReplayArgv: original.durableReplayArgv,
            reproducibleCommand: original.reproducibleCommand,
            options: original.options,
            runtimeIdentity: original.runtimeIdentity,
            files: original.files,
            output: replacement,
            outputs: [replacement],
            steps: original.steps,
            wallTimeSeconds: original.wallTimeSeconds,
            exitStatus: original.exitStatus,
            stderr: original.stderr,
            signatures: original.signatures,
            legacyWorkflowRun: original.legacyRun
        )
    }

    private func replacingPreparationEnvelopeID(
        _ original: ProvenanceEnvelope,
        with id: UUID
    ) -> ProvenanceEnvelope {
        ProvenanceEnvelope(
            schemaVersion: original.schemaVersion,
            id: id,
            createdAt: original.createdAt,
            workflowName: original.workflowName,
            workflowVersion: original.workflowVersion,
            toolName: original.toolName,
            toolVersion: original.toolVersion,
            githubReleaseVersion: original.githubReleaseVersion,
            tool: original.tool,
            argv: original.argv,
            durableReplayArgv: original.durableReplayArgv,
            reproducibleCommand: original.reproducibleCommand,
            options: original.options,
            runtimeIdentity: original.runtimeIdentity,
            files: original.files,
            output: original.output,
            outputs: original.outputs,
            steps: original.steps,
            wallTimeSeconds: original.wallTimeSeconds,
            exitStatus: original.exitStatus,
            stderr: original.stderr,
            signatures: original.signatures,
            legacyWorkflowRun: original.legacyRun
        )
    }

    private func assertDurableCompletion(
        _ witness: ExecutionDurabilityWitness,
        terminalStates: [ProjectStorageCleanupDispositionRecord.State],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for state in terminalStates {
            XCTAssertTrue(
                witness.durableStates.contains(state.rawValue),
                "\(state.rawValue) was not durably file- and parent-fsynced",
                file: file,
                line: line
            )
            XCTAssertTrue(
                witness.properlySyncedDispositionStates
                    .contains(state.rawValue),
                "\(state.rawValue) was not independently file+parent fsynced",
                file: file,
                line: line
            )
        }
        XCTAssertEqual(
            witness.summaryDurableCount,
            1,
            "summary must be durably published exactly once",
            file: file,
            line: line
        )
        XCTAssertTrue(
            witness.summaryPublicationWasSynced,
            "summary durable callback must follow its file and parent fsync",
            file: file,
            line: line
        )
        XCTAssertEqual(
            witness.provenanceDurableCount,
            1,
            "provenance must be durably published exactly once",
            file: file,
            line: line
        )
        XCTAssertTrue(
            witness.provenancePublicationWasSynced,
            "provenance durable callback must follow file and parent fsync",
            file: file,
            line: line
        )
    }

    private func assertCompleteExecutionProvenance(
        preparation: ProjectStorageCleanupPreparation,
        summary: ProjectStorageCleanupExecutionSummary,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let cleanupID = preparation.journal.cleanupID
        XCTAssertEqual(
            try Data(contentsOf: preparation.journalURL),
            try ProvenanceJSON.encoder.encode(preparation.journal),
            "Task 5 journal bytes are immutable",
            file: file,
            line: line
        )
        XCTAssertEqual(
            try Data(contentsOf: preparation.provenanceURL),
            try ProvenanceJSON.encoder.encode(preparation.provenance),
            "Task 5 provenance bytes are immutable",
            file: file,
            line: line
        )
        let provenance = try latestExecutionProvenance(
            cleanupID: cleanupID
        )
        XCTAssertEqual(
            provenance.workflowName,
            "Project Storage Cleanup Execution",
            file: file,
            line: line
        )
        XCTAssertEqual(
            provenance.workflowVersion,
            preparation.journal.workflowVersion,
            file: file,
            line: line
        )
        XCTAssertEqual(
            provenance.toolName,
            preparation.journal.toolName,
            file: file,
            line: line
        )
        XCTAssertEqual(
            provenance.toolVersion,
            preparation.journal.toolVersion,
            file: file,
            line: line
        )
        XCTAssertEqual(
            provenance.argv,
            executionArgv,
            file: file,
            line: line
        )
        XCTAssertEqual(
            provenance.durableReplayArgv,
            executionArgv,
            file: file,
            line: line
        )
        XCTAssertEqual(
            provenance.reproducibleCommand,
            executionArgv.map(shellEscape).joined(separator: " "),
            file: file,
            line: line
        )
        XCTAssertEqual(
            provenance.runtimeIdentity,
            runtimeIdentity,
            file: file,
            line: line
        )
        XCTAssertEqual(
            provenance.exitStatus,
            summary.exitStatus,
            file: file,
            line: line
        )
        XCTAssertEqual(
            provenance.stderr,
            summary.stderr,
            file: file,
            line: line
        )
        XCTAssertNotNil(
            provenance.wallTimeSeconds,
            file: file,
            line: line
        )
        XCTAssertGreaterThanOrEqual(
            provenance.wallTimeSeconds ?? -1,
            0,
            file: file,
            line: line
        )
        XCTAssertEqual(
            provenance.options.explicit["confirmed"],
            .boolean(true),
            file: file,
            line: line
        )
        XCTAssertEqual(
            provenance.options.defaults["permanentDeleteFallback"],
            .boolean(false),
            file: file,
            line: line
        )
        XCTAssertEqual(
            provenance.options.resolvedDefaults[
                "permanentDeleteFallback"
            ],
            .boolean(false),
            file: file,
            line: line
        )
        XCTAssertEqual(
            provenance.options.resolvedDefaults["cleanupID"],
            .string(cleanupID.uuidString.lowercased()),
            file: file,
            line: line
        )
        XCTAssertEqual(
            provenance.options.resolvedDefaults["projectRoot"],
            .string(project.path),
            file: file,
            line: line
        )
        XCTAssertEqual(
            provenance.options.resolvedDefaults[
                "executionStateDurability"
            ],
            .string("append-only-jsonl-fsync-file-and-directory"),
            file: file,
            line: line
        )

        let journalData = try Data(contentsOf: preparation.journalURL)
        let preparationProvenanceData = try Data(
            contentsOf: preparation.provenanceURL
        )
        for expected in [
            (
                preparation.journalURL,
                sha256Hex(journalData),
                UInt64(journalData.count)
            ),
            (
                preparation.provenanceURL,
                sha256Hex(preparationProvenanceData),
                UInt64(preparationProvenanceData.count)
            ),
        ] {
            let descriptor = provenance.files.first {
                $0.path == expected.0.path && $0.role == .input
            }
            XCTAssertEqual(
                descriptor?.checksumSHA256,
                expected.1,
                file: file,
                line: line
            )
            XCTAssertEqual(
                descriptor?.fileSize,
                expected.2,
                file: file,
                line: line
            )
        }

        let operation = operationDirectory(cleanupID: cleanupID)
        let stateURL = operation.appendingPathComponent(
            ProjectStorageCleanupExecutor.stateFileName
        )
        let summaryURL = try latestExecutionArtifactURL(
            cleanupID: cleanupID,
            prefix: "execution-summary-"
        )
        for outputURL in [stateURL, summaryURL] {
            let data = try Data(contentsOf: outputURL)
            let descriptor = provenance.outputs.first {
                $0.path == outputURL.path && $0.role == .output
            }
            XCTAssertEqual(
                descriptor?.checksumSHA256,
                sha256Hex(data),
                file: file,
                line: line
            )
            XCTAssertEqual(
                descriptor?.fileSize,
                UInt64(data.count),
                file: file,
                line: line
            )
        }

        let dispositions = try XCTUnwrap(
            provenance.options.resolvedDefaults["cleanupDispositions"]?
                .arrayValue,
            file: file,
            line: line
        )
        XCTAssertEqual(
            dispositions.count,
            summary.items.count,
            file: file,
            line: line
        )
        for summaryItem in summary.items {
            let preparedItem = try XCTUnwrap(
                preparation.journal.items.first {
                    $0.id == summaryItem.itemID
                },
                file: file,
                line: line
            )
            let disposition = try XCTUnwrap(
                dispositions.compactMap(\.dictionaryValue).first {
                    $0["itemID"]?.stringValue
                        == summaryItem.itemID.uuidString.lowercased()
                },
                file: file,
                line: line
            )
            XCTAssertEqual(
                disposition["sourceRelativePath"]?.stringValue,
                preparedItem.sourceRelativePath,
                file: file,
                line: line
            )
            XCTAssertEqual(
                disposition["sourceDevice"]?.integerValue,
                Int(preparedItem.sourceIdentity.device),
                file: file,
                line: line
            )
            XCTAssertEqual(
                disposition["sourceInode"]?.integerValue,
                Int(preparedItem.sourceIdentity.inode),
                file: file,
                line: line
            )
            XCTAssertEqual(
                disposition["aggregateTreeDigest"]?.stringValue,
                preparedItem.aggregateTreeDigest,
                file: file,
                line: line
            )
            XCTAssertEqual(
                disposition["inventory"],
                .array(
                    try preparedItem.inventory.map {
                        try $0.parameterValue()
                    }
                ),
                file: file,
                line: line
            )
            XCTAssertEqual(
                disposition["state"]?.stringValue,
                summaryItem.state.rawValue,
                file: file,
                line: line
            )
            XCTAssertEqual(
                disposition["trashDestinationPath"]?.stringValue,
                summaryItem.trashDestinationPath,
                file: file,
                line: line
            )
            XCTAssertEqual(
                disposition["quarantineRelativePath"]?.stringValue,
                summaryItem.quarantineRelativePath,
                file: file,
                line: line
            )
            if summaryItem.state != .movedToTrash {
                XCTAssertFalse(
                    summaryItem.reason?
                        .trimmingCharacters(
                            in: .whitespacesAndNewlines
                        ).isEmpty ?? true,
                    "non-Trash terminal outcomes require a reason",
                    file: file,
                    line: line
                )
                XCTAssertEqual(
                    disposition["reason"]?.stringValue,
                    summaryItem.reason,
                    file: file,
                    line: line
                )
            } else {
                XCTAssertFalse(
                    summaryItem.trashDestinationPath?
                        .trimmingCharacters(
                            in: .whitespacesAndNewlines
                        ).isEmpty ?? true,
                    "Trash success requires its durable destination",
                    file: file,
                    line: line
                )
                let destination = URL(
                    fileURLWithPath:
                        try XCTUnwrap(
                            summaryItem.trashDestinationPath,
                            file: file,
                            line: line
                        ),
                    isDirectory: true
                )
                var destinationInformation = stat()
                XCTAssertEqual(
                    Darwin.lstat(
                        destination.path,
                        &destinationInformation
                    ),
                    0,
                    "the Trash adapter destination must remain present",
                    file: file,
                    line: line
                )
                XCTAssertEqual(
                    destinationInformation.st_mode & S_IFMT,
                    S_IFDIR,
                    "the executor must not replace/delete its Trash result",
                    file: file,
                    line: line
                )
                var payloadInformation = stat()
                XCTAssertEqual(
                    Darwin.lstat(
                        destination.appendingPathComponent(
                            "payload.txt"
                        ).path,
                        &payloadInformation
                    ),
                    0,
                    "the trashed payload must remain recoverable",
                    file: file,
                    line: line
                )
                XCTAssertEqual(
                    payloadInformation.st_mode & S_IFMT,
                    S_IFREG,
                    file: file,
                    line: line
                )
            }
        }
        XCTAssertEqual(
            provenance.steps.singleValue?.exitStatus,
            summary.exitStatus,
            file: file,
            line: line
        )
        XCTAssertEqual(
            provenance.steps.singleValue?.stderr,
            summary.stderr,
            file: file,
            line: line
        )
    }

    private func latestExecutionArtifactURL(
        cleanupID: UUID,
        prefix: String
    ) throws -> URL {
        let directory = operationDirectory(cleanupID: cleanupID)
        let name = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                atPath: directory.path
            ).filter {
                $0.hasPrefix(prefix) && $0.hasSuffix(".json")
            }.sorted().last
        )
        return directory.appendingPathComponent(name)
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func latestSummary(
        cleanupID: UUID
    ) throws -> ProjectStorageCleanupExecutionSummary {
        let directory = operationDirectory(cleanupID: cleanupID)
        let name = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                atPath: directory.path
            ).filter {
                $0.hasPrefix("execution-summary-")
                    && $0.hasSuffix(".json")
            }.sorted().last
        )
        return try ProvenanceJSON.decoder.decode(
            ProjectStorageCleanupExecutionSummary.self,
            from: Data(
                contentsOf: directory.appendingPathComponent(name)
            )
        )
    }

    private func dispositionRecords(
        cleanupID: UUID
    ) throws -> [ProjectStorageCleanupDispositionRecord] {
        let data = try Data(
            contentsOf:
                operationDirectory(cleanupID: cleanupID)
                    .appendingPathComponent(
                        ProjectStorageCleanupExecutor.stateFileName
                    )
        )
        return try data.split(separator: 0x0a).map {
            try ProvenanceJSON.decoder.decode(
                ProjectStorageCleanupDispositionRecord.self,
                from: Data($0)
            )
        }
    }

    private func latestExecutionProvenance(
        cleanupID: UUID
    ) throws -> ProvenanceEnvelope {
        let directory = operationDirectory(cleanupID: cleanupID)
        let name = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                atPath: directory.path
            ).filter {
                $0.hasPrefix("execution-provenance-")
                    && $0.hasSuffix(".json")
            }.sorted().last
        )
        return try ProvenanceEnvelopeReader.decodeCanonical(
            Data(contentsOf: directory.appendingPathComponent(name))
        )
    }

    private func assertExecutionRejectedWithoutSourceMutation(
        cleanupID: UUID,
        expectedPayload: String
    ) async {
        await XCTAssertThrowsErrorAsync {
            try await ProjectStorageCleanupExecutor().execute(
                self.executionRequest(cleanupID: cleanupID)
            )
        }
        XCTAssertEqual(
            try? Data(
                contentsOf:
                    candidate.appendingPathComponent("payload.txt")
            ),
            Data(expectedPayload.utf8)
        )
        XCTAssertEqual(try? pendingQuarantines(), [])
    }

    private func operationDirectory(cleanupID: UUID) -> URL {
        project
            .appendingPathComponent(
                ProjectOperationHistoryWriter.historyDirectoryName
            )
            .appendingPathComponent(
                ProjectStorageCleanupReceiptWriter.collectionDirectoryName
            )
            .appendingPathComponent(
                cleanupID.uuidString.lowercased()
            )
    }
}

private final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ event: String) {
        lock.lock()
        storage.append(event)
        lock.unlock()
    }

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    var last: String? {
        lock.lock()
        defer { lock.unlock() }
        return storage.last
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    func increment() {
        _ = incrementAndReturn()
    }

    func incrementAndReturn() -> Int {
        lock.lock()
        storage += 1
        let value = storage
        lock.unlock()
        return value
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private final class StringRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ value: String) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    var last: String? {
        lock.lock()
        defer { lock.unlock() }
        return storage.last
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    func set() {
        lock.lock()
        storage = true
        lock.unlock()
    }

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private final class ActiveProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private var peak = 0

    func enter() {
        lock.lock()
        active += 1
        peak = max(peak, active)
        lock.unlock()
    }

    func leave() {
        lock.lock()
        active -= 1
        lock.unlock()
    }

    var maximum: Int {
        lock.lock()
        defer { lock.unlock() }
        return peak
    }
}

private final class FileGrowthRecorder: @unchecked Sendable {
    struct Snapshot: Sendable {
        let identity: FileSystemObjectIdentity
        let size: Int64
    }

    private let lock = NSLock()
    private var storage: [Snapshot] = []

    func record(_ url: URL) throws {
        var information = stat()
        guard Darwin.lstat(url.path, &information) == 0,
              information.st_mode & S_IFMT == S_IFREG else {
            throw CocoaError(.fileReadUnknown)
        }
        let snapshot = Snapshot(
            identity: FileSystemObjectIdentity(from: information),
            size: information.st_size
        )
        lock.lock()
        storage.append(snapshot)
        lock.unlock()
    }

    var snapshots: [Snapshot] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private final class ExecutionDurabilityWitness: @unchecked Sendable {
    private let lock = NSLock()
    private var currentState: String?
    private var currentStateFileSyncBaseline = 0
    private var currentStateDirectorySyncBaseline = 0
    private var durableStateStorage: [String] = []
    private var properlySyncedDispositionStorage: [String] = []
    private var fileSyncStorage: [String] = []
    private var directorySyncStorage: [String] = []
    private var summaryStorage = 0
    private var provenanceStorage = 0
    private var priorPublicationFileSyncCount = 0
    private var priorPublicationDirectorySyncCount = 0
    private var summarySynced = false
    private var provenanceSynced = false

    func begin(_ record: ProjectStorageCleanupDispositionRecord) {
        lock.lock()
        currentState = record.state.rawValue
        currentStateFileSyncBaseline = fileSyncStorage.count
        currentStateDirectorySyncBaseline =
            directorySyncStorage.count
        lock.unlock()
    }

    func checkpoint(
        _ checkpoint: ProjectStorageCleanupExecutor.Checkpoint,
        _ itemID: UUID
    ) throws {
        _ = itemID
        lock.lock()
        switch checkpoint {
        case .afterDispositionDurable:
            if let currentState {
                durableStateStorage.append(currentState)
                if fileSyncStorage.count
                    > currentStateFileSyncBaseline,
                   directorySyncStorage.count
                    > currentStateDirectorySyncBaseline {
                    properlySyncedDispositionStorage.append(
                        currentState
                    )
                }
            }
            priorPublicationFileSyncCount = fileSyncStorage.count
            priorPublicationDirectorySyncCount =
                directorySyncStorage.count
        case .afterSummaryDurable:
            summarySynced =
                fileSyncStorage.count > priorPublicationFileSyncCount
                && directorySyncStorage.count
                    > priorPublicationDirectorySyncCount
            priorPublicationFileSyncCount = fileSyncStorage.count
            priorPublicationDirectorySyncCount =
                directorySyncStorage.count
            summaryStorage += 1
        case .afterProvenanceDurable:
            provenanceSynced =
                fileSyncStorage.count > priorPublicationFileSyncCount
                && directorySyncStorage.count
                    > priorPublicationDirectorySyncCount
            provenanceStorage += 1
        default:
            break
        }
        lock.unlock()
    }

    func syncFile(_ descriptor: Int32) -> Int32 {
        lock.lock()
        if let currentState {
            fileSyncStorage.append(currentState)
        }
        lock.unlock()
        return Darwin.fsync(descriptor)
    }

    func syncDirectory(_ descriptor: Int32) -> Int32 {
        lock.lock()
        if let currentState {
            directorySyncStorage.append(currentState)
        }
        lock.unlock()
        return Darwin.fsync(descriptor)
    }

    var durableStates: [String] {
        lock.lock()
        defer { lock.unlock() }
        return durableStateStorage
    }

    var summaryDurableCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return summaryStorage
    }

    var properlySyncedDispositionStates: [String] {
        lock.lock()
        defer { lock.unlock() }
        return properlySyncedDispositionStorage
    }

    var provenanceDurableCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return provenanceStorage
    }

    var summaryPublicationWasSynced: Bool {
        lock.lock()
        defer { lock.unlock() }
        return summarySynced
    }

    var provenancePublicationWasSynced: Bool {
        lock.lock()
        defer { lock.unlock() }
        return provenanceSynced
    }
}

private final class TwoPartyBarrier: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var count = 0

    func arrive() -> Bool {
        lock.lock()
        count += 1
        let isSecond = count == 2
        lock.unlock()
        if isSecond {
            semaphore.signal()
            semaphore.signal()
        }
        return semaphore.wait(timeout: .now() + 2) == .success
    }

    var arrivals: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

private extension Array {
    var singleValue: Element? {
        count == 1 ? first : nil
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail(
            message.isEmpty ? "Expected error" : "Expected error: \(message)",
            file: file,
            line: line
        )
    } catch {
        // Expected.
    }
}
