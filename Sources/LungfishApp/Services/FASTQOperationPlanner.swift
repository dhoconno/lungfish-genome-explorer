import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

enum FASTQOperationExecutionOutputKind: Sendable, Equatable {
    case fastqFile
    case directory
    case jsonReport
}

struct FASTQOperationPlan: Sendable, Equatable {
    let originalRequest: FASTQOperationLaunchRequest
    let resolvedRequest: FASTQOperationLaunchRequest
    let outputTarget: URL
    let outputKind: FASTQOperationExecutionOutputKind
}

struct FASTQOperationPlanner: Sendable {
    func executionOutputDirectory(
        for request: FASTQOperationLaunchRequest,
        workingDirectory: URL
    ) -> URL {
        if outputMode(for: request) == .groupedResult || isDemultiplexRequest(request) {
            return workingDirectory
        }

        if case .assemble = request {
            return workingDirectory
        }

        if case .savont = request {
            return workingDirectory
        }

        if case .pbaa = request {
            return workingDirectory.appendingPathComponent(
                "cli-output-pbaa-\(UUID().uuidString)",
                isDirectory: true
            )
        }

        return workingDirectory.appendingPathComponent(
            "cli-output-\(UUID().uuidString)",
            isDirectory: true
        )
    }

func outputMode(for request: FASTQOperationLaunchRequest) -> FASTQOperationOutputMode {
    switch request {
    case .refreshQCSummary:
        return .fixedBatch
    case .derivative(_, _, let outputMode):
        return outputMode
    case .ontFluidigmSampleSplit, .ontPacBioBarcodeDemux:
        return .fixedBatch
    case .map(_, _, let outputMode):
        return outputMode
    case .assemble(_, let outputMode):
        return outputMode
    case .classify:
        return .fixedBatch
    case .savont, .pbaa:
        return .perInput
    case .ontGenotyping:
        return .fixedBatch
    }
}

func isDemultiplexRequest(_ request: FASTQOperationLaunchRequest) -> Bool {
    if case .derivative(let derivativeRequest, _, _) = request,
       case .demultiplex = derivativeRequest {
        return true
    }
    if case .ontFluidigmSampleSplit = request {
        return true
    }
    if case .ontPacBioBarcodeDemux = request {
        return true
    }
    return false
}

    func makeExecutionPlans(
        originalRequest: FASTQOperationLaunchRequest,
        resolvedRequest: FASTQOperationLaunchRequest,
        baseOutputDirectory: URL
    ) -> [FASTQOperationPlan] {
        let requestPairs = splitExecutionRequestsIfNeeded(
            originalRequest: originalRequest,
            resolvedRequest: resolvedRequest
        )

        var reservedOutputPaths = Set<String>()
        return requestPairs.map { pair in
            let outputKind = executionOutputKind(for: pair.original)
            let parentDirectory = outputParentDirectory(
                for: pair.original,
                baseOutputDirectory: baseOutputDirectory,
                totalRequestCount: requestPairs.count
            )
            let outputTarget: URL

            switch outputKind {
            case .directory:
                outputTarget = parentDirectory
            case .fastqFile:
                let requestedTarget = parentDirectory.appendingPathComponent(
                    defaultFASTQOutputFilename(for: pair.original)
                )
                outputTarget = isSavontRequest(pair.original)
                    ? collisionSafeOutputURL(
                        requestedTarget,
                        reservedOutputPaths: &reservedOutputPaths
                    )
                    : requestedTarget
            case .jsonReport:
                outputTarget = parentDirectory.appendingPathComponent("qc-summary.json")
            }

            return FASTQOperationPlan(
                originalRequest: pair.original,
                resolvedRequest: pair.resolved,
                outputTarget: outputTarget,
                outputKind: outputKind
            )
        }
    }

    func discoverOutputs(for plan: FASTQOperationPlan, in outputDirectory: URL) -> [URL] {
        switch plan.outputKind {
        case .directory:
            let directory = plan.outputTarget.standardizedFileURL
            if (try? AssemblyResult.load(from: directory)) != nil {
                return [directory]
            }
            if case .pbaa = plan.originalRequest {
                return Self.discoverReferenceBundles(in: directory)
            }
            if case .ontGenotyping(let request) = plan.originalRequest {
                let workbookURL = directory.appendingPathComponent(request.workbookURL.lastPathComponent)
                if FileManager.default.fileExists(atPath: workbookURL.path) {
                    return [workbookURL]
                }
                if FileManager.default.fileExists(atPath: directory.appendingPathComponent(ProvenanceWriter.provenanceFilename).path) {
                    return [directory]
                }
            }
            if plan.originalRequest.isRibosomalRNAFilterRequest {
                return Self.discoverSequenceFiles(in: directory)
            }
            return Self.discoverFASTQBundles(in: directory)
        case .fastqFile, .jsonReport:
            return FileManager.default.fileExists(atPath: plan.outputTarget.path)
                ? [plan.outputTarget]
                : []
        }
    }

