// WorkflowSchema.swift - Nextflow schema types for parameter UI generation
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - NextflowWorkflowSchema

/// Represents a parsed Nextflow workflow schema (nextflow_schema.json).
///
/// This structure follows the nf-core schema specification which defines
/// workflow parameters in JSON Schema format with additional UI hints.
///
/// ## Example
///
/// ```swift
/// let schema = try NextflowWorkflowSchema.parse(from: schemaURL)
/// for group in schema.parameterGroups {
///     print("Group: \(group.title)")
///     for param in group.parameters {
///         print("  - \(param.name): \(param.type)")
///     }
/// }
/// ```
public struct NextflowWorkflowSchema: Sendable, Codable {

    /// Schema format version
    public let schemaVersion: String

    /// Workflow title
    public let title: String

    /// Workflow description
    public let description: String

    /// Workflow type (e.g., "pipeline")
    public let type: String?

    /// URL to workflow documentation
    public let url: URL?

    /// Parameter groups organized by category
    public let parameterGroups: [NextflowParameterGroup]

    /// All parameters flattened (convenience accessor)
    public var allParameters: [NextflowParameter] {
        parameterGroups.flatMap { $0.parameters }
    }

    /// Creates a new workflow schema.
    public init(
        schemaVersion: String = "1.0",
        title: String,
        description: String,
        type: String? = nil,
        url: URL? = nil,
        parameterGroups: [NextflowParameterGroup]
    ) {
        self.schemaVersion = schemaVersion
        self.title = title
        self.description = description
        self.type = type
        self.url = url
        self.parameterGroups = parameterGroups
    }
}

// Type alias for backward compatibility
public typealias WorkflowSchema = NextflowWorkflowSchema

// MARK: - NextflowParameterGroup

/// A group of related workflow parameters.
///
/// Groups organize parameters into collapsible sections in the UI,
/// typically corresponding to pipeline phases like "Input/Output",
/// "Reference genome", or "Process options".
public struct NextflowParameterGroup: Sendable, Codable, Identifiable {

    /// Unique identifier for the group
    public let id: String

    /// Display title for the group
    public let title: String

    /// Description of the parameter group
    public let description: String?

    /// Icon name (SF Symbol) for the group
    public let icon: String?

    /// Whether the group should be collapsed by default
    public let collapsedByDefault: Bool

    /// Whether the group contains hidden/advanced parameters
    public let isAdvanced: Bool

    /// Parameters in this group
    public let parameters: [NextflowParameter]

    /// Creates a new parameter group.
    public init(
        id: String,
        title: String,
        description: String? = nil,
        icon: String? = nil,
        collapsedByDefault: Bool = false,
        isAdvanced: Bool = false,
        parameters: [NextflowParameter]
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.icon = icon
        self.collapsedByDefault = collapsedByDefault
        self.isAdvanced = isAdvanced
        self.parameters = parameters
    }
}

// Type alias for backward compatibility
public typealias ParameterGroup = NextflowParameterGroup

// MARK: - NextflowParameter

/// A single workflow parameter definition.
///
/// Parameters define the inputs that users can configure when running
/// a workflow. Each parameter has a type, validation constraints,
/// and UI presentation hints.
public struct NextflowParameter: Sendable, Codable, Identifiable {

    /// Parameter identifier (used as CLI argument)
    public let id: String

    /// Display name for the parameter
    public let name: String

    /// Description shown as tooltip/help text
    public let description: String?

    /// Data type of the parameter
    public let type: NextflowParameterType

    /// Default value if not specified
    public let defaultValue: NextflowParameterValue?

    /// Whether this parameter is required
    public let isRequired: Bool

    /// Whether this parameter should be hidden from basic UI
    public let isHidden: Bool

    /// Validation constraints
    public let validation: NextflowParameterValidation?

    /// Enumeration options for `enumeration` type
    public let enumValues: [String]?

