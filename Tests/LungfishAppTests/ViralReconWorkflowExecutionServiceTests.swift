import LungfishKit
import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishWorkflow
import LungfishTestSupport

@MainActor
final class ViralReconWorkflowExecutionServiceTests: XCTestCase {
    func testServiceCompletesAfterWizardDerivesPrimersFromGzippedReference() async throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("viral-recon-gzipped-reference-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let request = try ViralReconAppTestFixtures.illuminaRequest(root: temp)
        try FileManager.default.removeItem(at: request.primer.fastaURL)
        try """
        {
          "schema_version": 1,
          "name": "qiaseq-direct-sars2",
          "display_name": "QIASeq DIRECT SARS-CoV-2",
          "description": "Viral Recon test fixture",
          "organism": "SARS-CoV-2",
          "reference_accessions": [
            { "accession": "MN908947.3", "canonical": true },
            { "accession": "NC_045512.2", "equivalent": true }
          ],
          "primer_count": 2,
          "amplicon_count": 1
        }
        """.write(
            to: request.primer.bundleURL.appendingPathComponent("manifest.json"),
            atomically: true,
            encoding: .utf8
        )
        try "Test primer scheme\n".write(
            to: request.primer.bundleURL.appendingPathComponent("PROVENANCE.md"),
            atomically: true,
            encoding: .utf8
        )
        try "MN908947.3\t0\t4\tSARS2_1_LEFT\nMN908947.3\t4\t8\tSARS2_1_RIGHT\n".write(
            to: request.primer.bundleURL.appendingPathComponent("primers.bed"),
            atomically: true,
            encoding: .utf8
        )
        let importedBundle = temp
            .appendingPathComponent("Downloads", isDirectory: true)
            .appendingPathComponent("NC_045512.lungfishref", isDirectory: true)
        let genomeDirectory = importedBundle.appendingPathComponent("genome", isDirectory: true)
        try FileManager.default.createDirectory(at: genomeDirectory, withIntermediateDirectories: true)
        let importedReference = genomeDirectory.appendingPathComponent("sequence.fa.gz")
        try writeGzipFixture(
            ">NC_045512.2 imported SARS-CoV-2 reference\nAAAACCCCGGGGTTTT\n",
            to: importedReference
        )
        try "NC_045512.2\t16\t0\t16\t17\n".write(
            to: importedReference.appendingPathExtension("fai"),
            atomically: true,
            encoding: .utf8
        )
        try BundleManifest(
            name: "NC_045512",
            identifier: "org.lungfish.NC_045512",
            source: SourceInfo(organism: "SARS-CoV-2", assembly: "NC_045512.2"),
            genome: GenomeInfo(
                path: "genome/sequence.fa.gz",
                indexPath: "genome/sequence.fa.gz.fai",
                totalLength: 16,
                chromosomes: []
            )
        ).save(to: importedBundle)
        let importedCandidate = try XCTUnwrap(
            ReferenceSequenceScanner.scanAll(in: temp).first {
                $0.fastaURL.standardizedFileURL == importedReference.standardizedFileURL
            }
        )
        let derivedPrimer = try ViralReconPrimerStager.stage(
            primerBundleURL: request.primer.bundleURL,
            referenceFASTAURL: importedCandidate.fastaURL,
            referenceName: ViralReconWizardSheet.referenceName(
                from: importedCandidate.fastaURL,
                fallback: "MN908947.3"
            ),
            destinationDirectory: temp.appendingPathComponent("wizard-staging", isDirectory: true)
        )
        let preparedRequest = try ViralReconRunRequest(
            samples: request.samples,
            platform: request.platform,
            protocol: request.protocol,
            samplesheetURL: request.samplesheetURL,
            outputDirectory: request.outputDirectory,
            executor: request.executor,
            version: request.version,
            reference: .local(fastaURL: importedCandidate.fastaURL, gffURL: nil),
            primer: derivedPrimer,
            minimumMappedReads: request.minimumMappedReads,
            variantCaller: request.variantCaller,
            consensusCaller: request.consensusCaller,
            skipOptions: request.skipOptions,
            advancedParams: request.advancedParams
        )
        let operationCenter = OperationCenter()
        let runner = StubViralReconProcessRunner(result: .init(
            exitCode: 0,
            standardOutput: "viralrecon completed",
            standardError: ""
        ))
        let service = ViralReconWorkflowExecutionService(
            operationCenter: operationCenter,
            processRunner: runner
        )

        let result = try await service.run(
            preparedRequest,
            bundleRoot: temp.appendingPathComponent("Analyses", isDirectory: true)
        )

        let item = try XCTUnwrap(operationCenter.items.first { $0.id == result.operationID })
        XCTAssertEqual(item.state, .completed)
        let invocation = try XCTUnwrap(runner.invocations.first)
        XCTAssertTrue(invocation.arguments.contains { $0.contains("primer_fasta=") })
        XCTAssertTrue(invocation.arguments.contains("fasta=\(importedCandidate.fastaURL.path)"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.bundleURL.appendingPathComponent("inputs/primers/primers.fasta").path))
    }

