import CryptoKit
import Foundation
import LungfishIO
import LungfishTestSupport
import XCTest
@testable import LungfishWorkflow

final class ProjectStorageCleanupPreparationLargeTreeTests: XCTestCase {
    func testLargePreparationReusesAttestedDescriptorsAndHashesEachUnattestedInodeOnce()
        throws
    {
        let context = try makePreparationContext(includeHardLink: true)
        defer { try? FileManager.default.removeItem(at: context.project) }
        let hashed = PreparationStringRecorder()
        let reused = PreparationStringRecorder()
        let events = PreparationEventRecorder()
        let request = try makeRequest(
            context,
            attestedInventories: [
                try trustedAttestation(
                    context,
                    entries: [try inventoryEntry(for: context.sparse)]
                )
            ]
        )
        let writer = ProjectStorageCleanupReceiptWriter(
            operations: .init(
                didHashRelativePath: hashed.append,
                didReadAttestationProvenance: reused.append,
                authoritativeScan: { _ in
                    .init(
                        projectIdentity: context.projectIdentity,
                        entries: [context.entry]
                    )
                },
                instrumentation: .init(record: events.record)
            )
        )

        let prepared = try writer.prepareConfirmedCleanup(request)

        let expectedUnattested = try regularFileIdentities(
            under: context.candidate,
            excludingRelativePaths: [
                "large-sparse.bin",
            ]
        )
        let actualHashed = try hashed.values.map {
            try regularFileIdentity(
                context.candidate.appendingPathComponent($0)
            )
        }
        let missingHashPaths = expectedUnattested.filter {
            !Set(actualHashed).contains($0.key)
        }.values.flatMap { $0 }.sorted()
        XCTAssertEqual(
            actualHashed.count,
            expectedUnattested.count,
            "Missing hash paths: \(missingHashPaths)"
        )
        XCTAssertEqual(
            Set(actualHashed),
            Set(expectedUnattested.keys),
            "Missing hash paths: \(missingHashPaths)"
        )
        XCTAssertEqual(
            Array(
                Dictionary(grouping: actualHashed, by: { $0 })
                    .mapValues(\.count)
                    .values
            ).sorted(),
            Array(repeating: 1, count: expectedUnattested.count)
        )
        let hardLinkIdentity = try regularFileIdentity(
            context.candidate.appendingPathComponent(
                "hard-link-source.bin"
            )
        )
        XCTAssertEqual(
            actualHashed.filter { $0 == hardLinkIdentity }.count,
            1
        )
        XCTAssertFalse(hashed.values.contains("large-sparse.bin"))
        XCTAssertEqual(
            reused.values,
            [request.attestedInventories[0].sourceProvenancePath]
        )
        let counts = preparationCounterValues(events.snapshot)
        XCTAssertGreaterThan(try XCTUnwrap(counts[.reusedHashes]), 0)
        XCTAssertGreaterThan(try XCTUnwrap(counts[.computedHashes]), 0)
        XCTAssertEqual(
            prepared.journal.items[0].inventory.filter {
                $0.relativePath == "hard-link-source.bin"
                    || $0.relativePath == "hard-link-copy.bin"
            }.map(\.sha256).uniqued.count,
            1
        )
        let sparseDescriptor = try XCTUnwrap(
            prepared.journal.items[0].inventory.first {
                $0.relativePath == "large-sparse.bin"
            }
        )
        let attestedSparse = try XCTUnwrap(
            request.attestedInventories[0].entries.first
        )
        XCTAssertEqual(
            attestedSparse.sha256,
            try independentSHA256(context.sparse)
        )
        XCTAssertEqual(sparseDescriptor, attestedSparse)
    }

