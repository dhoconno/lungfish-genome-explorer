import Foundation
import LungfishIO

public struct ManagedMSACommand: Sendable, Equatable {
    public let executable: String
    public let arguments: [String]
    public let environment: String
    public let workingDirectory: URL
    public let stdoutURL: URL

    public init(
        executable: String,
        arguments: [String],
        environment: String,
        workingDirectory: URL,
        stdoutURL: URL
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.stdoutURL = stdoutURL
    }

    public var shellCommand: String {
        ([executable] + arguments).map(msaShellEscape).joined(separator: " ")
            + " > "
            + msaShellEscape(stdoutURL.path)
    }
}

public struct MSAToolRunResult: Sendable, Equatable {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32
    public let executablePath: String?
    public let version: String?

    public init(
        stdout: String,
        stderr: String,
        exitCode: Int32,
        executablePath: String?,
        version: String?
    ) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
        self.executablePath = executablePath
        self.version = version
    }
}

public protocol MSAToolRunning: Sendable {
    func runTool(
        name: String,
        arguments: [String],
        environment: String,
        workingDirectory: URL,
        environmentVariables: [String: String],
        timeout: TimeInterval,
        stderrHandler: (@Sendable (String) -> Void)?
    ) async throws -> MSAToolRunResult
}

public enum MAFFTAlignmentPipelineError: Error, LocalizedError, Sendable {
    case emptyInput
    case singleSequenceInput
    case unsupportedInput(URL)
    case malformedFASTA(String)
    case outputExists(URL)
    case executionFailed(exitCode: Int32, detail: String)

    public var errorDescription: String? {
        switch self {
        case .emptyInput:
            return "MAFFT alignment requires at least two input sequences."
        case .singleSequenceInput:
            return "MAFFT alignment requires at least two input sequences."
        case .unsupportedInput(let url):
            return "MAFFT alignment input is not a readable FASTA sequence: \(url.lastPathComponent)"
        case .malformedFASTA(let reason):
            return "Malformed FASTA input: \(reason)"
        case .outputExists(let url):
            return "Output bundle already exists: \(url.path)"
        case .executionFailed(let exitCode, let detail):
            return "MAFFT failed with exit code \(exitCode): \(detail)"
        }
    }
}

public final class MAFFTAlignmentPipeline: @unchecked Sendable {
    public typealias ProgressHandler = @Sendable (Double, String) -> Void

    private let toolRunner: any MSAToolRunning

    private struct StagedInputResult {
        let recordCount: Int
        let warnings: [String]
        let sourceRowMetadata: [MultipleSequenceAlignmentBundle.SourceRowMetadataInput]
        let sourceAnnotations: [MultipleSequenceAlignmentBundle.SourceAnnotationInput]
        let fastqQualitySummaries: [MultipleSequenceAlignmentBundle.FASTQQualitySummaryInput]
    }

    public init(toolRunner: any MSAToolRunning = CondaMSAToolRunner()) {
        self.toolRunner = toolRunner
    }

    public static func buildCommand(
        for request: MSAAlignmentRunRequest,
        stagedInputURL: URL,
        alignedOutputURL: URL
    ) throws -> ManagedMSACommand {
        var arguments = request.strategy.arguments
        arguments += request.extraArguments
        if let sequenceTypeArgument = request.sequenceType.argument {
            arguments.append(sequenceTypeArgument)
        }
        if let directionArgument = request.directionAdjustment.argument {
            arguments.append(directionArgument)
        }
        if let symbolPolicyArgument = request.symbolPolicy.argument {
            arguments.append(symbolPolicyArgument)
        }
        arguments += ["--thread", String(request.threads ?? -1)]
        if request.deterministicThreads {
            arguments += ["--threadit", "0"]
        }
        arguments.append(request.outputOrder.argument)
        arguments.append(stagedInputURL.path)

        return ManagedMSACommand(
            executable: request.tool.executableName,
            arguments: arguments,
            environment: request.tool.environmentName,
            workingDirectory: stagedInputURL.deletingLastPathComponent(),
            stdoutURL: alignedOutputURL
        )
    }

