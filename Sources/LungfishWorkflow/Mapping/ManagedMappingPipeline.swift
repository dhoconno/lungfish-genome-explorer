// ManagedMappingPipeline.swift - Shared managed mapping execution and BAM normalization
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

@preconcurrency import Foundation
import LungfishCore
import LungfishIO

public struct NormalizedMappingAlignment: Sendable, Equatable {
    public let bamURL: URL
    public let baiURL: URL
    public let totalReads: Int
    public let mappedReads: Int
    public let unmappedReads: Int
    public let steps: [StepExecution]

    public init(
        bamURL: URL,
        baiURL: URL,
        totalReads: Int,
        mappedReads: Int,
        unmappedReads: Int,
        steps: [StepExecution] = []
    ) {
        self.bamURL = bamURL
        self.baiURL = baiURL
        self.totalReads = totalReads
        self.mappedReads = mappedReads
        self.unmappedReads = unmappedReads
        self.steps = steps
    }
}

public enum ManagedMappingPipelineError: Error, LocalizedError, Sendable {
    case incompatibleSelection(String)
    case executionFailed(tool: String, exitCode: Int32, detail: String)
    case stagingFailed(String)
    case inputNotFound(URL)
    case referenceNotFound(URL)
    case mapperNotInstalled(String)
    case normalizationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .incompatibleSelection(let message):
            return message
        case .executionFailed(let tool, let exitCode, let detail):
            return "\(tool) failed (exit \(exitCode)): \(detail)"
        case .stagingFailed(let message):
            return message
        case .inputNotFound(let url):
            return "Input sequence file not found: \(url.lastPathComponent)"
        case .referenceNotFound(let url):
            return "Reference FASTA not found: \(url.lastPathComponent)"
        case .mapperNotInstalled(let tool):
            return "\(tool) is not installed. Install the read-mapping plugin pack first."
        case .normalizationFailed(let message):
            return message
        }
    }
}

private struct PreparedMappingExecution: Sendable {
    let request: MappingRunRequest
    let referenceLocator: ReferenceLocator
    let cleanupURLs: [URL]
}

public final class ManagedMappingPipeline: @unchecked Sendable {
    public typealias ProgressHandler = @Sendable (Double, String) -> Void

    private let condaManager: CondaManager
    private let nativeToolRunner: NativeToolRunner

    public init(
        condaManager: CondaManager = .shared,
        nativeToolRunner: NativeToolRunner = .shared
    ) {
        self.condaManager = condaManager
        self.nativeToolRunner = nativeToolRunner
    }

    public static func buildCommand(for request: MappingRunRequest) throws -> ManagedMappingCommand {
        try MappingCommandBuilder.buildCommand(for: request)
    }

