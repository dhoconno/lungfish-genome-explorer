import Darwin
import Foundation
import LungfishIO
import XCTest
@testable import LungfishWorkflow

final class ProjectStorageScannerTests: XCTestCase {
    private var root: URL!
    private var project: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ProjectStorageScannerTests-\(UUID().uuidString)",
            isDirectory: true
        )
        project = root.appendingPathComponent(
            "Storage.lungfish",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: project,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testScanRecognizesOnlyExactOwnedPatternsAndSkipsLiveBundlesAndHistory()
        throws
    {
        let runID = UUID()
        let staging = project.appendingPathComponent(
            ".analysis.lungfishgenotype.run-staging-"
                + runID.uuidString,
            isDirectory: true
        )
        try makeOwnedDirectory(staging, runID: runID, state: .completed)
        let candidate = project.appendingPathComponent(
            ".analysis.lungfishgenotype.candidate-artifact-work",
            isDirectory: true
        )
        try makeOwnedDirectory(
            candidate,
            runID: UUID(),
            state: .completed
        )
        let almost = project.appendingPathComponent(
            "analysis.lungfishgenotype.candidate-artifact-work",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: almost,
            withIntermediateDirectories: false
        )
        let malformedStaging = project.appendingPathComponent(
            ".analysis.lungfishgenotype.run-staging-not-a-uuid",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: malformedStaging,
            withIntermediateDirectories: false
        )
        let cleanupPending = project.appendingPathComponent(
            ".lungfish-workbook-cleanup-pending-unsafe",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: cleanupPending,
            withIntermediateDirectories: false
        )
        let impossibleArchive = project.appendingPathComponent(
            ".lungfish-workbook-generation-archive-"
                + "2026-99-27T120000Z-update-current-workbook-deadbeef",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: impossibleArchive,
            withIntermediateDirectories: false
        )
        let liveBundle = project.appendingPathComponent(
            "live.lungfishgenotype",
            isDirectory: true
        )
        let hiddenInsideBundle = liveBundle.appendingPathComponent(
            ".inside.lungfishgenotype.candidate-artifact-work",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: hiddenInsideBundle,
            withIntermediateDirectories: true
        )
        let historyCandidate = project
            .appendingPathComponent(
                ProjectOperationHistoryWriter.historyDirectoryName,
                isDirectory: true
            )
            .appendingPathComponent(
                ".history.lungfishgenotype.candidate-artifact-work",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: historyCandidate,
            withIntermediateDirectories: true
        )

        let result = try ProjectStorageScanner().scan(projectURL: project)

        XCTAssertEqual(
            Set(result.entries.map(\.relativePath)),
            Set([
                staging.lastPathComponent,
                candidate.lastPathComponent,
                malformedStaging.lastPathComponent,
                cleanupPending.lastPathComponent,
                impossibleArchive.lastPathComponent,
            ])
        )
        let classifications = Dictionary(
            uniqueKeysWithValues: result.entries.map {
                ($0.relativePath, $0.classification)
            }
        )
        XCTAssertTrue(
            try XCTUnwrap(classifications[staging.lastPathComponent])
                .isRemovable
        )
        XCTAssertTrue(
            try XCTUnwrap(classifications[candidate.lastPathComponent])
                .isRemovable
        )
        for path in [
            malformedStaging.lastPathComponent,
            cleanupPending.lastPathComponent,
            impossibleArchive.lastPathComponent,
        ] {
            let classification = try XCTUnwrap(classifications[path])
            XCTAssertFalse(classification.isRemovable)
            XCTAssertFalse(classification.reason.isEmpty)
        }
        XCTAssertFalse(
            result.entries.contains {
                $0.relativePath.contains("lungfish-operation-history")
                    || $0.relativePath.contains("live.lungfishgenotype/")
            }
        )
    }

    func testScanTreatsIndividualTempChildrenAsEntriesAndUnknownAsNotRemovable()
        throws
    {
        let tempRoot = project.appendingPathComponent(".tmp", isDirectory: true)
        try FileManager.default.createDirectory(
            at: tempRoot,
            withIntermediateDirectories: true
        )
        let completed = tempRoot.appendingPathComponent(
            "completed-\(UUID().uuidString)",
            isDirectory: true
        )
        try makeOwnedDirectory(
            completed,
            runID: UUID(),
            state: .completed
        )
        let unknown = tempRoot.appendingPathComponent(
            "legacy-unknown",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: unknown,
            withIntermediateDirectories: false
        )

        let result = try ProjectStorageScanner().scan(projectURL: project)
        let byPath = Dictionary(
            uniqueKeysWithValues: result.entries.map {
                ($0.relativePath, $0)
            }
        )
        XCTAssertTrue(
            try XCTUnwrap(byPath[".tmp/\(completed.lastPathComponent)"])
                .classification.isRemovable
        )
        let unsafe = try XCTUnwrap(
            byPath[".tmp/\(unknown.lastPathComponent)"]
        )
        XCTAssertFalse(unsafe.classification.isRemovable)
        XCTAssertTrue(unsafe.classification.reason.contains("marker"))
    }

    func testActiveOrphanRequiresDeadProcessUnlockedIdentityKeepFalseAndNoLiveHistory()
        throws
    {
        let deadRun = UUID()
        let dead = project.appendingPathComponent(
            ".dead.lungfishgenotype.run-staging-\(deadRun.uuidString)",
            isDirectory: true
        )
        try makeOwnedDirectory(
            dead,
            runID: deadRun,
            state: .active,
            lockRelativePath: "locks/dead.lock",
            processIdentity: .init(
                processIdentifier: 41,
                processStartTime: 100,
                bootSessionID: UUID().uuidString
            )
        )
        let retainedRun = UUID()
        let retained = project.appendingPathComponent(
            ".retained.lungfishgenotype.run-staging-"
                + retainedRun.uuidString,
            isDirectory: true
        )
        try makeOwnedDirectory(
            retained,
            runID: retainedRun,
            state: .active,
            keepIntermediates: true,
            processIdentity: .init(
                processIdentifier: 42,
                processStartTime: 200,
                bootSessionID: UUID().uuidString
            )
        )
        let heldRun = UUID()
        let held = project.appendingPathComponent(
            ".held.lungfishgenotype.run-staging-\(heldRun.uuidString)",
            isDirectory: true
        )
        try makeOwnedDirectory(
            held,
            runID: heldRun,
            state: .active,
            lockRelativePath: "locks/held.lock",
            processIdentity: .init(
                processIdentifier: 43,
                processStartTime: 300,
                bootSessionID: UUID().uuidString
            )
        )
        let historyRun = UUID()
        let history = project.appendingPathComponent(
            ".history.lungfishgenotype.run-staging-"
                + historyRun.uuidString,
            isDirectory: true
        )
        try makeOwnedDirectory(
            history,
            runID: historyRun,
            state: .active,
            lockRelativePath: "locks/history.lock",
            processIdentity: .init(
                processIdentifier: 44,
                processStartTime: 400,
                bootSessionID: UUID().uuidString
            )
        )
        _ = try ProjectOperationHistoryWriter(projectURL: project)
            .createOperation(
                operationID: historyRun,
                payloads: ["live-operation.json": Data(#"{"state":"active"}"#.utf8)]
            )

        let scanner = ProjectStorageScanner(
            processInspector: { _ in nil },
            lockProbe: { url in
                url.lastPathComponent == "held.lock" ? .held : .unlocked
            }
        )
        let result = try scanner.scan(projectURL: project)
        let byName = Dictionary(
            uniqueKeysWithValues: result.entries.map {
                (URL(fileURLWithPath: $0.relativePath).lastPathComponent, $0)
            }
        )
        XCTAssertTrue(
            try XCTUnwrap(byName[dead.lastPathComponent])
                .classification.isRemovable
        )
        XCTAssertFalse(
            try XCTUnwrap(byName[retained.lastPathComponent])
                .classification.isRemovable
        )
        XCTAssertTrue(
            try XCTUnwrap(byName[retained.lastPathComponent])
                .classification.reason.contains("Keep Intermediates")
        )
        XCTAssertFalse(
            try XCTUnwrap(byName[held.lastPathComponent])
                .classification.isRemovable
        )
        XCTAssertTrue(
            try XCTUnwrap(byName[held.lastPathComponent])
                .classification.reason.contains("lock")
        )
        XCTAssertFalse(
            try XCTUnwrap(byName[history.lastPathComponent])
                .classification.isRemovable
        )
        XCTAssertTrue(
            try XCTUnwrap(byName[history.lastPathComponent])
                .classification.reason.contains("operation history")
        )
    }

    func testTerminalOperationHistoryDistinguishesCompletedFailedAndContradictoryWork()
        throws
    {
        let completed = try makeActiveHistoryCandidate(
            stem: "history-completed",
            disposition: "completed"
        )
        let failed = try makeActiveHistoryCandidate(
            stem: "history-failed",
            disposition: "failed"
        )
        let contradictory = try makeActiveHistoryCandidate(
            stem: "history-removed",
            disposition: "removed"
        )
        let retainedTerminal = try makeActiveHistoryCandidate(
            stem: "history-retained-terminal",
            disposition: "retained-cleanup-failed",
            markerState: .completed
        )
        let malformedRun = UUID()
        let malformed = project.appendingPathComponent(
            ".history-malformed.lungfishgenotype.run-staging-"
                + malformedRun.uuidString,
            isDirectory: true
        )
        try makeOwnedDirectory(
            malformed,
            runID: malformedRun,
            state: .active,
            lockRelativePath: "locks/malformed.lock"
        )
        _ = try ProjectOperationHistoryWriter(projectURL: project)
            .createOperation(
                operationID: malformedRun,
                payloads: [
                    GenotypingCleanupJournal.terminalPayloadName:
                        Data(#"{"schemaVersion":1,"entries":[]}"#.utf8),
                ]
            )

        let entries = Dictionary(
            uniqueKeysWithValues:
                try ProjectStorageScanner(
                    processInspector: { _ in nil },
                    lockProbe: { _ in .unlocked }
                ).scan(projectURL: project).entries.map {
                    ($0.relativePath, $0.classification)
                }
        )

        XCTAssertEqual(
            try XCTUnwrap(entries[completed.lastPathComponent]).code,
            .conclusivelyOrphanedOwnedWork
        )
        XCTAssertEqual(
            try XCTUnwrap(entries[failed.lastPathComponent]).code,
            .conclusivelyOrphanedOwnedWork
        )
        for candidate in [contradictory, retainedTerminal, malformed] {
            XCTAssertEqual(
                try XCTUnwrap(entries[candidate.lastPathComponent]).code,
                .liveOperationHistory
            )
        }
    }

    func testActiveOrphanFailsClosedForMatchingLiveProcessAndInspectionError()
        throws
    {
        let liveRun = UUID()
        let liveIdentity = OwnedProcessIdentity(
            processIdentifier: 51,
            processStartTime: 500,
            bootSessionID: UUID().uuidString
        )
        let live = project.appendingPathComponent(
            ".live.lungfishgenotype.run-staging-\(liveRun.uuidString)",
            isDirectory: true
        )
        try makeOwnedDirectory(
            live,
            runID: liveRun,
            state: .active,
            lockRelativePath: "locks/live.lock",
            processIdentity: liveIdentity
        )
        let unknownRun = UUID()
        let unknown = project.appendingPathComponent(
            ".unknown.lungfishgenotype.run-staging-\(unknownRun.uuidString)",
            isDirectory: true
        )
        try makeOwnedDirectory(
            unknown,
            runID: unknownRun,
            state: .active,
            lockRelativePath: "locks/unknown.lock",
            processIdentity: .init(
                processIdentifier: 52,
                processStartTime: 600,
                bootSessionID: UUID().uuidString
            )
        )
        let reusedRun = UUID()
        let reused = project.appendingPathComponent(
            ".reused.lungfishgenotype.run-staging-\(reusedRun.uuidString)",
            isDirectory: true
        )
        try makeOwnedDirectory(
            reused,
            runID: reusedRun,
            state: .active,
            lockRelativePath: "locks/reused.lock",
            processIdentity: .init(
                processIdentifier: 53,
                processStartTime: 700,
                bootSessionID: UUID().uuidString
            )
        )

        let scanner = ProjectStorageScanner(
            processInspector: { pid in
                switch pid {
                case 51:
                    return liveIdentity
                case 52:
                    throw CocoaError(.fileReadUnknown)
                case 53:
                    return .init(
                        processIdentifier: 53,
                        processStartTime: 701,
                        bootSessionID: UUID().uuidString
                    )
                default:
                    return nil
                }
            },
            lockProbe: { _ in .unlocked }
        )
        let entries = Dictionary(
            uniqueKeysWithValues: try scanner.scan(projectURL: project)
                .entries.map { ($0.relativePath, $0.classification) }
        )

        XCTAssertEqual(
            try XCTUnwrap(entries[live.lastPathComponent]).code,
            .liveProcess
        )
        XCTAssertEqual(
            try XCTUnwrap(entries[unknown.lastPathComponent]).code,
            .liveProcess
        )
        XCTAssertEqual(
            try XCTUnwrap(entries[reused.lastPathComponent]).code,
            .conclusivelyOrphanedOwnedWork
        )
    }

    func testTerminalMarkerStillRequiresRecordedLockNotHeld() throws {
        let runID = UUID()
        let candidate = project.appendingPathComponent(
            ".terminal.lungfishgenotype.run-staging-\(runID.uuidString)",
            isDirectory: true
        )
        try makeOwnedDirectory(
            candidate,
            runID: runID,
            state: .completed,
            lockRelativePath: "locks/terminal.lock"
        )

        let held = try XCTUnwrap(
            ProjectStorageScanner(lockProbe: { _ in .held })
                .scan(projectURL: project).entries.first
        )
        XCTAssertEqual(held.classification.code, .heldLock)

        let unlocked = try XCTUnwrap(
            ProjectStorageScanner(lockProbe: { _ in .unlocked })
                .scan(projectURL: project).entries.first
        )
        XCTAssertTrue(unlocked.classification.isRemovable)
    }

    func testScanUsesLstatAllocatedBytesAndDeduplicatesHardLinks() throws {
        let candidate = project.appendingPathComponent(
            ".analysis.lungfishgenotype.cohort-alignment-work",
            isDirectory: true
        )
        try makeOwnedDirectory(
            candidate,
            runID: UUID(),
            state: .completed
        )
        let first = candidate.appendingPathComponent("evidence.bin")
        let second = candidate.appendingPathComponent("evidence-hardlink.bin")
        try Data(repeating: 0x5a, count: 8_192).write(to: first)
        XCTAssertEqual(Darwin.link(first.path, second.path), 0)
        var fileInfo = stat()
        XCTAssertEqual(Darwin.lstat(first.path, &fileInfo), 0)
        var markerInfo = stat()
        XCTAssertEqual(
            Darwin.lstat(
                candidate.appendingPathComponent(
                    OwnedWorkDirectoryMarker.fileName
                ).path,
                &markerInfo
            ),
            0
        )
        var directoryInfo = stat()
        XCTAssertEqual(Darwin.lstat(candidate.path, &directoryInfo), 0)

        let entry = try XCTUnwrap(
            ProjectStorageScanner().scan(projectURL: project).entries.first
        )

        XCTAssertEqual(
            entry.logicalBytes,
            UInt64(
                fileInfo.st_size
                    + markerInfo.st_size
                    + directoryInfo.st_size
            )
        )
        XCTAssertEqual(
            entry.allocatedBytes,
            UInt64(
                fileInfo.st_blocks
                    + markerInfo.st_blocks
                    + directoryInfo.st_blocks
            ) * 512
        )
    }

    func testAllocatedBytesExcludeCandidateHardLinkWithExternalSurvivor()
        throws
    {
        let candidate = project.appendingPathComponent(
            ".external-link.lungfishgenotype.cohort-alignment-work",
            isDirectory: true
        )
        try makeOwnedDirectory(
            candidate,
            runID: UUID(),
            state: .completed
        )
        let payload = candidate.appendingPathComponent("evidence.bin")
        try Data(repeating: 0x6a, count: 8_192).write(to: payload)
        let surviving = project.appendingPathComponent(
            "live.lungfishgenotype",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: surviving,
            withIntermediateDirectories: true
        )
        XCTAssertEqual(
            Darwin.link(
                payload.path,
                surviving.appendingPathComponent("evidence.bin").path
            ),
            0
        )
        var payloadInfo = stat()
        XCTAssertEqual(Darwin.lstat(payload.path, &payloadInfo), 0)
        var markerInfo = stat()
        XCTAssertEqual(
            Darwin.lstat(
                candidate.appendingPathComponent(
                    OwnedWorkDirectoryMarker.fileName
                ).path,
                &markerInfo
            ),
            0
        )
        var directoryInfo = stat()
        XCTAssertEqual(Darwin.lstat(candidate.path, &directoryInfo), 0)

        let entry = try XCTUnwrap(
            ProjectStorageScanner().scan(projectURL: project).entries.first
        )

        XCTAssertEqual(
            entry.allocatedBytes,
            UInt64(markerInfo.st_blocks + directoryInfo.st_blocks) * 512
        )
    }

    func testHardLinkAcrossManyCandidatesCountsOneInodeAllocation() throws {
        var payload: URL?
        var expectedBlocks: Int64 = 0
        for index in 0..<24 {
            let candidate = project.appendingPathComponent(
                ".linked-\(index).lungfishgenotype."
                    + "candidate-artifact-work",
                isDirectory: true
            )
            try makeOwnedDirectory(
                candidate,
                runID: UUID(),
                state: .completed
            )
            let linkedPayload = candidate.appendingPathComponent(
                "evidence.bin"
            )
            if let payload {
                XCTAssertEqual(
                    Darwin.link(payload.path, linkedPayload.path),
                    0
                )
            } else {
                try Data(repeating: 0x7a, count: 8_192)
                    .write(to: linkedPayload)
                payload = linkedPayload
                var payloadInfo = stat()
                XCTAssertEqual(
                    Darwin.lstat(linkedPayload.path, &payloadInfo),
                    0
                )
                expectedBlocks += payloadInfo.st_blocks
            }
            for measuredURL in [
                candidate,
                candidate.appendingPathComponent(
                    OwnedWorkDirectoryMarker.fileName
                ),
            ] {
                var information = stat()
                XCTAssertEqual(
                    Darwin.lstat(measuredURL.path, &information),
                    0
                )
                expectedBlocks += information.st_blocks
            }
        }

        let result = try ProjectStorageScanner().scan(projectURL: project)

        XCTAssertEqual(result.entries.count, 24)
        XCTAssertTrue(result.entries.allSatisfy {
            $0.classification.isRemovable
        })
        XCTAssertEqual(
            result.reclaimableAllocatedBytes,
            UInt64(expectedBlocks) * 512
        )
    }

    func testSymlinkAndSpecialFileCandidatesFailClosed() throws {
        let symlinkCandidate = project.appendingPathComponent(
            ".symlink.lungfishgenotype.candidate-artifact-work",
            isDirectory: true
        )
        try makeOwnedDirectory(
            symlinkCandidate,
            runID: UUID(),
            state: .completed
        )
        let external = root.appendingPathComponent("external")
        try Data("outside".utf8).write(to: external)
        try FileManager.default.createSymbolicLink(
            at: symlinkCandidate.appendingPathComponent("escape"),
            withDestinationURL: external
        )
        let specialCandidate = project.appendingPathComponent(
            ".special.lungfishgenotype.cohort-alignment-work",
            isDirectory: true
        )
        try makeOwnedDirectory(
            specialCandidate,
            runID: UUID(),
            state: .completed
        )
        XCTAssertEqual(
            Darwin.mkfifo(
                specialCandidate.appendingPathComponent("pipe").path,
                S_IRUSR | S_IWUSR
            ),
            0
        )
        let rootSymlink = project.appendingPathComponent(
            ".root-link.lungfishgenotype.candidate-artifact-work"
        )
        try FileManager.default.createSymbolicLink(
            at: rootSymlink,
            withDestinationURL: symlinkCandidate
        )

        let entries = try ProjectStorageScanner()
            .scan(projectURL: project).entries

        XCTAssertEqual(entries.count, 3)
        XCTAssertTrue(entries.allSatisfy {
            !$0.classification.isRemovable
                && $0.classification.code == .unsafeFileSystemObject
                && !$0.classification.reason.isEmpty
        })
        XCTAssertEqual(try Data(contentsOf: external), Data("outside".utf8))
    }

    func testScanReportsIncrementalProgressAndCancellationWithoutHashing()
        throws
    {
        let candidate = project.appendingPathComponent(
            ".large.lungfishgenotype.candidate-artifact-work",
            isDirectory: true
        )
        try makeOwnedDirectory(
            candidate,
            runID: UUID(),
            state: .completed
        )
        for index in 0..<20 {
            let file = candidate.appendingPathComponent("\(index).bin")
            XCTAssertEqual(Darwin.truncate(file.path, 2_000_000), -1)
            XCTAssertTrue(FileManager.default.createFile(
                atPath: file.path,
                contents: Data()
            ))
            XCTAssertEqual(Darwin.truncate(file.path, 2_000_000), 0)
        }
        let unreadablePayload = candidate.appendingPathComponent("0.bin")
        XCTAssertEqual(Darwin.chmod(unreadablePayload.path, 0), 0)
        defer {
            _ = Darwin.chmod(
                unreadablePayload.path,
                S_IRUSR | S_IWUSR
            )
        }
        var progress: [ProjectStorageScanProgress] = []
        let result = try ProjectStorageScanner().scan(
            projectURL: project,
            progress: { progress.append($0) }
        )
        XCTAssertEqual(result.entries.count, 1)
        XCTAssertGreaterThan(progress.count, 2)
        XCTAssertEqual(
            progress.map(\.visitedFileSystemObjects),
            progress.map(\.visitedFileSystemObjects).sorted()
        )

        var checks = 0
        let cancelling = ProjectStorageScanner(
            cancellationCheck: {
                checks += 1
                if checks == 5 { throw CancellationError() }
            }
        )
        XCTAssertThrowsError(
            try cancelling.scan(projectURL: project)
        ) {
            XCTAssertTrue($0 is CancellationError)
        }
    }

    func testLegacyArchiveRequiresOneNestedBundleAndOneLiveRevisionMatch()
        throws
    {
        let transactionID = legacyTransactionID()
        let archive = project.appendingPathComponent(
            ".lungfish-workbook-generation-archive-"
                + transactionID,
            isDirectory: true
        )
        let archivedBundle = archive.appendingPathComponent(
            "sample.lungfishgenotype",
            isDirectory: true
        )
        try writeBundle(
            archivedBundle,
            currentPath: "artifacts/workbooks/current.xlsx",
            revisionPath: "artifacts/workbooks/current.xlsx",
            bytes: Data("retired-workbook".utf8),
            checksum: String(repeating: "a", count: 64)
        )
        let liveBundle = project.appendingPathComponent(
            "sample.lungfishgenotype",
            isDirectory: true
        )
        try writeBundle(
            liveBundle,
            currentPath: "artifacts/workbooks/current.xlsx",
            revisionPath: "artifacts/workbooks/revisions/retired.xlsx",
            bytes: Data("retired-workbook".utf8),
            checksum: String(repeating: "a", count: 64)
        )

        let classification =
            try ProjectStorageLegacyWorkbookClassifier().classify(
                archiveURL: archive,
                projectURL: project
            )

        XCTAssertTrue(classification.isRemovable, classification.reason)
    }

    func testLegacyArchiveFailsClosedForMissingDuplicatePreparedAndTamperedContent()
        throws
    {
        let checksum = String(repeating: "b", count: 64)
        func makeArchive(_ name: String, bytes: Data) throws -> URL {
            let archive = project.appendingPathComponent(
                ".lungfish-workbook-generation-archive-"
                    + legacyTransactionID(),
                isDirectory: true
            )
            try writeBundle(
                archive.appendingPathComponent(
                    "\(name).lungfishgenotype",
                    isDirectory: true
                ),
                currentPath: "artifacts/workbooks/current.xlsx",
                revisionPath: "artifacts/workbooks/current.xlsx",
                bytes: bytes,
                checksum: checksum
            )
            return archive
        }
        let missing = try makeArchive("missing", bytes: Data("missing".utf8))
        let duplicate = try makeArchive(
            "duplicate",
            bytes: Data("duplicate".utf8)
        )
        for suffix in ["one", "two"] {
            try writeBundle(
                project.appendingPathComponent(
                    "duplicate-\(suffix).lungfishgenotype",
                    isDirectory: true
                ),
                currentPath: "artifacts/workbooks/current.xlsx",
                revisionPath: "artifacts/workbooks/revisions/old.xlsx",
                bytes: Data("duplicate".utf8),
                checksum: checksum
            )
        }
        let tampered = try makeArchive(
            "tampered",
            bytes: Data("original".utf8)
        )
        try writeBundle(
            project.appendingPathComponent(
                "tampered.lungfishgenotype",
                isDirectory: true
            ),
            currentPath: "artifacts/workbooks/current.xlsx",
            revisionPath: "artifacts/workbooks/revisions/old.xlsx",
            bytes: Data("original".utf8),
            checksum: checksum
        )
        try Data("different-size-content".utf8).write(
            to: tampered
                .appendingPathComponent(
                    "tampered.lungfishgenotype",
                    isDirectory: true
                )
                .appendingPathComponent("artifacts/workbooks/current.xlsx")
        )
        let prepared = try makeArchive(
            "prepared",
            bytes: Data("new-unpublished".utf8)
        )
        try writeBundle(
            project.appendingPathComponent(
                "prepared.lungfishgenotype",
                isDirectory: true
            ),
            currentPath: "artifacts/workbooks/current.xlsx",
            revisionPath: "artifacts/workbooks/revisions/old.xlsx",
            bytes: Data("old-live".utf8),
            checksum: String(repeating: "c", count: 64)
        )

        let classifier = ProjectStorageLegacyWorkbookClassifier()
        for archive in [missing, duplicate, tampered, prepared] {
            let result = try classifier.classify(
                archiveURL: archive,
                projectURL: project
            )
            XCTAssertFalse(
                result.isRemovable,
                "\(archive.lastPathComponent): \(result.reason)"
            )
        }
    }

    func testLegacyArchiveBlocksLiveAttestationAndHeldPublicationLock()
        throws
    {
        let transactionID = legacyTransactionID()
        let pair = try makeValidLegacyPair(
            transactionID: transactionID,
            stem: "authority",
            checksum: String(repeating: "d", count: 64)
        )
        let attestationRoot = root.appendingPathComponent(
            "attestations",
            isDirectory: true
        )
        _ = try ONTGenotypeWorkbookUpdateRecovery.createAttestation(
            for: workbookTransaction(
                transactionID: transactionID,
                liveBundle: pair.liveBundle
            ),
            attestationRootURL: attestationRoot
        )
        let attested = try ProjectStorageLegacyWorkbookClassifier(
            attestationRootURL: attestationRoot
        ).classify(
            archiveURL: pair.archive,
            projectURL: project
        )
        XCTAssertEqual(attested.code, .liveWorkbookAuthority)

        let secondID = legacyTransactionID()
        let lockedPair = try makeValidLegacyPair(
            transactionID: secondID,
            stem: "locked",
            checksum: String(repeating: "e", count: 64)
        )
        let lock = try ONTGenotypeBundlePublicationLock.acquire(
            for: lockedPair.liveBundle
        )
        defer { lock.release() }
        let locked = try ProjectStorageLegacyWorkbookClassifier(
            attestationRootURL: root.appendingPathComponent("empty-attestations")
        ).classify(
            archiveURL: lockedPair.archive,
            projectURL: project
        )
        XCTAssertEqual(locked.code, .liveWorkbookAuthority)
        XCTAssertTrue(locked.reason.contains("lock"))

        let malformedID = legacyTransactionID()
        let malformedPair = try makeValidLegacyPair(
            transactionID: malformedID,
            stem: "malformed-attestation",
            checksum: String(repeating: "4", count: 64)
        )
        let malformedRoot = root.appendingPathComponent(
            "malformed-attestations",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: malformedRoot,
            withIntermediateDirectories: true
        )
        try Data("{not-json".utf8).write(
            to: malformedRoot.appendingPathComponent("unknown.json")
        )
        let malformed = try ProjectStorageLegacyWorkbookClassifier(
            attestationRootURL: malformedRoot
        ).classify(
            archiveURL: malformedPair.archive,
            projectURL: project
        )
        XCTAssertEqual(malformed.code, .liveWorkbookAuthority)
    }

    func testLegacyArchiveBlocksEitherAttestationIdentityConflict()
        throws
    {
        let transactionID = legacyTransactionID()
        let pair = try makeValidLegacyPair(
            transactionID: transactionID,
            stem: "attestation-transaction-conflict",
            checksum: String(repeating: "6", count: 64)
        )
        let transactionConflictRoot = root.appendingPathComponent(
            "transaction-conflict-attestations",
            isDirectory: true
        )
        _ = try ONTGenotypeWorkbookUpdateRecovery.createAttestation(
            for: workbookTransaction(
                transactionID: transactionID,
                liveBundle: project.appendingPathComponent(
                    "different.lungfishgenotype",
                    isDirectory: true
                )
            ),
            attestationRootURL: transactionConflictRoot
        )
        let transactionConflict =
            try ProjectStorageLegacyWorkbookClassifier(
                attestationRootURL: transactionConflictRoot
            ).classify(
                archiveURL: pair.archive,
                projectURL: project
            )
        XCTAssertEqual(transactionConflict.code, .liveWorkbookAuthority)

        let secondID = legacyTransactionID()
        let secondPair = try makeValidLegacyPair(
            transactionID: secondID,
            stem: "attestation-bundle-conflict",
            checksum: String(repeating: "7", count: 64)
        )
        let bundleConflictRoot = root.appendingPathComponent(
            "bundle-conflict-attestations",
            isDirectory: true
        )
        _ = try ONTGenotypeWorkbookUpdateRecovery.createAttestation(
            for: workbookTransaction(
                transactionID: legacyTransactionID(),
                liveBundle: secondPair.liveBundle
            ),
            attestationRootURL: bundleConflictRoot
        )
        let bundleConflict =
            try ProjectStorageLegacyWorkbookClassifier(
                attestationRootURL: bundleConflictRoot
            ).classify(
                archiveURL: secondPair.archive,
                projectURL: project
            )
        XCTAssertEqual(bundleConflict.code, .liveWorkbookAuthority)
    }

    func testLegacyArchiveRejectsAttestationRootWithSymlinkedAncestor()
        throws
    {
        let pair = try makeValidLegacyPair(
            transactionID: legacyTransactionID(),
            stem: "attestation-symlink-root",
            checksum: String(repeating: "8", count: 64)
        )
        let realParent = root.appendingPathComponent(
            "real-attestation-parent",
            isDirectory: true
        )
        let realRoot = realParent.appendingPathComponent(
            "attestations",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: realRoot,
            withIntermediateDirectories: true
        )
        let linkedParent = root.appendingPathComponent(
            "linked-attestation-parent",
            isDirectory: true
        )
        try FileManager.default.createSymbolicLink(
            at: linkedParent,
            withDestinationURL: realParent
        )

        let classification =
            try ProjectStorageLegacyWorkbookClassifier(
                attestationRootURL:
                    linkedParent.appendingPathComponent(
                        "attestations",
                        isDirectory: true
                    )
            ).classify(
                archiveURL: pair.archive,
                projectURL: project
            )

        XCTAssertEqual(classification.code, .liveWorkbookAuthority)
    }

    func testLegacyArchiveRejectsIntermediateSymlinkInLiveRevisionPath()
        throws
    {
        let pair = try makeValidLegacyPair(
            transactionID: legacyTransactionID(),
            stem: "symlinked-revision",
            checksum: String(repeating: "5", count: 64)
        )
        let revisions = pair.liveBundle.appendingPathComponent(
            "artifacts/workbooks/revisions",
            isDirectory: true
        )
        let externalRevisions = root.appendingPathComponent(
            "external-revisions",
            isDirectory: true
        )
        try FileManager.default.moveItem(
            at: revisions,
            to: externalRevisions
        )
        try FileManager.default.createSymbolicLink(
            at: revisions,
            withDestinationURL: externalRevisions
        )

        let classification =
            try ProjectStorageLegacyWorkbookClassifier(
                attestationRootURL:
                    root.appendingPathComponent("empty-attestations")
            ).classify(
                archiveURL: pair.archive,
                projectURL: project
            )

        XCTAssertFalse(classification.isRemovable)
        XCTAssertEqual(classification.code, .ambiguousWorkbookArchive)
    }

    func testLegacyArchiveReceiptMustAgreeWithTransactionID() throws {
        let acceptedID = legacyTransactionID()
        let acceptedPair = try makeValidLegacyPair(
            transactionID: acceptedID,
            stem: "manual-save",
            checksum: String(repeating: "f", count: 64)
        )
        try writeRecoveryReceipt(
            filenameTransactionID: acceptedID,
            transaction: workbookTransaction(
                transactionID: acceptedID,
                liveBundle: acceptedPair.liveBundle,
                workbookChecksum: String(repeating: "f", count: 64),
                workbookSize: Int64(Data("retired-workbook".utf8).count)
            ),
            liveBundle: acceptedPair.liveBundle,
            action: "manual-save-winner-restored"
        )
        let accepted = try ProjectStorageLegacyWorkbookClassifier(
            attestationRootURL: root.appendingPathComponent("empty-attestations")
        ).classify(
            archiveURL: acceptedPair.archive,
            projectURL: project
        )
        XCTAssertTrue(accepted.isRemovable, accepted.reason)

        let rejectedID = legacyTransactionID()
        let rejectedPair = try makeValidLegacyPair(
            transactionID: rejectedID,
            stem: "receipt-mismatch",
            checksum: String(repeating: "1", count: 64)
        )
        try writeRecoveryReceipt(
            filenameTransactionID: rejectedID,
            transaction: workbookTransaction(
                transactionID: legacyTransactionID(),
                liveBundle: rejectedPair.liveBundle,
                workbookChecksum: String(repeating: "1", count: 64),
                workbookSize: Int64(Data("retired-workbook".utf8).count)
            ),
            liveBundle: rejectedPair.liveBundle,
            action: "committed"
        )
        let rejected = try ProjectStorageLegacyWorkbookClassifier(
            attestationRootURL: root.appendingPathComponent("empty-attestations")
        ).classify(
            archiveURL: rejectedPair.archive,
            projectURL: project
        )
        XCTAssertEqual(rejected.code, .liveWorkbookAuthority)

        let reverseID = legacyTransactionID()
        let reversePair = try makeValidLegacyPair(
            transactionID: reverseID,
            stem: "receipt-reverse-mismatch",
            checksum: String(repeating: "3", count: 64)
        )
        try writeRecoveryReceipt(
            filenameTransactionID: legacyTransactionID(),
            transaction: workbookTransaction(
                transactionID: reverseID,
                liveBundle: reversePair.liveBundle,
                workbookChecksum: String(repeating: "3", count: 64),
                workbookSize: Int64(Data("retired-workbook".utf8).count)
            ),
            liveBundle: reversePair.liveBundle,
            action: "committed"
        )
        let reverseRejected = try ProjectStorageLegacyWorkbookClassifier(
            attestationRootURL: root.appendingPathComponent("empty-attestations")
        ).classify(
            archiveURL: reversePair.archive,
            projectURL: project
        )
        XCTAssertEqual(reverseRejected.code, .liveWorkbookAuthority)
        XCTAssertTrue(reverseRejected.reason.contains("filename"))
    }

    private func makeOwnedDirectory(
        _ directory: URL,
        runID: UUID,
        state: OwnedWorkDirectoryMarker.State,
        keepIntermediates: Bool = false,
        lockRelativePath: String? = nil,
        processIdentity: OwnedProcessIdentity = .init(
            processIdentifier: 1,
            processStartTime: 1,
            bootSessionID: UUID().uuidString
        )
    ) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try OwnedWorkDirectoryMarkerStore.bindExistingDirectory(
            directory,
            request: .init(
                projectURL: project,
                parentDirectoryURL: directory.deletingLastPathComponent(),
                prefix: "unused-",
                runID: runID,
                processIdentity: processIdentity,
                state: state,
                lockRelativePath: lockRelativePath,
                keepIntermediates: keepIntermediates,
                toolName: "storage-scanner-test",
                toolVersion: "1"
            )
        )
    }

    private func makeActiveHistoryCandidate(
        stem: String,
        disposition: String,
        markerState: OwnedWorkDirectoryMarker.State = .active
    ) throws -> URL {
        let runID = UUID()
        let candidate = project.appendingPathComponent(
            ".\(stem).lungfishgenotype.run-staging-\(runID.uuidString)",
            isDirectory: true
        )
        try makeOwnedDirectory(
            candidate,
            runID: runID,
            state: markerState,
            lockRelativePath: "locks/\(stem).lock"
        )
        let terminal = try JSONSerialization.data(
            withJSONObject: [
                "schemaVersion": 1,
                "runID": runID.uuidString,
                "entries": [
                    [
                        "path": candidate.path,
                        "disposition": disposition,
                    ],
                ],
            ],
            options: [.sortedKeys]
        )
        _ = try ProjectOperationHistoryWriter(projectURL: project)
            .createOperation(
                operationID: runID,
                payloads: [
                    GenotypingCleanupJournal.terminalPayloadName: terminal,
                ]
            )
        return candidate
    }

    private func legacyTransactionID() -> String {
        "2026-07-27T120000Z-update-current-workbook-"
            + UUID().uuidString.replacingOccurrences(
                of: "-",
                with: ""
            ).prefix(8)
    }

    private func makeValidLegacyPair(
        transactionID: String,
        stem: String,
        checksum: String
    ) throws -> (archive: URL, liveBundle: URL) {
        let bytes = Data("retired-workbook".utf8)
        let archive = project.appendingPathComponent(
            ".lungfish-workbook-generation-archive-\(transactionID)",
            isDirectory: true
        )
        try writeBundle(
            archive.appendingPathComponent(
                "\(stem).lungfishgenotype",
                isDirectory: true
            ),
            currentPath: "artifacts/workbooks/current.xlsx",
            revisionPath: "artifacts/workbooks/current.xlsx",
            bytes: bytes,
            checksum: checksum
        )
        let liveBundle = project.appendingPathComponent(
            "\(stem).lungfishgenotype",
            isDirectory: true
        )
        try writeBundle(
            liveBundle,
            currentPath: "artifacts/workbooks/current.xlsx",
            revisionPath: "artifacts/workbooks/revisions/retired.xlsx",
            bytes: bytes,
            checksum: checksum
        )
        return (archive, liveBundle)
    }

    private func workbookTransaction(
        transactionID: String,
        liveBundle: URL,
        workbookChecksum: String = String(repeating: "0", count: 64),
        workbookSize: Int64 = 0
    ) -> ONTGenotypeWorkbookUpdateTransaction {
        let descriptor = ONTGenotypeWorkbookUpdateFileDescriptor(
            path: "artifacts/workbooks/current.xlsx",
            sizeBytes: workbookSize,
            sha256: workbookChecksum
        )
        let manifest = ONTGenotypeWorkbookUpdateFileDescriptor(
            path: ONTGenotypeResultBundleManifest.filename,
            sizeBytes: 1,
            sha256: String(repeating: "2", count: 64)
        )
        let identity = ONTGenotypeWorkbookUpdateDirectoryIdentity(
            path: liveBundle.path,
            device: 1,
            inode: 1
        )
        return .init(
            transactionID: transactionID,
            finalBundlePath: liveBundle.path,
            stagingBundlePath: liveBundle.path + ".staging",
            transactionRootPath: liveBundle.path + ".transaction",
            rotationTemporaryPath: liveBundle.path + ".rotation",
            workflowName: "storage-test",
            toolName: "storage-test",
            toolVersion: "1",
            argv: ["storage-test"],
            durableReplayArgv: ["storage-test", "--replay"],
            resolvedOptions: [:],
            runtimeIdentity: [:],
            oldManifest: manifest,
            newManifest: manifest,
            oldCurrentWorkbook: descriptor,
            newCurrentWorkbook: descriptor,
            oldGenerationIdentity: identity,
            newGenerationIdentity: identity,
            transactionRootIdentity: identity,
            finalParentIdentity: identity
        )
    }

    private func writeRecoveryReceipt(
        filenameTransactionID: String,
        transaction: ONTGenotypeWorkbookUpdateTransaction,
        liveBundle: URL,
        action: String
    ) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let transactionObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: encoder.encode(transaction)
            ) as? [String: Any]
        )
        let receipt: [String: Any] = [
            "schemaVersion": 1,
            "transaction": transactionObject,
            "action": action,
            "startedAt": "2026-07-27T00:00:00Z",
            "completedAt": "2026-07-27T00:00:01Z",
            "wallTimeSeconds": 1.0,
            "exitStatus": 0,
            "stderr": "",
            "inputs": [],
            "outputs": [],
            "detail": "storage test",
        ]
        let receiptURL = liveBundle.deletingLastPathComponent()
            .appendingPathComponent(
                ".\(liveBundle.lastPathComponent)"
                    + ".workbook-update-recovery-"
                    + "\(filenameTransactionID)-test.json"
            )
        try JSONSerialization.data(
            withJSONObject: receipt,
            options: [.sortedKeys]
        ).write(to: receiptURL)
    }

    private func writeBundle(
        _ bundle: URL,
        currentPath: String,
        revisionPath: String,
        bytes: Data,
        checksum: String
    ) throws {
        let workbook = bundle.appendingPathComponent(currentPath)
        let retainedRevision = bundle.appendingPathComponent(revisionPath)
        try FileManager.default.createDirectory(
            at: workbook.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: retainedRevision.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try bytes.write(to: workbook)
        if retainedRevision.standardizedFileURL != workbook.standardizedFileURL {
            try bytes.write(to: retainedRevision)
        }
        let revision = ONTGenotypeWorkbookRevision(
            id: UUID().uuidString,
            role: .externalEditSnapshot,
            path: revisionPath,
            label: "Retained",
            createdAt: "2026-07-27T00:00:00Z",
            sha256: checksum,
            sizeBytes: Int64(bytes.count)
        )
        let manifest = ONTGenotypeResultBundleManifest(
            outputName: bundle.deletingPathExtension().lastPathComponent,
            analysisName: "Storage scanner",
            primaryWorkbookPath: "primary.xlsx",
            longSummaryCSVPath: "long.csv",
            sampleSummaryCSVPath: "samples.csv",
            statsJSONPath: "stats.json",
            provenancePath: "provenance.json"
        ).replacingWorkbookFields(
            currentWorkbookPath: currentPath,
            workbookRevisions: [revision]
        )
        try JSONEncoder().encode(manifest).write(
            to: bundle.appendingPathComponent(
                ONTGenotypeResultBundleManifest.filename
            )
        )
    }
}
