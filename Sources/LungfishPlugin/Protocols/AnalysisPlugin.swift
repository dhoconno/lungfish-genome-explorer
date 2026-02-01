// AnalysisPlugin.swift - Sequence analysis plugin protocols
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner: Plugin Architecture Lead (Role 15)

import Foundation
import LungfishCore

// MARK: - Sequence Analysis Plugin

/// Protocol for plugins that analyze sequences and produce results.
///
/// Analysis plugins examine sequences and produce reports, statistics,
/// or other insights without modifying the sequence itself.
///
/// ## Example
/// ```swift
/// struct GCContentPlugin: SequenceAnalysisPlugin {
///     // ... plugin metadata ...
///
///     func analyze(_ input: AnalysisInput) async throws -> AnalysisResult {
///         let gcCount = input.sequence.filter { $0 == "G" || $0 == "C" }.count
///         let total = input.sequence.count
///         let gcPercent = Double(gcCount) / Double(total) * 100
///
///         return AnalysisResult(
///             summary: "GC Content: \(String(format: "%.1f", gcPercent))%",
///             sections: [...]
///         )
///     }
/// }
/// ```
public protocol SequenceAnalysisPlugin: Plugin {

    /// Performs analysis on the input sequence.
    ///
    /// - Parameter input: The sequence and selection to analyze
    /// - Returns: Analysis results for display
    /// - Throws: `PluginError` if analysis fails
    func analyze(_ input: AnalysisInput) async throws -> AnalysisResult

    /// Returns default options for this plugin.
    var defaultOptions: AnalysisOptions { get }

    /// Validates options before running analysis.
    func validateOptions(_ options: AnalysisOptions) throws
}

// MARK: - Default Implementations

extension SequenceAnalysisPlugin {
    public var defaultOptions: AnalysisOptions {
        AnalysisOptions()
    }

    public func validateOptions(_ options: AnalysisOptions) throws {
        // Default: no validation
    }
}

// MARK: - Analysis Input

/// Input data for sequence analysis plugins.
public struct AnalysisInput: Sendable {

    /// The sequence to analyze
    public let sequence: String

    /// The sequence name
    public let sequenceName: String

    /// The sequence alphabet
    public let alphabet: SequenceAlphabet

    /// Selected range within the sequence (nil = whole sequence)
    public let selection: Range<Int>?

    /// User-provided options for this analysis
    public let options: AnalysisOptions

    /// The sequence region to analyze (selection or whole)
    public var regionToAnalyze: String {
        if let selection = selection {
            let start = sequence.index(sequence.startIndex, offsetBy: selection.lowerBound)
            let end = sequence.index(sequence.startIndex, offsetBy: selection.upperBound)
            return String(sequence[start..<end])
        }
        return sequence
    }

    /// Start position of the region being analyzed (0-based)
    public var regionStart: Int {
        selection?.lowerBound ?? 0
    }

    /// End position of the region being analyzed (exclusive)
    public var regionEnd: Int {
        selection?.upperBound ?? sequence.count
    }

    public init(
        sequence: String,
        sequenceName: String = "Sequence",
        alphabet: SequenceAlphabet = .dna,
        selection: Range<Int>? = nil,
        options: AnalysisOptions = AnalysisOptions()
    ) {
        self.sequence = sequence
        self.sequenceName = sequenceName
        self.alphabet = alphabet
        self.selection = selection
        self.options = options
    }
}

// MARK: - Analysis Options

/// User-configurable options for analysis plugins.
public struct AnalysisOptions: Sendable {

    /// Generic key-value storage for plugin-specific options
    private var storage: [String: OptionValue]

    public init(_ values: [String: OptionValue] = [:]) {
        self.storage = values
    }

    public subscript(key: String) -> OptionValue? {
        get { storage[key] }
        set { storage[key] = newValue }
    }

    public func integer(for key: String, default defaultValue: Int = 0) -> Int {
        if case .integer(let value) = storage[key] {
            return value
        }
        return defaultValue
    }

    public func double(for key: String, default defaultValue: Double = 0.0) -> Double {
        if case .double(let value) = storage[key] {
            return value
        }
        return defaultValue
    }

    public func string(for key: String, default defaultValue: String = "") -> String {
        if case .string(let value) = storage[key] {
            return value
        }
        return defaultValue
    }

    public func bool(for key: String, default defaultValue: Bool = false) -> Bool {
        if case .bool(let value) = storage[key] {
            return value
        }
        return defaultValue
    }

    public func stringArray(for key: String, default defaultValue: [String] = []) -> [String] {
        if case .stringArray(let value) = storage[key] {
            return value
        }
        return defaultValue
    }
}

/// A value that can be stored in analysis options.
public enum OptionValue: Sendable, Codable, Equatable {
    case integer(Int)
    case double(Double)
    case string(String)
    case bool(Bool)
    case stringArray([String])
}