    public func run(
        request: MappingRunRequest,
        progress: ProgressHandler? = nil
    ) async throws -> MappingResult {
        let start = Date()
        let prepared = try await prepareExecution(for: request)
        defer {
            for url in prepared.cleanupURLs {
                try? FileManager.default.removeItem(at: url)
            }
        }

        let command = try MappingCommandBuilder.buildCommand(
            for: prepared.request,
            referenceLocator: prepared.referenceLocator
        )

        try await validateInputs(for: prepared.request)
        try FileManager.default.createDirectory(at: prepared.request.outputDirectory, withIntermediateDirectories: true)
        let mapperVersion = await detectToolVersion(
            toolName: command.executable,
            environment: prepared.request.tool.environmentName,
            condaManager: condaManager
        )
        let samtoolsVersion = await nativeToolRunner.getToolVersion(.samtools) ?? "unknown"
        let indexSteps = try await prepareReferenceIndexesIfNeeded(
            for: prepared.request,
            locator: prepared.referenceLocator,
            progress: progress,
            mapperVersion: mapperVersion
        )

        let rawAlignmentURL = MappingCommandBuilder.rawAlignmentURL(for: prepared.request)
        progress?(0.1, "Running \(prepared.request.tool.displayName)...")
        let mapperStep = try await executeMappingCommand(
            command,
            outputURL: rawAlignmentURL,
            inputRecords: mappingInputRecords(for: prepared.request, referenceURL: prepared.referenceLocator.referenceURL),
            mapperVersion: mapperVersion,
            progress: progress
        )

        progress?(0.7, "Normalizing sorted BAM...")
        let normalized = try await normalizeAlignment(
            rawAlignmentURL: rawAlignmentURL,
            outputDirectory: prepared.request.outputDirectory,
            sampleName: prepared.request.sampleName,
            threads: prepared.request.threads,
            minimumMappingQuality: prepared.request.minimumMappingQuality,
            includeSecondary: prepared.request.includeSecondary,
            includeSupplementary: prepared.request.includeSupplementary,
            removeIntermediateRawSAMOnSuccess: true,
            samtoolsVersion: samtoolsVersion
        )

        progress?(0.9, "Summarizing mapped contigs...")
        let contigs = try await MappingSummaryBuilder.build(
            sortedBAMURL: normalized.bamURL,
            totalReads: normalized.totalReads,
            runner: nativeToolRunner
        )

        let result = MappingResult(
            mapper: prepared.request.tool,
            modeID: prepared.request.modeID,
            sourceReferenceBundleURL: prepared.request.sourceReferenceBundleURL,
            bamURL: normalized.bamURL,
            baiURL: normalized.baiURL,
            totalReads: normalized.totalReads,
            mappedReads: normalized.mappedReads,
            unmappedReads: normalized.unmappedReads,
            wallClockSeconds: Date().timeIntervalSince(start),
            contigs: contigs
        )
        try result.save(to: prepared.request.outputDirectory)

        let mappingResultURL = prepared.request.outputDirectory.appendingPathComponent("mapping-result.json")
        let outputFiles = [
            ProvenanceRecorder.fileRecord(url: result.bamURL, format: .bam, role: .output),
            ProvenanceRecorder.fileRecord(url: result.baiURL, role: .index),
            ProvenanceRecorder.fileRecord(url: mappingResultURL, format: .json, role: .output)
        ]
        let steps = indexSteps + [mapperStep] + normalized.steps
        let provenance = MappingProvenance.build(
            request: prepared.request,
            result: result,
            mapperInvocation: MappingCommandInvocation(
                label: prepared.request.tool.displayName,
                argv: [command.executable] + command.arguments
            ),
            normalizationInvocations: MappingProvenance.normalizationInvocations(
                rawAlignmentURL: rawAlignmentURL,
                outputDirectory: prepared.request.outputDirectory,
                sampleName: prepared.request.sampleName,
                threads: prepared.request.threads,
                minimumMappingQuality: prepared.request.minimumMappingQuality,
                includeSecondary: prepared.request.includeSecondary,
                includeSupplementary: prepared.request.includeSupplementary
            ),
            mapperVersion: mapperVersion,
            samtoolsVersion: samtoolsVersion,
            inputFiles: mappingInputRecords(for: prepared.request, referenceURL: prepared.referenceLocator.referenceURL),
            outputFiles: outputFiles,
            runtimeIdentity: mappingRuntimeIdentity(for: command),
            steps: steps,
            exitStatus: 0,
            stderr: combinedStderr(steps.map(\.stderr))
        )
        try provenance.save(to: prepared.request.outputDirectory)
        progress?(1.0, "Mapping complete.")
        return result
    }

