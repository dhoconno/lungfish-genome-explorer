// CLIEventTranscriptCoverageTests+ImportRNASeq.swift - The in-process captures of import rnaseq
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
@testable import LungfishCLI
import LungfishCore
import LungfishIO

/// `import rnaseq` reads a plain count table in process and runs no tool, so its transcripts are captured in
/// process (Phase 5.1 lane RS-BULK-IMPORT, FIX-BULK-ROW), as the Import Center would run it: into a scratch project
/// with `--format json`. `complete` imports a table of two samples with a stated unit. `failed` names a table that
/// does not exist. They live here because the main file is past 800 lines.
extension CLIEventTranscriptCoverageTests {
    static func importRNASeqCaptures() -> [Capture] {
        ["complete", "failed"].map { name in
            Capture(leaf: "import rnaseq", name: name) { _ in
                let scratch = try ImportStreamCapture.Scratch()
                defer { scratch.remove() }
                try FileManager.default.createDirectory(at: scratch.project, withIntermediateDirectories: true)
                let input = scratch.root.appendingPathComponent(name == "complete" ? "counts.tsv" : "missing.tsv")
                if name == "complete" {
                    try "gene_id\tA\tB\ng1\t10\t20\ng2\t0\t5\n".write(to: input, atomically: true, encoding: .utf8)
                }
                let command = try ImportCommand.RNASeqSubcommand.parse([
                    input.path, "--project", scratch.project.path, "--name", "bulk", "--unit", "reads", "--format", "json",
                ])
                return try await ImportStreamCapture.capture(in: scratch) { try await command.run() }.standardOutput
            }
        }
    }
}
