import XCTest
@testable import LungfishIO
@testable import LungfishWorkflow

final class ClassificationPipelineProvenanceSourceTests: XCTestCase {
    private var pipelineSourceURL: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/LungfishWorkflow/Metagenomics/ClassificationPipeline.swift")
    }

    func testKraken2ProvenanceRecordsChecksummedFiles() async throws {
        let fixture = try FakeClassificationCondaFixture()
        defer { fixture.cleanup() }

        let config = try fixture.makeConfig()
        let pipeline = ClassificationPipeline(condaManager: fixture.condaManager)

        let result = try await pipeline.classify(config: config)
        let compressedOutputURL = config.outputURL.appendingPathExtension("gz")
        let indexURL = KrakenIndexDatabase.indexURL(for: compressedOutputURL)

        XCTAssertEqual(result.reportURL.standardizedFileURL, config.reportURL.standardizedFileURL)
        XCTAssertEqual(result.outputURL.standardizedFileURL, compressedOutputURL.standardizedFileURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: config.outputURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: compressedOutputURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: indexURL.path))

        let index = try KrakenIndexDatabase(url: indexURL)
        XCTAssertTrue(index.isClassifiedOnly)
        XCTAssertTrue(index.canResolve(taxIds: [562]))
        XCTAssertFalse(index.canResolve(taxIds: [0]))
        XCTAssertEqual(try index.readIds(forTaxIds: [562]), ["read1"])
        index.close()

        let provenance = try XCTUnwrap(ProvenanceRecorder.load(from: config.outputDirectory))
        XCTAssertEqual(provenance.name, "Metagenomics Classification")
        XCTAssertEqual(provenance.status, .completed)
        XCTAssertEqual(provenance.parameters["database"]?.stringValue, config.databaseName)
        XCTAssertEqual(provenance.parameters["databaseVersion"]?.stringValue, config.databaseVersion)
        XCTAssertEqual(provenance.parameters["databasePath"]?.fileValue, config.databasePath.standardizedFileURL)
        XCTAssertEqual(provenance.parameters["databaseDigest"]?.stringValue, config.databaseDigest)
        let krakenStep = try XCTUnwrap(provenance.steps.first { $0.toolName == "kraken2" })
        let gzipStep = try XCTUnwrap(provenance.steps.first { $0.toolName == "gzip" })
        let sidecarURL = config.outputDirectory.appendingPathComponent(ClassificationResult.sidecarFilename)
        let sidecarStep = try XCTUnwrap(provenance.steps.first { $0.toolName == "Lungfish Classification Result Sidecar" })

        XCTAssertEqual(krakenStep.exitCode, 0)
        XCTAssertNotNil(krakenStep.wallTime)
        XCTAssertTrue(krakenStep.command.contains("kraken2"))
        XCTAssertTrue(krakenStep.command.contains(config.reportURL.path))
        XCTAssertTrue(krakenStep.command.contains(config.outputURL.path))
        XCTAssertTrue(
            krakenStep.inputs.contains {
                $0.path == config.inputFiles[0].path && $0.format == .fastq && $0.role == .input
                    && $0.sha256 != nil && $0.sizeBytes != nil
            }
        )
        XCTAssertTrue(
            krakenStep.outputs.contains {
                $0.path == config.reportURL.path && $0.format == .text && $0.role == .report
                    && $0.sha256 != nil && $0.sizeBytes != nil
            }
        )
        XCTAssertTrue(
            provenance.steps.flatMap(\.outputs).contains {
                $0.path == compressedOutputURL.path && $0.format == .text && $0.role == .output
                    && $0.sha256 != nil && $0.sizeBytes != nil
            }
        )
        XCTAssertEqual(gzipStep.command.first, "/bin/sh")
        XCTAssertEqual(gzipStep.command.dropFirst().first, "-c")
        let gzipReplayCommand = try XCTUnwrap(gzipStep.command.last)
        XCTAssertTrue(gzipReplayCommand.contains("/usr/bin/gzip -c \(shellEscape(config.outputURL.path))"))
        XCTAssertTrue(gzipReplayCommand.contains("> \(shellEscape(compressedOutputURL.path))"))
        XCTAssertEqual(gzipStep.inputs.map(\.path), [config.outputURL.path])
        XCTAssertEqual(gzipStep.outputs.map(\.path), [compressedOutputURL.path])
        XCTAssertTrue(
            provenance.steps.flatMap(\.outputs).contains {
                $0.path == indexURL.path && $0.format == .unknown && $0.role == .index
                    && $0.sha256 != nil && $0.sizeBytes != nil
            }
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecarURL.path))
        XCTAssertTrue(
            sidecarStep.outputs.contains {
                $0.path == sidecarURL.path && $0.format == .json && $0.role == .output
                    && $0.sha256 != nil && $0.sizeBytes != nil
            }
        )
    }

    func testClassificationSidecarFailureRecordsFailedWrapperStepInSource() throws {
        let source = try String(contentsOf: pipelineSourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("} catch let sidecarError {\n            await provenanceRecorder.recordStep("))
        XCTAssertTrue(source.contains(#"toolName: "Lungfish Classification Result Sidecar""#))
        XCTAssertTrue(source.contains("exitCode: 1,\n                wallTime: Date().timeIntervalSince(sidecarSaveStart),\n                stderr: sidecarError.localizedDescription"))
    }

    func testAutomaticSilvaProfileUsesGenusAndBrackenVFlag() async throws {
        let fixture = try FakeClassificationCondaFixture(reportRank: .genus)
        defer { fixture.cleanup() }

        let config = try fixture.makeConfig(
            goal: .profile,
            catalogID: "kraken2-special-silva",
            installationRecipe: .kraken2Special(type: .silva),
            profileRequest: .automaticDefault
        )
        let result = try await ClassificationPipeline(condaManager: fixture.condaManager)
            .profile(config: config)

        XCTAssertEqual(result.profileOutcome.state, .completed)
        XCTAssertEqual(result.profileOutcome.resolution?.rank, .genus)
        XCTAssertEqual(result.profileOutcome.resolution?.readLength, 150)
        XCTAssertEqual(result.profileOutcome.resolution?.threshold, 10)
        XCTAssertEqual(result.profileOutcome.toolVersion, "3.0.1")
        XCTAssertEqual(result.tree.node(taxId: 561)?.brackenReads, 1)
        XCTAssertNotNil(result.brackenURL)

        let invocations = try fixture.toolInvocations(named: "bracken")
        XCTAssertTrue(invocations.contains("bracken -v"))
        XCTAssertFalse(invocations.contains("bracken --version"))
        let profileCall = try XCTUnwrap(fixture.brackenProfileInvocations().only)
        XCTAssertTrue(profileCall.contains("-l G"))
        XCTAssertTrue(profileCall.contains("-r 150"))
        XCTAssertTrue(profileCall.contains("-t 10"))

        let envelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: config.outputDirectory))
        XCTAssertEqual(envelope.exitStatus, 0)
        XCTAssertEqual(envelope.options.explicit["brackenRankRequest"], .string("automatic"))
        XCTAssertEqual(envelope.options.explicit["brackenRequestedReadLength"], .integer(150))
        XCTAssertNil(envelope.options.explicit["brackenResolvedRank"])
        XCTAssertEqual(envelope.options.defaults["brackenReadLength"], .integer(150))
        XCTAssertEqual(envelope.options.resolvedDefaults["brackenResolvedRank"], .string("G"))
        XCTAssertEqual(envelope.options.resolvedDefaults["profileState"], .string("completed"))
        let brackenStep = try XCTUnwrap(envelope.steps.first { $0.toolName == "bracken" })
        XCTAssertEqual(brackenStep.toolVersion, "3.0.1")
        XCTAssertEqual(brackenStep.runtimeIdentity?.condaEnvironment, ClassificationPipeline.brackenEnvironment)
    }

    func testRequestedReadLengthDoesNotReplaceSupported150BaseDistribution() async throws {
        let fixture = try FakeClassificationCondaFixture(reportRank: .species)
        defer { fixture.cleanup() }
        let config = try fixture.makeConfig(
            goal: .profile,
            catalogID: "kraken2-standard-8",
            profileRequest: BrackenProfileRequest(
                rank: .automatic,
                readLength: 100,
                threshold: 10
            )
        )

        let result = try await ClassificationPipeline(condaManager: fixture.condaManager)
            .profile(config: config)

        XCTAssertEqual(result.config.brackenProfileRequest?.readLength, 100)
        XCTAssertEqual(result.profileOutcome.state, .completed)
        XCTAssertEqual(result.profileOutcome.resolution?.readLength, 150)
        let call = try XCTUnwrap(fixture.brackenProfileInvocations().only)
        XCTAssertTrue(call.contains("-r 150"))
        XCTAssertFalse(call.contains("-r 100"))
        let envelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: config.outputDirectory))
        XCTAssertEqual(envelope.options.explicit["brackenRequestedReadLength"], .integer(100))
        XCTAssertEqual(envelope.options.defaults["brackenReadLength"], .integer(150))
        XCTAssertEqual(envelope.options.resolvedDefaults["brackenReadLength"], .integer(150))
    }

    func testAutomaticOrdinaryAndExplicitRanksAreNotRewritten() async throws {
        let cases: [(
            reportRank: FakeClassificationCondaFixture.ReportRank,
            catalogID: String,
            recipe: MetagenomicsDatabaseInstallationRecipe?,
            request: BrackenProfileRequest,
            expectedLevel: String
        )] = [
            (.species, "kraken2-standard-8", nil, .automaticDefault, "S"),
            (.genus, "kraken2-standard-8", nil, BrackenProfileRequest(rank: .explicit(.genus)), "G"),
            (.species, "kraken2-special-silva", .kraken2Special(type: .silva), BrackenProfileRequest(rank: .explicit(.species)), "S"),
        ]

        for testCase in cases {
            let fixture = try FakeClassificationCondaFixture(reportRank: testCase.reportRank)
            defer { fixture.cleanup() }
            let config = try fixture.makeConfig(
                goal: .profile,
                catalogID: testCase.catalogID,
                installationRecipe: testCase.recipe,
                profileRequest: testCase.request
            )

            let result = try await ClassificationPipeline(condaManager: fixture.condaManager)
                .profile(config: config)

            XCTAssertEqual(result.profileOutcome.state, .completed)
            XCTAssertEqual(result.profileOutcome.resolution?.rank.code, testCase.expectedLevel)
            let call = try XCTUnwrap(fixture.brackenProfileInvocations().only)
            XCTAssertTrue(call.contains("-l \(testCase.expectedLevel)"))
        }
    }

    func testMissingResolvedRankAndUnsupportedRankDegradeBeforeBracken() async throws {
        let cases: [(BrackenProfileRequest, BrackenProfileDegradationReason)] = [
            (BrackenProfileRequest(rank: .explicit(.species)), .rankAbsentFromReport),
            (BrackenProfileRequest(rank: .explicit(.kingdom)), .unsupportedRank),
        ]

        for (request, expectedReason) in cases {
            let fixture = try FakeClassificationCondaFixture(reportRank: .genus)
            defer { fixture.cleanup() }
            let config = try fixture.makeConfig(
                goal: .profile,
                catalogID: "kraken2-special-silva",
                installationRecipe: .kraken2Special(type: .silva),
                profileRequest: request
            )
            try FileManager.default.createDirectory(
                at: config.outputDirectory,
                withIntermediateDirectories: true
            )
            try "stale profile\n".write(
                to: config.brackenURL,
                atomically: true,
                encoding: .utf8
            )

            let result = try await ClassificationPipeline(condaManager: fixture.condaManager)
                .profile(config: config)

            XCTAssertEqual(result.profileOutcome.state, .degraded)
            XCTAssertEqual(result.profileOutcome.reason, expectedReason)
            XCTAssertNil(result.brackenURL)
            XCTAssertFalse(FileManager.default.fileExists(atPath: config.brackenURL.path))
            XCTAssertEqual(try fixture.brackenProfileInvocations(), [])
            XCTAssertTrue(FileManager.default.fileExists(atPath: result.reportURL.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: result.outputURL.path))
            XCTAssertTrue(ClassificationResult.exists(in: config.outputDirectory))

            let persisted = try ClassificationResult.load(from: config.outputDirectory)
            XCTAssertEqual(persisted.profileOutcome.reason, expectedReason)
            let envelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: config.outputDirectory))
            XCTAssertNotEqual(envelope.exitStatus, 0)
            XCTAssertEqual(envelope.legacyRun?.status, .failed)
            let preflight = try XCTUnwrap(envelope.steps.first { $0.toolName == "Lungfish Bracken Preflight" })
            XCTAssertNotEqual(preflight.exitStatus, 0)
            XCTAssertTrue(preflight.inputs.contains { $0.path == config.reportURL.path })
        }
    }

    func testInvalidDistributionVariantsDegradeWithoutBracken() async throws {
        let invalidStates: [FakeClassificationCondaFixture.DistributionState] = [
            .missing,
            .empty,
            .directory,
            .unreadable,
            .symbolicLink,
        ]

        for distributionState in invalidStates {
            let fixture = try FakeClassificationCondaFixture(
                reportRank: .species,
                distributionState: distributionState
            )
            defer { fixture.cleanup() }
            let config = try fixture.makeConfig(
                goal: .profile,
                catalogID: "kraken2-standard-8",
                profileRequest: .automaticDefault
            )

            let result = try await ClassificationPipeline(condaManager: fixture.condaManager)
                .profile(config: config)

            XCTAssertEqual(result.profileOutcome.state, .degraded, "state: \(distributionState)")
            XCTAssertEqual(result.profileOutcome.reason, .distributionUnavailable, "state: \(distributionState)")
            XCTAssertEqual(try fixture.brackenProfileInvocations(), [], "state: \(distributionState)")
            let envelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: config.outputDirectory))
            let preflight = try XCTUnwrap(envelope.steps.first { $0.toolName == "Lungfish Bracken Preflight" })
            XCTAssertNotEqual(preflight.exitStatus, 0)
            XCTAssertFalse(
                preflight.inputs.contains { $0.path == fixture.distributionURL.path },
                "An invalid intended path must not be claimed as consumed: \(distributionState)"
            )
            XCTAssertTrue(preflight.argv.contains(fixture.distributionURL.path))
        }
    }

    func testBrackenNonzeroDegradesAndFailedOutputIsNotExposed() async throws {
        let fixture = try FakeClassificationCondaFixture(brackenBehavior: .nonzero(42))
        defer { fixture.cleanup() }

        let config = try fixture.makeConfig()
        let pipeline = ClassificationPipeline(condaManager: fixture.condaManager)

        let result = try await pipeline.profile(config: config)

        XCTAssertNil(result.brackenURL)
        XCTAssertEqual(result.profileOutcome.state, .degraded)
        XCTAssertEqual(result.profileOutcome.reason, .toolFailed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: config.brackenURL.path))

        let provenance = try XCTUnwrap(ProvenanceRecorder.load(from: config.outputDirectory))
        XCTAssertEqual(provenance.name, "Metagenomics Profiling")
        XCTAssertEqual(provenance.status, .failed)
        let brackenStep = try XCTUnwrap(provenance.steps.first { $0.toolName == "bracken" })

        XCTAssertEqual(brackenStep.exitCode, 42)
        XCTAssertEqual(brackenStep.outputs, [])
        XCTAssertTrue(brackenStep.command.contains(config.brackenURL.path))
        XCTAssertTrue(brackenStep.inputs.contains {
            $0.path == config.reportURL.path && $0.format == .text && $0.role == .input
                && $0.sha256 != nil && $0.sizeBytes != nil
        })
        XCTAssertEqual(brackenStep.stderr, "synthetic bracken failure\n")
    }

    func testBrackenExit127IsReportedAsToolUnavailable() async throws {
        let fixture = try FakeClassificationCondaFixture(brackenBehavior: .unavailable)
        defer { fixture.cleanup() }
        let config = try fixture.makeConfig()

        let result = try await ClassificationPipeline(condaManager: fixture.condaManager)
            .profile(config: config)

        XCTAssertEqual(result.profileOutcome.state, .degraded)
        XCTAssertEqual(result.profileOutcome.reason, .toolUnavailable)
        XCTAssertNil(result.brackenURL)
        let envelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: config.outputDirectory))
        let brackenStep = try XCTUnwrap(envelope.steps.first { $0.toolName == "bracken" })
        XCTAssertEqual(brackenStep.exitStatus, 127)
        XCTAssertEqual(brackenStep.outputs, [])
    }

    func testMissingAndMalformedBrackenOutputsDegradeAfterZeroExit() async throws {
        let cases: [(
            FakeClassificationCondaFixture.BrackenBehavior,
            BrackenProfileDegradationReason,
            shouldRecordInvalidOutputInput: Bool
        )] = [
            (.missingOutput, .outputMissing, false),
            (.malformedOutput, .outputInvalid, true),
            (.unmatchedOutput, .outputInvalid, true),
        ]

        for (behavior, expectedReason, shouldRecordInvalidOutputInput) in cases {
            let fixture = try FakeClassificationCondaFixture(brackenBehavior: behavior)
            defer { fixture.cleanup() }
            let config = try fixture.makeConfig()

            let result = try await ClassificationPipeline(condaManager: fixture.condaManager)
                .profile(config: config)

            XCTAssertEqual(result.profileOutcome.state, .degraded)
            XCTAssertEqual(result.profileOutcome.reason, expectedReason)
            XCTAssertNil(result.brackenURL)
            XCTAssertFalse(FileManager.default.fileExists(atPath: config.brackenURL.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: result.reportURL.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: result.outputURL.path))

            let envelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: config.outputDirectory))
            XCTAssertNotEqual(envelope.exitStatus, 0)
            let brackenStep = try XCTUnwrap(envelope.steps.first { $0.toolName == "bracken" })
            XCTAssertEqual(brackenStep.exitStatus, 0, "The recorded process exit remains exact")
            XCTAssertEqual(brackenStep.outputs, [])
            let validation = try XCTUnwrap(
                envelope.steps.first { $0.toolName == "Lungfish Bracken Output Validation" }
            )
            XCTAssertNotEqual(validation.exitStatus, 0)
            if shouldRecordInvalidOutputInput {
                let invalidInput = validation.inputs.first {
                    $0.path == config.brackenURL.path
                }
                XCTAssertNotNil(
                    invalidInput,
                    "An existing invalid Bracken artifact must be captured as the validator's input."
                )
                XCTAssertNotNil(invalidInput?.checksumSHA256)
                XCTAssertNotNil(invalidInput?.fileSize)
            } else {
                XCTAssertEqual(validation.inputs, [])
            }
        }
    }

    func testThrownBrackenLaunchFailureDegradesAndRetainsKrakenResult() async throws {
        let fixture = try FakeClassificationCondaFixture(brackenBehavior: .launchFailure)
        defer { fixture.cleanup() }
        let config = try fixture.makeConfig()

        let result = try await ClassificationPipeline(condaManager: fixture.condaManager)
            .profile(config: config)

        XCTAssertEqual(result.profileOutcome.state, .degraded)
        XCTAssertEqual(result.profileOutcome.reason, .toolFailed)
        XCTAssertNil(result.brackenURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.reportURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.outputURL.path))
        let envelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: config.outputDirectory))
        XCTAssertNotEqual(envelope.exitStatus, 0)
        let brackenStep = try XCTUnwrap(envelope.steps.first { $0.toolName == "bracken" })
        XCTAssertNotEqual(brackenStep.exitStatus, 0)
        XCTAssertTrue((brackenStep.stderr ?? "").localizedCaseInsensitiveContains("micromamba"))
    }

    func testCancellationDuringBrackenPropagatesInsteadOfDegrading() async throws {
        let fixture = try FakeClassificationCondaFixture(brackenBehavior: .waitForCancellation)
        defer { fixture.cleanup() }
        let config = try fixture.makeConfig()
        let pipeline = ClassificationPipeline(condaManager: fixture.condaManager)
        let profileTask = Task {
            try await pipeline.profile(config: config)
        }

        var didStartBracken = false
        for _ in 0..<200 {
            if try !fixture.brackenProfileInvocations().isEmpty {
                didStartBracken = true
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(didStartBracken, "Bracken should start before the task is cancelled.")

        profileTask.cancel()
        do {
            _ = try await profileTask.value
            XCTFail("Cancellation must not be converted into a degraded scientific result.")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: config.brackenURL.path))
        XCTAssertFalse(ClassificationResult.exists(in: config.outputDirectory))
        let envelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: config.outputDirectory))
        XCTAssertEqual(envelope.legacyRun?.status, .cancelled)
        XCTAssertEqual(envelope.options.resolvedDefaults["profileState"], .string("cancelled"))
        let brackenStep = try XCTUnwrap(envelope.steps.first { $0.toolName == "bracken" })
        XCTAssertEqual(brackenStep.exitStatus, 130)
        XCTAssertEqual(brackenStep.outputs, [])
    }

    func testStaleBrackenOutputCannotSatisfyANewMissingOutputRun() async throws {
        let fixture = try FakeClassificationCondaFixture(brackenBehavior: .missingOutput)
        defer { fixture.cleanup() }
        let config = try fixture.makeConfig()
        try FileManager.default.createDirectory(
            at: config.outputDirectory,
            withIntermediateDirectories: true
        )
        let stale = "name\ttaxonomy_id\ttaxonomy_lvl\tkraken_assigned_reads\tadded_reads\tnew_est_reads\tfraction_total_reads\nEscherichia coli\t562\tS\t1\t0\t1\t1.0\n"
        try stale.write(to: config.brackenURL, atomically: true, encoding: .utf8)

        let result = try await ClassificationPipeline(condaManager: fixture.condaManager)
            .profile(config: config)

        XCTAssertEqual(result.profileOutcome.state, .degraded)
        XCTAssertEqual(result.profileOutcome.reason, .outputMissing)
        XCTAssertNil(result.brackenURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: config.brackenURL.path))
    }

    func testClassificationSidecarIsRemovedWhenFinalProvenanceCannotBeSaved() async throws {
        let fixture = try FakeClassificationCondaFixture()
        defer { fixture.cleanup() }

        let config = try fixture.makeConfig()
        try FileManager.default.createDirectory(at: config.outputDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: config.outputDirectory.appendingPathComponent(ProvenanceRecorder.provenanceFilename),
            withIntermediateDirectories: true
        )

        let pipeline = ClassificationPipeline(condaManager: fixture.condaManager)

        do {
            _ = try await pipeline.classify(config: config)
            XCTFail("Expected classification to fail when final provenance cannot be saved.")
        } catch {
            // Expected.
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: config.outputDirectory.appendingPathComponent(ClassificationResult.sidecarFilename).path
            ),
            "A successful-looking classification sidecar must not survive if final provenance cannot be saved."
        )
    }
}