    public func normalizeAlignment(
        rawAlignmentURL: URL,
        outputDirectory: URL,
        sampleName: String? = nil,
        threads: Int = ProcessInfo.processInfo.processorCount,
        minimumMappingQuality: Int = 0,
        includeSecondary: Bool = true,
        includeSupplementary: Bool = true,
        removeIntermediateRawSAMOnSuccess: Bool = false,
        samtoolsVersion: String? = nil
    ) async throws -> NormalizedMappingAlignment {
        let fm = FileManager.default
        try fm.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let derivedSampleName = sampleName ?? Self.derivedSampleName(from: rawAlignmentURL)
        let sortedBAM = outputDirectory.appendingPathComponent("\(derivedSampleName).sorted.bam")
        let baiURL = outputDirectory.appendingPathComponent("\(derivedSampleName).sorted.bam.bai")
        let tempFilteredBAM = outputDirectory.appendingPathComponent("\(derivedSampleName).filtered.bam")
        let sortThreads = max(1, threads / 2)
        let needsFiltering = minimumMappingQuality > 0 || !includeSecondary || !includeSupplementary
        let extensionLower = rawAlignmentURL.pathExtension.lowercased()
        let isAlreadySorted = rawAlignmentURL.lastPathComponent.hasSuffix(".sorted.bam")
        let resolvedSamtoolsVersion = samtoolsVersion ?? "unknown"
        var steps: [StepExecution] = []

        if extensionLower == "sam" {
            let viewStep = try await samtoolsViewToBAM(
                inputURL: rawAlignmentURL,
                outputBAMURL: tempFilteredBAM,
                minimumMappingQuality: minimumMappingQuality,
                includeSecondary: includeSecondary,
                includeSupplementary: includeSupplementary,
                samtoolsVersion: resolvedSamtoolsVersion
            )
            steps.append(viewStep)
            let sortStep = try await samtoolsSort(
                inputURL: tempFilteredBAM,
                outputBAMURL: sortedBAM,
                threads: sortThreads,
                samtoolsVersion: resolvedSamtoolsVersion
            )
            steps.append(sortStep)
        } else if extensionLower == "bam", isAlreadySorted, !needsFiltering {
            if rawAlignmentURL.standardizedFileURL != sortedBAM.standardizedFileURL {
                if fm.fileExists(atPath: sortedBAM.path) {
                    try fm.removeItem(at: sortedBAM)
                }
                try fm.copyItem(at: rawAlignmentURL, to: sortedBAM)
                steps.append(copyAlignmentStep(inputURL: rawAlignmentURL, outputURL: sortedBAM))
            }
        } else if extensionLower == "bam", !needsFiltering {
            let sortStep = try await samtoolsSort(
                inputURL: rawAlignmentURL,
                outputBAMURL: sortedBAM,
                threads: sortThreads,
                samtoolsVersion: resolvedSamtoolsVersion
            )
            steps.append(sortStep)
        } else {
            let viewStep = try await samtoolsViewToBAM(
                inputURL: rawAlignmentURL,
                outputBAMURL: tempFilteredBAM,
                minimumMappingQuality: minimumMappingQuality,
                includeSecondary: includeSecondary,
                includeSupplementary: includeSupplementary,
                samtoolsVersion: resolvedSamtoolsVersion
            )
            steps.append(viewStep)
            let sortStep = try await samtoolsSort(
                inputURL: tempFilteredBAM,
                outputBAMURL: sortedBAM,
                threads: sortThreads,
                samtoolsVersion: resolvedSamtoolsVersion
            )
            steps.append(sortStep)
        }

        let indexStep = try await samtoolsIndex(
            bamURL: sortedBAM,
            indexURL: baiURL,
            samtoolsVersion: resolvedSamtoolsVersion
        )
        steps.append(indexStep)
        let flagstat = try await samtoolsFlagstatCounts(
            bamURL: sortedBAM,
            samtoolsVersion: resolvedSamtoolsVersion
        )
        steps.append(flagstat.step)
        let (totalReads, mappedReads) = flagstat.counts
        if removeIntermediateRawSAMOnSuccess,
           extensionLower == "sam",
           rawAlignmentURL.lastPathComponent.hasSuffix(".raw.sam"),
           fm.fileExists(atPath: rawAlignmentURL.path) {
            try? fm.removeItem(at: rawAlignmentURL)
        }
        if fm.fileExists(atPath: tempFilteredBAM.path) {
            try? fm.removeItem(at: tempFilteredBAM)
        }

        return NormalizedMappingAlignment(
            bamURL: sortedBAM,
            baiURL: baiURL,
            totalReads: totalReads,
            mappedReads: mappedReads,
            unmappedReads: max(0, totalReads - mappedReads),
            steps: steps
        )
    }

    static func validateCompatibility(for request: MappingRunRequest) throws {
        let inspection = MappingInputInspection.inspect(urls: request.inputFASTQURLs)
        if inspection.mixedSequenceFormats {
            throw ManagedMappingPipelineError.incompatibleSelection(
                "Selected sequence inputs mix FASTA and FASTQ formats. Select one format per mapping run."
            )
        }
        if inspection.mixedReadClasses {
            throw ManagedMappingPipelineError.incompatibleSelection(
                "Selected FASTQ inputs mix incompatible read classes. Select one read class per mapping run."
            )
        }
        if inspection.mixesDetectedAndUnclassifiedReadClasses {
            throw ManagedMappingPipelineError.incompatibleSelection(
                "Selected FASTQ inputs mix classified and unclassified read types. Re-import or edit the read type metadata so every selected FASTQ has the same read type."
            )
        }
        guard let mode = MappingMode(rawValue: request.modeID) else {
            throw ManagedMappingPipelineError.incompatibleSelection(
                "Invalid mode '\(request.modeID)' for \(request.tool.displayName)."
            )
        }

        let inputFormat = inspection.sequenceFormat
            ?? (inspection.readClass != nil ? SequenceFormat.fastq : nil)

        if inputFormat == .fasta {
            let evaluation = MappingCompatibility.evaluate(
                tool: request.tool,
                mode: mode,
                inputFormat: .fasta,
                readClass: nil,
                observedMaxReadLength: inspection.observedMaxReadLength
            )
            if case .blocked(let message) = evaluation.state {
                throw ManagedMappingPipelineError.incompatibleSelection(message)
            }
            return
        }

        guard let readClass = inspection.readClass else {
            throw ManagedMappingPipelineError.incompatibleSelection(
                "Unable to detect a supported read class from the selected FASTQ inputs."
            )
        }

        let evaluation = MappingCompatibility.evaluate(
            tool: request.tool,
            mode: mode,
            inputFormat: .fastq,
            readClass: readClass,
            observedMaxReadLength: inspection.observedMaxReadLength
        )
        if case .blocked(let message) = evaluation.state {
            throw ManagedMappingPipelineError.incompatibleSelection(message)
        }
    }

