// SequenceAnnotationDeleteSigningReplayTests.swift - The record of an annotation deletion is signed when a key is set
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane Q-SIGN, family L1. `SequenceAnnotationTrackWorkflow.deleteAnnotations` writes the bundle's record
// through `writeDeleteAnnotationsProvenance`, which built `ProvenanceWriter(signingProvider: nil)`, so the record
// `sequence delete-annotations` and the drawer's deletion leave in the bundle never signed, though it is the record
// the result opens first. AnnotationEditRouteParityTests compares the app's call with the leaf in process and has no
// three-side run. This runs the deletion in process with `LUNGFISH_PROVENANCE_SIGNING_KEY_FILE` naming a throwaway
// key under the test's folder. It sets a process variable, so its name ends in ReplayTests and it runs in the
// integration tier.

import Foundation
import LungfishCore
import XCTest
import LungfishKitTestSupport
import LungfishTestSupport
import LungfishWorkflow

@MainActor
final class SequenceAnnotationDeleteSigningReplayTests: XCTestCase {
    func testTheDeletionRecordIsSignedWhenAKeyIsSet() async throws {
        let scratch = try TestTempDirectory.make(prefix: "annotation-delete-signing")
        defer { TestTempDirectory.cleanup(scratch) }
        let saved = RouteParityHarness.SigningEnvironment(keyFile: try RouteParityHarness.writeSigningKey(in: scratch))
        defer { saved.restore() }

        let root = scratch.appendingPathComponent("root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bundle = try AnnotationEditRouteParityTests.makeBundle(in: root, inputs: scratch)
        let location = ReferenceBundleAnnotationRowLocation(trackID: "imported", rowID: try AnnotationEditRouteParityTests.firstRowID(in: bundle))
        _ = try await ReferenceBundleManualAnnotationService(toolName: LungfishAppIdentity.recordedToolName).deleteAnnotation(location, bundleURL: bundle)

        let record = bundle.appendingPathComponent(ProvenanceWriter.provenanceFilename)
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.path), "the deletion left no record at \(record.path)")
        XCTAssertTrue(RouteParityHarness.isSigned(record), "\(record.lastPathComponent) has no signature and public key though a key is set")
        try await SigningRecordVerification.assertVerifies(record, in: scratch, testClass: Self.self)
    }
}
