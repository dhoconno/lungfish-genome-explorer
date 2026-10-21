// ProvenanceRunBuilder.swift - Immutable builder for canonical provenance envelopes
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

public enum ProvenanceBuilderError: Error, LocalizedError, Sendable, Equatable {
    case missingArgv(String)
    case missingOutput(String)
    case missingRuntimeIdentity(String)
    case unreadableFile(String)
    case invalidTimeRange(String)
    case incompleteFileDescriptor(String)
    case localDescriptorRequiresURL(String)
    case invalidConsumedInputSnapshotDescriptor(String)
    case invalidRelocatedFileDescriptor(String)
    case statusContradictsExitStatus(String)
    case statusIsRunning(String)

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
        case .localDescriptorRequiresURL(let path):
            return "Local provenance file descriptor must be added from a URL so checksum and size are computed from disk: \(path)"
        case .invalidConsumedInputSnapshotDescriptor(let path):
            return "Consumed-input snapshot provenance requires an absolute local path, a complete SHA-256 checksum, and file size: \(path)"
        case .invalidRelocatedFileDescriptor(let path):
            return "Relocated provenance output does not match its staged origin file: \(path)"
        case .statusContradictsExitStatus(let workflowName):
            return "Workflow '\(workflowName)' is recorded as completed with a non-zero exit status."
        case .statusIsRunning(let workflowName):
            return "Workflow '\(workflowName)' is recorded as still running, and a record is written once its run has ended."
        }
    }
}

public struct ProvenanceRunBuilder: Sendable {
    // Internal, not private, because `ProvenanceRunBuilder+Recorded.swift` completes a run that
    // `ProvenanceRecorder` gathered from the same values.
    let workflowName: String
    let workflowVersion: String
    let toolName: String
    let toolVersion: String
    /// The kind of the tool the record names. `cli` unless the writer passes the kind of its caller (BIO-Q-A2 R2).
    let toolKind: String
    let arguments: [String]
    let durableArguments: [String]?
    let command: String?
    let provenanceOptions: ProvenanceOptions
    let inputs: [ProvenanceFileDescriptor]
    let outputs: [ProvenanceFileDescriptor]
    let runtimeIdentity: ProvenanceRuntimeIdentity?
    let provenanceSteps: [ProvenanceStep]

    public init(
        workflowName: String,
        workflowVersion: String,
        toolName: String,
        toolVersion: String,
        toolKind: String = "cli"
    ) {
        self.init(
            workflowName: workflowName,
            workflowVersion: workflowVersion,
            toolName: toolName,
            toolVersion: toolVersion,
            toolKind: toolKind,
            arguments: [],
            durableArguments: nil,
            command: nil,
            provenanceOptions: ProvenanceOptions(),
            inputs: [],
            outputs: [],
            runtimeIdentity: nil,
            provenanceSteps: []
        )
    }

