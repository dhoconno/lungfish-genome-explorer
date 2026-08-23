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

    func testInvalidConfigurationPersistsFailedPreToolProvenance() async throws {
        let fixture = try FakeClassificationCondaFixture()
        defer { fixture.cleanup() }

        let config = try fixture.makeConfig()
        try FileManager.default.removeItem(at: config.inputFiles[0])

        do {
            _ = try await ClassificationPipeline(condaManager: fixture.condaManager)
                .classify(config: config)
            XCTFail("Expected validation to reject the missing input.")
        } catch let error as ClassificationConfigError {
            guard case .inputFileNotFound = error else {
                return XCTFail("Expected inputFileNotFound, got \(error)")
            }
        }

        XCTAssertEqual(try fixture.toolInvocations(named: "kraken2"), [])
        let envelope = try XCTUnwrap(
            ProvenanceRecorder.loadEnvelope(from: config.outputDirectory),
            "A pre-tool validation failure must still persist its attempted workflow provenance."
        )
        XCTAssertEqual(envelope.legacyRun?.status, .failed)
        XCTAssertNotEqual(envelope.exitStatus, 0)
        let validation = try XCTUnwrap(
            envelope.steps.first { $0.toolName == "Lungfish Classification Validation" }
        )
        XCTAssertNotEqual(validation.exitStatus, 0)
        XCTAssertTrue((validation.stderr ?? "").contains(config.inputFiles[0].lastPathComponent))
        XCTAssertEqual(validation.outputs, [])
    }

    func testOutputDirectoryCreationFailureSurfacesProvenanceSaveFailureWithoutRunningTools() async throws {
        let fixture = try FakeClassificationCondaFixture()
        defer { fixture.cleanup() }

        var config = try fixture.makeConfig()
        let blockedParent = fixture.root.appendingPathComponent("blocked-output-parent")
        try "regular file\n".write(to: blockedParent, atomically: true, encoding: .utf8)
        config.outputDirectory = blockedParent.appendingPathComponent("output", isDirectory: true)

        do {
            _ = try await ClassificationPipeline(condaManager: fixture.condaManager)
                .classify(config: config)
            XCTFail("Expected output-directory creation to fail.")
        } catch let error as ClassificationConfigError {
            guard case .outputDirectoryCreationFailed(let outputDirectory, let creationError) = error else {
                return XCTFail("Expected outputDirectoryCreationFailed, got \(error)")
            }
            XCTAssertEqual(outputDirectory, config.outputDirectory)
            let setupFailure = try XCTUnwrap(creationError as? ClassificationOutputSetupFailure)
            guard case .outputDirectoryCreationFailed(let originalOutputDirectory, let originalCreationError) =
                setupFailure.outputDirectoryCreationError else {
                return XCTFail("Expected the structured failure to retain the original output-directory error.")
            }
            XCTAssertEqual(originalOutputDirectory, config.outputDirectory)
            XCTAssertFalse(originalCreationError.localizedDescription.isEmpty)
            XCTAssertFalse(setupFailure.provenanceSaveErrorDescription.isEmpty)
            XCTAssertTrue(error.localizedDescription.contains("Cannot create output directory"))
            XCTAssertTrue(
                error.localizedDescription.contains("additionally failed to save failed-run provenance"),
                "The thrown error must surface the secondary provenance persistence failure."
            )
        } catch {
            XCTFail("Expected ClassificationConfigError, got \(error)")
        }

        XCTAssertEqual(try fixture.toolInvocations(named: "kraken2"), [])
        XCTAssertEqual(try fixture.toolInvocations(named: "bracken"), [])
    }

    func testFailedRerunCannotClaimStaleKrakenOutputsOrResultSidecar() async throws {
        let fixture = try FakeClassificationCondaFixture(krakenBehavior: .nonzero(37))
        defer { fixture.cleanup() }

        let config = try fixture.makeConfig()
        let fm = FileManager.default
        try fm.createDirectory(at: config.outputDirectory, withIntermediateDirectories: true)
        let compressedOutputURL = config.outputURL.appendingPathExtension("gz")
        let indexURL = KrakenIndexDatabase.indexURL(for: compressedOutputURL)
        let sidecarURL = config.outputDirectory.appendingPathComponent(ClassificationResult.sidecarFilename)
        for url in [config.reportURL, config.outputURL, compressedOutputURL, indexURL, sidecarURL] {
            try "stale prior-run artifact\n".write(to: url, atomically: true, encoding: .utf8)
        }

        do {
            _ = try await ClassificationPipeline(condaManager: fixture.condaManager)
                .classify(config: config)
            XCTFail("Expected the synthetic Kraken2 failure to propagate.")
        } catch let error as ClassificationPipelineError {
            guard case .kraken2Failed(let exitCode, _) = error else {
                return XCTFail("Expected kraken2Failed, got \(error)")
            }
            XCTAssertEqual(exitCode, 37)
        }

        for url in [config.reportURL, config.outputURL, compressedOutputURL, indexURL, sidecarURL] {
            XCTAssertFalse(
                fm.fileExists(atPath: url.path),
                "A failed rerun must not leave or attribute stale output: \(url.lastPathComponent)"
            )
        }
        let envelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: config.outputDirectory))
        let krakenStep = try XCTUnwrap(envelope.steps.first { $0.toolName == "kraken2" })
        XCTAssertEqual(krakenStep.exitStatus, 37)
        XCTAssertEqual(krakenStep.outputs, [])
    }

    func testHardKraken2NonzeroPersistsExactFailedEnvelope() async throws {
        let fixture = try FakeClassificationCondaFixture(krakenBehavior: .nonzero(37))
        defer { fixture.cleanup() }

        let config = try fixture.makeConfig(goal: .profile)
        let expectedArgv = ["kraken2"] + config.kraken2Arguments()

        do {
            _ = try await ClassificationPipeline(condaManager: fixture.condaManager)
                .profile(config: config)
            XCTFail("Expected the synthetic Kraken2 failure to propagate.")
        } catch let error as ClassificationPipelineError {
            guard case .kraken2Failed(let exitCode, let stderr) = error else {
                return XCTFail("Expected kraken2Failed, got \(error)")
            }
            XCTAssertEqual(exitCode, 37)
            XCTAssertEqual(stderr, "synthetic kraken2 failure\n")
        }

        let envelope = try XCTUnwrap(
            ProvenanceRecorder.loadEnvelope(from: config.outputDirectory),
            "A hard tool failure must persist its sample-level provenance before throwing."
        )
        XCTAssertEqual(envelope.exitStatus, 37)
        XCTAssertEqual(envelope.legacyRun?.status, .failed)

        let krakenStep = try XCTUnwrap(envelope.steps.first { $0.toolName == "kraken2" })
        XCTAssertEqual(krakenStep.argv, expectedArgv)
        XCTAssertEqual(krakenStep.toolVersion, "2.1.3")
        XCTAssertEqual(krakenStep.exitStatus, 37)
        XCTAssertGreaterThan(try XCTUnwrap(krakenStep.wallTimeSeconds), 0)
        XCTAssertEqual(krakenStep.stderr, "synthetic kraken2 failure\n")

        let environmentURL = await fixture.condaManager.environmentURL(
            named: ClassificationPipeline.kraken2Environment
        )
        let expectedRuntime = ProvenanceRuntimeIdentity(
            executablePath: environmentURL.appendingPathComponent("bin/kraken2").path,
            condaEnvironment: ClassificationPipeline.kraken2Environment,
            condaPrefix: environmentURL.path,
            pluginPack: "Metagenomics"
        )
        XCTAssertEqual(krakenStep.runtimeIdentity, expectedRuntime)
    }

    func testAutoEnabledMemoryMappingSeparatesRequestedDefaultAndResolvedValues() async throws {
        let fixture = try FakeClassificationCondaFixture()
        defer { fixture.cleanup() }

        let config = try fixture.makeConfig(memoryMapping: false)
        let hashURL = config.databasePath.appendingPathComponent("hash.k2d")
        let oversizedDatabase = UInt64(Double(ProcessInfo.processInfo.physicalMemory) * 0.81) + 1
        let handle = try FileHandle(forWritingTo: hashURL)
        try handle.truncate(atOffset: oversizedDatabase)
        try handle.close()

        let result = try await ClassificationPipeline(condaManager: fixture.condaManager)
            .classify(config: config)

        XCTAssertFalse(config.memoryMapping)
        XCTAssertTrue(result.config.memoryMapping)
        let envelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: config.outputDirectory))
        XCTAssertEqual(envelope.options.explicit["memoryMapping"], .boolean(false))
        XCTAssertEqual(envelope.options.defaults["memoryMapping"], .boolean(false))
        XCTAssertEqual(envelope.options.resolvedDefaults["effectiveMemoryMapping"], .boolean(true))
        let krakenStep = try XCTUnwrap(envelope.steps.first { $0.toolName == "kraken2" })
        XCTAssertEqual(krakenStep.resolvedOptions["memoryMapping"], .boolean(true))
        XCTAssertTrue(krakenStep.argv.contains("--memory-mapping"))
    }

    func testKrakenGitHubReleaseIsRecordedOnlyWhenItMatchesDetectedToolVersion() async throws {
        for (detectedVersion, expectedRelease) in [
            ("2.1.3", nil as String?),
            ("2.17.1", ClassificationPipeline.kraken2GithubReleaseVersion),
        ] {
            let fixture = try FakeClassificationCondaFixture(krakenVersion: detectedVersion)
            defer { fixture.cleanup() }
            let config = try fixture.makeConfig()

            _ = try await ClassificationPipeline(condaManager: fixture.condaManager)
                .classify(config: config)

            let envelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: config.outputDirectory))
            let krakenStep = try XCTUnwrap(envelope.steps.first { $0.toolName == "kraken2" })
            XCTAssertEqual(krakenStep.toolVersion, detectedVersion)
            XCTAssertEqual(krakenStep.githubReleaseVersion, expectedRelease)
            XCTAssertEqual(envelope.githubReleaseVersion, expectedRelease)
        }
    }

    func testKrakenStructuredOptionsAndLegacyDatabaseReferenceAreComplete() async throws {
        let fixture = try FakeClassificationCondaFixture()
        defer { fixture.cleanup() }

        let config = try fixture.makeConfig(
            databaseDigest: nil,
            inputFormat: .fasta,
            quickMode: true
        )
        _ = try await ClassificationPipeline(condaManager: fixture.condaManager)
            .classify(config: config)

        let envelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: config.outputDirectory))
        XCTAssertEqual(envelope.options.explicit["inputFormat"], .string("fasta"))
        XCTAssertEqual(envelope.options.explicit["quickMode"], .boolean(true))
        XCTAssertNil(envelope.options.explicit["reportMinimizerData"])
        XCTAssertEqual(envelope.options.defaults["inputFormat"], .string("fastq"))
        XCTAssertEqual(envelope.options.defaults["quickMode"], .boolean(false))
        XCTAssertEqual(envelope.options.defaults["reportMinimizerData"], .boolean(true))
        XCTAssertEqual(envelope.options.resolvedDefaults["inputFormat"], .string("fasta"))
        XCTAssertEqual(envelope.options.resolvedDefaults["quickMode"], .boolean(true))
        XCTAssertEqual(envelope.options.resolvedDefaults["reportMinimizerData"], .boolean(true))

        let krakenStep = try XCTUnwrap(envelope.steps.first { $0.toolName == "kraken2" })
        XCTAssertEqual(krakenStep.resolvedOptions["inputFormat"], .string("fasta"))
        XCTAssertEqual(krakenStep.resolvedOptions["quickMode"], .boolean(true))
        XCTAssertEqual(krakenStep.resolvedOptions["reportMinimizerData"], .boolean(true))
        let databaseRecord = try XCTUnwrap(
            krakenStep.inputs.first {
                $0.path == config.databasePath.path && $0.role == .reference
            }
        )
        XCTAssertNil(
            databaseRecord.checksumSHA256,
            "An unavailable custom-database digest must remain explicit instead of hashing the whole directory."
        )
        XCTAssertEqual(databaseRecord.fileSize, 24)
        XCTAssertEqual(krakenStep.resolvedOptions["databaseDigest"], .null)
        XCTAssertEqual(
            krakenStep.resolvedOptions["databaseIdentityStatus"],
            .string("unresolved-bounded-metadata")
        )
        XCTAssertEqual(
            krakenStep.resolvedOptions["databaseCoreFileSizes"],
            .dictionary([
                "hash.k2d": .integer(8),
                "opts.k2d": .integer(8),
                "taxo.k2d": .integer(8),
            ])
        )

        let source = try String(contentsOf: pipelineSourceURL, encoding: .utf8)
        let helperStart = try XCTUnwrap(source.range(of: "private func databaseInputRecord"))
        let helperEnd = try XCTUnwrap(
            source.range(of: "private func recordKraken2Failure", range: helperStart.upperBound..<source.endIndex)
        )
        let helperSource = source[helperStart.lowerBound..<helperEnd.lowerBound]
        XCTAssertFalse(helperSource.contains("fileOrDirectoryRecord"))
        XCTAssertFalse(helperSource.contains("directoryManifest"))
        XCTAssertFalse(helperSource.contains("enumerator("))
    }

    func testHardFailureRetainsDurableReplayForMaterializedInputLineage() async throws {
        let fixture = try FakeClassificationCondaFixture(krakenBehavior: .nonzero(37))
        defer { fixture.cleanup() }

        var config = try fixture.makeConfig()
        let executionInput = config.inputFiles[0]
        let sourceBundle = fixture.root.appendingPathComponent("source.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceBundle, withIntermediateDirectories: true)
        try "{\"source\":\"virtual\"}\n".write(
            to: sourceBundle.appendingPathComponent("manifest.json"),
            atomically: true,
            encoding: .utf8
        )
        config.originalInputFiles = [sourceBundle]

        do {
            _ = try await ClassificationPipeline(condaManager: fixture.condaManager)
                .classify(config: config)
            XCTFail("Expected the synthetic Kraken2 failure to propagate.")
        } catch let error as ClassificationPipelineError {
            guard case .kraken2Failed(let exitCode, _) = error else {
                return XCTFail("Expected kraken2Failed, got \(error)")
            }
            XCTAssertEqual(exitCode, 37)
        }

        try FileManager.default.removeItem(at: executionInput)
        XCTAssertFalse(FileManager.default.fileExists(atPath: executionInput.path))
        let envelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: config.outputDirectory))
        let krakenStep = try XCTUnwrap(envelope.steps.first { $0.toolName == "kraken2" })
        XCTAssertTrue(krakenStep.argv.contains(executionInput.path))
        let replayArgv = try XCTUnwrap(krakenStep.durableReplayArgv)
        XCTAssertFalse(replayArgv.contains(executionInput.path))
        XCTAssertFalse(replayArgv.contains(sourceBundle.path))
        let replayInput = try XCTUnwrap(
            replayArgv.first { $0.contains("/.lungfish-provenance/intermediates/classification-inputs/") }
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: replayInput))
        XCTAssertTrue(
            krakenStep.inputs.contains {
                $0.path == replayInput && $0.role == .input
                    && $0.checksumSHA256 != nil && $0.fileSize != nil
            }
        )
        XCTAssertTrue(
            krakenStep.inputs.contains {
                $0.path == sourceBundle.path && $0.role == .input
                    && $0.checksumSHA256 != nil && $0.fileSize != nil
            }
        )
    }

    func testSuccessfulReplayInputMaterializationRecordsProvenanceEdge() async throws {
        let fixture = try FakeClassificationCondaFixture(krakenBehavior: .nonzero(37))
        defer { fixture.cleanup() }

        var config = try fixture.makeConfig()
        let executionInput = config.inputFiles[0]
        let sourceBundle = fixture.root.appendingPathComponent("source.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceBundle, withIntermediateDirectories: true)
        try "{\"source\":\"virtual\"}\n".write(
            to: sourceBundle.appendingPathComponent("manifest.json"),
            atomically: true,
            encoding: .utf8
        )
        config.originalInputFiles = [sourceBundle]

        do {
            _ = try await ClassificationPipeline(condaManager: fixture.condaManager)
                .classify(config: config)
            XCTFail("Expected the synthetic Kraken2 failure to propagate.")
        } catch let error as ClassificationPipelineError {
            guard case .kraken2Failed(let exitCode, _) = error else {
                return XCTFail("Expected kraken2Failed, got \(error)")
            }
            XCTAssertEqual(exitCode, 37)
        }

        let envelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: config.outputDirectory))
        let materializationStep = try XCTUnwrap(
            envelope.steps.first {
                $0.toolName == "Lungfish Classification Replay Input Materialization"
                    && $0.exitStatus == 0
            },
            "Successful creation of durable scientific replay inputs needs its own provenance step."
        )
        XCTAssertEqual(materializationStep.toolVersion, WorkflowRun.currentAppVersion)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(materializationStep.wallTimeSeconds), 0)
        XCTAssertEqual(materializationStep.argv.prefix(2), ["/bin/sh", "-c"])
        XCTAssertTrue(materializationStep.argv.last?.contains("/bin/cp") == true)
        XCTAssertTrue(
            materializationStep.inputs.contains {
                $0.path == executionInput.path && $0.role == .input
                    && $0.checksumSHA256 != nil && $0.fileSize != nil
            }
        )
        XCTAssertTrue(
            materializationStep.inputs.contains {
                $0.path == sourceBundle.path && $0.role == .input
                    && $0.checksumSHA256 != nil && $0.fileSize != nil
            }
        )
        let durableOutput = try XCTUnwrap(
            materializationStep.outputs.first {
                $0.path.contains("/.lungfish-provenance/intermediates/classification-inputs/")
                    && $0.role == .output
            }
        )
        XCTAssertNotNil(durableOutput.checksumSHA256)
        XCTAssertNotNil(durableOutput.fileSize)

        let krakenStep = try XCTUnwrap(envelope.steps.first { $0.toolName == "kraken2" })
        XCTAssertTrue(krakenStep.dependsOn.contains(materializationStep.id))
        XCTAssertTrue(
            krakenStep.inputs.contains {
                $0.path == durableOutput.path && $0.role == .input
                    && $0.checksumSHA256 == durableOutput.checksumSHA256
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
            // Flipped for the degraded-is-not-failed rule: a sample whose
            // Kraken2 classification succeeded completes even when Bracken
            // degrades. NTC negative controls degrade by design. The evidence
            // stays in the step exit codes, the resolved options, and stderr.
            XCTAssertEqual(envelope.exitStatus, 0)
            XCTAssertEqual(envelope.legacyRun?.status, .completed)
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
        // Flipped for the degraded-is-not-failed rule: the Kraken2
        // classification completed, so the run does. The failing bracken step
        // below is where the degradation evidence lives.
        XCTAssertEqual(provenance.status, .completed)
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
            // Flipped for the degraded-is-not-failed rule: a sample whose
            // Kraken2 classification succeeded completes even when Bracken
            // degrades. NTC negative controls degrade by design. The evidence
            // stays in the step exit codes, the resolved options, and stderr.
            XCTAssertEqual(envelope.exitStatus, 0)
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
        // Flipped for the degraded-is-not-failed rule: the Kraken2 result is
        // retained and the run completes; the failed bracken step below still
        // carries the launch failure.
        XCTAssertEqual(envelope.exitStatus, 0)
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

    // MARK: - Durable input storage policy (Task 1)

    /// The GUI passes the `.lungfishfastq` bundle directory as the original input
    /// and the payload *inside* that bundle as the execution input. That payload is
    /// already durable, so copying it into `classification-inputs/` duplicates every
    /// imported FASTQ in the project (18.7 GB across a 55-sample batch).
    func testDurableBundlePayloadInputIsReferencedInPlaceWithoutCopying() async throws {
        let fixture = try FakeClassificationCondaFixture()
        defer { fixture.cleanup() }

        var config = try fixture.makeConfig()
        let sourceBundle = fixture.root.appendingPathComponent("sample.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceBundle, withIntermediateDirectories: true)
        let payload = sourceBundle.appendingPathComponent("reads.fastq")
        try "@read1\nACGT\n+\nIIII\n".write(to: payload, atomically: true, encoding: .utf8)
        config.inputFiles = [payload]
        config.originalInputFiles = [sourceBundle]

        _ = try await ClassificationPipeline(condaManager: fixture.condaManager).classify(config: config)

        let replayDirectory = config.outputDirectory
            .appendingPathComponent(".lungfish-provenance", isDirectory: true)
            .appendingPathComponent("intermediates", isDirectory: true)
            .appendingPathComponent("classification-inputs", isDirectory: true)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: replayDirectory.path),
            "An already-durable bundle payload must never be copied into provenance intermediates."
        )

        let envelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: config.outputDirectory))
        XCTAssertFalse(
            envelope.steps.contains { $0.toolName == "Lungfish Classification Replay Input Materialization" },
            "No materialization step should be recorded when nothing is copied."
        )
        let krakenStep = try XCTUnwrap(envelope.steps.first { $0.toolName == "kraken2" })
        let replayArgv = try XCTUnwrap(krakenStep.durableReplayArgv)
        XCTAssertTrue(replayArgv.contains(payload.path), "Replay must point at the in-place durable payload.")
        XCTAssertFalse(replayArgv.contains { $0.contains("classification-inputs") })
        XCTAssertTrue(
            krakenStep.inputs.contains { $0.path == sourceBundle.path && $0.role == .input },
            "The originating bundle lineage record must survive."
        )
    }

    /// An execution input inside the project tree (`*.lungfish`) is durable even
    /// when it is not under one of the declared original inputs.
    func testInputInsideProjectTreeIsReferencedInPlace() async throws {
        let fixture = try FakeClassificationCondaFixture()
        defer { fixture.cleanup() }

        var config = try fixture.makeConfig()
        let project = fixture.root.appendingPathComponent("Study.lungfish", isDirectory: true)
        let importsDirectory = project.appendingPathComponent("Imports", isDirectory: true)
        try FileManager.default.createDirectory(at: importsDirectory, withIntermediateDirectories: true)
        let payload = importsDirectory.appendingPathComponent("reads.fastq")
        try "@read1\nACGT\n+\nIIII\n".write(to: payload, atomically: true, encoding: .utf8)
        let unrelatedOriginal = fixture.root.appendingPathComponent("declared.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: unrelatedOriginal, withIntermediateDirectories: true)
        config.inputFiles = [payload]
        config.originalInputFiles = [unrelatedOriginal]

        _ = try await ClassificationPipeline(condaManager: fixture.condaManager).classify(config: config)

        let replayDirectory = config.outputDirectory
            .appendingPathComponent(".lungfish-provenance", isDirectory: true)
            .appendingPathComponent("intermediates", isDirectory: true)
            .appendingPathComponent("classification-inputs", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: replayDirectory.path))
    }

    /// `FASTQDerivativeService.materializeDatasetFASTQ` stages virtual subset,
    /// trim, and demux bundles into `ProjectTempDirectory`, which lives INSIDE
    /// the project at `<project>.lungfish/.tmp/`. Being inside the project tree
    /// does not make those files durable -- they are deleted once the run ends,
    /// so a replay command pointing at them would reference a missing file.
    func testMaterializedInputInProjectScratchDirectoryIsCopied() async throws {
        let fixture = try FakeClassificationCondaFixture()
        defer { fixture.cleanup() }

        var config = try fixture.makeConfig()
        let project = fixture.root.appendingPathComponent("Study.lungfish", isDirectory: true)
        let importsDirectory = project.appendingPathComponent("Imports", isDirectory: true)
        let sourceBundle = importsDirectory.appendingPathComponent("virtual.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceBundle, withIntermediateDirectories: true)
        let scratch = project
            .appendingPathComponent(".tmp", isDirectory: true)
            .appendingPathComponent("classify-mat-xyz", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let materialized = scratch.appendingPathComponent("reads.fastq")
        try "@read1\nACGT\n+\nIIII\n".write(to: materialized, atomically: true, encoding: .utf8)
        config.inputFiles = [materialized]
        config.originalInputFiles = [sourceBundle]

        _ = try await ClassificationPipeline(condaManager: fixture.condaManager).classify(config: config)

        let envelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: config.outputDirectory))
        let materialization = try XCTUnwrap(
            envelope.steps.first { $0.toolName == "Lungfish Classification Replay Input Materialization" },
            "A file staged under <project>.lungfish/.tmp/ is transient and must be copied."
        )
        let copy = try XCTUnwrap(
            materialization.outputs.first { $0.path.contains("/classification-inputs/") }
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path))
        let krakenStep = try XCTUnwrap(envelope.steps.first { $0.toolName == "kraken2" })
        let replayArgv = try XCTUnwrap(krakenStep.durableReplayArgv)
        XCTAssertTrue(replayArgv.contains(copy.path))
        XCTAssertFalse(replayArgv.contains(materialized.path))
    }

    /// A materialized virtual bundle lives in a scratch directory outside the
    /// project and is deleted after the run, so it still has to be copied.
    func testTransientTemporaryInputIsStillCopiedForDurableReplay() async throws {
        let fixture = try FakeClassificationCondaFixture()
        defer { fixture.cleanup() }

        var config = try fixture.makeConfig()
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("classification-transient-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let transientInput = scratch.appendingPathComponent("materialized.fastq")
        try "@read1\nACGT\n+\nIIII\n".write(to: transientInput, atomically: true, encoding: .utf8)
        let sourceBundle = fixture.root.appendingPathComponent("virtual.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceBundle, withIntermediateDirectories: true)
        config.inputFiles = [transientInput]
        config.originalInputFiles = [sourceBundle]

        _ = try await ClassificationPipeline(condaManager: fixture.condaManager).classify(config: config)

        let envelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: config.outputDirectory))
        let materialization = try XCTUnwrap(
            envelope.steps.first { $0.toolName == "Lungfish Classification Replay Input Materialization" },
            "A transient materialized input must still be copied for durable replay."
        )
        let copy = try XCTUnwrap(
            materialization.outputs.first { $0.path.contains("/classification-inputs/") }
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path))
        let krakenStep = try XCTUnwrap(envelope.steps.first { $0.toolName == "kraken2" })
        XCTAssertTrue(try XCTUnwrap(krakenStep.durableReplayArgv).contains(copy.path))
    }

    /// Mixed inputs: the durable one keeps its in-place path, only the transient
    /// one is copied, and the replay command references both.
    func testMixedDurableAndTransientInputsCopyOnlyTheTransientOne() async throws {
        let fixture = try FakeClassificationCondaFixture()
        defer { fixture.cleanup() }

        var config = try fixture.makeConfig()
        let sourceBundle = fixture.root.appendingPathComponent("paired.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceBundle, withIntermediateDirectories: true)
        let durablePayload = sourceBundle.appendingPathComponent("R1.fastq")
        try "@read1\nACGT\n+\nIIII\n".write(to: durablePayload, atomically: true, encoding: .utf8)
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("classification-mixed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let transientPayload = scratch.appendingPathComponent("R2.fastq")
        try "@read2\nACGT\n+\nIIII\n".write(to: transientPayload, atomically: true, encoding: .utf8)
        config.inputFiles = [durablePayload, transientPayload]
        config.originalInputFiles = [sourceBundle]

        _ = try await ClassificationPipeline(condaManager: fixture.condaManager).classify(config: config)

        let replayDirectory = config.outputDirectory
            .appendingPathComponent(".lungfish-provenance", isDirectory: true)
            .appendingPathComponent("intermediates", isDirectory: true)
            .appendingPathComponent("classification-inputs", isDirectory: true)
        let copied = try FileManager.default.contentsOfDirectory(atPath: replayDirectory.path)
        XCTAssertEqual(copied.count, 1, "Only the transient input may be copied: \(copied)")
        XCTAssertTrue(try XCTUnwrap(copied.first).contains("R2.fastq"))

        let envelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: config.outputDirectory))
        let krakenStep = try XCTUnwrap(envelope.steps.first { $0.toolName == "kraken2" })
        let replayArgv = try XCTUnwrap(krakenStep.durableReplayArgv)
        XCTAssertTrue(replayArgv.contains(durablePayload.path))
        XCTAssertFalse(replayArgv.contains(transientPayload.path))
        XCTAssertTrue(replayArgv.contains { $0.contains("classification-inputs") && $0.contains("R2.fastq") })
    }

    // MARK: - Declared files must exist (Task 2a)

    /// `compactKrakenOutputIfPossible` gzips and then deletes `classification.kraken`,
    /// but the raw path was still declared in the run-level `files`/`outputs`, leaving
    /// 55 dangling declarations in the user's batch.
    func testCompletedRunDeclaresNoMissingFilesAfterKrakenCompaction() async throws {
        let fixture = try FakeClassificationCondaFixture()
        defer { fixture.cleanup() }

        let config = try fixture.makeConfig()
        _ = try await ClassificationPipeline(condaManager: fixture.condaManager).classify(config: config)

        let envelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: config.outputDirectory))
        XCTAssertEqual(envelope.exitStatus, 0)
        let fm = FileManager.default
        let declared = envelope.files.map(\.path) + envelope.outputs.map(\.path)
        let missing = declared.filter { !fm.fileExists(atPath: $0) }
        XCTAssertTrue(missing.isEmpty, "Run-level declarations must all exist on disk: \(missing)")
        XCTAssertFalse(envelope.files.contains { $0.path == config.outputURL.path })
        XCTAssertFalse(envelope.outputs.contains { $0.path == config.outputURL.path })

        let compressedURL = config.outputURL.appendingPathExtension("gz")
        let indexURL = KrakenIndexDatabase.indexURL(for: compressedURL)
        XCTAssertTrue(envelope.outputs.contains { $0.path == compressedURL.path })
        XCTAssertTrue(envelope.outputs.contains { $0.path == indexURL.path })
        XCTAssertEqual(
            envelope.steps.first { $0.toolName == "gzip" }?.inputs.map(\.path),
            [config.outputURL.path],
            "Step-level records stay historically true."
        )
    }

    // MARK: - Bracken report declaration (Task 2b)

    /// Bracken auto-writes `<report>_bracken_<rank>.kreport` when `-w` is absent, so
    /// 53 report files in the user's batch were produced but never declared.
    func testBrackenReportIsWrittenAtTheExplicitPathAndDeclared() async throws {
        let fixture = try FakeClassificationCondaFixture(reportRank: .species)
        defer { fixture.cleanup() }

        let config = try fixture.makeConfig(goal: .profile, profileRequest: .automaticDefault)
        let result = try await ClassificationPipeline(condaManager: fixture.condaManager).profile(config: config)

        XCTAssertEqual(result.profileOutcome.state, .completed)
        let reportURL = config.brackenReportURL
        XCTAssertEqual(reportURL.lastPathComponent, "classification.bracken.kreport")
        XCTAssertTrue(FileManager.default.fileExists(atPath: reportURL.path))

        let profileCall = try XCTUnwrap(fixture.brackenProfileInvocations().only)
        XCTAssertTrue(profileCall.contains("-w \(reportURL.path)"), profileCall)

        let envelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: config.outputDirectory))
        let brackenStep = try XCTUnwrap(envelope.steps.first { $0.toolName == "bracken" })
        XCTAssertTrue(
            brackenStep.outputs.contains { $0.path == reportURL.path && $0.role == .report },
            "The Bracken re-estimated kreport must be a declared bracken step output."
        )
        let fm = FileManager.default
        let missing = (envelope.files.map(\.path) + envelope.outputs.map(\.path))
            .filter { !fm.fileExists(atPath: $0) }
        XCTAssertTrue(missing.isEmpty, "Declared files must exist: \(missing)")

        let sidecar = try XCTUnwrap(ClassificationResult.load(from: config.outputDirectory))
        XCTAssertEqual(sidecar.brackenReportURL?.standardizedFileURL, reportURL.standardizedFileURL)
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

    enum KrakenBehavior {
        case success
        case nonzero(Int32)
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
        krakenVersion: String = "2.1.3",
        krakenBehavior: KrakenBehavior = .success,
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
            krakenVersion: krakenVersion,
            krakenBehavior: krakenBehavior,
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

    /// Bracken invocations that are actual profiling runs, excluding the version
    /// probes and the `--help` CLI-dialect probe.
    func brackenProfileInvocations() throws -> [String] {
        try toolInvocations(named: "bracken").filter {
            $0 != "bracken -v" && $0 != "bracken --version" && $0 != "bracken --help"
        }
    }

    func makeConfig(
        goal: ClassificationConfig.Goal = .classify,
        databaseDigest: String? = "sha256:fixture-db",
        catalogID: String? = nil,
        installationRecipe: MetagenomicsDatabaseInstallationRecipe? = nil,
        profileRequest: BrackenProfileRequest? = nil,
        inputFormat: SequenceFormat = .fastq,
        memoryMapping: Bool = false,
        quickMode: Bool = false
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
            inputFormat: inputFormat,
            databaseVersion: "fixture-v1",
            databasePath: dbURL,
            databaseDigest: databaseDigest,
            databaseCatalogID: catalogID,
            databaseInstallationRecipe: installationRecipe,
            brackenProfileRequest: profileRequest,
            memoryMapping: memoryMapping,
            quickMode: quickMode,
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
        krakenVersion: String,
        krakenBehavior: KrakenBehavior,
        brackenBehavior: BrackenBehavior,
        invocationLogURL: URL
    ) -> String {
        let krakenFailureBody: String
        switch krakenBehavior {
        case .success:
            krakenFailureBody = ":"
        case .nonzero(let exitCode):
            krakenFailureBody = """
            echo "synthetic kraken2 failure" >&2
            exit \(exitCode)
            """
        }
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
              echo "Kraken version \(krakenVersion)"
              exit 0
            fi
            \(krakenFailureBody)
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
            # This fixture models the real Bracken driver, which advertises -d;
            # the pipeline probes --help to choose between that and the
            # est_abundance.py passthrough CLI.
            if [ "$1" = "--help" ]; then
              echo "Usage: bracken -d MY_DB -i INPUT.kreport -o OUTPUT.bracken -r READ_LEN -l LEVEL -t THRESHOLD"
              exit 0
            fi
            output=""
            reportOutput=""
            while [ "$#" -gt 0 ]; do
              if [ "$1" = "-o" ]; then
                shift
                output="$1"
              elif [ "$1" = "-w" ]; then
                shift
                reportOutput="$1"
              fi
              shift
            done
            mkdir -p "$(dirname "$output")"
            if [ -n "$reportOutput" ]; then
              mkdir -p "$(dirname "$reportOutput")"
              printf '100.00\t1\t0\tR\t1\troot\n' > "$reportOutput"
            fi
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