    func testServiceCreatesRunBundleAndLogsPreparation() async throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("viral-recon-service-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let request = try ViralReconAppTestFixtures.illuminaRequest(root: temp)
        let operationCenter = OperationCenter()
        let runner = StubViralReconProcessRunner(result: .init(
            exitCode: 0,
            standardOutput: "nextflow progress\ncompleted sample SARS2_A",
            standardError: "nextflow warning"
        ))
        runner.onRun = {
            let item = try XCTUnwrap(operationCenter.items.first)
            XCTAssertTrue(item.detail.contains("illumina"))
            XCTAssertTrue(item.detail.contains("1 sample(s)"))
            XCTAssertTrue(item.detail.contains("MN908947.3"))
        }
        let service = ViralReconWorkflowExecutionService(operationCenter: operationCenter, processRunner: runner)

        let result = try await service.run(
            request,
            bundleRoot: temp.appendingPathComponent("Analyses", isDirectory: true)
        )

        XCTAssertEqual(result.bundleURL.pathExtension, "lungfishrun")
        let persistedSamplesheet = result.bundleURL.appendingPathComponent("inputs/samplesheet.csv")
        let persistedPrimerBED = result.bundleURL.appendingPathComponent("inputs/primers/primers.bed")
        let persistedPrimerFASTA = result.bundleURL.appendingPathComponent("inputs/primers/primers.fasta")
        XCTAssertTrue(FileManager.default.fileExists(atPath: persistedSamplesheet.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: persistedPrimerBED.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: persistedPrimerFASTA.path))
        XCTAssertEqual(
            try String(contentsOf: persistedSamplesheet, encoding: .utf8),
            try String(contentsOf: request.samplesheetURL, encoding: .utf8)
        )
        XCTAssertEqual(
            try String(contentsOf: persistedPrimerBED, encoding: .utf8),
            try String(contentsOf: request.primer.bedURL, encoding: .utf8)
        )
        XCTAssertEqual(
            try String(contentsOf: persistedPrimerFASTA, encoding: .utf8),
            try String(contentsOf: request.primer.fastaURL, encoding: .utf8)
        )

        let invocation = try XCTUnwrap(runner.invocations.first)
        XCTAssertTrue(invocation.arguments.contains(persistedSamplesheet.path))
        XCTAssertTrue(invocation.arguments.contains("--expected-output"))
        XCTAssertTrue(invocation.arguments.contains(request.outputDirectory.path))
        XCTAssertTrue(invocation.arguments.contains("primer_bed=\(persistedPrimerBED.path)"))
        XCTAssertTrue(invocation.arguments.contains("primer_fasta=\(persistedPrimerFASTA.path)"))
        XCTAssertFalse(invocation.arguments.contains(request.samplesheetURL.path))
        XCTAssertEqual(runner.invocations.first?.workingDirectory, result.bundleURL)

        let manifest = try NFCoreRunBundleStore.read(from: result.bundleURL)
        XCTAssertEqual(manifest.workflowName, "viralrecon")
        XCTAssertEqual(manifest.version, "3.0.0")
        XCTAssertEqual(manifest.executor, .docker)
        XCTAssertEqual(manifest.params["input"], persistedSamplesheet.path)
        XCTAssertEqual(manifest.params["primer_bed"], persistedPrimerBED.path)
        XCTAssertEqual(manifest.params["primer_fasta"], persistedPrimerFASTA.path)

        XCTAssertEqual(
            try String(contentsOf: result.bundleURL.appendingPathComponent("logs/stdout.log"), encoding: .utf8),
            "nextflow progress\ncompleted sample SARS2_A"
        )
        XCTAssertEqual(
            try String(contentsOf: result.bundleURL.appendingPathComponent("logs/stderr.log"), encoding: .utf8),
            "nextflow warning"
        )

        let item = try XCTUnwrap(operationCenter.items.first { $0.id == result.operationID })
        XCTAssertEqual(item.operationType, .viralRecon)
        XCTAssertEqual(item.title, "Viral Recon")
        XCTAssertTrue(item.cliCommand?.contains(persistedSamplesheet.path) == true)
        XCTAssertTrue(item.logEntries.map(\.message).contains { $0.contains("samplesheet") })
        XCTAssertTrue(item.logEntries.map(\.message).contains { $0.contains("lungfish-cli workflow run nf-core/viralrecon") })
        XCTAssertTrue(item.logEntries.map(\.message).contains { $0.contains("nextflow progress") })
        XCTAssertTrue(item.logEntries.map(\.message).contains { $0.contains("nextflow warning") })
        XCTAssertEqual(item.state, .completed)
        XCTAssertTrue(item.detail.contains(request.outputDirectory.path))
        XCTAssertTrue(item.detail.contains(result.bundleURL.path))
        XCTAssertEqual(item.bundleURLs, [result.bundleURL])
    }

