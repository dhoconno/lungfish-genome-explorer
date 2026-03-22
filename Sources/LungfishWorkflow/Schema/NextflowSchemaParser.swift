// NextflowSchemaParser.swift - Parser for nf-core nextflow_schema.json files
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner: Workflow Integration Lead (Role 14)

import Foundation
import os.log
import LungfishCore

// MARK: - NextflowSchemaParser

/// Parser for nf-core `nextflow_schema.json` files.
///
/// This parser handles the JSON Schema format used by nf-core pipelines
/// to define workflow parameters and their validation rules.
///
/// ## JSON Schema Format
///
/// nf-core schemas follow JSON Schema draft-07 with additional properties:
/// - `definitions`: Parameter groups with their properties
/// - `allOf`: References to definition groups
/// - `fa_icon`: Font Awesome icon classes (converted to SF Symbols)
///
/// ## Example
///
/// ```swift
/// let parser = NextflowSchemaParser()
/// let schema = try await parser.parse(from: schemaURL)
///
/// for group in schema.groups {
///     print("Group: \(group.title)")
///     for param in group.parameters {
///         print("  \(param.name): \(param.type)")
///     }
/// }
/// ```
public struct NextflowSchemaParser: Sendable {

    private static let logger = Logger(
        subsystem: LogSubsystem.workflow,
        category: "NextflowSchemaParser"
    )

    // MARK: - Initialization

    /// Creates a new Nextflow schema parser.
    public init() {}

    // MARK: - Public Methods

    /// Parses a Nextflow schema file.
    ///
    /// - Parameter url: URL to the `nextflow_schema.json` file
    /// - Returns: Parsed workflow schema
    /// - Throws: `SchemaParseError` if parsing fails
    public func parse(from url: URL) async throws -> UnifiedWorkflowSchema {
        Self.logger.info("Parsing Nextflow schema from: \(url.path)")

        // Check file exists
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw SchemaParseError.fileNotFound(url)
        }

