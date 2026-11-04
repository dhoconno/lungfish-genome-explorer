// BlastSearchAdvancerTests.swift - The rows of ARCH-BLAST-RESILIENCE section 5 on a clock moved by hand
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishTestSupport
import Synchronization
import XCTest
@testable import LungfishCore

/// Phase 3.2 lane BLASTNET N2. The fault stand-in answers and a hand clock spends every wait at once, so a search of
/// hours runs in no time. `BlastSearchChildTests` holds the named rows on the built leaf.
final class BlastSearchAdvancerTests: XCTestCase {
    private var folder: URL!
    private let hand = BlastHandClock(advancesBySleeping: true)
    private let reads: [(id: String, sequence: String)] = [(id: "read_1", sequence: "ACGTACGTAC"), (id: "read_2", sequence: "GGCCTTAAGG")]

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("blast-search-advancer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func standIn(_ scripts: [BlastFaultScript]) throws -> BlastFaultStandIn {
        let hand = hand
        return try BlastFaultStandIn.start(scripts: scripts, now: { hand.now })
    }

    private func advancer(
        _ server: BlastFaultStandIn?,
        limits: BlastRateLimitConfiguration = .ncbiDefault,
        publish: @escaping BlastSearchAdvancer.Publish = { _ in }
    ) -> BlastSearchAdvancer {
        let environment = server.map { [BlastServiceEndpoints.standInOriginVariable: $0.baseURL.absoluteString] } ?? [:]
        return BlastSearchAdvancer(
            service: BlastService(rateLimits: limits, environment: environment),
            store: BlastSearchStore(folder: folder),
            request: BlastVerificationRequest(taxonName: "test", taxId: 0, sequences: reads),
            clock: hand.clock,
            noun: "sequences",
            progress: { _, _ in },
            publish: publish
        )
    }

    private func create(_ advancer: BlastSearchAdvancer) async throws -> BlastSearchFile {
        try await advancer.create(
            origin: .standIn,
            query: BlastSubmissionRecord.Query(fileName: "query.fasta", sha256: "digest", sequenceCount: reads.count),
            submitArgv: ["lungfish-cli", "blast", "submit"]
        )
    }

    private func onDisk() throws -> BlastSearchFile {
        try BlastSearchStore(folder: folder).load()
    }

    private func replyFile(_ name: String) -> URL {
        folder.appendingPathComponent("replies/\(name)")
    }

    // MARK: The file

    func testAFileReadsBackAsItWasWritten() async throws {
        let file = try await create(advancer(nil))

        XCTAssertEqual(try onDisk(), file)
        XCTAssertEqual(file.schemaVersion, 1)
        XCTAssertEqual(file.route, .ncbi)
        XCTAssertEqual(file.state, .sending)
        XCTAssertNil(file.copies[0].rid)
    }

