// Recipe.swift
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - Recipe bundle accessor

/// Exposes the `LungfishWorkflow` module bundle so that test code can load
/// bundled recipes via `@testable import LungfishWorkflow`.
///
/// In production this is `Bundle.module` (the synthesised SPM resource bundle).
/// Tests use `RecipeBundleAccessor.bundle` rather than `Bundle.module` so that
/// they reference the correct bundle even when `Bundle.module` in the test
/// target resolves to the test runner bundle.
public enum RecipeBundleAccessor {
    public static let bundle: Bundle = .module
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

    /// Schema version — currently always `1`.
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
    public let platforms: [SequencingPlatform]

    /// Whether the recipe requires paired, single, or any input.
    public let requiredInput: InputRequirement

    /// Optional quality-binning scheme applied during ingestion.
    public var qualityBinning: QualityBinningScheme?

    /// Ordered processing steps.
    public var steps: [RecipeStep]

    // MARK: CodingKeys

    private enum CodingKeys: String, CodingKey {
        case formatVersion, id, name, description, author, tags,
             platforms, requiredInput, qualityBinning, steps
    }

    // MARK: Memberwise initialiser (for tests and programmatic construction)

    public init(
        formatVersion: Int = 1,
        id: String,
        name: String,
        description: String? = nil,
        author: String? = nil,
        tags: [String] = [],
        platforms: [SequencingPlatform] = [.illumina],
        requiredInput: InputRequirement = .any,
        qualityBinning: QualityBinningScheme? = nil,
        steps: [RecipeStep]
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
    }

    // MARK: Custom decoder (tags defaults to [])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion  = try container.decode(Int.self,                   forKey: .formatVersion)
        id             = try container.decode(String.self,                forKey: .id)
        name           = try container.decode(String.self,                forKey: .name)
        description    = try container.decodeIfPresent(String.self,       forKey: .description)
        author         = try container.decodeIfPresent(String.self,       forKey: .author)
        tags           = try container.decodeIfPresent([String].self,     forKey: .tags) ?? []
        platforms      = try container.decode([SequencingPlatform].self,  forKey: .platforms)
        requiredInput  = try container.decode(InputRequirement.self,      forKey: .requiredInput)
        qualityBinning = try container.decodeIfPresent(QualityBinningScheme.self, forKey: .qualityBinning)
        steps          = try container.decode([RecipeStep].self,          forKey: .steps)
    }
}
