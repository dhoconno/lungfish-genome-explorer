import Darwin
import Foundation
import LungfishIO
import LungfishTestSupport
import XCTest
@testable import LungfishWorkflow

final class ProjectStorageScannerLargeTreeTests: XCTestCase {
    func testCISemanticFixtureHasExactTopology() throws {
        let fixture = try makeFixture(.ciSemantic)
        defer { try? FileManager.default.removeItem(at: fixture.projectURL) }
        try installHardLinksOrSkip(fixture)

        let oracle = try ProjectStorageFixtureOracle.inspect(
            projectURL: fixture.projectURL
        )
        let configuration = ProjectStorageLargeTreeFixture.configuration(
            for: .ciSemantic
        )

        XCTAssertEqual(oracle.candidateRelativePaths.count, 3)
        XCTAssertEqual(oracle.ordinaryFileCount, 1_536)
        XCTAssertEqual(oracle.sparseFileCount, 32)
        XCTAssertEqual(oracle.withinCandidateHardLinkIdentityCount, 128)
        XCTAssertEqual(oracle.crossCandidateHardLinkIdentityCount, 128)
        XCTAssertEqual(oracle.externalHardLinkIdentityCount, 128)
        XCTAssertEqual(oracle.hardLinkDirectoryEntryCount, 768)
        XCTAssertEqual(oracle.operationHistoryDescendantCount, 2_048)
        XCTAssertEqual(oracle.maximumCandidateDepth, 6)
        XCTAssertEqual(configuration.seed, 0x4C554E4746495348)
        XCTAssertEqual(
            configuration.sparseLogicalBytes,
            64 * 1_024 * 1_024
        )
        XCTAssertEqual(
            oracle.ordinaryFilesPerCandidate,
            configuration.ordinaryFilesPerCandidate
        )
        XCTAssertEqual(
            oracle.sparseFilesPerCandidate,
            configuration.sparseFilesPerCandidate
        )
        XCTAssertEqual(
            oracle.withinCandidateHardLinksPerCandidate,
            configuration.withinCandidateHardLinksPerCandidate
        )
        XCTAssertEqual(
            oracle.externalHardLinksPerCandidate,
            configuration.externalHardLinksPerCandidate
        )
        XCTAssertGreaterThan(oracle.fileSystem.blockSize, 0)
        XCTAssertFalse(oracle.fileSystem.typeName.isEmpty)
        XCTAssertTrue(
            oracle.hardLinkTopologies.values.allSatisfy {
                $0.linkCount == 2
                    && $0.candidateOccurrences
                        + $0.survivorOccurrences == 2
            }
        )
        XCTAssertTrue(
            oracle.treeRecords.filter {
                $0.key.contains("/sparse/")
            }.values.allSatisfy {
                $0.logicalSize == UInt64(configuration.sparseLogicalBytes)
            }
        )
        for identityIndex in 0..<128 {
            let sourceIndex = identityIndex % 3
            let destinationIndex = (identityIndex + 1) % 3
            let source = String(
                format:
                    ".tmp/candidate-%02d/hard-links/cross-source-%05d.bin",
                sourceIndex,
                identityIndex
            )
            let destination = String(
                format:
                    ".tmp/candidate-%02d/hard-links/cross-copy-%05d.bin",
                destinationIndex,
                identityIndex
            )
            let topology = try XCTUnwrap(
                oracle.hardLinkTopologies.values.first {
                    Set($0.occurrenceRelativePaths)
                        == Set([source, destination])
                }
            )
            XCTAssertEqual(
                topology.candidateIndices,
                [sourceIndex, destinationIndex].sorted()
            )
            XCTAssertEqual(topology.candidateOccurrences, 2)
            XCTAssertEqual(topology.survivorOccurrences, 0)
            XCTAssertEqual(topology.linkCount, 2)
        }
        for identityIndex in 0..<128 {
            let candidateIndex: Int
            if identityIndex < 43 {
                candidateIndex = 0
            } else if identityIndex < 86 {
                candidateIndex = 1
            } else {
                candidateIndex = 2
            }
            let source = String(
                format:
                    ".tmp/candidate-%02d/hard-links/external-source-%05d.bin",
                candidateIndex,
                identityIndex
            )
            let survivor = String(
                format: "survivor/external-survivor-%05d.bin",
                identityIndex
            )
            let topology = try XCTUnwrap(
                oracle.hardLinkTopologies.values.first {
                    Set($0.occurrenceRelativePaths)
                        == Set([source, survivor])
                }
            )
            XCTAssertEqual(topology.candidateIndices, [candidateIndex])
            XCTAssertEqual(topology.candidateOccurrences, 1)
            XCTAssertEqual(topology.survivorOccurrences, 1)
            XCTAssertEqual(topology.linkCount, 2)
        }
    }

