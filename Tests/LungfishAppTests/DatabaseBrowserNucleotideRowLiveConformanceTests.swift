// DatabaseBrowserNucleotideRowLiveConformanceTests.swift - The nucleotide row's requests to the real NCBI
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A45 M1b, panel decision G5 and the 2.9 O5 ruling, as lane A44 checks a genome row
// (DatabaseBrowserGenomeRowLiveConformanceTests). With LUNGFISH_LIVE_NCBI=1, one nucleotide row of
// the NCBI browser's batch download fetches a small real record from NCBI on the CLI route, through
// a loopback recorder that forwards every request to NCBI. Until lane A60 of 2.11 deleted the
// in-process route with its hidden key, the class compared the requests of the two routes. It now
// checks that the CLI route asks NCBI and never searches, because the row already holds the
// accession from the user's search, and never reads the bundle, which follows what NCBI serves that
// day. NCBI answers a client over its rate limit with HTTP 429, and the service then sends the same
// request again, so the check leaves out each request NCBI answered 429. Without the switch, or
// without the managed bgzip and samtools, it skips, and DatabaseBrowserNucleotideRowParityReplayTests
// on the stand-in stays the default.

import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishWorkflow
import LungfishIO
import LungfishKitTestSupport
import LungfishTestSupport

final class DatabaseBrowserNucleotideRowLiveConformanceTests: XCTestCase {
    static let switchVariable = DatabaseBrowserGenomeRowLiveConformanceTests.switchVariable
    /// Enterobacteria phage phiX174, one 5.4 kb sequence with its annotations.
    static let accession = "NC_001422.1"

    @MainActor
    func testBothRoutesSendNCBITheSameRequests() async throws {
        guard ProcessInfo.processInfo.environment[Self.switchVariable] == "1" else {
            throw XCTSkip("Set \(Self.switchVariable)=1 to fetch \(Self.accession) from NCBI on both routes")
        }
        do {
            try await GenBankDownloadBundleBuilder(ncbiService: NCBIService(apiKey: nil, environment: [:])).validateTools()
        } catch {
            try ToolAvailability.skipOrFail("Managed bgzip and samtools are required: \(error)")
        }
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let cli = try XCTUnwrap(CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: products))
        let root = try TestTempDirectory.make(prefix: "nucleotide-row-live")
        defer { TestTempDirectory.cleanup(root) }
        let recorder = try NCBIForwardingRecorder.start()
        defer { recorder.stop() }
        let saved = ProcessEnvironmentOverride(
            set: [NCBIServiceEndpoints.standInOriginVariable: recorder.baseURL.absoluteString], unset: ["NCBI_API_KEY"])
        defer { saved.restore() }

        let service = NCBIService()
        let record = SearchResultRecord(id: Self.accession, accession: Self.accession, title: Self.accession, source: .ncbi)

        let project = root.appendingPathComponent("cli/Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let start = recorder.answered.count
        _ = try await DatabaseBrowserViewModel.downloadNucleotideRow(
            record, index: 0, totalCount: 1, operationID: UUID(), ncbi: service,
            includeGFF3Annotations: true, projectURL: project, cliURLOverride: cli)
        let answered = Array(recorder.answered.dropFirst(start))
        let rateLimited = answered.filter { $0.status == DatabaseBrowserGenomeRowLiveConformanceTests.rateLimitedStatus }.count
        if rateLimited > 0 {
            print("NCBI answered \(rateLimited) request(s) with HTTP 429, and the service sent each again")
        }

        let throughCLI = DatabaseBrowserGenomeRowLiveConformanceTests.withoutRateLimited(answered)
        XCTAssertFalse(throughCLI.isEmpty, "the row asked NCBI")
        XCTAssertFalse(
            throughCLI.contains { $0.path == DatabaseBrowserGenomeRowLiveConformanceTests.searchPath },
            "the row holds its accession and never searches")
    }
}
