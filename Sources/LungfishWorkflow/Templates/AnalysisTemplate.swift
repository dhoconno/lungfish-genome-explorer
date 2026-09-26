// AnalysisTemplate.swift - Workflow template captured from a finished analysis
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation

// MARK: - AnalysisTemplate

/// A reusable workflow template captured from a finished Kraken2 analysis.
///
/// A template records the chain from a root FASTQ import (including the
/// import recipe) through Kraken2 (and Bracken) with every setting pinned to
/// the value that was recorded for the source analysis. Running the template
/// later on new FASTQ files repeats the same steps with the same settings.
///
/// The file is JSON with sorted keys and ISO 8601 dates, saved as
/// `<name>.lungfishtemplate`. It never stores an absolute source path: the
/// origin is recorded relative to the project it came from, and the run
/// supplies inputs, project, sample name and threads.
public struct AnalysisTemplate: Codable, Equatable, Sendable {

    /// The only schema this build reads and writes.
    public static let currentSchemaVersion = 1

    /// File extension for saved templates (no leading dot).
    public static let fileExtension = "lungfishtemplate"

    /// Provenance workflow name of the run-level record written by
    /// ``AnalysisTemplateRunner``.
    public static let runWorkflowName = "lungfish.workflow.template.run"

    // MARK: Nested types

    /// Where the template came from.
    public struct Origin: Codable, Equatable, Sendable {
        /// App version that created the template.
        public var appVersion: String
        /// Source analysis directory relative to its project root.
        public var sourceAnalysisRelativePath: String
        /// Provenance id of the root FASTQ import record, when present.
        public var importProvenanceID: UUID?
        /// Provenance id recorded in the source `classification-result.json`.
        public var classificationProvenanceID: UUID?
        /// SHA-256 of the source import provenance sidecar.
        public var importProvenanceSHA256: String?
        /// SHA-256 of the source `classification-result.json`.
        public var classificationResultSHA256: String?

        public init(
            appVersion: String,
            sourceAnalysisRelativePath: String,
            importProvenanceID: UUID? = nil,
            classificationProvenanceID: UUID? = nil,
            importProvenanceSHA256: String? = nil,
            classificationResultSHA256: String? = nil
        ) {
            self.appVersion = appVersion
            self.sourceAnalysisRelativePath = sourceAnalysisRelativePath
            self.importProvenanceID = importProvenanceID
            self.classificationProvenanceID = classificationProvenanceID
            self.importProvenanceSHA256 = importProvenanceSHA256
            self.classificationResultSHA256 = classificationResultSHA256
        }
    }

    /// The input every run asks for.
    public struct InputSpec: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable {
            case fastq
        }

        public var kind: Kind
        public var platform: SequencingPlatform
        public var pairing: AnalysisTemplatePairing
        /// Number of files one run consumes (2 for paired, otherwise 1).
        public var fileCount: Int

        public init(kind: Kind = .fastq, platform: SequencingPlatform, pairing: AnalysisTemplatePairing) {
            self.kind = kind
            self.platform = platform
            self.pairing = pairing
            self.fileCount = pairing.fileCount
        }

