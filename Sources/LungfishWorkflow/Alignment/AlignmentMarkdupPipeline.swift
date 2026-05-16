// AlignmentMarkdupPipeline.swift - Shared samtools markdup workflow helper
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import os.log

private let markdupLogger = Logger(subsystem: LogSubsystem.workflow, category: "AlignmentMarkdupPipeline")

/// Errors thrown while executing the shared markdup workflow.
public enum AlignmentMarkdupPipelineError: Error, LocalizedError, Sendable, Equatable {
    case samtoolsFailed(String)

    public var errorDescription: String? {
        switch self {
        case .samtoolsFailed(let message):
            return "samtools duplicate workflow failed: \(message)"
        }
    }
}

/// Injectable samtools runner used by alignment derivation services.
public protocol AlignmentSamtoolsRunning: Sendable {
    func runSamtools(arguments: [String], timeout: TimeInterval) async throws -> NativeToolResult
}

/// NativeToolRunner-backed samtools runner used in production code.
public actor NativeToolSamtoolsRunner: AlignmentSamtoolsRunning {
    public static let shared = NativeToolSamtoolsRunner()

    private let runner: NativeToolRunner

    public init(runner: NativeToolRunner = .shared) {
        self.runner = runner
    }

    public func runSamtools(arguments: [String], timeout: TimeInterval) async throws -> NativeToolResult {
        try await runner.run(.samtools, arguments: arguments, timeout: timeout)
    }
}

/// Recorded command metadata for minimal derivation provenance.
public struct AlignmentCommandExecutionRecord: Sendable, Equatable {
    public let tool: String
    public let arguments: [String]
    public let inputFile: String?
    public let outputFile: String?

    public init(
        tool: String = "samtools",
        arguments: [String],
        inputFile: String? = nil,
        outputFile: String? = nil
    ) {
        self.tool = tool
        self.arguments = arguments
        self.inputFile = inputFile
        self.outputFile = outputFile
    }

    public var subcommand: String? {
        arguments.first
    }

    public var commandLine: String {
        ([tool] + arguments).joined(separator: " ")
    }
}

/// Intermediate BAMs produced by the canonical markdup workflow.
public struct AlignmentMarkdupIntermediateFiles: Sendable, Equatable {
    public let nameSortedBAM: URL
    public let fixmateBAM: URL
    public let coordinateSortedBAM: URL

    public init(nameSortedBAM: URL, fixmateBAM: URL, coordinateSortedBAM: URL) {
        self.nameSortedBAM = nameSortedBAM
        self.fixmateBAM = fixmateBAM
        self.coordinateSortedBAM = coordinateSortedBAM
    }
}

/// Result of running the shared markdup helper.
public struct AlignmentMarkdupPipelineResult: Sendable, Equatable {
    public let outputURL: URL
    public let indexURL: URL
    public let intermediateFiles: AlignmentMarkdupIntermediateFiles
    public let commandHistory: [AlignmentCommandExecutionRecord]

    public init(
        outputURL: URL,
        indexURL: URL,
        intermediateFiles: AlignmentMarkdupIntermediateFiles,
        commandHistory: [AlignmentCommandExecutionRecord]
    ) {
        self.outputURL = outputURL
        self.indexURL = indexURL
        self.intermediateFiles = intermediateFiles
        self.commandHistory = commandHistory
    }
}

/// Abstraction for the shared markdup pipeline.
public protocol AlignmentMarkdupPipelining: Sendable {
    func run(
        inputURL: URL,
        outputURL: URL,
        removeDuplicates: Bool,
        referenceFastaPath: String?,
        progressHandler: (@Sendable (Double, String) -> Void)?
    ) async throws -> AlignmentMarkdupPipelineResult
}

/// Canonical `samtools sort/fixmate/markdup/index` pipeline shared by alignment services.
public struct AlignmentMarkdupPipeline: AlignmentMarkdupPipelining, Sendable {
    private let samtoolsRunner: any AlignmentSamtoolsRunning

    public init(samtoolsRunner: any AlignmentSamtoolsRunning = NativeToolSamtoolsRunner.shared) {
        self.samtoolsRunner = samtoolsRunner
    }

    public func run(
        inputURL: URL,
        outputURL: URL,
        removeDuplicates: Bool,
        referenceFastaPath: String?,
        progressHandler: (@Sendable (Double, String) -> Void)?
    ) async throws -> AlignmentMarkdupPipelineResult {
        try await run(
            inputURL: inputURL,
            outputURL: outputURL,
            removeDuplicates: removeDuplicates,
            referenceFastaPath: referenceFastaPath,
            sortThreads: nil,
            progressHandler: progressHandler
        )
    }

