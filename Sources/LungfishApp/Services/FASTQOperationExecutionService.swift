import Foundation
import LungfishIO
import LungfishWorkflow

struct CLIInvocation: Sendable, Equatable {
    let subcommand: String
    let arguments: [String]
}

struct FASTQCLIExecutionResult: Sendable, Equatable {
    let outputURLs: [URL]
}

struct FASTQOperationExecutionResult: Sendable, Equatable {
    let resolvedRequest: FASTQOperationLaunchRequest
    let executedInvocations: [CLIInvocation]
    let importedURLs: [URL]
    let groupedContainerURL: URL?
}

protocol FASTQOperationInputResolving: Sendable {
    func resolve(
        request: FASTQOperationLaunchRequest,
        tempDirectory: URL
    ) async throws -> FASTQOperationLaunchRequest
}

protocol FASTQOperationCommandRunning: Sendable {
    func run(invocation: CLIInvocation, outputDirectory: URL) async throws -> FASTQCLIExecutionResult
}

protocol FASTQOperationDirectImporting: Sendable {
    func importOutputs(
        at outputURLs: [URL],
        forResolvedRequest request: FASTQOperationLaunchRequest,
        originalRequest: FASTQOperationLaunchRequest,
        outputDirectory: URL
    ) async throws -> [URL]
}

enum FASTQOperationExecutionError: Error, LocalizedError {
    case unsupportedAdapterTrim(String)
    case unsupportedPrimerRemoval(String)
    case unsupportedDemultiplex(String)
    case unsupportedOrient(String)
    case unsupportedAssembly(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedAdapterTrim(let reason):
            return "FASTQ adapter trimming request is not supported by the CLI builder: \(reason)"
        case .unsupportedPrimerRemoval(let reason):
            return "FASTQ primer trimming request is not supported by the CLI builder: \(reason)"
        case .unsupportedDemultiplex(let reason):
            return "FASTQ demultiplex request is not supported by the CLI builder: \(reason)"
        case .unsupportedOrient(let reason):
            return "FASTQ orient request is not supported by the CLI builder: \(reason)"
        case .unsupportedAssembly(let reason):
            return "FASTQ assembly request is not supported by the CLI builder: \(reason)"
        }
    }
}

struct FASTQOperationExecutionService {
    private let inputResolver: any FASTQOperationInputResolving
    private let commandRunner: any FASTQOperationCommandRunning
    private let directImporter: any FASTQOperationDirectImporting

    init(
        inputResolver: any FASTQOperationInputResolving = FASTQSourceResolverAdapter(),
        commandRunner: any FASTQOperationCommandRunning = LungfishCLIProcessRunner(),
        directImporter: any FASTQOperationDirectImporting = IdentityFASTQOperationImporter()
    ) {
        self.inputResolver = inputResolver
        self.commandRunner = commandRunner
        self.directImporter = directImporter
    }

