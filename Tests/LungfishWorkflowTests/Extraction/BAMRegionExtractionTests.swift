import Foundation
import XCTest
@testable import LungfishIO
@testable import LungfishWorkflow

final class BAMRegionExtractionTests: XCTestCase {
    /// Catches implicit-index extraction, an off-by-one selected scope, and
    /// dropped evidence filters in the scientific execution plan.
    func testExplicitIndexPlanUsesSelectedHalfOpenScopeAndEvidenceFilters() {
        let config = BAMRegionExtractionConfig(
            bamURL: URL(fileURLWithPath: "/evidence/sample.bam"),
            indexURL: URL(fileURLWithPath: "/evidence/sample.bam.bai"),
            decodingReferenceURL: nil,
            regions: ["chrSynthetic:5-9"],
            minMapQ: 30,
            excludedFlags: 0x904,
            readGroups: ["normal", "tumor"],
            outputDirectory: URL(fileURLWithPath: "/out"),
            outputBaseName: "selected"
        )

        XCTAssertEqual(
            config.explicitViewArguments(outputBAM: URL(fileURLWithPath: "/stage/extracted.bam")),
            ["view", "-b", "-q", "30", "-F", "2308", "-r", "normal", "-r", "tumor",
             "-o", "/stage/extracted.bam", "-X", "/evidence/sample.bam", "/evidence/sample.bam.bai", "chrSynthetic:5-9"]
        )
    }

