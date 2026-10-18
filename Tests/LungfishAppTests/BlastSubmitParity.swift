// BlastSubmitParity.swift - What the parity classes of the viewers' BLAST read actions share
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 lane A65 M2, plan decision C1 and decisions C4, C5 and G5 of 2.10, on lane Q30's harness. Each
// class runs one viewer site on two sides that start as copies of one project, and one loopback stand-in of
// NCBI's BLAST CGI answers every search (G5). The in-process route and its hidden key left in Phase 2.12 (lane
// 12.02, K3), so the harness has no side A and the two declared `only in C` entries are gone.
//
// - Side C is the site's plan, its begin helper with the plan's command, then `BlastSubmitPlan.run` on
//   `CLIBlastSubmitRunner`, which launches the built `lungfish-cli blast submit`.
// - Side C' is the harness's replay of the command side C's row recorded.
// - The oracle is the search the site ran in the app before the route moved, `BlastService.verify` on the
//   request the site built (`inProcessSearch`). It writes nothing and takes no part in the roots. It keeps the
//   comparison of the request's bytes and of the verdicts, which `BlastSiteRequestBytesPinTests` pins for each
//   site at the base.
//
// C against C' declares nothing. Every search sends the stand-in the same bytes, the oracle's included. The
// harness compares on the contract's standard masks.

import Foundation
import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport

enum BlastSubmitParity {
    /// The variable that points a debug build's BLAST service at a stand-in origin.
    static let standInVariable = BlastServiceEndpoints.standInOriginVariable

    /// The one case of each class, one selection searched once.
    enum Case: String, Sendable {
        case oneSelection
    }

    /// A JSON2 answer with no hit for either read, the shape NCBI returns (`BlastSubmitCommandTests`).
    static let json2NoHits = Data("""
    {"BlastOutput2": [\
    {"report": {"program": "blastn", "version": "BLASTN 2.16.0+", "results": {"search": {"query_title": "read_1", "query_len": 10, "hits": []}}}}, \
    {"report": {"program": "blastn", "version": "BLASTN 2.16.0+", "results": {"search": {"query_title": "read_2", "query_len": 10, "hits": []}}}}]}
    """.utf8)

    /// Answers a submission with an RID, a status poll with READY and a result fetch with JSON2, the
    /// answers of `BlastSubmitStandInTests`.
    static func standIn() throws -> LoopbackHTTPStandIn {
        try LoopbackHTTPStandIn.start { request in
            guard request.path == "/blast/Blast.cgi" else { return .notFound }
            if request.method == "POST" {
                return .text("<!--QBlastInfoBegin\n    RID = STANDIN1\n    RTOE = 1\nQBlastInfoEnd-->")
            }
            if request.queryItems.contains(URLQueryItem(name: "FORMAT_OBJECT", value: "SearchInfo")) {
                return .text("<!--QBlastInfoBegin\n    Status=READY\nQBlastInfoEnd-->")
            }
            return LoopbackHTTPResponse(contentType: "application/json", body: json2NoHits)
        }
    }

