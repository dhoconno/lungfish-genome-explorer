// DatabaseBrowserPathoplexusRowLiveConformanceTests.swift - The Pathoplexus row's requests to the real Pathoplexus and NCBI on both routes
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A45 M2, panel decision G5 and the 2.9 O5 ruling, as DatabaseBrowserNucleotideRowLiveConformanceTests
// checks a nucleotide row. With LUNGFISH_LIVE_PATHOPLEXUS=1, one Pathoplexus row of the browser's batch
// download reads a small real record from Pathoplexus on the in-process route and on the CLI route, each
// through loopback recorders that forward every request to Pathoplexus's LAPIS and, for the GenBank record
// the row prefers, to NCBI. The class compares the requests the two routes sent to each, method, target and
// body, and never the bundles, which follow what Pathoplexus and NCBI serve that day. NCBI answers a client
// over its rate limit with HTTP 429, and the service then sends the same request again, so the routes start
// a second apart and the compare leaves out each request NCBI answered 429. Without the switch, or without
// the managed bgzip and samtools, it skips, and DatabaseBrowserPathoplexusRowParityReplayTests on the
// stand-ins stays the default.

import Foundation
import Synchronization
import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishWorkflow
import LungfishIO
import LungfishKitTestSupport
import LungfishTestSupport

final class DatabaseBrowserPathoplexusRowLiveConformanceTests: XCTestCase {
    static let switchVariable = "LUNGFISH_LIVE_PATHOPLEXUS"
    /// A West Nile virus record of 1,110 bases with an INSDC accession, open data use terms.
    static let accession = "PP_00005PG"
    static let organism = "west-nile"

    @MainActor
    func testBothRoutesSendPathoplexusAndNCBITheSameRequests() async throws {
        guard ProcessInfo.processInfo.environment[Self.switchVariable] == "1" else {
            throw XCTSkip("Set \(Self.switchVariable)=1 to fetch \(Self.accession) from Pathoplexus on both routes")
        }
        do {
            try await GenBankDownloadBundleBuilder(ncbiService: NCBIService(apiKey: nil, environment: [:])).validateTools()
        } catch {
            try ToolAvailability.skipOrFail("Managed bgzip and samtools are required: \(error)")
        }
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let cli = try XCTUnwrap(CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: products))
        let root = try TestTempDirectory.make(prefix: "pathoplexus-row-live")
        defer { TestTempDirectory.cleanup(root) }
        let ncbi = try NCBIForwardingRecorder.start()
        defer { ncbi.stop() }
        let lapis = try LAPISForwardingRecorder.start()
        defer { lapis.stop() }
        let saved = ProcessEnvironmentOverride(
            set: [
                NCBIServiceEndpoints.standInOriginVariable: ncbi.baseURL.absoluteString,
                PathoplexusServiceEndpoints.standInOriginVariable: lapis.baseURL.absoluteString,
            ],
            unset: ["NCBI_API_KEY"])
        defer { saved.restore() }

        let service = NCBIService()
        let record = SearchResultRecord(id: Self.accession, accession: Self.accession, title: Self.accession, source: .pathoplexus)

        var toNCBI: [PathoplexusRowDownloadRoute: [LoopbackHTTPRequest]] = [:]
        var toLAPIS: [PathoplexusRowDownloadRoute: [LoopbackHTTPRequest]] = [:]
        var rateLimited = 0
        for route in [PathoplexusRowDownloadRoute.legacy, .cli] {
            // Without a key NCBI takes three E-utilities requests a second, so each route starts a
            // second after the requests before it.
            try await Task.sleep(for: .seconds(1))
            let project = root.appendingPathComponent("\(route.rawValue)/Project.lungfish", isDirectory: true)
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            let ncbiStart = ncbi.answered.count
            let lapisStart = lapis.requests.count
            _ = try await DatabaseBrowserViewModel.downloadPathoplexusRow(
                record, index: 0, totalCount: 1, operationID: UUID(), route: route, organism: Self.organism,
                ncbi: service, genBankVM: GenBankBundleDownloadViewModel(ncbiService: service),
                includeGFF3Annotations: true, batchFolder: BatchDownloadFolder(projectURL: project),
                projectURL: project, cliURLOverride: cli)
            let answered = Array(ncbi.answered.dropFirst(ncbiStart))
            rateLimited += answered.filter { $0.status == DatabaseBrowserGenomeRowLiveConformanceTests.rateLimitedStatus }.count
            toNCBI[route] = DatabaseBrowserGenomeRowLiveConformanceTests.withoutRateLimited(answered)
            toLAPIS[route] = Array(lapis.requests.dropFirst(lapisStart))
        }
        if rateLimited > 0 {
            print("NCBI answered \(rateLimited) request(s) with HTTP 429, and the service sent each again")
        }

        XCTAssertFalse(toLAPIS[.legacy]?.isEmpty ?? true, "the in-process route read nothing from Pathoplexus")
        XCTAssertEqual(
            DatabaseBrowserGenomeRowLiveConformanceTests.bytes(toLAPIS[.legacy] ?? []),
            DatabaseBrowserGenomeRowLiveConformanceTests.bytes(toLAPIS[.cli] ?? []), "requests to Pathoplexus")
        XCTAssertEqual(
            DatabaseBrowserGenomeRowLiveConformanceTests.bytes(toNCBI[.legacy] ?? []),
            DatabaseBrowserGenomeRowLiveConformanceTests.bytes(toNCBI[.cli] ?? []), "requests to NCBI")
    }
}

/// A loopback recorder that forwards each request to Pathoplexus's LAPIS, whatever its path, and
/// records the request. Pathoplexus takes no key, so it adds none.
final class LAPISForwardingRecorder: Sendable {
    private let server: LoopbackHTTPStandIn
    var baseURL: URL { server.baseURL }
    var requests: [LoopbackHTTPRequest] { server.requests }

    private init(server: LoopbackHTTPStandIn) {
        self.server = server
    }

    static func start() throws -> LAPISForwardingRecorder {
        LAPISForwardingRecorder(server: try LoopbackHTTPStandIn.start { forward($0) })
    }

    func stop() {
        server.stop()
    }

    private static func forward(_ request: LoopbackHTTPRequest) -> LoopbackHTTPResponse {
        guard let url = URL(string: "https://lapis.pathoplexus.org" + request.target) else { return LoopbackHTTPResponse(status: 400) }
        let answer = Mutex<(Data, Int, String)?>(nil)
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: URLRequest(url: url, timeoutInterval: 60)) { data, response, _ in
            let http = response as? HTTPURLResponse
            answer.withLock {
                $0 = (data ?? Data(), http?.statusCode ?? 502, http?.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream")
            }
            done.signal()
        }.resume()
        guard done.wait(timeout: .now() + 90) == .success, let (body, status, type) = answer.withLock({ $0 }) else {
            return LoopbackHTTPResponse(status: 504)
        }
        return LoopbackHTTPResponse(status: status, contentType: type, body: body)
    }
}