    func executionDirectory(for plan: FASTQOperationPlan) -> URL {
        switch plan.outputKind {
        case .directory:
            if case .ontFluidigmSampleSplit = plan.originalRequest {
                return plan.outputTarget.deletingLastPathComponent()
            }
            return plan.outputTarget
        case .fastqFile, .jsonReport:
            return plan.outputTarget.deletingLastPathComponent()
        }
    }

    func cliCreatesFreshOutputDirectory(for request: FASTQOperationLaunchRequest) -> Bool {
        switch request {
        case .ontFluidigmSampleSplit, .ontPacBioBarcodeDemux:
            return true
        default:
            return false
        }
    }

    func cliCreatesFreshOutputDirectory(for plan: FASTQOperationPlan) -> Bool {
        plan.outputKind == .directory && cliCreatesFreshOutputDirectory(for: plan.originalRequest)
    }

    func persistGroupedResultManifest(
        originalRequest: FASTQOperationLaunchRequest,
        resolvedRequest: FASTQOperationLaunchRequest,
        outputURLs: [URL],
        outputDirectory: URL
    ) throws {
        let record = BatchOperationRecord(
            label: resolvedRequest.batchManifestLabel,
            operationKind: resolvedRequest.batchManifestOperationKind,
            parameters: resolvedRequest.batchManifestParameters,
            outputBundlePaths: outputURLs.compactMap { Self.relativePath(from: outputDirectory, to: $0) },
            inputBundlePaths: originalRequest.inputURLs.compactMap { Self.relativePath(from: outputDirectory, to: $0) }
        )
        try FASTQBatchManifest.appendOperation(record, to: outputDirectory)
    }

    func ensureGroupedResultProvenance(
        originalRequest: FASTQOperationLaunchRequest,
        resolvedRequest: FASTQOperationLaunchRequest,
        invocations: [CLIInvocation],
        outputURLs: [URL],
        outputDirectory: URL
    ) throws {
        let existingEnvelope = ProvenanceRecorder.loadEnvelope(from: outputDirectory)

        let missingProvenance = outputURLs.filter { !hasDiscoverableProvenance(forGroupedOutput: $0) }
        guard missingProvenance.isEmpty else {
            throw ProvenanceRehydrationError.missingSourceProvenance(
                "Missing provenance for grouped outputs: \(missingProvenance.map(\.path).joined(separator: ", "))"
            )
        }

        let outputPayloadURLs = uniqueExistingRegularPayloadURLs(from: outputURLs)
        guard !outputPayloadURLs.isEmpty else {
            throw ProvenanceRehydrationError.missingSourceProvenance(
                "No regular scientific payload files were discovered for grouped output \(outputDirectory.path)."
            )
        }

        if let existingEnvelope,
           groupedEnvelope(existingEnvelope, matches: outputPayloadURLs) {
            return
        }

        let inputPayloadURLs = uniqueExistingRegularPayloadURLs(from: originalRequest.provenanceInputURLs)
        let inputDescriptors = try inputPayloadURLs.map {
            try ProvenanceFileDescriptor.file(url: $0, role: .input)
        }
        let outputDescriptors = try outputPayloadURLs.map {
            try ProvenanceFileDescriptor.file(url: $0, role: .output)
        }
        let commandLines = invocations.map { invocation in
            let subcommandParts = invocation.subcommand
                .split(whereSeparator: { $0.isWhitespace })
                .map(String.init)
            return [CLICommandIdentity.executableName] + subcommandParts + invocation.arguments
        }
        let argv = commandLines.count == 1
            ? (commandLines.first ?? [CLICommandIdentity.executableName, "fastq"])
            : [
                CLICommandIdentity.executableName,
                "gui",
                "fastq-grouped-result",
                "--operation",
                resolvedRequest.batchManifestOperationKind,
            ]
        let reproducibleCommand = commandLines
            .map { $0.map(shellEscape).joined(separator: " ") }
            .joined(separator: " && ")
        var parameters = Dictionary(
            uniqueKeysWithValues: resolvedRequest.batchManifestParameters.map { key, value in
                (key, ParameterValue.string(value))
            }
        )
        parameters["operationKind"] = .string(resolvedRequest.batchManifestOperationKind)
        parameters["outputDirectory"] = .file(outputDirectory)
        parameters["outputMode"] = .string(FASTQOperationOutputMode.groupedResult.rawValue)
        parameters["outputCount"] = .integer(outputURLs.count)

        let step = ProvenanceStep(
            toolName: "lungfish gui grouped FASTQ operation",
            toolVersion: WorkflowRun.currentAppVersion,
            argv: argv,
            reproducibleCommand: reproducibleCommand,
            inputs: inputDescriptors,
            outputs: outputDescriptors,
            exitStatus: 0
        )
        let now = Date()
        let envelope = try ProvenanceRunBuilder(
            workflowName: "\(resolvedRequest.batchManifestOperationKind) grouped FASTQ operation",
            workflowVersion: WorkflowRun.currentAppVersion,
            toolName: "lungfish gui grouped FASTQ operation",
            toolVersion: WorkflowRun.currentAppVersion
        )
        .argv(argv)
        .reproducibleCommand(reproducibleCommand)
        .options(explicit: parameters, defaults: [:], resolved: parameters)
        .runtime(ProvenanceRuntimeIdentity())
        .step(step)
        .complete(exitStatus: 0, startedAt: now, endedAt: now)

        try ProvenanceWriter(signingProvider: nil).write(envelope, to: outputDirectory)
    }