private extension Array {
    var only: Element? { count == 1 ? self[0] : nil }
}

private struct FakeClassificationCondaFixture {
    enum ReportRank: String {
        case genus = "G"
        case species = "S"

        var taxID: Int { self == .genus ? 561 : 562 }
        var name: String { self == .genus ? "Escherichia" : "Escherichia coli" }
    }

    enum DistributionState: CustomStringConvertible {
        case valid
        case missing
        case empty
        case directory
        case unreadable
        case symbolicLink

        var description: String {
            switch self {
            case .valid: return "valid"
            case .missing: return "missing"
            case .empty: return "empty"
            case .directory: return "directory"
            case .unreadable: return "unreadable"
            case .symbolicLink: return "symbolicLink"
            }
        }
    }

    enum BrackenBehavior {
        case success
        case nonzero(Int32)
        case unavailable
        case missingOutput
        case malformedOutput
        case unmatchedOutput
        case launchFailure
        case waitForCancellation
    }

    let root: URL
    let condaManager: CondaManager
    let distributionURL: URL
    private let invocationLogURL: URL
    private let reportRank: ReportRank
    private let distributionState: DistributionState

    init(
        reportRank: ReportRank = .species,
        distributionState: DistributionState = .valid,
        brackenBehavior: BrackenBehavior = .success
    ) throws {
        self.reportRank = reportRank
        self.distributionState = distributionState
        let fm = FileManager.default
        root = fm.temporaryDirectory.appendingPathComponent(
            "classification-provenance-\(UUID().uuidString)",
            isDirectory: true
        )
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        invocationLogURL = root.appendingPathComponent("tool-invocations.log")
        distributionURL = root
            .appendingPathComponent("kraken-db", isDirectory: true)
            .appendingPathComponent("database150mers.kmer_distrib")

        let bundledMicromamba = root.appendingPathComponent("bundled-micromamba")
        try Self.scriptBody(
            reportRank: reportRank,
            brackenBehavior: brackenBehavior,
            invocationLogURL: invocationLogURL
        )
            .write(to: bundledMicromamba, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundledMicromamba.path)

        condaManager = CondaManager(
            rootPrefix: root.appendingPathComponent("conda", isDirectory: true),
            bundledMicromambaProvider: { bundledMicromamba },
            bundledMicromambaVersionProvider: { "2.0.0" }
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    func toolInvocations(named toolName: String) throws -> [String] {
        guard FileManager.default.fileExists(atPath: invocationLogURL.path) else { return [] }
        return try String(contentsOf: invocationLogURL, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
            .filter { $0 == toolName || $0.hasPrefix("\(toolName) ") }
    }

    func brackenProfileInvocations() throws -> [String] {
        try toolInvocations(named: "bracken").filter {
            $0 != "bracken -v" && $0 != "bracken --version"
        }
    }

    func makeConfig(
        goal: ClassificationConfig.Goal = .classify,
        catalogID: String? = nil,
        installationRecipe: MetagenomicsDatabaseInstallationRecipe? = nil,
        profileRequest: BrackenProfileRequest? = nil
    ) throws -> ClassificationConfig {
        let dbURL = root.appendingPathComponent("kraken-db", isDirectory: true)
        try FileManager.default.createDirectory(at: dbURL, withIntermediateDirectories: true)
        for filename in ["hash.k2d", "opts.k2d", "taxo.k2d"] {
            try "fake-db\n".write(to: dbURL.appendingPathComponent(filename), atomically: true, encoding: .utf8)
        }
        try materializeDistribution(in: dbURL)

        let readsURL = root.appendingPathComponent("reads.fastq")
        try "@read1\nACGT\n+\nIIII\n".write(to: readsURL, atomically: true, encoding: .utf8)

        return ClassificationConfig(
            goal: goal,
            inputFiles: [readsURL],
            isPairedEnd: false,
            databaseName: "FixtureDB",
            databaseVersion: "fixture-v1",
            databasePath: dbURL,
            databaseDigest: "sha256:fixture-db",
            databaseCatalogID: catalogID,
            databaseInstallationRecipe: installationRecipe,
            brackenProfileRequest: profileRequest,
            outputDirectory: root.appendingPathComponent("output", isDirectory: true)
        )
    }

    private func materializeDistribution(in databaseURL: URL) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: distributionURL)
        switch distributionState {
        case .valid:
            try "synthetic 150-mer distribution\n".write(
                to: distributionURL,
                atomically: true,
                encoding: .utf8
            )
        case .missing:
            break
        case .empty:
            try Data().write(to: distributionURL)
        case .directory:
            try fm.createDirectory(at: distributionURL, withIntermediateDirectories: true)
        case .unreadable:
            try "unreadable\n".write(to: distributionURL, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: distributionURL.path)
        case .symbolicLink:
            let target = databaseURL.appendingPathComponent("distribution-target")
            try "target\n".write(to: target, atomically: true, encoding: .utf8)
            try fm.createSymbolicLink(at: distributionURL, withDestinationURL: target)
        }
    }

    private static func scriptBody(
        reportRank: ReportRank,
        brackenBehavior: BrackenBehavior,
        invocationLogURL: URL
    ) -> String {
        let brackenBody: String
        switch brackenBehavior {
        case .success:
            brackenBody = """
            printf 'name\\ttaxonomy_id\\ttaxonomy_lvl\\tkraken_assigned_reads\\tadded_reads\\tnew_est_reads\\tfraction_total_reads\\n\(reportRank.name)\\t\(reportRank.taxID)\\t\(reportRank.rawValue)\\t1\\t0\\t1\\t1.0\\n' > "$output"
            exit 0
            """
        case .nonzero(let exitCode):
            brackenBody = """
            echo "synthetic bracken failure" >&2
            exit \(exitCode)
            """
        case .unavailable:
            brackenBody = """
            echo "bracken: executable not found" >&2
            exit 127
            """
        case .missingOutput:
            brackenBody = "exit 0"
        case .malformedOutput:
            brackenBody = """
            printf 'name\\ttaxonomy_id\\ttaxonomy_lvl\\tkraken_assigned_reads\\tadded_reads\\tnew_est_reads\\tfraction_total_reads\\n' > "$output"
            exit 0
            """
        case .unmatchedOutput:
            brackenBody = """
            printf 'name\\ttaxonomy_id\\ttaxonomy_lvl\\tkraken_assigned_reads\\tadded_reads\\tnew_est_reads\\tfraction_total_reads\\nUnknown taxon\\t999999\\t\(reportRank.rawValue)\\t1\\t0\\t1\\t1.0\\n' > "$output"
            exit 0
            """
        case .launchFailure:
            brackenBody = "exit 70"
        case .waitForCancellation:
            brackenBody = """
            sleep 30
            printf 'name\\ttaxonomy_id\\ttaxonomy_lvl\\tkraken_assigned_reads\\tadded_reads\\tnew_est_reads\\tfraction_total_reads\\n\(reportRank.name)\\t\(reportRank.taxID)\\t\(reportRank.rawValue)\\t1\\t0\\t1\\t1.0\\n' > "$output"
            exit 0
            """
        }
        let removeMicromamba: String
        if case .launchFailure = brackenBehavior {
            removeMicromamba = "rm -f \"$0\" \"\(invocationLogURL.deletingLastPathComponent().appendingPathComponent("bundled-micromamba").path)\""
        } else {
            removeMicromamba = ":"
        }

        return """
        #!/bin/sh
        if [ "$1" = "--version" ]; then
          echo "micromamba 2.0.0"
          exit 0
        fi
        if [ "$1" != "run" ]; then
          echo "unexpected micromamba invocation: $*" >&2
          exit 64
        fi
        shift
        if [ "$1" = "-n" ]; then
          shift
          shift
        fi
        tool="$1"
        shift
        printf '%s\\n' "$tool $*" >> "\(invocationLogURL.path)"
        case "$tool" in
          kraken2)
            if [ "$1" = "--version" ]; then
              echo "Kraken version 2.1.3"
              exit 0
            fi
            report=""
            output=""
            while [ "$#" -gt 0 ]; do
              case "$1" in
                --report)
                  shift
                  report="$1"
                  ;;
                --output)
                  shift
                  output="$1"
                  ;;
              esac
              shift
            done
            mkdir -p "$(dirname "$report")" "$(dirname "$output")"
            cat > "$report" <<'REPORT'
        100.00\t1\t0\tR\t1\troot
        100.00\t1\t1\t\(reportRank.rawValue)\t\(reportRank.taxID)\t  \(reportRank.name)
        REPORT
            printf 'C\tread1\t\(reportRank.taxID)\t4\t0:4\n' > "$output"
            echo "processed 1 sequence" >&2
            \(removeMicromamba)
            exit 0
            ;;
          bracken)
            if [ "$1" = "--version" ]; then
              echo "unsupported bracken version flag" >&2
              exit 64
            fi
            if [ "$1" = "-v" ]; then
              echo "Bracken v3.0.1"
              exit 0
            fi
            output=""
            while [ "$#" -gt 0 ]; do
              if [ "$1" = "-o" ]; then
                shift
                output="$1"
              fi
              shift
            done
            mkdir -p "$(dirname "$output")"
            \(brackenBody)
            ;;
          *)
            echo "unexpected tool: $tool" >&2
            exit 64
            ;;
        esac
        """
    }
}
