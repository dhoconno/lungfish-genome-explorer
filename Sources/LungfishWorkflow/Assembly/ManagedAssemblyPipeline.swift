// ManagedAssemblyPipeline.swift - Micromamba-backed multi-assembler execution
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

public struct ManagedAssemblyCommand: Sendable, Equatable {
    public let executable: String
    public let arguments: [String]
    public let environment: String
    public let workingDirectory: URL

    public init(
        executable: String,
        arguments: [String],
        environment: String,
        workingDirectory: URL
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
    }

    public var shellCommand: String {
        ([executable] + arguments).map(shellEscape).joined(separator: " ")
    }
}

public enum ManagedAssemblyPipelineError: Error, LocalizedError {
    case incompatibleSelection(String)
    case unsupportedInputTopology(String)

    public var errorDescription: String? {
        switch self {
        case .incompatibleSelection(let message):
            return message
        case .unsupportedInputTopology(let message):
            return message
        }
    }
}

public struct ManagedAssemblyPipeline: Sendable {
    public typealias ProgressHandler = @Sendable (Double, String) -> Void

    private let condaManager: CondaManager

    public init(condaManager: CondaManager = .shared) {
        self.condaManager = condaManager
    }

    public static func buildCommand(for request: AssemblyRunRequest) throws -> ManagedAssemblyCommand {
        guard AssemblyCompatibility.isSupported(tool: request.tool, for: request.readType) else {
            throw ManagedAssemblyPipelineError.incompatibleSelection(
                "\(request.tool.displayName) is not available for \(request.readType.displayName) in v1."
            )
        }

        try FileManager.default.createDirectory(
            at: request.outputDirectory.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        switch request.tool {
        case .spades:
            return try buildSpadesCommand(for: request)
        case .megahit:
            return try buildMegahitCommand(for: request)
        case .skesa:
            return try buildSKESACommand(for: request)
        case .flye:
            return try buildFlyeCommand(for: request)
        case .hifiasm:
            return try buildHifiasmCommand(for: request)
        }
    }

    public func run(
        request: AssemblyRunRequest,
        progress: ProgressHandler? = nil
    ) async throws -> AssemblyResult {
        let command = try Self.buildCommand(for: request)
        let start = Date()

        progress?(0, "Launching \(request.tool.displayName)...")
        let result = try await condaManager.runTool(
            name: command.executable,
            arguments: command.arguments,
            environment: command.environment,
            workingDirectory: command.workingDirectory,
            timeout: 24 * 3600,
            stderrHandler: { line in
                progress?(0.5, line)
            }
        )

        let logPath = request.outputDirectory.appendingPathComponent("assembly.log")
        let logBody = [result.stdout, result.stderr]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        if !logBody.isEmpty {
            try logBody.write(to: logPath, atomically: true, encoding: .utf8)
        }

        let version = await detectToolVersion(
            toolName: command.executable,
            environment: command.environment,
            condaManager: condaManager,
            flags: versionFlags(for: request.tool)
        )
        progress?(0.9, "Normalizing \(request.tool.displayName) output...")

        let normalizedResult = try AssemblyOutputNormalizer.normalize(
            request: request,
            primaryOutputDirectory: request.outputDirectory,
            commandLine: command.shellCommand,
            wallTimeSeconds: Date().timeIntervalSince(start),
            assemblerVersion: version == "unknown" ? nil : version
        )
        try normalizedResult.save(to: request.outputDirectory)
        return normalizedResult
    }

    private static func buildSpadesCommand(for request: AssemblyRunRequest) throws -> ManagedAssemblyCommand {
        let paired = try pairedReadsIfNeeded(for: request)
        var arguments: [String] = []
        switch request.selectedProfileID ?? "isolate" {
        case "meta":
            arguments.append("--meta")
        case "plasmid":
            arguments.append("--plasmid")
        default:
            break
        }
        if let paired {
            arguments += ["-1", paired.forward.path, "-2", paired.reverse.path]
        } else {
            for inputURL in request.inputURLs {
                arguments += ["-s", inputURL.path]
            }
        }
        arguments += ["-o", request.outputDirectory.path]
        arguments += ["--threads", "\(request.threads)"]
        if let memoryGB = request.memoryGB {
            arguments += ["--memory", "\(memoryGB)"]
        }
        arguments += request.extraArguments
        return ManagedAssemblyCommand(
            executable: "spades.py",
            arguments: arguments,
            environment: request.tool.environmentName,
            workingDirectory: request.outputDirectory.deletingLastPathComponent()
        )
    }

    private static func buildMegahitCommand(for request: AssemblyRunRequest) throws -> ManagedAssemblyCommand {
        let paired = try pairedReadsIfNeeded(for: request)
        var arguments: [String] = []
        if let paired {
            arguments += ["-1", paired.forward.path, "-2", paired.reverse.path]
        } else {
            arguments += ["-r", request.inputURLs.map(\.path).joined(separator: ",")]
        }
        arguments += ["-o", request.outputDirectory.path]
        arguments += ["--num-cpu-threads", "\(request.threads)"]
        if let minContigLength = request.minContigLength {
            arguments += ["--min-contig-len", "\(minContigLength)"]
        }
        if let selectedProfileID = request.selectedProfileID, !selectedProfileID.isEmpty {
            arguments += ["--presets", selectedProfileID]
        }
        arguments += request.extraArguments
        return ManagedAssemblyCommand(
            executable: "megahit",
            arguments: arguments,
            environment: request.tool.environmentName,
            workingDirectory: request.outputDirectory.deletingLastPathComponent()
        )
    }

    private static func buildSKESACommand(for request: AssemblyRunRequest) throws -> ManagedAssemblyCommand {
        try FileManager.default.createDirectory(
            at: request.outputDirectory,
            withIntermediateDirectories: true
        )
        let paired = try pairedReadsIfNeeded(for: request)
        let readsArgument = paired.map { "\($0.forward.path),\($0.reverse.path)" }
            ?? request.inputURLs.map(\.path).joined(separator: ",")
        var arguments: [String] = [
            "--reads", readsArgument,
            "--contigs_out", request.outputDirectory.appendingPathComponent("contigs.fasta").path,
            "--cores", "\(request.threads)",
        ]
        if let memoryGB = request.memoryGB {
            arguments += ["--memory", "\(memoryGB)"]
        }
        if let minContigLength = request.minContigLength {
            arguments += ["--min_contig", "\(minContigLength)"]
        }
        arguments += request.extraArguments
        return ManagedAssemblyCommand(
            executable: "skesa",
            arguments: arguments,
            environment: request.tool.environmentName,
            workingDirectory: request.outputDirectory
        )
    }

    private static func buildFlyeCommand(for request: AssemblyRunRequest) throws -> ManagedAssemblyCommand {
        guard request.inputURLs.count == 1, let inputURL = request.inputURLs.first else {
            throw ManagedAssemblyPipelineError.unsupportedInputTopology(
                "Flye expects a single ONT FASTQ input in v1."
            )
        }
        let readMode = request.selectedProfileID ?? "nano-hq"
        var arguments = [
            "--\(readMode)", inputURL.path,
            "--out-dir", request.outputDirectory.path,
            "--threads", "\(request.threads)",
        ]
        arguments += request.extraArguments
        return ManagedAssemblyCommand(
            executable: "flye",
            arguments: arguments,
            environment: request.tool.environmentName,
            workingDirectory: request.outputDirectory.deletingLastPathComponent()
        )
    }

    private static func buildHifiasmCommand(for request: AssemblyRunRequest) throws -> ManagedAssemblyCommand {
        guard request.inputURLs.count == 1, let inputURL = request.inputURLs.first else {
            throw ManagedAssemblyPipelineError.unsupportedInputTopology(
                "Hifiasm expects a single PacBio HiFi FASTQ input in v1."
            )
        }
        try FileManager.default.createDirectory(
            at: request.outputDirectory,
            withIntermediateDirectories: true
        )
        let outputPrefix = request.outputDirectory.appendingPathComponent(request.projectName).path
        var arguments = ["-o", outputPrefix, "-t", "\(request.threads)", inputURL.path]
        arguments += request.extraArguments
        return ManagedAssemblyCommand(
            executable: "hifiasm",
            arguments: arguments,
            environment: request.tool.environmentName,
            workingDirectory: request.outputDirectory
        )
    }

    private static func pairedReadsIfNeeded(
        for request: AssemblyRunRequest
    ) throws -> (forward: URL, reverse: URL)? {
        guard request.pairedEnd else { return nil }
        guard request.inputURLs.count == 2 else {
            throw ManagedAssemblyPipelineError.unsupportedInputTopology(
                "Paired-end assembly requests must include exactly two FASTQ inputs."
            )
        }
        return (request.inputURLs[0], request.inputURLs[1])
    }

    private func versionFlags(for tool: AssemblyTool) -> [String] {
        switch tool {
        case .spades, .megahit, .flye:
            return ["--version", "-v"]
        case .skesa:
            return ["--version", "-v"]
        case .hifiasm:
            return ["--version", "-h"]
        }
    }
}