    init(
        workflowName: String,
        workflowVersion: String,
        toolName: String,
        toolVersion: String,
        toolKind: String = "cli",
        arguments: [String],
        durableArguments: [String]?,
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
        self.toolKind = toolKind
        self.arguments = arguments
        self.durableArguments = durableArguments
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

    public func durableReplayArgv(_ argv: [String]?) -> Self {
        replacing(durableArguments: argv)
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

    public func input(_ descriptor: ProvenanceFileDescriptor) throws -> Self {
        try validateDescriptorCanBeAddedVerbatim(descriptor)
        return replacing(inputs: inputs + [descriptor])
    }

    /// Records a local input from a descriptor computed from bytes already
    /// consumed by the workflow. This avoids reopening a mutable path after
    /// rendering while retaining strict, complete local-file provenance.
    public func consumedInputSnapshot(
        _ descriptor: ProvenanceFileDescriptor
    ) throws -> Self {
        try validateConsumedInputSnapshotDescriptor(descriptor)
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

    public func output(_ descriptor: ProvenanceFileDescriptor) throws -> Self {
        try validateDescriptorCanBeAddedVerbatim(descriptor)
        return replacing(outputs: outputs + [descriptor])
    }

    /// Records a local output from the descriptor a step of this run took when it wrote the
    /// file, such as a staged input a batch's sample keeps, so the file is not read again. It
    /// needs what a consumed-input snapshot needs, an absolute local path, a complete SHA-256
    /// and a size.
    package func recordedOutputSnapshot(_ descriptor: ProvenanceFileDescriptor) throws -> Self {
        guard Self.isCompleteLocalSnapshot(descriptor) else {
            throw ProvenanceBuilderError.incompleteFileDescriptor(descriptor.path)
        }
        return replacing(outputs: outputs + [descriptor])
    }

    /// Adds a local output that will be atomically relocated from the descriptor's
    /// `originPath` after provenance is written. The origin must exist and match
    /// the descriptor's recorded checksum and size at the time it is added.
    public func relocatedOutput(_ descriptor: ProvenanceFileDescriptor) throws -> Self {
        try validateRelocatedOutputDescriptor(descriptor)
        return replacing(outputs: outputs + [descriptor])
    }

    public func runtime(_ runtimeIdentity: ProvenanceRuntimeIdentity) -> Self {
        replacing(runtimeIdentity: runtimeIdentity)
    }

    public func step(_ step: ProvenanceStep) -> Self {
        replacing(provenanceSteps: provenanceSteps + [step])
    }

    /// Builds the envelope.
    ///
    /// `status` says how the run ended. When it is nil the record keeps the status derived as
    /// before, from a nested legacy run or else from `exitStatus` (0 is completed, anything else
    /// failed), and a record with exit status 0 must hold an argv, an output with checksum and size,
    /// and a runtime identity. A given status replaces the derived one. `completed` needs exit
    /// status 0 and the same checks. `failed` and `cancelled` claim no result, so they skip those
    /// checks, which lets a failed or cancelled run be recorded with what it has, even when its
    /// last step exited 0. `running` is refused, because a record is written once its run has
    /// ended. The time range is checked for every status.
    public func complete(
        exitStatus: Int,
        status: RunStatus? = nil,
        stderr: String? = nil,
        startedAt: Date,
        endedAt: Date
    ) throws -> ProvenanceEnvelope {
        try complete(
            exitStatus: exitStatus,
            status: status,
            stderr: stderr,
            startedAt: startedAt,
            endedAt: endedAt,
            legacyWorkflowRun: nil
        )
    }

    public func complete(
        exitStatus: Int,
        status: RunStatus? = nil,
        stderr: String? = nil,
        startedAt: Date,
        endedAt: Date,
        legacyWorkflowRun: WorkflowRun?
    ) throws -> ProvenanceEnvelope {
        guard endedAt >= startedAt else {
            throw ProvenanceBuilderError.invalidTimeRange(workflowName)
        }
        if status == .completed, exitStatus != 0 {
            throw ProvenanceBuilderError.statusContradictsExitStatus(workflowName)
        }
        if status == .running {
            throw ProvenanceBuilderError.statusIsRunning(workflowName)
        }
        let combinedOutputs = deduplicatedOutputs()
        let claimsResult = status.map { $0 == .completed } ?? (exitStatus == 0)

        if claimsResult {
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
            tool: ProvenanceToolIdentity(name: toolName, version: toolVersion, kind: toolKind),
            argv: arguments,
            durableReplayArgv: durableArguments,
            reproducibleCommand: command,
            options: provenanceOptions,
            runtimeIdentity: runtimeIdentity ?? ProvenanceRuntimeIdentity(),
            files: combinedFiles,
            output: primaryOutput(),
            outputs: combinedOutputs,
            steps: provenanceSteps,
            wallTimeSeconds: endedAt.timeIntervalSince(startedAt),
            exitStatus: exitStatus,
            stderr: ProvenanceStderr.normalized(stderr),
            status: status,
            legacyWorkflowRun: legacyWorkflowRun
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

    private func validateDescriptorCanBeAddedVerbatim(_ descriptor: ProvenanceFileDescriptor) throws {
        if descriptor.path.contains("://"),
           URLComponents(string: descriptor.path)?.scheme?.lowercased() != "file" {
            return
        }

        if descriptorLooksLikeDirectory(descriptor),
           descriptor.checksumSHA256 != nil,
           descriptor.fileSize != nil {
            return
        }

        if descriptor.path.isEmpty || !descriptor.path.contains("://") {
            throw ProvenanceBuilderError.localDescriptorRequiresURL(descriptor.path)
        }

        throw ProvenanceBuilderError.localDescriptorRequiresURL(descriptor.path)
    }

    private func validateConsumedInputSnapshotDescriptor(
        _ descriptor: ProvenanceFileDescriptor
    ) throws {
        guard Self.isCompleteLocalSnapshot(descriptor),
              descriptor.role != .output else {
            throw ProvenanceBuilderError
                .invalidConsumedInputSnapshotDescriptor(descriptor.path)
        }
    }

    /// Whether a descriptor names a local file by its absolute path with a complete SHA-256 and
    /// a size, as the snapshot of a file the run already read or wrote must.
    private static func isCompleteLocalSnapshot(_ descriptor: ProvenanceFileDescriptor) -> Bool {
        let checksum = descriptor.checksumSHA256 ?? ""
        let isCompleteSHA256 = checksum.count == 64
            && checksum.unicodeScalars.allSatisfy {
                CharacterSet(charactersIn: "0123456789abcdefABCDEF")
                    .contains($0)
            }
        return !descriptor.path.isEmpty
            && !descriptor.path.contains("://")
            && descriptor.path.hasPrefix("/")
            && isCompleteSHA256
            && descriptor.fileSize != nil
    }

    private func validateRelocatedOutputDescriptor(_ descriptor: ProvenanceFileDescriptor) throws {
        guard !descriptor.path.isEmpty,
              !descriptor.path.contains("://"),
              let originPath = descriptor.originPath,
              !originPath.isEmpty,
              !originPath.contains("://"),
              let checksum = descriptor.checksumSHA256,
              let fileSize = descriptor.fileSize else {
            throw ProvenanceBuilderError.invalidRelocatedFileDescriptor(descriptor.path)
        }

        let originURL = URL(fileURLWithPath: originPath)
        do {
            guard FileManager.default.fileExists(atPath: originURL.path),
                  try ProvenanceFileHasher.sha256(of: originURL) == checksum,
                  try ProvenanceFileHasher.fileSize(of: originURL) == fileSize else {
                throw ProvenanceBuilderError.invalidRelocatedFileDescriptor(descriptor.path)
            }
        } catch {
            throw ProvenanceBuilderError.invalidRelocatedFileDescriptor(descriptor.path)
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
        if descriptorLooksLikeDirectory(descriptor) {
            return false
        }
        return descriptor.checksumSHA256 == nil || descriptor.fileSize == nil
    }

    private func descriptorLooksLikeDirectory(_ descriptor: ProvenanceFileDescriptor) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: descriptor.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private func replacing(
        arguments: [String]? = nil,
        durableArguments: [String]?? = nil,
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
            toolKind: toolKind,
            arguments: arguments ?? self.arguments,
            durableArguments: durableArguments ?? self.durableArguments,
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
