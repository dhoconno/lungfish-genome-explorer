import Darwin
import XCTest
@testable import LungfishApp
import LungfishCore
@testable import LungfishIO
import LungfishKit
@testable import LungfishWorkflow

private enum SyntheticCommandFailure: Error {
    case commandFailed
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedEvents: [(Double, String)] = []

    func append(_ fraction: Double, _ message: String) {
        lock.lock()
        recordedEvents.append((fraction, message))
        lock.unlock()
    }

    func events() -> [(Double, String)] {
        lock.lock()
        defer { lock.unlock() }
        return recordedEvents
    }
}

final class FASTQOperationExecutionServiceTests: XCTestCase {
    func testDefaultCLIRunnerCancelsRunningProcessWhenTaskIsCancelled() async throws {
        let tempDir = try FASTQOperationTestHelper.makeTempDir(prefix: "FASTQExecCLICancel")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let fakeCLIURL = tempDir.appendingPathComponent("fake-lungfish-cli")
        try """
        #!/bin/sh
        sleep 3
        """.write(to: fakeCLIURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakeCLIURL.path
        )

        let runner = LungfishCLIProcessRunner(cliURLProvider: { fakeCLIURL })
        let start = Date()
        let task = Task { () -> Result<FASTQCLIExecutionResult, Error> in
            do {
                let result = try await runner.run(
                    invocation: CLIInvocation(subcommand: "fastq", arguments: ["noop"]),
                    outputDirectory: tempDir,
                    progress: { _, _ in }
                )
                return .success(result)
            } catch {
                return .failure(error)
            }
        }

        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        let result = await task.value
        let elapsed = Date().timeIntervalSince(start)

        guard case .failure(let error) = result else {
            return XCTFail("Expected cancelled CLI runner task to fail")
        }
        guard case LungfishCLIRunner.RunError.cancelled = error else {
            return XCTFail("Expected RunError.cancelled, got \(error)")
        }
        XCTAssertLessThan(elapsed, 2.0)
    }

    func testPlannerSplitsPerInputDerivativeRequestsIntoOnePlanPerInput() throws {
        let planner = FASTQOperationPlanner()
        let baseOutputDirectory = URL(fileURLWithPath: "/tmp/fastq-operation-output", isDirectory: true)
        let originalInputURLs = [
            URL(fileURLWithPath: "/tmp/source-a.\(FASTQBundle.directoryExtension)", isDirectory: true),
            URL(fileURLWithPath: "/tmp/source-b.\(FASTQBundle.directoryExtension)", isDirectory: true),
        ]
        let resolvedInputURLs = [
            URL(fileURLWithPath: "/tmp/materialized/source-a.fastq"),
            URL(fileURLWithPath: "/tmp/materialized/source-b.fastq"),
        ]
        let originalRequest = FASTQOperationLaunchRequest.derivative(
            request: .lengthFilter(min: 20, max: 500),
            inputURLs: originalInputURLs,
            outputMode: .perInput
        )
        let resolvedRequest = FASTQOperationLaunchRequest.derivative(
            request: .lengthFilter(min: 20, max: 500),
            inputURLs: resolvedInputURLs,
            outputMode: .perInput
        )

        let plans = planner.makeExecutionPlans(
            originalRequest: originalRequest,
            resolvedRequest: resolvedRequest,
            baseOutputDirectory: baseOutputDirectory
        )

        XCTAssertEqual(plans.count, 2)
        XCTAssertEqual(plans.map(\.originalRequest.inputURLs), originalInputURLs.map { [$0] })
        XCTAssertEqual(plans.map(\.resolvedRequest.inputURLs), resolvedInputURLs.map { [$0] })
        XCTAssertEqual(plans.map(\.outputKind), [.fastqFile, .fastqFile])
        XCTAssertEqual(plans.map(\.outputTarget.lastPathComponent), ["lengthFilter.fastq", "lengthFilter.fastq"])
        XCTAssertEqual(plans.map { $0.outputTarget.deletingLastPathComponent().lastPathComponent }, ["source-a", "source-b"])
    }

    func testPlannerUsesWorkingDirectoryForGroupedDemultiplexOutput() throws {
        let planner = FASTQOperationPlanner()
        let workingDirectory = URL(fileURLWithPath: "/tmp/grouped-demultiplex", isDirectory: true)
        let request = FASTQOperationLaunchRequest.derivative(
            request: .demultiplex(
                kitID: "SQK-RBK004",
                customCSVPath: nil,
                location: "bothends",
                symmetryMode: nil,
                maxDistanceFrom5Prime: 24,
                maxDistanceFrom3Prime: 24,
                errorRate: 0.12,
                engine: .cutadapt,
                trimBarcodes: true,
                sampleAssignments: nil,
                kitOverride: nil
            ),
            inputURLs: [URL(fileURLWithPath: "/tmp/reads.fastq")],
            outputMode: .groupedResult
        )

        let outputDirectory = planner.executionOutputDirectory(for: request, workingDirectory: workingDirectory)
        let plans = planner.makeExecutionPlans(
            originalRequest: request,
            resolvedRequest: request,
            baseOutputDirectory: outputDirectory
        )

        XCTAssertEqual(outputDirectory, workingDirectory)
        XCTAssertEqual(plans.count, 1)
        XCTAssertEqual(plans[0].outputKind, .directory)
        XCTAssertEqual(plans[0].outputTarget, workingDirectory)
    }

    func testDemultiplexInvocationIncludesSelectedEngine() throws {
        let request = FASTQOperationLaunchRequest.derivative(
            request: .demultiplex(
                kitID: "fluidigm-access-array",
                customCSVPath: nil,
                location: "fiveprime",
                symmetryMode: nil,
                maxDistanceFrom5Prime: 100,
                maxDistanceFrom3Prime: 0,
                errorRate: 0.15,
                engine: .exactBareBarcode,
                trimBarcodes: true,
                sampleAssignments: nil,
                kitOverride: nil
            ),
            inputURLs: [URL(fileURLWithPath: "/tmp/reads.lungfishfastq")],
            outputMode: .groupedResult
        )

        let invocation = try FASTQOperationCLIInvocationBuilder().buildInvocation(for: request)
        let engineIndex = try XCTUnwrap(invocation.arguments.firstIndex(of: "--engine"))
        XCTAssertEqual(invocation.arguments[engineIndex + 1], "exact-bare")
        XCTAssertFalse(invocation.arguments.contains("--location"))
        XCTAssertFalse(invocation.arguments.contains("--max-distance-5prime"))
        XCTAssertFalse(invocation.arguments.contains("--max-distance-3prime"))
        XCTAssertFalse(invocation.arguments.contains("--error-rate"))
        XCTAssertFalse(invocation.arguments.contains("--no-trim"))
    }

    func testPBAAInvocationUsesFastqPBAAClusterCLI() throws {
        let request = try PBAAClusteringRunRequest(
            inputFASTQURL: URL(fileURLWithPath: "/tmp/reads.fastq"),
            guideSourceURL: URL(fileURLWithPath: "/tmp/guide.fasta"),
            outputDirectory: URL(fileURLWithPath: "/tmp/out", isDirectory: true),
            outputName: "sample",
            threads: 4,
            seed: 7,
            extraArgumentsText: "--min-cluster-read-count 2"
        )

        let invocation = try FASTQOperationCLIInvocationBuilder().buildInvocation(for: .pbaa(request: request))

        XCTAssertEqual(invocation.subcommand, "fastq")
        XCTAssertEqual(Array(invocation.arguments.prefix(2)), ["pbaa-cluster", "/tmp/reads.fastq"])
        XCTAssertTrue(invocation.arguments.contains("--guide"))
        XCTAssertTrue(invocation.arguments.contains("/tmp/guide.fasta"))
        XCTAssertTrue(invocation.arguments.contains("--extra-args"))
    }

    func testPBAAInvocationUsesScopedExecutionDirectoryWhenProvided() throws {
        let request = try PBAAClusteringRunRequest(
            inputFASTQURL: URL(fileURLWithPath: "/tmp/reads.fastq"),
            guideSourceURL: URL(fileURLWithPath: "/tmp/guide.fasta"),
            outputDirectory: URL(fileURLWithPath: "/tmp/analyses", isDirectory: true),
            outputName: "sample"
        )

        let invocation = try FASTQOperationCLIInvocationBuilder().buildInvocation(
            for: .pbaa(request: request),
            outputTargetPath: "/tmp/run-scoped"
        )

        let outputDirIndex = try XCTUnwrap(invocation.arguments.firstIndex(of: "--output-dir"))
        XCTAssertEqual(invocation.arguments[outputDirIndex + 1], "/tmp/run-scoped")
    }

    func testReferencePrimerRemovalInvocationUsesCutadaptLinkedPairs() throws {
        let request = FASTQOperationLaunchRequest.derivative(
            request: .primerRemoval(configuration: FASTQPrimerTrimConfiguration(
                source: .reference,
                mode: .linked,
                referenceFasta: "/tmp/fluidigm_primers.fa",
                tool: .cutadapt
            )),
            inputURLs: [URL(fileURLWithPath: "/tmp/reads.fastq")],
            outputMode: .perInput
        )

        let invocation = try FASTQOperationCLIInvocationBuilder().buildInvocation(
            for: request,
            outputTargetPath: "/tmp/trimmed.fastq"
        )

        XCTAssertEqual(invocation.subcommand, "fastq")
        XCTAssertEqual(Array(invocation.arguments.prefix(2)), ["primer-remove", "/tmp/reads.fastq"])
        XCTAssertTrue(invocation.arguments.contains("--ref"))
        XCTAssertTrue(invocation.arguments.contains("/tmp/fluidigm_primers.fa"))
        XCTAssertTrue(invocation.arguments.contains("--engine"))
        let engineIndex = try XCTUnwrap(invocation.arguments.firstIndex(of: "--engine"))
        XCTAssertEqual(invocation.arguments[engineIndex + 1], "cutadapt-linked")
        XCTAssertFalse(invocation.arguments.contains("--kmer"))
        XCTAssertFalse(invocation.arguments.contains("--literal"))
    }

