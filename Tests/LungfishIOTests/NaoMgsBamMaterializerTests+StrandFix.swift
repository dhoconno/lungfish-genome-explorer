// NaoMgsBamMaterializerTests+StrandFix.swift - The strand-fix marker survives markdup, and a purged database keeps its BAM
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.1 lane NAO-BAM-STALE (UX ruling UX-NAO-BAM-STALE, sections 2 and 3, tests T2 and T3). Since 2026-04-11 the
// import deletes the stored reads (`deleteVirusHitsAndVacuum`) once it has written each sample's BAM, so the result's
// database holds the accessions but no reads. A forced materialize of such a database used to replace each BAM with one
// that holds a header and no reads, and `lungfish-cli markdup --force` reaches that path today.

import XCTest
import CryptoKit
import LungfishTestSupport
@testable import LungfishIO

extension NaoMgsBamMaterializerTests {

    /// The BAM the import keeps is the one after markdup, so the marker must be in that BAM and the check must read it.
    func testOrientationOfAMaterializedBAMSurvivesMarkdup() throws {
        guard let samtools = BamFixtureBuilder.locateSamtools() else {
            try ToolAvailability.skipOrFail("samtools is not installed")
        }
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let dbURL = tmp.appendingPathComponent("naomgs.sqlite")
        try makeTestDatabase(at: dbURL, sample: "S1", duplicateCount: 3)

        let result = try materializeForPin(dbURL: dbURL, tmp: tmp, samtools: samtools, markDuplicates: true)
        let bam = try XCTUnwrap(result.bamURLs.first)
        XCTAssertEqual(
            try NaoMgsBamMaterializer.orientation(ofBAM: bam, samtoolsPath: samtools), .referenceStrand,
            "a BAM this version materialized and marked duplicates in is on the reference strand"
        )
    }

    /// T3. The database after the import's purge has the accessions (`accession_summaries`) and no reads. A forced
    /// materialize must leave the BAM as it was, byte for byte, and not write one with a header and no reads.
    func testForcedMaterializeOfAPurgedDatabaseKeepsTheBAM() throws {
        guard let samtools = BamFixtureBuilder.locateSamtools() else {
            try ToolAvailability.skipOrFail("samtools is not installed")
        }
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        // The real database the import makes from three reads of one sample, so the purge is the import's own.
        let hits = (1...3).map { index in
            NaoMgsVirusHit(
                sample: "S1", seqId: "read-\(index)", taxId: 11, bestAlignmentScore: 100, cigar: "50M", queryStart: 0,
                queryEnd: 50, refStart: index * 100, refEnd: index * 100 + 50,
                readSequence: String(repeating: "ACGT", count: 12) + "AC", readQuality: String(repeating: "I", count: 50),
                subjectSeqId: "NC_001", subjectTitle: "Test virus", bitScore: 100, eValue: 1e-20, percentIdentity: 99,
                editDistance: 0, fragmentLength: 50, isReverseComplement: index == 2, pairStatus: "UP", queryLength: 50
            )
        }
        let dbURL = tmp.appendingPathComponent("naomgs.sqlite")
        _ = try NaoMgsDatabase.create(at: dbURL, hits: hits)

        let result = try materializeForPin(dbURL: dbURL, tmp: tmp, samtools: samtools, markDuplicates: false)
        let bam = try XCTUnwrap(result.bamURLs.first)
        let digestBefore = try strandFixSHA256(of: bam)
        let countBefore = try strandFixReadCount(samtools, bam)
        XCTAssertGreaterThan(countBefore, 0, "the first materialize wrote the sample's reads")

        try NaoMgsDatabase.openReadWrite(at: dbURL).deleteVirusHitsAndVacuum()
        let forced = try NaoMgsBamMaterializer.materializeAll(
            dbPath: dbURL.path, resultURL: tmp, samtoolsPath: samtools, force: true, markDuplicates: false
        )

        XCTAssertEqual(try strandFixReadCount(samtools, bam), countBefore, "a forced run over a purged database keeps every read")
        XCTAssertEqual(try strandFixSHA256(of: bam), digestBefore, "and leaves the BAM byte for byte as it was")
        XCTAssertEqual(forced, [], "a sample the guard skipped is not reported as materialized")
    }

    /// UX review of NAO-BAM-MISSING, SF1. The viewer's fallback calls `materializeAll` with no `force`, over a result
    /// whose BAM is gone and whose database the import purged. The guard must stop that call, so no BAM with a header
    /// and no reads lands in a displayed result (the card would then be blank and its note would say nothing). T3 runs
    /// `force: true` over a BAM that exists, so it does not reach this call, and the viewer test replaces the writer
    /// with a hook. This pins the fallback's own call. It passes at the head, as a pin does.
    func testUnforcedMaterializeOfAPurgedDatabaseWithNoBAMWritesNoBAM() throws {
        guard let samtools = BamFixtureBuilder.locateSamtools() else {
            try ToolAvailability.skipOrFail("samtools is not installed")
        }
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        // The real database the import makes from three reads of one sample, so the purge is the import's own.
        let hits = (1...3).map { index in
            NaoMgsVirusHit(
                sample: "S1", seqId: "read-\(index)", taxId: 11, bestAlignmentScore: 100, cigar: "50M", queryStart: 0,
                queryEnd: 50, refStart: index * 100, refEnd: index * 100 + 50,
                readSequence: String(repeating: "ACGT", count: 12) + "AC", readQuality: String(repeating: "I", count: 50),
                subjectSeqId: "NC_001", subjectTitle: "Test virus", bitScore: 100, eValue: 1e-20, percentIdentity: 99,
                editDistance: 0, fragmentLength: 50, isReverseComplement: index == 2, pairStatus: "UP", queryLength: 50
            )
        }
        let dbURL = tmp.appendingPathComponent("naomgs.sqlite")
        _ = try NaoMgsDatabase.create(at: dbURL, hits: hits)

        let result = try materializeForPin(dbURL: dbURL, tmp: tmp, samtools: samtools, markDuplicates: false)
        let bam = try XCTUnwrap(result.bamURLs.first)
        let bamsFolder = bam.deletingLastPathComponent()
        try NaoMgsDatabase.openReadWrite(at: dbURL).deleteVirusHitsAndVacuum()
        // The BAM is removed by hand, with its index.
        for file in try FileManager.default.contentsOfDirectory(at: bamsFolder, includingPropertiesForKeys: nil)
        where ["bam", "bai"].contains(file.pathExtension) {
            try FileManager.default.removeItem(at: file)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: bam.path), "the set-up removed the sample's BAM")

        let unforced = try NaoMgsBamMaterializer.materializeAll(dbPath: dbURL.path, resultURL: tmp, samtoolsPath: samtools)

        XCTAssertEqual(unforced, [], "a sample the guard skipped is not reported as materialized")
        XCTAssertFalse(FileManager.default.fileExists(atPath: bam.path), "no BAM with a header and no reads is written")
        let left = try FileManager.default.contentsOfDirectory(atPath: bamsFolder.path)
            .filter { ["bam", "bai"].contains(($0 as NSString).pathExtension) }
        XCTAssertEqual(left, [], "the bams folder holds no BAM and no index")
    }

    private func strandFixSHA256(of url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    /// `samtools view -c` of the whole BAM.
    private func strandFixReadCount(_ samtools: String, _ bam: URL) throws -> Int {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: samtools)
        process.arguments = ["view", "-c", bam.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "samtools view -c of \(bam.lastPathComponent)")
        return Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
    }
}
