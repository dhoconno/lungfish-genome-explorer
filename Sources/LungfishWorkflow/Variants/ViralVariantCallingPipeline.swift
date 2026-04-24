import Foundation
import LungfishCore
import LungfishIO

public struct ViralVariantCallingExecutionPlan: Sendable, Equatable {
    public let caller: ViralVariantCaller
    public let workingDirectory: URL
    public let alignmentURL: URL
    public let alignmentIndexURL: URL
    public let referenceURL: URL
    public let referenceIndexURL: URL
    public let medakaFASTQURL: URL?
    public let rawVCFURL: URL
    public let normalizedVCFURL: URL
    public let stagedVCFGZURL: URL
    public let stagedTabixURL: URL
    public let commandLine: String

    public init(
        caller: ViralVariantCaller,
        workingDirectory: URL,
        alignmentURL: URL,
        alignmentIndexURL: URL,
        referenceURL: URL,
        referenceIndexURL: URL,
        medakaFASTQURL: URL?,
        rawVCFURL: URL,
        normalizedVCFURL: URL,
        stagedVCFGZURL: URL,
        stagedTabixURL: URL,
        commandLine: String
    ) {
        self.caller = caller
        self.workingDirectory = workingDirectory
        self.alignmentURL = alignmentURL
        self.alignmentIndexURL = alignmentIndexURL
        self.referenceURL = referenceURL
        self.referenceIndexURL = referenceIndexURL
        self.medakaFASTQURL = medakaFASTQURL
        self.rawVCFURL = rawVCFURL
        self.normalizedVCFURL = normalizedVCFURL
        self.stagedVCFGZURL = stagedVCFGZURL
        self.stagedTabixURL = stagedTabixURL
        self.commandLine = commandLine
    }
}

public struct ViralVariantCallingPipelineResult: Sendable, Equatable {
    public let normalizedVCFURL: URL
    public let stagedVCFGZURL: URL
    public let stagedTabixURL: URL
    public let referenceFASTAURL: URL
    public let referenceFASTASHA256: String
    public let callerVersion: String
    public let callerParametersJSON: String
    public let commandLine: String

    public init(
        normalizedVCFURL: URL,
        stagedVCFGZURL: URL,
        stagedTabixURL: URL,
        referenceFASTAURL: URL,
        referenceFASTASHA256: String,
        callerVersion: String,
        callerParametersJSON: String,
        commandLine: String = ""
    ) {
        self.normalizedVCFURL = normalizedVCFURL
        self.stagedVCFGZURL = stagedVCFGZURL
        self.stagedTabixURL = stagedTabixURL
        self.referenceFASTAURL = referenceFASTAURL
        self.referenceFASTASHA256 = referenceFASTASHA256
        self.callerVersion = callerVersion
        self.callerParametersJSON = callerParametersJSON
        self.commandLine = commandLine
    }
}

public enum ViralVariantCallingPipelineError: Error, LocalizedError, Equatable {
    case medakaRequiresModelMetadata
    case workspaceSetupFailed(String)
    case referenceStagingFailed(String)
    case alignmentStagingFailed(String)
    case fastqReconstructionFailed(String)
    case callerExecutionFailed(String)
    case missingCallerOutput(String)
    case normalizationFailed(String)
    case compressionFailed(String)
    case indexingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .medakaRequiresModelMetadata:
            return "Medaka requires ONT model metadata before the run can start."
        case .workspaceSetupFailed(let detail):
            return "Failed to prepare the variant-calling workspace: \(detail)"
        case .referenceStagingFailed(let detail):
            return "Failed to stage the reference FASTA: \(detail)"
        case .alignmentStagingFailed(let detail):
            return "Failed to stage the alignment inputs: \(detail)"
        case .fastqReconstructionFailed(let detail):
            return "Failed to reconstruct FASTQ input for Medaka: \(detail)"
        case .callerExecutionFailed(let detail):
            return "Variant caller execution failed: \(detail)"
        case .missingCallerOutput(let path):
            return "Variant caller did not produce the expected VCF output: \(path)"
        case .normalizationFailed(let detail):
            return "Failed to normalize the caller VCF output: \(detail)"
        case .compressionFailed(let detail):
            return "Failed to bgzip-compress the normalized VCF: \(detail)"
        case .indexingFailed(let detail):
            return "Failed to create the tabix index: \(detail)"
        }
    }
}

