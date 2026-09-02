import Foundation
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishWorkflow

@MainActor
final class ViralReconWorkflowExecutionService {
    struct RunResult {
        let operationID: UUID
        let bundleURL: URL
        let operationItem: OperationCenter.Item?
    }

    /// What a finished run offers the ingest step.
    struct ResultIngestContext {
        let resultsDirectory: URL
        let runBundleURL: URL
        let sampleNames: [String]
        let projectURL: URL?
    }

    /// Turns a finished run into a viewable bundle.
    ///
    /// Injected so a failing ingest can be exercised without a live pipeline.
    typealias ResultIngest = @MainActor (ResultIngestContext) throws -> Void

    private let operationCenter: OperationCenter
    private let processRunner: ViralReconWorkflowProcessRunning
    private let referenceDownloader: ViralReconReferenceAcquisition.Downloader
    private let resultIngest: ResultIngest
    private var acquisitionSummary: String?

    init(
        operationCenter: OperationCenter = .shared,
        processRunner: ViralReconWorkflowProcessRunning = ProcessViralReconWorkflowProcessRunner(),
        referenceDownloader: @escaping ViralReconReferenceAcquisition.Downloader
            = ViralReconReferenceDownloader.live(),
        resultIngest: @escaping ResultIngest = ViralReconWorkflowExecutionService.liveResultIngest
    ) {
        self.operationCenter = operationCenter
        self.processRunner = processRunner
        self.referenceDownloader = referenceDownloader
        self.resultIngest = resultIngest
    }

    func run(
        _ request: ViralReconRunRequest,
        bundleRoot: URL,
        projectURL: URL? = nil,
        routeContext: OperationRouteContext? = nil
    ) async throws -> RunResult {
        // Refused before anything is written. conda names a real viralrecon
        // profile but Lungfish never enables Nextflow's conda support here, and
        // there is no `local` profile at all, so both abort a run that has
        // already created its output tree.
        try validateExecutor(for: request)

        try FileManager.default.createDirectory(at: bundleRoot, withIntermediateDirectories: true)
        let bundleURL = try availableBundleURL(in: bundleRoot)
        let referencedRequest = try acquireReference(for: request, projectURL: projectURL)
        let persistedRequest = try persistGeneratedInputs(from: referencedRequest, in: bundleURL)
        try writeRunBundle(for: persistedRequest, to: bundleURL)

        let commandPreview = cliCommandPreview(for: persistedRequest, bundleURL: bundleURL)
        let operationID = operationCenter.start(
            title: "Viral Recon",
            detail: initialDetail(for: persistedRequest),
            operationType: .viralRecon,
            targetBundleURL: bundleURL,
            cliCommand: commandPreview,
            routeContext: routeContext
        )
        let cancellation = ViralReconWorkflowProcessCancellation(runner: processRunner)
        operationCenter.setCancelCallback(for: operationID) {
            cancellation.cancel()
        }
        logPreparation(
            for: persistedRequest,
            bundleURL: bundleURL,
            commandPreview: commandPreview,
            operationID: operationID
        )
        logReferenceAcquisition(operationID: operationID)

        do {
            let processResult = try await processRunner.runLungfishCLI(
                arguments: persistedRequest.cliArguments(bundlePath: bundleURL),
                workingDirectory: bundleURL,
                outputHandler: { [operationCenter] output in
                    switch output {
                    case .standardOutput(let line):
                        operationCenter.log(id: operationID, level: .info, message: line)
                    case .standardError(let line):
                        operationCenter.log(id: operationID, level: .warning, message: line)
                    }
                }
            )
            try writeProcessLogs(processResult, to: bundleURL.appendingPathComponent("logs", isDirectory: true))
            if !processResult.didStreamOutput {
                logProcessOutput(processResult, operationID: operationID)
            }

            if operationCenter.items.first(where: { $0.id == operationID })?.state == .cancelling {
                await waitForOperationCancellation(operationID)
            } else if processResult.exitCode == 0 {
                operationCenter.log(id: operationID, level: .info, message: "Viral Recon completed")
                ingestResults(
                    for: persistedRequest,
                    bundleURL: bundleURL,
                    projectURL: projectURL,
                    operationID: operationID
                )
                _ = operationCenter.complete(
                    id: operationID,
                    detail: completionDetail(for: persistedRequest, bundleURL: bundleURL),
                    bundleURLs: [bundleURL]
                )
            } else {
                let tail = stderrTail(processResult.standardError)
                let failureDetail = failureDetail(exitCode: processResult.exitCode, stderrTail: tail)
                operationCenter.log(
                    id: operationID,
                    level: .error,
                    message: "Viral Recon failed with exit code \(processResult.exitCode)"
                )
                _ = operationCenter.fail(
                    id: operationID,
                    detail: failureDetail,
                    errorMessage: "Viral Recon failed",
                    errorDetail: "exit code \(processResult.exitCode)\n\n\(tail)"
                )
                throw ViralReconWorkflowExecutionError.nonZeroExit(processResult.exitCode)
            }
        } catch {
            if operationCenter.items.first(where: { $0.id == operationID })?.state == .running {
                _ = operationCenter.fail(
                    id: operationID,
                    detail: "Viral Recon failed",
                    errorMessage: "Viral Recon failed",
                    errorDetail: String(describing: error)
                )
            }
            throw error
        }

        return RunResult(
            operationID: operationID,
            bundleURL: bundleURL,
            operationItem: operationCenter.items.first { $0.id == operationID }
        )
    }

