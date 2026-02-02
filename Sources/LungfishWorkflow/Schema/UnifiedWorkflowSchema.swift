// UnifiedWorkflowSchema.swift - Unified workflow parameter schema model
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner: Workflow Integration Lead (Role 14)

import Foundation

// MARK: - UnifiedWorkflowSchema

/// A unified schema model for workflow parameters.
///
/// This struct represents the parameter schema for both Nextflow and Snakemake
/// workflows, providing a common interface for generating parameter UIs.
///
/// ## Overview
///
/// UnifiedWorkflowSchema is parsed from:
/// - Nextflow: `nextflow_schema.json` (nf-core JSON Schema format)
/// - Snakemake: `config.yaml` or `config/config.yaml`
///
/// ## Example
///
/// ```swift
/// // Parse a Nextflow schema
/// let parser = NextflowSchemaParser()
/// let schema = try await parser.parse(url: schemaURL)
///
/// // Access parameter groups
/// for group in schema.groups {
///     print("Group: \(group.title)")
///     for param in group.parameters {
///         print("  - \(param.name): \(param.type)")
///     }
/// }
/// ```
public struct UnifiedWorkflowSchema: Sendable, Codable, Equatable {
    /// The schema format version
    public let version: String

    /// Workflow title
    public let title: String

    /// Workflow description
    public let description: String?

    /// Parameter groups organized by category
    public let groups: [UnifiedParameterGroup]

    /// All parameters as a flat list
    public var allParameters: [UnifiedWorkflowParameter] {
        groups.flatMap(\.parameters)
    }

    /// Required parameters
    public var requiredParameters: [UnifiedWorkflowParameter] {
        allParameters.filter(\.isRequired)
    }

    /// Creates a new workflow schema.
    ///
    /// - Parameters:
    ///   - version: The schema version string
    ///   - title: The workflow title
    ///   - description: Optional description
    ///   - groups: Parameter groups
    public init(
        version: String = "1.0",
        title: String,
        description: String? = nil,
        groups: [UnifiedParameterGroup]
    ) {
        self.version = version
        self.title = title
        self.description = description
        self.groups = groups
    }

    /// Finds a parameter by its name.
    ///
    /// - Parameter name: The parameter name to search for
    /// - Returns: The parameter if found, nil otherwise
    public func parameter(named name: String) -> UnifiedWorkflowParameter? {
        allParameters.first { $0.name == name }
    }

    /// Validates a set of parameter values against this schema.
    ///
    /// - Parameter values: Dictionary of parameter name to value
    /// - Returns: Array of validation errors (empty if valid)
    public func validate(_ values: [String: Any]) -> [SchemaValidationError] {
        var errors: [SchemaValidationError] = []

        // Check required parameters
        for param in requiredParameters {
            if values[param.name] == nil {
                errors.append(.missingRequired(parameterName: param.name))
            }
        }

        // Validate each provided value
        for (name, value) in values {
            guard let param = parameter(named: name) else {
                errors.append(.unknownParameter(name: name))
                continue
            }

            if let validationErrors = param.validate(value) {
                errors.append(contentsOf: validationErrors)
            }
        }

        return errors
    }
}

// MARK: - UnifiedParameterGroup

/// A group of related workflow parameters.
///
/// Parameter groups organize parameters by category (e.g., "Input/Output",
/// "Reference Genome", "Analysis Options") for better UI presentation.
public struct UnifiedParameterGroup: Sendable, Codable, Equatable, Identifiable {
    /// Unique identifier for this group
    public let id: String

    /// Display title for the group
    public let title: String

    /// Optional description
    public let description: String?

    /// SF Symbol icon name for the group
    public let iconName: String?

    /// Whether this group is collapsed by default
    public let isCollapsedByDefault: Bool

    /// Whether this group contains hidden/advanced parameters
    public let isHidden: Bool

    /// Parameters in this group
    public let parameters: [UnifiedWorkflowParameter]

    /// Creates a new parameter group.
    ///
    /// - Parameters:
    ///   - id: Unique identifier
    ///   - title: Display title
    ///   - description: Optional description
    ///   - iconName: SF Symbol name for the icon
    ///   - isCollapsedByDefault: Whether collapsed by default
    ///   - isHidden: Whether this is a hidden/advanced group
    ///   - parameters: Parameters in this group
    public init(
        id: String,
        title: String,
        description: String? = nil,
        iconName: String? = nil,
        isCollapsedByDefault: Bool = false,
        isHidden: Bool = false,
        parameters: [UnifiedWorkflowParameter]
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.iconName = iconName
        self.isCollapsedByDefault = isCollapsedByDefault
        self.isHidden = isHidden
        self.parameters = parameters
    }
}

