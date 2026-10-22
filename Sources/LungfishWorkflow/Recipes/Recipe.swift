// Recipe.swift
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

// MARK: - Recipe resource accessor

public enum RecipeBundleAccessor {
    public static func recipesDirectoryURL() -> URL? {
        RuntimeResourceLocator.path("Recipes", in: .workflow)
            ?? debugSourceRecipesDirectoryURL()
    }

    private static func debugSourceRecipesDirectoryURL() -> URL? {
        #if DEBUG
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/Recipes", isDirectory: true)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            return nil
        }
        return sourceURL
        #else
        return nil
        #endif
    }
}

// MARK: - AnyCodableValue

/// Type-erased ``Codable`` value for recipe step parameters.
///
/// Supports the four JSON scalar primitives: Bool, Int, Double, and String.
/// Booleans are decoded before integers so that `true`/`false` JSON literals
/// are not silently coerced to `1`/`0`.
public enum AnyCodableValue: Sendable, Equatable, Codable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)

    // MARK: Decoding

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        // Bool must be attempted first: on many platforms Int can decode "true"
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else {
            let value = try container.decode(String.self)
            self = .string(value)
        }
    }

    // MARK: Encoding

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .bool(let v):   try container.encode(v)
        case .int(let v):    try container.encode(v)
        case .double(let v): try container.encode(v)
        case .string(let v): try container.encode(v)
        }
    }

    // MARK: Convenience accessors

    public var stringValue: String? {
        guard case .string(let v) = self else { return nil }
        return v
    }

    public var intValue: Int? {
        guard case .int(let v) = self else { return nil }
        return v
    }

    public var doubleValue: Double? {
        guard case .double(let v) = self else { return nil }
        return v
    }

    public var boolValue: Bool? {
        guard case .bool(let v) = self else { return nil }
        return v
    }
}

// MARK: - RecipeStep

/// A single processing step within a ``Recipe``.
public struct RecipeStep: Codable, Sendable, Equatable {
    /// Tool type identifier (e.g. `"fastp-trim"`, `"deacon-scrub"`).
    public let type: String

    /// Human-readable description of the step, suitable for UI display.
    public var label: String?

    /// Tool-specific parameters.
    public var params: [String: AnyCodableValue]?
}

// MARK: - Recipe

/// A reusable FASTQ processing recipe that describes a sequence of pipeline steps.
public struct Recipe: Codable, Sendable, Identifiable, Equatable {

    // MARK: Nested types

    /// Whether the recipe requires paired-end, single-end, or any input.
    public enum InputRequirement: String, Codable, Sendable, Equatable {
        case paired
        case single
        case any
    }

    // MARK: Properties

    /// The format versions this build reads. Version 2 adds ``switches`` and ``presets``, which an older build
    /// would ignore and so run every step, so a build refuses a version it does not know (ruling BIO-PRESET P3).
    public static let supportedFormatVersions: ClosedRange<Int> = 1...2

    /// Schema version, one of ``supportedFormatVersions``.
    public let formatVersion: Int

    /// Unique identifier for the recipe (e.g. `"vsp2-target-enrichment"`).
    public let id: String

    /// Display name.
    public let name: String

    /// Optional human-readable description.
    public var description: String?

    /// Optional recipe author.
    public var author: String?

    /// Searchable tags (defaults to `[]` if absent in JSON).
    public var tags: [String]

    /// Compatible sequencing platforms.
    public let platforms: [IngestionPlatform]

    /// Whether the recipe requires paired, single, or any input.
    public let requiredInput: InputRequirement

    /// Optional quality-binning scheme applied during ingestion.
    public var qualityBinning: QualityBinningScheme?

    /// Ordered processing steps. A switch that is off leaves its step out of the run (``activeSteps``).
    public var steps: [RecipeStep]

    /// Switches that turn one step each on or off, formatVersion 2 and later.
    public var switches: [RecipeSwitch]

    /// Named sets of switch values, formatVersion 2 and later.
    public var presets: [RecipePreset]

    /// What the name a run passed resolved to, set by ``RecipeResolver`` and nil for a recipe nobody resolved. It is
    /// not part of the JSON.
    public var resolution: RecipeResolution?

