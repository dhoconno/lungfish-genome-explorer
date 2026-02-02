// WorkflowParameters.swift - Parameter values for workflow execution
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner: Swift Architecture Lead (Role 01)

import Foundation

// MARK: - ParameterValue

/// A typed parameter value for workflow execution.
///
/// ParameterValue represents different types of values that can be
/// passed to workflow engines. It provides type-safe extraction and
/// conversion utilities.
///
/// ## Example
///
/// ```swift
/// let stringParam = ParameterValue.string("hello")
/// let intParam = ParameterValue.integer(42)
/// let fileParam = ParameterValue.file(URL(fileURLWithPath: "/data/input.fasta"))
///
/// // Extract values
/// if let s = stringParam.stringValue {
///     print(s) // "hello"
/// }
/// ```
public enum ParameterValue: Sendable, Codable, Hashable {
    /// A string value.
    case string(String)

    /// An integer value.
    case integer(Int)

    /// A floating-point number value.
    case number(Double)

    /// A boolean value.
    case boolean(Bool)

    /// A file path value.
    case file(URL)

    /// An array of parameter values.
    case array([ParameterValue])

    /// A dictionary of parameter values.
    case dictionary([String: ParameterValue])

    /// A null/empty value.
    case null

    // MARK: - Value Extraction

    /// Returns the value as a string, or nil if not a string.
    public var stringValue: String? {
        if case .string(let value) = self {
            return value
        }
        return nil
    }

    /// Returns the value as an integer, or nil if not an integer.
    public var integerValue: Int? {
        if case .integer(let value) = self {
            return value
        }
        return nil
    }

    /// Returns the value as a double, or nil if not a number.
    public var numberValue: Double? {
        switch self {
        case .number(let value):
            return value
        case .integer(let value):
            return Double(value)
        default:
            return nil
        }
    }

    /// Returns the value as a boolean, or nil if not a boolean.
    public var booleanValue: Bool? {
        if case .boolean(let value) = self {
            return value
        }
        return nil
    }

    /// Returns the value as a file URL, or nil if not a file.
    public var fileValue: URL? {
        if case .file(let value) = self {
            return value
        }
        return nil
    }

    /// Returns the value as an array, or nil if not an array.
    public var arrayValue: [ParameterValue]? {
        if case .array(let value) = self {
            return value
        }
        return nil
    }

    /// Returns the value as a dictionary, or nil if not a dictionary.
    public var dictionaryValue: [String: ParameterValue]? {
        if case .dictionary(let value) = self {
            return value
        }
        return nil
    }

    /// Returns whether this value is null.
    public var isNull: Bool {
        if case .null = self {
            return true
        }
        return false
    }

    // MARK: - Conversion

    /// Converts the value to a string representation for command-line arguments.
    public func toArgumentString() -> String {
        switch self {
        case .string(let value):
            return value
        case .integer(let value):
            return String(value)
        case .number(let value):
            return String(value)
        case .boolean(let value):
            return value ? "true" : "false"
        case .file(let url):
            return url.path
        case .array(let values):
            return values.map { $0.toArgumentString() }.joined(separator: ",")
        case .dictionary(let dict):
            return dict.map { "\($0.key)=\($0.value.toArgumentString())" }.joined(separator: ",")
        case .null:
            return ""
        }
    }

    /// Converts the value to a JSON-compatible object.
    public func toJSONObject() -> Any {
        switch self {
        case .string(let value):
            return value
        case .integer(let value):
            return value
        case .number(let value):
            return value
        case .boolean(let value):
            return value
        case .file(let url):
            return url.path
        case .array(let values):
            return values.map { $0.toJSONObject() }
        case .dictionary(let dict):
            return dict.mapValues { $0.toJSONObject() }
        case .null:
            return NSNull()
        }
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case type, value
    }

    private enum ValueType: String, Codable {
        case string, integer, number, boolean, file, array, dictionary, null
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(ValueType.self, forKey: .type)

