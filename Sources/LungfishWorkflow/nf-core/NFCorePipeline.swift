// NFCorePipeline.swift - nf-core pipeline model
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner: Workflow Integration Lead (Role 14)

import Foundation

// MARK: - NFCorePipeline

/// Represents an nf-core pipeline from the registry.
///
/// nf-core pipelines are community-curated Nextflow pipelines that follow
/// best practices and include comprehensive documentation, testing, and
/// container support.
///
/// ## Example
///
/// ```swift
/// let registry = NFCoreRegistry()
/// let pipelines = try await registry.listPipelines()
///
/// for pipeline in pipelines {
///     print("\(pipeline.name): \(pipeline.description)")
///     print("  Latest version: \(pipeline.latestVersion ?? "N/A")")
///     print("  Topics: \(pipeline.topics.joined(separator: ", "))")
/// }
/// ```
public struct NFCorePipeline: Sendable, Codable, Identifiable, Hashable {

    // MARK: - Properties

    /// Unique identifier (usually the pipeline name).
    public var id: String { name }

    /// Pipeline name (e.g., "rnaseq", "sarek", "viralrecon").
    public let name: String

    /// Full display name (e.g., "nf-core/rnaseq").
    public var fullName: String { "nf-core/\(name)" }

    /// Human-readable description of what the pipeline does.
    public let description: String

    /// Brief tagline or summary.
    public let tagline: String?

    /// Topics/categories for the pipeline.
    public let topics: [String]

    /// Latest released version.
    public let latestVersion: String?

    /// All available versions.
    public let versions: [String]

    /// Number of GitHub stars.
    public let stargazersCount: Int?

    /// URL to the pipeline's schema file.
    public let schemaURL: URL?

    /// URL to the pipeline's GitHub repository.
    public let repositoryURL: URL

    /// URL to the pipeline's documentation.
    public let documentationURL: URL?

    /// URL to the pipeline's logo or icon.
    public let logoURL: URL?

    /// Whether this pipeline is archived/deprecated.
    public let isArchived: Bool

    /// Whether this pipeline is released (vs development).
    public let isReleased: Bool

    /// Date the pipeline was last updated.
    public let updatedAt: Date?

    /// Maintainers of the pipeline.
    public let maintainers: [String]

    // MARK: - Initialization

    /// Creates a new nf-core pipeline model.
    public init(
        name: String,
        description: String,
        tagline: String? = nil,
        topics: [String] = [],
        latestVersion: String? = nil,
        versions: [String] = [],
        stargazersCount: Int? = nil,
        schemaURL: URL? = nil,
        repositoryURL: URL,
        documentationURL: URL? = nil,
        logoURL: URL? = nil,
        isArchived: Bool = false,
        isReleased: Bool = true,
        updatedAt: Date? = nil,
        maintainers: [String] = []
    ) {
        self.name = name
        self.description = description
        self.tagline = tagline
        self.topics = topics
        self.latestVersion = latestVersion
        self.versions = versions
        self.stargazersCount = stargazersCount
        self.schemaURL = schemaURL
        self.repositoryURL = repositoryURL
        self.documentationURL = documentationURL
        self.logoURL = logoURL
        self.isArchived = isArchived
        self.isReleased = isReleased
        self.updatedAt = updatedAt
        self.maintainers = maintainers
    }

    // MARK: - Computed Properties

    /// URL to run this pipeline via Nextflow.
    ///
    /// This can be used directly with `nextflow run`.
    public var runURL: String {
        if let version = latestVersion {
            return "nf-core/\(name) -r \(version)"
        }
        return "nf-core/\(name)"
    }

    /// URL to the schema file for the latest version.
    public var latestSchemaURL: URL? {
        guard let version = latestVersion else { return schemaURL }
        return URL(string: "https://raw.githubusercontent.com/nf-core/\(name)/\(version)/nextflow_schema.json")
    }

    /// URL to download the pipeline.
    public var downloadURL: URL? {
        guard let version = latestVersion else { return nil }
        return URL(string: "https://github.com/nf-core/\(name)/archive/refs/tags/\(version).zip")
    }

    /// Whether this pipeline has genomics-related topics.
    public var isGenomicsPipeline: Bool {
        let genomicsTopics = ["genomics", "bioinformatics", "ngs", "sequencing",
                              "rna-seq", "dna-seq", "chip-seq", "atac-seq",
                              "methylation", "variant-calling", "assembly"]
        return !Set(topics.map { $0.lowercased() }).isDisjoint(with: genomicsTopics)
    }

