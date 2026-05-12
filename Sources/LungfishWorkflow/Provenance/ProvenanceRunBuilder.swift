// ProvenanceRunBuilder.swift - Immutable builder for canonical provenance envelopes
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

public enum ProvenanceBuilderError: Error, LocalizedError, Sendable, Equatable {
    case missingArgv(String)
    case missingOutput(String)
    case missingRuntimeIdentity(String)
    case unreadableFile(String)
    case invalidTimeRange(String)

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
        let combinedOutputs = deduplicated(outputs + provenanceSteps.flatMap(\.outputs))

        if exitStatus == 0 {
            guard arguments.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                throw ProvenanceBuilderError.missingArgv(workflowName)
            }
            guard !combinedOutputs.isEmpty else {
                throw ProvenanceBuilderError.missingOutput(workflowName)
            }
            guard runtimeIdentity != nil else {
                throw ProvenanceBuilderError.missingRuntimeIdentity(workflowName)
            }
        }

        let combinedFiles = deduplicated(inputs + combinedOutputs + provenanceSteps.flatMap { $0.inputs + $0.outputs })
        let usefulStderr = stderr.flatMap { value -> String? in
            value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
        }

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
            stderr: usefulStderr
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

    private func deduplicated(_ files: [ProvenanceFileDescriptor]) -> [ProvenanceFileDescriptor] {
        var seen = Set<String>()
        var result: [ProvenanceFileDescriptor] = []
        for file in files {
            let key = "\(file.role.rawValue)\u{0}\(file.path)"
            if seen.insert(key).inserted {
                result.append(file)
            }
        }
        return result
    }
}
