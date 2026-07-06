import CryptoKit
import Foundation
import LungfishCore

/// Project-level store for user-editable haplotype definition sets.
///
/// Definition sets live as JSON files under a `Haplotype Definitions/`
/// folder in the project root, with the `.lungfishhaplotypedef.json`
/// suffix. Each file holds one `GenotypeHaplotypeDefinitionSet` (which is
/// already `Codable`). The store surfaces these on-disk user definitions
/// so the genotype workflow + inspector pick them up automatically.
///
/// **Why JSON files (not a single registry blob):** one file per
/// definition set is easier to diff, share, and version in git. Users can
/// drop a colleague's definition file into their `Haplotype Definitions/`
/// folder and it appears in the picker on next open.
public struct HaplotypeDefinitionStore: Sendable {
    public static let folderName = "Haplotype Definitions"
    public static let fileSuffix = ".lungfishhaplotypedef.json"
    public static let provenanceSuffix = ".provenance.json"

    public let projectRoot: URL?

    public init(projectRoot: URL?) {
        self.projectRoot = projectRoot
    }

    /// Absolute URL of the definition-set folder, creating it lazily if a
    /// project root is set. Returns nil when there is no project context.
    public func definitionsFolderURL() -> URL? {
        guard let projectRoot else { return nil }
        return projectRoot.appendingPathComponent(Self.folderName, isDirectory: true)
    }

