import XCTest
import LungfishWorkflow
@testable import LungfishApp

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
        XCTAssertEqual(invocation.arguments.prefix(2), ["fastq", "ont-barcode-genotype"])
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
        XCTAssertEqual(item.title, "ONT Genotyping")
        XCTAssertEqual(item.state, .completed)
        XCTAssertTrue(item.cliCommand?.contains("lungfish-cli fastq ont-barcode-genotype") == true)
        XCTAssertTrue(item.outputURLs.contains(request.workbookURL.standardizedFileURL))
        XCTAssertEqual(
            resultRefresher.invocations,
            [request.outputDirectory.standardizedFileURL]
        )
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkflowOperationExecutionServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private final class StubWorkflowOperationCLIProcessRunner: LocalWorkflowCLIProcessRunning {
    struct Invocation: Equatable {
        let arguments: [String]
        let workingDirectory: URL
    }

    private(set) var invocations: [Invocation] = []

    func runLungfishCLI(
        arguments: [String],
        workingDirectory: URL
    ) async throws -> LocalWorkflowCLIProcessResult {
        invocations.append(Invocation(
            arguments: arguments,
            workingDirectory: workingDirectory.standardizedFileURL
        ))
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
        return LocalWorkflowCLIProcessResult(
            exitCode: 0,
            standardOutput: payload,
            standardError: ""
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