    private func validateInputs(for request: MappingRunRequest) async throws {
        for inputURL in request.inputFASTQURLs {
            guard FileManager.default.fileExists(atPath: inputURL.path) else {
                throw ManagedMappingPipelineError.inputNotFound(inputURL)
            }
        }
        guard FileManager.default.fileExists(atPath: request.referenceFASTAURL.path) else {
            throw ManagedMappingPipelineError.referenceNotFound(request.referenceFASTAURL)
        }
        try Self.validateCompatibility(for: request)

        switch request.tool {
        case .bbmap:
            let requiredTool: NativeTool = request.modeID == MappingMode.bbmapPacBio.id ? .mapPacBio : .bbmap
            guard await nativeToolRunner.isToolAvailable(requiredTool) else {
                throw ManagedMappingPipelineError.mapperNotInstalled("BBMap")
            }
        default:
            do {
                _ = try await condaManager.toolPath(
                    name: request.tool.executableName,
                    environment: request.tool.environmentName
                )
            } catch {
                throw ManagedMappingPipelineError.mapperNotInstalled(request.tool.displayName)
            }
        }
    }

    private func prepareExecution(for request: MappingRunRequest) async throws -> PreparedMappingExecution {
        let stagedInputs = try await MappingFASTAInputStager.stageSAMSafeFASTAInputsIfNeeded(
            inputURLs: request.inputFASTQURLs,
            projectURL: request.projectURL
        )
        let sourceReferenceBundleURL = request.sourceReferenceBundleURL
            ?? MappingReferenceStager.enclosingReferenceBundleURL(for: request.referenceFASTAURL)
        let stagedReference = try await MappingReferenceStager.stageMapperCompatibleReferenceIfNeeded(
            referenceURL: request.referenceFASTAURL,
            sourceReferenceBundleURL: sourceReferenceBundleURL,
            projectURL: request.projectURL
        )
        let effectiveRequest = request
            .withInputFASTQURLs(stagedInputs.inputURLs)
            .withSourceReferenceBundleURL(sourceReferenceBundleURL)
        let cleanupURLs = stagedInputs.cleanupURLs + stagedReference.cleanupURLs

        switch request.tool {
        case .bwaMem2, .bowtie2:
            let workspace = try ProjectTempDirectory.create(
                prefix: "mapping-index-",
                in: request.projectURL
            )
            let referenceLocator = ReferenceLocator(
                referenceURL: stagedReference.referenceURL,
                indexPrefixURL: workspace.appendingPathComponent("reference-index")
            )
            return PreparedMappingExecution(
                request: effectiveRequest,
                referenceLocator: referenceLocator,
                cleanupURLs: cleanupURLs + [workspace]
            )
        case .minimap2, .bbmap:
            return PreparedMappingExecution(
                request: effectiveRequest,
                referenceLocator: ReferenceLocator(
                    referenceURL: stagedReference.referenceURL,
                    indexPrefixURL: effectiveRequest.outputDirectory.appendingPathComponent(".mapping-index/reference-index")
                ),
                cleanupURLs: cleanupURLs
            )
        }
    }

