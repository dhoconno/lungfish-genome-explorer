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
}
