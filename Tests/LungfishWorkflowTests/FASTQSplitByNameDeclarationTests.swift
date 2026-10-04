// FASTQSplitByNameDeclarationTests.swift - Operations that split a mixed file by name declare it
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The FASTQ operations that partition a mixed file by fragment name, run its
// pairs in the tool's paired mode and its single reads in its single mode,
// and join the two outputs declare that handling in FASTQConsumerRegistry and
// the matching capability in ReadPairingCapabilityRegistry, so the contract
// table in docs/contracts/READ-PAIRING.md and the code agree (lane A8).

import XCTest
import LungfishIO
@testable import LungfishWorkflow

final class FASTQSplitByNameDeclarationTests: XCTestCase {

    private func assertSplitsByName(_ consumerID: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let declaration = try XCTUnwrap(FASTQConsumerRegistry.declaration(for: consumerID), file: file, line: line)
        XCTAssertEqual(declaration.handling(for: .singleEnd), .asSingle, consumerID, file: file, line: line)
        XCTAssertEqual(declaration.handling(for: .strictlyInterleaved), .asPairs, consumerID, file: file, line: line)
        XCTAssertEqual(declaration.handling(for: .mixedMergedAndPairs), .asPairs, consumerID, file: file, line: line)
        XCTAssertEqual(declaration.handling(for: .pairedFiles), .asSingle, consumerID, file: file, line: line)
        XCTAssertTrue(declaration.mixedHandlingIsGraceful, consumerID, file: file, line: line)
        XCTAssertTrue(declaration.mixedRationale.contains("partitioned by name"), declaration.mixedRationale, file: file, line: line)
        XCTAssertEqual(
            ReadPairingCapabilityRegistry.capability(for: consumerID),
            .bothInOneRunAsNameInterleavedStream,
            consumerID,
            file: file,
            line: line
        )
    }

    /// clumpify dedupe ran a mixed file as single reads, which separated
    /// every surviving mate from its partner.
    func testDeduplicateSplitsAMixedFileByName() throws {
        try assertSplitsByName("fastq.deduplicate")
    }

    /// bbduk and cutadapt judged every record on their own, so a mate the
    /// trim dropped orphaned its partner.
    func testPrimerRemovalRunsPairedAndSplitsAMixedFileByName() throws {
        try assertSplitsByName("fastq.primer-remove")
    }
}