    func testPlannerDiscoversPBAAReferenceBundles() throws {
        let tempDir = try FASTQOperationTestHelper.makeTempDir(prefix: "FASTQExecPBAARefs")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let outputDirectory = tempDir.appendingPathComponent("pbaa-output", isDirectory: true)
        let referenceBundle = outputDirectory.appendingPathComponent("passed.lungfishref", isDirectory: true)
        let fastqBundle = outputDirectory.appendingPathComponent("ignored.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: referenceBundle, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fastqBundle, withIntermediateDirectories: true)

        let request = try FASTQOperationLaunchRequest.pbaa(request: PBAAClusteringRunRequest(
            inputFASTQURL: URL(fileURLWithPath: "/tmp/reads.fastq"),
            guideSourceURL: URL(fileURLWithPath: "/tmp/guide.fasta"),
            outputDirectory: outputDirectory,
            outputName: "sample"
        ))
        let plan = FASTQOperationPlan(
            originalRequest: request,
            resolvedRequest: request,
            outputTarget: outputDirectory,
            outputKind: .directory
        )

        XCTAssertEqual(
            FASTQOperationPlanner().discoverOutputs(for: plan, in: outputDirectory).map {
                $0.resolvingSymlinksInPath()
            },
            [referenceBundle.resolvingSymlinksInPath()]
        )
    }

    func testPlannerScopesPBAADiscoveryToCurrentExecutionDirectory() throws {
        let tempDir = try FASTQOperationTestHelper.makeTempDir(prefix: "FASTQExecPBAAScopedRefs")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let analysesDirectory = tempDir.appendingPathComponent("Analyses", isDirectory: true)
        let oldReferenceBundle = analysesDirectory.appendingPathComponent("old.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: oldReferenceBundle, withIntermediateDirectories: true)

        let request = try FASTQOperationLaunchRequest.pbaa(request: PBAAClusteringRunRequest(
            inputFASTQURL: URL(fileURLWithPath: "/tmp/reads.fastq"),
            guideSourceURL: URL(fileURLWithPath: "/tmp/guide.fasta"),
            outputDirectory: analysesDirectory,
            outputName: "sample"
        ))
        let planner = FASTQOperationPlanner()
        let executionDirectory = planner.executionOutputDirectory(for: request, workingDirectory: tempDir)
        let currentReferenceBundle = executionDirectory.appendingPathComponent("sample.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: currentReferenceBundle, withIntermediateDirectories: true)

        let plan = try XCTUnwrap(planner.makeExecutionPlans(
            originalRequest: request,
            resolvedRequest: request,
            baseOutputDirectory: executionDirectory
        ).first)

        XCTAssertNotEqual(executionDirectory.standardizedFileURL, analysesDirectory.standardizedFileURL)
        XCTAssertTrue(executionDirectory.lastPathComponent.hasPrefix("cli-output-pbaa-"))
        XCTAssertEqual(plan.outputTarget.standardizedFileURL, executionDirectory.standardizedFileURL)
        XCTAssertEqual(
            planner.discoverOutputs(for: plan, in: executionDirectory).map { $0.resolvingSymlinksInPath() },
            [currentReferenceBundle.resolvingSymlinksInPath()]
        )
        XCTAssertFalse(
            planner.discoverOutputs(for: plan, in: executionDirectory).contains {
                $0.standardizedFileURL == oldReferenceBundle.standardizedFileURL
            }
        )
    }

    func testPBAAReferenceBundlesPassThroughImporterWithoutWrapping() async throws {
        let tempDir = try FASTQOperationTestHelper.makeTempDir(prefix: "FASTQExecPBAAImport")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let outputDirectory = tempDir.appendingPathComponent("pbaa-output", isDirectory: true)
        let referenceBundle = outputDirectory.appendingPathComponent("passed.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: referenceBundle, withIntermediateDirectories: true)

        let request = try FASTQOperationLaunchRequest.pbaa(request: PBAAClusteringRunRequest(
            inputFASTQURL: URL(fileURLWithPath: "/tmp/reads.fastq"),
            guideSourceURL: URL(fileURLWithPath: "/tmp/guide.fasta"),
            outputDirectory: outputDirectory,
            outputName: "sample"
        ))

        let imported = try await BundleFASTQOperationImporter(destinationDirectory: tempDir).importOutputs(
            at: [referenceBundle],
            forResolvedRequest: request,
            originalRequest: request,
            outputDirectory: outputDirectory
        )

        XCTAssertEqual(imported, [referenceBundle])
    }

    func testONTFluidigmSampleBundlesPassThroughImporterWithLocalProvenance() async throws {
        let tempDir = try FASTQOperationTestHelper.makeTempDir(prefix: "FASTQExecONTFluidigmImport")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let inputBundle = try FASTQOperationTestHelper.makeBundle(named: "barcode11", in: tempDir)
        try FASTQOperationTestHelper.writeSyntheticFASTQ(to: inputBundle.fastqURL, readCount: 2, readLength: 16)
        let barcodeURL = tempDir.appendingPathComponent("ONT09_NB11_samples.csv")
        try "sample,barcode\nLF1001,ACGT\n".write(to: barcodeURL, atomically: true, encoding: .utf8)

        let outputDirectory = tempDir.appendingPathComponent("ont-fluidigm-samples", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let sampleBundle = try FASTQOperationTestHelper.makeBundle(named: "LF1001", in: outputDirectory)
        try FASTQOperationTestHelper.writeSyntheticFASTQ(to: sampleBundle.fastqURL, readCount: 1, readLength: 16)
        try writeSyntheticMultiOutputProvenance(
            to: outputDirectory,
            name: "lungfish fastq ont-fluidigm-samples",
            toolName: "lungfish fastq ont-fluidigm-samples",
            toolVersion: WorkflowRun.currentAppVersion,
            command: [
                "lungfish", "fastq", "ont-fluidigm-samples",
                inputBundle.bundleURL.path,
                "--barcodes", barcodeURL.path,
                "--output", outputDirectory.path,
            ],
            inputURL: inputBundle.fastqURL,
            outputURLs: [sampleBundle.fastqURL],
            parameters: ["payloadCompression": .string("gzip")]
        )

        let request = FASTQOperationLaunchRequest.ontFluidigmSampleSplit(
            inputFASTQURL: inputBundle.bundleURL,
            barcodeDefinitionsURL: barcodeURL,
            threads: 4
        )

        let imported = try await BundleFASTQOperationImporter(destinationDirectory: tempDir).importOutputs(
            at: [sampleBundle.bundleURL],
            forResolvedRequest: request,
            originalRequest: request,
            outputDirectory: outputDirectory
        )

        XCTAssertEqual(imported, [sampleBundle.bundleURL])
        let envelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: sampleBundle.bundleURL))
        XCTAssertEqual(envelope.workflowName, "lungfish fastq ont-fluidigm-samples")
        XCTAssertEqual(envelope.outputs.map(\.path), [sampleBundle.fastqURL.path])
        XCTAssertEqual(envelope.steps.first?.outputs.map(\.path), [sampleBundle.fastqURL.path])
        XCTAssertEqual(
            envelope.output?.sourceProvenancePath,
            outputDirectory.appendingPathComponent(ProvenanceRecorder.provenanceFilename).path
        )
    }

    func testPlannerKeepsAssemblyOutputInWorkingDirectory() throws {
        let planner = FASTQOperationPlanner()
        let workingDirectory = URL(fileURLWithPath: "/tmp/assembly-output", isDirectory: true)
        let request = FASTQOperationLaunchRequest.assemble(
            request: AssemblyRunRequest(
                tool: .megahit,
                readType: .illuminaShortReads,
                inputURLs: [URL(fileURLWithPath: "/tmp/reads.fastq")],
                projectName: "Demo",
                outputDirectory: workingDirectory,
                threads: 4
            ),
            outputMode: .perInput
        )

        XCTAssertEqual(
            planner.executionOutputDirectory(for: request, workingDirectory: workingDirectory),
            workingDirectory
        )
        XCTAssertEqual(
            planner.makeExecutionPlans(
                originalRequest: request,
                resolvedRequest: request,
                baseOutputDirectory: workingDirectory
            ).first?.outputKind,
            .directory
        )
    }

    func testInvocationBuilderBuildsTrimInvocationAndServiceDelegatesCompatibilityEntryPoint() throws {
        let request = FASTQOperationLaunchRequest.derivative(
            request: .fastpTrim(
                threshold: 20,
                windowSize: 4,
                mode: .cutRight,
                adapterMode: .autoDetect,
                adapterSequence: nil
            ),
            inputURLs: [URL(fileURLWithPath: "/tmp/sample.lungfishfastq")],
            outputMode: .perInput
        )

        let builderInvocation = try FASTQOperationCLIInvocationBuilder().buildInvocation(for: request)
        let serviceInvocation = try FASTQOperationExecutionService().buildInvocation(for: request)

        XCTAssertEqual(builderInvocation, serviceInvocation)
        XCTAssertEqual(builderInvocation.subcommand, "fastq")
        XCTAssertEqual(builderInvocation.arguments.first, "trim")
        XCTAssertTrue(builderInvocation.arguments.contains("--adapter-trimming"))
        XCTAssertTrue(builderInvocation.arguments.contains("--threshold"))
        XCTAssertTrue(builderInvocation.arguments.contains("--window"))
    }

    func testProvenanceRehydratorMapsMaterializedInputPathsToFinalSourcePayload() throws {
        let tempDir = try FASTQOperationTestHelper.makeTempDir(prefix: "FASTQExecRehydratorPathMap")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sourceBundle = try FASTQOperationTestHelper.makeBundle(named: "source", in: tempDir)
        try FASTQOperationTestHelper.writeSyntheticFASTQ(to: sourceBundle.fastqURL, readCount: 2, readLength: 20)

        let stagingDir = tempDir.appendingPathComponent("staging", isDirectory: true)
        let materializedDir = stagingDir.appendingPathComponent("materialized-inputs-test", isDirectory: true)
        try FileManager.default.createDirectory(at: materializedDir, withIntermediateDirectories: true)
        let materializedInput = materializedDir.appendingPathComponent("source.fastq")
        let stagedOutput = stagingDir.appendingPathComponent("source.trimmed.fastq")
        let finalOutput = tempDir.appendingPathComponent("imported.fastq")
        try FASTQOperationTestHelper.writeSyntheticFASTQ(to: materializedInput, readCount: 2, readLength: 20)
        try FASTQOperationTestHelper.writeSyntheticFASTQ(to: stagedOutput, readCount: 1, readLength: 18)
        try FASTQOperationTestHelper.writeSyntheticFASTQ(to: finalOutput, readCount: 1, readLength: 18)
        try writeSyntheticProvenance(
            to: stagingDir,
            name: "Synthetic trim",
            toolName: "fastp",
            toolVersion: "1.0",
            command: ["fastp", "-i", materializedInput.path, "-o", stagedOutput.path],
            inputURL: materializedInput,
            outputURL: stagedOutput,
            parameters: ["operation": .string("trim")]
        )

        let pathMap = FASTQOperationProvenanceRehydrator().operationPathMap(
            sourceURL: stagedOutput,
            finalOutputURL: finalOutput,
            sourceInputURL: sourceBundle.bundleURL
        )

        XCTAssertEqual(pathMap[stagedOutput.path], finalOutput.path)
        XCTAssertEqual(pathMap[materializedInput.path], sourceBundle.fastqURL.path)
    }

    func testStagingCleanupRemovesTransientDirectoriesWhilePreservingFinalBundlesAndCallerDirectories() throws {
        let tempDir = try FASTQOperationTestHelper.makeTempDir(prefix: "FASTQExecCleanup")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let cliOutput = tempDir.appendingPathComponent("cli-output-remove", isDirectory: true)
        let materialized = tempDir.appendingPathComponent("materialized-inputs-remove", isDirectory: true)
        let preservedStaging = tempDir.appendingPathComponent("cli-output-preserve", isDirectory: true)
        let finalBundle = preservedStaging.appendingPathComponent("final.\(FASTQBundle.directoryExtension)", isDirectory: true)
        let callerDirectory = tempDir.appendingPathComponent("caller-output", isDirectory: true)
        for directory in [cliOutput, materialized, finalBundle, callerDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        FASTQOperationStagingCleanup().cleanup(
            directories: [cliOutput, materialized, preservedStaging, callerDirectory],
            preserving: [finalBundle, callerDirectory]
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: cliOutput.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: materialized.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: preservedStaging.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: finalBundle.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: callerDirectory.path))
    }

    func testFASTQCLIProgressEventParsesJSONProgressLines() throws {
        let event = try XCTUnwrap(FASTQCLIProgressEvent.parse(
            """
            {"event":"progress","operation":"ontPacBioBarcodeDemux","progress":0.46,"message":"Processed 1/2 chunks"}
            """
        ))

        XCTAssertEqual(event.progress, 0.46, accuracy: 0.0001)
        XCTAssertEqual(event.message, "Processed 1/2 chunks")
    }

    func testExecuteForwardsCommandProgressUpdatesToCaller() async throws {
        let tempDir = try FASTQOperationTestHelper.makeTempDir(prefix: "FASTQExecProgress")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let inputURL = tempDir.appendingPathComponent("input.fastq")
        try FASTQOperationTestHelper.writeSyntheticFASTQ(to: inputURL, readCount: 1, readLength: 16)
        let outputFASTQ = tempDir.appendingPathComponent("filtered.fastq")
        let runner = SpyCommandRunner(progressHandler: { _, _, progress in
            progress(0.46, "Processed 1/2 chunks")
            try FASTQOperationTestHelper.writeSyntheticFASTQ(to: outputFASTQ, readCount: 1, readLength: 16)
            return FASTQCLIExecutionResult(outputURLs: [outputFASTQ])
        })
        let service = FASTQOperationExecutionService(
            commandRunner: runner,
            directImporter: SpyDirectImporter()
        )
        let progressRecorder = ProgressRecorder()

        _ = try await service.execute(
            request: FASTQOperationLaunchRequest.derivative(
                request: FASTQDerivativeRequest.lengthFilter(min: 10, max: 40),
                inputURLs: [inputURL],
                outputMode: FASTQOperationOutputMode.perInput
            ),
            workingDirectory: tempDir,
            progress: { fraction, message in
                progressRecorder.append(fraction, message)
            }
        )

        let progressEvents = progressRecorder.events()
        XCTAssertEqual(progressEvents.count, 2)
        XCTAssertEqual(progressEvents[0].0, 0.01, accuracy: 0.0001)
        XCTAssertEqual(progressEvents[0].1, "Launching lungfish-cli...")
        XCTAssertEqual(progressEvents[1].0, 0.46, accuracy: 0.0001)
        XCTAssertEqual(progressEvents[1].1, "Processed 1/2 chunks")
    }

    func testExecuteEmitsLaunchProgressBeforeWaitingForFASTQCommand() async throws {
        let tempDir = try FASTQOperationTestHelper.makeTempDir(prefix: "FASTQExecLaunchProgress")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let inputDirectory = tempDir.appendingPathComponent("barcode05", isDirectory: true)
        try FileManager.default.createDirectory(at: inputDirectory, withIntermediateDirectories: true)
        let barcodesURL = tempDir.appendingPathComponent("NB05_samples.csv")
        try "sample,barcode\nLF1001,ACGT\n".write(to: barcodesURL, atomically: true, encoding: .utf8)

        let progressRecorder = ProgressRecorder()
        let runner = SpyCommandRunner { _, outputDirectory in
            let events = progressRecorder.events()
            XCTAssertTrue(
                events.contains { $0.0 > 0 && $0.1 == "Launching lungfish-cli..." },
                "Large FASTQ operations must leave Preparing before the subprocess waits."
            )
            let outputTarget = outputDirectory.appendingPathComponent("ont-fluidigm-samples", isDirectory: true)
            try FileManager.default.createDirectory(at: outputTarget, withIntermediateDirectories: true)
            return FASTQCLIExecutionResult(outputURLs: [outputTarget])
        }
        let service = FASTQOperationExecutionService(
            commandRunner: runner,
            directImporter: SpyDirectImporter()
        )

        _ = try await service.execute(
            request: .ontFluidigmSampleSplit(
                inputFASTQURL: inputDirectory,
                barcodeDefinitionsURL: barcodesURL,
                threads: 4
            ),
            workingDirectory: tempDir.appendingPathComponent("operation-output", isDirectory: true),
            progress: { fraction, message in
                progressRecorder.append(fraction, message)
            }
        )
    }

    func testFASTQCLIProcessRunnerClosesPipeWriteHandlesAfterProcessExit() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LungfishApp/Services/FASTQOperationExecutionService.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let runnerSource = try XCTUnwrap(
            source.range(of: "private struct LungfishCLIProcessRunner")
                .flatMap { start in
                    source[start.lowerBound...].range(of: "\n    }\n}")
                        .map { String(source[start.lowerBound..<$0.upperBound]) }
                }
        )

        XCTAssertTrue(runnerSource.contains("stdout.fileHandleForWriting.closeFile()"))
        XCTAssertTrue(runnerSource.contains("stderr.fileHandleForWriting.closeFile()"))
    }

    func testExecuteDoesNotPrecreateFreshONTPacBioDemuxOutputDirectoryBeforeLaunchingCLI() async throws {
        let tempDir = try FASTQOperationTestHelper.makeTempDir(prefix: "FASTQExecFreshDemuxOutput")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let inputDirectory = tempDir.appendingPathComponent("barcode13", isDirectory: true)
        try FileManager.default.createDirectory(at: inputDirectory, withIntermediateDirectories: true)
        let barcodesURL = tempDir.appendingPathComponent("NB13_MHC-I_plate1.barcodes.csv")
        try "sample,forward,reverse\nLF1001,ACGT,TGCA\n".write(to: barcodesURL, atomically: true, encoding: .utf8)
        let workingDirectory = tempDir.appendingPathComponent("ont-pacbio-barcode-demultiplex", isDirectory: true)

        let runner = SpyCommandRunner { invocation, processWorkingDirectory in
            let outputIndex = try XCTUnwrap(invocation.arguments.firstIndex(of: "--output"))
            let outputURL = URL(fileURLWithPath: invocation.arguments[outputIndex + 1], isDirectory: true)
            XCTAssertEqual(outputURL.standardizedFileURL, workingDirectory.standardizedFileURL)
            XCTAssertEqual(processWorkingDirectory.standardizedFileURL, tempDir.standardizedFileURL)
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: outputURL.path),
                "The GUI runner must not pre-create fresh demux output directories before invoking CLI tools that create their own output root."
            )

            let sampleBundle = try FASTQOperationTestHelper.makeBundle(named: "LF1001", in: outputURL)
            try FASTQOperationTestHelper.writeSyntheticFASTQ(to: sampleBundle.fastqURL, readCount: 1, readLength: 20)
            return FASTQCLIExecutionResult(outputURLs: [sampleBundle.bundleURL])
        }
        let importer = SpyDirectImporter()
        let service = FASTQOperationExecutionService(
            commandRunner: runner,
            directImporter: importer
        )

        let result = try await service.execute(
            request: .ontPacBioBarcodeDemux(
                inputFASTQURL: inputDirectory,
                barcodeDefinitionsURL: barcodesURL,
                threads: 1,
                chunkJobs: 2,
                maxReadsPerSlice: 100_000,
                maxBytesPerCutadapt: 536_870_912
            ),
            workingDirectory: workingDirectory
        )

        XCTAssertEqual(runner.invocations.count, 1)
        XCTAssertEqual(result.importedURLs.map(\.lastPathComponent), ["LF1001.\(FASTQBundle.directoryExtension)"])
    }

