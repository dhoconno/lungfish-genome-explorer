import Foundation
import LungfishWorkflow

protocol WorkflowOperationViewerBundlePreparing: Sendable {
    func prepareBaseBundle(
        sourceBundleURL: URL,
        viewerBundleURL: URL,
        fileManager: FileManager
    ) throws
}

struct DefaultWorkflowOperationViewerBundlePreparer: WorkflowOperationViewerBundlePreparing {
    func prepareBaseBundle(
        sourceBundleURL: URL,
        viewerBundleURL: URL,
        fileManager: FileManager
    ) throws {
        try MappingViewerBundlePreparer.prepareBaseBundle(
            sourceBundleURL: sourceBundleURL,
            viewerBundleURL: viewerBundleURL,
            fileManager: fileManager
        )
    }
}

protocol WorkflowOperationBAMImporting: Sendable {
    func importBAM(
        bamURL: URL,
        bundleURL: URL,
        name: String?,
        progressHandler: (@Sendable (Double, String) -> Void)?
    ) async throws
}

struct DefaultWorkflowOperationBAMImporter: WorkflowOperationBAMImporting {
    func importBAM(
        bamURL: URL,
        bundleURL: URL,
        name: String?,
        progressHandler: (@Sendable (Double, String) -> Void)?
    ) async throws {
        _ = try await BAMImportService.importBAM(
            bamURL: bamURL,
            bundleURL: bundleURL,
            name: name,
            progressHandler: progressHandler
        )
    }
}

protocol WorkflowOperationResultRefreshing: Sendable {
    @MainActor
    func refresh(routeContext: OperationRouteContext?, preferredSelectionURL: URL)
}

struct DefaultWorkflowOperationResultRefresher: WorkflowOperationResultRefreshing {
    @MainActor
    func refresh(routeContext: OperationRouteContext?, preferredSelectionURL: URL) {
        guard let splitViewController = AppDelegate.shared?
            .targetMainWindowController(routeContext: routeContext)?
            .mainSplitViewController else {
            return
        }

        if MappingResult.exists(in: preferredSelectionURL) {
            splitViewController.refreshSidebarAndDisplayMappingResult(at: preferredSelectionURL)
            return
        }

        splitViewController.sidebarController.reloadFromFilesystem()
        _ = splitViewController.sidebarController.selectItem(
            forURL: preferredSelectionURL.standardizedFileURL
        )
    }
}

@MainActor
final class WorkflowOperationExecutionService {
    private let operationCenter: OperationCenter
    private let processRunner: LocalWorkflowCLIProcessRunning
    private let viewerBundlePreparer: WorkflowOperationViewerBundlePreparing
    private let bamImporter: WorkflowOperationBAMImporting
    private let resultRefresher: WorkflowOperationResultRefreshing
    private let fileManager: FileManager

    init(
        operationCenter: OperationCenter = .shared,
        processRunner: LocalWorkflowCLIProcessRunning = ProcessLocalWorkflowCLIProcessRunner(),
        viewerBundlePreparer: WorkflowOperationViewerBundlePreparing = DefaultWorkflowOperationViewerBundlePreparer(),
        bamImporter: WorkflowOperationBAMImporting = DefaultWorkflowOperationBAMImporter(),
        resultRefresher: WorkflowOperationResultRefreshing = DefaultWorkflowOperationResultRefresher(),
        fileManager: FileManager = .default
    ) {
        self.operationCenter = operationCenter
        self.processRunner = processRunner
        self.viewerBundlePreparer = viewerBundlePreparer
        self.bamImporter = bamImporter
        self.resultRefresher = resultRefresher
        self.fileManager = fileManager
    }

    @discardableResult
    func run(
        _ request: WorkflowOperationLaunchRequest,
        routeContext: OperationRouteContext? = nil
    ) async throws -> [URL] {
        switch request {
        case .ontGenotyping(let request):
            return try await runONTGenotyping(request, routeContext: routeContext)
        case .workflowPackage(let request, let bundleRoot):
            let service = LocalWorkflowExecutionService(
                operationCenter: operationCenter,
                processRunner: processRunner
            )
            let result = try await service.run(request, bundleRoot: bundleRoot, routeContext: routeContext)
            return [result.bundleURL]
        }
    }