    /// File type hints for `file` type (e.g., ["fasta", "fa", "fna"])
    public let filePatterns: [String]?

    /// Help text shown in detailed view
    public let helpText: String?

    /// Creates a new workflow parameter.
    public init(
        id: String,
        name: String,
        description: String? = nil,
        type: NextflowParameterType,
        defaultValue: NextflowParameterValue? = nil,
        isRequired: Bool = false,
        isHidden: Bool = false,
        validation: NextflowParameterValidation? = nil,
        enumValues: [String]? = nil,
        filePatterns: [String]? = nil,
        helpText: String? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.type = type
        self.defaultValue = defaultValue
        self.isRequired = isRequired
        self.isHidden = isHidden
        self.validation = validation
        self.enumValues = enumValues
        self.filePatterns = filePatterns
        self.helpText = helpText
    }
}

// Type alias for backward compatibility
public typealias WorkflowParameter = NextflowParameter

// MARK: - NextflowParameterType

/// The data type of a workflow parameter.
public enum NextflowParameterType: String, Sendable, Codable, CaseIterable {
    /// String/text input
    case string

    /// Integer number
    case integer

    /// Floating-point number
    case number

    /// Boolean flag
    case boolean

    /// File path input
    case file

    /// Directory path input
    case directory

    /// Selection from enumerated values
    case enumeration

    /// Array of values (comma-separated)
    case array

    /// Display name for the type
    public var displayName: String {
        switch self {
        case .string: return "Text"
        case .integer: return "Integer"
        case .number: return "Number"
        case .boolean: return "Boolean"
        case .file: return "File"
        case .directory: return "Directory"
        case .enumeration: return "Selection"
        case .array: return "List"
        }
    }
}

// MARK: - NextflowParameterValue

/// A parameter value that can be one of several types (Nextflow-specific).
public enum NextflowParameterValue: Sendable, Codable, Equatable, CustomStringConvertible {
    case string(String)
    case integer(Int)
    case number(Double)
    case boolean(Bool)
    case array([String])
    case null

    /// String representation of the value
    public var description: String {
        switch self {
        case .string(let value): return value
        case .integer(let value): return String(value)
        case .number(let value): return String(value)
        case .boolean(let value): return value ? "true" : "false"
        case .array(let values): return values.joined(separator: ", ")
        case .null: return ""
        }
    }

    /// String value or nil
    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    /// Integer value or nil
    public var intValue: Int? {
        if case .integer(let value) = self { return value }
        return nil
    }

    /// Number value or nil
    public var doubleValue: Double? {
        switch self {
        case .number(let value): return value
        case .integer(let value): return Double(value)
        default: return nil
        }
    }

    /// Boolean value or nil
    public var boolValue: Bool? {
        if case .boolean(let value) = self { return value }
        return nil
    }

    /// Array value or nil
    public var arrayValue: [String]? {
        if case .array(let values) = self { return values }
        return nil
    }

    // MARK: Codable

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? container.decode(Int.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let values = try? container.decode([String].self) {
            self = .array(values)
        } else {
            throw DecodingError.typeMismatch(
                NextflowParameterValue.self,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Unable to decode NextflowParameterValue"
                )
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .boolean(let value): try container.encode(value)
        case .array(let values): try container.encode(values)
        case .null: try container.encodeNil()
        }
    }
}

// MARK: - NextflowParameterValidation

/// Validation constraints for a parameter (Nextflow-specific).
public struct NextflowParameterValidation: Sendable, Codable {

    /// Minimum value (for integer/number)
    public let minimum: Double?

    /// Maximum value (for integer/number)
    public let maximum: Double?

    /// Minimum length (for string/array)
    public let minLength: Int?

    /// Maximum length (for string/array)
    public let maxLength: Int?

    /// Regex pattern (for string)
    public let pattern: String?

    /// File must exist (for file/directory)
    public let mustExist: Bool?

