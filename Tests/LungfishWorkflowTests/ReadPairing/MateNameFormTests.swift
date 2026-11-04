// MateNameFormTests.swift - True mates stay mates in every common read name form, and a wizard reads no whole file
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishIO
@testable import LungfishWorkflow
import LungfishPortable
import LungfishTestSupport

/// Row READ-LAYOUT-PARTIAL-SCAN. The positional split's name check stops at a false pair and never at a true one.
/// `fastq-dump --split-3 --readids` writes mates as `SRR123.1.1` and `SRR123.1.2`, and LGE stores them that way
/// (`ImportFastqUnpairedReadsCheckTests`).
final class MateNameFormTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "mate-name-forms")
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    static let trueForms: [(name: String, pairs: [(String, String)])] = [
        ("SRR123.1.1 and SRR123.1.2", (1...3).map { ("SRR123.\($0).1", "SRR123.\($0).2") }),
        ("the same, as stored", (1...3).map { ("SRR123.\($0).1 \($0) length=8", "SRR123.\($0).2 \($0) length=8") }),
        ("SRR123.1/1 and SRR123.1/2", (1...3).map { ("SRR123.\($0)/1", "SRR123.\($0)/2") }),
        ("Casava comments", (1...3).map { ("M00:1:FC:1:1:1:\($0) 1:N:0:ACGT", "M00:1:FC:1:1:1:\($0) 2:N:0:ACGT") }),
        ("name/1 and name/2", (1...3).map { ("read\($0)/1", "read\($0)/2") }),
        ("identical names", (1...3).map { ("read\($0)", "read\($0)") }),
        ("identical names, SRA comment", (1...3).map { ("SRR123.\($0) \($0) length=8", "SRR123.\($0) \($0) length=8") }),
    ]

    private func write(_ pairs: [(String, String)], to url: URL) throws {
        let text = pairs.map { "@\($0.0)\nACGTACGT\n+\nIIIIIIII\n@\($0.1)\nTTGGCCAA\n+\nIIIIIIII\n" }.joined()
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func split(_ input: URL) throws -> (r1: String, r2: String, counts: FASTQPairInterleaver.Counts) {
        let r1 = root.appendingPathComponent("\(UUID().uuidString).r1"), r2 = root.appendingPathComponent("\(UUID().uuidString).r2")
        FileManager.default.createFile(atPath: r1.path, contents: nil)
        FileManager.default.createFile(atPath: r2.path, contents: nil)
        let handle1 = try FileHandle(forWritingTo: r1), handle2 = try FileHandle(forWritingTo: r2)
        defer {
            try? handle1.close()
            try? handle2.close()
        }
        let counts = try FASTQPairInterleaver.deinterleave(interleaved: input, r1: handle1, r2: handle2)
        return (try String(contentsOf: r1, encoding: .utf8), try String(contentsOf: r2, encoding: .utf8), counts)
    }

    func testDeinterleaveKeepsTrueMatesInEveryNameForm() throws {
        for form in Self.trueForms {
            let input = root.appendingPathComponent("\(UUID().uuidString).fastq")
            try write(form.pairs, to: input)
            do {
                let result = try split(input)
                XCTAssertEqual(result.counts.r1Records, 3, form.name)
                XCTAssertEqual(result.counts.r2Records, 3, form.name)
                XCTAssertEqual(
                    result.r1, form.pairs.map { "@\($0.0)\nACGTACGT\n+\nIIIIIIII\n" }.joined(), form.name)
                XCTAssertEqual(
                    result.r2, form.pairs.map { "@\($0.1)\nTTGGCCAA\n+\nIIIIIIII\n" }.joined(), form.name)
            } catch {
                XCTFail("\(form.name): \(error.localizedDescription)")
            }
        }
    }

    /// The forms read as mates only by the recorded-pair rule still stop at a false pair. SRA spots number single
    /// reads `SRR1.1`, `SRR1.2`, `SRR1.3`, so a run of them stops at its second pair.
    func testDeinterleaveStillStopsAtAFalsePairInEveryForm() throws {
        let falseFiles: [(name: String, pairs: [(String, String)], stopsAt: Int)] = [
            ("spots of single reads", [("SRR1.1", "SRR1.2"), ("SRR1.3", "SRR1.4")], 2),
            ("two fragments in the dotted form", [("SRR1.1.1", "SRR1.2.2")], 1),
            ("read 2 before read 1 in the dotted form", [("SRR1.1.2", "SRR1.1.1")], 1),
            ("merged reads", [("m0", "m1")], 1),
            ("a mate then a merged read", [("p0/1", "m0")], 1),
        ]
        for file in falseFiles {
            let input = root.appendingPathComponent("\(UUID().uuidString).fastq")
            try write(file.pairs, to: input)
            XCTAssertThrowsError(try split(input), file.name) { error in
                guard case FASTQPairInterleaver.InterleaveError.mateNameMismatch(let recordNumber, _, _, _, _) = error else {
                    return XCTFail("\(file.name): \(error)")
                }
                XCTAssertEqual(recordNumber, file.stopsAt, file.name)
            }
        }
    }

    /// `resolvePairing`'s default reads past the old window of 100,000 records (the first report's Open question).
    func testResolvePairingReadsPastTheOldWindow() throws {
        let input = root.appendingPathComponent("mix.fastq")
        try FASTQLayoutRecordFixtures.write([.pairs(60_000), .singles(20_000)], to: input)
        let decision = FASTQPairingModeResolver.resolvePairing(inputURL: input)
        XCTAssertFalse(decision.pairAware)
        XCTAssertEqual(decision.resolution.layout, .mixedMergedAndPairs)
        XCTAssertEqual(decision.resolution.classification?.scannedRecords, 140_000)
        XCTAssertEqual(decision.resolution.classification?.scannedWholeFile, true)
    }

    // MARK: - Item 11, what a wizard may read

    /// A wizard reads no whole file. With no recorded count a large file's layout is left to the run.
    func testWizardPlansLeaveAnUncountedLargeFileToTheRun() async throws {
        let input = root.appendingPathComponent("large.fastq")
        try FASTQLayoutRecordFixtures.write([.pairs(70_000)], to: input)
        let sample = MetagenomicsSampleInput(sampleId: "large", fastq1: input, fastq2: nil)

        let esViritu = await EsVirituSampleReadPlan.planned(for: sample)
        XCTAssertEqual(esViritu.label, "Read layout is decided when the run starts")
        XCTAssertNil(esViritu.layout, "no layout comes from the first records of a file")

        let kraken = await ClassificationSampleReadPlan.planned(for: sample)
        XCTAssertEqual(kraken.label, "Read layout is decided when the run starts")
        XCTAssertNil(kraken.layout, "no layout comes from the first records of a file")
    }

    /// A small file is read whole within the same bound, so a wizard still names its layout.
    func testWizardPlansStillNameTheLayoutOfASmallFile() async throws {
        let input = root.appendingPathComponent("small.fastq")
        try FASTQLayoutRecordFixtures.write([.pairs(40)], to: input)
        let sample = MetagenomicsSampleInput(sampleId: "small", fastq1: input, fastq2: nil)

        let esViritu = await EsVirituSampleReadPlan.planned(for: sample)
        XCTAssertEqual(esViritu.format, .interleaved)
        XCTAssertEqual(esViritu.layout?.layout, .strictlyInterleaved)

        let kraken = await ClassificationSampleReadPlan.planned(for: sample)
        XCTAssertEqual(kraken.format, .interleaved)
        XCTAssertEqual(kraken.layout?.layout, .strictlyInterleaved)
    }
}
