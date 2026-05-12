// ProvenanceRecord.swift - Provenance data model for reproducibility tracking
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - WorkflowRun

/// A complete record of a multi-step workflow execution.
///
/// `WorkflowRun` captures everything needed to reproduce an analysis:
/// tool versions, container digests, exact commands, input/output checksums,
/// and the dependency DAG between steps. It serves as the source of truth
/// from which Nextflow, Snakemake, shell, and Python scripts are generated.
public struct WorkflowRun: Codable, Sendable, Identifiable, Equatable {
    /// Unique identifier for this run.
    public let id: UUID

    /// Human-readable name (e.g., "VCF Import", "SPAdes Assembly").
    public let name: String

    /// When the run started.
    public let startTime: Date

    /// When the run completed (nil if still running or failed).
    public var endTime: Date?

    /// Final status of the run.
    public var status: RunStatus

    /// Lungfish app version that performed this run.
    public let appVersion: String

    /// Host OS description (e.g., "macOS 26.1 (arm64)").
    public let hostOS: String

    /// Runtime identity for audit and reproducibility.
    public let runtime: WorkflowRuntime

    /// Ordered list of execution steps.
    public var steps: [StepExecution]

    /// Top-level parameters the user configured (workflow-level, not per-step).
    public var parameters: [String: ParameterValue]

    public init(
        id: UUID = UUID(),
        name: String,
        startTime: Date = Date(),
        endTime: Date? = nil,
        status: RunStatus = .running,
        appVersion: String = Self.currentAppVersion,
        hostOS: String = Self.currentHostOS,
        runtime: WorkflowRuntime? = nil,
        steps: [StepExecution] = [],
        parameters: [String: ParameterValue] = [:]
    ) {
        self.id = id
        self.name = name
        self.startTime = startTime
        self.endTime = endTime
        self.status = status
        self.appVersion = appVersion
        self.hostOS = hostOS
        self.runtime = runtime ?? WorkflowRuntime(appVersion: appVersion, hostOS: hostOS, user: Self.currentUser)
        self.steps = steps
        self.parameters = parameters
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case startTime
        case endTime
        case status
        case appVersion
        case hostOS
        case runtime
        case steps
        case parameters
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        startTime = try container.decode(Date.self, forKey: .startTime)
        endTime = try container.decodeIfPresent(Date.self, forKey: .endTime)
        status = try container.decode(RunStatus.self, forKey: .status)
        appVersion = try container.decode(String.self, forKey: .appVersion)
        hostOS = try container.decode(String.self, forKey: .hostOS)
        runtime = try container.decodeIfPresent(WorkflowRuntime.self, forKey: .runtime)
            ?? WorkflowRuntime(appVersion: appVersion, hostOS: hostOS, user: nil)
        steps = try container.decode([StepExecution].self, forKey: .steps)
        parameters = try container.decode([String: ParameterValue].self, forKey: .parameters)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(startTime, forKey: .startTime)
        try container.encodeIfPresent(endTime, forKey: .endTime)
        try container.encode(status, forKey: .status)
        try container.encode(appVersion, forKey: .appVersion)
        try container.encode(hostOS, forKey: .hostOS)
        try container.encode(runtime, forKey: .runtime)
        try container.encode(steps, forKey: .steps)
        try container.encode(parameters, forKey: .parameters)
    }

    /// Total wall-clock time for the entire run.
    public var wallTime: TimeInterval? {
        guard let end = endTime else { return nil }
        return end.timeIntervalSince(startTime)
    }

    /// All output files produced by any step in this run.
    public var allOutputFiles: [FileRecord] {
        steps.flatMap(\.outputs)
    }

    /// All input files consumed by the first steps (no upstream dependency).
    public var primaryInputFiles: [FileRecord] {
        let stepsWithNoDeps = steps.filter(\.dependsOn.isEmpty)
        return stepsWithNoDeps.flatMap(\.inputs)
    }

    // MARK: - System Info Helpers

    public static var currentAppVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "Lungfish \(version) (\(build))"
    }

    public static var currentHostOS: String {
        let info = ProcessInfo.processInfo
        let os = info.operatingSystemVersion
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        return "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion) (\(arch))"
    }

    public static var currentUser: String {
        let nsUser = NSUserName()
        if !nsUser.isEmpty { return nsUser }
        let env = ProcessInfo.processInfo.environment
        if let user = env["USER"], !user.isEmpty { return user }
        if let logname = env["LOGNAME"], !logname.isEmpty { return logname }
        return "unknown"
    }
}

// MARK: - WorkflowRuntime