        // Read file data
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw SchemaParseError.invalidJSON("Failed to read file: \(error.localizedDescription)")
        }

        // Parse JSON
        let rawSchema: RawNextflowSchema
        do {
            let decoder = JSONDecoder()
            rawSchema = try decoder.decode(RawNextflowSchema.self, from: data)
        } catch {
            Self.logger.error("JSON parsing failed: \(error.localizedDescription)")
            throw SchemaParseError.invalidJSON(error.localizedDescription)
        }

        // Check schema version
        if let schemaUrl = rawSchema.schema {
            if !schemaUrl.contains("draft-07") && !schemaUrl.contains("draft-04") {
                Self.logger.warning("Unexpected schema version: \(schemaUrl)")
            }
        }

        // Parse parameter groups from definitions
        var groups: [UnifiedParameterGroup] = []
        let requiredParams = Set(rawSchema.required ?? [])

        // Process definitions
        if let definitions = rawSchema.definitions {
            for (groupId, definition) in definitions.sorted(by: { $0.key < $1.key }) {
                if let group = parseParameterGroup(
                    id: groupId,
                    definition: definition,
                    requiredParams: requiredParams
                ) {
                    groups.append(group)
                }
            }
        }

        // Sort groups by order in allOf if available
        if let allOf = rawSchema.allOf {
            let orderedRefs = allOf.compactMap { ref -> String? in
                guard let refPath = ref.ref else { return nil }
                // Extract group ID from "#/definitions/groupId"
                let parts = refPath.split(separator: "/")
                return parts.last.map(String.init)
            }

            groups.sort { group1, group2 in
                let index1 = orderedRefs.firstIndex(of: group1.id) ?? Int.max
                let index2 = orderedRefs.firstIndex(of: group2.id) ?? Int.max
                return index1 < index2
            }
        }

        Self.logger.info("Parsed \(groups.count) parameter groups with \(groups.flatMap(\.parameters).count) parameters")

        return UnifiedWorkflowSchema(
            version: "1.0",
            title: rawSchema.title ?? "Workflow",
            description: rawSchema.description,
            groups: groups
        )
    }

    // MARK: - Private Methods

    /// Parses a parameter group from a JSON Schema definition.
    private func parseParameterGroup(
        id: String,
        definition: RawDefinition,
        requiredParams: Set<String>
    ) -> UnifiedParameterGroup? {
        guard let properties = definition.properties, !properties.isEmpty else {
            Self.logger.debug("Skipping empty definition: \(id)")
            return nil
        }

        let groupRequired = Set(definition.required ?? [])
        let allRequired = requiredParams.union(groupRequired)

        var parameters: [UnifiedWorkflowParameter] = []

        for (paramName, property) in properties.sorted(by: { $0.key < $1.key }) {
            let param = parseParameter(
                name: paramName,
                property: property,
                isRequired: allRequired.contains(paramName)
            )
            parameters.append(param)
        }

        // Determine if this is an advanced/hidden group
        let isHidden = definition.faIcon?.contains("cogs") == true ||
                       id.contains("institutional") ||
                       id.contains("generic")

        return UnifiedParameterGroup(
            id: id,
            title: definition.title ?? formatTitle(id),
            description: definition.description,
            iconName: mapFAIconToSFSymbol(definition.faIcon),
            isCollapsedByDefault: isHidden,
            isHidden: definition.hidden == true,
            parameters: parameters
        )
    }

    /// Parses a single parameter from a JSON Schema property.
    private func parseParameter(
        name: String,
        property: RawProperty,
        isRequired: Bool
    ) -> UnifiedWorkflowParameter {
        let paramType = mapJSONSchemaType(
            type: property.type,
            format: property.format,
            enumValues: property.enumValues
        )

        var validation: UnifiedParameterValidation?
        if property.minimum != nil || property.maximum != nil ||
           property.minLength != nil || property.maxLength != nil ||
           property.pattern != nil {
            validation = UnifiedParameterValidation(
                pattern: property.pattern,
                minimum: property.minimum,
                maximum: property.maximum,
                minLength: property.minLength,
                maxLength: property.maxLength,
                mustExist: property.exists == true,
                mimeTypes: property.mimeType.map { [$0] },
                fileExtensions: parseFileExtensions(from: property.pattern)
            )
        }

        let defaultValue = property.defaultValue.flatMap { parseDefaultValue($0, type: paramType) }

        return UnifiedWorkflowParameter(
            id: name,
            name: name,
            title: formatTitle(name),
            description: property.description,
            type: paramType,
            defaultValue: defaultValue,
            isRequired: isRequired,
            isHidden: property.hidden == true,
            validation: validation,
            iconName: mapFAIconToSFSymbol(property.faIcon),
            helpURL: property.helpText.flatMap { URL(string: $0) }
        )
    }

    /// Maps JSON Schema type to UnifiedParameterType.
    private func mapJSONSchemaType(
        type: String?,
        format: String?,
        enumValues: [String]?
    ) -> UnifiedParameterType {
        // Check for enumeration first
        if let values = enumValues, !values.isEmpty {
            return .enumeration(values)
        }

        // Check format for file/directory
        if let format = format {
            switch format {
            case "file-path":
                return .file
            case "directory-path", "path":
                return .directory
            default:
                break
            }
        }

        // Map JSON Schema type
        switch type?.lowercased() {
        case "string":
            return .string
        case "integer":
            return .integer
        case "number":
            return .number
        case "boolean":
            return .boolean
        case "array":
            return .array(.string)  // Default to string array
        default:
            return .string
        }
    }

    /// Parses a default value from the raw JSON.
    private func parseDefaultValue(_ value: RawValue, type: UnifiedParameterType) -> UnifiedParameterValue? {
        switch value {
        case .string(let s):
            return .string(s)
        case .int(let i):
            return .integer(i)
        case .double(let d):
            return .number(d)
        case .bool(let b):
            return .boolean(b)
        case .null:
            return .null
        case .array(let arr):
            return .array(arr.compactMap { parseDefaultValue($0, type: .string) })
        }
    }

    /// Maps Font Awesome icon classes to SF Symbol names.
    private func mapFAIconToSFSymbol(_ faIcon: String?) -> String? {
        guard let icon = faIcon else { return nil }

        // Common nf-core icon mappings
        let mappings: [String: String] = [
            "fas fa-file-code": "doc.text",
            "fas fa-file": "doc",
            "fas fa-folder": "folder",
            "fas fa-folder-open": "folder",
            "fas fa-dna": "allergens",
            "fas fa-database": "cylinder.split.1x2",
            "fas fa-cogs": "gearshape.2",
            "fas fa-cog": "gearshape",
            "fas fa-terminal": "terminal",
            "fas fa-check": "checkmark",
            "fas fa-times": "xmark",
            "fas fa-users-cog": "person.2.badge.gearshape",
            "fas fa-align-left": "text.alignleft",
            "fas fa-clipboard-list": "list.clipboard",
            "fas fa-book": "book",
            "fas fa-question-circle": "questionmark.circle",
            "fas fa-info-circle": "info.circle",
            "fas fa-exclamation-triangle": "exclamationmark.triangle",
            "fas fa-download": "arrow.down.circle",
            "fas fa-upload": "arrow.up.circle",
            "fas fa-save": "square.and.arrow.down",
            "fas fa-server": "server.rack",
            "fas fa-cloud": "cloud",
            "fas fa-microchip": "cpu",
            "fas fa-memory": "memorychip",
            "fab fa-docker": "shippingbox",
            "fas fa-sitemap": "chart.bar.doc.horizontal"
        ]

        return mappings[icon] ?? "circle"
    }

    /// Formats a snake_case or camelCase identifier as a title.
    private func formatTitle(_ identifier: String) -> String {
        // Convert snake_case to spaces
        var title = identifier.replacingOccurrences(of: "_", with: " ")

        // Convert camelCase to spaces
        title = title.replacingOccurrences(
            of: "([a-z])([A-Z])",
            with: "$1 $2",
            options: .regularExpression
        )

        // Capitalize first letter of each word
        return title.capitalized
    }

    /// Parses file extensions from a regex pattern.
    private func parseFileExtensions(from pattern: String?) -> [String]? {
        guard let pattern = pattern else { return nil }

        // Match patterns like .*\.(fa|fasta|fna)$ or similar
        if let match = pattern.range(of: #"\\\.\(([^)]+)\)"#, options: .regularExpression) {
            let extensions = String(pattern[match])
                .replacingOccurrences(of: "\\.(", with: "")
                .replacingOccurrences(of: ")", with: "")
                .split(separator: "|")
                .map(String.init)
            return extensions.isEmpty ? nil : extensions
        }

        return nil
    }
}

