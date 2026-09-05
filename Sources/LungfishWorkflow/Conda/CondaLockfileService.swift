import Foundation

public protocol CondaLockInstalling: Sendable {
    func install(environment: String, packageSpecs: [String], condaRoot: URL) async throws
}

public struct CondaManagerLockInstaller: CondaLockInstalling {
    private let manager: CondaManager

    public init(manager: CondaManager = .shared) {
        self.manager = manager
    }

    public func install(environment: String, packageSpecs: [String], condaRoot: URL) async throws {
        let resolvedRoot = condaRoot.standardizedFileURL
        let installManager = manager.rootPrefix.standardizedFileURL == resolvedRoot
            ? manager
            : CondaManager(rootPrefix: resolvedRoot)
        try await installManager.install(packages: packageSpecs, environment: environment)
    }
}

public struct CondaLockfileResult: Sendable, Hashable {
    public let lockfileURL: URL
    public let provenanceURL: URL
}

public struct CondaLockInstallResult: Sendable, Hashable {
    public let installedEnvironments: [String]
    public let provenanceURL: URL
}

/// Requested inputs only. No package solve, platform resolution, artifact inventory,
/// or compatibility with an external lock consumer is implied by this document.
public struct CondaRequestedEnvironmentSpecification: Sendable, Codable, Equatable {
    public let kind: String
    public let schemaVersion: Int
    public let resolution: String
    public let packID: String
    public let packName: String
    public let platforms: [String]
    public let channels: [String]
    public let requirements: [PackToolRequirement]
    public let postInstallHooks: [PostInstallHook]

    fileprivate init(pack: PluginPack, platforms: [String], channels: [String]) {
        kind = "lungfish.conda-request-specification"
        schemaVersion = 1
        resolution = "unresolved"
        packID = pack.id
        packName = pack.name
        self.platforms = platforms
        self.channels = channels
        requirements = pack.toolRequirements
        postInstallHooks = pack.postInstallHooks
    }

    fileprivate func validate() throws {
        guard kind == "lungfish.conda-request-specification", schemaVersion == 1,
              resolution == "unresolved" else {
            throw CondaLockfileError.unsupportedSpecification
        }
        guard !packID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !platforms.isEmpty, Set(platforms).count == platforms.count,
              platforms.allSatisfy({ ["osx-arm64", "osx-64", "linux-64", "linux-aarch64", "win-64"].contains($0) }),
              !channels.isEmpty, channels.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              !requirements.isEmpty,
              Set(requirements.map(\.id)).count == requirements.count else {
            throw CondaLockfileError.invalidSpecification("Missing or unsupported pack, platform, channel, or requirement identity.")
        }
        for requirement in requirements {
            guard !requirement.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !requirement.environment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  requirement.managedDatabaseID != nil || !requirement.installPackages.isEmpty,
                  requirement.installPackages.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                throw CondaLockfileError.invalidSpecification("Requirement '\(requirement.id)' has no complete requested environment identity.")
            }
            try requirement.sourceOverlay?.validateRequestedIdentity()
        }
    }
}

public enum CondaLockfileError: Error, LocalizedError, Sendable, Equatable {
    case unsupportedSpecification
    case invalidSpecification(String)
    case exactReconstructionUnsupported

    public var errorDescription: String? {
        switch self {
        case .unsupportedSpecification:
            return "Unsupported environment document; expected Lungfish requested specification version 1."
        case .invalidSpecification(let reason):
            return "Invalid requested environment specification: \(reason)"
        case .exactReconstructionUnsupported:
            return "Conda exact reconstruction from --from-lockfile is unsupported. 'conda lock' exports an unresolved Lungfish requested specification, not a resolved artifact lock. No environment was installed; use the normal pack installation workflow for a fresh solve."
        }
    }
}

public struct CondaLockfileService {
    private let fileManager: FileManager
    private let platforms: [String]
    private let channels: [String]
    // Internal fault-injection seam; nil in normal callers.
    var publicationDidOccur: ((URL) throws -> Void)?

    public init(
        platforms: [String] = ["osx-arm64"],
        channels: [String] = ["conda-forge", "bioconda"],
        fileManager: FileManager = .default
    ) {
        self.platforms = platforms
        self.channels = channels
        self.fileManager = fileManager
    }

