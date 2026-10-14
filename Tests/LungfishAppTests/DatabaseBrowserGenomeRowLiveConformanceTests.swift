// DatabaseBrowserGenomeRowLiveConformanceTests.swift - The genome row's requests to the real NCBI on both routes
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A44, panel decision G5 and the 2.9 O5 ruling. With LUNGFISH_LIVE_NCBI=1, one
// genome row fetches a small real assembly from NCBI on the in-process route and on the CLI route,
// each through a loopback recorder that forwards every request to NCBI and points the summary's
// FTP folder at itself. The class compares the requests the two routes sent, method, target and
// body, and never the bundles, which follow what NCBI serves that day. The CLI route also searches
// for the accession, which the browser's row already holds from the user's search, so that request
// is checked on its own. NCBI answers a client over its rate limit with HTTP 429, and the service
// then sends the same request again, so the routes start a second apart and the compare leaves out
// each request NCBI answered 429. Without the switch, or without the managed bgzip and samtools,
// it skips, and DatabaseBrowserGenomeRowParityReplayTests on the stand-in stays the default.

import Foundation
import Synchronization
import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishWorkflow
import LungfishIO
import LungfishKitTestSupport
import LungfishTestSupport

final class DatabaseBrowserGenomeRowLiveConformanceTests: XCTestCase {
    static let switchVariable = "LUNGFISH_LIVE_NCBI"
    /// SARS-CoV-2 Wuhan-Hu-1, one 30 kb sequence with its annotations.
    static let accession = "GCF_009858895.2"
    static let searchPath = "/entrez/eutils/esearch.fcgi"

    @MainActor
    func testBothRoutesSendNCBITheSameRequests() async throws {
        guard ProcessInfo.processInfo.environment[Self.switchVariable] == "1" else {
            throw XCTSkip("Set \(Self.switchVariable)=1 to fetch \(Self.accession) from NCBI on both routes")
        }
        do {
            try await GenomeDownloadBundleBuilder(ncbiService: NCBIService(apiKey: nil, environment: [:])).validateTools()
        } catch {
            try ToolAvailability.skipOrFail("Managed bgzip and samtools are required: \(error)")
        }
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let cli = try XCTUnwrap(CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: products))
        let root = try TestTempDirectory.make(prefix: "genome-row-live")
        defer { TestTempDirectory.cleanup(root) }
        let recorder = try NCBIForwardingRecorder.start()
        defer { recorder.stop() }
        let saved = ProcessEnvironmentOverride(
            set: [NCBIServiceEndpoints.standInOriginVariable: recorder.baseURL.absoluteString], unset: ["NCBI_API_KEY"])
        defer { saved.restore() }

        // The user's search, which gives the browser's row its id.
        let service = NCBIService()
        let search = try await service.searchGenome(term: Self.accession, retmax: 1)
        let uid = try XCTUnwrap(search.ids.first)
        let record = SearchResultRecord(id: uid, accession: Self.accession, title: Self.accession, source: .ncbi)

        var requests: [GenomeRowDownloadRoute: [LoopbackHTTPRequest]] = [:]
        var rateLimited = 0
        for route in [GenomeRowDownloadRoute.legacy, .cli] {
            // Without a key NCBI takes three E-utilities requests a second, so each route starts a
            // second after the requests before it.
            try await Task.sleep(for: .seconds(1))
            let project = root.appendingPathComponent("\(route.rawValue)/Project.lungfish", isDirectory: true)
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            let start = recorder.answered.count
            _ = try await DatabaseBrowserViewModel.downloadGenomeRow(
                record, index: 0, totalCount: 1, operationID: UUID(), route: route,
                ncbi: service, genomeVM: GenomeDownloadViewModel(ncbiService: service),
                batchFolder: BatchDownloadFolder(projectURL: project),
                projectURL: project, cliURLOverride: cli)
            let answered = Array(recorder.answered.dropFirst(start))
            rateLimited += answered.filter { $0.status == Self.rateLimitedStatus }.count
            requests[route] = Self.withoutRateLimited(answered)
        }
        if rateLimited > 0 {
            print("NCBI answered \(rateLimited) request(s) with HTTP 429, and the service sent each again")
        }