    /// Builds the viewable bundle from a finished run.
    ///
    /// Deliberately non-throwing. The pipeline has already succeeded and its raw
    /// output is on disk, so a failure here reduces what can be displayed but
    /// must never be reported as a lost analysis. The reason is logged so the
    /// Inspector can explain why the bundle is unavailable.
    private func ingestResults(
        for request: ViralReconRunRequest,
        bundleURL: URL,
        projectURL: URL?,
        operationID: UUID
    ) {
        let context = ResultIngestContext(
            resultsDirectory: request.outputDirectory,
            runBundleURL: bundleURL,
            sampleNames: request.samples.map(\.sampleName),
            projectURL: projectURL
        )
        do {
            try resultIngest(context)
        } catch {
            _ = operationCenter.update(
                id: operationID,
                progress: 1.0,
                detail: "Viral Recon completed. Results could not be prepared for viewing."
            )
            operationCenter.log(
                id: operationID,
                level: .warning,
                message: "Viral Recon finished, but preparing its results for viewing failed: "
                    + "\(error.localizedDescription). The raw output is intact at "
                    + "\(request.outputDirectory.path)."
            )
        }
    }

    /// The shipping ingest: assemble the bundle, then register its tracks.
    @MainActor
    static func liveResultIngest(_ context: ResultIngestContext) throws {
        guard let projectURL = context.projectURL else { return }
        let referenceBundleURL = ViralReconReferenceCatalog.bundleURL(inProject: projectURL)
        for sampleName in context.sampleNames {
            let ingested = try ViralReconResultIngest.ingest(
                resultsDirectory: context.resultsDirectory,
                sampleName: sampleName,
                referenceBundleURL: referenceBundleURL,
                into: context.runBundleURL.appendingPathComponent(
                    TaxTriageSerialBatchRunner.sanitizedDirectoryName(for: sampleName),
                    isDirectory: true
                )
            )
            Task { try? await ViralReconViewerPublication.publish(ingested: ingested) }
        }
    }