public struct ViralVariantCallingPipeline: Sendable {
    private struct CallerParametersPayload: Encodable {
        let caller: String
        let threads: Int
        let minimumAlleleFrequency: Double?
        let minimumDepth: Int?
        let ivarPrimerTrimConfirmed: Bool
        let medakaModel: String?
        let advancedOptions: String
        let advancedArguments: [String]
    }

    public typealias ProgressHandler = @Sendable (Double, String) -> Void
    public typealias BAMToFASTQConverter = @Sendable (
        URL,
        URL,
        URL,
        String,
        Int,
        TimeInterval,
        NativeToolRunner,
        Bool
    ) async throws -> Void
    public typealias CallerExecutor = @Sendable (ViralVariantCallingExecutionPlan, NativeToolRunner) async throws -> Void

    private let request: BundleVariantCallingRequest
    private let preflight: BAMVariantCallingPreflightResult
    private let stagingRoot: URL
    private let toolRunner: NativeToolRunner
    private let bamToFASTQConverter: BAMToFASTQConverter
    private let callerExecutor: CallerExecutor?

    public init(
        request: BundleVariantCallingRequest,
        preflight: BAMVariantCallingPreflightResult,
        stagingRoot: URL,
        toolRunner: NativeToolRunner = .shared,
        bamToFASTQConverter: @escaping BAMToFASTQConverter = convertBAMToSingleFASTQ,
        callerExecutor: CallerExecutor? = nil
    ) {
        self.request = request
        self.preflight = preflight
        self.stagingRoot = stagingRoot
        self.toolRunner = toolRunner
        self.bamToFASTQConverter = bamToFASTQConverter
        self.callerExecutor = callerExecutor
    }

    public func buildExecutionPlan() throws -> ViralVariantCallingExecutionPlan {
        let workspaceURL = stagingRoot.appendingPathComponent("workspace", isDirectory: true)
        let inputsURL = workspaceURL.appendingPathComponent("inputs", isDirectory: true)
        let outputsURL = workspaceURL.appendingPathComponent("outputs", isDirectory: true)
        let referenceURL = inputsURL.appendingPathComponent("reference.fa")
        let alignmentURL = inputsURL.appendingPathComponent(preflight.alignmentURL.lastPathComponent)
        let alignmentIndexURL = inputsURL.appendingPathComponent(preflight.alignmentIndexURL.lastPathComponent)
        let medakaFASTQURL = request.caller == .medaka
            ? inputsURL.appendingPathComponent("medaka.fastq")
            : nil
        let rawVCFURL = outputsURL.appendingPathComponent(rawVCFFileName())
        let normalizedVCFURL = outputsURL.appendingPathComponent("variants.normalized.vcf")
        let stagedVCFGZURL = outputsURL.appendingPathComponent("variants.vcf.gz")
        let stagedTabixURL = outputsURL.appendingPathComponent("variants.vcf.gz.tbi")

        return ViralVariantCallingExecutionPlan(
            caller: request.caller,
            workingDirectory: workspaceURL,
            alignmentURL: alignmentURL,
            alignmentIndexURL: alignmentIndexURL,
            referenceURL: referenceURL,
            referenceIndexURL: referenceURL.appendingPathExtension("fai"),
            medakaFASTQURL: medakaFASTQURL,
            rawVCFURL: rawVCFURL,
            normalizedVCFURL: normalizedVCFURL,
            stagedVCFGZURL: stagedVCFGZURL,
            stagedTabixURL: stagedTabixURL,
            commandLine: commandLine(
                caller: request.caller,
                referenceURL: referenceURL,
                alignmentURL: alignmentURL,
                medakaFASTQURL: medakaFASTQURL,
                rawVCFURL: rawVCFURL
            )
        )
    }

