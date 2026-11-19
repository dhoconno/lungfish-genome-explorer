// DemultiplexSingleOffsetRecordTests.swift - The record of a single-index run counts the reads two rows fit equally
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Lane DEMUX-SINGLE-OFFSET-SHIFT (ruling BIO-SINGLE-OFFSET item 4, FIX-OFFSET-SHIFT item 2). A Custom Definition with one
// sequence a row, searched at 5' End or 3' End with that end's distance above 0, sends a read that two rows fit equally to
// Unassigned. The record counts it as `ambiguousReads` and names the end its lines searched as `ambiguousReadsEnds`, which
// the Operations Panel row and its Log read to name the distance. A run whose searched distance is 0 writes neither key.
// The keys are read by their strings, so the file builds at the base.

import XCTest
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishCLI

final class DemultiplexSingleOffsetRecordTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "demux-single-offset-record")
    }

    override func tearDown() {
        if let root { TestTempDirectory.cleanup(root) }
        super.tearDown()
    }

    private func requireTools() async throws {
        guard await NativeToolRunner.shared.isToolAvailable(.cutadapt),
              await NativeToolRunner.shared.isToolAvailable(.seqkit) else {
            try ToolAvailability.skipOrFail("managed cutadapt or seqkit is not installed")
        }
    }

    private func run(_ arguments: [String]) async throws {
        var command = try FastqDemultiplexSubcommand.parse(arguments)
        try await command.run()
    }

    /// Writes `reads` as a FASTQ file and the definition of `rows`, one sequence a row, under the project.
    private func files(
        _ name: String, rows: [String], reads: [(String, String)]
    ) throws -> (input: URL, kit: URL, output: URL) {
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        let definitions = project.appendingPathComponent("Barcode Definitions", isDirectory: true)
        try FileManager.default.createDirectory(at: definitions, withIntermediateDirectories: true)
        let input = project.appendingPathComponent("\(name).fastq")
        try reads.map { "@\($0.0)\n\($0.1)\n+\n\(String(repeating: "I", count: $0.1.count))\n" }.joined()
            .write(to: input, atomically: true, encoding: .utf8)
        let kit = definitions.appendingPathComponent("\(name).csv")
        try ("id,sequence\n" + rows.map { "\($0),\($0)\n" }.joined()).write(to: kit, atomically: true, encoding: .utf8)
        return (input, kit, project.appendingPathComponent("Analyses/\(name)", isDirectory: true))
    }

    private static let insert = "ACGTTGCAAGCTTCGAGATCCATGGTACCGAATTCTGCAGTCGACGGATCCAAGCTTGCAT"

    /// How many reads of its own a row has next to the tied read. The chance floor counts a row only above the most reads
    /// chance gives it among the reads that carry no barcode. With one read in Unassigned the run has two chance trials,
    /// and a row of 8 bases at 4 offsets has a share of about 6e-5, so the most chance gives a row is 1 read (a tail
    /// under one in two million). A row with 3 reads of its own lies above it, and so the run publishes its samples and
    /// writes its record instead of refusing the kit (`noBarcodeAboveChance`).
    private static let readsOfOwn = 3

    /// `count` reads named `<prefix>1`, `<prefix>2`, ... that all carry `sequence`.
    private func copies(_ prefix: String, _ count: Int, _ sequence: String) -> [(String, String)] {
        (1...count).map { ("\(prefix)\($0)", sequence) }
    }

    func testTheRecordCountsTheReadsTwoRowsFitAndNamesTheEndTheLinesSearched() async throws {
        try await requireTools()
        // 3' End at 3' Distance 3: `TGGGCGAA` fits the first read at the end and `AGTGGGCG` 2 bases in (BIO-OFFSET-TIES
        // item 3). The other reads each carry one row's barcode at the read end.
        let threeReads: [(String, String)] = [("tied", Self.insert + "CCCCC" + "AGTGGGCGAA")]
            + copies("p", Self.readsOfOwn, Self.insert + "CCCCC" + "TGGGCGAA")
            + copies("q", Self.readsOfOwn, Self.insert + "CCCCC" + "AGTGGGCG")
        let three = try files("three", rows: ["TGGGCGAA", "AGTGGGCG"], reads: threeReads)
        try await run([
            three.input.path, "--kit", three.kit.path, "--location", "3prime", "--max-distance-3prime", "3",
            "--error-rate", "0", "-o", three.output.path,
        ])
        let threeRecord = try XCTUnwrap(ProvenanceEnvelopeReader.loadCanonical(from: three.output))
        XCTAssertEqual(threeRecord.options.explicit["ambiguousReads"], .integer(1))
        XCTAssertEqual(threeRecord.options.explicit["ambiguousReadsEnds"], .string("threePrime"))
        XCTAssertEqual(try XCTUnwrap(DemultiplexManifest.load(from: three.output)).unassigned.readCount, 1,
                       "the Unassigned count holds the read")

        // 5' End at 5' Distance 3: `TGGGCGAA` fits the first read at the start and `GGCGAAGT` 2 bases in.
        let fiveReads: [(String, String)] = [("tied", "TGGGCGAAGT" + "CCCCC" + Self.insert)]
            + copies("p", Self.readsOfOwn, "TGGGCGAA" + "CCCCC" + Self.insert)
            + copies("q", Self.readsOfOwn, "GGCGAAGT" + "CCCCC" + Self.insert)
        let five = try files("five", rows: ["TGGGCGAA", "GGCGAAGT"], reads: fiveReads)
        try await run([
            five.input.path, "--kit", five.kit.path, "--location", "5prime", "--max-distance-5prime", "3",
            "--error-rate", "0", "-o", five.output.path,
        ])
        let fiveRecord = try XCTUnwrap(ProvenanceEnvelopeReader.loadCanonical(from: five.output))
        XCTAssertEqual(fiveRecord.options.explicit["ambiguousReads"], .integer(1))
        XCTAssertEqual(fiveRecord.options.explicit["ambiguousReadsEnds"], .string("fivePrime"))
        XCTAssertEqual(try XCTUnwrap(DemultiplexManifest.load(from: five.output)).unassigned.readCount, 1,
                       "the Unassigned count holds the read")

        // 5' End with only the 3' Distance set searches no offset, so its record holds neither key.
        let zero = try files("zero", rows: ["TGGGCGAA", "GGCGAAGT"], reads: [
            ("p", "TGGGCGAA" + "CCCCC" + Self.insert), ("q", "GGCGAAGT" + "CCCCC" + Self.insert),
        ])
        try await run([
            zero.input.path, "--kit", zero.kit.path, "--location", "5prime", "--max-distance-3prime", "3",
            "--error-rate", "0", "-o", zero.output.path,
        ])
        let zeroRecord = try XCTUnwrap(ProvenanceEnvelopeReader.loadCanonical(from: zero.output))
        XCTAssertNil(zeroRecord.options.explicit["ambiguousReads"])
        XCTAssertNil(zeroRecord.options.explicit["ambiguousReadsEnds"])
    }
}