    func testLargePreparationCancellationBeforePublicationMutatesNoSelectedRoot()
        throws
    {
        let context = try makePreparationContext(includeHardLink: false)
        defer { try? FileManager.default.removeItem(at: context.project) }
        let history = context.project.appendingPathComponent(
            ProjectOperationHistoryWriter.historyDirectoryName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: history,
            withIntermediateDirectories: true
        )
        let priorEvidence = history.appendingPathComponent("prior-evidence.json")
        try Data("prior".utf8).write(to: priorEvidence)
        let before = try preparationSnapshot(context.candidate)
        let beforeHistory = try preparationSnapshot(history)
        let hashCount = PreparationIntegerRecorder()
        let writer = ProjectStorageCleanupReceiptWriter(
            operations: .init(
                cancellationCheck: {
                    if hashCount.value >= 64 {
                        throw CancellationError()
                    }
                },
                didHashRelativePath: { _ in hashCount.increment() },
                authoritativeScan: { _ in
                    .init(
                        projectIdentity: context.projectIdentity,
                        entries: [context.entry]
                    )
                }
            )
        )
        let request = try makeRequest(
            context,
            attestedInventories: [
                try trustedAttestation(
                    context,
                    entries: [try inventoryEntry(for: context.sparse)]
                )
            ]
        )

        XCTAssertThrowsError(try writer.prepareConfirmedCleanup(request)) {
            XCTAssertTrue($0 is CancellationError)
        }

        XCTAssertEqual(try preparationSnapshot(context.candidate), before)
        XCTAssertEqual(try preparationSnapshot(history), beforeHistory)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: operationDirectory(context, request.cleanupID).path
            )
        )
    }

    func testLargePreparationEmitsBalancedDescriptorPreparationInstrumentation()
        throws
    {
        let project = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ProjectStorageCleanupPreparationLargeTreeTests-"
                    + UUID().uuidString,
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: project) }
        let source = project.appendingPathComponent(
            ".tmp/preparation",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: source,
            withIntermediateDirectories: true
        )
        for index in 0..<128 {
            try Data("payload-\(index)".utf8).write(
                to: source.appendingPathComponent("file-\(index)")
            )
        }
        let projectIdentity = try FileSystemObjectIdentity.noFollow(project)
        let entry = ProjectStorageEntry(
            projectIdentity: projectIdentity,
            relativePath: ".tmp/preparation",
            identity: try FileSystemObjectIdentity.noFollow(source),
            category: .temporary,
            logicalBytes: 0,
            allocatedBytes: 0,
            modificationDate: Date(timeIntervalSince1970: 0),
            classification: .removable(
                .completedOwnedWork,
                reason: "Test-owned completed work."
            )
        )
        let events = PreparationEventRecorder()
        let writer = ProjectStorageCleanupReceiptWriter(
            operations: .init(
                authoritativeScan: { _ in
                    ProjectStorageScanResult(
                        projectIdentity: projectIdentity,
                        entries: [entry]
                    )
                },
                instrumentation: .init(record: events.record)
            )
        )
        let request = ProjectStorageCleanupPreparationRequest(
            cleanupID: UUID(),
            projectURL: project,
            projectIdentity: projectIdentity,
            selectedEntries: [entry],
            workflowName: "Project Storage Cleanup",
            workflowVersion: "1",
            toolName: "lungfish-project-storage",
            toolVersion: "1",
            argv: ["lungfish-project-storage", "prepare", project.path],
            durableReplayArgv: nil,
            options: .init(),
            runtimeIdentity: .init(appVersion: "1"),
            startedAt: Date()
        )

        _ = try writer.prepareConfirmedCleanup(request)

        let snapshot = events.snapshot
        try assertBalancedPreparation(snapshot, outcome: .success)
        XCTAssertTrue(
            snapshot.contains {
                guard case .counted(
                    .computedHashes,
                    128,
                    intervalID: _
                ) = $0 else {
                    return false
                }
                return true
            }
        )

        let cancelledEvents = PreparationEventRecorder()
        let cancelling = ProjectStorageCleanupReceiptWriter(
            operations: .init(
                cancellationCheck: { throw CancellationError() },
                instrumentation: .init(record: cancelledEvents.record)
            )
        )
        XCTAssertThrowsError(
            try cancelling.prepareConfirmedCleanup(request)
        ) {
            XCTAssertTrue($0 is CancellationError)
        }
        try assertBalancedPreparation(
            cancelledEvents.snapshot,
            outcome: .cancelled
        )

        let failureEvents = PreparationEventRecorder()
        let failing = ProjectStorageCleanupReceiptWriter(
            operations: .init(
                instrumentation: .init(record: failureEvents.record)
            )
        )
        let emptyRequest = ProjectStorageCleanupPreparationRequest(
            cleanupID: UUID(),
            projectURL: project,
            projectIdentity: projectIdentity,
            selectedEntries: [],
            workflowName: "Project Storage Cleanup",
            workflowVersion: "1",
            toolName: "lungfish-project-storage",
            toolVersion: "1",
            argv: ["lungfish-project-storage", "prepare", project.path],
            durableReplayArgv: nil,
            options: .init(),
            runtimeIdentity: .init(appVersion: "1"),
            startedAt: Date()
        )
        XCTAssertThrowsError(
            try failing.prepareConfirmedCleanup(emptyRequest)
        )
        try assertBalancedPreparation(
            failureEvents.snapshot,
            outcome: .failure
        )
    }

    func testLargePreparationWritesCompleteCanonicalProvenance() throws {
        let context = try makePreparationContext(includeHardLink: false)
        defer { try? FileManager.default.removeItem(at: context.project) }
        let started = Date(timeIntervalSince1970: 1_000)
        let completed = Date(timeIntervalSince1970: 1_004.5)
        let request = try makeRequest(
            context,
            startedAt: started,
            attestedInventories: [
                try trustedAttestation(
                    context,
                    entries: [try inventoryEntry(for: context.sparse)]
                )
            ]
        )
        let writer = ProjectStorageCleanupReceiptWriter(
            operations: .init(
                cancellationCheck: {},
                now: { completed },
                authoritativeScan: { _ in
                    .init(
                        projectIdentity: context.projectIdentity,
                        entries: [context.entry]
                    )
                }
            )
        )

        let prepared = try writer.prepareConfirmedCleanup(request)
        let data = try Data(contentsOf: prepared.provenanceURL)
        let provenance = try ProvenanceEnvelopeReader.decodeCanonical(data)

        XCTAssertEqual(try ProvenanceJSON.encoder.encode(provenance), data)
        XCTAssertEqual(provenance.workflowName, request.workflowName)
        XCTAssertEqual(provenance.workflowVersion, request.workflowVersion)
        XCTAssertEqual(provenance.toolName, request.toolName)
        XCTAssertEqual(provenance.toolVersion, request.toolVersion)
        XCTAssertEqual(provenance.argv, request.argv)
        XCTAssertEqual(provenance.durableReplayArgv, request.durableReplayArgv)
        XCTAssertFalse(provenance.reproducibleCommand.isEmpty)
        XCTAssertEqual(provenance.options.explicit["reviewed"], .boolean(true))
        XCTAssertEqual(provenance.options.defaults["action"], .string("trash"))
        XCTAssertEqual(
            provenance.options.resolvedDefaults["permanentDeleteFallback"],
            .boolean(false)
        )
        XCTAssertEqual(
            provenance.options.explicit["selectedPaths"],
            .array([.string(context.entry.relativePath)])
        )
        XCTAssertEqual(
            provenance.options.explicit["intendedAction"],
            .string("move-to-trash")
        )
        let expectedInventory = ParameterValue.array(
            try prepared.journal.items.map { try $0.parameterValue() }
        )
        XCTAssertEqual(
            provenance.options.resolvedDefaults["cleanupInventory"],
            expectedInventory
        )
        XCTAssertEqual(
            provenance.options.resolvedDefaults["hashAlgorithm"],
            .string("sha256")
        )
        XCTAssertEqual(provenance.runtimeIdentity, request.runtimeIdentity)
        XCTAssertEqual(provenance.exitStatus, 0)
        XCTAssertEqual(provenance.wallTimeSeconds, 4.5)
        XCTAssertEqual(provenance.stderr, "")
        XCTAssertEqual(provenance.output?.path, prepared.journalURL.path)
        XCTAssertEqual(provenance.outputs.map(\.path), [prepared.journalURL.path])
        XCTAssertEqual(provenance.steps.count, 1)
        XCTAssertEqual(provenance.steps[0].toolName, request.toolName)
        XCTAssertEqual(provenance.steps[0].toolVersion, request.toolVersion)
        XCTAssertEqual(provenance.steps[0].argv, request.argv)
        XCTAssertEqual(
            provenance.steps[0].durableReplayArgv,
            request.durableReplayArgv
        )
        XCTAssertEqual(
            provenance.steps[0].reproducibleCommand,
            provenance.reproducibleCommand
        )
        var expectedExplicitOptions = request.options.explicit
        expectedExplicitOptions["projectRoot"] =
            .string(context.project.path)
        expectedExplicitOptions["selectedPaths"] =
            .array([.string(context.entry.relativePath)])
        expectedExplicitOptions["intendedAction"] =
            .string("move-to-trash")
        XCTAssertEqual(
            provenance.options.explicit,
            expectedExplicitOptions
        )
        XCTAssertEqual(provenance.options.defaults, request.options.defaults)
        var expectedResolvedDefaults = request.options.resolvedDefaults
        expectedResolvedDefaults["cleanupInventory"] = expectedInventory
        expectedResolvedDefaults["hashAlgorithm"] = .string("sha256")
        expectedResolvedDefaults["permanentDeleteFallback"] =
            .boolean(false)
        XCTAssertEqual(
            provenance.options.resolvedDefaults,
            expectedResolvedDefaults
        )
        var expectedResolvedOptions = request.options.defaults
        expectedResolvedOptions.merge(
            expectedResolvedDefaults
        ) { _, new in new }
        expectedResolvedOptions.merge(
            expectedExplicitOptions
        ) { _, new in new }
        XCTAssertEqual(
            provenance.steps[0].resolvedOptions,
            expectedResolvedOptions
        )
        XCTAssertEqual(
            provenance.steps[0].runtimeIdentity,
            request.runtimeIdentity
        )
        XCTAssertEqual(provenance.steps[0].inputs, provenance.files)
        XCTAssertEqual(provenance.steps[0].outputs, provenance.outputs)
        XCTAssertEqual(provenance.steps[0].exitStatus, 0)
        XCTAssertEqual(provenance.steps[0].wallTimeSeconds, 4.5)
        XCTAssertEqual(provenance.steps[0].stderr, "")
        XCTAssertTrue(
            provenance.files.allSatisfy {
                $0.checksumSHA256?.count == 64
                    && $0.fileSize != nil
            }
        )
        let expectedInputPaths = (
            request.attestedInventories.map(\.sourceProvenancePath)
                + prepared.journal.items.flatMap { item in
                    item.inventory.map {
                        context.project.appendingPathComponent(
                            item.sourceRelativePath
                        ).appendingPathComponent($0.relativePath).path
                    }
                }
        ).sorted()
        XCTAssertEqual(
            provenance.files.map(\.path),
            expectedInputPaths
        )
        let descriptors = prepared.journal.items[0].inventory
        XCTAssertEqual(descriptors.map(\.relativePath), descriptors.map(\.relativePath).sorted())
        XCTAssertTrue(descriptors.allSatisfy { $0.sha256.count == 64 })
        XCTAssertTrue(
            provenance.options.explicit["projectRoot"]
                == .string(context.project.path)
        )
        XCTAssertTrue(
            prepared.operationDirectoryURL.path.hasPrefix(
                context.project.path + "/"
            )
        )
        XCTAssertEqual(prepared.journalURL.deletingLastPathComponent(), prepared.operationDirectoryURL)
        XCTAssertEqual(prepared.provenanceURL.deletingLastPathComponent(), prepared.operationDirectoryURL)
        XCTAssertEqual(
            prepared.operationDirectoryURL,
            operationDirectory(context, request.cleanupID)
        )
        XCTAssertEqual(
            prepared.journalURL.lastPathComponent,
            ProjectStorageCleanupReceiptWriter.journalFileName
        )
        XCTAssertEqual(
            prepared.provenanceURL.lastPathComponent,
            ProjectStorageCleanupReceiptWriter.provenanceFileName
        )
        let journalData = try Data(contentsOf: prepared.journalURL)
        let output = try XCTUnwrap(provenance.output)
        XCTAssertEqual(output.path, prepared.journalURL.path)
        XCTAssertEqual(output.fileSize, UInt64(journalData.count))
        XCTAssertEqual(
            output.checksumSHA256,
            ProvenanceSigningPayload.sha256Hex(journalData)
        )
        let encodedText = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(encodedText.contains(".staging-"))
        XCTAssertFalse(encodedText.contains("staging-"))
        XCTAssertTrue(
            (provenance.files + provenance.outputs).allSatisfy {
                !$0.path.contains(".staging-")
                    && !$0.path.contains("/staging/")
            }
        )
    }

    private func assertBalancedPreparation(
        _ events: [ProjectStorageInstrumentation.Event],
        outcome: ProjectStorageInstrumentation.Outcome,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let intervals = events.compactMap {
            event -> ProjectStorageInstrumentation.Interval? in
            guard case .began(let interval) = event,
                  interval.phase == .descriptorPreparation else {
                return nil
            }
            return interval
        }
        XCTAssertEqual(intervals.count, 1, file: file, line: line)
        let interval = try XCTUnwrap(
            intervals.first,
            file: file,
            line: line
        )
        XCTAssertEqual(
            events.filter {
                guard case .ended(let ended, let actualOutcome) = $0 else {
                    return false
                }
                return ended == interval && actualOutcome == outcome
            }.count,
            1,
            file: file,
            line: line
        )
        XCTAssertEqual(
            events.filter {
                guard case .ended(let ended, _) = $0 else {
                    return false
                }
                return ended.id == interval.id
            }.count,
            1,
            file: file,
            line: line
        )
        for counter in [
            ProjectStorageInstrumentation.Counter.reusedHashes,
            .computedHashes,
        ] {
            XCTAssertEqual(
                events.filter {
                    guard case .counted(
                        let actualCounter,
                        _,
                        intervalID: let intervalID
                    ) = $0 else {
                        return false
                    }
                    return actualCounter == counter
                        && intervalID == interval.id
                }.count,
                1,
                file: file,
                line: line
            )
        }
    }

    private struct PreparationContext {
        let project: URL
        let candidate: URL
        let sparse: URL
        let projectIdentity: FileSystemObjectIdentity
        let entry: ProjectStorageEntry
    }

    private func makePreparationContext(
        includeHardLink: Bool
    ) throws -> PreparationContext {
        let project = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ProjectStoragePreparation-\(UUID().uuidString)",
                isDirectory: true
            )
        let candidate = project.appendingPathComponent(
            ".tmp/preparation",
            isDirectory: true
        )
        var succeeded = false
        defer {
            if !succeeded {
                try? FileManager.default.removeItem(at: project)
            }
        }
        try FileManager.default.createDirectory(
            at: candidate,
            withIntermediateDirectories: true
        )
        for index in 0..<128 {
            try Data("payload-\(index)".utf8).write(
                to: candidate.appendingPathComponent(
                    String(format: "payload-%04d.bin", index)
                )
            )
        }
        let hardLinkSource = candidate.appendingPathComponent(
            "hard-link-source.bin"
        )
        try Data(repeating: 0x5a, count: 16_384).write(to: hardLinkSource)
        if includeHardLink {
            let copy = candidate.appendingPathComponent("hard-link-copy.bin")
            if Darwin.link(hardLinkSource.path, copy.path) != 0 {
                let code = errno
                if [EOPNOTSUPP, ENOTSUP, EXDEV].contains(code) {
                    throw XCTSkip(hardLinkSkipReason(code))
                }
                throw POSIXError(.init(rawValue: code) ?? .EIO)
            }
        }
        let sparse = candidate.appendingPathComponent("large-sparse.bin")
        let descriptor = Darwin.open(
            sparse.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.ftruncate(descriptor, 64 * 1_024 * 1_024) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        try OwnedWorkDirectoryMarkerStore.bindExistingDirectory(
            candidate,
            request: .init(
                projectURL: project,
                parentDirectoryURL: candidate.deletingLastPathComponent(),
                prefix: "unused-",
                runID: UUID(uuidString: "00000000-0000-0000-0000-000000000009")!,
                processIdentity: .init(
                    processIdentifier: 1,
                    processStartTime: 1,
                    bootSessionID: "storage-task9"
                ),
                state: .completed,
                lockRelativePath: nil,
                keepIntermediates: false,
                toolName: "storage-task9-fixture",
                toolVersion: "1"
            )
        )
        let scan = try ProjectStorageScanner().scan(projectURL: project)
        let context = PreparationContext(
            project: project,
            candidate: candidate,
            sparse: sparse,
            projectIdentity: scan.projectIdentity,
            entry: try XCTUnwrap(
                scan.entries.first {
                    $0.relativePath == ".tmp/preparation"
                }
            )
        )
        succeeded = true
        return context
    }

    private func makeRequest(
        _ context: PreparationContext,
        startedAt: Date = Date(timeIntervalSince1970: 1_000),
        attestedInventories: [ProjectStorageCleanupAttestedInventory] = []
    ) throws -> ProjectStorageCleanupPreparationRequest {
        .init(
            cleanupID: UUID(),
            projectURL: context.project,
            projectIdentity: context.projectIdentity,
            selectedEntries: [context.entry],
            attestedInventories: attestedInventories,
            workflowName: "Project Storage Cleanup",
            workflowVersion: "9.0.0",
            toolName: "lungfish-project-storage",
            toolVersion: "9.0.0",
            argv: [
                "lungfish-project-storage",
                "prepare",
                context.project.path,
                context.entry.relativePath,
            ],
            durableReplayArgv: [
                "lungfish-project-storage",
                "prepare",
                context.project.path,
                context.entry.relativePath,
            ],
            options: .init(
                explicit: ["reviewed": .boolean(true)],
                defaults: ["action": .string("trash")],
                resolvedDefaults: [
                    "permanentDeleteFallback": .boolean(false)
                ]
            ),
            runtimeIdentity: .init(
                appVersion: "9.0.0",
                executablePath: "/Applications/Lungfish.app/Lungfish",
                processIdentifier: 99,
                operatingSystemVersion: "macOS",
                architecture: "arm64",
                gitRevision: "task9",
                user: "analyst",
                condaEnvironment: "storage-verification",
                condaPrefix: "/opt/conda/envs/storage-verification",
                pluginPack: "builtin",
                containerImage: "lungfish/storage-verification:9",
                containerDigest: "sha256:" + String(repeating: "b", count: 64)
            ),
            startedAt: startedAt
        )
    }

    private func inventoryEntry(
        for url: URL
    ) throws -> ProjectStorageCleanupInventoryEntry {
        var information = stat()
        guard Darwin.lstat(url.path, &information) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        return .init(
            relativePath: url.lastPathComponent,
            logicalSize: UInt64(information.st_size),
            allocatedSize: UInt64(information.st_blocks) * 512,
            sha256: try independentSHA256(url),
            device: UInt64(information.st_dev),
            inode: UInt64(information.st_ino),
            modifiedSeconds: Int64(information.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(information.st_mtimespec.tv_nsec),
            changedSeconds: Int64(information.st_ctimespec.tv_sec),
            changedNanoseconds: Int64(information.st_ctimespec.tv_nsec)
        )
    }

    private func trustedAttestation(
        _ context: PreparationContext,
        entries: [ProjectStorageCleanupInventoryEntry]
    ) throws -> ProjectStorageCleanupAttestedInventory {
        let provenanceURL = context.project.appendingPathComponent(
            "trusted-sparse-provenance.json"
        )
        let envelope = ProvenanceEnvelope(
            workflowName: "Trusted Sparse Fixture",
            workflowVersion: "1",
            toolName: "storage-task9-attestation",
            toolVersion: "1",
            argv: ["storage-task9-attestation"],
            files: entries.map {
                .init(
                    path: context.candidate.appendingPathComponent(
                        $0.relativePath
                    ).path,
                    checksumSHA256: $0.sha256,
                    fileSize: $0.logicalSize,
                    role: .input
                )
            },
            exitStatus: 0
        )
        let data = try ProvenanceJSON.encoder.encode(envelope)
        try data.write(to: provenanceURL)
        return .init(
            sourceRelativePath: context.entry.relativePath,
            sourceIdentity: context.entry.identity,
            sourceProvenancePath: provenanceURL.path,
            sourceProvenanceChecksumSHA256:
                ProvenanceSigningPayload.sha256Hex(data),
            sourceProvenanceFileSize: UInt64(data.count),
            entries: entries
        )
    }

    private func independentSHA256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map {
            String(format: "%02x", $0)
        }.joined()
    }

    private func preparationSnapshot(
        _ root: URL
    ) throws -> [String: String] {
        let canonicalRoot = URL(
            fileURLWithPath: canonicalPlatformPath(root.path),
            isDirectory: true
        )
        var snapshot: [String: String] = [:]
        snapshot["."] = try snapshotRecord(canonicalRoot)
        guard let enumerator = FileManager.default.enumerator(
            at: canonicalRoot,
            includingPropertiesForKeys: nil
        ) else {
            return snapshot
        }
        while let url = enumerator.nextObject() as? URL {
            let relative = String(
                url.path.dropFirst(canonicalRoot.path.count + 1)
            )
            snapshot[relative] = try snapshotRecord(url)
        }
        return snapshot
    }

    private func snapshotRecord(_ url: URL) throws -> String {
        var information = stat()
        guard Darwin.lstat(url.path, &information) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        let checksum: String
        if information.st_mode & S_IFMT == S_IFREG,
           information.st_blocks > 0,
           information.st_size < 1_048_576 {
            let digest = SHA256.hash(data: try Data(contentsOf: url))
            checksum = digest.map { String(format: "%02x", $0) }.joined()
        } else {
            checksum = "-"
        }
        return "\(url.path):\(information.st_dev):\(information.st_ino):"
            + "\(information.st_mode):\(information.st_size):"
            + "\(information.st_blocks):"
            + "\(information.st_mtimespec.tv_sec):"
            + "\(information.st_mtimespec.tv_nsec):"
            + "\(information.st_ctimespec.tv_sec):"
            + "\(information.st_ctimespec.tv_nsec):\(checksum)"
    }

    private struct RegularIdentity: Hashable {
        let device: UInt64
        let inode: UInt64
    }

    private func regularFileIdentity(_ url: URL) throws -> RegularIdentity {
        var information = stat()
        guard Darwin.lstat(url.path, &information) == 0,
              information.st_mode & S_IFMT == S_IFREG else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        return .init(
            device: UInt64(information.st_dev),
            inode: UInt64(information.st_ino)
        )
    }

    private func regularFileIdentities(
        under root: URL,
        excludingRelativePaths: Set<String>
    ) throws -> [RegularIdentity: [String]] {
        let canonicalRoot = URL(
            fileURLWithPath: canonicalPlatformPath(root.path),
            isDirectory: true
        )
        guard let enumerator = FileManager.default.enumerator(
            at: canonicalRoot,
            includingPropertiesForKeys: nil
        ) else {
            throw CocoaError(.fileReadUnknown)
        }
        var result: [RegularIdentity: [String]] = [:]
        while let url = enumerator.nextObject() as? URL {
            let relative = String(
                url.path.dropFirst(canonicalRoot.path.count + 1)
            )
            guard !excludingRelativePaths.contains(relative) else {
                continue
            }
            var information = stat()
            guard Darwin.lstat(url.path, &information) == 0 else {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
            guard information.st_mode & S_IFMT == S_IFREG else {
                continue
            }
            let identity = RegularIdentity(
                device: UInt64(information.st_dev),
                inode: UInt64(information.st_ino)
            )
            result[identity, default: []].append(relative)
        }
        return result
    }

    private func canonicalPlatformPath(_ path: String) -> String {
        let standardized = NSString(string: path).standardizingPath
        if standardized == "/var" || standardized.hasPrefix("/var/") {
            return "/private" + standardized
        }
        if standardized == "/tmp" || standardized.hasPrefix("/tmp/") {
            return "/private" + standardized
        }
        return standardized
    }

    private func operationDirectory(
        _ context: PreparationContext,
        _ cleanupID: UUID
    ) -> URL {
        context.project.appendingPathComponent(
            ProjectOperationHistoryWriter.historyDirectoryName,
            isDirectory: true
        ).appendingPathComponent(
            ProjectStorageCleanupReceiptWriter.collectionDirectoryName,
            isDirectory: true
        ).appendingPathComponent(
            cleanupID.uuidString.lowercased(),
            isDirectory: true
        )
    }

    private func preparationCounterValues(
        _ events: [ProjectStorageInstrumentation.Event]
    ) -> [ProjectStorageInstrumentation.Counter: UInt64] {
        Dictionary(
            uniqueKeysWithValues: events.compactMap {
                guard case .counted(let counter, let value, _) = $0 else {
                    return nil
                }
                return (counter, value)
            }
        )
    }

    private func hardLinkSkipReason(_ code: Int32) -> String {
        let symbol: String
        if code == EXDEV {
            symbol = "EXDEV"
        } else if code == EOPNOTSUPP {
            symbol = "EOPNOTSUPP"
        } else {
            symbol = "ENOTSUP"
        }
        return "hard-link-unavailable: errno=\(code) (\(symbol))"
    }
}

private final class PreparationEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [ProjectStorageInstrumentation.Event] = []

    var snapshot: [ProjectStorageInstrumentation.Event] {
        lock.withLock { events }
    }

    func record(_ event: ProjectStorageInstrumentation.Event) {
        lock.withLock { events.append(event) }
    }
}

private final class PreparationStringRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.withLock { storage }
    }

    func append(_ value: String) {
        lock.withLock { storage.append(value) }
    }
}

private final class PreparationIntegerRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.withLock { storage }
    }

    func increment() {
        lock.withLock { storage += 1 }
    }
}

private extension Array where Element: Hashable {
    var uniqued: Set<Element> { Set(self) }
}