        switch type {
        case .string:
            self = .string(try container.decode(String.self, forKey: .value))
        case .integer:
            self = .integer(try container.decode(Int.self, forKey: .value))
        case .number:
            self = .number(try container.decode(Double.self, forKey: .value))
        case .boolean:
            self = .boolean(try container.decode(Bool.self, forKey: .value))
        case .file:
            let path = try container.decode(String.self, forKey: .value)
            self = .file(URL(fileURLWithPath: path))
        case .array:
            self = .array(try container.decode([ParameterValue].self, forKey: .value))
        case .dictionary:
            self = .dictionary(try container.decode([String: ParameterValue].self, forKey: .value))
        case .null:
            self = .null
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .string(let value):
            try container.encode(ValueType.string, forKey: .type)
            try container.encode(value, forKey: .value)
        case .integer(let value):
            try container.encode(ValueType.integer, forKey: .type)
            try container.encode(value, forKey: .value)
        case .number(let value):
            try container.encode(ValueType.number, forKey: .type)
            try container.encode(value, forKey: .value)
        case .boolean(let value):
            try container.encode(ValueType.boolean, forKey: .type)
            try container.encode(value, forKey: .value)
        case .file(let url):
            try container.encode(ValueType.file, forKey: .type)
            try container.encode(url.path, forKey: .value)
        case .array(let value):
            try container.encode(ValueType.array, forKey: .type)
            try container.encode(value, forKey: .value)
        case .dictionary(let value):
            try container.encode(ValueType.dictionary, forKey: .type)
            try container.encode(value, forKey: .value)
        case .null:
            try container.encode(ValueType.null, forKey: .type)
        }
    }
}

// MARK: - WorkflowParameters

/// A collection of parameter values for workflow execution.
///
/// WorkflowParameters provides a type-safe container for workflow
/// parameter values with convenience accessors and validation.
///
/// ## Example
///
/// ```swift
/// var params = WorkflowParameters()
/// params["input"] = .file(inputURL)
/// params["genome"] = .string("GRCh38")
/// params["threads"] = .integer(8)
/// params["skip_qc"] = .boolean(false)
///
/// // Generate command-line arguments
/// let args = params.toNextflowArguments()
/// // ["--input", "/path/to/input", "--genome", "GRCh38", "--threads", "8"]
/// ```
public struct WorkflowParameters: Sendable, Codable, Hashable {

    // MARK: - Storage

    /// Internal storage for parameter values.
    private var values: [String: ParameterValue]

    // MARK: - Initialization

    /// Creates an empty parameter collection.
    public init() {
        self.values = [:]
    }

    /// Creates a parameter collection from a dictionary.
    ///
    /// - Parameter values: Dictionary of parameter names to values
    public init(values: [String: ParameterValue]) {
        self.values = values
    }

    // MARK: - Subscript Access

    /// Access a parameter value by name.
    public subscript(name: String) -> ParameterValue? {
        get { values[name] }
        set { values[name] = newValue }
    }

    // MARK: - Typed Accessors

    /// Returns a string parameter value.
    public func string(_ name: String) -> String? {
        values[name]?.stringValue
    }

    /// Returns an integer parameter value.
    public func integer(_ name: String) -> Int? {
        values[name]?.integerValue
    }

    /// Returns a number parameter value.
    public func number(_ name: String) -> Double? {
        values[name]?.numberValue
    }

    /// Returns a boolean parameter value.
    public func boolean(_ name: String) -> Bool? {
        values[name]?.booleanValue
    }

    /// Returns a file parameter value.
    public func file(_ name: String) -> URL? {
        values[name]?.fileValue
    }

    /// Returns an array parameter value.
    public func array(_ name: String) -> [ParameterValue]? {
        values[name]?.arrayValue
    }

    // MARK: - Convenience Setters

    /// Sets a string parameter.
    public mutating func set(_ name: String, string value: String) {
        values[name] = .string(value)
    }

    /// Sets an integer parameter.
    public mutating func set(_ name: String, integer value: Int) {
        values[name] = .integer(value)
    }

    /// Sets a number parameter.
    public mutating func set(_ name: String, number value: Double) {
        values[name] = .number(value)
    }

    /// Sets a boolean parameter.
    public mutating func set(_ name: String, boolean value: Bool) {
        values[name] = .boolean(value)
    }

    /// Sets a file parameter.
    public mutating func set(_ name: String, file value: URL) {
        values[name] = .file(value)
    }

    // MARK: - Collection Properties

    /// All parameter names.
    public var names: [String] {
        Array(values.keys)
    }

    /// Number of parameters.
    public var count: Int {
        values.count
    }

    /// Whether the collection is empty.
    public var isEmpty: Bool {
        values.isEmpty
    }

    /// Removes all parameters.
    public mutating func removeAll() {
        values.removeAll()
    }

    /// Removes a parameter by name.
    @discardableResult
    public mutating func remove(_ name: String) -> ParameterValue? {
        values.removeValue(forKey: name)
    }

    // MARK: - Merging

    /// Merges another parameter collection into this one.
    ///
    /// Values from `other` overwrite existing values with the same name.
    ///
    /// - Parameter other: The parameters to merge
    public mutating func merge(_ other: WorkflowParameters) {
        values.merge(other.values) { _, new in new }
    }

