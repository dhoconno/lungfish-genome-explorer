// FastqExportReadsStreamCapture.swift - Runs fastq export reads in process on a one-file bundle
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
@testable import LungfishCLI

/// The run of `fastq export reads` (Phase 2.12 lane 12.38 M2) whose `--format json` standard output is checked in under
/// `Tests/Fixtures/cli-events/commands/fastq-export-reads`. The command needs no tool for a bundle with one FASTQ file.
/// `CLIEventTranscriptCoverageTests` runs it through `ImportStreamCapture`, which gives each run a scratch folder of
/// its own and rewrites it to `/work`.
enum FastqExportReadsStreamCapture {
    static func cases() -> [ImportStreamCapture.Case] {
        [
            ImportStreamCapture.Case(leaf: "fastq export reads", name: "complete") { scratch in
                let reads = try scratch.write("inputs/reads.lungfishfastq/reads.fastq", "@r1\nACGT\n+\nIIII\n")
                let bundle = reads.deletingLastPathComponent()
                let command = try FastqExportReadsSubcommand.parse([
                    bundle.path, "--output", scratch.root.appendingPathComponent("reads-export.fastq").path,
                    "--format", "json",
                ])
                return try await ImportStreamCapture.capture(in: scratch) { try await command.run() }
            },
        ]
    }
}
