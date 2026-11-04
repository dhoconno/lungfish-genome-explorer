// BuildDbMissingAccessionTests.swift - A BAM that lacks a row's accession leaves the row's parsed counts alone
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// ESVUNIQUE-BIO-2 Backlog 1 (S2). `samtools view -c <bam> <accession>` on an accession the BAM does not hold prints a
// warning that holds "unknown reference", prints 0 and exits 0. `build-db` took that 0 for a count and wrote `reads_aligned`
// (TaxTriage) or `read_count` (EsViritu) and `unique_reads` as 0 over the count the pipeline gave the row, so a detected
// virus showed no reads, silently. A count that cannot be made leaves the row as it was parsed: its own count and a NULL
// `unique_reads`. These tests run the real managed samtools, through a scratch home whose samtools is a link to the host's
// (a failure under LUNGFISH_REQUIRE_TOOLS=1 when the host has none).

import XCTest
import LungfishTestSupport
@testable import LungfishCLI
@testable import LungfishIO
@testable import LungfishWorkflow

final class BuildDbMissingAccessionTests: XCTestCase {
    private var root: URL!
    private var scratchHome: URL?

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "build-db-missing-accession")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
        if let scratchHome { try? FileManager.default.removeItem(at: scratchHome) }
    }

    /// A scratch home whose managed samtools is the host's real one, so the build writes nothing under the real home.
    private func homeWithRealSamtools() async throws -> URL {
        let real = try await ToolAvailability.require("samtools", environment: "samtools")
        let fixture = try ManagedSamtoolsHome.makeStub(namePrefix: "BuildDbMissingAccession")
        scratchHome = fixture.homeURL
        try FileManager.default.removeItem(at: fixture.samtoolsPath)
        try FileManager.default.createSymbolicLink(at: fixture.samtoolsPath, withDestinationURL: real)
        return fixture.homeURL
    }

    private func withHomeDirectory<T>(_ home: URL, perform block: () async throws -> T) async throws -> T {
        let originalHome = ProcessInfo.processInfo.environment["HOME"]
        setenv("HOME", home.path, 1)
        defer {
            if let originalHome {
                setenv("HOME", originalHome, 1)
            } else {
                unsetenv("HOME")
            }
        }
        return try await block()
    }

    /// A copy of the fixture, since the build marks duplicates in the BAMs it counts.
    private func copyOfFixture(_ name: String) throws -> URL {
        let destination = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.copyItem(at: BuildDbStreamCapture.fixturesFolder.appendingPathComponent(name, isDirectory: true), to: destination)
        return destination
    }

    /// Renames an accession in one table of the copy, so the row reads an accession that no BAM holds.
    private func rename(_ accession: String, to missing: String, in table: URL) throws {
        let text = try String(contentsOf: table, encoding: .utf8)
        XCTAssertTrue(text.contains(accession), "\(table.lastPathComponent) names \(accession)")
        try text.replacingOccurrences(of: accession, with: missing).write(to: table, atomically: true, encoding: .utf8)
    }

    /// The SARS-CoV-2 row of SRR35517702 is parsed with 31 reads and the accession NC_045512.2, which the sample's BAM holds.
    func testTaxTriageKeepsTheParsedCountOfARowWhoseAccessionTheBAMLacks() async throws {
        let home = try await homeWithRealSamtools()
        let result = try copyOfFixture("taxtriage-mini")
        try rename("NC_045512.2", to: "NO_SUCH.2", in: result.appendingPathComponent("combine/SRR35517702.combined.gcfmap.tsv"))

        try await withHomeDirectory(home) {
            let command = try BuildDbCommand.TaxTriageSubcommand.parse([result.path, "-q"])
            try await command.run()
        }

        let database = try TaxTriageDatabase(at: result.appendingPathComponent("taxtriage.sqlite"))
        let rows = try database.fetchRows(samples: ["SRR35517702"])
        let missing = try XCTUnwrap(rows.first { $0.organism.hasPrefix("Severe acute respiratory syndrome") })
        XCTAssertEqual(missing.primaryAccession, "NO_SUCH.2", "the row reads the accession that no BAM holds")
        XCTAssertEqual(missing.readsAligned, 31, "the count the pipeline gave the row stays")
        XCTAssertNil(missing.uniqueReads, "no count was made, so none is stored")
        XCTAssertTrue(
            rows.contains { $0.primaryAccession != "NO_SUCH.2" && $0.uniqueReads != nil },
            "the other rows of the same BAM are still counted"
        )
    }

    /// The Bocaparvovirus row of SRR35517702 is parsed with 2 reads and the accession NC_007455.1.
    func testEsVirituKeepsTheParsedCountOfARowWhoseAccessionTheBAMLacks() async throws {
        let home = try await homeWithRealSamtools()
        let result = try copyOfFixture("esviritu-mini")
        try rename("NC_007455.1", to: "NO_SUCH.1", in: result.appendingPathComponent("SRR35517702/SRR35517702.detected_virus.info.tsv"))

        try await withHomeDirectory(home) {
            let command = try BuildDbCommand.EsVirituSubcommand.parse([result.path, "-q"])
            try await command.run()
        }

        let database = try EsVirituDatabase(at: result.appendingPathComponent("esviritu.sqlite"))
        let rows = try database.fetchRows(samples: ["SRR35517702"])
        let missing = try XCTUnwrap(rows.first { $0.accession == "NO_SUCH.1" })
        XCTAssertEqual(missing.readCount, 2, "the count EsViritu gave the row stays")
        XCTAssertNil(missing.uniqueReads, "no count was made, so none is stored")
        XCTAssertTrue(
            rows.contains { $0.accession != "NO_SUCH.1" && $0.uniqueReads != nil },
            "the other rows of the same BAM are still counted"
        )
    }
}
