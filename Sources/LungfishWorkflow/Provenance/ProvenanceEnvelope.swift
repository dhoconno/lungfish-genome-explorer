// ProvenanceEnvelope.swift - Canonical provenance envelope model
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

private struct RawProvenanceToolIdentity: Decodable {
    let name: String?
    let version: String?
    let kind: String?
}

// MARK: - ProvenanceEnvelope

public struct ProvenanceEnvelope: Codable, Sendable, Equatable, Identifiable {
    public let schemaVersion: Int
    public let id: UUID
    public let createdAt: Date
    public let workflowName: String
    public let workflowVersion: String
    public let toolName: String
    public let toolVersion: String
    public let githubReleaseVersion: String?
    public let tool: ProvenanceToolIdentity
    public let argv: [String]
    public let durableReplayArgv: [String]?
    public let reproducibleCommand: String
    public let options: ProvenanceOptions
    public let runtimeIdentity: ProvenanceRuntimeIdentity
    public let files: [ProvenanceFileDescriptor]
    public let output: ProvenanceFileDescriptor?
    public let outputs: [ProvenanceFileDescriptor]
    public let steps: [ProvenanceStep]
    public let wallTimeSeconds: TimeInterval?
    public let exitStatus: Int?
    public let stderr: String?
    public let signatures: [ProvenanceSignatureReference]
    public let legacyRun: WorkflowRun?

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case id
        case createdAt
        case legacyName = "name"
        case legacyStatus = "status"
        case startTime
        case endTime
        case appVersion
        case hostOS
        case runtime
        case parameters
        case workflowName
        case workflowVersion
        case toolName
        case toolVersion
        case githubReleaseVersion
        case tool
        case argv
        case durableReplayArgv
        case reproducibleCommand
        case reproducibleShellCommand
        case options
        case runtimeIdentity
        case files
        case input
        case inputFiles
        case output
        case outputs
        case steps
        case workflowSteps
        case externalToolInvocations
        case wallTimeSeconds
        case exitStatus
        case stderr
        case signatures
        case legacyRun = "legacyWorkflowRun"
    }

    public init(
        schemaVersion: Int = 1,
        id: UUID = UUID(),
        createdAt: Date = Date(),
        workflowName: String,
        workflowVersion: String = WorkflowRun.currentAppVersion,
        toolName: String,
        toolVersion: String = "unknown",
        githubReleaseVersion: String? = nil,
        tool: ProvenanceToolIdentity? = nil,
        argv: [String] = [],
        durableReplayArgv: [String]? = nil,
        reproducibleCommand: String? = nil,
        options: ProvenanceOptions = ProvenanceOptions(),
        runtimeIdentity: ProvenanceRuntimeIdentity = ProvenanceRuntimeIdentity(),
        files: [ProvenanceFileDescriptor] = [],
        output: ProvenanceFileDescriptor? = nil,
        outputs: [ProvenanceFileDescriptor] = [],
        steps: [ProvenanceStep] = [],
        wallTimeSeconds: TimeInterval? = nil,
        exitStatus: Int? = nil,
        stderr: String? = nil,
        signatures: [ProvenanceSignatureReference] = [],
        legacyWorkflowRun: WorkflowRun? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.createdAt = createdAt
        self.workflowName = ProvenanceName.required(workflowName)
        self.workflowVersion = ProvenanceVersion.required(workflowVersion, fallback: WorkflowRun.currentAppVersion)
        self.toolName = ProvenanceName.required(toolName)
        self.toolVersion = ProvenanceVersion.required(toolVersion)
        self.githubReleaseVersion = githubReleaseVersion
        self.tool = ProvenanceToolIdentity(name: self.toolName, version: self.toolVersion, kind: tool?.kind)
        self.argv = argv
        self.durableReplayArgv = durableReplayArgv
        self.reproducibleCommand = reproducibleCommand ?? argv.map(shellEscape).joined(separator: " ")
        self.options = options
        self.runtimeIdentity = runtimeIdentity
        self.files = files
        self.output = output
        self.outputs = outputs
        self.steps = steps
        self.wallTimeSeconds = wallTimeSeconds
        self.exitStatus = exitStatus
        self.stderr = stderr
        self.signatures = signatures
        self.legacyRun = legacyWorkflowRun
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        workflowName = ProvenanceName.required(
            try container.decodeIfPresent(String.self, forKey: .workflowName),
            fallback: try container.decodeIfPresent(String.self, forKey: .legacyName) ?? "unknown"
        )
        workflowVersion = ProvenanceVersion.required(
            try container.decodeIfPresent(String.self, forKey: .workflowVersion),
            fallback: WorkflowRun.currentAppVersion
        )
        let decodedTool = try container.decodeIfPresent(RawProvenanceToolIdentity.self, forKey: .tool)
        toolName = ProvenanceName.required(
            try container.decodeIfPresent(String.self, forKey: .toolName),
            fallback: decodedTool?.name ?? "unknown"
        )
        toolVersion = ProvenanceVersion.required(
            try container.decodeIfPresent(String.self, forKey: .toolVersion),
            fallback: decodedTool?.version ?? "unknown"
        )
        githubReleaseVersion = try container.decodeIfPresent(String.self, forKey: .githubReleaseVersion)
        if let decodedTool {
            tool = ProvenanceToolIdentity(
                name: toolName,
                version: toolVersion,
                kind: decodedTool.kind
            )
        } else {
            tool = ProvenanceToolIdentity(name: toolName, version: toolVersion)
        }
        argv = try container.decodeIfPresent([String].self, forKey: .argv) ?? []
        durableReplayArgv = try container.decodeIfPresent([String].self, forKey: .durableReplayArgv)
        reproducibleCommand = try container.decodeIfPresent(String.self, forKey: .reproducibleCommand)
            ?? container.decodeIfPresent(String.self, forKey: .reproducibleShellCommand)
            ?? argv.map(shellEscape).joined(separator: " ")
        options = try container.decodeIfPresent(ProvenanceOptions.self, forKey: .options) ?? ProvenanceOptions()
        runtimeIdentity = try container.decode(ProvenanceRuntimeIdentity.self, forKey: .runtimeIdentity)
        let decodedInput = try Self.decodeFileDescriptorIfPresent(
            from: container,
            forKey: .input,
            role: .input
        )
        let decodedInputFiles = try Self.decodeFileDescriptorsIfPresent(
            from: container,
            forKey: .inputFiles,
            role: .input
        ) ?? []
        let decodedOutput = try Self.decodeFileDescriptorIfPresent(
            from: container,
            forKey: .output,
            role: .output
        )
        let normalizedOutput = decodedOutput?.withRole(.output)
        let decodedFiles = try container.decodeIfPresent([ProvenanceFileDescriptor].self, forKey: .files) ?? []
        let normalizedFiles = Self.normalizePrimitiveFileRoles(
            decodedFiles,
            output: normalizedOutput,
            options: options
        )
        files = Self.deduplicated((decodedInput.map { [$0] } ?? []) + decodedInputFiles + normalizedFiles)
        output = normalizedOutput
        outputs = try container.decodeIfPresent([ProvenanceFileDescriptor].self, forKey: .outputs)
            ?? Self.derivedOutputs(from: normalizedFiles, output: normalizedOutput)
        steps = try container.decodeIfPresent([ProvenanceStep].self, forKey: .steps)
            ?? Self.decodePrimitiveSteps(
                from: container,
                defaultToolVersion: toolVersion,
                createdAt: createdAt
            )
        wallTimeSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .wallTimeSeconds)
        exitStatus = try container.decodeIfPresent(Int.self, forKey: .exitStatus)
        stderr = try container.decodeIfPresent(String.self, forKey: .stderr)
        signatures = try container.decodeIfPresent([ProvenanceSignatureReference].self, forKey: .signatures) ?? []
        legacyRun = try container.decodeIfPresent(WorkflowRun.self, forKey: .legacyRun)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(id, forKey: .id)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(workflowName, forKey: .legacyName)
        try container.encode(legacyCompatibilityStatus.rawValue, forKey: .legacyStatus)
        let compatibilityRun = legacyWorkflowRun()
        try container.encode(compatibilityRun.startTime, forKey: .startTime)
        try container.encodeIfPresent(compatibilityRun.endTime, forKey: .endTime)
        try container.encode(compatibilityRun.appVersion, forKey: .appVersion)
        try container.encode(compatibilityRun.hostOS, forKey: .hostOS)
        try container.encode(compatibilityRun.runtime, forKey: .runtime)
        try container.encode(compatibilityRun.parameters, forKey: .parameters)
        try container.encode(workflowName, forKey: .workflowName)
        try container.encode(workflowVersion, forKey: .workflowVersion)
        try container.encode(toolName, forKey: .toolName)
        try container.encode(toolVersion, forKey: .toolVersion)
        try container.encodeIfPresent(githubReleaseVersion, forKey: .githubReleaseVersion)
        try container.encode(tool, forKey: .tool)
        try container.encode(argv, forKey: .argv)
        try container.encodeIfPresent(durableReplayArgv, forKey: .durableReplayArgv)
        try container.encode(reproducibleCommand, forKey: .reproducibleCommand)
        try container.encode(options, forKey: .options)
        try container.encode(runtimeIdentity, forKey: .runtimeIdentity)
        try container.encode(files, forKey: .files)
        try container.encodeIfPresent(output, forKey: .output)
        try container.encode(outputs, forKey: .outputs)
        try container.encode(steps, forKey: .steps)
        try container.encodeIfPresent(wallTimeSeconds, forKey: .wallTimeSeconds)
        try container.encodeIfPresent(exitStatus, forKey: .exitStatus)
        try container.encodeIfPresent(stderr, forKey: .stderr)
        try container.encode(signatures, forKey: .signatures)
        try container.encodeIfPresent(legacyRun, forKey: .legacyRun)
    }

    private static func decodeFileDescriptorIfPresent(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys,
        role: FileRole
    ) throws -> ProvenanceFileDescriptor? {
        guard container.contains(key) else { return nil }
        if let descriptor = try? container.decode(ProvenanceFileDescriptor.self, forKey: key) {
            return descriptor.withRole(role)
        }
        if let path = try? container.decode(String.self, forKey: key) {
            return ProvenanceFileDescriptor(path: path, role: role)
        }
        return nil
    }

    private static func decodeFileDescriptorsIfPresent(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys,
        role: FileRole
    ) throws -> [ProvenanceFileDescriptor]? {
        guard container.contains(key) else { return nil }
        if let descriptors = try? container.decode([ProvenanceFileDescriptor].self, forKey: key) {
            return descriptors.map { $0.withRole(role) }
        }
        if let paths = try? container.decode([String].self, forKey: key) {
            return paths.map { ProvenanceFileDescriptor(path: $0, role: role) }
        }
        return nil
    }

    private static func decodePrimitiveSteps(
        from container: KeyedDecodingContainer<CodingKeys>,
        defaultToolVersion: String,
        createdAt: Date
    ) throws -> [ProvenanceStep] {
        if let workflowSteps = try container.decodeIfPresent([PrimitiveWorkflowStep].self, forKey: .workflowSteps),
           !workflowSteps.isEmpty {
            return workflowSteps.map { step in
                step.provenanceStep(defaultToolVersion: defaultToolVersion, createdAt: createdAt)
            }
        }
        if let invocations = try container.decodeIfPresent(
            [PrimitiveExternalToolInvocation].self,
            forKey: .externalToolInvocations
        ),
           !invocations.isEmpty {
            return invocations.map { invocation in
                invocation.provenanceStep(defaultToolVersion: defaultToolVersion, createdAt: createdAt)
            }
        }
        return []
    }

    private static func deduplicated(_ files: [ProvenanceFileDescriptor]) -> [ProvenanceFileDescriptor] {
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

    private static func normalizePrimitiveFileRoles(
        _ files: [ProvenanceFileDescriptor],
        output: ProvenanceFileDescriptor?,
        options: ProvenanceOptions
    ) -> [ProvenanceFileDescriptor] {
        guard let output else { return files }
        let outputPath = URL(fileURLWithPath: output.path).standardizedFileURL.path
        let outputDirectoryPath = options.explicit["outputDirectory"]?.stringValue
        return files.map { file in
            guard file.role == .input else { return file }
            guard !file.roleWasExplicit else { return file }
            if outputDirectoryPath == output.path,
               URL(fileURLWithPath: file.path).isFileURL,
               file.path.hasPrefix("/") == false {
                return file.withRole(.output)
            }
            let filePath = URL(fileURLWithPath: file.path).standardizedFileURL.path
            if filePath == outputPath || filePath.hasPrefix(outputPath + "/") {
                return file.withRole(.output)
            }
            return file
        }
    }

    private static func derivedOutputs(
        from files: [ProvenanceFileDescriptor],
        output: ProvenanceFileDescriptor?
    ) -> [ProvenanceFileDescriptor] {
        let fileOutputs = files.filter { $0.role == .output }
        if !fileOutputs.isEmpty {
            return fileOutputs
        }
        return output.map { [$0] } ?? []
    }

    private struct PrimitiveWorkflowStep: Decodable {
        let stepName: String?
        let workflowName: String?
        let toolName: String?
        let toolVersion: String?
        let argv: [String]?
        let reproducibleCommand: String?
        let input: String?
        let output: String?
        let exitStatus: Int?
        let wallTimeSeconds: TimeInterval?
        let stderr: String?

        func provenanceStep(defaultToolVersion: String, createdAt: Date) -> ProvenanceStep {
            let inputs = input.map { [ProvenanceFileDescriptor(path: $0, role: .input)] } ?? []
            let outputs = output.map { [ProvenanceFileDescriptor(path: $0, role: .output)] } ?? []
            let arguments = argv ?? []
            return ProvenanceStep(
                toolName: ProvenanceName.required(toolName, fallback: workflowName ?? stepName ?? "unknown"),
                toolVersion: ProvenanceVersion.required(toolVersion, fallback: defaultToolVersion),
                argv: arguments,
                reproducibleCommand: reproducibleCommand ?? arguments.map(shellEscape).joined(separator: " "),
                inputs: inputs,
                outputs: outputs,
                exitStatus: exitStatus,
                wallTimeSeconds: wallTimeSeconds,
                stderr: ProvenanceStderr.normalized(stderr),
                startedAt: createdAt,
                completedAt: wallTimeSeconds.map { createdAt.addingTimeInterval($0) }
            )
        }
    }

    private struct PrimitiveExternalToolInvocation: Decodable {
        let name: String?
        let version: String?
        let argv: [String]?
        let reproducibleCommand: String?
        let exitStatus: Int?
        let wallTimeSeconds: TimeInterval?
        let stderr: String?

        func provenanceStep(defaultToolVersion: String, createdAt: Date) -> ProvenanceStep {
            let arguments = argv ?? []
            return ProvenanceStep(
                toolName: ProvenanceName.required(name),
                toolVersion: ProvenanceVersion.required(version, fallback: defaultToolVersion),
                argv: arguments,
                reproducibleCommand: reproducibleCommand ?? arguments.map(shellEscape).joined(separator: " "),
                inputs: [],
                outputs: [],
                exitStatus: exitStatus,
                wallTimeSeconds: wallTimeSeconds,
                stderr: ProvenanceStderr.normalized(stderr),
                startedAt: createdAt,
                completedAt: wallTimeSeconds.map { createdAt.addingTimeInterval($0) }
            )
        }
    }

    private var legacyCompatibilityStatus: RunStatus {
        if let legacyRun {
            return legacyRun.status
        }
        guard let exitStatus else {
            return .running
        }
        return exitStatus == 0 ? .completed : .failed
    }
}

