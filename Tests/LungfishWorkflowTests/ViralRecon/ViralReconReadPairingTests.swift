// ViralReconReadPairingTests.swift - Interleaved bundles reach viralrecon as fastq_1/fastq_2
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

final class ViralReconReadPairingTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("viralrecon-read-pairing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Fixtures

    private func sample(_ name: String, _ urls: [URL]) -> ViralReconSample {
        ViralReconSample(sampleName: name, sourceBundleURL: urls[0], fastqURLs: urls, barcode: nil, sequencingSummaryURL: nil)
    }

    private func gzip(_ source: URL) throws -> URL {
        let destination = URL(fileURLWithPath: source.path + ".gz")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-k", "-f", source.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return destination
    }

    private func gunzipText(_ url: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-dc", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return String(decoding: data, as: UTF8.self)
    }

    private func samplesheetRows(_ url: URL) throws -> [[String]] {
        try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n")
            .dropFirst()
            .map { $0.split(separator: ",", omittingEmptySubsequences: false).map(String.init) }
    }

    // MARK: - Interleaved bundle (the science bug)

    func testStrictlyInterleavedBundleIsSplitIntoGzipMatesAndWrittenAsFastq1AndFastq2() async throws {
        for naming in InterleavedFASTQFixture.MateNaming.allCases {
            let bundle = try InterleavedFASTQFixture.writeBundle(
                named: "pairs-\(naming.rawValue)", in: root, pairCount: 6, naming: naming
            )
            let interleaved = sample("S-\(naming.rawValue)", [bundle.fastqURL])

            let decision = ViralReconReadPairing.decision(for: interleaved)
            XCTAssertEqual(decision.layout, .strictlyInterleaved, naming.rawValue)
            XCTAssertEqual(decision.handling, .splitToR1R2, naming.rawValue)
            XCTAssertNil(decision.warning, naming.rawValue)
            XCTAssertNil(decision.pairCount, "no split has run yet")

            let splitRoot = root.appendingPathComponent("split-\(naming.rawValue)", isDirectory: true)
            let prepared = try await ViralReconReadPairing.prepareIlluminaSamples([interleaved], splitRoot: splitRoot)

            let prepared0 = try XCTUnwrap(prepared.samples.first)
            XCTAssertEqual(prepared0.fastqURLs.count, 2, naming.rawValue)
            XCTAssertTrue(prepared0.fastqURLs.allSatisfy { $0.path.hasSuffix(".fastq.gz") && $0.path.hasPrefix(splitRoot.path) })
            let recorded = try XCTUnwrap(prepared.decisions.first)
            XCTAssertEqual(recorded.pairCount, 6)
            XCTAssertEqual(recorded.splitR1URL, prepared0.fastqURLs[0])
            XCTAssertEqual(recorded.splitR2URL, prepared0.fastqURLs[1])
            XCTAssertEqual(recorded.sourceFASTQURLs, [bundle.fastqURL], "the decision names the file the user chose")
            XCTAssertTrue(prepared.didSplit)

            // Each half holds exactly its mates, byte for byte.
            let r1 = try gunzipText(prepared0.fastqURLs[0])
            let r2 = try gunzipText(prepared0.fastqURLs[1])
            let expected = InterleavedFASTQFixture.fastqText(pairCount: 6, naming: naming)
                .split(separator: "\n").map(String.init)
            let expectedR1 = stride(from: 0, to: expected.count, by: 8).flatMap { expected[$0..<$0 + 4] }.joined(separator: "\n") + "\n"
            let expectedR2 = stride(from: 4, to: expected.count, by: 8).flatMap { expected[$0..<$0 + 4] }.joined(separator: "\n") + "\n"
            XCTAssertEqual(r1, expectedR1, naming.rawValue)
            XCTAssertEqual(r2, expectedR2, naming.rawValue)

            let samplesheet = try ViralReconSamplesheetBuilder.writeIlluminaSamplesheet(
                samples: prepared.samples,
                in: root.appendingPathComponent("sheet-\(naming.rawValue)", isDirectory: true)
            )
            let rows = try samplesheetRows(samplesheet)
            XCTAssertEqual(rows.count, 1)
            XCTAssertEqual(rows[0][0], "S-\(naming.rawValue)")
            XCTAssertEqual(rows[0][1], prepared0.fastqURLs[0].path)
            XCTAssertEqual(rows[0][2], prepared0.fastqURLs[1].path, "fastq_2 must carry the R2 half, not be empty")
        }
    }

    func testGzipInterleavedSourceIsSplitTheSameWay() async throws {
        let plain = root.appendingPathComponent("reads.fastq")
        try InterleavedFASTQFixture.write(pairCount: 5, naming: .slashSuffix, to: plain)
        let compressed = try gzip(plain)
        try FileManager.default.removeItem(at: plain)

        let prepared = try await ViralReconReadPairing.prepareIlluminaSamples(
            [sample("gz", [compressed])],
            splitRoot: root.appendingPathComponent("split", isDirectory: true)
        )
        let decision = try XCTUnwrap(prepared.decisions.first)
        XCTAssertEqual(decision.handling, .splitToR1R2)
        XCTAssertEqual(decision.pairCount, 5)
        XCTAssertEqual(prepared.samples[0].fastqURLs.map(\.lastPathComponent), ["reads_R1.fastq.gz", "reads_R2.fastq.gz"])
        XCTAssertTrue(try gunzipText(prepared.samples[0].fastqURLs[1]).hasPrefix("@frag0/2\n"))
    }

    // MARK: - Layouts that stay single or are already paired

    func testPairedFileSampleWritesBothColumnsWithoutSplitting() async throws {
        let r1 = root.appendingPathComponent("A_R1.fastq.gz")
        let r2 = root.appendingPathComponent("A_R2.fastq.gz")
        let paired = sample("A", [r1, r2])

        let decision = ViralReconReadPairing.decision(for: paired)
        XCTAssertEqual(decision.layout, .pairedFiles)
        XCTAssertEqual(decision.handling, .asPairs)
        XCTAssertFalse(decision.needsSplit)

        let prepared = try await ViralReconReadPairing.prepareIlluminaSamples([paired], splitRoot: root.appendingPathComponent("split"))
        XCTAssertEqual(prepared.samples, [paired])
        XCTAssertFalse(prepared.didSplit)
        let rows = try samplesheetRows(try ViralReconSamplesheetBuilder.writeIlluminaSamplesheet(samples: prepared.samples, in: root))
        XCTAssertEqual(rows, [["A", r1.path, r2.path]])
    }

    func testMixedBundleStaysSingleEndWithAWarning() async throws {
        let bundle = try InterleavedFASTQFixture.writeMixedBundle(
            named: "mixed", in: root, pairCount: 4, mergedCount: 3, naming: .identical
        )
        let mixed = sample("M", [bundle.fastqURL])

        let decision = ViralReconReadPairing.decision(for: mixed)
        XCTAssertEqual(decision.layout, .mixedMergedAndPairs)
        XCTAssertEqual(decision.handling, .asSingle)
        XCTAssertTrue(decision.warning?.contains("single-end") == true)
        XCTAssertTrue(decision.summary.contains("runs single-end"))

        let prepared = try await ViralReconReadPairing.prepareIlluminaSamples([mixed], splitRoot: root.appendingPathComponent("split"))
        XCTAssertEqual(prepared.samples, [mixed], "a mixed file is never split by position")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("split").path))
    }

    func testSingleEndBundleStaysSingleEndWithoutAWarning() async throws {
        let bundle = try InterleavedFASTQFixture.writeBundle(
            named: "single", in: root, pairCount: 4, naming: .slashSuffix,
            pairingMode: .singleEnd, pairingSource: .explicit
        )
        let single = sample("S", [bundle.fastqURL])

        let decision = ViralReconReadPairing.decision(for: single)
        XCTAssertEqual(decision.layout, .singleEnd)
        XCTAssertEqual(decision.handling, .asSingle)
        XCTAssertNil(decision.warning)

        let prepared = try await ViralReconReadPairing.prepareIlluminaSamples([single], splitRoot: root.appendingPathComponent("split"))
        XCTAssertEqual(prepared.samples, [single])
    }

    func testLooseSingleEndReadsStaySingleEnd() async throws {
        let plain = root.appendingPathComponent("solo.fastq")
        try (1...5).map { "@solo\($0)\nACGTACGTAC\n+\nIIIIIIIIII\n" }.joined().write(to: plain, atomically: true, encoding: .utf8)
        let compressed = try gzip(plain)

        let decision = ViralReconReadPairing.decision(for: sample("solo", [compressed]))
        XCTAssertEqual(decision.layout, .singleEnd)
        XCTAssertEqual(decision.handling, .asSingle)
        let rows = try samplesheetRows(try ViralReconSamplesheetBuilder.writeIlluminaSamplesheet(samples: [sample("solo", [compressed])], in: root))
        XCTAssertEqual(rows, [["solo", compressed.path, ""]])
    }

    func testMixedBatchSplitsOnlyTheInterleavedRows() async throws {
        let interleaved = try InterleavedFASTQFixture.writeBundle(named: "pairs", in: root, pairCount: 3, naming: .casava)
        let mixed = try InterleavedFASTQFixture.writeMixedBundle(named: "mixed", in: root, pairCount: 2, mergedCount: 2, naming: .casava)
        let samples = [
            sample("pairs", [interleaved.fastqURL]),
            sample("mixed", [mixed.fastqURL]),
            sample("files", [root.appendingPathComponent("x_R1.fastq.gz"), root.appendingPathComponent("x_R2.fastq.gz")]),
        ]

        let prepared = try await ViralReconReadPairing.prepareIlluminaSamples(samples, splitRoot: root.appendingPathComponent("split"))

        XCTAssertEqual(prepared.decisions.map(\.handling), [.splitToR1R2, .asSingle, .asPairs])
        XCTAssertEqual(prepared.decisions.map(\.layout), [.strictlyInterleaved, .mixedMergedAndPairs, .pairedFiles])
        XCTAssertEqual(prepared.samples.map { $0.fastqURLs.count }, [2, 1, 2])
        XCTAssertEqual(prepared.samples[1], samples[1])
        XCTAssertEqual(prepared.samples[2], samples[2])
        let summary = try XCTUnwrap(ViralReconReadPairing.summaryLine(for: prepared.decisions))
        XCTAssertTrue(summary.contains("pairs: interleaved pairs, split into R1/R2 (3 pairs), runs paired-end"), summary)
        XCTAssertTrue(summary.contains("mixed: mixed merged reads and pairs, runs single-end"), summary)
        XCTAssertTrue(summary.contains("files: paired R1/R2 files, runs paired-end"), summary)
    }

    // MARK: - Samplesheet round trip and decision records

    func testSamplesheetRowsReadBackIntoTheSameSamples() throws {
        let sheet = root.appendingPathComponent("samplesheet.csv")
        try """
        sample,fastq_1,fastq_2
        A,/data/A_R1.fastq.gz,/data/A_R2.fastq.gz
        "B, two",/data/B.fastq.gz,
        C,/data/C.fastq.gz

        """.write(to: sheet, atomically: true, encoding: .utf8)

        let samples = try ViralReconReadPairing.parseIlluminaSamplesheet(at: sheet)

        XCTAssertEqual(samples.map(\.sampleName), ["A", "B, two", "C"])
        XCTAssertEqual(samples.map { $0.fastqURLs.map(\.path) }, [
            ["/data/A_R1.fastq.gz", "/data/A_R2.fastq.gz"],
            ["/data/B.fastq.gz"],
            ["/data/C.fastq.gz"],
        ])
        let rewritten = try ViralReconSamplesheetBuilder.writeIlluminaSamplesheet(samples: samples, in: root, filename: "again.csv")
        XCTAssertEqual(
            try String(contentsOf: rewritten, encoding: .utf8),
            "sample,fastq_1,fastq_2\nA,/data/A_R1.fastq.gz,/data/A_R2.fastq.gz\n\"B, two\",/data/B.fastq.gz,\nC,/data/C.fastq.gz,\n"
        )
    }

    func testSamplesheetWithoutTheRequiredColumnsIsRefused() throws {
        let sheet = root.appendingPathComponent("bad.csv")
        try "name,reads\nA,/data/A.fastq.gz\n".write(to: sheet, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try ViralReconReadPairing.parseIlluminaSamplesheet(at: sheet)) { error in
            guard case ViralReconReadPairing.PairingError.malformedSamplesheet = error else {
                return XCTFail("unexpected error \(error)")
            }
        }
    }

    func testDecisionsRoundTripThroughJSONAndProvenance() throws {
        let decision = ViralReconReadPairingDecision(
            sampleName: "S1",
            sourceFASTQURLs: [root.appendingPathComponent("S1.fastq.gz")],
            layout: .strictlyInterleaved,
            handling: .splitToR1R2,
            reason: "scan",
            pairCount: 12,
            splitR1URL: root.appendingPathComponent("S1_R1.fastq.gz"),
            splitR2URL: root.appendingPathComponent("S1_R2.fastq.gz")
        )
        let url = root.appendingPathComponent("inputs").appendingPathComponent(ViralReconReadPairing.decisionsFilename)

        try ViralReconReadPairing.writeDecisions([decision], to: url)

        XCTAssertEqual(ViralReconReadPairing.loadDecisions(from: url), [decision])
        guard case .dictionary(let fields) = decision.provenanceValue else { return XCTFail("expected a dictionary") }
        XCTAssertEqual(fields["readLayout"], .string("strictly_interleaved"))
        XCTAssertEqual(fields["handling"], .string("split_to_r1_r2"))
        XCTAssertEqual(fields["pairs"], .integer(12))
        XCTAssertEqual(fields["splitR2"], .file(root.appendingPathComponent("S1_R2.fastq.gz")))
    }

    func testRegistryDeclaresTheSplit() throws {
        let declaration = try XCTUnwrap(FASTQConsumerRegistry.declaration(for: ViralReconReadPairing.consumerID))
        XCTAssertEqual(declaration.handling(for: .strictlyInterleaved), .splitToR1R2)
        XCTAssertEqual(declaration.handling(for: .mixedMergedAndPairs), .asSingle)
        XCTAssertEqual(declaration.handling(for: .pairedFiles), .asPairs)
        XCTAssertEqual(declaration.handling(for: .singleEnd), .asSingle)
    }
}
