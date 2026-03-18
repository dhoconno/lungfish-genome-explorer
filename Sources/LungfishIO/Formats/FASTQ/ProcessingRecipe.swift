// ProcessingRecipe.swift - Reusable multi-step FASTQ processing pipelines
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import os.log

private let logger = Logger(subsystem: "com.lungfish.io", category: "ProcessingRecipe")

// MARK: - Processing Recipe

/// A reusable, serializable pipeline definition.
///
/// Recipes capture an ordered sequence of FASTQ processing operations so they
/// can be applied uniformly across all barcodes in a demux group with a single
/// action. Each step reuses the existing `FASTQDerivativeOperation` type.
///
/// ```swift
/// let recipe = ProcessingRecipe.illuminaWGS
/// // → 3 steps: Quality Trim → Adapter Trim → PE Merge
/// ```
///
/// Recipes are stored as JSON in `~/Library/Application Support/Lungfish/recipes/`.
public struct ProcessingRecipe: Codable, Sendable, Identifiable, Equatable {
    public static let fileExtension = "recipe.json"

    public let id: UUID
    public var name: String
    public var description: String
    public let createdAt: Date
    public var modifiedAt: Date

    /// Ordered pipeline steps. Each step is a template whose `createdAt` is
    /// stamped with the real date at execution time.
    public var steps: [FASTQDerivativeOperation]

    /// Tags for organization (e.g., "amplicon", "wgs", "ont").
    public var tags: [String]

    /// Who created this recipe (for shared/built-in recipes).
    public var author: String?

    /// Minimum input requirements (e.g., must be paired-end for PE merge step).
    public var requiredPairingMode: IngestionMetadata.PairingMode?

    /// Placeholders that must be filled before the recipe can be executed.
    ///
    /// Each placeholder represents a runtime parameter (e.g., primer sequences,
    /// reference path) that varies between runs. When applying the recipe, a form
    /// collects these values. Filled values are stored in the batch manifest.
    public var placeholders: [RecipePlaceholder]

    public init(
        id: UUID = UUID(),
        name: String,
        description: String = "",
        createdAt: Date = Date(),
        modifiedAt: Date = Date(),
        steps: [FASTQDerivativeOperation],
        tags: [String] = [],
        author: String? = nil,
        requiredPairingMode: IngestionMetadata.PairingMode? = nil,
        placeholders: [RecipePlaceholder] = []
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.steps = steps
        self.tags = tags
        self.author = author
        self.requiredPairingMode = requiredPairingMode
        self.placeholders = placeholders
    }

    // Custom decoding for backward compatibility (placeholders may be absent in older JSON)
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decode(String.self, forKey: .description)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        modifiedAt = try container.decode(Date.self, forKey: .modifiedAt)
        steps = try container.decode([FASTQDerivativeOperation].self, forKey: .steps)
        tags = try container.decode([String].self, forKey: .tags)
        author = try container.decodeIfPresent(String.self, forKey: .author)
        requiredPairingMode = try container.decodeIfPresent(IngestionMetadata.PairingMode.self, forKey: .requiredPairingMode)
        placeholders = try container.decodeIfPresent([RecipePlaceholder].self, forKey: .placeholders) ?? []
    }

    /// Human-readable summary: "3 steps: Quality Trim → Adapter Trim → PE Merge".
    public var pipelineSummary: String {
        guard !steps.isEmpty else { return "Empty pipeline" }
        let stepNames = steps.map { $0.shortLabel }
        return "\(steps.count) steps: \(stepNames.joined(separator: " → "))"
    }

    // MARK: - Persistence

    /// Loads a recipe from a JSON file.
    public static func load(from url: URL) -> ProcessingRecipe? {
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(ProcessingRecipe.self, from: data)
        } catch {
            logger.warning("Failed to load recipe from \(url.lastPathComponent): \(error)")
            return nil
        }
    }

    /// Saves the recipe to a JSON file.
    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: url, options: .atomic)
    }
}

// MARK: - Recipe Placeholder

