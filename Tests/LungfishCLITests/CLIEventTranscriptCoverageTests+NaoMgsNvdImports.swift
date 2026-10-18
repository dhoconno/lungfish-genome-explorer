// CLIEventTranscriptCoverageTests+NaoMgsNvdImports.swift - The in-process captures of import nao-mgs and import nvd
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
@testable import LungfishCLI

/// `import nao-mgs` and `import nvd` parse files and run no tool in a test, so their transcripts are captured in
/// process (Phase 2.12 lane 12.05) on the fixtures of `NaoMgsNvdImportFixtures`, which carry the dotted sample ids
/// `S1.2024` and `S2.2024`. Each imports into the Imports folder of a scratch project, as the Import Center does.
/// The NAO-MGS case runs with `--no-fetch-references` and a managed storage under the scratch folder that holds a
/// fixture taxonomy, so it needs no network and writes nothing into the user's storage. They live here because
/// the main file is past 800 lines.
extension CLIEventTranscriptCoverageTests {
    static func naoMgsNvdImportCaptures() -> [Capture] {
        let cases: [(leaf: String, name: String, input: (URL) throws -> URL)] = [
            ("import nao-mgs", "complete", { try NaoMgsNvdImportFixtures.naoMgsResult(in: $0) }),
            ("import nao-mgs", "failed", { $0.appendingPathComponent("missing-naomgs", isDirectory: true) }),
            ("import nvd", "complete", { try NaoMgsNvdImportFixtures.nvdRun(in: $0) }),
            ("import nvd", "failed", { $0.appendingPathComponent("missing-nvd", isDirectory: true) }),
        ]
        return cases.map { testCase in
            Capture(leaf: testCase.leaf, name: testCase.name) { _ in
                let scratch = try ImportStreamCapture.Scratch()
                defer { scratch.remove() }
                let storage = try await NaoMgsNvdImportFixtures.installFixtureTaxonomy(in: scratch.root)
                let storageBefore = NaoMgsNvdImportFixtures.useStorage(storage)
                defer { NaoMgsNvdImportFixtures.restoreStorage(storageBefore) }
                let input = try testCase.input(scratch.root)
                let imports = scratch.project.appendingPathComponent("Imports", isDirectory: true)
                if testCase.leaf == "import nao-mgs" {
                    let command = try ImportCommand.NaoMgsSubcommand.parse(
                        [input.path, "--no-fetch-references", "--output-dir", imports.path, "--format", "json"]
                    )
                    return try await ImportStreamCapture.capture(in: scratch) { try await command.run() }.standardOutput
                }
                let command = try ImportCommand.NvdSubcommand.parse([input.path, "--output-dir", imports.path, "--format", "json"])
                return try await ImportStreamCapture.capture(in: scratch) { try await command.run() }.standardOutput
            }
        }
    }
}
