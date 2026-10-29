// ImportDatabaseIdentityRecordTests.swift - An imported classifier result says whether it names its database
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// DB-IDENTITY, Phase 3.1, BIO-DB-IDENTITY section 3 (Imports). An import has no run, so it has no database to cite.
// The Kraken2, EsViritu, TaxTriage and NAO-MGS results name no database, and the record says so in the status
// `notNamedBySource` and a note, instead of staying silent. A key the source does not state is left out, never set to
// `unknown`.

import Darwin
import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

final class ImportDatabaseIdentityRecordTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "import-database-identity").resolvingSymlinksInPath()
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    private var fixtures: URL {
        ProvenanceCompatCorpus.repositoryRoot.appendingPathComponent("Tests/Fixtures", isDirectory: true)
    }

    private var imports: URL { root.appendingPathComponent("imports", isDirectory: true) }

    /// The record of the import in `directory` says its source names no database, in the words the ruling gives.
    private func assertNamesNoDatabase(
        in directory: URL,
        tool: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let envelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: directory), "the import wrote no record", file: file, line: line)
        let resolved = envelope.options.resolvedDefaults
        XCTAssertEqual(resolved["databaseIdentityStatus"], .string("notNamedBySource"), file: file, line: line)
        XCTAssertEqual(
            resolved["databaseIdentityNote"],
            .string(
                "The \(tool) result names no database, so this record cannot name the release that made its calls. "
                    + "Cite it from the run that made the result."
            ),
            file: file,
            line: line
        )
        XCTAssertNil(resolved["databaseDigest"], "an import has no checksum to cite", file: file, line: line)
        XCTAssertNil(envelope.options.explicit["databaseIdentityStatus"], "a resolved default, not a chosen option", file: file, line: line)
    }

    /// Both import words read as statuses, and the five statuses are all there is.
    func testDatabaseIdentityStatusReadsImportWords() {
        XCTAssertEqual(DatabaseIdentityStatus(recordedWord: "namedBySource")?.rawValue, "namedBySource")
        XCTAssertEqual(DatabaseIdentityStatus(recordedWord: "notNamedBySource")?.rawValue, "notNamedBySource")
        XCTAssertEqual(DatabaseIdentityStatus.allCases.count, 5)
        XCTAssertEqual(DatabaseIdentityStatus(recordedWord: "unresolved-bounded-metadata"), .unpinned)
        XCTAssertEqual(DatabaseIdentityStatus(recordedWord: "provided-aggregate-digest"), .pinned)
        XCTAssertNil(DatabaseIdentityStatus(recordedWord: "unknown"), "CZ-ID's released word reads as nothing")
    }

    func testKraken2ImportRecordSaysSourceNamesNoDatabase() throws {
        let report = root.appendingPathComponent("input.kreport")
        try "0.00\t0\t0\tU\t0\tunclassified\n100.00\t10\t0\tR\t1\troot\n50.00\t5\t5\tS\t12345\t  Example species\n"
            .write(to: report, atomically: true, encoding: .utf8)

        let result = try MetagenomicsImportService.importKraken2(kreportURL: report, outputDirectory: imports)

        try assertNamesNoDatabase(in: result.resultDirectory, tool: "Kraken2")
    }

    func testEsVirituImportRecordSaysSourceNamesNoDatabase() throws {
        let result = try MetagenomicsImportService.importEsViritu(
            inputURL: fixtures.appendingPathComponent("esviritu-mini/SRR35517705", isDirectory: true),
            outputDirectory: imports
        )

        try assertNamesNoDatabase(in: result.resultDirectory, tool: "EsViritu")
    }

    func testTaxTriageImportRecordSaysSourceNamesNoDatabase() throws {
        let result = try MetagenomicsImportService.importTaxTriage(
            inputURL: fixtures.appendingPathComponent("taxtriage-mini", isDirectory: true),
            outputDirectory: imports
        )

        try assertNamesNoDatabase(in: result.resultDirectory, tool: "TaxTriage")
    }

    func testNaoMgsImportRecordSaysSourceNamesNoDatabase() async throws {
        let source = root.appendingPathComponent("virus_hits_final.tsv")
        try """
        sample\tseq_id\taligner_taxid_lca\tquery_seq\tquery_qual\tprim_align_genome_id_all\tprim_align_ref_start\tprim_align_cigar\tquery_len\tprim_align_edit_distance\tprim_align_query_rc
        SAMPLE_A\tread1\t111\tACGTACGT\tFFFFFFFF\tACCN0001\t10\t8M\t8\t0\tFalse
        SAMPLE_A\tread2\t111\tACGTACGA\tFFFFFFFF\tACCN0002\t20\t8M\t8\t1\tFalse
        SAMPLE_A\tread3\t222\tACGTACGG\tFFFFFFFF\tACCN0003\t30\t8M\t8\t0\tTrue
        """.write(to: source, atomically: true, encoding: .utf8)
        // A registry beside the output with a fixture taxdump keeps the taxonomy install off the network.
        let managed = root.appendingPathComponent("managed-databases", isDirectory: true)
        let registry = MetagenomicsDatabaseRegistry(
            baseDirectory: managed,
            catalog: MetagenomicsDatabaseInfo.builtInCatalog.filter { $0.tool == MetagenomicsTool.ncbiTaxonomy.rawValue },
            databaseInstaller: NCBITaxonomyFixture.installer(
                archive: managed.appendingPathComponent("taxdump.tar.gz"),
                scientificNames: [111: "Fixture virus alpha", 222: "Fixture virus beta"]
            )
        )

        let result = try await withNaoMgsImportLock {
            try await MetagenomicsImportService.importNaoMgs(
                inputURL: source,
                outputDirectory: imports,
                sampleName: "SAMPLE_A",
                minIdentity: 90,
                fetchReferences: false,
                preferredName: nil,
                taxonomyRegistry: registry,
                progress: nil
            )
        }

        try assertNamesNoDatabase(in: result.resultDirectory, tool: "NAO-MGS")
    }

    /// The same machine-wide lock `MetagenomicsImportServiceTests` takes around a NAO-MGS import.
    private func withNaoMgsImportLock<T>(_ body: () async throws -> T) async throws -> T {
        let lockURL = FileManager.default.temporaryDirectory.appendingPathComponent("lungfish-naomgs-import-tests.lock")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { flock(descriptor, LOCK_UN) }
        return try await body()
    }
}