/// A placeholder in a recipe template that must be filled before execution.
///
/// Placeholders separate "what to do" from "with what sequences/references",
/// allowing the same recipe to be reused across different experiments.
public struct RecipePlaceholder: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    /// Machine-readable key used to substitute into operation parameters.
    public let key: String
    /// Human-readable label shown in the fill form.
    public let label: String
    /// Hint text for the input field.
    public let hint: String
    /// What kind of value is expected.
    public let valueType: PlaceholderValueType

    public enum PlaceholderValueType: String, Codable, Sendable, Equatable {
        /// A DNA/RNA sequence string.
        case sequence
        /// A file path (e.g., reference FASTA).
        case filePath
        /// A numeric value.
        case number
        /// Free-form text.
        case text
    }

    public init(
        id: UUID = UUID(),
        key: String,
        label: String,
        hint: String = "",
        valueType: PlaceholderValueType = .text
    ) {
        self.id = id
        self.key = key
        self.label = label
        self.hint = hint
        self.valueType = valueType
    }
}

extension ProcessingRecipe {
    /// Returns the list of unfilled placeholder keys.
    public var unfilledPlaceholderKeys: [String] {
        placeholders.map(\.key)
    }

    /// Whether this recipe has placeholders that need to be filled.
    public var requiresPlaceholderValues: Bool {
        !placeholders.isEmpty
    }

    /// Resolves this recipe by substituting placeholder values into operation parameters.
    ///
    /// - Parameter values: Dictionary mapping placeholder keys to their filled values.
    /// - Returns: A new recipe with placeholders resolved into the operation parameters.
    public func resolved(with values: [String: String]) -> ProcessingRecipe {
        var resolved = self
        resolved.steps = steps.map { step in
            var s = step
            // Substitute known placeholder keys into primer sequences
            if let fwd = values["forwardPrimer"] { s.primerForwardSequence = s.primerForwardSequence == nil ? nil : fwd }
            if let rev = values["reversePrimer"] { s.primerReverseSequence = s.primerReverseSequence == nil ? nil : rev }
            if let ref = values["referencePath"] {
                if s.contaminantReferenceFasta != nil { s.contaminantReferenceFasta = ref }
                if s.orientReferencePath != nil { s.orientReferencePath = ref }
            }
            if let lit = values["primerSequence"] { s.primerLiteralSequence = s.primerLiteralSequence == nil ? nil : lit }
            return s
        }
        resolved.placeholders = [] // All filled
        return resolved
    }
}

// MARK: - Built-in Recipe Templates

extension ProcessingRecipe {
    /// Standard Illumina WGS preprocessing.
    public static let illuminaWGS = ProcessingRecipe(
        name: "Illumina WGS Standard",
        description: "Quality trim, adapter removal, PE merge",
        steps: [
            FASTQDerivativeOperation(
                kind: .qualityTrim,
                createdAt: .distantPast,
                qualityThreshold: 20,
                windowSize: 4,
                qualityTrimMode: .cutRight
            ),
            FASTQDerivativeOperation(
                kind: .adapterTrim,
                createdAt: .distantPast,
                adapterMode: .autoDetect
            ),
            FASTQDerivativeOperation(
                kind: .pairedEndMerge,
                createdAt: .distantPast,
                mergeStrictness: .normal,
                mergeMinOverlap: 12
            ),
        ],
        tags: ["illumina", "wgs", "paired-end"],
        author: "Lungfish Built-in",
        requiredPairingMode: .interleaved
    )

    /// ONT amplicon preprocessing.
    public static let ontAmplicon = ProcessingRecipe(
        name: "ONT Amplicon",
        description: "Quality filter, length selection for expected amplicon size",
        steps: [
            FASTQDerivativeOperation(
                kind: .qualityTrim,
                createdAt: .distantPast,
                qualityThreshold: 10,
                windowSize: 10,
                qualityTrimMode: .cutBoth
            ),
            FASTQDerivativeOperation(
                kind: .lengthFilter,
                createdAt: .distantPast,
                minLength: 200,
                maxLength: 1500
            ),
        ],
        tags: ["ont", "amplicon", "nanopore"],
        author: "Lungfish Built-in"
    )

