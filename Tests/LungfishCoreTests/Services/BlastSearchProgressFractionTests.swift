// BlastSearchProgressFractionTests.swift - The advancer reports under 0.20 until NCBI has the first send, and 0.20 or more after
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Lane BLASTWORDS, W-20. The FASTA list pane reads its phase from these two states (`ViewerViewController.blastFirstSendTakenFraction`
// in LungfishApp). If the advancer's numbers move, the pane says Waiting and Phase 2 before anything is sent again. The fault
// stand-in answers and a hand clock spends every wait at once. Nothing contacts NCBI.

import Foundation
import LungfishTestSupport
import XCTest
@testable import LungfishCore

final class BlastSearchProgressFractionTests: XCTestCase {
    /// `ViewerViewController.blastFirstSendTakenFraction`, which the list pane reads.
    private static let firstSendTaken = 0.20

    private var folder: URL!
    private let hand = BlastHandClock(advancesBySleeping: true)
    private let reads: [(id: String, sequence: String)] = [(id: "read_1", sequence: "ACGTACGTAC"), (id: "read_2", sequence: "GGCCTTAAGG")]

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("blast-progress-fraction-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private final class ProgressLog: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [(fraction: Double, message: String)] = []

        func add(_ fraction: Double, _ message: String) {
            lock.lock()
            defer { lock.unlock() }
            items.append((fraction, message))
        }

        var reports: [(fraction: Double, message: String)] {
            lock.lock()
            defer { lock.unlock() }
            return items
        }
    }

    /// Reaches nothing `triesBeforeACancel` times, as with no connection, and is then cancelled, which ends the test's run.
    private actor NoConnectionClient: HTTPClient {
        private var triesLeft: Int

        init(triesBeforeACancel: Int) {
            self.triesLeft = triesBeforeACancel
        }

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            guard triesLeft > 0 else { throw CancellationError() }
            triesLeft -= 1
            throw URLError(.notConnectedToInternet)
        }
    }

    private func create(_ advancer: BlastSearchAdvancer) async throws -> BlastSearchFile {
        try await advancer.create(
            origin: .standIn,
            query: BlastSubmissionRecord.Query(fileName: "query.fasta", sha256: "digest", sequenceCount: reads.count),
            submitArgv: ["lungfish-cli", "blast", "submit"]
        )
    }

    /// While a Put reaches nothing, every report the Operations row reads is under the fraction, so the pane stays on Submitting.
    func testEveryReportReadsUnderTheFirstSendFractionWhileNothingHasGoneOut() async throws {
        let log = ProgressLog()
        let advancer = BlastSearchAdvancer(
            service: BlastService(httpClient: NoConnectionClient(triesBeforeACancel: 3)),
            store: BlastSearchStore(folder: folder),
            request: BlastVerificationRequest(taxonName: "test", taxId: 0, sequences: reads),
            clock: hand.clock,
            noun: "sequences",
            progress: { log.add($0, $1) },
            publish: { _ in }
        )

        do {
            _ = try await advancer.advance(try await create(advancer))
            XCTFail("only a cancel ends a search that has reached nothing")
        } catch is CancellationError {}

        let reports = log.reports
        XCTAssertFalse(reports.isEmpty, "the advancer said nothing before the first send")
        for report in reports {
            XCTAssertLessThan(report.fraction, Self.firstSendTaken, "a report before any send: \(report.message)")
        }
    }

    /// Once NCBI has taken the first send, the reports are at the fraction or more, so the pane may say Waiting.
    func testEveryReportReadsAtTheFirstSendFractionOrMoreOnceNCBIHasTheSearch() async throws {
        let hand = hand
        let server = try BlastFaultStandIn.start(scripts: [BlastFaultScript()], now: { hand.now })
        defer { server.stop() }
        let log = ProgressLog()
        let advancer = BlastSearchAdvancer(
            service: BlastService(
                rateLimits: .ncbiDefault, searchShared: BlastSearchShared(searchLog: nil),
                environment: [BlastServiceEndpoints.standInOriginVariable: server.baseURL.absoluteString]
            ),
            store: BlastSearchStore(folder: folder),
            request: BlastVerificationRequest(taxonName: "test", taxId: 0, sequences: reads),
            clock: hand.clock,
            noun: "sequences",
            progress: { log.add($0, $1) },
            publish: { _ in }
        )

        _ = try await advancer.advance(try await create(advancer))

        let reports = log.reports
        let taken = try XCTUnwrap(reports.firstIndex { $0.fraction >= Self.firstSendTaken }, "no report said NCBI has the search")
        for report in reports[..<taken] {
            XCTAssertLessThan(report.fraction, Self.firstSendTaken, "a report before the send: \(report.message)")
        }
        for report in reports[taken...] {
            XCTAssertGreaterThanOrEqual(report.fraction, Self.firstSendTaken, "a report after the send: \(report.message)")
        }
    }
}
