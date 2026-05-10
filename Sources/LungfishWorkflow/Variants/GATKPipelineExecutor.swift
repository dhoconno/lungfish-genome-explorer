// GATKPipelineExecutor.swift - Execute GATK commands with final-location provenance
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

private final class GATKDataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func set(_ data: Data) {
        lock.lock()
        storage = data
        lock.unlock()
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

public struct GATKCommandExecutionResult: Sendable, Equatable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public let wallTime: TimeInterval

    public init(exitCode: Int32, stdout: String, stderr: String, wallTime: TimeInterval) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.wallTime = wallTime
    }

    public var isSuccess: Bool {
        exitCode == 0
    }
}

public protocol GATKCommandRunning: Sendable {
    func run(_ command: GATKCommand) async throws -> GATKCommandExecutionResult
}

public struct ProcessGATKCommandRunner: GATKCommandRunning {
    public let environment: [String: String]

    public init(environment: [String: String] = [:]) {
        self.environment = environment
    }

    public func run(_ command: GATKCommand) async throws -> GATKCommandExecutionResult {
        try await Task.detached(priority: .userInitiated) {
            try runGATKProcess(command, environment: environment)
        }.value
    }
}

private func runGATKProcess(
    _ command: GATKCommand,
    environment: [String: String]
) throws -> GATKCommandExecutionResult {
    let process = Process()
    if command.executable.contains("/") {
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
    } else {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [command.executable] + command.arguments
    }
    if let workingDirectory = command.workingDirectory {
        process.currentDirectoryURL = workingDirectory
    }
    if !environment.isEmpty {
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
    }

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    let start = Date()
    try process.run()
    let stdoutBox = GATKDataBox()
    let stderrBox = GATKDataBox()
    let drainGroup = DispatchGroup()
    drainGroup.enter()
    DispatchQueue.global(qos: .userInitiated).async {
        stdoutBox.set(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
        drainGroup.leave()
    }
    drainGroup.enter()
    DispatchQueue.global(qos: .userInitiated).async {
        stderrBox.set(stderrPipe.fileHandleForReading.readDataToEndOfFile())
        drainGroup.leave()
    }

    process.waitUntilExit()
    drainGroup.wait()
    let wallTime = Date().timeIntervalSince(start)
    let stdout = String(data: stdoutBox.data, encoding: .utf8) ?? ""
    let stderr = String(data: stderrBox.data, encoding: .utf8) ?? ""
    return GATKCommandExecutionResult(
        exitCode: process.terminationStatus,
        stdout: stdout,
        stderr: stderr,
        wallTime: wallTime
    )
}

public struct GATKFileArtifact: Sendable, Equatable {
    public let url: URL
    public let format: FileFormat?
    public let role: FileRole

    public init(url: URL, format: FileFormat? = nil, role: FileRole) {
        self.url = url
        self.format = format
        self.role = role
    }

    public func fileRecord() -> FileRecord {
        ProvenanceRecorder.fileRecord(url: url, format: format, role: role)
    }
}

public struct GATKRuntimeIdentity: Sendable, Equatable {
    public let condaEnvironment: String?
    public let containerImage: String?
    public let containerDigest: String?

    public init(
        condaEnvironment: String? = nil,
        containerImage: String? = nil,
        containerDigest: String? = nil
    ) {
        self.condaEnvironment = condaEnvironment
        self.containerImage = containerImage
        self.containerDigest = containerDigest
    }
}

public struct GATKPipelineExecutionRequest: Sendable, Equatable {
    public let workflowName: String
    public let toolName: String
    public let toolVersion: String
    public let command: GATKCommand
    public let outputDirectory: URL
    public let inputs: [GATKFileArtifact]
    public let outputs: [GATKFileArtifact]
    public let options: [String: String]
    public let resolvedDefaults: [String: String]
    public let runtimeIdentity: GATKRuntimeIdentity
    public let packID: String?
    public let packVersion: String?

    public init(
        workflowName: String,
        toolName: String,
        toolVersion: String,
        command: GATKCommand,
        outputDirectory: URL,
        inputs: [GATKFileArtifact],
        outputs: [GATKFileArtifact],
        options: [String: String],
        resolvedDefaults: [String: String],
        runtimeIdentity: GATKRuntimeIdentity = GATKRuntimeIdentity(),
        packID: String? = nil,
        packVersion: String? = nil
    ) {
        self.workflowName = workflowName
        self.toolName = toolName
        self.toolVersion = toolVersion
        self.command = command
        self.outputDirectory = outputDirectory
        self.inputs = inputs
        self.outputs = outputs
        self.options = options
        self.resolvedDefaults = resolvedDefaults
        self.runtimeIdentity = runtimeIdentity
        self.packID = packID
        self.packVersion = packVersion
    }
}

public extension GATKPipelineExecutionRequest {
    static func haplotypeCaller(
        configuration: GATKHaplotypeCallerConfiguration,
        toolVersion: String,
        runtimeIdentity: GATKRuntimeIdentity = GATKRuntimeIdentity(),
        packID: String? = "gatk-core",
        packVersion: String? = nil
    ) -> GATKPipelineExecutionRequest {
        let command = GATKCommandBuilder.haplotypeCallerCommand(configuration)
        var inputs = [
            GATKFileArtifact(url: configuration.referenceFASTAURL, format: .fasta, role: .reference),
            GATKFileArtifact(url: configuration.inputBAMURL, format: .bam, role: .input),
        ]
        if let intervalsURL = configuration.intervalsURL {
            inputs.append(GATKFileArtifact(url: intervalsURL, role: .input))
        }
        return GATKPipelineExecutionRequest(
            workflowName: "GATK HaplotypeCaller",
            toolName: "gatk-haplotype-caller",
            toolVersion: toolVersion,
            command: command,
            outputDirectory: configuration.outputVCFURL.deletingLastPathComponent(),
            inputs: inputs,
            outputs: [GATKFileArtifact(url: configuration.outputVCFURL, format: .vcf, role: .output)],
            options: [
                "emitReferenceConfidence": configuration.emitReferenceConfidence.rawValue,
                "ploidy": String(configuration.ploidy),
                "pcrIndelModel": configuration.pcrIndelModel,
                "standardMinConfidenceThresholdForCalling": format(configuration.standardMinConfidenceThresholdForCalling),
                "maxAlternateAlleles": String(configuration.maxAlternateAlleles),
                "nativePairHMMThreads": String(configuration.nativePairHMMThreads),
                "extraArguments": jsonArrayString(configuration.extraArguments),
            ],
            resolvedDefaults: [
                "emitReferenceConfidence": GATKEmitReferenceConfidence.gvcf.rawValue,
                "ploidy": "2",
                "pcrIndelModel": "CONSERVATIVE",
                "standardMinConfidenceThresholdForCalling": "30.0",
                "maxAlternateAlleles": "6",
                "nativePairHMMThreads": "4",
                "extraArguments": "[]",
            ],
            runtimeIdentity: runtimeIdentity,
            packID: packID,
            packVersion: packVersion
        )
    }
}

public struct GATKPipelineExecutionResult: Sendable, Equatable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public let provenanceURL: URL
}

