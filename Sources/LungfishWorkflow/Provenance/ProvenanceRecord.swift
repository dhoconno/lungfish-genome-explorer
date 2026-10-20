// ProvenanceRecord.swift - Provenance data model for reproducibility tracking
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import LungfishCore

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

    /// The app identity recorded in provenance: `Lungfish <version> (<build>)`.
    ///
    /// The packaged app and the CLI inside it read both values from the
    /// bundle's Info.plist. A bare `lungfish-cli` binary (SwiftPM build, or a
    /// copied CLI whose embedded identity plist carries no version keys) has
    /// no `CFBundleShortVersionString`, so the release version falls back to
    /// ``LungfishAppVersion/short``, the same constant `lungfish-cli --version`
    /// prints. Without a packaged build number the build is recorded as
    /// `dev`; it was previously recorded as `Lungfish dev (0)`, which named
    /// neither.
    ///
    /// The CLI shipped inside the app reads its own embedded identity plist,
    /// which carries no version keys, so without a fallback every record a
    /// packaged `lungfish-cli` wrote (including the analyses the app runs
    /// through it) said `(dev)`. A missing key is therefore taken from the
    /// enclosing `.app` bundle's Info.plist when the executable lives in one.
    ///
    /// Only a Lungfish Info.plist lends a key. A host's own, such as xctest's
    /// in a test run, lends nothing, so the host's version never stands for
    /// Lungfish's and a test run records what a bare `lungfish-cli` records.
    public static var currentAppVersion: String {
        appVersion(
            infoDictionary: Bundle.main.infoDictionary ?? [:],
            enclosingAppInfoDictionary: enclosingAppInfoDictionary(executableURL: Bundle.main.executableURL)
        )
    }

    /// The Info.plist of the `.app` bundle containing `executableURL`
    /// (`<name>.app/Contents/MacOS/<executable>`), or nil when the executable
    /// is not inside an app bundle. Symlinks such as an installed
    /// `/usr/local/bin/lungfish-cli` are resolved first.
    static func enclosingAppInfoDictionary(executableURL: URL?) -> [String: Any]? {
        guard let executable = executableURL?.resolvingSymlinksInPath() else { return nil }
        let contents = executable.deletingLastPathComponent().deletingLastPathComponent()
        guard executable.deletingLastPathComponent().lastPathComponent == "MacOS",
              contents.lastPathComponent == "Contents",
              contents.deletingLastPathComponent().pathExtension == "app",
              let data = try? Data(contentsOf: contents.appendingPathComponent("Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return plist
    }

    /// `currentAppVersion` for explicit Info.plist dictionaries (testable).
    /// A dictionary that is not a Lungfish Info.plist lends no key.
    public static func appVersion(
        infoDictionary: [String: Any],
        enclosingAppInfoDictionary: [String: Any]? = nil
    ) -> String {
        let lungfishInfo = [infoDictionary, enclosingAppInfoDictionary ?? [:]].filter(isLungfishInfoDictionary)
        func value(_ key: String) -> String? {
            for dictionary in lungfishInfo {
                if let text = (dictionary[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !text.isEmpty {
                    return text
                }
            }
            return nil
        }
        let plistVersion = value("CFBundleShortVersionString")
        let plistBuild = value("CFBundleVersion")
        let version = (plistVersion?.isEmpty == false) ? plistVersion! : LungfishAppVersion.short
        let build = (plistBuild?.isEmpty == false) ? plistBuild! : "dev"
        return "Lungfish \(version) (\(build))"
    }

    /// The identity keys of a Lungfish Info.plist. Every plist the repo ships carries
    /// `LungfishReleaseChannel` (`Lungfish-Info.plist`, `LungfishCLI-Info.plist`), and a fork's
    /// also carries the other two. They are the keys `RuntimeAppIdentityResolver` reads to tell
    /// Lungfish's metadata from a host's (`Sources/LungfishCore/AppIdentity.swift`).
    static let lungfishIdentityKeys = ["LungfishReleaseChannel", "LungfishRuntimeNamespace", "LungfishIdentitySchemaVersion"]

    /// Whether `info` is a Lungfish Info.plist, the app's or the identity plist its CLI embeds.
    static func isLungfishInfoDictionary(_ info: [String: Any]) -> Bool {
        lungfishIdentityKeys.contains { info[$0] != nil }
    }

    /// The release version alone (`2026.9.72`), for a step LGE itself
    /// performed: a step's `toolVersion` names a version, not the app.
    public static var currentAppReleaseVersion: String {
        releaseVersion(from: currentAppVersion)
    }

    /// `2026.9.72` from `Lungfish 2026.9.72 (dev)`.
    static func releaseVersion(from appVersion: String) -> String {
        var value = appVersion.trimmingCharacters(in: .whitespaces)
        if value.lowercased().hasPrefix("lungfish ") { value = String(value.dropFirst("lungfish ".count)) }
        if let open = value.firstIndex(of: "(") { value = String(value[..<open]) }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? LungfishAppVersion.short : trimmed
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

    /// The account name recorded in provenance: always nil. Records LGE
    /// writes into a project travel with shared projects and published
    /// archives, so they do not name the account that produced them. Older
    /// records that carry a `user` stay readable.
    public static var currentUser: String? { nil }
}

// MARK: - Canonical Provenance Conversion

extension WorkflowRun {
    /// The envelope a writer makes of this run. The executable path, process ID, architecture and
    /// dependency set are the writing process's own, because a run holds none of them.
    public func canonicalEnvelope(resolvedDefaults: [String: ParameterValue] = [:]) -> ProvenanceEnvelope {
        envelope(
            resolvedDefaults: resolvedDefaults,
            workflowVersion: ProvenanceVersion.required(appVersion, fallback: WorkflowRun.currentAppVersion),
            runtimeIdentity: ProvenanceRuntimeIdentity(
                appVersion: appVersion,
                operatingSystemVersion: hostOS,
                user: runtime.user,
                containerImage: steps.first?.containerImage,
                containerDigest: steps.first?.containerDigest
            )
        )
    }

    /// The envelope a reader makes of a decoded bare run. It holds only what the run recorded, so
    /// the executable path, process ID, architecture and dependency set read Not recorded instead
    /// of the reading Mac's (plan decision S4).
    func recordedEnvelope() -> ProvenanceEnvelope {
        let recordedAppVersion = ProvenanceRuntimeIdentity.recorded(appVersion)
        return envelope(
            resolvedDefaults: [:],
            workflowVersion: recordedAppVersion,
            runtimeIdentity: ProvenanceRuntimeIdentity(
                appVersion: recordedAppVersion,
                executablePath: nil,
                processIdentifier: nil,
                operatingSystemVersion: ProvenanceRuntimeIdentity.recorded(hostOS),
                architecture: nil,
                user: runtime.user,
                containerImage: steps.first?.containerImage,
                containerDigest: steps.first?.containerDigest,
                dependencySet: nil
            )
        )
    }

    private func envelope(
        resolvedDefaults: [String: ParameterValue],
        workflowVersion: String?,
        runtimeIdentity: ProvenanceRuntimeIdentity
    ) -> ProvenanceEnvelope {
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
            workflowVersion: workflowVersion,
            toolName: firstStep?.toolName ?? name,
            toolVersion: ProvenanceVersion.required(firstStep?.toolVersion, fallback: appVersion),
            githubReleaseVersion: firstStep?.githubReleaseVersion ?? parameters["github_release_version"]?.stringValue,
            tool: ProvenanceToolIdentity(
                name: firstStep?.toolName ?? name,
                version: ProvenanceVersion.required(firstStep?.toolVersion, fallback: appVersion),
                kind: "cli"
            ),
            argv: firstStep?.command ?? [],
            durableReplayArgv: firstStep?.durableReplayArgv,
            reproducibleCommand: firstStep?.commandString,
            options: ProvenanceOptions(explicit: parameters, resolvedDefaults: resolvedDefaults),
            runtimeIdentity: runtimeIdentity,
            files: allFiles,
            output: topLevelOutput,
            outputs: allOutputs,
            steps: convertedSteps,
            wallTimeSeconds: wallTime,
            exitStatus: canonicalExitStatus(outcomeStep: outcomeStep),
            stderr: canonicalStderr(outcomeStep: outcomeStep),
            status: status,
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
    public func legacyWorkflowRun(preferCanonicalSteps: Bool = false) -> WorkflowRun {
        if let legacyRun, !preferCanonicalSteps {
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
                    githubReleaseVersion: githubReleaseVersion,
                    containerImage: runtimeIdentity.containerImage,
                    containerDigest: runtimeIdentity.containerDigest,
                    command: legacyCommand(argv: argv, reproducibleCommand: reproducibleCommand),
                    durableReplayArgv: durableReplayArgv,
                    runtimeIdentity: runtimeIdentity,
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
                    githubReleaseVersion: step.githubReleaseVersion,
                    containerImage: runtimeIdentity.containerImage,
                    containerDigest: runtimeIdentity.containerDigest,
                    command: legacyCommand(argv: step.argv, reproducibleCommand: step.reproducibleCommand),
                    durableReplayArgv: step.durableReplayArgv,
                    resolvedOptions: step.resolvedOptions,
                    runtimeIdentity: step.runtimeIdentity ?? runtimeIdentity,
                    inputs: step.inputs.map(FileRecord.init(provenanceFile:)),
                    outputs: step.outputs.map(FileRecord.init(provenanceFile:)),
                    exitCode: step.exitStatus.map(Int32.init),
                    wallTime: step.wallTimeSeconds,
                    peakMemoryBytes: step.peakMemoryBytes,
                    stderr: step.stderr,
                    dependsOn: step.dependsOn,
                    parentStepID: step.parentStepID,
                    managedToolID: step.managedToolID,
                    toolVersionEvidence: step.toolVersionEvidence,
                    stdoutReadInProcess: step.stdoutReadInProcess,
                    startTime: step.startedAt ?? createdAt,
                    endTime: step.completedAt
                )
            }
            convertedSteps.mergeFallbackOutputsIntoFinalStep(legacyFallbackOutputs())
            legacySteps = convertedSteps
        }

        // A `WorkflowRun` needs text where the record may hold nothing. It gets the empty string,
        // which no app version or OS reads as, never the reading Mac's value (plan decision S4).
        let appVersion = runtimeIdentity.appVersion ?? ""
        let hostOS = runtimeIdentity.operatingSystemVersion ?? ""
        return WorkflowRun(
            id: id,
            name: workflowName,
            startTime: legacySteps.first?.startTime ?? createdAt,
            endTime: legacySteps.compactMap(\.endTime).max() ?? completedAtFromWallTime,
            status: status,
            appVersion: appVersion,
            hostOS: hostOS,
            runtime: WorkflowRuntime(appVersion: appVersion, hostOS: hostOS, user: runtimeIdentity.user),
            steps: legacySteps,
            parameters: options.explicit
        )
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

    private func legacyCommand(argv: [String], reproducibleCommand: String) -> [String] {
        if !argv.isEmpty {
            return argv
        }
        let trimmedCommand = reproducibleCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCommand.isEmpty else {
            return []
        }
        return ["/bin/sh", "-lc", trimmedCommand]
    }
}

extension ProvenanceEnvelope {
    /// This record as a reader shows it when the record's own format holds no host facts: the
    /// given runtime identity, no workflow version, and an embedded run, when there is one, with the
    /// empty string for its app version and operating system and no account. A typed record's
    /// reader uses it on the writer's conversion, so the reading Mac lends the record nothing.
    func readingWithoutHostFacts(runtimeIdentity: ProvenanceRuntimeIdentity) -> ProvenanceEnvelope {
        ProvenanceEnvelope(
            schemaVersion: schemaVersion,
            id: id,
            createdAt: createdAt,
            workflowName: workflowName,
            workflowVersion: nil,
            toolName: toolName,
            toolVersion: toolVersion,
            githubReleaseVersion: githubReleaseVersion,
            tool: tool,
            argv: argv,
            durableReplayArgv: durableReplayArgv,
            reproducibleCommand: reproducibleCommand,
            options: options,
            runtimeIdentity: runtimeIdentity,
            files: files,
            output: output,
            outputs: outputs,
            steps: steps,
            wallTimeSeconds: wallTimeSeconds,
            exitStatus: exitStatus,
            stderr: stderr,
            signatures: signatures,
            status: status,
            legacyWorkflowRun: legacyRun.map { run in
                WorkflowRun(
                    id: run.id,
                    name: run.name,
                    startTime: run.startTime,
                    endTime: run.endTime,
                    status: run.status,
                    appVersion: "",
                    hostOS: "",
                    runtime: WorkflowRuntime(appVersion: "", hostOS: "", user: nil),
                    steps: run.steps,
                    parameters: run.parameters
                )
            }
        )
    }
}

private extension Array where Element == StepExecution {
    mutating func mergeFallbackOutputsIntoFinalStep(_ fallbackOutputs: [ProvenanceFileDescriptor]) {
        guard !isEmpty, !fallbackOutputs.isEmpty else { return }
        let finalStepIndex = index(before: endIndex)
        // A run output that any step lists stays on that step. The final step gets only those that no step lists.
        var seenOutputPaths = Set(self.flatMap { $0.outputs.map(\.path) })
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

extension ProvenanceStep {
    public init(stepExecution: StepExecution) {
        self.init(
            id: stepExecution.id,
            toolName: stepExecution.toolName,
            toolVersion: ProvenanceVersion.required(stepExecution.toolVersion),
            githubReleaseVersion: stepExecution.githubReleaseVersion,
            argv: stepExecution.command,
            durableReplayArgv: stepExecution.durableReplayArgv,
            reproducibleCommand: (stepExecution.durableReplayArgv ?? stepExecution.command).map(shellEscape).joined(separator: " "),
            resolvedOptions: stepExecution.resolvedOptions ?? [:],
            runtimeIdentity: stepExecution.runtimeIdentity,
            inputs: stepExecution.inputs.map { ProvenanceFileDescriptor(fileRecord: $0) },
            outputs: stepExecution.outputs.map { ProvenanceFileDescriptor(fileRecord: $0) },
            exitStatus: stepExecution.exitCode.map(Int.init),
            wallTimeSeconds: stepExecution.wallTime,
            peakMemoryBytes: stepExecution.peakMemoryBytes,
            stderr: stepExecution.stderr,
            dependsOn: stepExecution.dependsOn,
            startedAt: stepExecution.startTime,
            completedAt: stepExecution.endTime,
            parentStepID: stepExecution.parentStepID,
            managedToolID: stepExecution.managedToolID,
            toolVersionEvidence: stepExecution.toolVersionEvidence,
            stdoutReadInProcess: stepExecution.stdoutReadInProcess
        )
    }
}

// Note: Uses ParameterValue from WorkflowParameters.swift for workflow parameters.
