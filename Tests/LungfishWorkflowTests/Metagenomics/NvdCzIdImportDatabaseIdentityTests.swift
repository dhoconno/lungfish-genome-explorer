// NvdCzIdImportDatabaseIdentityTests.swift - The NVD and CZ-ID imports name the database versions their results state
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// DB-IDENTITY, Phase 3.1, BIO-DB-IDENTITY section 3 (Imports). NVD states its BLAST and STAT database versions in every
// row of its result, and CZ-ID states its NT and NR versions in the header of its report. Neither states a checksum, so
// the record names the versions as the source states them, says `namedBySource`, and says in a note that no checksum was
// stated. A mixed NVD import never reads as one release.

import XCTest
import LungfishTestSupport
@testable import LungfishWorkflow

final class NvdCzIdImportDatabaseIdentityTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "nvd-czid-database-identity").resolvingSymlinksInPath()
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    /// The NVD run directory `MetagenomicsImportServiceTests` imports, with the one row of its CSV, whose rows state the
    /// BLAST database `nt-2026` and the STAT database `stat-1`.
    private func makeNvdRunDirectory() throws -> URL {
        let nvdDir = root.appendingPathComponent("nvd-run", isDirectory: true)
        let labkeyDir = nvdDir.appendingPathComponent("05_labkey_bundling", isDirectory: true)
        let humanVirusDir = nvdDir
            .appendingPathComponent("02_human_viruses", isDirectory: true)
            .appendingPathComponent("03_human_virus_results", isDirectory: true)
        let mappedReadsDir = humanVirusDir.appendingPathComponent("mapped_reads", isDirectory: true)
        try FileManager.default.createDirectory(at: labkeyDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: mappedReadsDir, withIntermediateDirectories: true)
        let header = "experiment,blast_task,sample_id,qseqid,qlen,sseqid,stitle,tax_rank,length,pident,evalue,bitscore,"
            + "sscinames,staxids,blast_db_version,snakemake_run_id,mapped_reads,total_reads,stat_db_version,"
            + "adjusted_taxid,adjustment_method,adjusted_taxid_name,adjusted_taxid_rank"
        let row = "EXP001,blastn,S1,contig-1,120,gb|NC_001|,Example virus species,S,118,99.2,1e-20,250.5,Example virus,"
            + "12345,nt-2026,run-001,42,100000,stat-1,12345,unchanged,Example virus,species"
        try "\(header)\n\(row)\n".write(
            to: labkeyDir.appendingPathComponent("sample_blast_concatenated.csv"), atomically: true, encoding: .utf8
        )
        try "synthetic bam payload\n".write(
            to: mappedReadsDir.appendingPathComponent("S1.filtered.bam"), atomically: true, encoding: .utf8
        )
        try "synthetic bai payload\n".write(
            to: mappedReadsDir.appendingPathComponent("S1.filtered.bam.bai"), atomically: true, encoding: .utf8
        )
        try ">contig-1\nACGTACGT\n".write(
            to: humanVirusDir.appendingPathComponent("S1.human_virus.fasta"), atomically: true, encoding: .utf8
        )
        return nvdDir
    }

    /// The record names the BLAST and STAT versions the rows state, as one string when every row agrees, and says the
    /// source named them with no checksum.
    func testNvdImportRecordNamesBlastAndStatVersions() async throws {
        let result = try await MetagenomicsImportService.importNvd(
            inputURL: try makeNvdRunDirectory(),
            outputDirectory: root.appendingPathComponent("imports", isDirectory: true),
            samtoolsPath: nil
        )

        let envelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: result.resultDirectory), "the import wrote no record")
        let resolved = envelope.options.resolvedDefaults
        XCTAssertEqual(resolved["blastDatabaseVersion"], .string("nt-2026"))
        XCTAssertEqual(resolved["statDatabaseVersion"], .string("stat-1"))
        XCTAssertEqual(resolved["databaseIdentityStatus"], .string("namedBySource"))
        XCTAssertEqual(
            resolved["databaseIdentityNote"],
            .string("The NVD result states its BLAST and STAT database versions and no checksum.")
        )
        XCTAssertNil(resolved["databaseDigest"], "an import has no checksum to cite")
    }

    /// The record keeps CZ-ID's three released keys and adds the status and the note.
    func testCzIdImportRecordNamesSourceVersions() throws {
        let fixture = ProvenanceCompatCorpus.repositoryRoot.appendingPathComponent("Tests/Fixtures/czid/minimal_taxon_report.tsv")
        let output = root.appendingPathComponent("czid", isDirectory: true)

        _ = try CzIdDataConverter.convertTaxonReport(at: fixture, outputDirectory: output)

        let envelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: output), "the import wrote no record")
        let resolved = envelope.options.resolvedDefaults
        XCTAssertEqual(resolved["pipelineVersion"], .string("8.4"))
        XCTAssertEqual(resolved["ntDatabaseVersion"], .string("nt_2025_12_01"))
        XCTAssertEqual(resolved["nrDatabaseVersion"], .string("nr_2025_12_01"))
        XCTAssertEqual(resolved["databaseIdentityStatus"], .string("namedBySource"))
        XCTAssertEqual(
            resolved["databaseIdentityNote"],
            .string("The CZ-ID result states its NT and NR database versions and no checksum.")
        )
        XCTAssertNil(resolved["databaseDigest"], "an import has no checksum to cite")
    }

    /// A mixed NVD import never reads as one release. Rows that agree read as one string, rows that differ as the sorted
    /// distinct values, and rows that state no version name no database.
    func testNvdVersionsAgreeAsOneStringAndDifferAsASortedArray() {
        let mixed = MetagenomicsImportDatabaseIdentity.nvd(
            versions: [("nt-2026", "stat-1"), ("nt-2025", "stat-1"), ("nt-2026", "stat-1")], adding: [:]
        )
        XCTAssertEqual(mixed["blastDatabaseVersion"], .array([.string("nt-2025"), .string("nt-2026")]))
        XCTAssertEqual(mixed["statDatabaseVersion"], .string("stat-1"))
        XCTAssertEqual(mixed["databaseIdentityStatus"], .string("namedBySource"))

        let silent = MetagenomicsImportDatabaseIdentity.nvd(versions: [("", ""), (" ", "")], adding: ["hitCount": .integer(2)])
        XCTAssertNil(silent["blastDatabaseVersion"], "a version the source does not state is left out, never unknown")
        XCTAssertNil(silent["statDatabaseVersion"])
        XCTAssertEqual(silent["hitCount"], .integer(2), "the import's own keys stay")
        XCTAssertEqual(silent["databaseIdentityStatus"], .string("notNamedBySource"))
        XCTAssertEqual(
            silent["databaseIdentityNote"],
            .string(
                "The NVD result names no database, so this record cannot name the release that made its calls. "
                    + "Cite it from the run that made the result."
            )
        )
    }

    /// A CZ-ID report that names neither version names no database, and the released `unknown` stays as it was.
    func testCzIdReportThatNamesNoVersionIsNotNamedBySource() {
        let silent = MetagenomicsImportDatabaseIdentity.czId(
            ntVersion: nil, nrVersion: "unknown", adding: ["ntDatabaseVersion": .string("unknown")]
        )
        XCTAssertEqual(silent["databaseIdentityStatus"], .string("notNamedBySource"))
        XCTAssertEqual(silent["ntDatabaseVersion"], .string("unknown"), "the released key keeps its value")
        let named = MetagenomicsImportDatabaseIdentity.czId(ntVersion: "nt_2025_12_01", nrVersion: nil, adding: [:])
        XCTAssertEqual(named["databaseIdentityStatus"], .string("namedBySource"))
    }
}
