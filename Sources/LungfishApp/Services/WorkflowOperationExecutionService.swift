import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow
import LungfishKit

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

struct WorkflowOperationAIHaplotypingPublication: Sendable {
    let revision: ONTGenotypeHaplotypeAnalysisRevision
    let analysis: GenotypeHaplotypeAnalysis
    let provenanceURL: URL
}

protocol WorkflowOperationAIHaplotypingRunning: Sendable {
    @MainActor
    func run(
        bundleURL: URL,
        mode: AIHaplotypingPromptMode,
        routeContext: OperationRouteContext?,
        parentOperationID: UUID?
    ) async throws -> WorkflowOperationAIHaplotypingPublication
}

final class DefaultWorkflowOperationAIHaplotyper: WorkflowOperationAIHaplotypingRunning, @unchecked Sendable {
    private let operationCenter: OperationCenter

    @MainActor
    init(operationCenter: OperationCenter = .shared) {
        self.operationCenter = operationCenter
    }

    @MainActor
    func run(
        bundleURL: URL,
        mode: AIHaplotypingPromptMode,
        routeContext: OperationRouteContext?,
        parentOperationID: UUID?
    ) async throws -> WorkflowOperationAIHaplotypingPublication {
        let published = try await GenotypeAIHaplotypingExecutionService(
            operationCenter: operationCenter
        ).run(
            bundleURL: bundleURL,
            mode: mode,
            routeContext: routeContext,
            parentOperationID: parentOperationID
        )
        return WorkflowOperationAIHaplotypingPublication(
            revision: published.revision,
            analysis: published.analysis,
            provenanceURL: published.provenanceURL
        )
    }
}

protocol WorkflowOperationWorkbookUpdating: Sendable {
    func applyHaplotypeCalls(
        _ calls: [GenotypeWorkbookHaplotypeCall],
        annotationSidecarURL: URL?,
        into bundleURL: URL,
        provenanceContext: GenotypeWorkbookRevisionProvenanceContext?
    ) async throws -> URL
}

struct DefaultWorkflowOperationWorkbookUpdater: WorkflowOperationWorkbookUpdating {
    typealias PythonExecutableResolver = @Sendable () async throws -> URL
    typealias HaplotypeOverrideApplier = @Sendable (
        _ calls: [GenotypeWorkbookHaplotypeCall],
        _ annotationSidecarURL: URL?,
        _ bundleURL: URL,
        _ provenanceContext: GenotypeWorkbookRevisionProvenanceContext?,
        _ pythonExecutableURL: URL
    ) throws -> URL

    private let pythonExecutableResolver: PythonExecutableResolver
    private let haplotypeOverrideApplier: HaplotypeOverrideApplier

    init(
        pythonExecutableResolver: @escaping PythonExecutableResolver = {
            try await CondaManager.shared.toolPath(name: "python", environment: "openpyxl")
        },
        haplotypeOverrideApplier: @escaping HaplotypeOverrideApplier = { calls, annotationSidecarURL, bundleURL, provenanceContext, pythonExecutableURL in
            let manifest = try GenotypeWorkbookRevisionService(pythonExecutableURL: pythonExecutableURL)
                .applyHaplotypeOverrides(
                    calls,
                    annotationSidecarURL: annotationSidecarURL,
                    into: bundleURL,
                    provenanceContext: provenanceContext
                )
            if let currentWorkbookPath = manifest.currentWorkbookPath {
                return ONTGenotypeResultBundle.resolvedURL(for: currentWorkbookPath, in: bundleURL)
            }
            return try ONTGenotypeResultBundle.currentWorkbookURL(for: bundleURL)
        }
    ) {
        self.pythonExecutableResolver = pythonExecutableResolver
        self.haplotypeOverrideApplier = haplotypeOverrideApplier
    }

    func applyHaplotypeCalls(
        _ calls: [GenotypeWorkbookHaplotypeCall],
        annotationSidecarURL: URL?,
        into bundleURL: URL,
        provenanceContext: GenotypeWorkbookRevisionProvenanceContext?
    ) async throws -> URL {
        let pythonExecutableURL = try await pythonExecutableResolver()
        return try haplotypeOverrideApplier(
            calls,
            annotationSidecarURL,
            bundleURL,
            provenanceContext,
            pythonExecutableURL
        )
    }
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
    private let aiHaplotyper: WorkflowOperationAIHaplotypingRunning
    private let workbookUpdater: WorkflowOperationWorkbookUpdating
    private let fileManager: FileManager