    func execute(
        request: FASTQOperationLaunchRequest,
        workingDirectory: URL
    ) async throws -> FASTQOperationExecutionResult {
        let materializationDirectory = workingDirectory.appendingPathComponent(
            "materialized-inputs-\(UUID().uuidString)",
            isDirectory: true
        )
        let outputDirectory = executionOutputDirectory(for: request, workingDirectory: workingDirectory)
        try FileManager.default.createDirectory(at: materializationDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let resolvedRequest = try await inputResolver.resolve(
            request: request,
            tempDirectory: materializationDirectory
        )
        let executionPlans = makeExecutionPlans(
            originalRequest: request,
            resolvedRequest: resolvedRequest,
            baseOutputDirectory: outputDirectory
        )

        var invocations: [CLIInvocation] = []
        var outputURLs: [URL] = []

        for executionPlan in executionPlans {
            let executionDirectory = executionDirectory(for: executionPlan)
            try FileManager.default.createDirectory(at: executionDirectory, withIntermediateDirectories: true)
            let invocation = try buildExecutionInvocation(
                for: executionPlan.resolvedRequest,
                outputTargetPath: executionPlan.outputTarget.path
            )
            invocations.append(invocation)
            let result = try await commandRunner.run(
                invocation: invocation,
                outputDirectory: executionDirectory
            )
            if result.outputURLs.isEmpty {
                outputURLs.append(contentsOf: discoverOutputs(for: executionPlan, in: executionDirectory))
            } else {
                outputURLs.append(contentsOf: result.outputURLs)
            }
        }

        if outputURLs.isEmpty {
            outputURLs = Self.discoverFASTQBundles(in: outputDirectory)
        }

        switch resolvedRequest.outputMode {
        case .groupedResult:
            try persistGroupedResultManifest(
                originalRequest: request,
                resolvedRequest: resolvedRequest,
                outputURLs: outputURLs,
                outputDirectory: outputDirectory
            )
            return FASTQOperationExecutionResult(
                resolvedRequest: resolvedRequest,
                executedInvocations: invocations,
                importedURLs: [outputDirectory],
                groupedContainerURL: outputDirectory
            )

        case .perInput, .fixedBatch:
            let importedURLs = try await directImporter.importOutputs(
                at: outputURLs,
                forResolvedRequest: resolvedRequest,
                originalRequest: request,
                outputDirectory: outputDirectory
            )
            return FASTQOperationExecutionResult(
                resolvedRequest: resolvedRequest,
                executedInvocations: invocations,
                importedURLs: importedURLs,
                groupedContainerURL: nil
            )
        }
    }

    func buildInvocation(for request: FASTQOperationLaunchRequest) throws -> CLIInvocation {
        try buildExecutionInvocation(for: request, outputTargetPath: derivedOutputPlaceholder)
    }

    private var derivedOutputPlaceholder: String {
        "<derived>"
    }

    private func executionOutputDirectory(
        for request: FASTQOperationLaunchRequest,
        workingDirectory: URL
    ) -> URL {
        if request.outputMode == .groupedResult || request.isDemultiplexRequest {
            return workingDirectory
        }

        if case .assemble = request {
            return workingDirectory
        }

        return workingDirectory.appendingPathComponent(
            "cli-output-\(UUID().uuidString)",
            isDirectory: true
        )
    }

    private func makeExecutionPlans(
        originalRequest: FASTQOperationLaunchRequest,
        resolvedRequest: FASTQOperationLaunchRequest,
        baseOutputDirectory: URL
    ) -> [FASTQExecutionPlan] {
        let requestPairs = splitExecutionRequestsIfNeeded(
            originalRequest: originalRequest,
            resolvedRequest: resolvedRequest
        )

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
                outputTarget = parentDirectory.appendingPathComponent(
                    defaultFASTQOutputFilename(for: pair.original)
                )
            case .jsonReport:
                outputTarget = parentDirectory.appendingPathComponent("qc-summary.json")
            }

            return FASTQExecutionPlan(
                originalRequest: pair.original,
                resolvedRequest: pair.resolved,
                outputTarget: outputTarget,
                outputKind: outputKind
            )
        }
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