    func testReleaseRepresentativeConfigurationIsExact() {
        let configuration = ProjectStorageLargeTreeFixture.configuration(
            for: .releaseRepresentative
        )

        XCTAssertEqual(configuration.candidateCount, 8)
        XCTAssertEqual(configuration.ordinaryFileCount, 32_768)
        XCTAssertEqual(
            configuration.ordinaryFilesPerCandidate,
            Array(repeating: 4_096, count: 8)
        )
        XCTAssertEqual(configuration.withinCandidateHardLinkIdentityCount, 682)
        XCTAssertEqual(
            configuration.withinCandidateHardLinksPerCandidate,
            [86, 86, 85, 85, 85, 85, 85, 85]
        )
        XCTAssertEqual(configuration.crossCandidateHardLinkIdentityCount, 683)
        XCTAssertEqual(configuration.externalHardLinkIdentityCount, 683)
        XCTAssertEqual(
            configuration.externalHardLinksPerCandidate,
            [86, 86, 86, 85, 85, 85, 85, 85]
        )
        XCTAssertEqual(configuration.sparseFileCount, 128)
        XCTAssertEqual(
            configuration.sparseFilesPerCandidate,
            Array(repeating: 16, count: 8)
        )
        XCTAssertEqual(configuration.sparseLogicalBytes, 1_073_741_824)
        XCTAssertEqual(configuration.operationHistoryDecoyObjectCount, 16_384)
        XCTAssertEqual(configuration.hardLinkDirectoryEntryCount, 4_096)
        XCTAssertEqual(configuration.seed, 0x4C554E4746495348)
    }

    func testLargeTreeScanStreamsWithoutReadingOrHashingPayloads() throws {
        let fixture = try makeFixture(.ciSemantic)
        defer { try? FileManager.default.removeItem(at: fixture.projectURL) }
        let sparse = try XCTUnwrap(fixture.sparseFileURLs.first)
        XCTAssertEqual(Darwin.chmod(sparse.path, 0), 0)
        defer { _ = Darwin.chmod(sparse.path, S_IRUSR | S_IWUSR) }
        let before = try ProjectStorageFixtureOracle.inspect(
            projectURL: fixture.projectURL
        )
        let recorder = StorageEventRecorder()

        let result = try ProjectStorageScanner(
            instrumentation: .init(record: recorder.record)
        ).scan(projectURL: fixture.projectURL)

        XCTAssertEqual(result.entries.count, 3)
        XCTAssertEqual(
            result.entries.reduce(0) { $0 + $1.logicalBytes },
            before.candidateLogicalBytes
        )
        XCTAssertEqual(
            result.entries.reduce(0) { $0 + $1.allocatedBytes },
            before.candidateReclaimableAllocatedBytes
        )
        XCTAssertFalse(
            recorder.snapshot.contains {
                guard case .counted(.computedHashes, _, _) = $0 else {
                    return false
                }
                return true
            }
        )
        XCTAssertTrue(
            before.sparseFileIdentities.values.contains(
                try fileIdentity(sparse)
            )
        )
    }

    func testLargeTreeHardLinksAreDeduplicatedAcrossCandidateBoundaries()
        throws
    {
        let fixture = try makeFixture(.ciSemantic)
        defer { try? FileManager.default.removeItem(at: fixture.projectURL) }
        try installHardLinksOrSkip(fixture)
        let oracle = try ProjectStorageFixtureOracle.inspect(
            projectURL: fixture.projectURL
        )

        let result = try ProjectStorageScanner().scan(
            projectURL: fixture.projectURL
        )

        XCTAssertEqual(
            result.entries.reduce(0) { $0 + $1.allocatedBytes },
            oracle.candidateReclaimableAllocatedBytes
        )
        XCTAssertEqual(oracle.crossCandidateHardLinkIdentityCount, 128)
        XCTAssertEqual(oracle.withinCandidateHardLinkIdentityCount, 128)
    }

    func testLargeTreeExternalHardLinkSurvivorIsNotCreditedAsReclaimable()
        throws
    {
        let fixture = try makeFixture(.ciSemantic)
        defer { try? FileManager.default.removeItem(at: fixture.projectURL) }
        try installHardLinksOrSkip(fixture)
        let oracle = try ProjectStorageFixtureOracle.inspect(
            projectURL: fixture.projectURL
        )

        let result = try ProjectStorageScanner().scan(
            projectURL: fixture.projectURL
        )

        XCTAssertEqual(oracle.externalHardLinkIdentityCount, 128)
        XCTAssertGreaterThan(
            oracle.candidateAllocatedBytesWithoutSurvivorExclusion,
            oracle.candidateReclaimableAllocatedBytes
        )
        XCTAssertEqual(
            result.entries.reduce(0) { $0 + $1.allocatedBytes },
            oracle.candidateReclaimableAllocatedBytes
        )
    }

    func testLargeTreeCancellationReturnsNoPartialResultAndMutatesNothing()
        throws
    {
        let fixture = try makeFixture(.ciSemantic)
        defer {
            try? FileManager.default.removeItem(at: fixture.projectURL)
        }
        let before = try ProjectStorageFixtureOracle.inspect(
            projectURL: fixture.projectURL
        )
        for cancellationAt in [10, 256, 1_024] {
            let events = StorageEventRecorder()
            var checks = 0
            var lastReportedVisited: UInt64 = 0
            let scanner = ProjectStorageScanner(
                cancellationCheck: {
                    checks += 1
                    if checks == cancellationAt {
                        throw CancellationError()
                    }
                },
                instrumentation: .init(record: events.record)
            )

            XCTAssertThrowsError(
                try scanner.scan(
                    projectURL: fixture.projectURL,
                    progress: {
                        lastReportedVisited =
                            $0.visitedFileSystemObjects
                    }
                )
            ) {
                XCTAssertTrue($0 is CancellationError)
            }
            XCTAssertEqual(
                counterValues(in: events.snapshot)[.visitedObjects],
                lastReportedVisited + 1,
                "Yield \(cancellationAt) must count before cancellation."
            )
        }
        let after = try ProjectStorageFixtureOracle.inspect(
            projectURL: fixture.projectURL
        )
        XCTAssertEqual(after.externalSentinels, before.externalSentinels)
        XCTAssertEqual(after.treeRecords, before.treeRecords)
        XCTAssertEqual(
            after.candidateRootRecords,
            before.candidateRootRecords
        )
    }