    func testExecuteRemovesFreshOutputDirectoryAfterCommandFailure() async throws {
        let tempDir = try FASTQOperationTestHelper.makeTempDir(prefix: "FASTQExecFailedDemuxCleanup")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let inputDirectory = tempDir.appendingPathComponent("barcode13", isDirectory: true)
        try FileManager.default.createDirectory(at: inputDirectory, withIntermediateDirectories: true)
        let barcodesURL = tempDir.appendingPathComponent("NB13_MHC-I_plate1.barcodes.csv")
        try "sample,forward,reverse\nLF1001,ACGT,TGCA\n".write(to: barcodesURL, atomically: true, encoding: .utf8)
        let workingDirectory = tempDir.appendingPathComponent("ont-pacbio-barcode-demultiplex", isDirectory: true)

        let runner = SpyCommandRunner { invocation, _ in
            let outputIndex = try XCTUnwrap(invocation.arguments.firstIndex(of: "--output"))
            let outputURL = URL(fileURLWithPath: invocation.arguments[outputIndex + 1], isDirectory: true)
            try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
            try "partial\n".write(
                to: outputURL.appendingPathComponent("partial.txt"),
                atomically: true,
                encoding: .utf8
            )
            throw SyntheticCommandFailure.commandFailed
        }
        let service = FASTQOperationExecutionService(
            commandRunner: runner,
            directImporter: SpyDirectImporter()
        )

        do {
            _ = try await service.execute(
                request: FASTQOperationLaunchRequest.ontPacBioBarcodeDemux(
                    inputFASTQURL: inputDirectory,
                    barcodeDefinitionsURL: barcodesURL,
                    threads: 1,
                    chunkJobs: 2,
                    maxReadsPerSlice: 100_000,
                    maxBytesPerCutadapt: 536_870_912
                ),
                workingDirectory: workingDirectory
            )
            XCTFail("Expected command failure")
        } catch SyntheticCommandFailure.commandFailed {
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: workingDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.path))
    }

    func testExecuteRemovesTransientFASTQOperationStagingAfterCommandFailure() async throws {
        let tempDir = try FASTQOperationTestHelper.makeTempDir(prefix: "FASTQExecFailedGenericCleanup")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let inputURL = tempDir.appendingPathComponent("input.fastq")
        try FASTQOperationTestHelper.writeSyntheticFASTQ(to: inputURL, readCount: 2, readLength: 16)
        let runner = SpyCommandRunner { _, outputDirectory in
            try "partial\n".write(
                to: outputDirectory.appendingPathComponent("partial.txt"),
                atomically: true,
                encoding: .utf8
            )
            throw SyntheticCommandFailure.commandFailed
        }
        let service = FASTQOperationExecutionService(
            commandRunner: runner,
            directImporter: SpyDirectImporter()
        )

        do {
            _ = try await service.execute(
                request: FASTQOperationLaunchRequest.derivative(
                    request: FASTQDerivativeRequest.lengthFilter(min: 10, max: 40),
                    inputURLs: [inputURL],
                    outputMode: FASTQOperationOutputMode.perInput
                ),
                workingDirectory: tempDir
            )
            XCTFail("Expected command failure")
        } catch SyntheticCommandFailure.commandFailed {
        }

        let remainingEntries = try FileManager.default.contentsOfDirectory(
            at: tempDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        XCTAssertFalse(remainingEntries.contains { $0.lastPathComponent.hasPrefix("cli-output-") })
    }

    func testBuildInvocationRoutesCombinedFastpTrimToFastqTrimCommand() throws {
        let service = FASTQOperationExecutionService()
        let inputURL = URL(fileURLWithPath: "/tmp/sample.lungfishfastq")

        let invocation = try service.buildInvocation(
            for: .derivative(
                request: .fastpTrim(
                    threshold: 20,
                    windowSize: 4,
                    mode: .cutRight,
                    adapterMode: .autoDetect,
                    adapterSequence: nil
                ),
                inputURLs: [inputURL],
                outputMode: .perInput
            )
        )

        XCTAssertEqual(invocation.subcommand, "fastq")
        XCTAssertEqual(invocation.arguments.first, "trim")
        XCTAssertTrue(invocation.arguments.contains("--adapter-trimming"))
        XCTAssertTrue(invocation.arguments.contains("--threshold"))
        XCTAssertTrue(invocation.arguments.contains("--window"))
    }

    func testExecuteDerivativeDiscoversStagedFASTQFileAndImportsIt() async throws {
        let tempDir = try FASTQOperationTestHelper.makeTempDir(prefix: "FASTQExecService")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let inputURL = tempDir.appendingPathComponent("input.fastq")
        try FASTQOperationTestHelper.writeSyntheticFASTQ(to: inputURL, readCount: 3, readLength: 18)

        let resolver = SpyInputResolver(
            resolvedRequest: .derivative(
                request: .lengthFilter(min: 10, max: 40),
                inputURLs: [inputURL],
                outputMode: .perInput
            )
        )
        let runner = SpyCommandRunner { invocation, _ in
            guard
                let outputIndex = invocation.arguments.firstIndex(of: "-o"),
                invocation.arguments.indices.contains(outputIndex + 1)
            else {
                XCTFail("Expected -o output path in CLI invocation")
                throw NSError(
                    domain: "FASTQOperationExecutionServiceTests",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Missing -o output path in CLI invocation"]
                )
            }

            let outputURL = URL(fileURLWithPath: invocation.arguments[outputIndex + 1])
            XCTAssertTrue(FASTQBundle.isFASTQFileURL(outputURL), "Expected a staged FASTQ file output path")
            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FASTQOperationTestHelper.writeSyntheticFASTQ(to: outputURL, readCount: 2, readLength: 16)
            return FASTQCLIExecutionResult(outputURLs: [])
        }
        let importer = SpyDirectImporter()
        let service = FASTQOperationExecutionService(
            inputResolver: resolver,
            commandRunner: runner,
            directImporter: importer
        )

        let importedBundle = tempDir.appendingPathComponent("filtered.\(FASTQBundle.directoryExtension)")
        importer.resultURLs = [importedBundle]

        let result = try await service.execute(
            request: .derivative(
                request: .lengthFilter(min: 10, max: 40),
                inputURLs: [inputURL],
                outputMode: .perInput
            ),
            workingDirectory: tempDir
        )

        XCTAssertEqual(result.importedURLs, [importedBundle])
        XCTAssertEqual(importer.calls.count, 1)
        XCTAssertEqual(importer.calls[0].count, 1)
        XCTAssertTrue(FASTQBundle.isFASTQFileURL(importer.calls[0][0]))
    }

    func testExecuteDerivativeRemovesTransientStagingDirectoriesAfterImport() async throws {
        let tempDir = try FASTQOperationTestHelper.makeTempDir(prefix: "FASTQExecService")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let inputURL = tempDir.appendingPathComponent("input.fastq")
        try FASTQOperationTestHelper.writeSyntheticFASTQ(to: inputURL, readCount: 3, readLength: 18)

        let runner = SpyCommandRunner { invocation, _ in
            guard
                let outputIndex = invocation.arguments.firstIndex(of: "-o"),
                invocation.arguments.indices.contains(outputIndex + 1)
            else {
                XCTFail("Expected -o output path in CLI invocation")
                throw NSError(domain: "FASTQOperationExecutionServiceTests", code: 11)
            }

            let outputURL = URL(fileURLWithPath: invocation.arguments[outputIndex + 1])
            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FASTQOperationTestHelper.writeSyntheticFASTQ(to: outputURL, readCount: 2, readLength: 16)
            return FASTQCLIExecutionResult(outputURLs: [])
        }
        let importer = SpyDirectImporter()
        let importedBundle = tempDir.appendingPathComponent("filtered.\(FASTQBundle.directoryExtension)", isDirectory: true)
        importer.resultURLs = [importedBundle]
        let service = FASTQOperationExecutionService(
            commandRunner: runner,
            directImporter: importer
        )

        _ = try await service.execute(
            request: .derivative(
                request: .lengthFilter(min: 10, max: 40),
                inputURLs: [inputURL],
                outputMode: .perInput
            ),
            workingDirectory: tempDir
        )

        let leftoverNames = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        XCTAssertFalse(leftoverNames.contains { $0.hasPrefix("cli-output-") })
        XCTAssertFalse(leftoverNames.contains { $0.hasPrefix("materialized-inputs-") })
    }

    func testExecuteDerivativeMaterializesMultiFileBundleIntoSingleCLIInput() async throws {
        let tempDir = try FASTQOperationTestHelper.makeTempDir(prefix: "FASTQExecService")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let bundleURL = tempDir.appendingPathComponent(
            "multi.\(FASTQBundle.directoryExtension)",
            isDirectory: true
        )
        let chunksDir = bundleURL.appendingPathComponent("chunks", isDirectory: true)
        try FileManager.default.createDirectory(at: chunksDir, withIntermediateDirectories: true)

        let chunkA = chunksDir.appendingPathComponent("chunk-a.fastq")
        let chunkB = chunksDir.appendingPathComponent("chunk-b.fastq")
        try FASTQOperationTestHelper.writeSyntheticFASTQ(to: chunkA, readCount: 2, readLength: 12, idPrefix: "chunkA")
        try FASTQOperationTestHelper.writeSyntheticFASTQ(to: chunkB, readCount: 1, readLength: 12, idPrefix: "chunkB")

        try """
        {
          "version": 1,
          "files": [
            {
              "filename": "chunks/chunk-a.fastq",
              "originalPath": "/tmp/chunk-a.fastq",
              "sizeBytes": 1,
              "isSymlink": false
            },
            {
              "filename": "chunks/chunk-b.fastq",
              "originalPath": "/tmp/chunk-b.fastq",
              "sizeBytes": 1,
              "isSymlink": false
            }
          ]
        }
        """.write(
            to: bundleURL.appendingPathComponent("source-files.json"),
            atomically: true,
            encoding: .utf8
        )

        let runner = SpyCommandRunner { invocation, _ in
            XCTAssertEqual(invocation.arguments.first, "subsample")
            let resolvedInputPath = try XCTUnwrap(invocation.arguments[safe: 1])
            XCTAssertNotEqual(resolvedInputPath, chunkA.path)
            XCTAssertNotEqual(resolvedInputPath, chunkB.path)

            let resolvedInputURL = URL(fileURLWithPath: resolvedInputPath)
            let resolvedContents = try String(contentsOf: resolvedInputURL, encoding: .utf8)
            XCTAssertTrue(resolvedContents.contains("@chunkA1"))
            XCTAssertTrue(resolvedContents.contains("@chunkB1"))

            guard
                let outputIndex = invocation.arguments.firstIndex(of: "-o"),
                let outputPath = invocation.arguments[safe: outputIndex + 1]
            else {
                XCTFail("Expected -o output path in CLI invocation")
                throw NSError(
                    domain: "FASTQOperationExecutionServiceTests",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Missing -o output path in multi-file invocation"]
                )
            }

            let outputURL = URL(fileURLWithPath: outputPath)
            try FASTQOperationTestHelper.writeSyntheticFASTQ(to: outputURL, readCount: 2, readLength: 12, idPrefix: "output")
            return FASTQCLIExecutionResult(outputURLs: [])
        }
        let importer = SpyDirectImporter()
        let service = FASTQOperationExecutionService(
            commandRunner: runner,
            directImporter: importer
        )

        _ = try await service.execute(
            request: .derivative(
                request: .subsampleCount(2),
                inputURLs: [bundleURL],
                outputMode: .perInput
            ),
            workingDirectory: tempDir
        )

        XCTAssertEqual(runner.invocations.count, 1)
        XCTAssertEqual(importer.calls.count, 1)
    }

    func testExecuteExactBareDemultiplexPreservesMultiFileBundleInput() async throws {
        let tempDir = try FASTQOperationTestHelper.makeTempDir(prefix: "FASTQExecExactBareMulti")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let bundleURL = tempDir.appendingPathComponent(
            "multi.\(FASTQBundle.directoryExtension)",
            isDirectory: true
        )
        let chunksDir = bundleURL.appendingPathComponent("chunks", isDirectory: true)
        try FileManager.default.createDirectory(at: chunksDir, withIntermediateDirectories: true)

        let chunkA = chunksDir.appendingPathComponent("chunk-a.fastq")
        let chunkB = chunksDir.appendingPathComponent("chunk-b.fastq")
        try FASTQOperationTestHelper.writeSyntheticFASTQ(to: chunkA, readCount: 2, readLength: 12, idPrefix: "chunkA")
        try FASTQOperationTestHelper.writeSyntheticFASTQ(to: chunkB, readCount: 1, readLength: 12, idPrefix: "chunkB")

        try """
        {
          "version": 1,
          "files": [
            {
              "filename": "chunks/chunk-a.fastq",
              "originalPath": "/tmp/chunk-a.fastq",
              "sizeBytes": 1,
              "isSymlink": false
            },
            {
              "filename": "chunks/chunk-b.fastq",
              "originalPath": "/tmp/chunk-b.fastq",
              "sizeBytes": 1,
              "isSymlink": false
            }
          ]
        }
        """.write(
            to: bundleURL.appendingPathComponent("source-files.json"),
            atomically: true,
            encoding: .utf8
        )

        let runner = SpyCommandRunner { invocation, outputDirectory in
            XCTAssertEqual(Array(invocation.arguments.prefix(2)), ["demultiplex", bundleURL.path])
            XCTAssertTrue(invocation.arguments.contains("--engine"))
            XCTAssertTrue(invocation.arguments.contains(DemultiplexEngine.exactBareBarcode.rawValue))
            let outputBundle = outputDirectory.appendingPathComponent(
                "DW472.\(FASTQBundle.directoryExtension)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: outputBundle, withIntermediateDirectories: true)
            try FASTQOperationTestHelper.writeSyntheticFASTQ(
                to: outputBundle.appendingPathComponent("DW472.fastq"),
                readCount: 1,
                readLength: 12,
                idPrefix: "DW472"
            )
            try writeSyntheticProvenance(
                to: outputBundle,
                name: "Exact bare demux",
                toolName: "exact-bare-barcode-demux",
                toolVersion: "test",
                command: invocation.arguments,
                inputURL: chunkA,
                outputURL: outputBundle.appendingPathComponent("DW472.fastq")
            )
            return FASTQCLIExecutionResult(outputURLs: [outputBundle])
        }
        let service = FASTQOperationExecutionService(commandRunner: runner)

        let result = try await service.execute(
            request: .derivative(
                request: .demultiplex(
                    kitID: "custom",
                    customCSVPath: "/tmp/barcodes.csv",
                    location: "bothends",
                    symmetryMode: nil,
                    maxDistanceFrom5Prime: 0,
                    maxDistanceFrom3Prime: 0,
                    errorRate: 0.15,
                    engine: .exactBareBarcode,
                    trimBarcodes: false,
                    sampleAssignments: nil,
                    kitOverride: nil
                ),
                inputURLs: [bundleURL],
                outputMode: .groupedResult
            ),
            workingDirectory: tempDir.appendingPathComponent("demux", isDirectory: true)
        )

        XCTAssertEqual(runner.invocations.count, 1)
        XCTAssertEqual(result.resolvedRequest.inputURLs, [bundleURL])
    }

    func testExecuteMaterializesVirtualBundleInputBeforeInvocation() async throws {
        let tempDir = try FASTQOperationTestHelper.makeTempDir(prefix: "FASTQExecService")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let bundleURL = tempDir.appendingPathComponent(
            "virtual.\(FASTQBundle.directoryExtension)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let materializedURL = tempDir.appendingPathComponent("materialized.fastq")
        try FASTQOperationTestHelper.writeSyntheticFASTQ(to: materializedURL, readCount: 2, readLength: 12)

        let resolver = SpyInputResolver(
            resolvedRequest: .derivative(
                request: .subsampleCount(5),
                inputURLs: [materializedURL],
                outputMode: .perInput
            )
        )
        let runner = SpyCommandRunner()
        let importer = SpyDirectImporter()
        let service = FASTQOperationExecutionService(
            inputResolver: resolver,
            commandRunner: runner,
            directImporter: importer
        )

        _ = try await service.execute(
            request: .derivative(
                request: .subsampleCount(5),
                inputURLs: [bundleURL],
                outputMode: .perInput
            ),
            workingDirectory: tempDir
        )

        XCTAssertEqual(resolver.requests, [
            .derivative(
                request: .subsampleCount(5),
                inputURLs: [bundleURL],
                outputMode: .perInput
            )
        ])
        XCTAssertEqual(runner.invocations.map { $0.arguments.first }, ["subsample"])
        XCTAssertTrue(runner.invocations[0].arguments.contains(materializedURL.path))
    }

    func testExecuteDerivativeBridgesDerivedFASTAInputToSyntheticFASTQ() async throws {
        let tempDir = try FASTQOperationTestHelper.makeTempDir(prefix: "FASTQExecFASTA")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fastaBundleURL = try makeFullFASTABundle(
            named: "fasta-input",
            in: tempDir,
            records: [
                (id: "seq1", sequence: "AACCGGTTAACC"),
                (id: "seq2", sequence: "TTGGCCAATTGG"),
            ]
        )

        let runner = SpyCommandRunner { invocation, _ in
            XCTAssertEqual(invocation.subcommand, "fastq")
            XCTAssertEqual(invocation.arguments.first, "adapter-trim")

            let bridgedInputURL = URL(fileURLWithPath: try XCTUnwrap(invocation.arguments[safe: 1]))
            XCTAssertEqual(SequenceFormat.from(url: bridgedInputURL), .fastq)

            let bridgedContents = try String(contentsOf: bridgedInputURL, encoding: .utf8)
            XCTAssertTrue(bridgedContents.contains("@seq1"))
            XCTAssertTrue(bridgedContents.contains("AACCGGTTAACC"))
            XCTAssertTrue(bridgedContents.contains("+"))
            XCTAssertTrue(bridgedContents.contains("IIIIIIIIIIII"))

            return FASTQCLIExecutionResult(outputURLs: [])
        }
        let importer = SpyDirectImporter()
        let service = FASTQOperationExecutionService(
            commandRunner: runner,
            directImporter: importer
        )

        _ = try await service.execute(
            request: .derivative(
                request: .adapterTrim(
                    mode: .autoDetect,
                    sequence: nil,
                    sequenceR2: nil,
                    fastaFilename: nil
                ),
                inputURLs: [fastaBundleURL],
                outputMode: .perInput
            ),
            workingDirectory: tempDir
        )

        XCTAssertEqual(runner.invocations.count, 1)
    }

    func testExecuteDerivativeBridgesReferenceBundleInputToSyntheticFASTQ() async throws {
        let tempDir = try FASTQOperationTestHelper.makeTempDir(prefix: "FASTQExecRefFASTA")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let referenceBundleURL = try makeReferenceBundle(
            named: "reference-input",
            in: tempDir,
            records: [
                (id: "contig1", sequence: "AACCGGTTAACC"),
                (id: "contig2", sequence: "TTGGCCAATTGG"),
            ]
        )

        let runner = SpyCommandRunner { invocation, _ in
            XCTAssertEqual(invocation.subcommand, "fastq")
            XCTAssertEqual(invocation.arguments.first, "adapter-trim")

            let bridgedInputURL = URL(fileURLWithPath: try XCTUnwrap(invocation.arguments[safe: 1]))
            XCTAssertEqual(SequenceFormat.from(url: bridgedInputURL), .fastq)

            let bridgedContents = try String(contentsOf: bridgedInputURL, encoding: .utf8)
            XCTAssertTrue(bridgedContents.contains("@contig1"))
            XCTAssertTrue(bridgedContents.contains("AACCGGTTAACC"))
            XCTAssertTrue(bridgedContents.contains("IIIIIIIIIIII"))

            return FASTQCLIExecutionResult(outputURLs: [])
        }
        let importer = SpyDirectImporter()
        let service = FASTQOperationExecutionService(
            commandRunner: runner,
            directImporter: importer
        )

        _ = try await service.execute(
            request: .derivative(
                request: .adapterTrim(
                    mode: .autoDetect,
                    sequence: nil,
                    sequenceR2: nil,
                    fastaFilename: nil
                ),
                inputURLs: [referenceBundleURL],
                outputMode: .perInput
            ),
            workingDirectory: tempDir
        )

        XCTAssertEqual(runner.invocations.count, 1)
    }

    func testExecuteDeaconRiboPreservesFASTAInputAndDiscoversFASTAOutputs() async throws {
        let tempDir = try FASTQOperationTestHelper.makeTempDir(prefix: "FASTQExecRiboFASTA")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let referenceBundleURL = try makeReferenceBundle(
            named: "reference-input",
            in: tempDir,
            records: [
                (id: "contig1", sequence: "AACCGGTTAACC"),
                (id: "contig2", sequence: "TTGGCCAATTGG"),
            ]
        )

        let runner = SpyCommandRunner { invocation, outputDirectory in
            XCTAssertEqual(invocation.subcommand, "fastq")
            XCTAssertEqual(invocation.arguments.first, "deacon-ribo")
            let resolvedInputURL = URL(fileURLWithPath: try XCTUnwrap(invocation.arguments[safe: 1]))
            XCTAssertEqual(SequenceFormat.from(url: resolvedInputURL), .fasta)
            XCTAssertFalse(resolvedInputURL.lastPathComponent.hasSuffix(".fastq"))
            XCTAssertEqual(invocation.arguments[safe: 2], "--database-id")
            XCTAssertEqual(invocation.arguments[safe: 3], "deacon-ribokmers")
            XCTAssertEqual(invocation.arguments[safe: 4], "--retain")
            XCTAssertEqual(invocation.arguments[safe: 5], "both")

            guard
                let outputIndex = invocation.arguments.firstIndex(of: "-o"),
                let outputPath = invocation.arguments[safe: outputIndex + 1]
            else {
                XCTFail("Expected -o output directory in CLI invocation")
                throw NSError(
                    domain: "FASTQOperationExecutionServiceTests",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Missing -o output directory in Deacon rRNA invocation"]
                )
            }
            XCTAssertEqual(URL(fileURLWithPath: outputPath), outputDirectory)

            try ">contig1\nAACCGGTTAACC\n".write(
                to: outputDirectory.appendingPathComponent("reference-input.norrna.fasta"),
                atomically: true,
                encoding: .utf8
            )
            try ">contig2\nTTGGCCAATTGG\n".write(
                to: outputDirectory.appendingPathComponent("reference-input.rrna.fasta"),
                atomically: true,
                encoding: .utf8
            )
            return FASTQCLIExecutionResult(outputURLs: [])
        }
        let importer = SpyDirectImporter()
        let service = FASTQOperationExecutionService(
            commandRunner: runner,
            directImporter: importer
        )

        _ = try await service.execute(
            request: .derivative(
                request: .ribosomalRNAFilter(retention: .both, ensure: .rrna),
                inputURLs: [referenceBundleURL],
                outputMode: .perInput
            ),
            workingDirectory: tempDir
        )

        XCTAssertEqual(runner.invocations.count, 1)
        XCTAssertEqual(importer.calls.count, 1)
        XCTAssertEqual(importer.calls[0].map(\.lastPathComponent), [
            "reference-input.norrna.fasta",
            "reference-input.rrna.fasta",
        ])
    }

    func testExecuteForwardsResolvedInputsIntoBuiltInvocation() async throws {
        let tempDir = try FASTQOperationTestHelper.makeTempDir(prefix: "FASTQExecService")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let resolvedR1 = tempDir.appendingPathComponent("resolved-R1.fastq")
        let resolvedR2 = tempDir.appendingPathComponent("resolved-R2.fastq")
        let referenceURL = tempDir.appendingPathComponent("reference.fasta")
        try FASTQOperationTestHelper.writeSyntheticFASTQ(to: resolvedR1, readCount: 1, readLength: 10)
        try FASTQOperationTestHelper.writeSyntheticFASTQ(to: resolvedR2, readCount: 1, readLength: 10)
        try ">ref\nAACCGGTT\n".write(to: referenceURL, atomically: true, encoding: .utf8)

        let resolver = SpyInputResolver(
            resolvedRequest: .map(
                inputURLs: [resolvedR1, resolvedR2],
                referenceURL: referenceURL,
                outputMode: .groupedResult
            )
        )
        let runner = SpyCommandRunner { _, outputDirectory in
            let bamURL = outputDirectory.appendingPathComponent("mapped.bam")
            try Data("bam\n".utf8).write(to: bamURL, options: .atomic)
            try writeSyntheticProvenance(
                to: outputDirectory,
                name: "minimap2 mapping",
                toolName: "minimap2",
                toolVersion: "2.28",
                command: ["minimap2", referenceURL.path, resolvedR1.path, resolvedR2.path, "-o", bamURL.path],
                inputURL: resolvedR1,
                outputURL: bamURL,
                format: .bam
            )
            return FASTQCLIExecutionResult(outputURLs: [bamURL])
        }
        let importer = SpyDirectImporter()
        let service = FASTQOperationExecutionService(
            inputResolver: resolver,
            commandRunner: runner,
            directImporter: importer
        )

        _ = try await service.execute(
            request: .map(
                inputURLs: [
                    tempDir.appendingPathComponent("raw-R1.\(FASTQBundle.directoryExtension)"),
                    tempDir.appendingPathComponent("raw-R2.\(FASTQBundle.directoryExtension)")
                ],
                referenceURL: referenceURL,
                outputMode: .groupedResult
            ),
            workingDirectory: tempDir
        )

        XCTAssertEqual(runner.invocations.count, 1)
        XCTAssertEqual(runner.invocations[0].subcommand, "map")
        XCTAssertEqual(Array(runner.invocations[0].arguments[0..<2]), [
            resolvedR1.path,
            resolvedR2.path,
        ])
        XCTAssertTrue(runner.invocations[0].arguments.contains("--paired"))
    }

    func testExecuteGroupedResultWritesBatchManifestAndReturnsGroupedContainer() async throws {
        let tempDir = try FASTQOperationTestHelper.makeTempDir(prefix: "FASTQExecService")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let groupedOutputDir = tempDir.appendingPathComponent("grouped-output", isDirectory: true)
        try FileManager.default.createDirectory(at: groupedOutputDir, withIntermediateDirectories: true)

        let inputABundle = try FASTQOperationTestHelper.makeBundle(named: "input-a", in: tempDir)
        let inputBBundle = try FASTQOperationTestHelper.makeBundle(named: "input-b", in: tempDir)
        try FASTQOperationTestHelper.writeSyntheticFASTQ(to: inputABundle.fastqURL, readCount: 2, readLength: 20)
        try FASTQOperationTestHelper.writeSyntheticFASTQ(to: inputBBundle.fastqURL, readCount: 2, readLength: 20)

        let resolver = SpyInputResolver(
            resolvedRequest: .derivative(
                request: .lengthFilter(min: 100, max: 500),
                inputURLs: [inputABundle.bundleURL, inputBBundle.bundleURL],
                outputMode: .groupedResult
            )
        )
        let runner = SpyCommandRunner { _, outputDirectory in
            let outputABundle = try FASTQOperationTestHelper.makeBundle(named: "filtered-a", in: outputDirectory)
            let outputBBundle = try FASTQOperationTestHelper.makeBundle(named: "filtered-b", in: outputDirectory)
            try FASTQOperationTestHelper.writeSyntheticFASTQ(to: outputABundle.fastqURL, readCount: 1, readLength: 20)
            try FASTQOperationTestHelper.writeSyntheticFASTQ(to: outputBBundle.fastqURL, readCount: 1, readLength: 20)
            try writeSyntheticProvenance(
                to: outputABundle.bundleURL,
                name: "lungfish fastq length-filter",
                toolName: "seqkit",
                toolVersion: "2.9.0",
                command: ["seqkit", "seq", inputABundle.fastqURL.path, "-o", outputABundle.fastqURL.path],
                inputURL: inputABundle.fastqURL,
                outputURL: outputABundle.fastqURL
            )
            try writeSyntheticProvenance(
                to: outputBBundle.bundleURL,
                name: "lungfish fastq length-filter",
                toolName: "seqkit",
                toolVersion: "2.9.0",
                command: ["seqkit", "seq", inputBBundle.fastqURL.path, "-o", outputBBundle.fastqURL.path],
                inputURL: inputBBundle.fastqURL,
                outputURL: outputBBundle.fastqURL
            )
            return FASTQCLIExecutionResult(outputURLs: [outputABundle.bundleURL, outputBBundle.bundleURL])
        }
        let importer = SpyDirectImporter()
        let service = FASTQOperationExecutionService(
            inputResolver: resolver,
            commandRunner: runner,
            directImporter: importer
        )

        let result = try await service.execute(
            request: .derivative(
                request: .lengthFilter(min: 100, max: 500),
                inputURLs: [inputABundle.bundleURL, inputBBundle.bundleURL],
                outputMode: .groupedResult
            ),
            workingDirectory: groupedOutputDir
        )

        let groupedURL = try XCTUnwrap(result.groupedContainerURL)
        XCTAssertEqual(result.importedURLs, [groupedURL])
        XCTAssertTrue(FileManager.default.fileExists(atPath: groupedURL.appendingPathComponent(FASTQBatchManifest.filename).path))
        XCTAssertTrue(importer.calls.isEmpty, "Grouped results should bypass direct import")
        XCTAssertNotNil(ProvenanceRecorder.loadEnvelope(from: groupedURL))

        let manifest = try XCTUnwrap(FASTQBatchManifest.load(from: groupedURL))
        XCTAssertEqual(manifest.operations.count, 1)
        let record = try XCTUnwrap(manifest.operations.first)
        XCTAssertEqual(record.outputBundlePaths.sorted(), [
            "filtered-a.\(FASTQBundle.directoryExtension)",
            "filtered-b.\(FASTQBundle.directoryExtension)",
        ])
        XCTAssertEqual(record.inputBundlePaths.sorted(), [
            "../input-a.\(FASTQBundle.directoryExtension)",
            "../input-b.\(FASTQBundle.directoryExtension)",
        ])
    }

    func testExecuteGroupedResultRejectsRootSidecarWhenChildOutputsLackProvenance() async throws {
        let tempDir = try FASTQOperationTestHelper.makeTempDir(prefix: "FASTQExecService")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let groupedOutputDir = tempDir.appendingPathComponent("grouped-output", isDirectory: true)
        try FileManager.default.createDirectory(at: groupedOutputDir, withIntermediateDirectories: true)

        let inputBundle = try FASTQOperationTestHelper.makeBundle(named: "input", in: tempDir)
        try FASTQOperationTestHelper.writeSyntheticFASTQ(to: inputBundle.fastqURL, readCount: 2, readLength: 20)

        try ProvenanceWriter(signingProvider: nil).write(
            ProvenanceEnvelope(
                workflowName: "stale grouped root",
                toolName: "lungfish gui",
                argv: ["lungfish", "gui"],
                output: ProvenanceFileDescriptor(path: groupedOutputDir.path, role: .output),
                outputs: [ProvenanceFileDescriptor(path: groupedOutputDir.path, role: .output)],
                exitStatus: 0
            ),
            to: groupedOutputDir
        )

        let resolver = SpyInputResolver(
            resolvedRequest: .derivative(
                request: .lengthFilter(min: 100, max: 500),
                inputURLs: [inputBundle.bundleURL],
                outputMode: .groupedResult
            )
        )
        let runner = SpyCommandRunner { _, outputDirectory in
            let outputBundle = try FASTQOperationTestHelper.makeBundle(named: "filtered", in: outputDirectory)
            try FASTQOperationTestHelper.writeSyntheticFASTQ(to: outputBundle.fastqURL, readCount: 1, readLength: 20)
            return FASTQCLIExecutionResult(outputURLs: [outputBundle.bundleURL])
        }
        let service = FASTQOperationExecutionService(
            inputResolver: resolver,
            commandRunner: runner,
            directImporter: SpyDirectImporter()
        )

        do {
            _ = try await service.execute(
                request: .derivative(
                    request: .lengthFilter(min: 100, max: 500),
                    inputURLs: [inputBundle.bundleURL],
                    outputMode: .groupedResult
                ),
                workingDirectory: groupedOutputDir
            )
            XCTFail("Expected grouped result execution to reject child outputs without provenance")
        } catch let error as ProvenanceRehydrationError {
            guard case .missingSourceProvenance = error else {
                return XCTFail("Expected missing source provenance, got \(error)")
            }
        }
    }

    func testExecuteGroupedResultRefreshesStaleRootSidecarWhenChildrenHaveProvenance() async throws {
        let tempDir = try FASTQOperationTestHelper.makeTempDir(prefix: "FASTQExecService")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let groupedOutputDir = tempDir.appendingPathComponent("grouped-output", isDirectory: true)
        try FileManager.default.createDirectory(at: groupedOutputDir, withIntermediateDirectories: true)

        let inputBundle = try FASTQOperationTestHelper.makeBundle(named: "input", in: tempDir)
        try FASTQOperationTestHelper.writeSyntheticFASTQ(to: inputBundle.fastqURL, readCount: 2, readLength: 20)

        let staleOutput = groupedOutputDir.appendingPathComponent("old.fastq")
        try FASTQOperationTestHelper.writeSyntheticFASTQ(to: staleOutput, readCount: 1, readLength: 20)
        try ProvenanceWriter(signingProvider: nil).write(
            ProvenanceEnvelope(
                workflowName: "stale grouped root",
                toolName: "lungfish gui",
                argv: ["lungfish", "gui"],
                output: try ProvenanceFileDescriptor.file(url: staleOutput, role: .output),
                outputs: [try ProvenanceFileDescriptor.file(url: staleOutput, role: .output)],
                exitStatus: 0
            ),
            to: groupedOutputDir
        )

        let resolver = SpyInputResolver(
            resolvedRequest: .derivative(
                request: .lengthFilter(min: 100, max: 500),
                inputURLs: [inputBundle.bundleURL],
                outputMode: .groupedResult
            )
        )
        let runner = SpyCommandRunner { _, outputDirectory in
            let outputBundle = try FASTQOperationTestHelper.makeBundle(named: "filtered", in: outputDirectory)
            try FASTQOperationTestHelper.writeSyntheticFASTQ(to: outputBundle.fastqURL, readCount: 1, readLength: 20)
            try writeSyntheticProvenance(
                to: outputBundle.bundleURL,
                name: "lungfish fastq length-filter",
                toolName: "seqkit",
                toolVersion: "2.9.0",
                command: ["seqkit", "seq", inputBundle.fastqURL.path, "-o", outputBundle.fastqURL.path],
                inputURL: inputBundle.fastqURL,
                outputURL: outputBundle.fastqURL
            )
            return FASTQCLIExecutionResult(outputURLs: [outputBundle.bundleURL])
        }
        let service = FASTQOperationExecutionService(
            inputResolver: resolver,
            commandRunner: runner,
            directImporter: SpyDirectImporter()
        )

        _ = try await service.execute(
            request: .derivative(
                request: .lengthFilter(min: 100, max: 500),
                inputURLs: [inputBundle.bundleURL],
                outputMode: .groupedResult
            ),
            workingDirectory: groupedOutputDir
        )

        let envelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: groupedOutputDir))
        XCTAssertEqual(envelope.toolName, "lungfish gui grouped FASTQ operation")
        XCTAssertTrue(envelope.outputs.contains { $0.path.hasSuffix("filtered.\(FASTQBundle.directoryExtension)/reads.fastq") })
    }

    func testExecuteTranslateDerivativeUsesFASTAOutputTarget() async throws {
        let tempDir = try FASTQOperationTestHelper.makeTempDir(prefix: "FASTQExecService")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let inputURL = tempDir.appendingPathComponent("reads.fastq")
        try FASTQOperationTestHelper.writeSyntheticFASTQ(to: inputURL, readCount: 1, readLength: 12)

        let runner = SpyCommandRunner { invocation, _ in
            guard
                let outputIndex = invocation.arguments.firstIndex(of: "-o"),
                invocation.arguments.indices.contains(outputIndex + 1)
            else {
                XCTFail("Expected -o output path in translate invocation")
                throw NSError(domain: "FASTQOperationExecutionServiceTests", code: 1)
            }
            let outputURL = URL(fileURLWithPath: invocation.arguments[outputIndex + 1])
            XCTAssertEqual(outputURL.pathExtension.lowercased(), "fasta")
            try ">read1\nMA\n".write(to: outputURL, atomically: true, encoding: .utf8)
            return FASTQCLIExecutionResult(outputURLs: [outputURL])
        }
        let importer = SpyDirectImporter()
        let service = FASTQOperationExecutionService(commandRunner: runner, directImporter: importer)

        _ = try await service.execute(
            request: .derivative(
                request: .translate(frameOffset: 0),
                inputURLs: [inputURL],
                outputMode: .perInput
            ),
            workingDirectory: tempDir
        )

        XCTAssertEqual(importer.calls.first?.first?.pathExtension.lowercased(), "fasta")
    }

    func testBundleImporterWrapsRawFASTQOutputsIntoBundles() async throws {
        let tempDir = try FASTQOperationTestHelper.makeTempDir(prefix: "FASTQExecImport")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sourceBundle = try FASTQOperationTestHelper.makeBundle(named: "source", in: tempDir)
        try FASTQOperationTestHelper.writeSyntheticFASTQ(
            to: sourceBundle.fastqURL,
            readCount: 4,
            readLength: 20
        )

        let stagingDir = tempDir.appendingPathComponent("staging", isDirectory: true)
        let destinationDir = tempDir.appendingPathComponent("results", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)

        let stagedFASTQ = stagingDir.appendingPathComponent("filtered.fastq")
        try FASTQOperationTestHelper.writeSyntheticFASTQ(to: stagedFASTQ, readCount: 2, readLength: 14)

        let bundleWriter = SpyFASTQOutputBundleWriter(removeSource: true)
        let importer = BundleFASTQOperationImporter(
            destinationDirectory: destinationDir,
            fastqBundleWriter: bundleWriter
        )
        let request = FASTQOperationLaunchRequest.derivative(
            request: .lengthFilter(min: 10, max: 40),
            inputURLs: [sourceBundle.bundleURL],
            outputMode: .perInput
        )

        let imported = try await importer.importOutputs(
            at: [stagedFASTQ],
            forResolvedRequest: request,
            originalRequest: request,
            outputDirectory: stagingDir
        )

        XCTAssertEqual(imported.count, 1)
        let bundleURL = try XCTUnwrap(imported.first)
        XCTAssertTrue(FASTQBundle.isBundleURL(bundleURL))
        XCTAssertEqual(bundleWriter.calls.map(\.sourceURL), [stagedFASTQ])
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedFASTQ.path))
    }

    func testBundleImporterRoutesDeaconRiboFASTQOutputsThroughBundleWriter() async throws {
        let tempDir = try FASTQOperationTestHelper.makeTempDir(prefix: "FASTQExecImportRibo")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sourceBundle = try FASTQOperationTestHelper.makeBundle(named: "source", in: tempDir)
        try FASTQOperationTestHelper.writeSyntheticFASTQ(
            to: sourceBundle.fastqURL,
            readCount: 4,
            readLength: 20
        )

        let stagingDir = tempDir.appendingPathComponent("staging", isDirectory: true)
        let destinationDir = tempDir.appendingPathComponent("results", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)

        let nonRRNAOutput = stagingDir.appendingPathComponent("source.norrna.fastq")
        let rRNAOutput = stagingDir.appendingPathComponent("source.rrna.fastq")
        try FASTQOperationTestHelper.writeSyntheticFASTQ(to: nonRRNAOutput, readCount: 2, readLength: 14)
        try FASTQOperationTestHelper.writeSyntheticFASTQ(to: rRNAOutput, readCount: 1, readLength: 14)

        let bundleWriter = SpyFASTQOutputBundleWriter()
        let importer = BundleFASTQOperationImporter(
            destinationDirectory: destinationDir,
            fastqBundleWriter: bundleWriter
        )
        let request = FASTQOperationLaunchRequest.derivative(
            request: .ribosomalRNAFilter(retention: .both, ensure: .rrna),
            inputURLs: [sourceBundle.bundleURL],
            outputMode: .perInput
        )

        let imported = try await importer.importOutputs(
            at: [nonRRNAOutput, rRNAOutput],
            forResolvedRequest: request,
            originalRequest: request,
            outputDirectory: stagingDir
        )

        XCTAssertEqual(imported.map(\.lastPathComponent), [
            "source-deacon-ribo-norrna.\(FASTQBundle.directoryExtension)",
            "source-deacon-ribo-rrna.\(FASTQBundle.directoryExtension)",
        ])
        XCTAssertEqual(bundleWriter.calls.map(\.sourceURL), [nonRRNAOutput, rRNAOutput])
        XCTAssertEqual(bundleWriter.calls.map(\.bundleURL.lastPathComponent), imported.map(\.lastPathComponent))
        XCTAssertEqual(bundleWriter.calls.compactMap(\.sourceInputURL), [sourceBundle.bundleURL, sourceBundle.bundleURL])
    }

    func testAppFASTQOutputBundleWriterIngestsAndAnnotatesCompressedDeaconRiboOutput() async throws {
        let tempDir = try FASTQOperationTestHelper.makeTempDir(prefix: "FASTQExecImportRiboMetadata")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sourceBundle = try FASTQOperationTestHelper.makeBundle(named: "source", in: tempDir)
        try FASTQOperationTestHelper.writeSyntheticFASTQ(
            to: sourceBundle.fastqURL,
            readCount: 4,
            readLength: 20
        )
        FASTQMetadataStore.save(
            PersistedFASTQMetadata(
                ingestion: IngestionMetadata(
                    isClumpified: true,
                    isCompressed: true,
                    pairingMode: .interleaved,
                    originalFilenames: [sourceBundle.fastqURL.lastPathComponent]
                )
            ),
            for: sourceBundle.fastqURL
        )

        let stagedFASTQ = tempDir.appendingPathComponent("source.norrna.fastq")
        try FASTQOperationTestHelper.writeSyntheticFASTQ(
            to: stagedFASTQ,
            readCount: 2,
            readLength: 14
        )
        try writeSyntheticProvenance(
            to: tempDir,
            name: "Deacon rRNA FASTQ filter",
            toolName: "deacon",
            toolVersion: "0.15.0",
            command: ["deacon", "filter", sourceBundle.fastqURL.path, "-o", stagedFASTQ.path],
            inputURL: sourceBundle.fastqURL,
            outputURL: stagedFASTQ,
            parameters: ["retain": .string("norrna")]
        )

        let destinationBundle = tempDir.appendingPathComponent(
            "source-deacon-ribo-norrna.\(FASTQBundle.directoryExtension)",
            isDirectory: true
        )
        let ingestor = SpyFASTQOutputIngestor()
        let writer = AppFASTQOutputBundleWriter(ingestor: ingestor)
        let request = FASTQOperationLaunchRequest.derivative(
            request: .ribosomalRNAFilter(retention: .nonRRNA, ensure: .rrna),
            inputURLs: [sourceBundle.bundleURL],
            outputMode: .perInput
        )

        let bundleURL = try await writer.importFASTQOutput(
            sourceURL: stagedFASTQ,
            bundleURL: destinationBundle,
            originalRequest: request,
            sourceInputURL: sourceBundle.bundleURL
        )

        XCTAssertEqual(bundleURL, destinationBundle)
        let config = try XCTUnwrap(ingestor.configs.first)
        XCTAssertEqual(config.inputFiles, [stagedFASTQ])
        XCTAssertEqual(config.outputDirectory, destinationBundle)
        XCTAssertFalse(config.skipClumpify)
        XCTAssertTrue(config.deleteOriginals)
        XCTAssertEqual(config.pairingMode.rawValue, FASTQIngestionConfig.PairingMode.interleaved.rawValue)

        let bundledFASTQ = try XCTUnwrap(FASTQBundle.resolvePrimaryFASTQURL(for: bundleURL))
        XCTAssertEqual(bundledFASTQ.pathExtension, "gz")
        let persisted = try XCTUnwrap(FASTQMetadataStore.load(for: bundledFASTQ))
        let ingestion = try XCTUnwrap(persisted.ingestion)
        XCTAssertTrue(ingestion.isCompressed)
        XCTAssertTrue(ingestion.isClumpified)
        XCTAssertEqual(ingestion.pairingMode, .interleaved)
        XCTAssertEqual(ingestion.originalFilenames, [stagedFASTQ.lastPathComponent])

        let manifest = try XCTUnwrap(FASTQBundle.loadDerivedManifest(in: bundleURL))
        XCTAssertEqual(manifest.operation.kind, .ribosomalRNAFilter)
        XCTAssertEqual(manifest.operation.riboDetectorRetention, .nonRRNA)
        XCTAssertEqual(manifest.operation.riboDetectorEnsure, .rrna)
        XCTAssertEqual(manifest.operation.toolUsed, "deacon")
        XCTAssertEqual(manifest.cachedStatistics.readCount, 2)
        XCTAssertEqual(manifest.pairingMode, .interleaved)
        XCTAssertEqual(manifest.sequenceFormat, .fastq)
        XCTAssertEqual(manifest.parentBundleRelativePath, "../source.\(FASTQBundle.directoryExtension)")
        if case .full(let fastqFilename) = manifest.payload {
            XCTAssertEqual(fastqFilename, bundledFASTQ.lastPathComponent)
        } else {
            XCTFail("Expected materialized full FASTQ payload")
        }
    }

    func testAppFASTQOutputBundleWriterPreservesDeaconRiboProvenanceInImportedBundle() async throws {
        let tempDir = try FASTQOperationTestHelper.makeTempDir(prefix: "FASTQExecImportRiboProvenance")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sourceBundle = try FASTQOperationTestHelper.makeBundle(named: "source", in: tempDir)
        try FASTQOperationTestHelper.writeSyntheticFASTQ(
            to: sourceBundle.fastqURL,
            readCount: 4,
            readLength: 20
        )

        let stagingDir = tempDir.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        let stagedFASTQ = stagingDir.appendingPathComponent("source.norrna.fastq")
        try FASTQOperationTestHelper.writeSyntheticFASTQ(
            to: stagedFASTQ,
            readCount: 2,
            readLength: 14
        )
        try writeSyntheticProvenance(
            to: stagingDir,
            name: "Deacon rRNA FASTQ filter",
            toolName: "deacon",
            toolVersion: "0.15.0",
            command: [
                "micromamba", "run", "-n", "deacon", "deacon",
                "filter", "--deplete", "-a", "1", "-r", "0",
                "/data/deacon-ribokmers/ribokmers.k31w15.idx",
                sourceBundle.fastqURL.path, "-o", stagedFASTQ.path, "-t", "4",
            ],
            inputURL: sourceBundle.fastqURL,
            outputURL: stagedFASTQ,
            parameters: [
                "retain": .string("norrna"),
                "databaseID": .string("deacon-ribokmers"),
                "absoluteThreshold": .integer(1),
                "relativeThreshold": .number(0),
                "threads": .integer(4),
            ]
        )

        let destinationBundle = tempDir.appendingPathComponent(
            "source-deacon-ribo-norrna.\(FASTQBundle.directoryExtension)",
            isDirectory: true
        )
        let writer = AppFASTQOutputBundleWriter(ingestor: SpyFASTQOutputIngestor())
        let request = FASTQOperationLaunchRequest.derivative(
            request: .ribosomalRNAFilter(retention: .nonRRNA, ensure: .rrna),
            inputURLs: [sourceBundle.bundleURL],
            outputMode: .perInput
        )

        let bundleURL = try await writer.importFASTQOutput(
            sourceURL: stagedFASTQ,
            bundleURL: destinationBundle,
            originalRequest: request,
            sourceInputURL: sourceBundle.bundleURL
        )

        let bundledFASTQ = try XCTUnwrap(FASTQBundle.resolvePrimaryFASTQURL(for: bundleURL))
        let bundledFASTQPath = bundledFASTQ.standardizedFileURL.path
        let envelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: bundleURL))
        let descriptor = try XCTUnwrap(envelope.output)
        XCTAssertEqual(envelope.workflowName, "Deacon rRNA FASTQ filter")
        XCTAssertEqual(envelope.exitStatus, 0)
        XCTAssertEqual(envelope.toolName, "deacon")
        XCTAssertEqual(envelope.toolVersion, "0.15.0")
        XCTAssertEqual(envelope.argv.prefix(5), ["micromamba", "run", "-n", "deacon", "deacon"])
        XCTAssertEqual(descriptor.path, bundledFASTQPath)
        XCTAssertEqual(descriptor.originPath, stagedFASTQ.path)
        XCTAssertEqual(
            descriptor.sourceProvenancePath,
            stagingDir.appendingPathComponent(ProvenanceRecorder.provenanceFilename).path
        )
        XCTAssertEqual(descriptor.checksumSHA256, try ProvenanceFileHasher.sha256(of: bundledFASTQ))
        XCTAssertEqual(descriptor.fileSize, try ProvenanceFileHasher.fileSize(of: bundledFASTQ))
        XCTAssertEqual(envelope.outputs.map(\.path), [bundledFASTQPath])
        XCTAssertEqual(envelope.steps.first?.outputs.map(\.path), [bundledFASTQPath])

        let provenance = try XCTUnwrap(ProvenanceRecorder.load(from: bundleURL))
        let step = try XCTUnwrap(provenance.steps.first)
        XCTAssertEqual(provenance.name, "Deacon rRNA FASTQ filter")
        XCTAssertEqual(step.outputs.map(\.filename), [bundledFASTQ.lastPathComponent])
        XCTAssertNotNil(ProvenanceRecorder.findProvenance(forFile: bundledFASTQ))
    }

    func testAppFASTQOutputBundleWriterRehydratesMaterializedInputToSourceBundlePayload() async throws {
        let tempDir = try FASTQOperationTestHelper.makeTempDir(prefix: "FASTQExecImportMaterializedInput")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sourceBundle = try FASTQOperationTestHelper.makeBundle(named: "source", in: tempDir)
        try FASTQOperationTestHelper.writeSyntheticFASTQ(
            to: sourceBundle.fastqURL,
            readCount: 4,
            readLength: 20
        )

        let stagingDir = tempDir.appendingPathComponent("staging", isDirectory: true)
        let materializedDir = stagingDir.appendingPathComponent("materialized-inputs-test", isDirectory: true)
        try FileManager.default.createDirectory(at: materializedDir, withIntermediateDirectories: true)

        let materializedInput = materializedDir.appendingPathComponent("materialized-source.fastq")
        try FASTQOperationTestHelper.writeSyntheticFASTQ(
            to: materializedInput,
            readCount: 4,
            readLength: 20
        )
        let stagedFASTQ = stagingDir.appendingPathComponent("source.trimmed.fastq")
        try FASTQOperationTestHelper.writeSyntheticFASTQ(
            to: stagedFASTQ,
            readCount: 3,
            readLength: 18
        )
        try writeSyntheticProvenance(
            to: stagingDir,
            name: "Sequential FASTQ trim",
            toolName: "fastp",
            toolVersion: "1.3.2",
            command: ["fastp", "-i", materializedInput.path, "-o", stagedFASTQ.path],
            inputURL: materializedInput,
            outputURL: stagedFASTQ,
            parameters: ["operation": .string("adapter trim")]
        )

        let destinationBundle = tempDir.appendingPathComponent(
            "source-trimmed.\(FASTQBundle.directoryExtension)",
            isDirectory: true
        )
        let writer = AppFASTQOutputBundleWriter(ingestor: SpyFASTQOutputIngestor())
        let request = FASTQOperationLaunchRequest.derivative(
            request: .adapterTrim(mode: .autoDetect, sequence: nil, sequenceR2: nil, fastaFilename: nil),
            inputURLs: [sourceBundle.bundleURL],
            outputMode: .perInput
        )

        let bundleURL = try await writer.importFASTQOutput(
            sourceURL: stagedFASTQ,
            bundleURL: destinationBundle,
            originalRequest: request,
            sourceInputURL: sourceBundle.bundleURL
        )

        let envelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: bundleURL))
        let stepInput = try XCTUnwrap(envelope.steps.first?.inputs.first)
        XCTAssertEqual(stepInput.path, sourceBundle.fastqURL.path)
        XCTAssertEqual(stepInput.originPath, materializedInput.path)
        XCTAssertEqual(stepInput.checksumSHA256, try ProvenanceFileHasher.sha256(of: sourceBundle.fastqURL))
        XCTAssertFalse(
            envelope.files.contains { $0.path.contains("materialized-inputs-test") },
            "Final bundle provenance should not keep the temporary materialized input as the scientific input"
        )
    }

    func testAppFASTQOutputBundleWriterMakesFullSourceOutputsSelfRooted() async throws {
        let tempDir = try FASTQOperationTestHelper.makeTempDir(prefix: "FASTQExecImportFullRoot")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sourceBundle = tempDir.appendingPathComponent("oriented.\(FASTQBundle.directoryExtension)", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceBundle, withIntermediateDirectories: true)
        let orientedFASTQ = sourceBundle.appendingPathComponent("orient.fastq")
        try FASTQOperationTestHelper.writeSyntheticFASTQ(
            to: orientedFASTQ,
            readCount: 2,
            readLength: 20
        )

        let orientOperation = FASTQDerivativeOperation(kind: .orient)
        let sourceManifest = FASTQDerivedBundleManifest(
            name: "oriented",
            parentBundleRelativePath: "@/source.\(FASTQBundle.directoryExtension)",
            rootBundleRelativePath: "@/source.\(FASTQBundle.directoryExtension)",
            rootFASTQFilename: "missing-root.fastq",
            payload: .full(fastqFilename: orientedFASTQ.lastPathComponent),
            lineage: [orientOperation],
            operation: orientOperation,
            cachedStatistics: .placeholder(readCount: 2, baseCount: 40),
            pairingMode: .singleEnd,
            sequenceFormat: .fastq
        )
        try FASTQBundle.saveDerivedManifest(sourceManifest, in: sourceBundle)

        let stagedFASTQ = tempDir.appendingPathComponent("oriented.filtered.fastq")
        try FASTQOperationTestHelper.writeSyntheticFASTQ(
            to: stagedFASTQ,
            readCount: 1,
            readLength: 18
        )
        try writeSyntheticProvenance(
            to: tempDir,
            name: "Sequential FASTQ trim",
            toolName: "fastp",
            toolVersion: "1.3.2",
            command: ["fastp", "-i", orientedFASTQ.path, "-o", stagedFASTQ.path],
            inputURL: orientedFASTQ,
            outputURL: stagedFASTQ,
            parameters: ["operation": .string("adapter trim")]
        )

        let destinationBundle = tempDir.appendingPathComponent(
            "oriented-filtered.\(FASTQBundle.directoryExtension)",
            isDirectory: true
        )
        let writer = AppFASTQOutputBundleWriter(ingestor: SpyFASTQOutputIngestor())
        let request = FASTQOperationLaunchRequest.derivative(
            request: .adapterTrim(mode: .autoDetect, sequence: nil, sequenceR2: nil, fastaFilename: nil),
            inputURLs: [sourceBundle],
            outputMode: .perInput
        )

        let bundleURL = try await writer.importFASTQOutput(
            sourceURL: stagedFASTQ,
            bundleURL: destinationBundle,
            originalRequest: request,
            sourceInputURL: sourceBundle
        )

        let manifest = try XCTUnwrap(FASTQBundle.loadDerivedManifest(in: bundleURL))
        let bundledFASTQ = try XCTUnwrap(FASTQBundle.resolvePrimaryFASTQURL(for: bundleURL))
        XCTAssertEqual(manifest.rootBundleRelativePath, ".")
        XCTAssertEqual(manifest.rootFASTQFilename, bundledFASTQ.lastPathComponent)
        XCTAssertEqual(manifest.parentBundleRelativePath, "../oriented.\(FASTQBundle.directoryExtension)")
    }

    func testAppFASTQOutputBundleWriterPreservesMultiOutputCLIProvenanceOneBundleAtATime() async throws {
        let tempDir = try FASTQOperationTestHelper.makeTempDir(prefix: "FASTQExecImportMultiOutputProvenance")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sourceBundle = try FASTQOperationTestHelper.makeBundle(named: "source", in: tempDir)
        try FASTQOperationTestHelper.writeSyntheticFASTQ(
            to: sourceBundle.fastqURL,
            readCount: 6,
            readLength: 18
        )

        let stagingDir = tempDir.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        let stagedNonRRNA = stagingDir.appendingPathComponent("source.norrna.fastq")
        let stagedRRNA = stagingDir.appendingPathComponent("source.rrna.fastq")
        try FASTQOperationTestHelper.writeSyntheticFASTQ(to: stagedNonRRNA, readCount: 3, readLength: 12)
        try FASTQOperationTestHelper.writeSyntheticFASTQ(to: stagedRRNA, readCount: 2, readLength: 12)
        try writeSyntheticMultiOutputProvenance(
            to: stagingDir,
            name: "Deacon split rRNA FASTQ filter",
            toolName: "deacon",
            toolVersion: "0.15.0",
            command: [
                "deacon", "filter", "--retain-both",
                sourceBundle.fastqURL.path,
                "--norrna", stagedNonRRNA.path,
                "--rrna", stagedRRNA.path,
            ],
            inputURL: sourceBundle.fastqURL,
            outputURLs: [stagedNonRRNA, stagedRRNA],
            parameters: ["retain": .string("both")]
        )

        let writer = AppFASTQOutputBundleWriter(ingestor: SpyFASTQOutputIngestor())
        let request = FASTQOperationLaunchRequest.derivative(
            request: .ribosomalRNAFilter(retention: .nonRRNA, ensure: .rrna),
            inputURLs: [sourceBundle.bundleURL],
            outputMode: .perInput
        )
        let nonRRNABundle = tempDir.appendingPathComponent(
            "source-deacon-ribo-norrna.\(FASTQBundle.directoryExtension)",
            isDirectory: true
        )
        let rrnaBundle = tempDir.appendingPathComponent(
            "source-deacon-ribo-rrna.\(FASTQBundle.directoryExtension)",
            isDirectory: true
        )

        let importedNonRRNA = try await writer.importFASTQOutput(
            sourceURL: stagedNonRRNA,
            bundleURL: nonRRNABundle,
            originalRequest: request,
            sourceInputURL: sourceBundle.bundleURL
        )
        let importedRRNA = try await writer.importFASTQOutput(
            sourceURL: stagedRRNA,
            bundleURL: rrnaBundle,
            originalRequest: request,
            sourceInputURL: sourceBundle.bundleURL
        )

        try assertProjectedProvenance(
            in: importedNonRRNA,
            sourceOutput: stagedNonRRNA,
            sourceInput: sourceBundle.fastqURL,
            sourceProvenanceDirectory: stagingDir,
            workflowName: "Deacon split rRNA FASTQ filter"
        )
        try assertProjectedProvenance(
            in: importedRRNA,
            sourceOutput: stagedRRNA,
            sourceInput: sourceBundle.fastqURL,
            sourceProvenanceDirectory: stagingDir,
            workflowName: "Deacon split rRNA FASTQ filter"
        )
    }

    func testAppFASTQOutputBundleWriterRejectsDerivativeBundlesWithoutSourceProvenance() async throws {
        let tempDir = try FASTQOperationTestHelper.makeTempDir(prefix: "FASTQExecImportMissingProvenance")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sourceBundle = try FASTQOperationTestHelper.makeBundle(named: "source", in: tempDir)
        try FASTQOperationTestHelper.writeSyntheticFASTQ(
            to: sourceBundle.fastqURL,
            readCount: 3,
            readLength: 20
        )
        let stagedFASTQ = tempDir.appendingPathComponent("source.length.fastq")
        try FASTQOperationTestHelper.writeSyntheticFASTQ(
            to: stagedFASTQ,
            readCount: 2,
            readLength: 14
        )

        let destinationBundle = tempDir.appendingPathComponent(
            "source-length-filtered.\(FASTQBundle.directoryExtension)",
            isDirectory: true
        )
        let writer = AppFASTQOutputBundleWriter(ingestor: SpyFASTQOutputIngestor())
        let request = FASTQOperationLaunchRequest.derivative(
            request: .lengthFilter(min: 10, max: 50),
            inputURLs: [sourceBundle.bundleURL],
            outputMode: .perInput
        )

        do {
            _ = try await writer.importFASTQOutput(
                sourceURL: stagedFASTQ,
                bundleURL: destinationBundle,
                originalRequest: request,
                sourceInputURL: sourceBundle.bundleURL
            )
            XCTFail("Derivative FASTQ import should fail when the staged CLI output has no provenance sidecar.")
        } catch ProvenanceRehydrationError.missingSourceProvenance {
            // Expected: GUI imports must preserve CLI provenance instead of synthesizing it.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: destinationBundle.path),
            "A final FASTQ bundle must not remain when provenance rehydration fails."
        )
    }

    func testBundleImporterWrapsRawFASTAOutputsIntoReferenceBundles() async throws {
        let tempDir = try FASTQOperationTestHelper.makeTempDir(prefix: "FASTQExecImportFASTA")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sourceBundle = try makeReferenceBundle(
            named: "source",
            in: tempDir,
            records: [
                (id: "seq1", sequence: "AACCGGTTAACC"),
            ]
        )
        let stagingDir = tempDir.appendingPathComponent("staging", isDirectory: true)
        let destinationDir = tempDir.appendingPathComponent("results", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)

        let stagedFASTA = stagingDir.appendingPathComponent("filtered.rrna.fasta")
        try ">seq1\nAACCGGTTAACC\n".write(to: stagedFASTA, atomically: true, encoding: .utf8)

        let referenceWrapper = SpyReferenceBundleWrapper()
        let importedReferenceBundle = destinationDir.appendingPathComponent("source-deacon-ribo-rrna.lungfishref", isDirectory: true)
        referenceWrapper.resultURLs = [importedReferenceBundle]
        let importer = BundleFASTQOperationImporter(
            destinationDirectory: destinationDir,
            referenceBundleWrapper: referenceWrapper
        )
        let request = FASTQOperationLaunchRequest.derivative(
            request: .ribosomalRNAFilter(retention: .rRNA, ensure: .rrna),
            inputURLs: [sourceBundle],
            outputMode: .perInput
        )

        let imported = try await importer.importOutputs(
            at: [stagedFASTA],
            forResolvedRequest: request,
            originalRequest: request,
            outputDirectory: stagingDir
        )

        XCTAssertEqual(imported, [importedReferenceBundle])
        XCTAssertEqual(referenceWrapper.calls.map(\.sourceURL), [stagedFASTA])
        XCTAssertEqual(referenceWrapper.calls.map(\.outputDirectory), [destinationDir])
        XCTAssertEqual(referenceWrapper.calls.map(\.preferredBundleName), ["source-deacon-ribo-rrna"])
    }

    func testBundleImporterRehydratesFileSpecificFASTAProvenanceIntoReferenceBundle() async throws {
        let tempDir = try FASTQOperationTestHelper.makeTempDir(prefix: "FASTQExecImportFASTAProvenance")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sourceBundle = try makeReferenceBundle(
            named: "source",
            in: tempDir,
            records: [
                (id: "seq1", sequence: "AACCGGTTAACC"),
            ]
        )
        let sourcePayloadURL = try XCTUnwrap(SequenceInputResolver.resolvePrimarySequenceURL(for: sourceBundle))
        let stagingDir = tempDir.appendingPathComponent("staging", isDirectory: true)
        let destinationDir = tempDir.appendingPathComponent("results", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)

        let stagedFASTA = stagingDir.appendingPathComponent("filtered.rrna.fasta")
        try ">seq1\nAACCGGTTAACC\n".write(to: stagedFASTA, atomically: true, encoding: .utf8)
        let stagedSidecarURL = ProvenanceRecorder.fileSidecarURL(for: stagedFASTA)
        let sourceDurableReplayArgv = ["deacon", "filter", sourcePayloadURL.path, "-o", stagedFASTA.path]
        try writeSyntheticProvenance(
            to: stagingDir,
            name: "Deacon rRNA FASTA filter",
            toolName: "deacon",
            toolVersion: "0.15.0",
            command: sourceDurableReplayArgv,
            durableReplayArgv: sourceDurableReplayArgv,
            inputURL: sourcePayloadURL,
            outputURL: stagedFASTA,
            parameters: ["retain": .string("rrna")],
            format: .fasta,
            sidecarURL: stagedSidecarURL
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: stagingDir.appendingPathComponent(ProvenanceRecorder.provenanceFilename).path)
        )

        let referenceWrapper = SpyReferenceBundleWrapper()
        let importedReferenceBundle = try makeReferenceBundle(
            named: "source-deacon-ribo-rrna",
            in: destinationDir,
            records: [
                (id: "seq1", sequence: "AACCGGTTAACC"),
            ]
        )
        let finalPayloadBeforeImport = try XCTUnwrap(
            SequenceInputResolver.resolvePrimarySequenceURL(for: importedReferenceBundle)
        )
        try writeSyntheticProvenance(
            to: importedReferenceBundle,
            name: "Native reference bundle wrapping",
            toolName: "native-bundle-builder",
            toolVersion: WorkflowRun.currentAppVersion,
            command: ["lungfish", "import", "reference", stagedFASTA.path],
            inputURL: stagedFASTA,
            outputURL: finalPayloadBeforeImport,
            format: .fasta
        )
        referenceWrapper.resultURLs = [importedReferenceBundle]
        let importer = BundleFASTQOperationImporter(
            destinationDirectory: destinationDir,
            referenceBundleWrapper: referenceWrapper
        )
        let request = FASTQOperationLaunchRequest.derivative(
            request: .ribosomalRNAFilter(retention: .rRNA, ensure: .rrna),
            inputURLs: [sourceBundle],
            outputMode: .perInput
        )

        let imported = try await importer.importOutputs(
            at: [stagedFASTA],
            forResolvedRequest: request,
            originalRequest: request,
            outputDirectory: stagingDir
        )

        let bundleURL = try XCTUnwrap(imported.first)
        let finalPayloadURL = try XCTUnwrap(SequenceInputResolver.resolvePrimarySequenceURL(for: bundleURL))
        let envelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: bundleURL))
        let descriptor = try XCTUnwrap(envelope.output)
        XCTAssertEqual(envelope.workflowName, "Deacon rRNA FASTA filter")
        XCTAssertEqual(envelope.toolName, "deacon")
        XCTAssertEqual(envelope.toolVersion, "0.15.0")
        XCTAssertEqual(envelope.durableReplayArgv, [
            "deacon", "filter", sourcePayloadURL.path, "-o", finalPayloadURL.path
        ])
        XCTAssertFalse(envelope.durableReplayArgv?.contains(stagedFASTA.path) ?? true)
        XCTAssertEqual(descriptor.path, finalPayloadURL.path)
        XCTAssertEqual(descriptor.originPath, stagedFASTA.path)
        XCTAssertEqual(descriptor.sourceProvenancePath, stagedSidecarURL.path)
        XCTAssertEqual(descriptor.checksumSHA256, try ProvenanceFileHasher.sha256(of: finalPayloadURL))
        XCTAssertEqual(envelope.steps.first?.outputs.map(\.path), [finalPayloadURL.path])
        XCTAssertEqual(envelope.steps.map(\.toolName), ["deacon", "native-bundle-builder"])
    }

    func testBundleImporterRefreshesDerivedManifestStatisticsFromQCSummary() async throws {
        let tempDir = try FASTQOperationTestHelper.makeTempDir(prefix: "FASTQExecImport")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let root = try FASTQOperationTestHelper.makeBundle(named: "root", in: tempDir)
        try FASTQOperationTestHelper.writeSyntheticFASTQ(to: root.fastqURL, readCount: 10, readLength: 30)

        let derivedBundle = tempDir.appendingPathComponent(
            "subset.\(FASTQBundle.directoryExtension)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: derivedBundle, withIntermediateDirectories: true)
        let initialManifest = FASTQDerivedBundleManifest(
            name: "subset",
            parentBundleRelativePath: "../\(root.bundleURL.lastPathComponent)",
            rootBundleRelativePath: "../\(root.bundleURL.lastPathComponent)",
            rootFASTQFilename: root.fastqURL.lastPathComponent,
            payload: .subset(readIDListFilename: "read-ids.txt"),
            lineage: [],
            operation: FASTQDerivativeOperation(kind: .subsampleCount, count: 2),
            cachedStatistics: .placeholder(readCount: 1, baseCount: 30),
            pairingMode: nil
        )
        try FASTQBundle.saveDerivedManifest(initialManifest, in: derivedBundle)

        let reportURL = tempDir.appendingPathComponent("qc-summary.json")
        let report = TestFastqQCSummaryReport(
            inputs: [
                .init(
                    input: derivedBundle.path,
                    statistics: FASTQDatasetStatistics(
                        readCount: 4,
                        baseCount: 120,
                        meanReadLength: 30,
                        minReadLength: 20,
                        maxReadLength: 40,
                        medianReadLength: 30,
                        n50ReadLength: 30,
                        meanQuality: 35,
                        q20Percentage: 100,
                        q30Percentage: 95,
                        gcContent: 0.5,
                        readLengthHistogram: [30: 4],
                        qualityScoreHistogram: [:],
                        perPositionQuality: []
                    )
                )
            ]
        )
        let reportData = try JSONEncoder().encode(report)
        try reportData.write(to: reportURL, options: .atomic)

        let importer = BundleFASTQOperationImporter(destinationDirectory: tempDir)
        let request = FASTQOperationLaunchRequest.refreshQCSummary(inputURLs: [derivedBundle])

        let imported = try await importer.importOutputs(
            at: [reportURL],
            forResolvedRequest: request,
            originalRequest: request,
            outputDirectory: tempDir
        )

        XCTAssertEqual(imported, [derivedBundle])
        let updatedManifest = try XCTUnwrap(FASTQBundle.loadDerivedManifest(in: derivedBundle))
        XCTAssertEqual(updatedManifest.cachedStatistics.readCount, 4)
        XCTAssertEqual(updatedManifest.cachedStatistics.baseCount, 120)
    }

    func testMapLaunchBuildsTopLevelMapInvocation() throws {
        let request = FASTQOperationLaunchRequest.map(
            inputURLs: [
                URL(fileURLWithPath: "/tmp/R1.fastq"),
                URL(fileURLWithPath: "/tmp/R2.fastq"),
            ],
            referenceURL: URL(fileURLWithPath: "/tmp/ref.fasta"),
            outputMode: .groupedResult
        )

        let invocation = try FASTQOperationExecutionService().buildInvocation(for: request)

        XCTAssertEqual(invocation.subcommand, "map")
        XCTAssertEqual(invocation.arguments, [
            "/tmp/R1.fastq",
            "/tmp/R2.fastq",
            "--reference",
            "/tmp/ref.fasta",
            "--paired",
            ])
    }

    func testONTFluidigmSampleSplitBuildsCLIInvocation() throws {
        let request = FASTQOperationLaunchRequest.ontFluidigmSampleSplit(
            inputFASTQURL: URL(fileURLWithPath: "/tmp/barcode11.lungfishfastq", isDirectory: true),
            barcodeDefinitionsURL: URL(fileURLWithPath: "/tmp/ONT09_NB11_samples.csv"),
            threads: 8
        )

        let invocation = try FASTQOperationExecutionService().buildInvocation(for: request)

        XCTAssertEqual(invocation.subcommand, "fastq")
        XCTAssertEqual(invocation.arguments, [
            "ont-fluidigm-samples",
            "/tmp/barcode11.lungfishfastq",
            "--barcodes", "/tmp/ONT09_NB11_samples.csv",
            "--output", "<derived>",
            "--threads", "8",
        ])
    }

    func testONTPacBioBarcodeDemuxBuildsCLIInvocation() throws {
        let request = FASTQOperationLaunchRequest.ontPacBioBarcodeDemux(
            inputFASTQURL: URL(fileURLWithPath: "/tmp/fastq_pass/barcode13", isDirectory: true),
            barcodeDefinitionsURL: URL(fileURLWithPath: "/tmp/NB13_MHC-I_plate1.barcodes.csv"),
            threads: 4,
            chunkJobs: 6,
            maxReadsPerSlice: 100_000,
            maxBytesPerCutadapt: 536_870_912
        )

        let invocation = try FASTQOperationExecutionService().buildInvocation(for: request)

        XCTAssertEqual(invocation.subcommand, "fastq")
        XCTAssertEqual(invocation.arguments, [
            "ont-pacbio-barcode-demux",
            "/tmp/fastq_pass/barcode13",
            "--barcodes", "/tmp/NB13_MHC-I_plate1.barcodes.csv",
            "--output", "<derived>",
            "--threads", "4",
            "--chunk-jobs", "6",
            "--max-reads-per-slice", "100000",
            "--max-bytes-per-cutadapt", "536870912",
        ])
    }

    func testAssemblyLaunchBuildsAssemblerAwareInvocation() throws {
        let request = FASTQOperationLaunchRequest.assemble(
            request: AssemblyRunRequest(
                tool: .spades,
                readType: .illuminaShortReads,
                inputURLs: [URL(fileURLWithPath: "/tmp/sample.fastq.gz")],
                projectName: "Demo",
                outputDirectory: URL(fileURLWithPath: "/tmp/assembly-out"),
                threads: 8,
                memoryGB: nil,
                minContigLength: nil,
                selectedProfileID: nil,
                extraArguments: []
            ),
            outputMode: .groupedResult
        )

        let invocation = try FASTQOperationExecutionService().buildInvocation(for: request)

        XCTAssertEqual(
            invocation,
            CLIInvocation(
                subcommand: "assemble",
                arguments: [
                    "/tmp/sample.fastq.gz",
                    "--assembler", "spades",
                    "--read-type", "illumina-short-reads",
                    "--project-name", "Demo",
                    "--threads", "8",
                    "--output", "<derived>",
                ]
            )
        )
    }

    func testAssemblyLaunchPreservesExplicitPairedTopology() throws {
        let request = FASTQOperationLaunchRequest.assemble(
            request: AssemblyRunRequest(
                tool: .spades,
                readType: .illuminaShortReads,
                inputURLs: [
                    URL(fileURLWithPath: "/tmp/sample_R1.fastq.gz"),
                    URL(fileURLWithPath: "/tmp/sample_R2.fastq.gz"),
                ],
                projectName: "Demo",
                outputDirectory: URL(fileURLWithPath: "/tmp/assembly-out"),
                pairedEnd: true,
                threads: 8,
                memoryGB: nil,
                minContigLength: nil,
                selectedProfileID: nil,
                extraArguments: []
            ),
            outputMode: .groupedResult
        )

        let invocation = try FASTQOperationExecutionService().buildInvocation(for: request)

        XCTAssertEqual(
            invocation.arguments,
            [
                "/tmp/sample_R1.fastq.gz",
                "/tmp/sample_R2.fastq.gz",
                "--paired",
                "--assembler", "spades",
                "--read-type", "illumina-short-reads",
                "--project-name", "Demo",
                "--threads", "8",
                "--output", "<derived>",
            ]
        )
    }

    func testAssemblyLaunchDoesNotInferPairedFromTwoInputFilesAlone() throws {
        let request = FASTQOperationLaunchRequest.assemble(
            request: AssemblyRunRequest(
                tool: .spades,
                readType: .illuminaShortReads,
                inputURLs: [
                    URL(fileURLWithPath: "/tmp/chunk-a.fastq.gz"),
                    URL(fileURLWithPath: "/tmp/chunk-b.fastq.gz"),
                ],
                projectName: "Demo",
                outputDirectory: URL(fileURLWithPath: "/tmp/assembly-out"),
                pairedEnd: false,
                threads: 8,
                memoryGB: nil,
                minContigLength: nil,
                selectedProfileID: nil,
                extraArguments: []
            ),
            outputMode: .groupedResult
        )

        let invocation = try FASTQOperationExecutionService().buildInvocation(for: request)

        XCTAssertFalse(invocation.arguments.contains("--paired"))
    }

    func testAssemblyLaunchBuildsGenericManagedInvocationForMegahit() throws {
        let request = FASTQOperationLaunchRequest.assemble(
            request: AssemblyRunRequest(
                tool: .megahit,
                readType: .illuminaShortReads,
                inputURLs: [URL(fileURLWithPath: "/tmp/sample.fastq.gz")],
                projectName: "Demo",
                outputDirectory: URL(fileURLWithPath: "/tmp/assembly-out"),
                threads: 8,
                memoryGB: 24,
                minContigLength: 1000,
                selectedProfileID: "meta-sensitive",
                extraArguments: ["--k-min", "21"]
            ),
            outputMode: .groupedResult
        )

        let invocation = try FASTQOperationExecutionService().buildInvocation(for: request)

        #if os(macOS) && arch(arm64)
        let expectedThreads = "2"
        #else
        let expectedThreads = "8"
        #endif

        XCTAssertEqual(
            invocation.arguments,
            [
                "/tmp/sample.fastq.gz",
                "--assembler", "megahit",
                "--read-type", "illumina-short-reads",
                "--project-name", "Demo",
                "--threads", expectedThreads,
                "--output", "<derived>",
                "--memory-gb", "24",
                "--min-contig-length", "1000",
                "--profile", "meta-sensitive",
                "--extra-args", "--k-min 21",
            ]
        )
    }

    func testAssemblyLaunchBuildsHifiasmProfileInvocationWithoutCuratedFlagDuplication() throws {
        let request = FASTQOperationLaunchRequest.assemble(
            request: AssemblyRunRequest(
                tool: .hifiasm,
                readType: .pacBioHiFi,
                inputURLs: [URL(fileURLWithPath: "/tmp/sample.fastq.gz")],
                projectName: "Demo",
                outputDirectory: URL(fileURLWithPath: "/tmp/assembly-out"),
                threads: 8,
                memoryGB: nil,
                minContigLength: nil,
                selectedProfileID: "haploid-viral",
                extraArguments: ["--primary"]
            ),
            outputMode: .groupedResult
        )

        let invocation = try FASTQOperationExecutionService().buildInvocation(for: request)

        XCTAssertEqual(
            invocation.arguments,
            [
                "/tmp/sample.fastq.gz",
                "--assembler", "hifiasm",
                "--read-type", "pacbio-hifi",
                "--project-name", "Demo",
                "--threads", "8",
                "--output", "<derived>",
                "--profile", "haploid-viral",
                "--extra-args", "--primary",
            ]
        )
        XCTAssertFalse(invocation.arguments.contains("--n-hap"))
        XCTAssertFalse(invocation.arguments.contains("-l0"))
        XCTAssertFalse(invocation.arguments.contains("-f0"))
    }

    func testAssemblyLaunchNormalizesZeroMinContigLengthToOne() throws {
        let request = FASTQOperationLaunchRequest.assemble(
            request: AssemblyRunRequest(
                tool: .skesa,
                readType: .illuminaShortReads,
                inputURLs: [
                    URL(fileURLWithPath: "/tmp/sample_R1.fastq.gz"),
                    URL(fileURLWithPath: "/tmp/sample_R2.fastq.gz"),
                ],
                projectName: "Demo",
                outputDirectory: URL(fileURLWithPath: "/tmp/assembly-out"),
                pairedEnd: true,
                threads: 8,
                memoryGB: nil,
                minContigLength: 0,
                selectedProfileID: nil,
                extraArguments: []
            ),
            outputMode: .groupedResult
        )

        let invocation = try FASTQOperationExecutionService().buildInvocation(for: request)

        let minContigIndex = try XCTUnwrap(invocation.arguments.firstIndex(of: "--min-contig-length"))
        XCTAssertEqual(invocation.arguments[minContigIndex + 1], "1")
    }

    func testExecuteAssemblyPreservesOriginalDerivedBundleInputInCLIInvocation() async throws {
        let tempDir = try FASTQOperationTestHelper.makeTempDir(prefix: "FASTQExecAssemblyOriginalInput")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sourceBundleURL = try makeVirtualDerivedFASTQBundle(named: "derived-input", in: tempDir)
        let materializedURL = tempDir.appendingPathComponent("materialized.fastq")
        try FASTQOperationTestHelper.writeSyntheticFASTQ(to: materializedURL, readCount: 2, readLength: 20)

        let originalRequest = FASTQOperationLaunchRequest.assemble(
            request: AssemblyRunRequest(
                tool: .spades,
                readType: .illuminaShortReads,
                inputURLs: [sourceBundleURL],
                projectName: "Demo",
                outputDirectory: tempDir.appendingPathComponent("assembly-output", isDirectory: true),
                threads: 2
            ),
            outputMode: .perInput
        )
        let preMaterializedRequest = FASTQOperationLaunchRequest.assemble(
            request: AssemblyRunRequest(
                tool: .spades,
                readType: .illuminaShortReads,
                inputURLs: [materializedURL],
                projectName: "Demo",
                outputDirectory: tempDir.appendingPathComponent("assembly-output", isDirectory: true),
                threads: 2
            ),
            outputMode: .perInput
        )

        let resolver = SpyInputResolver(resolvedRequest: preMaterializedRequest)
        let runner = SpyCommandRunner { _, outputDirectory in
            FASTQCLIExecutionResult(outputURLs: [outputDirectory])
        }
        let service = FASTQOperationExecutionService(
            inputResolver: resolver,
            commandRunner: runner,
            directImporter: SpyDirectImporter()
        )

        _ = try await service.execute(
            request: originalRequest,
            workingDirectory: tempDir
        )

        XCTAssertTrue(resolver.requests.isEmpty, "Assembly execution should let the assemble CLI own input materialization")
        XCTAssertEqual(runner.invocations.count, 1)
        XCTAssertTrue(runner.invocations[0].arguments.contains(sourceBundleURL.path))
        XCTAssertFalse(runner.invocations[0].arguments.contains(materializedURL.path))
    }

    func testExecuteONTFluidigmSampleSplitUsesWorkingDirectoryAsCLIOutputWithoutResolvingChunks() async throws {
        let tempDir = try FASTQOperationTestHelper.makeTempDir(prefix: "FASTQExecONTFluidigmNoResolve")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let workingDirectory = tempDir.appendingPathComponent("32271-NB05", isDirectory: true)
        let inputBundle = try makeVirtualDerivedFASTQBundle(named: "bulk-barcode11", in: tempDir)
        let materializedURL = tempDir.appendingPathComponent("materialized.fastq")
        try FASTQOperationTestHelper.writeSyntheticFASTQ(to: materializedURL, readCount: 2, readLength: 20)
        let barcodeURL = tempDir.appendingPathComponent("ONT09_NB11_samples.csv")
        try "sample,barcode\nLF1001,ACGT\n".write(to: barcodeURL, atomically: true, encoding: .utf8)

        let originalRequest = FASTQOperationLaunchRequest.ontFluidigmSampleSplit(
            inputFASTQURL: inputBundle,
            barcodeDefinitionsURL: barcodeURL,
            threads: 6
        )
        let resolvedRequest = FASTQOperationLaunchRequest.ontFluidigmSampleSplit(
            inputFASTQURL: materializedURL,
            barcodeDefinitionsURL: barcodeURL,
            threads: 6
        )

        let resolver = SpyInputResolver(resolvedRequest: resolvedRequest)
        let runner = SpyCommandRunner { invocation, outputDirectory in
            XCTAssertTrue(invocation.arguments.contains(inputBundle.path))
            XCTAssertFalse(invocation.arguments.contains(materializedURL.path))
            let outputFlagIndex = try XCTUnwrap(invocation.arguments.firstIndex(of: "--output"))
            let outputTarget = URL(fileURLWithPath: invocation.arguments[outputFlagIndex + 1], isDirectory: true)
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: outputTarget.path),
                "ONT Fluidigm materializer rejects pre-existing output directories."
            )
            XCTAssertEqual(outputTarget.standardizedFileURL, workingDirectory.standardizedFileURL)
            XCTAssertEqual(
                outputDirectory.standardizedFileURL,
                workingDirectory.deletingLastPathComponent().standardizedFileURL
            )
            try FileManager.default.createDirectory(at: outputTarget, withIntermediateDirectories: true)
            let sampleBundle = try FASTQOperationTestHelper.makeBundle(named: "LF1001", in: outputTarget)
            try FASTQOperationTestHelper.writeSyntheticFASTQ(to: sampleBundle.fastqURL, readCount: 1, readLength: 20)
            return FASTQCLIExecutionResult(outputURLs: [sampleBundle.bundleURL])
        }
        let importer = SpyDirectImporter()
        let service = FASTQOperationExecutionService(
            inputResolver: resolver,
            commandRunner: runner,
            directImporter: importer
        )

        let result = try await service.execute(
            request: originalRequest,
            workingDirectory: workingDirectory
        )

        XCTAssertTrue(resolver.requests.isEmpty)
        XCTAssertEqual(result.executedInvocations.count, 1)
        XCTAssertEqual(importer.calls.count, 1)
        XCTAssertEqual(result.resolvedRequest, originalRequest)
    }

    func testExecuteAssemblyRejectsInvalidFlyeAndHifiasmMultiInputBeforeResolvingInputs() async throws {
        let tempDir = try FASTQOperationTestHelper.makeTempDir(prefix: "FASTQExecAssemblyTopology")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        for (tool, readType, expectedMessage) in [
            (AssemblyTool.flye, AssemblyReadType.ontReads, "Flye expects a single"),
            (.hifiasm, .pacBioHiFi, "Hifiasm expects a single"),
        ] {
            let request = FASTQOperationLaunchRequest.assemble(
                request: AssemblyRunRequest(
                    tool: tool,
                    readType: readType,
                    inputURLs: [
                        tempDir.appendingPathComponent("reads-a.\(FASTQBundle.directoryExtension)", isDirectory: true),
                        tempDir.appendingPathComponent("reads-b.\(FASTQBundle.directoryExtension)", isDirectory: true),
                    ],
                    projectName: "Demo",
                    outputDirectory: tempDir.appendingPathComponent("assembly-output", isDirectory: true),
                    threads: 2
                ),
                outputMode: .perInput
            )
            let resolver = SpyInputResolver(resolvedRequest: request)
            let runner = SpyCommandRunner()
            let service = FASTQOperationExecutionService(
                inputResolver: resolver,
                commandRunner: runner,
                directImporter: SpyDirectImporter()
            )

            do {
                _ = try await service.execute(request: request, workingDirectory: tempDir)
                XCTFail("Expected invalid \(tool.rawValue) multi-input launch to fail before resolving inputs")
            } catch let error as FASTQOperationExecutionError {
                guard case .unsupportedAssembly(let reason) = error else {
                    return XCTFail("Expected unsupported assembly error, got \(error)")
                }
                XCTAssertTrue(reason.contains(expectedMessage))
            }

            XCTAssertTrue(resolver.requests.isEmpty)
            XCTAssertTrue(runner.invocations.isEmpty)
        }
    }

    func testExecuteKeepsPairedAssemblyAsSinglePerInputPlan() async throws {
        let tempDir = try FASTQOperationTestHelper.makeTempDir(prefix: "FASTQExecService")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let assemblyRequest = FASTQOperationLaunchRequest.assemble(
            request: AssemblyRunRequest(
                tool: .spades,
                readType: .illuminaShortReads,
                inputURLs: [
                    URL(fileURLWithPath: "/tmp/sample_R1.fastq.gz"),
                    URL(fileURLWithPath: "/tmp/sample_R2.fastq.gz"),
                ],
                projectName: "Demo",
                outputDirectory: URL(fileURLWithPath: "/tmp/assembly-out"),
                pairedEnd: true,
                threads: 8,
                memoryGB: nil,
                minContigLength: nil,
                selectedProfileID: nil,
                extraArguments: []
            ),
            outputMode: .perInput
        )

        let resolver = SpyInputResolver(resolvedRequest: assemblyRequest)
        let runner = SpyCommandRunner { invocation, outputDirectory in
            let reportedOutput = outputDirectory.appendingPathComponent("assembly-result")
            try FileManager.default.createDirectory(at: reportedOutput, withIntermediateDirectories: true)
            return FASTQCLIExecutionResult(outputURLs: [reportedOutput])
        }
        let importer = SpyDirectImporter()
        importer.resultURLs = [tempDir.appendingPathComponent("imported-result")]
        let service = FASTQOperationExecutionService(
            inputResolver: resolver,
            commandRunner: runner,
            directImporter: importer
        )

        _ = try await service.execute(
            request: assemblyRequest,
            workingDirectory: tempDir
        )

        XCTAssertEqual(runner.invocations.count, 1)
        XCTAssertEqual(
            runner.invocations[0].arguments.prefix(3),
            [
                "/tmp/sample_R1.fastq.gz",
                "/tmp/sample_R2.fastq.gz",
                "--paired",
            ]
        )
    }

    func testExecuteDiscoversAssemblyResultDirectoryWhenAssemblerWritesSidecar() async throws {
        let tempDir = try FASTQOperationTestHelper.makeTempDir(prefix: "FASTQExecService")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let outputDirectory = tempDir.appendingPathComponent("analysis-output", isDirectory: true)
        let request = FASTQOperationLaunchRequest.assemble(
            request: AssemblyRunRequest(
                tool: .megahit,
                readType: .illuminaShortReads,
                inputURLs: [
                    URL(fileURLWithPath: "/tmp/sample_R1.fastq.gz"),
                    URL(fileURLWithPath: "/tmp/sample_R2.fastq.gz"),
                ],
                projectName: "Demo",
                outputDirectory: outputDirectory,
                pairedEnd: true,
                threads: 2,
                memoryGB: nil,
                minContigLength: nil,
                selectedProfileID: nil,
                extraArguments: []
            ),
            outputMode: .perInput
        )

        let resolver = SpyInputResolver(resolvedRequest: request)
        let runner = SpyCommandRunner { _, workingDirectory in
            try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
            let contigsURL = workingDirectory.appendingPathComponent("contigs.fasta")
            try ">contig1\nAACCGGTT\n".write(to: contigsURL, atomically: true, encoding: .utf8)
            let result = AssemblyResult(
                tool: .megahit,
                readType: .illuminaShortReads,
                contigsPath: contigsURL,
                graphPath: nil,
                logPath: nil,
                assemblerVersion: "test",
                commandLine: "megahit",
                outputDirectory: workingDirectory,
                statistics: try AssemblyStatisticsCalculator.compute(from: contigsURL),
                wallTimeSeconds: 1
            )
            try result.save(to: workingDirectory)
            return FASTQCLIExecutionResult(outputURLs: [])
        }
        let importer = SpyDirectImporter()
        let service = FASTQOperationExecutionService(
            inputResolver: resolver,
            commandRunner: runner,
            directImporter: importer
        )

        let result = try await service.execute(
            request: request,
            workingDirectory: outputDirectory
        )

        XCTAssertEqual(result.importedURLs, [outputDirectory])
        XCTAssertEqual(importer.calls, [[outputDirectory]])
    }

    func testExecuteDiscoversAssemblyResultFromInvocationOutputDirectory() async throws {
        let tempDir = try FASTQOperationTestHelper.makeTempDir(prefix: "FASTQExecService")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let outputDirectory = tempDir.appendingPathComponent("analysis-output", isDirectory: true)
        let request = FASTQOperationLaunchRequest.assemble(
            request: AssemblyRunRequest(
                tool: .megahit,
                readType: .illuminaShortReads,
                inputURLs: [
                    URL(fileURLWithPath: "/tmp/sample_R1.fastq.gz"),
                    URL(fileURLWithPath: "/tmp/sample_R2.fastq.gz"),
                ],
                projectName: "Demo",
                outputDirectory: outputDirectory,
                pairedEnd: true,
                threads: 2,
                memoryGB: nil,
                minContigLength: nil,
                selectedProfileID: nil,
                extraArguments: []
            ),
            outputMode: .perInput
        )

        let resolver = SpyInputResolver(resolvedRequest: request)
        let runner = SpyCommandRunner { invocation, workingDirectory in
            let outputFlagIndex = try XCTUnwrap(invocation.arguments.firstIndex(of: "--output"))
            let resultDirectory = URL(
                fileURLWithPath: invocation.arguments[outputFlagIndex + 1],
                isDirectory: true
            )

            XCTAssertEqual(workingDirectory.standardizedFileURL, outputDirectory.standardizedFileURL)

            try FileManager.default.createDirectory(at: resultDirectory, withIntermediateDirectories: true)
            let contigsURL = resultDirectory.appendingPathComponent("contigs.fasta")
            try ">contig1\nAACCGGTT\n".write(to: contigsURL, atomically: true, encoding: .utf8)
            let result = AssemblyResult(
                tool: .megahit,
                readType: .illuminaShortReads,
                contigsPath: contigsURL,
                graphPath: nil,
                logPath: nil,
                assemblerVersion: "test",
                commandLine: "megahit",
                outputDirectory: resultDirectory,
                statistics: try AssemblyStatisticsCalculator.compute(from: contigsURL),
                wallTimeSeconds: 1
            )
            try result.save(to: resultDirectory)
            return FASTQCLIExecutionResult(outputURLs: [])
        }
        let importer = SpyDirectImporter()
        let service = FASTQOperationExecutionService(
            inputResolver: resolver,
            commandRunner: runner,
            directImporter: importer
        )

        let result = try await service.execute(
            request: request,
            workingDirectory: outputDirectory
        )

        XCTAssertEqual(result.importedURLs, [outputDirectory])
        XCTAssertEqual(importer.calls, [[outputDirectory]])
    }

    func testExecuteWithLiveRunnerDrainsVerboseAssemblyProcessOutput() async throws {
        actor ResultBox {
            var result: FASTQOperationExecutionResult?
            var error: Error?

            func store(result: FASTQOperationExecutionResult) {
                self.result = result
            }

            func store(error: Error) {
                self.error = error
            }
        }

        let tempDir = try FASTQOperationTestHelper.makeTempDir(prefix: "FASTQExecService")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let outputDirectory = tempDir.appendingPathComponent("analysis-output", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let fakeCLI = tempDir.appendingPathComponent("fake-lungfish-cli.sh")
        let script = """
        #!/bin/bash
        set -euo pipefail
        head -c 1048576 /dev/zero | tr '\\0' 'x'
        head -c 1048576 /dev/zero | tr '\\0' 'y' >&2
        cat > contigs.fasta <<'EOF'
        >contig1
        AACCGGTT
        EOF
        output_dir="$PWD"
        cat > assembly-result.json <<EOF
        {
          "schemaVersion": 2,
          "tool": "megahit",
          "readType": "illuminaShortReads",
          "contigsPath": "contigs.fasta",
          "graphPath": null,
          "logPath": null,
          "scaffoldsPath": null,
          "paramsPath": null,
          "assemblerVersion": "test",
          "commandLine": "fake-lungfish-cli",
          "outputDirectory": "$output_dir",
          "statistics": {
            "contigCount": 1,
            "gcFraction": 0.5,
            "l50": 1,
            "largestContigBP": 8,
            "meanLengthBP": 8,
            "n50": 8,
            "n90": 8,
            "smallestContigBP": 8,
            "totalLengthBP": 8
          },
          "wallTimeSeconds": 1
        }
        EOF
        """
        try script.write(to: fakeCLI, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCLI.path)

        XCTAssertEqual(setenv("LUNGFISH_CLI_PATH", fakeCLI.path, 1), 0)
        defer { unsetenv("LUNGFISH_CLI_PATH") }

        let request = FASTQOperationLaunchRequest.assemble(
            request: AssemblyRunRequest(
                tool: .megahit,
                readType: .illuminaShortReads,
                inputURLs: [
                    URL(fileURLWithPath: "/tmp/sample_R1.fastq.gz"),
                    URL(fileURLWithPath: "/tmp/sample_R2.fastq.gz"),
                ],
                projectName: "VerboseRunner",
                outputDirectory: outputDirectory,
                pairedEnd: true,
                threads: 2,
                memoryGB: nil,
                minContigLength: nil,
                selectedProfileID: nil,
                extraArguments: []
            ),
            outputMode: .perInput
        )

        let service = FASTQOperationExecutionService(
            inputResolver: SpyInputResolver(resolvedRequest: request),
            directImporter: SpyDirectImporter()
        )
        let resultBox = ResultBox()
        let finished = expectation(description: "live runner completed")

        Task {
            do {
                let result = try await service.execute(
                    request: request,
                    workingDirectory: outputDirectory
                )
                await resultBox.store(result: result)
            } catch {
                await resultBox.store(error: error)
            }
            finished.fulfill()
        }

        await fulfillment(of: [finished], timeout: 5.0)

        let error = await resultBox.error
        XCTAssertNil(error)
        let result = await resultBox.result
        XCTAssertEqual(result?.importedURLs, [outputDirectory])
    }

    func testRefreshQCSummaryLaunchBuildsFastqQCSummaryInvocation() throws {
        let request = FASTQOperationLaunchRequest.refreshQCSummary(
            inputURLs: [
                URL(fileURLWithPath: "/tmp/input-1.fastq"),
                URL(fileURLWithPath: "/tmp/input-2.fastq"),
            ]
        )

        let invocation = try FASTQOperationExecutionService().buildInvocation(for: request)

        XCTAssertEqual(invocation.subcommand, "fastq")
        XCTAssertEqual(invocation.arguments, [
            "qc-summary",
            "/tmp/input-1.fastq",
            "/tmp/input-2.fastq",
            "--output",
            "<derived>",
        ])
    }

    @MainActor
    func testPrepareForRunSynthesizesConcreteDerivativeRequest() throws {
        let state = FASTQOperationDialogState(
            initialCategory: .readProcessing,
            selectedInputURLs: [URL(fileURLWithPath: "/tmp/input.fastq")],
            projectURL: nil
        )
        state.selectTool(.orientReads)
        state.setAuxiliaryInput(URL(fileURLWithPath: "/tmp/reference.fasta"), for: .referenceSequence)

        state.prepareForRun()

        guard case .derivative(let request, let inputURLs, let outputMode)? = state.pendingLaunchRequest else {
            return XCTFail("Expected concrete derivative launch request")
        }

        XCTAssertEqual(inputURLs, [URL(fileURLWithPath: "/tmp/input.fastq")])
        XCTAssertEqual(outputMode, .perInput)
        XCTAssertEqual(request, .orient(
            referenceURL: URL(fileURLWithPath: "/tmp/reference.fasta"),
            wordLength: 12,
            dbMask: "dust",
            saveUnoriented: false
        ))
    }

    func testDerivativeLaunchBuildsConcreteFastqInvocation() throws {
        let request = FASTQOperationLaunchRequest.derivative(
            request: .subsampleProportion(0.25),
            inputURLs: [URL(fileURLWithPath: "/tmp/input.fastq")],
            outputMode: .perInput
        )

        let invocation = try FASTQOperationExecutionService().buildInvocation(for: request)

        XCTAssertEqual(invocation.subcommand, "fastq")
        XCTAssertEqual(invocation.arguments, [
            "subsample",
            "/tmp/input.fastq",
            "--proportion",
            "0.25",
            "-o",
            "<derived>",
        ])
    }

    func testQualityTrimInvocationIncludesExtraArgs() throws {
        let request = FASTQOperationLaunchRequest.derivative(
            request: .qualityTrim(
                threshold: 20,
                windowSize: 4,
                mode: .cutRight,
                extraArguments: ["--length_required", "75"]
            ),
            inputURLs: [URL(fileURLWithPath: "/tmp/input.fastq")],
            outputMode: .perInput
        )

        let invocation = try FASTQOperationExecutionService().buildInvocation(for: request)

        XCTAssertEqual(Array(invocation.arguments.suffix(2)), ["--extra-args", "--length_required 75"])
    }

    func testClassificationInvocationIncludesExtraArgs() throws {
        let baseInput = [URL(fileURLWithPath: "/tmp/input.fastq")]

        let kraken2 = try FASTQOperationExecutionService().buildInvocation(
            for: .classify(
                tool: .kraken2,
                inputURLs: baseInput,
                databaseName: "kraken-db",
                extraArguments: ["--minimum-base-quality", "20"]
            )
        )

        XCTAssertEqual(Array(kraken2.arguments.suffix(2)), ["--extra-args", "--minimum-base-quality 20"])
    }

    func testDerivativeLaunchRejectsAdapterRequestsThatNeedMultipleAdapterShapes() {
        let request = FASTQOperationLaunchRequest.derivative(
            request: .adapterTrim(
                mode: .specified,
                sequence: "AGATCGGAAGAGC",
                sequenceR2: "GCTCTTCCGATCT",
                fastaFilename: nil
            ),
            inputURLs: [URL(fileURLWithPath: "/tmp/input.fastq")],
            outputMode: .perInput
        )

        XCTAssertThrowsError(try FASTQOperationExecutionService().buildInvocation(for: request)) { error in
            guard let execError = error as? FASTQOperationExecutionError else {
                return XCTFail("Expected FASTQOperationExecutionError")
            }
            XCTAssertTrue(execError.errorDescription?.contains("sequenceR2") == true)
        }
    }

    func testDerivativeLaunchRejectsCutadaptPrimerRequestsOutsideTheLinkedReferenceSubset() {
        let request = FASTQOperationLaunchRequest.derivative(
            request: .primerRemoval(
                configuration: FASTQPrimerTrimConfiguration(
                    source: .literal,
                    readMode: .paired,
                    mode: .linked,
                    forwardSequence: "AGATCGGAAGAGC",
                    reverseSequence: "GCTCTTCCGATCT",
                    tool: .cutadapt
                )
            ),
            inputURLs: [URL(fileURLWithPath: "/tmp/input.fastq")],
            outputMode: .perInput
        )

        XCTAssertThrowsError(try FASTQOperationExecutionService().buildInvocation(for: request)) { error in
            guard let execError = error as? FASTQOperationExecutionError else {
                return XCTFail("Expected FASTQOperationExecutionError")
            }
            XCTAssertTrue(execError.errorDescription?.contains("cutadapt linked") == true)
        }
    }

    func testDerivativeLaunchRejectsDemultiplexRequestsWithSampleAssignments() {
        let request = FASTQOperationLaunchRequest.derivative(
            request: .demultiplex(
                kitID: "test-kit",
                customCSVPath: nil,
                location: "bothends",
                symmetryMode: .symmetric,
                maxDistanceFrom5Prime: 0,
                maxDistanceFrom3Prime: 0,
                errorRate: 0.15,
                engine: .cutadapt,
                trimBarcodes: true,
                sampleAssignments: [
                    FASTQSampleBarcodeAssignment(sampleID: "sample-1", forwardBarcodeID: "BC01")
                ],
                kitOverride: nil
            ),
            inputURLs: [URL(fileURLWithPath: "/tmp/input.fastq")],
            outputMode: .fixedBatch
        )

        XCTAssertThrowsError(try FASTQOperationExecutionService().buildInvocation(for: request)) { error in
            XCTAssertTrue(error.localizedDescription.contains("demultiplex"))
            XCTAssertTrue(error.localizedDescription.contains("sampleAssignments"))
        }
    }

    func testDerivativeLaunchRejectsOrientRequestsThatAskToSaveUnorientedReads() {
        let request = FASTQOperationLaunchRequest.derivative(
            request: .orient(
                referenceURL: URL(fileURLWithPath: "/tmp/reference.fasta"),
                wordLength: 12,
                dbMask: "dust",
                saveUnoriented: true
            ),
            inputURLs: [URL(fileURLWithPath: "/tmp/input.fastq")],
            outputMode: .perInput
        )

        XCTAssertThrowsError(try FASTQOperationExecutionService().buildInvocation(for: request)) { error in
            XCTAssertTrue(error.localizedDescription.contains("orient"))
            XCTAssertTrue(error.localizedDescription.contains("saveUnoriented"))
        }
    }

    func testClassificationLaunchesMapToTopLevelCommands() throws {
        let baseInput = [URL(fileURLWithPath: "/tmp/input.fastq")]

        let kraken2 = try FASTQOperationExecutionService().buildInvocation(
            for: .classify(tool: .kraken2, inputURLs: baseInput, databaseName: "kraken-db")
        )
        XCTAssertEqual(kraken2.subcommand, "classify")

        let esviritu = try FASTQOperationExecutionService().buildInvocation(
            for: .classify(tool: .esViritu, inputURLs: baseInput, databaseName: "esv-db")
        )
        XCTAssertEqual(esviritu.subcommand, "esviritu")

        let taxtriage = try FASTQOperationExecutionService().buildInvocation(
            for: .classify(tool: .taxTriage, inputURLs: baseInput, databaseName: "tax-db")
        )
        XCTAssertEqual(taxtriage.subcommand, "taxtriage")
    }

    func testExecuteEsVirituClassificationBridgesFASTAInputToSyntheticFASTQ() async throws {
        let tempDir = try FASTQOperationTestHelper.makeTempDir(prefix: "FASTQExecEsViritu")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fastaURL = tempDir.appendingPathComponent("reads.fasta")
        try """
        >seq1
        AACCGGTTAACC
        >seq2
        TTGGCCAATTGG
        """.write(to: fastaURL, atomically: true, encoding: .utf8)

        let runner = SpyCommandRunner { invocation, _ in
            XCTAssertEqual(invocation.subcommand, "esviritu")
            XCTAssertEqual(invocation.arguments.first, "detect")

            let bridgedInputURL = URL(fileURLWithPath: try XCTUnwrap(invocation.arguments[safe: 1]))
            XCTAssertEqual(SequenceFormat.from(url: bridgedInputURL), .fastq)

            let bridgedContents = try String(contentsOf: bridgedInputURL, encoding: .utf8)
            XCTAssertTrue(bridgedContents.contains("@seq1"))
            XCTAssertTrue(bridgedContents.contains("IIIIIIIIIIII"))

            return FASTQCLIExecutionResult(outputURLs: [])
        }
        let importer = SpyDirectImporter()
        let service = FASTQOperationExecutionService(
            commandRunner: runner,
            directImporter: importer
        )

        _ = try await service.execute(
            request: .classify(tool: .esViritu, inputURLs: [fastaURL], databaseName: "esv-db"),
            workingDirectory: tempDir
        )

        XCTAssertEqual(runner.invocations.count, 1)
    }

    func testExecuteKraken2ClassificationPreservesNativeFASTAInput() async throws {
        let tempDir = try FASTQOperationTestHelper.makeTempDir(prefix: "FASTQExecKrakenFASTA")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fastaURL = tempDir.appendingPathComponent("reads.fasta")
        try """
        >seq1
        AACCGGTTAACC
        """.write(to: fastaURL, atomically: true, encoding: .utf8)

        let runner = SpyCommandRunner { invocation, _ in
            XCTAssertEqual(invocation.subcommand, "classify")
            XCTAssertEqual(invocation.arguments.first, fastaURL.path)
            XCTAssertEqual(SequenceFormat.from(url: URL(fileURLWithPath: invocation.arguments[0])), .fasta)
            return FASTQCLIExecutionResult(outputURLs: [])
        }
        let importer = SpyDirectImporter()
        let service = FASTQOperationExecutionService(
            commandRunner: runner,
            directImporter: importer
        )

        _ = try await service.execute(
            request: .classify(tool: .kraken2, inputURLs: [fastaURL], databaseName: "kraken-db"),
            workingDirectory: tempDir
        )

        XCTAssertEqual(runner.invocations.count, 1)
    }
}