    /// Creates validation constraints.
    public init(
        minimum: Double? = nil,
        maximum: Double? = nil,
        minLength: Int? = nil,
        maxLength: Int? = nil,
        pattern: String? = nil,
        mustExist: Bool? = nil
    ) {
        self.minimum = minimum
        self.maximum = maximum
        self.minLength = minLength
        self.maxLength = maxLength
        self.pattern = pattern
        self.mustExist = mustExist
    }

    /// Validates a value against the constraints.
    ///
    /// - Parameter value: The value to validate
    /// - Returns: An error message if validation fails, nil if valid
    public func validate(_ value: NextflowParameterValue) -> String? {
        switch value {
        case .integer(let intValue):
            if let min = minimum, Double(intValue) < min {
                return "Value must be at least \(Int(min))"
            }
            if let max = maximum, Double(intValue) > max {
                return "Value must be at most \(Int(max))"
            }

        case .number(let doubleValue):
            if let min = minimum, doubleValue < min {
                return "Value must be at least \(min)"
            }
            if let max = maximum, doubleValue > max {
                return "Value must be at most \(max)"
            }

        case .string(let stringValue):
            if let minLen = minLength, stringValue.count < minLen {
                return "Must be at least \(minLen) characters"
            }
            if let maxLen = maxLength, stringValue.count > maxLen {
                return "Must be at most \(maxLen) characters"
            }
            if let pattern = pattern {
                let regex = try? NSRegularExpression(pattern: pattern)
                let range = NSRange(stringValue.startIndex..., in: stringValue)
                if regex?.firstMatch(in: stringValue, range: range) == nil {
                    return "Value does not match required format"
                }
            }

        case .array(let values):
            if let minLen = minLength, values.count < minLen {
                return "Must have at least \(minLen) items"
            }
            if let maxLen = maxLength, values.count > maxLen {
                return "Must have at most \(maxLen) items"
            }

        default:
            break
        }

        return nil
    }
}

// MARK: - NextflowWorkflowParameters

/// A collection of parameter values for workflow execution (Nextflow-specific).
///
/// This type maps parameter IDs to their values and provides
/// serialization for passing to workflow runners.
public struct NextflowWorkflowParameters: Sendable, Codable {

    /// The parameter values keyed by parameter ID
    public var values: [String: NextflowParameterValue]

    /// Creates empty parameters.
    public init() {
        self.values = [:]
    }

    /// Creates parameters with initial values.
    public init(values: [String: NextflowParameterValue]) {
        self.values = values
    }

    /// Gets a parameter value.
    public subscript(key: String) -> NextflowParameterValue? {
        get { values[key] }
        set { values[key] = newValue }
    }

    /// Sets a string value.
    public mutating func set(_ key: String, string value: String) {
        values[key] = .string(value)
    }

    /// Sets an integer value.
    public mutating func set(_ key: String, integer value: Int) {
        values[key] = .integer(value)
    }

    /// Sets a number value.
    public mutating func set(_ key: String, number value: Double) {
        values[key] = .number(value)
    }

    /// Sets a boolean value.
    public mutating func set(_ key: String, boolean value: Bool) {
        values[key] = .boolean(value)
    }

    /// Sets an array value.
    public mutating func set(_ key: String, array value: [String]) {
        values[key] = .array(value)
    }

    /// Converts to JSON for workflow runner.
    public func toJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(values)
    }

    /// Converts to command-line arguments.
    ///
    /// - Parameter prefix: Argument prefix (e.g., "--" for Nextflow)
    /// - Returns: Array of command-line argument strings
    public func toCommandLineArgs(prefix: String = "--") -> [String] {
        var args: [String] = []

        for (key, value) in values.sorted(by: { $0.key < $1.key }) {
            switch value {
            case .boolean(true):
                args.append("\(prefix)\(key)")
            case .boolean(false):
                // Skip false booleans
                continue
            case .null:
                continue
            default:
                args.append("\(prefix)\(key)")
                args.append(value.description)
            }
        }

        return args
    }
}