    func testLargeTreeCandidateReplacementDuringScanFailsClosed() throws {
        let fixture = try makeFixture(.ciSemantic)
        defer { try? FileManager.default.removeItem(at: fixture.projectURL) }
        let target = fixture.candidateURLs[0]
        let displaced = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ProjectStorage-Replaced-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: displaced) }
        var checks = 0
        var replaced = false
        let scanner = ProjectStorageScanner(cancellationCheck: {
            checks += 1
            if !replaced && checks == 256 {
                try FileManager.default.moveItem(at: target, to: displaced)
                try FileManager.default.createDirectory(
                    at: target,
                    withIntermediateDirectories: false
                )
                replaced = true
            }
        })

        do {
            let result = try scanner.scan(projectURL: fixture.projectURL)
            XCTAssertTrue(replaced)
            let entry = try XCTUnwrap(
                result.entries.first {
                    $0.relativePath == ".tmp/candidate-00"
                }
            )
            XCTAssertFalse(entry.classification.isRemovable)
            XCTAssertEqual(entry.classification.code, .identityChanged)
        } catch {
            XCTAssertTrue(replaced)
        }

        let rootFixture = try makeFixture(.ciSemantic)
        let originalRoot = rootFixture.projectURL
        let displacedRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ProjectStorage-ReplacedRoot-\(UUID().uuidString)",
                isDirectory: true
            )
        defer {
            try? FileManager.default.removeItem(at: originalRoot)
            try? FileManager.default.removeItem(at: displacedRoot)
        }
        var rootChecks = 0
        var rootReplaced = false
        let rootReplacingScanner = ProjectStorageScanner(
            cancellationCheck: {
                rootChecks += 1
                if !rootReplaced && rootChecks == 256 {
                    try FileManager.default.moveItem(
                        at: originalRoot,
                        to: displacedRoot
                    )
                    try FileManager.default.createDirectory(
                        at: originalRoot,
                        withIntermediateDirectories: false
                    )
                    rootReplaced = true
                }
            }
        )
        XCTAssertThrowsError(
            try rootReplacingScanner.scan(projectURL: originalRoot)
        )
        XCTAssertTrue(rootReplaced)
    }

    func testLargeOperationHistoryTreeIsSkippedAndNeverOffered() throws {
        let fixture = try makeFixture(.ciSemantic)
        defer { try? FileManager.default.removeItem(at: fixture.projectURL) }
        let oracle = try ProjectStorageFixtureOracle.inspect(
            projectURL: fixture.projectURL
        )
        let recorder = StorageEventRecorder()

        let result = try ProjectStorageScanner(
            instrumentation: .init(record: recorder.record)
        ).scan(projectURL: fixture.projectURL)

        XCTAssertEqual(result.entries.count, 3)
        XCTAssertFalse(
            result.entries.contains {
                $0.relativePath.contains(".lungfish-operation-history")
            }
        )
        XCTAssertEqual(
            counterValues(in: recorder.snapshot)[.visitedObjects],
            oracle.visitedObjects
        )
        XCTAssertEqual(oracle.operationHistoryDescendantCount, 2_048)
    }

    func testLargeTreeScanEmitsBalancedScanInstrumentation() throws {
        let root = try makeTemporaryProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let candidate = root.appendingPathComponent(
            ".tmp/large-preview",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: candidate,
            withIntermediateDirectories: true
        )
        for index in 0..<256 {
            try Data("fixture-\(index)".utf8).write(
                to: candidate.appendingPathComponent("file-\(index)")
            )
        }
        for index in 0..<32 {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(
                    ".tmp/cancel-candidate-\(index)",
                    isDirectory: true
                ),
                withIntermediateDirectories: false
            )
        }
        let events = StorageEventRecorder()
        let scanner = ProjectStorageScanner(
            instrumentation: .init(record: events.record)
        )

        let result = try scanner.scan(projectURL: root)

        let snapshot = events.snapshot
        try assertBalancedScan(snapshot, outcome: .success)
        XCTAssertTrue(
            snapshot.contains {
                guard case .counted(
                    .visitedObjects,
                    let count,
                    intervalID: _
                ) = $0 else {
                    return false
                }
                return count >= 256
            }
        )
        let successCounts = counterValues(in: snapshot)
        let successCandidateCount = try XCTUnwrap(
            successCounts[.candidateEntries]
        )
        let successHardLinkCount = try XCTUnwrap(
            successCounts[.trackedHardLinkIdentities]
        )
        XCTAssertGreaterThanOrEqual(
            try XCTUnwrap(successCounts[.retainedScannerRecords]),
            successCandidateCount
                + UInt64(result.entries.count)
                + successHardLinkCount
        )

        let duplicateEvents = StorageEventRecorder()
        let duplicateInstrumentation = ProjectStorageInstrumentation(
            record: duplicateEvents.record
        )
        let duplicateInterval = duplicateInstrumentation.begin(.scan)
        duplicateInstrumentation.end(
            duplicateInterval,
            outcome: .success
        )
        duplicateInstrumentation.end(
            duplicateInterval,
            outcome: .failure
        )
        XCTAssertEqual(
            terminalEventCount(
                for: duplicateInterval.id,
                in: duplicateEvents.snapshot
            ),
            1
        )

        let cancelledEvents = StorageEventRecorder()
        var cancellationChecks = 0
        let cancelling = ProjectStorageScanner(
            cancellationCheck: {
                cancellationChecks += 1
                if cancellationChecks > 12 {
                    throw CancellationError()
                }
            },
            instrumentation: .init(record: cancelledEvents.record)
        )
        XCTAssertThrowsError(try cancelling.scan(projectURL: root)) {
            XCTAssertTrue($0 is CancellationError)
        }
        try assertBalancedScan(
            cancelledEvents.snapshot,
            outcome: .cancelled
        )
        let cancelledCounts = counterValues(
            in: cancelledEvents.snapshot
        )
        XCTAssertGreaterThan(
            try XCTUnwrap(cancelledCounts[.candidateEntries]),
            0
        )
        XCTAssertGreaterThanOrEqual(
            try XCTUnwrap(cancelledCounts[.retainedScannerRecords]),
            try XCTUnwrap(cancelledCounts[.candidateEntries])
        )

        let failureEvents = StorageEventRecorder()
        let failing = ProjectStorageScanner(
            instrumentation: .init(record: failureEvents.record)
        )
        XCTAssertThrowsError(
            try failing.scan(
                projectURL: root.appendingPathComponent("missing")
            )
        )
        try assertBalancedScan(failureEvents.snapshot, outcome: .failure)
        let failureCounts = counterValues(in: failureEvents.snapshot)
        XCTAssertEqual(failureCounts[.visitedObjects], 0)
        XCTAssertEqual(failureCounts[.candidateEntries], 0)
        XCTAssertEqual(failureCounts[.retainedScannerRecords], 0)
    }

    func testHardLinkTrackingBudgetFailsClosed() throws {
        let root = try makeTemporaryProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let earlier = root.appendingPathComponent(
            ".tmp/00-earlier",
            isDirectory: true
        )
        try makeCompletedOwnedDirectory(earlier, project: root)
        try Data(repeating: 42, count: 8_192).write(
            to: earlier.appendingPathComponent("payload")
        )
        let expectedEarlier = try XCTUnwrap(
            ProjectStorageScanner(
                maximumTrackedHardLinkIdentities: 16
            ).scan(projectURL: root).entries.first {
                $0.relativePath == ".tmp/00-earlier"
            }
        )
        XCTAssertTrue(expectedEarlier.classification.isRemovable)
        let candidate = root.appendingPathComponent(
            ".tmp/hard-links",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: candidate,
            withIntermediateDirectories: true
        )
        for index in 0..<17 {
            let source = candidate.appendingPathComponent("source-\(index)")
            try Data(repeating: UInt8(index), count: 4_096).write(to: source)
            let destination = candidate.appendingPathComponent("link-\(index)")
            if Darwin.link(source.path, destination.path) != 0 {
                let code = errno
                let unavailable = Set<Int32>([
                    EOPNOTSUPP,
                    ENOTSUP,
                    EXDEV,
                ])
                if unavailable.contains(code) {
                    let symbol: String
                    if code == EXDEV {
                        symbol = "EXDEV"
                    } else if code == EOPNOTSUPP {
                        symbol = "EOPNOTSUPP"
                    } else {
                        symbol = "ENOTSUP"
                    }
                    throw XCTSkip(
                        "hard-link-unavailable: errno=\(code) (\(symbol))"
                    )
                }
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
        }
        let events = StorageEventRecorder()
        let scanner = ProjectStorageScanner(
            instrumentation: .init(record: events.record),
            maximumTrackedHardLinkIdentities: 16
        )

        let result = try scanner.scan(projectURL: root)

        let entry = try XCTUnwrap(
            result.entries.first {
                $0.relativePath == ".tmp/hard-links"
            }
        )
        XCTAssertEqual(entry.classification.code, .resourceLimitExceeded)
        XCTAssertEqual(
            entry.classification.reason,
            "Hard-link identity tracking exceeded the 16-entry safety limit."
        )
        XCTAssertEqual(entry.allocatedBytes, 0)
        let retainedEarlier = try XCTUnwrap(
            result.entries.first {
                $0.relativePath == ".tmp/00-earlier"
            }
        )
        XCTAssertEqual(
            retainedEarlier.classification,
            expectedEarlier.classification
        )
        XCTAssertEqual(
            retainedEarlier.logicalBytes,
            expectedEarlier.logicalBytes
        )
        XCTAssertEqual(
            retainedEarlier.allocatedBytes,
            expectedEarlier.allocatedBytes
        )
        let counted = events.snapshot.compactMap {
            event -> (ProjectStorageInstrumentation.Counter, UInt64)? in
            guard case .counted(let counter, let value, _) = event else {
                return nil
            }
            return (counter, value)
        }
        XCTAssertEqual(
            counted.filter { $0.0 == .candidateEntries }.map(\.1),
            [2]
        )
        XCTAssertEqual(
            counted.filter {
                $0.0 == .trackedHardLinkIdentities
            }.map(\.1),
            [16]
        )
        XCTAssertLessThanOrEqual(
            try XCTUnwrap(
                counted.first {
                    $0.0 == .trackedHardLinkIdentities
                }?.1
            ),
            16
        )
        XCTAssertLessThanOrEqual(
            try XCTUnwrap(
                counted.first {
                    $0.0 == .retainedScannerRecords
                }?.1
            ),
            try XCTUnwrap(
                counted.first {
                    $0.0 == .candidateEntries
                }?.1
            ) + UInt64(result.entries.count) + 16
        )
    }

    func testRetainedScannerStateMatchesDeclaredComplexityBound() throws {
        let fixture = try makeFixture(.ciSemantic)
        defer { try? FileManager.default.removeItem(at: fixture.projectURL) }
        let events = StorageEventRecorder()

        let result = try ProjectStorageScanner(
            instrumentation: .init(record: events.record)
        ).scan(projectURL: fixture.projectURL)

        let counts = counterValues(in: events.snapshot)
        let candidates = try XCTUnwrap(counts[.candidateEntries])
        let identities = try XCTUnwrap(counts[.trackedHardLinkIdentities])
        let retained = try XCTUnwrap(counts[.retainedScannerRecords])
        XCTAssertLessThanOrEqual(identities, 65_536)
        XCTAssertLessThanOrEqual(
            retained,
            UInt64(result.entries.count) + candidates + identities
        )
    }

    func testReleaseRepresentativeScanMemoryDeltaIsAtMost96MiB() throws {
        try assertSamplerProtocol()
        guard let mode = ProcessInfo.processInfo.environment[
            "LUNGFISH_RUN_STORAGE_PERF"
        ] else {
            throw XCTSkip(
                "storage-perf-disabled: LUNGFISH_RUN_STORAGE_PERF is absent"
            )
        }
        let configuredTrial = try validateStoragePerformanceMode(
            mode,
            trial: ProcessInfo.processInfo.environment[
                "LUNGFISH_STORAGE_PERF_TRIAL"
            ]
        )
        let fixture = try makeFixture(.releaseRepresentative)
        defer { try? FileManager.default.removeItem(at: fixture.projectURL) }
        do {
            try fixture.installHardLinkOverlay()
        } catch let error as ProjectStorageHardLinkUnavailableError {
            throw XCTSkip(
                "storage-perf-incomplete: link errno=\(error.code) "
                    + "(\(hardLinkSymbol(error.code)))"
            )
        }
        if mode == "warmup" {
            _ = try ProjectStorageScanner().scan(
                projectURL: fixture.projectURL
            )
            return
        }
        let sampler = ProcessMemorySampler()
        let events = StorageEventRecorder()
        let sampled = try runWithMemorySampler(sampler) {
            try ProjectStorageScanner(
                instrumentation: .init(record: events.record)
            ).scan(projectURL: fixture.projectURL)
        }
        let baseline = sampled.baseline
        let result = sampled.result
        let counts = counterValues(in: events.snapshot)
        XCTAssertGreaterThanOrEqual(sampler.sampleCount, 2)
        XCTAssertLessThanOrEqual(
            sampler.maximumObservedSampleGapNanoseconds,
            ProcessMemorySampler.maximumAllowedSampleGapNanoseconds
        )
        XCTAssertEqual(counts[.computedHashes], nil)
        XCTAssertEqual(
            counts[.trackedHardLinkIdentities],
            UInt64(
                ProjectStorageLargeTreeFixture
                    .releaseRepresentativeConfiguration
                    .withinCandidateHardLinkIdentityCount
                    + ProjectStorageLargeTreeFixture
                    .releaseRepresentativeConfiguration
                    .crossCandidateHardLinkIdentityCount
                    + ProjectStorageLargeTreeFixture
                    .releaseRepresentativeConfiguration
                    .externalHardLinkIdentityCount
            )
        )
        XCTAssertLessThanOrEqual(
            try XCTUnwrap(counts[.trackedHardLinkIdentities]),
            UInt64(ProjectStorageScanner.maximumTrackedHardLinkIdentities)
        )
        XCTAssertLessThanOrEqual(
            try XCTUnwrap(counts[.retainedScannerRecords]),
            try XCTUnwrap(counts[.candidateEntries])
                + UInt64(result.entries.count)
                + (try XCTUnwrap(counts[.trackedHardLinkIdentities]))
        )
        let peak = max(baseline, sampler.peakResidentBytes)
        let delta = peak - baseline
        XCTAssertLessThanOrEqual(delta, 96 * 1_024 * 1_024)
        let trial = try XCTUnwrap(configuredTrial)
        let firstSample = try XCTUnwrap(
            sampler.firstSampleTimestampNanoseconds
        )
        let lastSample = try XCTUnwrap(
            sampler.lastSampleTimestampNanoseconds
        )
        print(
            "storage-perf-memory: trial=\(trial) "
                + "baseline=\(baseline) "
                + "peak=\(peak) "
                + "samples=\(sampler.sampleCount) "
                + "targetIntervalNs="
                + "\(ProcessMemorySampler.targetSampleIntervalNanoseconds) "
                + "firstSampleNs=\(firstSample) "
                + "lastSampleNs=\(lastSample) "
                + "maxGapNs="
                + "\(sampler.maximumObservedSampleGapNanoseconds) "
                + "delta=\(delta)"
        )
    }

    private func assertSamplerProtocol() throws {
        XCTAssertNil(
            try validateStoragePerformanceMode("warmup", trial: nil)
        )
        XCTAssertEqual(
            try validateStoragePerformanceMode("memory", trial: "1"),
            "1"
        )
        XCTAssertThrowsError(
            try validateStoragePerformanceMode("timing", trial: nil)
        )
        XCTAssertThrowsError(
            try validateStoragePerformanceMode("memory", trial: nil)
        )
        XCTAssertThrowsError(
            try validateStoragePerformanceMode("memory", trial: "4")
        )

        let sequence = StorageSampleSequence([100, 200, 150])
        let protocolClock = StorageSamplerClock(
            startNanoseconds: 1_000_000,
            stepNanoseconds: 250_000
        )
        let protocolDeadlines = StorageBlockingDeadlineController()
        let sampler = ProcessMemorySampler(
            sample: sequence.next,
            cadenceControl: .init(
                monotonicNow: protocolClock.next,
                waitUntil: protocolDeadlines.wait,
                wake: protocolDeadlines.wake
            )
        )
        try sampler.arm()
        XCTAssertGreaterThanOrEqual(sampler.sampleCount, 1)
        XCTAssertEqual(sampler.baselineResidentBytes, 100)
        XCTAssertTrue(protocolDeadlines.waitForWaitCount(1))
        let beforeTerminal = sampler.sampleCount
        try sampler.requestTerminalSampleAndWait()
        XCTAssertGreaterThan(sampler.sampleCount, beforeTerminal)
        sampler.stop()
        try sampler.join()
        XCTAssertGreaterThanOrEqual(sampler.peakResidentBytes, 150)
        XCTAssertEqual(protocolDeadlines.wakeCount, 2)

        let deterministicClock = StorageSamplerClock(
            startNanoseconds: 10_000_000,
            stepNanoseconds: 250_000
        )
        let deadlineController = StorageBlockingDeadlineController()
        let cadenceSampler = ProcessMemorySampler(
            sample: { 1 },
            cadenceControl: .init(
                monotonicNow: deterministicClock.next,
                waitUntil: deadlineController.wait,
                wake: deadlineController.wake
            )
        )
        try cadenceSampler.arm()
        XCTAssertTrue(deadlineController.waitForWaitCount(1))
        try cadenceSampler.requestTerminalSampleAndWait()
        cadenceSampler.stop()
        try cadenceSampler.join()
        let timestamps = deterministicClock.values
        XCTAssertEqual(timestamps.count, Int(cadenceSampler.sampleCount))
        XCTAssertEqual(cadenceSampler.sampleCount, 2)
        let observedGaps = zip(
            timestamps.dropFirst(),
            timestamps
        ).map { later, earlier in
            later - earlier
        }
        XCTAssertEqual(
            cadenceSampler.maximumObservedSampleGapNanoseconds,
            observedGaps.max() ?? 0
        )
        XCTAssertLessThanOrEqual(
            cadenceSampler.maximumObservedSampleGapNanoseconds,
            1_000_000
        )
        XCTAssertLessThanOrEqual(
            ProcessMemorySampler.targetSampleIntervalNanoseconds,
            ProcessMemorySampler.maximumAllowedSampleGapNanoseconds
        )
        XCTAssertEqual(
            deadlineController.values.first,
            try XCTUnwrap(timestamps.first) + 500_000
        )
        XCTAssertEqual(
            cadenceSampler.firstSampleTimestampNanoseconds,
            timestamps.first
        )
        XCTAssertEqual(
            cadenceSampler.lastSampleTimestampNanoseconds,
            timestamps.last
        )
        XCTAssertEqual(deadlineController.wakeCount, 2)

        let stopClock = StorageSamplerClock(
            startNanoseconds: 15_000_000,
            stepNanoseconds: 250_000
        )
        let stopController = StorageBlockingDeadlineController()
        let stoppedWhileWaiting = ProcessMemorySampler(
            sample: { 1 },
            cadenceControl: .init(
                monotonicNow: stopClock.next,
                waitUntil: stopController.wait,
                wake: stopController.wake
            )
        )
        try stoppedWhileWaiting.arm()
        XCTAssertTrue(stopController.waitForWaitCount(1))
        stoppedWhileWaiting.stop()
        try stoppedWhileWaiting.join()
        XCTAssertEqual(stoppedWhileWaiting.sampleCount, 1)
        XCTAssertEqual(stopController.wakeCount, 1)

        let overBudgetClock = StorageSamplerClock(
            startNanoseconds: 20_000_000,
            stepNanoseconds: 1_000_001
        )
        let invalidCadence = ProcessMemorySampler(
            sample: { 1 },
            cadenceControl: .init(
                monotonicNow: overBudgetClock.next,
                waitUntil: { _ in true },
                wake: {}
            )
        )
        var cadenceErrors: [ProcessMemorySampler.SamplerError] = []
        do {
            try invalidCadence.arm(timeout: 1)
            try invalidCadence.requestTerminalSampleAndWait(timeout: 1)
        } catch let error as ProcessMemorySampler.SamplerError {
            cadenceErrors.append(error)
        }
        invalidCadence.stop()
        do {
            try invalidCadence.join(timeout: 1)
        } catch let error as ProcessMemorySampler.SamplerError {
            cadenceErrors.append(error)
        }
        XCTAssertTrue(
            cadenceErrors.contains(
                .cadenceExceeded(maxGapNanoseconds: 1_000_001)
            )
        )
        XCTAssertEqual(
            invalidCadence.maximumObservedSampleGapNanoseconds,
            1_000_001
        )

        let callOrder = StorageCallOrder()
        let orderedClock = StorageSamplerClock(
            startNanoseconds: 30_000_000,
            stepNanoseconds: 250_000
        )
        let orderedDeadlines = StorageBlockingDeadlineController()
        let orderedSampler = ProcessMemorySampler(sample: {
            callOrder.append("sample")
            return 110
        }, cadenceControl: .init(
            monotonicNow: orderedClock.next,
            waitUntil: orderedDeadlines.wait,
            wake: orderedDeadlines.wake
        ))
        let ordered = try runWithMemorySampler(
            orderedSampler,
            baselineSample: {
                callOrder.append("baseline")
                return 100
            }
        ) { 1 }
        XCTAssertEqual(ordered.baseline, 100)
        XCTAssertEqual(callOrder.values.first, "baseline")

        let failingClock = StorageSamplerClock(
            startNanoseconds: 40_000_000,
            stepNanoseconds: 250_000
        )
        let failing = ProcessMemorySampler(sample: {
            throw POSIXError(.EIO)
        }, cadenceControl: .init(
            monotonicNow: failingClock.next,
            waitUntil: { _ in true },
            wake: {}
        ))
        XCTAssertThrowsError(try failing.arm(timeout: 1)) {
            guard case ProcessMemorySampler.SamplerError.sampleFailed = $0
            else {
                return XCTFail("Expected a first-sample failure, got \($0)")
            }
        }
        XCTAssertThrowsError(try failing.join(timeout: 1)) {
            guard case ProcessMemorySampler.SamplerError.sampleFailed = $0
            else {
                return XCTFail("Expected a join failure, got \($0)")
            }
        }

        let delayedClock = StorageSamplerClock(
            startNanoseconds: 50_000_000,
            stepNanoseconds: 250_000
        )
        let delayed = ProcessMemorySampler(sample: {
            usleep(20_000)
            return 1
        }, cadenceControl: .init(
            monotonicNow: delayedClock.next,
            waitUntil: { _ in true },
            wake: {}
        ))
        XCTAssertThrowsError(
            try runWithMemorySampler(
                delayed,
                armTimeout: 0.001
            ) { 1 }
        ) {
            XCTAssertEqual(
                $0 as? ProcessMemorySampler.SamplerError,
                .timedOut("first-sample")
            )
        }
        XCTAssertTrue(delayed.isJoined)

        enum InjectedScanFailure: Error { case failed }
        let scanFailureClock = StorageSamplerClock(
            startNanoseconds: 60_000_000,
            stepNanoseconds: 250_000
        )
        let scanFailureDeadlines = StorageBlockingDeadlineController()
        let scanFailure = ProcessMemorySampler(
            sample: StorageSampleSequence([1, 2]).next,
            cadenceControl: .init(
                monotonicNow: scanFailureClock.next,
                waitUntil: scanFailureDeadlines.wait,
                wake: scanFailureDeadlines.wake
            )
        )
        XCTAssertThrowsError(
            try runWithMemorySampler(scanFailure) {
                throw InjectedScanFailure.failed
            } as (baseline: UInt64, result: Int)
        ) {
            XCTAssertTrue($0 is InjectedScanFailure)
        }
        XCTAssertTrue(scanFailure.isJoined)
    }

    private func runWithMemorySampler<Result>(
        _ sampler: ProcessMemorySampler,
        armTimeout: TimeInterval = 5,
        baselineSample: () throws -> UInt64 = {
            try ProcessMemorySampler.currentResidentFootprint()
        },
        operation: () throws -> Result
    ) throws -> (baseline: UInt64, result: Result) {
        let baseline = try baselineSample()
        do {
            try sampler.arm(timeout: armTimeout)
        } catch {
            sampler.stop()
            try? sampler.join()
            throw error
        }
        do {
            let result = try operation()
            try withExtendedLifetime(result) {
                try sampler.requestTerminalSampleAndWait()
                sampler.stop()
                try sampler.join()
            }
            return (baseline, result)
        } catch {
            sampler.stop()
            try? sampler.join()
            throw error
        }
    }

    private enum StoragePerformanceConfigurationError: Error {
        case invalidMode(String)
        case invalidTrial(String?)
    }

    private func validateStoragePerformanceMode(
        _ mode: String,
        trial: String?
    ) throws -> String? {
        switch mode {
        case "warmup":
            return nil
        case "memory":
            guard let trial, ["1", "2", "3"].contains(trial) else {
                throw StoragePerformanceConfigurationError
                    .invalidTrial(trial)
            }
            return trial
        default:
            throw StoragePerformanceConfigurationError.invalidMode(mode)
        }
    }

    private func hardLinkSymbol(_ code: Int32) -> String {
        if code == EXDEV { return "EXDEV" }
        if code == EOPNOTSUPP { return "EOPNOTSUPP" }
        return "ENOTSUP"
    }

    private func makeTemporaryProject() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ProjectStorageScannerLargeTreeTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        return root
    }

    private func makeFixture(
        _ profile: ProjectStorageLargeTreeFixture.Profile
    ) throws -> ProjectStorageLargeTreeFixture {
        let project = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ProjectStorageLargeTree-\(UUID().uuidString)",
                isDirectory: true
            )
        return try ProjectStorageLargeTreeFixture.createBaseTree(
            profile: profile,
            at: project
        )
    }

    private func installHardLinksOrSkip(
        _ fixture: ProjectStorageLargeTreeFixture
    ) throws {
        do {
            try fixture.installHardLinkOverlay()
        } catch let error as ProjectStorageHardLinkUnavailableError {
            throw XCTSkip(error.skipReason)
        }
    }

    private func fileIdentity(
        _ url: URL
    ) throws -> ProjectStorageFixtureOracle.FileIdentity {
        var information = stat()
        guard Darwin.lstat(url.path, &information) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        return .init(
            device: UInt64(information.st_dev),
            inode: UInt64(information.st_ino)
        )
    }

    private func assertBalancedScan(
        _ events: [ProjectStorageInstrumentation.Event],
        outcome: ProjectStorageInstrumentation.Outcome,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let intervals = events.compactMap { event -> UUID? in
            guard case .began(let interval) = event,
                  interval.phase == .scan else {
                return nil
            }
            return interval.id
        }
        XCTAssertEqual(intervals.count, 1, file: file, line: line)
        let intervalID = try XCTUnwrap(
            intervals.first,
            file: file,
            line: line
        )
        XCTAssertEqual(
            events.filter {
                guard case .ended(let interval, let actualOutcome) = $0
                else {
                    return false
                }
                return interval.id == intervalID
                    && actualOutcome == outcome
            }.count,
            1,
            file: file,
            line: line
        )
        XCTAssertEqual(
            terminalEventCount(for: intervalID, in: events),
            1,
            file: file,
            line: line
        )
        for counter in [
            ProjectStorageInstrumentation.Counter.visitedObjects,
            .candidateEntries,
            .trackedHardLinkIdentities,
            .retainedScannerRecords,
        ] {
            XCTAssertEqual(
                events.filter {
                    guard case .counted(
                        let actualCounter,
                        _,
                        intervalID: let countedIntervalID
                    ) = $0 else {
                        return false
                    }
                    return actualCounter == counter
                        && countedIntervalID == intervalID
                }.count,
                1,
                "Missing stable aggregate counter \(counter.rawValue)",
                file: file,
                line: line
            )
        }
    }

    private func counterValues(
        in events: [ProjectStorageInstrumentation.Event]
    ) -> [ProjectStorageInstrumentation.Counter: UInt64] {
        var values: [ProjectStorageInstrumentation.Counter: UInt64] = [:]
        for event in events {
            guard case .counted(let counter, let value, _) = event else {
                continue
            }
            values[counter] = value
        }
        return values
    }

    private func terminalEventCount(
        for intervalID: UUID,
        in events: [ProjectStorageInstrumentation.Event]
    ) -> Int {
        events.filter {
            guard case .ended(let interval, _) = $0 else {
                return false
            }
            return interval.id == intervalID
        }.count
    }

    private func makeCompletedOwnedDirectory(
        _ directory: URL,
        project: URL
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
                runID: UUID(),
                processIdentity: .init(
                    processIdentifier: 1,
                    processStartTime: 1,
                    bootSessionID: UUID().uuidString
                ),
                state: .completed,
                lockRelativePath: nil,
                keepIntermediates: false,
                toolName: "storage-scanner-test",
                toolVersion: "1"
            )
        )
    }
}

