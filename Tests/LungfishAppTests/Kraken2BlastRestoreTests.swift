// Kraken2BlastRestoreTests.swift - A saved Kraken2 BLAST verification comes back when its taxon is selected
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishTestSupport
import LungfishWorkflow

/// Phase 2.12 lane 12.10 (A65-P50), M2 (1) and ARCH 4. The Kraken2 row saved each verification as an archive file
/// under `<result>/blast-verifications/` and now keeps the folder `blast submit` writes there. Selecting the taxon
/// in a reopened result shows the newest saved search of either form (`restoreSavedBlastVerification`).
@MainActor
final class Kraken2BlastRestoreTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = try TestTempDirectory.make(prefix: "kraken2-blast-restore")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(scratch)
    }

    /// The pin, green at the lane's base. A verification the in-process row saved restores.
    func testAVerificationTheInProcessRowSavedRestores() throws {
        let result = try resultFolder()
        saveBlastVerification(
            Self.verification(rid: "RID-ARCHIVE", taxId: 562, at: Self.earlier), request: Self.request(taxId: 562),
            resultDirectory: result, classResult: try Self.classResult(in: result), sourceInputs: [], readCount: 1,
            runClock: ProvenanceRunClock()
        )
        let (restored, controller) = restore(taxId: 562, from: result)
        XCTAssertEqual(restored?.rid, "RID-ARCHIVE")
        XCTAssertEqual(controller.lastBlastResult?.rid, "RID-ARCHIVE")
        XCTAssertEqual(controller.lastBlastNode?.taxId, 562, "Re-run BLAST targets the restored taxon")
    }

    /// A search the row ran on `blast submit` restores, a search of another taxon does not, and of two saved
    /// searches of the taxon the newer shows, whichever form it has.
    func testABlastSubmitSearchRestoresAndTheNewerSearchShows() throws {
        let result = try resultFolder()
        try BlastVerificationArchive.save(Self.verification(rid: "RID-ARCHIVE", taxId: 562, at: Self.earlier), request: nil, in: result)
        try writeSubmitRecord(rid: "RID-SUBMIT", taxId: 562, savedAt: Self.later, in: result, folder: "Escherichia-coli-a")
        try writeSubmitRecord(rid: "RID-OTHER", taxId: 570, savedAt: Self.latest, in: result, folder: "Klebsiella-b")
        XCTAssertEqual(restore(taxId: 562, from: result).result?.rid, "RID-SUBMIT", "the newer search is the blast submit one")
        XCTAssertEqual(restore(taxId: 570, from: result).result?.rid, "RID-OTHER")

        try BlastVerificationArchive.save(Self.verification(rid: "RID-NEWER-ARCHIVE", taxId: 562, at: Self.latest), request: nil, in: result)
        XCTAssertEqual(restore(taxId: 562, from: result).result?.rid, "RID-NEWER-ARCHIVE", "an older blast submit search gives way")
    }

    /// ARCH ruling T5 of lane 12.33, condition 1. The drawer keeps the URL of the file its result was read from, since
    /// the table export reads that file. An archive file gives its own URL, and once a `blast submit` record is newer
    /// the record's URL takes its place.
    func testARestoredVerificationKeepsTheURLOfTheFileItCameFrom() throws {
        let result = try resultFolder()
        let archiveURL = try BlastVerificationArchive.save(
            Self.verification(rid: "RID-ARCHIVE", taxId: 562, at: Self.earlier), request: nil, in: result
        )
        let archived = restoreIntoDrawer(taxId: 562, from: result)
        XCTAssertEqual(archived.tab.currentResult?.rid, "RID-ARCHIVE")
        XCTAssertEqual(archived.tab.currentRecordURL?.resolvingSymlinksInPath(), archiveURL.resolvingSymlinksInPath())
        XCTAssertEqual(
            archived.controller.lastBlastRecordURL?.resolvingSymlinksInPath(), archiveURL.resolvingSymlinksInPath(),
            "the view keeps the URL of the file it restored from"
        )

        try writeSubmitRecord(rid: "RID-SUBMIT", taxId: 562, savedAt: Self.later, in: result, folder: "Escherichia-coli-a")
        let recordURL = BlastVerificationArchive.directoryURL(for: result)
            .appendingPathComponent("Escherichia-coli-a", isDirectory: true)
            .appendingPathComponent(BlastSubmissionRecord.recordFileName)
        let submitted = restoreIntoDrawer(taxId: 562, from: result)
        XCTAssertEqual(submitted.tab.currentResult?.rid, "RID-SUBMIT")
        XCTAssertEqual(submitted.tab.currentRecordURL?.resolvingSymlinksInPath(), recordURL.resolvingSymlinksInPath())
    }

    /// Review 12.33-A9 Fix 1 (T5 condition 1c). A verification restored while no drawer exists keeps the URL of its file
    /// in the view, and a drawer made later gets that URL with the result, so its table export reads the file.
    func testARestoredVerificationWaitingForAMissingDrawerReplaysItsFileURL() throws {
        let result = try resultFolder()
        let archiveURL = try BlastVerificationArchive.save(
            Self.verification(rid: "RID-ARCHIVE", taxId: 562, at: Self.earlier), request: nil, in: result
        )
        let controller = TaxonomyViewController()
        controller.blastVerificationDirectoryResolver = { _ in result }
        let node = TaxonNode(
            taxId: 562, name: "taxon 562", rank: .species, depth: 7,
            readsDirect: 10, readsClade: 10, fractionClade: 0.1, fractionDirect: 0.1, parentTaxId: 1
        )
        _ = controller.restoreSavedBlastVerification(for: node)
        XCTAssertEqual(controller.lastBlastRecordURL?.resolvingSymlinksInPath(), archiveURL.resolvingSymlinksInPath())

        let drawer = TaxaCollectionsDrawerView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        controller.taxaCollectionsDrawerView = drawer
        controller.wireBlastDrawerCallbacks()
        XCTAssertEqual(drawer.blastResultsTab.currentResult?.rid, "RID-ARCHIVE")
        XCTAssertEqual(
            drawer.blastResultsTab.currentRecordURL?.resolvingSymlinksInPath(), archiveURL.resolvingSymlinksInPath(),
            "the drawer made after the restore gets the file's URL with the result"
        )
    }

    // MARK: - Fixtures

    private static let earlier = Date(timeIntervalSince1970: 1_790_000_000)
    private static let later = earlier.addingTimeInterval(60)
    private static let latest = earlier.addingTimeInterval(120)

    private func resultFolder() throws -> URL {
        let url = scratch.appendingPathComponent("Project.lungfish/Analyses/kraken2-run", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A reopened result whose BLAST drawer exists, with the taxon selected. The restore shows the saved search in the
    /// drawer's tab, which `currentRecordURL` reads.
    private func restoreIntoDrawer(
        taxId: Int,
        from directory: URL
    ) -> (tab: BlastResultsDrawerTab, controller: TaxonomyViewController) {
        let controller = TaxonomyViewController()
        let drawer = TaxaCollectionsDrawerView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        controller.taxaCollectionsDrawerView = drawer
        controller.blastVerificationDirectoryResolver = { _ in directory }
        let node = TaxonNode(
            taxId: taxId, name: "taxon \(taxId)", rank: .species, depth: 7,
            readsDirect: 10, readsClade: 10, fractionClade: 0.1, fractionDirect: 0.1, parentTaxId: 1
        )
        _ = controller.restoreSavedBlastVerification(for: node)
        return (drawer.blastResultsTab, controller)
    }

    /// A reopened result, a fresh controller with no BLAST state, and the taxon selected.
    private func restore(taxId: Int, from directory: URL) -> (result: BlastVerificationResult?, controller: TaxonomyViewController) {
        let controller = TaxonomyViewController()
        controller.blastVerificationDirectoryResolver = { _ in directory }
        let node = TaxonNode(
            taxId: taxId, name: "taxon \(taxId)", rank: .species, depth: 7,
            readsDirect: 10, readsClade: 10, fractionClade: 0.1, fractionDirect: 0.1, parentTaxId: 1
        )
        return (controller.restoreSavedBlastVerification(for: node), controller)
    }

    /// The folder `blast submit` writes, with only the record the restore reads.
    private func writeSubmitRecord(rid: String, taxId: Int, savedAt: Date, in result: URL, folder: String) throws {
        let directory = BlastVerificationArchive.directoryURL(for: result).appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let record = BlastSubmissionRecord(
            savedAt: savedAt,
            query: .init(fileName: BlastSubmissionRecord.queryFileName, sha256: String(repeating: "0", count: 64), sequenceCount: 1),
            lineage: .init(sourceResult: "@/Analyses/kraken2-run", taxId: taxId, subsampleCount: 1, subsampleSeed: 0),
            search: .init(Self.request(taxId: taxId)),
            result: Self.verification(rid: rid, taxId: taxId, at: savedAt)
        )
        try BlastSubmissionRecord.encoder.encode(record)
            .write(to: directory.appendingPathComponent(BlastSubmissionRecord.recordFileName))
    }

    private static func request(taxId: Int) -> BlastVerificationRequest {
        BlastVerificationRequest(
            taxonName: "taxon \(taxId)", taxId: taxId, sequences: [(id: "read_1", sequence: "ACGTACGTAC")],
            database: BlastDatabaseID.coreNT.rawValue
        )
    }

    private static func verification(rid: String, taxId: Int, at date: Date) -> BlastVerificationResult {
        BlastVerificationResult(
            taxonName: "taxon \(taxId)",
            taxId: taxId,
            readResults: [
                BlastReadResult(
                    id: "read_1", verdict: .verified, topHitOrganism: "taxon \(taxId)", topHitAccession: "NC_000001.1",
                    percentIdentity: 99.0, eValue: 0.0, matchesQueriedTaxon: true
                )
            ],
            submittedAt: date,
            completedAt: date,
            rid: rid,
            blastProgram: "megablast",
            database: "core_nt"
        )
    }

    private static func classResult(in directory: URL) throws -> ClassificationResult {
        let report = directory.appendingPathComponent("classification.kreport")
        try Data("100.00\t10\t10\tS\t562\tEscherichia coli\n".utf8).write(to: report)
        let root = TaxonNode(
            taxId: 1, name: "root", rank: .root, depth: 0,
            readsDirect: 0, readsClade: 10, fractionClade: 1.0, fractionDirect: 0.0, parentTaxId: nil
        )
        return ClassificationResult(
            config: ClassificationConfig(
                inputFiles: [directory.appendingPathComponent("reads.fastq")], isPairedEnd: false,
                databaseName: "test-db", databasePath: directory.appendingPathComponent("db"), outputDirectory: directory
            ),
            tree: TaxonTree(root: root, unclassifiedNode: nil, totalReads: 10),
            reportURL: report,
            outputURL: directory.appendingPathComponent("classification.kraken"),
            brackenURL: nil,
            runtime: 1,
            toolVersion: "2.1.3",
            provenanceId: nil
        )
    }
}
