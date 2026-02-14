// QueryRule.swift - Data model for variant query builder rules
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - Query Rule

/// A single rule in the query builder (e.g. "Quality >= 30").
public struct QueryRule: Codable, Sendable, Identifiable {
    public let id: UUID
    public var category: QueryCategory
    public var field: String
    public var op: String
    public var value: String

    public init(
        id: UUID = UUID(),
        category: QueryCategory = .callQuality,
        field: String = "",
        op: String = "=",
        value: String = ""
    ) {
        self.id = id
        self.category = category
        self.field = field
        self.op = op
        self.value = value
    }

    /// Converts this rule to a semicolon-delimited filter clause string.
    func toFilterClause() -> String? {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty, !field.isEmpty else { return nil }

        switch category {
        case .location:
            switch field {
            case "Region":
                return "region=\(trimmedValue)"
            case "Chromosome":
                return "chr=\(trimmedValue)"
            default:
                return nil
            }
        case .identity:
            switch field {
            case "ID/Name":
                return "text=\(trimmedValue)"
            case "Type":
                return "type=\(trimmedValue)"
            default:
                return nil
            }
        case .biologicalEffect:
            // These map to INFO field queries
            return "\(field)\(op)\(trimmedValue)"
        case .population:
            return "\(field)\(op)\(trimmedValue)"
        case .callQuality:
            switch field {
            case "Quality":
                return "qual\(op)\(trimmedValue)"
            case "Filter":
                return "filter=\(trimmedValue)"
            case "Sample Count":
                return "sc\(op)\(trimmedValue)"
            default:
                return "\(field)\(op)\(trimmedValue)"
            }
        case .sampleGenotype:
            // Not supported yet by the variant table query backend.
            return nil
        }
    }
}

// MARK: - Query Category

/// Categories of query rules in the builder.
public enum QueryCategory: String, Codable, Sendable, CaseIterable, Identifiable {
    case location
    case identity
    case biologicalEffect
    case population
    case callQuality
    case sampleGenotype

    public var id: String { rawValue }

    // Hide unsupported categories from UI while retaining Codable compatibility.
    public static var allCases: [QueryCategory] {
        [.location, .identity, .biologicalEffect, .population, .callQuality]
    }

    public var displayName: String {
        switch self {
        case .location: return "Location"
        case .identity: return "Variant Identity"
        case .biologicalEffect: return "Biological Effect"
        case .population: return "Population/Frequency"
        case .callQuality: return "Call Quality"
        case .sampleGenotype: return "Sample/Genotype"
        }
    }

    /// Returns available fields for this category.
    public var fields: [String] {
        switch self {
        case .location:
            return ["Region", "Chromosome"]
        case .identity:
            return ["ID/Name", "Type"]
        case .biologicalEffect:
            return ["IMPACT", "GENE", "CLNSIG"]
        case .population:
            return ["AF", "gnomAD_AF", "ExAC_AF", "1000G_AF"]
        case .callQuality:
            return ["Quality", "Filter", "DP", "MQ", "Sample Count"]
        case .sampleGenotype:
            return []
        }
    }

    /// Returns available operators for a given field in this category.
    public func operators(for field: String) -> [String] {
        switch self {
        case .location:
            return ["="]
        case .identity:
            if field == "Type" { return ["="] }
            return ["=", "~"]
        case .biologicalEffect:
            if field == "IMPACT" || field == "CLNSIG" { return ["=", "~"] }
            return ["=", "~"]
        case .population:
            return ["<", "<=", ">", ">=", "="]
        case .callQuality:
            if field == "Filter" { return ["="] }
            return ["<", "<=", ">", ">=", "="]
        case .sampleGenotype:
            return []
        }
    }
}

// MARK: - Query Logic

/// How multiple rules are combined.
public enum QueryLogic: String, Codable, Sendable, CaseIterable {
    case matchAll = "all"
    case matchAny = "any"

    // Keep `matchAny` for decode compatibility, but do not expose it in UI until execution supports OR groups.
    public static var allCases: [QueryLogic] { [.matchAll] }

    public var displayName: String {
        switch self {
        case .matchAll: return "Match All"
        case .matchAny: return "Match Any"
        }
    }
}

// MARK: - Query Preset

/// A saved/built-in query preset.
public struct QueryPreset: Codable, Sendable, Identifiable {
    public let id: UUID
    public var name: String
    public var rules: [QueryRule]
    public var logic: QueryLogic
    public let isBuiltIn: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        rules: [QueryRule],
        logic: QueryLogic = .matchAll,
        isBuiltIn: Bool = false
    ) {
        self.id = id
        self.name = name
        self.rules = rules
        self.logic = logic
        self.isBuiltIn = isBuiltIn
    }

    /// Built-in presets available by default.
    public static let builtInPresets: [QueryPreset] = [
        QueryPreset(
            name: "High-Confidence Coding",
            rules: [
                QueryRule(category: .callQuality, field: "Quality", op: ">=", value: "30"),
                QueryRule(category: .callQuality, field: "Filter", op: "=", value: "PASS"),
                QueryRule(category: .biologicalEffect, field: "IMPACT", op: "~", value: "HIGH"),
            ],
            isBuiltIn: true
        ),
        QueryPreset(
            name: "Rare Pathogenic",
            rules: [
                QueryRule(category: .population, field: "AF", op: "<", value: "0.01"),
                QueryRule(category: .biologicalEffect, field: "CLNSIG", op: "~", value: "athogenic"),
            ],
            isBuiltIn: true
        ),
        QueryPreset(
            name: "Quality Review",
            rules: [
                QueryRule(category: .callQuality, field: "Quality", op: "<", value: "30"),
                QueryRule(category: .callQuality, field: "DP", op: ">=", value: "10"),
            ],
            isBuiltIn: true
        ),
    ]
}