    private func splitExecutionRequestsIfNeeded(
        originalRequest: FASTQOperationLaunchRequest,
        resolvedRequest: FASTQOperationLaunchRequest
    ) -> [(original: FASTQOperationLaunchRequest, resolved: FASTQOperationLaunchRequest)] {
        switch (originalRequest, resolvedRequest) {
        case (
            .derivative(let originalDerivative, let originalInputURLs, let outputMode),
            .derivative(let resolvedDerivative, let resolvedInputURLs, let resolvedOutputMode)
        )
            where outputMode == .perInput &&
                  resolvedOutputMode == .perInput &&
                  originalInputURLs.count > 1 &&
                  originalInputURLs.count == resolvedInputURLs.count:
            return zip(originalInputURLs, resolvedInputURLs).map { originalInputURL, resolvedInputURL in
                (
                    .derivative(request: originalDerivative, inputURLs: [originalInputURL], outputMode: outputMode),
                    .derivative(request: resolvedDerivative, inputURLs: [resolvedInputURL], outputMode: resolvedOutputMode)
                )
            }

        case (
            .map(let originalInputURLs, let referenceURL, let outputMode),
            .map(let resolvedInputURLs, let resolvedReferenceURL, let resolvedOutputMode)
        )
            where outputMode == .perInput &&
                  resolvedOutputMode == .perInput &&
                  originalInputURLs.count > 1 &&
                  originalInputURLs.count == resolvedInputURLs.count:
            return zip(originalInputURLs, resolvedInputURLs).map { originalInputURL, resolvedInputURL in
                (
                    .map(inputURLs: [originalInputURL], referenceURL: referenceURL, outputMode: outputMode),
                    .map(inputURLs: [resolvedInputURL], referenceURL: resolvedReferenceURL, outputMode: resolvedOutputMode)
                )
            }

        case (
            .assemble(let originalAssemblyRequest, let outputMode),
            .assemble(let resolvedAssemblyRequest, let resolvedOutputMode)
        )
            where outputMode == .perInput &&
                  resolvedOutputMode == .perInput &&
                  !originalAssemblyRequest.pairedEnd &&
                  !resolvedAssemblyRequest.pairedEnd &&
                  originalAssemblyRequest.inputURLs.count > 1 &&
                  originalAssemblyRequest.inputURLs.count == resolvedAssemblyRequest.inputURLs.count:
            return zip(originalAssemblyRequest.inputURLs, resolvedAssemblyRequest.inputURLs).map { originalInputURL, resolvedInputURL in
                (
                    .assemble(
                        request: originalAssemblyRequest.replacingInputURLs(with: [originalInputURL]),
                        outputMode: outputMode
                    ),
                    .assemble(
                        request: resolvedAssemblyRequest.replacingInputURLs(with: [resolvedInputURL]),
                        outputMode: resolvedOutputMode
                    )
                )
            }

        case (
            .savont(let originalSavontRequest),
            .savont(let resolvedSavontRequest)
        )
            where originalSavontRequest.inputURLs.count > 1 &&
                  originalSavontRequest.inputURLs.count == resolvedSavontRequest.inputURLs.count:
            return zip(originalSavontRequest.inputURLs, resolvedSavontRequest.inputURLs).map {
                originalInputURL, resolvedInputURL in
                (
                    .savont(request: FASTQSavontClusteringRequest(
                        inputURLs: [originalInputURL],
                        outputDirectoryURL: originalSavontRequest.outputDirectoryURL,
                        singleInputOutputName: nil,
                        threads: originalSavontRequest.threads,
                        qualityValueCutoff: originalSavontRequest.qualityValueCutoff,
                        minimumClusterSize: originalSavontRequest.minimumClusterSize,
                        minimumReadLength: originalSavontRequest.minimumReadLength,
                        maximumReadLength: originalSavontRequest.maximumReadLength,
                        singleStrand: originalSavontRequest.singleStrand
                    )),
                    .savont(request: FASTQSavontClusteringRequest(
                        inputURLs: [resolvedInputURL],
                        outputDirectoryURL: resolvedSavontRequest.outputDirectoryURL,
                        singleInputOutputName: nil,
                        threads: resolvedSavontRequest.threads,
                        qualityValueCutoff: resolvedSavontRequest.qualityValueCutoff,
                        minimumClusterSize: resolvedSavontRequest.minimumClusterSize,
                        minimumReadLength: resolvedSavontRequest.minimumReadLength,
                        maximumReadLength: resolvedSavontRequest.maximumReadLength,
                        singleStrand: resolvedSavontRequest.singleStrand
                    ))
                )
            }

        default:
            return [(originalRequest, resolvedRequest)]
        }
    }

