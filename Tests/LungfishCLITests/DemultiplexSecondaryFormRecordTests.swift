// DemultiplexSecondaryFormRecordTests.swift - The record of a dual-index run names the form the first reads carried
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Fix round FIX-DUAL-FORM item 3 (review DEMUX-DUAL-FORM-BIO, should-fix 3). `FastqCommand.swift` is the only code that writes
// `secondaryForm` and `secondaryFormVotes` into the record of a run (BIO-DUAL-FORM item 2, for this route only), and the
// Operations Panel line and the AFFECTED row read them. The app test and the AFFECTED test build their records by hand, so
// a key that drifted, or a block that moved inside a branch, left every test green. This test runs the command and reads the
// record it wrote. The keys are read by their strings, so the file builds at the base.

import XCTest
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishCLI

final class DemultiplexSecondaryFormRecordTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "demux-secondary-form-record")
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

    /// Three rows with no two first barcodes within a base of each other, so no two rows collide (the first three of
    /// `DemultiplexDualFormTests.eight`).
    private static let rows: [(id: String, first: String, second: String)] = [
        ("D01", "TAAGGCGA", "TAGATCGC"), ("D02", "CGTACTAG", "CTCTCTAT"), ("D03", "AGGCAGAA", "TATCCTCT"),
    ]
    private static let complement: [Character: Character] = ["A": "T", "C": "G", "G": "C", "T": "A"]
    private static let readsPerRow = 10

    private func reverseComplement(_ sequence: String) -> String {
        String(sequence.reversed().map { Self.complement[$0] ?? $0 })
    }

    /// Seeded bases, so every run reads the same file.
    private struct Bases {
        var state: UInt64 = 0x5EED
        mutating func next() -> Character {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Array("ACGT")[Int((state >> 33) % 4)]
        }
    }

    /// 10 reads of each row in primer form: the first barcode at the start and the reverse complement of the secondary
    /// sequence at the end, which is how a file that lists the i5 primer's barcodes carries them.
    private func writePrimerFormReads(to url: URL) throws {
        var bases = Bases()
        var text = ""
        for row in Self.rows {
            for index in 0..<Self.readsPerRow {
                let middle = String((0..<60).map { _ in bases.next() })
                let sequence = row.first + middle + reverseComplement(row.second)
                text += "@\(row.id)|\(index)\n\(sequence)\n+\n\(String(repeating: "I", count: sequence.count))\n"
            }
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// 200 reads whose names carry the index ATTACTCG and 100 that carry TCCGGAGA, the read-name route of
    /// `DemultiplexDefinitionCopyTests`.
    private func writeIndexNameReads(to url: URL) throws {
        var bases = Bases()
        let indexes = Array(repeating: "ATTACTCG", count: 200) + Array(repeating: "TCCGGAGA", count: 100)
        let text = indexes.enumerated().map { read in
            let sequence = String((0..<60).map { _ in bases.next() })
            return "@r\(read.offset) 1:N:0:\(read.element)\n\(sequence)\n+\n\(String(repeating: "I", count: 60))\n"
        }.joined()
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func run(_ arguments: [String]) async throws {
        var command = try FastqDemultiplexSubcommand.parse(arguments)
        try await command.run()
    }

    func testTheRecordNamesTheFormOnThisRouteOnly() async throws {
        try await requireTools()
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        let definitions = project.appendingPathComponent("Barcode Definitions", isDirectory: true)
        try FileManager.default.createDirectory(at: definitions, withIntermediateDirectories: true)

        // This route: a Custom Definition of dual indexes at Both Ends with no sample sheet, on reads in primer form.
        let input = project.appendingPathComponent("reads.fastq")
        try writePrimerFormReads(to: input)
        let dual = definitions.appendingPathComponent("dual.csv")
        let table = "id,sequence,secondary_sequence\n" + Self.rows.map { "\($0.id),\($0.first),\($0.second)\n" }.joined()
        try table.write(to: dual, atomically: true, encoding: .utf8)
        let dualOutput = project.appendingPathComponent("Analyses/dual", isDirectory: true)
        try await run([input.path, "--kit", dual.path, "--location", "bothends", "-o", dualOutput.path])

        let record = try XCTUnwrap(ProvenanceEnvelopeReader.loadCanonical(from: dualOutput))
        let reads = Self.rows.count * Self.readsPerRow
        XCTAssertEqual(record.options.explicit["secondaryForm"], .string("reverse-complemented"))
        XCTAssertEqual(
            record.options.explicit["secondaryFormVotes"],
            .dictionary([
                "readsRead": .integer(reads), "asWritten": .integer(0), "reverseComplemented": .integer(reads),
                "disputed": .integer(0), "rowsCarrying": .integer(Self.rows.count),
            ])
        )

        // Another route: one barcode column, found in the read names. Its record holds neither key.
        let names = project.appendingPathComponent("names.fastq")
        try writeIndexNameReads(to: names)
        let single = definitions.appendingPathComponent("single.csv")
        try "id,sequence,sample_name\nWater_blank,ATTACTCG,Water_blank sample\nNTC_1,TCCGGAGA,NTC_1 sample\n"
            .write(to: single, atomically: true, encoding: .utf8)
        let singleOutput = project.appendingPathComponent("Analyses/single", isDirectory: true)
        try await run([names.path, "--kit", single.path, "-o", singleOutput.path])

        let other = try XCTUnwrap(ProvenanceEnvelopeReader.loadCanonical(from: singleOutput))
        XCTAssertNil(other.options.explicit["secondaryForm"])
        XCTAssertNil(other.options.explicit["secondaryFormVotes"])
    }
}