// MARK: - ProvenanceFileDescriptor

public struct ProvenanceFileDescriptor: Codable, Sendable, Equatable {
    public let path: String
    public let checksumSHA256: String?
    public let fileSize: UInt64?
    public let format: FileFormat?
    public let role: FileRole
    public let originPath: String?
    public let sourceProvenancePath: String?
    fileprivate let roleWasExplicit: Bool

    public init(
        path: String,
        checksumSHA256: String? = nil,
        fileSize: UInt64? = nil,
        format: FileFormat? = nil,
        role: FileRole = .input,
        originPath: String? = nil,
        sourceProvenancePath: String? = nil,
        roleWasExplicit: Bool = true
    ) {
        self.path = path
        self.checksumSHA256 = checksumSHA256
        self.fileSize = fileSize
        self.format = format
        self.role = role
        self.originPath = originPath
        self.sourceProvenancePath = sourceProvenancePath
        self.roleWasExplicit = roleWasExplicit
    }

    /// The recorded format, or the one the file name implies when the record
    /// has none or says unknown (older records stamped every index unknown).
    public var resolvedFormat: FileFormat {
        if let format, format != .unknown { return format }
        return FileFormat.inferred(fromPath: path)
    }

    private enum CodingKeys: String, CodingKey {
        case path
        case checksumSHA256
        case fileSize
        case format
        case role
        case originPath
        case sourceProvenancePath
        case sha256
        case sizeBytes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        checksumSHA256 = try container.decodeIfPresent(String.self, forKey: .checksumSHA256)
            ?? container.decodeIfPresent(String.self, forKey: .sha256)
        fileSize = try container.decodeIfPresent(UInt64.self, forKey: .fileSize)
            ?? container.decodeIfPresent(UInt64.self, forKey: .sizeBytes)
        format = try container.decodeIfPresent(FileFormat.self, forKey: .format)
        roleWasExplicit = container.contains(.role)
        role = try container.decodeIfPresent(FileRole.self, forKey: .role) ?? .input
        originPath = try container.decodeIfPresent(String.self, forKey: .originPath)
        sourceProvenancePath = try container.decodeIfPresent(String.self, forKey: .sourceProvenancePath)
    }

