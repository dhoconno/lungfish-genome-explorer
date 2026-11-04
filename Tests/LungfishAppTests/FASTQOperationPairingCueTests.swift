// FASTQOperationPairingCueTests.swift - The FASTQ operations dialog reads no whole file on the main actor
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
import LungfishIO
import LungfishTestSupport

/// Row READ-LAYOUT-PARTIAL-SCAN, item 11. `pairingArguments(for:verifiedAgainst:metadataFrom:)` builds the dialog's
/// command on the main actor. Red at the lane's head, where it read the whole file and named a pairing.
final class FASTQOperationPairingCueTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "pairing-cue")
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    func testALongFileWithNoCountNamesNoPairing() throws {
        let input = root.appendingPathComponent("long.fastq")
        try FASTQLayoutRecordFixtures.write([.pairs(70_000)], to: input)

        let arguments = FASTQOperationCLIInvocationBuilder.pairingArguments(
            for: .interleaved, verifiedAgainst: input, metadataFrom: nil)

        XCTAssertEqual(arguments, [], "the command decides when it runs")
    }

    func testAShortFileIsReadWholeAndNamesItsPairing() throws {
        let input = root.appendingPathComponent("short.fastq")
        try FASTQLayoutRecordFixtures.write([.pairs(40)], to: input)

        let arguments = FASTQOperationCLIInvocationBuilder.pairingArguments(
            for: .interleaved, verifiedAgainst: input, metadataFrom: nil)

        XCTAssertEqual(arguments, ["--pairing", "interleaved"])
    }
}