    public func run(progress: ProgressHandler? = nil) async throws -> ViralVariantCallingPipelineResult {
        if request.caller == .medaka,
           request.medakaModel?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            throw ViralVariantCallingPipelineError.medakaRequiresModelMetadata
        }

        let plan = try buildExecutionPlan()
        do {
            try FileManager.default.createDirectory(at: plan.workingDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: plan.referenceURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: plan.rawVCFURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            throw ViralVariantCallingPipelineError.workspaceSetupFailed(error.localizedDescription)
        }

        progress?(0.08, "Staging reference and alignment inputs")
        try await stageAlignmentArtifacts(plan: plan)
        try await stageReference(plan: plan)

        if request.caller == .medaka, let fastqURL = plan.medakaFASTQURL {
            progress?(0.20, "Reconstructing FASTQ input for Medaka")
            do {
                try await bamToFASTQConverter(
                    plan.alignmentURL,
                    fastqURL,
                    plan.referenceURL.deletingLastPathComponent(),
                    "medaka",
                    0x900,
                    600,
                    toolRunner,
                    false
                )
            } catch let error as BAMToFASTQConversionError {
                switch error {
                case .samtoolsFailed(let stderr):
                    throw ViralVariantCallingPipelineError.fastqReconstructionFailed(stderr)
                case .emptySidecarOutputs:
                    throw ViralVariantCallingPipelineError.fastqReconstructionFailed(
                        "samtools fastq produced no sidecar output and stdout fallback is disabled for Medaka."
                    )
                }
            } catch {
                throw ViralVariantCallingPipelineError.fastqReconstructionFailed(error.localizedDescription)
            }
        }

        progress?(0.45, "Running \(request.caller.displayName)")
        if let callerExecutor {
            try await callerExecutor(plan, toolRunner)
        } else {
            try await runCaller(plan: plan)
        }

        guard FileManager.default.fileExists(atPath: plan.rawVCFURL.path) else {
            throw ViralVariantCallingPipelineError.missingCallerOutput(plan.rawVCFURL.path)
        }

        progress?(0.70, "Sorting VCF")
        let sortResult = try await toolRunner.run(
            .bcftools,
            arguments: [
                "sort",
                "-O", "v",
                "-o", plan.normalizedVCFURL.path,
                plan.rawVCFURL.path,
            ],
            workingDirectory: plan.workingDirectory,
            timeout: 600
        )
        guard sortResult.isSuccess else {
            throw ViralVariantCallingPipelineError.normalizationFailed(sortResult.combinedOutput)
        }

        progress?(0.82, "Compressing normalized VCF")
        let bgzipResult = try await toolRunner.bgzipCompress(
            inputPath: plan.normalizedVCFURL,
            keepOriginal: true,
            threads: request.threads
        )
        guard bgzipResult.isSuccess else {
            throw ViralVariantCallingPipelineError.compressionFailed(bgzipResult.combinedOutput)
        }

        let compressedNormalizedURL = plan.normalizedVCFURL.appendingPathExtension("gz")
        do {
            if FileManager.default.fileExists(atPath: plan.stagedVCFGZURL.path) {
                try FileManager.default.removeItem(at: plan.stagedVCFGZURL)
            }
            try FileManager.default.moveItem(at: compressedNormalizedURL, to: plan.stagedVCFGZURL)
        } catch {
            throw ViralVariantCallingPipelineError.compressionFailed(error.localizedDescription)
        }

        progress?(0.92, "Indexing compressed VCF")
        let tabixResult = try await toolRunner.run(
            .tabix,
            arguments: ["-f", "-p", "vcf", plan.stagedVCFGZURL.path],
            workingDirectory: plan.workingDirectory,
            timeout: 600
        )
        guard tabixResult.isSuccess else {
            throw ViralVariantCallingPipelineError.indexingFailed(tabixResult.combinedOutput)
        }

        guard let referenceFASTASHA256 = ProvenanceRecorder.sha256(of: plan.referenceURL) else {
            throw ViralVariantCallingPipelineError.referenceStagingFailed("Failed to compute staged FASTA checksum.")
        }

        let callerVersion = await toolRunner.getToolVersion(nativeTool(for: request.caller)) ?? "unknown"
        return ViralVariantCallingPipelineResult(
            normalizedVCFURL: plan.normalizedVCFURL,
            stagedVCFGZURL: plan.stagedVCFGZURL,
            stagedTabixURL: plan.stagedTabixURL,
            referenceFASTAURL: plan.referenceURL,
            referenceFASTASHA256: referenceFASTASHA256,
            callerVersion: callerVersion,
            callerParametersJSON: callerParametersJSON(),
            commandLine: plan.commandLine
        )
    }

