// ViralReconStagedReadOrderTests.swift - viralrecon gets the pairs in a fixed-seed random order, not the bundle's
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Trust session finding F5 (S1, ruling BIO-F5-READ-ORDER). The import
// clumps a bundle's reads (clumpify `reorder groups=auto`), so similar reads
// sit together at the head of the file. viralrecon's fastp guesses the
// adapter from the head of the file, and on SRR36291587 it took the TruSeq
// adapter without its first base. One kept `A` on 2,309 reads then moved
// iVar's AF at 16935 from 0.868 to 0.418. The staging step now writes the
// pairs in a fixed-seed random order, with mates kept together, so fastp
// sees a fair sample and every run sees the same order.

import XCTest
import LungfishIO
import LungfishPortable
import LungfishTestSupport
@testable import LungfishWorkflow

final class ViralReconStagedReadOrderTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("viralrecon-staged-order-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// The four-line records of a plain or gzip FASTQ, each joined with its newlines.
    private func records(_ url: URL) throws -> [String] {
        let reader = try FASTQRawLineReader(url: url)
        defer { reader.close() }
        var lines: [String] = []
        while let line = try reader.nextLine() {
            lines.append(String(decoding: line, as: UTF8.self))
        }
        XCTAssertEqual(lines.count % 4, 0, url.lastPathComponent)
        return stride(from: 0, to: lines.count, by: 4).map { lines[$0..<$0 + 4].joined(separator: "\n") }
    }

    private func fragment(_ record: String) -> String {
        let header = record.prefix { $0 != "\n" }.dropFirst()
        return String(header.prefix { $0 != " " && $0 != "/" })
    }

    // F5. The split must not hand viralrecon the bundle's clumped order, and
    // must hand it the same order on every run.
    func testSplitStagesThePairsInAFixedSeededOrderThatIsNotTheBundleOrder() async throws {
        let pairCount = 300
        let bundle = try InterleavedFASTQFixture.writeBundle(named: "clumped", in: root, pairCount: pairCount, naming: .casava)
        let source = try records(bundle.fastqURL)
        let sourceR1 = stride(from: 0, to: source.count, by: 2).map { source[$0] }
        let sourcePairs = stride(from: 0, to: source.count, by: 2).map { source[$0] + "\n" + source[$0 + 1] }

        let first = try await ViralReconReadPairing.splitInterleavedInput(
            bundle.fastqURL, into: root.appendingPathComponent("run-1/clumped", isDirectory: true)
        )
        let second = try await ViralReconReadPairing.splitInterleavedInput(
            bundle.fastqURL, into: root.appendingPathComponent("run-2/clumped", isDirectory: true)
        )
        XCTAssertEqual(first.counts.r1Records, pairCount)
        XCTAssertEqual(first.counts.r2Records, pairCount)

        let r1 = try records(first.r1)
        let r2 = try records(first.r2)
        XCTAssertEqual(r1.count, pairCount)
        XCTAssertEqual(r2.count, pairCount)
        for (mate1, mate2) in zip(r1, r2) {
            XCTAssertEqual(fragment(mate1), fragment(mate2), "mates stay together")
        }
        XCTAssertEqual(
            zip(r1, r2).map { $0 + "\n" + $1 }.sorted(), sourcePairs.sorted(),
            "the staged files hold the bundle's pairs, each once, byte for byte"
        )
        XCTAssertNotEqual(r1, sourceR1, "viralrecon must not get the bundle's clumped order")

        XCTAssertEqual(try records(second.r1), r1, "every run stages the same order")
        XCTAssertEqual(try records(second.r2), r2, "every run stages the same order")
    }

    // F5, BIO item 2. The order is the seeded sort of the pair indices for
    // any bucket count, so bounded memory never changes it, and two mate
    // files are staged the same way as one interleaved file.
    func testOrderIsTheSameForAnyBucketCountAndForTwoMateFiles() throws {
        let pairCount = 500
        let interleaved = root.appendingPathComponent("pairs.fastq")
        try InterleavedFASTQFixture.write(pairCount: pairCount, naming: .slashSuffix, to: interleaved)
        let source = try records(interleaved)
        let mate1 = root.appendingPathComponent("pairs_R1.fastq")
        let mate2 = root.appendingPathComponent("pairs_R2.fastq")
        try (stride(from: 0, to: source.count, by: 2).map { source[$0] + "\n" }.joined()).write(to: mate1, atomically: true, encoding: .utf8)
        try (stride(from: 1, to: source.count, by: 2).map { source[$0] + "\n" }.joined()).write(to: mate2, atomically: true, encoding: .utf8)

        func stage(_ input: SeededPairOrder.Source, buckets: Int, _ tag: String) throws -> (r1: [String], r2: [String]) {
            let out1 = root.appendingPathComponent("\(tag)_R1.fastq")
            let out2 = root.appendingPathComponent("\(tag)_R2.fastq")
            FileManager.default.createFile(atPath: out1.path, contents: nil)
            FileManager.default.createFile(atPath: out2.path, contents: nil)
            let handle1 = try FileHandle(forWritingTo: out1)
            let handle2 = try FileHandle(forWritingTo: out2)
            let pairs = try SeededPairOrder.write(
                input, r1: handle1, r2: handle2,
                scratch: root.appendingPathComponent("scratch-\(tag)", isDirectory: true), bucketCount: buckets
            )
            try handle1.close()
            try handle2.close()
            XCTAssertEqual(pairs, pairCount, tag)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("scratch-\(tag)").path), tag)
            return (try records(out1), try records(out2))
        }

        let one = try stage(.interleaved(interleaved), buckets: 1, "one")
        let expectedR1 = SeededPairOrder.order(count: pairCount).map { source[2 * $0] }
        XCTAssertEqual(one.r1, expectedR1, "the order is the pair indices sorted by their seeded key")
        XCTAssertEqual(one.r2, SeededPairOrder.order(count: pairCount).map { source[2 * $0 + 1] })
        let seven = try stage(.interleaved(interleaved), buckets: 7, "seven")
        XCTAssertEqual(seven.r1, one.r1, "the bucket count never changes the order")
        XCTAssertEqual(seven.r2, one.r2)
        let files = try stage(.separate(r1: mate1, r2: mate2), buckets: 3, "files")
        XCTAssertEqual(files.r1, one.r1, "two mate files are staged in the same order")
        XCTAssertEqual(files.r2, one.r2)

        let short = root.appendingPathComponent("ten-second-mates.fastq")
        try (stride(from: 1, to: 20, by: 2).map { source[$0] + "\n" }.joined()).write(to: short, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try stage(.separate(r1: mate1, r2: short), buckets: 2, "short")) { error in
            XCTAssertEqual(error as? SeededPairOrder.StagingError, .mateCountMismatch(r1Records: pairCount, r2Records: 10))
        }
    }

    // F5, BIO item 2. The run record names the staging step and its seed.
    func testRunRecordNamesTheSeededStagingStep() async throws {
        let bundle = try InterleavedFASTQFixture.writeBundle(named: "S1", in: root, pairCount: 12, naming: .slashSuffix)
        let prepared = try await ViralReconReadPairing.prepareIlluminaSamples(
            [ViralReconSample(
                sampleName: "S1", sourceBundleURL: bundle.bundleURL, fastqURLs: [bundle.fastqURL],
                barcode: nil, sequencingSummaryURL: nil
            )],
            splitRoot: root.appendingPathComponent("split", isDirectory: true)
        )
        let decision = try XCTUnwrap(prepared.decisions.first)
        guard case .dictionary(let fields) = decision.provenanceValue else { return XCTFail("expected a dictionary") }
        guard case .dictionary(let order)? = fields["stagedPairOrder"] else {
            return XCTFail("the record does not name the order the pairs were staged in: \(fields.keys.sorted())")
        }
        XCTAssertEqual(order["step"], .string("pairs staged in seeded random order"))
        XCTAssertEqual(order["seed"], .integer(1))

        let url = root.appendingPathComponent("inputs").appendingPathComponent(ViralReconReadPairing.decisionsFilename)
        try ViralReconReadPairing.writeDecisions(prepared.decisions, to: url)
        XCTAssertEqual(ViralReconReadPairing.loadDecisions(from: url), prepared.decisions)
    }

    // F5, BIO 7. The seeded order is pinned (SplitMix64, seed 1), so a changed constant or seed fails here.
    func testSeededOrderIsPinned() {
        XCTAssertEqual(SeededPairOrder.key(of: 0, seed: 1), 0x910a_2dec_8902_5cc1)
        XCTAssertEqual(SeededPairOrder.key(of: 1, seed: 1), 0xbeeb_8da1_658e_ec67)
        XCTAssertEqual(SeededPairOrder.order(count: 8), [4, 3, 7, 0, 1, 5, 6, 2])
        XCTAssertEqual(SeededPairOrder.order(count: 12), [8, 10, 4, 3, 7, 0, 11, 1, 5, 9, 6, 2])
    }

    // R2. A single-end row of a bundle is staged in the seeded order too, since fastp guesses a single-end adapter
    // from the head of the file as well. The row is one gzip file that holds every read once, and the record says so.
    func testSingleEndBundleRowIsStagedInTheSeededOrderNotTheBundleOrder() async throws {
        let bundle = try InterleavedFASTQFixture.writeBundle(
            named: "solo", in: root, pairCount: 300, naming: .casava, pairingMode: .singleEnd, pairingSource: .explicit
        )
        let source = try records(bundle.fastqURL)
        func stage(_ tag: String) async throws -> (reads: [String], decision: ViralReconReadPairingDecision) {
            let prepared = try await ViralReconReadPairing.prepareIlluminaSamples(
                [ViralReconSample(
                    sampleName: "S1", sourceBundleURL: bundle.bundleURL, fastqURLs: [bundle.bundleURL],
                    barcode: nil, sequencingSummaryURL: nil
                )],
                splitRoot: root.appendingPathComponent("split-\(tag)", isDirectory: true)
            )
            let staged = try XCTUnwrap(prepared.samples.first?.fastqURLs)
            XCTAssertEqual(staged.count, 1, "a single-end row is one file")
            return (try records(try XCTUnwrap(staged.first)), try XCTUnwrap(prepared.decisions.first))
        }

        let first = try await stage("1")
        let second = try await stage("2")
        XCTAssertEqual(first.decision.layout, .singleEnd)
        XCTAssertEqual(first.reads.sorted(), source.sorted(), "viralrecon gets every read once, byte for byte")
        XCTAssertNotEqual(first.reads, source, "viralrecon must not get the bundle's clumped order")
        XCTAssertEqual(first.reads, SeededPairOrder.order(count: source.count).map { source[$0] })
        XCTAssertEqual(second.reads, first.reads, "every run stages the same order")
        guard case .dictionary(let fields) = first.decision.provenanceValue,
              case .dictionary(let order)? = fields["stagedPairOrder"] else {
            return XCTFail("the record does not name the order the reads were staged in")
        }
        XCTAssertEqual(order["step"], .string("reads staged in seeded random order"))
        XCTAssertEqual(order["seed"], .integer(1))
    }
}