private struct TestFastqQCSummaryReport: Codable {
    let inputs: [Entry]

    struct Entry: Codable {
        let input: String
        let statistics: FASTQDatasetStatistics
    }
}

private final class SpyInputResolver: @unchecked Sendable, FASTQOperationInputResolving {
    let resolvedRequest: FASTQOperationLaunchRequest
    private(set) var requests: [FASTQOperationLaunchRequest] = []

    init(resolvedRequest: FASTQOperationLaunchRequest) {
        self.resolvedRequest = resolvedRequest
    }

    func resolve(
        request: FASTQOperationLaunchRequest,
        tempDirectory: URL
    ) async throws -> FASTQOperationLaunchRequest {
        _ = tempDirectory
        requests.append(request)
        return resolvedRequest
    }
}

private final class SpyDirectImporter: @unchecked Sendable, FASTQOperationDirectImporting {
    private(set) var calls: [[URL]] = []
    var resultURLs: [URL] = []

    func importOutputs(
        at outputURLs: [URL],
        forResolvedRequest request: FASTQOperationLaunchRequest,
        originalRequest: FASTQOperationLaunchRequest,
        outputDirectory: URL
    ) async throws -> [URL] {
        _ = request
        _ = originalRequest
        _ = outputDirectory
        calls.append(outputURLs)
        return resultURLs.isEmpty ? outputURLs : resultURLs
    }
}

