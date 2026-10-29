// ProvenanceInspectorDatabaseIdentityTests.swift - The Provenance tab shows the database identity words of a record
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// DB-IDENTITY, Phase 3.1, BIO-DB-IDENTITY section 3. The tab shows `databaseDigest`, `databaseIdentityStatus` and
// `databaseIdentityNote` as Resolved Default rows, so a reader sees the release of the database and the checksum the
// run cited, or the words that say the result named no database. The EsViritu record is the one an EsViritu run with an
// install receipt files (`EsVirituDatabaseIdentityRecordTests` pins those words against the writer in the CLI target,
// which the App target cannot reach). The NAO-MGS and CZ-ID records are real imports.

import Foundation
import XCTest
@testable import LungfishApp
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

@MainActor
final class ProvenanceInspectorDatabaseIdentityTests: XCTestCase {
    private let naoMgsNote = "The NAO-MGS result names no database, so this record cannot name the release that made its "
        + "calls. Cite it from the run that made the result."

    /// The rows the tab builds for the record in `directory`.
    private func optionRows(of directory: URL) async throws -> [ProvenanceOptionRow] {
        let viewModel = ProvenanceInspectorViewModel()
        viewModel.load(
            item: ProvenanceInspectableItem(
                url: directory, sidebarType: .fastqBundle, contentMode: .fastq, displayName: "Result"
            )
        )
        let finished = await waitUntil(budget: .lookup, pollInterval: .milliseconds(5)) { !viewModel.isLoading }
        XCTAssertTrue(finished, "the Provenance tab never finished loading \(directory.lastPathComponent)")
        return viewModel.optionRows
    }

    /// The values of the rows named `name`, each with the group it sits in.
    private func rows(_ rows: [ProvenanceOptionRow], named name: String) -> [String] {
        rows.filter { $0.name == name }.map { "\($0.kind): \($0.value)" }
    }

    func testTabShowsDatabaseIdentityAsResolvedDefaultsForEsVirituReceiptNaoMgsAndCzIdRecords() async throws {
        let root = try TestTempDirectory.make(prefix: "provenance-database-identity").resolvingSymlinksInPath()
        defer { TestTempDirectory.cleanup(root) }

        // An EsViritu record whose database has an install receipt that adds up: pinned, with the aggregate digest.
        let digest = String(repeating: "ab", count: 32)
        let esviritu = root.appendingPathComponent("esviritu", isDirectory: true)
        try FileManager.default.createDirectory(at: esviritu, withIntermediateDirectories: true)
        _ = try ProvenanceWriter(signingProvider: nil).write(
            ProvenanceEnvelope(
                workflowName: "EsViritu detect",
                workflowVersion: "1",
                toolName: "lungfish-cli",
                toolVersion: "test",
                options: ProvenanceOptions(
                    explicit: ["sample": .string("S1")],
                    defaults: [:],
                    resolvedDefaults: [
                        "databaseCatalogVersion": .string("v3.2.4"),
                        "databaseDigest": .string(digest),
                        "databaseIdentityStatus": .string("pinned"),
                    ]
                ),
                output: nil,
                outputs: [],
                exitStatus: 0
            ),
            to: esviritu
        )
        let esvirituRows = try await optionRows(of: esviritu)
        XCTAssertEqual(rows(esvirituRows, named: "databaseIdentityStatus"), ["Resolved Default: pinned"])
        XCTAssertEqual(rows(esvirituRows, named: "databaseDigest"), ["Resolved Default: \(digest)"])
        XCTAssertEqual(rows(esvirituRows, named: "databaseCatalogVersion"), ["Resolved Default: v3.2.4"])
        XCTAssertTrue(rows(esvirituRows, named: "databaseIdentityNote").isEmpty, "a receipt that adds up needs no note")

        // A NAO-MGS import names no database, and says so in words, among the resolved defaults only.
        let naoMgsRows = try await optionRows(of: try await importNaoMgs(in: root))
        XCTAssertEqual(rows(naoMgsRows, named: "databaseIdentityStatus"), ["Resolved Default: notNamedBySource"])
        XCTAssertEqual(rows(naoMgsRows, named: "databaseIdentityNote"), ["Resolved Default: \(naoMgsNote)"])
        XCTAssertTrue(rows(naoMgsRows, named: "databaseDigest").isEmpty, "an import has no checksum to cite")

        // A CZ-ID import keeps its three released keys and gains the status and the note, once each, as defaults.
        let czid = root.appendingPathComponent("czid", isDirectory: true)
        _ = try CzIdDataConverter.convertTaxonReport(
            at: ProvenanceCompatCorpus.repositoryRoot.appendingPathComponent("Tests/Fixtures/czid/minimal_taxon_report.tsv"),
            outputDirectory: czid
        )
        let czidRows = try await optionRows(of: czid)
        XCTAssertEqual(rows(czidRows, named: "databaseIdentityStatus"), ["Resolved Default: namedBySource"])
        XCTAssertEqual(
            rows(czidRows, named: "databaseIdentityNote"),
            ["Resolved Default: The CZ-ID result states its NT and NR database versions and no checksum."]
        )
        XCTAssertEqual(rows(czidRows, named: "ntDatabaseVersion").last, "Resolved Default: nt_2025_12_01")
    }

    /// A NAO-MGS import of the inline three-row table of `MetagenomicsImportServiceTests`, on a fixture taxdump so the
    /// taxonomy install stays off the network. Returns the result folder.
    private func importNaoMgs(in root: URL) async throws -> URL {
        let source = root.appendingPathComponent("virus_hits_final.tsv")
        try """
        sample\tseq_id\taligner_taxid_lca\tquery_seq\tquery_qual\tprim_align_genome_id_all\tprim_align_ref_start\tprim_align_cigar\tquery_len\tprim_align_edit_distance\tprim_align_query_rc
        SAMPLE_A\tread1\t111\tACGTACGT\tFFFFFFFF\tACCN0001\t10\t8M\t8\t0\tFalse
        SAMPLE_A\tread2\t111\tACGTACGA\tFFFFFFFF\tACCN0002\t20\t8M\t8\t1\tFalse
        SAMPLE_A\tread3\t222\tACGTACGG\tFFFFFFFF\tACCN0003\t30\t8M\t8\t0\tTrue
        """.write(to: source, atomically: true, encoding: .utf8)
        let managed = root.appendingPathComponent("managed-databases", isDirectory: true)
        let registry = MetagenomicsDatabaseRegistry(
            baseDirectory: managed,
            catalog: MetagenomicsDatabaseInfo.builtInCatalog.filter { $0.tool == MetagenomicsTool.ncbiTaxonomy.rawValue },
            databaseInstaller: NCBITaxonomyFixture.installer(
                archive: managed.appendingPathComponent("taxdump.tar.gz"),
                scientificNames: [111: "Fixture virus alpha", 222: "Fixture virus beta"]
            )
        )
        let lockURL = FileManager.default.temporaryDirectory.appendingPathComponent("lungfish-naomgs-import-tests.lock")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { flock(descriptor, LOCK_UN) }
        return try await MetagenomicsImportService.importNaoMgs(
            inputURL: source,
            outputDirectory: root.appendingPathComponent("imports", isDirectory: true),
            sampleName: "SAMPLE_A",
            minIdentity: 90,
            fetchReferences: false,
            preferredName: nil,
            taxonomyRegistry: registry,
            progress: nil
        ).resultDirectory
    }
}