// MARK: - Raw JSON Schema Types

/// Raw Nextflow schema structure for decoding.
private struct RawNextflowSchema: Decodable {
    let schema: String?
    let title: String?
    let description: String?
    let type: String?
    let required: [String]?
    let definitions: [String: RawDefinition]?
    let allOf: [RawRef]?

    enum CodingKeys: String, CodingKey {
        case schema = "$schema"
        case title
        case description
        case type
        case required
        case definitions
        case allOf
    }
}

/// Raw definition (parameter group) structure.
private struct RawDefinition: Decodable {
    let title: String?
    let description: String?
    let required: [String]?
    let properties: [String: RawProperty]?
    let faIcon: String?
    let hidden: Bool?

    enum CodingKeys: String, CodingKey {
        case title
        case description
        case required
        case properties
        case faIcon = "fa_icon"
        case hidden
    }
}

/// Raw property (parameter) structure.
private struct RawProperty: Decodable {
    let type: String?
    let format: String?
    let description: String?
    let defaultValue: RawValue?
    let enumValues: [String]?
    let minimum: Double?
    let maximum: Double?
    let minLength: Int?
    let maxLength: Int?
    let pattern: String?
    let faIcon: String?
    let hidden: Bool?
    let helpText: String?
    let mimeType: String?
    let exists: Bool?

    enum CodingKeys: String, CodingKey {
        case type
        case format
        case description
        case defaultValue = "default"
        case enumValues = "enum"
        case minimum
        case maximum
        case minLength
        case maxLength
        case pattern
        case faIcon = "fa_icon"
        case hidden
        case helpText = "help_text"
        case mimeType = "mimetype"
        case exists
    }
}

/// Raw reference structure for allOf.
private struct RawRef: Decodable {
    let ref: String?

    enum CodingKeys: String, CodingKey {
        case ref = "$ref"
    }
}

/// Raw value that can be any JSON type.
private enum RawValue: Decodable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([RawValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let int = try? container.decode(Int.self) {
            self = .int(int)
        } else if let double = try? container.decode(Double.self) {
            self = .double(double)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([RawValue].self) {
            self = .array(array)
        } else {
            throw DecodingError.typeMismatch(
                RawValue.self,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Unsupported value type"
                )
            )
        }
    }
}