        default:
            return [(originalRequest, resolvedRequest)]
        }
    }

    private func executionOutputKind(for request: FASTQOperationLaunchRequest) -> FASTQExecutionOutputKind {
        switch request {
        case .refreshQCSummary:
            return .jsonReport
        case .derivative(let derivativeRequest, _, _):
            return derivativeRequest.isDemultiplexRequest ? .directory : .fastqFile
        case .map, .assemble, .classify:
            return .directory
        }
    }

    private func outputParentDirectory(
        for request: FASTQOperationLaunchRequest,
        baseOutputDirectory: URL,
        totalRequestCount: Int
    ) -> URL {
        guard totalRequestCount > 1 else {
            return baseOutputDirectory
        }

        let stem = request.primaryInputURL
            .map(Self.sanitizedStem(for:))
            ?? "output-\(UUID().uuidString.prefix(8))"
        return baseOutputDirectory.appendingPathComponent(stem, isDirectory: true)
    }

    private func defaultFASTQOutputFilename(for request: FASTQOperationLaunchRequest) -> String {
        switch request {
        case .derivative(let derivativeRequest, _, _):
            return "\(derivativeRequest.operationKindString).fastq"
        default:
            return "output.fastq"
        }
    }

    private func discoverOutputs(for plan: FASTQExecutionPlan, in outputDirectory: URL) -> [URL] {
        switch plan.outputKind {
        case .directory:
            let directory = plan.outputTarget.standardizedFileURL
            if (try? AssemblyResult.load(from: directory)) != nil {
                return [directory]
            }
            return Self.discoverFASTQBundles(in: directory)
        case .fastqFile, .jsonReport:
            return FileManager.default.fileExists(atPath: plan.outputTarget.path)
                ? [plan.outputTarget]
                : []
        }
    }

    private func executionDirectory(for plan: FASTQExecutionPlan) -> URL {
        switch plan.outputKind {
        case .directory:
            return plan.outputTarget
        case .fastqFile, .jsonReport:
            return plan.outputTarget.deletingLastPathComponent()
        }
    }

    fileprivate static func sanitizedStem(for url: URL) -> String {
        let stem = url.deletingPathExtension().lastPathComponent
        return stem.isEmpty ? "output" : stem
    }

    private func persistGroupedResultManifest(
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

    private func buildExecutionInvocation(
        for request: FASTQOperationLaunchRequest,
        outputTargetPath: String
    ) throws -> CLIInvocation {
        switch request {
        case .refreshQCSummary(let inputURLs):
            return CLIInvocation(
                subcommand: "fastq",
                arguments: ["qc-summary"] + inputURLs.map(\.path) + ["--output", outputTargetPath]
            )

        case .derivative(let request, let inputURLs, _):
            return CLIInvocation(
                subcommand: "fastq",
                arguments: try fastqArguments(
                    for: request,
                    inputURLs: inputURLs,
                    outputTarget: outputTargetPath
                )
            )

        case .map(let inputURLs, let referenceURL, _):
            var arguments = inputURLs.map(\.path)
            arguments += ["--reference", referenceURL.path]
            if inputURLs.count == 2 {
                arguments.append("--paired")
            }
            return CLIInvocation(subcommand: "map", arguments: arguments)

        case .assemble(let request, _):
            var arguments = request.inputURLs.map(\.path)
            if request.pairedEnd {
                arguments.append("--paired")
            }
            arguments += [
                "--assembler", request.tool.rawValue,
                "--read-type", request.readType.cliArgument,
                "--project-name", request.projectName,
                "--threads", "\(request.threads)",
                "--output", outputTargetPath,
            ]
            if let memoryGB = request.memoryGB {
                arguments += ["--memory-gb", "\(memoryGB)"]
            }
            if let minContigLength = request.minContigLength {
                arguments += ["--min-contig-length", "\(minContigLength)"]
            }
            if let selectedProfileID = request.selectedProfileID {
                arguments += ["--profile", selectedProfileID]
            }
            for extraArgument in request.extraArguments {
                arguments += ["--extra-arg", extraArgument]
            }
            return CLIInvocation(subcommand: "assemble", arguments: arguments)

        case .classify(let tool, let inputURLs, let databaseName):
            let arguments = inputURLs.map(\.path) + ["--db", databaseName]
            switch tool {
            case .kraken2:
                return CLIInvocation(subcommand: "classify", arguments: arguments)
            case .esViritu:
                return CLIInvocation(subcommand: "esviritu", arguments: ["detect"] + arguments)
            case .taxTriage:
                return CLIInvocation(subcommand: "taxtriage", arguments: ["run"] + arguments)
            default:
                return CLIInvocation(subcommand: "classify", arguments: arguments)
            }
        }
    }

    private func qualityTrimModeArgument(for mode: FASTQQualityTrimMode) -> String {
        switch mode {
        case .cutRight:
            return "cut-right"
        case .cutFront:
            return "cut-front"
        case .cutTail:
            return "cut-tail"
        case .cutBoth:
            return "cut-both"
        }
    }

    private func sequenceSearchEndArgument(for searchEnd: FASTQAdapterSearchEnd) -> String {
        switch searchEnd {
        case .fivePrime:
            return "left"
        case .threePrime:
            return "right"
        }
    }

    private func fastqArguments(
        for request: FASTQDerivativeRequest,
        inputURLs: [URL],
        outputTarget: String
    ) throws -> [String] {
        guard let inputURL = inputURLs.first else {
            return ["qc-summary", "--output", outputTarget]
        }

        switch request {
        case .subsampleProportion(let proportion):
            return [
                "subsample",
                inputURL.path,
                "--proportion",
                String(proportion),
                "-o",
                outputTarget,
            ]

        case .subsampleCount(let count):
            return [
                "subsample",
                inputURL.path,
                "--count",
                "\(count)",
                "-o",
                outputTarget,
            ]

        case .lengthFilter(let min, let max):
            var arguments = ["length-filter", inputURL.path]
            if let min {
                arguments += ["--min", "\(min)"]
            }
            if let max {
                arguments += ["--max", "\(max)"]
            }
            arguments += ["-o", outputTarget]
            return arguments

        case .searchText(let query, let field, let regex):
            var arguments = [
                "search-text",
                inputURL.path,
                "--query",
                query,
                "--field",
                field.rawValue,
            ]
            if regex {
                arguments.append("--regex")
            }
            arguments += ["-o", outputTarget]
            return arguments

        case .searchMotif(let pattern, let regex):
            var arguments = [
                "search-motif",
                inputURL.path,
                "--pattern",
                pattern,
            ]
            if regex {
                arguments.append("--regex")
            }
            arguments += ["-o", outputTarget]
            return arguments

        case .deduplicate(let preset, let substitutions, let optical, let opticalDistance):
            var arguments = [
                "deduplicate",
                inputURL.path,
                "--subs",
                "\(substitutions)",
                "-o",
                outputTarget,
            ]
            if optical {
                arguments += ["--optical", "--dupedist", "\(opticalDistance)"]
            }
            _ = preset
            return arguments

        case .qualityTrim(let threshold, let windowSize, let mode):
            return [
                "quality-trim",
                inputURL.path,
                "--threshold",
                "\(threshold)",
                "--window",
                "\(windowSize)",
                "--mode",
                qualityTrimModeArgument(for: mode),
                "-o",
                outputTarget,
            ]

        case .adapterTrim(let mode, let sequence, let sequenceR2, let fastaFilename):
            guard sequenceR2 == nil, fastaFilename == nil else {
                throw FASTQOperationExecutionError.unsupportedAdapterTrim(
                    "sequenceR2 and fastaFilename are not encodable"
                )
            }
            var arguments = ["adapter-trim", inputURL.path]
            switch mode {
            case .autoDetect:
                guard sequence == nil else {
                    throw FASTQOperationExecutionError.unsupportedAdapterTrim(
                        "auto-detect cannot carry a literal adapter sequence"
                    )
                }
            case .specified:
                guard let sequence else {
                    throw FASTQOperationExecutionError.unsupportedAdapterTrim(
                        "manual adapter mode requires a literal adapter sequence"
                    )
                }
                arguments += ["--adapter", sequence]
            case .fastaFile:
                throw FASTQOperationExecutionError.unsupportedAdapterTrim(
                    "fastaFile mode is not encodable"
                )
            }
            arguments += ["-o", outputTarget]
            return arguments

        case .fixedTrim(let from5Prime, let from3Prime):
            var arguments = ["fixed-trim", inputURL.path]
            if from5Prime > 0 {
                arguments += ["--front", "\(from5Prime)"]
            }
            if from3Prime > 0 {
                arguments += ["--tail", "\(from3Prime)"]
            }
            arguments += ["-o", outputTarget]
            return arguments

        case .contaminantFilter(let mode, let referenceFasta, let kmerSize, let hammingDistance):
            var arguments = [
                "contaminant-filter",
                inputURL.path,
                "--mode",
                mode.rawValue,
                "--kmer",
                "\(kmerSize)",
                "--hdist",
                "\(hammingDistance)",
                "-o",
                outputTarget,
            ]
            if let referenceFasta {
                arguments.insert(contentsOf: ["--ref", referenceFasta], at: 4)
            }
            return arguments

        case .pairedEndMerge(let strictness, let minOverlap):
            var arguments = [
                "merge",
                inputURL.path,
                "--min-overlap",
                "\(minOverlap)",
                "-o",
                outputTarget,
            ]
            if strictness == .strict {
                arguments.append("--strict")
            }
            return arguments

        case .pairedEndRepair:
            return [
                "repair",
                inputURL.path,
                "-o",
                outputTarget,
            ]

        case .primerRemoval(let configuration):
            guard configuration.tool == .bbduk else {
                throw FASTQOperationExecutionError.unsupportedPrimerRemoval(
                    "only the bbduk subset is encodable"
                )
            }
            guard configuration.readMode == .single,
                  configuration.mode == .fivePrime,
                  configuration.anchored5Prime,
                  configuration.anchored3Prime,
                  configuration.errorRate == 0.12,
                  configuration.minimumOverlap == 12,
                  configuration.allowIndels,
                  !configuration.keepUntrimmed,
                  configuration.searchReverseComplement,
                  configuration.pairFilter == .any,
                  configuration.ktrimDirection == .left
            else {
                throw FASTQOperationExecutionError.unsupportedPrimerRemoval(
                    "only the literal/reference bbduk subset with the default read-mode flags is encodable"
                )
            }
            var arguments = ["primer-remove", inputURL.path]
            if let sequence = configuration.forwardSequence, configuration.source == .literal {
                arguments += ["--literal", sequence]
            } else if let referenceFasta = configuration.referenceFasta, configuration.source == .reference {
                arguments += ["--ref", referenceFasta]
            } else {
                throw FASTQOperationExecutionError.unsupportedPrimerRemoval(
                    "literal and reference primer inputs must match the selected source"
                )
            }
            arguments += [
                "--kmer",
                "\(configuration.kmerSize)",
                "--mink",
                "\(configuration.minKmer)",
                "--hdist",
                "\(configuration.hammingDistance)",
            ]
            arguments += ["-o", outputTarget]
            return arguments

        case .sequencePresenceFilter(
            let sequence,
            let fastaPath,
            let searchEnd,
            let minOverlap,
            let errorRate,
            let keepMatched,
            let searchReverseComplement
        ):
            var arguments = [
                "sequence-filter",
                inputURL.path,
                "--search-end",
                sequenceSearchEndArgument(for: searchEnd),
                "--min-overlap",
                "\(minOverlap)",
                "--error-rate",
                String(format: "%.2f", errorRate),
                "-o",
                outputTarget,
            ]
            if let sequence {
                arguments += ["--sequence", sequence]
            } else if let fastaPath {
                arguments += ["--fasta-path", fastaPath]
            }
            if keepMatched {
                arguments.append("--keep-matched")
            }
            if searchReverseComplement {
                arguments.append("--search-rc")
            }
            return arguments

        case .errorCorrection(let kmerSize):
            return [
                "error-correct",
                inputURL.path,
                "--kmer",
                "\(kmerSize)",
                "-o",
                outputTarget,
            ]

        case .interleaveReformat(let direction):
            switch direction {
            case .interleave:
                return [
                    "interleave",
                    "--in1",
                    inputURL.path,
                    "--in2",
                    "<R2>",
                    "-o",
                    outputTarget,
                ]
            case .deinterleave:
                return [
                    "deinterleave",
                    inputURL.path,
                    "--out1",
                    "\(outputTarget).R1.fastq",
                    "--out2",
                    "\(outputTarget).R2.fastq",
                ]
            }

        case .demultiplex(
            let kitID,
            let customCSVPath,
            let location,
            let symmetryMode,
            let maxDistanceFrom5Prime,
            let maxDistanceFrom3Prime,
            let errorRate,
            let trimBarcodes,
            let sampleAssignments,
            let kitOverride
        ):
            guard sampleAssignments?.isEmpty ?? true else {
                throw FASTQOperationExecutionError.unsupportedDemultiplex(
                    "sampleAssignments are not encodable"
                )
            }
            guard symmetryMode == nil else {
                throw FASTQOperationExecutionError.unsupportedDemultiplex(
                    "symmetryMode is not encodable"
                )
            }
            guard kitOverride == nil else {
                throw FASTQOperationExecutionError.unsupportedDemultiplex(
                    "kitOverride is not encodable"
                )
            }
            var arguments = [
                "demultiplex",
                inputURL.path,
                "--kit",
                customCSVPath ?? kitID,
                "-o",
                outputTarget,
                "--location",
                location,
                "--max-distance-5prime",
                "\(maxDistanceFrom5Prime)",
                "--max-distance-3prime",
                "\(maxDistanceFrom3Prime)",
                "--error-rate",
                String(format: "%.2f", errorRate),
            ]
            if !trimBarcodes {
                arguments.append("--no-trim")
            }
            return arguments

        case .orient(let referenceURL, let wordLength, let dbMask, let saveUnoriented):
            guard !saveUnoriented else {
                throw FASTQOperationExecutionError.unsupportedOrient(
                    "saveUnoriented is not encodable"
                )
            }
            return [
                "orient",
                inputURL.path,
                "--reference",
                referenceURL.path,
                "--word-length",
                "\(wordLength)",
                "--db-mask",
                dbMask,
                "-o",
                outputTarget,
            ]

        case .humanReadScrub(let databaseID, _):
            return [
                "scrub-human",
                inputURL.path,
                "--database-id",
                databaseID,
                "-o",
                outputTarget,
            ]
        }
    }

    fileprivate static func discoverFASTQBundles(in directory: URL) -> [URL] {
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

    fileprivate static func relativePath(from base: URL, to target: URL) -> String? {
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

private enum FASTQExecutionOutputKind: Sendable {
    case fastqFile
    case directory
    case jsonReport
}

private struct FASTQExecutionPlan: Sendable {
    let originalRequest: FASTQOperationLaunchRequest
    let resolvedRequest: FASTQOperationLaunchRequest
    let outputTarget: URL
    let outputKind: FASTQExecutionOutputKind
}

private struct FASTQSourceResolverAdapter: FASTQOperationInputResolving {
    func resolve(
        request: FASTQOperationLaunchRequest,
        tempDirectory: URL
    ) async throws -> FASTQOperationLaunchRequest {
        if request.requiresSingleResolvedFASTQPerInput {
            var resolvedURLs: [URL] = []
            resolvedURLs.reserveCapacity(request.inputURLs.count)
            for inputURL in request.inputURLs {
                resolvedURLs.append(
                    try await resolveSingleExecutionInput(
                        from: inputURL,
                        tempDirectory: tempDirectory
                    )
                )
            }
            return request.replacingInputURLs(with: resolvedURLs)
        }

        let resolver = FASTQSourceResolver()
        resolver.materializer = { bundleURL, tempDir, progress in
            try await FASTQDerivativeService.shared.materializeDatasetFASTQ(
                fromBundle: bundleURL,
                tempDirectory: tempDir,
                progress: progress
            )
        }

        var resolvedURLs: [URL] = []
        for inputURL in request.inputURLs {
            if FASTQBundle.isBundleURL(inputURL) {
                let urls = try await resolver.resolve(
                    bundleURL: inputURL,
                    tempDirectory: tempDirectory,
                    progress: { _, _ in }
                )
                resolvedURLs.append(contentsOf: urls)
            } else if FASTQBundle.isBundleURL(inputURL.deletingLastPathComponent()) {
                let urls = try await resolver.resolve(
                    bundleURL: inputURL.deletingLastPathComponent(),
                    tempDirectory: tempDirectory,
                    progress: { _, _ in }
                )
                resolvedURLs.append(contentsOf: urls)
            } else {
                resolvedURLs.append(inputURL)
            }
        }

        return request.replacingInputURLs(with: resolvedURLs)
    }

    private func resolveSingleExecutionInput(
        from inputURL: URL,
        tempDirectory: URL
    ) async throws -> URL {
        let standardizedInputURL = inputURL.standardizedFileURL
        let bundleURL: URL?
        if FASTQBundle.isBundleURL(standardizedInputURL) {
            bundleURL = standardizedInputURL
        } else {
            let parentBundleURL = standardizedInputURL.deletingLastPathComponent()
            bundleURL = FASTQBundle.isBundleURL(parentBundleURL) ? parentBundleURL : nil
        }

        guard let bundleURL else {
            return standardizedInputURL
        }

        if FASTQBundle.isDerivedBundle(bundleURL) {
            return try await FASTQDerivativeService.shared.materializeDatasetFASTQ(
                fromBundle: bundleURL,
                tempDirectory: tempDirectory,
                progress: nil
            )
        }

        if let allFASTQURLs = FASTQBundle.resolveAllFASTQURLs(for: bundleURL),
           allFASTQURLs.count > 1 {
            return try materializeConcatenatedFASTQ(
                from: allFASTQURLs,
                tempDirectory: tempDirectory
            )
        }

        if let primaryFASTQURL = FASTQBundle.resolvePrimaryFASTQURL(for: bundleURL) {
            return primaryFASTQURL
        }

        return standardizedInputURL
    }

    private func materializeConcatenatedFASTQ(
        from inputURLs: [URL],
        tempDirectory: URL
    ) throws -> URL {
        guard let firstInputURL = inputURLs.first else {
            throw ExtractionError.noSourceFASTQ
        }

        let fileExtension: String
        if firstInputURL.pathExtension.lowercased() == "gz" {
            let baseExtension = firstInputURL.deletingPathExtension().pathExtension
            fileExtension = baseExtension.isEmpty ? "fastq.gz" : "\(baseExtension).gz"
        } else {
            fileExtension = firstInputURL.pathExtension.isEmpty ? "fastq" : firstInputURL.pathExtension
        }

        let outputURL = tempDirectory.appendingPathComponent(
            FASTQSourceResolver.tempFileName(extension: fileExtension)
        )
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        defer { try? outputHandle.close() }

        for inputURL in inputURLs {
            let inputHandle = try FileHandle(forReadingFrom: inputURL)
            defer { try? inputHandle.close() }

            while true {
                let chunk = inputHandle.readData(ofLength: 1_048_576)
                if chunk.isEmpty { break }
                outputHandle.write(chunk)
            }
        }

        return outputURL
    }
}

private struct LungfishCLIProcessRunner: FASTQOperationCommandRunning {
    func run(invocation: CLIInvocation, outputDirectory: URL) async throws -> FASTQCLIExecutionResult {
        guard let cliURL = LungfishCLIRunner.findCLI() else {
            throw LungfishCLIRunner.RunError.cliNotFound
        }

        let process = Process()
        process.executableURL = cliURL
        process.currentDirectoryURL = outputDirectory
        process.arguments = [invocation.subcommand] + invocation.arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            throw LungfishCLIRunner.RunError.launchFailed(error.localizedDescription)
        }

        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let stderrText = String(
                data: stderr.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            throw LungfishCLIRunner.RunError.nonZeroExit(
                status: process.terminationStatus,
                stderr: stderrText
            )
        }

        return FASTQCLIExecutionResult(
            outputURLs: FASTQOperationExecutionService.discoverFASTQBundles(in: outputDirectory)
        )
    }
}

private struct IdentityFASTQOperationImporter: FASTQOperationDirectImporting {
    func importOutputs(
        at outputURLs: [URL],
        forResolvedRequest request: FASTQOperationLaunchRequest,
        originalRequest: FASTQOperationLaunchRequest,
        outputDirectory: URL
    ) async throws -> [URL] {
        _ = request
        _ = originalRequest
        _ = outputDirectory
        return outputURLs
    }
}

struct BundleFASTQOperationImporter: FASTQOperationDirectImporting {
    let destinationDirectory: URL

    func importOutputs(
        at outputURLs: [URL],
        forResolvedRequest request: FASTQOperationLaunchRequest,
        originalRequest: FASTQOperationLaunchRequest,
        outputDirectory: URL
    ) async throws -> [URL] {
        _ = request

        switch originalRequest {
        case .refreshQCSummary(let inputURLs):
            guard let reportURL = outputURLs.first else { return inputURLs }
            try applyQCSummaryReport(from: reportURL, to: inputURLs)
            return inputURLs.map(selectableSourceURL(for:))

        case .derivative(let derivativeRequest, _, _) where derivativeRequest.isDemultiplexRequest:
            return [outputDirectory]

        case .derivative:
            return try importFASTQOutputs(outputURLs, originalRequest: originalRequest)

        default:
            return outputURLs
        }
    }

    private func importFASTQOutputs(
        _ outputURLs: [URL],
        originalRequest: FASTQOperationLaunchRequest
    ) throws -> [URL] {
        guard !outputURLs.isEmpty else { return [] }

        var importedBundleURLs: [URL] = []
        for (index, outputURL) in outputURLs.enumerated() {
            guard FASTQBundle.isFASTQFileURL(outputURL) else {
                importedBundleURLs.append(outputURL)
                continue
            }

            let bundleBaseName = bundleNameStem(
                for: originalRequest,
                outputURL: outputURL,
                index: index
            )
            let bundleURL = uniqueBundleURL(named: bundleBaseName)
            try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

            let bundledFASTQURL = bundleURL.appendingPathComponent(outputURL.lastPathComponent)
            try FileManager.default.moveItem(at: outputURL, to: bundledFASTQURL)
            importedBundleURLs.append(bundleURL)
        }

        return importedBundleURLs
    }

    private func bundleNameStem(
        for request: FASTQOperationLaunchRequest,
        outputURL: URL,
        index: Int
    ) -> String {
        let inputStem = request.inputURLs[safe: index]
            .map(FASTQOperationExecutionService.sanitizedStem(for:))
            ?? FASTQOperationExecutionService.sanitizedStem(for: outputURL)
        let operationStem = request.outputNameStem
        return "\(inputStem)-\(operationStem)"
    }

    private func uniqueBundleURL(named baseName: String) -> URL {
        let ext = FASTQBundle.directoryExtension
        let initialURL = destinationDirectory.appendingPathComponent("\(baseName).\(ext)", isDirectory: true)
        guard !FileManager.default.fileExists(atPath: initialURL.path) else {
            var counter = 2
            var candidate = destinationDirectory.appendingPathComponent("\(baseName)-\(counter).\(ext)", isDirectory: true)
            while FileManager.default.fileExists(atPath: candidate.path) {
                counter += 1
                candidate = destinationDirectory.appendingPathComponent("\(baseName)-\(counter).\(ext)", isDirectory: true)
            }
            return candidate
        }

        return initialURL
    }

    private func applyQCSummaryReport(from reportURL: URL, to inputURLs: [URL]) throws {
        let data = try Data(contentsOf: reportURL)
        let report = try JSONDecoder().decode(FASTQQCSummaryReport.self, from: data)

        for (entry, inputURL) in zip(report.inputs, inputURLs) {
            if FASTQBundle.isDerivedBundle(inputURL),
               let manifest = FASTQBundle.loadDerivedManifest(in: inputURL) {
                let updatedManifest = FASTQDerivedBundleManifest(
                    id: manifest.id,
                    name: manifest.name,
                    createdAt: manifest.createdAt,
                    parentBundleRelativePath: manifest.parentBundleRelativePath,
                    rootBundleRelativePath: manifest.rootBundleRelativePath,
                    rootFASTQFilename: manifest.rootFASTQFilename,
                    payload: manifest.payload,
                    lineage: manifest.lineage,
                    operation: manifest.operation,
                    cachedStatistics: entry.statistics,
                    pairingMode: manifest.pairingMode,
                    readClassification: manifest.readClassification,
                    batchOperationID: manifest.batchOperationID,
                    sequenceFormat: manifest.sequenceFormat,
                    provenance: manifest.provenance,
                    payloadChecksums: manifest.payloadChecksums
                )
                try FASTQBundle.saveDerivedManifest(updatedManifest, in: inputURL)
                continue
            }

            guard let fastqURL = writableFASTQURL(for: inputURL) else { continue }
            var metadata = FASTQMetadataStore.load(for: fastqURL) ?? PersistedFASTQMetadata()
            metadata.computedStatistics = entry.statistics
            FASTQMetadataStore.save(metadata, for: fastqURL)
        }
    }

    private func writableFASTQURL(for inputURL: URL) -> URL? {
        if FASTQBundle.isFASTQFileURL(inputURL) {
            return inputURL
        }
        if FASTQBundle.isBundleURL(inputURL) {
            return FASTQBundle.resolvePrimaryFASTQURL(for: inputURL)
        }
        let parentBundleURL = inputURL.deletingLastPathComponent()
        if FASTQBundle.isBundleURL(parentBundleURL) {
            return FASTQBundle.resolvePrimaryFASTQURL(for: parentBundleURL)
        }
        return nil
    }

    private func selectableSourceURL(for inputURL: URL) -> URL {
        if FASTQBundle.isBundleURL(inputURL) {
            return inputURL
        }
        let parentBundleURL = inputURL.deletingLastPathComponent()
        if FASTQBundle.isBundleURL(parentBundleURL) {
            return parentBundleURL
        }
        return inputURL
    }
}

private struct FASTQQCSummaryReport: Decodable {
    let inputs: [Entry]

    struct Entry: Decodable {
        let input: String
        let statistics: FASTQDatasetStatistics
    }
}

private extension FASTQOperationLaunchRequest {
    var inputURLs: [URL] {
        switch self {
        case .refreshQCSummary(let inputURLs):
            return inputURLs
        case .derivative(_, let inputURLs, _):
            return inputURLs
        case .map(let inputURLs, _, _):
            return inputURLs
        case .assemble(let request, _):
            return request.inputURLs
        case .classify(_, let inputURLs, _):
            return inputURLs
        }
    }

    var primaryInputURL: URL? {
        inputURLs.first
    }

    var outputMode: FASTQOperationOutputMode {
        switch self {
        case .refreshQCSummary:
            return .fixedBatch
        case .derivative(_, _, let outputMode):
            return outputMode
        case .map(_, _, let outputMode):
            return outputMode
        case .assemble(_, let outputMode):
            return outputMode
        case .classify:
            return .fixedBatch
        }
    }

    func replacingInputURLs(with inputURLs: [URL]) -> FASTQOperationLaunchRequest {
        switch self {
        case .refreshQCSummary:
            return .refreshQCSummary(inputURLs: inputURLs)
        case .derivative(let request, _, let outputMode):
            return .derivative(request: request, inputURLs: inputURLs, outputMode: outputMode)
        case .map(_, let referenceURL, let outputMode):
            return .map(inputURLs: inputURLs, referenceURL: referenceURL, outputMode: outputMode)
        case .assemble(let request, let outputMode):
            return .assemble(request: request.replacingInputURLs(with: inputURLs), outputMode: outputMode)
        case .classify(let tool, _, let databaseName):
            return .classify(tool: tool, inputURLs: inputURLs, databaseName: databaseName)
        }
    }

    var batchManifestLabel: String {
        switch self {
        case .refreshQCSummary:
            return "FASTQ QC Summary"
        case .derivative(let request, _, _):
            return request.batchLabel
        case .map:
            return "Map Reads"
        case .assemble(let request, _):
            return request.tool.displayName
        case .classify(let tool, _, _):
            return tool.title
        }
    }

    var batchManifestOperationKind: String {
        switch self {
        case .refreshQCSummary:
            return "qcSummary"
        case .derivative(let request, _, _):
            return request.operationKindString
        case .map:
            return "mapping"
        case .assemble:
            return "assembly"
        case .classify:
            return "classification"
        }
    }

    var batchManifestParameters: [String: String] {
        switch self {
        case .refreshQCSummary:
            return [:]
        case .derivative(let request, _, _):
            return request.batchParameters
        case .map(_, let referenceURL, _):
            return ["reference": referenceURL.lastPathComponent]
        case .assemble(let request, _):
            return [
                "assembler": request.tool.rawValue,
                "readType": request.readType.rawValue,
            ]
        case .classify(_, _, let databaseName):
            return ["database": databaseName]
        }
    }

    var isDemultiplexRequest: Bool {
        if case .derivative(let request, _, _) = self {
            return request.isDemultiplexRequest
        }
        return false
    }

    var outputNameStem: String {
        switch self {
        case .refreshQCSummary:
            return "qc-summary"
        case .derivative(let request, _, _):
            return request.operationKindString
        case .map:
            return "mapping"
        case .assemble(let request, _):
            return "assembly-\(request.tool.rawValue)"
        case .classify(let tool, _, _):
            return tool.title.lowercased()
        }
    }

    var requiresSingleResolvedFASTQPerInput: Bool {
        switch self {
        case .refreshQCSummary, .derivative:
            return true
        case .map, .assemble, .classify:
            return false
        }
    }
}

private extension AssemblyRunRequest {
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

private extension FASTQDerivativeRequest {
    var isDemultiplexRequest: Bool {
        if case .demultiplex = self {
            return true
        }
        return false
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