    /// The built lungfish-cli beside the test bundle of `testClass`.
    static func cli(for testClass: AnyClass) throws -> URL {
        let products = Bundle(for: testClass).bundleURL.deletingLastPathComponent()
        return try XCTUnwrap(
            CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: products),
            "No lungfish-cli beside \(products.path) and none named by LUNGFISH_CLI_PATH, so no side can run"
        )
    }

    /// The harness of a class, on `masks`. Side C' gets the stand-in's origin, which side C reads from this
    /// process.
    static func harness(cli: URL, server: LoopbackHTTPStandIn) -> RouteParityHarness {
        let origin = server.baseURL.absoluteString
        return RouteParityHarness(cliBinary: cli, kind: .bundle, masks: masks, replayTimeout: .seconds(120)) { _ in
            [standInVariable: origin]
        }
    }

    /// The contract's standard masks, which read the three clock values of a `blast submit` record
    /// (`blast-result.json`) as `<TIMESTAMP>` and compare every other value of it as written
    /// (docs/contracts/CLI-EQUIVALENCE.md).
    static let masks = OutputEquivalence.MaskPolicy.standard

    /// The project of a side root.
    static func project(in root: URL) -> URL {
        root.appendingPathComponent("Project.lungfish", isDirectory: true)
    }

    /// The oracle. `request` searched in this process against the stand-in, as the site searched before the
    /// route moved.
    static func inProcessSearch(_ request: BlastVerificationRequest, server: LoopbackHTTPStandIn) async -> RouteParitySideOutcome {
        do {
            let service = BlastService(environment: [standInVariable: server.baseURL.absoluteString])
            return RouteParitySideOutcome(end: .completed, detail: summary(try await service.verify(request: request)))
        } catch {
            return RouteParitySideOutcome(end: .failed, detail: "\(error)")
        }
    }

    /// Side C. The site's plan begun by `begin` with the plan's command on a recording reporter, then run
    /// on the runner that launches the built CLI. The query stage is then copied to root C', where the
    /// command side C' replays reads it.
    @MainActor
    static func sideC(
        _ root: URL,
        cli: URL,
        plan makePlan: (URL) throws -> BlastSubmitPlan,
        begin: (String, RecordingOperationReporter) -> Void
    ) async -> RouteParitySideOutcome {
        let reporter = RecordingOperationReporter()
        do {
            let plan = try makePlan(root)
            begin(plan.cliCommand, reporter)
            let result = try await plan.run(runner: CLIBlastSubmitRunner(cliURLOverride: cli)) { _ in }
            try copyStage(of: plan, from: root)
            return RouteParitySideOutcome(end: .completed, detail: summary(result), recordedCommand: reporter.items.first?.cliCommand)
        } catch {
            return RouteParitySideOutcome(end: .failed, detail: "\(error)", recordedCommand: reporter.items.first?.cliCommand)
        }
    }

    /// The verdict counts a row completes with.
    static func summary(_ result: BlastVerificationResult) -> String {
        "\(result.verifiedCount)/\(result.readResults.count) verified"
    }

    /// Copies side C's query stage to the same place under root C', with each spelling of root C in its
    /// files rewritten to root C', so side C' finds the query its command names and no file of root C'
    /// names root C.
    static func copyStage(of plan: BlastSubmitPlan, from rootC: URL) throws {
        let stage = plan.request.queryURL.deletingLastPathComponent().standardizedFileURL
        let rootPath = rootC.standardizedFileURL.path
        guard stage.path.hasPrefix(rootPath + "/") else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: stage.path])
        }
        let rootCPrime = RouteParityHarness.root(of: .cPrime, in: rootC.deletingLastPathComponent())
        let target = rootCPrime.appendingPathComponent(String(stage.path.dropFirst(rootPath.count + 1)), isDirectory: true)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.copyItem(at: stage, to: target)
        let renames = [
            (rootC.resolvingSymlinksInPath().path, rootCPrime.resolvingSymlinksInPath().path), (rootC.path, rootCPrime.path),
        ]
        for name in try fileManager.subpathsOfDirectory(atPath: target.path) {
            let file = target.appendingPathComponent(name)
            guard let original = try? String(contentsOf: file, encoding: .utf8) else { continue }
            var text = original
            for (from, to) in renames {
                text = text.replacingOccurrences(of: from, with: to)
                    .replacingOccurrences(of: from.replacingOccurrences(of: "/", with: "\\/"), with: to.replacingOccurrences(of: "/", with: "\\/"))
            }
            if text != original { try text.write(to: file, atomically: true, encoding: .utf8) }
        }
    }

    /// The body of each submission the stand-in received, in order.
    static func submissions(_ server: LoopbackHTTPStandIn) -> [String] {
        server.requests.filter { $0.method == "POST" }.map { String(decoding: $0.body, as: UTF8.self) }
    }

    /// The record of the one search under `blast-verifications/` of `parent`.
    static func record(under parent: URL) -> URL {
        let folder = parent.appendingPathComponent("blast-verifications", isDirectory: true)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
        return folder.appendingPathComponent(names.first ?? "no-search", isDirectory: true)
            .appendingPathComponent("blast-result.json.lungfish-provenance.json")
    }

    /// Runs the case on sides C and C' and fails on each difference between them. Both must complete and keep the
    /// search under `blast-verifications/` of `resultsParent`. The oracle must complete too and give the verdicts
    /// the row completes with, and all three searches must send the stand-in the same bytes.
    @MainActor
    static func assertParity(
        harness: RouteParityHarness,
        server: LoopbackHTTPStandIn,
        in caseRoot: URL,
        resultsParent: (URL) -> URL,
        fixture: (URL) throws -> Void,
        oracle: () async -> RouteParitySideOutcome,
        sideC: (URL) async throws -> RouteParitySideOutcome,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let inProcess = await oracle()
        let runs = try await ReadsRouteParity.runCAndCPrime(harness, in: caseRoot, fixture: fixture, sideC: sideC)
        let result = try harness.evaluate(Case.oneSelection, declared: [], runs: runs)
        RouteParityHarness.assertNoFailures(result.failures, in: "\(Case.oneSelection), C against C'", file: file, line: line)
        XCTAssertEqual(inProcess.end, .completed, "the in-process search: \(inProcess.detail)", file: file, line: line)
        for run in [runs.c, runs.cPrime] {
            XCTAssertEqual(run.outcome.end, .completed, "side \(run.side): \(run.outcome.detail)", file: file, line: line)
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: record(under: resultsParent(run.root)).path),
                "side \(run.side) keeps the search under blast-verifications/ of \(resultsParent(run.root).path)",
                file: file, line: line
            )
        }
        XCTAssertEqual(runs.c.outcome.detail, inProcess.detail, "the row's verdicts", file: file, line: line)
        let bodies = submissions(server)
        XCTAssertEqual(bodies.count, 3, "one submission a search", file: file, line: line)
        XCTAssertEqual(Set(bodies).count, 1, "every search sends the same bytes: \(bodies)", file: file, line: line)
    }

    /// Runs the case with a throwaway signing key, then checks with `provenance verify` that the record
    /// sides C and C' write is signed and verifies, and that a copy with one digit edited does not (ARCH 3).
    @MainActor
    static func assertSignedRecordVerifies(
        harness: RouteParityHarness,
        in caseRoot: URL,
        resultsParent: @escaping @Sendable (URL) -> URL,
        fixture: (URL) throws -> Void,
        sideC: (URL) async throws -> RouteParitySideOutcome,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let runs = try await ReadsRouteParity.runSignedCAndCPrime(harness, in: caseRoot, fixture: fixture, sideC: sideC)
        for run in [runs.c, runs.cPrime] {
            XCTAssertEqual(run.outcome.end, .completed, "side \(run.side): \(run.outcome.detail)", file: file, line: line)
        }
        await harness.assertSignaturesVerify(runs, opening: { record(under: resultsParent($0)) }, file: file, line: line)
    }
}