    private func executionOutputKind(for request: FASTQOperationLaunchRequest) -> FASTQOperationExecutionOutputKind {
        switch request {
        case .refreshQCSummary:
            return .jsonReport
        case .derivative(let derivativeRequest, _, _):
            return derivativeRequest.usesDirectoryOutput ? .directory : .fastqFile
        case .savont:
            return .fastqFile
        case .ontFluidigmSampleSplit, .ontPacBioBarcodeDemux, .map, .assemble, .classify, .pbaa, .ontGenotyping:
            return .directory
        }
    }

    private func outputParentDirectory(
        for request: FASTQOperationLaunchRequest,
        baseOutputDirectory: URL,
        totalRequestCount: Int
    ) -> URL {
        if isSavontRequest(request) {
            return baseOutputDirectory
        }
        guard totalRequestCount > 1 else {
            return baseOutputDirectory
        }

        let stem = request.inputURLs.first
            .map(Self.sanitizedStem(for:))
            ?? "output-\(UUID().uuidString.prefix(8))"
        return baseOutputDirectory.appendingPathComponent(stem, isDirectory: true)
    }

    private func defaultFASTQOutputFilename(for request: FASTQOperationLaunchRequest) -> String {
        switch request {
        case .derivative(let derivativeRequest, _, _):
            if case .translate = derivativeRequest {
                return "\(derivativeRequest.operationKindString).fasta"
            }
            return "\(derivativeRequest.operationKindString).fastq"
        case .savont(let savontRequest):
            let baseName = savontRequest.singleInputOutputName
                ?? savontRequest.inputURLs.first.map(FASTQSavontClusteringRequest.defaultOutputBaseName(for:))
                ?? "savont-clusters"
            return baseName.lowercased().hasSuffix(".fasta")
                ? baseName
                : "\(baseName).fasta"
        default:
            return "output.fastq"
        }
    }

    private func isSavontRequest(_ request: FASTQOperationLaunchRequest) -> Bool {
        if case .savont = request { return true }
        return false
    }

    private func collisionSafeOutputURL(
        _ requestedURL: URL,
        reservedOutputPaths: inout Set<String>
    ) -> URL {
        let fileManager = FileManager.default
        let parent = requestedURL.deletingLastPathComponent()
        let pathExtension = requestedURL.pathExtension
        let baseName = requestedURL.deletingPathExtension().lastPathComponent
        var candidate = requestedURL
        var counter = 2
        while fileManager.fileExists(atPath: candidate.path)
            || reservedOutputPaths.contains(caseFoldedReservationKey(for: candidate)) {
            let filename = pathExtension.isEmpty
                ? "\(baseName)-\(counter)"
                : "\(baseName)-\(counter).\(pathExtension)"
            candidate = parent.appendingPathComponent(filename)
            counter += 1
        }
        reservedOutputPaths.insert(caseFoldedReservationKey(for: candidate))
        return candidate
    }

    private func caseFoldedReservationKey(for url: URL) -> String {
        url.standardizedFileURL.path
            .precomposedStringWithCanonicalMapping
            .lowercased()
    }

    private func groupedEnvelope(_ envelope: ProvenanceEnvelope, matches outputPayloadURLs: [URL]) -> Bool {
        let expectedPaths = Set(outputPayloadURLs.map { $0.standardizedFileURL.path })
        let recordedPaths = Set(((envelope.output.map { [$0.path] } ?? [])
            + envelope.outputs.map(\.path)
            + envelope.steps.flatMap { $0.outputs.map(\.path) })
            .map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        return expectedPaths.isSubset(of: recordedPaths)
    }

    private func hasDiscoverableProvenance(forGroupedOutput outputURL: URL) -> Bool {
        if ProvenanceRecorder.loadEnvelope(from: outputURL) != nil {
            return true
        }
        if isDirectory(outputURL) {
            if let primaryURL = SequenceInputResolver.resolvePrimarySequenceURL(for: outputURL),
               let resolved = ProvenanceRecorder.findProvenanceEnvelope(for: primaryURL),
               provenanceSidecar(resolved.sidecarURL, isLocalTo: outputURL) {
                return true
            }
            if let resolved = ProvenanceRecorder.findProvenanceEnvelope(for: outputURL) {
                return provenanceSidecar(resolved.sidecarURL, isLocalTo: outputURL)
            }
            return false
        }
        return ProvenanceRecorder.findProvenance(forFile: outputURL) != nil
    }

    private func provenanceSidecar(_ sidecarURL: URL, isLocalTo outputURL: URL) -> Bool {
        let sidecarPath = sidecarURL.standardizedFileURL.path
        let outputPath = outputURL.standardizedFileURL.path
        return sidecarPath == outputPath
            || sidecarPath.hasPrefix(outputPath + "/")
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private func uniqueExistingRegularPayloadURLs(from urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls
            .flatMap(Self.regularPayloadURLs)
            .filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    static func regularPayloadURLs(for url: URL) -> [URL] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return []
        }
        if !isDirectory.boolValue {
            return [url]
        }
        if let primaryURL = SequenceInputResolver.resolvePrimarySequenceURL(for: url) {
            return [primaryURL]
        }
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return enumerator.compactMap { item -> URL? in
            guard let fileURL = item as? URL,
                  (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  !fileURL.lastPathComponent.hasSuffix(".lungfish-provenance.json") else {
                return nil
            }
            return fileURL
        }
    }

    static func discoverSequenceFiles(in directory: URL) -> [URL] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return contents.filter { SequenceFormat.from(url: $0) != nil }.sorted {
            $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending
        }
    }

    static func discoverFASTQBundles(in directory: URL) -> [URL] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return contents.filter { FASTQBundle.isBundleURL($0) }.sorted {
            $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending
        }
    }

