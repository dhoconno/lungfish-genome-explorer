import Foundation
import LungfishCore
import LungfishIO
import os.log

private let logger = Logger(subsystem: LogSubsystem.workflow, category: "ViralVariantCallingPipeline")

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
    public let provenanceSteps: [VariantCallingProvenanceStep]

    public init(
        normalizedVCFURL: URL,
        stagedVCFGZURL: URL,
        stagedTabixURL: URL,
        referenceFASTAURL: URL,
        referenceFASTASHA256: String,
        callerVersion: String,
        callerParametersJSON: String,
        commandLine: String = "",
        provenanceSteps: [VariantCallingProvenanceStep] = []
    ) {
        self.normalizedVCFURL = normalizedVCFURL
        self.stagedVCFGZURL = stagedVCFGZURL
        self.stagedTabixURL = stagedTabixURL
        self.referenceFASTAURL = referenceFASTAURL
        self.referenceFASTASHA256 = referenceFASTASHA256
        self.callerVersion = callerVersion
        self.callerParametersJSON = callerParametersJSON
        self.commandLine = commandLine
        self.provenanceSteps = provenanceSteps
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
        let ivarPrimerTrimConfirmed: Bool?
        let ivarConsensusAF: Double?
        let ivarMergeAFThreshold: Double?
        let ivarBadQualityThreshold: Int?
        let ivarIgnoreStrandBias: Bool?
        let medakaModel: String?
        let advancedOptions: String?
        let advancedArguments: [String]?
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
                workingDirectory: workspaceURL,
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
        var provenanceSteps: [VariantCallingProvenanceStep] = []
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
        provenanceSteps.append(contentsOf: try await stageAlignmentArtifacts(plan: plan))
        provenanceSteps.append(contentsOf: try await stageReference(plan: plan))

        if request.caller == .medaka, let fastqURL = plan.medakaFASTQURL {
            progress?(0.20, "Reconstructing FASTQ input for Medaka")
            let startedAt = Date()
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
                let completedAt = Date()
                provenanceSteps.append(
                    VariantCallingProvenanceStep(
                        toolName: "samtools",
                        toolVersion: await nativeToolVersion(for: .samtools),
                        command: await nativeCommand(
                            for: .samtools,
                            arguments: [
                                "fastq",
                                "-F", "2304",
                                "-0", plan.referenceURL.deletingLastPathComponent().appendingPathComponent("medaka_other.fastq").path,
                                "-1", plan.referenceURL.deletingLastPathComponent().appendingPathComponent("medaka_r1.fastq").path,
                                "-2", plan.referenceURL.deletingLastPathComponent().appendingPathComponent("medaka_r2.fastq").path,
                                "-s", plan.referenceURL.deletingLastPathComponent().appendingPathComponent("medaka_singletons.fastq").path,
                                plan.alignmentURL.path,
                            ]
                        ),
                        inputs: [ProvenanceRecorder.fileRecord(url: plan.alignmentURL, format: .bam, role: .input)],
                        outputs: [ProvenanceRecorder.fileRecord(url: fastqURL, format: .fastq, role: .output)],
                        exitCode: 0,
                        wallTime: completedAt.timeIntervalSince(startedAt),
                        stderr: nil,
                        startedAt: startedAt,
                        completedAt: completedAt
                    )
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
        let executedCommandLine: String
        if let callerExecutor {
            try await callerExecutor(plan, toolRunner)
            executedCommandLine = plan.commandLine
        } else {
            let callerResult = try await runCaller(plan: plan)
            executedCommandLine = callerResult.commandLine
            provenanceSteps.append(contentsOf: callerResult.steps)
        }

        guard FileManager.default.fileExists(atPath: plan.rawVCFURL.path) else {
            throw ViralVariantCallingPipelineError.missingCallerOutput(plan.rawVCFURL.path)
        }

        progress?(0.70, "Sorting VCF")
        let sortArguments = [
            "sort",
            "-O", "v",
            "-o", plan.normalizedVCFURL.path,
            plan.rawVCFURL.path,
        ]
        let sortStartedAt = Date()
        let sortResult = try await toolRunner.run(
            .bcftools,
            arguments: sortArguments,
            workingDirectory: plan.workingDirectory,
            timeout: 600
        )
        let sortCompletedAt = Date()
        provenanceSteps.append(
                VariantCallingProvenanceStep(
                    toolName: "bcftools",
                    toolVersion: await nativeToolVersion(for: .bcftools),
                    command: await nativeCommand(for: .bcftools, arguments: sortArguments),
                inputs: [ProvenanceRecorder.fileRecord(url: plan.rawVCFURL, format: .vcf, role: .input)],
                outputs: [ProvenanceRecorder.fileRecord(url: plan.normalizedVCFURL, format: .vcf, role: .output)],
                exitCode: sortResult.exitCode,
                wallTime: sortCompletedAt.timeIntervalSince(sortStartedAt),
                stderr: sortResult.stderr,
                startedAt: sortStartedAt,
                completedAt: sortCompletedAt
            )
        )
        guard sortResult.isSuccess else {
            throw ViralVariantCallingPipelineError.normalizationFailed(sortResult.combinedOutput)
        }

        progress?(0.82, "Compressing normalized VCF")
        let bgzipStartedAt = Date()
        let bgzipResult = try await toolRunner.bgzipCompress(
            inputPath: plan.normalizedVCFURL,
            keepOriginal: true,
            threads: request.threads
        )
        let bgzipCompletedAt = Date()
        let compressedNormalizedURL = plan.normalizedVCFURL.appendingPathExtension("gz")
        provenanceSteps.append(
            VariantCallingProvenanceStep(
                toolName: "bgzip",
                toolVersion: await nativeToolVersion(for: .bgzip),
                command: await nativeCommand(
                    for: .bgzip,
                    arguments: bgzipArguments(inputURL: plan.normalizedVCFURL, keepOriginal: true, threads: request.threads)
                ),
                inputs: [ProvenanceRecorder.fileRecord(url: plan.normalizedVCFURL, format: .vcf, role: .input)],
                outputs: [ProvenanceRecorder.fileRecord(url: compressedNormalizedURL, format: .vcf, role: .output)],
                exitCode: bgzipResult.exitCode,
                wallTime: bgzipCompletedAt.timeIntervalSince(bgzipStartedAt),
                stderr: bgzipResult.stderr,
                startedAt: bgzipStartedAt,
                completedAt: bgzipCompletedAt
            )
        )
        guard bgzipResult.isSuccess else {
            throw ViralVariantCallingPipelineError.compressionFailed(bgzipResult.combinedOutput)
        }

        do {
            if FileManager.default.fileExists(atPath: plan.stagedVCFGZURL.path) {
                try FileManager.default.removeItem(at: plan.stagedVCFGZURL)
            }
            try FileManager.default.moveItem(at: compressedNormalizedURL, to: plan.stagedVCFGZURL)
        } catch {
            throw ViralVariantCallingPipelineError.compressionFailed(error.localizedDescription)
        }

        progress?(0.92, "Indexing compressed VCF")
        let tabixArguments = ["-f", "-p", "vcf", plan.stagedVCFGZURL.path]
        let tabixStartedAt = Date()
        let tabixResult = try await toolRunner.run(
            .tabix,
            arguments: tabixArguments,
            workingDirectory: plan.workingDirectory,
            timeout: 600
        )
        let tabixCompletedAt = Date()
        provenanceSteps.append(
                VariantCallingProvenanceStep(
                    toolName: "tabix",
                    toolVersion: await nativeToolVersion(for: .tabix),
                    command: await nativeCommand(for: .tabix, arguments: tabixArguments),
                inputs: [ProvenanceRecorder.fileRecord(url: plan.stagedVCFGZURL, format: .vcf, role: .input)],
                outputs: [ProvenanceRecorder.fileRecord(url: plan.stagedTabixURL, role: .index)],
                exitCode: tabixResult.exitCode,
                wallTime: tabixCompletedAt.timeIntervalSince(tabixStartedAt),
                stderr: tabixResult.stderr,
                startedAt: tabixStartedAt,
                completedAt: tabixCompletedAt
            )
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
            commandLine: executedCommandLine,
            provenanceSteps: provenanceSteps
        )
    }

    private func stageAlignmentArtifacts(plan: ViralVariantCallingExecutionPlan) async throws -> [VariantCallingProvenanceStep] {
        let startedAt = Date()
        do {
            if preflight.contigValidation == .matchedByAlias {
                return try await rewriteAlignmentHeader(plan: plan)
            } else {
                try stageInputArtifact(from: preflight.alignmentURL, to: plan.alignmentURL)
                try stageInputArtifact(from: preflight.alignmentIndexURL, to: plan.alignmentIndexURL)
                let completedAt = Date()
                return [
                    VariantCallingProvenanceStep(
                        toolName: "lungfish alignment-staging",
                        toolVersion: WorkflowRun.currentAppVersion,
                        command: [
                            "lungfish-internal", "stage-alignment",
                            "--input-bam", preflight.alignmentURL.path,
                            "--input-index", preflight.alignmentIndexURL.path,
                            "--output-bam", plan.alignmentURL.path,
                            "--output-index", plan.alignmentIndexURL.path,
                            "--mode", "symlink",
                        ],
                        inputs: [
                            ProvenanceRecorder.fileRecord(url: preflight.alignmentURL, format: .bam, role: .input),
                            ProvenanceRecorder.fileRecord(url: preflight.alignmentIndexURL, role: .index),
                        ],
                        outputs: [
                            ProvenanceRecorder.fileRecord(url: plan.alignmentURL, format: .bam, role: .output),
                            ProvenanceRecorder.fileRecord(url: plan.alignmentIndexURL, role: .index),
                        ],
                        exitCode: 0,
                        wallTime: completedAt.timeIntervalSince(startedAt),
                        stderr: nil,
                        startedAt: startedAt,
                        completedAt: completedAt
                    )
                ]
            }
        } catch {
            throw ViralVariantCallingPipelineError.alignmentStagingFailed(error.localizedDescription)
        }
    }

    private func stageReference(plan: ViralVariantCallingExecutionPlan) async throws -> [VariantCallingProvenanceStep] {
        let startedAt = Date()
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
            let stagedAt = Date()

            let faiResult = try await toolRunner.indexFASTA(fastaPath: plan.referenceURL)
            let indexedAt = Date()
            guard faiResult.isSuccess else {
                throw ViralVariantCallingPipelineError.referenceStagingFailed(faiResult.combinedOutput)
            }
            return [
                VariantCallingProvenanceStep(
                    toolName: "lungfish reference-staging",
                    toolVersion: WorkflowRun.currentAppVersion,
                    command: [
                        "lungfish-internal", "stage-reference",
                        "--input", preflight.referenceFASTAURL.path,
                        "--output", plan.referenceURL.path,
                        "--mode", preflight.referenceFASTAURL.pathExtension.lowercased() == "gz" ? "decompress-gzip" : "copy",
                    ],
                    inputs: [
                        ProvenanceRecorder.fileRecord(url: preflight.referenceFASTAURL, format: .fasta, role: .reference)
                    ],
                    outputs: [
                        ProvenanceRecorder.fileRecord(url: plan.referenceURL, format: .fasta, role: .output)
                    ],
                    exitCode: 0,
                    wallTime: stagedAt.timeIntervalSince(startedAt),
                    stderr: nil,
                    startedAt: startedAt,
                    completedAt: stagedAt
                ),
                VariantCallingProvenanceStep(
                    toolName: "samtools",
                    toolVersion: await nativeToolVersion(for: .samtools),
                    command: await nativeCommand(for: .samtools, arguments: ["faidx", plan.referenceURL.path]),
                    inputs: [
                        ProvenanceRecorder.fileRecord(url: plan.referenceURL, format: .fasta, role: .input)
                    ],
                    outputs: [
                        ProvenanceRecorder.fileRecord(url: plan.referenceIndexURL, role: .index)
                    ],
                    exitCode: faiResult.exitCode,
                    wallTime: indexedAt.timeIntervalSince(stagedAt),
                    stderr: faiResult.stderr,
                    startedAt: stagedAt,
                    completedAt: indexedAt
                )
            ]
        } catch let error as ViralVariantCallingPipelineError {
            throw error
        } catch {
            throw ViralVariantCallingPipelineError.referenceStagingFailed(error.localizedDescription)
        }
    }

    private func runCaller(plan: ViralVariantCallingExecutionPlan) async throws -> (commandLine: String, steps: [VariantCallingProvenanceStep]) {
        switch request.caller {
        case .lofreq:
            let arguments = lofreqArguments(plan: plan)
            let startedAt = Date()
            let result = try await toolRunner.run(
                .lofreq,
                arguments: arguments,
                workingDirectory: plan.workingDirectory,
                timeout: 3600
            )
            let completedAt = Date()
            let step = VariantCallingProvenanceStep(
                toolName: nativeTool(for: request.caller).executableName,
                toolVersion: await nativeToolVersion(for: nativeTool(for: request.caller)),
                command: await nativeCommand(for: nativeTool(for: request.caller), arguments: arguments),
                inputs: [
                    ProvenanceRecorder.fileRecord(url: plan.referenceURL, format: .fasta, role: .reference),
                    ProvenanceRecorder.fileRecord(url: plan.alignmentURL, format: .bam, role: .input),
                ],
                outputs: [ProvenanceRecorder.fileRecord(url: plan.rawVCFURL, format: .vcf, role: .output)],
                exitCode: result.exitCode,
                wallTime: completedAt.timeIntervalSince(startedAt),
                stderr: result.stderr,
                startedAt: startedAt,
                completedAt: completedAt
            )
            guard result.isSuccess else {
                throw ViralVariantCallingPipelineError.callerExecutionFailed(result.combinedOutput)
            }
            return (([nativeTool(for: request.caller).executableName] + arguments).map(shellEscape).joined(separator: " "), [step])
        case .ivar:
            let gffURL = await exportBundleGFFIfAvailable(plan: plan)
            let mpileupArguments = ivarMpileupArguments(plan: plan)
            let variantArguments = ivarVariantArguments(plan: plan, gffURL: gffURL)
            let startedAt = Date()
            let result = try await toolRunner.runPipeline(
                [
                    NativePipelineStage(.samtools, arguments: mpileupArguments),
                    NativePipelineStage(.ivar, arguments: variantArguments),
                ],
                workingDirectory: plan.workingDirectory,
                timeout: 3600
            )
            let completedAt = Date()
            guard result.isSuccess else {
                throw ViralVariantCallingPipelineError.callerExecutionFailed(result.combinedStderr)
            }
            let tsvURL = plan.workingDirectory.appendingPathComponent("ivar.tsv-prefix.tsv")
            let allHapURL = plan.workingDirectory.appendingPathComponent("ivar.all-haplotypes.vcf")
            let manifest = try BundleManifest.load(from: request.bundleURL)
            let contigs = (manifest.genome?.chromosomes ?? []).map { chrom in
                IVarTSVToVCFConverter.Contig(name: chrom.name, length: Int(chrom.length))
            }
            let ivarVersion = await nativeToolVersion(for: .ivar) ?? "unknown"
            let lungfishVersion = WorkflowRun.currentAppVersion
            let options = IVarTSVToVCFConverter.Options(
                consensusAF: request.ivarConsensusAF,
                mergeAFThreshold: request.ivarMergeAFThreshold,
                badQualityThreshold: request.ivarBadQualityThreshold,
                ignoreStrandBias: request.ivarIgnoreStrandBias,
                sourceLine: "iVar \(ivarVersion) (TSV-to-VCF: Lungfish \(lungfishVersion))",
                contigs: contigs,
                gffMissingNote: gffURL == nil
            )
            try IVarTSVToVCFConverter().convert(
                tsvURL: tsvURL,
                primaryVCFURL: plan.rawVCFURL,
                allHaplotypesVCFURL: allHapURL,
                options: options
            )
            let conversionCompletedAt = Date()
            let samtoolsStep = VariantCallingProvenanceStep(
                toolName: "samtools",
                toolVersion: await nativeToolVersion(for: .samtools),
                command: await nativeCommand(for: .samtools, arguments: mpileupArguments),
                inputs: [
                    ProvenanceRecorder.fileRecord(url: plan.referenceURL, format: .fasta, role: .reference),
                    ProvenanceRecorder.fileRecord(url: plan.alignmentURL, format: .bam, role: .input),
                ],
                outputs: [],
                exitCode: result.exitCodes.indices.contains(0) ? result.exitCodes[0] : nil,
                wallTime: completedAt.timeIntervalSince(startedAt),
                stderr: result.stderrByStage.indices.contains(0) ? result.stderrByStage[0] : nil,
                startedAt: startedAt,
                completedAt: completedAt
            )
            let ivarInputs = gffURL
                .map { [ProvenanceRecorder.fileRecord(url: $0, format: .gff3, role: .input)] }
                ?? []
            let ivarStep = VariantCallingProvenanceStep(
                toolName: "ivar",
                toolVersion: await nativeToolVersion(for: .ivar),
                command: await nativeCommand(for: .ivar, arguments: variantArguments),
                inputs: ivarInputs,
                outputs: [ProvenanceRecorder.fileRecord(url: tsvURL, format: .text, role: .output)],
                exitCode: result.exitCodes.indices.contains(1) ? result.exitCodes[1] : nil,
                wallTime: completedAt.timeIntervalSince(startedAt),
                stderr: result.stderrByStage.indices.contains(1) ? result.stderrByStage[1] : nil,
                startedAt: startedAt,
                completedAt: completedAt
            )
            let converterStep = VariantCallingProvenanceStep(
                toolName: "lungfish ivar-tsv-to-vcf-converter",
                toolVersion: WorkflowRun.currentAppVersion,
                command: [
                    "lungfish-internal", "ivar-tsv-to-vcf",
                    "--input", tsvURL.path,
                    "--output", plan.rawVCFURL.path,
                    "--all-haplotypes-output", allHapURL.path,
                    "--consensus-af", String(request.ivarConsensusAF),
                    "--merge-af-threshold", String(request.ivarMergeAFThreshold),
                    "--bad-quality-threshold", String(request.ivarBadQualityThreshold),
                    "--ignore-strand-bias", String(request.ivarIgnoreStrandBias),
                ],
                inputs: [ProvenanceRecorder.fileRecord(url: tsvURL, format: .text, role: .input)],
                outputs: [
                    ProvenanceRecorder.fileRecord(url: plan.rawVCFURL, format: .vcf, role: .output),
                    ProvenanceRecorder.fileRecord(url: allHapURL, format: .vcf, role: .output),
                ],
                exitCode: 0,
                wallTime: conversionCompletedAt.timeIntervalSince(completedAt),
                stderr: nil,
                startedAt: completedAt,
                completedAt: conversionCompletedAt
            )
            return (
                "samtools \(mpileupArguments.map(shellEscape).joined(separator: " ")) | ivar \(variantArguments.map(shellEscape).joined(separator: " "))",
                [samtoolsStep, ivarStep, converterStep]
            )
        case .medaka:
            let arguments = medakaArguments(plan: plan)
            let startedAt = Date()
            let result = try await toolRunner.run(
                .medaka,
                arguments: arguments,
                workingDirectory: plan.workingDirectory,
                timeout: 3600
            )
            let completedAt = Date()
            let step = VariantCallingProvenanceStep(
                toolName: nativeTool(for: request.caller).executableName,
                toolVersion: await nativeToolVersion(for: nativeTool(for: request.caller)),
                command: await nativeCommand(for: nativeTool(for: request.caller), arguments: arguments),
                inputs: [
                    ProvenanceRecorder.fileRecord(url: plan.referenceURL, format: .fasta, role: .reference),
                    plan.medakaFASTQURL.map { ProvenanceRecorder.fileRecord(url: $0, format: .fastq, role: .input) },
                ].compactMap { $0 },
                outputs: [ProvenanceRecorder.fileRecord(url: plan.rawVCFURL, format: .vcf, role: .output)],
                exitCode: result.exitCode,
                wallTime: completedAt.timeIntervalSince(startedAt),
                stderr: result.stderr,
                startedAt: startedAt,
                completedAt: completedAt
            )
            guard result.isSuccess else {
                throw ViralVariantCallingPipelineError.callerExecutionFailed(result.combinedOutput)
            }
            return (([nativeTool(for: request.caller).executableName] + arguments).map(shellEscape).joined(separator: " "), [step])
        }
    }

    private func stageInputArtifact(from sourceURL: URL, to stagedURL: URL) throws {
        if FileManager.default.fileExists(atPath: stagedURL.path) {
            try FileManager.default.removeItem(at: stagedURL)
        }
        try FileManager.default.createSymbolicLink(at: stagedURL, withDestinationURL: sourceURL)
    }

    private func rewriteAlignmentHeader(plan: ViralVariantCallingExecutionPlan) async throws -> [VariantCallingProvenanceStep] {
        let headerStartedAt = Date()
        let headerResult = try await toolRunner.run(
            .samtools,
            arguments: ["view", "-H", preflight.alignmentURL.path],
            timeout: 120
        )
        let headerCompletedAt = Date()
        guard headerResult.isSuccess else {
            throw ViralVariantCallingPipelineError.alignmentStagingFailed(headerResult.combinedOutput)
        }

        let rewrittenHeader = remapAlignmentHeader(headerResult.stdout)
        let rawHeaderURL = plan.workingDirectory.appendingPathComponent("original-header.sam")
        let rewrittenHeaderURL = plan.workingDirectory.appendingPathComponent("rewritten-header.sam")
        try headerResult.stdout.write(to: rawHeaderURL, atomically: true, encoding: .utf8)
        try rewrittenHeader.write(to: rewrittenHeaderURL, atomically: true, encoding: .utf8)

        let reheaderStartedAt = Date()
        let reheaderResult = try await toolRunner.runWithFileOutput(
            .samtools,
            arguments: ["reheader", rewrittenHeaderURL.path, preflight.alignmentURL.path],
            outputFile: plan.alignmentURL,
            workingDirectory: plan.workingDirectory,
            timeout: 600
        )
        let reheaderCompletedAt = Date()
        guard reheaderResult.isSuccess else {
            throw ViralVariantCallingPipelineError.alignmentStagingFailed(reheaderResult.combinedOutput)
        }

        let indexStartedAt = Date()
        let indexResult = try await toolRunner.run(
            .samtools,
            arguments: ["index", plan.alignmentURL.path],
            workingDirectory: plan.workingDirectory,
            timeout: 600
        )
        let indexCompletedAt = Date()
        guard indexResult.isSuccess else {
            throw ViralVariantCallingPipelineError.alignmentStagingFailed(indexResult.combinedOutput)
        }
        return [
            VariantCallingProvenanceStep(
                toolName: "samtools",
                toolVersion: await nativeToolVersion(for: .samtools),
                command: await nativeCommand(for: .samtools, arguments: ["view", "-H", preflight.alignmentURL.path]),
                inputs: [ProvenanceRecorder.fileRecord(url: preflight.alignmentURL, format: .bam, role: .input)],
                outputs: [ProvenanceRecorder.fileRecord(url: rawHeaderURL, format: .sam, role: .output)],
                exitCode: headerResult.exitCode,
                wallTime: headerCompletedAt.timeIntervalSince(headerStartedAt),
                stderr: headerResult.stderr,
                startedAt: headerStartedAt,
                completedAt: headerCompletedAt
            ),
            VariantCallingProvenanceStep(
                toolName: "lungfish alignment-header-remap",
                toolVersion: WorkflowRun.currentAppVersion,
                command: [
                    "lungfish-internal", "remap-sam-header",
                    "--input-header", rawHeaderURL.path,
                    "--output-header", rewrittenHeaderURL.path,
                    "--reference-name-map", referenceNameMapDescription(),
                ],
                inputs: [ProvenanceRecorder.fileRecord(url: rawHeaderURL, format: .sam, role: .input)],
                outputs: [ProvenanceRecorder.fileRecord(url: rewrittenHeaderURL, format: .sam, role: .output)],
                exitCode: 0,
                wallTime: reheaderStartedAt.timeIntervalSince(headerCompletedAt),
                stderr: nil,
                startedAt: headerCompletedAt,
                completedAt: reheaderStartedAt
            ),
            VariantCallingProvenanceStep(
                toolName: "samtools",
                toolVersion: await nativeToolVersion(for: .samtools),
                command: await nativeCommand(
                    for: .samtools,
                    arguments: ["reheader", rewrittenHeaderURL.path, preflight.alignmentURL.path]
                ),
                inputs: [
                    ProvenanceRecorder.fileRecord(url: preflight.alignmentURL, format: .bam, role: .input),
                    ProvenanceRecorder.fileRecord(url: rewrittenHeaderURL, format: .sam, role: .input),
                ],
                outputs: [ProvenanceRecorder.fileRecord(url: plan.alignmentURL, format: .bam, role: .output)],
                exitCode: reheaderResult.exitCode,
                wallTime: reheaderCompletedAt.timeIntervalSince(reheaderStartedAt),
                stderr: reheaderResult.stderr,
                startedAt: reheaderStartedAt,
                completedAt: reheaderCompletedAt
            ),
            VariantCallingProvenanceStep(
                toolName: "samtools",
                toolVersion: await nativeToolVersion(for: .samtools),
                command: await nativeCommand(for: .samtools, arguments: ["index", plan.alignmentURL.path]),
                inputs: [ProvenanceRecorder.fileRecord(url: plan.alignmentURL, format: .bam, role: .input)],
                outputs: [ProvenanceRecorder.fileRecord(url: plan.alignmentIndexURL, role: .index)],
                exitCode: indexResult.exitCode,
                wallTime: indexCompletedAt.timeIntervalSince(indexStartedAt),
                stderr: indexResult.stderr,
                startedAt: indexStartedAt,
                completedAt: indexCompletedAt
            ),
        ]
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

    private func referenceNameMapDescription() -> String {
        preflight.referenceNameMap
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ",")
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
        workingDirectory: URL,
        referenceURL: URL,
        alignmentURL: URL,
        medakaFASTQURL: URL?,
        rawVCFURL: URL
    ) -> String {
        let plan = placeholderPlan(
            workingDirectory: workingDirectory,
            referenceURL: referenceURL,
            alignmentURL: alignmentURL,
            medakaFASTQURL: medakaFASTQURL,
            rawVCFURL: rawVCFURL
        )
        switch caller {
        case .lofreq:
            return ([nativeTool(for: caller).executableName] + lofreqArguments(
                plan: plan
            )).map(shellEscape).joined(separator: " ")
        case .ivar:
            return """
            samtools \(ivarMpileupArguments(plan: plan).map(shellEscape).joined(separator: " ")) | ivar \(ivarVariantArguments(plan: plan, gffURL: plannedIVarGFFURL(workingDirectory: workingDirectory)).map(shellEscape).joined(separator: " "))
            """
        case .medaka:
            return ([nativeTool(for: caller).executableName] + medakaArguments(
                plan: plan
            )).map(shellEscape).joined(separator: " ")
        }
    }

    private func placeholderPlan(
        workingDirectory: URL,
        referenceURL: URL,
        alignmentURL: URL,
        medakaFASTQURL: URL?,
        rawVCFURL: URL
    ) -> ViralVariantCallingExecutionPlan {
        ViralVariantCallingExecutionPlan(
            caller: request.caller,
            workingDirectory: workingDirectory,
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

    private func plannedIVarGFFURL(workingDirectory: URL) -> URL? {
        guard preflight.manifest.annotations.contains(where: { annotation in
            annotation.databasePath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }) else {
            return nil
        }
        return workingDirectory.appendingPathComponent("ivar-annotations.gff3")
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

    private func ivarVariantArguments(plan: ViralVariantCallingExecutionPlan, gffURL: URL?) -> [String] {
        let prefix = plan.workingDirectory.appendingPathComponent("ivar.tsv-prefix").path
        var args: [String] = ["variants"]
        args.append(contentsOf: request.advancedArguments)
        args.append(contentsOf: [
            "-p", prefix,
            "-q", "20",
            "-t", String(request.minimumAlleleFrequency ?? 0.05),
            "-m", String(request.minimumDepth ?? 10),
            "-r", plan.referenceURL.path,
        ])
        if let gffURL {
            args.append(contentsOf: ["-g", gffURL.path])
        }
        return args
    }

    private func bgzipArguments(inputURL: URL, keepOriginal: Bool, threads: Int) -> [String] {
        var args = ["-f"]
        if keepOriginal {
            args.append("-k")
        }
        if threads > 1 {
            args.append(contentsOf: ["-@", "\(threads)"])
        }
        args.append(inputURL.path)
        return args
    }

    private func exportBundleGFFIfAvailable(plan: ViralVariantCallingExecutionPlan) async -> URL? {
        let manifest: BundleManifest
        do {
            manifest = try BundleManifest.load(from: request.bundleURL)
        } catch {
            // Could not load the bundle manifest. Skip GFF passthrough and let
            // iVar run without per-codon merging. Logged so a curious user can
            // find the cause in Console.app, but not surfaced as an error.
            logger.warning("Could not load bundle manifest for GFF export: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        guard let firstAnnotation = manifest.annotations.first else {
            // No annotations attached; this is normal for un-annotated bundles.
            // Skip codon merging silently.
            return nil
        }
        guard let databasePath = firstAnnotation.databasePath else {
            // Annotation present but no database path; nothing we can convert
            // to GFF for iVar.
            return nil
        }
        let dbURL = request.bundleURL.appendingPathComponent(databasePath)
        do {
            let database = try AnnotationDatabase(url: dbURL)
            let outURL = plan.workingDirectory.appendingPathComponent("ivar-annotations.gff3")
            try AnnotationDatabaseGFFExporter.export(database: database, to: outURL)
            return outURL
        } catch {
            // The bundle has annotations but we couldn't open the database or
            // export GFF. This is unexpected; record the cause so the next
            // reader has a hint without needing to re-instrument the code.
            logger.error("Failed to export bundle GFF for iVar codon merging: \(error.localizedDescription, privacy: .public)")
            return nil
        }
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
        let isIvar = request.caller == .ivar
        let payload = CallerParametersPayload(
            caller: request.caller.rawValue,
            threads: request.threads,
            minimumAlleleFrequency: request.minimumAlleleFrequency,
            minimumDepth: request.minimumDepth,
            ivarPrimerTrimConfirmed: isIvar ? request.ivarPrimerTrimConfirmed : nil,
            ivarConsensusAF: isIvar ? request.ivarConsensusAF : nil,
            ivarMergeAFThreshold: isIvar ? request.ivarMergeAFThreshold : nil,
            ivarBadQualityThreshold: isIvar ? request.ivarBadQualityThreshold : nil,
            ivarIgnoreStrandBias: isIvar ? request.ivarIgnoreStrandBias : nil,
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

    private func nativeCommand(for tool: NativeTool, arguments: [String]) async -> [String] {
        if let toolURL = try? await toolRunner.findTool(tool) {
            return [toolURL.path] + arguments
        }
        return [tool.executableName] + arguments
    }

    private func nativeToolVersion(for tool: NativeTool) async -> String {
        let version = await toolRunner.getToolVersion(tool) ?? "unknown"
        return "\(version) (\(runtimeIdentity(for: tool)))"
    }

    private func runtimeIdentity(for tool: NativeTool) -> String {
        switch tool.location {
        case .managed(let environment, let executableName):
            let packageSpec = (try? ManagedToolLock.loadFromBundle().tool(named: environment)?.packageSpec)
                ?? tool.sourcePackage
            return "managed conda environment \(environment); executable \(executableName); package \(packageSpec)"
        case .bundled(let relativePath):
            return "bundled executable \(relativePath)"
        }
    }
}