        /// A human-readable description such as "Paired Illumina FASTQ files".
        public var summary: String {
            "\(pairing.displayName) \(platform.displayName) FASTQ file\(fileCount == 1 ? "" : "s")"
        }
    }

    /// One step in the chain, in execution order.
    public enum Step: Equatable, Sendable {
        case importFASTQ(ImportFASTQStepSpec)
        case kraken2(Kraken2StepSpec)

        /// Stable identifier used as the `type` discriminator in JSON.
        public var typeIdentifier: String {
            switch self {
            case .importFASTQ: return "importFASTQ"
            case .kraken2: return "kraken2"
            }
        }

        /// Short title for step lists.
        public var title: String {
            switch self {
            case .importFASTQ(let spec):
                return spec.recipe == nil ? "Import FASTQ" : "Import FASTQ and apply recipe \(spec.recipe?.name ?? "")"
            case .kraken2(let spec):
                return spec.goal == .profile ? "Kraken2 + Bracken" : "Kraken2"
            }
        }

        /// One-line summary of the pinned settings.
        public var settingsSummary: String {
            switch self {
            case .importFASTQ(let spec): return spec.settingsSummary
            case .kraken2(let spec): return spec.settingsSummary
            }
        }
    }

    // MARK: Stored properties

    public var schemaVersion: Int
    public var id: UUID
    public var name: String
    public var createdAt: Date
    public var origin: Origin
    public var input: InputSpec
    public var steps: [Step]
    /// Warnings raised while the template was created (for display and records).
    public var creationWarnings: [String]

    public init(
        schemaVersion: Int = AnalysisTemplate.currentSchemaVersion,
        id: UUID = UUID(),
        name: String,
        createdAt: Date = Date(),
        origin: Origin,
        input: InputSpec,
        steps: [Step],
        creationWarnings: [String] = []
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.origin = origin
        self.input = input
        self.steps = steps
        self.creationWarnings = creationWarnings
    }

    // MARK: Convenience accessors

    public var importStep: ImportFASTQStepSpec? {
        for case .importFASTQ(let spec) in steps { return spec }
        return nil
    }

    public var kraken2Step: Kraken2StepSpec? {
        for case .kraken2(let spec) in steps { return spec }
        return nil
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, name, createdAt, origin, input, steps, creationWarnings
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .schemaVersion)
        guard version == Self.currentSchemaVersion else {
            throw AnalysisTemplateError.unsupportedSchemaVersion(version)
        }
        schemaVersion = version
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        origin = try container.decode(Origin.self, forKey: .origin)
        input = try container.decode(InputSpec.self, forKey: .input)
        steps = try container.decode([Step].self, forKey: .steps)
        creationWarnings = try container.decodeIfPresent([String].self, forKey: .creationWarnings) ?? []
        guard !steps.isEmpty else {
            throw AnalysisTemplateError.invalidTemplate("A template needs at least one step.")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(origin, forKey: .origin)
        try container.encode(input, forKey: .input)
        try container.encode(steps, forKey: .steps)
        try container.encode(creationWarnings, forKey: .creationWarnings)
    }

    // MARK: Serialization

    /// The stable on-disk encoding: sorted keys, pretty printed, ISO 8601 dates.
    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Serialized JSON in the on-disk form.
    public func jsonData() throws -> Data {
        try Self.encoder.encode(self)
    }

    /// SHA-256 (hex) of the on-disk JSON encoding.
    public func sha256() throws -> String {
        AnalysisTemplateHashing.sha256Hex(of: try jsonData())
    }

    /// Loads a template file, rejecting unknown schema versions.
    public static func load(from url: URL) throws -> AnalysisTemplate {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw AnalysisTemplateError.unreadableFile(url, error.localizedDescription)
        }
        return try load(from: data)
    }

    public static func load(from data: Data) throws -> AnalysisTemplate {
        do {
            return try decoder.decode(AnalysisTemplate.self, from: data)
        } catch let error as AnalysisTemplateError {
            throw error
        } catch let DecodingError.dataCorrupted(context) {
            if let underlying = context.underlyingError as? AnalysisTemplateError {
                throw underlying
            }
            throw AnalysisTemplateError.invalidTemplate(context.debugDescription)
        } catch {
            throw AnalysisTemplateError.invalidTemplate(error.localizedDescription)
        }
    }

    /// Writes the template atomically.
    public func save(to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try jsonData().write(to: url, options: .atomic)
    }
}

// MARK: - Step Codable

extension AnalysisTemplate.Step: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, settings
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "importFASTQ":
            self = .importFASTQ(try container.decode(ImportFASTQStepSpec.self, forKey: .settings))
        case "kraken2":
            self = .kraken2(try container.decode(Kraken2StepSpec.self, forKey: .settings))
        default:
            throw AnalysisTemplateError.invalidTemplate("Unknown template step type '\(type)'.")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(typeIdentifier, forKey: .type)
        switch self {
        case .importFASTQ(let spec):
            try container.encode(spec, forKey: .settings)
        case .kraken2(let spec):
            try container.encode(spec, forKey: .settings)
        }
    }
}

// MARK: - AnalysisTemplatePairing