    static func discoverReferenceBundles(in directory: URL) -> [URL] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return contents.filter { $0.pathExtension.lowercased() == "lungfishref" }.sorted {
            $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending
        }
    }

    static func sanitizedStem(for url: URL) -> String {
        let stem = url.deletingPathExtension().lastPathComponent
        return stem.isEmpty ? "output" : stem
    }

    static func relativePath(from base: URL, to target: URL) -> String? {
        let basePath = base.standardizedFileURL.path
        let normalizedBase = basePath.hasSuffix("/") ? basePath : basePath + "/"
        let targetPath = target.standardizedFileURL.path
        guard targetPath.hasPrefix(normalizedBase) else {
            let baseComponents = base.standardizedFileURL.pathComponents
            let targetComponents = target.standardizedFileURL.pathComponents
            var index = 0
            while index < min(baseComponents.count, targetComponents.count),
                  baseComponents[index] == targetComponents[index] {
                index += 1
            }
            let parentTraversal = Array(repeating: "..", count: max(0, baseComponents.count - index))
            let suffix = Array(targetComponents.dropFirst(index))
            let relative = parentTraversal + suffix
            return relative.isEmpty ? "." : relative.joined(separator: "/")
        }
        return String(targetPath.dropFirst(normalizedBase.count))
    }
}

extension FASTQOperationLaunchRequest {
    var inputURLs: [URL] {
        switch self {
        case .refreshQCSummary(let inputURLs):
            return inputURLs
        case .derivative(_, let inputURLs, _):
            return inputURLs
        case .ontFluidigmSampleSplit(let inputFASTQURL, _, _),
             .ontPacBioBarcodeDemux(let inputFASTQURL, _, _, _, _, _):
            return [inputFASTQURL]
        case .map(let inputURLs, _, _):
            return inputURLs
        case .assemble(let request, _):
            return request.inputURLs
        case .classify(_, let inputURLs, _, _):
            return inputURLs
        case .savont(let request):
            return request.inputURLs
        case .pbaa(let request):
            return [request.inputFASTQURL]
        case .ontGenotyping(let request):
            return request.inputFASTQURLs
        }
    }

    var provenanceInputURLs: [URL] {
        var urls = inputURLs
        switch self {
        case .derivative(let request, _, _):
            urls.append(contentsOf: request.provenanceInputURLs)
        case .ontFluidigmSampleSplit(_, let barcodeDefinitionsURL, _),
             .ontPacBioBarcodeDemux(_, let barcodeDefinitionsURL, _, _, _, _):
            urls.append(barcodeDefinitionsURL)
        case .map(_, let referenceURL, _):
            urls.append(referenceURL)
        case .classify(_, _, let databaseName, _):
            let databaseURL = URL(fileURLWithPath: databaseName)
            if FileManager.default.fileExists(atPath: databaseURL.path) {
                urls.append(databaseURL)
            }
        case .pbaa(let request):
            urls.append(request.guideSourceURL)
        case .ontGenotyping(let request):
            urls.append(request.referenceSourceURL)
            if let barcodeDefinitionsURL = request.barcodeDefinitionsURL {
                urls.append(barcodeDefinitionsURL)
            }
            if let comparisonWorkbookURL = request.comparisonWorkbookURL {
                urls.append(comparisonWorkbookURL)
            }
        default:
            break
        }
        return urls
    }


