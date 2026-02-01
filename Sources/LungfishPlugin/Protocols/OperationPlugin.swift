// OperationPlugin.swift - Sequence operation plugin protocols
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner: Plugin Architecture Lead (Role 15)

import Foundation
import LungfishCore

// MARK: - Sequence Operation Plugin

/// Protocol for plugins that transform sequences.
///
/// Operation plugins take a sequence and produce a modified version,
/// such as reverse complement, translation, or format conversion.
///
/// ## Example
/// ```swift
/// struct ReverseComplementPlugin: SequenceOperationPlugin {
///     // ... plugin metadata ...
///
///     func transform(_ input: OperationInput) async throws -> OperationResult {
///         let reversed = String(input.sequence.reversed())
///         let complemented = reversed.map { complementBase($0) }
///         return OperationResult(sequence: String(complemented))
///     }
/// }
/// ```
public protocol SequenceOperationPlugin: Plugin {

    /// Transforms the input sequence.
    ///
    /// - Parameter input: The sequence to transform
    /// - Returns: The transformed sequence
    /// - Throws: `PluginError` if transformation fails
    func transform(_ input: OperationInput) async throws -> OperationResult

    /// Returns default options for this plugin.
    var defaultOptions: OperationOptions { get }

    /// Validates options before running the operation.
    func validateOptions(_ options: OperationOptions) throws

    /// Whether this operation can be previewed in real-time
    var supportsPreview: Bool { get }
}

// MARK: - Default Implementations

extension SequenceOperationPlugin {
    public var defaultOptions: OperationOptions {
        OperationOptions()
    }

    public func validateOptions(_ options: OperationOptions) throws {
        // Default: no validation
    }

    public var supportsPreview: Bool { true }
}

// MARK: - Operation Input

/// Input data for sequence operation plugins.
public struct OperationInput: Sendable {

    /// The sequence to transform
    public let sequence: String

    /// The sequence name
    public let sequenceName: String

    /// The sequence alphabet
    public let alphabet: SequenceAlphabet

    /// Selected range within the sequence (nil = whole sequence)
    public let selection: Range<Int>?

    /// User-provided options for this operation
    public let options: OperationOptions

    /// The sequence region to transform (selection or whole)
    public var regionToTransform: String {
        if let selection = selection {
            let start = sequence.index(sequence.startIndex, offsetBy: selection.lowerBound)
            let end = sequence.index(sequence.startIndex, offsetBy: selection.upperBound)
            return String(sequence[start..<end])
        }
        return sequence
    }

    public init(
        sequence: String,
        sequenceName: String = "Sequence",
        alphabet: SequenceAlphabet = .dna,
        selection: Range<Int>? = nil,
        options: OperationOptions = OperationOptions()
    ) {
        self.sequence = sequence
        self.sequenceName = sequenceName
        self.alphabet = alphabet
        self.selection = selection
        self.options = options
    }
}

// MARK: - Operation Options

/// User-configurable options for operation plugins.
public struct OperationOptions: Sendable {

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
}

// MARK: - Operation Result

/// Result from a sequence operation plugin.
public struct OperationResult: Sendable {

    /// The transformed sequence
    public let sequence: String

    /// Name for the result sequence
    public let sequenceName: String?

    /// Alphabet of the result sequence
    public let alphabet: SequenceAlphabet?

    /// Annotations to apply to the result
    public let annotations: [AnnotationResult]

    /// Whether the operation was successful
    public let isSuccess: Bool

    /// Error message if operation failed
    public let errorMessage: String?

    /// Additional metadata about the transformation
    public let metadata: [String: String]

    public init(
        sequence: String,
        sequenceName: String? = nil,
        alphabet: SequenceAlphabet? = nil,
        annotations: [AnnotationResult] = [],
        isSuccess: Bool = true,
        errorMessage: String? = nil,
        metadata: [String: String] = [:]
    ) {
        self.sequence = sequence
        self.sequenceName = sequenceName
        self.alphabet = alphabet
        self.annotations = annotations
        self.isSuccess = isSuccess
        self.errorMessage = errorMessage
        self.metadata = metadata
    }

    /// Creates a failed result with an error message.
    public static func failure(_ message: String) -> OperationResult {
        OperationResult(
            sequence: "",
            isSuccess: false,
            errorMessage: message
        )
    }
}

// MARK: - Annotation Generator Plugin

/// Protocol for plugins that generate annotations from sequences.
///
/// These plugins analyze sequences and produce annotations (features)
/// without modifying the sequence itself.
///
/// ## Example
/// ```swift
/// struct ORFFinderPlugin: AnnotationGeneratorPlugin {
///     func generateAnnotations(_ input: AnnotationInput) async throws -> [AnnotationResult] {
///         var orfs: [AnnotationResult] = []
///         // Find ORFs and create annotations...
///         return orfs
///     }
/// }
/// ```
public protocol AnnotationGeneratorPlugin: Plugin {

    /// Generates annotations from the input sequence.
    ///
    /// - Parameter input: The sequence to analyze
    /// - Returns: Array of annotations found
    /// - Throws: `PluginError` if generation fails
    func generateAnnotations(_ input: AnnotationInput) async throws -> [AnnotationResult]

    /// Returns default options for this plugin.
    var defaultOptions: AnnotationOptions { get }

    /// Validates options before generating annotations.
    func validateOptions(_ options: AnnotationOptions) throws
}

// MARK: - Default Implementations

extension AnnotationGeneratorPlugin {
    public var defaultOptions: AnnotationOptions {
        AnnotationOptions()
    }

    public func validateOptions(_ options: AnnotationOptions) throws {
        // Default: no validation
    }
}

// MARK: - Annotation Input

/// Input data for annotation generator plugins.
public struct AnnotationInput: Sendable {

    /// The sequence to analyze
    public let sequence: String

    /// The sequence name
    public let sequenceName: String

    /// The sequence alphabet
    public let alphabet: SequenceAlphabet

    /// Existing annotations (for context)
    public let existingAnnotations: [AnnotationResult]

    /// User-provided options
    public let options: AnnotationOptions

    public init(
        sequence: String,
        sequenceName: String = "Sequence",
        alphabet: SequenceAlphabet = .dna,
        existingAnnotations: [AnnotationResult] = [],
        options: AnnotationOptions = AnnotationOptions()
    ) {
        self.sequence = sequence
        self.sequenceName = sequenceName
        self.alphabet = alphabet
        self.existingAnnotations = existingAnnotations
        self.options = options
    }
}

// MARK: - Annotation Options

/// Options for annotation generation.
public struct AnnotationOptions: Sendable {

    /// Generic key-value storage
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

    public func bool(for key: String, default defaultValue: Bool = false) -> Bool {
        if case .bool(let value) = storage[key] {
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

    public func stringArray(for key: String, default defaultValue: [String] = []) -> [String] {
        if case .stringArray(let value) = storage[key] {
            return value
        }
        return defaultValue
    }
}