    private func stageAlignmentArtifacts(plan: ViralVariantCallingExecutionPlan) async throws {
        do {
            if preflight.contigValidation == .matchedByAlias {
                try await rewriteAlignmentHeader(plan: plan)
            } else {
                try stageInputArtifact(from: preflight.alignmentURL, to: plan.alignmentURL)
                try stageInputArtifact(from: preflight.alignmentIndexURL, to: plan.alignmentIndexURL)
            }
        } catch {
            throw ViralVariantCallingPipelineError.alignmentStagingFailed(error.localizedDescription)
        }
    }

    private func stageReference(plan: ViralVariantCallingExecutionPlan) async throws {
        do {
            if FileManager.default.fileExists(atPath: plan.referenceURL.path) {
                try FileManager.default.removeItem(at: plan.referenceURL)
            }

            if preflight.referenceFASTAURL.pathExtension.lowercased() == "gz" {
                let contents = try await GzipInputStream(url: preflight.referenceFASTAURL).readAll()
                try contents.write(to: plan.referenceURL, atomically: true, encoding: .utf8)
            } else {
                try FileManager.default.copyItem(at: preflight.referenceFASTAURL, to: plan.referenceURL)
            }

            let faiResult = try await toolRunner.indexFASTA(fastaPath: plan.referenceURL)
            guard faiResult.isSuccess else {
                throw ViralVariantCallingPipelineError.referenceStagingFailed(faiResult.combinedOutput)
            }
        } catch let error as ViralVariantCallingPipelineError {
            throw error
        } catch {
            throw ViralVariantCallingPipelineError.referenceStagingFailed(error.localizedDescription)
        }
    }

    private func runCaller(plan: ViralVariantCallingExecutionPlan) async throws {
        switch request.caller {
        case .lofreq:
            let result = try await toolRunner.run(
                .lofreq,
                arguments: lofreqArguments(plan: plan),
                workingDirectory: plan.workingDirectory,
                timeout: 3600
            )
            guard result.isSuccess else {
                throw ViralVariantCallingPipelineError.callerExecutionFailed(result.combinedOutput)
            }
        case .ivar:
            let result = try await toolRunner.runPipeline(
                [
                    NativePipelineStage(.samtools, arguments: ivarMpileupArguments(plan: plan)),
                    NativePipelineStage(.ivar, arguments: ivarVariantArguments(plan: plan)),
                ],
                workingDirectory: plan.workingDirectory,
                timeout: 3600
            )
            guard result.isSuccess else {
                throw ViralVariantCallingPipelineError.callerExecutionFailed(result.combinedStderr)
            }
        case .medaka:
            let result = try await toolRunner.run(
                .medaka,
                arguments: medakaArguments(plan: plan),
                workingDirectory: plan.workingDirectory,
                timeout: 3600
            )
            guard result.isSuccess else {
                throw ViralVariantCallingPipelineError.callerExecutionFailed(result.combinedOutput)
            }
        }
    }

    private func stageInputArtifact(from sourceURL: URL, to stagedURL: URL) throws {
        if FileManager.default.fileExists(atPath: stagedURL.path) {
            try FileManager.default.removeItem(at: stagedURL)
        }
        try FileManager.default.createSymbolicLink(at: stagedURL, withDestinationURL: sourceURL)
    }