private final class StorageEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [ProjectStorageInstrumentation.Event] = []

    var snapshot: [ProjectStorageInstrumentation.Event] {
        lock.withLock { events }
    }

    func record(_ event: ProjectStorageInstrumentation.Event) {
        lock.withLock { events.append(event) }
    }
}

private final class StorageSampleSequence: @unchecked Sendable {
    private let lock = NSLock()
    private let values: [UInt64]
    private var index = 0

    init(_ values: [UInt64]) {
        self.values = values
    }

    func next() -> UInt64 {
        lock.withLock {
            let value = values[min(index, values.count - 1)]
            index += 1
            return value
        }
    }
}

private final class StorageCallOrder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.withLock { storage }
    }

    func append(_ value: String) {
        lock.withLock { storage.append(value) }
    }
}

private final class StorageSamplerClock: @unchecked Sendable {
    private let lock = NSLock()
    private var nextNanoseconds: UInt64
    private let stepNanoseconds: UInt64
    private var timestamps: [UInt64] = []

    init(startNanoseconds: UInt64, stepNanoseconds: UInt64) {
        self.nextNanoseconds = startNanoseconds
        self.stepNanoseconds = stepNanoseconds
    }

    func next() -> UInt64 {
        lock.withLock {
            let result = nextNanoseconds
            nextNanoseconds += stepNanoseconds
            timestamps.append(result)
            return result
        }
    }

    var values: [UInt64] {
        lock.withLock { timestamps }
    }
}

private final class StorageBlockingDeadlineController: @unchecked Sendable {
    private let condition = NSCondition()
    private let semaphore = DispatchSemaphore(value: 0)
    private var deadlines: [UInt64] = []
    private var waitCount = 0
    private var wakes = 0

    var values: [UInt64] {
        condition.withLock { deadlines }
    }

    var wakeCount: Int {
        condition.withLock { wakes }
    }

    func wait(_ deadlineNanoseconds: UInt64) -> Bool {
        condition.withLock {
            deadlines.append(deadlineNanoseconds)
            waitCount += 1
            condition.broadcast()
        }
        semaphore.wait()
        return false
    }

    func wake() {
        condition.withLock { wakes += 1 }
        semaphore.signal()
    }

    func waitForWaitCount(
        _ expected: Int,
        timeout: TimeInterval = 1
    ) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date(timeIntervalSinceNow: timeout)
        while waitCount < expected {
            guard condition.wait(until: deadline) else {
                return false
            }
        }
        return true
    }
}
