// BlastVerifyDatabaseTests.swift - lungfish-cli blast verify searches core_nt when no database is named
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCLI
@testable import LungfishCore

/// Phase 3.2 lane KRAKENCORE, BIO R3 (BIO-BLAST-DATABASES items 3 and 6). `blast verify` has no `--database` option, so
/// nobody can name `nt` on its command line, and it must not send the shared default `nt`. Its request is the one the
/// Kraken 2 viewport's row repeats, so it asks for the database every other route asks for.
final class BlastVerifyDatabaseTests: XCTestCase {
    func testBlastVerifyRequestSearchesCoreNTWhenNoDatabaseIsNamed() throws {
        let command = try BlastCommand.VerifySubcommand.parse([
            "--kreport", "classification.kreport",
            "--source", "reads.fastq",
            "--kraken-output", "classification.kraken",
            "--taxid", "562",
        ])

        let request = try command.makeVerificationRequestForTesting(
            taxonName: "Escherichia coli",
            sequences: [("read1", "ACGT")]
        )

        XCTAssertEqual(request.database, BlastDatabaseID.coreNT.rawValue)
    }
}
