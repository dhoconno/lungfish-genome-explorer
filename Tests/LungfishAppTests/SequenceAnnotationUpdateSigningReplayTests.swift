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
import LungfishCore
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
        _ = try await ReferenceBundleManualAnnotationService(toolName: LungfishAppIdentity.recordedToolName).updateAnnotation(
            location, name: "-10 box", type: "gene", strand: "-", note: "renamed in the Inspector", bundleURL: bundle
        )

        let record = bundle.appendingPathComponent(ProvenanceWriter.provenanceFilename)
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.path), "the update left no record at \(record.path)")
        XCTAssertTrue(RouteParityHarness.isSigned(record), "\(record.lastPathComponent) has no signature and public key though a key is set")
        try await SigningRecordVerification.assertVerifies(record, in: scratch, testClass: Self.self)
    }

    /// Phase 2.10 fix FX-QSIGN, ARCH Fix 3. With a key set the writer replaces the record, publishes
    /// `<record>.signature.json` and then `<record>.pub`. A failure on the key reaches the update's rollback, which
    /// put back the record and `provenance/` and left the new signature beside the old record, whose bytes it no
    /// longer signs. A non-empty folder at the key's name makes the key's publication fail after the signature's.
    func testAFailedSignedUpdateLeavesNoSignatureBesideTheRestoredRecord() async throws {
        let scratch = try TestTempDirectory.make(prefix: "annotation-update-signing-rollback")
        defer { TestTempDirectory.cleanup(scratch) }
        let root = scratch.appendingPathComponent("root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bundle = try AnnotationEditRouteParityTests.makeBundle(in: root, inputs: scratch)
        let location = ReferenceBundleAnnotationRowLocation(trackID: "imported", rowID: try AnnotationEditRouteParityTests.firstRowID(in: bundle))
        let service = ReferenceBundleManualAnnotationService(toolName: LungfishAppIdentity.recordedToolName)

        // An update with no key leaves an unsigned record, which a failed signed update must give back as it was.
        XCTAssertNil(ProvenanceSigningConfiguration.defaultProvider(), "an ambient signing key would sign the first update")
        _ = try await service.updateAnnotation(location, name: "first", type: "gene", strand: "+", note: "before the key", bundleURL: bundle)
        let record = bundle.appendingPathComponent(ProvenanceWriter.provenanceFilename)
        let before = try Data(contentsOf: record)

        let saved = RouteParityHarness.SigningEnvironment(keyFile: try RouteParityHarness.writeSigningKey(in: scratch))
        defer { saved.restore() }
        let keyURL = ProvenanceSigningConfiguration.publicKeyURL(for: record)
        try FileManager.default.createDirectory(at: keyURL, withIntermediateDirectories: true)
        try "blocks the key".write(to: keyURL.appendingPathComponent("blocker.txt"), atomically: true, encoding: .utf8)

        do {
            _ = try await service.updateAnnotation(location, name: "second", type: "gene", strand: "-", note: "signed, key blocked", bundleURL: bundle)
            XCTFail("the update succeeded though the public key could not be published")
        } catch {
            XCTAssertTrue("\(error)".contains(keyURL.lastPathComponent), "the update failed for another reason: \(error)")
        }

        let signature = ProvenanceSigningConfiguration.signatureURL(for: record)
        XCTAssertEqual(try Data(contentsOf: record), before, "the failed update did not give back the record it replaced")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: signature.path),
            "\(signature.lastPathComponent) stays beside the restored record, a signature over bytes the record no longer holds"
        )
    }
}