    init(
        operationCenter: OperationCenter = .shared,
        processRunner: LocalWorkflowCLIProcessRunning = ProcessLocalWorkflowCLIProcessRunner(),
        viewerBundlePreparer: WorkflowOperationViewerBundlePreparing = DefaultWorkflowOperationViewerBundlePreparer(),
        bamImporter: WorkflowOperationBAMImporting = DefaultWorkflowOperationBAMImporter(),
        resultRefresher: WorkflowOperationResultRefreshing = DefaultWorkflowOperationResultRefresher(),
        aiHaplotyper: WorkflowOperationAIHaplotypingRunning? = nil,
        workbookUpdater: WorkflowOperationWorkbookUpdating = DefaultWorkflowOperationWorkbookUpdater(),
        fileManager: FileManager = .default
    ) {
        self.operationCenter = operationCenter
        self.processRunner = processRunner
        self.viewerBundlePreparer = viewerBundlePreparer
        self.bamImporter = bamImporter
        self.resultRefresher = resultRefresher
        self.aiHaplotyper = aiHaplotyper ?? DefaultWorkflowOperationAIHaplotyper(operationCenter: operationCenter)
        self.workbookUpdater = workbookUpdater
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
        case .fullLengthONTMHCGenotyping(let request):
            return try await runFullLengthONTMHCGenotyping(request, routeContext: routeContext)
        case .twelveSAmpliconMatching(let configuration):
            return try await runTwelveSAmpliconMatching(configuration, routeContext: routeContext)
        case .workflowPackage(let request, let bundleRoot):
            let service = LocalWorkflowExecutionService(
                operationCenter: operationCenter,
                processRunner: processRunner
            )
            let result = try await service.run(request, bundleRoot: bundleRoot, routeContext: routeContext)
            return [result.bundleURL]
        }
    }

    @discardableResult
    func runTwelveSReferenceBundleBuild(
        _ configuration: TwelveSReferenceBundleBuildConfiguration,
        routeContext: OperationRouteContext? = nil
    ) async throws -> [URL] {
        try fileManager.createDirectory(
            at: configuration.outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let arguments = twelveSReferenceBundleArguments(for: configuration)
        let cliCommand = ViralReconWorkflowCommandPreview.build(
            executableName: CLICommandIdentity.executableName,
            arguments: arguments
        )
        let operationID = operationCenter.start(
            title: "12S Reference Bundle",
            detail: "Creating 12S reference bundle",
            operationType: .workflow,
            targetBundleURL: configuration.outputURL,
            cliCommand: cliCommand,
            routeContext: routeContext
        )
        operationCenter.log(id: operationID, level: .info, message: cliCommand)
        _ = operationCenter.updateWithLog(
            id: operationID,
            progress: 0.01,
            detail: "Launching lungfish-cli for 12S reference bundle creation..."
        )

        do {
            let result = try await processRunner.runLungfishCLI(
                arguments: arguments,
                workingDirectory: configuration.outputURL.deletingLastPathComponent(),
                outputHandler: { [operationCenter] output in
                    Self.recordProcessOutput(output, operationID: operationID, operationCenter: operationCenter)
                }
            )
            if !result.didStreamOutput {
                logProcessOutput(result, operationID: operationID)
            }
            if result.exitCode != 0 {
                let failureDetail = "12S reference bundle creation failed with exit code \(result.exitCode)"
                operationCenter.log(id: operationID, level: .error, message: failureDetail)
                _ = operationCenter.fail(
                    id: operationID,
                    detail: failureDetail,
                    errorMessage: "12S reference bundle creation failed",
                    errorDetail: failureDiagnostics(
                        result: result,
                        cliCommand: cliCommand
                    )
                )
                throw LocalWorkflowExecutionError.nonZeroExit(result.exitCode)
            }
            try verifyTwelveSReferenceBundleProvenance(at: configuration.outputURL)
            let outputURLs = deduplicatedExistingURLs([
                configuration.outputURL,
                TwelveSReferenceBundle.manifestURL(in: configuration.outputURL),
                TwelveSReferenceBundle.targetMetadataURL(in: configuration.outputURL),
                TwelveSReferenceBundle.provenanceURL(in: configuration.outputURL),
            ].compactMap { $0 })
            operationCenter.log(id: operationID, level: .info, message: "Status: completed")
            _ = operationCenter.complete(
                id: operationID,
                detail: "12S reference bundle created. Output: \(configuration.outputURL.path)",
                outputURLs: outputURLs
            )
            resultRefresher.refresh(
                routeContext: routeContext,
                preferredSelectionURL: configuration.outputURL
            )
            return outputURLs
        } catch {
            _ = operationCenter.fail(
                id: operationID,
                detail: "12S reference bundle creation failed",
                errorMessage: "12S reference bundle creation failed",
                errorDetail: error.localizedDescription
            )
            throw error
        }
    }

    private func runTwelveSAmpliconMatching(
        _ configuration: TwelveSAmpliconMatchingConfiguration,
        routeContext: OperationRouteContext?
    ) async throws -> [URL] {
        try fileManager.createDirectory(at: configuration.outputDirectory, withIntermediateDirectories: true)
        let arguments = twelveSAmpliconMatchingArguments(for: configuration)
        let cliCommand = ViralReconWorkflowCommandPreview.build(
            executableName: CLICommandIdentity.executableName,
            arguments: arguments
        )
        let bundleURL = twelveSAmpliconMatchingBundleURL(for: configuration)
        let operationID = operationCenter.start(
            title: "12S Amplicon Matching",
            detail: "Running 12S amplicon matching workflow",
            operationType: .workflow,
            targetBundleURL: bundleURL,
            cliCommand: cliCommand,
            routeContext: routeContext
        )
        operationCenter.log(id: operationID, level: .info, message: cliCommand)
        _ = operationCenter.updateWithLog(
            id: operationID,
            progress: 0.01,
            detail: "Launching lungfish-cli for 12S amplicon matching..."
        )

        do {
            let result = try await processRunner.runLungfishCLI(
                arguments: arguments,
                workingDirectory: configuration.outputDirectory,
                outputHandler: { [operationCenter] output in
                    Self.recordProcessOutput(output, operationID: operationID, operationCenter: operationCenter)
                }
            )
            if !result.didStreamOutput {
                logProcessOutput(result, operationID: operationID)
            }
            if result.exitCode != 0 {
                let failureDetail = "12S amplicon matching failed with exit code \(result.exitCode)"
                operationCenter.log(id: operationID, level: .error, message: failureDetail)
                _ = operationCenter.fail(
                    id: operationID,
                    detail: failureDetail,
                    errorMessage: "12S amplicon matching failed",
                    errorDetail: failureDiagnostics(
                        result: result,
                        cliCommand: cliCommand
                    )
                )
                throw LocalWorkflowExecutionError.nonZeroExit(result.exitCode)
            }
            try verifyTwelveSAmpliconBundleProvenance(at: bundleURL)
            let outputURLs = deduplicatedExistingURLs([
                bundleURL,
                bundleURL.appendingPathComponent(TwelveSAmpliconResultBundleManifest.filename),
                bundleURL.appendingPathComponent(ProvenanceRecorder.provenanceFilename),
            ])
            operationCenter.log(id: operationID, level: .info, message: "Status: completed")
            _ = operationCenter.complete(
                id: operationID,
                detail: "12S amplicon matching completed. Output: \(bundleURL.path)",
                outputURLs: outputURLs
            )
            resultRefresher.refresh(
                routeContext: routeContext,
                preferredSelectionURL: bundleURL
            )
            return outputURLs
        } catch {
            _ = operationCenter.fail(
                id: operationID,
                detail: "12S amplicon matching failed",
                errorMessage: "12S amplicon matching failed",
                errorDetail: error.localizedDescription
            )
            throw error
        }
    }

    private func runONTGenotyping(
        _ request: ONTBarcodeDemuxGenotypingRunRequest,
        routeContext: OperationRouteContext?
    ) async throws -> [URL] {
        let request = try uniqueONTGenotypingRequestIfNeeded(request)
        try fileManager.createDirectory(at: request.outputDirectory, withIntermediateDirectories: true)
        let arguments = ontGenotypingArguments(for: request)
        let cliCommand = ViralReconWorkflowCommandPreview.build(
            executableName: CLICommandIdentity.executableName,
            arguments: arguments
        )
        let operationID = operationCenter.start(
            title: "miSeq amplicon MHC genotyping",
            detail: "Running miSeq amplicon MHC genotyping workflow",
            operationType: .workflow,
            targetBundleURL: request.outputDirectory,
            cliCommand: cliCommand,
            routeContext: routeContext
        )
        operationCenter.log(id: operationID, level: .info, message: cliCommand)
        _ = operationCenter.updateWithLog(
            id: operationID,
            progress: 0.01,
            detail: "Launching lungfish-cli for miSeq amplicon MHC genotyping..."
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
                let failureDetail = "miSeq amplicon MHC genotyping failed with exit code \(result.exitCode)"
                operationCenter.log(id: operationID, level: .error, message: failureDetail)
                _ = operationCenter.fail(
                    id: operationID,
                    detail: failureDetail,
                    errorMessage: "miSeq amplicon MHC genotyping failed",
                    errorDetail: failureDiagnostics(
                        result: result,
                        cliCommand: cliCommand
                    )
                )
                throw LocalWorkflowExecutionError.nonZeroExit(result.exitCode)
            }
            let cliPayload = decodeONTGenotypingPayload(from: result.standardOutput)
            var outputURLs = ontGenotypingOutputURLs(
                for: request,
                cliPayload: cliPayload
            )
            let scientificArtifactURLs = try await validatedONTGenotypingScientificArtifactURLs(
                in: request.outputDirectory
            )
            outputURLs = deduplicatedExistingURLs(
                outputURLs + scientificArtifactURLs
            )
            if request.aiSpecialistPresetID != nil {
                _ = operationCenter.updateWithLog(
                    id: operationID,
                    progress: 0.9,
                    detail: "Running specialist AI haplotyping..."
                )
                let published = try await aiHaplotyper.run(
                    bundleURL: request.outputDirectory,
                    mode: .aiDiscovery,
                    routeContext: routeContext,
                    parentOperationID: operationID
                )
                _ = operationCenter.updateWithLog(
                    id: operationID,
                    progress: 0.96,
                    detail: "Updating current.xlsx with specialist AI haplotypes..."
                )
                let currentWorkbookURL = try await workbookUpdater.applyHaplotypeCalls(
                    Self.workbookHaplotypeCalls(from: published.analysis),
                    annotationSidecarURL: ONTGenotypeResultBundleData.annotationSidecarURL(
                        forBundleAt: request.outputDirectory
                    ),
                    into: request.outputDirectory,
                    provenanceContext: Self.aiWorkbookUpdateProvenanceContext(
                        request: request,
                        publication: published
                    )
                )
                let analysisURL = ONTGenotypeResultBundle.resolvedURL(
                    for: published.revision.path,
                    in: request.outputDirectory
                )
                outputURLs = deduplicatedExistingURLs(
                    outputURLs + [
                        analysisURL,
                        published.provenanceURL,
                        currentWorkbookURL,
                        ONTGenotypeResultBundleData.annotationSidecarURL(forBundleAt: request.outputDirectory),
                    ]
                )
            }
            operationCenter.log(id: operationID, level: .info, message: "Status: completed")
            _ = operationCenter.complete(
                id: operationID,
                detail: "miSeq amplicon MHC genotyping completed. Output: \(request.outputDirectory.path)",
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
            _ = operationCenter.fail(
                id: operationID,
                detail: "miSeq amplicon MHC genotyping failed",
                errorMessage: "miSeq amplicon MHC genotyping failed",
                errorDetail: error.localizedDescription
            )
            throw error
        }
    }

    private func runFullLengthONTMHCGenotyping(
        _ request: FullLengthONTMHCGenotypingRunRequest,
        routeContext: OperationRouteContext?
    ) async throws -> [URL] {
        let outputParentDirectory = request.outputDirectory.deletingLastPathComponent()
        try fileManager.createDirectory(at: outputParentDirectory, withIntermediateDirectories: true)
        let arguments = fullLengthONTMHCGenotypingArguments(for: request)
        let cliCommand = ViralReconWorkflowCommandPreview.build(
            executableName: CLICommandIdentity.executableName,
            arguments: arguments
        )
        let operationID = operationCenter.start(
            title: "Full-length ONT MHC genotyping",
            detail: "Running full-length ONT MHC genotyping workflow",
            operationType: .workflow,
            targetBundleURL: request.outputDirectory,
            cliCommand: cliCommand,
            routeContext: routeContext
        )
        operationCenter.log(id: operationID, level: .info, message: cliCommand)
        _ = operationCenter.updateWithLog(
            id: operationID,
            progress: 0.01,
            detail: "Launching lungfish-cli for full-length ONT MHC genotyping..."
        )

        do {
            let result = try await processRunner.runLungfishCLI(
                arguments: arguments,
                workingDirectory: outputParentDirectory,
                outputHandler: { [operationCenter] output in
                    Self.recordProcessOutput(output, operationID: operationID, operationCenter: operationCenter)
                }
            )
            if !result.didStreamOutput {
                logProcessOutput(result, operationID: operationID)
            }
            if result.exitCode != 0 {
                let failureDetail = "Full-length ONT MHC genotyping failed with exit code \(result.exitCode)"
                operationCenter.log(id: operationID, level: .error, message: failureDetail)
                _ = operationCenter.fail(
                    id: operationID,
                    detail: failureDetail,
                    errorMessage: "Full-length ONT MHC genotyping failed",
                    errorDetail: failureDiagnostics(result: result, cliCommand: cliCommand)
                )
                throw LocalWorkflowExecutionError.nonZeroExit(result.exitCode)
            }
            let cliPayload = decodeFullLengthONTMHCGenotypingPayload(from: result.standardOutput)
            let outputURLs = fullLengthONTMHCGenotypingOutputURLs(for: request, cliPayload: cliPayload)
            operationCenter.log(id: operationID, level: .info, message: "Status: completed")
            _ = operationCenter.complete(
                id: operationID,
                detail: "Full-length ONT MHC genotyping completed. Output: \(request.outputDirectory.path)",
                outputURLs: outputURLs
            )
            resultRefresher.refresh(
                routeContext: routeContext,
                preferredSelectionURL: request.outputDirectory
            )
            return outputURLs
        } catch {
            _ = operationCenter.fail(
                id: operationID,
                detail: "Full-length ONT MHC genotyping failed",
                errorMessage: "Full-length ONT MHC genotyping failed",
                errorDetail: error.localizedDescription
            )
            throw error
        }
    }

    func ontGenotypingArguments(for request: ONTBarcodeDemuxGenotypingRunRequest) -> [String] {
        Array(request.argv.dropFirst())
    }

    func fullLengthONTMHCGenotypingArguments(for request: FullLengthONTMHCGenotypingRunRequest) -> [String] {
        var arguments = ["fastq", "full-length-ont-mhc-genotype"] + request.inputFASTQURLs.map(\.path)
        arguments += [
            "--reference", request.referenceSourceURL.path,
            "--output-dir", request.outputDirectory.path,
            "--output-name", request.outputName,
            "--threads", String(request.threads),
            "--min-length", String(request.minimumLength),
            "--max-length", String(request.maximumLength),
            "--savont-quality-value-cutoff", String(request.savontQualityValueCutoff),
            "--savont-min-cluster-size", String(request.savontMinimumClusterSize),
            "--min-unmatched-reads", String(request.minUnmatchedReads),
            "--cdna-threshold", String(request.cdnaThreshold),
        ]
        request.appendHaplotypeThresholdArguments(to: &arguments)
        if let orientReferenceURL = request.orientReferenceURL {
            arguments += ["--orient-reference", orientReferenceURL.path]
        }
        if let forwardPrimerURL = request.forwardPrimerURL {
            arguments += ["--forward-primer", forwardPrimerURL.path]
        }
        if let reversePrimerURL = request.reversePrimerURL {
            arguments += ["--reverse-primer", reversePrimerURL.path]
        }
        if let projectURL = request.projectURL {
            arguments += ["--project", projectURL.path]
        }
        if let sampleJobs = request.sampleJobs {
            arguments += ["--sample-jobs", String(sampleJobs)]
        }
        if let savontThreadsPerSample = request.savontThreadsPerSample {
            arguments += ["--savont-threads-per-sample", String(savontThreadsPerSample)]
        }
        if request.keepIntermediates {
            arguments += ["--keep-intermediates"]
        }
        if request.reuseCompatibleCheckpoints {
            arguments += ["--reuse-compatible-checkpoints"]
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
        return arguments
    }

    private func ontGenotypingSubcommand(for request: ONTBarcodeDemuxGenotypingRunRequest) -> String {
        let illuminaCohort = request.inputFASTQURLs.count > 1
            && request.barcodeDefinitionsURL == nil
            && (request.mode == .illuminaPaired || (request.mode == .auto && request.readType == .illumina))
        let ontSampleBundleCohort = request.inputFASTQURLs.count > 1
            && request.barcodeDefinitionsURL == nil
            && (request.mode == .ontSampleBundles || (request.mode == .auto && request.readType == .ont))
        return illuminaCohort || ontSampleBundleCohort ? "genotype-cohort" : "genotype"
    }

    private func uniqueONTGenotypingRequestIfNeeded(
        _ request: ONTBarcodeDemuxGenotypingRunRequest
    ) throws -> ONTBarcodeDemuxGenotypingRunRequest {
        guard try outputBundleIsOccupied(request.outputDirectory) else {
            return request
        }
        let parentURL = request.outputDirectory.deletingLastPathComponent()
        let baseOutputName = request.outputName
        let baseAnalysisName = request.analysisName
        for index in 1...999 {
            let candidateOutputName = "\(baseOutputName)_\(index)"
            let candidateAnalysisName = "\(baseAnalysisName)_\(index)"
            let candidateURL = parentURL.appendingPathComponent(
                "\(candidateOutputName).\(ONTGenotypeResultBundle.directoryExtension)",
                isDirectory: true
            )
            if try !outputBundleIsOccupied(candidateURL) {
                return request.replacingOutput(
                    outputDirectory: candidateURL,
                    outputName: candidateOutputName,
                    analysisName: candidateAnalysisName
                )
            }
        }
        throw LocalWorkflowExecutionError.incompleteRunBundle(
            "Could not find an unused report name near \(request.outputDirectory.path)"
        )
    }

    private func outputBundleIsOccupied(_ url: URL) throws -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return false
        }
        guard isDirectory.boolValue else {
            return true
        }
        let visibleContents = try fileManager.contentsOfDirectory(atPath: url.path)
            .filter { $0 != ".DS_Store" }
        return !visibleContents.isEmpty
    }

    func twelveSAmpliconMatchingArguments(for configuration: TwelveSAmpliconMatchingConfiguration) -> [String] {
        var arguments = ["fastq", "12s-match"] + configuration.inputFASTQs.map(\.path)
        let referenceURL = configuration.referenceBundleURL ?? configuration.referenceFASTA
        arguments += [
            "--reference", referenceURL.path,
        ]
        if let referenceMetadata = configuration.referenceMetadata,
           !Self.isBundledTwelveSReferenceMetadata(referenceMetadata, bundleURL: configuration.referenceBundleURL) {
            arguments += ["--reference-metadata", referenceMetadata.path]
        }
        if let sampleMetadata = configuration.sampleMetadata {
            arguments += ["--sample-metadata", sampleMetadata.path]
        }
        arguments += [
            "--output-dir", configuration.outputDirectory.path,
            "--output-name", configuration.outputName,
        ]
        if configuration.minimumSoftClipBases != 1 {
            arguments += ["--min-soft-clip", String(configuration.minimumSoftClipBases)]
        }
        if configuration.maximumIndelBases != 3 {
            arguments += ["--max-indels", String(configuration.maximumIndelBases)]
        }
        arguments += ["--matching-mode", configuration.matchingMode.rawValue]
        if configuration.threads != 1 {
            arguments += ["--threads", String(configuration.threads)]
        }
        if !configuration.runChimeraReview {
            arguments.append("--no-chimera-review")
        }
        if configuration.forceOverwrite {
            arguments.append("--force")
        }
        return arguments
    }

    func twelveSReferenceBundleArguments(for configuration: TwelveSReferenceBundleBuildConfiguration) -> [String] {
        var arguments = [
            "fastq", "12s-reference-bundle",
            "--dedup-fasta", configuration.deduplicatedFASTA.path,
            "--midori-metadata", configuration.midoriMetadataTSV.path,
            "--output", configuration.outputURL.path,
        ]
        if let name = configuration.name,
           !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            arguments += ["--name", name]
        }
        for sourceFile in configuration.sourceFiles {
            arguments += ["--source-file", sourceFile.path]
        }
        for sourceDirectory in configuration.sourceDirectories {
            arguments += ["--source-directory", sourceDirectory.path]
        }
        if configuration.forceOverwrite {
            arguments.append("--force")
        }
        return arguments
    }

    private static func isBundledTwelveSReferenceMetadata(_ metadataURL: URL, bundleURL: URL?) -> Bool {
        guard let bundleURL,
              let bundledURL = TwelveSReferenceBundle.targetMetadataURL(in: bundleURL) else {
            return false
        }
        return metadataURL.standardizedFileURL == bundledURL.standardizedFileURL
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
        urls.append(request.currentWorkbookURL)
        if request.haplotypeDefinitionSetID != nil {
            urls.append(request.haplotypeAnalysisURL)
        }
        urls.append(request.reportCSVURL)
        urls.append(request.sampleSummaryCSVURL)
        urls.append(request.statsJSONURL)
        urls.append(request.provenanceURL)
        urls.append(request.outputDirectory)
        return deduplicatedExistingURLs(urls)
    }

    private func validatedONTGenotypingScientificArtifactURLs(
        in bundleURL: URL
    ) async throws -> [URL] {
        guard let manifest = try? ONTGenotypeResultBundle.loadManifest(from: bundleURL),
              manifest.alignmentArtifacts?.genotypingEvidence != nil
                || manifest.provisionalExon2Artifacts != nil else {
            return []
        }
        let result = try await ONTGenotypeResultBundle.loadResultAsync(
            from: bundleURL
        )
        return [
            result.alignmentArtifactURLs.genotypingBAM,
            result.alignmentArtifactURLs.genotypingBAI,
            result.provisionalExon2ArtifactURLs.catalogJSON,
            result.provisionalExon2ArtifactURLs.sequencesFASTA,
        ].compactMap { $0 }
    }

    static func workbookHaplotypeCalls(
        from analysis: GenotypeHaplotypeAnalysis
    ) -> [GenotypeWorkbookHaplotypeCall] {
        analysis.samples.flatMap { sample in
            sample.calls.filter {
                GenotypeWorkbookHaplotypeCall.isWritableCurrentWorkbookLocus($0.locus)
            }.map { call in
                GenotypeWorkbookHaplotypeCall(
                    sample: sample.sample,
                    locus: call.locus,
                    haplotype1: call.haplotype1,
                    haplotype2: call.haplotype2,
                    status: call.status.rawValue,
                    notes: call.notes
                )
            }
        }
    }

    private static func aiWorkbookUpdateProvenanceContext(
        request: ONTBarcodeDemuxGenotypingRunRequest,
        publication: WorkflowOperationAIHaplotypingPublication
    ) -> GenotypeWorkbookRevisionProvenanceContext {
        let argv = [
            "lungfish-gui",
            "workflow",
            "miseq-amplicon-mhc-genotyping",
            "--output-dir",
            request.outputDirectory.path,
            "--output-name",
            request.outputName,
            "--ai-specialist-preset",
            request.aiSpecialistPresetID ?? "unspecified",
            "--ai-revision",
            publication.revision.id,
        ]
        return GenotypeWorkbookRevisionProvenanceContext(
            toolName: "Lungfish Genome Explorer miSeq amplicon MHC AI haplotyping workflow",
            toolKind: "gui",
            argv: argv
        )
    }

    private func fullLengthONTMHCGenotypingOutputURLs(
        for request: FullLengthONTMHCGenotypingRunRequest,
        cliPayload: FullLengthONTMHCGenotypingCLIPayload?
    ) -> [URL] {
        var urls: [URL] = []
        if let cliPayload {
            urls.append(cliPayload.workbookURL)
            if let primaryWorkbookURL = cliPayload.primaryWorkbookURL {
                urls.append(primaryWorkbookURL)
            }
            if let haplotypeAnalysisURL = cliPayload.haplotypeAnalysisURL {
                urls.append(haplotypeAnalysisURL)
            }
            urls.append(cliPayload.reportCSVURL)
            urls.append(cliPayload.sampleSummaryCSVURL)
            urls.append(cliPayload.statsJSONURL)
            urls.append(cliPayload.unmatchedClustersFASTAURL)
            urls.append(cliPayload.cdnaClustersFASTAURL)
            urls.append(cliPayload.provenanceURL)
        }
        urls.append(request.workbookURL)
        urls.append(request.currentWorkbookURL)
        if request.haplotypeDefinitionSetID != nil {
            urls.append(request.haplotypeAnalysisURL)
        }
        urls.append(request.reportCSVURL)
        urls.append(request.sampleSummaryCSVURL)
        urls.append(request.statsJSONURL)
        urls.append(request.unmatchedClustersFASTAURL)
        urls.append(request.cdnaClustersFASTAURL)
        urls.append(request.provenanceURL)
        urls.append(request.outputDirectory)
        return deduplicatedExistingURLs(urls)
    }

    private func twelveSAmpliconMatchingBundleURL(
        for configuration: TwelveSAmpliconMatchingConfiguration
    ) -> URL {
        configuration.outputDirectory.appendingPathComponent(
            "\(configuration.outputName).\(TwelveSAmpliconResultBundle.directoryExtension)",
            isDirectory: true
        )
    }

    private func verifyTwelveSAmpliconBundleProvenance(at bundleURL: URL) throws {
        let provenanceURL = bundleURL.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        guard fileManager.fileExists(atPath: provenanceURL.path) else {
            throw LocalWorkflowExecutionError.missingProvenance(provenanceURL.path)
        }
        guard let envelope = try ProvenanceEnvelopeReader.load(from: bundleURL),
              Self.isTwelveSAmpliconMatchingProvenance(envelope),
              envelope.exitStatus == 0,
              !envelope.argv.isEmpty else {
            throw LocalWorkflowExecutionError.invalidProvenance(provenanceURL.path)
        }

        let bundlePath = bundleURL.standardizedFileURL.path
        let outputPaths = Set(
            (envelope.outputs + envelope.steps.flatMap(\.outputs))
                .map { URL(fileURLWithPath: $0.path).standardizedFileURL.path }
        )
        guard outputPaths.contains(bundlePath) || outputPaths.contains(where: { $0.hasPrefix(bundlePath + "/") }) else {
            throw LocalWorkflowExecutionError.invalidProvenance(provenanceURL.path)
        }
    }

    private func verifyTwelveSReferenceBundleProvenance(at bundleURL: URL) throws {
        let provenanceURL = bundleURL.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        guard fileManager.fileExists(atPath: provenanceURL.path) else {
            throw LocalWorkflowExecutionError.missingProvenance(provenanceURL.path)
        }
        guard let envelope = try ProvenanceEnvelopeReader.load(from: bundleURL),
              envelope.workflowName == "lungfish fastq 12s-reference-bundle",
              envelope.exitStatus == 0,
              !envelope.argv.isEmpty else {
            throw LocalWorkflowExecutionError.invalidProvenance(provenanceURL.path)
        }

        let bundlePath = bundleURL.standardizedFileURL.path
        let outputPaths = Set(
            (envelope.outputs + envelope.steps.flatMap(\.outputs))
                .map { URL(fileURLWithPath: $0.path).standardizedFileURL.path }
        )
        guard outputPaths.contains(bundlePath) || outputPaths.contains(where: { $0.hasPrefix(bundlePath + "/") }) else {
            throw LocalWorkflowExecutionError.invalidProvenance(provenanceURL.path)
        }
    }

    private static func isTwelveSAmpliconMatchingProvenance(_ envelope: ProvenanceEnvelope) -> Bool {
        let acceptedToolNames: Set<String> = [
            CLICommandIdentity.executableName,
            CLICommandIdentity.legacyExecutableName,
        ]
        guard acceptedToolNames.contains(envelope.toolName) else { return false }
        if envelope.workflowName == "lungfish fastq 12s-match" {
            return true
        }
        return envelope.argv.indices.contains { index in
            let nextIndex = envelope.argv.index(after: index)
            return nextIndex < envelope.argv.endIndex
                && envelope.argv[index] == "fastq"
                && envelope.argv[nextIndex] == "12s-match"
        }
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
            _ = operationCenter.update(
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

    private func decodeFullLengthONTMHCGenotypingPayload(from stdout: String) -> FullLengthONTMHCGenotypingCLIPayload? {
        guard let data = stdout.data(using: .utf8) else { return nil }
        if let payload = try? JSONDecoder().decode(FullLengthONTMHCGenotypingCLIPayload.self, from: data) {
            return payload
        }
        guard let start = stdout.firstIndex(of: "{"),
              let end = stdout.lastIndex(of: "}"),
              start <= end else {
            return nil
        }
        let json = String(stdout[start...end])
        return try? JSONDecoder().decode(FullLengthONTMHCGenotypingCLIPayload.self, from: Data(json.utf8))
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
                _ = operationCenter.updateWithLog(
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
        if let hint = failureHint(result: result, cliCommand: cliCommand) {
            parts += ["", "Likely cause:", hint]
        }
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

    private func failureHint(
        result: LocalWorkflowCLIProcessResult,
        cliCommand: String
    ) -> String? {
        let combined = "\(result.standardError)\n\(result.standardOutput)"
        guard combined.localizedCaseInsensitiveContains("Demultiplex manifest does not exist") else {
            return nil
        }
        if cliCommand.contains("--barcodes") {
            return """
            A barcode CSV was provided with --mode ont-barcode-demux, but the CLI still failed while resolving demux-manifest.json. Current Lungfish builds synthesize this manifest for imported ONT barcode FASTQ bundles; use the rebuilt app/CLI, or check that any explicitly supplied --demux-manifest path exists.
            """
        }
        return """
        Lungfish could not find demux-manifest.json for prepared demultiplexed input. Select an ONT barcode CSV for barcode-demux genotyping, or re-create/import the FASTQ bundle so its demux manifest is present.
        """
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

private struct FullLengthONTMHCGenotypingCLIPayload: Decodable {
    let outputDirectory: String
    let reportCSVPath: String
    let sampleSummaryCSVPath: String
    let statsJSONPath: String
    let workbookPath: String
    let primaryWorkbookPath: String?
    let haplotypeAnalysisPath: String?
    let unmatchedClustersFASTAPath: String
    let cdnaClustersFASTAPath: String
    let provenancePath: String
    let referenceFASTAPath: String

    var outputDirectoryURL: URL { URL(fileURLWithPath: outputDirectory).standardizedFileURL }
    var reportCSVURL: URL { URL(fileURLWithPath: reportCSVPath).standardizedFileURL }
    var sampleSummaryCSVURL: URL { URL(fileURLWithPath: sampleSummaryCSVPath).standardizedFileURL }
    var statsJSONURL: URL { URL(fileURLWithPath: statsJSONPath).standardizedFileURL }
    var workbookURL: URL { URL(fileURLWithPath: workbookPath).standardizedFileURL }
    var primaryWorkbookURL: URL? { primaryWorkbookPath.map { URL(fileURLWithPath: $0).standardizedFileURL } }
    var haplotypeAnalysisURL: URL? { haplotypeAnalysisPath.map { URL(fileURLWithPath: $0).standardizedFileURL } }
    var unmatchedClustersFASTAURL: URL { URL(fileURLWithPath: unmatchedClustersFASTAPath).standardizedFileURL }
    var cdnaClustersFASTAURL: URL { URL(fileURLWithPath: cdnaClustersFASTAPath).standardizedFileURL }
    var provenanceURL: URL { URL(fileURLWithPath: provenancePath).standardizedFileURL }
}
