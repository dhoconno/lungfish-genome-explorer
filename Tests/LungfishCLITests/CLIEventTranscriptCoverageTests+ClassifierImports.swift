// CLIEventTranscriptCoverageTests+ClassifierImports.swift - The in-process captures of the three classifier result imports
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
@testable import LungfishCLI

/// `import kraken2`, `import esviritu` and `import taxtriage` parse files and run no tool, so their transcripts are
/// captured in process (Phase 2.12 lane 12.04) on the fixtures of `ClassifierResultImportFixtures`, which carry the
/// dotted sample id `S1.2024`. Each imports into the Imports folder of a scratch project, as the Import Center does.
/// They live here because the main file is past 800 lines.
extension CLIEventTranscriptCoverageTests {
    static func classifierImportCaptures() -> [Capture] {
        let cases: [(leaf: String, name: String, input: (URL) throws -> URL)] = [
            ("import kraken2", "complete", { try ClassifierResultImportFixtures.kraken2Report(in: $0) }),
            ("import kraken2", "failed", { $0.appendingPathComponent("missing.kreport") }),
            ("import esviritu", "complete", { try ClassifierResultImportFixtures.esVirituResult(in: $0) }),
            ("import esviritu", "failed", { $0.appendingPathComponent("missing-esviritu", isDirectory: true) }),
            ("import taxtriage", "complete", { try ClassifierResultImportFixtures.taxTriageResult(in: $0) }),
            ("import taxtriage", "failed", { $0.appendingPathComponent("missing-taxtriage", isDirectory: true) }),
        ]
        return cases.map { testCase in
            Capture(leaf: testCase.leaf, name: testCase.name) { _ in
                let scratch = try ImportStreamCapture.Scratch()
                defer { scratch.remove() }
                let input = try testCase.input(scratch.root)
                let imports = scratch.project.appendingPathComponent("Imports", isDirectory: true)
                let argv = [input.path, "--output-dir", imports.path, "--format", "json"]
                switch testCase.leaf {
                case "import kraken2":
                    let command = try ImportCommand.Kraken2Subcommand.parse(argv)
                    return try await ImportStreamCapture.capture(in: scratch) { try await command.run() }.standardOutput
                case "import esviritu":
                    let command = try ImportCommand.EsVirituSubcommand.parse(argv)
                    return try await ImportStreamCapture.capture(in: scratch) { try await command.run() }.standardOutput
                default:
                    let command = try ImportCommand.TaxTriageSubcommand.parse(argv)
                    return try await ImportStreamCapture.capture(in: scratch) { try await command.run() }.standardOutput
                }
            }
        }
    }
}