    public static func == (lhs: ProvenanceFileDescriptor, rhs: ProvenanceFileDescriptor) -> Bool {
        lhs.path == rhs.path
            && lhs.checksumSHA256 == rhs.checksumSHA256
            && lhs.fileSize == rhs.fileSize
            && lhs.format == rhs.format
            && lhs.role == rhs.role
            && lhs.originPath == rhs.originPath
            && lhs.sourceProvenancePath == rhs.sourceProvenancePath
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(path, forKey: .path)
        try container.encodeIfPresent(checksumSHA256, forKey: .checksumSHA256)
        try container.encodeIfPresent(checksumSHA256, forKey: .sha256)
        try container.encodeIfPresent(fileSize, forKey: .fileSize)
        try container.encodeIfPresent(fileSize, forKey: .sizeBytes)
        try container.encodeIfPresent(format, forKey: .format)
        try container.encode(role, forKey: .role)
        try container.encodeIfPresent(originPath, forKey: .originPath)
        try container.encodeIfPresent(sourceProvenancePath, forKey: .sourceProvenancePath)
    }

    public func withRole(_ role: FileRole) -> ProvenanceFileDescriptor {
        ProvenanceFileDescriptor(
            path: path,
            checksumSHA256: checksumSHA256,
            fileSize: fileSize,
            format: format,
            role: role,
            originPath: originPath,
            sourceProvenancePath: sourceProvenancePath
        )
    }

