import XCTest
import LungfishWorkflow
@testable import LungfishApp

@MainActor
final class WorkflowOperationExecutionServiceTests: XCTestCase {
    func testONTGenotypingRunsThroughLungfishCLIAndPreparesViewerBundleOutputs() async throws {
        let temp = try temporaryDirectory()
        let readsURL = temp.appendingPathComponent("reads.lungfishfastq", isDirectory: true)
        let referenceURL = temp.appendingPathComponent("ref.lungfishref", isDirectory: true)
        let outputURL = temp.appendingPathComponent("Analyses", isDirectory: true)
        try FileManager.default.createDirectory(at: readsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: referenceURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
        let request = ONTGenotypingRunRequest(
            inputFASTQURLs: [readsURL],
            referenceSourceURL: referenceURL,
            outputDirectory: outputURL,
            outputName: "reads-ont",
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
        XCTAssertEqual(invocation.arguments.prefix(2), ["fastq", "ont-genotype"])
        XCTAssertTrue(invocation.arguments.contains(readsURL.standardizedFileURL.path))
        XCTAssertTrue(invocation.arguments.contains("--reference"))
        XCTAssertTrue(invocation.arguments.contains(referenceURL.standardizedFileURL.path))
        XCTAssertTrue(invocation.arguments.contains("--min-support"))
        XCTAssertTrue(invocation.arguments.contains("2"))
        XCTAssertEqual(invocation.workingDirectory, outputURL.standardizedFileURL)
        XCTAssertTrue(outputs.contains(outputURL.appendingPathComponent("reads-ont.csv").standardizedFileURL))
        XCTAssertTrue(outputs.contains(outputURL.appendingPathComponent("reads/reads.sorted.bam").standardizedFileURL))
        XCTAssertTrue(outputs.contains(outputURL.appendingPathComponent("reads/reads.sorted.bam.bai").standardizedFileURL))
        XCTAssertTrue(outputs.contains(outputURL.appendingPathComponent("reads/reads.ont-genotyping.filtered.bam").standardizedFileURL))
        XCTAssertTrue(outputs.contains(outputURL.appendingPathComponent("reads/reads.ont-genotyping.filtered.bam.bai").standardizedFileURL))
        XCTAssertTrue(outputs.contains(outputURL.appendingPathComponent("reads/ref.lungfishref").standardizedFileURL))
        XCTAssertEqual(
            viewerBundlePreparer.invocations,
            [ViewerBundleInvocation(
                sourceBundleURL: referenceURL.standardizedFileURL,
                viewerBundleURL: outputURL.appendingPathComponent("reads/ref.lungfishref", isDirectory: true).standardizedFileURL
            )]
        )
        XCTAssertEqual(
            bamImporter.invocations,
            [BAMImportInvocation(
                bamURL: outputURL.appendingPathComponent("reads/reads.ont-genotyping.filtered.bam").standardizedFileURL,
                bundleURL: outputURL.appendingPathComponent("reads/ref.lungfishref", isDirectory: true).standardizedFileURL,
                name: "ONT Genotyping"
            )]
        )

        let preparedResult = try MappingResult.load(from: outputURL.appendingPathComponent("reads", isDirectory: true))
        XCTAssertEqual(
            preparedResult.viewerBundleURL,
            outputURL.appendingPathComponent("reads/ref.lungfishref", isDirectory: true).standardizedFileURL
        )
        let preparedProvenance = try XCTUnwrap(
            MappingProvenance.load(from: outputURL.appendingPathComponent("reads", isDirectory: true))
        )
        XCTAssertEqual(
            preparedProvenance.viewerBundlePath,
            outputURL.appendingPathComponent("reads/ref.lungfishref", isDirectory: true).standardizedFileURL.path
        )

        let item = try XCTUnwrap(operationCenter.items.first)
        XCTAssertEqual(item.title, "ONT Genotyping")
        XCTAssertEqual(item.state, .completed)
        XCTAssertTrue(item.cliCommand?.contains("lungfish-cli fastq ont-genotype") == true)
        XCTAssertTrue(item.outputURLs.contains(outputURL.appendingPathComponent("reads-ont.csv").standardizedFileURL))
        XCTAssertTrue(item.outputURLs.contains(outputURL.appendingPathComponent("reads/reads.ont-genotyping.filtered.bam").standardizedFileURL))
        XCTAssertTrue(item.outputURLs.contains(outputURL.appendingPathComponent("reads/ref.lungfishref").standardizedFileURL))
        XCTAssertEqual(
            resultRefresher.invocations,
            [outputURL.appendingPathComponent("reads", isDirectory: true).standardizedFileURL]
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
        let sampleDirectory = outputDirectory.appendingPathComponent("reads", isDirectory: true)
        let mappingBAM = sampleDirectory.appendingPathComponent("reads.sorted.bam")
        let mappingBAI = sampleDirectory.appendingPathComponent("reads.sorted.bam.bai")
        let filteredBAM = sampleDirectory.appendingPathComponent("reads.ont-genotyping.filtered.bam")
        let filteredBAI = sampleDirectory.appendingPathComponent("reads.ont-genotyping.filtered.bam.bai")
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sampleDirectory, withIntermediateDirectories: true)
        try "input_bundle_name,genotype,filtered_indel_only_mapped_reads,total_reads\n".write(
            to: outputDirectory.appendingPathComponent("\(outputName).csv"),
            atomically: true,
            encoding: .utf8
        )
        for url in [mappingBAM, mappingBAI, filteredBAM, filteredBAI] {
            try Data(url.lastPathComponent.utf8).write(to: url)
        }
        let mappingResult = MappingResult(
            mapper: .minimap2,
            modeID: MappingMode.defaultShortRead.id,
            sourceReferenceBundleURL: URL(fileURLWithPath: try value(after: "--reference", in: arguments)).standardizedFileURL,
            viewerBundleURL: nil,
            bamURL: filteredBAM,
            baiURL: filteredBAI,
            totalReads: 100,
            mappedReads: 42,
            unmappedReads: 58,
            wallClockSeconds: 1.5,
            contigs: []
        )
        try mappingResult.save(to: sampleDirectory)
        let provenance = MappingProvenance(
            schemaVersion: 4,
            workflowName: "ONT Genotyping",
            mapper: .minimap2,
            modeID: MappingMode.defaultShortRead.id,
            sampleName: "reads",
            pairedEnd: false,
            threads: 4,
            minimumMappingQuality: 0,
            includeSecondary: true,
            includeSupplementary: true,
            advancedArguments: [],
            inputFASTQURLs: [URL(fileURLWithPath: "/tmp/reads.fastq")],
            referenceFASTAURL: URL(fileURLWithPath: "/tmp/ref.fa"),
            sourceReferenceBundleURL: URL(fileURLWithPath: try value(after: "--reference", in: arguments)).standardizedFileURL,
            viewerBundleURL: nil,
            mapperInvocation: MappingCommandInvocation(
                label: "lungfish fastq ont-genotype",
                argv: ["lungfish", "fastq", "ont-genotype"],
                durableReplayArgv: ["lungfish", "fastq", "ont-genotype"]
            ),
            normalizationInvocations: [],
            mapperVersion: "stub",
            samtoolsVersion: "stub",
            wallClockSeconds: 1.5,
            outputFiles: [
                FileRecord(path: filteredBAM.path, format: .bam, role: .output),
                FileRecord(path: filteredBAI.path, format: .unknown, role: .index),
            ]
        )
        try provenance.save(to: sampleDirectory)
        try provenance.saveCanonicalEnvelope(to: sampleDirectory)
        let payload = """
        {
          "outputDirectory": "\(outputDirectory.path)",
          "referenceFASTAPath": "/tmp/ref.fa",
          "reportCSVPath": "\(outputDirectory.appendingPathComponent("\(outputName).csv").path)",
          "sampleResults": [
            {
              "filteredAlignments": 42,
              "filteredBAIPath": "\(filteredBAI.path)",
              "filteredBAMPath": "\(filteredBAM.path)",
              "inputFASTQPath": "/tmp/reads.fastq",
              "mappingBAIPath": "\(mappingBAI.path)",
              "mappingBAMPath": "\(mappingBAM.path)",
              "sampleName": "reads",
              "totalReads": 100
            }
          ],
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