    /// PacBio HiFi minimal preprocessing.
    public static let pacbioHiFi = ProcessingRecipe(
        name: "PacBio HiFi",
        description: "Deduplicate HiFi consensus reads",
        steps: [
            FASTQDerivativeOperation(
                kind: .deduplicate,
                createdAt: .distantPast,
                deduplicatePreset: .exactPCR,
                deduplicateSubstitutions: 0
            ),
        ],
        tags: ["pacbio", "hifi", "long-read"],
        author: "Lungfish Built-in"
    )

    /// Primer removal + quality trim for targeted amplicon sequencing.
    public static let targetedAmplicon = ProcessingRecipe(
        name: "Targeted Amplicon",
        description: "Primer removal, quality trim, adapter trim, PE merge",
        steps: [
            FASTQDerivativeOperation(
                kind: .primerRemoval,
                createdAt: .distantPast,
                primerSource: .literal,
                primerReadMode: .paired,
                primerTrimMode: .paired,
                primerAnchored5Prime: true,
                primerAnchored3Prime: true,
                primerErrorRate: 0.12,
                primerMinimumOverlap: 12,
                primerAllowIndels: true,
                primerKeepUntrimmed: false,
                primerPairFilter: .any
            ),
            FASTQDerivativeOperation(
                kind: .qualityTrim,
                createdAt: .distantPast,
                qualityThreshold: 20,
                windowSize: 4,
                qualityTrimMode: .cutRight
            ),
            FASTQDerivativeOperation(
                kind: .adapterTrim,
                createdAt: .distantPast,
                adapterMode: .autoDetect
            ),
            FASTQDerivativeOperation(
                kind: .pairedEndMerge,
                createdAt: .distantPast,
                mergeStrictness: .strict,
                mergeMinOverlap: 10
            ),
        ],
        tags: ["amplicon", "targeted", "paired-end"],
        author: "Lungfish Built-in",
        requiredPairingMode: .interleaved
    )

    /// Illumina VSP2 target enrichment preprocessing.
    ///
    /// Designed for viral surveillance panel (VSP2) target-enriched paired-end
    /// libraries. Adapter removal comes first (Nextera/TruSeq read-through is
    /// common with short inserts), then quality trimming while data is still
    /// properly interleaved, then merging cleaned pairs. The resulting bundle
    /// contains a mix of merged reads and unmerged interleaved R1/R2 pairs.
    public static let illuminaVSP2TargetEnrichment = ProcessingRecipe(
        name: "Illumina VSP2 Target Enrichment",
        description: "Human read removal, deduplicate, adapter trim, quality trim, merge pairs, remove short reads",
        steps: [
            // 1. Remove human reads before any other processing
            //    Uses NCBI sra-human-scrubber with -s (interleaved paired-end mode):
            //    if either read in a pair aligns to human, both are masked with N.
            //    Masked reads are removed in the length filter at the end.
            FASTQDerivativeOperation(
                kind: .humanReadScrub,
                createdAt: .distantPast,
                humanScrubRemoveReads: false,   // mask with N; length filter removes them later
                humanScrubDatabaseID: "human-scrubber"
            ),
            // 2. Remove PCR duplicates (exact match, paired-end aware)
            FASTQDerivativeOperation(
                kind: .deduplicate,
                createdAt: .distantPast,
                deduplicatePreset: .exactPCR,
                deduplicateSubstitutions: 0
            ),
            // 3. Remove Illumina adapters (auto-detect TruSeq/Nextera/transposase)
            //    Critical for short-insert libraries where reads extend into adapter
            FASTQDerivativeOperation(
                kind: .adapterTrim,
                createdAt: .distantPast,
                adapterMode: .autoDetect
            ),
            // 4. Quality trim 3' tails (Q15 — conservative, preserves more read length
            //    while still removing poor-quality tail bases common in short-insert libraries)
            FASTQDerivativeOperation(
                kind: .qualityTrim,
                createdAt: .distantPast,
                qualityThreshold: 15,
                windowSize: 5,
                qualityTrimMode: .cutRight
            ),
            // 5. Merge overlapping R1/R2 pairs on clean, trimmed reads —
            //    produces merged reads plus unmerged pairs kept interleaved
            FASTQDerivativeOperation(
                kind: .pairedEndMerge,
                createdAt: .distantPast,
                mergeStrictness: .normal,
                mergeMinOverlap: 15
            ),
            // 6. Remove reads shorter than 50 bp (catches N-masked human reads)
            FASTQDerivativeOperation(
                kind: .lengthFilter,
                createdAt: .distantPast,
                minLength: 50,
                maxLength: nil
            ),
        ],
        tags: ["illumina", "target-enrichment", "vsp2", "paired-end", "viral"],
        author: "Lungfish Built-in",
        requiredPairingMode: .interleaved
    )

