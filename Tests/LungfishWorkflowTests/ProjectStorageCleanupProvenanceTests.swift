import Darwin
import Foundation
import LungfishIO
import XCTest
@testable import LungfishWorkflow

final class ProjectStorageCleanupProvenanceTests: XCTestCase {
    private var root: URL!
    private var project: URL!
    private var candidate: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ProjectStorageCleanupProvenanceTests-\(UUID().uuidString)",
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
        try FileManager.default.createDirectory(
            at: candidate.appendingPathComponent(
                "nested",
                isDirectory: true
            ),
            withIntermediateDirectories: true
        )
        try OwnedWorkDirectoryMarkerStore.bindExistingDirectory(
            candidate,
            request: .init(
                projectURL: project,
                parentDirectoryURL: project,
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
                toolName: "cleanup-provenance-test",
                toolVersion: "1"
            )
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testPreparationPublishesSortedInventoryAndCompleteProvenance()
        throws
    {
        let attestedURL = candidate.appendingPathComponent("a.txt")
        let nestedURL = candidate.appendingPathComponent("nested/b.txt")
        let finalURL = candidate.appendingPathComponent("z.txt")
        try Data("attested".utf8).write(to: attestedURL)
        try Data("nested".utf8).write(to: nestedURL)
        try Data("final".utf8).write(to: finalURL)
        let entry = try storageEntry(for: candidate)
        let attested = try attestedInventoryEntry(
            item: entry,
            fileURL: attestedURL,
            relativePath: "a.txt"
        )
        let hashes = StringRecorder()
        let started = Date(timeIntervalSince1970: 100)
        let completed = Date(timeIntervalSince1970: 104)
        let trusted = try trustedAttestation(
            for: entry,
            entries: [attested]
        )
        let request = try makeRequest(
            entry: entry,
            startedAt: started,
            attestedInventories: [trusted]
        )
        let writer = ProjectStorageCleanupReceiptWriter(
            operations: .init(
                cancellationCheck: {},
                didHashRelativePath: { hashes.append($0) },
                now: { completed }
            )
        )

        let prepared = try writer.prepareConfirmedCleanup(request)

        XCTAssertEqual(
            prepared.operationDirectoryURL.path,
            project
                .appendingPathComponent(
                    ProjectOperationHistoryWriter.historyDirectoryName,
                    isDirectory: true
                )
                .appendingPathComponent(
                    "storage-cleanups",
                    isDirectory: true
                )
                .appendingPathComponent(
                    request.cleanupID.uuidString.lowercased(),
                    isDirectory: true
                ).path
        )
        XCTAssertEqual(
            prepared.operationDirectoryIdentity,
            try FileSystemObjectIdentity.noFollow(
                prepared.operationDirectoryURL
            )
        )
        let inventoryPaths = try XCTUnwrap(
            prepared.journal.items.singleValue?.inventory.map(\.relativePath)
        )
        XCTAssertEqual(inventoryPaths, inventoryPaths.sorted())
        XCTAssertTrue(inventoryPaths.contains("a.txt"))
        XCTAssertTrue(inventoryPaths.contains("nested/b.txt"))
        XCTAssertTrue(inventoryPaths.contains("z.txt"))
        XCTAssertFalse(hashes.values.contains("a.txt"))
        XCTAssertTrue(hashes.values.contains("nested/b.txt"))
        XCTAssertTrue(hashes.values.contains("z.txt"))
        XCTAssertEqual(prepared.journal.state, .prepared)
        XCTAssertEqual(prepared.journal.intendedAction, .moveToTrash)
        XCTAssertEqual(prepared.journal.argv, request.argv)
        XCTAssertEqual(
            prepared.journal.durableReplayArgv,
            request.durableReplayArgv
        )
        XCTAssertEqual(prepared.journal.runtimeIdentity, request.runtimeIdentity)
        XCTAssertEqual(prepared.journal.exitStatus, 0)
        XCTAssertEqual(prepared.journal.wallTimeSeconds, 4)
        XCTAssertEqual(prepared.journal.stderr, "")
        XCTAssertEqual(
            prepared.journal.attestationSources.singleValue?
                .provenanceFileSize,
            trusted.sourceProvenanceFileSize
        )
        XCTAssertEqual(
            prepared.journal.items.singleValue?.inventory.first {
                $0.relativePath == "a.txt"
            }?.sha256,
            attested.sha256
        )

        let decodedJournal = try ProvenanceJSON.decoder.decode(
            ProjectStorageCleanupJournal.self,
            from: Data(contentsOf: prepared.journalURL)
        )
        XCTAssertEqual(decodedJournal, prepared.journal)
        let canonicalProvenanceData = try Data(
            contentsOf: prepared.provenanceURL
        )
        let decodedProvenance =
            try ProvenanceEnvelopeReader.decodeCanonical(
                canonicalProvenanceData
            )
        XCTAssertEqual(
            try ProvenanceJSON.encoder.encode(decodedProvenance),
            canonicalProvenanceData
        )
        XCTAssertEqual(decodedProvenance.argv, request.argv)
        XCTAssertEqual(
            decodedProvenance.durableReplayArgv,
            request.durableReplayArgv
        )
        XCTAssertEqual(decodedProvenance.options.explicit["reviewed"], .boolean(true))
        XCTAssertEqual(decodedProvenance.options.defaults["action"], .string("trash"))
        XCTAssertEqual(
            decodedProvenance.options.resolvedDefaults[
                "permanentDeleteFallback"
            ],
            .boolean(false)
        )
        XCTAssertNotNil(
            (
                decodedProvenance.options.resolvedDefaults[
                    "cleanupInventory"
                ]
            )?.arrayValue
        )
        let firstInventoryValue = try XCTUnwrap(
            decodedProvenance.options.resolvedDefaults[
                "cleanupInventory"
            ]?.arrayValue?.first?.dictionaryValue?["inventory"]?
                .arrayValue?.first?.dictionaryValue
        )
        XCTAssertNotNil(firstInventoryValue["logicalSize"]?.integerValue)
        XCTAssertNotNil(firstInventoryValue["allocatedSize"]?.integerValue)
        XCTAssertNotNil(firstInventoryValue["device"]?.integerValue)
        XCTAssertNotNil(firstInventoryValue["inode"]?.integerValue)
        XCTAssertEqual(decodedProvenance.runtimeIdentity, request.runtimeIdentity)
        XCTAssertEqual(decodedProvenance.exitStatus, 0)
        XCTAssertEqual(decodedProvenance.wallTimeSeconds, 4)
        XCTAssertEqual(decodedProvenance.stderr, "")
        XCTAssertEqual(decodedProvenance.output?.path, prepared.journalURL.path)
        XCTAssertTrue(
            decodedProvenance.files.contains {
                $0.path == trusted.sourceProvenancePath
                    && $0.fileSize == trusted.sourceProvenanceFileSize
                    && $0.checksumSHA256
                        == trusted.sourceProvenanceChecksumSHA256
            }
        )
        XCTAssertEqual(decodedProvenance.output?.checksumSHA256?.count, 64)
        XCTAssertEqual(
            decodedProvenance.output?.fileSize,
            UInt64(try Data(contentsOf: prepared.journalURL).count)
        )
        XCTAssertEqual(decodedProvenance.steps.singleValue?.startedAt, started)
        XCTAssertEqual(decodedProvenance.steps.singleValue?.completedAt, completed)
        XCTAssertEqual(
            decodedProvenance.steps.singleValue?.resolvedOptions[
                "cleanupInventory"
            ],
            decodedProvenance.options.resolvedDefaults["cleanupInventory"]
        )
        XCTAssertEqual(
            try Data(contentsOf: attestedURL),
            Data("attested".utf8)
        )
    }

    func testTreeDigestIsDeterministicAndHardLinksHashOnce() throws {
        let first = candidate.appendingPathComponent("first.bin")
        let second = candidate.appendingPathComponent("second.bin")
        try Data(repeating: 0x5a, count: 8_192).write(to: first)
        XCTAssertEqual(Darwin.link(first.path, second.path), 0)
        let entry = try storageEntry(for: candidate)
        let firstHashes = StringRecorder()
        let firstPrepared = try ProjectStorageCleanupReceiptWriter(
            operations: .init(
                didHashRelativePath: { firstHashes.append($0) }
            )
        ).prepareConfirmedCleanup(try makeRequest(entry: entry))
        let secondPrepared = try ProjectStorageCleanupReceiptWriter()
            .prepareConfirmedCleanup(
                try makeRequest(entry: entry, cleanupID: UUID())
            )

        XCTAssertEqual(
            firstHashes.values.filter {
                $0 == "first.bin" || $0 == "second.bin"
            }.count,
            1
        )
        XCTAssertEqual(
            firstPrepared.journal.items.singleValue?.aggregateTreeDigest,
            secondPrepared.journal.items.singleValue?.aggregateTreeDigest
        )
        let hardLinkInventory =
            firstPrepared.journal.items.singleValue?.inventory.filter {
                $0.relativePath == "first.bin"
                    || $0.relativePath == "second.bin"
            } ?? []
        XCTAssertEqual(hardLinkInventory.count, 2)
        XCTAssertEqual(
            Set(hardLinkInventory.map(\.sha256)).count,
            1
        )
    }

    func testCancellationAndPublicationFailureNeverMutateSelectedRoot()
        throws
    {
        let payload = candidate.appendingPathComponent("payload.bin")
        try Data(repeating: 0x22, count: 1_048_576).write(to: payload)
        let entry = try storageEntry(for: candidate)
        let beforeIdentity = try FileSystemObjectIdentity.noFollow(candidate)
        let cancelling = ProjectStorageCleanupReceiptWriter(
            operations: .init(
                cancellationCheck: { throw CancellationError() }
            )
        )
        let cancelledRequest = try makeRequest(entry: entry)
        XCTAssertThrowsError(
            try cancelling.prepareConfirmedCleanup(
                cancelledRequest
            )
        ) {
            XCTAssertTrue($0 is CancellationError)
        }
        XCTAssertEqual(
            try FileSystemObjectIdentity.noFollow(candidate),
            beforeIdentity
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath:
                    operationDirectory(
                        for: entry,
                        cleanupID: cancelledRequest.cleanupID
                    ).path
            )
        )

        enum InjectedFailure: Error { case durability }
        let failedRequest = try makeRequest(entry: entry, cleanupID: UUID())
        let failing = ProjectStorageCleanupReceiptWriter(
            operations: .init(
                beforePublish: { throw InjectedFailure.durability }
            )
        )
        XCTAssertThrowsError(
            try failing.prepareConfirmedCleanup(failedRequest)
        )
        XCTAssertEqual(
            try FileSystemObjectIdentity.noFollow(candidate),
            beforeIdentity
        )
        XCTAssertEqual(
            try Data(contentsOf: payload),
            Data(repeating: 0x22, count: 1_048_576)
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath:
                    operationDirectory(
                        for: entry,
                        cleanupID: failedRequest.cleanupID
                    ).path
            )
        )
    }

    func testSymlinkSpecialFileAndIdentityMismatchFailClosed() throws {
        let outside = root.appendingPathComponent("outside.txt")
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: candidate.appendingPathComponent("escape"),
            withDestinationURL: outside
        )
        let unsafeEntry = try storageEntry(for: candidate)
        XCTAssertThrowsError(
            try ProjectStorageCleanupReceiptWriter()
                .prepareConfirmedCleanup(
                    try makeRequest(entry: unsafeEntry)
                )
        )
        XCTAssertEqual(try Data(contentsOf: outside), Data("outside".utf8))

        try FileManager.default.removeItem(
            at: candidate.appendingPathComponent("escape")
        )
        XCTAssertEqual(
            Darwin.mkfifo(
                candidate.appendingPathComponent("pipe").path,
                S_IRUSR | S_IWUSR
            ),
            0
        )
        XCTAssertThrowsError(
            try ProjectStorageCleanupReceiptWriter()
                .prepareConfirmedCleanup(
                    try makeRequest(entry: unsafeEntry, cleanupID: UUID())
                )
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: candidate.path))
    }

    func testUnsafeOperationHistoryPermissionsFailBeforePublication()
        throws
    {
        let payload = candidate.appendingPathComponent("payload.txt")
        try Data("keep".utf8).write(to: payload)
        let entry = try storageEntry(for: candidate)
        let history = project.appendingPathComponent(
            ProjectOperationHistoryWriter.historyDirectoryName,
            isDirectory: true
        )
        let collection = history.appendingPathComponent(
            ProjectStorageCleanupReceiptWriter.collectionDirectoryName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: collection,
            withIntermediateDirectories: true
        )
        XCTAssertEqual(Darwin.chmod(collection.path, 0o777), 0)
        let request = try makeRequest(entry: entry)

        XCTAssertThrowsError(
            try ProjectStorageCleanupReceiptWriter()
                .prepareConfirmedCleanup(request)
        )

        XCTAssertEqual(try Data(contentsOf: payload), Data("keep".utf8))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath:
                    operationDirectory(
                        for: entry,
                        cleanupID: request.cleanupID
                    ).path
            )
        )
    }

    func testSourcePathReplacementDuringHashingFailsClosed() throws {
        let payload = candidate.appendingPathComponent("payload.txt")
        try Data("original".utf8).write(to: payload)
        let entry = try storageEntry(for: candidate)
        let displaced = project.appendingPathComponent(
            "displaced",
            isDirectory: true
        )
        let mutation = OnceAction {
            try FileManager.default.moveItem(at: self.candidate, to: displaced)
            try FileManager.default.createDirectory(
                at: self.candidate,
                withIntermediateDirectories: false
            )
            try Data("replacement".utf8).write(
                to: self.candidate.appendingPathComponent("payload.txt")
            )
        }
        let request = try makeRequest(entry: entry)
        let writer = ProjectStorageCleanupReceiptWriter(
            operations: .init(
                didHashRelativePath: { _ in try? mutation.run() }
            )
        )

        XCTAssertThrowsError(
            try writer.prepareConfirmedCleanup(request)
        )

        XCTAssertEqual(
            try Data(
                contentsOf: candidate.appendingPathComponent("payload.txt")
            ),
            Data("replacement".utf8)
        )
        XCTAssertEqual(
            try Data(
                contentsOf: displaced.appendingPathComponent("payload.txt")
            ),
            Data("original".utf8)
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath:
                    operationDirectory(
                        for: entry,
                        cleanupID: request.cleanupID
                    ).path
            )
        )
    }

    func testPayloadAndDirectoryFsyncsPrecedePublication() throws {
        try Data("durable".utf8).write(
            to: candidate.appendingPathComponent("payload.txt")
        )
        let entry = try storageEntry(for: candidate)
        let syncs = StringRecorder()
        let writer = ProjectStorageCleanupReceiptWriter(
            operations: .init(
                syncFile: {
                    syncs.append("file")
                    return Darwin.fsync($0)
                },
                syncDirectory: {
                    syncs.append("directory")
                    return Darwin.fsync($0)
                }
            )
        )

        _ = try writer.prepareConfirmedCleanup(
            try makeRequest(entry: entry)
        )

        XCTAssertGreaterThanOrEqual(
            syncs.values.filter { $0 == "file" }.count,
            2
        )
        XCTAssertGreaterThanOrEqual(
            syncs.values.filter { $0 == "directory" }.count,
            5
        )
    }

    func testPayloadFsyncFailureRollsBackFinalPublication() throws {
        let payload = candidate.appendingPathComponent("payload.txt")
        try Data("keep".utf8).write(to: payload)
        let entry = try storageEntry(for: candidate)
        let request = try makeRequest(entry: entry)
        let writer = ProjectStorageCleanupReceiptWriter(
            operations: .init(
                syncFile: { _ in
                    errno = EIO
                    return -1
                }
            )
        )

        XCTAssertThrowsError(
            try writer.prepareConfirmedCleanup(request)
        )

        XCTAssertEqual(try Data(contentsOf: payload), Data("keep".utf8))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath:
                    operationDirectory(
                        for: entry,
                        cleanupID: request.cleanupID
                    ).path
            )
        )
    }

    func testForgedStaleReservedAndOverlappingSelectionsAreRejected()
        throws
    {
        let payload = candidate.appendingPathComponent("payload.txt")
        try Data("first".utf8).write(to: payload)
        let authoritative = try storageEntry(for: candidate)
        let forged = ProjectStorageEntry(
            projectIdentity: try FileSystemObjectIdentity.noFollow(project),
            relativePath: authoritative.relativePath,
            identity: authoritative.identity,
            category: authoritative.category,
            logicalBytes: authoritative.logicalBytes,
            allocatedBytes: authoritative.allocatedBytes,
            modificationDate: authoritative.modificationDate,
            classification: .removable(
                .completedOwnedWork,
                reason: "Caller-forged authority."
            )
        )
        XCTAssertThrowsError(
            try ProjectStorageCleanupReceiptWriter()
                .prepareConfirmedCleanup(try makeRequest(entry: forged))
        ) {
            guard case ProjectStorageCleanupPreparationError
                .selectionAuthorityChanged = $0 else {
                return XCTFail("Unexpected error: \($0)")
            }
        }

        try Data("second-longer".utf8).write(to: payload)
        XCTAssertThrowsError(
            try ProjectStorageCleanupReceiptWriter()
                .prepareConfirmedCleanup(
                    try makeRequest(entry: authoritative, cleanupID: UUID())
                )
        ) {
            guard case ProjectStorageCleanupPreparationError
                .selectionAuthorityChanged = $0 else {
                return XCTFail("Unexpected error: \($0)")
            }
        }

        let history = project.appendingPathComponent(
            ProjectOperationHistoryWriter.historyDirectoryName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: history,
            withIntermediateDirectories: true
        )
        let reserved = try forgedEntry(for: history, relativeTo: project)
        XCTAssertThrowsError(
            try ProjectStorageCleanupReceiptWriter()
                .prepareConfirmedCleanup(
                    try makeRequest(entry: reserved, cleanupID: UUID())
                )
        ) {
            guard case ProjectStorageCleanupPreparationError
                .selectionAuthorityChanged = $0 else {
                return XCTFail("Unexpected error: \($0)")
            }
        }

        let descendant = try forgedEntry(
            for: candidate.appendingPathComponent("nested"),
            relativeTo: project
        )
        XCTAssertThrowsError(
            try ProjectStorageCleanupReceiptWriter()
                .prepareConfirmedCleanup(
                    try makeRequest(
                        entries: [authoritative, descendant],
                        cleanupID: UUID()
                    )
                )
        ) {
            guard case ProjectStorageCleanupPreparationError
                .overlappingSelection = $0 else {
                return XCTFail("Unexpected error: \($0)")
            }
        }
    }

    func testAttestedGenerationAndHardLinkConflictsFailClosed() throws {
        let first = candidate.appendingPathComponent("first.bin")
        let second = candidate.appendingPathComponent("second.bin")
        try Data("original".utf8).write(to: first)
        var entry = try storageEntry(for: candidate)
        let stale = try attestedInventoryEntry(
            item: entry,
            fileURL: first,
            relativePath: "first.bin"
        )
        usleep(10_000)
        try Data("modified".utf8).write(to: first)
        XCTAssertThrowsError(
            try ProjectStorageCleanupReceiptWriter()
                .prepareConfirmedCleanup(
                    try makeRequest(
                        entry: entry,
                        attestedInventories: [
                            try trustedAttestation(
                                for: entry,
                                entries: [stale]
                            ),
                        ]
                    )
                )
        ) {
            guard case ProjectStorageCleanupPreparationError
                .invalidAttestation = $0 else {
                return XCTFail("Unexpected error: \($0)")
            }
        }

        entry = try storageEntry(for: candidate)
        XCTAssertEqual(Darwin.link(first.path, second.path), 0)
        entry = try storageEntry(for: candidate)
        let firstAttestation = try attestedInventoryEntry(
            item: entry,
            fileURL: first,
            relativePath: "first.bin"
        )
        let secondAttestation = ProjectStorageCleanupInventoryEntry(
            relativePath: "second.bin",
            logicalSize: firstAttestation.logicalSize,
            allocatedSize: firstAttestation.allocatedSize,
            sha256: String(repeating: "b", count: 64),
            device: firstAttestation.device,
            inode: firstAttestation.inode,
            modifiedSeconds: firstAttestation.modifiedSeconds,
            modifiedNanoseconds: firstAttestation.modifiedNanoseconds,
            changedSeconds: firstAttestation.changedSeconds,
            changedNanoseconds: firstAttestation.changedNanoseconds
        )
        XCTAssertThrowsError(
            try ProjectStorageCleanupReceiptWriter()
                .prepareConfirmedCleanup(
                    try makeRequest(
                        entry: entry,
                        cleanupID: UUID(),
                        attestedInventories: [
                            try trustedAttestation(
                                for: entry,
                                entries: [
                                    firstAttestation,
                                    secondAttestation,
                                ]
                            ),
                        ]
                    )
                )
        ) {
            guard case ProjectStorageCleanupPreparationError
                .invalidAttestation = $0 else {
                return XCTFail("Unexpected error: \($0)")
            }
        }
    }

    func testTraversalClosesSiblingDescriptorsAndCollisionFailsClosed()
        throws
    {
        for index in 0..<300 {
            let directory = candidate.appendingPathComponent(
                "sibling-\(index)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false
            )
            try Data([UInt8(index % 255)]).write(
                to: directory.appendingPathComponent("payload.bin")
            )
        }
        let entry = try storageEntry(for: candidate)
        let request = try makeRequest(entry: entry)
        let prepared = try ProjectStorageCleanupReceiptWriter()
            .prepareConfirmedCleanup(request)
        XCTAssertGreaterThanOrEqual(
            prepared.journal.items.singleValue?.inventory.count ?? 0,
            300
        )

        XCTAssertThrowsError(
            try ProjectStorageCleanupReceiptWriter()
                .prepareConfirmedCleanup(request)
        ) {
            guard case ProjectStorageCleanupPreparationError
                .operationAlreadyExists(let cleanupID) = $0 else {
                return XCTFail("Unexpected error: \($0)")
            }
            XCTAssertEqual(cleanupID, request.cleanupID)
        }
    }

    func testPostRenameParentFsyncFailureReportsPublishedUncertainty()
        throws
    {
        try Data("durable".utf8).write(
            to: candidate.appendingPathComponent("payload.txt")
        )
        let entry = try storageEntry(for: candidate)
        let request = try makeRequest(entry: entry)
        let publication = Flag()
        let writer = ProjectStorageCleanupReceiptWriter(
            operations: .init(
                beforePublish: { publication.set() },
                syncDirectory: {
                    if publication.value {
                        errno = EIO
                        return -1
                    }
                    return Darwin.fsync($0)
                }
            )
        )

        XCTAssertThrowsError(
            try writer.prepareConfirmedCleanup(request)
        ) {
            guard case ProjectStorageCleanupPreparationError
                .publicationDurabilityUncertain = $0 else {
                return XCTFail("Unexpected error: \($0)")
            }
        }
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath:
                    operationDirectory(
                        for: entry,
                        cleanupID: request.cleanupID
                    ).path
            )
        )
    }

    func testAttestationRequiresStableRealMatchingCanonicalProvenance()
        throws
    {
        let payload = candidate.appendingPathComponent("payload.txt")
        try Data("authority".utf8).write(to: payload)
        let entry = try storageEntry(for: candidate)
        let descriptor = try attestedInventoryEntry(
            item: entry,
            fileURL: payload,
            relativePath: "payload.txt"
        )
        let trusted = try trustedAttestation(
            for: entry,
            entries: [descriptor]
        )
        let nonexistent = ProjectStorageCleanupAttestedInventory(
            sourceRelativePath: entry.relativePath,
            sourceIdentity: entry.identity,
            sourceProvenancePath:
                project.appendingPathComponent("missing.json").path,
            sourceProvenanceChecksumSHA256:
                trusted.sourceProvenanceChecksumSHA256,
            sourceProvenanceFileSize: trusted.sourceProvenanceFileSize,
            entries: [descriptor]
        )
        XCTAssertThrowsError(
            try ProjectStorageCleanupReceiptWriter()
                .prepareConfirmedCleanup(
                    try makeRequest(
                        entry: entry,
                        attestedInventories: [nonexistent]
                    )
                )
        )

        for mismatched in [
            ProjectStorageCleanupAttestedInventory(
                sourceRelativePath: entry.relativePath,
                sourceIdentity: entry.identity,
                sourceProvenancePath: trusted.sourceProvenancePath,
                sourceProvenanceChecksumSHA256:
                    String(repeating: "f", count: 64),
                sourceProvenanceFileSize:
                    trusted.sourceProvenanceFileSize,
                entries: [descriptor]
            ),
            ProjectStorageCleanupAttestedInventory(
                sourceRelativePath: entry.relativePath,
                sourceIdentity: entry.identity,
                sourceProvenancePath: trusted.sourceProvenancePath,
                sourceProvenanceChecksumSHA256:
                    trusted.sourceProvenanceChecksumSHA256,
                sourceProvenanceFileSize:
                    trusted.sourceProvenanceFileSize + 1,
                entries: [descriptor]
            ),
        ] {
            XCTAssertThrowsError(
                try ProjectStorageCleanupReceiptWriter()
                    .prepareConfirmedCleanup(
                        try makeRequest(
                            entry: entry,
                            cleanupID: UUID(),
                            attestedInventories: [mismatched]
                        )
                    )
            )
        }

        let wrongMapping = ProjectStorageCleanupInventoryEntry(
            relativePath: descriptor.relativePath,
            logicalSize: descriptor.logicalSize,
            allocatedSize: descriptor.allocatedSize,
            sha256: String(repeating: "b", count: 64),
            device: descriptor.device,
            inode: descriptor.inode,
            modifiedSeconds: descriptor.modifiedSeconds,
            modifiedNanoseconds: descriptor.modifiedNanoseconds,
            changedSeconds: descriptor.changedSeconds,
            changedNanoseconds: descriptor.changedNanoseconds
        )
        let mappingMismatch = try trustedAttestation(
            for: entry,
            entries: [descriptor],
            provenanceEntries: [wrongMapping]
        )
        XCTAssertThrowsError(
            try ProjectStorageCleanupReceiptWriter()
                .prepareConfirmedCleanup(
                    try makeRequest(
                        entry: entry,
                        cleanupID: UUID(),
                        attestedInventories: [mappingMismatch]
                    )
                )
        )

        let provenanceData = try Data(
            contentsOf: URL(
                fileURLWithPath: trusted.sourceProvenancePath
            )
        )
        let swap = OnceAction {
            try provenanceData.write(
                to: URL(
                    fileURLWithPath: trusted.sourceProvenancePath
                ),
                options: .atomic
            )
        }
        let swappingWriter = ProjectStorageCleanupReceiptWriter(
            operations: .init(
                didReadAttestationProvenance: { _ in
                    try? swap.run()
                }
            )
        )
        XCTAssertThrowsError(
            try swappingWriter.prepareConfirmedCleanup(
                try makeRequest(
                    entry: entry,
                    cleanupID: UUID(),
                    attestedInventories: [trusted]
                )
            )
        )
    }

    func testPostCreateStagingFailureLeavesNoOrphan() throws {
        try Data("keep".utf8).write(
            to: candidate.appendingPathComponent("payload.txt")
        )
        let entry = try storageEntry(for: candidate)
        enum InjectedFailure: Error { case afterCreate }
        let writer = ProjectStorageCleanupReceiptWriter(
            operations: .init(
                afterCreateStaging: {
                    throw InjectedFailure.afterCreate
                }
            )
        )

        XCTAssertThrowsError(
            try writer.prepareConfirmedCleanup(
                try makeRequest(entry: entry)
            )
        )

        let collection = project
            .appendingPathComponent(
                ProjectOperationHistoryWriter.historyDirectoryName
            )
            .appendingPathComponent(
                ProjectStorageCleanupReceiptWriter.collectionDirectoryName
            )
        let children =
            (try? FileManager.default.contentsOfDirectory(
                atPath: collection.path
            )) ?? []
        XCTAssertTrue(children.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: candidate.path))
    }

    func testBeforePublishStagingReplacementFailsClosed() throws {
        try Data("keep".utf8).write(
            to: candidate.appendingPathComponent("payload.txt")
        )
        let entry = try storageEntry(for: candidate)
        let request = try makeRequest(entry: entry)
        let collection = try XCTUnwrap(project)
            .appendingPathComponent(
                ProjectOperationHistoryWriter.historyDirectoryName,
                isDirectory: true
            )
            .appendingPathComponent(
                ProjectStorageCleanupReceiptWriter.collectionDirectoryName,
                isDirectory: true
            )
        let stagingPrefix =
            ".\(request.cleanupID.uuidString.lowercased()).staging-"
        let displaced = collection.appendingPathComponent(
            "displaced-staging",
            isDirectory: true
        )
        let replaced = Flag()
        let writer = ProjectStorageCleanupReceiptWriter(
            operations: .init(
                beforePublish: {
                    let name = try FileManager.default
                        .contentsOfDirectory(atPath: collection.path)
                        .first {
                            $0.hasPrefix(stagingPrefix)
                        }
                    let staging = collection.appendingPathComponent(
                        try XCTUnwrap(name),
                        isDirectory: true
                    )
                    try FileManager.default.moveItem(
                        at: staging,
                        to: displaced
                    )
                    try FileManager.default.createDirectory(
                        at: staging,
                        withIntermediateDirectories: false
                    )
                    replaced.set()
                }
            )
        )

        XCTAssertThrowsError(
            try writer.prepareConfirmedCleanup(request)
        )
        XCTAssertTrue(replaced.value)
    }

    func testInventoryParameterValuePreservesLargeUnsignedValuesAsDecimalStrings()
        throws
    {
        let exFATInode: UInt64 = 18_446_744_073_709_486_468
        let inventory = ProjectStorageCleanupInventoryEntry(
            relativePath: "huge.bin",
            logicalSize: UInt64.max,
            allocatedSize: 0,
            sha256: String(repeating: "a", count: 64),
            device: 1,
            inode: exFATInode,
            modifiedSeconds: 3,
            modifiedNanoseconds: 4,
            changedSeconds: 5,
            changedNanoseconds: 6
        )

        let values = try XCTUnwrap(
            inventory.parameterValue().dictionaryValue
        )
        XCTAssertEqual(values["logicalSize"], .string(String(UInt64.max)))
        XCTAssertEqual(values["inode"], .string(String(exFATInode)))
        XCTAssertEqual(values["device"], .integer(1))
    }

    func testDirectoryLinkCountAllowsExFATSemanticsOnlyForExFAT() {
        XCTAssertTrue(
            projectStorageDirectoryLinkCountIsPlausible(
                1,
                fileSystemType: "exfat"
            )
        )
        XCTAssertTrue(
            projectStorageDirectoryLinkCountIsPlausible(
                2,
                fileSystemType: "apfs"
            )
        )
        XCTAssertFalse(
            projectStorageDirectoryLinkCountIsPlausible(
                1,
                fileSystemType: "apfs"
            )
        )
        XCTAssertFalse(
            projectStorageDirectoryLinkCountIsPlausible(
                0,
                fileSystemType: "exfat"
            )
        )
    }

    private func makeRequest(
        entry: ProjectStorageEntry,
        cleanupID: UUID = UUID(),
        startedAt: Date = Date(timeIntervalSince1970: 100),
        attestedInventories: [ProjectStorageCleanupAttestedInventory] = []
    ) throws -> ProjectStorageCleanupPreparationRequest {
        try makeRequest(
            entries: [entry],
            cleanupID: cleanupID,
            startedAt: startedAt,
            attestedInventories: attestedInventories
        )
    }

    private func makeRequest(
        entries: [ProjectStorageEntry],
        cleanupID: UUID,
        startedAt: Date = Date(timeIntervalSince1970: 100),
        attestedInventories: [ProjectStorageCleanupAttestedInventory] = []
    ) throws -> ProjectStorageCleanupPreparationRequest {
        ProjectStorageCleanupPreparationRequest(
            cleanupID: cleanupID,
            projectURL: project,
            projectIdentity: try FileSystemObjectIdentity.noFollow(project),
            selectedEntries: entries,
            attestedInventories: attestedInventories,
            workflowName: "Project Storage Cleanup",
            workflowVersion: "7.2.0",
            toolName: "lungfish-project-storage",
            toolVersion: "7.2.0",
            argv: [
                "lungfish-project-storage",
                "prepare",
                project.path,
            ] + entries.map(\.relativePath),
            durableReplayArgv: [
                "lungfish-project-storage",
                "prepare",
                project.path,
            ] + entries.map(\.relativePath),
            options: ProvenanceOptions(
                explicit: ["reviewed": .boolean(true)],
                defaults: ["action": .string("trash")],
                resolvedDefaults: [
                    "permanentDeleteFallback": .boolean(false),
                ]
            ),
            runtimeIdentity: ProvenanceRuntimeIdentity(
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
            ),
            startedAt: startedAt
        )
    }

    private func storageEntry(for url: URL) throws -> ProjectStorageEntry {
        let relativePath = String(
            url.path.dropFirst(project.path.count + 1)
        )
        return try XCTUnwrap(
            ProjectStorageScanner().scan(projectURL: project)
                .entries.first { $0.relativePath == relativePath }
        )
    }

    private func attestedInventoryEntry(
        item: ProjectStorageEntry,
        fileURL: URL,
        relativePath: String
    ) throws -> ProjectStorageCleanupInventoryEntry {
        var info = stat()
        XCTAssertEqual(Darwin.lstat(fileURL.path, &info), 0)
        return ProjectStorageCleanupInventoryEntry(
            relativePath: relativePath,
            logicalSize: UInt64(info.st_size),
            allocatedSize: UInt64(info.st_blocks) * 512,
            sha256: try ProvenanceFileHasher.sha256(of: fileURL),
            device: UInt64(info.st_dev),
            inode: UInt64(info.st_ino),
            modifiedSeconds: Int64(info.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec),
            changedSeconds: Int64(info.st_ctimespec.tv_sec),
            changedNanoseconds: Int64(info.st_ctimespec.tv_nsec)
        )
    }

    private func trustedAttestation(
        for entry: ProjectStorageEntry,
        entries: [ProjectStorageCleanupInventoryEntry],
        provenanceEntries:
            [ProjectStorageCleanupInventoryEntry]? = nil
    ) throws -> ProjectStorageCleanupAttestedInventory {
        let provenanceURL = project.appendingPathComponent(
            "trusted-provenance-\(UUID().uuidString).json"
        )
        let descriptors = (provenanceEntries ?? entries).map {
            ProvenanceFileDescriptor(
                path: candidate.appendingPathComponent(
                    $0.relativePath
                ).standardizedFileURL.path,
                checksumSHA256: $0.sha256,
                fileSize: $0.logicalSize,
                role: .input
            )
        }
        let envelope = ProvenanceEnvelope(
            workflowName: "Trusted Cleanup Attestation",
            workflowVersion: "1",
            toolName: "cleanup-attestation-test",
            toolVersion: "1",
            argv: ["cleanup-attestation-test"],
            files: descriptors,
            exitStatus: 0
        )
        let data = try ProvenanceJSON.encoder.encode(envelope)
        try data.write(to: provenanceURL, options: .atomic)
        return .init(
            sourceRelativePath: entry.relativePath,
            sourceIdentity: entry.identity,
            sourceProvenancePath: provenanceURL.path,
            sourceProvenanceChecksumSHA256:
                ProvenanceSigningPayload.sha256Hex(data),
            sourceProvenanceFileSize: UInt64(data.count),
            entries: entries
        )
    }

    private func forgedEntry(
        for url: URL,
        relativeTo project: URL
    ) throws -> ProjectStorageEntry {
        var projectInformation = stat()
        XCTAssertEqual(Darwin.lstat(project.path, &projectInformation), 0)
        var information = stat()
        XCTAssertEqual(Darwin.lstat(url.path, &information), 0)
        return .init(
            projectIdentity: FileSystemObjectIdentity(
                from: projectInformation
            ),
            relativePath: String(
                url.path.dropFirst(project.path.count + 1)
            ),
            identity: FileSystemObjectIdentity(from: information),
            category: .temporary,
            logicalBytes: UInt64(max(information.st_size, 0)),
            allocatedBytes: UInt64(max(information.st_blocks, 0)) * 512,
            modificationDate: Date(
                timeIntervalSince1970:
                    TimeInterval(information.st_mtimespec.tv_sec)
                    + TimeInterval(information.st_mtimespec.tv_nsec)
                        / 1_000_000_000
            ),
            classification: .removable(
                .completedOwnedWork,
                reason: "Caller-forged authority."
            )
        )
    }

    private func operationDirectory(
        for entry: ProjectStorageEntry,
        cleanupID: UUID
    ) -> URL {
        project
            .appendingPathComponent(
                ProjectOperationHistoryWriter.historyDirectoryName,
                isDirectory: true
            )
            .appendingPathComponent(
                "storage-cleanups",
                isDirectory: true
            )
            .appendingPathComponent(
                cleanupID.uuidString.lowercased(),
                isDirectory: true
            )
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
}

private final class OnceAction: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (() throws -> Void)?

    init(_ action: @escaping () throws -> Void) {
        self.action = action
    }

    func run() throws {
        lock.lock()
        let current = action
        action = nil
        lock.unlock()
        try current?()
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

private extension Array {
    var singleValue: Element? {
        count == 1 ? first : nil
    }
}