        let inProcess = requests[.legacy] ?? []
        let throughCLI = requests[.cli] ?? []
        let searches = throughCLI.filter { $0.path == Self.searchPath }
        XCTAssertEqual(searches.count, 1)
        XCTAssertEqual(searches.first?.queryItems.first { $0.name == "term" }?.value, Self.accession)
        XCTAssertFalse(inProcess.isEmpty)
        XCTAssertEqual(Self.bytes(inProcess), Self.bytes(throughCLI.filter { $0.path != Self.searchPath }))
    }

    /// Method, target and body of each request, in order.
    static func bytes(_ requests: [LoopbackHTTPRequest]) -> [String] {
        requests.map { "\($0.method) \($0.target) \($0.body.base64EncodedString())" }
    }

    /// NCBI's answer to a client over its rate limit.
    static let rateLimitedStatus = 429

    /// The requests of `answered` less each one NCBI answered with HTTP 429. The service waits and
    /// sends the same request again (`NCBIService.makeRequest`), which the recorder also counts, so
    /// the compare holds whether or not NCBI limited a route that day (landing 5, open item 7).
    static func withoutRateLimited(_ answered: [NCBIForwardingRecorder.Answer]) -> [LoopbackHTTPRequest] {
        answered.filter { $0.status != rateLimitedStatus }.map(\.request)
    }

    /// A 429 answer drops out, and the request the service sent again stays.
    func testARateLimitedRequestDropsOutOfTheCompare() {
        let search = LoopbackHTTPRequest(method: "GET", target: Self.searchPath + "?term=x", headerLines: [], body: Data())
        let summary = LoopbackHTTPRequest(method: "GET", target: "/entrez/eutils/esummary.fcgi?id=1", headerLines: [], body: Data())
        let answered = [
            NCBIForwardingRecorder.Answer(request: search, status: 200),
            NCBIForwardingRecorder.Answer(request: summary, status: Self.rateLimitedStatus),
            NCBIForwardingRecorder.Answer(request: summary, status: 200),
        ]
        XCTAssertEqual(Self.bytes(Self.withoutRateLimited(answered)), Self.bytes([search, summary]))
    }
}

/// A loopback recorder that forwards each request to NCBI, E-utilities or the FTP site by its
/// path, and rewrites the FTP folder of an assembly summary to itself, so the files come through
/// it too. It always fetches the whole answer, so a HEAD request gets the length a GET would.
final class NCBIForwardingRecorder: Sendable {
    /// A request and the status NCBI answered it with.
    struct Answer: Sendable {
        let request: LoopbackHTTPRequest
        let status: Int
    }

    private let server: LoopbackHTTPStandIn
    private let log: LockedValue<[Answer]>
    var baseURL: URL { server.baseURL }
    var requests: [LoopbackHTTPRequest] { server.requests }
    /// Each request with NCBI's status, in the order the answers came back.
    var answered: [Answer] { log.value }

    private init(server: LoopbackHTTPStandIn, log: LockedValue<[Answer]>) {
        self.server = server
        self.log = log
    }

    static func start() throws -> NCBIForwardingRecorder {
        let base = LockedValue("")
        let log = LockedValue<[Answer]>([])
        let server = try LoopbackHTTPStandIn.start { request in
            let response = forward(request, base: base.value)
            log.append(Answer(request: request, status: response.status))
            return response
        }
        base.value = server.baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return NCBIForwardingRecorder(server: server, log: log)
    }

    func stop() {
        server.stop()
    }

    private static func forward(_ request: LoopbackHTTPRequest, base: String) -> LoopbackHTTPResponse {
        let host = request.path.hasPrefix("/genomes/") ? "https://ftp.ncbi.nlm.nih.gov" : "https://eutils.ncbi.nlm.nih.gov"
        guard let url = URL(string: host + request.target) else { return LoopbackHTTPResponse(status: 400) }
        let answer = LockedValue<(Data, Int, String)?>(nil)
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: URLRequest(url: url, timeoutInterval: 60)) { data, response, _ in
            let http = response as? HTTPURLResponse
            answer.value = (data ?? Data(), http?.statusCode ?? 502, http?.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream")
            done.signal()
        }.resume()
        guard done.wait(timeout: .now() + 90) == .success, let (body, status, type) = answer.value else {
            return LoopbackHTTPResponse(status: 504)
        }
        guard request.path == "/entrez/eutils/esummary.fcgi" else {
            return LoopbackHTTPResponse(status: status, contentType: type, body: body)
        }
        let text = String(decoding: body, as: UTF8.self)
            .replacingOccurrences(of: "ftp://ftp.ncbi.nlm.nih.gov", with: base)
            .replacingOccurrences(of: "https://ftp.ncbi.nlm.nih.gov", with: base)
        return LoopbackHTTPResponse(status: status, contentType: type, body: Data(text.utf8))
    }
}

/// One value behind a lock, which an escaping closure can capture.
private final class LockedValue<Value: Sendable>: Sendable {
    private let mutex: Mutex<Value>

    init(_ value: Value) {
        mutex = Mutex(value)
    }

    var value: Value {
        get { mutex.withLock { $0 } }
        set { mutex.withLock { $0 = newValue } }
    }

    func append<Element: Sendable>(_ element: Element) where Value == [Element] {
        mutex.withLock { $0.append(element) }
    }
}
