// SnakemakeConfigParser.swift - Parser for Snakemake config.yaml files
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner: Workflow Integration Lead (Role 14)

import Foundation
import os.log
import LungfishCore

// MARK: - SnakemakeConfigParser

/// Parser for Snakemake `config.yaml` configuration files.
///
/// This parser reads YAML configuration files used by Snakemake workflows
/// and converts them to a unified `UnifiedWorkflowSchema` for UI generation.
///
/// ## YAML Format
///
/// Snakemake configs are typically simple YAML key-value pairs:
/// ```yaml
/// input_dir: "data/raw"
/// output_dir: "results"
/// threads: 4
/// run_qc: true
/// genome:
///   reference: "GRCh38"
///   annotation: "gencode.v38"
/// ```
///
/// ## Example
///
/// ```swift
/// let parser = SnakemakeConfigParser()
/// let schema = try await parser.parse(from: configURL)
///
/// for param in schema.allParameters {
///     print("\(param.name): \(param.type)")
/// }
/// ```
public struct SnakemakeConfigParser: Sendable {

    private static let logger = Logger(
        subsystem: LogSubsystem.workflow,
        category: "SnakemakeConfigParser"
    )

    // MARK: - Initialization

    /// Creates a new Snakemake config parser.
    public init() {}

    // MARK: - Public Methods

    /// Parses a Snakemake config file.
    ///
    /// - Parameter url: URL to the `config.yaml` file
    /// - Returns: Parsed workflow schema
    /// - Throws: `SchemaParseError` if parsing fails
    public func parse(from url: URL) async throws -> UnifiedWorkflowSchema {
        Self.logger.info("Parsing Snakemake config from: \(url.path)")

        // Check file exists
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw SchemaParseError.fileNotFound(url)
        }

        // Read file content
        let content: String
        do {
            content = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw SchemaParseError.invalidYAML("Failed to read file: \(error.localizedDescription)")
        }

        // Parse YAML content
        let values = try parseYAML(content)

        // Convert to parameters
        var parameters: [UnifiedWorkflowParameter] = []

        for (key, value) in values.sorted(by: { $0.key < $1.key }) {
            let param = createParameter(name: key, value: value, path: [])
            parameters.append(contentsOf: param)
        }

        Self.logger.info("Parsed \(parameters.count) parameters from config")

        // Create a single default group
        let group = UnifiedParameterGroup(
            id: "config",
            title: "Configuration",
            description: "Snakemake workflow configuration",
            iconName: "gearshape",
            isCollapsedByDefault: false,
            isHidden: false,
            parameters: parameters
        )

