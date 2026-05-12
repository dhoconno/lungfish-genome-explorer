// ProvenanceEnvelope.swift - Canonical provenance envelope model
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - ProvenanceJSON

public enum ProvenanceJSON {
    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

enum ProvenanceVersion {
    static func required(_ value: String?, fallback: String = "unknown") -> String {
        let fallbackValue = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedFallback = fallbackValue.isEmpty ? "unknown" : fallbackValue
        guard let value else { return normalizedFallback }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? normalizedFallback : normalized
    }
}

private struct RawProvenanceToolIdentity: Decodable {
    let name: String
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
    public let tool: ProvenanceToolIdentity
    public let argv: [String]
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
        case workflowName
        case workflowVersion
        case toolName
        case toolVersion
        case tool
        case argv
        case reproducibleCommand
        case options
        case runtimeIdentity
        case files
        case output
        case outputs
        case steps
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
        tool: ProvenanceToolIdentity? = nil,
        argv: [String] = [],
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
        self.workflowName = workflowName
        self.workflowVersion = ProvenanceVersion.required(workflowVersion, fallback: WorkflowRun.currentAppVersion)
        self.toolName = toolName
        self.toolVersion = ProvenanceVersion.required(toolVersion)
        self.tool = tool ?? ProvenanceToolIdentity(name: toolName, version: self.toolVersion)
        self.argv = argv
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
        id = try container.decode(UUID.self, forKey: .id)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        workflowName = try container.decode(String.self, forKey: .workflowName)
        workflowVersion = ProvenanceVersion.required(
            try container.decodeIfPresent(String.self, forKey: .workflowVersion),
            fallback: WorkflowRun.currentAppVersion
        )
        toolName = try container.decode(String.self, forKey: .toolName)
        let decodedTool = try container.decodeIfPresent(RawProvenanceToolIdentity.self, forKey: .tool)
        toolVersion = ProvenanceVersion.required(
            try container.decodeIfPresent(String.self, forKey: .toolVersion),
            fallback: decodedTool?.version ?? "unknown"
        )
        if let decodedTool {
            tool = ProvenanceToolIdentity(
                name: decodedTool.name,
                version: ProvenanceVersion.required(decodedTool.version, fallback: toolVersion),
                kind: decodedTool.kind
            )
        } else {
            tool = ProvenanceToolIdentity(name: toolName, version: toolVersion)
        }
        argv = try container.decode([String].self, forKey: .argv)
        reproducibleCommand = try container.decode(String.self, forKey: .reproducibleCommand)
        options = try container.decode(ProvenanceOptions.self, forKey: .options)
        runtimeIdentity = try container.decode(ProvenanceRuntimeIdentity.self, forKey: .runtimeIdentity)
        files = try container.decode([ProvenanceFileDescriptor].self, forKey: .files)
        output = try container.decodeIfPresent(ProvenanceFileDescriptor.self, forKey: .output)
        outputs = try container.decode([ProvenanceFileDescriptor].self, forKey: .outputs)
        steps = try container.decode([ProvenanceStep].self, forKey: .steps)
        wallTimeSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .wallTimeSeconds)
        exitStatus = try container.decodeIfPresent(Int.self, forKey: .exitStatus)
        stderr = try container.decodeIfPresent(String.self, forKey: .stderr)
        signatures = try container.decode([ProvenanceSignatureReference].self, forKey: .signatures)
        legacyRun = try container.decodeIfPresent(WorkflowRun.self, forKey: .legacyRun)
    }
}

// MARK: - ProvenanceToolIdentity

public struct ProvenanceToolIdentity: Codable, Sendable, Equatable {
    public let name: String
    public let version: String
    public let kind: String?

    private enum CodingKeys: String, CodingKey {
        case name
        case version
        case kind
    }

    public init(name: String, version: String = "unknown", kind: String? = nil) {
        self.name = name
        self.version = ProvenanceVersion.required(version)
        self.kind = kind
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        version = ProvenanceVersion.required(try container.decodeIfPresent(String.self, forKey: .version))
        kind = try container.decodeIfPresent(String.self, forKey: .kind)
    }
}

// MARK: - ProvenanceOptions

public struct ProvenanceOptions: Codable, Sendable, Equatable {
    public let explicit: [String: ParameterValue]
    public let defaults: [String: ParameterValue]
    public let resolvedDefaults: [String: ParameterValue]

