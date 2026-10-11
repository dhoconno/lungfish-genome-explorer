// BuildDbTextOutputPinTests.swift - What the three build-db leaves print in text mode
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCLI

/// What `build-db kraken2`, `esviritu` and `taxtriage` print in text mode, the mode the app runs them in
/// (`LungfishCLIRunner.buildClassifierDatabase`). The lines were captured at base `18e422c4f`, before
/// lane A7 retired the S14 progress shape, and text mode keeps them. Each run uses a fixture of
/// `BuildDbStreamCapture`, and the size a cleanup line reports is left out of the comparison.
final class BuildDbTextOutputPinTests: XCTestCase {
    func testKraken2PrintsTheBaseLines() async throws {
        let scratch = try ImportStreamCapture.Scratch()
        defer { scratch.remove() }
        let result = try BuildDbStreamCapture.kraken2Result(in: scratch)

        let output = try await BuildDbStreamCapture.run("build-db kraken2", result, in: scratch)

        XCTAssertNil(output.thrown)
        XCTAssertEqual(BuildDbStreamCapture.withoutFreedSize(output.standardOutput), [
            "Parsed 5294 classification rows from Kraken2 results",
            "Built database at /work/kraken2/kraken2.sqlite with 5294 rows",
            "Cleanup complete. Freed <size>",
        ])
        XCTAssertEqual(output.standardError, [])
    }

    func testEsVirituPrintsTheBaseLines() async throws {
        let scratch = try ImportStreamCapture.Scratch()
        defer { scratch.remove() }
        let result = try BuildDbStreamCapture.esVirituResultWithoutBAMs(in: scratch)

        let output = try await BuildDbStreamCapture.run("build-db esviritu", result, in: scratch)

        XCTAssertNil(output.thrown)
        XCTAssertEqual(BuildDbStreamCapture.withoutFreedSize(output.standardOutput), [
            "Parsed 19 detection rows from EsViritu results",
            "Parsed 4000 coverage windows from EsViritu results",
            "Built database at /work/esviritu/esviritu.sqlite with 19 rows",
            "  No rows with BAM paths found, skipping unique reads",
            "Cleanup complete. Freed <size>",
        ])
        XCTAssertEqual(output.standardError, [])
    }

    func testTaxTriagePrintsTheBaseLines() async throws {
        let scratch = try ImportStreamCapture.Scratch()
        defer { scratch.remove() }
        let result = try BuildDbStreamCapture.taxTriageResultWithoutBAMs(in: scratch)

        let output = try await BuildDbStreamCapture.run("build-db taxtriage", result, in: scratch)

        XCTAssertNil(output.thrown)
        XCTAssertEqual(BuildDbStreamCapture.withoutFreedSize(output.standardOutput), [
            "Parsed 15 taxonomy rows, 51 accession entries from confidence report",
            "Built database at /work/taxtriage/taxtriage.sqlite with 15 rows",
            "  No rows with BAM paths found, skipping unique reads",
            "Cleanup complete. Freed <size>",
        ])
        XCTAssertEqual(output.standardError, [])
    }

    /// A second run without `--force` keeps the database and says so.
    func testAnExistingDatabaseIsKeptWithTheBaseLine() async throws {
        let scratch = try ImportStreamCapture.Scratch()
        defer { scratch.remove() }
        let result = try BuildDbStreamCapture.kraken2Result(in: scratch)
        _ = try await BuildDbStreamCapture.run("build-db kraken2", result, ["--quiet"], in: scratch)

        let output = try await BuildDbStreamCapture.run("build-db kraken2", result, in: scratch)

        XCTAssertNil(output.thrown)
        XCTAssertEqual(output.standardOutput, [
            "Database already exists at /work/kraken2/kraken2.sqlite. Use --force to rebuild.",
        ])
        XCTAssertEqual(output.standardError, [])
    }

    /// `--quiet` prints nothing, on either stream.
    func testQuietPrintsNothing() async throws {
        let scratch = try ImportStreamCapture.Scratch()
        defer { scratch.remove() }
        let result = try BuildDbStreamCapture.esVirituResultWithoutBAMs(in: scratch)

        let output = try await BuildDbStreamCapture.run("build-db esviritu", result, ["--quiet"], in: scratch)

        XCTAssertNil(output.thrown)
        XCTAssertEqual(output.standardOutput, [])
        XCTAssertEqual(output.standardError, [])
    }
}