    public func run(
        inputURL: URL,
        outputURL: URL,
        removeDuplicates: Bool,
        referenceFastaPath: String?,
        sortThreads: Int?,
        progressHandler: (@Sendable (Double, String) -> Void)?
    ) async throws -> AlignmentMarkdupPipelineResult {
        let outputDir = outputURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let tempDir = outputDir.appendingPathComponent(".markdup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let intermediateFiles = AlignmentMarkdupIntermediateFiles(
            nameSortedBAM: tempDir.appendingPathComponent("name.sorted.bam"),
            fixmateBAM: tempDir.appendingPathComponent("fixmate.bam"),
            coordinateSortedBAM: tempDir.appendingPathComponent("coord.sorted.bam")
        )

        let size = (try? FileManager.default.attributesOfItem(atPath: inputURL.path)[.size] as? Int64) ?? 0
        let longTimeout = max(600.0, Double(size) / 10_000_000.0)
        var commandHistory: [AlignmentCommandExecutionRecord] = []
        let threadArguments = sortThreads.map { ["-@", String(max(1, $0))] } ?? []

        progressHandler?(0.05, "Sorting by read name...")
        var sortNameArgs = ["sort", "-n"] + threadArguments + ["-o", intermediateFiles.nameSortedBAM.path]
        if let referenceFastaPath {
            sortNameArgs += ["--reference", referenceFastaPath]
        }
        sortNameArgs.append(inputURL.path)
        try await runSamtoolsOrThrow(sortNameArgs, timeout: longTimeout)
        commandHistory.append(
            AlignmentCommandExecutionRecord(
                arguments: sortNameArgs,
                inputFile: inputURL.path,
                outputFile: intermediateFiles.nameSortedBAM.path
            )
        )

        progressHandler?(0.30, "Running fixmate...")
        var fixmateArgs = ["fixmate", "-m"]
        if let referenceFastaPath {
            fixmateArgs += ["--reference", referenceFastaPath]
        }
        fixmateArgs += [intermediateFiles.nameSortedBAM.path, intermediateFiles.fixmateBAM.path]
        try await runSamtoolsOrThrow(fixmateArgs, timeout: longTimeout)
        commandHistory.append(
            AlignmentCommandExecutionRecord(
                arguments: fixmateArgs,
                inputFile: intermediateFiles.nameSortedBAM.path,
                outputFile: intermediateFiles.fixmateBAM.path
            )
        )

        progressHandler?(0.55, "Sorting by coordinate...")
        var sortCoordArgs = ["sort"] + threadArguments + ["-o", intermediateFiles.coordinateSortedBAM.path]
        if let referenceFastaPath {
            sortCoordArgs += ["--reference", referenceFastaPath]
        }
        sortCoordArgs.append(intermediateFiles.fixmateBAM.path)
        try await runSamtoolsOrThrow(sortCoordArgs, timeout: longTimeout)
        commandHistory.append(
            AlignmentCommandExecutionRecord(
                arguments: sortCoordArgs,
                inputFile: intermediateFiles.fixmateBAM.path,
                outputFile: intermediateFiles.coordinateSortedBAM.path
            )
        )

        progressHandler?(0.78, removeDuplicates ? "Removing duplicates..." : "Marking duplicates...")
        var markdupArgs = ["markdup"]
        if removeDuplicates {
            markdupArgs.append("-r")
        }
        markdupArgs += [intermediateFiles.coordinateSortedBAM.path, outputURL.path]
        try await runSamtoolsOrThrow(markdupArgs, timeout: longTimeout)
        commandHistory.append(
            AlignmentCommandExecutionRecord(
                arguments: markdupArgs,
                inputFile: intermediateFiles.coordinateSortedBAM.path,
                outputFile: outputURL.path
            )
        )

        progressHandler?(0.93, "Indexing output BAM...")
        let indexArgs = ["index", outputURL.path]
        try await runSamtoolsOrThrow(indexArgs, timeout: 3600)
        commandHistory.append(
            AlignmentCommandExecutionRecord(
                arguments: indexArgs,
                inputFile: outputURL.path,
                outputFile: outputURL.path + ".bai"
            )
        )

        progressHandler?(1.0, "Done")
        markdupLogger.info("Completed markdup pipeline for \(outputURL.lastPathComponent, privacy: .public)")

        return AlignmentMarkdupPipelineResult(
            outputURL: outputURL,
            indexURL: URL(fileURLWithPath: outputURL.path + ".bai"),
            intermediateFiles: intermediateFiles,
            commandHistory: commandHistory
        )
    }

    private func runSamtoolsOrThrow(_ arguments: [String], timeout: TimeInterval) async throws {
        let result = try await samtoolsRunner.runSamtools(arguments: arguments, timeout: timeout)
        guard result.isSuccess else {
            throw AlignmentMarkdupPipelineError.samtoolsFailed(
                result.stderr.isEmpty ? "samtools exited with \(result.exitCode)" : result.stderr
            )
        }
    }
}