// MARK: - UnifiedWorkflowParameter

/// A single workflow parameter with type and validation information.
///
/// Parameters represent inputs to workflows like file paths, numeric values,
/// boolean flags, and enumerated choices.
public struct UnifiedWorkflowParameter: Sendable, Codable, Equatable, Identifiable {
    /// Unique identifier (usually same as name)
    public let id: String

    /// Parameter name (used in workflow)
    public let name: String

    /// Display title
    public let title: String

    /// Description/help text
    public let description: String?

    /// Parameter type
    public let type: UnifiedParameterType

    /// Default value (as JSON-compatible Any wrapped in Codable)
    public let defaultValue: UnifiedParameterValue?

    /// Whether this parameter is required
    public let isRequired: Bool

    /// Whether this parameter is hidden from the UI
    public let isHidden: Bool

    /// Validation rules
    public let validation: UnifiedParameterValidation?

    /// SF Symbol icon name
    public let iconName: String?

    /// Help URL for more information
    public let helpURL: URL?

    /// Creates a new workflow parameter.
    ///
    /// - Parameters:
    ///   - id: Unique identifier
    ///   - name: Parameter name
    ///   - title: Display title
    ///   - description: Help text
    ///   - type: Parameter type
    ///   - defaultValue: Default value
    ///   - isRequired: Whether required
    ///   - isHidden: Whether hidden
    ///   - validation: Validation rules
    ///   - iconName: SF Symbol name
    ///   - helpURL: Help URL
    public init(
        id: String? = nil,
        name: String,
        title: String? = nil,
        description: String? = nil,
        type: UnifiedParameterType,
        defaultValue: UnifiedParameterValue? = nil,
        isRequired: Bool = false,
        isHidden: Bool = false,
        validation: UnifiedParameterValidation? = nil,
        iconName: String? = nil,
        helpURL: URL? = nil
    ) {
        self.id = id ?? name
        self.name = name
        self.title = title ?? name.replacingOccurrences(of: "_", with: " ").capitalized
        self.description = description
        self.type = type
        self.defaultValue = defaultValue
        self.isRequired = isRequired
        self.isHidden = isHidden
        self.validation = validation
        self.iconName = iconName
        self.helpURL = helpURL
    }

    /// Validates a value against this parameter's type and validation rules.
    ///
    /// - Parameter value: The value to validate
    /// - Returns: Array of validation errors, or nil if valid
    public func validate(_ value: Any) -> [SchemaValidationError]? {
        var errors: [SchemaValidationError] = []

        // Type validation
        switch type {
        case .string:
            guard value is String else {
                errors.append(.typeMismatch(parameterName: name, expected: "string"))
                return errors
            }
        case .integer:
            guard value is Int || value is Int64 else {
                errors.append(.typeMismatch(parameterName: name, expected: "integer"))
                return errors
            }
        case .number:
            guard value is Double || value is Float || value is Int else {
                errors.append(.typeMismatch(parameterName: name, expected: "number"))
                return errors
            }
        case .boolean:
            guard value is Bool else {
                errors.append(.typeMismatch(parameterName: name, expected: "boolean"))
                return errors
            }
        case .file, .directory:
            guard let path = value as? String else {
                errors.append(.typeMismatch(parameterName: name, expected: "path"))
                return errors
            }
            if let validation = validation {
                if validation.mustExist {
                    let url = URL(fileURLWithPath: path)
                    if !FileManager.default.fileExists(atPath: url.path) {
                        errors.append(.fileNotFound(parameterName: name, path: path))
                    }
                }
            }
        case .enumeration(let options):
            guard let stringValue = value as? String else {
                errors.append(.typeMismatch(parameterName: name, expected: "string"))
                return errors
            }
            if !options.contains(stringValue) {
                errors.append(.invalidEnumValue(parameterName: name, value: stringValue, options: options))
            }
        case .array(let elementType):
            guard let arrayValue = value as? [Any] else {
                errors.append(.typeMismatch(parameterName: name, expected: "array"))
                return errors
            }
            // Validate each element
            for (index, element) in arrayValue.enumerated() {
                let elementParam = UnifiedWorkflowParameter(
                    name: "\(name)[\(index)]",
                    type: elementType
                )
                if let elementErrors = elementParam.validate(element) {
                    errors.append(contentsOf: elementErrors)
                }
            }
        }

        // Additional validation rules
        if let validation = validation, errors.isEmpty {
            if let pattern = validation.pattern, let stringValue = value as? String {
                let regex = try? NSRegularExpression(pattern: pattern)
                let range = NSRange(stringValue.startIndex..., in: stringValue)
                if regex?.firstMatch(in: stringValue, range: range) == nil {
                    errors.append(.patternMismatch(parameterName: name, pattern: pattern))
                }
            }

            if let minimum = validation.minimum, let numericValue = value as? Double {
                if numericValue < minimum {
                    errors.append(.valueTooSmall(parameterName: name, minimum: minimum))
                }
            }

            if let maximum = validation.maximum, let numericValue = value as? Double {
                if numericValue > maximum {
                    errors.append(.valueTooLarge(parameterName: name, maximum: maximum))
                }
            }
        }

        return errors.isEmpty ? nil : errors
    }
}

