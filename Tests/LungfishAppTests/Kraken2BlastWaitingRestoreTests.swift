// Kraken2BlastWaitingRestoreTests.swift - A waiting BLAST search shows on its own taxon row of a Kraken 2 result only
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Lane BLASTCOLLECT (BIO review of C1 to C3, ruling 4.2, gap 3: Kraken 2 had no test). Both are pins of the lookup as it
// stands, so they pass at the base. They hold the day a folder holds two samples, which today it does not, since the
// batch display sends each sample's own folder (`ViewerViewController+Taxonomy.swift:172-213`). The file sits in
// LungfishAppTests, which already links every module the lookup and the fixture need.

import Foundation
import XCTest
import LungfishCore
import LungfishKit
import LungfishTestSupport
@testable import LungfishTaxonomyUI

final class Kraken2BlastWaitingRestoreTests: XCTestCase {
    /// Saves one live search for `taxId` and `sample` under `<directory>/blast-verifications/<name>`.
    private func saveLiveSearch(in directory: URL, name: String, taxId: Int, sample: String?, age: TimeInterval) throws -> UUID {
        let request = BlastVerificationRequest(taxonName: "Taxon \(taxId)", taxId: taxId, sequences: [(id: "read_1", sequence: "ACGT")], database: "core_nt")
        var file = BlastSearchFile(
            origin: .standIn, createdAt: Date(timeIntervalSinceNow: -age), submitArgv: [], facts: BlastSearchFile.Facts(request),
            query: BlastSubmissionRecord.Query(fileName: "query.fasta", sha256: "x", sequenceCount: 1), formSHA256: "x"
        )
        file.state = .waiting
        file.copies[0].rid = "RID-\(name)"
        file.copies[0].state = .live
        file.lineage = BlastSubmissionRecord.Lineage(sample: sample, taxId: taxId)
        let folder = directory.appendingPathComponent("blast-verifications/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try BlastSearchStore(folder: folder).save(file)
        return file.searchID
    }

    func testAWaitingSearchShowsOnItsTaxonRowOnly() async throws {
        let directory = try TestTempDirectory.make(prefix: "kraken2-waiting-restore")
        defer { TestTempDirectory.cleanup(directory) }
        let id = try saveLiveSearch(in: directory, name: "t7-a", taxId: 7, sample: "A", age: 60)

        let own = await TaxonomyViewController.liveBlastSearchOffMain(forTaxId: 7, sample: "A", in: directory)
        XCTAssertEqual(own?.file.searchID, id, "the row of taxon 7 in sample A shows its own waiting search")
        let otherTaxon = await TaxonomyViewController.liveBlastSearchOffMain(forTaxId: 8, sample: "A", in: directory)
        XCTAssertNil(otherTaxon, "another taxon's row shows nothing")
        let otherSample = await TaxonomyViewController.liveBlastSearchOffMain(forTaxId: 7, sample: "B", in: directory)
        XCTAssertNil(otherSample, "another sample's row shows nothing")
        let noSample = await TaxonomyViewController.liveBlastSearchOffMain(forTaxId: 7, sample: nil, in: directory)
        XCTAssertEqual(noSample?.file.searchID, id, "a row with no sample named matches by taxon, which is safe only while one folder holds one sample")
    }

    func testASearchOfAnotherSampleInTheSameFolderIsNotShown() async throws {
        let directory = try TestTempDirectory.make(prefix: "kraken2-two-samples")
        defer { TestTempDirectory.cleanup(directory) }
        let forA = try saveLiveSearch(in: directory, name: "t7-a", taxId: 7, sample: "A", age: 120)
        let forB = try saveLiveSearch(in: directory, name: "t7-b", taxId: 7, sample: "B", age: 60)

        let rowA = await TaxonomyViewController.liveBlastSearchOffMain(forTaxId: 7, sample: "A", in: directory)
        XCTAssertEqual(rowA?.file.searchID, forA, "sample A's row shows sample A's search though sample B's is newer")
        let rowB = await TaxonomyViewController.liveBlastSearchOffMain(forTaxId: 7, sample: "B", in: directory)
        XCTAssertEqual(rowB?.file.searchID, forB)
    }
}
