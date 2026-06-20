import XCTest
import LungfishIO
import LungfishWorkflow
@testable import LungfishApp
import LungfishKit

@MainActor
final class WorkflowOperationExecutionServiceTests: XCTestCase {
    func testONTGenotypingRunsThroughRetainedDemuxCLIAndReportsWorkbookOutput() async throws {
        let temp = try temporaryDirectory()
        let readsURL = temp.appendingPathComponent("reads.lungfishfastq", isDirectory: true)
        let referenceURL = temp.appendingPathComponent("ref.lungfishref", isDirectory: true)
        let barcodesURL = temp.appendingPathComponent("barcodes.csv")
        let outputURL = temp.appendingPathComponent("Analyses/reads-ont.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: readsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: referenceURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
        try Data("sample,barcode\nDW472,ACGT\n".utf8).write(to: barcodesURL)
        let request = ONTBarcodeDemuxGenotypingRunRequest(
            inputFASTQURL: readsURL,
            referenceSourceURL: referenceURL,
            barcodeDefinitionsURL: barcodesURL,
            outputDirectory: outputURL,
            outputName: "reads-ont",
            analysisName: "ONT08",
            projectURL: temp,
            threads: 4,
            minSupport: 2
        )
        let operationCenter = OperationCenter()
        let runner = StubWorkflowOperationCLIProcessRunner()
        let viewerBundlePreparer = StubWorkflowOperationViewerBundlePreparer()
        let bamImporter = StubWorkflowOperationBAMImporter()
        let resultRefresher = StubWorkflowOperationResultRefresher()
        let service = WorkflowOperationExecutionService(
            operationCenter: operationCenter,
            processRunner: runner,
            viewerBundlePreparer: viewerBundlePreparer,
            bamImporter: bamImporter,
            resultRefresher: resultRefresher
        )

        let outputs = try await service.run(.ontGenotyping(request))

        let invocation = try XCTUnwrap(runner.invocations.first)
        XCTAssertEqual(invocation.arguments.prefix(2), ["fastq", "genotype"])
        XCTAssertEqual(try testValue(after: "--mode", in: invocation.arguments), "ont-barcode-demux")
        XCTAssertEqual(try testValue(after: "--read-type", in: invocation.arguments), "ont")
        XCTAssertTrue(invocation.arguments.contains(readsURL.standardizedFileURL.path))
        XCTAssertTrue(invocation.arguments.contains("--reference"))
        XCTAssertTrue(invocation.arguments.contains(referenceURL.standardizedFileURL.path))
        XCTAssertTrue(invocation.arguments.contains("--barcodes"))
        XCTAssertTrue(invocation.arguments.contains(barcodesURL.standardizedFileURL.path))
        XCTAssertTrue(invocation.arguments.contains("--min-support"))
        XCTAssertTrue(invocation.arguments.contains("2"))
        XCTAssertEqual(invocation.workingDirectory, outputURL.standardizedFileURL)
        XCTAssertTrue(outputs.contains(request.workbookURL.standardizedFileURL))
        XCTAssertTrue(outputs.contains(request.reportCSVURL.standardizedFileURL))
        XCTAssertTrue(outputs.contains(request.sampleSummaryCSVURL.standardizedFileURL))
        XCTAssertTrue(outputs.contains(request.statsJSONURL.standardizedFileURL))
        XCTAssertTrue(outputs.contains(request.provenanceURL.standardizedFileURL))
        XCTAssertTrue(outputs.contains(request.outputDirectory.standardizedFileURL))
        XCTAssertFalse(outputs.contains(request.mappingBAMURL.standardizedFileURL))
        XCTAssertFalse(outputs.contains(request.retainedBAMURL.standardizedFileURL))
        XCTAssertTrue(viewerBundlePreparer.invocations.isEmpty)
        XCTAssertTrue(bamImporter.invocations.isEmpty)

        let item = try XCTUnwrap(operationCenter.items.first)
        XCTAssertEqual(item.title, "miSeq amplicon MHC genotyping")
        XCTAssertEqual(item.state, .completed)
        XCTAssertTrue(item.cliCommand?.contains("lungfish-cli fastq genotype") == true)
        XCTAssertTrue(item.outputURLs.contains(request.workbookURL.standardizedFileURL))
        XCTAssertTrue(runner.didReceiveOutputHandler)
        XCTAssertEqual(
            resultRefresher.invocations,
            [request.outputDirectory.standardizedFileURL]
        )
    }

    func testFullLengthONTMHCGenotypingRunsCLIWithSavontAndPrimerArguments() async throws {
        let temp = try temporaryDirectory()
        let readsURL = temp.appendingPathComponent("NB13.lungfishfastq", isDirectory: true)
        let referenceURL = temp.appendingPathComponent("Mamu-class-I.lungfishmhcref", isDirectory: true)
        let orientReferenceURL = temp.appendingPathComponent("MHC_class_I_orient.fasta")
        let forwardPrimerURL = temp.appendingPathComponent("MHC_class_I_F.fasta")
        let reversePrimerURL = temp.appendingPathComponent("MHC_class_I_R.fasta")
        let outputURL = temp.appendingPathComponent("Analyses/nb13-full-length.lungfishgenotype", isDirectory: true)
        for url in [readsURL, referenceURL, outputURL] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        for url in [orientReferenceURL, forwardPrimerURL, reversePrimerURL] {
            try ">x\nACGT\n".write(to: url, atomically: true, encoding: .utf8)
        }
        let request = FullLengthONTMHCGenotypingRunRequest(
            inputFASTQURLs: [readsURL],
            referenceSourceURL: referenceURL,
            orientReferenceURL: orientReferenceURL,
            forwardPrimerURL: forwardPrimerURL,
            reversePrimerURL: reversePrimerURL,
            outputDirectory: outputURL,
            outputName: "nb13-full-length",
            projectURL: temp,
            threads: 8,
            minimumLength: 2000,
            maximumLength: 4000
        )
        let operationCenter = OperationCenter()
        let runner = StubWorkflowOperationCLIProcessRunner()
        let resultRefresher = StubWorkflowOperationResultRefresher()
        let service = WorkflowOperationExecutionService(
            operationCenter: operationCenter,
            processRunner: runner,
            viewerBundlePreparer: StubWorkflowOperationViewerBundlePreparer(),
            bamImporter: StubWorkflowOperationBAMImporter(),
            resultRefresher: resultRefresher
        )

        let outputs = try await service.run(.fullLengthONTMHCGenotyping(request))

        let invocation = try XCTUnwrap(runner.invocations.first)
        XCTAssertEqual(invocation.arguments.prefix(2), ["fastq", "full-length-ont-mhc-genotype"])
        XCTAssertTrue(invocation.arguments.contains(readsURL.standardizedFileURL.path))
        XCTAssertEqual(try testValue(after: "--reference", in: invocation.arguments), referenceURL.standardizedFileURL.path)
        XCTAssertFalse(invocation.arguments.contains("--guide"))
        XCTAssertFalse(invocation.arguments.contains { $0.contains("pbaa") || $0.contains("pbAA") })
        XCTAssertEqual(try testValue(after: "--orient-reference", in: invocation.arguments), orientReferenceURL.standardizedFileURL.path)
        XCTAssertEqual(try testValue(after: "--forward-primer", in: invocation.arguments), forwardPrimerURL.standardizedFileURL.path)
        XCTAssertEqual(try testValue(after: "--reverse-primer", in: invocation.arguments), reversePrimerURL.standardizedFileURL.path)
        XCTAssertEqual(try testValue(after: "--min-length", in: invocation.arguments), "2000")
        XCTAssertEqual(try testValue(after: "--max-length", in: invocation.arguments), "4000")
        XCTAssertEqual(try testValue(after: "--savont-quality-value-cutoff", in: invocation.arguments), "90")
        XCTAssertEqual(try testValue(after: "--savont-min-cluster-size", in: invocation.arguments), "3")
        XCTAssertEqual(try testValue(after: "--threads", in: invocation.arguments), "8")
        XCTAssertEqual(invocation.workingDirectory, outputURL.standardizedFileURL)
        XCTAssertTrue(outputs.contains(request.workbookURL.standardizedFileURL))
        XCTAssertTrue(outputs.contains(request.currentWorkbookURL.standardizedFileURL))
        XCTAssertTrue(outputs.contains(request.reportCSVURL.standardizedFileURL))
        XCTAssertTrue(outputs.contains(request.sampleSummaryCSVURL.standardizedFileURL))
        XCTAssertTrue(outputs.contains(request.statsJSONURL.standardizedFileURL))
        XCTAssertTrue(outputs.contains(request.provenanceURL.standardizedFileURL))
        XCTAssertTrue(outputs.contains(request.outputDirectory.standardizedFileURL))

        let item = try XCTUnwrap(operationCenter.items.first)
        XCTAssertEqual(item.title, "Full-length ONT MHC genotyping")
        XCTAssertEqual(item.state, .completed)
        XCTAssertTrue(item.cliCommand?.contains("lungfish-cli fastq full-length-ont-mhc-genotype") == true)
        XCTAssertEqual(resultRefresher.invocations, [request.outputDirectory.standardizedFileURL])
    }

    func testFullLengthONTMHCGenotypingDoesNotPassPBAAClusterSourceModeToCLI() throws {
        let temp = try temporaryDirectory()
        let request = FullLengthONTMHCGenotypingRunRequest(
            inputFASTQURLs: [temp.appendingPathComponent("NB13.lungfishfastq", isDirectory: true)],
            referenceSourceURL: temp.appendingPathComponent("Mamu-class-I.lungfishmhcref", isDirectory: true),
            outputDirectory: temp.appendingPathComponent("Analyses/nb13-full-length.lungfishgenotype", isDirectory: true),
            outputName: "nb13-full-length"
        )

        let arguments = WorkflowOperationExecutionService().fullLengthONTMHCGenotypingArguments(for: request)

        XCTAssertFalse(arguments.contains("--pbaa-cluster-source"))
        XCTAssertFalse(arguments.contains("--guide"))
    }

    func testFullLengthONTMHCGenotypingPassesHaplotypeArgumentsToCLI() throws {
        let temp = try temporaryDirectory()
        let request = FullLengthONTMHCGenotypingRunRequest(
            inputFASTQURLs: [temp.appendingPathComponent("NB13.lungfishfastq", isDirectory: true)],
            referenceSourceURL: temp.appendingPathComponent("Mamu-class-I.lungfishmhcref", isDirectory: true),
            outputDirectory: temp.appendingPathComponent("Analyses/nb13-full-length.lungfishgenotype", isDirectory: true),
            outputName: "nb13-full-length",
            haplotypeDropoutLocusFraction: 0.12,
            haplotypeAssayID: "MHC-full-length-ONT",
            haplotypeSpeciesCode: "MAMU",
            haplotypeDefinitionScope: .project,
            haplotypeDefinitionSetID: "MHC-full-length-ONT.mamu"
        )

        let arguments = WorkflowOperationExecutionService().fullLengthONTMHCGenotypingArguments(for: request)

        XCTAssertEqual(try testValue(after: "--haplotype-min-locus-percent", in: arguments), "12")
        XCTAssertEqual(try testValue(after: "--haplotype-assay", in: arguments), "MHC-full-length-ONT")
        XCTAssertEqual(try testValue(after: "--haplotype-species", in: arguments), "MAMU")
        XCTAssertEqual(try testValue(after: "--haplotype-definition-scope", in: arguments), "project")
        XCTAssertEqual(try testValue(after: "--haplotype-definition", in: arguments), "MHC-full-length-ONT.mamu")
    }

    func testFullLengthONTMHCGenotypingPassesCheckpointArgumentsToCLI() throws {
        let temp = try temporaryDirectory()
        let request = FullLengthONTMHCGenotypingRunRequest(
            inputFASTQURLs: [temp.appendingPathComponent("NB13.lungfishfastq", isDirectory: true)],
            referenceSourceURL: temp.appendingPathComponent("Mamu-class-I.lungfishmhcref", isDirectory: true),
            outputDirectory: temp.appendingPathComponent("Analyses/nb13-full-length.lungfishgenotype", isDirectory: true),
            outputName: "nb13-full-length",
            keepIntermediates: true,
            reuseCompatibleCheckpoints: true
        )

        let arguments = WorkflowOperationExecutionService().fullLengthONTMHCGenotypingArguments(for: request)

        XCTAssertTrue(arguments.contains("--keep-intermediates"))
        XCTAssertTrue(arguments.contains("--reuse-compatible-checkpoints"))
    }

    func testONTGenotypingFailureReportsCLIExitStatusAndStderr() async throws {
        let temp = try temporaryDirectory()
        let request = try makeONTGenotypingRequest(temp: temp)
        let operationCenter = OperationCenter()
        let runner = StubWorkflowOperationCLIProcessRunner(
            exitCode: 5,
            stderr: """
            [ 45%] Mapping ONT reads with minimap2.
            LungfishWorkflow/resource_bundle_accessor.swift:12: Fatal error: could not load resource bundle
            """
        )
        let service = WorkflowOperationExecutionService(
            operationCenter: operationCenter,
            processRunner: runner,
            viewerBundlePreparer: StubWorkflowOperationViewerBundlePreparer(),
            bamImporter: StubWorkflowOperationBAMImporter(),
            resultRefresher: StubWorkflowOperationResultRefresher()
        )

        do {
            _ = try await service.run(.ontGenotyping(request))
            XCTFail("Expected amplicon genotyping failure")
        } catch LocalWorkflowExecutionError.nonZeroExit(let status) {
            XCTAssertEqual(status, 5)
        }

        let item = try XCTUnwrap(operationCenter.items.first)
        XCTAssertEqual(item.state, .failed)
        XCTAssertEqual(item.progress, 0.45, accuracy: 0.001)
        XCTAssertEqual(item.detail, "miSeq amplicon MHC genotyping failed with exit code 5")
        XCTAssertEqual(item.errorMessage, "miSeq amplicon MHC genotyping failed")
        XCTAssertTrue(item.errorDetail?.contains("exit code 5") == true)
        XCTAssertTrue(item.errorDetail?.contains("could not load resource bundle") == true)
        XCTAssertTrue(item.logEntries.contains { $0.message == "Mapping ONT reads with minimap2." })
        XCTAssertTrue(item.logEntries.contains { $0.message.contains("could not load resource bundle") })
    }

    func testONTReadTypeForcesBarcodeDemuxModeWhenRequestModeIsAuto() throws {
        let temp = try temporaryDirectory()
        let readsURL = temp.appendingPathComponent("reads.lungfishfastq", isDirectory: true)
        let referenceURL = temp.appendingPathComponent("ref.lungfishref", isDirectory: true)
        let barcodesURL = temp.appendingPathComponent("barcodes.csv")
        let outputURL = temp.appendingPathComponent("Analyses/amplicon-genotyping.lungfishgenotype", isDirectory: true)

        let request = ONTBarcodeDemuxGenotypingRunRequest(
            inputFASTQURLs: [readsURL],
            referenceSourceURL: referenceURL,
            barcodeDefinitionsURL: barcodesURL,
            outputDirectory: outputURL,
            outputName: "amplicon-genotyping",
            mode: .auto,
            readType: .ont
        )
        let arguments = WorkflowOperationExecutionService().ontGenotypingArguments(for: request)

        XCTAssertEqual(try testValue(after: "--mode", in: arguments), "ont-barcode-demux")
        XCTAssertEqual(try testValue(after: "--read-type", in: arguments), "ont")
    }

    func testIlluminaReadTypeForcesCohortModeWhenRequestModeIsAuto() throws {
        let temp = try temporaryDirectory()
        let first = temp.appendingPathComponent("dw001.lungfishfastq", isDirectory: true)
        let second = temp.appendingPathComponent("dw002.lungfishfastq", isDirectory: true)
        let referenceURL = temp.appendingPathComponent("ref.lungfishref", isDirectory: true)
        let outputURL = temp.appendingPathComponent("Analyses/amplicon-genotyping.lungfishgenotype", isDirectory: true)

        let request = ONTBarcodeDemuxGenotypingRunRequest(
            inputFASTQURLs: [first, second],
            referenceSourceURL: referenceURL,
            outputDirectory: outputURL,
            outputName: "amplicon-genotyping",
            mode: .auto,
            readType: .illumina
        )
        let arguments = WorkflowOperationExecutionService().ontGenotypingArguments(for: request)

        XCTAssertEqual(arguments.prefix(2), ["fastq", "genotype-cohort"])
        XCTAssertEqual(try testValue(after: "--mode", in: arguments), "illumina-paired")
        XCTAssertEqual(try testValue(after: "--read-type", in: arguments), "illumina")
    }

    func testONTSampleBundleModeUsesCohortSubcommandWithoutBarcodes() throws {
        let temp = try temporaryDirectory()
        let first = temp.appendingPathComponent("lf2871.lungfishfastq", isDirectory: true)
        let second = temp.appendingPathComponent("lf2872.lungfishfastq", isDirectory: true)
        let referenceURL = temp.appendingPathComponent("ref.lungfishref", isDirectory: true)
        let outputURL = temp.appendingPathComponent("Analyses/amplicon-genotyping.lungfishgenotype", isDirectory: true)

        let request = ONTBarcodeDemuxGenotypingRunRequest(
            inputFASTQURLs: [first, second],
            referenceSourceURL: referenceURL,
            outputDirectory: outputURL,
            outputName: "amplicon-genotyping",
            mode: .ontSampleBundles,
            readType: .ont
        )
        let arguments = WorkflowOperationExecutionService().ontGenotypingArguments(for: request)

        XCTAssertEqual(arguments.prefix(2), ["fastq", "genotype-cohort"])
        XCTAssertEqual(try testValue(after: "--mode", in: arguments), "ont-sample-bundles")
        XCTAssertEqual(try testValue(after: "--read-type", in: arguments), "ont")
        XCTAssertFalse(arguments.contains("--barcodes"))
    }

    func testONTGenotypingDisambiguatesOccupiedOutputBundleNameAtRuntime() async throws {
        let temp = try temporaryDirectory()
        let request = try makeONTGenotypingRequest(temp: temp)
        try Data("previous run".utf8).write(
            to: request.outputDirectory.appendingPathComponent("manifest.json")
        )
        let operationCenter = OperationCenter()
        let runner = StubWorkflowOperationCLIProcessRunner()
        let resultRefresher = StubWorkflowOperationResultRefresher()
        let service = WorkflowOperationExecutionService(
            operationCenter: operationCenter,
            processRunner: runner,
            viewerBundlePreparer: StubWorkflowOperationViewerBundlePreparer(),
            bamImporter: StubWorkflowOperationBAMImporter(),
            resultRefresher: resultRefresher
        )

        _ = try await service.run(.ontGenotyping(request))

        let invocation = try XCTUnwrap(runner.invocations.first)
        XCTAssertEqual(try testValue(after: "--output-name", in: invocation.arguments), "reads-ont_1")
        XCTAssertEqual(try testValue(after: "--analysis-name", in: invocation.arguments), "ONT08_1")
        XCTAssertEqual(
            try testValue(after: "--output-dir", in: invocation.arguments),
            request.outputDirectory.deletingLastPathComponent()
                .appendingPathComponent("reads-ont_1.lungfishgenotype", isDirectory: true)
                .standardizedFileURL.path
        )
        XCTAssertEqual(
            resultRefresher.invocations,
            [
                request.outputDirectory.deletingLastPathComponent()
                    .appendingPathComponent("reads-ont_1.lungfishgenotype", isDirectory: true)
                    .standardizedFileURL
            ]
        )
    }

    func testONTGenotypingFailureAddsDemuxManifestHintWhenBarcodesWereProvided() async throws {
        let temp = try temporaryDirectory()
        let request = ONTBarcodeDemuxGenotypingRunRequest(
            inputFASTQURLs: [temp.appendingPathComponent("reads.lungfishfastq", isDirectory: true)],
            referenceSourceURL: temp.appendingPathComponent("ref.lungfishref", isDirectory: true),
            barcodeDefinitionsURL: temp.appendingPathComponent("ONT09_NB11_samples.csv"),
            outputDirectory: temp.appendingPathComponent("Analyses/amplicon-genotyping.lungfishgenotype", isDirectory: true),
            outputName: "amplicon-genotyping",
            mode: .auto,
            readType: .ont
        )
        let operationCenter = OperationCenter()
        let runner = StubWorkflowOperationCLIProcessRunner(
            exitCode: 1,
            stderr: "Error: Demultiplex manifest does not exist: /tmp/project/demux-manifest.json"
        )
        let service = WorkflowOperationExecutionService(
            operationCenter: operationCenter,
            processRunner: runner,
            viewerBundlePreparer: StubWorkflowOperationViewerBundlePreparer(),
            bamImporter: StubWorkflowOperationBAMImporter(),
            resultRefresher: StubWorkflowOperationResultRefresher()
        )

        do {
            _ = try await service.run(.ontGenotyping(request))
            XCTFail("Expected failure")
        } catch LocalWorkflowExecutionError.nonZeroExit(let status) {
            XCTAssertEqual(status, 1)
        }

        let item = try XCTUnwrap(operationCenter.items.first)
        XCTAssertTrue(item.errorDetail?.contains("Demultiplex manifest") == true)
        XCTAssertTrue(item.errorDetail?.contains("barcode CSV") == true)
        XCTAssertTrue(item.errorDetail?.contains("--mode ont-barcode-demux") == true)
    }

    func testTwelveSAmpliconMatchingRunsCLIAndReportsBundleOutput() async throws {
        let temp = try temporaryDirectory()
        let firstReadsURL = temp.appendingPathComponent("hilo-f09.lungfishfastq", isDirectory: true)
        let secondReadsURL = temp.appendingPathComponent("hilo-f10.lungfishfastq", isDirectory: true)
        let referenceURL = temp.appendingPathComponent("amplicons_12s.fa")
        let metadataURL = temp.appendingPathComponent("analysis-metadata.tsv")
        let outputURL = temp.appendingPathComponent("Analyses/12S amplicon results", isDirectory: true)
        for url in [firstReadsURL, secondReadsURL, outputURL] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        try Data(">target\nACGT\n".utf8).write(to: referenceURL)
        try Data("sample_id\tsite\nhilo-f09\tHilo WWTP\n".utf8).write(to: metadataURL)
        let configuration = TwelveSAmpliconMatchingConfiguration(
            inputFASTQs: [firstReadsURL, secondReadsURL],
            referenceFASTA: referenceURL,
            sampleMetadata: metadataURL,
            outputDirectory: outputURL,
            outputName: "hilo-12s",
            minimumSoftClipBases: 2,
            maximumIndelBases: 5,
            threads: 6,
            runChimeraReview: false,
            forceOverwrite: true
        )
        let operationCenter = OperationCenter()
        let runner = StubWorkflowOperationCLIProcessRunner(stderr: """
        [  2%] Validating 12S amplicon matching inputs.
        [ 12%] Loading 12S reference records.
        [ 40%] Matching reads to 12S references.
        [ 70%] Reviewing unresolved sequences for chimeras.
        [ 84%] Writing 12S result bundle tables.
        [ 94%] Writing reproducibility provenance.
        [100%] 12S amplicon matching complete.
        """)
        let resultRefresher = StubWorkflowOperationResultRefresher()
        let service = WorkflowOperationExecutionService(
            operationCenter: operationCenter,
            processRunner: runner,
            viewerBundlePreparer: StubWorkflowOperationViewerBundlePreparer(),
            bamImporter: StubWorkflowOperationBAMImporter(),
            resultRefresher: resultRefresher
        )

        let outputs = try await service.run(.twelveSAmpliconMatching(configuration))

        let invocation = try XCTUnwrap(runner.invocations.first)
        XCTAssertEqual(invocation.arguments.prefix(2), ["fastq", "12s-match"])
        XCTAssertEqual(try testValue(after: "--reference", in: invocation.arguments), referenceURL.standardizedFileURL.path)
        XCTAssertEqual(try testValue(after: "--sample-metadata", in: invocation.arguments), metadataURL.standardizedFileURL.path)
        XCTAssertEqual(try testValue(after: "--output-dir", in: invocation.arguments), outputURL.standardizedFileURL.path)
        XCTAssertEqual(try testValue(after: "--output-name", in: invocation.arguments), "hilo-12s")
        XCTAssertEqual(try testValue(after: "--min-soft-clip", in: invocation.arguments), "2")
        XCTAssertEqual(try testValue(after: "--max-indels", in: invocation.arguments), "5")
        XCTAssertEqual(try testValue(after: "--matching-mode", in: invocation.arguments), "illumina-exact")
        XCTAssertEqual(try testValue(after: "--threads", in: invocation.arguments), "6")
        XCTAssertTrue(invocation.arguments.contains(firstReadsURL.standardizedFileURL.path))
        XCTAssertTrue(invocation.arguments.contains(secondReadsURL.standardizedFileURL.path))
        XCTAssertTrue(invocation.arguments.contains("--no-chimera-review"))
        XCTAssertTrue(invocation.arguments.contains("--force"))
        XCTAssertEqual(invocation.workingDirectory, outputURL.standardizedFileURL)

        let bundleURL = outputURL.appendingPathComponent("hilo-12s.lungfish12s", isDirectory: true).standardizedFileURL
        XCTAssertTrue(outputs.contains(bundleURL))
        XCTAssertTrue(outputs.contains(bundleURL.appendingPathComponent("12s-result.json")))
        XCTAssertTrue(outputs.contains(bundleURL.appendingPathComponent(".lungfish-provenance.json")))

        let item = try XCTUnwrap(operationCenter.items.first)
        XCTAssertEqual(item.title, "12S Amplicon Matching")
        XCTAssertEqual(item.state, .completed)
        XCTAssertTrue(item.cliCommand?.contains("lungfish-cli fastq 12s-match") == true)
        XCTAssertTrue(item.outputURLs.contains(bundleURL))
        let operationLogMessages = item.logEntries.map(\.message)
        XCTAssertTrue(
            operationLogMessages.contains("Loading 12S reference records."),
            operationLogMessages.joined(separator: "\n")
        )
        XCTAssertTrue(
            operationLogMessages.contains("Matching reads to 12S references."),
            operationLogMessages.joined(separator: "\n")
        )
        XCTAssertTrue(
            operationLogMessages.contains("Writing reproducibility provenance."),
            operationLogMessages.joined(separator: "\n")
        )
        XCTAssertFalse(item.logEntries.contains { $0.message.contains("fake vsearch stderr") })
        XCTAssertEqual(resultRefresher.invocations, [bundleURL])
    }

    func testTwelveSAmpliconMatchingAcceptsCanonicalLungfishProvenanceToolName() async throws {
        let temp = try temporaryDirectory()
        let readsURL = temp.appendingPathComponent("hilo-f09.lungfishfastq", isDirectory: true)
        let referenceURL = temp.appendingPathComponent("amplicons_12s.fa")
        let outputURL = temp.appendingPathComponent("Analyses/12S amplicon results", isDirectory: true)
        try FileManager.default.createDirectory(at: readsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
        try Data(">target\nACGT\n".utf8).write(to: referenceURL)
        let configuration = TwelveSAmpliconMatchingConfiguration(
            inputFASTQs: [readsURL],
            referenceFASTA: referenceURL,
            outputDirectory: outputURL,
            outputName: "hilo-12s"
        )
        let runner = StubWorkflowOperationCLIProcessRunner(provenanceToolName: "lungfish")
        let resultRefresher = StubWorkflowOperationResultRefresher()
        let service = WorkflowOperationExecutionService(
            operationCenter: OperationCenter(),
            processRunner: runner,
            viewerBundlePreparer: StubWorkflowOperationViewerBundlePreparer(),
            bamImporter: StubWorkflowOperationBAMImporter(),
            resultRefresher: resultRefresher
        )

        let outputs = try await service.run(.twelveSAmpliconMatching(configuration))

        let bundleURL = outputURL.appendingPathComponent("hilo-12s.lungfish12s", isDirectory: true).standardizedFileURL
        XCTAssertTrue(outputs.contains(bundleURL))
        XCTAssertEqual(resultRefresher.invocations, [bundleURL])
    }

    func testTwelveSReferenceBundleBuildRunsCLIAndReportsBundleOutput() async throws {
        let temp = try temporaryDirectory()
        let fastaURL = temp.appendingPathComponent("amplicons_12s_deduplicated.fa")
        let metadataURL = temp.appendingPathComponent("12s_reference.tsv")
        let sourceDirectory = temp.appendingPathComponent("midori-source", isDirectory: true)
        let outputURL = temp.appendingPathComponent("Reference Sequences/MIDORI-12S.lungfish12sref", isDirectory: true)
        try Data(">target\nACGT\n".utf8).write(to: fastaURL)
        try Data("seq_id\tlatin_name\tgroup\ttaxid\tcommon_name\n".utf8).write(to: metadataURL)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)

        let configuration = TwelveSReferenceBundleBuildConfiguration(
            deduplicatedFASTA: fastaURL,
            midoriMetadataTSV: metadataURL,
            outputURL: outputURL,
            name: "MIDORI 12S",
            sourceDirectories: [sourceDirectory],
            forceOverwrite: true
        )
        let operationCenter = OperationCenter()
        let runner = StubWorkflowOperationCLIProcessRunner(stderr: """
        [  2%] Validating 12S reference bundle inputs.
        [ 35%] Building 12S target metadata.
        [ 94%] Writing 12S reference bundle provenance.
        [100%] 12S reference bundle creation complete.
        """)
        let resultRefresher = StubWorkflowOperationResultRefresher()
        let service = WorkflowOperationExecutionService(
            operationCenter: operationCenter,
            processRunner: runner,
            viewerBundlePreparer: StubWorkflowOperationViewerBundlePreparer(),
            bamImporter: StubWorkflowOperationBAMImporter(),
            resultRefresher: resultRefresher
        )

        let outputs = try await service.runTwelveSReferenceBundleBuild(configuration)

        let invocation = try XCTUnwrap(runner.invocations.first)
        XCTAssertEqual(invocation.arguments.prefix(2), ["fastq", "12s-reference-bundle"])
        XCTAssertEqual(try testValue(after: "--dedup-fasta", in: invocation.arguments), fastaURL.standardizedFileURL.path)
        XCTAssertEqual(try testValue(after: "--midori-metadata", in: invocation.arguments), metadataURL.standardizedFileURL.path)
        XCTAssertEqual(try testValue(after: "--output", in: invocation.arguments), outputURL.standardizedFileURL.path)
        XCTAssertEqual(try testValue(after: "--name", in: invocation.arguments), "MIDORI 12S")
        XCTAssertEqual(try testValue(after: "--source-directory", in: invocation.arguments), sourceDirectory.standardizedFileURL.path)
        XCTAssertTrue(invocation.arguments.contains("--force"))
        XCTAssertEqual(invocation.workingDirectory, outputURL.deletingLastPathComponent().standardizedFileURL)

        XCTAssertTrue(outputs.contains(outputURL.standardizedFileURL))
        XCTAssertTrue(outputs.contains(outputURL.appendingPathComponent("12s-reference.json").standardizedFileURL))
        XCTAssertTrue(outputs.contains(outputURL.appendingPathComponent("target-metadata.tsv").standardizedFileURL))
        XCTAssertTrue(outputs.contains(outputURL.appendingPathComponent(".lungfish-provenance.json").standardizedFileURL))

        let item = try XCTUnwrap(operationCenter.items.first)
        XCTAssertEqual(item.title, "12S Reference Bundle")
        XCTAssertEqual(item.state, .completed)
        XCTAssertTrue(item.cliCommand?.contains("lungfish-cli fastq 12s-reference-bundle") == true)
        XCTAssertTrue(item.outputURLs.contains(outputURL.standardizedFileURL))
        XCTAssertTrue(item.logEntries.contains { $0.message == "Building 12S target metadata." })
        XCTAssertTrue(item.logEntries.contains { $0.message == "Writing 12S reference bundle provenance." })
        XCTAssertEqual(resultRefresher.invocations, [outputURL.standardizedFileURL])
    }

    func testLocalWorkflowExecutionErrorsHaveUserVisibleDescriptions() {
        XCTAssertEqual(
            LocalWorkflowExecutionError.invalidProvenance("/tmp/out/.lungfish-provenance.json").localizedDescription,
            "The workflow output provenance is incomplete or does not match the expected workflow: /tmp/out/.lungfish-provenance.json"
        )
    }

    func testTwelveSAmpliconMatchingFailsWhenCLIOutputOmitsFinalBundleProvenance() async throws {
        let temp = try temporaryDirectory()
        let readsURL = temp.appendingPathComponent("hilo-f09.lungfishfastq", isDirectory: true)
        let referenceURL = temp.appendingPathComponent("amplicons_12s.fa")
        let outputURL = temp.appendingPathComponent("Analyses/12S amplicon results", isDirectory: true)
        try FileManager.default.createDirectory(at: readsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
        try Data(">target\nACGT\n".utf8).write(to: referenceURL)
        let configuration = TwelveSAmpliconMatchingConfiguration(
            inputFASTQs: [readsURL],
            referenceFASTA: referenceURL,
            outputDirectory: outputURL,
            outputName: "hilo-12s"
        )
        let operationCenter = OperationCenter()
        let runner = StubWorkflowOperationCLIProcessRunner(writesTwelveSProvenance: false)
        let service = WorkflowOperationExecutionService(
            operationCenter: operationCenter,
            processRunner: runner,
            viewerBundlePreparer: StubWorkflowOperationViewerBundlePreparer(),
            bamImporter: StubWorkflowOperationBAMImporter(),
            resultRefresher: StubWorkflowOperationResultRefresher()
        )

        do {
            _ = try await service.run(.twelveSAmpliconMatching(configuration))
            XCTFail("Expected missing provenance to fail the 12S GUI workflow operation")
        } catch LocalWorkflowExecutionError.missingProvenance(let path) {
            XCTAssertTrue(path.hasSuffix(".lungfish-provenance.json"))
        }

        let item = try XCTUnwrap(operationCenter.items.first)
        XCTAssertEqual(item.state, .failed)
        XCTAssertEqual(item.errorMessage, "12S amplicon matching failed")
        XCTAssertTrue(item.errorDetail?.contains(".lungfish-provenance.json") == true)
    }

    func testONTGenotypingArgumentsIncludeExplicitHaplotypeDefinitionWhenSelected() throws {
        let temp = try temporaryDirectory()
        let request = ONTBarcodeDemuxGenotypingRunRequest(
            inputFASTQURL: temp.appendingPathComponent("reads.lungfishfastq", isDirectory: true),
            referenceSourceURL: temp.appendingPathComponent("ref.lungfishref", isDirectory: true),
            barcodeDefinitionsURL: temp.appendingPathComponent("barcodes.csv"),
            outputDirectory: temp.appendingPathComponent("out.lungfishgenotype", isDirectory: true),
            outputName: "reads-ont",
            analysisName: "ONT08",
            threads: 4,
            minSupport: 2,
            haplotypeAssayID: "MHC-exon2-miSeq",
            haplotypeDefinitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques"
        )

        let service = WorkflowOperationExecutionService()
        let arguments = service.ontGenotypingArguments(for: request)

        XCTAssertEqual(try testValue(after: "--haplotype-assay", in: arguments), "MHC-exon2-miSeq")
        XCTAssertEqual(
            try testValue(after: "--haplotype-definition", in: arguments),
            "MHC-exon2-miSeq.mauritian-cynomolgus-macaques"
        )
    }

    func testONTGenotypingArgumentsIncludeOperationHaplotypeThresholds() throws {
        let temp = try temporaryDirectory()
        let request = ONTBarcodeDemuxGenotypingRunRequest(
            inputFASTQURL: temp.appendingPathComponent("reads.lungfishfastq", isDirectory: true),
            referenceSourceURL: temp.appendingPathComponent("ref.lungfishref", isDirectory: true),
            barcodeDefinitionsURL: temp.appendingPathComponent("barcodes.csv"),
            outputDirectory: temp.appendingPathComponent("out.lungfishgenotype", isDirectory: true),
            outputName: "reads-ont",
            analysisName: "ONT08",
            threads: 4,
            minSupport: 10,
            haplotypeDropoutSampleFraction: 0.001,
            haplotypeDropoutLocusFraction: 0.01,
            haplotypeDropoutLocusFractionOverrides: [
                "MHC-DP": 0.10,
                "MHC-DQ": 0.10,
            ],
            haplotypeAssayID: "MHC-exon2-miSeq",
            haplotypeDefinitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques"
        )

        let service = WorkflowOperationExecutionService()
        let arguments = service.ontGenotypingArguments(for: request)

        XCTAssertEqual(try testValue(after: "--haplotype-min-sample-percent", in: arguments), "0.1")
        XCTAssertEqual(try testValue(after: "--haplotype-min-locus-percent", in: arguments), "1")
        XCTAssertTrue(arguments.contains("--haplotype-min-locus-percent-override"))
        XCTAssertTrue(arguments.contains("MHC-DP=10"))
        XCTAssertTrue(arguments.contains("MHC-DQ=10"))
    }

    func testONTGenotypingArgumentsUseCohortCommandForMultipleIlluminaInputs() throws {
        let temp = try temporaryDirectory()
        let first = temp.appendingPathComponent("DW001.lungfishfastq", isDirectory: true)
        let second = temp.appendingPathComponent("DW002.lungfishfastq", isDirectory: true)
        let request = ONTBarcodeDemuxGenotypingRunRequest(
            inputFASTQURLs: [first, second],
            referenceSourceURL: temp.appendingPathComponent("ref.lungfishref", isDirectory: true),
            outputDirectory: temp.appendingPathComponent("out.lungfishgenotype", isDirectory: true),
            outputName: "miseq-mhc",
            threads: 4,
            minSupport: 2,
            mode: .illuminaPaired,
            readType: .illumina
        )

        let service = WorkflowOperationExecutionService()
        let arguments = service.ontGenotypingArguments(for: request)

        XCTAssertEqual(Array(arguments.prefix(2)), ["fastq", "genotype-cohort"])
        XCTAssertTrue(arguments.contains(first.standardizedFileURL.path))
        XCTAssertTrue(arguments.contains(second.standardizedFileURL.path))
        XCTAssertEqual(try testValue(after: "--mode", in: arguments), "illumina-paired")
        XCTAssertEqual(try testValue(after: "--read-type", in: arguments), "illumina")
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkflowOperationExecutionServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeONTGenotypingRequest(temp: URL) throws -> ONTBarcodeDemuxGenotypingRunRequest {
        let readsURL = temp.appendingPathComponent("reads.lungfishfastq", isDirectory: true)
        let referenceURL = temp.appendingPathComponent("ref.lungfishref", isDirectory: true)
        let barcodesURL = temp.appendingPathComponent("barcodes.csv")
        let outputURL = temp.appendingPathComponent("Analyses/reads-ont.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: readsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: referenceURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
        try Data("sample,barcode\nDW472,ACGT\n".utf8).write(to: barcodesURL)
        return ONTBarcodeDemuxGenotypingRunRequest(
            inputFASTQURL: readsURL,
            referenceSourceURL: referenceURL,
            barcodeDefinitionsURL: barcodesURL,
            outputDirectory: outputURL,
            outputName: "reads-ont",
            analysisName: "ONT08",
            projectURL: temp,
            threads: 4,
            minSupport: 2
        )
    }

    private func testValue(after flag: String, in arguments: [String]) throws -> String {
        guard let index = arguments.firstIndex(of: flag),
              arguments.indices.contains(arguments.index(after: index)) else {
            throw NSError(
                domain: "WorkflowOperationExecutionServiceTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Missing \(flag)"]
            )
        }
        return arguments[arguments.index(after: index)]
    }
}

private final class StubWorkflowOperationCLIProcessRunner: LocalWorkflowCLIProcessRunning {
    struct Invocation: Equatable {
        let arguments: [String]
        let workingDirectory: URL
    }

    private(set) var invocations: [Invocation] = []
    private(set) var didReceiveOutputHandler = false
    private let exitCode: Int32
    private let stdout: String?
    private let stderr: String
    private let writesTwelveSProvenance: Bool
    private let provenanceToolName: String

    init(
        exitCode: Int32 = 0,
        stdout: String? = nil,
        stderr: String = "",
        writesTwelveSProvenance: Bool = true,
        provenanceToolName: String = "lungfish-cli"
    ) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.writesTwelveSProvenance = writesTwelveSProvenance
        self.provenanceToolName = provenanceToolName
    }

    func runLungfishCLI(
        arguments: [String],
        workingDirectory: URL,
        outputHandler: (@MainActor @Sendable (ViralReconWorkflowProcessOutput) -> Void)?
    ) async throws -> LocalWorkflowCLIProcessResult {
        didReceiveOutputHandler = outputHandler != nil
        invocations.append(Invocation(
            arguments: arguments,
            workingDirectory: workingDirectory.standardizedFileURL
        ))
        for line in stderr.split(whereSeparator: \.isNewline).map(String.init) {
            outputHandler?(.standardError(line))
        }
        if let stdout {
            for line in stdout.split(whereSeparator: \.isNewline).map(String.init) {
                outputHandler?(.standardOutput(line))
            }
            return LocalWorkflowCLIProcessResult(
                exitCode: exitCode,
                standardOutput: stdout,
                standardError: stderr,
                didStreamOutput: outputHandler != nil
            )
        }
        if arguments.prefix(2) == ["fastq", "12s-reference-bundle"] {
            let outputURL = URL(fileURLWithPath: try value(after: "--output", in: arguments))
                .standardizedFileURL
            try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
            try Data(">target\nACGT\n".utf8).write(
                to: outputURL.appendingPathComponent("reference.fa")
            )
            try Data("target_id\tscientific_name\n".utf8).write(
                to: outputURL.appendingPathComponent("target-metadata.tsv")
            )
            let manifest = TwelveSReferenceBundleManifest(
                name: "MIDORI 12S",
                referenceFastaPath: "reference.fa",
                targetMetadataPath: "target-metadata.tsv",
                sourceFiles: [],
                metrics: TwelveSReferenceBundleMetrics(
                    referenceCount: 1,
                    metadataRowCount: 1,
                    taxidCount: 1,
                    taxonGroupCount: 1,
                    taxonomyCount: 1,
                    alternateMatchCount: 0
                ),
                provenancePath: ".lungfish-provenance.json",
                createdAt: "2026-05-30T00:00:00Z"
            )
            try TwelveSReferenceBundle.writeManifest(manifest, to: outputURL)
            let argv = ["lungfish-cli"] + arguments
            let envelope = ProvenanceEnvelope(
                workflowName: "lungfish fastq 12s-reference-bundle",
                workflowVersion: "1",
                toolName: "lungfish-cli",
                toolVersion: "1",
                argv: argv,
                durableReplayArgv: argv,
                runtimeIdentity: ProvenanceRuntimeIdentity(user: "tests"),
                outputs: [
                    ProvenanceFileDescriptor(path: outputURL.path, role: .output),
                ],
                exitStatus: 0
            )
            try ProvenanceJSON.encoder.encode(envelope).write(
                to: outputURL.appendingPathComponent(".lungfish-provenance.json")
            )
            return LocalWorkflowCLIProcessResult(
                exitCode: exitCode,
                standardOutput: "12S reference bundle written to \(outputURL.path)\n",
                standardError: stderr,
                didStreamOutput: outputHandler != nil
            )
        }
        if arguments.prefix(2) == ["fastq", "12s-match"] {
            let outputDirectory = URL(fileURLWithPath: try value(after: "--output-dir", in: arguments))
                .standardizedFileURL
            let outputName = try value(after: "--output-name", in: arguments)
            let bundleURL = outputDirectory.appendingPathComponent("\(outputName).lungfish12s", isDirectory: true)
            try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
            try #"{"formatVersion":1}"#.write(
                to: bundleURL.appendingPathComponent("12s-result.json"),
                atomically: true,
                encoding: .utf8
            )
            if writesTwelveSProvenance {
                let argv = ["lungfish-cli"] + arguments
                let envelope = ProvenanceEnvelope(
                    workflowName: "lungfish fastq 12s-match",
                    workflowVersion: "1",
                    toolName: provenanceToolName,
                    toolVersion: "1",
                    argv: argv,
                    durableReplayArgv: argv,
                    runtimeIdentity: ProvenanceRuntimeIdentity(user: "tests"),
                    outputs: [
                        ProvenanceFileDescriptor(path: bundleURL.path, role: .output),
                    ],
                    exitStatus: 0
                )
                try ProvenanceJSON.encoder.encode(envelope).write(
                    to: bundleURL.appendingPathComponent(".lungfish-provenance.json")
                )
            }
            return LocalWorkflowCLIProcessResult(
                exitCode: exitCode,
                standardOutput: "12S amplicon result bundle written to \(bundleURL.path)\n",
                standardError: stderr,
                didStreamOutput: outputHandler != nil
            )
        }
        if arguments.prefix(2) == ["fastq", "full-length-ont-mhc-genotype"] {
            let outputDirectory = URL(fileURLWithPath: try value(after: "--output-dir", in: arguments))
                .standardizedFileURL
            let outputName = try value(after: "--output-name", in: arguments)
            let workbookURL = outputDirectory.appendingPathComponent("\(outputName).full-length-ont-mhc-genotypes.xlsx")
            let currentWorkbookURL = outputDirectory
                .appendingPathComponent("artifacts/workbooks", isDirectory: true)
                .appendingPathComponent("current.xlsx")
            let haplotypeAnalysisURL = outputDirectory.appendingPathComponent("\(outputName).haplotype-analysis.json")
            let reportCSVURL = outputDirectory.appendingPathComponent("\(outputName).full-length-ont-mhc-genotypes.csv")
            let sampleSummaryCSVURL = outputDirectory.appendingPathComponent("\(outputName).full-length-ont-mhc-samples.csv")
            let statsJSONURL = outputDirectory.appendingPathComponent("\(outputName).full-length-ont-mhc-stats.json")
            let unmatchedURL = outputDirectory.appendingPathComponent("unmatched_clusters.fasta")
            let cdnaURL = outputDirectory.appendingPathComponent("cdna_clusters.fasta")
            let provenanceURL = outputDirectory.appendingPathComponent("full-length-ont-mhc-genotyping-provenance.json")
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: currentWorkbookURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try "sample,genotype,passed_alignments,passed_unique_reads\n".write(
                to: reportCSVURL,
                atomically: true,
                encoding: .utf8
            )
            try "sample,passed_alignments,passed_unique_reads\n".write(
                to: sampleSummaryCSVURL,
                atomically: true,
                encoding: .utf8
            )
            try #"{"totalInputReads":100,"retainedUniqueReads":12}"#.write(
                to: statsJSONURL,
                atomically: true,
                encoding: .utf8
            )
            try Data("workbook".utf8).write(to: workbookURL)
            try Data("current workbook".utf8).write(to: currentWorkbookURL)
            let haplotypePayloadLine: String
            if arguments.contains("--haplotype-definition") {
                try #"{"assayID":"MHC-full-length-ONT","samples":[]}"#.write(
                    to: haplotypeAnalysisURL,
                    atomically: true,
                    encoding: .utf8
                )
                haplotypePayloadLine = #"  "haplotypeAnalysisPath": "\#(haplotypeAnalysisURL.path)","# + "\n"
            } else {
                haplotypePayloadLine = #"  "haplotypeAnalysisPath": null,"# + "\n"
            }
            try Data().write(to: unmatchedURL)
            try Data().write(to: cdnaURL)
            try #"{"workflowName":"lungfish fastq full-length-ont-mhc-genotype","exitStatus":0}"#.write(
                to: provenanceURL,
                atomically: true,
                encoding: .utf8
            )
            let payload = """
            {
              "outputDirectory": "\(outputDirectory.path)",
              "referenceFASTAPath": "/tmp/reference.fa",
              "reportCSVPath": "\(reportCSVURL.path)",
              "sampleSummaryCSVPath": "\(sampleSummaryCSVURL.path)",
              "statsJSONPath": "\(statsJSONURL.path)",
              "workbookPath": "\(currentWorkbookURL.path)",
              "primaryWorkbookPath": "\(workbookURL.path)",
            """
            + haplotypePayloadLine
            + """
              "unmatchedClustersFASTAPath": "\(unmatchedURL.path)",
              "cdnaClustersFASTAPath": "\(cdnaURL.path)",
              "provenancePath": "\(provenanceURL.path)"
            }
            """
            for line in payload.split(whereSeparator: \.isNewline).map(String.init) {
                outputHandler?(.standardOutput(line))
            }
            return LocalWorkflowCLIProcessResult(
                exitCode: exitCode,
                standardOutput: payload,
                standardError: stderr,
                didStreamOutput: outputHandler != nil
            )
        }
        let outputDirectory = URL(fileURLWithPath: try value(after: "--output-dir", in: arguments))
            .standardizedFileURL
        let outputName = try value(after: "--output-name", in: arguments)
        let analysisName = try value(after: "--analysis-name", in: arguments)
        let workbookURL = outputDirectory.appendingPathComponent("\(outputName)_\(analysisName).xlsx")
        let reportCSVURL = outputDirectory.appendingPathComponent("\(outputName).retained-demux-genotypes.csv")
        let sampleSummaryCSVURL = outputDirectory.appendingPathComponent("\(outputName).retained-demux-samples.csv")
        let statsJSONURL = outputDirectory.appendingPathComponent("\(outputName).retained-demux-stats.json")
        let provenanceURL = outputDirectory.appendingPathComponent("retained-demux-genotyping-provenance.json")
        let mappingBAM = outputDirectory.appendingPathComponent("\(outputName).md.sorted.bam")
        let mappingBAI = mappingBAM.appendingPathExtension("bai")
        let retainedBAM = outputDirectory.appendingPathComponent("\(outputName).retained.demuxed.bam")
        let retainedBAI = retainedBAM.appendingPathExtension("bai")
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try "input_bundle_name,genotype,filtered_indel_only_mapped_reads,total_reads\n".write(
            to: reportCSVURL,
            atomically: true,
            encoding: .utf8
        )
        try "sample,total_input_reads,retained_unique_reads\n".write(to: sampleSummaryCSVURL, atomically: true, encoding: .utf8)
        try #"{"totalInputReads":100,"retainedUniqueReads":42}"#.write(to: statsJSONURL, atomically: true, encoding: .utf8)
        try #"{"toolName":"lungfish fastq ont-barcode-genotype","workflowVersion":"1"}"#.write(to: provenanceURL, atomically: true, encoding: .utf8)
        try Data("workbook".utf8).write(to: workbookURL)
        for url in [mappingBAM, mappingBAI, retainedBAM, retainedBAI] {
            try Data(url.lastPathComponent.utf8).write(to: url)
        }
        let payload = """
        {
          "outputDirectory": "\(outputDirectory.path)",
          "mappingBAMPath": "\(mappingBAM.path)",
          "mappingBAIPath": "\(mappingBAI.path)",
          "retainedBAMPath": "\(retainedBAM.path)",
          "retainedBAIPath": "\(retainedBAI.path)",
          "referenceFASTAPath": "/tmp/ref.fa",
          "reportCSVPath": "\(reportCSVURL.path)",
          "sampleSummaryCSVPath": "\(sampleSummaryCSVURL.path)",
          "statsJSONPath": "\(statsJSONURL.path)",
          "workbookPath": "\(workbookURL.path)",
          "provenancePath": "\(provenanceURL.path)",
          "sourceReferenceBundlePath": null
        }
        """
        for line in payload.split(whereSeparator: \.isNewline).map(String.init) {
            outputHandler?(.standardOutput(line))
        }
        return LocalWorkflowCLIProcessResult(
            exitCode: exitCode,
            standardOutput: payload,
            standardError: stderr,
            didStreamOutput: outputHandler != nil
        )
    }

    private func value(after flag: String, in arguments: [String]) throws -> String {
        guard let index = arguments.firstIndex(of: flag),
              arguments.indices.contains(arguments.index(after: index)) else {
            throw NSError(
                domain: "WorkflowOperationExecutionServiceTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Missing \(flag)"]
            )
        }
        return arguments[arguments.index(after: index)]
    }
}

