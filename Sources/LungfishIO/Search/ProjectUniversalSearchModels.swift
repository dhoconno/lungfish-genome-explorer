// ProjectUniversalSearchModels.swift - Query/result models for project-scoped universal search
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - ProjectUniversalSearchResult

/// A single universal-search result scoped to one project.
public struct ProjectUniversalSearchResult: Sendable, Equatable, Identifiable {
    public let id: String
    public let kind: String
    public let title: String
    public let subtitle: String?
    public let format: String?
    public let url: URL

    public init(
        id: String,
        kind: String,
        title: String,
        subtitle: String? = nil,
        format: String? = nil,
        url: URL
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.format = format
        self.url = url
    }
}

// MARK: - ProjectUniversalSearchBuildStats

/// Build diagnostics for index refresh runs.
public struct ProjectUniversalSearchBuildStats: Sendable, Equatable {
    public let indexedEntities: Int
    public let indexedAttributes: Int
    public let durationSeconds: Double
    public let perKindCounts: [String: Int]

    public init(
        indexedEntities: Int,
        indexedAttributes: Int,
        durationSeconds: Double,
        perKindCounts: [String: Int]
    ) {
        self.indexedEntities = indexedEntities
        self.indexedAttributes = indexedAttributes
        self.durationSeconds = durationSeconds
        self.perKindCounts = perKindCounts
    }
}

// MARK: - ProjectUniversalSearchIndexStats

/// Point-in-time index stats.
public struct ProjectUniversalSearchIndexStats: Sendable, Equatable {
    public let entityCount: Int
    public let attributeCount: Int
    public let perKindCounts: [String: Int]
    public let lastIndexedAt: Date?

    public init(
        entityCount: Int,
        attributeCount: Int,
        perKindCounts: [String: Int],
        lastIndexedAt: Date?
    ) {
        self.entityCount = entityCount
        self.attributeCount = attributeCount
        self.perKindCounts = perKindCounts
        self.lastIndexedAt = lastIndexedAt
    }
}

// MARK: - ProjectUniversalSearchQuery

/// Parsed search query used by the universal-search engine.
public struct ProjectUniversalSearchQuery: Sendable, Equatable {

    public enum MatchKind: Sendable, Equatable {
        case contains
        case exact
    }

    public struct AttributeFilter: Sendable, Equatable {
        public let key: String
        public let value: String
        public let match: MatchKind

        public init(key: String, value: String, match: MatchKind = .contains) {
            self.key = key
            self.value = value
            self.match = match
        }
    }

    public var rawText: String
    public var textTerms: [String]
    public var kinds: Set<String>
    public var formats: Set<String>
    public var attributeFilters: [AttributeFilter]
    public var dateFrom: Date?
    public var dateTo: Date?
    public var limit: Int

    public init(
        rawText: String,
        textTerms: [String] = [],
        kinds: Set<String> = [],
        formats: Set<String> = [],
        attributeFilters: [AttributeFilter] = [],
        dateFrom: Date? = nil,
        dateTo: Date? = nil,
        limit: Int = 200
    ) {
        self.rawText = rawText
        self.textTerms = textTerms
        self.kinds = kinds
        self.formats = formats
        self.attributeFilters = attributeFilters
        self.dateFrom = dateFrom
        self.dateTo = dateTo
        self.limit = max(1, limit)
    }
}

// MARK: - ProjectUniversalSearchQueryParser

/// Lightweight token parser for universal search.
///
/// Supported tokens:
/// - `type:<kind>`
/// - `format:<format>`
/// - `sample:<value>`
/// - `virus:<value>`
/// - `role:<value>`
/// - `date>=YYYY-MM-DD`
/// - `date<=YYYY-MM-DD`
/// - generic `key:value`
/// - remaining terms are treated as free text
public enum ProjectUniversalSearchQueryParser {

    public static func parse(_ rawQuery: String, limit: Int = 200) -> ProjectUniversalSearchQuery {
        let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ProjectUniversalSearchQuery(rawText: rawQuery, limit: limit)
        }

        var query = ProjectUniversalSearchQuery(rawText: rawQuery, limit: limit)

