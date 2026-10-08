// GATKPipelineExecutor.swift - Execute GATK commands with final-location provenance
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

private struct GATKExecutedCommand {
    let command: GATKCommand
    let result: GATKCommandExecutionResult
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
        let preexistingOutputPaths = preexistingOutputPaths(for: request)
        let runClock = ProvenanceRunClock(startedAt: dateProvider())
        var executedCommands: [GATKExecutedCommand] = []
        for command in request.commands {
            let commandResult = try await runner.run(command)
            executedCommands.append(GATKExecutedCommand(command: command, result: commandResult))
            guard commandResult.isSuccess else {
                let completedAt = runClock.now
                let outputArtifacts = outputArtifactsForProvenance(request)
                removeNewOutputs(for: request, preexistingOutputPaths: preexistingOutputPaths)
                let provenanceURL: URL
                do {
                    provenanceURL = try writeProvenance(
                        request: request,
                        executedCommands: executedCommands,
                        outputArtifacts: outputArtifacts,
                        startedAt: runClock.startedAt,
                        completedAt: completedAt,
                        status: .failed
                    )
                } catch {
                    throw error
                }
                throw GATKPipelineExecutionError.commandFailed(
                    exitCode: commandResult.exitCode,
                    provenanceURL: provenanceURL
                )
            }
        }
        // VCF outputs kept in a project carry GATK's
        // ##GATKCommandLine lines; rewrite their paths before provenance
        // records the final checksums.
        for output in request.outputs where isVCFOutput(output) && fileManager.fileExists(atPath: output.url.path) {
            do {
                try await VCFHeaderPathSanitizer.sanitizeKeptVCF(at: output.url)
            } catch {
                removeNewOutputs(for: request, preexistingOutputPaths: preexistingOutputPaths)
                throw error
            }
        }
        let completedAt = runClock.now
        let outputArtifacts = outputArtifactsForProvenance(request)
        let provenanceURL: URL
        do {
            provenanceURL = try writeProvenance(
                request: request,
                executedCommands: executedCommands,
                outputArtifacts: outputArtifacts,
                startedAt: runClock.startedAt,
                completedAt: completedAt,
                status: .completed
            )
        } catch {
            removeNewOutputs(for: request, preexistingOutputPaths: preexistingOutputPaths)
            throw error
        }
        return GATKPipelineExecutionResult(
            exitCode: executedCommands.last?.result.exitCode ?? 0,
            stdout: executedCommands.map(\.result.stdout).filter { !$0.isEmpty }.joined(separator: "\n"),
            stderr: executedCommands.map(\.result.stderr).filter { !$0.isEmpty }.joined(separator: "\n"),
            provenanceURL: provenanceURL
        )
    }

    private func preexistingOutputPaths(for request: GATKPipelineExecutionRequest) -> Set<String> {
        Set(
            removableOutputArtifacts(for: request)
                .map { $0.url.standardizedFileURL.path }
                .filter { fileManager.fileExists(atPath: $0) }
        )
    }

    private func removeNewOutputs(
        for request: GATKPipelineExecutionRequest,
        preexistingOutputPaths: Set<String>
    ) {
        for output in removableOutputArtifacts(for: request) {
            let path = output.url.standardizedFileURL.path
            guard !preexistingOutputPaths.contains(path),
                  fileManager.fileExists(atPath: path) else {
                continue
            }
            try? fileManager.removeItem(at: output.url)
        }
    }

    private func writeProvenance(
        request: GATKPipelineExecutionRequest,
        executedCommands: [GATKExecutedCommand],
        outputArtifacts: [GATKFileArtifact],
        startedAt: Date,
        completedAt: Date,
        status: RunStatus
    ) throws -> URL {
        let steps = executedCommands.map { executed in
            StepExecution(
                toolName: request.toolName,
                toolVersion: request.toolVersion,
                containerImage: request.runtimeIdentity.containerImage,
                containerDigest: request.runtimeIdentity.containerDigest,
                command: [executed.command.executable] + executed.command.arguments,
                inputs: request.inputs.map { $0.fileRecord() },
                outputs: outputArtifacts.map { $0.fileRecord() },
                exitCode: executed.result.exitCode,
                wallTime: executed.result.wallTime,
                stderr: executed.result.stderr.isEmpty ? nil : executed.result.stderr,
                startTime: startedAt,
                endTime: completedAt
            )
        }
        let run = WorkflowRun(
            name: request.workflowName,
            startTime: startedAt,
            endTime: completedAt,
            status: status,
            steps: steps,
            parameters: parameters(for: request)
        )
        let provenanceURL = request.outputDirectory.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        try run.writeSidecar(to: provenanceURL)
        return provenanceURL
    }

    private func outputArtifactsForProvenance(_ request: GATKPipelineExecutionRequest) -> [GATKFileArtifact] {
        uniquedArtifacts(
            request.outputs + request.outputs.flatMap { output in
                vcfIndexArtifacts(for: output).filter { fileManager.fileExists(atPath: $0.url.path) }
            }
        )
    }

    private func removableOutputArtifacts(for request: GATKPipelineExecutionRequest) -> [GATKFileArtifact] {
        uniquedArtifacts(request.outputs + request.outputs.flatMap(vcfIndexArtifacts))
    }

    private func vcfIndexArtifacts(for output: GATKFileArtifact) -> [GATKFileArtifact] {
        guard isVCFOutput(output) else { return [] }
        let path = output.url.path
        return [".tbi", ".csi", ".idx"].map { suffix in
            GATKFileArtifact(
                url: URL(fileURLWithPath: path + suffix),
                format: .unknown,
                role: .index
            )
        }
    }

    private func isVCFOutput(_ output: GATKFileArtifact) -> Bool {
        guard output.role == .output else { return false }
        if output.format == .vcf { return true }
        let name = output.url.lastPathComponent.lowercased()
        return name.hasSuffix(".vcf") || name.hasSuffix(".vcf.gz")
    }

    private func uniquedArtifacts(_ artifacts: [GATKFileArtifact]) -> [GATKFileArtifact] {
        var seen: Set<String> = []
        return artifacts.filter { artifact in
            seen.insert(artifact.url.standardizedFileURL.path).inserted
        }
    }

    private func parameters(for request: GATKPipelineExecutionRequest) -> [String: ParameterValue] {
        var parameters: [String: ParameterValue] = [
            "toolEnvironment": .string(request.commands.map(\.environment).uniqued().joined(separator: ",")),
            "toolExecutable": .string(request.commands.map(\.executable).uniqued().joined(separator: ",")),
            "shellCommand": .string(request.commands.map(\.shellCommand).joined(separator: " && ")),
            "shellCommands": .array(request.commands.map { .string($0.shellCommand) }),
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

public extension GATKPipelineExecutor where Runner == ManagedGATKCommandRunner {
    init(
        fileManager: FileManager = .default,
        dateProvider: @escaping DateProvider = Date.init
    ) {
        self.init(
            runner: ManagedGATKCommandRunner(),
            fileManager: fileManager,
            dateProvider: dateProvider
        )
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen: Set<Element> = []
        return filter { seen.insert($0).inserted }
    }
}