    private func prepareReferenceIndexesIfNeeded(
        for request: MappingRunRequest,
        locator: ReferenceLocator,
        progress: ProgressHandler?,
        mapperVersion: String
    ) async throws -> [StepExecution] {
        switch request.tool {
        case .bwaMem2:
            progress?(0.02, "Building BWA-MEM2 index...")
            try FileManager.default.createDirectory(
                at: locator.indexPrefixURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let execution = try await runCondaToolStep(
                name: "bwa-mem2",
                arguments: ["index", "-p", locator.indexPrefixURL.path, locator.referenceURL.path],
                environment: request.tool.environmentName,
                workingDirectory: request.outputDirectory,
                timeout: 24 * 3_600,
                toolVersion: mapperVersion,
                inputs: [(locator.referenceURL, .fasta, .reference)],
                outputs: { self.indexOutputFiles(prefixURL: locator.indexPrefixURL) }
            )
            let result = execution.result
            guard result.exitCode == 0 else {
                throw ManagedMappingPipelineError.executionFailed(
                    tool: request.tool.displayName,
                    exitCode: result.exitCode,
                    detail: result.stderr
                )
            }
            return [execution.step]
        case .bowtie2:
            progress?(0.02, "Building Bowtie2 index...")
            try FileManager.default.createDirectory(
                at: locator.indexPrefixURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let execution = try await runCondaToolStep(
                name: "bowtie2-build",
                arguments: [locator.referenceURL.path, locator.indexPrefixURL.path],
                environment: request.tool.environmentName,
                workingDirectory: request.outputDirectory,
                timeout: 24 * 3_600,
                toolVersion: mapperVersion,
                inputs: [(locator.referenceURL, .fasta, .reference)],
                outputs: { self.indexOutputFiles(prefixURL: locator.indexPrefixURL) }
            )
            let result = execution.result
            guard result.exitCode == 0 else {
                throw ManagedMappingPipelineError.executionFailed(
                    tool: "bowtie2-build",
                    exitCode: result.exitCode,
                    detail: result.stderr
                )
            }
            return [execution.step]
        case .minimap2, .bbmap:
            return []
        }
    }

    private func executeMappingCommand(
        _ command: ManagedMappingCommand,
        outputURL: URL,
        inputRecords: [FileRecord],
        mapperVersion: String,
        progress: ProgressHandler?
    ) async throws -> StepExecution {
        if let nativeTool = command.nativeTool {
            let execution = try await runNativeToolStep(
                tool: nativeTool,
                arguments: command.arguments,
                workingDirectory: command.workingDirectory,
                timeout: 24 * 3_600,
                toolVersion: mapperVersion,
                inputs: inputRecords.map { (URL(fileURLWithPath: $0.path), $0.format, $0.role) },
                outputs: [(outputURL, fileFormat(for: outputURL), .output)]
            )
            let result = execution.result
            guard result.exitCode == 0 else {
                throw ManagedMappingPipelineError.executionFailed(
                    tool: command.executable,
                    exitCode: result.exitCode,
                    detail: result.stderr
                )
            }
            return execution.step
        }

        guard let environment = command.environment else {
            throw ManagedMappingPipelineError.stagingFailed("Missing environment for \(command.executable).")
        }

        if command.executable == "bwa-mem2" {
            progress?(0.15, "Streaming bwa-mem2 SAM output...")
            let stepStart = Date()
            let result = try await runCondaToolStreamingStdout(
                executable: command.executable,
                arguments: command.arguments,
                environment: environment,
                workingDirectory: command.workingDirectory,
                stdoutURL: outputURL,
                timeout: 24 * 3_600
            )
            let stepEnd = Date()
            let step = StepExecution(
                toolName: command.executable,
                toolVersion: condaToolVersionString(
                    mapperVersion,
                    environment: environment,
                    executableName: command.executable
                ),
                command: condaCommand(name: command.executable, arguments: command.arguments, environment: environment),
                inputs: inputRecords,
                outputs: [ProvenanceRecorder.fileRecord(url: outputURL, format: fileFormat(for: outputURL), role: .output)],
                exitCode: result.exitCode,
                wallTime: stepEnd.timeIntervalSince(stepStart),
                stderr: nonEmpty(result.stderr),
                startTime: stepStart,
                endTime: stepEnd
            )
            guard result.exitCode == 0 else {
                throw ManagedMappingPipelineError.executionFailed(
                    tool: command.executable,
                    exitCode: result.exitCode,
                    detail: result.stderr
                )
            }
            return step
        }

        let execution = try await runCondaToolStep(
            name: command.executable,
            arguments: command.arguments,
            environment: environment,
            workingDirectory: command.workingDirectory,
            timeout: 24 * 3_600,
            toolVersion: mapperVersion,
            inputs: inputRecords.map { (URL(fileURLWithPath: $0.path), $0.format, $0.role) },
            outputs: { [(outputURL, self.fileFormat(for: outputURL), .output)] }
        )
        let result = execution.result
        guard result.exitCode == 0 else {
            throw ManagedMappingPipelineError.executionFailed(
                tool: command.executable,
                exitCode: result.exitCode,
                detail: result.stderr
            )
        }
        return execution.step
    }

    private func runCondaToolStep(
        name: String,
        arguments: [String],
        environment: String,
        workingDirectory: URL,
        timeout: TimeInterval,
        toolVersion: String,
        inputs: [(URL, FileFormat?, FileRole)],
        outputs: () -> [(URL, FileFormat?, FileRole)]
    ) async throws -> MappingTimedCondaToolResult {
        let start = Date()
        let result = try await condaManager.runTool(
            name: name,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory,
            timeout: timeout
        )
        let end = Date()
        let step = StepExecution(
            toolName: name,
            toolVersion: condaToolVersionString(toolVersion, environment: environment, executableName: name),
            command: condaCommand(name: name, arguments: arguments, environment: environment),
            inputs: inputs.map { ProvenanceRecorder.fileRecord(url: $0.0, format: $0.1, role: $0.2) },
            outputs: outputs().map { ProvenanceRecorder.fileRecord(url: $0.0, format: $0.1, role: $0.2) },
            exitCode: result.exitCode,
            wallTime: end.timeIntervalSince(start),
            stderr: nonEmpty(result.stderr),
            startTime: start,
            endTime: end
        )
        return MappingTimedCondaToolResult(result: result, step: step)
    }

    private func runCondaToolStreamingStdout(
        executable: String,
        arguments: [String],
        environment: String,
        workingDirectory: URL,
        stdoutURL: URL,
        timeout: TimeInterval
    ) async throws -> (stderr: String, exitCode: Int32) {
        try await condaManager.ensureMicromamba()
        let micromambaPath = await condaManager.micromambaPath
        let rootPath = condaManager.rootPrefix.path
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        let tempDirectory = ProcessInfo.processInfo.environment["TMPDIR"]

        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = micromambaPath
            process.arguments = ["run", "-n", environment, executable] + arguments
            process.currentDirectoryURL = workingDirectory

            var processEnvironment: [String: String] = [
                "MAMBA_ROOT_PREFIX": rootPath,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "HOME": homePath,
            ]
            if let tempDirectory {
                processEnvironment["TMPDIR"] = tempDirectory
            }
            process.environment = processEnvironment

            let stderrPipe = Pipe()
            let outputHandle: FileHandle
            do {
                FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
                outputHandle = try FileHandle(forWritingTo: stdoutURL)
            } catch {
                continuation.resume(throwing: error)
                return
            }

            process.standardOutput = outputHandle
            process.standardError = stderrPipe

            let timeoutWorkItem = DispatchWorkItem {
                if process.isRunning {
                    process.terminate()
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutWorkItem)

            do {
                try process.run()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                timeoutWorkItem.cancel()
                try? outputHandle.close()
                let stderr = String(data: stderrData, encoding: .utf8) ?? ""
                continuation.resume(returning: (stderr, process.terminationStatus))
            } catch {
                timeoutWorkItem.cancel()
                try? outputHandle.close()
                continuation.resume(throwing: error)
            }
        }
    }

    private func samtoolsViewToBAM(
        inputURL: URL,
        outputBAMURL: URL,
        minimumMappingQuality: Int,
        includeSecondary: Bool,
        includeSupplementary: Bool,
        samtoolsVersion: String
    ) async throws -> StepExecution {
        var arguments = ["view", "-b", "-o", outputBAMURL.path]
        if minimumMappingQuality > 0 {
            arguments += ["-q", String(minimumMappingQuality)]
        }
        let excludedFlags = excludedFlags(
            includeSecondary: includeSecondary,
            includeSupplementary: includeSupplementary
        )
        if excludedFlags > 0 {
            arguments += ["-F", String(excludedFlags)]
        }
        arguments.append(inputURL.path)

        let execution = try await runNativeToolStep(
            tool: .samtools,
            arguments: arguments,
            workingDirectory: outputBAMURL.deletingLastPathComponent(),
            timeout: 3_600,
            toolVersion: samtoolsVersion,
            inputs: [(inputURL, fileFormat(for: inputURL), .input)],
            outputs: [(outputBAMURL, .bam, .output)]
        )
        let result = execution.result
        guard result.isSuccess else {
            throw ManagedMappingPipelineError.normalizationFailed(result.stderr)
        }
        return execution.step
    }

    private func samtoolsSort(
        inputURL: URL,
        outputBAMURL: URL,
        threads: Int,
        samtoolsVersion: String
    ) async throws -> StepExecution {
        let execution = try await runNativeToolStep(
            tool: .samtools,
            arguments: ["sort", "-@", String(max(1, threads)), "-o", outputBAMURL.path, inputURL.path],
            workingDirectory: outputBAMURL.deletingLastPathComponent(),
            timeout: 3_600,
            toolVersion: samtoolsVersion,
            inputs: [(inputURL, fileFormat(for: inputURL), .input)],
            outputs: [(outputBAMURL, .bam, .output)]
        )
        let result = execution.result
        guard result.isSuccess else {
            throw ManagedMappingPipelineError.normalizationFailed(result.stderr)
        }
        return execution.step
    }

    private func samtoolsIndex(
        bamURL: URL,
        indexURL: URL,
        samtoolsVersion: String
    ) async throws -> StepExecution {
        let execution = try await runNativeToolStep(
            tool: .samtools,
            arguments: ["index", bamURL.path],
            workingDirectory: bamURL.deletingLastPathComponent(),
            timeout: 600,
            toolVersion: samtoolsVersion,
            inputs: [(bamURL, .bam, .input)],
            outputs: [(indexURL, nil, .index)]
        )
        let result = execution.result
        guard result.isSuccess else {
            throw ManagedMappingPipelineError.normalizationFailed(result.stderr)
        }
        return execution.step
    }

    private func samtoolsFlagstatCounts(
        bamURL: URL,
        samtoolsVersion: String
    ) async throws -> (counts: (Int, Int), step: StepExecution) {
        let execution = try await runNativeToolStep(
            tool: .samtools,
            arguments: ["flagstat", bamURL.path],
            workingDirectory: bamURL.deletingLastPathComponent(),
            timeout: 300,
            toolVersion: samtoolsVersion,
            inputs: [(bamURL, .bam, .input)],
            outputs: []
        )
        let result = execution.result
        guard result.isSuccess else {
            throw ManagedMappingPipelineError.normalizationFailed(result.stderr)
        }
        return (Self.parseFlagstat(result.stdout), execution.step)
    }

    private func runNativeToolStep(
        tool: NativeTool,
        arguments: [String],
        workingDirectory: URL,
        timeout: TimeInterval,
        toolVersion: String,
        inputs: [(URL, FileFormat?, FileRole)],
        outputs: [(URL, FileFormat?, FileRole)]
    ) async throws -> MappingTimedNativeToolResult {
        let command = await nativeCommand(for: tool, arguments: arguments)
        let start = Date()
        let result = try await nativeToolRunner.run(
            tool,
            arguments: arguments,
            workingDirectory: workingDirectory,
            timeout: timeout
        )
        let end = Date()
        let step = StepExecution(
            toolName: tool.executableName,
            toolVersion: toolVersionString(toolVersion, tool: tool),
            command: command,
            inputs: inputs.map { ProvenanceRecorder.fileRecord(url: $0.0, format: $0.1, role: $0.2) },
            outputs: outputs.map { ProvenanceRecorder.fileRecord(url: $0.0, format: $0.1, role: $0.2) },
            exitCode: result.exitCode,
            wallTime: end.timeIntervalSince(start),
            stderr: nonEmpty(result.stderr),
            startTime: start,
            endTime: end
        )
        return MappingTimedNativeToolResult(result: result, step: step)
    }

    private func nativeCommand(for tool: NativeTool, arguments: [String]) async -> [String] {
        if let toolURL = try? await nativeToolRunner.findTool(tool) {
            return [toolURL.path] + arguments
        }
        return [tool.executableName] + arguments
    }

    private func condaCommand(name: String, arguments: [String], environment: String) -> [String] {
        ["micromamba", "run", "-n", environment, name] + arguments
    }

    private func mappingInputRecords(for request: MappingRunRequest, referenceURL: URL) -> [FileRecord] {
        let sequenceInputs = request.inputFASTQURLs.map {
            ProvenanceRecorder.fileRecord(url: $0, format: fileFormat(for: $0), role: .input)
        }
        return sequenceInputs + [
            ProvenanceRecorder.fileRecord(url: referenceURL, format: fileFormat(for: referenceURL), role: .reference)
        ]
    }

    private func mappingRuntimeIdentity(for command: ManagedMappingCommand) -> [String: String] {
        var identity: [String: String] = [
            "samtools": runtimeIdentity(for: .samtools)
        ]
        if let nativeTool = command.nativeTool {
            identity["mapper"] = runtimeIdentity(for: nativeTool)
        } else if let environment = command.environment {
            identity["mapper"] = condaRuntimeIdentity(environment: environment, executableName: command.executable)
        }
        return identity
    }

    private func indexOutputFiles(prefixURL: URL) -> [(URL, FileFormat?, FileRole)] {
        let directory = prefixURL.deletingLastPathComponent()
        let prefix = prefixURL.lastPathComponent
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        return urls
            .filter { $0.lastPathComponent.hasPrefix(prefix) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { ($0, fileFormat(for: $0), .index) }
    }

    private func copyAlignmentStep(inputURL: URL, outputURL: URL) -> StepExecution {
        let timestamp = Date()
        return StepExecution(
            toolName: "lungfish",
            toolVersion: WorkflowRun.currentAppVersion,
            command: ["lungfish", "map", "normalize-copy", inputURL.path, outputURL.path],
            inputs: [ProvenanceRecorder.fileRecord(url: inputURL, format: fileFormat(for: inputURL), role: .input)],
            outputs: [ProvenanceRecorder.fileRecord(url: outputURL, format: .bam, role: .output)],
            exitCode: 0,
            wallTime: 0,
            stderr: nil,
            startTime: timestamp,
            endTime: timestamp
        )
    }

    private static func parseFlagstat(_ output: String) -> (Int, Int) {
        var totalReads = 0
        var mappedReads = 0

        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.contains("in total") {
                totalReads = Int(trimmed.split(separator: " ").first ?? "0") ?? 0
            } else if trimmed.contains(" mapped (") && !trimmed.contains("primary mapped") {
                mappedReads = Int(trimmed.split(separator: " ").first ?? "0") ?? 0
            }
        }

        return (totalReads, mappedReads)
    }

    private func fileFormat(for url: URL) -> FileFormat {
        switch url.pathExtension.lowercased() {
        case "sam":
            return .sam
        case "bam":
            return .bam
        case "bai":
            return .unknown
        case "fastq", "fq":
            return .fastq
        case "fa", "fasta", "fna":
            return .fasta
        default:
            if url.lastPathComponent.lowercased().hasSuffix(".fastq.gz")
                || url.lastPathComponent.lowercased().hasSuffix(".fq.gz") {
                return .fastq
            }
            return .unknown
        }
    }

    private func toolVersionString(_ version: String, tool: NativeTool) -> String {
        "\(version) (\(runtimeIdentity(for: tool)))"
    }

    private func condaToolVersionString(
        _ version: String,
        environment: String,
        executableName: String
    ) -> String {
        "\(version) (\(condaRuntimeIdentity(environment: environment, executableName: executableName)))"
    }

    private func condaRuntimeIdentity(environment: String, executableName: String) -> String {
        "managed conda environment \(environment); executable \(executableName); root \(condaManager.rootPrefix.path)"
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

    private func nonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : value
    }

    private func combinedStderr(_ values: [String?]) -> String? {
        let combined = values
            .compactMap { $0 }
            .compactMap(nonEmpty)
            .joined(separator: "\n")
        return combined.isEmpty ? nil : combined
    }

    private func excludedFlags(
        includeSecondary: Bool,
        includeSupplementary: Bool
    ) -> Int {
        var flags = 0
        if !includeSecondary {
            flags |= 0x100
        }
        if !includeSupplementary {
            flags |= 0x800
        }
        return flags
    }

    private static func derivedSampleName(from rawAlignmentURL: URL) -> String {
        var name = rawAlignmentURL.deletingPathExtension().lastPathComponent
        let suffixes = [".raw", ".unsorted", ".sorted"]
        for suffix in suffixes where name.hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count))
            break
        }
        return name
    }
}

private struct MappingTimedNativeToolResult {
    let result: NativeToolResult
    let step: StepExecution
}

private struct MappingTimedCondaToolResult {
    let result: (stdout: String, stderr: String, exitCode: Int32)
    let step: StepExecution
}
