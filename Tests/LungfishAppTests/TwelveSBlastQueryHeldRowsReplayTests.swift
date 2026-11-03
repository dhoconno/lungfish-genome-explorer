// TwelveSBlastQueryHeldRowsReplayTests.swift - The real 12S export passes the check that holds a BLAST to the rows on screen
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.1 lane STALE12S, ruling BIO-12S-STALE-EXPORT Fix A. The check compares the query the export wrote with the
// rows the viewer holds, so a check that is too strict would refuse BLAST on every healthy result. This runs the route
// the viewer runs with the built lungfish-cli. The rows come from a real loadResult, the argv from
// twelveSUnresolvedExportArguments and the query from the real TwelveSBlastQuery.prepare. It stops before the plan, so
// nothing goes to NCBI. The table holds a chimera candidate, a lowercase sequence, a long sequence and a row under the
// minimum. It launches the built lungfish-cli, so its name ends in ReplayTests, which sends it to the integration tier.

import Foundation
import XCTest
@testable import LungfishApp
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
@testable import LungfishTwelveSUI

@MainActor
final class TwelveSBlastQueryHeldRowsReplayTests: XCTestCase {
    private var scratch: URL!
    private var saved: ProcessEnvironmentOverride?

    override func setUpWithError() throws {
        scratch = try TestTempDirectory.make(prefix: "twelve-s-held-rows")
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let cli = try XCTUnwrap(
            CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: products),
            "No lungfish-cli beside \(products.path) and none named by LUNGFISH_CLI_PATH, so the export cannot run"
        )
        saved = ProcessEnvironmentOverride(set: ["LUNGFISH_CLI_PATH": cli.path], unset: [])
    }

    override func tearDownWithError() throws {
        saved?.restore()
        TestTempDirectory.cleanup(scratch)
    }

    /// A healthy result is never refused. The check must allow the export's choices and nothing more, so the same
    /// query is refused against rows that differ in the case of one sequence.
    func testTheRealExportOfAHealthyResultPassesTheCheck() async throws {
        let bundle = scratch.appendingPathComponent("Project/Analyses/hilo.lungfish12s", isDirectory: true)
        try TwelveSResultExportCLIGUIParityReplayTests.writeBundle(at: bundle)
        let table = [
            "sequence_id\tsequence\tread_count\tsample_counts\tchimera_status\tnote",
            "unresolved_1\tACGTACGTAC\t12\tSampleA:12\tnot_detected\t",
            "unresolved_2\tTTTTCCCCTT\t8\tSampleA:8\tcandidate\t",
            "unresolved_3\tacgtacgtac\t6\tSampleA:6\tnot_detected\t",
            "unresolved_4\t\(String(repeating: "ACGTTGCA", count: 40))\t5\tSampleA:5\tnot_detected\t",
            "unresolved_5\tGGGGAAAA\t1\tSampleA:1\tnot_detected\t",
        ].joined(separator: "\n") + "\n"
        try table.write(to: bundle.appendingPathComponent("unresolved-sequences.tsv"), atomically: true, encoding: .utf8)

        let result = try TwelveSAmpliconResultBundle.loadResult(from: bundle)
        XCTAssertEqual(result.unresolvedSequences.count, 5)
        let request = TwelveSUnresolvedBlastRequest(
            bundleURL: bundle, minimumReads: 3, sequences: result.unresolvedSequences
        )
        let held = ViewerViewController.twelveSHeldRows(of: request)
        let expected = ["unresolved_1", "unresolved_2", "unresolved_3", "unresolved_4"]
        XCTAssertEqual(held.map(\.sequenceID).sorted(), expected, "the row under the minimum is not held")

        let exportURL = scratch.appendingPathComponent("lungfish-12s-blast-\(UUID().uuidString)/unresolved-min3.fasta")
        let arguments = ViewerViewController.twelveSUnresolvedExportArguments(
            bundleURL: bundle, minimumReads: 3, exportURL: exportURL, sequenceIDs: request.sequences.map(\.sequenceID)
        )
        let query = try await ViewerViewController.TwelveSBlastQuery.prepare(
            arguments: arguments, exportURL: exportURL, cancellation: LungfishCLIRunner.CancellationHandle()
        )

        XCTAssertEqual(query.map(\.id).sorted(), expected, "the export wrote the held rows and no other")
        XCTAssertTrue(
            ViewerViewController.twelveSBlastQuery(query, isHeldRows: held),
            "a healthy result is never refused"
        )
        let recased = held.map { row in
            row.sequenceID == "unresolved_3"
                ? TwelveSUnresolvedSequence(
                    sequenceID: "unresolved_3", sequence: "ACGTACGTAC", readCount: 6,
                    sampleCounts: ["SampleA": 6], chimeraStatus: .notDetected
                )
                : row
        }
        XCTAssertFalse(
            ViewerViewController.twelveSBlastQuery(query, isHeldRows: recased),
            "a sequence in another case is another sequence"
        )
        XCTAssertFalse(
            ViewerViewController.twelveSBlastQuery(query, isHeldRows: held.filter { $0.sequenceID != "unresolved_4" }),
            "a row missing from the held rows is refused"
        )
    }
}