private final class SpyCommandRunner: @unchecked Sendable, FASTQOperationCommandRunning {
    private(set) var invocations: [CLIInvocation] = []
    private let handler: @Sendable (CLIInvocation, URL, FASTQOperationProgressHandler) throws -> FASTQCLIExecutionResult

    init(
        handler: @escaping @Sendable (CLIInvocation, URL) throws -> FASTQCLIExecutionResult = { _, _ in
            FASTQCLIExecutionResult(outputURLs: [])
        }
    ) {
        self.handler = { invocation, outputDirectory, _ in
            try handler(invocation, outputDirectory)
        }
    }

    init(
        progressHandler: @escaping @Sendable (CLIInvocation, URL, FASTQOperationProgressHandler) throws -> FASTQCLIExecutionResult
    ) {
        self.handler = progressHandler
    }

    func run(
        invocation: CLIInvocation,
        outputDirectory: URL,
        progress: @escaping FASTQOperationProgressHandler
    ) async throws -> FASTQCLIExecutionResult {
        invocations.append(invocation)
        return try handler(invocation, outputDirectory, progress)
    }
}

private final class SpyReferenceBundleWrapper: @unchecked Sendable, ReferenceBundleWrapping {
    struct Call: Equatable {
        let sourceURL: URL
        let outputDirectory: URL
        let preferredBundleName: String?
    }