/// The read layout a template imports, pinned from the source import.
///
/// Raw values match the `import fastq --pairing` argument.
public enum AnalysisTemplatePairing: String, Codable, Sendable, CaseIterable {
    case single
    case paired
    case interleaved

    public var fileCount: Int {
        self == .paired ? 2 : 1
    }

    public var displayName: String {
        switch self {
        case .single: return "Single-end"
        case .paired: return "Paired"
        case .interleaved: return "Interleaved"
        }
    }

    /// The Kraken2 read format this pairing classifies as.
    public var classificationReadFormat: ClassificationConfig.ReadFormat {
        switch self {
        case .single: return .unpaired
        case .paired: return .paired
        case .interleaved: return .interleaved
        }
    }
}

// MARK: - ImportFASTQStepSpec

/// Pinned settings for the `lungfish-cli import fastq` step.
public struct ImportFASTQStepSpec: Codable, Equatable, Sendable {
    public var platform: SequencingPlatform
    public var pairing: AnalysisTemplatePairing
    public var qualityBinning: QualityBinningScheme
    public var optimizeStorage: Bool
    public var clumpingTool: ClumpingTool
    public var compressionLevel: CompressionLevel
    public var recipe: RecipeSnapshot?

    public init(
        platform: SequencingPlatform,
        pairing: AnalysisTemplatePairing,
        qualityBinning: QualityBinningScheme,
        optimizeStorage: Bool,
        clumpingTool: ClumpingTool,
        compressionLevel: CompressionLevel,
        recipe: RecipeSnapshot? = nil
    ) {
        self.platform = platform
        self.pairing = pairing
        self.qualityBinning = qualityBinning
        self.optimizeStorage = optimizeStorage
        self.clumpingTool = clumpingTool
        self.compressionLevel = compressionLevel
        self.recipe = recipe
    }

    public var settingsSummary: String {
        var parts = [
            "\(platform.displayName), \(pairing.displayName.lowercased())",
            "quality binning \(qualityBinning.rawValue)",
            "compression \(compressionLevel.rawValue)",
        ]
        parts.append(optimizeStorage ? "storage optimization \(clumpingTool.rawValue)" : "no storage optimization")
        if let recipe {
            parts.append("recipe \(recipe.name)")
        }
        return parts.joined(separator: "; ")
    }
}

// MARK: - RecipeSnapshot

/// A recipe as it was when the template was created.
///
/// The full definition is kept because the import provenance records the id
/// only, and user recipes can change or shadow built-in ones. `recipe` and
/// `sha256` are nil when the recipe was not installed at creation time; the
/// run then refuses unless drift is allowed.
public struct RecipeSnapshot: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var sha256: String?
    public var recipe: Recipe?

    public init(id: String, name: String, sha256: String? = nil, recipe: Recipe? = nil) {
        self.id = id
        self.name = name
        self.sha256 = sha256
        self.recipe = recipe
    }

    /// Snapshots an installed recipe, hashing its canonical encoding.
    public init(recipe: Recipe) throws {
        self.id = recipe.id
        self.name = recipe.name
        self.recipe = recipe
        self.sha256 = try Self.sha256(of: recipe)
    }

    /// SHA-256 (hex) of a recipe's canonical (sorted-key, compact) JSON encoding.
    public static func sha256(of recipe: Recipe) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return AnalysisTemplateHashing.sha256Hex(of: try encoder.encode(recipe))
    }
}

// MARK: - Kraken2StepSpec

/// Pinned settings for the `lungfish-cli conda classify` step.
public struct Kraken2StepSpec: Codable, Equatable, Sendable {

    /// Classify or profile. `extract` has no CLI flag and is refused at creation.
    public enum Goal: String, Codable, Sendable {
        case classify
        case profile
    }

    /// Identity of the pinned Kraken2 database.
    public struct DatabaseIdentity: Codable, Equatable, Sendable {
        public var name: String
        /// Recorded version, or "unknown" when the source did not record one.
        public var version: String
        public var catalogID: String?
        public var digest: String?

        public init(name: String, version: String, catalogID: String? = nil, digest: String? = nil) {
            self.name = name
            self.version = version
            self.catalogID = catalogID
            self.digest = digest
        }

        public static let unknownVersion = "unknown"

