// ManagedAssemblyPipeline.swift - Micromamba-backed multi-assembler execution
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

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
    case stagingFailed(String)
    case executionFailed(tool: String, exitCode: Int32, detail: String)

    public var errorDescription: String? {
        switch self {
        case .incompatibleSelection(let message):
            return message
        case .unsupportedInputTopology(let message):
            return message
        case .stagingFailed(let message):
            return message
        case .executionFailed(let tool, let exitCode, let detail):
            return "\(tool) failed (exit \(exitCode)): \(detail)"
        }
    }
}

private struct PreparedManagedAssemblyExecution {
    let request: AssemblyRunRequest
    let redirectRoot: URL?
}

public struct ManagedAssemblyPipeline: Sendable {
    public typealias ProgressHandler = @Sendable (Double, String) -> Void

    private let condaManager: CondaManager

    public init(condaManager: CondaManager = .shared) {
        self.condaManager = condaManager
    }

    public static func buildCommand(for request: AssemblyRunRequest) throws -> ManagedAssemblyCommand {
        try buildCommand(for: request, host: .current)
    }

    static func buildCommand(
        for request: AssemblyRunRequest,
        host: AssemblyExecutionHost
    ) throws -> ManagedAssemblyCommand {
        let request = request.normalizedForExecution(on: host)
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
        let request = request.normalizedForExecution()
        let preparedExecution = try Self.prepareExecution(for: request)
        defer {
            if let redirectRoot = preparedExecution.redirectRoot {
                try? FileManager.default.removeItem(at: redirectRoot)
            }
        }

        let command = try Self.buildCommand(for: preparedExecution.request)
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

        let logPath = preparedExecution.request.outputDirectory.appendingPathComponent("assembly.log")
        let logBody = [result.stdout, result.stderr]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        if !logBody.isEmpty {
            try logBody.write(to: logPath, atomically: true, encoding: .utf8)
        }

        if result.exitCode != 0 {
            try Self.repatriateOutputsIfNeeded(
                from: preparedExecution.request.outputDirectory,
                to: request.outputDirectory,
                redirectRoot: preparedExecution.redirectRoot
            )
            throw ManagedAssemblyPipelineError.executionFailed(
                tool: request.tool.displayName,
                exitCode: result.exitCode,
                detail: Self.failureDetail(
                    tool: request.tool,
                    outputDirectory: request.outputDirectory,
                    stdout: result.stdout,
                    stderr: result.stderr
                )
            )
        }

        let version = await detectToolVersion(
            toolName: command.executable,
            environment: command.environment,
            condaManager: condaManager,
            flags: versionFlags(for: request.tool)
        )

        try Self.repatriateOutputsIfNeeded(
            from: preparedExecution.request.outputDirectory,
            to: request.outputDirectory,
            redirectRoot: preparedExecution.redirectRoot
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
        case "isolate":
            arguments.append("--isolate")
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
        if let minContigLength = request.effectiveMinContigLength {
            arguments += ["--min-contig-len", "\(minContigLength)"]
        }
        if let selectedProfileID = request.selectedProfileID, !selectedProfileID.isEmpty {
            arguments += ["--presets", selectedProfileID]
        }
        if let memoryBytes = request.effectiveMegahitMemoryBytes {
            arguments += ["--memory", "\(memoryBytes)"]
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
        if let minContigLength = request.effectiveMinContigLength {
            arguments += ["--min_contig", "\(minContigLength)"]
        }
        if !containsArgument(named: "--min_count", in: request.extraArguments) {
            // Pin SKESA's documented default to avoid high-coverage auto-escalation
            // that can zero out small assemblies on subsets like ecoli_1K.
            arguments += ["--min_count", "2"]
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
                "Hifiasm expects a single ONT or PacBio HiFi/CCS FASTQ input in v1."
            )
        }
        try FileManager.default.createDirectory(
            at: request.outputDirectory,
            withIntermediateDirectories: true
        )
        let outputPrefix = request.outputDirectory.appendingPathComponent(request.projectName).path
        var arguments = ["-o", outputPrefix, "-t", "\(request.threads)"]
        if request.readType == .ontReads {
            arguments.insert("--ont", at: 0)
        }
        appendHifiasmProfileArguments(to: &arguments, request: request)
        arguments += request.extraArguments
        arguments.append(inputURL.path)
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

    private static func prepareExecution(
        for request: AssemblyRunRequest
    ) throws -> PreparedManagedAssemblyExecution {
        let requiresFreshOutputDirectory = toolRequiresFreshOutputDirectory(request.tool)
        let outputDirectoryAlreadyExists = FileManager.default.fileExists(atPath: request.outputDirectory.path)
        let needsRedirect = request.outputDirectory.path.contains(" ")
            || request.inputURLs.contains(where: { $0.path.contains(" ") })
            || (requiresFreshOutputDirectory && outputDirectoryAlreadyExists)
        guard needsRedirect else {
            return PreparedManagedAssemblyExecution(
                request: request,
                redirectRoot: nil
            )
        }

        let fm = FileManager.default
        let safeRoot = try ProjectTempDirectory.create(
            prefix: "managed-assembly-",
            contextURL: request.outputDirectory,
            policy: .systemOnly
        )
        guard !safeRoot.path.contains(" ") else {
            try? fm.removeItem(at: safeRoot)
            throw ManagedAssemblyPipelineError.stagingFailed(
                "Unable to create a space-free temporary assembly workspace."
            )
        }

        let stagedInputsDirectory = safeRoot.appendingPathComponent("inputs", isDirectory: true)
        let stagedOutputDirectory = safeRoot.appendingPathComponent("output", isDirectory: true)
        try fm.createDirectory(at: stagedInputsDirectory, withIntermediateDirectories: true)
        if !requiresFreshOutputDirectory {
            try fm.createDirectory(at: stagedOutputDirectory, withIntermediateDirectories: true)
        }

        let stagedInputs = try request.inputURLs.enumerated().map { index, inputURL -> URL in
            guard inputURL.path.contains(" ") else { return inputURL }
            let linkURL = stagedInputsDirectory.appendingPathComponent(
                stagedLeafName(for: inputURL, index: index)
            )
            try? fm.removeItem(at: linkURL)
            try fm.createSymbolicLink(at: linkURL, withDestinationURL: inputURL)
            return linkURL
        }

        return PreparedManagedAssemblyExecution(
            request: request
                .replacingInputURLs(with: stagedInputs)
                .replacingOutputDirectory(with: stagedOutputDirectory),
            redirectRoot: safeRoot
        )
    }

    private static func stagedLeafName(for url: URL, index: Int) -> String {
        "\(index)-\(url.lastPathComponent.replacingOccurrences(of: " ", with: "_"))"
    }

    private static func containsArgument(named flag: String, in arguments: [String]) -> Bool {
        arguments.contains(flag) || arguments.contains { $0.hasPrefix("\(flag)=") }
    }

    private static func appendHifiasmProfileArguments(
        to arguments: inout [String],
        request: AssemblyRunRequest
    ) {
        guard request.selectedProfileID == "haploid-viral" else { return }
        if !containsArgument(named: "--n-hap", in: request.extraArguments) {
            arguments += ["--n-hap", "1"]
        }
        if !request.extraArguments.contains("-l0") {
            arguments.append("-l0")
        }
        if !request.extraArguments.contains("-f0") {
            arguments.append("-f0")
        }
    }

    private static func toolRequiresFreshOutputDirectory(_ tool: AssemblyTool) -> Bool {
        switch tool {
        case .megahit:
            // MEGAHIT rejects an output directory that already exists, so project-backed
            // app runs need a staging directory even though the final analysis folder is
            // pre-created for sidebar tracking.
            return true
        case .spades, .skesa, .flye, .hifiasm:
            return false
        }
    }

    private static func repatriateOutputsIfNeeded(
        from stagedOutputDirectory: URL,
        to finalOutputDirectory: URL,
        redirectRoot: URL?
    ) throws {
        guard redirectRoot != nil else { return }

        let fm = FileManager.default
        try fm.createDirectory(at: finalOutputDirectory, withIntermediateDirectories: true)
        let contents = try fm.contentsOfDirectory(
            at: stagedOutputDirectory,
            includingPropertiesForKeys: nil,
            options: []
        )

        for item in contents {
            let destination = finalOutputDirectory.appendingPathComponent(item.lastPathComponent)
            if fm.fileExists(atPath: destination.path) {
                try fm.removeItem(at: destination)
            }
            do {
                try fm.moveItem(at: item, to: destination)
            } catch {
                try fm.copyItem(at: item, to: destination)
                try? fm.removeItem(at: item)
            }
        }
    }

    private static func failureDetail(
        tool: AssemblyTool,
        outputDirectory: URL,
        stdout: String,
        stderr: String
    ) -> String {
        if tool == .spades,
           let spadesDetail = spadesFailureDetail(
                from: outputDirectory.appendingPathComponent("spades.log")
           ) {
            return spadesDetail
        }

        return lastNonEmptyLine(in: stderr)
            ?? lastNonEmptyLine(in: stdout)
            ?? "No additional error details were reported."
    }

    private static func spadesFailureDetail(from logURL: URL) -> String? {
        guard let logBody = try? String(contentsOf: logURL, encoding: .utf8) else {
            return nil
        }

        let lines = logBody
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if let line = lines.reversed().first(where: isSpecificSPAdesErrorLine) {
            return normalizeSPAdesErrorLine(line)
        }

        for phrase in ["Exception caught", "== Error ==", "finished abnormally"] {
            if let line = lines.reversed().first(where: { $0.localizedCaseInsensitiveContains(phrase) }) {
                return line
            }
        }

        return lines.last
    }

    private static func isSpecificSPAdesErrorLine(_ line: String) -> Bool {
        guard line.localizedCaseInsensitiveContains("ERROR") else {
            return false
        }

        let excludedPhrases = [
            "== ERRORs:",
            "== Error ==",
            "finished abnormally",
            "system call for:"
        ]
        return !excludedPhrases.contains(where: { line.localizedCaseInsensitiveContains($0) })
    }

    private static func normalizeSPAdesErrorLine(_ line: String) -> String {
        let marker = ")   "
        if let range = line.range(of: marker, options: .backwards) {
            let suffix = line[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !suffix.isEmpty {
                return suffix
            }
        }
        return line.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func lastNonEmptyLine(in text: String) -> String? {
        text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .last(where: { !$0.isEmpty })
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

private extension AssemblyRunRequest {
    func replacingInputURLs(with inputURLs: [URL]) -> AssemblyRunRequest {
        AssemblyRunRequest(
            tool: tool,
            readType: readType,
            inputURLs: inputURLs,
            projectName: projectName,
            outputDirectory: outputDirectory,
            pairedEnd: pairedEnd,
            threads: threads,
            memoryGB: memoryGB,
            minContigLength: minContigLength,
            selectedProfileID: selectedProfileID,
            extraArguments: extraArguments
        )
    }

    func replacingOutputDirectory(with outputDirectory: URL) -> AssemblyRunRequest {
        AssemblyRunRequest(
            tool: tool,
            readType: readType,
            inputURLs: inputURLs,
            projectName: projectName,
            outputDirectory: outputDirectory,
            pairedEnd: pairedEnd,
            threads: threads,
            memoryGB: memoryGB,
            minContigLength: minContigLength,
            selectedProfileID: selectedProfileID,
            extraArguments: extraArguments
        )
    }
}
