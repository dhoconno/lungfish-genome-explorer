// ProvenanceRunBuilder.swift - Immutable builder for canonical provenance envelopes
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

enum ProvenanceStderr {
    static let maxLength = 10_240
    static let truncationMarker = "\n... [truncated]"

    static func truncated(_ stderr: String?) -> String? {
        guard let stderr else {
            return nil
        }
        guard stderr.count > maxLength else {
            return stderr
        }
        return String(stderr.prefix(maxLength)) + truncationMarker
    }

    static func normalized(_ stderr: String?) -> String? {
        guard let stderr = truncated(stderr) else {
            return nil
        }
        return stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : stderr
    }
}

public enum ProvenanceBuilderError: Error, LocalizedError, Sendable, Equatable {
    case missingArgv(String)
    case missingOutput(String)
    case missingRuntimeIdentity(String)
    case unreadableFile(String)
    case invalidTimeRange(String)
    case incompleteFileDescriptor(String)

    public var errorDescription: String? {
        switch self {
        case .missingArgv(let workflowName):
            return "Workflow '\(workflowName)' produced successful scientific output without recording the exact argv."
        case .missingOutput(let workflowName):
            return "Workflow '\(workflowName)' completed successfully without recording at least one scientific output."
        case .missingRuntimeIdentity(let workflowName):
            return "Workflow '\(workflowName)' completed successfully without recording an explicit runtime identity."
        case .unreadableFile(let path):
            return "Provenance file is unreadable: \(path)"
        case .invalidTimeRange(let workflowName):
            return "Workflow '\(workflowName)' has an invalid provenance time range; endedAt is before startedAt."
        case .incompleteFileDescriptor(let path):
            return "Successful provenance file descriptor is missing checksum or file size: \(path)"
        }
    }
}

public struct ProvenanceRunBuilder: Sendable {
    private let workflowName: String
    private let workflowVersion: String
    private let toolName: String
    private let toolVersion: String
    private let arguments: [String]
    private let command: String?
    private let provenanceOptions: ProvenanceOptions
    private let inputs: [ProvenanceFileDescriptor]
    private let outputs: [ProvenanceFileDescriptor]
    private let runtimeIdentity: ProvenanceRuntimeIdentity?
    private let provenanceSteps: [ProvenanceStep]

    public init(
        workflowName: String,
        workflowVersion: String,
        toolName: String,
        toolVersion: String
    ) {
        self.init(
            workflowName: workflowName,
            workflowVersion: workflowVersion,
            toolName: toolName,
            toolVersion: toolVersion,
            arguments: [],
            command: nil,
            provenanceOptions: ProvenanceOptions(),
            inputs: [],
            outputs: [],
            runtimeIdentity: nil,
            provenanceSteps: []
        )
    }

    private init(
        workflowName: String,
        workflowVersion: String,
        toolName: String,
        toolVersion: String,
        arguments: [String],
        command: String?,
        provenanceOptions: ProvenanceOptions,
        inputs: [ProvenanceFileDescriptor],
        outputs: [ProvenanceFileDescriptor],
        runtimeIdentity: ProvenanceRuntimeIdentity?,
        provenanceSteps: [ProvenanceStep]
    ) {
        self.workflowName = workflowName
        self.workflowVersion = workflowVersion
        self.toolName = toolName
        self.toolVersion = toolVersion
        self.arguments = arguments
        self.command = command
        self.provenanceOptions = provenanceOptions
        self.inputs = inputs
        self.outputs = outputs
        self.runtimeIdentity = runtimeIdentity
        self.provenanceSteps = provenanceSteps
    }

    public func argv(_ argv: [String]) -> Self {
        replacing(arguments: argv)
    }

    public func reproducibleCommand(_ command: String) -> Self {
        replacing(command: command)
    }

    public func options(
        explicit: [String: ParameterValue],
        defaults: [String: ParameterValue],
        resolved: [String: ParameterValue]
    ) -> Self {
        replacing(
            provenanceOptions: ProvenanceOptions(
                explicit: explicit,
                defaults: defaults,
                resolvedDefaults: resolved
            )
        )
    }

    public func input(
        _ url: URL,
        format: FileFormat? = nil,
        role: FileRole = .input
    ) throws -> Self {
        let descriptor = try fileDescriptor(url: url, format: format, role: role)
        return replacing(inputs: inputs + [descriptor])
    }

    public func output(
        _ url: URL,
        format: FileFormat? = nil,
        role: FileRole = .output
    ) throws -> Self {
        let descriptor = try fileDescriptor(url: url, format: format, role: role)
        return replacing(outputs: outputs + [descriptor])
    }

    public func runtime(_ runtimeIdentity: ProvenanceRuntimeIdentity) -> Self {
        replacing(runtimeIdentity: runtimeIdentity)
    }

    public func step(_ step: ProvenanceStep) -> Self {
        replacing(provenanceSteps: provenanceSteps + [step])
    }

