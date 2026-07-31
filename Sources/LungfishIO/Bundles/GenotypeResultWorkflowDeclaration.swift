import Foundation

public enum GenotypeResultWorkflowDeclarationValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case integer(Int64)
    /// Foundation's `Decoder` does not expose the original JSON number token.
    /// `Decimal` preserves semantic identity for integers beyond `Int64`
    /// within its 38-significant-digit precision, but not lexical formatting.
    case decimal(Decimal)
    case number(Double)
    case string(String)
    case array([GenotypeResultWorkflowDeclarationValue])
    case object([String: GenotypeResultWorkflowDeclarationValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Decimal.self) {
            self = .decimal(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([GenotypeResultWorkflowDeclarationValue].self) {
            self = .array(value)
        } else {
            self = .object(
                try container.decode([String: GenotypeResultWorkflowDeclarationValue].self)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .integer(let value):
            try container.encode(value)
        case .decimal(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }

    var typeDescription: String {
        switch self {
        case .null: return "null"
        case .bool: return "boolean"
        case .integer, .decimal, .number: return "number"
        case .string: return "string"
        case .array: return "array"
        case .object: return "object"
        }
    }
}

public struct GenotypeResultWorkflowDeclaration: Equatable, Sendable {
    public let originalValue: GenotypeResultWorkflowDeclarationValue?
    public let issue: String?

    fileprivate init(
        originalValue: GenotypeResultWorkflowDeclarationValue?,
        issue: String?
    ) {
        self.originalValue = originalValue
        self.issue = issue
    }
}

@propertyWrapper
public struct GenotypeResultWorkflowKindField: Codable, Equatable, Sendable {
    private var declaration: GenotypeResultWorkflowDeclaration

    public var wrappedValue: GenotypeResultWorkflowKind? {
        get {
            guard case .string(let rawValue)? = declaration.originalValue else { return nil }
            return GenotypeResultWorkflowKind(rawValue: rawValue)
        }
        set {
            declaration = Self.declaration(for: newValue)
        }
    }

    public var projectedValue: GenotypeResultWorkflowDeclaration { declaration }

    public init(wrappedValue: GenotypeResultWorkflowKind?) {
        declaration = Self.declaration(for: wrappedValue)
    }

    public init(from decoder: Decoder) throws {
        let originalValue = try GenotypeResultWorkflowDeclarationValue(from: decoder)
        declaration = Self.declaration(for: originalValue)
    }

    public func encode(to encoder: Encoder) throws {
        guard let originalValue = declaration.originalValue else {
            var container = encoder.singleValueContainer()
            try container.encodeNil()
            return
        }
        try originalValue.encode(to: encoder)
    }

    private static func declaration(
        for value: GenotypeResultWorkflowKind?
    ) -> GenotypeResultWorkflowDeclaration {
        guard let value else {
            return GenotypeResultWorkflowDeclaration(originalValue: nil, issue: nil)
        }
        return GenotypeResultWorkflowDeclaration(
            originalValue: .string(value.rawValue),
            issue: nil
        )
    }

    private static func declaration(
        for originalValue: GenotypeResultWorkflowDeclarationValue
    ) -> GenotypeResultWorkflowDeclaration {
        guard case .string(let rawValue) = originalValue else {
            return GenotypeResultWorkflowDeclaration(
                originalValue: originalValue,
                issue: "The workflow kind declaration must be a JSON string; found \(originalValue.typeDescription)."
            )
        }
        guard GenotypeResultWorkflowKind(rawValue: rawValue) != nil else {
            return GenotypeResultWorkflowDeclaration(
                originalValue: originalValue,
                issue: "The workflow kind declaration “\(rawValue)” is unsupported."
            )
        }
        return GenotypeResultWorkflowDeclaration(originalValue: originalValue, issue: nil)
    }
}

@propertyWrapper
public struct GenotypeResultWorkflowModeField: Codable, Equatable, Sendable {
    private var declaration: GenotypeResultWorkflowDeclaration

    public var wrappedValue: GenotypeResultWorkflowMode? {
        get {
            guard case .string(let rawValue)? = declaration.originalValue else { return nil }
            return GenotypeResultWorkflowMode(rawValue: rawValue)
        }
        set {
            declaration = Self.declaration(for: newValue)
        }
    }

    public var projectedValue: GenotypeResultWorkflowDeclaration { declaration }

    public init(wrappedValue: GenotypeResultWorkflowMode?) {
        declaration = Self.declaration(for: wrappedValue)
    }

    public init(from decoder: Decoder) throws {
        let originalValue = try GenotypeResultWorkflowDeclarationValue(from: decoder)
        declaration = Self.declaration(for: originalValue)
    }

    public func encode(to encoder: Encoder) throws {
        guard let originalValue = declaration.originalValue else {
            var container = encoder.singleValueContainer()
            try container.encodeNil()
            return
        }
        try originalValue.encode(to: encoder)
    }

    private static func declaration(
        for value: GenotypeResultWorkflowMode?
    ) -> GenotypeResultWorkflowDeclaration {
        guard let value else {
            return GenotypeResultWorkflowDeclaration(originalValue: nil, issue: nil)
        }
        return GenotypeResultWorkflowDeclaration(
            originalValue: .string(value.rawValue),
            issue: nil
        )
    }

    private static func declaration(
        for originalValue: GenotypeResultWorkflowDeclarationValue
    ) -> GenotypeResultWorkflowDeclaration {
        guard case .string(let rawValue) = originalValue else {
            return GenotypeResultWorkflowDeclaration(
                originalValue: originalValue,
                issue: "The workflow mode declaration must be a JSON string; found \(originalValue.typeDescription)."
            )
        }
        guard GenotypeResultWorkflowMode(rawValue: rawValue) != nil else {
            return GenotypeResultWorkflowDeclaration(
                originalValue: originalValue,
                issue: "The workflow mode declaration “\(rawValue)” is unsupported."
            )
        }
        return GenotypeResultWorkflowDeclaration(originalValue: originalValue, issue: nil)
    }
}

extension KeyedDecodingContainer {
    func decode(
        _ type: GenotypeResultWorkflowKindField.Type,
        forKey key: Key
    ) throws -> GenotypeResultWorkflowKindField {
        guard contains(key) else {
            return GenotypeResultWorkflowKindField(wrappedValue: nil)
        }
        return try GenotypeResultWorkflowKindField(from: superDecoder(forKey: key))
    }

    func decode(
        _ type: GenotypeResultWorkflowModeField.Type,
        forKey key: Key
    ) throws -> GenotypeResultWorkflowModeField {
        guard contains(key) else {
            return GenotypeResultWorkflowModeField(wrappedValue: nil)
        }
        return try GenotypeResultWorkflowModeField(from: superDecoder(forKey: key))
    }
}

extension KeyedEncodingContainer {
    mutating func encode(
        _ value: GenotypeResultWorkflowKindField,
        forKey key: Key
    ) throws {
        guard let originalValue = value.projectedValue.originalValue else { return }
        try encode(originalValue, forKey: key)
    }

    mutating func encode(
        _ value: GenotypeResultWorkflowModeField,
        forKey key: Key
    ) throws {
        guard let originalValue = value.projectedValue.originalValue else { return }
        try encode(originalValue, forKey: key)
    }
}
