// SRADownloadSourcePreferenceTests.swift - A download can prefer NCBI's SRA Toolkit over ENA's mirror
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
import LungfishTestSupport
@testable import LungfishCore

/// Owner request of 2026-10-05: ENA is sometimes slow, so the user can
/// prefer NCBI. With `.ncbi` the SRA Toolkit fetches the run first, and when
/// it is not installed or fails, ENA's mirror serves the run when ENA lists
/// FASTQ files for it. With `.ena` nothing changes. ENA is a scripted HTTP
/// client and the toolkit writes recorded fasterq-dump output, so no test
/// reaches the network or spawns a tool.
final class SRADownloadSourcePreferenceTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "sra-source-preference")
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    // MARK: - The plan both surfaces take

    func testPreferringENAKeepsTodaysOrder() {
        let record = Self.record(listsFiles: true)
        XCTAssertEqual(SRAFASTQDownloadRoute.enaMirror(record).plan(preferring: .ena).transfers, [.enaMirror, .sraToolkit])
        XCTAssertEqual(
            SRAFASTQDownloadRoute.sraToolkit(enaRecord: Self.record(listsFiles: false), reason: "no files").plan(preferring: .ena).transfers,
            [.sraToolkit]
        )
        XCTAssertEqual(
            SRAFASTQDownloadRoute.sraToolkit(enaRecord: nil, reason: "ENA failed").plan(preferring: .ena).transfers,
            [.sraToolkit]
        )
    }

    func testPreferringNCBITakesTheToolkitFirstAndENAOnlyWhenItListsFiles() {
        XCTAssertEqual(
            SRAFASTQDownloadRoute.enaMirror(Self.record(listsFiles: true)).plan(preferring: .ncbi).transfers,
            [.sraToolkit, .enaMirror]
        )
        XCTAssertEqual(
            SRAFASTQDownloadRoute.sraToolkit(enaRecord: Self.record(listsFiles: false), reason: "no files").plan(preferring: .ncbi).transfers,
            [.sraToolkit]
        )
        XCTAssertEqual(
            SRAFASTQDownloadRoute.sraToolkit(enaRecord: nil, reason: "ENA failed").plan(preferring: .ncbi).transfers,
            [.sraToolkit]
        )
    }

    // MARK: - Stored choice

    func testTheStoredChoiceDefaultsToENAAndRoundTrips() throws {
        let suite = "sra-source-preference-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(SRADownloadSourcePreference.stored(in: defaults), .ena)
        SRADownloadSourcePreference.ncbi.store(in: defaults)
        XCTAssertEqual(defaults.string(forKey: SRADownloadSourcePreference.userDefaultsKey), "ncbi")
        XCTAssertEqual(SRADownloadSourcePreference.stored(in: defaults), .ncbi)
        defaults.set("ddbj", forKey: SRADownloadSourcePreference.userDefaultsKey)
        XCTAssertEqual(SRADownloadSourcePreference.stored(in: defaults), .ena, "an unknown value falls back to the default")
    }

    // MARK: - Sources the fallback records

    func testTheENAFallbackNamesWhyTheToolkitFailed() {
        XCTAssertNil(SRAFASTQDownloadSource.enaFallback(afterToolkitError: CancellationError()))
        XCTAssertNil(SRAFASTQDownloadSource.enaFallback(afterToolkitError: URLError(.cancelled)))
        XCTAssertEqual(SRAFASTQDownloadSource.enaFallback(afterToolkitError: SRAError.toolkitNotFound), .enaAfterMissingToolkit)
        XCTAssertEqual(SRAFASTQDownloadSource.enaFallback(afterToolkitError: SRAError.conversionFailed("x")), .enaAfterFailedToolkit)
        XCTAssertFalse(SRAFASTQDownloadSource.enaAfterMissingToolkit.usesSRAToolkit)
        XCTAssertFalse(SRAFASTQDownloadSource.enaAfterFailedToolkit.usesSRAToolkit)
    }

    // MARK: - SRAService, preferring NCBI

    func testNCBIWithTheToolkitTakesTheToolkitAndFetchesNothingFromTheMirror() async throws {
        for portal in [ScriptedPortal.listsFiles, .listsNoFiles, .outage] {
            let outcome = try await download(preferring: .ncbi, portal: portal, toolkit: .recorded)
            XCTAssertEqual(outcome.files, ["\(Self.run)_1.fastq", "\(Self.run)_2.fastq", "\(Self.run).fastq"], "\(portal)")
            XCTAssertEqual(outcome.sources, [.sraToolkit], "\(portal)")
            XCTAssertEqual(outcome.mirrorRequests, 0, "\(portal)")
            XCTAssertTrue(outcome.fallbackMessages.isEmpty, "\(portal)")
        }
    }

    /// ENA can be slow, which is why the owner prefers NCBI, so a toolkit
    /// success must not wait on ENA's portal at all.
    func testNCBIToolkitSuccessMakesNoENARequest() async throws {
        for portal in [ScriptedPortal.listsFiles, .listsNoFiles, .outage] {
            let outcome = try await download(preferring: .ncbi, portal: portal, toolkit: .recorded)
            XCTAssertEqual(outcome.sources, [.sraToolkit], "\(portal)")
            XCTAssertEqual(outcome.portalRequests, 0, "\(portal)")
        }
    }

    /// Only when the toolkit is missing or fails is the run looked up on
    /// ENA, once, and served from ENA's mirror.
    func testNCBIToolkitFailureLooksTheRunUpOnENAAndFallsBack() async throws {
        for toolkit in [ScriptedToolkit.missing, .failsAfterWritingAMate] {
            let outcome = try await download(preferring: .ncbi, portal: .listsFiles, toolkit: toolkit)
            XCTAssertEqual(outcome.portalRequests, 1, "\(toolkit)")
            XCTAssertEqual(outcome.mirrorRequests, 2, "\(toolkit)")
            XCTAssertEqual(outcome.files, ["\(Self.run)_1.fastq.gz", "\(Self.run)_2.fastq.gz"], "\(toolkit)")
        }
    }

    func testNCBICancelledToolkitMakesNoENARequest() async throws {
        let client = ScriptedPortalClient(portal: .listsFiles, run: Self.run)
        do {
            _ = try await download(preferring: .ncbi, client: client, toolkit: .cancelled)
            XCTFail("a cancelled toolkit run must not fall back")
        } catch is CancellationError {}
        let portalRequests = await client.portalRequests
        XCTAssertEqual(portalRequests, 0)
    }

    func testNCBIWithoutTheToolkitFallsBackToENAAndSaysWhy() async throws {
        let outcome = try await download(preferring: .ncbi, portal: .listsFiles, toolkit: .missing)
        XCTAssertEqual(outcome.files, ["\(Self.run)_1.fastq.gz", "\(Self.run)_2.fastq.gz"])
        XCTAssertEqual(outcome.sources, [.enaAfterMissingToolkit])
        let message = try XCTUnwrap(outcome.fallbackMessages.first)
        XCTAssertTrue(message.contains("not installed"), message)
        XCTAssertTrue(message.contains("ENA"), message)
    }

    func testNCBIWhenTheToolkitFailsFallsBackToENAAndRemovesThePartialReads() async throws {
        let outcome = try await download(preferring: .ncbi, portal: .listsFiles, toolkit: .failsAfterWritingAMate)
        XCTAssertEqual(outcome.files, ["\(Self.run)_1.fastq.gz", "\(Self.run)_2.fastq.gz"])
        XCTAssertEqual(outcome.sources, [.enaAfterFailedToolkit])
        XCTAssertEqual(outcome.folderFASTQ, ["\(Self.run)_1.fastq.gz", "\(Self.run)_2.fastq.gz"], "the toolkit's partial mate is removed")
        XCTAssertTrue(try XCTUnwrap(outcome.fallbackMessages.first).contains("SRA Toolkit failed"))
    }

    /// Review finding S3-1: prefetch's archive (`<run>/<run>.sra`) must not
    /// stay in the user's folder when the toolkit fails and ENA serves the run.
    func testNCBIWhenFasterqDumpFailsRemovesThePrefetchArchiveBeforeFallingBack() async throws {
        let outcome = try await download(preferring: .ncbi, portal: .listsFiles, toolkit: .failsAfterPrefetch)
        XCTAssertEqual(outcome.sources, [.enaAfterFailedToolkit])
        XCTAssertEqual(outcome.folderEntries, ["\(Self.run)_1.fastq.gz", "\(Self.run)_2.fastq.gz"], "prefetch's archive folder is removed")
    }

    func testNCBIFailsWithBothReasonsWhenENACannotServeTheRunEither() async throws {
        for portal in [ScriptedPortal.listsNoFiles, .outage] {
            for toolkit in [ScriptedToolkit.missing, .failsAfterWritingAMate] {
                do {
                    let outcome = try await download(preferring: .ncbi, portal: portal, toolkit: toolkit)
                    XCTFail("\(portal) \(toolkit) must fail, got \(outcome.files)")
                } catch let error as SRAError {
                    guard case .downloadFailed(let message) = error else {
                        return XCTFail("expected downloadFailed, got \(error)")
                    }
                    XCTAssertTrue(message.contains("Toolkit"), message)
                    XCTAssertTrue(message.contains("ENA"), message)
                }
            }
        }
    }

    // MARK: - SRAService, preferring ENA (today's behaviour)

    func testENAKeepsTodaysBehaviour() async throws {
        let served = try await download(preferring: .ena, portal: .listsFiles, toolkit: .recorded)
        XCTAssertEqual(served.sources, [.ena])
        XCTAssertEqual(served.mirrorRequests, 2)

        for portal in [ScriptedPortal.listsNoFiles, .outage] {
            let fallback = try await download(preferring: .ena, portal: portal, toolkit: .recorded)
            XCTAssertEqual(fallback.sources, [.sraToolkit], "\(portal)")
            XCTAssertEqual(fallback.mirrorRequests, 0, "\(portal)")
        }

        do {
            _ = try await download(preferring: .ena, portal: .outage, toolkit: .missing)
            XCTFail("ENA down and no toolkit must fail")
        } catch is SRAError {}
    }

    func testCancellationStopsTheNCBIDownloadWithoutAFallback() async throws {
        do {
            _ = try await download(preferring: .ncbi, portal: .listsFiles, toolkit: .cancelled)
            XCTFail("a cancelled toolkit run must not fall back")
        } catch is CancellationError {}
    }

    // MARK: - Helpers

    private static let run = SRAToolkitRecordedRunner.pairedRunWithSingletons

    private struct Outcome {
        let files: [String]
        let sources: [SRAFASTQDownloadSource]
        let fallbackMessages: [String]
        let mirrorRequests: Int
        let portalRequests: Int
        let folderFASTQ: [String]
        let folderEntries: [String]
    }

    private func download(
        preferring preference: SRADownloadSourcePreference,
        portal: ScriptedPortal,
        toolkit: ScriptedToolkit
    ) async throws -> Outcome {
        try await download(
            preferring: preference,
            client: ScriptedPortalClient(portal: portal, run: Self.run),
            toolkit: toolkit
        )
    }

    private func download(
        preferring preference: SRADownloadSourcePreference,
        client: ScriptedPortalClient,
        toolkit: ScriptedToolkit
    ) async throws -> Outcome {
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let emptyHome = root.appendingPathComponent("home-\(UUID().uuidString)", isDirectory: true)
        let service = SRAService(
            ncbiService: NCBIService(httpClient: client, environment: [:]),
            httpClient: client,
            homeDirectoryProvider: { emptyHome },
            toolkitRunner: toolkit.runner(testFile: #filePath)
        )
        let sources = Recorder<SRAFASTQDownloadSource>()
        let messages = Recorder<String>()
        let files = try await service.downloadFASTQ(
            accession: Self.run,
            outputDir: folder,
            preferring: preference,
            onFallback: { messages.append($0) },
            onSource: { sources.append($0) }
        )
        let folderFASTQ = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.contains(".fastq") }.sorted()
        return Outcome(
            files: files.map(\.lastPathComponent),
            sources: sources.values,
            fallbackMessages: messages.values,
            mirrorRequests: await client.mirrorRequests,
            portalRequests: await client.portalRequests,
            folderFASTQ: folderFASTQ,
            folderEntries: try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        )
    }

    private static func record(listsFiles: Bool) -> ENAReadRecord {
        let ftp = listsFiles ? "ftp.sra.ebi.ac.uk/vol1/fastq/ERR123/094/\(run)/\(run)_1.fastq.gz" : ""
        let json = #"{"run_accession": "\#(run)", "library_layout": "PAIRED", "fastq_ftp": "\#(ftp)", "fastq_bytes": ""}"#
        return try! JSONDecoder().decode(ENAReadRecord.self, from: Data(json.utf8))
    }
}