    private func rewriteAlignmentHeader(plan: ViralVariantCallingExecutionPlan) async throws {
        let headerResult = try await toolRunner.run(
            .samtools,
            arguments: ["view", "-H", preflight.alignmentURL.path],
            timeout: 120
        )
        guard headerResult.isSuccess else {
            throw ViralVariantCallingPipelineError.alignmentStagingFailed(headerResult.combinedOutput)
        }

        let rewrittenHeader = remapAlignmentHeader(headerResult.stdout)
        let headerURL = plan.workingDirectory.appendingPathComponent("rewritten-header.sam")
        try rewrittenHeader.write(to: headerURL, atomically: true, encoding: .utf8)

        let reheaderResult = try await toolRunner.runWithFileOutput(
            .samtools,
            arguments: ["reheader", headerURL.path, preflight.alignmentURL.path],
            outputFile: plan.alignmentURL,
            workingDirectory: plan.workingDirectory,
            timeout: 600
        )
        guard reheaderResult.isSuccess else {
            throw ViralVariantCallingPipelineError.alignmentStagingFailed(reheaderResult.combinedOutput)
        }

        let indexResult = try await toolRunner.run(
            .samtools,
            arguments: ["index", plan.alignmentURL.path],
            workingDirectory: plan.workingDirectory,
            timeout: 600
        )
        guard indexResult.isSuccess else {
            throw ViralVariantCallingPipelineError.alignmentStagingFailed(indexResult.combinedOutput)
        }
    }

