// WorkflowValidateSubcommand.swift - Validate workflow definition
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

// MARK: - Validate Subcommand (Workflow)

/// Validate workflow definition
struct WorkflowValidateSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "validate",
        abstract: "Validate a workflow definition"
    )

    @Argument(help: "Workflow file to validate")
    var workflow: String

    @OptionGroup var globalOptions: GlobalOptions

    func run() async throws {
        let formatter = TerminalFormatter(useColors: globalOptions.useColors)

        guard FileManager.default.fileExists(atPath: workflow) else {
            throw CLIError.inputFileNotFound(path: workflow)
        }

        let url = URL(fileURLWithPath: workflow)
        let ext = url.pathExtension.lowercased()
        let source = try String(contentsOf: url, encoding: .utf8)

        if ext == "nf" {
            try validateNextflow(source, fileName: url.lastPathComponent)
            emitValidationSuccess(
                workflowURL: url,
                engine: .nextflow,
                formatter: formatter
            )
        } else if url.lastPathComponent.lowercased().contains("snakefile") {
            try validateSnakemake(source, fileName: url.lastPathComponent)
            emitValidationSuccess(
                workflowURL: url,
                engine: .snakemake,
                formatter: formatter
            )
        } else {
            throw CLIError.unsupportedFormat(format: "Unknown workflow format")
        }
    }

    private func validateNextflow(_ source: String, fileName: String) throws {
        let validationSource = sourceForValidation(source, engine: .nextflow)
        var errors = commonSyntaxErrors(in: validationSource, fileName: fileName)
        if validationSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("Nextflow workflow \(fileName) is empty")
        }

        let nextflowPattern = #"\b(nextflow\.enable\.dsl|process\s+[A-Za-z_][A-Za-z0-9_]*|workflow\s*(\{|[A-Za-z_][A-Za-z0-9_]*\s*\{))"#
        if validationSource.range(of: nextflowPattern, options: .regularExpression) == nil {
            errors.append("Nextflow workflow \(fileName) must contain a Nextflow DSL declaration, process block, or workflow block")
        }

        if !errors.isEmpty {
            throw CLIError.validationFailed(errors: errors)
        }
    }

    private func validateSnakemake(_ source: String, fileName: String) throws {
        let validationSource = sourceForValidation(source, engine: .snakemake)
        var errors = commonSyntaxErrors(in: validationSource, fileName: fileName)
        if validationSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("Snakemake workflow \(fileName) is empty")
        }

        let snakemakePattern = #"(?m)^\s*(rule|checkpoint|include:|configfile:|module|use\s+rule|subworkflow)\b"#
        if validationSource.range(of: snakemakePattern, options: .regularExpression) == nil {
            errors.append("Snakemake workflow \(fileName) must contain at least one rule, checkpoint, include, configfile, module, use rule, or subworkflow declaration")
        }

        if !errors.isEmpty {
            throw CLIError.validationFailed(errors: errors)
        }
    }

    private func commonSyntaxErrors(in source: String, fileName: String) -> [String] {
        var errors: [String] = []
        if source.contains("<<<<<<<") || source.contains("=======") || source.contains(">>>>>>>") {
            errors.append("\(fileName) contains unresolved merge conflict markers")
        }

        let delimiters: [(open: Character, close: Character, name: String)] = [
            (open: "(", close: ")", name: "parentheses"),
            (open: "[", close: "]", name: "brackets"),
            (open: "{", close: "}", name: "braces"),
        ]
        for delimiter in delimiters {
            if !hasOrderedDelimiters(in: source, open: delimiter.open, close: delimiter.close) {
                errors.append("\(fileName) has unbalanced \(delimiter.name)")
            }
        }
        return errors
    }

    private func hasOrderedDelimiters(in source: String, open: Character, close: Character) -> Bool {
        var depth = 0
        for character in source {
            if character == open {
                depth += 1
            } else if character == close {
                guard depth > 0 else { return false }
                depth -= 1
            }
        }
        return depth == 0
    }

    private func sourceForValidation(_ source: String, engine: WorkflowValidationEngine) -> String {
        let lineCommentPrefix: String = engine == .nextflow ? "//" : "#"
        var stripped = ""
        var index = source.startIndex
        var activeQuote: Character?
        var isEscaped = false
        var isInBlockComment = false

        while index < source.endIndex {
            let character = source[index]

            if isInBlockComment {
                if source[index...].hasPrefix("*/") {
                    index = source.index(index, offsetBy: 2)
                    isInBlockComment = false
                    continue
                }
                if character == "\n" {
                    stripped.append(character)
                }
                index = source.index(after: index)
                continue
            }

            if let quote = activeQuote {
                stripped.append(character)
                if isEscaped {
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == quote {
                    activeQuote = nil
                }
                index = source.index(after: index)
                continue
            }

            if character == "\"" || character == "'" {
                activeQuote = character
                stripped.append(character)
                index = source.index(after: index)
                continue
            }

            if source[index...].hasPrefix("/*") {
                index = source.index(index, offsetBy: 2)
                isInBlockComment = true
                continue
            }

            if source[index...].hasPrefix(lineCommentPrefix) {
                repeat {
                    index = source.index(after: index)
                } while index < source.endIndex && source[index] != "\n"
                continue
            }

            stripped.append(character)
            index = source.index(after: index)
        }

        return stripped
    }

    private func emitValidationSuccess(
        workflowURL: URL,
        engine: WorkflowValidationEngine,
        formatter: TerminalFormatter
    ) {
        guard !globalOptions.quiet else { return }

        let report = WorkflowValidationReport(
            workflow: workflowURL.path,
            engine: engine,
            valid: true,
            errors: []
        )

        switch globalOptions.outputFormat {
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(report),
               let json = String(data: data, encoding: .utf8) {
                print(json)
            }
        case .tsv:
            print("workflow\tengine\tvalid\terrors")
            print("\(workflowURL.path)\t\(engine.rawValue)\ttrue\t")
        case .text:
            print(formatter.info("Validating \(engine.displayName) workflow: \(workflowURL.lastPathComponent)"))
            print(formatter.success("Workflow syntax appears valid"))
        }
    }

    private struct WorkflowValidationReport: Encodable {
        let workflow: String
        let engine: WorkflowValidationEngine
        let valid: Bool
        let errors: [String]
    }

    private enum WorkflowValidationEngine: String, Encodable {
        case nextflow
        case snakemake

        var displayName: String {
            switch self {
            case .nextflow: return "Nextflow"
            case .snakemake: return "Snakemake"
            }
        }
    }
}
