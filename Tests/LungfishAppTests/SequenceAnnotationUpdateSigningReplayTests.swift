// SequenceAnnotationUpdateSigningReplayTests.swift - The record of an annotation update is signed when a key is set
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane Q-SIGN, family L1. `SequenceAnnotationTrackWorkflow.updateAnnotation` writes the bundle's record
// through `writeUpdateAnnotationProvenance`, which built `ProvenanceWriter(signingProvider: nil)`, so the record
// `sequence update-annotation` and the Inspector's edit leave in the bundle never signed, though it is the record
// the result opens first. AnnotationEditRouteParityTests compares the app's call with the leaf in process and has no
// three-side run. This runs the update in process with `LUNGFISH_PROVENANCE_SIGNING_KEY_FILE` naming a throwaway
// key under the test's folder. It sets a process variable, so its name ends in ReplayTests and it runs in the
// integration tier.

import Foundation
import XCTest
import LungfishKitTestSupport
import LungfishTestSupport
import LungfishWorkflow

@MainActor
final class SequenceAnnotationUpdateSigningReplayTests: XCTestCase {
    func testTheUpdateRecordIsSignedWhenAKeyIsSet() async throws {
        let scratch = try TestTempDirectory.make(prefix: "annotation-update-signing")
        defer { TestTempDirectory.cleanup(scratch) }
        let saved = RouteParityHarness.SigningEnvironment(keyFile: try RouteParityHarness.writeSigningKey(in: scratch))
        defer { saved.restore() }

        let root = scratch.appendingPathComponent("root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bundle = try AnnotationEditRouteParityTests.makeBundle(in: root, inputs: scratch)
        let location = ReferenceBundleAnnotationRowLocation(trackID: "imported", rowID: try AnnotationEditRouteParityTests.firstRowID(in: bundle))
        _ = try await ReferenceBundleManualAnnotationService().updateAnnotation(
            location, name: "-10 box", type: "gene", strand: "-", note: "renamed in the Inspector", bundleURL: bundle
        )

        let record = bundle.appendingPathComponent(ProvenanceWriter.provenanceFilename)
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.path), "the update left no record at \(record.path)")
        XCTAssertTrue(RouteParityHarness.isSigned(record), "\(record.lastPathComponent) has no signature and public key though a key is set")
        try await SigningRecordVerification.assertVerifies(record, in: scratch, testClass: Self.self)
    }
}