    /// SHA-256 of the recipe file's bytes, set by ``RecipeRegistryV2`` when it reads the file and nil for a recipe
    /// built in code. It is not part of the JSON, and two recipes with the same content stay equal whatever their
    /// files' bytes (CHTC lane L5-RECORDS M2).
    public var sourceSHA256: String?

    public static func == (lhs: Recipe, rhs: Recipe) -> Bool {
        lhs.formatVersion == rhs.formatVersion && lhs.id == rhs.id && lhs.name == rhs.name
            && lhs.description == rhs.description && lhs.author == rhs.author && lhs.tags == rhs.tags
            && lhs.platforms == rhs.platforms && lhs.requiredInput == rhs.requiredInput
            && lhs.qualityBinning == rhs.qualityBinning && lhs.steps == rhs.steps
            && lhs.switches == rhs.switches && lhs.presets == rhs.presets
    }

    // MARK: CodingKeys

    private enum CodingKeys: String, CodingKey {
        case formatVersion, id, name, description, author, tags,
             platforms, requiredInput, qualityBinning, steps, switches, presets
    }

    // MARK: Memberwise initialiser (for tests and programmatic construction)

    public init(
        formatVersion: Int = 1,
        id: String,
        name: String,
        description: String? = nil,
        author: String? = nil,
        tags: [String] = [],
        platforms: [IngestionPlatform] = [.illumina],
        requiredInput: InputRequirement = .any,
        qualityBinning: QualityBinningScheme? = nil,
        steps: [RecipeStep],
        switches: [RecipeSwitch] = [],
        presets: [RecipePreset] = []
    ) {
        self.formatVersion  = formatVersion
        self.id             = id
        self.name           = name
        self.description    = description
        self.author         = author
        self.tags           = tags
        self.platforms      = platforms
        self.requiredInput  = requiredInput
        self.qualityBinning = qualityBinning
        self.steps          = steps
        self.switches       = switches
        self.presets        = presets
    }

    // MARK: Custom decoder (tags defaults to [], an unknown formatVersion is refused)

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion  = try container.decode(Int.self,                   forKey: .formatVersion)
        guard Self.supportedFormatVersions.contains(formatVersion) else {
            throw RecipeFormatVersionError(formatVersion: formatVersion)
        }
        id             = try container.decode(String.self,                forKey: .id)
        name           = try container.decode(String.self,                forKey: .name)
        description    = try container.decodeIfPresent(String.self,       forKey: .description)
        author         = try container.decodeIfPresent(String.self,       forKey: .author)
        tags           = try container.decodeIfPresent([String].self,     forKey: .tags) ?? []
        platforms      = try container.decode([IngestionPlatform].self,   forKey: .platforms)
        requiredInput  = try container.decode(InputRequirement.self,      forKey: .requiredInput)
        qualityBinning = try container.decodeIfPresent(QualityBinningScheme.self, forKey: .qualityBinning)
        steps          = try container.decode([RecipeStep].self,          forKey: .steps)
        switches       = try container.decodeIfPresent([RecipeSwitch].self, forKey: .switches) ?? []
        presets        = try container.decodeIfPresent([RecipePreset].self, forKey: .presets) ?? []
        try validateSwitches()
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(formatVersion, forKey: .formatVersion)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encodeIfPresent(author, forKey: .author)
        try container.encode(tags, forKey: .tags)
        try container.encode(platforms, forKey: .platforms)
        try container.encode(requiredInput, forKey: .requiredInput)
        try container.encodeIfPresent(qualityBinning, forKey: .qualityBinning)
        try container.encode(steps, forKey: .steps)
        if !switches.isEmpty { try container.encode(switches, forKey: .switches) }
        if !presets.isEmpty { try container.encode(presets, forKey: .presets) }
    }
}

/// A recipe file at a format version this build does not read.
public struct RecipeFormatVersionError: Error, LocalizedError, Equatable {
    public let formatVersion: Int

    public init(formatVersion: Int) {
        self.formatVersion = formatVersion
    }

    public var errorDescription: String? {
        let versions = Recipe.supportedFormatVersions
        let advice = formatVersion > versions.upperBound ? "Update the app." : "No version of it reads this file."
        return "The recipe has formatVersion \(formatVersion). This version of Lungfish Genome Explorer reads formatVersion \(versions.lowerBound) to \(versions.upperBound). \(advice)"
    }
}
