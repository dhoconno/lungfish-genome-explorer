// BuildDbTextOutputPinTests.swift - What the three build-db leaves print in text mode
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCLI

/// What `build-db kraken2`, `esviritu` and `taxtriage` print in text mode, the mode the app runs them in
/// (`LungfishCLIRunner.buildClassifierDatabase`). The lines were captured at base `18e422c4f`, before
/// lane A7 retired the S14 progress shape, and text mode keeps them. Phase 2.10 lane U34 changed two of
/// the words (W4). `Cleanup complete. Freed <size>` became `Removed intermediate files (<size>).`, which a
/// cleanup that removed nothing does not print, and `Built database at <path> with N rows` became
/// `Built <file name> with N rows.`, each count noun following its count. Each run uses a fixture of
/// `BuildDbStreamCapture`, and the size a cleanup line reports is left out of the comparison.
final class BuildDbTextOutputPinTests: XCTestCase {
    /// The line that ends a run names the file and not its path, and a count of one reads in the singular.
    func testTheBuiltLineNamesTheFileAndFollowsItsCount() {
        let folder = URL(fileURLWithPath: "/work/esviritu", isDirectory: true)
        let database = folder.appendingPathComponent("esviritu.sqlite")
        XCTAssertEqual(BuildDbRunResult(databaseURL: database, rowCount: 19, record: nil).summary, "Built esviritu.sqlite with 19 rows.")
        XCTAssertEqual(BuildDbRunResult(databaseURL: database, rowCount: 1, record: nil).summary, "Built esviritu.sqlite with 1 row.")
        XCTAssertEqual(BuildDbRunResult(databaseURL: database, rowCount: 0, record: nil).summary, "Built esviritu.sqlite with 0 rows.")
    }


    func testKraken2PrintsTheBaseLines() async throws {
        let scratch = try ImportStreamCapture.Scratch()
        defer { scratch.remove() }
        let result = try BuildDbStreamCapture.kraken2Result(in: scratch)

        let output = try await BuildDbStreamCapture.run("build-db kraken2", result, in: scratch)

        XCTAssertNil(output.thrown)
        XCTAssertEqual(BuildDbStreamCapture.withoutFreedSize(output.standardOutput), [
            "Parsed 5294 classification rows from Kraken2 results",
            "Built kraken2.sqlite with 5294 rows.",
            "Removed intermediate files (<size>).",
        ])
        XCTAssertEqual(output.standardError, [])
    }

    /// The fixture holds no `<sample>_temp` folder, so its cleanup removes nothing and prints no line, where it
    /// once read `Cleanup complete. Freed Zero KB`.
    func testEsVirituPrintsTheBaseLines() async throws {
        let scratch = try ImportStreamCapture.Scratch()
        defer { scratch.remove() }
        let result = try BuildDbStreamCapture.esVirituResultWithoutBAMs(in: scratch)

        let output = try await BuildDbStreamCapture.run("build-db esviritu", result, in: scratch)

        XCTAssertNil(output.thrown)
        XCTAssertEqual(BuildDbStreamCapture.withoutFreedSize(output.standardOutput), [
            "Parsed 19 detection rows from EsViritu results",
            "Parsed 4000 coverage windows from EsViritu results",
            "Built esviritu.sqlite with 19 rows.",
            "  No rows with BAM paths found, skipping unique reads",
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
            "Built taxtriage.sqlite with 15 rows.",
            "  No rows with BAM paths found, skipping unique reads",
            "Removed intermediate files (<size>).",
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