    private func runONTGenotyping(
        _ request: ONTBarcodeDemuxGenotypingRunRequest,
        routeContext: OperationRouteContext?
    ) async throws -> [URL] {
        try fileManager.createDirectory(at: request.outputDirectory, withIntermediateDirectories: true)
        let arguments = ontGenotypingArguments(for: request)
        let cliCommand = ViralReconWorkflowCommandPreview.build(
            executableName: "lungfish-cli",
            arguments: arguments
        )
        let operationID = operationCenter.start(
            title: "ONT Genotyping",
            detail: "Running ONT genotyping workflow",
            operationType: .workflow,
            targetBundleURL: request.outputDirectory,
            cliCommand: cliCommand,
            routeContext: routeContext
        )
        operationCenter.log(id: operationID, level: .info, message: cliCommand)

        do {
            let result = try await processRunner.runLungfishCLI(
                arguments: arguments,
                workingDirectory: request.outputDirectory
            )
            logProcessOutput(result, operationID: operationID)
            if result.exitCode != 0 {
                throw LocalWorkflowExecutionError.nonZeroExit(result.exitCode)
            }
            let cliPayload = decodeONTGenotypingPayload(from: result.standardOutput)
            let outputURLs = ontGenotypingOutputURLs(
                for: request,
                cliPayload: cliPayload
            )
            operationCenter.log(id: operationID, level: .info, message: "Status: completed")
            operationCenter.complete(
                id: operationID,
                detail: "ONT genotyping completed. Output: \(request.outputDirectory.path)",
                outputURLs: outputURLs
            )
            resultRefresher.refresh(
                routeContext: routeContext,
                preferredSelectionURL: preferredSelectionURL(
                    for: request,
                    cliPayload: cliPayload
                )
            )
            return outputURLs
        } catch {
            operationCenter.fail(
                id: operationID,
                detail: "ONT genotyping failed",
                errorMessage: "ONT genotyping failed",
                errorDetail: String(describing: error)
            )
            throw error
        }
    }

    func ontGenotypingArguments(for request: ONTBarcodeDemuxGenotypingRunRequest) -> [String] {
        var arguments = ["fastq", "ont-barcode-genotype", request.inputFASTQURL.path]
        arguments += [
            "--reference", request.referenceSourceURL.path,
            "--barcodes", request.barcodeDefinitionsURL.path,
            "--output-dir", request.outputDirectory.path,
            "--output-name", request.outputName,
            "--analysis-name", request.analysisName,
            "--threads", String(request.threads),
            "--sort-threads", String(request.sortThreads),
            "--min-support", String(request.minSupport),
        ]
        if let demuxManifestURL = request.demuxManifestURL {
            arguments += ["--demux-manifest", demuxManifestURL.path]
        }
        if let comparisonWorkbookURL = request.comparisonWorkbookURL {
            arguments += ["--comparison-workbook", comparisonWorkbookURL.path]
        }
        if let comparisonName = request.comparisonName {
            arguments += ["--comparison-name", comparisonName]
        }
        if let projectURL = request.projectURL {
            arguments += ["--project", projectURL.path]
        }
        if !request.extraArguments.isEmpty {
            arguments += ["--extra-args", AdvancedCommandLineOptions.join(request.extraArguments)]
        }
        return arguments
    }

    private func ontGenotypingOutputURLs(
        for request: ONTBarcodeDemuxGenotypingRunRequest,
        cliPayload: ONTGenotypingCLIPayload?
    ) -> [URL] {
        var urls: [URL] = []
        if let cliPayload {
            urls.append(cliPayload.workbookURL)
            urls.append(cliPayload.reportCSVURL)
            urls.append(cliPayload.sampleSummaryCSVURL)
            urls.append(cliPayload.statsJSONURL)
            urls.append(cliPayload.provenanceURL)
        }
        urls.append(request.workbookURL)
        urls.append(request.reportCSVURL)
        urls.append(request.sampleSummaryCSVURL)
        urls.append(request.statsJSONURL)
        urls.append(request.provenanceURL)
        urls.append(request.outputDirectory)
        return deduplicatedExistingURLs(urls)
    }