// MARK: - UnifiedParameterType

/// The data type of a workflow parameter.
public enum UnifiedParameterType: Sendable, Codable, Equatable {
    /// String value
    case string

    /// Integer value
    case integer

    /// Floating-point number
    case number

    /// Boolean flag
    case boolean

    /// File path
    case file

    /// Directory path
    case directory

    /// Enumerated choice from a list of options
    case enumeration([String])

    /// Array of values (with element type)
    indirect case array(UnifiedParameterType)

    /// Human-readable display name for the parameter type.
    public var displayName: String {
        switch self {
        case .string: return "Text"
        case .integer: return "Integer"
        case .number: return "Number"
        case .boolean: return "Boolean"
        case .file: return "File"
        case .directory: return "Directory"
        case .enumeration: return "Selection"
        case .array: return "Array"
        }
    }

    /// SF Symbol icon name for this parameter type.
    public var iconName: String {
        defaultIconName
    }

    /// Returns the JSON Schema type name for this parameter type.
    public var jsonSchemaType: String {
        switch self {
        case .string, .file, .directory: return "string"
        case .integer: return "integer"
        case .number: return "number"
        case .boolean: return "boolean"
        case .enumeration: return "string"
        case .array: return "array"
        }
    }

    /// Returns an SF Symbol name appropriate for this type.
    public var defaultIconName: String {
        switch self {
        case .string: return "textformat"
        case .integer: return "number"
        case .number: return "function"
        case .boolean: return "switch.2"
        case .file: return "doc"
        case .directory: return "folder"
        case .enumeration: return "list.bullet"
        case .array: return "square.stack.3d.up"
        }
    }
}

// MARK: - UnifiedParameterValue

/// A type-erased parameter value that supports Codable.
public enum UnifiedParameterValue: Sendable, Codable, Equatable {
    case string(String)
    case integer(Int)
    case number(Double)
    case boolean(Bool)
    case array([UnifiedParameterValue])
    case null

    // MARK: - Typed Accessors

    /// Returns the string value if this is a `.string` case.
    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    /// Returns the integer value if this is an `.integer` case.
    public var integerValue: Int? {
        if case .integer(let value) = self { return value }
        return nil
    }

    /// Returns the number value if this is a `.number` case.
    public var numberValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    /// Returns the boolean value if this is a `.boolean` case.
    public var booleanValue: Bool? {
        if case .boolean(let value) = self { return value }
        return nil
    }