    func testAFileOfANewerLGEIsRefusedAndLeftAlone() throws {
        let bytes = Data(#"{"schemaVersion": 2, "searchID": "from the future"}"#.utf8)
        let url = folder.appendingPathComponent(BlastSearchFile.fileName)
        try bytes.write(to: url)

        XCTAssertThrowsError(try onDisk()) { error in
            XCTAssertEqual(error as? BlastSearchStoreError, .newerSchema(found: 2))
            XCTAssertTrue(error.localizedDescription.contains("newer LGE"), error.localizedDescription)
        }
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    /// The contract's pattern for ExFAT, a swap of three renames that a crash cuts short.
    func testASwapCutShortOnExFATLeavesAFileAResumeCanFind() async throws {
        let file = try await create(advancer(nil))
        let store = BlastSearchStore(folder: folder)
        try PortableRename.simulatingUnsupportedFlags { try store.save(file) }
        let name = folder.appendingPathComponent(BlastSearchFile.fileName)
        try FileManager.default.moveItem(at: name, to: folder.appendingPathComponent(".\(BlastSearchFile.fileName).lungfish-swap-\(UUID().uuidString)"))
        try Data().write(to: name)

        XCTAssertThrowsError(try store.load(), "a read runs no recovery")
        store.recoverInterruptedSwap()

        XCTAssertEqual(try store.load(), file)
    }

    // MARK: Before the Put

    func testTheFormAndTheFileAreDurableBeforeThePost() async throws {
        let server = try standIn([BlastFaultScript()])
        defer { server.stop() }
        let advancer = advancer(server)

        let file = try await create(advancer)

        XCTAssertEqual(server.arrivals.count, 0, "nothing has gone out")
        let form = try BlastSearchStore(folder: folder).loadForm()
        XCTAssertEqual(file.formSHA256, BlastSearchStore.digest(of: form))
        XCTAssertEqual(try onDisk().state, .sending)
        _ = try await advancer.advance(file)
        XCTAssertEqual(server.requests.first?.body, form, "the POST is the saved bytes")
    }

    func testLGEsOwnLimitContactsNothingAndLeavesNoFileInSending() async throws {
        let server = try standIn([BlastFaultScript()])
        defer { server.stop() }
        let limits = BlastRateLimitConfiguration(maxSequencesPerHour: 1)

        do {
            _ = try await create(advancer(server, limits: limits))
            XCTFail("two reads are over a limit of one")
        } catch let error as BlastServiceError {
            guard case .rateLimitExceeded = error else { throw error }
        }

        XCTAssertEqual(server.arrivals.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(BlastSearchFile.fileName).path))
    }

    // MARK: The Put

    func testAPutThatStaysBusyWaitsItsWaitsThenEndsNotSent() async throws {
        let server = try standIn([BlastFaultScript(put: Array(repeating: .http(status: 503), count: 4))])
        defer { server.stop() }
        let advancer = advancer(server)

        let outcome = try await advancer.advance(try await create(advancer))

        guard case .ended(.notSent, let words) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(words.contains("error 503 4 times"), words)
        XCTAssertEqual(hand.sleeps, [60, 120, 300])
        XCTAssertEqual(server.arrivals.count, 4)
        XCTAssertEqual(try onDisk().state, .notSent)
    }

    func testAPutAnsweredWithNoRIDEndsNotSentAndKeepsThePage() async throws {
        let server = try standIn([BlastFaultScript(put: [.noRID(page: "<p>Query contains no sequence data</p>")])])
        defer { server.stop() }
        let advancer = advancer(server)

        let outcome = try await advancer.advance(try await create(advancer))

        guard case .ended(.notSent, let words) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(words.contains("Query contains no sequence data"), words)
        XCTAssertEqual(try onDisk().copies[0].words, "<p>Query contains no sequence data</p>")
        XCTAssertEqual(server.arrivals.count, 1)
    }

    func testAPutLostTwiceEndsNotSent() async throws {
        let server = try standIn([BlastFaultScript(put: [.droppedAfterSending, .droppedAfterSending])])
        defer { server.stop() }
        let advancer = advancer(server)

        let outcome = try await advancer.advance(try await create(advancer))

        guard case .ended(.notSent, let words) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(words.contains("did not confirm"), words)
        XCTAssertEqual(hand.sleeps.first, 60)
    }

    func testAPutThatReachesNothingStaysSendingAndGoesOutLater() async throws {
        let advancer = BlastSearchAdvancer(
            service: BlastService(httpClient: BlastNoConnectionClient(triesBeforeACancel: 3)),
            store: BlastSearchStore(folder: folder),
            request: BlastVerificationRequest(taxonName: "test", taxId: 0, sequences: reads),
            clock: hand.clock,
            noun: "sequences",
            progress: { _, _ in },
            publish: { _ in }
        )

        do {
            _ = try await advancer.advance(try await create(advancer))
            XCTFail("only a cancel ends a search that has reached nothing")
        } catch is CancellationError {}

        let kept = try onDisk()
        XCTAssertEqual(kept.state, .sending, "nothing was sent and a cancel leaves the file")
        XCTAssertEqual(kept.copies[0].failedContacts, 3)
        XCTAssertEqual(hand.sleeps, [60, 60, 60], "the Put goes out again at each tick")
    }

    func testAPutThatReachesNothingCountsOneSendHoweverLongItTries() async throws {
        let ledger = InMemoryBlastSubmissionLedger()
        let advancer = BlastSearchAdvancer(
            service: BlastService(httpClient: BlastNoConnectionClient(triesBeforeACancel: 3), submissionLedger: ledger),
            store: BlastSearchStore(folder: folder),
            request: BlastVerificationRequest(taxonName: "test", taxId: 0, sequences: reads),
            clock: hand.clock,
            noun: "sequences",
            progress: { _, _ in },
            publish: { _ in }
        )

        do {
            _ = try await advancer.advance(try await create(advancer))
            XCTFail("only a cancel ends a search that has reached nothing")
        } catch is CancellationError {}

        let events = await ledger.events(at: hand.now)
        XCTAssertEqual(events.count, 1, "nothing went out, so the one count stands")
    }

    func testARePostPastTheLimitStaysDueAndNeverEndsTheSearch() async throws {
        let server = try standIn([BlastFaultScript(put: [.http(status: 503)])])
        defer { server.stop() }
        let advancer = advancer(server, limits: BlastRateLimitConfiguration(maxSequencesPerHour: reads.count))

        let outcome = try await advancer.advance(try await create(advancer))

        guard case .done = outcome else { return XCTFail("the search went on to its result: \(outcome)") }
        XCTAssertEqual(server.arrivals.filter { $0.contact == .put }.count, 2)
        // The busy answer's wait, then the rest of the hour the first POST's reads fill.
        XCTAssertEqual(hand.sleeps[0], 60, accuracy: 0.01)
        XCTAssertEqual(hand.sleeps[1], 3540, accuracy: 0.01)
    }

    // MARK: The check

    func testFailedEndsWithNCBIsWordsAndTheRid() async throws {
        let server = try standIn([BlastFaultScript(search: .failed(words: "CPU usage limit was exceeded"))])
        defer { server.stop() }
        let advancer = advancer(server)

        let outcome = try await advancer.advance(try await create(advancer))

        guard case .ended(.ncbiFailed, let words) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(words.contains("CPU usage limit was exceeded"), words)
        XCTAssertTrue(words.contains(BlastFaultStandIn.rid(ofPut: 1)), words)
        XCTAssertEqual(try onDisk().copies[0].state, .failed)
    }

    func testAPageWithNoStatusLineIsNoNews() async throws {
        let server = try standIn([BlastFaultScript(status: [.noStatusLine, .emptyPage])])
        defer { server.stop() }
        let advancer = advancer(server)

        let outcome = try await advancer.advance(try await create(advancer))

        guard case .done = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(try onDisk().copies[0].failedContacts, 2, "each is counted, and no count ends anything")
    }

    func testASearchOfHoursGoesOnUntilNCBIAnswers() async throws {
        let server = try standIn([BlastFaultScript(search: .ready(after: 26 * 3600))])
        defer { server.stop() }
        let advancer = advancer(server)

        let outcome = try await advancer.advance(try await create(advancer))

        guard case .done = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(hand.sleeps.last, 1800, "past 6 hours the checks are 30 minutes apart")
    }

    func testAResumePastItsDueTimeChecksAtOnce() async throws {
        let server = try standIn([BlastFaultScript()])
        defer { server.stop() }
        let advancer = advancer(server)
        // The search holds an RID whose check came due while nothing ran, as after a sleep or a quit.
        var file = try await create(advancer)
        _ = await BlastService(environment: [BlastServiceEndpoints.standInOriginVariable: server.baseURL.absoluteString])
            .sendPutForTest(try BlastSearchStore(folder: folder).loadForm())
        file.state = .waiting
        file.copies[0].state = .live
        file.copies[0].rid = BlastFaultStandIn.rid(ofPut: 1)
        file.copies[0].postAt = hand.now
        file.copies[0].nextCheckAt = hand.now.addingTimeInterval(-3600)

        let outcome = try await advancer.advance(file)

        guard case .done = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(hand.sleeps, [], "a due time in the past reads as check now")
        XCTAssertEqual(server.arrivals.count { $0.contact == .put }, 1, "a resume sends nothing again")
    }

    // MARK: The reply

    func testFiveUnreadableRepliesAskAPersonAndKeepTheLastThenAResumeGoesOn() async throws {
        let server = try standIn([BlastFaultScript(result: Array(repeating: .html, count: 5))])
        defer { server.stop() }
        let advancer = advancer(server)
        let rid = BlastFaultStandIn.rid(ofPut: 1)

        let outcome = try await advancer.advance(try await create(advancer))

        guard case .needsAPerson(let words) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(words.contains("Try Again"), words)
        let kept = try onDisk()
        XCTAssertEqual(kept.state, .fetching, "the search has not failed")
        XCTAssertEqual(server.arrivals.count { $0.contact == .result }, 5)
        XCTAssertTrue(FileManager.default.fileExists(atPath: replyFile("\(rid).reply").path), "the reply is kept")

        let again = try await advancer.advance(kept)

        guard case .done = again else { return XCTFail("\(again)") }
        XCTAssertEqual(try onDisk().state, .done)
        XCTAssertFalse(FileManager.default.fileExists(atPath: replyFile("\(rid).reply").path), "the record is durable, so the reply goes")
    }

    func testAResultThatDoesNotArriveHoldsFetchingAndFetchesAgain() async throws {
        let server = try standIn([BlastFaultScript(result: [.http(status: 503), .dropped])])
        defer { server.stop() }
        let advancer = advancer(server)

        let outcome = try await advancer.advance(try await create(advancer))

        guard case .done = outcome else { return XCTFail("\(outcome)") }
        // The URL loading system may repeat a dropped GET by itself, so the tries are counted at the stand-in.
        XCTAssertGreaterThanOrEqual(try onDisk().copies[0].failedContacts, 1, "the 503 is counted")
        XCTAssertGreaterThanOrEqual(server.arrivals.count { $0.contact == .result }, 3, "each fault, then the result")
    }

    func testARecordThatCannotBeWrittenKeepsTheReplyAndFetchesNothingMore() async throws {
        let server = try standIn([BlastFaultScript()])
        defer { server.stop() }
        let tries = Mutex(0)
        let advancer = advancer(server, publish: { _ in
            let attempt = tries.withLock { value -> Int in
                value += 1
                return value
            }
            if attempt == 1 { throw CocoaError(.fileWriteNoPermission) }
        })

        let outcome = try await advancer.advance(try await create(advancer))

        guard case .done = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(tries.withLock { $0 }, 2)
        XCTAssertEqual(server.arrivals.count { $0.contact == .result }, 1, "the second try reads the saved reply")
    }

    func testAReplacedQueryIsAskedOfAPersonWithTheReplyKept() async throws {
        let server = try standIn([BlastFaultScript()])
        defer { server.stop() }
        let advancer = advancer(server, publish: { _ in throw BlastSearchRefusal(words: "not the file LGE sent") })

        let outcome = try await advancer.advance(try await create(advancer))

        guard case .needsAPerson(let words) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(words, "not the file LGE sent")
        XCTAssertEqual(try onDisk().state, .fetching)
        XCTAssertTrue(FileManager.default.fileExists(atPath: replyFile("\(BlastFaultStandIn.rid(ofPut: 1)).reply").path))
    }

    // MARK: Origin

    func testAFieldInTheFileCanOnlyStopAContact() {
        let standIn = [BlastServiceEndpoints.standInOriginVariable: "http://127.0.0.1:9"]
        XCTAssertTrue(BlastSearchFile.Origin.standIn.allowsContact(environment: standIn))
        XCTAssertFalse(BlastSearchFile.Origin.ncbi.allowsContact(environment: standIn), "a stand-in run never touches a search at NCBI")
        XCTAssertFalse(BlastSearchFile.Origin.standIn.allowsContact(environment: [:]), "a run that talks to NCBI never contacts it for a stand-in's search")
        XCTAssertTrue(BlastSearchFile.Origin.ncbi.allowsContact(environment: [:]))
    }
}

extension BlastService {
    /// One accepted Put, for a test that seeds a search NCBI already holds.
    fileprivate func sendPutForTest(_ form: Data) async -> Bool {
        (try? await putOnce(form)) != nil
    }
}

/// Reaches nothing `triesBeforeACancel` times, as with no connection, and is then cancelled, which ends the test's run.
private actor BlastNoConnectionClient: HTTPClient {
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
