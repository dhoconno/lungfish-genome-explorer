// BlastSourceStampRouteTests.swift - Which routes' source folders give a stamp, and a search that sits inside its source
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Lane BLASTCOLLECT, gap 6 of C3 and BIO's SF1. A stamp tells one run of a source from another. Kraken2 keeps its searches
// inside its source, so a copy of the source brings them along and writes a new root record beside them, and that copy
// must not read as a replaced source. No network and no process.

import Foundation
import LungfishCore
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow
import XCTest

final class BlastSourceStampRouteTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = try TestTempDirectory.make(prefix: "blast-source-stamp-route")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(scratch)
    }

    private static var analyses: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/analyses", isDirectory: true)
    }

    /// The real writers' folders, and for NVD and NAO-MGS, which have no fixture folder, the manifest each import writes.
    /// A plain FASTA has no stamp, and its route looks up no row, so it needs none.
    func testEveryRoutesSourceFolderGivesAStamp() throws {
        for name in [
            "esviritu-2026-01-15T10-00-00", "esviritu-batch-2026-01-15T15-00-00", "kraken2-2026-01-15T11-00-00",
            "spades-2026-01-15T13-00-00", "taxtriage-2026-01-15T12-00-00",
        ] {
            let folder = Self.analyses.appendingPathComponent(name, isDirectory: true)
            XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path), name)
            XCTAssertNotNil(BlastVerificationArchive.sourceStamp(ofResult: folder), name)
        }
        for name in ["nvd-import", "naomgs-S1"] {
            let folder = scratch.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: folder.appendingPathComponent("manifest.json"))
            XCTAssertNotNil(BlastVerificationArchive.sourceStamp(ofResult: folder), name)
        }
        let fasta = scratch.appendingPathComponent("selection.fasta")
        try Data(">a\nACGT\n".utf8).write(to: fasta)
        XCTAssertNil(BlastVerificationArchive.sourceStamp(ofResult: fasta), "FASTA has no row key")
    }

    /// A done search of `source` in `folder`, stamped with the source as it stands, with its record.
    private func saveDoneSearch(of source: URL, in folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let lineage = BlastSubmissionRecord.Lineage(sourceResult: source.path, sample: "S1", taxId: 7, contig: nil)
        let request = BlastVerificationRequest(
            taxonName: "Taxon", taxId: 7, sequences: [(id: "read_1", sequence: "ACGT")], database: "nt"
        )
        var file = BlastSearchFile(
            origin: .standIn, createdAt: Date(), submitArgv: [], facts: BlastSearchFile.Facts(request),
            query: BlastSubmissionRecord.Query(fileName: "query.fasta", sha256: "x", sequenceCount: 1), formSHA256: "x"
        )
        file.state = .done
        file.copies[0].rid = "RID-DONE"
        file.lineage = lineage
        file.sourceStamp = BlastVerificationArchive.sourceStamp(ofResult: source)
        try BlastSearchStore(folder: folder).save(file)

        let project = try SavedBlastSearchProject()
        defer { project.remove() }
        _ = try project.result("result-A")
        var record = try BlastSubmissionRecord.load(
            try project.saveRecord(rid: "RID-DONE", sourceResult: "result-A", sample: "S1", taxId: 7, contig: nil)
        )
        record.lineage = lineage
        try BlastSubmissionRecord.encoder.encode(record)
            .write(to: folder.appendingPathComponent(BlastSubmissionRecord.recordFileName))
    }

    private func lookup(in directory: URL) -> BlastRowSearch? {
        BlastVerificationArchive.newestSearch(in: directory) { lineage, _ in
            lineage.taxId == 7 && lineage.sample == "S1"
        }
    }

    func testASearchInsideItsSourceKeepsItsRowWhenTheCopyRewritesTheRootRecord() throws {
        let source = scratch.appendingPathComponent("kraken2-result", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let record = source.appendingPathComponent(BundleKindDescriptor.SidecarNaming.rootRecordFileName)
        try Data(#"{"id":"11111111-1111-1111-1111-111111111111"}"#.utf8).write(to: record)
        try saveDoneSearch(of: source, in: BlastVerificationArchive.directoryURL(for: source).appendingPathComponent("s1", isDirectory: true))

        try Data(#"{"id":"22222222-2222-2222-2222-222222222222"}"#.utf8).write(to: record)

        guard case .saved? = lookup(in: source) else {
            return XCTFail("the search travels with its source, and it reads \(String(describing: lookup(in: source)))")
        }
    }

    func testASearchOutsideItsSourceStillReadsSourceReplacedWhenTheRootRecordChanges() throws {
        let source = scratch.appendingPathComponent("esviritu-result", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let record = source.appendingPathComponent(BundleKindDescriptor.SidecarNaming.rootRecordFileName)
        try Data(#"{"id":"11111111-1111-1111-1111-111111111111"}"#.utf8).write(to: record)
        try saveDoneSearch(of: source, in: BlastVerificationArchive.directoryURL(for: scratch).appendingPathComponent("s1", isDirectory: true))

        try Data(#"{"id":"22222222-2222-2222-2222-222222222222"}"#.utf8).write(to: record)

        guard case .sourceReplaced? = lookup(in: scratch) else {
            return XCTFail("the guard still works, and it reads \(String(describing: lookup(in: scratch)))")
        }
    }
}
