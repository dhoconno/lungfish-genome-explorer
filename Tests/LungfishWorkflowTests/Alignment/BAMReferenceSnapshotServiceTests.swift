// BAMReferenceSnapshotServiceTests.swift - The lengths and counts the TaxTriage viewer reads from a BAM
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.09 M1, BIO-TT-ROUTES item 4. The mapped-read counts could not be pinned through the view at the
// base, so they are pinned here, on the service the view's `parseBamReferenceLengthsSnapshot` now forwards to. The
// lengths through the view are pinned by `TaxTriageReferenceSnapshotPinTests`.

import XCTest
import LungfishWorkflow
import LungfishTestSupport

final class BAMReferenceSnapshotServiceTests: XCTestCase {

    private static let fixtureBAM = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/sarscov2/test.paired_end.sorted.bam")

    /// Copied from a base run of the managed samtools 1.24 on the fixture (lane 13.09 report). Both
    /// `samtools idxstats -X <bam> <bai>` and `samtools idxstats <bam>` with no index print
    /// `MT192765.1 29829 197 3` and `* 0 0 0`, so column 1 against column 3, without `*`, is this map.
    private static let fixtureSnapshot = BAMReferenceSnapshot(
        accessionLengths: ["MT192765.1": 29_829],
        accessionMappedReadCounts: ["MT192765.1": 197],
        parsedMappedReads: true
    )

    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BAMReferenceSnapshotService-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
        try super.tearDownWithError()
    }

    func testIdxstatsCountsOfTheFixtureBAM() throws {
        guard let samtools = BamFixtureBuilder.locateSamtools() else {
            try ToolAvailability.skipOrFail("samtools is not installed")
        }
        let fm = FileManager.default
        let minimap = root.appendingPathComponent("minimap2", isDirectory: true)
        let alignment = root.appendingPathComponent("alignment", isDirectory: true)
        try fm.createDirectory(at: minimap, withIntermediateDirectories: true)
        try fm.createDirectory(at: alignment, withIntermediateDirectories: true)
        let bam = minimap.appendingPathComponent("sampleA.bam")
        let externalIndex = alignment.appendingPathComponent("sampleA.bam.bai")
        try fm.copyItem(at: Self.fixtureBAM, to: bam)
        try fm.copyItem(at: URL(fileURLWithPath: Self.fixtureBAM.path + ".bai"), to: externalIndex)
        XCTAssertFalse(fm.fileExists(atPath: bam.path + ".bai"), "Precondition failed: an adjacent index exists")

        let withExternalIndex = BAMReferenceSnapshotService.snapshot(
            bamPath: bam.path,
            indexPath: externalIndex.path,
            samtoolsPath: samtools
        )
        XCTAssertEqual(withExternalIndex, Self.fixtureSnapshot, "idxstats -X with the external index")

        let withNoIndex = BAMReferenceSnapshotService.snapshot(bamPath: bam.path, indexPath: nil, samtoolsPath: samtools)
        XCTAssertEqual(withNoIndex, Self.fixtureSnapshot, "idxstats with no index anywhere")
    }

    /// A samtools that cannot launch gives an empty snapshot, as the view's own spawn did.
    func testASamtoolsThatCannotLaunchGivesAnEmptySnapshot() {
        let snapshot = BAMReferenceSnapshotService.snapshot(
            bamPath: Self.fixtureBAM.path,
            indexPath: nil,
            samtoolsPath: root.appendingPathComponent("no-such-samtools").path
        )
        XCTAssertEqual(
            snapshot,
            BAMReferenceSnapshot(accessionLengths: [:], accessionMappedReadCounts: [:], parsedMappedReads: false)
        )
    }
}
