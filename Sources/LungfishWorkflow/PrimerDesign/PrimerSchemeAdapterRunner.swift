import CryptoKit
import Foundation
import LungfishCore
import LungfishIO

public enum PrimerSchemeAdapterGrouping: String, Codable, Sendable { case perInput, combined }

public struct PrimerSchemeAdapterInput: Codable, Equatable, Sendable {
    public var id: UUID
    public var label: String
    public var path: String
    public init(id: UUID, label: String, path: String) {
        self.id = id; self.label = label; self.path = path
    }

    private enum CodingKeys: String, CodingKey { case id, label, path }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let rawID = try values.decode(String.self, forKey: .id)
        guard let id = UUID(uuidString: rawID) else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: values,
                                                   debugDescription: "Invalid UUID")
        }
        self.init(id: id, label: try values.decode(String.self, forKey: .label),
                  path: try values.decode(String.self, forKey: .path))
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id.uuidString.lowercased(), forKey: .id)
        try values.encode(label, forKey: .label)
        try values.encode(path, forKey: .path)
    }
}

public struct PrimerSchemeAdapterRequest: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public var schemaVersion: Int
    public var engine: PrimerSchemeEngine
    public var engineVersion: String
    public var analysisID: UUID
    public var runID: UUID
    public var resultID: UUID
    public var mode: PrimerSchemeMode
    public var grouping: PrimerSchemeAdapterGrouping
    public var inputs: [PrimerSchemeAdapterInput]
    public var outputDirectory: String
    public var options: [String: PrimerSchemeJSONValue]
    public init(schemaVersion: Int = Self.currentSchemaVersion, engine: PrimerSchemeEngine,
                engineVersion: String, analysisID: UUID, runID: UUID, resultID: UUID,
                mode: PrimerSchemeMode, grouping: PrimerSchemeAdapterGrouping,
                inputs: [PrimerSchemeAdapterInput], outputDirectory: String,
                options: [String: PrimerSchemeJSONValue]) {
        self.schemaVersion = schemaVersion; self.engine = engine; self.engineVersion = engineVersion
        self.analysisID = analysisID; self.runID = runID; self.resultID = resultID
        self.mode = mode; self.grouping = grouping; self.inputs = inputs
        self.outputDirectory = outputDirectory; self.options = options
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, engine, engineVersion, analysisID, runID, resultID, mode
        case grouping, inputs, outputDirectory, options
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        func uuid(_ key: CodingKeys) throws -> UUID {
            let raw = try values.decode(String.self, forKey: key)
            guard let value = UUID(uuidString: raw) else {
                throw DecodingError.dataCorruptedError(forKey: key, in: values,
                                                       debugDescription: "Invalid UUID")
            }
            return value
        }
        self.init(schemaVersion: try values.decode(Int.self, forKey: .schemaVersion),
                  engine: try values.decode(PrimerSchemeEngine.self, forKey: .engine),
                  engineVersion: try values.decode(String.self, forKey: .engineVersion),
                  analysisID: try uuid(.analysisID), runID: try uuid(.runID),
                  resultID: try uuid(.resultID),
                  mode: try values.decode(PrimerSchemeMode.self, forKey: .mode),
                  grouping: try values.decode(PrimerSchemeAdapterGrouping.self, forKey: .grouping),
                  inputs: try values.decode([PrimerSchemeAdapterInput].self, forKey: .inputs),
                  outputDirectory: try values.decode(String.self, forKey: .outputDirectory),
                  options: try values.decode([String: PrimerSchemeJSONValue].self, forKey: .options))
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schemaVersion, forKey: .schemaVersion)
        try values.encode(engine, forKey: .engine)
        try values.encode(engineVersion, forKey: .engineVersion)
        try values.encode(analysisID.uuidString.lowercased(), forKey: .analysisID)
        try values.encode(runID.uuidString.lowercased(), forKey: .runID)
        try values.encode(resultID.uuidString.lowercased(), forKey: .resultID)
        try values.encode(mode, forKey: .mode)
        try values.encode(grouping, forKey: .grouping)
        try values.encode(inputs, forKey: .inputs)
        try values.encode(outputDirectory, forKey: .outputDirectory)
        try values.encode(options, forKey: .options)
    }
}

