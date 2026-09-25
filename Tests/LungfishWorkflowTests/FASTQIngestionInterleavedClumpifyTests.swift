// FASTQIngestionInterleavedClumpifyTests.swift - Storage clumpify keeps interleaved mates together
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Regression for 2026-09-25: an interleaved single-file import ran
// `clumpify.sh` with no `interleaved=` flag. BBTools does not recognise mates
// that share one identical name (SRA dumps: `@SRR12486983.1 SRR12486983.1`
// twice), so clumpify sorted each read on its own and split ~all pairs. When
// it did recognise `/1` `/2` or Casava names it paired by position, and a
// file with an odd record count silently lost its last read.

import XCTest
@testable import LungfishWorkflow
import LungfishIO
import LungfishTestSupport

final class FASTQIngestionInterleavedClumpifyTests: XCTestCase {

    // MARK: - argv (always runs)

    private let input = URL(fileURLWithPath: "/data/in.fastq")
    private let input2 = URL(fileURLWithPath: "/data/in_R2.fastq")
    private let output = URL(fileURLWithPath: "/data/out.fastq.gz")

    private func interleavedFlags(_ args: [String]) -> [String] {
        args.filter { $0.hasPrefix("interleaved=") || $0.hasPrefix("int=") }
    }

    func testInterleavedSingleFileStatesInterleavedTrue() {
        let args = FASTQIngestionPipeline.clumpifyArguments(
            input: input, output: output, interleaved: true,
            heapGB: 4, threads: 2, qualityBinning: .none
        )
        XCTAssertEqual(interleavedFlags(args), ["interleaved=t"])
        XCTAssertFalse(args.contains { $0.hasPrefix("in2=") })
        XCTAssertEqual(Array(args.prefix(2)), ["in=/data/in.fastq", "out=/data/out.fastq.gz"])
        XCTAssertTrue(args.contains("reorder"))
    }

    func testUnpairedSingleFileStatesInterleavedFalse() {
        let args = FASTQIngestionPipeline.clumpifyArguments(
            input: input, output: output, interleaved: false,
            heapGB: 4, threads: 2, qualityBinning: .illumina4
        )
        XCTAssertEqual(interleavedFlags(args), ["interleaved=f"])
        XCTAssertEqual(args.last, "quantize=0,8,13,22,27,32,37")
    }

    func testPairedFilesPassIn2AndInterleavedTrue() {
        // A second file always means interleaved output, whatever the caller says.
        let args = FASTQIngestionPipeline.clumpifyArguments(
            input: input, input2: input2, output: output, interleaved: false,
            heapGB: 4, threads: 2, qualityBinning: .none
        )
        XCTAssertTrue(args.contains("in=/data/in.fastq"))
        XCTAssertTrue(args.contains("in2=/data/in_R2.fastq"))
        XCTAssertEqual(interleavedFlags(args), ["interleaved=t"])
    }

    func testPlanFollowsTheRecordsByName() {
        typealias Counts = FASTQPairInterleaver.MixedCounts
        XCTAssertEqual(FASTQIngestionPipeline.singleFileClumpPlan(for: Counts(pairs: 0, unpaired: 7)), .unpaired)
        XCTAssertEqual(FASTQIngestionPipeline.singleFileClumpPlan(for: Counts(pairs: 0, unpaired: 0)), .unpaired)
        XCTAssertEqual(FASTQIngestionPipeline.singleFileClumpPlan(for: Counts(pairs: 5, unpaired: 0)), .interleaved)
        XCTAssertEqual(FASTQIngestionPipeline.singleFileClumpPlan(for: Counts(pairs: 5, unpaired: 1)), .splitMixed)
    }

