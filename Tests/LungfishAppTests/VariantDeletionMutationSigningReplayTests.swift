// VariantDeletionMutationSigningReplayTests.swift - The record of a variant deletion is signed when a key is set
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane Q-SIGN, family L1. `VariantDeletionMutationService` builds its record writer as
// `ProvenanceWriter(signingProvider: nil)`, so the record `variants delete` and the drawer's deletion leave in
// the bundle never signed, though it is the record the result opens first. VariantEditRouteParityTests compares
// the drawer's call with the leaf in process and has no three-side run. This runs the deletion in process with
// `LUNGFISH_PROVENANCE_SIGNING_KEY_FILE` naming a throwaway key under the test's folder. It sets a process
// variable, so its name ends in ReplayTests and it runs in the integration tier.

import Foundation
import XCTest
import LungfishCore
import LungfishKitTestSupport
import LungfishTestSupport
@testable import LungfishWorkflow

@MainActor
final class VariantDeletionMutationSigningReplayTests: XCTestCase {
    func testTheDeletionRecordIsSignedWhenAKeyIsSet() async throws {
        let scratch = try TestTempDirectory.make(prefix: "variant-deletion-signing")
        defer { TestTempDirectory.cleanup(scratch) }
        let saved = RouteParityHarness.SigningEnvironment(keyFile: try RouteParityHarness.writeSigningKey(in: scratch))
        defer { saved.restore() }

        let root = scratch.appendingPathComponent("root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fixture = try VariantEditFixture.make(in: root, withTrackManifest: true)
        let selection = [VariantEditFixture.trackID: [try XCTUnwrap(fixture.variantIDs().first)]]
        let target = VariantDeletionMutationTarget(
            trackId: VariantEditFixture.trackID, databaseURL: fixture.databaseURL, trackName: VariantEditFixture.trackName
        )
        let arguments = VariantDeletionMutationService.deleteSelectedArguments(bundleURL: fixture.bundleURL, idsByTrack: selection)
        _ = try VariantDeletionMutationService(toolName: LungfishAppIdentity.recordedToolName, toolKind: LungfishAppIdentity.recordedToolKind).deleteVariants(
            idsByTrack: selection, bundleURL: fixture.bundleURL, targets: [target],
            invocationArgv: [CLICommandIdentity.executableName] + arguments
        )

        let record = fixture.bundleURL.appendingPathComponent(ProvenanceWriter.provenanceFilename)
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.path), "the deletion left no record at \(record.path)")
        XCTAssertTrue(RouteParityHarness.isSigned(record), "\(record.lastPathComponent) has no signature and public key though a key is set")
        try await SigningRecordVerification.assertVerifies(record, in: scratch, testClass: Self.self)
    }
}