    public func complete(
        exitStatus: Int,
        stderr: String? = nil,
        startedAt: Date,
        endedAt: Date
    ) throws -> ProvenanceEnvelope {
        guard endedAt >= startedAt else {
            throw ProvenanceBuilderError.invalidTimeRange(workflowName)
        }
        let combinedOutputs = deduplicatedOutputs()

        if exitStatus == 0 {
            guard arguments.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                throw ProvenanceBuilderError.missingArgv(workflowName)
            }
            guard !combinedOutputs.isEmpty else {
                throw ProvenanceBuilderError.missingOutput(workflowName)
            }
            if let incompleteDescriptor = allSuccessfulDescriptors().first(where: isIncompleteDescriptor) {
                throw ProvenanceBuilderError.incompleteFileDescriptor(incompleteDescriptor.path)
            }
            guard runtimeIdentity != nil else {
                throw ProvenanceBuilderError.missingRuntimeIdentity(workflowName)
            }
        }

        let combinedFiles = deduplicated(inputs + combinedOutputs + provenanceSteps.flatMap { $0.inputs + $0.outputs })

        return ProvenanceEnvelope(
            id: UUID(),
            createdAt: startedAt,
            workflowName: workflowName,
            workflowVersion: workflowVersion,
            toolName: toolName,
            toolVersion: toolVersion,
            tool: ProvenanceToolIdentity(name: toolName, version: toolVersion, kind: "cli"),
            argv: arguments,
            reproducibleCommand: command,
            options: provenanceOptions,
            runtimeIdentity: runtimeIdentity ?? ProvenanceRuntimeIdentity(),
            files: combinedFiles,
            output: primaryOutput(),
            outputs: combinedOutputs,
            steps: provenanceSteps,
            wallTimeSeconds: endedAt.timeIntervalSince(startedAt),
            exitStatus: exitStatus,
            stderr: ProvenanceStderr.normalized(stderr)
        )
    }

    private func fileDescriptor(
        url: URL,
        format: FileFormat?,
        role: FileRole
    ) throws -> ProvenanceFileDescriptor {
        do {
            return try ProvenanceFileDescriptor.file(url: url, format: format, role: role)
        } catch {
            throw ProvenanceBuilderError.unreadableFile(url.path)
        }
    }

    private func primaryOutput() -> ProvenanceFileDescriptor? {
        if let explicitOutput = outputs.first {
            return explicitOutput
        }

        for index in provenanceSteps.indices.reversed() {
            let laterInputPaths = Set(provenanceSteps.dropFirst(index + 1).flatMap { $0.inputs.map(\.path) })
            if let terminalOutput = provenanceSteps[index].outputs.first(where: { !laterInputPaths.contains($0.path) }) {
                return terminalOutput
            }
        }

        return provenanceSteps.last?.outputs.first
    }

    private func allSuccessfulDescriptors() -> [ProvenanceFileDescriptor] {
        inputs + outputs + provenanceSteps.flatMap { $0.inputs + $0.outputs }
    }

    private func isIncompleteDescriptor(_ descriptor: ProvenanceFileDescriptor) -> Bool {
        descriptor.checksumSHA256 == nil || descriptor.fileSize == nil
    }

    private func replacing(
        arguments: [String]? = nil,
        command: String?? = nil,
        provenanceOptions: ProvenanceOptions? = nil,
        inputs: [ProvenanceFileDescriptor]? = nil,
        outputs: [ProvenanceFileDescriptor]? = nil,
        runtimeIdentity: ProvenanceRuntimeIdentity?? = nil,
        provenanceSteps: [ProvenanceStep]? = nil
    ) -> Self {
        Self(
            workflowName: workflowName,
            workflowVersion: workflowVersion,
            toolName: toolName,
            toolVersion: toolVersion,
            arguments: arguments ?? self.arguments,
            command: command ?? self.command,
            provenanceOptions: provenanceOptions ?? self.provenanceOptions,
            inputs: inputs ?? self.inputs,
            outputs: outputs ?? self.outputs,
            runtimeIdentity: runtimeIdentity ?? self.runtimeIdentity,
            provenanceSteps: provenanceSteps ?? self.provenanceSteps
        )
    }

    private func deduplicatedOutputs() -> [ProvenanceFileDescriptor] {
        var seen = Set<String>()
        var result: [ProvenanceFileDescriptor] = []

        for output in outputs {
            let key = deduplicationKey(for: output)
            if seen.insert(key).inserted {
                result.append(output)
            }
        }

        var latestStepOutputByKey: [String: (order: Int, descriptor: ProvenanceFileDescriptor)] = [:]
        var order = 0
        for step in provenanceSteps {
            for output in step.outputs {
                let key = deduplicationKey(for: output)
                order += 1
                guard !seen.contains(key) else {
                    continue
                }
                latestStepOutputByKey[key] = (order, output)
            }
        }

        result.append(
            contentsOf: latestStepOutputByKey.values
                .sorted { $0.order < $1.order }
                .map(\.descriptor)
        )

        return result
    }

    private func deduplicated(_ files: [ProvenanceFileDescriptor]) -> [ProvenanceFileDescriptor] {
        var seen = Set<String>()
        var result: [ProvenanceFileDescriptor] = []
        for file in files {
            let key = deduplicationKey(for: file)
            if seen.insert(key).inserted {
                result.append(file)
            }
        }
        return result
    }

    private func deduplicationKey(for file: ProvenanceFileDescriptor) -> String {
        "\(file.role.rawValue)\u{0}\(file.path)"
    }
}
