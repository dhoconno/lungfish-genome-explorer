// FASTQOperationCLIInvocationBuilderTests.swift - The argv and the record of the app's Merge Overlapping Pairs
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// MERGE-COUNTED-INVENTED-Q (S1). The dialog builds `.pairedEndMerge(strictness:minOverlap:)` and offers no
// choice about duplicates, yet the builder always appended `--count-duplicates`. The CLI then collapsed every
// output sequence, merged and unmerged alike, into one `u<number>;size=<reads>` record with a Q40 placeholder
// score on every base, and the unmerged mates lost their pairing. The person never chose any of that. The app
// argv is now `merge <in> --min-overlap <N> -o <out>`, plus `--strict` when chosen, and the parameters the
// request records say that nothing was counted. The CLI flag itself stays, off by default, and its tests are
// `CLICommandTests` and `FastqMergeProvenanceTests`. The cases here run no tool. The conformance class in
// `FASTQOperationCLIInvocationBuilderMergeConformanceTests` runs this argv through the real bbmerge.

import Foundation
import LungfishIO
import LungfishTestSupport
@testable import LungfishApp
@testable import LungfishCLI
import XCTest

final class FASTQOperationCLIInvocationBuilderTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("builder-merge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func mergeInvocation(
        _ request: FASTQDerivativeRequest,
        outputTargetPath: String = "<derived>"
    ) throws -> (invocation: FASTQCLIInvocation, input: URL) {
        let input = root.appendingPathComponent("pairs.fastq")
        try InterleavedFASTQFixture.write(pairCount: 2, naming: .casava, to: input)
        let launch = FASTQOperationLaunchRequest.derivative(
            request: request,
            inputURLs: [input],
            outputMode: .perInput
        )
        let invocation = try FASTQOperationCLIInvocationBuilder()
            .buildInvocation(for: launch, outputTargetPath: outputTargetPath)
        return (invocation, input)
    }

    /// The app never passes `--count-duplicates`. The argv is the input, the overlap and the output, and nothing
    /// else, so the output is bbmerge's own: merged reads with bbmerge's scores, then the unmerged pairs with
    /// the sequencer's scores and names.
    func testMergeArgvDoesNotCountDuplicates() throws {
        let (invocation, input) = try mergeInvocation(.pairedEndMerge(strictness: .normal, minOverlap: 12))

        XCTAssertEqual(invocation.subcommand, "fastq")
        XCTAssertFalse(
            invocation.arguments.contains("--count-duplicates"),
            "the app must not count duplicates after a merge: \(invocation.arguments)"
        )
        XCTAssertEqual(invocation.arguments.first, "merge")
        XCTAssertEqual(
            URL(fileURLWithPath: invocation.arguments[1]).lastPathComponent,
            input.lastPathComponent,
            "the second word is the input path"
        )
        XCTAssertEqual(
            Array(invocation.arguments.dropFirst(2)),
            ["--min-overlap", "12", "-o", "<derived>"],
            "the app argv is merge <in> --min-overlap <N> -o <out>"
        )
    }

    /// `--strict` is the only word the dialog's choice adds.
    func testStrictMergeArgvAddsOnlyStrict() throws {
        let (invocation, _) = try mergeInvocation(.pairedEndMerge(strictness: .strict, minOverlap: 20))

        XCTAssertFalse(invocation.arguments.contains("--count-duplicates"), "\(invocation.arguments)")
        XCTAssertEqual(invocation.arguments.first, "merge")
        XCTAssertEqual(
            Array(invocation.arguments.dropFirst(2)),
            ["--min-overlap", "20", "-o", "<derived>", "--strict"]
        )
    }

    /// The parameters the request records say what runs, which is no counting and no `size=` encoding. They
    /// used to say `true` and `size=N` for a step nobody chose.
    func testMergeRequestRecordsThatNothingWasCounted() {
        for strictness in [FASTQMergeStrictness.normal, .strict] {
            let parameters = FASTQDerivativeRequest.pairedEndMerge(strictness: strictness, minOverlap: 12).batchParameters
            XCTAssertEqual(parameters["countDuplicatesAfterMerge"], "false", "\(strictness)")
            XCTAssertEqual(parameters["duplicateCountEncoding"], "none", "\(strictness)")
            XCTAssertEqual(parameters["minOverlap"], "12", "\(strictness)")
            XCTAssertEqual(parameters["strictness"], "\(strictness)")
        }
    }
}
