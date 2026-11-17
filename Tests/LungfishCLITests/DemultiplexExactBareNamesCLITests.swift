// DemultiplexExactBareNamesCLITests.swift - lungfish-cli refuses Exact Bare on barcodes in the read names, and keeps it on choice
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// S1 sweep 2026-11-17 lane DEMUX-EXACTBARE-NAMES (item 2), backlog DEMUX-EXACT-BARE-NO-FLOOR, the names case (ruling
// BIO-DEMUX-THREE item 7). The run through the CLI. Exact Bare Barcode runs no tool, so this needs none.

import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow
@testable import LungfishCLI

final class DemultiplexExactBareNamesCLITests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "demux-exactbare-names-cli")
    }

    override func tearDown() {
        if let root { TestTempDirectory.cleanup(root) }
        super.tearDown()
    }

    /// 2,000 reads of 150 seeded random bases named `r<i> 1:N:0:<barcode>`, alternating the first two of 12 barcodes of 8 bases,
    /// and the 12 as a definition with no `# kit:` line.
    private func files(in project: URL) throws -> (input: URL, definition: URL) {
        let twelve = ["ATTACTCG", "TCCGGAGA", "CGCTCATT", "GAGATTCC", "ATTCAGAA", "GAATTCGT", "CTGAAGCT", "TAATGCGC",
                      "CGGCTATG", "TCCGCGAA", "TCTCGCGC", "AGCGATAG"]
        var state: UInt64 = 17
        let letters = Array("ACGT")
        var text = ""
        for index in 0..<2_000 {
            let bases = String((0..<150).map { _ -> Character in
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                return letters[Int((state >> 33) % 4)]
            })
            text += "@r\(index) 1:N:0:\(twelve[index % 2])\n\(bases)\n+\n\(String(repeating: "I", count: 150))\n"
        }
        let input = project.appendingPathComponent("names.fastq")
        try text.write(to: input, atomically: true, encoding: .utf8)
        let definition = project.appendingPathComponent("Twelve.csv")
        let rows = twelve.enumerated().map { "BC\(String(format: "%02d", $0.offset + 1)),\($0.element)" }
        try (["id,sequence"] + rows).joined(separator: "\n").appending("\n").write(to: definition, atomically: true, encoding: .utf8)
        return (input, definition)
    }

    /// Without the opt-in the CLI refuses and writes no folder. With `--keep-unchecked-samples` it runs the search of the
    /// sequences as the base ran it, records the opt-in beside `chanceCheck: "none"`, and carries the flag in its recorded
    /// command, so the command reproduces the run.
    func testTheCLIRefusesExactBareOnBarcodesInTheNamesAndRunsItOnlyWithTheOptIn() async throws {
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let (input, definition) = try files(in: project)
        let output = project.appendingPathComponent("Analyses/demux", isDirectory: true)
        let arguments = [input.path, "--kit", definition.path, "-o", output.path, "--engine", "exact-bare"]

        do {
            var command = try FastqDemultiplexSubcommand.parse(arguments)
            try await command.run()
            XCTFail("Exact Bare ran on reads whose barcodes sit in their names, so its sample files hold chance matches")
        } catch {
            XCTAssertTrue(String(describing: error).hasPrefix("exactBareBarcodesInReadNames("), "\(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "a refusal writes no folder")

        var command = try FastqDemultiplexSubcommand.parse(arguments + ["--keep-unchecked-samples"])
        try await command.run()
        let manifest = try XCTUnwrap(DemultiplexManifest.load(from: output), "no manifest in \(output.path)")
        XCTAssertFalse(manifest.barcodes.filter { $0.readCount > 0 }.isEmpty, "the opt-in keeps the search's sample files")
        let record = try XCTUnwrap(ProvenanceEnvelopeReader.loadCanonical(from: output))
        XCTAssertTrue(record.argv.contains("--keep-unchecked-samples"), "\(record.argv)")
        XCTAssertEqual(record.options.explicit["engine"], .string("exact-bare"))
        XCTAssertEqual(record.options.explicit["chanceCheck"], .string("none"))
        XCTAssertEqual(record.options.explicit["optIn"], .boolean(true), "\(record.options.explicit.keys.sorted())")
        XCTAssertEqual(AffectedResults.kind(of: record), .fastqDemultiplexExactBareNames, "the record of a run kept by choice")
        var unchosen = record
        var explicit = record.options.explicit
        explicit["optIn"] = nil
        unchosen.options = ProvenanceOptions(explicit: explicit)
        XCTAssertEqual(AffectedResults.kind(of: unchosen), .fastqDemultiplexExactBareNames, "read from the input's names")
    }
}
