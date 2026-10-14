// FetchNCBIFetchedRecordReplayTests.swift - The records of lungfish-cli's NCBI fetches name what they fetched as a live snapshot
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A45 M2, ruling K7 (`ruling-A45-M1.md` section 4) and the manager's grant 4. A record
// fetched from NCBI on the day of the run is a live snapshot (2.9 R3). The CLI's records add the
// status, in the shape of `NextflowDatabaseEntry` (role `fetchedRecord`), so a reader knows the
// record names the source as it stood on that day.
//
// - `fetch ncbi --bundle` runs the GenBank bundle builder, which already records the versioned
//   accession, the date of the fetch and the digest of the kept `sources/record.gb`, so the entry
//   lists that file and takes the fetch step's date.
// - `fetch genome` records each fetched file under its source URL with its digest, and keeps none
//   of them, so its entry has the date of the run's start and lists no file.
//
// The in-process routes do not record the entry, so the record pins of lane A44 hold until 2.11. Both
// tests run the built CLI on the loopback NCBI stand-in. They launch the built CLI and the managed
// bgzip and samtools, so the class name ends in ReplayTests, which sends it to the integration tier.

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
        try await runAndLoadRecord(["fetch", "ncbi", NCBIDownloadPinFixtures.genBankAccession, "--bundle"]) { envelope, bundle in
            let entry = try Self.fetchedRecord(in: envelope)
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

    func testTheFetchGenomeRecordNamesTheFetchedRecordAsALiveSnapshot() async throws {
        let before = Date().addingTimeInterval(-1)
        try await runAndLoadRecord(["fetch", "genome", NCBIGenomeStandIn.assemblyAccession]) { envelope, _ in
            let after = Date().addingTimeInterval(1)
            let entry = try Self.fetchedRecord(in: envelope)
            XCTAssertEqual(DatabaseIdentityStatus(recordedWord: entry["status"]?.stringValue ?? ""), .liveSnapshot)
            let fetchedAt = try Date(try XCTUnwrap(entry["fetchedAt"]?.stringValue), strategy: .iso8601)
            XCTAssertTrue((before...after).contains(fetchedAt), "the date of the fetch is the date of the run: \(fetchedAt)")
            XCTAssertNil(entry["listingFiles"], "the run keeps no file that lists what it fetched")
            XCTAssertFalse(envelope.files.isEmpty, "the record names each fetched file under its source URL")
        }
    }

    /// Phase 2.10 lane A45, ruling A45-M3 section 2 (finding 6). The GenBank builder records the host's
    /// argument vector for the run and for each conversion step, so a key typed with `--api-key` reached
    /// the record of the bundle. The vector is written with the key replaced by `<redacted>`, as the
    /// records of `fetch genome` and of the Conda commands write it.
    func testATypedAPIKeyReachesNoFileOfTheBundle() async throws {
        try await runAndLoadRecord(
            ["fetch", "ncbi", NCBIDownloadPinFixtures.genBankAccession, "--bundle", "--api-key", TypedAPIKeyLeak.key]
        ) { envelope, bundle in
            TypedAPIKeyLeak.assertHeldNowhere(in: bundle, envelope: envelope)
        }
    }

    // MARK: - Helpers

    /// The `fetchedRecord` entry of a record's resolved defaults.
    private static func fetchedRecord(in envelope: ProvenanceEnvelope) throws -> [String: ParameterValue] {
        guard case let .dictionary(entry)? = envelope.options.resolvedDefaults["fetchedRecord"] else {
            XCTFail("The record names no fetchedRecord: \(envelope.options.resolvedDefaults.keys.sorted())")
            throw CocoaError(.fileReadCorruptFile)
        }
        return entry
    }

    /// Runs the built CLI with `arguments`, `--output-dir <folder> --format json` added, on the
    /// stand-in, and hands the record of the one bundle it made to `check` with that bundle.
    private func runAndLoadRecord(
        _ arguments: [String],
        check: (ProvenanceEnvelope, URL) throws -> Void
    ) async throws {
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
            arguments: arguments + ["--output-dir", work.path, "--format", "json"],
            timeout: .seconds(120),
            environment: [NCBIServiceEndpoints.standInOriginVariable: server.baseURL.absoluteString, "NCBI_API_KEY": ""])
        XCTAssertEqual(run.status, 0, run.detail)

        let names = try FileManager.default.contentsOfDirectory(atPath: work.path).filter { $0.hasSuffix(".lungfishref") }
        XCTAssertEqual(names.count, 1, "\(names)")
        let bundle = work.appendingPathComponent(try XCTUnwrap(names.first), isDirectory: true)
        let envelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: bundle), "the run wrote no record")
        try check(envelope, bundle)
    }
}