        for token in tokenize(trimmed) {
            guard !token.isEmpty else { continue }

            if let date = parseDateBound(token: token, prefix: "date>=") {
                query.dateFrom = date
                continue
            }
            if let date = parseDateBound(token: token, prefix: "date<=") {
                query.dateTo = date
                continue
            }

            if let value = value(after: "type:", in: token) {
                let normalized = normalizeKind(value)
                if !normalized.isEmpty {
                    query.kinds.insert(normalized)
                }
                continue
            }

            if let value = value(after: "format:", in: token) {
                let normalized = normalizeKey(value)
                if !normalized.isEmpty {
                    query.formats.insert(normalized)
                }
                continue
            }

            if let value = value(after: "sample:", in: token) {
                let normalized = normalizeTextValue(value)
                if !normalized.isEmpty {
                    query.attributeFilters.append(.init(key: "sample_name", value: normalized, match: .contains))
                }
                continue
            }

            if let value = value(after: "virus:", in: token) {
                let normalized = normalizeTextValue(value)
                if !normalized.isEmpty {
                    query.attributeFilters.append(.init(key: "virus_name", value: normalized, match: .contains))
                    query.textTerms.append(normalized)
                }
                continue
            }

            if let value = value(after: "role:", in: token) {
                let normalized = normalizeTextValue(value)
                if !normalized.isEmpty {
                    query.attributeFilters.append(.init(key: "sample_role", value: normalized, match: .exact))
                }
                continue
            }

            if let separatorIndex = token.firstIndex(of: ":"), separatorIndex != token.startIndex {
                let key = normalizeKey(String(token[..<separatorIndex]))
                let rawValue = String(token[token.index(after: separatorIndex)...])
                let normalizedValue = normalizeTextValue(rawValue)
                if !key.isEmpty, !normalizedValue.isEmpty {
                    query.attributeFilters.append(.init(key: key, value: normalizedValue, match: .contains))
                    continue
                }
            }

            let freeTerm = normalizeTextValue(token)
            if !freeTerm.isEmpty {
                query.textTerms.append(freeTerm)
            }
        }

        return query
    }

    // MARK: - Tokenization

    private static func tokenize(_ query: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        var quoteCharacter: Character?

        for char in query {
            if (char == "\"" || char == "'") {
                if inQuotes {
                    if quoteCharacter == char {
                        inQuotes = false
                        quoteCharacter = nil
                    } else {
                        current.append(char)
                    }
                } else {
                    inQuotes = true
                    quoteCharacter = char
                }
                continue
            }

            if char.isWhitespace && !inQuotes {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else {
                current.append(char)
            }
        }

        if !current.isEmpty {
            tokens.append(current)
        }

        return tokens
    }

    // MARK: - Parsing Helpers

    private static func parseDateBound(token: String, prefix: String) -> Date? {
        guard let rawValue = value(after: prefix, in: token) else { return nil }
        return parseDate(rawValue)
    }

    private static func value(after prefix: String, in token: String) -> String? {
        guard token.lowercased().hasPrefix(prefix) else { return nil }
        let start = token.index(token.startIndex, offsetBy: prefix.count)
        return String(token[start...])
    }

    private static func parseDate(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: trimmed) {
            return date
        }

        let formats = ["yyyy-MM-dd", "yyyy-MM", "yyyy"]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) {
                return date
            }
        }

        return nil
    }

    private static func normalizeKey(_ key: String) -> String {
        key
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "-", with: "_")
    }

    private static func normalizeKind(_ kind: String) -> String {
        let normalized = normalizeKey(kind)
        switch normalized {
        case "fastq", "fastq_dataset", "fastq_bundle":
            return "fastq_dataset"
        case "reference", "reference_bundle", "ref":
            return "reference_bundle"
        case "vcf", "vcf_track":
            return "vcf_track"
        case "vcf_sample", "sample":
            return "vcf_sample"
        case "classification", "classification_result", "kraken":
            return "classification_result"
        case "esviritu", "esviritu_result":
            return "esviritu_result"
        case "taxtriage", "taxtriage_result":
            return "taxtriage_result"
        case "manifest", "manifest_document":
            return "manifest_document"
        case "virus", "virus_hit":
            return "virus_hit"
        default:
            return normalized
        }
    }

    private static func normalizeTextValue(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}
