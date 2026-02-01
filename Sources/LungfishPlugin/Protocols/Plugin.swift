// Plugin.swift - Base plugin protocol definitions
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner: Plugin Architecture Lead (Role 15)

import Foundation

// MARK: - Base Plugin Protocol

/// Base protocol for all Lungfish plugins.
///
/// Plugins extend Lungfish's functionality by providing sequence analysis,
/// operations, annotation generation, and visualization capabilities.
///
/// ## Plugin Categories
/// - **Sequence Analysis**: Analyze sequences and produce reports
/// - **Sequence Operations**: Transform sequences (complement, translate)
/// - **Annotation Tools**: Generate annotations from sequences
/// - **Visualization**: Create custom visualizations
///
/// ## Example
/// ```swift
/// struct MyPlugin: SequenceAnalysisPlugin {
///     let id = "com.example.my-plugin"
///     let name = "My Plugin"
///     let version = "1.0.0"
///     let category = PluginCategory.sequenceAnalysis
///
///     func analyze(_ sequence: Sequence, options: AnalysisOptions) async throws -> AnalysisResult {
///         // Analysis implementation
///     }
/// }
/// ```
public protocol Plugin: Identifiable, Sendable {

    /// Unique identifier in reverse domain notation (e.g., "com.lungfish.restriction-finder")
    var id: String { get }

    /// Human-readable display name
    var name: String { get }

    /// Semantic version string (e.g., "1.0.0")
    var version: String { get }

    /// Brief description of what this plugin does
    var description: String { get }

    /// Plugin category for organization in menus
    var category: PluginCategory { get }

    /// Capability flags for UI integration
    var capabilities: PluginCapabilities { get }

    /// Required sequence alphabet (nil means any)
    var requiredAlphabet: SequenceAlphabet? { get }

    /// Minimum sequence length required (0 means no minimum)
    var minimumSequenceLength: Int { get }

    /// Icon name (SF Symbol name)
    var iconName: String { get }

    /// Keyboard shortcut (optional)
    var keyboardShortcut: KeyboardShortcut? { get }
}

// MARK: - Default Implementations

extension Plugin {
    public var requiredAlphabet: SequenceAlphabet? { nil }
    public var minimumSequenceLength: Int { 0 }
    public var iconName: String { "puzzlepiece.extension" }
    public var keyboardShortcut: KeyboardShortcut? { nil }
}

// MARK: - Plugin Category

/// Categories for organizing plugins in menus and UI.
public enum PluginCategory: String, Sendable, CaseIterable, Codable {
    case sequenceAnalysis = "Sequence Analysis"
    case sequenceOperations = "Sequence Operations"
    case annotationTools = "Annotation Tools"
    case visualization = "Visualization"
    case dataImport = "Data Import"
    case dataExport = "Data Export"
    case workflow = "Workflow"
    case utility = "Utility"

    /// SF Symbol icon for this category
    public var iconName: String {
        switch self {
        case .sequenceAnalysis: return "chart.bar.doc.horizontal"
        case .sequenceOperations: return "arrow.triangle.swap"
        case .annotationTools: return "tag"
        case .visualization: return "chart.xyaxis.line"
        case .dataImport: return "square.and.arrow.down"
        case .dataExport: return "square.and.arrow.up"
        case .workflow: return "flowchart"
        case .utility: return "wrench.and.screwdriver"
        }
    }
}

// MARK: - Plugin Capabilities

/// Capability flags describing what a plugin can do.
///
/// These flags are used by the UI to determine where and how to display
/// plugin options (menus, context menus, toolbars).
public struct PluginCapabilities: OptionSet, Sendable, Codable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// Plugin can operate on a selection within a sequence
    public static let worksOnSelection = PluginCapabilities(rawValue: 1 << 0)

    /// Plugin can operate on whole sequences
    public static let worksOnWholeSequence = PluginCapabilities(rawValue: 1 << 1)

    /// Plugin generates annotations as output
    public static let generatesAnnotations = PluginCapabilities(rawValue: 1 << 2)

    /// Plugin modifies the sequence (requires editing permissions)
    public static let modifiesSequence = PluginCapabilities(rawValue: 1 << 3)

    /// Plugin produces a text/HTML report
    public static let producesReport = PluginCapabilities(rawValue: 1 << 4)

    /// Plugin produces a new sequence
    public static let producesSequence = PluginCapabilities(rawValue: 1 << 5)

    /// Plugin requires protein sequence input
    public static let requiresProtein = PluginCapabilities(rawValue: 1 << 6)

    /// Plugin requires nucleotide sequence input
    public static let requiresNucleotide = PluginCapabilities(rawValue: 1 << 7)

    /// Plugin can work on multiple sequences at once
    public static let supportsMultipleSequences = PluginCapabilities(rawValue: 1 << 8)

    /// Plugin provides real-time results as you type/select
    public static let supportsLivePreview = PluginCapabilities(rawValue: 1 << 9)

    /// Plugin can be cancelled mid-operation
    public static let supportsCancellation = PluginCapabilities(rawValue: 1 << 10)

    /// Common combination: analysis that works on selection or whole sequence
    public static let standardAnalysis: PluginCapabilities = [.worksOnSelection, .worksOnWholeSequence, .producesReport]

    /// Common combination: generates annotations from nucleotide sequences
    public static let nucleotideAnnotator: PluginCapabilities = [.worksOnWholeSequence, .generatesAnnotations, .requiresNucleotide]
}

// MARK: - Keyboard Shortcut

/// Represents a keyboard shortcut for a plugin.
public struct KeyboardShortcut: Sendable, Codable, Equatable {
    public let key: String
    public let modifiers: Modifiers

    public struct Modifiers: OptionSet, Sendable, Codable {
        public let rawValue: Int

        public init(rawValue: Int) {
            self.rawValue = rawValue
        }

        public static let command = Modifiers(rawValue: 1 << 0)
        public static let shift = Modifiers(rawValue: 1 << 1)
        public static let option = Modifiers(rawValue: 1 << 2)
        public static let control = Modifiers(rawValue: 1 << 3)
    }

    public init(key: String, modifiers: Modifiers = .command) {
        self.key = key
        self.modifiers = modifiers
    }
}

// MARK: - Sequence Alphabet

/// The type of sequence alphabet.
public enum SequenceAlphabet: String, Sendable, Codable, CaseIterable {
    case dna = "DNA"
    case rna = "RNA"
    case protein = "Protein"

    /// Valid characters for this alphabet
    public var validCharacters: Set<Character> {
        switch self {
        case .dna:
            return Set("ATCGNatcgn")
        case .rna:
            return Set("AUCGNaucgn")
        case .protein:
            return Set("ACDEFGHIKLMNPQRSTVWYacdefghiklmnpqrstvwy*")
        }
    }

    /// IUPAC ambiguity codes for this alphabet
    public var ambiguityCodes: Set<Character> {
        switch self {
        case .dna:
            return Set("RYSWKMBDHVNryswkmbdhvn")
        case .rna:
            return Set("RYSWKMBDHVNryswkmbdhvn")
        case .protein:
            return Set("BZXbzx")
        }
    }

    /// Whether this is a nucleotide alphabet
    public var isNucleotide: Bool {
        self == .dna || self == .rna
    }
}
