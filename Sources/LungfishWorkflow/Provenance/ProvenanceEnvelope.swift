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

enum ProvenanceName {
    static func required(_ value: String?, fallback: String = "unknown") -> String {
        let fallbackValue = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedFallback = fallbackValue.isEmpty ? "unknown" : fallbackValue
        guard let value else { return normalizedFallback }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? normalizedFallback : normalized
    }
}

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
        case tool
        case argv
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
        self.workflowName = ProvenanceName.required(workflowName)
        self.workflowVersion = ProvenanceVersion.required(workflowVersion, fallback: WorkflowRun.currentAppVersion)
        self.toolName = ProvenanceName.required(toolName)
        self.toolVersion = ProvenanceVersion.required(toolVersion)
        self.tool = ProvenanceToolIdentity(name: self.toolName, version: self.toolVersion, kind: tool?.kind)
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
        try container.encode(tool, forKey: .tool)
        try container.encode(argv, forKey: .argv)
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
        self.name = ProvenanceName.required(name)
        self.version = ProvenanceVersion.required(version)
        self.kind = kind
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = ProvenanceName.required(try container.decodeIfPresent(String.self, forKey: .name))
        version = ProvenanceVersion.required(try container.decodeIfPresent(String.self, forKey: .version))
        kind = try container.decodeIfPresent(String.self, forKey: .kind)
    }
}

// MARK: - ProvenanceOptions

public struct ProvenanceOptions: Codable, Sendable, Equatable {
    public let explicit: [String: ParameterValue]
    public let defaults: [String: ParameterValue]
    public let resolvedDefaults: [String: ParameterValue]

    private enum CodingKeys: String, CodingKey {
        case explicit
        case defaults
        case resolvedDefaults
        case userVisibleOptions
    }

    public init(
        explicit: [String: ParameterValue] = [:],
        defaults: [String: ParameterValue] = [:],
        resolvedDefaults: [String: ParameterValue] = [:]
    ) {
        self.explicit = explicit
        self.defaults = defaults
        self.resolvedDefaults = resolvedDefaults
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var decodedExplicit = try Self.decodeMapIfPresent(from: container, forKey: .explicit) ?? [:]
        let userVisibleOptions = try Self.decodeMapIfPresent(from: container, forKey: .userVisibleOptions) ?? [:]
        let legacyTopLevelOptions = try Self.decodeLegacyTopLevelOptions(from: decoder)
        decodedExplicit.merge(legacyTopLevelOptions) { current, _ in current }
        decodedExplicit.merge(userVisibleOptions) { _, userVisible in userVisible }

        explicit = decodedExplicit
        defaults = try Self.decodeMapIfPresent(from: container, forKey: .defaults) ?? [:]
        resolvedDefaults = try Self.decodeMapIfPresent(from: container, forKey: .resolvedDefaults) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(explicit, forKey: .explicit)
        try container.encode(defaults, forKey: .defaults)
        try container.encode(resolvedDefaults, forKey: .resolvedDefaults)
    }

    private static func decodeMapIfPresent(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) throws -> [String: ParameterValue]? {
        guard container.contains(key) else { return nil }
        let values = try container.decode([String: FlexibleParameterValue].self, forKey: key)
        return values.mapValues(\.value)
    }

    private static func decodeLegacyTopLevelOptions(from decoder: Decoder) throws -> [String: ParameterValue] {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        let reservedKeys: Set<String> = [
            CodingKeys.explicit.stringValue,
            CodingKeys.defaults.stringValue,
            CodingKeys.resolvedDefaults.stringValue,
            CodingKeys.userVisibleOptions.stringValue,
        ]

        var values: [String: ParameterValue] = [:]
        for key in container.allKeys where !reservedKeys.contains(key.stringValue) {
            values[key.stringValue] = try container.decode(FlexibleParameterValue.self, forKey: key).value
        }
        return values
    }

    private struct DynamicCodingKey: CodingKey {
        let stringValue: String
        let intValue: Int?

        init?(stringValue: String) {
            self.stringValue = stringValue
            intValue = nil
        }

        init?(intValue: Int) {
            stringValue = "\(intValue)"
            self.intValue = intValue
        }
    }