        public var summary: String {
            "\(name) (\(version))"
        }
    }

    public var goal: Goal
    public var database: DatabaseIdentity
    public var readFormat: ClassificationConfig.ReadFormat
    public var confidence: Double
    public var minimumHitGroups: Int
    public var memoryMapping: Bool
    public var quickMode: Bool
    public var extraArguments: [String]
    public var bracken: BrackenProfileRequest?
    /// Kraken2 version recorded by the source analysis, when known.
    public var recordedKraken2Version: String?
    /// Bracken version recorded by the source analysis, when known.
    public var recordedBrackenVersion: String?

    public init(
        goal: Goal,
        database: DatabaseIdentity,
        readFormat: ClassificationConfig.ReadFormat,
        confidence: Double,
        minimumHitGroups: Int,
        memoryMapping: Bool,
        quickMode: Bool,
        extraArguments: [String] = [],
        bracken: BrackenProfileRequest? = nil,
        recordedKraken2Version: String? = nil,
        recordedBrackenVersion: String? = nil
    ) {
        self.goal = goal
        self.database = database
        self.readFormat = readFormat
        self.confidence = confidence
        self.minimumHitGroups = minimumHitGroups
        self.memoryMapping = memoryMapping
        self.quickMode = quickMode
        self.extraArguments = extraArguments
        self.bracken = bracken
        self.recordedKraken2Version = recordedKraken2Version
        self.recordedBrackenVersion = recordedBrackenVersion
    }

    public var settingsSummary: String {
        var parts = [
            "database \(database.summary)",
            "confidence \(confidence)",
            "min hit groups \(minimumHitGroups)",
            "reads \(readFormat.rawValue)",
        ]
        if memoryMapping { parts.append("memory mapping") }
        if quickMode { parts.append("quick mode") }
        if !extraArguments.isEmpty { parts.append("extra args \(extraArguments.joined(separator: " "))") }
        if goal == .profile {
            let request = bracken ?? .automaticDefault
            var brackenText = "Bracken read length \(request.readLength), threshold \(request.threshold)"
            if case .explicit(let rank) = request.rank {
                brackenText += ", level \(rank.code)"
            }
            parts.append(brackenText)
        }
        return parts.joined(separator: "; ")
    }

    /// Builds the classification config the CLI argv builder consumes.
    ///
    /// `databasePath` is a placeholder: the CLI resolves `--db` by registry
    /// name, and the builder never emits the path.
    public func classificationConfig(
        inputFiles: [URL],
        outputDirectory: URL,
        threads: Int
    ) -> ClassificationConfig {
        ClassificationConfig(
            goal: goal == .profile ? .profile : .classify,
            inputFiles: inputFiles,
            isPairedEnd: readFormat == .paired,
            interleavedInput: readFormat == .interleaved,
            databaseName: database.name,
            databaseVersion: database.version,
            databasePath: URL(fileURLWithPath: "/"),
            databaseDigest: database.digest,
            databaseCatalogID: database.catalogID,
            brackenProfileRequest: goal == .profile ? (bracken ?? .automaticDefault) : nil,
            confidence: confidence,
            minimumHitGroups: minimumHitGroups,
            threads: threads,
            memoryMapping: memoryMapping,
            quickMode: quickMode,
            outputDirectory: outputDirectory,
            extraArguments: extraArguments
        )
    }
}

// MARK: - AnalysisTemplateError

/// Errors reading or writing a template file.
public enum AnalysisTemplateError: Error, LocalizedError, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
    case invalidTemplate(String)
    case unreadableFile(URL, String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchemaVersion(let version):
            return "This template uses schema version \(version), which this version of LGE cannot read. It was made by a newer version of LGE."
        case .invalidTemplate(let reason):
            return "The template file is not valid: \(reason)"
        case .unreadableFile(let url, let reason):
            return "Could not read the template at \(url.path): \(reason)"
        }
    }
}

// MARK: - AnalysisTemplateHashing

/// SHA-256 helpers shared by the template types.
public enum AnalysisTemplateHashing {
    public static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256Hex(ofFileAt url: URL) throws -> String {
        sha256Hex(of: try Data(contentsOf: url))
    }
}
