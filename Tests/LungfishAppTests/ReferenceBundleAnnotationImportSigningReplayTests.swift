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

        let result = try await ReferenceBundleAnnotationImportService().attachAnnotationTrack(
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
}