    private func waitForOperationCancellation(_ operationID: UUID) async {
        for _ in 0..<50 {
            guard let item = operationCenter.items.first(where: { $0.id == operationID }) else {
                return
            }
            if !item.state.isActive {
                return
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func validateExecutor(for request: ViralReconRunRequest) throws {
        let workflow = try viralReconWorkflow()
        try NFCoreRunRequest(
            workflow: workflow,
            version: request.version,
            executor: request.executor,
            inputURLs: [request.samplesheetURL],
            outputDirectory: request.outputDirectory,
            params: request.effectiveParams,
            presentationMode: .customAdapter("viralrecon")
        ).validateExecutorSupported()
    }

    /// Replaces the requested accession with the reference bundle on disk.
    ///
    /// Viral Recon is SARS-CoV-2 only, so the reference is the fixed
    /// MN908947.3 and Lungfish owns it rather than letting `--genome` resolve to
    /// a remote URL. That keeps the pipeline input and the results viewer bundle
    /// the same artifact, so the viewer can never show a different reference
    /// from the one reads were aligned to.
    private func acquireReference(
        for request: ViralReconRunRequest,
        projectURL: URL?
    ) throws -> ViralReconRunRequest {
        guard case .genome = request.reference, let projectURL else {
            acquisitionSummary = nil
            return request
        }

        let outcome = try ViralReconReferenceAcquisition.acquire(
            projectURL: projectURL,
            downloader: referenceDownloader
        )
        guard let fastaURL = Self.referenceFASTAURL(in: outcome.bundleURL) else {
            throw ViralReconWorkflowExecutionError.referenceBundleHasNoFASTA(outcome.bundleURL)
        }

        switch outcome {
        case .alreadyPresent:
            acquisitionSummary = "Using reference \(ViralReconReferenceCatalog.canonicalAccession) from \(outcome.bundleURL.path)"
        case .downloaded:
            acquisitionSummary = "Downloaded reference \(ViralReconReferenceCatalog.canonicalAccession) to \(outcome.bundleURL.path)"
        }

        let primer = try completedPrimerSelection(for: request, referenceFASTAURL: fastaURL)

        return try ViralReconRunRequest(
            samples: request.samples,
            platform: request.platform,
            protocol: request.protocol,
            samplesheetURL: request.samplesheetURL,
            outputDirectory: request.outputDirectory,
            executor: request.executor,
            version: request.version,
            reference: .local(fastaURL: fastaURL, gffURL: Self.referenceGFFURL(in: outcome.bundleURL)),
            primer: primer,
            minimumMappedReads: request.minimumMappedReads,
            variantCaller: request.variantCaller,
            consensusCaller: request.consensusCaller,
            skipOptions: request.skipOptions,
            advancedParams: request.advancedParams,
            gffURL: request.gffURL,
            fastqPassDirectoryURL: request.fastqPassDirectoryURL,
            sequencingSummaryURL: request.sequencingSummaryURL
        )
    }

    /// Cuts the primer sequences out of the reference when the wizard could not.
    ///
    /// No bundled scheme ships `primers.fasta`, and the wizard has no reference
    /// to cut from until this point, so it stages only the BED and leaves the
    /// FASTA to be derived here.
    private func completedPrimerSelection(
        for request: ViralReconRunRequest,
        referenceFASTAURL: URL
    ) throws -> ViralReconPrimerSelection {
        guard !FileManager.default.fileExists(atPath: request.primer.fastaURL.path) else {
            return request.primer
        }
        return try ViralReconPrimerStager.stage(
            primerBundleURL: request.primer.bundleURL,
            referenceFASTAURL: referenceFASTAURL,
            referenceName: ViralReconReferenceCatalog.canonicalAccession,
            destinationDirectory: request.primer.bedURL
                .deletingLastPathComponent()
                .deletingLastPathComponent()
        )
    }

    private static func referenceFASTAURL(in bundleURL: URL) -> URL? {
        if let manifestFASTAURL = ReferenceSequenceFolder.fastaURL(in: bundleURL) {
            return manifestFASTAURL
        }
        if let resolvedURL = SequenceInputResolver.resolvePrimarySequenceURL(for: bundleURL),
           resolvedURL != bundleURL {
            return resolvedURL
        }
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: bundleURL,
            includingPropertiesForKeys: nil
        )) ?? []
        return contents
            .filter { SequenceFormat.from(url: $0) == .fasta }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .first
    }

    /// The GFF3 the fetch path writes alongside the sequence, when there is one.
    private static func referenceGFFURL(in bundleURL: URL) -> URL? {
        let names = ["genome/genes.gff3", "genome/genes.gff", "annotations.gff3", "annotations.gff"]
        for name in names {
            let candidate = bundleURL.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    private func logReferenceAcquisition(operationID: UUID) {
        guard let acquisitionSummary else { return }
        _ = operationCenter.update(id: operationID, progress: 0, detail: acquisitionSummary)
        operationCenter.log(id: operationID, level: .info, message: acquisitionSummary)
    }

    private func persistGeneratedInputs(from request: ViralReconRunRequest, in bundleURL: URL) throws -> ViralReconRunRequest {
        let inputsURL = bundleURL.appendingPathComponent("inputs", isDirectory: true)
        let primersURL = inputsURL.appendingPathComponent("primers", isDirectory: true)
        let nanoporeURL = inputsURL.appendingPathComponent("nanopore", isDirectory: true)
        try FileManager.default.createDirectory(at: primersURL, withIntermediateDirectories: true)

        let samplesheetURL = inputsURL.appendingPathComponent("samplesheet.csv")
        let primerBEDURL = primersURL.appendingPathComponent("primers.bed")
        let primerFASTAURL = primersURL.appendingPathComponent("primers.fasta")
        try copyItem(from: request.samplesheetURL, to: samplesheetURL)
        try copyItem(from: request.primer.bedURL, to: primerBEDURL)
        try copyItem(from: request.primer.fastaURL, to: primerFASTAURL)

        var fastqPassDirectoryURL: URL?
        var sequencingSummaryURL: URL?
        if request.platform == .nanopore {
            if let sourceFastqPass = request.fastqPassDirectoryURL {
                try FileManager.default.createDirectory(at: nanoporeURL, withIntermediateDirectories: true)
                let destinationFastqPass = nanoporeURL.appendingPathComponent("fastq_pass", isDirectory: true)
                try copyItem(from: sourceFastqPass, to: destinationFastqPass)
                fastqPassDirectoryURL = destinationFastqPass
            }
            if let sourceSummary = request.sequencingSummaryURL {
                try FileManager.default.createDirectory(at: nanoporeURL, withIntermediateDirectories: true)
                let destinationSummary = nanoporeURL.appendingPathComponent(sourceSummary.lastPathComponent)
                try copyItem(from: sourceSummary, to: destinationSummary)
                sequencingSummaryURL = destinationSummary
            }
        }

        let primer = ViralReconPrimerSelection(
            bundleURL: request.primer.bundleURL,
            displayName: request.primer.displayName,
            bedURL: primerBEDURL,
            fastaURL: primerFASTAURL,
            leftSuffix: request.primer.leftSuffix,
            rightSuffix: request.primer.rightSuffix,
            derivedFasta: request.primer.derivedFasta
        )

        return try ViralReconRunRequest(
            samples: request.samples,
            platform: request.platform,
            protocol: request.protocol,
            samplesheetURL: samplesheetURL,
            outputDirectory: request.outputDirectory,
            executor: request.executor,
            version: request.version,
            reference: request.reference,
            primer: primer,
            minimumMappedReads: request.minimumMappedReads,
            variantCaller: request.variantCaller,
            consensusCaller: request.consensusCaller,
            skipOptions: request.skipOptions,
            advancedParams: request.advancedParams,
            gffURL: request.gffURL,
            fastqPassDirectoryURL: fastqPassDirectoryURL ?? request.fastqPassDirectoryURL,
            sequencingSummaryURL: sequencingSummaryURL ?? request.sequencingSummaryURL
        )
    }

    private func writeRunBundle(for request: ViralReconRunRequest, to bundleURL: URL) throws {
        let workflow = try viralReconWorkflow()
        let runRequest = NFCoreRunRequest(
            workflow: workflow,
            version: request.version,
            executor: request.executor,
            inputURLs: [request.samplesheetURL],
            outputDirectory: request.outputDirectory,
            params: request.effectiveParams,
            presentationMode: .customAdapter("viralrecon")
        )
        try NFCoreRunBundleStore.write(runRequest.manifest(), to: bundleURL)

        let inputsURL = bundleURL.appendingPathComponent("inputs", isDirectory: true)
        try FileManager.default.createDirectory(at: inputsURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(request)
        try data.write(to: inputsURL.appendingPathComponent("viralrecon-request.json"), options: .atomic)
        try request.samplesheetURL.path.write(
            to: inputsURL.appendingPathComponent("samplesheet.path"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func logPreparation(
        for request: ViralReconRunRequest,
        bundleURL: URL,
        commandPreview: String,
        operationID: UUID
    ) {
        operationCenter.log(
            id: operationID,
            level: .info,
            message: "Prepared run bundle at \(bundleURL.path)"
        )
        operationCenter.log(
            id: operationID,
            level: .info,
            message: "Using samplesheet \(request.samplesheetURL.path)"
        )
        operationCenter.log(
            id: operationID,
            level: .info,
            message: "Using primer scheme \(request.primer.displayName) from \(request.primer.bundleURL.path)"
        )
        if request.primer.derivedFasta {
            operationCenter.log(
                id: operationID,
                level: .info,
                message: "Using derived primer FASTA \(request.primer.fastaURL.path)"
            )
        }
        operationCenter.log(id: operationID, level: .info, message: commandPreview)
    }

    private func logProcessOutput(_ result: ViralReconWorkflowProcessResult, operationID: UUID) {
        for line in result.standardOutput.split(whereSeparator: \.isNewline) {
            operationCenter.log(id: operationID, level: .info, message: String(line))
        }
        for line in result.standardError.split(whereSeparator: \.isNewline) {
            operationCenter.log(id: operationID, level: .warning, message: String(line))
        }
    }

    private func availableBundleURL(in root: URL) throws -> URL {
        let base = root.appendingPathComponent("viralrecon.\(NFCoreRunBundleStore.directoryExtension)", isDirectory: true)
        guard FileManager.default.fileExists(atPath: base.path) else {
            return base
        }

        for index in 2...999 {
            let candidate = root.appendingPathComponent(
                "viralrecon-\(index).\(NFCoreRunBundleStore.directoryExtension)",
                isDirectory: true
            )
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: base.path])
    }

    private func viralReconWorkflow() throws -> NFCoreSupportedWorkflow {
        if let workflow = NFCoreSupportedWorkflowCatalog.workflow(named: "viralrecon") {
            return workflow
        }
        throw ViralReconWorkflowExecutionError.missingWorkflowDefinition
    }

    private func writeProcessLogs(_ result: ViralReconWorkflowProcessResult, to logsURL: URL) throws {
        try FileManager.default.createDirectory(at: logsURL, withIntermediateDirectories: true)
        try result.standardOutput.write(
            to: logsURL.appendingPathComponent("stdout.log"),
            atomically: true,
            encoding: .utf8
        )
        try result.standardError.write(
            to: logsURL.appendingPathComponent("stderr.log"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func cliCommandPreview(for request: ViralReconRunRequest, bundleURL: URL) -> String {
        ViralReconWorkflowCommandPreview.build(
            executableName: CLICommandIdentity.executableName,
            arguments: request.cliArguments(bundlePath: bundleURL)
        )
    }

    private func stderrTail(_ stderr: String) -> String {
        let lines = stderr.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.suffix(40).joined(separator: "\n")
    }

    private func initialDetail(for request: ViralReconRunRequest) -> String {
        "\(request.platform.rawValue) · \(request.samples.count) sample(s) · \(referenceDisplayName(request.reference))"
    }

    private func completionDetail(for request: ViralReconRunRequest, bundleURL: URL) -> String {
        "Viral Recon completed. Output: \(request.outputDirectory.path). Run bundle: \(bundleURL.path)"
    }

    private func failureDetail(exitCode: Int32, stderrTail: String) -> String {
        let trimmedTail = stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTail.isEmpty else {
            return "Viral Recon failed with exit code \(exitCode)"
        }
        return "Viral Recon failed with exit code \(exitCode). \(trimmedTail)"
    }

    private func referenceDisplayName(_ reference: ViralReconReference) -> String {
        switch reference {
        case .genome(let accession):
            return accession
        case .local(let fastaURL, _):
            return fastaURL.lastPathComponent
        }
    }

    private func copyItem(from sourceURL: URL, to destinationURL: URL) throws {
        let source = sourceURL.standardizedFileURL
        let destination = destinationURL.standardizedFileURL
        if source.path == destination.path {
            return
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: source, to: destination)
    }
}

private final class ViralReconWorkflowProcessCancellation: @unchecked Sendable {
    private let runner: ViralReconWorkflowProcessRunning

    @MainActor
    init(runner: ViralReconWorkflowProcessRunning) {
        self.runner = runner
    }

    func cancel() {
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated {
                runner.cancel()
            }
        }
    }
}

enum ViralReconWorkflowCommandPreview {
    static func build(executableName: String, arguments: [String]) -> String {
        ([executableName] + arguments)
            .map(shellEscape)
            .joined(separator: " ")
    }
}

struct ViralReconWorkflowProcessResult: Sendable, Equatable {
    let exitCode: Int32
    let standardOutput: String
    let standardError: String
    let didStreamOutput: Bool

    init(
        exitCode: Int32,
        standardOutput: String,
        standardError: String,
        didStreamOutput: Bool = false
    ) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.didStreamOutput = didStreamOutput
    }
}

enum ViralReconWorkflowProcessOutput: Sendable, Equatable {
    case standardOutput(String)
    case standardError(String)
}

@MainActor
protocol ViralReconWorkflowProcessRunning {
    func runLungfishCLI(
        arguments: [String],
        workingDirectory: URL,
        outputHandler: (@MainActor @Sendable (ViralReconWorkflowProcessOutput) -> Void)?
    ) async throws -> ViralReconWorkflowProcessResult

    func cancel()
}

enum ViralReconWorkflowExecutionError: Error, Equatable {
    case nonZeroExit(Int32)
    case missingWorkflowDefinition
    case referenceBundleHasNoFASTA(URL)
}

final class ProcessViralReconWorkflowProcessRunner: ViralReconWorkflowProcessRunning {
    private let executableURL: URL?
    private let cancellationHandle = NativeProcessCancellationHandle()

    init(executableURL: URL? = nil) {
        self.executableURL = executableURL
    }

    func runLungfishCLI(
        arguments: [String],
        workingDirectory: URL,
        outputHandler: (@MainActor @Sendable (ViralReconWorkflowProcessOutput) -> Void)?
    ) async throws -> ViralReconWorkflowProcessResult {
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let process = Process()
        let collector = ProcessOutputCollector(outputHandler: outputHandler)
        if let cliURL = executableURL ?? Self.lungfishCLIURL() {
            process.executableURL = cliURL
            process.arguments = arguments
        } else {
            throw LungfishCLIRunner.RunError.cliNotFound
        }
        process.currentDirectoryURL = workingDirectory
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        cancellationHandle.store(process)

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            collector.append(data, source: .standardOutput)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            collector.append(data, source: .standardError)
        }

        let termination = ProcessTermination()
        process.terminationHandler = { process in
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            collector.append(
                stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
                source: .standardOutput
            )
            collector.append(
                stderrPipe.fileHandleForReading.readDataToEndOfFile(),
                source: .standardError
            )
            collector.flushPendingLines()
            termination.finish(process.terminationStatus)
        }

        do {
            try process.run()
            cancellationHandle.terminateIfRequested()
        } catch {
            cancellationHandle.clear(process)
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            throw error
        }

        let exitCode = await termination.wait()
        cancellationHandle.clear(process)
        return ViralReconWorkflowProcessResult(
            exitCode: exitCode,
            standardOutput: collector.standardOutput,
            standardError: collector.standardError,
            didStreamOutput: collector.didStreamOutput
        )
    }

    private static func lungfishCLIURL() -> URL? {
        CLIBinaryLocator.cliBinaryPath()
    }

    func cancel() {
        cancellationHandle.requestProcessTreeTermination(gracePeriod: 0)
    }
}

private final class ProcessOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var standardOutputData = Data()
    private var standardErrorData = Data()
    private var pendingStandardOutput = ""
    private var pendingStandardError = ""
    private var streamedOutput = false
    private let outputHandler: (@MainActor @Sendable (ViralReconWorkflowProcessOutput) -> Void)?

    init(outputHandler: (@MainActor @Sendable (ViralReconWorkflowProcessOutput) -> Void)?) {
        self.outputHandler = outputHandler
    }

    var standardOutput: String {
        lock.withLock {
            String(data: standardOutputData, encoding: .utf8) ?? ""
        }
    }

    var standardError: String {
        lock.withLock {
            String(data: standardErrorData, encoding: .utf8) ?? ""
        }
    }

    var didStreamOutput: Bool {
        lock.withLock {
            streamedOutput
        }
    }

    func append(_ data: Data, source: ViralReconWorkflowProcessOutput.Source) {
        guard !data.isEmpty else { return }
        let lines: [String]
        lock.lock()
        switch source {
        case .standardOutput:
            standardOutputData.append(data)
            lines = Self.completeLines(from: data, pending: &pendingStandardOutput)
        case .standardError:
            standardErrorData.append(data)
            lines = Self.completeLines(from: data, pending: &pendingStandardError)
        }
        lock.unlock()

        for line in lines {
            emit(line, source: source)
        }
    }

    func flushPendingLines() {
        let outputLine: String?
        let errorLine: String?
        lock.lock()
        outputLine = pendingStandardOutput.isEmpty ? nil : pendingStandardOutput
        errorLine = pendingStandardError.isEmpty ? nil : pendingStandardError
        pendingStandardOutput = ""
        pendingStandardError = ""
        lock.unlock()

        if let outputLine {
            emit(outputLine, source: .standardOutput)
        }
        if let errorLine {
            emit(errorLine, source: .standardError)
        }
    }

    private func emit(_ line: String, source: ViralReconWorkflowProcessOutput.Source) {
        guard let outputHandler else { return }
        let output: ViralReconWorkflowProcessOutput
        switch source {
        case .standardOutput:
            output = .standardOutput(line)
        case .standardError:
            output = .standardError(line)
        }
        lock.withLock {
            streamedOutput = true
        }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                outputHandler(output)
            }
        }
    }

    private static func completeLines(from data: Data, pending: inout String) -> [String] {
        guard let chunk = String(data: data, encoding: .utf8), !chunk.isEmpty else {
            return []
        }

        pending += chunk
        let components = pending.components(separatedBy: .newlines)
        let completeComponents = components.prefix(max(0, components.count - 1))
        if pending.last?.isNewline == true {
            pending = ""
            return Array(completeComponents)
        }

        pending = components.last ?? ""
        return Array(completeComponents)
    }
}

private final class ProcessTermination: @unchecked Sendable {
    private let lock = NSLock()
    private var exitCode: Int32?
    private var continuation: CheckedContinuation<Int32, Never>?

    func finish(_ code: Int32) {
        let continuationToResume: CheckedContinuation<Int32, Never>?
        lock.lock()
        exitCode = code
        continuationToResume = continuation
        continuation = nil
        lock.unlock()
        continuationToResume?.resume(returning: code)
    }

    func wait() async -> Int32 {
        await withCheckedContinuation { continuation in
            let code: Int32?
            lock.lock()
            code = exitCode
            if code == nil {
                self.continuation = continuation
            }
            lock.unlock()
            if let code {
                continuation.resume(returning: code)
            }
        }
    }
}

private extension ViralReconWorkflowProcessOutput {
    enum Source {
        case standardOutput
        case standardError
    }
}