    /// Compatibility API name: exports a requested specification, never a resolved lock.
    public func writeLockfile(
        for pack: PluginPack,
        to output: URL,
        commandLine: [String]
    ) throws -> CondaLockfileResult {
        let start = Date()
        let specification = CondaRequestedEnvironmentSpecification(pack: pack, platforms: platforms, channels: channels)
        try specification.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(specification)
        try fileManager.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        let provenanceURL = output.appendingPathExtension("lungfish-provenance.json")
        let stage = output.deletingLastPathComponent().appendingPathComponent(".requested-specification-\(UUID().uuidString)")
        try fileManager.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: stage) }
        let stagedOutput = stage.appendingPathComponent("specification.json")
        let stagedReceipt = stage.appendingPathComponent("provenance.json")
        let publication = try ScientificFilePublicationTransaction(
            protectedURLs: [output, provenanceURL], fileDestinations: [output, provenanceURL])
        do {
            try data.write(to: stagedOutput, options: .atomic)
            let outputRecord = FileRecord(path: output.standardizedFileURL.path,
                sha256: try ProvenanceFileHasher.sha256(of: stagedOutput),
                sizeBytes: try ProvenanceFileHasher.fileSize(of: stagedOutput), format: .text, role: .output)
            _ = try writeProvenance(
                name: "Conda Requested Specification Export",
                toolName: "lungfish conda lock",
                commandLine: commandLine,
                inputs: [],
                outputs: [outputRecord],
                parameters: [
                    "packID": .string(pack.id), "packName": .string(pack.name),
                    "outputPath": .string(output.standardizedFileURL.path),
                    "documentKind": .string(specification.kind), "resolution": .string(specification.resolution),
                    "platforms": .array(platforms.map { .string($0) }),
                    "channels": .array(channels.map { .string($0) }),
                    "runtimeUser": .string(WorkflowRun.currentUser),
                    "runtimeHostName": .string(ProcessInfo.processInfo.hostName),
                ],
                provenanceURL: stagedReceipt,
                start: start, exitCode: 0, stderr: nil
            )
            try publication.publish(stagedURL: stagedOutput, to: output)
            try publicationDidOccur?(output)
            try publication.publish(stagedURL: stagedReceipt, to: provenanceURL)
            try publicationDidOccur?(provenanceURL)
            publication.commit()
            return CondaLockfileResult(lockfileURL: output, provenanceURL: provenanceURL)
        } catch {
            try publication.rollback(after: error)
        }
    }

    public func readSpecification(from input: URL) throws -> CondaRequestedEnvironmentSpecification {
        let specification: CondaRequestedEnvironmentSpecification
        do { specification = try JSONDecoder().decode(CondaRequestedEnvironmentSpecification.self, from: Data(contentsOf: input)) }
        catch let error as CocoaError { throw error }
        catch { throw CondaLockfileError.unsupportedSpecification }
        try specification.validate()
        return specification
    }

    /// Kept so existing callers receive a precise supported-contract error. Never
    /// routes a partial external lock or requested specification to a fresh solver.
    public func install(
        fromLockfile lockfile: URL,
        condaRoot: URL,
        installer: any CondaLockInstalling = CondaManagerLockInstaller(),
        commandLine: [String]
    ) async throws -> CondaLockInstallResult {
        throw CondaLockfileError.exactReconstructionUnsupported
    }

    private func writeProvenance(
        name: String,
        toolName: String,
        commandLine: [String],
        inputs: [FileRecord],
        outputs: [FileRecord],
        parameters: [String: ParameterValue],
        provenanceURL: URL,
        start: Date,
        exitCode: Int32,
        stderr: String?
    ) throws -> URL {
        try fileManager.createDirectory(at: provenanceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let end = Date()
        let step = StepExecution(
            toolName: toolName,
            toolVersion: WorkflowRun.currentAppVersion,
            command: CondaOfflinePackService.redactedCommandLine(commandLine),
            inputs: inputs,
            outputs: outputs,
            exitCode: exitCode,
            wallTime: end.timeIntervalSince(start),
            stderr: stderr,
            startTime: start,
            endTime: end
        )
        let run = WorkflowRun(
            name: name,
            startTime: start,
            endTime: end,
            status: exitCode == 0 ? .completed : .failed,
            steps: [step],
            parameters: parameters
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(run).write(to: provenanceURL, options: .atomic)
        return provenanceURL
    }
}
