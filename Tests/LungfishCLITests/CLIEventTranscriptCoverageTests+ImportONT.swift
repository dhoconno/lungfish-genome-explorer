// CLIEventTranscriptCoverageTests+ImportONT.swift - The in-process captures of `fastq import-ont`
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
@testable import LungfishCLI

/// `fastq import-ont` runs no tool without `--optimize-storage`, so its transcripts are captured in process
/// through `execute(emit:)` on a two-barcode run folder (2.10 A53). They live here because the main file is
/// past 800 lines. The import's last stage word carries its wall time, so the capture writes it as `0.0s`.
/// That is the one edit besides the scratch folder, and it keeps the transcript from changing with the speed
/// of the Mac.
extension CLIEventTranscriptCoverageTests {
    static func importONTCaptures() -> [Capture] {
        func runFolder(_ scratch: Scratch) throws -> URL {
            let source = scratch.root.appendingPathComponent("fastq_pass", isDirectory: true)
            for (barcode, reads) in [("barcode01", ["r1", "r2"]), ("barcode02", ["r3"])] {
                let directory = source.appendingPathComponent(barcode, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let text = reads.map {
                    "@\($0) runid=test flow_cell_id=FLO-MIN sample_id=S1 barcode=\(barcode)\nACGTACGT\n+\nIIIIIIII\n"
                }.joined()
                try text.write(to: directory.appendingPathComponent("chunk_0.fastq"), atomically: true, encoding: .utf8)
            }
            return source
        }
        func withoutWallTime(_ line: String) -> String {
            line.replacingOccurrences(of: #"\d+\.\ds\)"#, with: "0.0s)", options: .regularExpression)
        }
        return [
            Capture(leaf: "fastq import-ont", name: "complete") { scratch in
                let source = try runFolder(scratch)
                let output = scratch.root.appendingPathComponent("imported", isDirectory: true)
                let command = try FastqImportONTSubcommand.parse([
                    source.path, "--output", output.path, "--concurrency", "1", "--format", "json",
                ])
                return try await Self.eventLines { try await command.execute(emit: $0) }.map(withoutWallTime)
            },
            // A folder with no barcode folder and no FASTQ ends the stream after its start line.
            Capture(leaf: "fastq import-ont", name: "failed") { scratch in
                let folder = scratch.root.appendingPathComponent("empty-run", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let output = scratch.root.appendingPathComponent("imported", isDirectory: true)
                let command = try FastqImportONTSubcommand.parse([folder.path, "--output", output.path, "--format", "json"])
                return try await Self.eventLines(expectingFailure: true) { try await command.execute(emit: $0) }
            },
        ]
    }
}