    func replacingInputURLs(with inputURLs: [URL]) -> FASTQOperationLaunchRequest {
        switch self {
        case .refreshQCSummary:
            return .refreshQCSummary(inputURLs: inputURLs)
        case .derivative(let request, _, let outputMode):
            return .derivative(request: request, inputURLs: inputURLs, outputMode: outputMode)
        case .ontFluidigmSampleSplit(_, let barcodeDefinitionsURL, let threads):
            guard let inputFASTQURL = inputURLs.first else { return self }
            return .ontFluidigmSampleSplit(
                inputFASTQURL: inputFASTQURL,
                barcodeDefinitionsURL: barcodeDefinitionsURL,
                threads: threads
            )
        case .ontPacBioBarcodeDemux(
            _,
            let barcodeDefinitionsURL,
            let threads,
            let chunkJobs,
            let maxReadsPerSlice,
            let maxBytesPerCutadapt
        ):
            guard let inputFASTQURL = inputURLs.first else { return self }
            return .ontPacBioBarcodeDemux(
                inputFASTQURL: inputFASTQURL,
                barcodeDefinitionsURL: barcodeDefinitionsURL,
                threads: threads,
                chunkJobs: chunkJobs,
                maxReadsPerSlice: maxReadsPerSlice,
                maxBytesPerCutadapt: maxBytesPerCutadapt
            )
        case .map(_, let referenceURL, let outputMode):
            return .map(inputURLs: inputURLs, referenceURL: referenceURL, outputMode: outputMode)
        case .assemble(let request, let outputMode):
            return .assemble(request: request.replacingInputURLs(with: inputURLs), outputMode: outputMode)
        case .classify(let tool, _, let databaseName, let extraArguments):
            return .classify(tool: tool, inputURLs: inputURLs, databaseName: databaseName, extraArguments: extraArguments)
        case .savont(let request):
            return .savont(request: FASTQSavontClusteringRequest(
                inputURLs: inputURLs,
                outputDirectoryURL: request.outputDirectoryURL,
                singleInputOutputName: request.singleInputOutputName,
                threads: request.threads,
                qualityValueCutoff: request.qualityValueCutoff,
                minimumClusterSize: request.minimumClusterSize,
                minimumReadLength: request.minimumReadLength,
                maximumReadLength: request.maximumReadLength,
                singleStrand: request.singleStrand
            ))
        case .pbaa(let request):
            guard let inputURL = inputURLs.first,
                  let updatedRequest = try? PBAAClusteringRunRequest(
                    inputFASTQURL: inputURL,
                    guideSourceURL: request.guideSourceURL,
                    outputDirectory: request.outputDirectory,
                    outputName: request.outputName,
                    threads: request.threads,
                    seed: request.seed,
                    extraArgumentsText: request.extraArgumentsText,
                    containerPins: request.containerPins
                  ) else { return self }
            return .pbaa(request: updatedRequest)
        case .ontGenotyping(let request):
            return .ontGenotyping(request: ONTBarcodeDemuxGenotypingRunRequest(
                inputFASTQURLs: inputURLs,
                referenceSourceURL: request.referenceSourceURL,
                barcodeDefinitionsURL: request.barcodeDefinitionsURL,
                outputDirectory: request.outputDirectory,
                outputName: request.outputName,
                demuxManifestURL: request.demuxManifestURL,
                analysisName: request.analysisName,
                comparisonWorkbookURL: request.comparisonWorkbookURL,
                comparisonName: request.comparisonName,
                projectURL: request.projectURL,
                threads: request.threads,
                sortThreads: request.sortThreads,
                minSupport: request.minSupport,
                haplotypeDropoutSampleFraction: request.haplotypeDropoutSampleFraction,
                haplotypeDropoutLocusFraction: request.haplotypeDropoutLocusFraction,
                haplotypeDropoutLocusFractionOverrides: request.haplotypeDropoutLocusFractionOverrides,
                haplotypeAssayID: request.haplotypeAssayID,
                haplotypeSpeciesCode: request.haplotypeSpeciesCode,
                haplotypeDefinitionScope: request.haplotypeDefinitionScope,
                haplotypeDefinitionSetID: request.haplotypeDefinitionSetID,
                presetID: request.presetID,
                presetVersion: request.presetVersion,
                lockedReferenceSHA256: request.lockedReferenceSHA256,
                extraArguments: request.extraArguments,
                mode: request.mode,
                readType: request.readType,
                resultWorkflowKind: request.resultWorkflowKind,
                aiSpecialistPresetID: request.aiSpecialistPresetID
            ))
        }
    }

    var batchManifestLabel: String {
        switch self {
        case .refreshQCSummary:
            return "FASTQ QC Summary"
        case .derivative(let request, _, _):
            return request.batchLabel
        case .ontFluidigmSampleSplit:
            return "ONT Fluidigm Sample Split"
        case .ontPacBioBarcodeDemux:
            return "ONT PacBio Barcode Demultiplex"
        case .map:
            return "Map Reads"
        case .assemble(let request, _):
            return request.tool.displayName
        case .classify(let tool, _, _, _):
            return tool.title
        case .savont:
            return "Savont Clustering"
        case .pbaa:
            return "pbAA Amplicon Clustering"
        case .ontGenotyping:
            return "miSeq amplicon MHC genotyping"
        }
    }

