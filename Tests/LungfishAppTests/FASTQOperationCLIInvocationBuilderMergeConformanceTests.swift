// FASTQOperationCLIInvocationBuilderMergeConformanceTests.swift - The app's merge argv through the real bbmerge
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// MERGE-COUNTED-INVENTED-Q (S1). The argv comes from `FASTQOperationCLIInvocationBuilder`, the code the dialog
// uses, and runs through `FastqMergeSubcommand` in this process with the managed bbmerge on the five-pair
// fixture of `Tests/Fixtures/merge-uncounted`. The expected numbers are what bbmerge gives on that file when it
// is run directly (`bbmerge.sh in=fixture.fastq out=merged.fastq outu=unmerged.fastq minoverlap=12
// interleaved=t qin=33 qout=33`, the argument list the CLI records). With the old argv the file held 6 records,
// no mate pairs, and Q40 on every base (mean Q 40.00). It sits in this target because the builder is in
// LungfishApp, which LungfishCLITests does not import. The default-tier cases of the argv are in
// `FASTQOperationCLIInvocationBuilderTests`. The test skips where bbmerge is missing and fails under
// LUNGFISH_REQUIRE_TOOLS=1.

import Foundation
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishApp
@testable import LungfishCLI
import XCTest

final class FASTQOperationCLIInvocationBuilderMergeConformanceTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("builder-merge-conformance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private struct Record {
        let header: String
        let quality: String

        /// The first token of the header, the part a mate pair shares.
        var name: String { String(header.split(separator: " ").first ?? "") }
        var mateTag: String { header.split(separator: " ").dropFirst().first.map(String.init) ?? "" }
    }

    private static var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/merge-uncounted/fixture.fastq")
    }

    private static func records(of url: URL) throws -> [Record] {
        let lines = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        XCTAssertEqual(lines.count % 4, 0, "a FASTQ file holds four lines a record")
        return stride(from: 0, to: lines.count - 3, by: 4).map {
            Record(header: String(lines[$0].dropFirst()), quality: lines[$0 + 3])
        }
    }

    /// The app's Merge Overlapping Pairs on the fixture writes what bbmerge writes. The merged reads keep
    /// bbmerge's scores, the two pairs that cannot merge stay adjacent mates with the sequencer's scores and
    /// names, and the file reads as the scores it was given, never as Q40.
    func testAppMergeArgvKeepsBBMergeScoresAndPairs() async throws {
        guard await NativeToolRunner.shared.isToolAvailable(.bbmerge) else {
            try ToolAvailability.skipOrFail("bbmerge is not available in this test environment")
        }
        let input = root.appendingPathComponent("fixture.fastq")
        try FileManager.default.copyItem(at: Self.fixtureURL, to: input)
        let output = root.appendingPathComponent("merged.fastq")

        // The argv the app runs (`lungfish-cli fastq <arguments>`), from the builder the dialog uses.
        let launch = FASTQOperationLaunchRequest.derivative(
            request: .pairedEndMerge(strictness: .normal, minOverlap: 12),
            inputURLs: [input],
            outputMode: .perInput
        )
        let invocation = try FASTQOperationCLIInvocationBuilder()
            .buildInvocation(for: launch, outputTargetPath: output.path)
        XCTAssertEqual(invocation.subcommand, "fastq")
        XCTAssertEqual(invocation.arguments.first, "merge")

        // `FastqMergeSubcommand` is the `merge` of `lungfish-cli fastq merge`, so it parses what follows the name.
        try await FastqMergeSubcommand.parse(Array(invocation.arguments.dropFirst())).run()

        let records = try Self.records(of: output)
        XCTAssertEqual(records.count, 7, "3 merged reads and 2 unmerged pairs: \(records.map(\.header))")
        guard records.count == 7 else { return }

        // The merged reads come first, the unmerged pairs follow as adjacent mates.
        XCTAssertEqual(Set(records.prefix(3).map(\.name)), ["p1", "p2", "p3"])
        XCTAssertEqual(records.suffix(4).map(\.name), ["p4", "p4", "p5", "p5"], "the unmerged mates stay adjacent pairs")
        XCTAssertEqual(records.suffix(4).map(\.mateTag), ["1:N:0:1", "2:N:0:1", "1:N:0:1", "2:N:0:1"])
        XCTAssertFalse(
            records.contains { $0.header.contains("size=") || $0.header.hasPrefix("u0") },
            "no record is a counted copy: \(records.map(\.header))"
        )

        // bbmerge's own quality line for the p1 merge (mean Q 29.83), not a Q40 placeholder.
        let p1 = try XCTUnwrap(records.first { $0.name == "p1" })
        XCTAssertEqual(p1.quality, "GGFFEEDDCCBBAA@@??>>CCBBAA@@@@????????>>::::::::::::::::::::")

        // The scores of the whole file, as the app's statistics read them.
        let scores = records.flatMap { $0.quality.utf8.map { Int($0) - 33 } }
        XCTAssertEqual(scores.count, 340, "180 merged bases and 160 unmerged bases")
        let total = Double(scores.count)
        XCTAssertEqual(Double(scores.reduce(0, +)) / total, 20.68, accuracy: 0.005, "mean Q")
        XCTAssertEqual(100 * Double(scores.filter { $0 >= 20 }.count) / total, 64.7, accuracy: 0.05, "Q20 share")
        XCTAssertEqual(100 * Double(scores.filter { $0 >= 30 }.count) / total, 28.2, accuracy: 0.05, "Q30 share")
    }
}
