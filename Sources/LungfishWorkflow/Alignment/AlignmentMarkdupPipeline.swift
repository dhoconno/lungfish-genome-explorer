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
    func samtoolsVersion() async -> String
}

public extension AlignmentSamtoolsRunning {
    func samtoolsVersion() async -> String {
        "unknown"
    }
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

    public func samtoolsVersion() async -> String {
        guard let result = try? await runSamtools(arguments: ["--version"], timeout: 30),
              result.isSuccess else {
            return "unknown"
        }
        return parsedSamtoolsVersion(from: result.stdout) ?? "unknown"
    }

    private func parsedSamtoolsVersion(from stdout: String) -> String? {
        guard let line = stdout
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .first(where: { $0.lowercased().hasPrefix("samtools ") }) else {
            return nil
        }
        let fields = line.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 2 else { return nil }
        return String(fields[1])
    }
}

/// Recorded command metadata for minimal derivation provenance.
public struct AlignmentCommandExecutionRecord: Sendable, Equatable {
    public let tool: String
    public let arguments: [String]
    public let inputFile: String?
    public let outputFile: String?
    public let inputDescriptor: ProvenanceFileDescriptor?
    public let outputDescriptor: ProvenanceFileDescriptor?
    public let additionalInputDescriptors: [ProvenanceFileDescriptor]
    public let toolVersion: String?
    public let exitStatus: Int?
    public let wallTimeSeconds: TimeInterval?
    public let stderr: String?
    public let startedAt: Date?
    public let completedAt: Date?

    public init(
        tool: String = "samtools",
        arguments: [String],
        inputFile: String? = nil,
        outputFile: String? = nil,
        inputDescriptor: ProvenanceFileDescriptor? = nil,
        outputDescriptor: ProvenanceFileDescriptor? = nil,
        additionalInputDescriptors: [ProvenanceFileDescriptor] = [],
        toolVersion: String? = nil,
        exitStatus: Int? = nil,
        wallTimeSeconds: TimeInterval? = nil,
        stderr: String? = nil,
        startedAt: Date? = nil,
        completedAt: Date? = nil
    ) {
        self.tool = tool
        self.arguments = arguments
        self.inputFile = inputFile
        self.outputFile = outputFile
        self.inputDescriptor = inputDescriptor
        self.outputDescriptor = outputDescriptor
        self.additionalInputDescriptors = additionalInputDescriptors
        self.toolVersion = toolVersion
        self.exitStatus = exitStatus
        self.wallTimeSeconds = wallTimeSeconds
        self.stderr = stderr
        self.startedAt = startedAt
        self.completedAt = completedAt
    }

    public var subcommand: String? {
        arguments.first
    }

    public var commandLine: String {
        ([tool] + arguments).joined(separator: " ")
    }
}

struct AlignmentNativeCommandExecution: Sendable {
    let result: NativeToolResult
    let startedAt: Date
    let completedAt: Date

    var exitStatus: Int {
        Int(result.exitCode)
    }

    var wallTimeSeconds: TimeInterval {
        completedAt.timeIntervalSince(startedAt)
    }

    var stderr: String? {
        result.stderr.isEmpty ? nil : result.stderr
    }
}

func alignmentCommandExecutionRecord(
    arguments: [String],
    inputFile: String?,
    outputFile: String?,
    toolVersion: String,
    execution: AlignmentNativeCommandExecution,
    referenceFiles: [String] = []
) throws -> AlignmentCommandExecutionRecord {
    let inputDescriptor = try inputFile.map {
        try alignmentCommandFileDescriptor(path: $0, role: .input)
    }
    let outputDescriptor = try outputFile.map {
        try alignmentCommandFileDescriptor(path: $0, role: .output)
    }
    let referenceDescriptors = try referenceFiles.map {
        try alignmentCommandFileDescriptor(path: $0, role: .reference)
    }
    return AlignmentCommandExecutionRecord(
        arguments: arguments,
        inputFile: inputFile,
        outputFile: outputFile,
        inputDescriptor: inputDescriptor,
        outputDescriptor: outputDescriptor,
        additionalInputDescriptors: referenceDescriptors,
        toolVersion: toolVersion,
        exitStatus: execution.exitStatus,
        wallTimeSeconds: execution.wallTimeSeconds,
        stderr: execution.stderr,
        startedAt: execution.startedAt,
        completedAt: execution.completedAt
    )
}

func alignmentCommandFileDescriptor(path: String, role: FileRole) throws -> ProvenanceFileDescriptor {
    try ProvenanceFileDescriptor.file(
        url: URL(fileURLWithPath: path),
        format: alignmentCommandFileFormat(path: path),
        role: role
    )
}