// MARK: - Analysis Result

/// Results from a sequence analysis plugin.
public struct AnalysisResult: Sendable {

    /// One-line summary of the results
    public let summary: String

    /// Detailed result sections
    public let sections: [ResultSection]

    /// Annotations generated by the analysis (if any)
    public let annotations: [AnnotationResult]

    /// Raw data for export
    public let exportData: ExportData?

    /// Whether the analysis was successful
    public let isSuccess: Bool

    /// Error message if analysis failed
    public let errorMessage: String?

    public init(
        summary: String,
        sections: [ResultSection] = [],
        annotations: [AnnotationResult] = [],
        exportData: ExportData? = nil,
        isSuccess: Bool = true,
        errorMessage: String? = nil
    ) {
        self.summary = summary
        self.sections = sections
        self.annotations = annotations
        self.exportData = exportData
        self.isSuccess = isSuccess
        self.errorMessage = errorMessage
    }

    /// Creates a failed result with an error message.
    public static func failure(_ message: String) -> AnalysisResult {
        AnalysisResult(
            summary: "Analysis failed",
            isSuccess: false,
            errorMessage: message
        )
    }
}

// MARK: - Result Section

/// A section of analysis results for display.
public struct ResultSection: Sendable, Identifiable {
    public let id: UUID
    public let title: String
    public let content: SectionContent

    public init(title: String, content: SectionContent) {
        self.id = UUID()
        self.title = title
        self.content = content
    }

    /// Creates a text section.
    public static func text(_ title: String, _ text: String) -> ResultSection {
        ResultSection(title: title, content: .text(text))
    }

    /// Creates a key-value section.
    public static func keyValue(_ title: String, _ pairs: [(String, String)]) -> ResultSection {
        ResultSection(title: title, content: .keyValue(pairs))
    }

    /// Creates a table section.
    public static func table(_ title: String, headers: [String], rows: [[String]]) -> ResultSection {
        ResultSection(title: title, content: .table(headers: headers, rows: rows))
    }
}

/// Content types for result sections.
public enum SectionContent: Sendable {
    case text(String)
    case keyValue([(String, String)])
    case table(headers: [String], rows: [[String]])
    case chart(ChartData)
}

/// Data for chart visualization.
public struct ChartData: Sendable {
    public enum ChartType: Sendable {
        case bar
        case line
        case pie
        case histogram
    }

    public let type: ChartType
    public let labels: [String]
    public let values: [Double]
    public let title: String

    public init(type: ChartType, labels: [String], values: [Double], title: String = "") {
        self.type = type
        self.labels = labels
        self.values = values
        self.title = title
    }
}

// MARK: - Annotation Result

/// An annotation generated by analysis.
public struct AnnotationResult: Sendable, Identifiable {
    public let id: UUID
    public let name: String
    public let type: String
    public let start: Int
    public let end: Int
    public let strand: Strand
    public let qualifiers: [String: String]

    public init(
        name: String,
        type: String,
        start: Int,
        end: Int,
        strand: Strand = .forward,
        qualifiers: [String: String] = [:]
    ) {
        self.id = UUID()
        self.name = name
        self.type = type
        self.start = start
        self.end = end
        self.strand = strand
        self.qualifiers = qualifiers
    }
}

/// Strand orientation.
public enum Strand: String, Sendable, Codable {
    case forward = "+"
    case reverse = "-"
    case unknown = "."
}

// MARK: - Export Data

/// Data that can be exported from analysis results.
public struct ExportData: Sendable {
    public let format: ExportFormat
    public let content: String

    public enum ExportFormat: String, Sendable {
        case csv
        case tsv
        case json
        case gff3
        case fasta
    }

    public init(format: ExportFormat, content: String) {
        self.format = format
        self.content = content
    }
}

// MARK: - Plugin Error

/// Errors that can occur during plugin execution.
public enum PluginError: Error, LocalizedError, Sendable {
    case invalidInput(reason: String)
    case invalidOptions(reason: String)
    case analysisError(reason: String)
    case cancelled
    case unsupportedAlphabet(expected: SequenceAlphabet, got: SequenceAlphabet)
    case sequenceTooShort(minimum: Int, actual: Int)

    public var errorDescription: String? {
        switch self {
        case .invalidInput(let reason):
            return "Invalid input: \(reason)"
        case .invalidOptions(let reason):
            return "Invalid options: \(reason)"
        case .analysisError(let reason):
            return "Analysis error: \(reason)"
        case .cancelled:
            return "Analysis was cancelled"
        case .unsupportedAlphabet(let expected, let got):
            return "Unsupported alphabet: expected \(expected.rawValue), got \(got.rawValue)"
        case .sequenceTooShort(let minimum, let actual):
            return "Sequence too short: minimum \(minimum), actual \(actual)"
        }
    }
}
