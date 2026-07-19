import Foundation
import Darwin
import XCTest
@testable import LungfishWorkflow

final class FullLengthONTMHCCohortAlignmentBuilderTests: XCTestCase {
    func testBuildNamespacesTargetsAddsReadGroupsAndUsesExactStableCommandOrder() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let result = try await fixture.build(samples: [
            fixture.sample("sample-B", clusters: ["cluster-2"]),
            fixture.sample("sample-A", clusters: ["cluster-1"]),
        ])

        XCTAssertEqual(result.sampleMappings.map(\.sampleID), ["sample-A", "sample-B"])
        XCTAssertEqual(
            result.sampleMappings.flatMap(\.targets).map(\.namespacedTargetID),
            ["sample-A|cluster-1", "sample-B|cluster-2"]
        )
        XCTAssertEqual(result.sampleMappings.map(\.readGroupID), ["sample-A", "sample-B"])
        XCTAssertEqual(result.sampleMappings.map(\.readGroupSample), ["sample-A", "sample-B"])

        let bam = try String(contentsOf: result.bamURL, encoding: .utf8)
        XCTAssertTrue(bam.contains("@SQ\tSN:sample-A|cluster-1"))
        XCTAssertTrue(bam.contains("@SQ\tSN:sample-B|cluster-2"))
        XCTAssertTrue(bam.contains("@RG\tID:sample-A\tSM:sample-A"))
        XCTAssertTrue(bam.contains("@RG\tID:sample-B\tSM:sample-B"))

        let commands = try fixture.commands()
        XCTAssertEqual(commands.map(\.first), [
            "minimap2", "samtools", "samtools", "samtools",
            "minimap2", "samtools", "samtools", "samtools",
            "samtools", "samtools", "samtools", "samtools", "samtools",
        ])
        XCTAssertEqual(commands.compactMap { $0.dropFirst().first }, [
            "-a", "view", "addreplacerg", "sort",
            "-a", "view", "addreplacerg", "sort",
            "merge", "sort", "index", "quickcheck", "idxstats",
        ])

        let minimapArguments = Array(commands[0].dropFirst())
        XCTAssertEqual(Array(minimapArguments.prefix(11)), [
            "-a", "-x", "splice", "--eqx", "-t", "4", "-N", "100", "--secondary=yes",
            result.sampleMappings[0].namespacedClustersFASTAURL.path,
            fixture.referenceURL.path,
        ])
        XCTAssertEqual(minimapArguments.count, 11)
        XCTAssertEqual(Array(commands[1].dropFirst()), [
            "view", "-b", "-o",
            result.sampleMappings[0].unsortedBAMURL.path,
            result.sampleMappings[0].samURL.path,
        ])
        XCTAssertEqual(Array(commands[2].dropFirst()), [
            "addreplacerg", "-r", "ID:sample-A", "-r", "SM:sample-A", "-o",
            result.sampleMappings[0].readGroupBAMURL.path,
            result.sampleMappings[0].unsortedBAMURL.path,
        ])
        XCTAssertEqual(Array(commands[3].dropFirst()), [
            "sort", "-o", result.sampleMappings[0].sortedBAMURL.path,
            result.sampleMappings[0].readGroupBAMURL.path,
        ])
        XCTAssertEqual(Array(commands[4].dropFirst()), [
            "-a", "-x", "splice", "--eqx", "-t", "4", "-N", "100", "--secondary=yes",
            result.sampleMappings[1].namespacedClustersFASTAURL.path,
            fixture.referenceURL.path,
        ])
        XCTAssertEqual(Array(commands[5].dropFirst()), [
            "view", "-b", "-o",
            result.sampleMappings[1].unsortedBAMURL.path,
            result.sampleMappings[1].samURL.path,
        ])
        XCTAssertEqual(Array(commands[6].dropFirst()), [
            "addreplacerg", "-r", "ID:sample-B", "-r", "SM:sample-B", "-o",
            result.sampleMappings[1].readGroupBAMURL.path,
            result.sampleMappings[1].unsortedBAMURL.path,
        ])
        XCTAssertEqual(Array(commands[7].dropFirst()), [
            "sort", "-o", result.sampleMappings[1].sortedBAMURL.path,
            result.sampleMappings[1].readGroupBAMURL.path,
        ])

