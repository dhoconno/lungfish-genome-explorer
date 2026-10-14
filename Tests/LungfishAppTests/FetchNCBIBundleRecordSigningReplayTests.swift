// FetchNCBIBundleRecordSigningReplayTests.swift - The rewritten record of a fetched NCBI bundle is signed when a key is set
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane Q-SIGN, family L5. `fetch ncbi --bundle`, `fetch pathoplexus` and `fetch sra download --bundle`
// build the bundle in a staging folder, move it into the output folder and rewrite its record in the final place
// (`FetchNCBIBundleRecord.rebase`). That rewrite built `ProvenanceWriter(signingProvider: nil)`, so the record the
// bundle opens first never signed on the CLI route. This builds a bundle in process against the loopback NCBI
// stand-in, then rewrites its record with `LUNGFISH_PROVENANCE_SIGNING_KEY_FILE` naming a throwaway key under the
// test's folder. It sets process variables and runs the managed bgzip and samtools, so its name ends in
// ReplayTests and it runs in the integration tier.

import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCLI
@testable import LungfishCore
@testable import LungfishWorkflow
import LungfishKitTestSupport
import LungfishTestSupport

@MainActor
final class FetchNCBIBundleRecordSigningReplayTests: XCTestCase {
    func testTheRewrittenBundleRecordIsSignedWhenAKeyIsSet() async throws {
        do {
            try await GenBankDownloadBundleBuilder(ncbiService: NCBIService(apiKey: nil, environment: [:])).validateTools()
        } catch {
            try ToolAvailability.skipOrFail("Managed bgzip and samtools are required: \(error)")
        }
        let scratch = try TestTempDirectory.make(prefix: "fetch-record-signing")
        defer { TestTempDirectory.cleanup(scratch) }
        let server = try await NCBIGenomeStandIn.start(servingIn: scratch.appendingPathComponent("served", isDirectory: true))
        defer { server.stop() }
        let saved = ProcessEnvironmentOverride(
            set: [NCBIServiceEndpoints.standInOriginVariable: server.baseURL.absoluteString], unset: ["NCBI_API_KEY"])
        defer { saved.restore() }
        let signing = RouteParityHarness.SigningEnvironment(keyFile: try RouteParityHarness.writeSigningKey(in: scratch))
        defer { signing.restore() }

        // The in-process row leaves a bundle with the builder's record in the project's Downloads folder.
        let root = scratch.appendingPathComponent("root", isDirectory: true)
        try DatabaseBrowserNucleotideRowParityReplayTests.makeProject(root)
        let outcome = try await DatabaseBrowserNucleotideRowParityReplayTests.sideA(
            root, record: DatabaseBrowserNucleotideRowParityReplayTests.record(of: .recordWithGFF3)
        )
        XCTAssertEqual(outcome.end, .completed, outcome.detail)
        let bundle = try DatabaseBrowserNucleotideRowParityReplayTests.onlyBundle(in: root)

        try FetchNCBIBundleRecord.rebase(bundle: bundle, from: scratch.appendingPathComponent("staging", isDirectory: true))
        let record = bundle.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.path), "the rewrite left no record at \(record.path)")
        XCTAssertTrue(RouteParityHarness.isSigned(record), "\(record.lastPathComponent) has no signature and public key though a key is set")
    }
}