    public func run(
        request: MSAAlignmentRunRequest,
        progress: ProgressHandler? = nil
    ) async throws -> MSAAlignmentRunResult {
        let startedAt = Date()
        let fm = FileManager.default
        let outputBundleURL = request.resolvedOutputBundleURL
        if fm.fileExists(atPath: outputBundleURL.path) {
            throw MAFFTAlignmentPipelineError.outputExists(outputBundleURL)
        }

        progress?(0.02, "Preparing MAFFT workspace...")
        let tempDirectory = try ProjectTempDirectory.create(
            prefix: "mafft-",
            contextURL: request.projectURL,
            policy: .requireProjectContext
        )
        defer { try? fm.removeItem(at: tempDirectory) }

        let mafftTempDirectory = tempDirectory.appendingPathComponent("mafft-tmp", isDirectory: true)
        try fm.createDirectory(at: mafftTempDirectory, withIntermediateDirectories: true)
        let stagedInputURL = tempDirectory.appendingPathComponent("input.unaligned.fasta")
        let alignedOutputURL = tempDirectory.appendingPathComponent("primary.aligned.fasta")

        let stageResult = try await stageInputFASTA(request.inputSequenceURLs, to: stagedInputURL, request: request)
        guard stageResult.recordCount >= 2 else {
            throw MAFFTAlignmentPipelineError.singleSequenceInput
        }

        let command = try Self.buildCommand(
            for: request,
            stagedInputURL: stagedInputURL,
            alignedOutputURL: alignedOutputURL
        )

        progress?(0.12, "Running MAFFT...")
        let runStartedAt = Date()
        let toolResult = try await toolRunner.runTool(
            name: command.executable,
            arguments: command.arguments,
            environment: command.environment,
            workingDirectory: command.workingDirectory,
            environmentVariables: [
                "TMPDIR": mafftTempDirectory.path,
                "MAFFT_TMPDIR": mafftTempDirectory.path,
            ],
            timeout: 24 * 3600,
            stderrHandler: { line in
                progress?(0.50, line)
            }
        )

        try Data(toolResult.stdout.utf8).write(to: alignedOutputURL, options: .atomic)
        guard toolResult.exitCode == 0 else {
            throw MAFFTAlignmentPipelineError.executionFailed(
                exitCode: toolResult.exitCode,
                detail: failureDetail(stdout: toolResult.stdout, stderr: toolResult.stderr)
            )
        }

        progress?(0.82, "Creating native MSA bundle...")
        try fm.createDirectory(at: outputBundleURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let wrapperArgv = request.wrapperArgv.isEmpty
            ? defaultWrapperArgv(request: request, outputBundleURL: outputBundleURL)
            : request.wrapperArgv
        let finalInputURL = outputBundleURL.appendingPathComponent("alignment/input.unaligned.fasta")
        let finalAlignedOutputURL = outputBundleURL.appendingPathComponent("alignment/primary.aligned.fasta")
        let externalArgv = Self.rehydratedExternalArgv(
            command: command,
            stagedInputURL: stagedInputURL,
            finalInputURL: finalInputURL
        )
        let externalCommand = ManagedMSACommand(
            executable: command.executable,
            arguments: Array(externalArgv.dropFirst()),
            environment: command.environment,
            workingDirectory: outputBundleURL.appendingPathComponent("alignment", isDirectory: true),
            stdoutURL: finalAlignedOutputURL
        )
        let externalInvocation = MultipleSequenceAlignmentBundle.ToolInvocation(
            name: command.executable,
            version: toolResult.version,
            argv: externalArgv,
            reproducibleCommand: externalCommand.shellCommand,
            condaEnvironment: command.environment,
            executablePath: toolResult.executablePath,
            exitStatus: Int(toolResult.exitCode),
            wallTimeSeconds: max(0, Date().timeIntervalSince(runStartedAt)),
            stdout: nil,
            stderr: toolResult.stderr.isEmpty ? nil : toolResult.stderr
        )
        let inputRecords = try request.inputSequenceURLs.map {
            try MultipleSequenceAlignmentBundle.fileRecordForProvenance(at: $0)
        }
        let bundle = try MultipleSequenceAlignmentBundle.importAlignment(
            from: alignedOutputURL,
            to: outputBundleURL,
            options: .init(
                name: request.name,
                sourceFormat: .alignedFASTA,
                argv: wrapperArgv,
                reproducibleCommand: wrapperArgv.map(msaShellEscape).joined(separator: " "),
                workflowName: "multiple-sequence-alignment-mafft",
                toolName: "lungfish align mafft",
                toolVersion: MultipleSequenceAlignmentBundle.toolVersion,
                externalToolInvocations: [externalInvocation],
                inputFiles: inputRecords,
                additionalFiles: [
                    .init(
                        sourceURL: stagedInputURL,
                        relativePath: "alignment/input.unaligned.fasta"
                    ),
                ],
                analysisToolName: "mafft",
                stderr: toolResult.stderr.isEmpty ? nil : toolResult.stderr,
                wallTimeSeconds: max(0, Date().timeIntervalSince(startedAt)),
                extraWarnings: stageResult.warnings,
                sourceRowMetadata: stageResult.sourceRowMetadata,
                sourceAnnotations: stageResult.sourceAnnotations,
                fastqQualitySummaries: stageResult.fastqQualitySummaries
            )
        )

        progress?(1.0, "MAFFT alignment complete.")
        return MSAAlignmentRunResult(
            bundleURL: bundle.url,
            rowCount: bundle.manifest.rowCount,
            alignedLength: bundle.manifest.alignedLength,
            warnings: bundle.manifest.warnings,
            wallTimeSeconds: max(0, Date().timeIntervalSince(startedAt))
        )
    }

    private func stageInputFASTA(
        _ inputURLs: [URL],
        to stagedInputURL: URL,
        request: MSAAlignmentRunRequest
    ) async throws -> StagedInputResult {
        guard !inputURLs.isEmpty else {
            throw MAFFTAlignmentPipelineError.emptyInput
        }

        var output = ""
        var recordCount = 0
        var warnings: [String] = []
        var seenLabels: [String: Int] = [:]
        var sourceRowMetadata: [MultipleSequenceAlignmentBundle.SourceRowMetadataInput] = []
        var sourceAnnotations: [MultipleSequenceAlignmentBundle.SourceAnnotationInput] = []
        var fastqQualitySummaries: [MultipleSequenceAlignmentBundle.FASTQQualitySummaryInput] = []

        for inputURL in inputURLs {
            guard let fastaURL = SequenceInputResolver.resolvePrimarySequenceURL(for: inputURL),
                  let sequenceFormat = SequenceInputResolver.inputSequenceFormat(for: inputURL) ??
                    SequenceInputResolver.inputSequenceFormat(for: fastaURL) else {
                throw MAFFTAlignmentPipelineError.unsupportedInput(inputURL)
            }
            let records: [(name: String, sequence: String, quality: [UInt8]?)]
            switch sequenceFormat {
            case .fasta:
                let text = try await readFASTAText(from: fastaURL)
                records = try parseFASTA(text, sourceName: inputURL.lastPathComponent)
                    .map { ($0.name, $0.sequence, nil) }
            case .fastq:
                guard request.allowFASTQAssemblyInputs else {
                    throw MAFFTAlignmentPipelineError.unsupportedInput(inputURL)
                }
                warnings.append("FASTQ input \(inputURL.lastPathComponent) was converted to FASTA for MAFFT; quality scores are retained only as non-aligned sidecar metadata.")
                records = try await parseFASTQRecords(from: fastaURL)
            }
            let annotationsBySequence = try await sourceAnnotationsBySequence(for: inputURL, records: records)
            for record in records {
                let baseLabel = sanitizedLabel(record.name)
                let occurrence = seenLabels[baseLabel, default: 0] + 1
                seenLabels[baseLabel] = occurrence
                let finalLabel = occurrence == 1 ? baseLabel : "\(baseLabel)_\(occurrence)"
                if finalLabel != record.name {
                    warnings.append("Input row '\(record.name)' was rewritten as '\(finalLabel)' for downstream tree compatibility.")
                }
                output += ">\(finalLabel)\n\(wrapped(record.sequence))"
                recordCount += 1
                sourceRowMetadata.append(
                    .init(
                        rowName: finalLabel,
                        originalName: record.name,
                        sourceSequenceName: record.name,
                        sourceFilePath: inputURL.path,
                        sourceFormat: sequenceFormat.rawValue,
                        sourceChecksumSHA256: MultipleSequenceAlignmentBundle.sha256Hex(for: Data(record.sequence.utf8))
                    )
                )
                for annotation in annotationsBySequence[record.name, default: []] {
                    sourceAnnotations.append(annotation.withRowName(finalLabel))
                }
                if let quality = record.quality {
                    fastqQualitySummaries.append(
                        qualitySummary(
                            rowName: finalLabel,
                            recordID: record.name,
                            sourceFASTQPath: inputURL.path,
                            sequence: record.sequence,
                            quality: quality
                        )
                    )
                }
            }
        }

        try output.write(to: stagedInputURL, atomically: true, encoding: .utf8)
        return StagedInputResult(
            recordCount: recordCount,
            warnings: Array(Set(warnings)).sorted(),
            sourceRowMetadata: sourceRowMetadata,
            sourceAnnotations: sourceAnnotations,
            fastqQualitySummaries: fastqQualitySummaries
        )
    }

    private func readFASTAText(from fastaURL: URL) async throws -> String {
        if fastaURL.isGzipCompressed {
            return try await GzipInputStream(url: fastaURL).readAll()
        }
        return try String(contentsOf: fastaURL, encoding: .utf8)
    }

    private func parseFASTA(
        _ text: String,
        sourceName: String
    ) throws -> [(name: String, sequence: String)] {
        var records: [(String, String)] = []
        var currentName: String?
        var currentSequence = ""
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            if line.hasPrefix(">") {
                if let currentName {
                    records.append((currentName, currentSequence))
                }
                let name = String(line.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else {
                    throw MAFFTAlignmentPipelineError.malformedFASTA("\(sourceName) contains an empty FASTA header.")
                }
                currentName = name
                currentSequence = ""
            } else {
                guard currentName != nil else {
                    throw MAFFTAlignmentPipelineError.malformedFASTA("\(sourceName) has sequence before the first FASTA header.")
                }
                currentSequence += line.filter { !$0.isWhitespace }
            }
        }
        if let currentName {
            records.append((currentName, currentSequence))
        }
        guard !records.isEmpty else {
            throw MAFFTAlignmentPipelineError.malformedFASTA("\(sourceName) contains no FASTA records.")
        }
        if records.contains(where: { $0.1.isEmpty }) {
            throw MAFFTAlignmentPipelineError.malformedFASTA("\(sourceName) contains an empty sequence.")
        }
        return records
    }

    private func parseFASTQRecords(from fastqURL: URL) async throws -> [(name: String, sequence: String, quality: [UInt8]?)] {
        let records = try await FASTQReader().readAll(from: fastqURL)
        guard !records.isEmpty else {
            throw MAFFTAlignmentPipelineError.malformedFASTA("\(fastqURL.lastPathComponent) contains no FASTQ records.")
        }
        return records.map { record in
            (record.identifier, record.sequence, Array(record.quality))
        }
    }

    private func sourceAnnotationsBySequence(
        for inputURL: URL,
        records: [(name: String, sequence: String, quality: [UInt8]?)]
    ) async throws -> [String: [MultipleSequenceAlignmentBundle.SourceAnnotationInput]] {
        guard let bundleURL = SequenceInputResolver.enclosingReferenceBundleURL(for: inputURL) else {
            return [:]
        }
        let bundle: ReferenceBundle
        do {
            bundle = try await ReferenceBundle(url: bundleURL)
        } catch {
            return [:]
        }

        var result: [String: [MultipleSequenceAlignmentBundle.SourceAnnotationInput]] = [:]
        for record in records {
            for track in bundle.manifest.annotations {
                let region = GenomicRegion(chromosome: record.name, start: 0, end: record.sequence.count)
                let annotations = (try? await bundle.getAnnotations(trackId: track.id, region: region)) ?? []
                for annotation in annotations {
                    result[record.name, default: []].append(
                        MultipleSequenceAlignmentBundle.SourceAnnotationInput(
                            rowName: record.name,
                            sourceSequenceName: record.name,
                            sourceFilePath: bundleURL.path,
                            sourceTrackID: track.id,
                            sourceTrackName: track.name,
                            sourceAnnotationID: annotation.qualifier("ID") ?? annotation.id.uuidString,
                            name: annotation.name,
                            type: annotation.type.rawValue,
                            strand: annotation.strand.rawValue,
                            intervals: annotation.intervals,
                            qualifiers: annotation.qualifiers.mapValues(\.values),
                            note: annotation.note
                        )
                    )
                }
            }
        }
        return result
    }

    private func qualitySummary(
        rowName: String,
        recordID: String,
        sourceFASTQPath: String,
        sequence: String,
        quality: [UInt8]
    ) -> MultipleSequenceAlignmentBundle.FASTQQualitySummaryInput {
        let minimum = quality.min().map(Int.init) ?? 0
        let maximum = quality.max().map(Int.init) ?? 0
        let mean = quality.isEmpty
            ? 0
            : Double(quality.reduce(0) { $0 + Int($1) }) / Double(quality.count)
        return MultipleSequenceAlignmentBundle.FASTQQualitySummaryInput(
            rowName: rowName,
            recordID: recordID,
            sourceFASTQPath: sourceFASTQPath,
            sequenceChecksumSHA256: MultipleSequenceAlignmentBundle.sha256Hex(for: Data(sequence.utf8)),
            minimumQuality: minimum,
            meanQuality: mean,
            maximumQuality: maximum
        )
    }

    private func sanitizedLabel(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let replaced = trimmed.replacingOccurrences(
            of: "[^A-Za-z0-9._-]+",
            with: "_",
            options: .regularExpression
        )
        let cleaned = replaced.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return cleaned.isEmpty ? "sequence" : cleaned
    }

    private func wrapped(_ sequence: String) -> String {
        var result = ""
        var index = sequence.startIndex
        while index < sequence.endIndex {
            let end = sequence.index(index, offsetBy: 80, limitedBy: sequence.endIndex) ?? sequence.endIndex
            result += String(sequence[index..<end]) + "\n"
            index = end
        }
        return result
    }

    private func failureDetail(stdout: String, stderr: String) -> String {
        let detail = [stderr, stdout]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return detail.isEmpty ? "No diagnostic output." : detail
    }

    private func defaultWrapperArgv(
        request: MSAAlignmentRunRequest,
        outputBundleURL: URL
    ) -> [String] {
        var argv = [
            "lungfish", "align", "mafft",
        ] + request.inputSequenceURLs.map(\.path) + [
            "--project", request.projectURL.path,
            "--output", outputBundleURL.path,
            "--name", request.name,
            "--strategy", request.strategy.rawValue,
            "--output-order", request.outputOrder.rawValue,
        ]
        if let threads = request.threads {
            argv += ["--threads", "\(threads)"]
        }
        if request.sequenceType != .auto {
            argv += ["--sequence-type", request.sequenceType.rawValue]
        }
        if request.directionAdjustment != .off {
            argv += ["--adjust-direction", request.directionAdjustment.rawValue]
        }
        if request.symbolPolicy != .strict {
            argv += ["--symbols", request.symbolPolicy.rawValue]
        }
        if !request.deterministicThreads {
            argv += ["--allow-nondeterministic-threads"]
        }
        if !request.extraArguments.isEmpty {
            argv += ["--extra-mafft-options", AdvancedCommandLineOptions.join(request.extraArguments)]
        }
        if request.allowFASTQAssemblyInputs {
            argv += ["--allow-fastq-assembly-inputs"]
        }
        return argv
    }

    private static func rehydratedExternalArgv(
        command: ManagedMSACommand,
        stagedInputURL: URL,
        finalInputURL: URL
    ) -> [String] {
        [command.executable] + command.arguments.map { argument in
            argument == stagedInputURL.path ? finalInputURL.path : argument
        }
    }
}

private extension MultipleSequenceAlignmentBundle.SourceAnnotationInput {
    func withRowName(_ rowName: String) -> MultipleSequenceAlignmentBundle.SourceAnnotationInput {
        MultipleSequenceAlignmentBundle.SourceAnnotationInput(
            rowName: rowName,
            sourceSequenceName: sourceSequenceName,
            sourceFilePath: sourceFilePath,
            sourceTrackID: sourceTrackID,
            sourceTrackName: sourceTrackName,
            sourceAnnotationID: sourceAnnotationID,
            name: name,
            type: type,
            strand: strand,
            intervals: intervals,
            qualifiers: qualifiers,
            note: note
        )
    }
}

public struct CondaMSAToolRunner: MSAToolRunning {
    private let condaManager: CondaManager