        let merge = Array(commands[8].dropFirst())
        XCTAssertEqual(merge, [
            "merge", "-f", "-o", result.mergedBAMURL.path,
            result.sampleMappings[0].sortedBAMURL.path,
            result.sampleMappings[1].sortedBAMURL.path,
        ])
        let stagedBAMURL = result.commandRecords[9].outputs[0]
        XCTAssertEqual(Array(commands[9].dropFirst()), [
            "sort", "-o", stagedBAMURL.path, result.mergedBAMURL.path,
        ])
        XCTAssertEqual(
            result.commandRecords[4].argv,
            [
                fixture.toolsURL.appendingPathComponent("minimap2").path,
                "-a", "-x", "splice", "--eqx", "-t", "4", "-N", "100", "--secondary=yes",
                result.sampleMappings[1].namespacedClustersFASTAURL.path,
                fixture.referenceURL.path,
            ]
        )
        XCTAssertEqual(
            result.commandRecords[5].argv,
            [
                fixture.toolsURL.appendingPathComponent("samtools").path,
                "view", "-b", "-o",
                result.sampleMappings[1].unsortedBAMURL.path,
                result.sampleMappings[1].samURL.path,
            ]
        )
        XCTAssertEqual(
            result.commandRecords[6].argv,
            [
                fixture.toolsURL.appendingPathComponent("samtools").path,
                "addreplacerg", "-r", "ID:sample-B", "-r", "SM:sample-B", "-o",
                result.sampleMappings[1].readGroupBAMURL.path,
                result.sampleMappings[1].unsortedBAMURL.path,
            ]
        )
        XCTAssertEqual(
            result.commandRecords[7].argv,
            [
                fixture.toolsURL.appendingPathComponent("samtools").path,
                "sort", "-o", result.sampleMappings[1].sortedBAMURL.path,
                result.sampleMappings[1].readGroupBAMURL.path,
            ]
        )
        XCTAssertEqual(
            result.commandRecords[9].argv,
            [
                fixture.toolsURL.appendingPathComponent("samtools").path,
                "sort", "-o", stagedBAMURL.path, result.mergedBAMURL.path,
            ]
        )
    }

    func testBuildStagesAndValidatesBothFilesBeforePublishingFinalNames() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let result = try await fixture.build(samples: [fixture.sample("S1", clusters: ["c1"])])

        XCTAssertEqual(result.bamURL.path, fixture.outputURL.appendingPathComponent("artifacts/alignments/genotyping-evidence.bam").path)
        XCTAssertEqual(result.baiURL.path, fixture.outputURL.appendingPathComponent("artifacts/alignments/genotyping-evidence.bam.bai").path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.bamURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.baiURL.path))
        let commands = try fixture.commands()
        let cohortSort = Array(commands[5].dropFirst())
        let stagedBAM = cohortSort[2]
        XCTAssertNotEqual(stagedBAM, result.bamURL.path)
        XCTAssertTrue(stagedBAM.contains(".alignments-replacement-"))
        XCTAssertEqual(Array(commands[6].dropFirst()), ["index", stagedBAM, stagedBAM + ".bai"])
        XCTAssertEqual(Array(commands[7].dropFirst()), ["quickcheck", stagedBAM])
        XCTAssertEqual(Array(commands[8].dropFirst()), ["idxstats", stagedBAM])
        XCTAssertEqual(result.commandRecords.suffix(2).map(\.arguments.first), ["quickcheck", "idxstats"])
        XCTAssertEqual(result.commandRecords[result.commandRecords.count - 2].inputs, [URL(fileURLWithPath: stagedBAM)])
        XCTAssertEqual(
            result.commandRecords[result.commandRecords.count - 1].inputs,
            [URL(fileURLWithPath: stagedBAM), URL(fileURLWithPath: stagedBAM + ".bai")]
        )
    }

    func testReturnsImmutableArtifactDescriptorsToolVersionsRuntimeAndPublicationMappings() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let result = try await fixture.build(samples: [fixture.sample("S1", clusters: ["c1"])])

        XCTAssertEqual(result.toolVersions.map(\.toolName), ["minimap2", "samtools"])
        XCTAssertEqual(result.toolVersions.map(\.version), ["minimap2 2.28-fake", "samtools 1.21-fake"])
        XCTAssertEqual(result.toolVersions.map(\.discoveryCommand.argv), [
            [fixture.toolsURL.appendingPathComponent("minimap2").path, "--version"],
            [fixture.toolsURL.appendingPathComponent("samtools").path, "--version"],
        ])
        XCTAssertEqual(
            result.toolVersionDiscoveryRecords,
            result.toolVersions.map(\.discoveryCommand)
        )
        XCTAssertTrue(result.commandRecords.allSatisfy { $0.toolVersion?.isEmpty == false })
        XCTAssertFalse(result.runtimeIdentity.executablePath.isEmpty)
        XCTAssertFalse(result.runtimeIdentity.operatingSystemVersion.isEmpty)
        XCTAssertFalse(result.runtimeIdentity.architecture.isEmpty)

        let finalBAMDescriptor = try XCTUnwrap(result.finalArtifactDescriptors.first {
            $0.path == result.bamURL.path
        })
        let finalBAIDescriptor = try XCTUnwrap(result.finalArtifactDescriptors.first {
            $0.path == result.baiURL.path
        })
        for descriptor in [finalBAMDescriptor, finalBAIDescriptor] {
            let url = URL(fileURLWithPath: descriptor.path)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            XCTAssertEqual(descriptor.sha256, try ProvenanceFileHasher.sha256(of: url))
            XCTAssertEqual(descriptor.byteSize, try ProvenanceFileHasher.fileSize(of: url))
            XCTAssertEqual(descriptor.phase, .final)
        }

        let temporaryDescriptor = try XCTUnwrap(result.temporaryArtifactDescriptors.first {
            $0.path.hasSuffix("S1.namespaced-clusters.fa")
        })
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryDescriptor.path))
        XCTAssertFalse(temporaryDescriptor.sha256.isEmpty)
        XCTAssertGreaterThan(temporaryDescriptor.byteSize, 0)
        XCTAssertEqual(temporaryDescriptor.phase, .temporary)

        XCTAssertEqual(result.publicationMappings.count, 2)
        XCTAssertEqual(Set(result.publicationMappings.map(\.finalDescriptor.path)), [
            result.bamURL.path,
            result.baiURL.path,
        ])
        XCTAssertTrue(result.publicationMappings.allSatisfy {
            $0.stagedDescriptor.phase == .staging && $0.finalDescriptor.phase == .final
        })

        let transformation = try XCTUnwrap(result.transformationRecords.first)
        XCTAssertEqual(transformation.workflowName, "lungfish-in-process:namespace-mhc-cluster-fasta")
        XCTAssertEqual(transformation.argv, [
            "lungfish-in-process", "namespace-mhc-cluster-fasta",
            "--sample-id", "S1", "--separator", "|", "--line-width", "80",
            result.sampleMappings[0].originalClustersFASTAURL.path,
            result.sampleMappings[0].namespacedClustersFASTAURL.path,
        ])
        XCTAssertEqual(transformation.inputs.first?.path, result.sampleMappings[0].originalClustersFASTAURL.path)
        XCTAssertEqual(transformation.outputs.first?.path, result.sampleMappings[0].namespacedClustersFASTAURL.path)
    }

    func testFinalDescriptorsArePreparedBeforeAtomicExchangeWithoutPostPublicationReads() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let boundary = PublicationBoundaryState()
        let descriptorProvider = RejectingPostPublicationArtifactDescriptorProvider(boundary: boundary)
        let publisher = BoundaryTrackingAlignmentDirectoryPublisher(boundary: boundary)

        let result = try await fixture.build(
            samples: [fixture.sample("S1", clusters: ["c1"])],
            publisher: publisher,
            artifactDescriptorProvider: descriptorProvider
        )

        XCTAssertTrue(boundary.wasPublished)
        XCTAssertEqual(boundary.postPublicationDescriptorAttempts, 0)
        XCTAssertEqual(result.publicationMappings.count, 2)
        for mapping in result.publicationMappings {
            XCTAssertEqual(mapping.finalDescriptor.sha256, mapping.stagedDescriptor.sha256)
            XCTAssertEqual(mapping.finalDescriptor.byteSize, mapping.stagedDescriptor.byteSize)
            XCTAssertEqual(mapping.finalDescriptor.role, mapping.stagedDescriptor.role)
            XCTAssertEqual(mapping.finalDescriptor.phase, .final)
            XCTAssertEqual(mapping.stagedDescriptor.phase, .staging)
        }
        XCTAssertEqual(
            result.publicationMappings.map(\.finalDescriptor.path),
            [result.bamURL.path, result.baiURL.path]
        )
    }

    func testFailedVersionDiscoveryRetainsExactCommandRecordAndLogs() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.setFailure(command: "minimap2-version")

        do {
            _ = try await fixture.build(samples: [fixture.sample("S1", clusters: ["c1"])])
            XCTFail("Expected version discovery failure")
        } catch let error as FullLengthONTMHCCohortAlignmentBuildError {
            let record = try XCTUnwrap(error.toolVersionDiscoveryRecords.first)
            XCTAssertEqual(error.toolVersionDiscoveryRecords.count, 1)
            XCTAssertEqual(record.argv, [
                fixture.toolsURL.appendingPathComponent("minimap2").path,
                "--version",
            ])
            XCTAssertEqual(record.exitStatus, 42)
            XCTAssertTrue(record.stderr.contains("forced minimap2 version failure"))
            XCTAssertEqual(record.toolVersion, nil)
            XCTAssertTrue(FileManager.default.fileExists(atPath: record.stdoutLogDescriptor.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: record.stderrLogDescriptor.path))
            XCTAssertEqual(
                error.artifactDescriptors.filter { $0.role == .commandStderrLog }.last,
                record.stderrLogDescriptor
            )
        }
        XCTAssertEqual(try fixture.commands(), [])
    }

    func testCommandDiagnosticsAreBoundedInMemoryAndFullOutputLogsAreRetained() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.setNoisyCommand(command: "idxstats")

        let result = try await fixture.build(
            samples: [fixture.sample("S1", clusters: ["c1"])],
            keepIntermediates: true
        )

        let idxstats = try XCTUnwrap(result.commandRecords.last)
        XCTAssertEqual(idxstats.arguments.first, "idxstats")
        XCTAssertLessThanOrEqual(idxstats.stdout.utf8.count, 65_536)
        XCTAssertLessThanOrEqual(idxstats.stderr.utf8.count, 65_536)
        XCTAssertGreaterThan(idxstats.stdoutLogDescriptor.byteSize, 100_000)
        XCTAssertGreaterThan(idxstats.stderrLogDescriptor.byteSize, 100_000)
        XCTAssertTrue(FileManager.default.fileExists(atPath: idxstats.stdoutLogDescriptor.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: idxstats.stderrLogDescriptor.path))
        XCTAssertEqual(
            idxstats.stdoutLogDescriptor.sha256,
            try ProvenanceFileHasher.sha256(of: URL(fileURLWithPath: idxstats.stdoutLogDescriptor.path))
        )
        XCTAssertEqual(
            idxstats.stderrLogDescriptor.sha256,
            try ProvenanceFileHasher.sha256(of: URL(fileURLWithPath: idxstats.stderrLogDescriptor.path))
        )
    }

    func testSuccessfulAtomicDirectoryPublicationPreservesUnrelatedAlignmentArtifacts() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let reciprocalBAMURL = fixture.finalBAMURL.deletingLastPathComponent()
            .appendingPathComponent("reciprocal-evidence.bam")
        try FileManager.default.createDirectory(
            at: reciprocalBAMURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("reciprocal-bam".utf8).write(to: reciprocalBAMURL)

        let result = try await fixture.build(samples: [fixture.sample("S1", clusters: ["c1"])])

        XCTAssertEqual(try String(contentsOf: reciprocalBAMURL, encoding: .utf8), "reciprocal-bam")
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.bamURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.baiURL.path))
    }

    func testFailureBeforePublicationRetainsTemporaryFilesAndPublishesNoPair() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.setFailure(command: "quickcheck")

        var retained: URL?
        do {
            _ = try await fixture.build(samples: [fixture.sample("S1", clusters: ["c1"])])
            XCTFail("Expected quickcheck failure")
        } catch let error as FullLengthONTMHCCohortAlignmentBuildError {
            retained = error.retainedWorkDirectoryURL
        }

        XCTAssertNotNil(retained)
        XCTAssertTrue(FileManager.default.fileExists(atPath: retained!.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.finalBAMURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.finalBAIURL.path))
        XCTAssertTrue(try recursiveFiles(at: retained!).contains { $0.pathExtension == "bam" })
    }

    func testSuccessRemovesTemporaryFilesUnlessKeepIntermediatesIsTrue() async throws {
        let cleanupFixture = try Fixture()
        defer { cleanupFixture.remove() }
        let cleaned = try await cleanupFixture.build(samples: [cleanupFixture.sample("S1", clusters: ["c1"])])
        XCTAssertFalse(FileManager.default.fileExists(atPath: cleaned.temporaryWorkDirectoryURL.path))

        let retainedFixture = try Fixture()
        defer { retainedFixture.remove() }
        let retained = try await retainedFixture.build(
            samples: [retainedFixture.sample("S1", clusters: ["c1"])],
            keepIntermediates: true
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: retained.temporaryWorkDirectoryURL.path))
        XCTAssertTrue(try recursiveFiles(at: retained.temporaryWorkDirectoryURL).contains {
            $0.lastPathComponent.hasSuffix(".namespaced-clusters.fa")
        })
    }

    func testValidationFailureDoesNotReplaceExistingFinalPair() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(
            at: fixture.finalBAMURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("old-bam".utf8).write(to: fixture.finalBAMURL)
        try Data("old-bai".utf8).write(to: fixture.finalBAIURL)
        try Data().write(to: fixture.toolsURL.appendingPathComponent("allow-existing-final"))
        try fixture.setFailure(command: "idxstats")

        await XCTAssertThrowsErrorAsync {
            _ = try await fixture.build(samples: [fixture.sample("S1", clusters: ["c1"])])
        }

        XCTAssertEqual(try String(contentsOf: fixture.finalBAMURL, encoding: .utf8), "old-bam")
        XCTAssertEqual(try String(contentsOf: fixture.finalBAIURL, encoding: .utf8), "old-bai")
    }

    func testAtomicDirectoryPublicationFailureLeavesExistingPairUnmixedAndRetainsDiagnostics() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(
            at: fixture.finalBAMURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("old-bam".utf8).write(to: fixture.finalBAMURL)
        try Data("old-bai".utf8).write(to: fixture.finalBAIURL)
        try Data().write(to: fixture.toolsURL.appendingPathComponent("allow-existing-final"))

        var publicationDiagnostics: URL?
        do {
            _ = try await fixture.build(
                samples: [fixture.sample("S1", clusters: ["c1"])],
                publisher: FailingAtomicAlignmentDirectoryPublisher()
            )
            XCTFail("Expected atomic publication failure")
        } catch let error as FullLengthONTMHCCohortAlignmentBuildError {
            publicationDiagnostics = error.retainedPublicationDirectoryURL
        }

        XCTAssertEqual(try String(contentsOf: fixture.finalBAMURL, encoding: .utf8), "old-bam")
        XCTAssertEqual(try String(contentsOf: fixture.finalBAIURL, encoding: .utf8), "old-bai")
        XCTAssertNotNil(publicationDiagnostics)
        XCTAssertTrue(FileManager.default.fileExists(atPath: publicationDiagnostics!.path))
        XCTAssertNotEqual(
            try String(
                contentsOf: publicationDiagnostics!.appendingPathComponent("genotyping-evidence.bam"),
                encoding: .utf8
            ),
            "old-bam"
        )
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: publicationDiagnostics!.appendingPathComponent("genotyping-evidence.bam.bai").path
        ))
        XCTAssertEqual(try fixture.commands().last?.dropFirst().first, "idxstats")
    }

    func testRetiredDirectoryCleanupFailureKeepsPublishedPairAndReportsDiagnostic() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(
            at: fixture.finalBAMURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("old-bam".utf8).write(to: fixture.finalBAMURL)
        try Data("old-bai".utf8).write(to: fixture.finalBAIURL)
        try Data().write(to: fixture.toolsURL.appendingPathComponent("allow-existing-final"))

        let result = try await fixture.build(
            samples: [fixture.sample("S1", clusters: ["c1"])],
            publisher: CleanupFailingAtomicAlignmentDirectoryPublisher()
        )

        XCTAssertNotEqual(try String(contentsOf: result.bamURL, encoding: .utf8), "old-bam")
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.baiURL.path))
        let retiredDirectoryURL = try XCTUnwrap(result.retainedPublicationDirectoryURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: retiredDirectoryURL.path))
        XCTAssertEqual(
            try String(
                contentsOf: retiredDirectoryURL.appendingPathComponent("genotyping-evidence.bam"),
                encoding: .utf8
            ),
            "old-bam"
        )
        XCTAssertEqual(result.publicationCleanupError, "forced retired-directory cleanup failure")
        XCTAssertEqual(result.cleanupDiagnostics.map(\.kind), [.retiredPublicationDirectory])
        XCTAssertTrue(result.cleanupDiagnostics.allSatisfy(\.publishedArtifactsRemainValid))
    }

    func testWorkDirectoryCleanupFailureReturnsTypedDiagnosticWithValidPublishedPair() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let result = try await fixture.build(
            samples: [fixture.sample("S1", clusters: ["c1"])],
            workDirectoryCleaner: FailingWorkDirectoryCleaner()
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: result.bamURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.baiURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.temporaryWorkDirectoryURL.path))
        let diagnostic = try XCTUnwrap(result.cleanupDiagnostics.first {
            $0.kind == .temporaryWorkDirectory
        })
        XCTAssertEqual(diagnostic.retainedDirectoryURL, result.temporaryWorkDirectoryURL)
        XCTAssertEqual(diagnostic.message, "forced work-directory cleanup failure")
        XCTAssertTrue(diagnostic.publishedArtifactsRemainValid)
    }

    func testPublicationLockContentionCannotOverwriteOrLoseUnrelatedArtifact() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let artifactsDirectoryURL = fixture.outputURL.appendingPathComponent("artifacts", isDirectory: true)
        let alignmentsDirectoryURL = artifactsDirectoryURL.appendingPathComponent("alignments", isDirectory: true)
        try FileManager.default.createDirectory(at: alignmentsDirectoryURL, withIntermediateDirectories: true)
        let unrelatedURL = alignmentsDirectoryURL.appendingPathComponent("reciprocal-evidence.bam")
        try Data("unrelated-original".utf8).write(to: unrelatedURL)

        let publisher = DarwinAtomicAlignmentDirectoryPublisher()
        let heldLock = try publisher.acquirePublicationLock(artifactsDirectoryURL: artifactsDirectoryURL)
        defer { heldLock.release() }

        await XCTAssertThrowsErrorAsync {
            _ = try await fixture.build(
                samples: [fixture.sample("S1", clusters: ["c1"])],
                publisher: publisher
            )
        }

        XCTAssertEqual(try String(contentsOf: unrelatedURL, encoding: .utf8), "unrelated-original")
        let stagedDirectories = try FileManager.default.contentsOfDirectory(
            at: artifactsDirectoryURL,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix(".alignments-replacement-") }
        XCTAssertEqual(stagedDirectories, [])
    }

    func testCancellationTerminatesChildRetainsDiagnosticsAndNeverPublishes() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.setSleepingCommand(command: "view")

        let buildTask = Task {
            try await fixture.build(samples: [fixture.sample("S1", clusters: ["c1"])])
        }
        let childPIDURL = fixture.toolsURL.appendingPathComponent("sleeping-child.pid")
        try await waitForFile(childPIDURL)
        let childPID = try XCTUnwrap(Int32(
            String(contentsOf: childPIDURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        ))
        buildTask.cancel()

        do {
            _ = try await buildTask.value
            XCTFail("Expected cancellation")
        } catch let error as FullLengthONTMHCCohortAlignmentBuildError {
            XCTAssertTrue(error.wasCancelled)
            XCTAssertTrue(FileManager.default.fileExists(atPath: error.retainedWorkDirectoryURL.path))
            XCTAssertEqual(error.commandRecords.last?.arguments.first, "view")
            XCTAssertTrue(error.commandRecords.last?.wasCancelled == true)
            let stderrLogPath = try XCTUnwrap(error.commandRecords.last?.stderrLogDescriptor.path)
            XCTAssertTrue(FileManager.default.fileExists(atPath: stderrLogPath))
            XCTAssertFalse(error.artifactDescriptors.isEmpty)
            XCTAssertEqual(error.toolVersions.map(\.toolName), ["minimap2", "samtools"])
        }

        XCTAssertNotEqual(Darwin.kill(childPID, 0), 0, "cancelled child must be reaped")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.finalBAMURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.finalBAIURL.path))
        XCTAssertEqual(try fixture.commands().compactMap { $0.dropFirst().first }, ["-a", "view"])
    }

    func testMissingDeclaredOutputFailsEvenWhenToolExitsZero() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.setMissingOutput(command: "view")

        var retained: URL?
        do {
            _ = try await fixture.build(samples: [fixture.sample("S1", clusters: ["c1"])])
            XCTFail("Expected missing output failure")
        } catch let error as FullLengthONTMHCCohortAlignmentBuildError {
            retained = error.retainedWorkDirectoryURL
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: retained?.path ?? ""))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.finalBAMURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.finalBAIURL.path))
    }

    func testRejectsUnsafeOrDuplicateSampleIDsAndDuplicateNamespacedTargets() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        for samples in [
            [fixture.sample("../unsafe", clusters: ["c1"])],
            [fixture.sample("duplicate", clusters: ["c1"]), fixture.sample("duplicate", clusters: ["c2"])],
            [fixture.sample("S1", clusters: ["same", "same"])],
        ] {
            await XCTAssertThrowsErrorAsync {
                _ = try await fixture.build(samples: samples)
            }
        }
        XCTAssertEqual(try fixture.commands(), [])
    }

    func testRejectsSymlinkedScientificInputsWithoutRunningTools() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let realClustersURL = fixture.root.appendingPathComponent("real-clusters.fa")
        let linkedClustersURL = fixture.root.appendingPathComponent("linked-clusters.fa")
        try ">c1\nACGT\n".write(to: realClustersURL, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: linkedClustersURL,
            withDestinationURL: realClustersURL
        )
        let sample = FullLengthONTMHCSampleAlignmentInput(
            sampleID: "S1",
            originalClustersFASTAURL: linkedClustersURL,
            clusterRecords: [.init(name: "c1", sequence: "ACGT", readCount: 1)]
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await fixture.build(samples: [sample])
        }

        XCTAssertEqual(try fixture.commands(), [])
    }

    func testRejectsSymlinkedAlignmentDirectoryWithoutTouchingExternalArtifacts() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let externalDirectoryURL = fixture.root.appendingPathComponent("external-alignments", isDirectory: true)
        let artifactsDirectoryURL = fixture.outputURL.appendingPathComponent("artifacts", isDirectory: true)
        try FileManager.default.createDirectory(at: externalDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: artifactsDirectoryURL, withIntermediateDirectories: true)
        let externalBAMURL = externalDirectoryURL.appendingPathComponent("genotyping-evidence.bam")
        let externalBAIURL = externalDirectoryURL.appendingPathComponent("genotyping-evidence.bam.bai")
        let sentinelURL = externalDirectoryURL.appendingPathComponent("sentinel.txt")
        try Data("external-old-bam".utf8).write(to: externalBAMURL)
        try Data("external-old-bai".utf8).write(to: externalBAIURL)
        try Data("external-sentinel".utf8).write(to: sentinelURL)
        try FileManager.default.createSymbolicLink(
            at: artifactsDirectoryURL.appendingPathComponent("alignments"),
            withDestinationURL: externalDirectoryURL
        )
        try fixture.setFailure(command: "quickcheck")

        await XCTAssertThrowsErrorAsync {
            _ = try await fixture.build(samples: [fixture.sample("S1", clusters: ["c1"])])
        }

        XCTAssertEqual(try String(contentsOf: externalBAMURL, encoding: .utf8), "external-old-bam")
        XCTAssertEqual(try String(contentsOf: externalBAIURL, encoding: .utf8), "external-old-bai")
        XCTAssertEqual(try String(contentsOf: sentinelURL, encoding: .utf8), "external-sentinel")
        XCTAssertEqual(try fixture.commands(), [])
    }

    func testRejectsOverlappingWorkAndOutputDirectories() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.outputURL, withIntermediateDirectories: true)

        await XCTAssertThrowsErrorAsync {
            _ = try await fixture.build(
                samples: [fixture.sample("S1", clusters: ["c1"])],
                workDirectoryURL: fixture.outputURL
            )
        }

        XCTAssertEqual(try fixture.commands(), [])
    }

    func testRequiresSourceFASTAToMatchDeclaredClusterRecordsExactly() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let sample = fixture.sample("S1", clusters: ["c1"])
        try ">c1\nTGCA\n".write(
            to: sample.originalClustersFASTAURL,
            atomically: true,
            encoding: .utf8
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await fixture.build(samples: [sample])
        }

        XCTAssertEqual(try fixture.commands(), [])
    }

    func testRejectsUnsafeClusterIdentifiersAndInvalidOrEmptyIUPACSequences() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let invalidRecords: [(String, String)] = [
            ("contains|separator", "ACGT"),
            ("nonascii-ß", "ACGT"),
            ("valid-id", ""),
            ("valid-id", "ACGTZ"),
        ]

        for (index, invalid) in invalidRecords.enumerated() {
            let sourceURL = fixture.root.appendingPathComponent("invalid-\(index).fa")
            try ">\(invalid.0)\n\(invalid.1)\n".write(
                to: sourceURL,
                atomically: true,
                encoding: .utf8
            )
            let sample = FullLengthONTMHCSampleAlignmentInput(
                sampleID: "S\(index)",
                originalClustersFASTAURL: sourceURL,
                clusterRecords: [.init(name: invalid.0, sequence: invalid.1, readCount: 1)]
            )
            await XCTAssertThrowsErrorAsync {
                _ = try await fixture.build(samples: [sample])
            }
        }

        XCTAssertEqual(try fixture.commands(), [])
    }
}

    private final class Fixture: @unchecked Sendable {
    let root: URL
    let toolsURL: URL
    let outputURL: URL
    let workURL: URL
    let referenceURL: URL

    var finalBAMURL: URL { outputURL.appendingPathComponent("artifacts/alignments/genotyping-evidence.bam") }
    var finalBAIURL: URL { outputURL.appendingPathComponent("artifacts/alignments/genotyping-evidence.bam.bai") }

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cohort-alignment-builder-tests-\(UUID().uuidString)", isDirectory: true)
        toolsURL = root.appendingPathComponent("tools", isDirectory: true)
        outputURL = root.appendingPathComponent("result.lungfishgenotype", isDirectory: true)
        workURL = root.appendingPathComponent("work", isDirectory: true)
        referenceURL = root.appendingPathComponent("alleles.fa")
        try FileManager.default.createDirectory(at: toolsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workURL, withIntermediateDirectories: true)
        try ">allele-1\nACGT\n".write(to: referenceURL, atomically: true, encoding: .utf8)
        try Self.writeExecutable(Self.minimap2Script, to: toolsURL.appendingPathComponent("minimap2"))
        try Self.writeExecutable(Self.samtoolsScript, to: toolsURL.appendingPathComponent("samtools"))
        try finalBAMURL.path.write(
            to: toolsURL.appendingPathComponent("final-bam-path"),
            atomically: true,
            encoding: .utf8
        )
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func sample(_ id: String, clusters: [String]) -> FullLengthONTMHCSampleAlignmentInput {
        let source = root.appendingPathComponent("\(id.replacingOccurrences(of: "/", with: "_")).clusters.fa")
        try? clusters.map { ">\($0)\nACGT\n" }.joined().write(to: source, atomically: true, encoding: .utf8)
        return FullLengthONTMHCSampleAlignmentInput(
            sampleID: id,
            originalClustersFASTAURL: source,
            clusterRecords: clusters.map {
                FullLengthONTMHCClusterFASTARecord(name: $0, sequence: "ACGT", readCount: 1)
            }
        )
    }

    func build(
        samples: [FullLengthONTMHCSampleAlignmentInput],
        keepIntermediates: Bool = false,
        publisher: any FullLengthONTMHCAlignmentDirectoryPublishing = DarwinAtomicAlignmentDirectoryPublisher(),
        workDirectoryCleaner: any FullLengthONTMHCWorkDirectoryCleaning = DefaultFullLengthONTMHCWorkDirectoryCleaner(),
        artifactDescriptorProvider: (any FullLengthONTMHCArtifactDescriptorProviding)? = nil,
        outputDirectoryURL: URL? = nil,
        workDirectoryURL: URL? = nil
    ) async throws -> FullLengthONTMHCCohortAlignmentResult {
        let builder: FullLengthONTMHCCohortAlignmentBuilder
        if let artifactDescriptorProvider {
            builder = FullLengthONTMHCCohortAlignmentBuilder(
                executableDirectoryURL: toolsURL,
                alignmentDirectoryPublisher: publisher,
                workDirectoryCleaner: workDirectoryCleaner,
                artifactDescriptorProvider: artifactDescriptorProvider
            )
        } else {
            builder = FullLengthONTMHCCohortAlignmentBuilder(
                executableDirectoryURL: toolsURL,
                alignmentDirectoryPublisher: publisher,
                workDirectoryCleaner: workDirectoryCleaner
            )
        }
        return try await builder.build(
            .init(
                samples: samples,
                referenceAlleleFASTAURL: referenceURL,
                threads: 4,
                outputDirectoryURL: outputDirectoryURL ?? outputURL,
                workDirectoryURL: workDirectoryURL ?? workURL,
                keepIntermediates: keepIntermediates
            )
        )
    }

    func setFailure(command: String) throws {
        try command.write(to: toolsURL.appendingPathComponent("fail-command"), atomically: true, encoding: .utf8)
    }

    func setMissingOutput(command: String) throws {
        try command.write(to: toolsURL.appendingPathComponent("missing-output-command"), atomically: true, encoding: .utf8)
    }

    func setNoisyCommand(command: String) throws {
        try command.write(to: toolsURL.appendingPathComponent("noisy-command"), atomically: true, encoding: .utf8)
    }

    func setSleepingCommand(command: String) throws {
        try command.write(to: toolsURL.appendingPathComponent("sleep-command"), atomically: true, encoding: .utf8)
    }

    func commands() throws -> [[String]] {
        let url = toolsURL.appendingPathComponent("commands.log")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n")
            .map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
    }

    private static func writeExecutable(_ script: String, to url: URL) throws {
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private static let minimap2Script = #"""
    #!/bin/sh
    tool_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
    if [ "$1" = "--version" ]; then
      if [ -f "$tool_dir/fail-command" ] && [ "$(cat "$tool_dir/fail-command")" = "minimap2-version" ]; then
        printf 'forced minimap2 version failure\n' >&2
        exit 42
      fi
      printf 'minimap2 2.28-fake\n'
      exit 0
    fi
    printf 'minimap2' >> "$tool_dir/commands.log"
    for arg in "$@"; do printf '\t%s' "$arg" >> "$tool_dir/commands.log"; done
    printf '\n' >> "$tool_dir/commands.log"
    previous=''
    current=''
    for arg in "$@"; do previous=$current; current=$arg; done
    target=$previous
    target_id=$(awk '/^>/{sub(/^>/, ""); print $1; exit}' "$target")
    printf '@HD\tVN:1.6\tSO:unsorted\n@SQ\tSN:%s\tLN:4\nallele-1\t0\t%s\t1\t60\t4=\t*\t0\t0\tACGT\tIIII\n' "$target_id" "$target_id"
    """#

    private static let samtoolsScript = #"""
    #!/bin/sh
    tool_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
    if [ "$1" = "--version" ]; then
      printf 'samtools 1.21-fake\n'
      exit 0
    fi
    printf 'samtools' >> "$tool_dir/commands.log"
    for arg in "$@"; do printf '\t%s' "$arg" >> "$tool_dir/commands.log"; done
    printf '\n' >> "$tool_dir/commands.log"
    command=$1
    if [ -f "$tool_dir/sleep-command" ] && [ "$(cat "$tool_dir/sleep-command")" = "$command" ]; then
      printf '%s\n' "$$" > "$tool_dir/sleeping-child.pid"
      exec /bin/sleep 30
    fi
    if [ -f "$tool_dir/fail-command" ] && [ "$(cat "$tool_dir/fail-command")" = "$command" ]; then
      printf 'forced %s failure\n' "$command" >&2
      exit 42
    fi
    missing=''
    if [ -f "$tool_dir/missing-output-command" ] && [ "$(cat "$tool_dir/missing-output-command")" = "$command" ]; then
      missing=1
    fi
    shift
    case "$command" in
      view)
        [ "$1" = "-b" ] && shift
        [ "$1" = "-o" ] || exit 90
        output=$2; input=$3
        [ -n "$missing" ] || cp "$input" "$output"
        ;;
      addreplacerg)
        shift; rg_id=$1; shift
        shift; rg_sm=$1; shift
        shift; output=$1; input=$2
        if [ -z "$missing" ]; then
          printf '@RG\t%s\t%s\n' "$rg_id" "$rg_sm" > "$output"
          cat "$input" >> "$output"
        fi
        ;;
      sort)
        [ "$1" = "-o" ] || exit 91
        output=$2; input=$3
        [ -n "$missing" ] || cp "$input" "$output"
        ;;
      merge)
        [ "$1" = "-f" ] || exit 92; shift
        [ "$1" = "-o" ] || exit 93
        output=$2; shift 2
        if [ -z "$missing" ]; then
          : > "$output"
          for input in "$@"; do cat "$input" >> "$output"; done
        fi
        ;;
      index)
        input=$1; output=$2
        [ -n "$missing" ] || cp "$input" "$output"
        ;;
      quickcheck|idxstats)
        input=$1
        final_path=$(cat "$tool_dir/final-bam-path")
        if [ -e "$final_path" ] && [ ! -f "$tool_dir/allow-existing-final" ]; then
          printf 'final BAM published before %s\n' "$command" >&2
          exit 77
        fi
        [ -f "$input" ] || exit 94
        [ -f "$input.bai" ] || exit 95
        if [ -f "$tool_dir/noisy-command" ] && [ "$(cat "$tool_dir/noisy-command")" = "$command" ]; then
          yes 'full-stdout-diagnostic' | head -c 200000
          yes 'full-stderr-diagnostic' | head -c 200000 >&2
        fi
        [ "$command" = "idxstats" ] && printf 'sample-target\t4\t1\t0\n'
        ;;
      *) exit 99 ;;
    esac
    exit 0
    """#
}

private final class PublicationBoundaryState: @unchecked Sendable {
    private let lock = NSLock()
    private var published = false
    private var descriptorAttemptsAfterPublication = 0

    var wasPublished: Bool { lock.withLock { published } }
    var postPublicationDescriptorAttempts: Int { lock.withLock { descriptorAttemptsAfterPublication } }

    func markPublished() {
        lock.withLock { published = true }
    }

    func recordDescriptorAttempt() throws {
        let attemptedAfterPublication = lock.withLock { () -> Bool in
            guard published else { return false }
            descriptorAttemptsAfterPublication += 1
            return true
        }
        if attemptedAfterPublication { throw PostPublicationDescriptorFailure() }
    }

    private struct PostPublicationDescriptorFailure: Error {}
}

private struct RejectingPostPublicationArtifactDescriptorProvider: FullLengthONTMHCArtifactDescriptorProviding {
    let boundary: PublicationBoundaryState

    func descriptor(
        for url: URL,
        role: FullLengthONTMHCArtifactRole,
        phase: FullLengthONTMHCArtifactPhase
    ) throws -> FullLengthONTMHCArtifactDescriptor {
        try boundary.recordDescriptorAttempt()
        return try DefaultFullLengthONTMHCArtifactDescriptorProvider().descriptor(
            for: url,
            role: role,
            phase: phase
        )
    }
}

private struct BoundaryTrackingAlignmentDirectoryPublisher: FullLengthONTMHCAlignmentDirectoryPublishing {
    let boundary: PublicationBoundaryState

    func publish(
        stagedDirectoryURL: URL,
        finalDirectoryURL: URL
    ) throws -> FullLengthONTMHCAlignmentDirectoryPublication {
        let publication = try DarwinAtomicAlignmentDirectoryPublisher().publish(
            stagedDirectoryURL: stagedDirectoryURL,
            finalDirectoryURL: finalDirectoryURL
        )
        boundary.markPublished()
        return publication
    }
}

private struct FailingAtomicAlignmentDirectoryPublisher: FullLengthONTMHCAlignmentDirectoryPublishing {
    func publish(
        stagedDirectoryURL: URL,
        finalDirectoryURL: URL
    ) throws -> FullLengthONTMHCAlignmentDirectoryPublication {
        throw CocoaError(.fileWriteUnknown)
    }
}

private struct CleanupFailingAtomicAlignmentDirectoryPublisher: FullLengthONTMHCAlignmentDirectoryPublishing {
    func publish(
        stagedDirectoryURL: URL,
        finalDirectoryURL: URL
    ) throws -> FullLengthONTMHCAlignmentDirectoryPublication {
        try DarwinAtomicAlignmentDirectoryPublisher().publish(
            stagedDirectoryURL: stagedDirectoryURL,
            finalDirectoryURL: finalDirectoryURL
        )
    }

    func cleanupRetiredDirectory(at url: URL) throws {
        throw CleanupFailure()
    }

    private struct CleanupFailure: Error, LocalizedError {
        var errorDescription: String? { "forced retired-directory cleanup failure" }
    }
}

private struct FailingWorkDirectoryCleaner: FullLengthONTMHCWorkDirectoryCleaning {
    func removeWorkDirectory(at url: URL) throws {
        throw CleanupFailure()
    }

    private struct CleanupFailure: Error, LocalizedError {
        var errorDescription: String? { "forced work-directory cleanup failure" }
    }
}

private func recursiveFiles(at root: URL) throws -> [URL] {
    let keys: [URLResourceKey] = [.isRegularFileKey]
    guard let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: keys
    ) else { return [] }
    return enumerator.compactMap { $0 as? URL }.filter {
        (try? $0.resourceValues(forKeys: Set(keys)).isRegularFile) == true
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {}
}

private func waitForFile(
    _ url: URL,
    file: StaticString = #filePath,
    line: UInt = #line
) async throws {
    for _ in 0..<200 {
        if FileManager.default.fileExists(atPath: url.path) { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Timed out waiting for \(url.path)", file: file, line: line)
}