    /// Ensure the folder exists on disk. Idempotent — safe to call from
    /// the editor sheet whenever the user adds a new definition.
    public func ensureFolderExists() throws {
        guard let url = definitionsFolderURL() else { return }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// All user-defined sets currently on disk, parsed into native
    /// `GenotypeHaplotypeDefinitionSet` values. Sets that fail to decode
    /// are skipped (don't crash the inspector for one malformed file).
    public func loadAllUserSets() -> [GenotypeHaplotypeDefinitionSet] {
        guard let folder = definitionsFolderURL(),
              FileManager.default.fileExists(atPath: folder.path) else {
            return []
        }
        let contents = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return contents
            .filter { $0.lastPathComponent.hasSuffix(Self.fileSuffix) }
            .compactMap { url -> GenotypeHaplotypeDefinitionSet? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder().decode(GenotypeHaplotypeDefinitionSet.self, from: data)
            }
    }

    /// Save a definition set to disk. The file name is derived from the
    /// set ID (path-safe). Overwrites if a file with the same id exists.
    /// Bumps the set's `schemaVersion` and stamps `lastModified` so the
    /// provenance trail can identify which version produced a call.
    public func save(
        _ set: GenotypeHaplotypeDefinitionSet,
        changeNote: String? = nil,
        provenanceContext: HaplotypeDefinitionProvenanceContext? = nil
    ) throws {
        let startedAt = Date()
        try ensureFolderExists()
        guard let url = fileURL(for: set.id) else {
            throw HaplotypeDefinitionStoreError.noProjectRoot
        }
        let priorRecord = try? fileRecord(url: url, role: "input")
        let versioned = GenotypeHaplotypeDefinitionSet(
            id: set.id,
            assayID: set.assayID,
            displayName: set.displayName,
            speciesName: set.speciesName,
            speciesCode: set.speciesCode,
            prefix: set.prefix,
            locusDefinitions: set.locusDefinitions,
            schemaVersion: (set.schemaVersion ?? 0) + 1,
            lastModified: ISO8601DateFormatter().string(from: Date()),
            changeNote: changeNote ?? set.changeNote
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(versioned)
        let fileManager = FileManager.default
        let hadPriorDefinition = fileManager.fileExists(atPath: url.path)
        let priorData = hadPriorDefinition ? try Data(contentsOf: url) : nil

        do {
            try data.write(to: url, options: .atomic)
            try writeSaveProvenance(
                set: versioned,
                outputURL: url,
                priorRecord: priorRecord,
                context: provenanceContext,
                startedAt: startedAt,
                endedAt: Date()
            )
        } catch {
            if let priorData {
                try? priorData.write(to: url, options: .atomic)
            } else if fileManager.fileExists(atPath: url.path) {
                try? fileManager.removeItem(at: url)
            }
            throw error
        }
    }

    /// Remove a user-defined set by id. Does nothing for built-in IDs.
    public func delete(
        id: String,
        provenanceContext: HaplotypeDefinitionProvenanceContext? = nil
    ) throws {
        let startedAt = Date()
        guard let url = fileURL(for: id),
              FileManager.default.fileExists(atPath: url.path) else { return }
        let removedRecord = try fileRecord(url: url, role: "input")
        let removedData = try Data(contentsOf: url)
        do {
            try FileManager.default.removeItem(at: url)
            try writeDeleteProvenance(
                definitionID: id,
                removedRecord: removedRecord,
                context: provenanceContext,
                startedAt: startedAt,
                endedAt: Date()
            )
        } catch {
            if !FileManager.default.fileExists(atPath: url.path) {
                try? removedData.write(to: url, options: .atomic)
            }
            throw error
        }
    }

    public func definitionURL(for id: String) -> URL? {
        fileURL(for: id)
    }

    private func fileURL(for id: String) -> URL? {
        guard let folder = definitionsFolderURL() else { return nil }
        let safeId = id.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return folder.appendingPathComponent(safeId + Self.fileSuffix)
    }

    public func provenanceURL(for id: String) -> URL? {
        fileURL(for: id)?.appendingPathExtension("provenance.json")
    }

    private func writeSaveProvenance(
        set: GenotypeHaplotypeDefinitionSet,
        outputURL: URL,
        priorRecord: HaplotypeDefinitionEditProvenance.FileRecord?,
        context: HaplotypeDefinitionProvenanceContext?,
        startedAt: Date,
        endedAt: Date
    ) throws {
        guard let projectRoot else { return }
        let defaultArgv = [
            "lungfish-gui",
            "save-haplotype-definition",
            "--project", projectRoot.path,
            "--definition-id", set.id,
            "--output", outputURL.path,
        ]
        var explicit = [
            "definitionID": set.id,
            "assayID": set.assayID,
            "displayName": set.displayName,
            "speciesName": set.speciesName,
            "speciesCode": set.speciesCode,
            "changeNote": set.changeNote ?? "",
        ]
        var resolvedDefaults = [
            "folderName": Self.folderName,
            "fileSuffix": Self.fileSuffix,
            "schemaVersion": "\(set.schemaVersion ?? 0)",
            "locusCount": "\(set.locusDefinitions.count)",
            "haplotypeCount": "\(set.locusDefinitions.reduce(0) { $0 + $1.haplotypes.count })",
        ]
        if let context {
            explicit.merge(context.explicitOptions) { _, new in new }
            resolvedDefaults.merge(context.resolvedDefaults) { _, new in new }
        }
        let argv = context?.argv.isEmpty == false ? context?.argv ?? defaultArgv : defaultArgv
        let workflowName = context?.workflowName ?? "Haplotype definition save"
        let toolName = context?.toolName ?? "Lungfish Genome Explorer"
        let inputs = (context?.inputFiles ?? []) + (priorRecord.map { [$0] } ?? [])
        let provenance = HaplotypeDefinitionEditProvenance(
            workflowName: workflowName,
            workflowVersion: Self.currentToolVersion,
            toolName: toolName,
            toolVersion: Self.currentToolVersion,
            argv: argv,
            reproducibleCommand: Self.shellCommand(argv),
            options: .init(
                explicit: explicit,
                resolvedDefaults: resolvedDefaults
            ),
            runtime: .init(
                operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
                user: NSUserName().isEmpty ? nil : NSUserName()
            ),
            inputs: inputs,
            outputs: [try fileRecord(url: outputURL, role: "output")],
            exitStatus: 0,
            startedAt: Self.isoString(startedAt),
            endedAt: Self.isoString(endedAt),
            wallTimeSeconds: endedAt.timeIntervalSince(startedAt),
            stderr: context?.stderr
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(provenance).write(to: outputURL.appendingPathExtension("provenance.json"), options: .atomic)
    }

    private func writeDeleteProvenance(
        definitionID: String,
        removedRecord: HaplotypeDefinitionEditProvenance.FileRecord,
        context: HaplotypeDefinitionProvenanceContext?,
        startedAt: Date,
        endedAt: Date
    ) throws {
        guard let projectRoot,
              let provenanceURL = provenanceURL(for: definitionID) else { return }
        let defaultArgv = [
            "lungfish-gui",
            "delete-haplotype-definition",
            "--project", projectRoot.path,
            "--definition-id", definitionID,
        ]
        var explicit = [
            "definitionID": definitionID,
            "removedPath": removedRecord.path,
        ]
        var resolvedDefaults = [
            "folderName": Self.folderName,
            "fileSuffix": Self.fileSuffix,
        ]
        if let context {
            explicit.merge(context.explicitOptions) { _, new in new }
            resolvedDefaults.merge(context.resolvedDefaults) { _, new in new }
        }
        let argv = context?.argv.isEmpty == false ? context?.argv ?? defaultArgv : defaultArgv
        let workflowName = context?.workflowName ?? "Haplotype definition delete"
        let toolName = context?.toolName ?? "Lungfish Genome Explorer"
        let provenance = HaplotypeDefinitionEditProvenance(
            workflowName: workflowName,
            workflowVersion: Self.currentToolVersion,
            toolName: toolName,
            toolVersion: Self.currentToolVersion,
            argv: argv,
            reproducibleCommand: Self.shellCommand(argv),
            options: .init(
                explicit: explicit,
                resolvedDefaults: resolvedDefaults
            ),
            runtime: .init(
                operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
                user: NSUserName().isEmpty ? nil : NSUserName()
            ),
            inputs: (context?.inputFiles ?? []) + [removedRecord],
            outputs: [],
            exitStatus: 0,
            startedAt: Self.isoString(startedAt),
            endedAt: Self.isoString(endedAt),
            wallTimeSeconds: endedAt.timeIntervalSince(startedAt),
            stderr: context?.stderr
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(provenance).write(to: provenanceURL, options: .atomic)
    }

    private func fileRecord(url: URL, role: String) throws -> HaplotypeDefinitionEditProvenance.FileRecord {
        try Self.fileRecord(url: url, role: role)
    }

    public static func fileRecord(url: URL, role: String) throws -> HaplotypeDefinitionEditProvenance.FileRecord {
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return .init(path: url.path, role: role, checksumSHA256: digest, fileSizeBytes: UInt64(data.count))
    }

    public static var currentToolVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "Lungfish \(version) (\(build))"
    }

    public static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    public static func shellCommand(_ argv: [String]) -> String {
        argv.map { arg in
            guard !arg.isEmpty else { return "''" }
            if arg.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.union(.init(charactersIn: "'\"$\\`"))) == nil {
                return arg
            }
            return "'" + arg.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }.joined(separator: " ")
    }

    /// Registry built from all user-defined sets currently on disk. Each
    /// definition set lives in its own JSON file under the project's
    /// `Haplotype Definitions/` folder (or inside a `.lungfishmhcref`
    /// bundle); there is no compiled-in source any more. Sets are grouped
    /// by `assayID` into assays so the inspector + workflow can resolve a
    /// definition from its id.
    public func mergedRegistry() -> GenotypeHaplotypeDefinitionRegistry {
        let userSets = loadAllUserSets()
        let userByAssay = Dictionary(grouping: userSets, by: \.assayID)
        let assays = userByAssay.keys.sorted().map { assayID in
            GenotypeHaplotypeAssay(
                id: assayID,
                displayName: assayID,
                definitionSets: userByAssay[assayID] ?? []
            )
        }
        return GenotypeHaplotypeDefinitionRegistry(
            assays: assays,
            defaultDefinitionSetID: nil
        )
    }
}

public struct HaplotypeDefinitionEditProvenance: Codable, Equatable, Sendable {
    public struct Options: Codable, Equatable, Sendable {
        public let explicit: [String: String]
        public let resolvedDefaults: [String: String]

        public init(explicit: [String: String], resolvedDefaults: [String: String]) {
            self.explicit = explicit
            self.resolvedDefaults = resolvedDefaults
        }
    }

    public struct Runtime: Codable, Equatable, Sendable {
        public let operatingSystem: String
        public let user: String?

        public init(operatingSystem: String, user: String?) {
            self.operatingSystem = operatingSystem
            self.user = user
        }
    }

    public struct FileRecord: Codable, Equatable, Sendable {
        public let path: String
        public let role: String
        public let checksumSHA256: String
        public let fileSizeBytes: UInt64

        public init(path: String, role: String, checksumSHA256: String, fileSizeBytes: UInt64) {
            self.path = path
            self.role = role
            self.checksumSHA256 = checksumSHA256
            self.fileSizeBytes = fileSizeBytes
        }
    }

    public let schemaVersion: Int
    public let workflowName: String
    public let workflowVersion: String
    public let toolName: String
    public let toolVersion: String
    public let argv: [String]
    public let reproducibleCommand: String
    public let options: Options
    public let runtime: Runtime
    public let inputs: [FileRecord]
    public let outputs: [FileRecord]
    public let exitStatus: Int
    public let startedAt: String
    public let endedAt: String
    public let wallTimeSeconds: TimeInterval
    public let stderr: String?

    public init(
        schemaVersion: Int = 1,
        workflowName: String,
        workflowVersion: String,
        toolName: String,
        toolVersion: String,
        argv: [String],
        reproducibleCommand: String,
        options: Options,
        runtime: Runtime,
        inputs: [FileRecord],
        outputs: [FileRecord],
        exitStatus: Int,
        startedAt: String,
        endedAt: String,
        wallTimeSeconds: TimeInterval,
        stderr: String?
    ) {
        self.schemaVersion = schemaVersion
        self.workflowName = workflowName
        self.workflowVersion = workflowVersion
        self.toolName = toolName
        self.toolVersion = toolVersion
        self.argv = argv
        self.reproducibleCommand = reproducibleCommand
        self.options = options
        self.runtime = runtime
        self.inputs = inputs
        self.outputs = outputs
        self.exitStatus = exitStatus
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.wallTimeSeconds = wallTimeSeconds
        self.stderr = stderr
    }
}

public struct HaplotypeDefinitionProvenanceContext: Equatable, Sendable {
    public let workflowName: String
    public let toolName: String
    public let argv: [String]
    public let explicitOptions: [String: String]
    public let resolvedDefaults: [String: String]
    public let inputFiles: [HaplotypeDefinitionEditProvenance.FileRecord]
    public let stderr: String?

    public init(
        workflowName: String,
        toolName: String = CLICommandIdentity.executableName,
        argv: [String],
        explicitOptions: [String: String] = [:],
        resolvedDefaults: [String: String] = [:],
        inputFiles: [HaplotypeDefinitionEditProvenance.FileRecord] = [],
        stderr: String? = nil
    ) {
        self.workflowName = workflowName
        self.toolName = toolName
        self.argv = argv
        self.explicitOptions = explicitOptions
        self.resolvedDefaults = resolvedDefaults
        self.inputFiles = inputFiles
        self.stderr = stderr
    }
}

public enum HaplotypeDefinitionStoreError: Error, LocalizedError {
    case noProjectRoot

    public var errorDescription: String? {
        switch self {
        case .noProjectRoot:
            return "Open a Lungfish project before adding a haplotype definition set."
        }
    }
}