    private struct FlexibleParameterValue: Decodable {
        let value: ParameterValue

        init(from decoder: Decoder) throws {
            if let typedValue = try? ParameterValue(from: decoder) {
                value = typedValue
                return
            }

            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                value = .null
            } else if let boolValue = try? container.decode(Bool.self) {
                value = .boolean(boolValue)
            } else if let intValue = try? container.decode(Int.self) {
                value = .integer(intValue)
            } else if let doubleValue = try? container.decode(Double.self) {
                value = .number(doubleValue)
            } else if let stringValue = try? container.decode(String.self) {
                value = .string(stringValue)
            } else if let arrayValue = try? container.decode([FlexibleParameterValue].self) {
                value = .array(arrayValue.map(\.value))
            } else if let dictionaryValue = try? container.decode([String: FlexibleParameterValue].self) {
                value = .dictionary(dictionaryValue.mapValues(\.value))
            } else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Unsupported provenance option value"
                )
            }
        }
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

// MARK: - ProvenanceDirectoryManifest

public struct ProvenanceDirectoryManifest: Codable, Sendable, Equatable {
    public let rootPath: String
    public let files: [ProvenanceFileDescriptor]

    public init(rootPath: String, files: [ProvenanceFileDescriptor]) {
        self.rootPath = rootPath
        self.files = files
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
        case command
        case reproducibleCommand
        case inputs
        case outputs
        case exitStatus
        case exitCode
        case wallTimeSeconds
        case wallTime
        case stderr
        case dependsOn
        case startedAt
        case completedAt
        case startTime
        case endTime
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
        self.toolName = ProvenanceName.required(toolName)
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
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        toolName = ProvenanceName.required(try container.decodeIfPresent(String.self, forKey: .toolName))
        toolVersion = ProvenanceVersion.required(try container.decodeIfPresent(String.self, forKey: .toolVersion))
        argv = try container.decodeIfPresent([String].self, forKey: .argv)
            ?? container.decodeIfPresent([String].self, forKey: .command)
            ?? []
        reproducibleCommand = try container.decodeIfPresent(String.self, forKey: .reproducibleCommand)
            ?? argv.map(shellEscape).joined(separator: " ")
        inputs = try container.decodeIfPresent([ProvenanceFileDescriptor].self, forKey: .inputs) ?? []
        outputs = try container.decodeIfPresent([ProvenanceFileDescriptor].self, forKey: .outputs) ?? []
        exitStatus = try container.decodeIfPresent(Int.self, forKey: .exitStatus)
            ?? container.decodeIfPresent(Int.self, forKey: .exitCode)
        wallTimeSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .wallTimeSeconds)
            ?? container.decodeIfPresent(TimeInterval.self, forKey: .wallTime)
        stderr = try container.decodeIfPresent(String.self, forKey: .stderr)
        dependsOn = try container.decodeIfPresent([UUID].self, forKey: .dependsOn) ?? []
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
            ?? container.decodeIfPresent(Date.self, forKey: .startTime)
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
            ?? container.decodeIfPresent(Date.self, forKey: .endTime)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(toolName, forKey: .toolName)
        try container.encode(toolVersion, forKey: .toolVersion)
        try container.encode(argv, forKey: .argv)
        try container.encode(argv, forKey: .command)
        try container.encode(reproducibleCommand, forKey: .reproducibleCommand)
        try container.encode(inputs, forKey: .inputs)
        try container.encode(outputs, forKey: .outputs)
        try container.encodeIfPresent(exitStatus, forKey: .exitStatus)
        try container.encodeIfPresent(exitStatus, forKey: .exitCode)
        try container.encodeIfPresent(wallTimeSeconds, forKey: .wallTimeSeconds)
        try container.encodeIfPresent(wallTimeSeconds, forKey: .wallTime)
        try container.encodeIfPresent(stderr, forKey: .stderr)
        try container.encode(dependsOn, forKey: .dependsOn)
        try container.encodeIfPresent(startedAt, forKey: .startedAt)
        try container.encodeIfPresent(completedAt, forKey: .completedAt)
        try container.encodeIfPresent(startedAt, forKey: .startTime)
        try container.encodeIfPresent(completedAt, forKey: .endTime)
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