    private(set) var calls: [Call] = []
    var resultURLs: [URL] = []

    func importReferenceBundle(
        sourceURL: URL,
        outputDirectory: URL,
        preferredBundleName: String?
    ) async throws -> URL {
        calls.append(Call(
            sourceURL: sourceURL,
            outputDirectory: outputDirectory,
            preferredBundleName: preferredBundleName
        ))
        let resultURL = resultURLs[safe: calls.count - 1]
            ?? outputDirectory.appendingPathComponent("\(preferredBundleName ?? sourceURL.deletingPathExtension().lastPathComponent).lungfishref")
        try FileManager.default.createDirectory(at: resultURL, withIntermediateDirectories: true)
        return resultURL
    }
}

private final class SpyFASTQOutputBundleWriter: @unchecked Sendable, FASTQOutputBundleWriting {
    struct Call: Equatable {
        let sourceURL: URL
        let bundleURL: URL
        let originalRequest: FASTQOperationLaunchRequest
        let sourceInputURL: URL?
    }

    private(set) var calls: [Call] = []
    private let removeSource: Bool

    init(removeSource: Bool = false) {
        self.removeSource = removeSource
    }

    func importFASTQOutput(
        sourceURL: URL,
        bundleURL: URL,
        originalRequest: FASTQOperationLaunchRequest,
        sourceInputURL: URL?
    ) async throws -> URL {
        calls.append(Call(
            sourceURL: sourceURL,
            bundleURL: bundleURL,
            originalRequest: originalRequest,
            sourceInputURL: sourceInputURL
        ))
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        if removeSource {
            try? FileManager.default.removeItem(at: sourceURL)
        }
        return bundleURL
    }
}