    private func remapAlignmentHeader(_ headerText: String) -> String {
        let lines = headerText.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            guard line.hasPrefix("@SQ") else {
                return String(line)
            }

            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            let rewrittenFields = fields.map { field -> String in
                guard field.hasPrefix("SN:") else {
                    return field
                }
                let originalName = String(field.dropFirst(3))
                let remappedName = preflight.referenceNameMap[originalName] ?? originalName
                return "SN:\(remappedName)"
            }
            return rewrittenFields.joined(separator: "\t")
        }
        return lines.joined(separator: "\n")
    }

    private func rawVCFFileName() -> String {
        switch request.caller {
        case .lofreq:
            return "lofreq.raw.vcf"
        case .ivar:
            return "ivar.raw.vcf"
        case .medaka:
            return "medaka.raw.vcf"
        }
    }

    private func commandLine(
        caller: ViralVariantCaller,
        referenceURL: URL,
        alignmentURL: URL,
        medakaFASTQURL: URL?,
        rawVCFURL: URL
    ) -> String {
        switch caller {
        case .lofreq:
            return ([nativeTool(for: caller).executableName] + lofreqArguments(
                plan: ViralVariantCallingExecutionPlan(
                    caller: caller,
                    workingDirectory: stagingRoot,
                    alignmentURL: alignmentURL,
                    alignmentIndexURL: alignmentURL.appendingPathExtension("bai"),
                    referenceURL: referenceURL,
                    referenceIndexURL: referenceURL.appendingPathExtension("fai"),
                    medakaFASTQURL: medakaFASTQURL,
                    rawVCFURL: rawVCFURL,
                    normalizedVCFURL: rawVCFURL.deletingLastPathComponent().appendingPathComponent("variants.normalized.vcf"),
                    stagedVCFGZURL: rawVCFURL.deletingLastPathComponent().appendingPathComponent("variants.vcf.gz"),
                    stagedTabixURL: rawVCFURL.deletingLastPathComponent().appendingPathComponent("variants.vcf.gz.tbi"),
                    commandLine: ""
                )
            )).map(shellEscape).joined(separator: " ")
        case .ivar:
            return """
            samtools \(ivarMpileupArguments(plan: placeholderPlan(referenceURL: referenceURL, alignmentURL: alignmentURL, medakaFASTQURL: medakaFASTQURL, rawVCFURL: rawVCFURL)).map(shellEscape).joined(separator: " ")) | ivar \(ivarVariantArguments(plan: placeholderPlan(referenceURL: referenceURL, alignmentURL: alignmentURL, medakaFASTQURL: medakaFASTQURL, rawVCFURL: rawVCFURL)).map(shellEscape).joined(separator: " "))
            """
        case .medaka:
            return ([nativeTool(for: caller).executableName] + medakaArguments(
                plan: placeholderPlan(referenceURL: referenceURL, alignmentURL: alignmentURL, medakaFASTQURL: medakaFASTQURL, rawVCFURL: rawVCFURL)
            )).map(shellEscape).joined(separator: " ")
        }
    }

    private func placeholderPlan(
        referenceURL: URL,
        alignmentURL: URL,
        medakaFASTQURL: URL?,
        rawVCFURL: URL
    ) -> ViralVariantCallingExecutionPlan {
        ViralVariantCallingExecutionPlan(
            caller: request.caller,
            workingDirectory: stagingRoot,
            alignmentURL: alignmentURL,
            alignmentIndexURL: alignmentURL.appendingPathExtension("bai"),
            referenceURL: referenceURL,
            referenceIndexURL: referenceURL.appendingPathExtension("fai"),
            medakaFASTQURL: medakaFASTQURL,
            rawVCFURL: rawVCFURL,
            normalizedVCFURL: rawVCFURL.deletingLastPathComponent().appendingPathComponent("variants.normalized.vcf"),
            stagedVCFGZURL: rawVCFURL.deletingLastPathComponent().appendingPathComponent("variants.vcf.gz"),
            stagedTabixURL: rawVCFURL.deletingLastPathComponent().appendingPathComponent("variants.vcf.gz.tbi"),
            commandLine: ""
        )
    }

    private func lofreqArguments(plan: ViralVariantCallingExecutionPlan) -> [String] {
        return ["call-parallel"]
            + request.advancedArguments
            + [
            "--pp-threads", String(max(1, request.threads)),
            "-f", plan.referenceURL.path,
            "-o", plan.rawVCFURL.path,
            plan.alignmentURL.path,
        ]
    }

    private func ivarMpileupArguments(plan: ViralVariantCallingExecutionPlan) -> [String] {
        [
            "mpileup",
            "-aa",
            "-A",
            "-d", "600000",
            "-B",
            "-Q", "20",
            "-q", "0",
            "-f", plan.referenceURL.path,
            plan.alignmentURL.path,
        ]
    }

    private func ivarVariantArguments(plan: ViralVariantCallingExecutionPlan) -> [String] {
        let prefix = plan.rawVCFURL.deletingPathExtension().path
        return ["variants"]
            + request.advancedArguments
            + [
            "-p", prefix,
            "-q", "20",
            "-t", String(request.minimumAlleleFrequency ?? 0.05),
            "-m", String(request.minimumDepth ?? 10),
            "-r", plan.referenceURL.path,
            "--output-format", "vcf",
        ]
    }

    private func medakaArguments(plan: ViralVariantCallingExecutionPlan) -> [String] {
        return ["variant"]
            + request.advancedArguments
            + [
            "-i", plan.medakaFASTQURL?.path ?? "",
            "-r", plan.referenceURL.path,
            "-o", plan.rawVCFURL.path,
            "-m", request.medakaModel ?? "",
            "-t", String(max(1, request.threads)),
        ]
    }

    private func callerParametersJSON() -> String {
        let payload = CallerParametersPayload(
            caller: request.caller.rawValue,
            threads: request.threads,
            minimumAlleleFrequency: request.minimumAlleleFrequency,
            minimumDepth: request.minimumDepth,
            ivarPrimerTrimConfirmed: request.ivarPrimerTrimConfirmed,
            medakaModel: request.medakaModel,
            advancedOptions: AdvancedCommandLineOptions.join(request.advancedArguments),
            advancedArguments: request.advancedArguments
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(payload),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }

    private func nativeTool(for caller: ViralVariantCaller) -> NativeTool {
        switch caller {
        case .lofreq:
            return .lofreq
        case .ivar:
            return .ivar
        case .medaka:
            return .medaka
        }
    }
}
