// CzIdImportStreamCapture.swift - Runs import cz-id in process on a small taxon report
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
@testable import LungfishCLI

/// The runs of `import cz-id` (Phase 2.12 lane 12.06) whose `--format json` standard output is checked in under
/// `Tests/Fixtures/cli-events/commands/import-cz-id`. The command needs no tool. `CLIEventTranscriptCoverageTests`
/// runs them through `ImportStreamCapture`, which gives each run a scratch folder of its own and rewrites it to
/// `/work`.
enum CzIdImportStreamCapture {
    /// A taxon report of one sample with a root, a superkingdom and a species row.
    static let report = """
    sample_name\tproject_id\tpipeline_version\tnt_db_version\tnr_db_version\ttax_id\ttaxon_name\trank\tnt_read_count\tnt_rpm\tnr_read_count\tnr_rpm
    Sample-CZ-001\tProject-42\t8.4\tnt_2025_12_01\tnr_2025_12_01\t1\troot\troot\t1200\t1000000\t1200\t1000000
    Sample-CZ-001\tProject-42\t8.4\tnt_2025_12_01\tnr_2025_12_01\t10239\tViruses\tsuperkingdom\t88\t73333\t12\t10000
    Sample-CZ-001\tProject-42\t8.4\tnt_2025_12_01\tnr_2025_12_01\t2697049\tSevere acute respiratory syndrome coronavirus 2\tspecies\t42\t35000\t5\t4166.7

    """

    static func cases() -> [ImportStreamCapture.Case] {
        func run(_ scratch: ImportStreamCapture.Scratch, source: URL) async throws -> ImportStreamCapture.Output {
            let command = try ImportCommand.CzIdSubcommand.parse([
                source.path, "--project", scratch.project.path, "--sample-name", "Sample CZ 001", "--format", "json",
            ])
            return try await ImportStreamCapture.capture(in: scratch) { try await command.run() }
        }
        return [
            ImportStreamCapture.Case(leaf: "import cz-id", name: "complete") { scratch in
                try await run(scratch, source: try scratch.write("inputs/taxon_report.tsv", report))
            },
            // An input that does not exist is refused before anything is written, with exit 3.
            ImportStreamCapture.Case(leaf: "import cz-id", name: "failed") { scratch in
                try await run(scratch, source: scratch.root.appendingPathComponent("inputs/missing.tsv"))
            },
        ]
    }
}