    func testCountMixedRecognisesEveryMateNamingStyle() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        for style in NamingStyle.allCases {
            let url = root.appendingPathComponent("\(style).fastq")
            try writeInterleaved(style: style, pairCount: 12, to: url)
            XCTAssertEqual(
                try FASTQPairInterleaver.countMixed(interleaved: url),
                FASTQPairInterleaver.MixedCounts(pairs: 12, unpaired: 0),
                "\(style)"
            )
        }
        let mixed = root.appendingPathComponent("mixed.fastq")
        try InterleavedFASTQFixture.writeMixed(pairCount: 6, mergedCount: 3, naming: .identical, to: mixed)
        XCTAssertEqual(
            try FASTQPairInterleaver.countMixed(interleaved: mixed),
            FASTQPairInterleaver.MixedCounts(pairs: 6, unpaired: 3)
        )
    }

    // MARK: - Managed clumpify (skips cleanly without BBTools)

    func testClumpifyKeepsMatesAdjacentForEveryNamingStyle() async throws {
        try await requireTools(.clumpify)
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        for style in NamingStyle.allCases {
            for pairing in [FASTQIngestionConfig.PairingMode.interleaved, .singleEnd] {
                let label = "\(style)-\(pairing.rawValue)"
                let inputURL = root.appendingPathComponent("\(label).fastq")
                try writeInterleaved(style: style, pairCount: 400, to: inputURL)
                let before = try await InterleavedFASTQFixture.readRecords(at: inputURL)

                let result = try await runPipeline(input: inputURL, pairing: pairing, root: root, label: label)
                let after = try await InterleavedFASTQFixture.readRecords(at: result.outputFile)

                XCTAssertEqual(after.count, before.count, label)
                InterleavedFASTQFixture.assertWholePairs(after, label)
                XCTAssertEqual(pairTuples(after), pairTuples(before), label)
                XCTAssertNotEqual(after.map(\.sequence), before.map(\.sequence), "clumpify should reorder duplicates (\(label))")
                XCTAssertTrue(result.processingCommandLine?.contains("interleaved=t") == true, label)
            }
        }
    }

    func testClumpifyKeepsEveryReadOfAMixedOrOddFile() async throws {
        try await requireTools(.clumpify)
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        // Odd count: before the fix BBTools paired /1 /2 by position and
        // dropped the last read. Mixed: pairs plus merged reads (VSP2 output).
        for mergedCount in [1, 51] {
            let label = "mixed-\(mergedCount)"
            let inputURL = root.appendingPathComponent("\(label).fastq")
            try InterleavedFASTQFixture.writeMixed(
                pairCount: 200,
                mergedCount: mergedCount,
                naming: .slashSuffix,
                sequences: Self.duplicatedPairs,
                to: inputURL
            )
            let before = try await InterleavedFASTQFixture.readRecords(at: inputURL)

            let result = try await runPipeline(input: inputURL, pairing: .interleaved, root: root, label: label)
            let after = try await InterleavedFASTQFixture.readRecords(at: result.outputFile)

            XCTAssertEqual(after.count, before.count, label)
            XCTAssertEqual(
                after.map(\.sequence).sorted(), before.map(\.sequence).sorted(),
                "every read must survive (\(label))"
            )
            InterleavedFASTQFixture.assertMixedIntegrity(after, label)
            XCTAssertTrue(result.processingCommandLine?.contains("interleaved=t") == true, label)
            XCTAssertTrue(result.processingCommandLine?.contains("interleaved=f") == true, label)
        }
    }

    func testQuantizeWithoutClumpingKeepsTheLastReadOfAnOddFile() async throws {
        try await requireTools(.reformat)
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let inputURL = root.appendingPathComponent("odd.fastq")
        try InterleavedFASTQFixture.writeMixed(pairCount: 50, mergedCount: 1, naming: .casava, to: inputURL)
        let before = try await InterleavedFASTQFixture.readRecords(at: inputURL)

        let result = try await FASTQIngestionPipeline().run(
            config: FASTQIngestionConfig(
                inputFiles: [inputURL],
                pairingMode: .interleaved,
                outputDirectory: root.appendingPathComponent("odd-out", isDirectory: true),
                threads: 1,
                deleteOriginals: false,
                qualityBinning: .illumina4,
                clumpingTool: ClumpingTool.none
            ),
            progress: { _, _ in }
        )
        let after = try await InterleavedFASTQFixture.readRecords(at: result.outputFile)
        XCTAssertEqual(after.count, before.count)
        XCTAssertEqual(after.map(\.identifier), before.map(\.identifier))
        XCTAssertTrue(result.processingCommandLine?.contains("interleaved=f") == true)
    }

    // MARK: - Helpers

    /// Mate naming styles seen in real interleaved files.
    enum NamingStyle: CaseIterable {
        case slash        // @frag1/1, @frag1/2
        case casava       // @M00:1:FC:1:1101:1:2 1:N:0:1, ... 2:N:0:1
        case sraIdentical // @SRR12486983.1 SRR12486983.1 twice
        case bareIdentical // @frag1 twice

        func headers(_ index: Int) -> (String, String) {
            switch self {
            case .slash: return ("frag\(index)/1", "frag\(index)/2")
            case .casava:
                let id = "M00:1:FC:1:1101:\(1000 + index):\(2000 + index)"
                return ("\(id) 1:N:0:1", "\(id) 2:N:0:1")
            case .sraIdentical:
                let id = "SRR12486983.\(index + 1)"
                return ("\(id) \(id)", "\(id) \(id)")
            case .bareIdentical: return ("frag\(index)", "frag\(index)")
            }
        }
    }

    /// 150-base mates where only 40 fragments are distinct, so clumpify has
    /// duplicates to gather and must move records.
    static let duplicatedPairs: InterleavedFASTQFixture.PairSequences = { index in
        let fragment = UInt64(index % 40)
        return (
            InterleavedFASTQFixture.deterministicSequence(seed: fragment * 2 + 1, length: 150),
            InterleavedFASTQFixture.deterministicSequence(seed: fragment * 2 + 2, length: 150)
        )
    }

    private func writeInterleaved(style: NamingStyle, pairCount: Int, to url: URL) throws {
        var text = ""
        for index in 0..<pairCount {
            let (h1, h2) = style.headers(index)
            let (s1, s2) = Self.duplicatedPairs(index)
            for (header, sequence) in [(h1, s1), (h2, s2)] {
                text += "@\(header)\n\(sequence)\n+\n\(String(repeating: "I", count: sequence.count))\n"
            }
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func pairTuples(_ records: [FASTQRecord]) -> [String] {
        stride(from: 0, to: records.count - 1, by: 2)
            .map { records[$0].sequence + "|" + records[$0 + 1].sequence }
            .sorted()
    }

    private func runPipeline(
        input: URL,
        pairing: FASTQIngestionConfig.PairingMode,
        root: URL,
        label: String
    ) async throws -> FASTQIngestionResult {
        try await FASTQIngestionPipeline().run(
            config: FASTQIngestionConfig(
                inputFiles: [input],
                pairingMode: pairing,
                outputDirectory: root.appendingPathComponent("\(label)-out", isDirectory: true),
                threads: 2,
                deleteOriginals: false,
                clumpingTool: .bbtools
            ),
            progress: { _, _ in }
        )
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("InterleavedClumpify-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func requireTools(_ tool: NativeTool) async throws {
        let runner = NativeToolRunner.shared
        guard (try? await runner.toolPath(for: tool)) != nil else {
            try ToolAvailability.skipOrFail("Managed \(tool.rawValue) is not available")
        }
        let hasBgzip = (try? await runner.toolPath(for: .bgzip)) != nil
        let hasPigz = (try? await runner.toolPath(for: .pigz)) != nil
        guard hasBgzip || hasPigz else {
            try ToolAvailability.skipOrFail("Neither managed bgzip nor pigz is available")
        }
    }
}