    var batchManifestOperationKind: String {
        switch self {
        case .refreshQCSummary:
            return "qcSummary"
        case .derivative(let request, _, _):
            return request.operationKindString
        case .ontFluidigmSampleSplit:
            return "ontFluidigmSampleSplit"
        case .ontPacBioBarcodeDemux:
            return "ontPacBioBarcodeDemux"
        case .map:
            return "mapping"
        case .assemble:
            return "assembly"
        case .classify:
            return "classification"
        case .savont:
            return "savontClustering"
        case .pbaa:
            return "pbaaClustering"
        case .ontGenotyping:
            return "ampliconGenotyping"
        }
    }

    var batchManifestParameters: [String: String] {
        switch self {
        case .refreshQCSummary:
            return [:]
        case .derivative(let request, _, _):
            return request.batchParameters
        case .ontFluidigmSampleSplit(_, let barcodeDefinitionsURL, let threads):
            return [
                "barcodes": barcodeDefinitionsURL.lastPathComponent,
                "threads": String(threads),
                "primerMismatches": "2",
                "minimumInsertLength": "20",
                "payloadRepresentation": "deduplicated gzip-compressed CS1-CS2 insert FASTQ",
                "duplicateCountEncoding": "size=N",
            ]
        case .ontPacBioBarcodeDemux(
            _,
            let barcodeDefinitionsURL,
            let threads,
            let chunkJobs,
            let maxReadsPerSlice,
            let maxBytesPerCutadapt
        ):
            return [
                "barcodes": barcodeDefinitionsURL.lastPathComponent,
                "threads": String(threads),
                "chunkJobs": String(chunkJobs),
                "maxReadsPerSlice": String(maxReadsPerSlice),
                "maxBytesPerCutadapt": String(maxBytesPerCutadapt),
                "payloadRepresentation": "gzip-compressed full demultiplexed FASTQ",
            ]
        case .map(_, let referenceURL, _):
            return ["reference": referenceURL.lastPathComponent]
        case .assemble(let request, _):
            return [
                "assembler": request.tool.rawValue,
                "readType": request.readType.rawValue,
            ]
        case .classify(_, _, let databaseName, let extraArguments):
            var params = ["database": databaseName]
            if !extraArguments.isEmpty {
                params["extraArgs"] = AdvancedCommandLineOptions.join(extraArguments)
            }
            return params
        case .savont(let request):
            var params = [
                "threads": String(request.threads),
                "qualityValueCutoff": String(request.qualityValueCutoff),
                "minimumClusterSize": String(request.minimumClusterSize),
                "singleStrand": String(request.singleStrand),
            ]
            if let requestOutputName = request.singleInputOutputName {
                params["outputName"] = requestOutputName
            }
            if let minimumReadLength = request.minimumReadLength {
                params["minimumReadLength"] = String(minimumReadLength)
            }
            if let maximumReadLength = request.maximumReadLength {
                params["maximumReadLength"] = String(maximumReadLength)
            }
            return params
        case .pbaa(let request):
            var params: [String: String] = [
                "guide": request.guideSourceURL.lastPathComponent,
                "outputName": request.outputName,
                "threads": String(request.threads),
                "seed": String(request.seed),
            ]
            if !request.extraArguments.isEmpty {
                params["extraArgs"] = AdvancedCommandLineOptions.join(request.extraArguments)
            }
            return params
        case .ontGenotyping(let request):
            let haplotypeDropoutLocusFractionOverrides = request.haplotypeDropoutLocusFractionOverrides
                .keys
                .sorted()
                .compactMap { key -> String? in
                    guard let fraction = request.haplotypeDropoutLocusFractionOverrides[key] else {
                        return nil
                    }
                    return "\(key)=\(fraction)"
                }
                .joined(separator: ";")
            var params = [
                "reference": request.referenceSourceURL.lastPathComponent,
                "outputName": request.outputName,
                "analysisName": request.analysisName,
                "threads": "\(request.threads)",
                "sortThreads": "\(request.sortThreads)",
                "minSupport": "\(request.minSupport)",
                "haplotypeDropoutSampleFraction": request.haplotypeDropoutSampleFraction.map { "\($0)" } ?? "",
                "haplotypeDropoutLocusFraction": request.haplotypeDropoutLocusFraction.map { "\($0)" } ?? "",
                "haplotypeDropoutLocusFractionOverrides": haplotypeDropoutLocusFractionOverrides,
                "mode": request.mode.rawValue,
                "readType": request.readType.rawValue,
                "maxMismatches": "0",
                "allowIndels": "true",
            ]
            if let barcodeDefinitionsURL = request.barcodeDefinitionsURL {
                params["barcodes"] = barcodeDefinitionsURL.lastPathComponent
            }
            if let haplotypeDefinitionSetID = request.haplotypeDefinitionSetID {
                if let haplotypeAssayID = request.haplotypeAssayID {
                    params["haplotypeAssay"] = haplotypeAssayID
                }
                if let haplotypeSpeciesCode = request.haplotypeSpeciesCode {
                    params["haplotypeSpecies"] = haplotypeSpeciesCode
                }
                if let haplotypeDefinitionScope = request.haplotypeDefinitionScope {
                    params["haplotypeDefinitionScope"] = haplotypeDefinitionScope.rawValue
                }
                params["haplotypeDefinition"] = haplotypeDefinitionSetID
            }
            if !request.extraArguments.isEmpty {
                params["extraArgs"] = AdvancedCommandLineOptions.join(request.extraArguments)
            }
            return params
        }
    }