        return UnifiedWorkflowSchema(
            version: "1.0",
            title: url.deletingPathExtension().lastPathComponent.capitalized,
            description: "Configuration parsed from \(url.lastPathComponent)",
            groups: [group]
        )
    }

    /// Parses YAML content with nested section support.
    ///
    /// - Parameters:
    ///   - url: URL to the config file
    ///   - sectionPrefix: Prefix for parameter names (for nested configs)
    /// - Returns: Parsed workflow schema
    public func parse(from url: URL, sectionPrefix: String) async throws -> UnifiedWorkflowSchema {
        let baseSchema = try await parse(from: url)

        // Prefix all parameter names
        let prefixedGroups = baseSchema.groups.map { group in
            UnifiedParameterGroup(
                id: group.id,
                title: group.title,
                description: group.description,
                iconName: group.iconName,
                isCollapsedByDefault: group.isCollapsedByDefault,
                isHidden: group.isHidden,
                parameters: group.parameters.map { param in
                    UnifiedWorkflowParameter(
                        id: "\(sectionPrefix).\(param.id)",
                        name: "\(sectionPrefix).\(param.name)",
                        title: param.title,
                        description: param.description,
                        type: param.type,
                        defaultValue: param.defaultValue,
                        isRequired: param.isRequired,
                        isHidden: param.isHidden,
                        validation: param.validation,
                        iconName: param.iconName,
                        helpURL: param.helpURL
                    )
                }
            )
        }

        return UnifiedWorkflowSchema(
            version: baseSchema.version,
            title: baseSchema.title,
            description: baseSchema.description,
            groups: prefixedGroups
        )
    }

    // MARK: - Private Methods

    /// Parses YAML content to a dictionary.
    ///
    /// This is a simplified YAML parser that handles the common cases
    /// found in Snakemake configs. For full YAML support, consider
    /// using a dedicated YAML library.
    private func parseYAML(_ content: String) throws -> [String: YAMLValue] {
        var result: [String: YAMLValue] = [:]
        var currentIndent = 0
        var stack: [(indent: Int, key: String, dict: [String: YAMLValue])] = []

        let lines = content.components(separatedBy: .newlines)

        for lineNum in lines.indices {
            let line = lines[lineNum]

            // Skip empty lines and comments
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }

            // Calculate indentation
            let indent = line.prefix(while: { $0 == " " }).count

            // Parse key-value pair
            guard let colonIndex = trimmed.firstIndex(of: ":") else {
                continue
            }

            let key = String(trimmed[..<colonIndex]).trimmingCharacters(in: .whitespaces)
            let valueStr = String(trimmed[trimmed.index(after: colonIndex)...])
                .trimmingCharacters(in: .whitespaces)

            // Handle nested structures
            if indent < currentIndent {
                // Pop the stack until we're at the right level
                while let last = stack.last, last.indent >= indent {
                    stack.removeLast()
                }
            }

            if valueStr.isEmpty {
                // This is a nested section
                stack.append((indent: indent, key: key, dict: [:]))
                currentIndent = indent + 2  // Assume 2-space indent
            } else {
                // This is a value
                let value = parseYAMLValue(valueStr)

                if let parent = stack.last {
                    // Add to parent dict
                    var parentDict = parent.dict
                    parentDict[key] = value
                    stack[stack.count - 1] = (indent: parent.indent, key: parent.key, dict: parentDict)
                } else {
                    // Add to root
                    result[key] = value
                }
            }
        }

        // Flatten remaining stack
        while let item = stack.popLast() {
            if let parent = stack.last {
                var parentDict = parent.dict
                parentDict[item.key] = .dictionary(item.dict)
                stack[stack.count - 1] = (indent: parent.indent, key: parent.key, dict: parentDict)
            } else {
                result[item.key] = .dictionary(item.dict)
            }
        }

        return result
    }

    /// Parses a single YAML value.
    private func parseYAMLValue(_ value: String) -> YAMLValue {
        let trimmed = value.trimmingCharacters(in: .whitespaces)

        // Boolean
        if trimmed.lowercased() == "true" || trimmed.lowercased() == "yes" {
            return .boolean(true)
        }
        if trimmed.lowercased() == "false" || trimmed.lowercased() == "no" {
            return .boolean(false)
        }

        // Null
        if trimmed.lowercased() == "null" || trimmed == "~" {
            return .null
        }

        // Integer
        if let intValue = Int(trimmed) {
            return .integer(intValue)
        }

        // Number
        if let doubleValue = Double(trimmed) {
            return .number(doubleValue)
        }

        // Array (inline format)
        if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
            let arrayContent = String(trimmed.dropFirst().dropLast())
            let elements = arrayContent
                .split(separator: ",")
                .map { parseYAMLValue(String($0)) }
            return .array(elements)
        }

        // Quoted string
        if (trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"")) ||
           (trimmed.hasPrefix("'") && trimmed.hasSuffix("'")) {
            return .string(String(trimmed.dropFirst().dropLast()))
        }

        // Plain string
        return .string(trimmed)
    }

    /// Creates workflow parameters from a YAML value.
    private func createParameter(
        name: String,
        value: YAMLValue,
        path: [String]
    ) -> [UnifiedWorkflowParameter] {
        let fullName = (path + [name]).joined(separator: ".")

        switch value {
        case .string(let s):
            let type = inferTypeFromValue(name: name, value: s)
            return [UnifiedWorkflowParameter(
                id: fullName,
                name: fullName,
                title: formatTitle(name),
                description: nil,
                type: type,
                defaultValue: .string(s),
                isRequired: false,
                isHidden: false,
                validation: nil,
                iconName: iconForType(type),
                helpURL: nil
            )]

        case .integer(let i):
            return [UnifiedWorkflowParameter(
                id: fullName,
                name: fullName,
                title: formatTitle(name),
                description: nil,
                type: .integer,
                defaultValue: .integer(i),
                isRequired: false,
                isHidden: false,
                validation: nil,
                iconName: "number",
                helpURL: nil
            )]

        case .number(let n):
            return [UnifiedWorkflowParameter(
                id: fullName,
                name: fullName,
                title: formatTitle(name),
                description: nil,
                type: .number,
                defaultValue: .number(n),
                isRequired: false,
                isHidden: false,
                validation: nil,
                iconName: "function",
                helpURL: nil
            )]

        case .boolean(let b):
            return [UnifiedWorkflowParameter(
                id: fullName,
                name: fullName,
                title: formatTitle(name),
                description: nil,
                type: .boolean,
                defaultValue: .boolean(b),
                isRequired: false,
                isHidden: false,
                validation: nil,
                iconName: "switch.2",
                helpURL: nil
            )]

        case .array(let arr):
            let defaultArray = arr.compactMap { v -> UnifiedParameterValue? in
                switch v {
                case .string(let s): return .string(s)
                case .integer(let i): return .integer(i)
                case .number(let n): return .number(n)
                case .boolean(let b): return .boolean(b)
                default: return nil
                }
            }
            return [UnifiedWorkflowParameter(
                id: fullName,
                name: fullName,
                title: formatTitle(name),
                description: nil,
                type: .array(.string),
                defaultValue: .array(defaultArray),
                isRequired: false,
                isHidden: false,
                validation: nil,
                iconName: "square.stack.3d.up",
                helpURL: nil
            )]

        case .dictionary(let dict):
            // Flatten nested dictionaries
            var params: [UnifiedWorkflowParameter] = []
            for (key, val) in dict.sorted(by: { $0.key < $1.key }) {
                params.append(contentsOf: createParameter(
                    name: key,
                    value: val,
                    path: path + [name]
                ))
            }
            return params

        case .null:
            return [UnifiedWorkflowParameter(
                id: fullName,
                name: fullName,
                title: formatTitle(name),
                description: nil,
                type: .string,
                defaultValue: .null,
                isRequired: false,
                isHidden: false,
                validation: nil,
                iconName: "questionmark",
                helpURL: nil
            )]
        }
    }

    /// Infers the parameter type from its name and value.
    private func inferTypeFromValue(name: String, value: String) -> UnifiedParameterType {
        let lowerName = name.lowercased()

        // Check for file paths
        if lowerName.contains("file") || lowerName.contains("path") ||
           value.hasPrefix("/") || value.hasPrefix("~") ||
           value.contains(".fa") || value.contains(".fasta") ||
           value.contains(".gz") || value.contains(".bam") ||
           value.contains(".vcf") || value.contains(".bed") {
            return .file
        }

        // Check for directories
        if lowerName.contains("dir") || lowerName.contains("folder") ||
           lowerName.hasSuffix("_dir") || lowerName.hasSuffix("_directory") {
            return .directory
        }

        return .string
    }

    /// Returns an SF Symbol icon for a parameter type.
    private func iconForType(_ type: UnifiedParameterType) -> String {
        switch type {
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

    /// Formats a snake_case identifier as a title.
    private func formatTitle(_ identifier: String) -> String {
        identifier
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: ".", with: " - ")
            .capitalized
    }
}

// MARK: - YAMLValue

/// Represents a parsed YAML value.
private enum YAMLValue {
    case string(String)
    case integer(Int)
    case number(Double)
    case boolean(Bool)
    case array([YAMLValue])
    case dictionary([String: YAMLValue])
    case null
}