    public init(
        explicit: [String: ParameterValue] = [:],
        defaults: [String: ParameterValue] = [:],
        resolvedDefaults: [String: ParameterValue] = [:]
    ) {
        self.explicit = explicit
        self.defaults = defaults
        self.resolvedDefaults = resolvedDefaults
    }
}

// MARK: - ProvenanceRuntimeIdentity

public struct ProvenanceRuntimeIdentity: Codable, Sendable, Equatable {
    public let appVersion: String
    public let executablePath: String
    public let processIdentifier: Int
    public let operatingSystemVersion: String
    public let architecture: String
    public let gitRevision: String?
    public let user: String?
    public let condaEnvironment: String?
    public let condaPrefix: String?
    public let pluginPack: String?
    public let containerImage: String?
    public let containerDigest: String?

    private enum CodingKeys: String, CodingKey {
        case appVersion
        case executablePath
        case processIdentifier
        case operatingSystemVersion
        case architecture
        case gitRevision
        case user
        case condaEnvironment
        case condaPrefix
        case pluginPack
        case containerImage
        case containerDigest
    }

    public init(
        appVersion: String = WorkflowRun.currentAppVersion,
        executablePath: String = Self.currentExecutablePath,
        processIdentifier: Int = Int(ProcessInfo.processInfo.processIdentifier),
        operatingSystemVersion: String = WorkflowRun.currentHostOS,
        architecture: String = Self.currentArchitecture,
        gitRevision: String? = nil,
        user: String? = nil,
        condaEnvironment: String? = nil,
        condaPrefix: String? = nil,
        pluginPack: String? = nil,
        containerImage: String? = nil,
        containerDigest: String? = nil
    ) {
        self.appVersion = ProvenanceVersion.required(appVersion, fallback: WorkflowRun.currentAppVersion)
        self.executablePath = ProvenanceVersion.required(executablePath, fallback: Self.currentExecutablePath)
        self.processIdentifier = processIdentifier
        self.operatingSystemVersion = ProvenanceVersion.required(operatingSystemVersion, fallback: WorkflowRun.currentHostOS)
        self.architecture = ProvenanceVersion.required(architecture, fallback: Self.currentArchitecture)
        self.gitRevision = gitRevision
        self.user = user
        self.condaEnvironment = condaEnvironment
        self.condaPrefix = condaPrefix
        self.pluginPack = pluginPack
        self.containerImage = containerImage
        self.containerDigest = containerDigest
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        appVersion = ProvenanceVersion.required(
            try container.decodeIfPresent(String.self, forKey: .appVersion),
            fallback: WorkflowRun.currentAppVersion
        )
        executablePath = ProvenanceVersion.required(
            try container.decodeIfPresent(String.self, forKey: .executablePath),
            fallback: Self.currentExecutablePath
        )
        processIdentifier = try container.decodeIfPresent(Int.self, forKey: .processIdentifier)
            ?? Int(ProcessInfo.processInfo.processIdentifier)
        operatingSystemVersion = ProvenanceVersion.required(
            try container.decodeIfPresent(String.self, forKey: .operatingSystemVersion),
            fallback: WorkflowRun.currentHostOS
        )
        architecture = ProvenanceVersion.required(
            try container.decodeIfPresent(String.self, forKey: .architecture),
            fallback: Self.currentArchitecture
        )
        gitRevision = try container.decodeIfPresent(String.self, forKey: .gitRevision)
        user = try container.decodeIfPresent(String.self, forKey: .user)
        condaEnvironment = try container.decodeIfPresent(String.self, forKey: .condaEnvironment)
        condaPrefix = try container.decodeIfPresent(String.self, forKey: .condaPrefix)
        pluginPack = try container.decodeIfPresent(String.self, forKey: .pluginPack)
        containerImage = try container.decodeIfPresent(String.self, forKey: .containerImage)
        containerDigest = try container.decodeIfPresent(String.self, forKey: .containerDigest)
    }

    public static var currentExecutablePath: String {
        ProvenanceVersion.required(
            Bundle.main.executablePath ?? CommandLine.arguments.first,
            fallback: "unknown"
        )
    }

    public static var currentArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
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

