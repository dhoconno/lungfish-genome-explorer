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
        _ request: ONTGenotypingRunRequest,
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
            try await prepareONTGenotypingViewerBundles(
                for: request,
                cliPayload: cliPayload,
                operationID: operationID
            )
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

    func ontGenotypingArguments(for request: ONTGenotypingRunRequest) -> [String] {
        var arguments = ["fastq", "ont-genotype"] + request.inputFASTQURLs.map(\.path)
        arguments += [
            "--reference", request.referenceSourceURL.path,
            "--output-dir", request.outputDirectory.path,
            "--output-name", request.outputName,
            "--threads", String(request.threads),
            "--min-support", String(request.minSupport),
        ]
        if let projectURL = request.projectURL {
            arguments += ["--project", projectURL.path]
        }
        if !request.extraArguments.isEmpty {
            arguments += ["--extra-args", AdvancedCommandLineOptions.join(request.extraArguments)]
        }
        return arguments
    }

    private func ontGenotypingOutputURLs(
        for request: ONTGenotypingRunRequest,
        cliPayload: ONTGenotypingCLIPayload?
    ) -> [URL] {
        var urls: [URL] = []
        if let cliPayload {
            urls.append(cliPayload.reportCSVURL)
            for sample in cliPayload.sampleResults {
                urls.append(sample.mappingBAMURL)
                urls.append(sample.mappingBAIURL)
                urls.append(sample.filteredBAMURL)
                urls.append(sample.filteredBAIURL)
                let sampleDirectory = sample.filteredBAMURL.deletingLastPathComponent().standardizedFileURL
                urls.append(sampleDirectory)
                if let mappingResult = try? MappingResult.load(from: sampleDirectory),
                   let viewerBundleURL = mappingResult.viewerBundleURL {
                    urls.append(viewerBundleURL)
                }
            }
        }
        let reportURL = request.outputDirectory.appendingPathComponent("\(request.outputName).csv")
        if fileManager.fileExists(atPath: reportURL.path) {
            urls.append(reportURL)
        }
        for inputURL in request.inputFASTQURLs {
            let sampleDirectory = request.outputDirectory
                .appendingPathComponent(inputURL.deletingPathExtension().lastPathComponent, isDirectory: true)
            let sampleName = inputURL.deletingPathExtension().lastPathComponent
            let mappingBAM = sampleDirectory.appendingPathComponent("\(sampleName).sorted.bam")
            let mappingBAI = sampleDirectory.appendingPathComponent("\(sampleName).sorted.bam.bai")
            let filteredBAM = sampleDirectory.appendingPathComponent("\(sampleName).ont-genotyping.filtered.bam")
            let filteredBAI = sampleDirectory.appendingPathComponent("\(sampleName).ont-genotyping.filtered.bam.bai")
            urls.append(contentsOf: [mappingBAM, mappingBAI, filteredBAM, filteredBAI])
            if fileManager.fileExists(atPath: sampleDirectory.path) {
                urls.append(sampleDirectory)
                if let mappingResult = try? MappingResult.load(from: sampleDirectory),
                   let viewerBundleURL = mappingResult.viewerBundleURL {
                    urls.append(viewerBundleURL)
                }
            }
        }
        urls.append(request.outputDirectory)
        return deduplicatedExistingURLs(urls)
    }

    private func prepareONTGenotypingViewerBundles(
        for request: ONTGenotypingRunRequest,
        cliPayload: ONTGenotypingCLIPayload?,
        operationID: UUID
    ) async throws {
        guard let cliPayload, !cliPayload.sampleResults.isEmpty else { return }

        let fallbackSourceBundleURL = resolvedSourceReferenceBundleURL(
            for: request,
            cliPayload: cliPayload
        )
        let totalSamples = max(1, cliPayload.sampleResults.count)

        for (index, sample) in cliPayload.sampleResults.enumerated() {
            let sampleDirectory = sample.filteredBAMURL.deletingLastPathComponent().standardizedFileURL
            guard fileManager.fileExists(atPath: sampleDirectory.path) else { continue }

            let filteredMappingResult = try MappingResult.load(from: sampleDirectory)
            guard let sourceBundleURL = filteredMappingResult.sourceReferenceBundleURL ?? fallbackSourceBundleURL,
                  fileManager.fileExists(atPath: sourceBundleURL.path) else {
                operationCenter.log(
                    id: operationID,
                    level: .warning,
                    message: "Skipping integrated BAM viewer for \(sample.sampleName): source reference bundle unavailable."
                )
                continue
            }

            let viewerBundleURL = sampleDirectory.appendingPathComponent(
                sourceBundleURL.lastPathComponent,
                isDirectory: true
            )
            let sampleBaseProgress = 0.82 + (Double(index) / Double(totalSamples)) * 0.15
            operationCenter.update(
                id: operationID,
                progress: sampleBaseProgress,
                detail: "Preparing integrated BAM viewer for \(sample.sampleName)..."
            )
            operationCenter.log(
                id: operationID,
                level: .info,
                message: "Preparing integrated BAM viewer for \(sample.sampleName)."
            )

            try viewerBundlePreparer.prepareBaseBundle(
                sourceBundleURL: sourceBundleURL,
                viewerBundleURL: viewerBundleURL,
                fileManager: fileManager
            )
            try await bamImporter.importBAM(
                bamURL: filteredMappingResult.bamURL,
                bundleURL: viewerBundleURL,
                name: "ONT Genotyping",
                progressHandler: { [operationCenter] fraction, message in
                    Task { @MainActor in
                        let progress = sampleBaseProgress + (fraction * 0.15 / Double(totalSamples))
                        operationCenter.update(id: operationID, progress: progress, detail: message)
                        operationCenter.log(id: operationID, level: .info, message: message)
                    }
                }
            )

            let preparedResult = filteredMappingResult.withViewerBundle(
                viewerBundleURL: viewerBundleURL,
                sourceReferenceBundleURL: sourceBundleURL
            )
            try preparedResult.save(to: sampleDirectory)
            if let provenance = MappingProvenance.load(from: sampleDirectory) {
                let updatedProvenance = provenance
                    .withViewerBundleURL(viewerBundleURL)
                    .withSourceReferenceBundleURL(sourceBundleURL)
                try updatedProvenance.save(to: sampleDirectory)
                try updatedProvenance.saveCanonicalEnvelope(to: sampleDirectory)
            }
        }
    }

    private func resolvedSourceReferenceBundleURL(
        for request: ONTGenotypingRunRequest,
        cliPayload: ONTGenotypingCLIPayload
    ) -> URL? {
        if let sourceReferenceBundlePath = cliPayload.sourceReferenceBundlePath {
            return URL(fileURLWithPath: sourceReferenceBundlePath).standardizedFileURL
        }
        if request.referenceSourceURL.pathExtension.lowercased() == "lungfishref" {
            return request.referenceSourceURL.standardizedFileURL
        }
        return nil
    }

    private func preferredSelectionURL(
        for request: ONTGenotypingRunRequest,
        cliPayload: ONTGenotypingCLIPayload?
    ) -> URL {
        guard let cliPayload, cliPayload.sampleResults.count == 1,
              let sample = cliPayload.sampleResults.first else {
            return request.outputDirectory.standardizedFileURL
        }
        return sample.filteredBAMURL.deletingLastPathComponent().standardizedFileURL
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
    let reportCSVPath: String
    let outputDirectory: String
    let referenceFASTAPath: String
    let sourceReferenceBundlePath: String?
    let sampleResults: [ONTGenotypingCLISamplePayload]

    var reportCSVURL: URL { URL(fileURLWithPath: reportCSVPath).standardizedFileURL }
}

private struct ONTGenotypingCLISamplePayload: Decodable {
    let inputFASTQPath: String
    let sampleName: String
    let mappingBAMPath: String
    let mappingBAIPath: String?
    let filteredBAMPath: String
    let filteredBAIPath: String
    let totalReads: Int
    let filteredAlignments: Int

    var mappingBAMURL: URL { URL(fileURLWithPath: mappingBAMPath).standardizedFileURL }
    var mappingBAIURL: URL {
        URL(fileURLWithPath: mappingBAIPath ?? "\(mappingBAMPath).bai").standardizedFileURL
    }
    var filteredBAMURL: URL { URL(fileURLWithPath: filteredBAMPath).standardizedFileURL }
    var filteredBAIURL: URL { URL(fileURLWithPath: filteredBAIPath).standardizedFileURL }
}