private final class SpyFASTQOutputIngestor: @unchecked Sendable, FASTQOutputIngesting {
    private(set) var configs: [FASTQIngestionConfig] = []

    func ingest(
        config: FASTQIngestionConfig,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> FASTQIngestionResult {
        configs.append(config)
        progress(0.5, "ingesting")

        let outputURL = config.outputDirectory
            .appendingPathComponent(config.inputFiles[0].deletingPathExtension().lastPathComponent)
            .appendingPathExtension("fastq")
            .appendingPathExtension("gz")
        try FileManager.default.createDirectory(
            at: config.outputDirectory,
            withIntermediateDirectories: true
        )
        try Data("compressed-fastq\n".utf8).write(to: outputURL)
        if config.deleteOriginals {
            try? FileManager.default.removeItem(at: config.inputFiles[0])
        }

        progress(1.0, "done")
        return FASTQIngestionResult(
            outputFile: outputURL,
            wasClumpified: true,
            qualityBinning: config.qualityBinning,
            originalFilenames: config.inputFiles.map(\.lastPathComponent),
            originalSizeBytes: 128,
            finalSizeBytes: 16,
            pairingMode: config.pairingMode
        )
    }
}

private func writeSyntheticProvenance(
    to directory: URL,
    name: String,
    toolName: String,
    toolVersion: String,
    command: [String],
    durableReplayArgv: [String]? = nil,
    inputURL: URL,
    outputURL: URL,
    parameters: [String: ParameterValue] = [:],
    format: FileFormat = .fastq,
    sidecarURL: URL? = nil
) throws {
    let startedAt = Date(timeIntervalSince1970: 1_800)
    let endedAt = Date(timeIntervalSince1970: 1_801.25)
    let input = try ProvenanceFileDescriptor.file(url: inputURL, format: format, role: .input)
    let output = try ProvenanceFileDescriptor.file(url: outputURL, format: format, role: .output)
    let envelope = try ProvenanceRunBuilder(
        workflowName: name,
        workflowVersion: WorkflowRun.currentAppVersion,
        toolName: toolName,
        toolVersion: toolVersion
    )
    .argv(command)
    .durableReplayArgv(durableReplayArgv)
    .options(explicit: parameters, defaults: [:], resolved: parameters)
    .input(inputURL, format: format, role: .input)
    .output(outputURL, format: format, role: .output)
    .step(
        ProvenanceStep(
            toolName: toolName,
            toolVersion: toolVersion,
            argv: command,
            inputs: [input],
            outputs: [output],
            exitStatus: 0,
            wallTimeSeconds: 1.25,
            startedAt: startedAt,
            completedAt: endedAt
        )
    )
    .runtime(ProvenanceRuntimeIdentity.fixture())
    .complete(
        exitStatus: 0,
        startedAt: startedAt,
        endedAt: endedAt
    )
    if let sidecarURL {
        try ProvenanceWriter(signingProvider: nil).write(envelope, toSidecar: sidecarURL)
    } else {
        try ProvenanceWriter(signingProvider: nil).write(envelope, to: directory)
    }
}

private func writeSyntheticMultiOutputProvenance(
    to directory: URL,
    name: String,
    toolName: String,
    toolVersion: String,
    command: [String],
    inputURL: URL,
    outputURLs: [URL],
    parameters: [String: ParameterValue] = [:]
) throws {
    let startedAt = Date(timeIntervalSince1970: 1_900)
    let endedAt = Date(timeIntervalSince1970: 1_902)
    let input = try ProvenanceFileDescriptor.file(url: inputURL, format: .fastq, role: .input)
    let outputs = try outputURLs.map {
        try ProvenanceFileDescriptor.file(url: $0, format: .fastq, role: .output)
    }
    var builder = try ProvenanceRunBuilder(
        workflowName: name,
        workflowVersion: WorkflowRun.currentAppVersion,
        toolName: toolName,
        toolVersion: toolVersion
    )
    .argv(command)
    .options(explicit: parameters, defaults: [:], resolved: parameters)
    .input(inputURL, format: .fastq, role: .input)
    .runtime(ProvenanceRuntimeIdentity.fixture())

    for outputURL in outputURLs {
        builder = try builder.output(outputURL, format: .fastq, role: .output)
    }

    let envelope = try builder
        .step(
            ProvenanceStep(
                toolName: toolName,
                toolVersion: toolVersion,
                argv: command,
                inputs: [input],
                outputs: outputs,
                exitStatus: 0,
                wallTimeSeconds: 2,
                startedAt: startedAt,
                completedAt: endedAt
            )
        )
        .complete(exitStatus: 0, startedAt: startedAt, endedAt: endedAt)
    try ProvenanceWriter(signingProvider: nil).write(envelope, to: directory)
}

private func assertProjectedProvenance(
    in bundleURL: URL,
    sourceOutput: URL,
    sourceInput: URL,
    sourceProvenanceDirectory: URL,
    workflowName: String
) throws {
    let bundledFASTQ = try XCTUnwrap(FASTQBundle.resolvePrimaryFASTQURL(for: bundleURL))
    let bundledFASTQPath = bundledFASTQ.standardizedFileURL.path
    let envelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: bundleURL))
    let descriptor = try XCTUnwrap(envelope.output)

    XCTAssertEqual(envelope.workflowName, workflowName)
    XCTAssertEqual(envelope.output?.path, bundledFASTQPath)
    XCTAssertEqual(envelope.outputs.map(\.path), [bundledFASTQPath])
    XCTAssertEqual(envelope.steps.first?.outputs.map(\.path), [bundledFASTQPath])
    XCTAssertEqual(envelope.steps.first?.inputs.map(\.path), [sourceInput.path])
    XCTAssertEqual(descriptor.originPath, sourceOutput.path)
    XCTAssertEqual(
        descriptor.sourceProvenancePath,
        sourceProvenanceDirectory.appendingPathComponent(ProvenanceRecorder.provenanceFilename).path
    )
    XCTAssertEqual(descriptor.checksumSHA256, try ProvenanceFileHasher.sha256(of: bundledFASTQ))
    XCTAssertEqual(descriptor.fileSize, try ProvenanceFileHasher.fileSize(of: bundledFASTQ))

    let legacy = try XCTUnwrap(ProvenanceRecorder.load(from: bundleURL))
    XCTAssertEqual(legacy.steps.first?.outputs.map(\.filename), [bundledFASTQ.lastPathComponent])
}