    // MARK: - Hashable

    public func hash(into hasher: inout Hasher) {
        hasher.combine(name)
    }

    public static func == (lhs: NFCorePipeline, rhs: NFCorePipeline) -> Bool {
        lhs.name == rhs.name
    }
}

// MARK: - NFCorePipelineVersion

/// Represents a specific version of an nf-core pipeline.
public struct NFCorePipelineVersion: Sendable, Codable, Identifiable {

    /// Unique identifier.
    public var id: String { "\(pipelineName)-\(version)" }

    /// Name of the parent pipeline.
    public let pipelineName: String

    /// Version tag (e.g., "3.12.0").
    public let version: String

    /// Release date.
    public let releaseDate: Date?

    /// Release notes/changelog.
    public let releaseNotes: String?

    /// URL to the release.
    public let releaseURL: URL?

    /// Whether this is the latest version.
    public let isLatest: Bool

    /// Whether this is a pre-release.
    public let isPrerelease: Bool

    /// Creates a new pipeline version.
    public init(
        pipelineName: String,
        version: String,
        releaseDate: Date? = nil,
        releaseNotes: String? = nil,
        releaseURL: URL? = nil,
        isLatest: Bool = false,
        isPrerelease: Bool = false
    ) {
        self.pipelineName = pipelineName
        self.version = version
        self.releaseDate = releaseDate
        self.releaseNotes = releaseNotes
        self.releaseURL = releaseURL
        self.isLatest = isLatest
        self.isPrerelease = isPrerelease
    }
}

// MARK: - NFCorePipelineCategory

/// Categories of nf-core pipelines.
public enum NFCorePipelineCategory: String, Sendable, CaseIterable {
    case rnaSeq = "rna-seq"
    case dnaSeq = "dna-seq"
    case variantCalling = "variant-calling"
    case assembly = "assembly"
    case metagenomics = "metagenomics"
    case epigenetics = "epigenetics"
    case proteomics = "proteomics"
    case singleCell = "single-cell"
    case imaging = "imaging"
    case other = "other"

    /// Human-readable display name.
    public var displayName: String {
        switch self {
        case .rnaSeq: return "RNA-seq"
        case .dnaSeq: return "DNA-seq"
        case .variantCalling: return "Variant Calling"
        case .assembly: return "Genome Assembly"
        case .metagenomics: return "Metagenomics"
        case .epigenetics: return "Epigenetics"
        case .proteomics: return "Proteomics"
        case .singleCell: return "Single Cell"
        case .imaging: return "Imaging"
        case .other: return "Other"
        }
    }

    /// SF Symbol icon for this category.
    public var iconName: String {
        switch self {
        case .rnaSeq: return "waveform.path"
        case .dnaSeq: return "allergens"
        case .variantCalling: return "arrow.triangle.branch"
        case .assembly: return "puzzlepiece.extension"
        case .metagenomics: return "globe.americas"
        case .epigenetics: return "tag"
        case .proteomics: return "atom"
        case .singleCell: return "circle.grid.3x3"
        case .imaging: return "camera.macro"
        case .other: return "ellipsis.circle"
        }
    }

    /// Matches a pipeline to this category based on its topics.
    public static func categorize(_ pipeline: NFCorePipeline) -> NFCorePipelineCategory {
        let topics = Set(pipeline.topics.map { $0.lowercased() })

        if !topics.isDisjoint(with: ["rna-seq", "rnaseq", "transcriptomics"]) {
            return .rnaSeq
        }
        if !topics.isDisjoint(with: ["dna-seq", "dnaseq", "wgs", "wes", "exome"]) {
            return .dnaSeq
        }
        if !topics.isDisjoint(with: ["variant-calling", "variants", "snp", "indel"]) {
            return .variantCalling
        }
        if !topics.isDisjoint(with: ["assembly", "genome-assembly", "de-novo"]) {
            return .assembly
        }
        if !topics.isDisjoint(with: ["metagenomics", "microbiome", "16s"]) {
            return .metagenomics
        }
        if !topics.isDisjoint(with: ["epigenetics", "chip-seq", "atac-seq", "methylation"]) {
            return .epigenetics
        }
        if !topics.isDisjoint(with: ["proteomics", "mass-spec"]) {
            return .proteomics
        }
        if !topics.isDisjoint(with: ["single-cell", "scrnaseq", "scrna-seq"]) {
            return .singleCell
        }
        if !topics.isDisjoint(with: ["imaging", "microscopy"]) {
            return .imaging
        }

        return .other
    }
}