private func alignmentCommandFileFormat(path: String) -> FileFormat? {
    if path.hasSuffix(".bam") {
        return .bam
    }
    if path.hasSuffix(".fa")
        || path.hasSuffix(".fasta")
        || path.hasSuffix(".fna")
        || path.hasSuffix(".fa.gz")
        || path.hasSuffix(".fasta.gz")
        || path.hasSuffix(".fna.gz") {
        return .fasta
    }
    if path.hasSuffix(".db") || path.hasSuffix(".sqlite") {
        return .sqlite
    }
    if path.hasSuffix(".json") {
        return .json
    }
    return .unknown
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
        let samtoolsVersion = await samtoolsRunner.samtoolsVersion()
        let referenceFiles = referenceFastaPath.map { [$0] } ?? []

        progressHandler?(0.05, "Sorting by read name...")
        var sortNameArgs = ["sort", "-n"] + threadArguments + ["-o", intermediateFiles.nameSortedBAM.path]
        if let referenceFastaPath {
            sortNameArgs += ["--reference", referenceFastaPath]
        }
        sortNameArgs.append(inputURL.path)
        let sortNameExecution = try await runSamtoolsOrThrow(sortNameArgs, timeout: longTimeout)
        commandHistory.append(
            try alignmentCommandExecutionRecord(
                arguments: sortNameArgs,
                inputFile: inputURL.path,
                outputFile: intermediateFiles.nameSortedBAM.path,
                toolVersion: samtoolsVersion,
                execution: sortNameExecution,
                referenceFiles: referenceFiles
            )
        )

        progressHandler?(0.30, "Running fixmate...")
        var fixmateArgs = ["fixmate", "-m"]
        if let referenceFastaPath {
            fixmateArgs += ["--reference", referenceFastaPath]
        }
        fixmateArgs += [intermediateFiles.nameSortedBAM.path, intermediateFiles.fixmateBAM.path]
        let fixmateExecution = try await runSamtoolsOrThrow(fixmateArgs, timeout: longTimeout)
        commandHistory.append(
            try alignmentCommandExecutionRecord(
                arguments: fixmateArgs,
                inputFile: intermediateFiles.nameSortedBAM.path,
                outputFile: intermediateFiles.fixmateBAM.path,
                toolVersion: samtoolsVersion,
                execution: fixmateExecution,
                referenceFiles: referenceFiles
            )
        )

        progressHandler?(0.55, "Sorting by coordinate...")
        var sortCoordArgs = ["sort"] + threadArguments + ["-o", intermediateFiles.coordinateSortedBAM.path]
        if let referenceFastaPath {
            sortCoordArgs += ["--reference", referenceFastaPath]
        }
        sortCoordArgs.append(intermediateFiles.fixmateBAM.path)
        let sortCoordExecution = try await runSamtoolsOrThrow(sortCoordArgs, timeout: longTimeout)
        commandHistory.append(
            try alignmentCommandExecutionRecord(
                arguments: sortCoordArgs,
                inputFile: intermediateFiles.fixmateBAM.path,
                outputFile: intermediateFiles.coordinateSortedBAM.path,
                toolVersion: samtoolsVersion,
                execution: sortCoordExecution,
                referenceFiles: referenceFiles
            )
        )

        progressHandler?(0.78, removeDuplicates ? "Removing duplicates..." : "Marking duplicates...")
        var markdupArgs = ["markdup"]
        if removeDuplicates {
            markdupArgs.append("-r")
        }
        markdupArgs += [intermediateFiles.coordinateSortedBAM.path, outputURL.path]
        let markdupExecution = try await runSamtoolsOrThrow(markdupArgs, timeout: longTimeout)
        commandHistory.append(
            try alignmentCommandExecutionRecord(
                arguments: markdupArgs,
                inputFile: intermediateFiles.coordinateSortedBAM.path,
                outputFile: outputURL.path,
                toolVersion: samtoolsVersion,
                execution: markdupExecution
            )
        )

        progressHandler?(0.93, "Indexing output BAM...")
        let indexArgs = ["index", outputURL.path]
        let indexExecution = try await runSamtoolsOrThrow(indexArgs, timeout: 3600)
        commandHistory.append(
            try alignmentCommandExecutionRecord(
                arguments: indexArgs,
                inputFile: outputURL.path,
                outputFile: outputURL.path + ".bai",
                toolVersion: samtoolsVersion,
                execution: indexExecution
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

    private func runSamtoolsOrThrow(_ arguments: [String], timeout: TimeInterval) async throws -> AlignmentNativeCommandExecution {
        let startedAt = Date()
        let result = try await samtoolsRunner.runSamtools(arguments: arguments, timeout: timeout)
        let completedAt = Date()
        guard result.isSuccess else {
            throw AlignmentMarkdupPipelineError.samtoolsFailed(
                result.stderr.isEmpty ? "samtools exited with \(result.exitCode)" : result.stderr
            )
        }
        return AlignmentNativeCommandExecution(
            result: result,
            startedAt: startedAt,
            completedAt: completedAt
        )
    }
}
