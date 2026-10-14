// BundleAlignmentTrackRemovalSigningReplayTests.swift - The record of a removed alignment track is signed when a key is set
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane Q-SIGN, family L3. `BundleAlignmentTrackRemovalRecord.write` built
// `ProvenanceWriter(signingProvider: nil)`, so the record `bam remove-track` and the Inspector's removal leave in
// the bundle never signed. The record is the one the result opens first, and `bam filter` and `bam annotate` sign
// theirs. This runs the removal service in process with `LUNGFISH_PROVENANCE_SIGNING_KEY_FILE` naming a
// throwaway key under the test's folder. It sets a process variable, so its name ends in ReplayTests and it runs
// in the integration tier.

import Foundation
import XCTest
@testable import LungfishApp
import LungfishKitTestSupport
import LungfishTestSupport
import LungfishWorkflow

@MainActor
final class BundleAlignmentTrackRemovalSigningReplayTests: XCTestCase {
    func testTheRemovalRecordIsSignedWhenAKeyIsSet() async throws {
        guard BamFixtureBuilder.locateSamtools() != nil else {
            try ToolAvailability.skipOrFail("samtools is not available, so the fixture bundle cannot be built")
        }
        let scratch = try TestTempDirectory.make(prefix: "removal-record-signing")
        defer { TestTempDirectory.cleanup(scratch) }
        let saved = RouteParityHarness.SigningEnvironment(keyFile: try RouteParityHarness.writeSigningKey(in: scratch))
        defer { saved.restore() }

        let root = scratch.appendingPathComponent("root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try AlignmentActionCLIGUIParityReplayTests.makeFixture(in: root)
        let outcome = await AlignmentActionCLIGUIParityReplayTests.sideA(root, trackID: DerivedAlignmentTrackFixture.derivedTrackID)
        XCTAssertEqual(outcome.end, .completed, outcome.detail)

        let record = BundleAlignmentTrackRemovalRecord.recordURL(
            bundleURL: DerivedAlignmentTrackFixture.existing(in: root).bundleURL, trackID: DerivedAlignmentTrackFixture.derivedTrackID
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.path), "the removal left no record at \(record.path)")
        XCTAssertTrue(RouteParityHarness.isSigned(record), "\(record.lastPathComponent) has no signature and public key though a key is set")
    }
}