    public static func file(
        url: URL,
        format: FileFormat? = nil,
        role: FileRole = .input,
        originPath: String? = nil,
        sourceProvenancePath: String? = nil
    ) throws -> ProvenanceFileDescriptor {
        try ProvenanceFileDescriptor(
            path: url.path,
            checksumSHA256: ProvenanceFileHasher.sha256(of: url),
            fileSize: ProvenanceFileHasher.fileSize(of: url),
            format: format,
            role: role,
            originPath: originPath,
            sourceProvenancePath: sourceProvenancePath
        )
    }
}

#if DEBUG
extension ProvenanceEnvelope {
    public static func fixture(
        workflowName: String = "fixture.workflow",
        toolName: String = "fixture-tool",
        toolVersion: String = "1.0.0",
        argv: [String] = ["fixture-tool"],
        inputPath: String = "input.fastq",
        outputPath: String = "output.fastq"
    ) -> ProvenanceEnvelope {
        let input = ProvenanceFileDescriptor(
            path: inputPath,
            checksumSHA256: String(repeating: "a", count: 64),
            fileSize: 12,
            format: .fastq,
            role: .input
        )
        let output = ProvenanceFileDescriptor(
            path: outputPath,
            checksumSHA256: String(repeating: "b", count: 64),
            fileSize: 22,
            format: .fastq,
            role: .output
        )
        let step = ProvenanceStep(
            toolName: toolName,
            toolVersion: toolVersion,
            argv: argv,
            inputs: [input],
            outputs: [output],
            exitStatus: 0,
            wallTimeSeconds: 1.25,
            startedAt: Date(timeIntervalSince1970: 0),
            completedAt: Date(timeIntervalSince1970: 1.25)
        )
        let legacyRun = WorkflowRun(
            name: workflowName,
            startTime: Date(timeIntervalSince1970: 0),
            endTime: Date(timeIntervalSince1970: 1.25),
            status: .completed,
            appVersion: "Lungfish fixture",
            hostOS: "macOS fixture",
            runtime: WorkflowRuntime(appVersion: "Lungfish fixture", hostOS: "macOS fixture", user: "fixture-user"),
            steps: [
                StepExecution(
                    toolName: toolName,
                    toolVersion: toolVersion,
                    command: argv,
                    inputs: [FileRecord(provenanceFile: input)],
                    outputs: [FileRecord(provenanceFile: output)],
                    exitCode: 0,
                    wallTime: 1.25,
                    stderr: "fixture stderr"
                )
            ]
        )
        return ProvenanceEnvelope(
            createdAt: Date(timeIntervalSince1970: 0),
            workflowName: workflowName,
            workflowVersion: "fixture-workflow-version",
            toolName: toolName,
            toolVersion: toolVersion,
            tool: ProvenanceToolIdentity(name: toolName, version: toolVersion, kind: "cli"),
            argv: argv,
            runtimeIdentity: .fixture(),
            files: [input, output],
            output: output,
            outputs: [output],
            steps: [step],
            wallTimeSeconds: 1.25,
            exitStatus: 0,
            stderr: "fixture stderr",
            signatures: [
                ProvenanceSignatureReference(
                    provider: "fixture-provider",
                    provenanceSHA256: String(repeating: "d", count: 64),
                    signaturePath: "fixture.sig",
                    publicKeyPath: "fixture.pub"
                )
            ],
            legacyWorkflowRun: legacyRun
        )
    }
}

extension ProvenanceRuntimeIdentity {
    public static func fixture(
        executablePath: String = "/usr/local/bin/lungfish-cli",
        condaEnvironment: String? = "lungfish"
    ) -> ProvenanceRuntimeIdentity {
        ProvenanceRuntimeIdentity(
            appVersion: "Lungfish fixture",
            executablePath: executablePath,
            processIdentifier: 12345,
            operatingSystemVersion: "macOS fixture",
            architecture: "arm64",
            user: "fixture-user",
            condaEnvironment: condaEnvironment
        )
    }
}
#endif
