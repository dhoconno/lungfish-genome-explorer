// ReferenceBundleAnnotationImportSigningReplayTests.swift - The record of an attached annotation track is signed when a key is set
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane Q-SIGN, family L1. `ReferenceBundleAnnotationImportService.attachAnnotationTrack` writes the
// bundle's record, the one the result opens first, through `writeCanonicalProvenance`. That write built
// `ProvenanceWriter(signingProvider: nil)`, so `sequence attach-track` and the Import Center's in-process attach
// never signed it. This runs the attach in process with `LUNGFISH_PROVENANCE_SIGNING_KEY_FILE` naming a
// throwaway key under the test's folder. It sets a process variable, so its name ends in ReplayTests and it runs
// in the integration tier.

import Foundation
import LungfishCore
import XCTest
import LungfishKitTestSupport
import LungfishTestSupport
import LungfishWorkflow

@MainActor
final class ReferenceBundleAnnotationImportSigningReplayTests: XCTestCase {
    func testTheAttachRecordIsSignedWhenAKeyIsSet() async throws {
        let scratch = try TestTempDirectory.make(prefix: "attach-record-signing")
        defer { TestTempDirectory.cleanup(scratch) }
        let saved = RouteParityHarness.SigningEnvironment(keyFile: try RouteParityHarness.writeSigningKey(in: scratch))
        defer { saved.restore() }

        let root = scratch.appendingPathComponent("root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bundle = try AnnotationEditRouteParityTests.makeBundle(in: root, inputs: scratch)
        let source = root.appendingPathComponent("primers.bed")
        try "chr1\t2\t9\tprimer-left\t0\t+\nchr1\t10\t15\tprimer-right\t0\t-\n"
            .write(to: source, atomically: true, encoding: .utf8)

        let result = try await ReferenceBundleAnnotationImportService(toolName: LungfishAppIdentity.recordedToolName, toolKind: LungfishAppIdentity.recordedToolKind).attachAnnotationTrack(
            sourceURL: source,
            bundleURL: bundle,
            trackID: "primers",
            trackName: "primers v2",
            invocationArgv: ["lungfish-cli", "sequence", "attach-track", bundle.path, source.path]
        )
        XCTAssertEqual(result.featureCount, 2)

        let record = bundle.appendingPathComponent(ProvenanceWriter.provenanceFilename)
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.path), "the attach left no record at \(record.path)")
        XCTAssertTrue(RouteParityHarness.isSigned(record), "\(record.lastPathComponent) has no signature and public key though a key is set")
        try await SigningRecordVerification.assertVerifies(record, in: scratch, testClass: Self.self)
    }

    /// Phase 2.10 fix FX-QSIGN, ARCH Fix 3. With a key set the writer replaces the record, publishes
    /// `<record>.signature.json` and then `<record>.pub`. A failure on the key reaches the attach's rollback, which
    /// put back the record and `provenance/` and left the new signature beside the old record, whose bytes it no
    /// longer signs. A non-empty folder at the key's name makes the key's publication fail after the signature's.
    func testAFailedSignedAttachLeavesNoSignatureBesideTheRestoredRecord() async throws {
        let scratch = try TestTempDirectory.make(prefix: "attach-record-signing-rollback")
        defer { TestTempDirectory.cleanup(scratch) }
        let root = scratch.appendingPathComponent("root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bundle = try AnnotationEditRouteParityTests.makeBundle(in: root, inputs: scratch)
        let source = root.appendingPathComponent("primers.bed")
        try "chr1\t2\t9\tprimer-left\t0\t+\nchr1\t10\t15\tprimer-right\t0\t-\n"
            .write(to: source, atomically: true, encoding: .utf8)
        let service = ReferenceBundleAnnotationImportService(toolName: LungfishAppIdentity.recordedToolName, toolKind: LungfishAppIdentity.recordedToolKind)

        // An attach with no key leaves an unsigned record, which a failed signed attach must give back as it was.
        XCTAssertNil(ProvenanceSigningConfiguration.defaultProvider(), "an ambient signing key would sign the first attach")
        _ = try await service.attachAnnotationTrack(
            sourceURL: source, bundleURL: bundle, trackID: "primers", trackName: "primers v1",
            invocationArgv: ["lungfish-cli", "sequence", "attach-track", bundle.path, source.path]
        )
        let record = bundle.appendingPathComponent(ProvenanceWriter.provenanceFilename)
        let before = try Data(contentsOf: record)

        let saved = RouteParityHarness.SigningEnvironment(keyFile: try RouteParityHarness.writeSigningKey(in: scratch))
        defer { saved.restore() }
        let keyURL = ProvenanceSigningConfiguration.publicKeyURL(for: record)
        try FileManager.default.createDirectory(at: keyURL, withIntermediateDirectories: true)
        try "blocks the key".write(to: keyURL.appendingPathComponent("blocker.txt"), atomically: true, encoding: .utf8)

        do {
            _ = try await service.attachAnnotationTrack(
                sourceURL: source, bundleURL: bundle, trackID: "primers2", trackName: "primers v2",
                invocationArgv: ["lungfish-cli", "sequence", "attach-track", bundle.path, source.path]
            )
            XCTFail("the attach succeeded though the public key could not be published")
        } catch {
            XCTAssertTrue("\(error)".contains(keyURL.lastPathComponent), "the attach failed for another reason: \(error)")
        }

        let signature = ProvenanceSigningConfiguration.signatureURL(for: record)
        XCTAssertEqual(try Data(contentsOf: record), before, "the failed attach did not give back the record it replaced")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: signature.path),
            "\(signature.lastPathComponent) stays beside the restored record, a signature over bytes the record no longer holds"
        )
    }
}