public struct PrimerSchemeAdapterCommand: Sendable {
    public let executableURL: URL
    public let arguments: [String]
    public let request: PrimerSchemeAdapterRequest
    public let requestURL: URL
    public let adapterDirectoryURL: URL
    public let outputDirectoryURL: URL
    public let workingDirectoryURL: URL
    public let environment: [String: String]
}

public struct PrimerSchemeAdapterExecution: Sendable {
    public let argv: [String]
    public let stdout: String
    public let stderr: String
    public let exitStatus: Int32
    public let runtime: ProvenanceRuntimeIdentity
    public let startedAt: Date
    public let endedAt: Date
    public init(argv: [String], stdout: String, stderr: String, exitStatus: Int32,
                runtime: ProvenanceRuntimeIdentity, startedAt: Date, endedAt: Date) {
        self.argv = argv; self.stdout = stdout; self.stderr = stderr; self.exitStatus = exitStatus
        self.runtime = runtime; self.startedAt = startedAt; self.endedAt = endedAt
    }
}

public typealias PrimerSchemeAdapterRunner = @Sendable (PrimerSchemeAdapterCommand) async throws -> PrimerSchemeAdapterExecution

public enum PrimerSchemeAdapterResources {
    public static func bundledV1URL() throws -> URL {
        guard let url = RuntimeResourceLocator.path("PrimerDesignAdapters/v1", in: .workflow) else {
            throw PrimerSchemeDesignError.invalidRequest("Bundled primer-design adapter v1 is missing.")
        }
        return url
    }

    static func copyV1(from source: URL, to destination: URL) throws {
        try PrimerSchemeInputPreparation.copySource(source, to: destination)
        for required in ["run.py", "common.py", "olivar_adapter.py", "varvamp_adapter.py", "contract.json"] {
            guard FileManager.default.fileExists(atPath: destination.appendingPathComponent(required).path) else {
                throw PrimerSchemeDesignError.invalidRequest("Primer adapter is incomplete: missing \(required).")
            }
        }
    }