    // A visualisation problem must never present as a lost analysis. The
    // pipeline did its work; failing to build a viewer bundle from that work is
    // a reduced result, not a failed run.
    func testIngestFailureStillReportsTheRunAsCompleted() async throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("viral-recon-ingest-fail-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let request = try ViralReconAppTestFixtures.illuminaRequest(root: temp)
        let marker = request.outputDirectory.appendingPathComponent("raw-output.txt")
        try FileManager.default.createDirectory(at: request.outputDirectory,
                                                withIntermediateDirectories: true)
        try "pipeline output".write(to: marker, atomically: true, encoding: .utf8)

        let operationCenter = OperationCenter()
        let service = ViralReconWorkflowExecutionService(
            operationCenter: operationCenter,
            processRunner: StubViralReconProcessRunner(
                result: .init(exitCode: 0, standardOutput: "", standardError: "")
            ),
            referenceDownloader: { _, _ in },
            resultIngest: { _ in
                throw ViralReconResultIngest.IngestError.referenceBundleMissing
            }
        )

        let result = try await service.run(
            request,
            bundleRoot: temp.appendingPathComponent("Analyses", isDirectory: true)
        )

        let item = try XCTUnwrap(operationCenter.items.first { $0.id == result.operationID })
        XCTAssertEqual(item.state, .completed, "ingest failure must not fail the run")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: marker.path),
            "raw pipeline output must be left intact"
        )
        XCTAssertTrue(
            item.logEntries.contains { $0.level == .warning && $0.message.contains("results") },
            "the ingest failure must be recorded for the Inspector"
        )
    }

    func testSuccessfulIngestIsReportedAndDoesNotDisturbCompletion() async throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("viral-recon-ingest-ok-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let request = try ViralReconAppTestFixtures.illuminaRequest(root: temp)
        let operationCenter = OperationCenter()
        let ingested = IngestRecorder()
        let service = ViralReconWorkflowExecutionService(
            operationCenter: operationCenter,
            processRunner: StubViralReconProcessRunner(
                result: .init(exitCode: 0, standardOutput: "", standardError: "")
            ),
            referenceDownloader: { _, _ in },
            resultIngest: { context in
                ingested.record(context.resultsDirectory)
            }
        )

        let result = try await service.run(
            request,
            bundleRoot: temp.appendingPathComponent("Analyses", isDirectory: true)
        )

        XCTAssertEqual(ingested.directories.count, 1, "ingest runs once on completion")
        let item = try XCTUnwrap(operationCenter.items.first { $0.id == result.operationID })
        XCTAssertEqual(item.state, .completed)
    }

    func testServiceFailsWithExitCodeAndStderrTail() async throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("viral-recon-service-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let request = try ViralReconAppTestFixtures.illuminaRequest(root: temp)
        let operationCenter = OperationCenter()
        let stderr = (1...45).map { "stderr line \($0)" }.joined(separator: "\n") + "\nbad params"
        let runner = StubViralReconProcessRunner(result: .init(
            exitCode: 2,
            standardOutput: "",
            standardError: stderr
        ))
        let service = ViralReconWorkflowExecutionService(operationCenter: operationCenter, processRunner: runner)

        do {
            _ = try await service.run(
                request,
                bundleRoot: temp.appendingPathComponent("Analyses", isDirectory: true)
            )
            XCTFail("Expected Viral Recon service to throw for a non-zero CLI exit")
        } catch {
            XCTAssertEqual(error as? ViralReconWorkflowExecutionError, .nonZeroExit(2))
        }

        let item = try XCTUnwrap(operationCenter.items.first)
        XCTAssertEqual(item.state, .failed)
        XCTAssertTrue(item.detail.contains("exit code 2"))
        XCTAssertEqual(item.errorMessage, "Viral Recon failed")
        XCTAssertTrue(item.errorDetail?.contains("exit code 2") == true)
        XCTAssertTrue(item.errorDetail?.contains("bad params") == true)
        XCTAssertFalse(item.errorDetail?.components(separatedBy: .newlines).contains("stderr line 1") == true)
        XCTAssertTrue(item.logEntries.map(\.message).contains { $0.contains("bad params") })
    }

    // conda and local reach no working run, so they must be refused before any
    // pipeline work starts rather than several minutes into one.
    func testServiceRefusesUnsupportedExecutorsBeforeAnyPipelineWork() async throws {
        for executor in [NFCoreExecutor.conda, .local] {
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent("viral-recon-executor-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: temp) }

            let request = try ViralReconAppTestFixtures.illuminaRequest(root: temp, executor: executor)
            let runner = StubViralReconProcessRunner(
                result: .init(exitCode: 0, standardOutput: "", standardError: "")
            )
            let operationCenter = OperationCenter()
            let service = ViralReconWorkflowExecutionService(
                operationCenter: operationCenter,
                processRunner: runner,
                referenceDownloader: { _, _ in XCTFail("must not download for a refused executor") }
            )
            let bundleRoot = temp.appendingPathComponent("Analyses", isDirectory: true)

            do {
                _ = try await service.run(request, bundleRoot: bundleRoot, projectURL: temp)
                XCTFail("expected \(executor.rawValue) to be refused")
            } catch let error as NFCoreRunRequest.UnsupportedExecutorError {
                XCTAssertEqual(error, .unsupported(executor))
            }

            XCTAssertTrue(runner.invocations.isEmpty)
            XCTAssertTrue(operationCenter.items.isEmpty)
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: bundleRoot.path),
                "no run bundle root should exist for a run refused up front"
            )
        }
    }

    // A project without the canonical bundle must download it exactly once, and
    // the acquired bundle is what the pipeline aligns against.
    func testServiceAcquiresTheReferenceWhenTheProjectLacksIt() async throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("viral-recon-acquire-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let request = try ViralReconAppTestFixtures.illuminaRequest(root: temp)
        let project = temp.appendingPathComponent("Project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

        let downloads = DownloadRecorder()
        let runner = StubViralReconProcessRunner(
            result: .init(exitCode: 0, standardOutput: "", standardError: "")
        )
        let operationCenter = OperationCenter()
        let service = ViralReconWorkflowExecutionService(
            operationCenter: operationCenter,
            processRunner: runner,
            referenceDownloader: { accession, destination in
                downloads.record(accession)
                let bundle = destination.appendingPathComponent(
                    ViralReconReferenceCatalog.bundleFilename, isDirectory: true)
                try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
                try ">\(ViralReconReferenceCatalog.canonicalAccession) SARS-CoV-2\nACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGT\n"
                    .write(
                        to: bundle.appendingPathComponent("sequence.fasta"),
                        atomically: true,
                        encoding: .utf8
                    )
            }
        )

        let result = try await service.run(
            request,
            bundleRoot: temp.appendingPathComponent("Analyses", isDirectory: true),
            projectURL: project
        )

        XCTAssertEqual(downloads.accessions, [ViralReconReferenceCatalog.canonicalAccession])

        let acquiredFASTA = ViralReconReferenceCatalog.bundleURL(inProject: project)
            .appendingPathComponent("sequence.fasta")
        let manifest = try NFCoreRunBundleStore.read(from: result.bundleURL)
        let recordedFASTA = try XCTUnwrap(manifest.params["fasta"])
        XCTAssertEqual(
            URL(fileURLWithPath: recordedFASTA).resolvingSymlinksInPath(),
            acquiredFASTA.resolvingSymlinksInPath()
        )
        XCTAssertNil(manifest.params["genome"], "the pipeline must not resolve the reference itself")

        let invocation = try XCTUnwrap(runner.invocations.first)
        XCTAssertTrue(invocation.arguments.contains("fasta=\(recordedFASTA)"))

        let item = try XCTUnwrap(operationCenter.items.first { $0.id == result.operationID })
        XCTAssertTrue(
            item.logEntries.map(\.message).contains {
                $0.contains(ViralReconReferenceCatalog.canonicalAccession)
            }
        )
    }

    func testServiceReusesAnAlreadyPresentReferenceWithoutDownloading() async throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("viral-recon-reuse-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let request = try ViralReconAppTestFixtures.illuminaRequest(root: temp)
        let project = temp.appendingPathComponent("Project", isDirectory: true)
        let bundle = ViralReconReferenceCatalog.bundleURL(inProject: project)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let presentFASTA = bundle.appendingPathComponent("sequence.fasta")
        try ">\(ViralReconReferenceCatalog.canonicalAccession) SARS-CoV-2\nACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGT\n"
            .write(to: presentFASTA, atomically: true, encoding: .utf8)
        let expectedFASTA = presentFASTA

        let runner = StubViralReconProcessRunner(
            result: .init(exitCode: 0, standardOutput: "", standardError: "")
        )
        let service = ViralReconWorkflowExecutionService(
            operationCenter: OperationCenter(),
            processRunner: runner,
            referenceDownloader: { _, _ in XCTFail("must not download an already present reference") }
        )

        let result = try await service.run(
            request,
            bundleRoot: temp.appendingPathComponent("Analyses", isDirectory: true),
            projectURL: project
        )

        let manifest = try NFCoreRunBundleStore.read(from: result.bundleURL)
        let recordedFASTA = try XCTUnwrap(manifest.params["fasta"])
        XCTAssertEqual(
            URL(fileURLWithPath: recordedFASTA).resolvingSymlinksInPath(),
            expectedFASTA.resolvingSymlinksInPath()
        )
    }

    // The wizard stages only the BED when the reference is not on disk yet, so
    // the launch path has to cut the primer sequences once it has one.
    func testServiceDerivesTheDeferredPrimerFASTAAfterAcquiringTheReference() async throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("viral-recon-deferred-primers-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let request = try ViralReconAppTestFixtures.illuminaRequest(root: temp)
        // The wizard leaves no primers.fasta behind when it could not derive one.
        try FileManager.default.removeItem(at: request.primer.fastaURL)
        try "MN908947.3\t0\t4\tSARS2_1_LEFT\t1\t+\nMN908947.3\t4\t8\tSARS2_1_RIGHT\t1\t-\n"
            .write(to: request.primer.bedURL, atomically: true, encoding: .utf8)
        try """
        {
          "schema_version": 1,
          "name": "qiaseq-direct-sars2",
          "display_name": "QIASeq DIRECT SARS-CoV-2",
          "description": "Viral Recon test fixture",
          "organism": "SARS-CoV-2",
          "reference_accessions": [
            { "accession": "MN908947.3", "canonical": true }
          ],
          "primer_count": 2,
          "amplicon_count": 1
        }
        """.write(
            to: request.primer.bundleURL.appendingPathComponent("manifest.json"),
            atomically: true,
            encoding: .utf8
        )
        try "Test primer scheme\n".write(
            to: request.primer.bundleURL.appendingPathComponent("PROVENANCE.md"),
            atomically: true,
            encoding: .utf8
        )

        let project = temp.appendingPathComponent("Project", isDirectory: true)
        let bundle = ViralReconReferenceCatalog.bundleURL(inProject: project)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try ">\(ViralReconReferenceCatalog.canonicalAccession) SARS-CoV-2\nAAAACCCCGGGGTTTT\n"
            .write(
                to: bundle.appendingPathComponent("sequence.fasta"),
                atomically: true,
                encoding: .utf8
            )

        let service = ViralReconWorkflowExecutionService(
            operationCenter: OperationCenter(),
            processRunner: StubViralReconProcessRunner(
                result: .init(exitCode: 0, standardOutput: "", standardError: "")
            ),
            referenceDownloader: { _, _ in XCTFail("reference is already present") }
        )

        let result = try await service.run(
            request,
            bundleRoot: temp.appendingPathComponent("Analyses", isDirectory: true),
            projectURL: project
        )

        let persistedPrimerFASTA = result.bundleURL.appendingPathComponent("inputs/primers/primers.fasta")
        XCTAssertTrue(FileManager.default.fileExists(atPath: persistedPrimerFASTA.path))
        let staged = try String(contentsOf: persistedPrimerFASTA, encoding: .utf8)
        XCTAssertTrue(staged.contains(">SARS2_1_LEFT\nAAAA"), staged)
        XCTAssertTrue(staged.contains(">SARS2_1_RIGHT\nGGGG"), staged)
    }

    func testServiceAllocatesUniqueBundleNames() async throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("viral-recon-service-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let request = try ViralReconAppTestFixtures.illuminaRequest(root: temp)
        let analyses = temp.appendingPathComponent("Analyses", isDirectory: true)
        try FileManager.default.createDirectory(
            at: analyses.appendingPathComponent("viralrecon.lungfishrun", isDirectory: true),
            withIntermediateDirectories: true
        )
        let operationCenter = OperationCenter()
        let service = ViralReconWorkflowExecutionService(
            operationCenter: operationCenter,
            processRunner: StubViralReconProcessRunner(result: .init(exitCode: 0, standardOutput: "", standardError: ""))
        )

        let result = try await service.run(request, bundleRoot: analyses)

        XCTAssertEqual(result.bundleURL.lastPathComponent, "viralrecon-2.lungfishrun")
    }

    func testServicePersistsNanoporeInputsAndUsesPersistedPaths() async throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("viral-recon-service-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let request = try ViralReconAppTestFixtures.nanoporeRequest(root: temp)
        let runner = StubViralReconProcessRunner(result: .init(exitCode: 0, standardOutput: "", standardError: ""))
        let service = ViralReconWorkflowExecutionService(
            operationCenter: OperationCenter(),
            processRunner: runner
        )

        let result = try await service.run(
            request,
            bundleRoot: temp.appendingPathComponent("Analyses", isDirectory: true)
        )

        let persistedFastqPass = result.bundleURL.appendingPathComponent("inputs/nanopore/fastq_pass", isDirectory: true)
        let persistedSummary = result.bundleURL.appendingPathComponent("inputs/nanopore/sequencing_summary.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: persistedFastqPass.appendingPathComponent("barcode01/reads.fastq").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: persistedSummary.path))

        let invocation = try XCTUnwrap(runner.invocations.first)
        XCTAssertTrue(invocation.arguments.contains("fastq_dir=\(persistedFastqPass.path)"))
        XCTAssertTrue(invocation.arguments.contains("sequencing_summary=\(persistedSummary.path)"))
        XCTAssertFalse(invocation.arguments.contains("fastq_dir=\(try XCTUnwrap(request.fastqPassDirectoryURL).path)"))

        let manifest = try NFCoreRunBundleStore.read(from: result.bundleURL)
        XCTAssertEqual(manifest.params["fastq_dir"], persistedFastqPass.path)
        XCTAssertEqual(manifest.params["sequencing_summary"], persistedSummary.path)
    }

    func testCommandPreviewQuotesShellMetacharactersWithoutWhitespace() async throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("viral&recon'\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let request = try ViralReconAppTestFixtures.illuminaRequest(root: temp)
        let operationCenter = OperationCenter()
        let service = ViralReconWorkflowExecutionService(
            operationCenter: operationCenter,
            processRunner: StubViralReconProcessRunner(result: .init(exitCode: 0, standardOutput: "", standardError: ""))
        )

        let result = try await service.run(
            request,
            bundleRoot: temp.appendingPathComponent("Analyses", isDirectory: true)
        )

        let item = try XCTUnwrap(operationCenter.items.first { $0.id == result.operationID })
        let command = try XCTUnwrap(item.cliCommand)
        let persistedSamplesheet = result.bundleURL.appendingPathComponent("inputs/samplesheet.csv")
        XCTAssertTrue(command.contains("'\(shellEscapedInner(persistedSamplesheet.path))'"))
        XCTAssertFalse(command.contains(" --input \(persistedSamplesheet.path)"))
    }

    func testCommandPreviewQuotesEmptyArguments() {
        XCTAssertEqual(
            ViralReconWorkflowCommandPreview.build(
                executableName: "lungfish-cli",
                arguments: ["workflow", ""]
            ),
            "lungfish-cli workflow ''"
        )
    }

    func testServiceDoesNotDuplicateProcessLinesWhenRunnerStreamsAndReturnsOutput() async throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("viral-recon-service-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let request = try ViralReconAppTestFixtures.illuminaRequest(root: temp)
        let operationCenter = OperationCenter()
        let runner = StreamingStubViralReconProcessRunner(result: .init(
            exitCode: 0,
            standardOutput: "streamed stdout\n",
            standardError: "streamed stderr\n"
        ))
        let service = ViralReconWorkflowExecutionService(operationCenter: operationCenter, processRunner: runner)

        let result = try await service.run(
            request,
            bundleRoot: temp.appendingPathComponent("Analyses", isDirectory: true)
        )

        let item = try XCTUnwrap(operationCenter.items.first { $0.id == result.operationID })
        XCTAssertEqual(item.logEntries.map(\.message).filter { $0 == "streamed stdout" }.count, 1)
        XCTAssertEqual(item.logEntries.map(\.message).filter { $0 == "streamed stderr" }.count, 1)
    }

    func testServiceDoesNotReplayReturnedOutputWhenResultReportsStreaming() async throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("viral-recon-service-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let request = try ViralReconAppTestFixtures.illuminaRequest(root: temp)
        let operationCenter = OperationCenter()
        let runner = StubViralReconProcessRunner(result: .init(
            exitCode: 0,
            standardOutput: "queued stdout\n",
            standardError: "queued stderr\n",
            didStreamOutput: true
        ))
        let service = ViralReconWorkflowExecutionService(operationCenter: operationCenter, processRunner: runner)

        let result = try await service.run(
            request,
            bundleRoot: temp.appendingPathComponent("Analyses", isDirectory: true)
        )

        let item = try XCTUnwrap(operationCenter.items.first { $0.id == result.operationID })
        let messages = item.logEntries.map { $0.message }
        XCTAssertFalse(messages.contains("queued stdout"))
        XCTAssertFalse(messages.contains("queued stderr"))
    }

    func testConcreteRunnerStreamsOutputBeforeProcessReturns() async throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("viral-recon-runner-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)

        let runner = ProcessViralReconWorkflowProcessRunner(executableURL: URL(fileURLWithPath: "/bin/sh"))
        var received: [ViralReconWorkflowProcessOutput] = []

        let task = Task {
            try await runner.runLungfishCLI(
                arguments: ["-c", "printf 'stdout-ready\\n'; printf 'stderr-ready\\n' >&2; sleep 3; printf 'stdout-done\\n'"],
                workingDirectory: temp,
                outputHandler: { output in
                    received.append(output)
                }
            )
        }

        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline
            && !(received.contains(.standardOutput("stdout-ready"))
                 && received.contains(.standardError("stderr-ready"))) {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(received.contains(.standardOutput("stdout-ready")))
        XCTAssertTrue(received.contains(.standardError("stderr-ready")))
        XCTAssertFalse(received.contains(.standardOutput("stdout-done")))
        let result = try await task.value
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.standardOutput.contains("stdout-ready"))
        XCTAssertTrue(result.standardOutput.contains("stdout-done"))
        XCTAssertTrue(result.standardError.contains("stderr-ready"))
        XCTAssertTrue(result.didStreamOutput)
    }

    func testConcreteRunnerUsesWorktreeCLIWhenNoExplicitExecutableIsProvided() async throws {
        let originalWorkingDirectory = FileManager.default.currentDirectoryPath
        let originalCLIPath = ProcessInfo.processInfo.environment["LUNGFISH_CLI_PATH"]
        defer {
            FileManager.default.changeCurrentDirectoryPath(originalWorkingDirectory)
            if let originalCLIPath {
                setenv("LUNGFISH_CLI_PATH", originalCLIPath, 1)
            } else {
                unsetenv("LUNGFISH_CLI_PATH")
            }
        }
        unsetenv("LUNGFISH_CLI_PATH")

        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("viral-recon-worktree-cli-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let packageRoot = temp.appendingPathComponent("repo", isDirectory: true)
        let sourceSubdirectory = packageRoot.appendingPathComponent("Sources/LungfishApp", isDirectory: true)
        let workingDirectory = temp.appendingPathComponent("run", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceSubdirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        try Data("// swift-tools-version: 6.2\n".utf8)
            .write(to: packageRoot.appendingPathComponent("Package.swift"))
        let cliDirectory = try swiftPMBinPath(packageRoot: packageRoot)
        try FileManager.default.createDirectory(at: cliDirectory, withIntermediateDirectories: true)

        let fakeCLI = cliDirectory.appendingPathComponent("lungfish-cli")
        let script = """
        #!/bin/sh
        printf 'worktree-cli:%s\\n' "$*"
        """
        try script.write(to: fakeCLI, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCLI.path)

        XCTAssertTrue(FileManager.default.changeCurrentDirectoryPath(sourceSubdirectory.path))
        let runner = ProcessViralReconWorkflowProcessRunner()

        let result = try await runner.runLungfishCLI(
            arguments: ["--version"],
            workingDirectory: workingDirectory,
            outputHandler: nil
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.standardOutput.contains("worktree-cli:--version"))
        XCTAssertEqual(result.standardError, "")
    }

    func testConcreteRunnerCancelTerminatesProcessTree() async throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("viral-recon-cancel-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)

        let fakeCLI = temp.appendingPathComponent("lungfish-cli")
        let readyURL = temp.appendingPathComponent("ready")
        let rootPIDURL = temp.appendingPathComponent("root.pid")
        let childPIDURL = temp.appendingPathComponent("child.pid")
        let script = """
        #!/bin/sh
        echo $$ > '\(rootPIDURL.path)'
        /bin/sh -c 'trap "" TERM HUP; sleep 3 & wait' &
        child=$!
        echo "$child" > '\(childPIDURL.path)'
        touch '\(readyURL.path)'
        wait "$child"
        """
        try script.write(to: fakeCLI, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCLI.path)

        let runner = ProcessViralReconWorkflowProcessRunner(executableURL: fakeCLI)
        let runTask = Task {
            try await runner.runLungfishCLI(
                arguments: [],
                workingDirectory: temp,
                outputHandler: nil
            )
        }

        try await waitForFile(readyURL)
        let rootPID = try readPID(rootPIDURL)
        let childPID = try readPID(childPIDURL)
        defer {
            ProcessTreeTerminator.terminate(rootPID: rootPID, gracePeriod: 0)
            ProcessTreeTerminator.terminate(rootPID: childPID, gracePeriod: 0)
        }

        let cancelStart = Date()
        runner.cancel()
        let cancelReturnElapsed = Date().timeIntervalSince(cancelStart)
        XCTAssertLessThan(cancelReturnElapsed, 0.25, "ViralRecon cancel() should only request process-tree termination")
        try await waitForProcessExit(pid: childPID)
        _ = try await runTask.value

        XCTAssertFalse(ProcessTreeTerminator.processExists(pid: rootPID), "ViralRecon root process should exit after cancellation")
    }

    func testOperationCenterCancelCallbackCancelsViralReconRunner() async throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("viral-recon-service-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let request = try ViralReconAppTestFixtures.illuminaRequest(root: temp)
        let operationCenter = OperationCenter()
        let runner = CancelRecordingViralReconProcessRunner()
        runner.onRun = {
            guard let operationID = operationCenter.items.first?.id else {
                XCTFail("Expected Viral Recon operation to be registered before process launch")
                return
            }
            operationCenter.cancel(id: operationID)
        }
        let service = ViralReconWorkflowExecutionService(operationCenter: operationCenter, processRunner: runner)

        let result = try await service.run(
            request,
            bundleRoot: temp.appendingPathComponent("Analyses", isDirectory: true)
        )

        XCTAssertEqual(result.operationItem?.state, .cancelled)
        try await waitUntil(timeout: 10) {
            runner.cancelCallCount == 1
        }
    }

    func testViralReconProcessRunnerCancelTerminatesCurrentProcessTreeSource() throws {
        let source = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishApp/Services/ViralReconWorkflowExecutionService.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("func cancel()"))
        let processRunnerSource = try XCTUnwrap(
            source.range(of: "ProcessViralReconWorkflowProcessRunner: ViralReconWorkflowProcessRunning")
        )
        let cancelBody = try functionBody(
            named: "cancel",
            in: String(source[processRunnerSource.lowerBound...])
        )

        XCTAssertTrue(cancelBody.contains("requestProcessTreeTermination(gracePeriod: 0)"))
    }

    private func swiftPMBinPath(packageRoot: URL) throws -> URL {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "swift",
            "build",
            "--package-path", packageRoot.path,
            "--show-bin-path",
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(fileURLWithPath: try XCTUnwrap(output), isDirectory: true)
    }
}

private func writeGzipFixture(_ content: String, to gzipURL: URL) throws {
    let sourceURL = gzipURL.deletingLastPathComponent()
        .appendingPathComponent("reference-source-\(UUID().uuidString).fa")
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
            domain: "ViralReconWorkflowExecutionServiceTests.GzipFixture",
            code: Int(process.terminationStatus),
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
    try compressed.write(to: gzipURL)
}

final class PipelineCancelCallbackRegressionTests: XCTestCase {
    /// `runManagedMapping` is checked separately from the other three start
    /// sites below (C2's per-bundle sequential fan-out, commits
    /// acd77b57/f652209f/e512e1d5): it no longer captures its own `task` and
    /// calls `task.cancel()` inline in the cancel callback. Instead it
    /// assigns the batch `Task` to a `MappingBatchTaskHandle` actor and the
    /// cancel callback calls `taskHandle.cancel()`, which the actor forwards
    /// to the stored task's `.cancel()` -- see `MappingBatchTaskHandle`'s doc
    /// comment for why the indirection exists (a cancel-before-assign race
    /// between the per-bundle cancel callback and the outer `Task.detached`
    /// literal still finishing construction). `MappingBatchTaskHandleTests`
    /// separately proves `taskHandle.cancel()` genuinely cancels the
    /// assigned task in every race ordering, so this test only needs to
    /// confirm `runManagedMapping` still wires the handle-based callback
    /// in (not that the handle itself works).
    func testAppDelegateLongRunningPipelineStartSitesInstallCancelCallbacks() throws {
        let source = try appDelegateSource()
        for functionName in [
            "runSequenceAnnotationOperation",
            "runMinimap2Mapping",
            "runOrientReads",
        ] {
            let body = try functionBody(named: functionName, in: source)
            XCTAssertTrue(
                body.contains("let task = Task.detached"),
                "\(functionName) should keep the detached task handle for cancellation"
            )
            XCTAssertTrue(
                body.contains("OperationCenter.shared.setCancelCallback(for: opID)"),
                "\(functionName) should wire OperationCenter cancellation"
            )
            XCTAssertTrue(
                body.contains("task.cancel()"),
                "\(functionName) cancel callback should cancel the detached task"
            )
        }

        let managedMappingBody = try functionBody(named: "runManagedMapping", in: source)
        XCTAssertTrue(
            managedMappingBody.contains("let taskHandle = MappingBatchTaskHandle()"),
            "runManagedMapping should create a MappingBatchTaskHandle to own the batch task's cancellation"
        )
        XCTAssertTrue(
            managedMappingBody.contains("let task = Task.detached"),
            "runManagedMapping should keep the detached batch task handle for cancellation"
        )
        XCTAssertTrue(
            managedMappingBody.contains("taskHandle.assign(task)"),
            "runManagedMapping should assign its batch task to the handle so cancel callbacks can reach it"
        )
        XCTAssertTrue(
            managedMappingBody.contains("OperationCenter.shared.setCancelCallback(for: opID)"),
            "runManagedMapping should wire OperationCenter cancellation for each per-bundle operation"
        )
        XCTAssertTrue(
            managedMappingBody.contains("taskHandle.cancel()"),
            "runManagedMapping's cancel callback should cancel the batch task via the handle"
        )

        let handleSource = try functionBody(
            named: "cancelStoredTask",
            in: try String(contentsOf: appDelegateSourceDirectory().appendingPathComponent("AppDelegate+ToolsMenu.swift"), encoding: .utf8)
        )
        XCTAssertTrue(
            handleSource.contains("task?.cancel()"),
            "MappingBatchTaskHandle.cancelStoredTask must actually cancel the stored task, closing the loop from runManagedMapping's callback"
        )

        let sequenceBody = try functionBody(named: "runSequenceAnnotationOperation", in: source)
        XCTAssertTrue(sequenceBody.contains("LungfishCLIRunner.CancellationHandle()"))
        XCTAssertTrue(sequenceBody.contains("cancellation: cliCancellation"))
        XCTAssertTrue(sequenceBody.contains("cliCancellation.cancel()"))
    }

    func testMAFFTStartSiteCancelsDetachedTaskAndRunnerProcess() throws {
        let body = try functionBody(named: "runMAFFTAlignment", in: appDelegateSource())

        XCTAssertTrue(body.contains("let runner = CLIMSAAlignmentRunner()"))
        XCTAssertTrue(body.contains("let task = Task.detached"))
        XCTAssertTrue(body.contains("try await runner.run("))
        XCTAssertTrue(body.contains("OperationCenter.shared.setCancelCallback(for: opID)"))
        XCTAssertTrue(body.contains("task.cancel()"))
        XCTAssertTrue(body.contains("runner.cancel()"))
    }
}

@MainActor
/// Records downloader calls from a `@Sendable` closure without touching the
/// main actor, which the acquisition step runs off.
private final class DownloadRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    func record(_ accession: String) {
        lock.withLock { recorded.append(accession) }
    }

    var accessions: [String] {
        lock.withLock { recorded }
    }
}

private final class StubViralReconProcessRunner: ViralReconWorkflowProcessRunning {
    struct Invocation: Equatable {
        let arguments: [String]
        let workingDirectory: URL
    }

    private(set) var invocations: [Invocation] = []
    let result: ViralReconWorkflowProcessResult
    var onRun: (() throws -> Void)?

    init(result: ViralReconWorkflowProcessResult) {
        self.result = result
    }

    func runLungfishCLI(
        arguments: [String],
        workingDirectory: URL,
        outputHandler: (@MainActor @Sendable (ViralReconWorkflowProcessOutput) -> Void)?
    ) async throws -> ViralReconWorkflowProcessResult {
        invocations.append(Invocation(arguments: arguments, workingDirectory: workingDirectory))
        try onRun?()
        return result
    }

    func cancel() {}
}

@MainActor
private final class StreamingStubViralReconProcessRunner: ViralReconWorkflowProcessRunning {
    let result: ViralReconWorkflowProcessResult

    init(result: ViralReconWorkflowProcessResult) {
        self.result = result
    }

    func runLungfishCLI(
        arguments: [String],
        workingDirectory: URL,
        outputHandler: (@MainActor @Sendable (ViralReconWorkflowProcessOutput) -> Void)?
    ) async throws -> ViralReconWorkflowProcessResult {
        outputHandler?(.standardOutput("streamed stdout"))
        outputHandler?(.standardError("streamed stderr"))
        return ViralReconWorkflowProcessResult(
            exitCode: result.exitCode,
            standardOutput: result.standardOutput,
            standardError: result.standardError,
            didStreamOutput: outputHandler != nil
        )
    }

    func cancel() {}
}

@MainActor
private final class CancelRecordingViralReconProcessRunner: ViralReconWorkflowProcessRunning {
    private(set) var cancelCallCount = 0
    var onRun: (() -> Void)?

    func runLungfishCLI(
        arguments: [String],
        workingDirectory: URL,
        outputHandler: (@MainActor @Sendable (ViralReconWorkflowProcessOutput) -> Void)?
    ) async throws -> ViralReconWorkflowProcessResult {
        onRun?()
        return ViralReconWorkflowProcessResult(
            exitCode: 0,
            standardOutput: "cancelled",
            standardError: "",
            didStreamOutput: false
        )
    }

    func cancel() {
        cancelCallCount += 1
    }
}

private func shellEscapedInner(_ value: String) -> String {
    value.replacingOccurrences(of: "'", with: "'\\''")
}

private func repositoryRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

private func appDelegateSource() throws -> String {
    combinedAppDelegateSource()
}

private func functionBody(named name: String, in source: String) throws -> String {
    let signature = "func \(name)"
    let signatureRange = try XCTUnwrap(source.range(of: signature), "Missing \(signature)")
    let openBrace = try XCTUnwrap(
        source[signatureRange.lowerBound...].firstIndex(of: "{"),
        "Missing opening brace for \(signature)"
    )
    var depth = 0
    var index = openBrace
    while index < source.endIndex {
        switch source[index] {
        case "{":
            depth += 1
        case "}":
            depth -= 1
            if depth == 0 {
                return String(source[openBrace...index])
            }
        default:
            break
        }
        index = source.index(after: index)
    }
    XCTFail("Missing closing brace for \(signature)")
    return ""
}

private func waitForFile(_ url: URL, timeout: TimeInterval = 10) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if FileManager.default.fileExists(atPath: url.path) {
            return
        }
        try await Task.sleep(nanoseconds: 25_000_000)
    }
    XCTFail("Timed out waiting for \(url.path)")
}

@MainActor
private func waitUntil(
    timeout: TimeInterval,
    condition: @escaping () -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() {
            return
        }
        try await Task.sleep(nanoseconds: 25_000_000)
    }
    XCTFail("Timed out waiting for condition")
}

private func waitForProcessExit(pid: Int32, timeout: TimeInterval = 10) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if !ProcessTreeTerminator.processExists(pid: pid) {
            return
        }
        try await Task.sleep(nanoseconds: 25_000_000)
    }
    XCTFail("Process \(pid) was still running after cancellation")
}

private func readPID(_ url: URL) throws -> Int32 {
    let text = try String(contentsOf: url, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return try XCTUnwrap(Int32(text), "Expected pid in \(url.path)")
}

private final class IngestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URL] = []

    var directories: [URL] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    func record(_ url: URL) {
        lock.lock(); defer { lock.unlock() }
        storage.append(url)
    }
}
