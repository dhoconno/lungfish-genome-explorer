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

    public init(
        bamURL: URL,
        baiURL: URL,
        totalReads: Int,
        mappedReads: Int,
        unmappedReads: Int
    ) {
        self.bamURL = bamURL
        self.baiURL = baiURL
        self.totalReads = totalReads
        self.mappedReads = mappedReads
        self.unmappedReads = unmappedReads
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
        try await prepareReferenceIndexesIfNeeded(for: prepared.request, locator: prepared.referenceLocator, progress: progress)

        let rawAlignmentURL = MappingCommandBuilder.rawAlignmentURL(for: prepared.request)
        progress?(0.1, "Running \(prepared.request.tool.displayName)...")
        try await executeMappingCommand(
            command,
            outputURL: rawAlignmentURL,
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
            removeIntermediateRawSAMOnSuccess: true
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

        let mapperVersion = await detectToolVersion(
            toolName: command.executable,
            environment: prepared.request.tool.environmentName,
            condaManager: condaManager
        )
        let samtoolsVersion = await nativeToolRunner.getToolVersion(.samtools) ?? "unknown"
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
            samtoolsVersion: samtoolsVersion
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
        removeIntermediateRawSAMOnSuccess: Bool = false
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

        if extensionLower == "sam" {
            try await samtoolsViewToBAM(
                inputURL: rawAlignmentURL,
                outputBAMURL: tempFilteredBAM,
                minimumMappingQuality: minimumMappingQuality,
                includeSecondary: includeSecondary,
                includeSupplementary: includeSupplementary
            )
            try await samtoolsSort(inputURL: tempFilteredBAM, outputBAMURL: sortedBAM, threads: sortThreads)
        } else if extensionLower == "bam", isAlreadySorted, !needsFiltering {
            if rawAlignmentURL.standardizedFileURL != sortedBAM.standardizedFileURL {
                if fm.fileExists(atPath: sortedBAM.path) {
                    try fm.removeItem(at: sortedBAM)
                }
                try fm.copyItem(at: rawAlignmentURL, to: sortedBAM)
            }
        } else if extensionLower == "bam", !needsFiltering {
            try await samtoolsSort(inputURL: rawAlignmentURL, outputBAMURL: sortedBAM, threads: sortThreads)
        } else {
            try await samtoolsViewToBAM(
                inputURL: rawAlignmentURL,
                outputBAMURL: tempFilteredBAM,
                minimumMappingQuality: minimumMappingQuality,
                includeSecondary: includeSecondary,
                includeSupplementary: includeSupplementary
            )
            try await samtoolsSort(inputURL: tempFilteredBAM, outputBAMURL: sortedBAM, threads: sortThreads)
        }

        try await samtoolsIndex(bamURL: sortedBAM)
        let (totalReads, mappedReads) = try await samtoolsFlagstatCounts(bamURL: sortedBAM)
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
            unmappedReads: max(0, totalReads - mappedReads)
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
            let installed = await condaManager.isToolInstalled(request.tool.executableName)
            guard installed else {
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
        progress: ProgressHandler?
    ) async throws {
        switch request.tool {
        case .bwaMem2:
            progress?(0.02, "Building BWA-MEM2 index...")
            try FileManager.default.createDirectory(
                at: locator.indexPrefixURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let result = try await condaManager.runTool(
                name: "bwa-mem2",
                arguments: ["index", "-p", locator.indexPrefixURL.path, locator.referenceURL.path],
                environment: request.tool.environmentName,
                workingDirectory: request.outputDirectory,
                timeout: 24 * 3_600
            )
            guard result.exitCode == 0 else {
                throw ManagedMappingPipelineError.executionFailed(
                    tool: request.tool.displayName,
                    exitCode: result.exitCode,
                    detail: result.stderr
                )
            }
        case .bowtie2:
            progress?(0.02, "Building Bowtie2 index...")
            try FileManager.default.createDirectory(
                at: locator.indexPrefixURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let result = try await condaManager.runTool(
                name: "bowtie2-build",
                arguments: [locator.referenceURL.path, locator.indexPrefixURL.path],
                environment: request.tool.environmentName,
                workingDirectory: request.outputDirectory,
                timeout: 24 * 3_600
            )
            guard result.exitCode == 0 else {
                throw ManagedMappingPipelineError.executionFailed(
                    tool: "bowtie2-build",
                    exitCode: result.exitCode,
                    detail: result.stderr
                )
            }
        case .minimap2, .bbmap:
            break
        }
    }

    private func executeMappingCommand(
        _ command: ManagedMappingCommand,
        outputURL: URL,
        progress: ProgressHandler?
    ) async throws {
        if let nativeTool = command.nativeTool {
            let result = try await nativeToolRunner.run(
                nativeTool,
                arguments: command.arguments,
                workingDirectory: command.workingDirectory,
                timeout: 24 * 3_600
            )
            guard result.exitCode == 0 else {
                throw ManagedMappingPipelineError.executionFailed(
                    tool: command.executable,
                    exitCode: result.exitCode,
                    detail: result.stderr
                )
            }
            return
        }

        guard let environment = command.environment else {
            throw ManagedMappingPipelineError.stagingFailed("Missing environment for \(command.executable).")
        }

        if command.executable == "bwa-mem2" {
            progress?(0.15, "Streaming bwa-mem2 SAM output...")
            let result = try await runCondaToolStreamingStdout(
                executable: command.executable,
                arguments: command.arguments,
                environment: environment,
                workingDirectory: command.workingDirectory,
                stdoutURL: outputURL,
                timeout: 24 * 3_600
            )
            guard result.exitCode == 0 else {
                throw ManagedMappingPipelineError.executionFailed(
                    tool: command.executable,
                    exitCode: result.exitCode,
                    detail: result.stderr
                )
            }
            return
        }

        let result = try await condaManager.runTool(
            name: command.executable,
            arguments: command.arguments,
            environment: environment,
            workingDirectory: command.workingDirectory,
            timeout: 24 * 3_600
        )
        guard result.exitCode == 0 else {
            throw ManagedMappingPipelineError.executionFailed(
                tool: command.executable,
                exitCode: result.exitCode,
                detail: result.stderr
            )
        }
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
        includeSupplementary: Bool
    ) async throws {
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

        let result = try await nativeToolRunner.run(
            .samtools,
            arguments: arguments,
            workingDirectory: outputBAMURL.deletingLastPathComponent(),
            timeout: 3_600
        )
        guard result.isSuccess else {
            throw ManagedMappingPipelineError.normalizationFailed(result.stderr)
        }
    }

    private func samtoolsSort(
        inputURL: URL,
        outputBAMURL: URL,
        threads: Int
    ) async throws {
        let result = try await nativeToolRunner.run(
            .samtools,
            arguments: ["sort", "-@", String(max(1, threads)), "-o", outputBAMURL.path, inputURL.path],
            workingDirectory: outputBAMURL.deletingLastPathComponent(),
            timeout: 3_600
        )
        guard result.isSuccess else {
            throw ManagedMappingPipelineError.normalizationFailed(result.stderr)
        }
    }

    private func samtoolsIndex(bamURL: URL) async throws {
        let result = try await nativeToolRunner.run(
            .samtools,
            arguments: ["index", bamURL.path],
            workingDirectory: bamURL.deletingLastPathComponent(),
            timeout: 600
        )
        guard result.isSuccess else {
            throw ManagedMappingPipelineError.normalizationFailed(result.stderr)
        }
    }

    private func samtoolsFlagstatCounts(bamURL: URL) async throws -> (Int, Int) {
        let result = try await nativeToolRunner.run(
            .samtools,
            arguments: ["flagstat", bamURL.path],
            workingDirectory: bamURL.deletingLastPathComponent(),
            timeout: 300
        )
        guard result.isSuccess else {
            throw ManagedMappingPipelineError.normalizationFailed(result.stderr)
        }
        return Self.parseFlagstat(result.stdout)
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
