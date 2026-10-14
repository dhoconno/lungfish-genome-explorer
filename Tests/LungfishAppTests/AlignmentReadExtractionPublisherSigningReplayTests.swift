// AlignmentReadExtractionPublisherSigningReplayTests.swift - The record of a published read extraction is signed when a key is set
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane Q-SIGN, family L3. `AlignmentReadExtractionPublisher` wrote the record of an extracted-reads
// bundle through `ProvenanceWriter(signingProvider: nil)`, so the record the new bundle opens first, which both
// the Viewer's in-process route and `extract reads` write, never signed. This runs the stager and the publisher
// in process with `LUNGFISH_PROVENANCE_SIGNING_KEY_FILE` naming a throwaway key under the test's folder. It sets
// a process variable and runs samtools, so its name ends in ReplayTests and it runs in the integration tier.

import Foundation
import XCTest
@testable import LungfishApp
import LungfishKitTestSupport
import LungfishTestSupport
import LungfishWorkflow

@MainActor
final class AlignmentReadExtractionPublisherSigningReplayTests: XCTestCase {
    func testTheExtractedReadsBundleRecordIsSignedWhenAKeyIsSet() async throws {
        guard BamFixtureBuilder.locateSamtools() != nil else {
            try ToolAvailability.skipOrFail("samtools is not available, so the reads cannot be extracted")
        }
        let scratch = try TestTempDirectory.make(prefix: "reads-record-signing")
        defer { TestTempDirectory.cleanup(scratch) }
        let saved = RouteParityHarness.SigningEnvironment(keyFile: try RouteParityHarness.writeSigningKey(in: scratch))
        defer { saved.restore() }

        let root = scratch.appendingPathComponent("root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try AlignmentActionCLIGUIParityReplayTests.makeReadsFixture(in: root)
        let outcome = await AlignmentActionCLIGUIParityReplayTests.readsSideA(root, selected: true)
        XCTAssertEqual(outcome.end, .completed, outcome.detail)

        let record = root.appendingPathComponent("out/S1.lungfishfastq/\(ProvenanceRecorder.provenanceFilename)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.path), "the publisher left no record at \(record.path)")
        XCTAssertTrue(RouteParityHarness.isSigned(record), "\(record.lastPathComponent) has no signature and public key though a key is set")
    }
}