    private func prepareONTGenotypingViewerBundlesIfPossible(
        request: ONTBarcodeDemuxGenotypingRunRequest,
        cliPayload: ONTGenotypingCLIPayload?,
        operationID: UUID
    ) async throws -> [URL] {
        guard let sourceBundleURL = sourceReferenceBundleURL(for: request, cliPayload: cliPayload) else {
            return []
        }

        let mappingBAMURL = cliPayload?.mappingBAMURL ?? request.mappingBAMURL
        let retainedBAMURL = cliPayload?.retainedBAMURL ?? request.retainedBAMURL
        let mappingViewerBundleURL = request.outputDirectory.appendingPathComponent(
            "\(request.outputName).mapped.lungfishref",
            isDirectory: true
        )
        let retainedViewerBundleURL = request.outputDirectory.appendingPathComponent(
            "\(request.outputName).retained-demux.lungfishref",
            isDirectory: true
        )

        var preparedURLs: [URL] = []
        for item in [
            (
                bamURL: mappingBAMURL,
                viewerBundleURL: mappingViewerBundleURL,
                trackName: "Pre-filter ONT mapping",
                workflowName: "ONT Genotyping Mapping BAM Viewer Bundle"
            ),
            (
                bamURL: retainedBAMURL,
                viewerBundleURL: retainedViewerBundleURL,
                trackName: "Filtered exact-match demuxed reads",
                workflowName: "ONT Genotyping Retained BAM Viewer Bundle"
            ),
        ] {
            guard fileManager.fileExists(atPath: item.bamURL.path) else { continue }
            operationCenter.update(
                id: operationID,
                progress: 0.96,
                detail: "Preparing \(item.trackName) viewer..."
            )
            operationCenter.log(
                id: operationID,
                level: .info,
                message: "Preparing lightweight reference bundle for \(item.bamURL.lastPathComponent)."
            )
            try viewerBundlePreparer.prepareBaseBundle(
                sourceBundleURL: sourceBundleURL,
                viewerBundleURL: item.viewerBundleURL,
                fileManager: fileManager
            )
            try await bamImporter.importBAM(
                bamURL: item.bamURL,
                bundleURL: item.viewerBundleURL,
                name: item.trackName,
                progressHandler: nil
            )
            try writeONTViewerBundleProvenance(
                workflowName: item.workflowName,
                sourceBundleURL: sourceBundleURL,
                bamURL: item.bamURL,
                viewerBundleURL: item.viewerBundleURL,
                request: request
            )
            preparedURLs.append(item.viewerBundleURL)
        }
        return preparedURLs
    }