public enum GATKPipelineExecutionError: Error, LocalizedError, Equatable {
    case commandFailed(exitCode: Int32, provenanceURL: URL)

    public var errorDescription: String? {
        switch self {
        case .commandFailed(let exitCode, let provenanceURL):
            return "GATK command failed with exit code \(exitCode). Provenance was written to \(provenanceURL.path)."
        }
    }
}

public struct GATKPipelineExecutor<Runner: GATKCommandRunning> {
    public typealias DateProvider = @Sendable () -> Date

    private let runner: Runner
    private let dateProvider: DateProvider
    private let fileManager: FileManager

    public init(
        runner: Runner,
        fileManager: FileManager = .default,
        dateProvider: @escaping DateProvider = Date.init
    ) {
        self.runner = runner
        self.fileManager = fileManager
        self.dateProvider = dateProvider
    }

    public func run(_ request: GATKPipelineExecutionRequest) async throws -> GATKPipelineExecutionResult {
        try fileManager.createDirectory(at: request.outputDirectory, withIntermediateDirectories: true)
        let startedAt = dateProvider()
        let commandResult = try await runner.run(request.command)
        let completedAt = dateProvider()
        let status: RunStatus = commandResult.isSuccess ? .completed : .failed
        let provenanceURL = try writeProvenance(
            request: request,
            commandResult: commandResult,
            startedAt: startedAt,
            completedAt: completedAt,
            status: status
        )
        let result = GATKPipelineExecutionResult(
            exitCode: commandResult.exitCode,
            stdout: commandResult.stdout,
            stderr: commandResult.stderr,
            provenanceURL: provenanceURL
        )
        guard commandResult.isSuccess else {
            throw GATKPipelineExecutionError.commandFailed(
                exitCode: commandResult.exitCode,
                provenanceURL: provenanceURL
            )
        }
        return result
    }

