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
            title: "Amplicon Genotyping",
            detail: "Running amplicon genotyping workflow",
            operationType: .workflow,
            targetBundleURL: request.outputDirectory,
            cliCommand: cliCommand,
            routeContext: routeContext
        )
        operationCenter.log(id: operationID, level: .info, message: cliCommand)
        operationCenter.updateWithLog(
            id: operationID,
            progress: 0.01,
            detail: "Launching lungfish-cli for amplicon genotyping..."
        )

        do {
            let result = try await processRunner.runLungfishCLI(
                arguments: arguments,
                workingDirectory: request.outputDirectory,
                outputHandler: { [operationCenter] output in
                    Self.recordProcessOutput(output, operationID: operationID, operationCenter: operationCenter)
                }
            )
            if !result.didStreamOutput {
                logProcessOutput(result, operationID: operationID)
            }
            if result.exitCode != 0 {
            let failureDetail = "Amplicon genotyping failed with exit code \(result.exitCode)"
                operationCenter.log(id: operationID, level: .error, message: failureDetail)
                operationCenter.fail(
                    id: operationID,
                    detail: failureDetail,
                    errorMessage: "Amplicon genotyping failed",
                    errorDetail: failureDiagnostics(
                        result: result,
                        cliCommand: cliCommand
                    )
                )
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
                detail: "Amplicon genotyping completed. Output: \(request.outputDirectory.path)",
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
                detail: "Amplicon genotyping failed",
                errorMessage: "Amplicon genotyping failed",
                errorDetail: String(describing: error)
            )
            throw error
        }
    }

    func ontGenotypingArguments(for request: ONTBarcodeDemuxGenotypingRunRequest) -> [String] {
        var arguments = ["fastq", "genotype"] + request.inputFASTQURLs.map(\.path)
        arguments += [
            "--mode", request.mode.cliArgument,
            "--read-type", request.readType.cliArgument,
            "--reference", request.referenceSourceURL.path,
            "--output-dir", request.outputDirectory.path,
            "--output-name", request.outputName,
            "--analysis-name", request.analysisName,
            "--threads", String(request.threads),
            "--sort-threads", String(request.sortThreads),
            "--min-support", String(request.minSupport),
        ]
        if let barcodeDefinitionsURL = request.barcodeDefinitionsURL {
            arguments += ["--barcodes", barcodeDefinitionsURL.path]
        }
        if let demuxManifestURL = request.demuxManifestURL {
            arguments += ["--demux-manifest", demuxManifestURL.path]
        }
        if let comparisonWorkbookURL = request.comparisonWorkbookURL {
            arguments += ["--comparison-workbook", comparisonWorkbookURL.path]
        }
        if let comparisonName = request.comparisonName {
            arguments += ["--comparison-name", comparisonName]
        }
        if let haplotypeDefinitionSetID = request.haplotypeDefinitionSetID {
            if let haplotypeAssayID = request.haplotypeAssayID {
                arguments += ["--haplotype-assay", haplotypeAssayID]
            }
            if let haplotypeSpeciesCode = request.haplotypeSpeciesCode {
                arguments += ["--haplotype-species", haplotypeSpeciesCode]
            }
            if let haplotypeDefinitionScope = request.haplotypeDefinitionScope {
                arguments += ["--haplotype-definition-scope", haplotypeDefinitionScope.rawValue]
            }
            arguments += ["--haplotype-definition", haplotypeDefinitionSetID]
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
            Self.recordProcessOutput(
                .standardOutput(String(line)),
                operationID: operationID,
                operationCenter: operationCenter
            )
        }
        for line in result.standardError.split(whereSeparator: \.isNewline) {
            Self.recordProcessOutput(
                .standardError(String(line)),
                operationID: operationID,
                operationCenter: operationCenter
            )
        }
    }

    private static func recordProcessOutput(
        _ output: ViralReconWorkflowProcessOutput,
        operationID: UUID,
        operationCenter: OperationCenter
    ) {
        switch output {
        case .standardOutput(let line):
            operationCenter.log(id: operationID, level: .info, message: line)
        case .standardError(let line):
            if let progress = parseCLIProgressLine(line) {
                operationCenter.updateWithLog(
                    id: operationID,
                    progress: progress.fraction,
                    detail: progress.message
                )
            } else {
                operationCenter.log(id: operationID, level: .warning, message: line)
            }
        }
    }

    private static func parseCLIProgressLine(_ line: String) -> (fraction: Double, message: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "[",
              let closingBracket = trimmed.firstIndex(of: "]") else {
            return nil
        }
        let percentRange = trimmed.index(after: trimmed.startIndex)..<closingBracket
        let percentText = trimmed[percentRange]
            .replacingOccurrences(of: "%", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard let percent = Double(percentText) else {
            return nil
        }
        let messageStart = trimmed.index(after: closingBracket)
        let message = trimmed[messageStart...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (max(0, min(1, percent / 100)), message.isEmpty ? trimmed : message)
    }

    private func failureDiagnostics(
        result: LocalWorkflowCLIProcessResult,
        cliCommand: String
    ) -> String {
        var parts = [
            "lungfish-cli exited with exit code \(result.exitCode).",
            "",
            "CLI command:",
            cliCommand,
        ]
        let stderr = tail(result.standardError)
        if !stderr.isEmpty {
            parts += ["", "stderr:", stderr]
        }
        let stdout = tail(result.standardOutput)
        if !stdout.isEmpty {
            parts += ["", "stdout:", stdout]
        }
        return parts.joined(separator: "\n")
    }

    private func tail(_ text: String, lineLimit: Int = 80) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = trimmed.split(whereSeparator: \.isNewline).map(String.init)
        guard lines.count > lineLimit else { return trimmed }
        return lines.suffix(lineLimit).joined(separator: "\n")
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