    private func sourceReferenceBundleURL(
        for request: ONTBarcodeDemuxGenotypingRunRequest,
        cliPayload: ONTGenotypingCLIPayload?
    ) -> URL? {
        if let sourceReferenceBundlePath = cliPayload?.sourceReferenceBundlePath,
           !sourceReferenceBundlePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let url = URL(fileURLWithPath: sourceReferenceBundlePath).standardizedFileURL
            if fileManager.fileExists(atPath: url.path) {
                return url
            }
        }
        let requestedReferenceURL = request.referenceSourceURL.standardizedFileURL
        guard requestedReferenceURL.pathExtension.lowercased() == "lungfishref",
              fileManager.fileExists(atPath: requestedReferenceURL.path) else {
            return nil
        }
        return requestedReferenceURL
    }

    private func writeONTViewerBundleProvenance(
        workflowName: String,
        sourceBundleURL: URL,
        bamURL: URL,
        viewerBundleURL: URL,
        request: ONTBarcodeDemuxGenotypingRunRequest
    ) throws {
        let startedAt = Date()
        let outputDescriptor = ProvenanceFileDescriptor(
            path: viewerBundleURL.path,
            role: .output
        )
        let referenceDescriptor = ProvenanceFileDescriptor(
            path: sourceBundleURL.path,
            role: .reference
        )
        let bamDescriptor = try ProvenanceFileDescriptor.file(
            url: bamURL,
            format: .bam,
            role: .input
        )
        let argv = [
            "Lungfish.app",
            "workflow-operations",
            "prepare-ont-bam-viewer",
            "--source-reference", sourceBundleURL.path,
            "--bam", bamURL.path,
            "--viewer-bundle", viewerBundleURL.path,
        ]
        let options: [String: ParameterValue] = [
            "outputName": .string(request.outputName),
            "analysisName": .string(request.analysisName),
            "sourceReferenceBundle": .file(sourceBundleURL),
            "bam": .file(bamURL),
            "viewerBundle": .file(viewerBundleURL),
        ]
        let envelope = ProvenanceEnvelope(
            createdAt: startedAt,
            workflowName: workflowName,
            workflowVersion: WorkflowRun.currentAppVersion,
            toolName: "Lungfish.app",
            toolVersion: WorkflowRun.currentAppVersion,
            argv: argv,
            durableReplayArgv: argv,
            options: ProvenanceOptions(explicit: options, resolvedDefaults: options),
            runtimeIdentity: ProvenanceRuntimeIdentity(),
            files: [referenceDescriptor, bamDescriptor, outputDescriptor],
            output: outputDescriptor,
            outputs: [outputDescriptor],
            wallTimeSeconds: Date().timeIntervalSince(startedAt),
            exitStatus: 0
        )
        try ProvenanceWriter(signingProvider: nil).write(envelope, to: viewerBundleURL)
    }

    private func preferredSelectionURL(
        for request: ONTBarcodeDemuxGenotypingRunRequest,
        cliPayload: ONTGenotypingCLIPayload?
    ) -> URL {
        request.outputDirectory
    }

    private func decodeONTGenotypingPayload(from stdout: String) -> ONTGenotypingCLIPayload? {
        guard let data = stdout.data(using: .utf8) else { return nil }
        if let payload = try? JSONDecoder().decode(ONTGenotypingCLIPayload.self, from: data) {
            return payload
        }
        guard let start = stdout.firstIndex(of: "{"),
              let end = stdout.lastIndex(of: "}"),
              start <= end else {
            return nil
        }
        let json = String(stdout[start...end])
        return try? JSONDecoder().decode(ONTGenotypingCLIPayload.self, from: Data(json.utf8))
    }

    private func deduplicatedExistingURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        for url in urls.map(\.standardizedFileURL) {
            guard !url.lastPathComponent.hasPrefix("._") else { continue }
            guard fileManager.fileExists(atPath: url.path) else { continue }
            guard seen.insert(url.path).inserted else { continue }
            result.append(url)
        }
        return result
    }

    private func logProcessOutput(_ result: LocalWorkflowCLIProcessResult, operationID: UUID) {
        for line in result.standardOutput.split(whereSeparator: \.isNewline) {
            operationCenter.log(id: operationID, level: .info, message: String(line))
        }
        for line in result.standardError.split(whereSeparator: \.isNewline) {
            operationCenter.log(id: operationID, level: .warning, message: String(line))
        }
    }
}

private struct ONTGenotypingCLIPayload: Decodable {
    let mappingBAMPath: String
    let mappingBAIPath: String
    let retainedBAMPath: String
    let retainedBAIPath: String
    let reportCSVPath: String
    let sampleSummaryCSVPath: String
    let statsJSONPath: String
    let workbookPath: String
    let provenancePath: String
    let outputDirectory: String
    let referenceFASTAPath: String
    let sourceReferenceBundlePath: String?

    var mappingBAMURL: URL { URL(fileURLWithPath: mappingBAMPath).standardizedFileURL }
    var mappingBAIURL: URL { URL(fileURLWithPath: mappingBAIPath).standardizedFileURL }
    var retainedBAMURL: URL { URL(fileURLWithPath: retainedBAMPath).standardizedFileURL }
    var retainedBAIURL: URL { URL(fileURLWithPath: retainedBAIPath).standardizedFileURL }
    var reportCSVURL: URL { URL(fileURLWithPath: reportCSVPath).standardizedFileURL }
    var sampleSummaryCSVURL: URL { URL(fileURLWithPath: sampleSummaryCSVPath).standardizedFileURL }
    var statsJSONURL: URL { URL(fileURLWithPath: statsJSONPath).standardizedFileURL }
    var workbookURL: URL { URL(fileURLWithPath: workbookPath).standardizedFileURL }
    var provenanceURL: URL { URL(fileURLWithPath: provenancePath).standardizedFileURL }
}