    var isRibosomalRNAFilterRequest: Bool {
        if case .derivative(let request, _, _) = self {
            return request.isRibosomalRNAFilterRequest
        }
        return false
    }

    var outputNameStem: String {
        switch self {
        case .refreshQCSummary:
            return "qc-summary"
        case .derivative(let request, _, _):
            return request.outputNameStem
        case .ontFluidigmSampleSplit:
            return "ont-fluidigm-samples"
        case .ontPacBioBarcodeDemux:
            return "ont-pacbio-barcode-demux"
        case .map:
            return "mapping"
        case .assemble(let request, _):
            return "assembly-\(request.tool.rawValue)"
        case .classify(let tool, _, _, _):
            return tool.title.lowercased()
        case .savont:
            return "savont-clusters"
        case .pbaa:
            return "pbaa"
        case .ontGenotyping(let request):
            return request.outputName
        }
    }

    var requiresSingleResolvedFASTQPerInput: Bool {
        switch self {
        case .refreshQCSummary, .derivative, .savont, .pbaa:
            return true
        case .ontFluidigmSampleSplit, .ontPacBioBarcodeDemux, .map, .assemble, .classify, .ontGenotyping:
            return false
        }
    }

    var allowsDirectMultiFileFASTQBundleInput: Bool {
        guard case .derivative(let request, _, _) = self,
              case .demultiplex(
                  _,
                  _,
                  _,
                  _,
                  _,
                  _,
                  _,
                  let engine,
                  _,
                  _,
                  _
              ) = request else {
            return false
        }
        return engine == .exactBareBarcode
    }

    var resolvesInputsBeforeCLI: Bool {
        if case .savont = self {
            return false
        }
        if case .assemble = self {
            return false
        }
        if case .ontFluidigmSampleSplit = self {
            return false
        }
        if case .ontPacBioBarcodeDemux = self {
            return false
        }
        return true
    }

    var requiresSyntheticFASTQBridge: Bool {
        switch self {
        case .refreshQCSummary:
            return false
        case .derivative:
            return !isRibosomalRNAFilterRequest
        case .classify(let tool, _, _, _):
            switch tool {
            case .esViritu, .taxTriage:
                return true
            default:
                return false
            }
        case .ontFluidigmSampleSplit, .ontPacBioBarcodeDemux, .map, .assemble, .savont, .pbaa, .ontGenotyping:
            return false
        }
    }
}

extension AssemblyRunRequest {
    func replacingInputURLs(with inputURLs: [URL]) -> AssemblyRunRequest {
        AssemblyRunRequest(
            tool: tool,
            readType: readType,
            inputURLs: inputURLs,
            projectName: projectName,
            outputDirectory: outputDirectory,
            pairedEnd: pairedEnd,
            threads: threads,
            memoryGB: memoryGB,
            minContigLength: minContigLength,
            selectedProfileID: selectedProfileID,
            extraArguments: extraArguments
        )
    }
}

extension FASTQDerivativeRequest {
    var provenanceInputURLs: [URL] {
        switch self {
        case .contaminantFilter(_, let referenceFasta, _, _):
            return referenceFasta.map { [URL(fileURLWithPath: $0)] } ?? []
        case .primerRemoval(let configuration):
            guard configuration.source == .reference,
                  let referenceFasta = configuration.referenceFasta else {
                return []
            }
            return [URL(fileURLWithPath: referenceFasta)]
        case .sequencePresenceFilter(_, let fastaPath, _, _, _, _, _):
            return fastaPath.map { [URL(fileURLWithPath: $0)] } ?? []
        case .orient(let referenceURL, _, _, _, _):
            return [referenceURL]
        default:
            return []
        }
    }


    var isRibosomalRNAFilterRequest: Bool {
        if case .ribosomalRNAFilter = self {
            return true
        }
        return false
    }

    var usesDirectoryOutput: Bool {
        if case .demultiplex = self {
            return true
        }
        return isRibosomalRNAFilterRequest
    }

    var outputNameStem: String {
        switch self {
        case .ribosomalRNAFilter(let retention, _):
            return "deacon-ribo-\(retention.rawValue)"
        default:
            return operationKindString
        }
    }
}

extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