    /// All built-in recipe templates.
    public static let builtinRecipes: [ProcessingRecipe] = [
        .illuminaWGS,
        .illuminaVSP2TargetEnrichment,
        .ontAmplicon,
        .pacbioHiFi,
        .targetedAmplicon,
    ]
}

// MARK: - Before/After Comparison

/// Comparison of statistics between a parent bundle and its derivative.
///
/// Used by the "Compare with Parent" UI to show processing impact.
public struct FASTQComparisonResult: Sendable, Equatable {
    /// Statistics from the parent (before processing).
    public let before: FASTQDatasetStatistics
    /// Statistics from the child (after processing).
    public let after: FASTQDatasetStatistics
    /// The operation that produced the child from the parent.
    public let operation: FASTQDerivativeOperation

    /// Percentage of reads retained (0–100).
    public var retentionPercentage: Double {
        guard before.readCount > 0 else { return 0 }
        return Double(after.readCount) / Double(before.readCount) * 100
    }

    /// Change in mean quality (positive = improved).
    public var qualityDelta: Double {
        after.meanQuality - before.meanQuality
    }

    /// Change in mean read length (positive = longer).
    public var lengthDelta: Double {
        after.meanReadLength - before.meanReadLength
    }

    /// Number of reads removed.
    public var readsRemoved: Int {
        max(0, before.readCount - after.readCount)
    }

    /// Generates a plain-text summary of the comparison.
    public var summaryText: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal

        let beforeReads = formatter.string(from: NSNumber(value: before.readCount)) ?? "\(before.readCount)"
        let afterReads = formatter.string(from: NSNumber(value: after.readCount)) ?? "\(after.readCount)"
        let removed = formatter.string(from: NSNumber(value: readsRemoved)) ?? "\(readsRemoved)"
        let retention = String(format: "%.1f%%", retentionPercentage)
        let qDelta = String(format: "%+.1f", qualityDelta)
        let lDelta = String(format: "%+.0f bp", lengthDelta)

        return """
        Reads: \(beforeReads) → \(afterReads) (\(removed) removed, \(retention) retained)
        Mean quality: \(String(format: "%.1f", before.meanQuality)) → \(String(format: "%.1f", after.meanQuality)) (\(qDelta))
        Mean length: \(String(format: "%.0f", before.meanReadLength)) → \(String(format: "%.0f", after.meanReadLength)) (\(lDelta))
        """
    }
}

// MARK: - Recipe Registry

/// Manages built-in and user-created recipes.
public enum RecipeRegistry {

    /// Returns the directory for user-created recipes.
    public static var userRecipesDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("Lungfish", isDirectory: true)
            .appendingPathComponent("recipes", isDirectory: true)
    }

    /// Loads all available recipes (built-in + user).
    public static func loadAllRecipes() -> [ProcessingRecipe] {
        var recipes = ProcessingRecipe.builtinRecipes

        let userDir = userRecipesDirectory
        guard FileManager.default.fileExists(atPath: userDir.path) else { return recipes }

        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: userDir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            for url in contents where url.pathExtension == "json" || url.lastPathComponent.hasSuffix(".recipe.json") {
                if let recipe = ProcessingRecipe.load(from: url) {
                    recipes.append(recipe)
                }
            }
        } catch {
            logger.warning("Failed to scan user recipes directory: \(error)")
        }

        return recipes
    }

    /// Saves a user-created recipe to the recipes directory.
    public static func saveUserRecipe(_ recipe: ProcessingRecipe) throws {
        let dir = userRecipesDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let sanitized = recipe.name
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
        let filename = sanitized.unicodeScalars.filter { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_"
        }.map(String.init).joined()
        let url = dir.appendingPathComponent("\(filename).\(ProcessingRecipe.fileExtension)")
        try recipe.save(to: url)
    }
}