    public static func directorySHA256(_ directory: URL) throws -> String {
        let canonicalRoot = directory.resolvingSymlinksInPath().standardizedFileURL
        let rootPrefix = canonicalRoot.path + "/"
        let files = try PrimerSchemeInputPreparation.regularFiles(in: canonicalRoot)
            .filter { !$0.pathComponents.contains("__pycache__") }
            .map { $0.resolvingSymlinksInPath().standardizedFileURL }
            .sorted { $0.path < $1.path }
        var hasher = SHA256()
        for file in files {
            guard file.path.hasPrefix(rootPrefix) else {
                throw PrimerSchemeDesignError.invalidRequest(
                    "Primer adapter digest encountered a file outside its copied directory.")
            }
            let relative = String(file.path.dropFirst(rootPrefix.count))
            let data = try Data(contentsOf: file)
            var pathLength = UInt64(relative.utf8.count).bigEndian
            withUnsafeBytes(of: &pathLength) { hasher.update(bufferPointer: $0) }
            hasher.update(data: Data(relative.utf8))
            var contentLength = UInt64(data.count).bigEndian
            withUnsafeBytes(of: &contentLength) { hasher.update(bufferPointer: $0) }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

extension PrimerSchemeAdapterExecution {
    static func execute(_ command: PrimerSchemeAdapterCommand) async throws -> Self {
        let startedAt = Date()
        let result = try await NativeToolRunner.shared.runProcess(
            executableURL: command.executableURL, arguments: command.arguments,
            workingDirectory: command.workingDirectoryURL, environment: command.environment,
            timeout: 86_400, toolName: "LGE \(command.request.engine.rawValue) primer adapter",
            maxStderrBytes: 4 * 1_024 * 1_024)
        return .init(
            argv: result.arguments.isEmpty ? [command.executableURL.path] + command.arguments : result.arguments,
            stdout: result.stdout, stderr: result.stderr, exitStatus: result.exitCode,
            runtime: .init(executablePath: command.executableURL.path,
                           condaEnvironment: command.request.engine.rawValue,
                           condaPrefix: command.executableURL.deletingLastPathComponent()
                            .deletingLastPathComponent().path,
                           pluginPack: "pcr-primer-design"),
            startedAt: startedAt, endedAt: Date())
    }
}

public struct PrimerSchemeAdapterProvenance: Codable, Equatable, Sendable {
    public struct Command: Codable, Equatable, Sendable {
        public var executable: String
        public var argv: [String]
        public var replayCommand: String
        public var workingDirectory: String
        public var environment: [String: String]
        public var nativeInvocations: [[String]]
        public var pathMappings: [PrimerSchemeJSONValue]
        public var durableReplay: [String: PrimerSchemeJSONValue]
    }
    public struct Settings: Codable, Equatable, Sendable {
        public var supplied: [String: PrimerSchemeJSONValue]
        public var resolved: [String: PrimerSchemeJSONValue]
    }
    public struct SourceVerification: Codable, Equatable, Sendable {
        public var path: String
        public var sha256: String
        public var expectedSHA256: String
        public var byteSize: UInt64
    }
    public struct CondaPackageRecord: Codable, Equatable, Sendable {
        public var path: String
        public var sha256: String
        public var byteSize: UInt64
        public var name: String
        public var version: String
        public var build: String
        public var channel: String
        public var subdir: String
        public var url: String
    }
    public struct Runtime: Codable, Equatable, Sendable {
        public var pythonExecutable: String
        public var pythonVersion: String
        public var platform: String
        public var implementation: String
        public var engineModulePath: String
        public var sourceVerification: [SourceVerification]
        public var environmentPrefix: String
        public var distribution: String
        public var condaPackageRecord: CondaPackageRecord
    }
    public struct Input: Codable, Equatable, Sendable {
        public var id: UUID
        public var path: String
        public var sha256: String
        public var byteSize: UInt64
    }
    public struct AuxiliaryInput: Codable, Equatable, Sendable {
        public var kind: String
        public var prefix: String
        public var path: String
        public var sha256: String
        public var byteSize: UInt64
    }
    public struct IntegrityObservation: Codable, Equatable, Sendable {
        public var id: UUID?
        public var kind: String?
        public var path: String
        public var sha256: String?
        public var byteSize: UInt64?
        public var unchanged: Bool
        public var error: String?
    }
    public struct InputIntegrity: Codable, Equatable, Sendable {
        public var checkedBeforeExecution: Bool
        public var checkedAfterExecution: Bool
        public var unchanged: Bool
        public var postExecution: [IntegrityObservation]
    }
    public struct NativeEvent: Codable, Equatable, Sendable {
        public var engine: PrimerSchemeEngine
        public var kind: String
        public var module: String
        public var modulePath: String?
        public var function: String
        public var arguments: [String: PrimerSchemeJSONValue]
        public var status: String
        public var startedAt: String
        public var finishedAt: String
        public var wallTimeSeconds: Double
        public var exitStatus: Int32?
        public var error: PrimerSchemeJSONValue?
        public var result: PrimerSchemeJSONValue?
        public var adapterContext: PrimerSchemeJSONValue?
        public var durableArguments: [String: PrimerSchemeJSONValue]
        public var durableResult: PrimerSchemeJSONValue?
    }
    public var schemaVersion: Int
    public var adapterVersion: String
    public var adapterSHA256: String
    public var engine: PrimerSchemeEngine
    public var engineVersion: String
    public var analysisID: UUID
    public var runID: UUID
    public var resultID: UUID
    public var command: Command
    public var settings: Settings
    public var runtime: Runtime
    public var inputs: [Input]
    public var auxiliaryInputs: [AuxiliaryInput]
    public var inputIntegrity: InputIntegrity
    public var outputs: [PrimerSchemeArtifact]
    public var nativeEvents: [NativeEvent]
    public var startedAt: String
    public var finishedAt: String
    public var wallTimeSeconds: Double
    public var exitStatus: Int32
    public var stdoutPath: String
    public var stderrPath: String
}

public struct PrimerSchemeVerifiedAdapterOutput: Sendable {
    public let document: PrimerSchemeResultsDocument
    public let provenance: PrimerSchemeAdapterProvenance
    public let projections: [String: PrimerBindingProjection]
}

public enum PrimerSchemeAdapterResultLoader {
    public static func loadVerified(
        outputDirectory: URL, command: PrimerSchemeAdapterCommand,
        options: PrimerSchemeDesignOptions
    ) throws -> PrimerSchemeVerifiedAdapterOutput {
        let resultURL = outputDirectory.appendingPathComponent("adapter-result-v1.json")
        let document = try JSONDecoder().decode(
            PrimerSchemeResultsDocument.self, from: Data(contentsOf: resultURL))
        guard document.analysisID == command.request.analysisID,
              document.runID == command.request.runID,
              document.resultID == command.request.resultID,
              document.engine == command.request.engine,
              document.engineVersion == command.request.engineVersion,
              document.mode == command.request.mode else {
            throw PrimerSchemeDesignError.contractViolation("Adapter result identity or resolved options differ from the exact request.")
        }
        let resolutionKeys = Set(document.resolvedOptions.keys).subtracting(command.request.options.keys)
        guard resolutionKeys == ["adapterResolution"],
              command.request.options.allSatisfy({ document.resolvedOptions[$0.key] == $0.value }) else {
            throw PrimerSchemeDesignError.contractViolation("Adapter resolved settings do not extend the exact request with adapterResolution.")
        }
        var paths = Set<String>()
        for artifact in document.artifacts {
            guard PrimerSchemeResultsDocument.safeRelativePath(artifact.path),
                  paths.insert(artifact.path).inserted,
                  artifact.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
                  !artifact.kind.isEmpty else {
                throw PrimerSchemeDesignError.contractViolation("Adapter artifact inventory contains an unsafe or duplicate entry.")
            }
            let url = outputDirectory.appendingPathComponent(artifact.path)
            guard try ProvenanceFileHasher.sha256(of: url) == artifact.sha256,
                  try ProvenanceFileHasher.fileSize(of: url) == artifact.byteSize else {
                throw PrimerSchemeDesignError.contractViolation("Adapter artifact hash or size changed: \(artifact.path)")
            }
        }
        let actualPayloadPaths = Set(try PrimerSchemeInputPreparation.regularFiles(in: outputDirectory)
            .map { PrimerSchemeInputPreparation.relative($0, to: outputDirectory) }
            .filter { $0 != "adapter-result-v1.json" && $0 != document.provenancePath })
        guard actualPayloadPaths == paths else {
            throw PrimerSchemeDesignError.contractViolation(
                "Adapter artifact inventory does not exactly cover every published native file.")
        }
        guard PrimerSchemeResultsDocument.safeRelativePath(document.provenancePath) else {
            throw PrimerSchemeDesignError.contractViolation("Adapter provenance path is unsafe.")
        }
        let provenance = try JSONDecoder().decode(
            PrimerSchemeAdapterProvenance.self,
            from: Data(contentsOf: outputDirectory.appendingPathComponent(document.provenancePath)))
        guard provenance.schemaVersion == 1, provenance.adapterVersion == document.adapterVersion,
              provenance.engine == document.engine, provenance.engineVersion == document.engineVersion,
              provenance.analysisID == document.analysisID, provenance.runID == document.runID,
              provenance.resultID == document.resultID else {
            throw PrimerSchemeDesignError.contractViolation(
                "Adapter provenance envelope identity is inconsistent.")
        }
        let copiedAdapterDigest = try PrimerSchemeAdapterResources.directorySHA256(
            command.adapterDirectoryURL)
        guard provenance.adapterSHA256 == copiedAdapterDigest else {
            throw PrimerSchemeDesignError.contractViolation(
                "Adapter provenance digest \(provenance.adapterSHA256) differs from copied adapter digest \(copiedAdapterDigest).")
        }
        guard provenance.command.argv == command.arguments.prepending(command.executableURL.path),
              provenance.command.executable == command.executableURL.path else {
            throw PrimerSchemeDesignError.contractViolation(
                "Adapter provenance command differs from the launched argv.")
        }
        guard provenance.settings.supplied == command.request.options,
              provenance.settings.resolved == document.resolvedOptions else {
            throw PrimerSchemeDesignError.contractViolation(
                "Adapter provenance settings differ from the request or result.")
        }
        guard provenance.outputs == document.artifacts, provenance.exitStatus == 0 else {
            throw PrimerSchemeDesignError.contractViolation(
                "Adapter provenance output inventory or exit status is inconsistent.")
        }
        guard
              provenance.inputIntegrity.checkedBeforeExecution,
              provenance.inputIntegrity.checkedAfterExecution,
              provenance.inputIntegrity.unchanged,
              !provenance.command.pathMappings.isEmpty,
              !provenance.command.durableReplay.isEmpty,
              !provenance.nativeEvents.isEmpty,
              provenance.wallTimeSeconds.isFinite, provenance.wallTimeSeconds >= 0,
              PrimerSchemeResultsDocument.safeRelativePath(provenance.stdoutPath),
              PrimerSchemeResultsDocument.safeRelativePath(provenance.stderrPath) else {
            throw PrimerSchemeDesignError.contractViolation(
                "Adapter provenance durable replay, input integrity, native events, or timing are inconsistent.")
        }
        let expectedInputs = Dictionary(uniqueKeysWithValues: command.request.inputs.map { ($0.id, $0) })
        guard provenance.inputs.count == expectedInputs.count else {
            throw PrimerSchemeDesignError.contractViolation("Adapter provenance input count differs from the request.")
        }
        for input in provenance.inputs {
            guard let expected = expectedInputs[input.id], expected.path == input.path,
                  try ProvenanceFileHasher.sha256(of: URL(fileURLWithPath: input.path)) == input.sha256,
                  try ProvenanceFileHasher.fileSize(of: URL(fileURLWithPath: input.path)) == input.byteSize else {
                throw PrimerSchemeDesignError.contractViolation("Adapter provenance input identity or checksum is invalid.")
            }
        }
        let observedPaths = Set(provenance.inputIntegrity.postExecution.compactMap {
            $0.unchanged ? $0.path : nil
        })
        let snapshottedPaths = Set(provenance.inputs.map(\.path)
            + provenance.auxiliaryInputs.map(\.path))
        guard observedPaths == snapshottedPaths else {
            throw PrimerSchemeDesignError.contractViolation(
                "Adapter post-execution input integrity does not match its immutable snapshots.")
        }
        for auxiliary in provenance.auxiliaryInputs {
            let url = URL(fileURLWithPath: auxiliary.path)
            guard auxiliary.kind == "blastDatabaseComponent",
                  auxiliary.prefix == command.request.options["blastDatabasePath"]?.adapterStringValue,
                  try ProvenanceFileHasher.sha256(of: url) == auxiliary.sha256,
                  try ProvenanceFileHasher.fileSize(of: url) == auxiliary.byteSize else {
                throw PrimerSchemeDesignError.contractViolation(
                    "Adapter auxiliary-input provenance is incomplete or changed.")
            }
        }
        let hasBlastDatabase = command.request.options["blastDatabasePath"]?.adapterStringValue != nil
        guard (hasBlastDatabase ? !provenance.auxiliaryInputs.isEmpty
                                : provenance.auxiliaryInputs.isEmpty),
              provenance.nativeEvents.allSatisfy({
                  $0.engine == command.request.engine && $0.status == "succeeded"
                      && $0.exitStatus == 0 && $0.wallTimeSeconds.isFinite
                      && $0.wallTimeSeconds >= 0 && !$0.kind.isEmpty
                      && !$0.module.isEmpty && !$0.function.isEmpty
                      && $0.arguments.values.allSatisfy(\.isFinite)
                      && $0.durableArguments.values.allSatisfy(\.isFinite)
              }),
              command.request.engine == .olivar
                ? provenance.command.nativeInvocations.isEmpty
                : !provenance.command.nativeInvocations.isEmpty else {
            throw PrimerSchemeDesignError.contractViolation(
                "Adapter native events, invocations, or auxiliary-input inventory are invalid.")
        }
        guard !provenance.runtime.sourceVerification.isEmpty,
              provenance.runtime.pythonExecutable == command.executableURL.path,
              provenance.runtime.environmentPrefix == command.executableURL
                .deletingLastPathComponent().deletingLastPathComponent().path,
              provenance.runtime.distribution == expectedDistribution(for: command.request.engine) else {
            throw PrimerSchemeDesignError.contractViolation("Adapter provenance lacks upstream source verification.")
        }
        for source in provenance.runtime.sourceVerification {
            guard source.sha256 == source.expectedSHA256,
                  try ProvenanceFileHasher.sha256(of: URL(fileURLWithPath: source.path)) == source.sha256,
                  try ProvenanceFileHasher.fileSize(of: URL(fileURLWithPath: source.path)) == source.byteSize else {
                throw PrimerSchemeDesignError.contractViolation("Verified upstream source changed: \(source.path)")
            }
        }
        let record = provenance.runtime.condaPackageRecord
        let recordURL = URL(fileURLWithPath: record.path)
        let metadataRoot = URL(fileURLWithPath: provenance.runtime.environmentPrefix)
            .appendingPathComponent("conda-meta", isDirectory: true).standardizedFileURL.path + "/"
        guard recordURL.standardizedFileURL.path.hasPrefix(metadataRoot),
              try ProvenanceFileHasher.sha256(of: recordURL) == record.sha256,
              try ProvenanceFileHasher.fileSize(of: recordURL) == record.byteSize,
              record.name == command.request.engine.rawValue,
              record.version == command.request.engineVersion,
              record.build == expectedBuild(for: command.request.engine),
              record.channel == "bioconda", record.subdir == "noarch",
              URL(string: record.url)?.scheme == "https" else {
            throw PrimerSchemeDesignError.contractViolation("Pinned conda package evidence is invalid.")
        }

        var projections: [String: PrimerBindingProjection] = [:]
        for result in document.results {
            for target in result.targets {
                guard document.artifacts.contains(where: { $0.path == target.referencePath }),
                      document.artifacts.contains(where: { $0.path == target.bindingProjectionPath }) else {
                    throw PrimerSchemeDesignError.contractViolation("Target references an artifact absent from the adapter inventory.")
                }
                let projection = try JSONDecoder().decode(
                    PrimerBindingProjection.self,
                    from: Data(contentsOf: outputDirectory.appendingPathComponent(target.bindingProjectionPath)))
                guard projection.sourcePath == expectedInputs[target.sourceInputID]?.path else {
                    throw PrimerSchemeDesignError.contractViolation("Binding projection source path differs from the exact executed input.")
                }
                let rows = try Primer3InputLoader.readAlignedRows(
                    at: outputDirectory.appendingPathComponent(target.referencePath), allowingRNAU: false)
                guard rows.count == 1, rows[0].sequence.count == target.referenceLength,
                      !rows[0].sequence.contains("-"), !rows[0].sequence.contains("."),
                      rows[0].title.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) == target.referenceID else {
                    throw PrimerSchemeDesignError.contractViolation("Generated reference identity or length is invalid.")
                }
                projections[target.bindingProjectionPath] = projection
            }
        }
        try document.validateStructure(
            knownInputIDs: Set(command.request.inputs.map(\.id)), options: options,
            projections: projections)
        return .init(document: document, provenance: provenance, projections: projections)
    }
}

private func expectedDistribution(for engine: PrimerSchemeEngine) -> String {
    switch engine {
    case .olivar: return "bioconda::olivar=1.3.3=pyhdfd78af_3"
    case .varvamp: return "bioconda::varvamp=1.3.2=pyhdfd78af_0"
    }
}

private func expectedBuild(for engine: PrimerSchemeEngine) -> String {
    engine == .olivar ? "pyhdfd78af_3" : "pyhdfd78af_0"
}

private extension Array where Element == String {
    func prepending(_ value: String) -> [String] { [value] + self }
}

private extension PrimerSchemeJSONValue {
    var adapterStringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }
}