    public init(
        path: String,
        checksumSHA256: String? = nil,
        fileSize: UInt64? = nil,
        format: FileFormat? = nil,
        role: FileRole = .input,
        originPath: String? = nil,
        sourceProvenancePath: String? = nil
    ) {
        self.path = path
        self.checksumSHA256 = checksumSHA256
        self.fileSize = fileSize
        self.format = format
        self.role = role
        self.originPath = originPath
        self.sourceProvenancePath = sourceProvenancePath
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
        role = try container.decodeIfPresent(FileRole.self, forKey: .role) ?? .input
        originPath = try container.decodeIfPresent(String.self, forKey: .originPath)
        sourceProvenancePath = try container.decodeIfPresent(String.self, forKey: .sourceProvenancePath)
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
}

// MARK: - ProvenanceStep

public struct ProvenanceStep: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let toolName: String
    public let toolVersion: String
    public let argv: [String]
    public let reproducibleCommand: String
    public let inputs: [ProvenanceFileDescriptor]
    public let outputs: [ProvenanceFileDescriptor]
    public let exitStatus: Int?
    public let wallTimeSeconds: TimeInterval?
    public let stderr: String?
    public let dependsOn: [UUID]
    public let startedAt: Date?
    public let completedAt: Date?

    private enum CodingKeys: String, CodingKey {
        case id
        case toolName
        case toolVersion
        case argv
        case reproducibleCommand
        case inputs
        case outputs
        case exitStatus
        case wallTimeSeconds
        case stderr
        case dependsOn
        case startedAt
        case completedAt
    }

    public init(
        id: UUID = UUID(),
        toolName: String,
        toolVersion: String = "unknown",
        argv: [String] = [],
        reproducibleCommand: String? = nil,
        inputs: [ProvenanceFileDescriptor] = [],
        outputs: [ProvenanceFileDescriptor] = [],
        exitStatus: Int? = nil,
        wallTimeSeconds: TimeInterval? = nil,
        stderr: String? = nil,
        dependsOn: [UUID] = [],
        startedAt: Date? = nil,
        completedAt: Date? = nil
    ) {
        self.id = id
        self.toolName = toolName
        self.toolVersion = ProvenanceVersion.required(toolVersion)
        self.argv = argv
        self.reproducibleCommand = reproducibleCommand ?? argv.map(shellEscape).joined(separator: " ")
        self.inputs = inputs
        self.outputs = outputs
        self.exitStatus = exitStatus
        self.wallTimeSeconds = wallTimeSeconds
        self.stderr = stderr
        self.dependsOn = dependsOn
        self.startedAt = startedAt
        self.completedAt = completedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        toolName = try container.decode(String.self, forKey: .toolName)
        toolVersion = ProvenanceVersion.required(try container.decodeIfPresent(String.self, forKey: .toolVersion))
        argv = try container.decode([String].self, forKey: .argv)
        reproducibleCommand = try container.decode(String.self, forKey: .reproducibleCommand)
        inputs = try container.decode([ProvenanceFileDescriptor].self, forKey: .inputs)
        outputs = try container.decode([ProvenanceFileDescriptor].self, forKey: .outputs)
        exitStatus = try container.decodeIfPresent(Int.self, forKey: .exitStatus)
        wallTimeSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .wallTimeSeconds)
        stderr = try container.decodeIfPresent(String.self, forKey: .stderr)
        dependsOn = try container.decodeIfPresent([UUID].self, forKey: .dependsOn) ?? []
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
    }
}

// MARK: - ProvenanceSignatureReference

public struct ProvenanceSignatureReference: Codable, Sendable, Equatable {
    public let provider: String
    public let provenanceSHA256: String
    public let signaturePath: String
    public let publicKeyPath: String?

    public init(provider: String, provenanceSHA256: String, signaturePath: String, publicKeyPath: String? = nil) {
        self.provider = provider
        self.provenanceSHA256 = provenanceSHA256
        self.signaturePath = signaturePath
        self.publicKeyPath = publicKeyPath
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
            wallTimeSeconds: 1.25
        )
        let legacyRun = WorkflowRun(
            name: workflowName,
            startTime: Date(timeIntervalSince1970: 0),
            endTime: Date(timeIntervalSince1970: 1.25),
            status: .completed,
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