/// Runtime identity captured for a workflow execution.
public struct WorkflowRuntime: Codable, Sendable, Equatable {
    /// Lungfish app version that performed this run.
    public let appVersion: String

    /// Host OS description (e.g., "macOS 26.1 (arm64)").
    public let hostOS: String

    /// OS user account that ran the operation.
    public let user: String?

    public init(appVersion: String, hostOS: String, user: String?) {
        self.appVersion = appVersion
        self.hostOS = hostOS
        self.user = user
    }
}

// MARK: - RunStatus

/// Status of a workflow run.
public enum RunStatus: String, Codable, Sendable, Equatable {
    case running
    case completed
    case failed
    case cancelled
}

// MARK: - StepExecution

/// Record of a single tool invocation within a workflow run.
///
/// Each `StepExecution` captures the exact command, tool version,
/// container image digest, and input/output file checksums needed
/// to reproduce that step.
public struct StepExecution: Codable, Sendable, Identifiable, Equatable {
    /// Unique identifier for this step.
    public let id: UUID

    /// Tool name (e.g., "samtools", "bcftools", "fastp").
    public let toolName: String

    /// Tool version string (e.g., "1.21").
    public let toolVersion: String

    /// Container image reference, if the tool ran in a container.
    public let containerImage: String?

    /// Immutable SHA256 digest of the container image used.
    public let containerDigest: String?

    /// Full command-line as executed (argv).
    public let command: [String]

    /// Input files consumed by this step.
    public let inputs: [FileRecord]

    /// Output files produced by this step.
    public var outputs: [FileRecord]

    /// Process exit code.
    public var exitCode: Int32?

    /// Wall-clock execution time in seconds.
    public var wallTime: TimeInterval?

    /// Peak memory usage in bytes (if available).
    public var peakMemoryBytes: UInt64?

    /// Standard error output (truncated to 10 KB for storage).
    public var stderr: String?

    /// IDs of upstream steps this step depends on (DAG edges).
    public let dependsOn: [UUID]

    /// When this step started.
    public let startTime: Date

    /// When this step completed.
    public var endTime: Date?

    public init(
        id: UUID = UUID(),
        toolName: String,
        toolVersion: String,
        containerImage: String? = nil,
        containerDigest: String? = nil,
        command: [String],
        inputs: [FileRecord],
        outputs: [FileRecord] = [],
        exitCode: Int32? = nil,
        wallTime: TimeInterval? = nil,
        peakMemoryBytes: UInt64? = nil,
        stderr: String? = nil,
        dependsOn: [UUID] = [],
        startTime: Date = Date(),
        endTime: Date? = nil
    ) {
        self.id = id
        self.toolName = toolName
        self.toolVersion = toolVersion
        self.containerImage = containerImage
        self.containerDigest = containerDigest
        self.command = command
        self.inputs = inputs
        self.outputs = outputs
        self.exitCode = exitCode
        self.wallTime = wallTime
        self.peakMemoryBytes = peakMemoryBytes
        self.stderr = stderr
        self.dependsOn = dependsOn
        self.startTime = startTime
        self.endTime = endTime
    }

    /// Whether this step succeeded.
    public var isSuccess: Bool { exitCode == 0 }

    /// The command as a single shell-escaped string.
    public var commandString: String {
        command.map { shellEscape($0) }.joined(separator: " ")
    }
}

// MARK: - FileRecord

/// Metadata for an input or output file in a provenance record.
public struct FileRecord: Codable, Sendable, Equatable {
    /// Original file path (relative to project root when possible).
    public let path: String

    /// SHA-256 checksum of the file contents.
    public let sha256: String?

    /// File size in bytes.
    public let sizeBytes: UInt64?

    /// File format identifier.
    public let format: FileFormat?

    /// Role of this file in the step.
    public let role: FileRole

    public init(
        path: String,
        sha256: String? = nil,
        sizeBytes: UInt64? = nil,
        format: FileFormat? = nil,
        role: FileRole = .input
    ) {
        self.path = path
        self.sha256 = sha256
        self.sizeBytes = sizeBytes
        self.format = format
        self.role = role
    }

    /// The filename component of the path.
    public var filename: String {
        URL(fileURLWithPath: path).lastPathComponent
    }
}

// MARK: - FileFormat

/// Recognized genomic file formats.
public enum FileFormat: String, Codable, Sendable {
    case fasta
    case fastq
    case bam
    case cram
    case sam
    case vcf
    case bcf
    case gff3
    case bed
    case bigBed
    case bigWig
    case genBank
    case html
    case json
    case text
    case unknown
}

// MARK: - FileRole

/// Role of a file in a workflow step.
public enum FileRole: String, Codable, Sendable {
    case input
    case output
    case reference
    case index
    case log
    case report
}

