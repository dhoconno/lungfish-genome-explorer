// FASTQIngestionPipeline+StorageStep.swift - The Mac launcher of the portable storage step
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import os.log
import LungfishCore
import LungfishIO

private let logger = Logger(subsystem: LogSubsystem.workflow, category: "FASTQIngestionPipeline")

/// The Mac launcher of ``PortableStorageStep``. It starts every storage tool through `NativeToolRunner`, as the
/// import did before the seam, and records each accepted launch as a `StepExecution` with the managed tool's version
/// evidence, right after the launch while its files still exist.
struct NativeToolStorageLauncher: PortableToolLauncher {
    /// One accepted launch: its provenance step, the version evidence the step recorded and the launch itself.
    struct Record: Sendable {
        let step: StepExecution
        let evidence: ToolVersionEvidence
        let run: PortableToolRun
    }

    let pipeline: FASTQIngestionPipeline

    static func nativeTool(_ tool: PortableStorageTool) -> NativeTool {
        switch tool {
        case .clumpify: return .clumpify
        case .reformat: return .reformat
        case .trimGalore: return .trimGalore
        case .bgzip: return .bgzip
        case .pigz: return .pigz
        }
    }

    /// The tool name a record gives each launch, as the import named it before the seam.
    static func recordName(_ tool: PortableStorageTool) -> String {
        switch tool {
        case .clumpify: return "clumpify.sh"
        case .reformat: return "reformat.sh"
        case .trimGalore: return "trim_galore"
        case .bgzip, .pigz: return nativeTool(tool).executableName
        }
    }

    func executableURL(for tool: PortableStorageTool) async throws -> URL {
        try await pipeline.runner.toolPath(for: Self.nativeTool(tool))
    }

    func run(_ launch: PortableToolLaunch) async throws -> PortableToolOutcome {
        let tool = Self.nativeTool(launch.tool)
        // Trim Galore starts by its path with no managed environment, as the import started it before the seam, and
        // so does an executable the step names.
        var executable = launch.executable
        if executable == nil, launch.tool == .trimGalore {
            executable = try await executableURL(for: .trimGalore)
        }
        let clock = ProvenanceRunClock()
        let result: NativeToolResult
        if let executable {
            result = try await pipeline.runner.runProcess(
                executableURL: executable,
                arguments: launch.arguments,
                workingDirectory: launch.workingDirectory,
                environment: launch.environment,
                timeout: launch.timeout.isFinite ? launch.timeout : AnalysisTimeLimit.launchTimeout,
                toolName: Self.recordName(launch.tool)
            )
        } else if let standardOutput = launch.standardOutput {
            result = try await pipeline.runner.runWithFileOutput(
                tool,
                arguments: launch.arguments,
                outputFile: standardOutput,
                workingDirectory: launch.workingDirectory,
                environment: launch.environment,
                timeout: launch.timeout.isFinite ? launch.timeout : AnalysisTimeLimit.launchTimeout
            )
        } else {
            result = try await pipeline.runner.run(
                tool,
                arguments: launch.arguments,
                workingDirectory: launch.workingDirectory,
                environment: launch.environment,
                timeout: launch.timeout.isFinite ? launch.timeout : AnalysisTimeLimit.launchTimeout
            )
        }
        let completedAt = clock.now
        return PortableToolOutcome(
            exitCode: result.exitCode, isSuccess: result.isSuccess, stdout: result.stdout, stderr: result.stderr,
            startTime: clock.startedAt, endTime: completedAt
        )
    }

    func record(_ run: PortableToolRun) async -> Record {
        let tool = Self.nativeTool(run.launch.tool)
        let evidence = await pipeline.versionEvidence(for: tool)
        var command = [run.executableURL.path] + run.launch.arguments
        if let standardOutput = run.launch.standardOutput {
            command += [">", standardOutput.path]
        }
        let outcome = run.outcome
        // A Trim Galore call records the folder it wrote into and, from its report, the effective parameters and the
        // reads it read, wrote and removed.
        let outputs = run.launch.tool == .trimGalore
            ? run.outputs.map { ProvenanceRecorder.fileOrDirectoryRecord(url: $0, format: .unknown, role: .output) }
            : run.outputs.map { ProvenanceRecorder.fileRecord(url: $0, format: .fastq, role: .output) }
        let step = StepExecution(
            toolName: Self.recordName(run.launch.tool),
            toolVersion: evidence.recordedString,
            command: command,
            // A BBTools or compress launch states how its gzip was written (C4-10).
            resolvedOptions: run.report.map { FASTQIngestionPipeline.trimGaloreResolvedOptions($0) }
                ?? FASTQIngestionPipeline.storageResolvedOptions(of: run),
            inputs: run.inputs.map {
                ProvenanceRecorder.fileRecord(url: $0, format: .fastq, role: .input)
            },
            outputs: outputs,
            exitCode: outcome.exitCode,
            wallTime: outcome.endTime.timeIntervalSince(outcome.startTime),
            stderr: outcome.stderr.isEmpty ? nil : outcome.stderr,
            managedToolID: tool.managedToolID, toolVersionEvidence: evidence,
            startTime: outcome.startTime,
            endTime: outcome.endTime
        )
        return Record(step: step, evidence: evidence, run: run)
    }
}

extension PortableStorageError {
    /// The import's error for a storage failure, in the words the import showed before the seam.
    var ingestionError: FASTQIngestionError {
        switch self {
        case .storageFailed(let text):
            return .clumpifyFailed(text)
        case .outOfMemory(let tool, let arguments):
            return .outOfMemory(BBToolsOutOfMemory.message(tool: tool, arguments: arguments, optionPinsHeap: true))
        case .compressionFailed(let text):
            return .compressionFailed(text)
        case .compressorNotFound:
            return .toolNotFound("pigz or bgzip")
        case .pairedOutputVerificationFailed(let text):
            return .pairedOutputVerificationFailed(text)
        }
    }
}

extension FASTQIngestionPipeline {

    /// The storage step with the Mac's launchers, `NativeToolRunner` for the tools and `ToolProcess` for `gzip -dc`.
    var storageStep: PortableStorageStep<NativeToolStorageLauncher> {
        PortableStorageStep(
            launcher: NativeToolStorageLauncher(pipeline: self),
            childLauncher: ToolProcessChildLauncher(),
            log: { logger.info("\($0, privacy: .public)") }
        )
    }

    /// Runs `body` and gives a storage failure the import's own error.
    static func mappingStorageErrors<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as PortableStorageError {
            throw error.ingestionError
        }
    }

    /// Runs `body`, which does not wait, and gives a storage failure the import's own error.
    static func mappingStorageErrorsNow<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as PortableStorageError {
            throw error.ingestionError
        }
    }

    /// The command line a storage launch adds to the processing record, as the import wrote it before the seam.
    static func storageCommandLine(_ record: NativeToolStorageLauncher.Record) -> String {
        let launch = record.run.launch
        let line = "\(NativeToolStorageLauncher.recordName(launch.tool)) \(launch.arguments.joined(separator: " "))"
        guard let standardOutput = launch.standardOutput else { return line }
        return "\(line) > \(standardOutput.path)"
    }

    /// The compressor the Mac's storage and interleave routes write with, by what is installed in today's order,
    /// bgzip and then pigz, or nil when neither is.
    func resolveCompressor() async -> PortableCompressor? {
        let runner = self.runner
        return await PortableCompressor.firstInstalled { compressor in
            (try? await runner.toolPath(for: NativeToolStorageLauncher.nativeTool(compressor.tool))) != nil
        }
    }
}