private func makeFullFASTABundle(
    named name: String,
    in tempDir: URL,
    records: [(id: String, sequence: String)]
) throws -> URL {
    let bundleURL = tempDir.appendingPathComponent(
        "\(name).\(FASTQBundle.directoryExtension)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

    let fastaFilename = "reads.fasta"
    let fastaURL = bundleURL.appendingPathComponent(fastaFilename)
    let fastaContents = records.map { ">\($0.id)\n\($0.sequence)\n" }.joined()
    try fastaContents.write(to: fastaURL, atomically: true, encoding: .utf8)

    let manifest = FASTQDerivedBundleManifest(
        name: name,
        parentBundleRelativePath: ".",
        rootBundleRelativePath: ".",
        rootFASTQFilename: fastaFilename,
        payload: .fullFASTA(fastaFilename: fastaFilename),
        lineage: [],
        operation: FASTQDerivativeOperation(kind: .searchText, query: "fasta-fixture"),
        cachedStatistics: .placeholder(
            readCount: records.count,
            baseCount: Int64(records.reduce(0) { $0 + $1.sequence.count })
        ),
        pairingMode: nil,
        sequenceFormat: .fasta
    )
    try FASTQBundle.saveDerivedManifest(manifest, in: bundleURL)
    return bundleURL
}

private func makeReferenceBundle(
    named name: String,
    in tempDir: URL,
    records: [(id: String, sequence: String)]
) throws -> URL {
    let bundleURL = tempDir.appendingPathComponent("\(name).lungfishref", isDirectory: true)
    let genomeDirectory = bundleURL.appendingPathComponent("genome", isDirectory: true)
    try FileManager.default.createDirectory(at: genomeDirectory, withIntermediateDirectories: true)

    let fastaFilename = "genome/sequence.fa.gz"
    let fastaURL = bundleURL.appendingPathComponent(fastaFilename)
    let fastaContents = records.map { ">\($0.id)\n\($0.sequence)\n" }.joined()
    try writeGzipFixture(fastaContents, to: fastaURL)

    let faiContents = records.reduce(into: [String]()) { lines, record in
        lines.append("\(record.id)\t\(record.sequence.count)\t9\t\(record.sequence.count)\t\(record.sequence.count + 1)")
    }.joined(separator: "\n") + "\n"
    try faiContents.write(
        to: bundleURL.appendingPathComponent("\(fastaFilename).fai"),
        atomically: true,
        encoding: .utf8
    )

    let manifest = BundleManifest(
        name: name,
        identifier: "org.lungfish.\(name)",
        source: SourceInfo(organism: "Test organism", assembly: "Test assembly"),
        genome: GenomeInfo(
            path: fastaFilename,
            indexPath: "\(fastaFilename).fai",
            totalLength: Int64(records.reduce(0) { $0 + $1.sequence.count }),
            chromosomes: []
        )
    )
    try manifest.save(to: bundleURL)
    return bundleURL
}

private func writeGzipFixture(_ content: String, to gzipURL: URL) throws {
    let sourceURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("lungfish-app-gzip-source-\(UUID().uuidString).fa")
    try content.write(to: sourceURL, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: sourceURL) }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
    process.arguments = ["-c", sourceURL.path]

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    try process.run()
    let compressed = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    let stderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
        let message = String(data: stderr, encoding: .utf8) ?? "gzip failed"
        throw NSError(
            domain: "FASTQOperationExecutionServiceTests.GzipFixture",
            code: Int(process.terminationStatus),
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    try compressed.write(to: gzipURL)
}

private func makeVirtualDerivedFASTQBundle(named name: String, in tempDir: URL) throws -> URL {
    let root = try FASTQOperationTestHelper.makeBundle(named: "\(name)-root", in: tempDir)
    try FASTQOperationTestHelper.writeSyntheticFASTQ(to: root.fastqURL, readCount: 4, readLength: 20)

    let bundleURL = tempDir.appendingPathComponent(
        "\(name).\(FASTQBundle.directoryExtension)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
    try "read1\nread2\n".write(
        to: bundleURL.appendingPathComponent("read-ids.txt"),
        atomically: true,
        encoding: .utf8
    )

    let manifest = FASTQDerivedBundleManifest(
        name: name,
        parentBundleRelativePath: "../\(root.bundleURL.lastPathComponent)",
        rootBundleRelativePath: "../\(root.bundleURL.lastPathComponent)",
        rootFASTQFilename: root.fastqURL.lastPathComponent,
        payload: .subset(readIDListFilename: "read-ids.txt"),
        lineage: [],
        operation: FASTQDerivativeOperation(kind: .subsampleCount, count: 2),
        cachedStatistics: .placeholder(readCount: 2, baseCount: 40),
        pairingMode: nil,
        sequenceFormat: .fastq,
        materializationState: .virtual
    )
    try FASTQBundle.saveDerivedManifest(manifest, in: bundleURL)
    return bundleURL
}