    /// Catches a publication regression where the viewer can receive a raw
    /// staging FASTQ, or canonical provenance continues to identify a staging
    /// payload after the scientific artifact has been published.
    func testBundlePublicationRewritesStagedPayloadDescriptorsToFinalPaths() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("alignment-transaction-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let stagingDirectory = root.appendingPathComponent(".staging", isDirectory: true)
        let stagedFASTQ = stagingDirectory.appendingPathComponent("selected.fastq")
        let finalBundle = root.appendingPathComponent("selected.lungfishfastq", isDirectory: true)
        try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        try "@selected\nACGT\n+\n!!!!\n".write(to: stagedFASTQ, atomically: true, encoding: .utf8)

        let stagedDescriptor = try ProvenanceFileDescriptor.file(
            url: stagedFASTQ,
            format: .fastq,
            role: .output
        )
        let transaction = try AlignmentReadExtractionTransaction(
            stagingDirectoryURL: stagingDirectory,
            stagedFiles: [
                .init(
                    stagedURL: stagedFASTQ,
                    relativeFinalPath: "selected.fastq",
                    format: .fastq
                ),
            ],
            readCount: 1,
            pairedEnd: false,
            executionRecords: [
                .init(
                    stage: .payloadStaging,
                    toolName: "samtools",
                    toolVersion: "1.23",
                    argv: ["/managed/samtools", "fastq", stagedFASTQ.path],
                    inputs: [],
                    outputs: [stagedDescriptor],
                    exitStatus: 0,
                    startedAt: Date(timeIntervalSince1970: 10),
                    completedAt: Date(timeIntervalSince1970: 11)
                ),
            ],
            startedAt: Date(timeIntervalSince1970: 10)
        )

        let result = try AlignmentReadExtractionPublisher().publish(
            .init(
                transaction: transaction,
                destination: .bundle(finalBundle),
                provenance: .init(
                    workflowName: "lungfish alignment read extraction",
                    argv: ["lungfish-cli", "alignment", "extract"],
                    explicitOptions: ["scope": .string("selected-region")],
                    inputURLs: []
                )
            )
        )

        let finalPayload = finalBundle.appendingPathComponent("selected.fastq")
        XCTAssertEqual(result.finalURL, finalBundle)
        XCTAssertEqual(result.outputURLs, [finalPayload])
        XCTAssertFalse(fileManager.fileExists(atPath: stagingDirectory.path))

        let provenance = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: finalBundle))
        XCTAssertEqual(provenance.output?.path, finalPayload.path)
        XCTAssertTrue(provenance.outputs.contains { $0.path == finalPayload.path })
        XCTAssertFalse(provenance.outputs.contains { $0.path.contains(".staging") })
        XCTAssertFalse(provenance.steps.flatMap(\.outputs).contains { $0.path.contains(".staging") })
        XCTAssertEqual(
            provenance.options.resolvedDefaults["stagingToFinalMapping"]?.dictionaryValue?[stagedFASTQ.path]?.stringValue,
            finalPayload.path
        )
    }

    /// Catches region extraction escaping to a caller-owned output directory,
    /// dropping explicit-index/filter argv, or returning a staged payload
    /// without checksummed scientific execution records.
    func testRegionStagerUsesExplicitIndexAndOwnsChecksummedTransaction() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("alignment-region-stage-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        let bamURL = root.appendingPathComponent("evidence.bam")
        let indexURL = root.appendingPathComponent("evidence.bam.bai")
        try Data(repeating: 0x42, count: 128).write(to: bamURL)
        try Data(repeating: 0x49, count: 32).write(to: indexURL)
        let config = BAMRegionExtractionConfig(
            bamURL: bamURL,
            indexURL: indexURL,
            regions: ["chrSynthetic:5-9"],
            minMapQ: 30,
            excludedFlags: 0x904,
            readGroups: ["normal"],
            outputDirectory: root.appendingPathComponent("caller-output", isDirectory: true),
            outputBaseName: "selected",
            deduplicateReads: false
        )

        let stager = AlignmentReadExtractionStager(
            processRunner: { tool, arguments, _ in
                XCTAssertEqual(tool, .samtools)
                if arguments.starts(with: ["view", "-b"]) {
                    let output = URL(fileURLWithPath: arguments[arguments.firstIndex(of: "-o")! + 1])
                    try Data(repeating: 0x56, count: 128).write(to: output)
                    return .init(exitCode: 0, stdout: "", stderr: "", arguments: ["/fixture/samtools"] + arguments)
                }
                if arguments.starts(with: ["view", "-c"]) {
                    return .init(exitCode: 0, stdout: "1\n", stderr: "", arguments: ["/fixture/samtools"] + arguments)
                }
                if arguments.starts(with: ["fastq"]) {
                    let output = URL(fileURLWithPath: arguments[arguments.firstIndex(of: "-0")! + 1])
                    try "@selected\nACGT\n+\n!!!!\n".write(to: output, atomically: true, encoding: .utf8)
                    return .init(exitCode: 0, stdout: "", stderr: "", arguments: ["/fixture/samtools"] + arguments)
                }
                XCTFail("Unexpected command: \(arguments)")
                return .init(exitCode: 1, stdout: "", stderr: "unexpected", arguments: arguments)
            },
            toolIdentityResolver: { _ in
                .init(executablePath: "/fixture/samtools", executableChecksumSHA256: "fixture", version: "1.23")
            }
        )

        let transaction = try await stager.stageRegion(config: config)

        XCTAssertNotEqual(transaction.stagingDirectoryURL, config.outputDirectory)
        XCTAssertFalse(fileManager.fileExists(atPath: config.outputDirectory.path))
        XCTAssertEqual(transaction.readCount, 1)
        XCTAssertEqual(transaction.stagedFiles.count, 1)
        XCTAssertFalse(try ProvenanceFileHasher.sha256(of: transaction.stagedFiles[0].stagedURL).isEmpty)
        XCTAssertEqual(transaction.executionRecords.count, 4)
        XCTAssertEqual(
            Array(transaction.executionRecords[0].argv.dropFirst()),
            config.explicitViewArguments(
                outputBAM: transaction.stagingDirectoryURL.appendingPathComponent("selected.filtered.bam")
            )
        )
        XCTAssertEqual(
            transaction.executionRecords[0].visibleOptions["regionsOneBasedInclusive"],
            .array([.string("chrSynthetic:5-9")])
        )
        XCTAssertEqual(
            transaction.executionRecords[0].resolvedDefaults["explicitIndexRequired"],
            .boolean(true)
        )
        let outputRecords = transaction.executionRecords.filter { !$0.outputs.isEmpty }
        XCTAssertEqual(outputRecords.count, 3)
        XCTAssertTrue(outputRecords.allSatisfy { record in
            record.exitStatus == 0 && record.outputs.allSatisfy { descriptor in
                descriptor.checksumSHA256 != nil && descriptor.fileSize != nil
            }
        })
        transaction.cleanup()
    }

    /// Source FASTQ staging must be preferred-capable without allowing the
    /// legacy caller output directory to become a scientific output path.
    func testSourceFASTQStagerStagesPairedPayloadsAndMissingSequenceEvidence() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("alignment-source-stage-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        let sourceR1 = root.appendingPathComponent("source_R1.fastq.gz")
        let sourceR2 = root.appendingPathComponent("source_R2.fastq.gz")
        try Data(repeating: 0x31, count: 32).write(to: sourceR1)
        try Data(repeating: 0x32, count: 32).write(to: sourceR2)
        let config = ReadIDExtractionConfig(
            sourceFASTQs: [sourceR1, sourceR2],
            readIDs: ["selected/1"],
            keepReadPairs: true,
            outputDirectory: root.appendingPathComponent("caller-output", isDirectory: true),
            outputBaseName: "selected"
        )

        let stager = AlignmentReadExtractionStager(
            processRunner: { tool, arguments, _ in
                if tool == .seqkit, arguments.first == "grep" {
                    XCTAssertTrue(arguments.contains("-r"))
                    let patternURL = URL(fileURLWithPath: arguments[arguments.firstIndex(of: "-f")! + 1])
                    XCTAssertEqual(
                        try String(contentsOf: patternURL, encoding: .utf8),
                        "^selected(/[12])?$"
                    )
                    let output = URL(fileURLWithPath: arguments[arguments.firstIndex(of: "-o")! + 1])
                    try "@selected\nACGT\n+\n!!!!\n".write(to: output, atomically: true, encoding: .utf8)
                    return .init(exitCode: 0, stdout: "", stderr: "", arguments: ["/fixture/seqkit"] + arguments)
                }
                if tool == .seqkit, arguments.first == "stats" {
                    return .init(
                        exitCode: 0,
                        stdout: "file\tformat\ttype\tnum_seqs\nfixture\tFASTQ\tDNA\t1\n",
                        stderr: "",
                        arguments: ["/fixture/seqkit"] + arguments
                    )
                }
                XCTFail("Unexpected command: \(tool) \(arguments)")
                return .init(exitCode: 1, stdout: "", stderr: "unexpected", arguments: arguments)
            },
            toolIdentityResolver: { tool in
                .init(executablePath: "/fixture/\(tool.rawValue)", executableChecksumSHA256: "fixture", version: "1.23")
            }
        )

        let transaction = try await stager.stageReadIDsFromSourceFASTQs(
            config: config,
            recordsWithoutSequence: 2,
            missingSequenceMessage: "Two selected records have no retained sequence."
        )

        XCTAssertFalse(fileManager.fileExists(atPath: config.outputDirectory.path))
        XCTAssertTrue(transaction.pairedEnd)
        XCTAssertEqual(transaction.readCount, 1)
        XCTAssertEqual(transaction.recordsWithoutSequence, 2)
        XCTAssertEqual(transaction.missingSequenceMessage, "Two selected records have no retained sequence.")
        XCTAssertEqual(
            transaction.stagedFiles.map(\.relativeFinalPath),
            ["selected_R1.fastq.gz", "selected_R2.fastq.gz"]
        )
        XCTAssertEqual(transaction.executionRecords.count, 3)
        XCTAssertTrue(transaction.executionRecords.allSatisfy { $0.exitStatus == 0 })
        XCTAssertEqual(transaction.executionRecords[0].visibleOptions["keepReadPairs"], .boolean(true))
        XCTAssertEqual(transaction.executionRecords[0].resolvedDefaults["sourcePreference"], .string("retained-source-fastq"))
        transaction.cleanup()
    }

    /// Exercises seqkit's real RE2 parser so mate-retention patterns cannot
    /// silently drift to unsupported regular-expression syntax.
    func testSourceFASTQStagerKeepsBothMatesWithManagedSeqkit() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("alignment-source-seqkit-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        let sourceR1 = root.appendingPathComponent("source_R1.fastq")
        let sourceR2 = root.appendingPathComponent("source_R2.fastq")
        try "@selected/1\nACGT\n+\n!!!!\n@other/1\nAAAA\n+\n!!!!\n"
            .write(to: sourceR1, atomically: true, encoding: .utf8)
        try "@selected/2\nTGCA\n+\n!!!!\n@other/2\nCCCC\n+\n!!!!\n"
            .write(to: sourceR2, atomically: true, encoding: .utf8)

        let transaction = try await AlignmentReadExtractionStager().stageReadIDsFromSourceFASTQs(
            config: .init(
                sourceFASTQs: [sourceR1, sourceR2],
                readIDs: ["selected/1"],
                keepReadPairs: true,
                outputDirectory: root.appendingPathComponent("caller-output", isDirectory: true),
                outputBaseName: "selected"
            )
        )
        defer { transaction.cleanup() }

        XCTAssertEqual(transaction.readCount, 1)
        XCTAssertEqual(transaction.stagedFiles.count, 2)
        let runner = NativeToolRunner.shared
        let r1Names = try await runner.run(
            .seqkit,
            arguments: ["seq", "-n", transaction.stagedFiles[0].stagedURL.path]
        )
        let r2Names = try await runner.run(
            .seqkit,
            arguments: ["seq", "-n", transaction.stagedFiles[1].stagedURL.path]
        )
        XCTAssertTrue(r1Names.isSuccess, r1Names.stderr)
        XCTAssertTrue(r2Names.isSuccess, r2Names.stderr)
        XCTAssertEqual(r1Names.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "selected/1")
        XCTAssertEqual(r2Names.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "selected/2")
    }

    /// QNAME staging is the evidence-preserving fallback when no retained
    /// source FASTQ can be used. It must retain its filter and mate policy.
    func testBAMQNAMEStagerStagesPrimaryAndSingletonPayloads() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("alignment-qname-stage-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        let bamURL = root.appendingPathComponent("evidence.bam")
        try Data(repeating: 0x42, count: 128).write(to: bamURL)
        let config = ReadIDBAMExtractionConfig(
            bamURL: bamURL,
            readIDs: ["selected"],
            includeSecondary: true,
            excludeDuplicates: true,
            format: .fasta,
            outputDirectory: root.appendingPathComponent("caller-output", isDirectory: true),
            outputBaseName: "selected"
        )

        let stager = AlignmentReadExtractionStager(
            processRunner: { tool, arguments, _ in
                XCTAssertEqual(tool, .samtools)
                if arguments.starts(with: ["view", "-b"]) {
                    let output = URL(fileURLWithPath: arguments[arguments.firstIndex(of: "-o")! + 1])
                    try Data(repeating: 0x56, count: 128).write(to: output)
                } else if arguments.starts(with: ["view", "-c"]) {
                    return .init(exitCode: 0, stdout: "2\n", stderr: "", arguments: ["/fixture/samtools"] + arguments)
                } else if arguments.first == "collate" {
                    let output = URL(fileURLWithPath: arguments[arguments.firstIndex(of: "-o")! + 1])
                    try Data(repeating: 0x43, count: 128).write(to: output)
                } else if arguments.first == "fasta" {
                    let output = URL(fileURLWithPath: arguments[arguments.firstIndex(of: "-o")! + 1])
                    let singletons = URL(fileURLWithPath: arguments[arguments.firstIndex(of: "-s")! + 1])
                    try ">selected\nACGT\n".write(to: output, atomically: true, encoding: .utf8)
                    try ">selected-mate\nTGCA\n".write(to: singletons, atomically: true, encoding: .utf8)
                } else {
                    XCTFail("Unexpected command: \(arguments)")
                    return .init(exitCode: 1, stdout: "", stderr: "unexpected", arguments: arguments)
                }
                return .init(exitCode: 0, stdout: "", stderr: "", arguments: ["/fixture/samtools"] + arguments)
            },
            toolIdentityResolver: { _ in
                .init(executablePath: "/fixture/samtools", executableChecksumSHA256: "fixture", version: "1.23")
            }
        )

        let transaction = try await stager.stageReadIDsFromBAM(
            config: config,
            recordsWithoutSequence: 1,
            missingSequenceMessage: "One selected record has no sequence."
        )

        XCTAssertFalse(fileManager.fileExists(atPath: config.outputDirectory.path))
        XCTAssertEqual(transaction.readCount, 2)
        XCTAssertEqual(transaction.recordsWithoutSequence, 1)
        XCTAssertEqual(
            transaction.stagedFiles.map(\.relativeFinalPath),
            ["selected.fasta", "selected_singletons.fasta", "selected_read_names.txt"]
        )
        XCTAssertEqual(transaction.executionRecords.count, 5)
        XCTAssertEqual(transaction.executionRecords[0].visibleOptions["includeSecondary"], .boolean(true))
        XCTAssertEqual(transaction.executionRecords[0].visibleOptions["excludeDuplicates"], .boolean(true))
        XCTAssertEqual(transaction.executionRecords[0].resolvedDefaults["matePolicy"], .string("samtools-qname-matches-both-mates; unmatched-mates-to-singletons"))
        XCTAssertTrue(transaction.executionRecords[3].argv.dropFirst().starts(with: ["fasta", "-F", "0"]))
        transaction.cleanup()
    }

    func testRegionStagerRecordsTypedLaunchCancellationAndEmptyFailures() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("alignment-region-failures-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let bamURL = root.appendingPathComponent("evidence.bam")
        let indexURL = root.appendingPathComponent("evidence.bam.bai")
        try Data(repeating: 0x42, count: 128).write(to: bamURL)
        try Data(repeating: 0x49, count: 32).write(to: indexURL)
        let config = BAMRegionExtractionConfig(
            bamURL: bamURL,
            indexURL: indexURL,
            regions: ["chrSynthetic:5-9"],
            outputDirectory: root,
            outputBaseName: "selected"
        )

        let launchFailureStager = AlignmentReadExtractionStager(
            processRunner: { _, _, _ in throw NSError(domain: "fixture", code: 17, userInfo: [NSLocalizedDescriptionKey: "launch denied"]) },
            toolIdentityResolver: { _ in .init(executablePath: "/fixture/samtools", executableChecksumSHA256: "fixture", version: "1.23") }
        )
        do {
            _ = try await launchFailureStager.stageRegion(config: config)
            XCTFail("Expected launch failure")
        } catch let failure as AlignmentReadExtractionFailure {
            XCTAssertEqual(failure.kind, .launchFailed)
            XCTAssertEqual(failure.executionRecords.count, 1)
            XCTAssertNil(failure.executionRecords[0].exitStatus)
            XCTAssertEqual(failure.executionRecords[0].stderr, "launch denied")
        }

        let cancelledStager = AlignmentReadExtractionStager(
            processRunner: { _, _, _ in throw CancellationError() },
            toolIdentityResolver: { _ in .init(executablePath: "/fixture/samtools", executableChecksumSHA256: "fixture", version: "1.23") }
        )
        do {
            _ = try await cancelledStager.stageRegion(config: config)
            XCTFail("Expected cancellation")
        } catch let failure as AlignmentReadExtractionFailure {
            XCTAssertEqual(failure.kind, .cancelled)
            XCTAssertEqual(failure.executionRecords.count, 1)
            XCTAssertNil(failure.executionRecords[0].exitStatus)
            XCTAssertEqual(failure.executionRecords[0].stderr, "Cancelled.")
        }

        let emptyStager = AlignmentReadExtractionStager(
            processRunner: { _, arguments, _ in
                if arguments.starts(with: ["view", "-b"]) {
                    let output = URL(fileURLWithPath: arguments[arguments.firstIndex(of: "-o")! + 1])
                    try Data(repeating: 0x56, count: 128).write(to: output)
                    return .init(exitCode: 0, stdout: "", stderr: "", arguments: arguments)
                }
                return .init(exitCode: 0, stdout: "0\n", stderr: "", arguments: arguments)
            },
            toolIdentityResolver: { _ in .init(executablePath: "/fixture/samtools", executableChecksumSHA256: "fixture", version: "1.23") }
        )
        do {
            _ = try await emptyStager.stageRegion(config: config)
            XCTFail("Expected empty extraction")
        } catch let failure as AlignmentReadExtractionFailure {
            XCTAssertEqual(failure.kind, .emptyExtraction)
            XCTAssertEqual(failure.executionRecords.count, 2)
            XCTAssertEqual(failure.executionRecords.last?.exitStatus, 0)
        }
    }

    func testPublisherPreservesExistingBundleAndFileOnTypedPublicationFailure() throws {
        enum FixtureError: Error { case installDenied }

        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("alignment-publication-rollback-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        func makeTransaction(named name: String) throws -> AlignmentReadExtractionTransaction {
            let staging = root.appendingPathComponent(".\(name)-staging", isDirectory: true)
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
            let payload = staging.appendingPathComponent("selected.fastq")
            try "@selected\nACGT\n+\n!!!!\n".write(to: payload, atomically: true, encoding: .utf8)
            return try AlignmentReadExtractionTransaction(
                stagingDirectoryURL: staging,
                stagedFiles: [.init(stagedURL: payload, relativeFinalPath: "selected.fastq", format: .fastq)],
                readCount: 1,
                pairedEnd: false
            )
        }

        let provenance = AlignmentReadExtractionProvenance(
            workflowName: "fixture",
            argv: ["fixture"],
            inputURLs: []
        )
        let publisher = AlignmentReadExtractionPublisher(beforeFinalInstall: { throw FixtureError.installDenied })

        let bundle = root.appendingPathComponent("selected.lungfishfastq", isDirectory: true)
        try fileManager.createDirectory(at: bundle, withIntermediateDirectories: true)
        let retainedBundleFile = bundle.appendingPathComponent("retain.txt")
        try "keep".write(to: retainedBundleFile, atomically: true, encoding: .utf8)
        let bundleTransaction = try makeTransaction(named: "bundle")
        do {
            _ = try publisher.publish(.init(transaction: bundleTransaction, destination: .bundle(bundle), provenance: provenance))
            XCTFail("Expected bundle publication failure")
        } catch let failure as AlignmentReadExtractionFailure {
            XCTAssertEqual(failure.kind, .publicationFailed)
            XCTAssertEqual(failure.executionRecords.last?.stage, .publication)
            XCTAssertEqual(failure.executionRecords.last?.exitStatus, 1)
        }
        XCTAssertEqual(try String(contentsOf: retainedBundleFile, encoding: .utf8), "keep")
        XCTAssertTrue(bundleTransaction.isCleanedUp)

        let file = root.appendingPathComponent("selected.fastq")
        let sidecar = ProvenanceRecorder.fileSidecarURL(for: file)
        try "old-payload".write(to: file, atomically: true, encoding: .utf8)
        try "old-sidecar".write(to: sidecar, atomically: true, encoding: .utf8)
        let fileTransaction = try makeTransaction(named: "file")
        do {
            _ = try publisher.publish(.init(transaction: fileTransaction, destination: .file(file), provenance: provenance))
            XCTFail("Expected file publication failure")
        } catch let failure as AlignmentReadExtractionFailure {
            XCTAssertEqual(failure.kind, .publicationFailed)
            XCTAssertEqual(failure.executionRecords.last?.stage, .publication)
            XCTAssertEqual(failure.executionRecords.last?.exitStatus, 1)
        }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "old-payload")
        XCTAssertEqual(try String(contentsOf: sidecar, encoding: .utf8), "old-sidecar")
        XCTAssertTrue(fileTransaction.isCleanedUp)
    }

    func testIncompleteRollbackPreservesStagingAndPublicationExecutionRecords() throws {
        enum FixtureError: Error { case injectedFailure }

        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("alignment-publication-incomplete-rollback-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        func makeTransaction(named name: String) throws -> AlignmentReadExtractionTransaction {
            let staging = root.appendingPathComponent(".\(name)-staging", isDirectory: true)
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
            let payload = staging.appendingPathComponent("selected.fastq")
            try "@selected\nACGT\n+\n!!!!\n".write(to: payload, atomically: true, encoding: .utf8)
            let transaction = try AlignmentReadExtractionTransaction(
                stagingDirectoryURL: staging,
                stagedFiles: [.init(stagedURL: payload, relativeFinalPath: "selected.fastq", format: .fastq)],
                readCount: 1,
                pairedEnd: false
            )
            transaction.appendExecutionRecord(
                .init(
                    stage: .payloadStaging,
                    toolName: "fixture-stager",
                    toolVersion: "1",
                    argv: ["fixture-stager", payload.path],
                    inputs: [],
                    outputs: [],
                    exitStatus: 0,
                    startedAt: Date(timeIntervalSince1970: 10),
                    completedAt: Date(timeIntervalSince1970: 11)
                )
            )
            return transaction
        }

        func assertFailureRecords(
            _ transaction: AlignmentReadExtractionTransaction,
            destination: AlignmentReadExtractionPublicationDestination,
            publisher: AlignmentReadExtractionPublisher,
            file: StaticString = #filePath,
            line: UInt = #line
        ) {
            do {
                _ = try publisher.publish(
                    .init(
                        transaction: transaction,
                        destination: destination,
                        provenance: .init(workflowName: "fixture", argv: ["fixture"], inputURLs: [])
                    )
                )
                XCTFail("Expected incomplete rollback failure", file: file, line: line)
            } catch let failure as AlignmentReadExtractionFailure {
                XCTAssertEqual(failure.kind, .publicationFailed, file: file, line: line)
                XCTAssertEqual(failure.executionRecords.count, 2, file: file, line: line)
                XCTAssertEqual(failure.executionRecords.first?.stage, .payloadStaging, file: file, line: line)
                XCTAssertEqual(failure.executionRecords.last?.stage, .publication, file: file, line: line)
                XCTAssertEqual(failure.executionRecords.last?.exitStatus, 1, file: file, line: line)
                XCTAssertTrue(
                    failure.executionRecords.last?.stderr?.contains("rollback was incomplete") == true,
                    file: file,
                    line: line
                )
            } catch {
                XCTFail("Unexpected error: \(error)", file: file, line: line)
            }
            XCTAssertTrue(transaction.isCleanedUp, file: file, line: line)
        }

        let bundle = root.appendingPathComponent("selected.lungfishfastq", isDirectory: true)
        try fileManager.createDirectory(at: bundle, withIntermediateDirectories: true)
        try "old".write(
            to: bundle.appendingPathComponent("retained.txt"),
            atomically: true,
            encoding: .utf8
        )
        let bundleTransaction = try makeTransaction(named: "bundle")
        let bundlePublisher = AlignmentReadExtractionPublisher { event in
            if event == .directoryAfterInstall || event == .directoryBeforeBackupRestore {
                throw FixtureError.injectedFailure
            }
        }
        assertFailureRecords(bundleTransaction, destination: .bundle(bundle), publisher: bundlePublisher)

        let finalFile = root.appendingPathComponent("selected.fastq")
        let finalSidecar = ProvenanceRecorder.fileSidecarURL(for: finalFile)
        try "old-payload".write(to: finalFile, atomically: true, encoding: .utf8)
        try "old-sidecar".write(to: finalSidecar, atomically: true, encoding: .utf8)
        let fileTransaction = try makeTransaction(named: "file")
        let filePublisher = AlignmentReadExtractionPublisher { event in
            if event == .fileAfterPayloadInstall || event == .fileBeforePayloadBackupRestore {
                throw FixtureError.injectedFailure
            }
        }
        assertFailureRecords(fileTransaction, destination: .file(finalFile), publisher: filePublisher)
    }

    func testPublisherValidationFailuresAppendFailedPublicationRecords() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("alignment-publication-validation-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        func makeTransaction(named name: String, payloadCount: Int) throws -> AlignmentReadExtractionTransaction {
            let staging = root.appendingPathComponent(".\(name)-staging", isDirectory: true)
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
            var stagedFiles: [AlignmentReadExtractionStagedFile] = []
            for index in 0..<payloadCount {
                let payload = staging.appendingPathComponent("selected-\(index).fastq")
                try "@selected\nACGT\n+\n!!!!\n".write(to: payload, atomically: true, encoding: .utf8)
                stagedFiles.append(.init(stagedURL: payload, relativeFinalPath: payload.lastPathComponent, format: .fastq))
            }
            let transaction = try AlignmentReadExtractionTransaction(
                stagingDirectoryURL: staging,
                stagedFiles: stagedFiles,
                readCount: 1,
                pairedEnd: false
            )
            transaction.appendExecutionRecord(
                .init(
                    stage: .payloadStaging,
                    toolName: "fixture-stager",
                    toolVersion: "1",
                    argv: ["fixture-stager"],
                    inputs: [],
                    outputs: [],
                    exitStatus: 0,
                    startedAt: Date(timeIntervalSince1970: 10),
                    completedAt: Date(timeIntervalSince1970: 11)
                )
            )
            return transaction
        }

        func assertValidationFailure(
            transaction: AlignmentReadExtractionTransaction,
            destination: AlignmentReadExtractionPublicationDestination,
            file: StaticString = #filePath,
            line: UInt = #line
        ) {
            do {
                _ = try AlignmentReadExtractionPublisher().publish(
                    .init(
                        transaction: transaction,
                        destination: destination,
                        provenance: .init(workflowName: "fixture", argv: ["fixture"], inputURLs: [])
                    )
                )
                XCTFail("Expected publication validation failure", file: file, line: line)
            } catch let failure as AlignmentReadExtractionFailure {
                XCTAssertEqual(failure.kind, .publicationFailed, file: file, line: line)
                XCTAssertEqual(failure.executionRecords.count, 2, file: file, line: line)
                XCTAssertEqual(failure.executionRecords.first?.stage, .payloadStaging, file: file, line: line)
                XCTAssertEqual(failure.executionRecords.last?.stage, .publication, file: file, line: line)
                XCTAssertEqual(failure.executionRecords.last?.exitStatus, 1, file: file, line: line)
                XCTAssertFalse(failure.executionRecords.last?.stderr?.isEmpty ?? true, file: file, line: line)
            } catch {
                XCTFail("Unexpected error: \(error)", file: file, line: line)
            }
            XCTAssertTrue(transaction.isCleanedUp, file: file, line: line)
        }

        assertValidationFailure(
            transaction: try makeTransaction(named: "bundle", payloadCount: 1),
            destination: .bundle(root.appendingPathComponent("invalid-extension"))
        )
        assertValidationFailure(
            transaction: try makeTransaction(named: "file", payloadCount: 2),
            destination: .file(root.appendingPathComponent("selected.fastq"))
        )
    }
}
