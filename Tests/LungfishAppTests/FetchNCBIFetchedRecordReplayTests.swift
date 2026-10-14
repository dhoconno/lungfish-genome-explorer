// FetchNCBIFetchedRecordReplayTests.swift - The record of fetch ncbi --bundle names the fetched record as a live snapshot
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A45 M2, ruling K7 (`ruling-A45-M1.md` section 4). A record fetched from NCBI on the
// day of the run is a live snapshot (2.9 R3). The GenBank bundle builder already records the versioned
// accession, the date of the fetch and the digest of the kept file. The CLI route adds the status, in
// the shape of `NextflowDatabaseEntry` (role `fetchedRecord`), so a reader knows the record names the
// source as it stood on that day. The in-process route does not, so the record pins of lane A44 hold
// until 2.11. The test runs the built CLI on the loopback NCBI stand-in.
//
// It launches the built CLI and the managed bgzip and samtools, so its name ends in ReplayTests,
// which sends it to the integration tier.

import Foundation
import XCTest
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
@testable import LungfishCore
@testable import LungfishWorkflow

final class FetchNCBIFetchedRecordReplayTests: XCTestCase {
    func testTheCLIRecordNamesTheFetchedRecordAsALiveSnapshot() async throws {
        do {
            try await GenBankDownloadBundleBuilder(ncbiService: NCBIService(apiKey: nil, environment: [:])).validateTools()
        } catch {
            try ToolAvailability.skipOrFail("Managed bgzip and samtools are required: \(error)")
        }
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let cli = try XCTUnwrap(
            CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: products),
            "No lungfish-cli beside \(products.path) and none named by LUNGFISH_CLI_PATH")
        let root = try TestTempDirectory.make(prefix: "fetch-ncbi-fetched-record")
        defer { TestTempDirectory.cleanup(root) }
        let server = try await NCBIGenomeStandIn.start(servingIn: root.appendingPathComponent("served", isDirectory: true))
        defer { server.stop() }
        let work = root.appendingPathComponent("work", isDirectory: true)
        let run = await RouteParityHarness.runCLI(
            cli,
            arguments: ["fetch", "ncbi", NCBIDownloadPinFixtures.genBankAccession, "--bundle", "--output-dir", work.path, "--format", "json"],
            timeout: .seconds(120),
            environment: [NCBIServiceEndpoints.standInOriginVariable: server.baseURL.absoluteString, "NCBI_API_KEY": ""])
        XCTAssertEqual(run.status, 0, run.detail)

        let names = try FileManager.default.contentsOfDirectory(atPath: work.path).filter { $0.hasSuffix(".lungfishref") }
        XCTAssertEqual(names.count, 1, "\(names)")
        let bundle = work.appendingPathComponent(try XCTUnwrap(names.first), isDirectory: true)
        let envelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: bundle), "the run wrote no record")
        guard case let .dictionary(entry)? = envelope.options.resolvedDefaults["fetchedRecord"] else {
            return XCTFail("The record names no fetchedRecord: \(envelope.options.resolvedDefaults.keys.sorted())")
        }
        XCTAssertEqual(DatabaseIdentityStatus(recordedWord: entry["status"]?.stringValue ?? ""), .liveSnapshot)

        // The date and the listing digest are the fetch step's own.
        let fetch = try XCTUnwrap(envelope.steps.first { $0.toolName == "NCBI EFetch (URLSession)" }, "the record lists no fetch step")
        let completedAt = try XCTUnwrap(fetch.completedAt)
        XCTAssertEqual(entry["fetchedAt"]?.stringValue, completedAt.formatted(.iso8601))
        guard case let .array(listings)? = entry["listingFiles"], listings.count == 1, case let .file(listing)? = listings.first else {
            return XCTFail("The entry lists one kept file: \(String(describing: entry["listingFiles"]))")
        }
        XCTAssertEqual(
            listing.resolvingSymlinksInPath().path,
            bundle.appendingPathComponent("sources/record.gb").resolvingSymlinksInPath().path,
            "the listing is the kept record, in the bundle's final place")
        XCTAssertEqual(try ProvenanceFileHasher.sha256(of: listing), fetch.outputs.first?.checksumSHA256)
    }
}