    /// Returns a new collection by merging with another.
    public func merging(_ other: WorkflowParameters) -> WorkflowParameters {
        var result = self
        result.merge(other)
        return result
    }

    // MARK: - Command-Line Conversion

    /// Converts parameters to Nextflow command-line arguments.
    ///
    /// - Parameter prefix: Argument prefix (default: "--")
    /// - Returns: Array of command-line argument strings
    public func toNextflowArguments(prefix: String = "--") -> [String] {
        var args: [String] = []

        for (name, value) in values.sorted(by: { $0.key < $1.key }) {
            guard !value.isNull else { continue }

            if case .boolean(let boolValue) = value {
                if boolValue {
                    args.append("\(prefix)\(name)")
                }
            } else {
                args.append("\(prefix)\(name)")
                args.append(value.toArgumentString())
            }
        }

        return args
    }

    /// Converts parameters to Snakemake config format.
    ///
    /// - Returns: Dictionary suitable for YAML/JSON serialization
    public func toSnakemakeConfig() -> [String: Any] {
        values.mapValues { $0.toJSONObject() }
    }

    /// Converts parameters to environment variables.
    ///
    /// - Parameter prefix: Variable name prefix
    /// - Returns: Dictionary of environment variable names to values
    public func toEnvironment(prefix: String = "WORKFLOW_") -> [String: String] {
        var env: [String: String] = [:]

        for (name, value) in values {
            let envName = prefix + name.uppercased().replacingOccurrences(of: "-", with: "_")
            env[envName] = value.toArgumentString()
        }

        return env
    }

    // MARK: - JSON Serialization

    /// Writes parameters to a JSON file.
    ///
    /// - Parameter url: Destination file URL
    /// - Throws: If serialization or writing fails
    public func writeJSON(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: url)
    }

    /// Reads parameters from a JSON file.
    ///
    /// - Parameter url: Source file URL
    /// - Returns: Decoded parameters
    /// - Throws: If reading or decoding fails
    public static func readJSON(from url: URL) throws -> WorkflowParameters {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        return try decoder.decode(WorkflowParameters.self, from: data)
    }
}

// MARK: - ExpressibleByDictionaryLiteral

extension WorkflowParameters: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, ParameterValue)...) {
        self.values = Dictionary(uniqueKeysWithValues: elements)
    }
}

// MARK: - Sequence Conformance

extension WorkflowParameters: Sequence {
    public func makeIterator() -> Dictionary<String, ParameterValue>.Iterator {
        values.makeIterator()
    }
}

// MARK: - ParameterDefinition

/// Definition of a workflow parameter for UI generation.
///
/// ParameterDefinition describes the schema of a parameter including
/// its type, constraints, and UI hints. This is typically parsed from
/// workflow schema files like `nextflow_schema.json`.
public struct ParameterDefinition: Sendable, Codable, Identifiable, Hashable {
    /// Unique identifier (parameter name)
    public var id: String { name }

    /// Parameter name
    public let name: String

    /// Human-readable title
    public var title: String

    /// Description of the parameter
    public var description: String

    /// Parameter type
    public var type: ParameterType

    /// Default value
    public var defaultValue: ParameterValue?

    /// Whether this parameter is required
    public var isRequired: Bool

    /// Whether this parameter is hidden from basic UI
    public var isHidden: Bool

    /// Allowed values (for enumerated types)
    public var allowedValues: [ParameterValue]?

    /// Minimum value (for numeric types)
    public var minimum: Double?

    /// Maximum value (for numeric types)
    public var maximum: Double?

    /// Pattern for validation (for string types)
    public var pattern: String?

    /// File type hints (for file types)
    public var fileFormats: [String]?

    /// Parameter group for UI organization
    public var group: String?

    /// Creates a new parameter definition.
    public init(
        name: String,
        title: String? = nil,
        description: String = "",
        type: ParameterType = .string,
        defaultValue: ParameterValue? = nil,
        isRequired: Bool = false,
        isHidden: Bool = false
    ) {
        self.name = name
        self.title = title ?? name
        self.description = description
        self.type = type
        self.defaultValue = defaultValue
        self.isRequired = isRequired
        self.isHidden = isHidden
        self.allowedValues = nil
        self.minimum = nil
        self.maximum = nil
        self.pattern = nil
        self.fileFormats = nil
        self.group = nil
    }
}

// MARK: - ParameterType

/// Type of a workflow parameter.
public enum ParameterType: String, Sendable, Codable {
    case string
    case integer
    case number
    case boolean
    case file
    case directory
    case array
    case object
}
