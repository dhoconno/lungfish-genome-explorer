// FastqExportStreamCapture.swift - Runs fastq export sample-barcodes in process on a small selection
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishIO
@testable import LungfishCLI
import LungfishWorkflow

/// The run of `fastq export sample-barcodes` (Phase 2.12 lane 12.34 M2) whose `--format json` standard output is
/// checked in under `Tests/Fixtures/cli-events/commands/fastq-export-sample-barcodes`. The command needs no tool.
/// `CLIEventTranscriptCoverageTests` runs it through `ImportStreamCapture`, which gives each run a scratch folder of
/// its own and rewrites it to `/work`.
enum FastqExportStreamCapture {
    static func cases() -> [ImportStreamCapture.Case] {
        [
            ImportStreamCapture.Case(leaf: "fastq export sample-barcodes", name: "complete") { scratch in
                let assignments = [
                    FASTQSampleBarcodeAssignment(sampleID: "S1", forwardBarcodeID: "BC01", reverseBarcodeID: "BC02"),
                    FASTQSampleBarcodeAssignment(sampleID: "S2", forwardBarcodeID: "BC03", reverseBarcodeID: "BC04"),
                ]
                let selection = FASTQSampleBarcodeExport.selection(assignments: assignments, asymmetric: true)
                let selectionURL = try scratch.write(
                    "inputs/selection.json", String(decoding: try selection.encoded(), as: UTF8.self)
                )
                let reads = try scratch.write("inputs/reads.fastq", "@r1\nACGT\n+\nIIII\n")
                let command = try FastqExportSampleBarcodesSubcommand.parse([
                    reads.path, "--tab", "demux", "--selection", selectionURL.path,
                    "--output", scratch.root.appendingPathComponent("demux-pattern.csv").path, "--format", "json",
                ])
                return try await ImportStreamCapture.capture(in: scratch) { try await command.run() }
            },
        ]
    }
}
