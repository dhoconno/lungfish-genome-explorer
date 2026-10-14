// BundleAlignmentTrackRemovalPinTests.swift - What removing a derived alignment track leaves, and in what order
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A51 M1, the freeze before `lungfish-cli bam remove-track` runs the removal for the
// Inspector's row (census row 13, gap alignment-track-remove). It pins, from the service the base
// runs in the app, the manifest and the files `removeDerivedAlignmentTrack` leaves in the bundle and
// the order of its writes. The manifest is saved before any file goes (SWIFT 4), and then the BAM,
// its index, its statistics database and the BAM's sidecar go, in that order.

import Foundation
import Synchronization
import XCTest
import LungfishCore
import LungfishTestSupport
@testable import LungfishWorkflow

final class BundleAlignmentTrackRemovalPinTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "track-removal-pin")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    func testRemovalSavesTheManifestFirstThenRemovesTheTrackFilesInOrder() async throws {
        let fixture = try DerivedAlignmentTrackFixture.make(in: root)
        let log = RemovalWriteLog()
        let service = BundleAlignmentTrackRemovalService(
            fileManager: RemovalRecordingFileManager(fixture: fixture, log: log)
        ) { manifest, bundleURL in
            let left = DerivedAlignmentTrackFixture.derivedArtifactPaths.filter {
                FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent($0).path)
            }
            log.append("save manifest with \(manifest.alignments.map(\.id)) while \(left.count) track files remain")
            try PreparedAlignmentAttachmentService.atomicManifestSave(manifest: manifest, bundleURL: bundleURL)
        }

        let result = try await service.removeDerivedAlignmentTrack(
            bundleURL: fixture.bundleURL,
            trackID: DerivedAlignmentTrackFixture.derivedTrackID
        )

        let removed = DerivedAlignmentTrackFixture.derivedArtifactPaths + [DerivedAlignmentTrackFixture.derivedSidecarPath]
        XCTAssertEqual(
            log.entries,
            ["save manifest with [\"aln-source\"] while 3 track files remain"] + removed.map { "remove \($0)" }
        )
        XCTAssertEqual(result.removedTrack.id, DerivedAlignmentTrackFixture.derivedTrackID)
        XCTAssertEqual(result.removedTrack.name, DerivedAlignmentTrackFixture.derivedTrackName)
        XCTAssertEqual(result.removedArtifactURLs.map(fixture.relativePath(of:)), removed)
        XCTAssertEqual(
            try BundleManifest.load(from: fixture.bundleURL).alignments.map(\.id),
            [DerivedAlignmentTrackFixture.sourceTrackID]
        )
        XCTAssertEqual(
            fixture.relativeFiles(),
            (DerivedAlignmentTrackFixture.sourcePaths + [BundleManifest.filename]).sorted()
        )
    }
}

/// The writes of one removal, in order.
final class RemovalWriteLog: Sendable {
    private let state = Mutex<[String]>([])

    func append(_ entry: String) {
        state.withLock { $0.append(entry) }
    }

    var entries: [String] {
        state.withLock { $0 }
    }
}

/// A file manager that logs each removal by its bundle-relative path before it removes the item.
final class RemovalRecordingFileManager: FileManager {
    private let fixture: DerivedAlignmentTrackFixture
    private let log: RemovalWriteLog

    init(fixture: DerivedAlignmentTrackFixture, log: RemovalWriteLog) {
        self.fixture = fixture
        self.log = log
        super.init()
    }

    override func removeItem(at url: URL) throws {
        log.append("remove \(fixture.relativePath(of: url))")
        try super.removeItem(at: url)
    }
}