// MARK: - Canonical Provenance Conversion

extension WorkflowRun {
    public func canonicalEnvelope() -> ProvenanceEnvelope {
        let firstStep = steps.first
        let convertedSteps = steps.map(ProvenanceStep.init(stepExecution:))
        let allFiles = convertedSteps.flatMap { $0.inputs + $0.outputs }
        let allOutputs = convertedSteps.flatMap(\.outputs)
        let outcomeStep = canonicalOutcomeStep()
        let topLevelOutput = canonicalTopLevelOutput(outcomeStep: outcomeStep)

        return ProvenanceEnvelope(
            id: id,
            createdAt: startTime,
            workflowName: name,
            workflowVersion: ProvenanceVersion.required(appVersion, fallback: WorkflowRun.currentAppVersion),
            toolName: firstStep?.toolName ?? name,
            toolVersion: ProvenanceVersion.required(firstStep?.toolVersion, fallback: appVersion),
            tool: ProvenanceToolIdentity(
                name: firstStep?.toolName ?? name,
                version: ProvenanceVersion.required(firstStep?.toolVersion, fallback: appVersion),
                kind: "cli"
            ),
            argv: firstStep?.command ?? [],
            reproducibleCommand: firstStep?.commandString,
            options: ProvenanceOptions(explicit: parameters),
            runtimeIdentity: ProvenanceRuntimeIdentity(
                appVersion: appVersion,
                operatingSystemVersion: hostOS,
                user: runtime.user,
                containerImage: firstStep?.containerImage,
                containerDigest: firstStep?.containerDigest
            ),
            files: allFiles,
            output: topLevelOutput,
            outputs: allOutputs,
            steps: convertedSteps,
            wallTimeSeconds: wallTime,
            exitStatus: canonicalExitStatus(outcomeStep: outcomeStep),
            stderr: canonicalStderr(outcomeStep: outcomeStep),
            legacyWorkflowRun: self
        )
    }

    private func canonicalOutcomeStep() -> StepExecution? {
        if status == .failed, let failedStep = steps.last(where: { ($0.exitCode ?? 0) != 0 }) {
            return failedStep
        }
        return steps.last ?? steps.first
    }

    private func canonicalTopLevelOutput(outcomeStep: StepExecution?) -> ProvenanceFileDescriptor? {
        for index in steps.indices.reversed() {
            let laterInputPaths = Set(steps.dropFirst(index + 1).flatMap { $0.inputs.map(\.path) })
            if let terminalOutput = steps[index].outputs.first(where: { !laterInputPaths.contains($0.path) }) {
                return ProvenanceFileDescriptor(fileRecord: terminalOutput)
            }
        }

        if let output = outcomeStep?.outputs.first {
            return ProvenanceFileDescriptor(fileRecord: output)
        }
        if let output = steps.last?.outputs.first ?? steps.first?.outputs.first {
            return ProvenanceFileDescriptor(fileRecord: output)
        }
        return nil
    }

    private func canonicalExitStatus(outcomeStep: StepExecution?) -> Int? {
        if status == .completed {
            return outcomeStep?.exitCode.map(Int.init) ?? 0
        }
        if status == .failed {
            if let exitCode = outcomeStep?.exitCode, exitCode != 0 {
                return Int(exitCode)
            }
            return 1
        }
        return outcomeStep?.exitCode.map(Int.init)
    }

    private func canonicalStderr(outcomeStep: StepExecution?) -> String? {
        if status == .failed {
            return outcomeStep?.stderr ?? steps.reversed().first { !($0.stderr ?? "").isEmpty }?.stderr
        }
        return outcomeStep?.stderr
    }
}