private enum ScriptedPortal: Sendable, CustomStringConvertible {
    case listsFiles
    case listsNoFiles
    case outage

    var description: String {
        switch self {
        case .listsFiles: return "ENA lists files"
        case .listsNoFiles: return "ENA lists no files"
        case .outage: return "ENA outage"
        }
    }
}

private enum ScriptedToolkit: Sendable {
    /// Writes the recorded fasterq-dump output.
    case recorded
    /// No managed sra-tools environment, so the download throws `toolkitNotFound`.
    case missing
    /// fasterq-dump writes one mate, then exits 3.
    case failsAfterWritingAMate
    /// prefetch writes the run's archive (part of it), then fasterq-dump exits 3.
    case failsAfterPrefetch
    /// prefetch is cancelled.
    case cancelled


    func runner(testFile: String) -> SRAToolkitRunner? {
        let recorded = SRAToolkitRecordedRunner(testFile: testFile)
        switch self {
        case .recorded:
            return recorded.runner
        case .missing:
            return nil
        case .failsAfterWritingAMate:
            let fasterq = URL(fileURLWithPath: "/managed/sra-tools/bin/fasterq-dump")
            return SRAToolkitRunner(prefetch: URL(fileURLWithPath: "/managed/sra-tools/bin/prefetch"), fasterqDump: fasterq) { executable, arguments in
                guard executable == fasterq, let index = arguments.firstIndex(of: "-O") else {
                    return SRAToolkitRunner.Result(exitCode: 0)
                }
                let accession = URL(fileURLWithPath: arguments[0]).deletingPathExtension().lastPathComponent
                try Data("@\(accession).1\nAC".utf8).write(
                    to: URL(fileURLWithPath: arguments[index + 1]).appendingPathComponent("\(accession)_1.fastq")
                )
                return SRAToolkitRunner.Result(exitCode: 3, stderr: "disk full")
            }
        case .failsAfterPrefetch:
            let prefetch = URL(fileURLWithPath: "/managed/sra-tools/bin/prefetch")
            return SRAToolkitRunner(prefetch: prefetch, fasterqDump: URL(fileURLWithPath: "/managed/sra-tools/bin/fasterq-dump")) { executable, arguments in
                guard executable == prefetch, let index = arguments.firstIndex(of: "-O") else {
                    return SRAToolkitRunner.Result(exitCode: 3, stderr: "disk full")
                }
                let folder = URL(fileURLWithPath: arguments[index + 1]).appendingPathComponent(arguments[0], isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try Data("partial".utf8).write(to: folder.appendingPathComponent("\(arguments[0]).sra"))
                return SRAToolkitRunner.Result(exitCode: 0)
            }
        case .cancelled:
            return SRAToolkitRunner(
                prefetch: URL(fileURLWithPath: "/managed/sra-tools/bin/prefetch"),
                fasterqDump: URL(fileURLWithPath: "/managed/sra-tools/bin/fasterq-dump")
            ) { _, _ in throw CancellationError() }
        }
    }
}

/// Answers ENA's portal as `portal` says, and serves each listed mate as
/// the gzip fixture.
private actor ScriptedPortalClient: HTTPClient {
    let portal: ScriptedPortal
    let run: String
    private(set) var mirrorRequests = 0
    private(set) var portalRequests = 0

    init(portal: ScriptedPortal, run: String) {
        self.portal = portal
        self.run = run
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = request.url ?? URL(string: "https://example.invalid")!
        guard url.absoluteString.contains("portal/api") else {
            throw URLError(.cannotFindHost)
        }
        portalRequests += 1
        let size = ENAFASTQDownloadValidatorTests.gzipFixture.count
        let folder = "ftp.sra.ebi.ac.uk/vol1/fastq/ERR123/094/\(run)"
        switch portal {
        case .outage:
            return (Data(ENAOutageFixture.page.utf8), Self.response(url, 500))
        case .listsNoFiles:
            let payload: [[String: Any]] = [["run_accession": run, "library_layout": "PAIRED", "fastq_ftp": "", "fastq_bytes": ""]]
            return (try JSONSerialization.data(withJSONObject: payload), Self.response(url, 200))
        case .listsFiles:
            let payload: [[String: Any]] = [[
                "run_accession": run,
                "library_layout": "PAIRED",
                "fastq_ftp": "\(folder)/\(run)_1.fastq.gz;\(folder)/\(run)_2.fastq.gz",
                "fastq_bytes": "\(size);\(size)",
            ]]
            return (try JSONSerialization.data(withJSONObject: payload), Self.response(url, 200))
        }
    }

    func download(for request: URLRequest) async throws -> (URL, URLResponse) {
        let url = request.url ?? URL(string: "https://example.invalid")!
        mirrorRequests += 1
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sra-source-preference-file-\(UUID().uuidString)")
        try ENAFASTQDownloadValidatorTests.gzipFixture.write(to: temporaryURL, options: .atomic)
        return (temporaryURL, Self.response(url, 200))
    }

    private static func response(_ url: URL, _ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
    }
}

private final class Recorder<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Value] = []
    var values: [Value] { lock.withLock { stored } }
    func append(_ value: Value) { lock.withLock { stored.append(value) } }
}