private struct ViewerBundleInvocation: Equatable {
    let sourceBundleURL: URL
    let viewerBundleURL: URL
}

private struct BAMImportInvocation: Equatable {
    let bamURL: URL
    let bundleURL: URL
    let name: String?
}

private final class StubWorkflowOperationViewerBundlePreparer: WorkflowOperationViewerBundlePreparing, @unchecked Sendable {
    private(set) var invocations: [ViewerBundleInvocation] = []

    func prepareBaseBundle(
        sourceBundleURL: URL,
        viewerBundleURL: URL,
        fileManager: FileManager
    ) throws {
        invocations.append(ViewerBundleInvocation(
            sourceBundleURL: sourceBundleURL.standardizedFileURL,
            viewerBundleURL: viewerBundleURL.standardizedFileURL
        ))
        try fileManager.createDirectory(at: viewerBundleURL, withIntermediateDirectories: true)
    }
}

private final class StubWorkflowOperationBAMImporter: WorkflowOperationBAMImporting, @unchecked Sendable {
    private(set) var invocations: [BAMImportInvocation] = []

    func importBAM(
        bamURL: URL,
        bundleURL: URL,
        name: String?,
        progressHandler: (@Sendable (Double, String) -> Void)?
    ) async throws {
        invocations.append(BAMImportInvocation(
            bamURL: bamURL.standardizedFileURL,
            bundleURL: bundleURL.standardizedFileURL,
            name: name
        ))
        progressHandler?(1, "Import complete.")
    }
}

private final class StubWorkflowOperationResultRefresher: WorkflowOperationResultRefreshing, @unchecked Sendable {
    private(set) var invocations: [URL] = []

    @MainActor
    func refresh(routeContext: OperationRouteContext?, preferredSelectionURL: URL) {
        invocations.append(preferredSelectionURL.standardizedFileURL)
    }
}