extension ProvenanceEnvelope {
    public func legacyWorkflowRun() -> WorkflowRun {
        if let legacyRun {
            return legacyRun
        }

        let legacySteps: [StepExecution]
        if steps.isEmpty {
            let fallbackOutputs = legacyFallbackOutputs()
            legacySteps = [
                StepExecution(
                    id: UUID(),
                    toolName: toolName,
                    toolVersion: toolVersion,
                    containerImage: runtimeIdentity.containerImage,
                    containerDigest: runtimeIdentity.containerDigest,
                    command: argv,
                    inputs: files.filter { $0.role == .input }.map(FileRecord.init(provenanceFile:)),
                    outputs: fallbackOutputs.map(FileRecord.init(provenanceFile:)),
                    exitCode: exitStatus.map(Int32.init),
                    wallTime: wallTimeSeconds,
                    stderr: stderr,
                    startTime: createdAt,
                    endTime: completedAtFromWallTime
                )
            ]
        } else {
            var convertedSteps = steps.map { step in
                StepExecution(
                    id: step.id,
                    toolName: step.toolName,
                    toolVersion: step.toolVersion,
                    containerImage: runtimeIdentity.containerImage,
                    containerDigest: runtimeIdentity.containerDigest,
                    command: step.argv,
                    inputs: step.inputs.map(FileRecord.init(provenanceFile:)),
                    outputs: step.outputs.map(FileRecord.init(provenanceFile:)),
                    exitCode: step.exitStatus.map(Int32.init),
                    wallTime: step.wallTimeSeconds,
                    stderr: step.stderr,
                    dependsOn: step.dependsOn,
                    startTime: step.startedAt ?? createdAt,
                    endTime: step.completedAt
                )
            }
            convertedSteps.mergeFallbackOutputsIntoFinalStep(legacyFallbackOutputs())
            legacySteps = convertedSteps
        }

        return WorkflowRun(
            id: id,
            name: workflowName,
            startTime: legacySteps.first?.startTime ?? createdAt,
            endTime: legacySteps.compactMap(\.endTime).max() ?? completedAtFromWallTime,
            status: legacyStatus,
            appVersion: runtimeIdentity.appVersion,
            hostOS: runtimeIdentity.operatingSystemVersion,
            runtime: WorkflowRuntime(
                appVersion: runtimeIdentity.appVersion,
                hostOS: runtimeIdentity.operatingSystemVersion,
                user: runtimeIdentity.user
            ),
            steps: legacySteps,
            parameters: options.explicit
        )
    }

    private var legacyStatus: RunStatus {
        guard let exitStatus else { return .running }
        return exitStatus == 0 ? .completed : .failed
    }

    private var completedAtFromWallTime: Date? {
        wallTimeSeconds.map { createdAt.addingTimeInterval($0) }
    }

    private func legacyFallbackOutputs() -> [ProvenanceFileDescriptor] {
        var seen = Set<String>()
        var descriptors: [ProvenanceFileDescriptor] = []

        for descriptor in outputs + [output].compactMap({ $0 }) + files.filter({ $0.role == .output }) {
            guard seen.insert(descriptor.path).inserted else { continue }
            descriptors.append(descriptor)
        }

        return descriptors
    }
}

private extension Array where Element == StepExecution {
    mutating func mergeFallbackOutputsIntoFinalStep(_ fallbackOutputs: [ProvenanceFileDescriptor]) {
        guard !isEmpty, !fallbackOutputs.isEmpty else { return }
        let finalStepIndex = index(before: endIndex)
        var seenOutputPaths = Set(self[finalStepIndex].outputs.map(\.path))
        let missingOutputs = fallbackOutputs
            .map(FileRecord.init(provenanceFile:))
            .filter { seenOutputPaths.insert($0.path).inserted }
        guard !missingOutputs.isEmpty else { return }
        self[finalStepIndex].outputs.append(contentsOf: missingOutputs)
    }
}

extension ProvenanceFileDescriptor {
    public init(fileRecord: FileRecord, sourceProvenancePath: String? = nil) {
        self.init(
            path: fileRecord.path,
            checksumSHA256: fileRecord.sha256,
            fileSize: fileRecord.sizeBytes,
            format: fileRecord.format,
            role: fileRecord.role,
            sourceProvenancePath: sourceProvenancePath
        )
    }
}

extension FileRecord {
    public init(provenanceFile: ProvenanceFileDescriptor) {
        self.init(
            path: provenanceFile.path,
            sha256: provenanceFile.checksumSHA256,
            sizeBytes: provenanceFile.fileSize,
            format: provenanceFile.format,
            role: provenanceFile.role
        )
    }
}

extension ProvenanceStep {
    public init(stepExecution: StepExecution) {
        self.init(
            id: stepExecution.id,
            toolName: stepExecution.toolName,
            toolVersion: ProvenanceVersion.required(stepExecution.toolVersion),
            argv: stepExecution.command,
            reproducibleCommand: stepExecution.commandString,
            inputs: stepExecution.inputs.map { ProvenanceFileDescriptor(fileRecord: $0) },
            outputs: stepExecution.outputs.map { ProvenanceFileDescriptor(fileRecord: $0) },
            exitStatus: stepExecution.exitCode.map(Int.init),
            wallTimeSeconds: stepExecution.wallTime,
            stderr: stepExecution.stderr,
            dependsOn: stepExecution.dependsOn,
            startedAt: stepExecution.startTime,
            completedAt: stepExecution.endTime
        )
    }
}

// Note: Uses ParameterValue from WorkflowParameters.swift for workflow parameters.