    public init(condaManager: CondaManager = .shared) {
        self.condaManager = condaManager
    }

    public func runTool(
        name: String,
        arguments: [String],
        environment: String,
        workingDirectory: URL,
        environmentVariables: [String: String],
        timeout: TimeInterval,
        stderrHandler: (@Sendable (String) -> Void)?
    ) async throws -> MSAToolRunResult {
        let result = try await condaManager.runTool(
            name: name,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory,
            environmentVariables: environmentVariables,
            timeout: timeout,
            stderrHandler: stderrHandler
        )
        let version = await detectToolVersion(
            toolName: name,
            environment: environment,
            condaManager: condaManager,
            flags: ["--version"],
            timeout: 10
        )
        let executablePath = await condaManager.environmentURL(named: environment)
            .appendingPathComponent("bin/\(name)")
            .path
        return MSAToolRunResult(
            stdout: result.stdout,
            stderr: result.stderr,
            exitCode: result.exitCode,
            executablePath: executablePath,
            version: version == "unknown" ? nil : version
        )
    }
}

private func msaShellEscape(_ value: String) -> String {
    guard !value.isEmpty else { return "''" }
    if value.allSatisfy({ $0.isLetter || $0.isNumber || "-_./:=".contains($0) }) {
        return value
    }
    return "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
}