    private func writeProvenance(
        request: GATKPipelineExecutionRequest,
        commandResult: GATKCommandExecutionResult,
        startedAt: Date,
        completedAt: Date,
        status: RunStatus
    ) throws -> URL {
        let step = StepExecution(
            toolName: request.toolName,
            toolVersion: request.toolVersion,
            containerImage: request.runtimeIdentity.containerImage,
            containerDigest: request.runtimeIdentity.containerDigest,
            command: [request.command.executable] + request.command.arguments,
            inputs: request.inputs.map { $0.fileRecord() },
            outputs: request.outputs.map { $0.fileRecord() },
            exitCode: commandResult.exitCode,
            wallTime: commandResult.wallTime,
            stderr: commandResult.stderr.isEmpty ? nil : commandResult.stderr,
            startTime: startedAt,
            endTime: completedAt
        )
        let run = WorkflowRun(
            name: request.workflowName,
            startTime: startedAt,
            endTime: completedAt,
            status: status,
            steps: [step],
            parameters: parameters(for: request)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let provenanceURL = request.outputDirectory.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        try encoder.encode(run).write(to: provenanceURL, options: .atomic)
        return provenanceURL
    }

    private func parameters(for request: GATKPipelineExecutionRequest) -> [String: ParameterValue] {
        var parameters: [String: ParameterValue] = [
            "toolEnvironment": .string(request.command.environment),
            "toolExecutable": .string(request.command.executable),
            "shellCommand": .string(request.command.shellCommand),
        ]
        if let packID = request.packID {
            parameters["packID"] = .string(packID)
        }
        if let packVersion = request.packVersion {
            parameters["packVersion"] = .string(packVersion)
        }
        if let condaEnvironment = request.runtimeIdentity.condaEnvironment {
            parameters["condaEnvironment"] = .string(condaEnvironment)
        }
        if let containerImage = request.runtimeIdentity.containerImage {
            parameters["containerImage"] = .string(containerImage)
        }
        if let containerDigest = request.runtimeIdentity.containerDigest {
            parameters["containerDigest"] = .string(containerDigest)
        }
        for (key, value) in request.options {
            parameters["option.\(key)"] = .string(value)
        }
        for (key, value) in request.resolvedDefaults {
            parameters["default.\(key)"] = .string(value)
        }
        return parameters
    }
}

public extension GATKPipelineExecutor where Runner == ProcessGATKCommandRunner {
    init(
        fileManager: FileManager = .default,
        dateProvider: @escaping DateProvider = Date.init
    ) {
        self.init(
            runner: ProcessGATKCommandRunner(),
            fileManager: fileManager,
            dateProvider: dateProvider
        )
    }
}

private func format(_ value: Double) -> String {
    String(format: "%.1f", value)
}

private func jsonArrayString(_ values: [String]) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: values),
          let string = String(data: data, encoding: .utf8) else {
        return "[]"
    }
    return string
}