    /// Returns the array value if this is an `.array` case.
    public var arrayValue: [UnifiedParameterValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    /// Returns true if this is the `.null` case.
    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let boolValue = try? container.decode(Bool.self) {
            self = .boolean(boolValue)
        } else if let intValue = try? container.decode(Int.self) {
            self = .integer(intValue)
        } else if let doubleValue = try? container.decode(Double.self) {
            self = .number(doubleValue)
        } else if let stringValue = try? container.decode(String.self) {
            self = .string(stringValue)
        } else if let arrayValue = try? container.decode([UnifiedParameterValue].self) {
            self = .array(arrayValue)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported parameter value type"
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
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    /// Converts the value to Any for use with validation.
    public var anyValue: Any {
        switch self {
        case .string(let value): return value
        case .integer(let value): return value
        case .number(let value): return value
        case .boolean(let value): return value
        case .array(let value): return value.map(\.anyValue)
        case .null: return NSNull()
        }
    }

    /// Creates a UnifiedParameterValue from an Any value.
    public static func from(_ value: Any) -> UnifiedParameterValue? {
        switch value {
        case let string as String: return .string(string)
        case let int as Int: return .integer(int)
        case let double as Double: return .number(double)
        case let bool as Bool: return .boolean(bool)
        case let array as [Any]:
            let values = array.compactMap { UnifiedParameterValue.from($0) }
            return values.count == array.count ? .array(values) : nil
        case is NSNull: return .null
        default: return nil
        }
    }
}

// MARK: - UnifiedParameterValidation

/// Validation rules for a workflow parameter.
public struct UnifiedParameterValidation: Sendable, Codable, Equatable {
    /// Regex pattern for string validation
    public let pattern: String?

    /// Minimum value for numeric parameters
    public let minimum: Double?

    /// Maximum value for numeric parameters
    public let maximum: Double?

    /// Minimum length for strings/arrays
    public let minLength: Int?

    /// Maximum length for strings/arrays
    public let maxLength: Int?

    /// For file/directory parameters, whether the path must exist
    public let mustExist: Bool

    /// MIME types for file parameters
    public let mimeTypes: [String]?

    /// File extensions for file parameters
    public let fileExtensions: [String]?

    /// Creates validation rules.
    ///
    /// - Parameters:
    ///   - pattern: Regex pattern
    ///   - minimum: Minimum numeric value
    ///   - maximum: Maximum numeric value
    ///   - minLength: Minimum length
    ///   - maxLength: Maximum length
    ///   - mustExist: Whether file/directory must exist
    ///   - mimeTypes: Allowed MIME types
    ///   - fileExtensions: Allowed file extensions
    public init(
        pattern: String? = nil,
        minimum: Double? = nil,
        maximum: Double? = nil,
        minLength: Int? = nil,
        maxLength: Int? = nil,
        mustExist: Bool = false,
        mimeTypes: [String]? = nil,
        fileExtensions: [String]? = nil
    ) {
        self.pattern = pattern
        self.minimum = minimum
        self.maximum = maximum
        self.minLength = minLength
        self.maxLength = maxLength
        self.mustExist = mustExist
        self.mimeTypes = mimeTypes
        self.fileExtensions = fileExtensions
    }
}

// MARK: - SchemaValidationError

/// Errors that can occur during parameter validation.
public enum SchemaValidationError: Error, LocalizedError, Sendable, Equatable {
    case missingRequired(parameterName: String)
    case unknownParameter(name: String)
    case typeMismatch(parameterName: String, expected: String)
    case fileNotFound(parameterName: String, path: String)
    case invalidEnumValue(parameterName: String, value: String, options: [String])
    case patternMismatch(parameterName: String, pattern: String)
    case valueTooSmall(parameterName: String, minimum: Double)
    case valueTooLarge(parameterName: String, maximum: Double)

    public var errorDescription: String? {
        switch self {
        case .missingRequired(let name):
            return "Required parameter '\(name)' is missing"
        case .unknownParameter(let name):
            return "Unknown parameter '\(name)'"
        case .typeMismatch(let name, let expected):
            return "Parameter '\(name)' should be of type \(expected)"
        case .fileNotFound(let name, let path):
            return "File for parameter '\(name)' not found: \(path)"
        case .invalidEnumValue(let name, let value, let options):
            return "Invalid value '\(value)' for parameter '\(name)'. Valid options: \(options.joined(separator: ", "))"
        case .patternMismatch(let name, let pattern):
            return "Value for parameter '\(name)' does not match pattern: \(pattern)"
        case .valueTooSmall(let name, let minimum):
            return "Value for parameter '\(name)' is less than minimum \(minimum)"
        case .valueTooLarge(let name, let maximum):
            return "Value for parameter '\(name)' exceeds maximum \(maximum)"
        }
    }
}

// MARK: - SchemaParseError

/// Errors that can occur during schema parsing.
public enum SchemaParseError: Error, LocalizedError, Sendable {
    case fileNotFound(URL)
    case invalidJSON(String)
    case invalidYAML(String)
    case missingRequiredField(String)
    case unsupportedSchemaVersion(String)
    case malformedSchema(String)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let url):
            return "Schema file not found: \(url.path)"
        case .invalidJSON(let message):
            return "Invalid JSON in schema: \(message)"
        case .invalidYAML(let message):
            return "Invalid YAML in schema: \(message)"
        case .missingRequiredField(let field):
            return "Missing required field in schema: \(field)"
        case .unsupportedSchemaVersion(let version):
            return "Unsupported schema version: \(version)"
        case .malformedSchema(let message):
            return "Malformed schema: \(message)"
        }
    }
}
