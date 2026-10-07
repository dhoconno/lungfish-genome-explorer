// DemultiplexCLIMatePairsTests.swift - lungfish-cli fastq demultiplex records how it called the mates of a paired input
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Demultiplexing now places both mates of a fragment by the fragment's call
// (A9, D6). The command records the calls in the demultiplex manifest and in
// its provenance, so a reader can see how many pairs one mate placed and how
// many went to unassigned because their mates disagreed.

import ArgumentParser
import Foundation
import XCTest
@testable import LungfishCLI
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

final class DemultiplexCLIMatePairsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "demultiplex-cli-mate-pairs")
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    private func record(_ header: String, _ sequence: String) -> String {
        "@\(header)\n\(sequence)\n+\n\(String(repeating: "I", count: sequence.count))\n"
    }

    /// `length` bases of GATTACA repeated, which holds neither barcode.
    private func insert(_ offset: Int, _ length: Int) -> String {
        let unit = Array("GATTACA")
        return String((0..<length).map { unit[($0 + offset) % unit.count] })
    }

    func testTheCommandRecordsTheMateCallsOfAPairedBundle() async throws {
        guard await NativeToolRunner.shared.isToolAvailable(.cutadapt),
              await NativeToolRunner.shared.isToolAvailable(.seqkit) else {
            try ToolAvailability.skipOrFail("managed cutadapt or seqkit is not installed")
        }
        let bc01 = "ACGTTGCA"
        let bc02 = "TTGGCCAA"
        let pairs = [
            ("agree", bc01 + insert(0, 52), bc01 + insert(1, 52)),
            ("onemate", bc01 + insert(2, 52), insert(3, 60)),
            ("clash", bc01 + insert(4, 52), bc02 + insert(5, 52)),
        ]
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        let bundle = project.appendingPathComponent("Imports/pairs.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try pairs.map { record("\($0.0) 1:N:0:1", $0.1) + record("\($0.0) 2:N:0:1", $0.2) }.joined()
            .write(to: bundle.appendingPathComponent("reads.fastq"), atomically: true, encoding: .utf8)
        let kit = root.appendingPathComponent("kit.csv")
        try "id,sequence\nBC01,\(bc01)\nBC02,\(bc02)\n".write(to: kit, atomically: true, encoding: .utf8)
        let output = project.appendingPathComponent("Analyses/demux", isDirectory: true)

        var command = try FastqDemultiplexSubcommand.parse([
            bundle.path, "--kit", kit.path, "--output", output.path,
            "--location", "5prime", "--error-rate", "0", "--overlap", "8",
        ])
        try await command.run()

        let manifest = try XCTUnwrap(DemultiplexManifest.load(from: output))
        XCTAssertEqual(
            manifest.mateCalls,
            DemultiplexMateCalls(pairs: 3, bothMatesAgree: 1, oneMateCalled: 1, matesDisagree: 1, neitherMateCalled: 0, singleReads: 0)
        )
        XCTAssertEqual(manifest.barcodes.map(\.readCount), [4], "BC01 holds both mates of two pairs")
        XCTAssertEqual(manifest.unassigned.readCount, 2, "the disagreeing pair is unassigned whole")

        let provenance = try XCTUnwrap(ProvenanceEnvelopeReader.loadCanonical(from: output))
        XCTAssertEqual(provenance.options.explicit["mateCalls"], .dictionary([
            "pairs": .integer(3),
            "bothMatesAgree": .integer(1),
            "oneMateCalled": .integer(1),
            "matesDisagree": .integer(1),
            "neitherMateCalled": .integer(0),
            "singleReads": .integer(0),
        ]))
    }
}
