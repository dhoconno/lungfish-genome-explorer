// BlastSearchAdvancer.swift - Moves a BLAST search on from where its file says it stands
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import os.log

private let logger = Logger(subsystem: LogSubsystem.core, category: "BlastSearchAdvancer")

/// How a pass of ``BlastSearchAdvancer`` ends.
package enum BlastSearchOutcome: Sendable {
    /// The result is judged and published.
    case done(BlastVerificationResult)
    /// NCBI's answer or the person ended the search.
    case ended(BlastSearchFile.State, words: String)
    /// The search stays in `fetching` with its reply kept, and only a person can move it on.
    case needsAPerson(words: String)
}

/// What a publish step throws when writing a record would say something false, so no later try can help.
package struct BlastSearchRefusal: Error {
    package let words: String

    package init(words: String) {
        self.words = words
    }
}

/// Moves a BLAST search on from where its file says it stands, through the first send, its checks and its fetch.
///
/// A failed contact is no news. Only NCBI's answer or the person ends a search, and no limit of LGE's stays
/// (ARCH-BLAST-RESILIENCE section 5). Every due time is wall clock in the file, so a sleep, a quit and a restart all
/// read as contact now once it has passed. Each state change is durable before the next event or contact, and a
/// reply is durable before anything unzips or parses it.
package struct BlastSearchAdvancer: Sendable {
    package typealias Progress = @Sendable (Double, String) -> Void
    package typealias Publish = @Sendable (BlastVerificationResult) async throws -> Void

    private let service: BlastService
    private let store: BlastSearchStore
    private let request: BlastVerificationRequest
    private let clock: BlastSearchClock
    private let noun: String
    private let progress: Progress
    private let publish: Publish

    /// - Parameters:
    ///   - noun: What the words call the sequences, `reads`, `contigs` or `sequences`.
    ///   - publish: Writes the record of a judged result. It throws ``BlastSearchRefusal`` when no later try can help,
    ///     and any other error keeps the reply for the next tick.
    package init(
        service: BlastService,
        store: BlastSearchStore,
        request: BlastVerificationRequest,
        clock: BlastSearchClock,
        noun: String,
        progress: @escaping Progress,
        publish: @escaping Publish
    ) {
        self.service = service
        self.store = store
        self.request = request
        self.clock = clock
        self.noun = noun
        self.progress = progress
        self.publish = publish
    }

    // MARK: Create

    /// Reserves the first send, then makes the form and the search file durable, in that order and before any POST.
    /// LGE's own limit therefore refuses with no contact and no file left in `sending`.
    package func create(
        origin: BlastSearchFile.Origin,
        query: BlastSubmissionRecord.Query,
        submitArgv: [String]
    ) async throws -> BlastSearchFile {
        let form = try await service.putForm(for: request)
        try await service.reservePost(sequenceCount: request.sequences.count, kind: .first, at: clock.now())
        let digest = try store.saveForm(form)
        var file = BlastSearchFile(
            origin: origin,
            createdAt: clock.now(),
            submitArgv: submitArgv,
            facts: BlastSearchFile.Facts(request),
            query: query,
            formSHA256: digest
        )
        file.copies[0].postReserved = true
        try store.save(file)
        return file
    }

    // MARK: Advance

    /// Runs the search to an ending. A cancel leaves the file as it stands, so the search lives on.
    package func advance(_ start: BlastSearchFile) async throws -> BlastSearchOutcome {
        var file = start
        // A pass that starts on an unreadable reply reads it once more and gets fresh tries, which is Try Again.
        if file.state == .fetching {
            let index = winnerIndex(in: file)
            file.copies[index].replyUnreadable = false
            if file.copies[index].fetchTries >= BlastSearchPolicy.fetchTries { file.copies[index].fetchTries = 0 }
        }
        sayWhereItStands(file)
        while true {
            try Task.checkCancellation()
            if file.state.isEnding {
                return .ended(file.state, words: file.ending?.words ?? "")
            }
            let index = file.state == .fetching ? winnerIndex(in: file) : 0
            let wait = (file.copies[index].nextCheckAt ?? clock.now()).timeIntervalSince(clock.now())
            if wait > 0 { try await clock.sleep(wait) }
            try Task.checkCancellation()
            switch file.state {
            case .sending, .sendUnknown:
                try await sendThePut(&file)
            case .waiting:
                try await checkTheStatus(&file)
            case .fetching:
                if let outcome = try await fetchTheReply(&file) { return outcome }
            case .done, .expired, .ncbiFailed, .notSent, .stopped:
                break
            }
        }
    }

    private func winnerIndex(in file: BlastSearchFile) -> Int {
        file.copies.firstIndex { $0.ordinal == file.winnerOrdinal } ?? 0
    }

    private func sayWhereItStands(_ file: BlastSearchFile) {
        switch file.state {
        case .sending, .sendUnknown:
            progress(0.15, BlastSearchWords.sending(request.sequences.count, noun: noun))
        case .waiting:
            guard let rid = file.copies[0].rid else { return }
            progress(waitingFraction(of: file), BlastSearchWords.waiting(rid: rid))
        case .fetching, .done, .expired, .ncbiFailed, .notSent, .stopped:
            break
        }
    }

    /// How far a bar stands while NCBI holds the search. It slows with age and never arrives, since no time is promised.
    private func waitingFraction(of file: BlastSearchFile) -> Double {
        0.20 + 0.70 * (1 - exp(-max(0, clock.now().timeIntervalSince(file.createdAt)) / 600))
    }

    private func nextTick(after now: Date, in file: BlastSearchFile) -> Date {
        now.addingTimeInterval(BlastSearchPolicy.checkInterval(atAge: now.timeIntervalSince(file.createdAt)))
    }

    /// Makes a state change durable. A folder that cannot be written holds the search up and never ends it, since the
    /// RID must be on disk before any event or check.
    private func persist(_ file: BlastSearchFile) async throws {
        while true {
            do {
                try store.save(file)
                return
            } catch {
                logger.warning("Could not save a BLAST search: \(error.localizedDescription, privacy: .public)")
                progress(waitingFraction(of: file), BlastSearchWords.fileNotWritten(folder: store.folder.path, reason: error.localizedDescription))
                try await clock.sleep(BlastSearchPolicy.fetchWait)
            }
        }
    }

    private func end(_ file: inout BlastSearchFile, as state: BlastSearchFile.State, words: String) async throws {
        file.state = state
        file.ending = BlastSearchFile.Ending(state: state, at: clock.now(), words: words)
        try await persist(file)
    }

    private func rethrowIfCancelled(_ error: any Error) throws {
        if error is CancellationError || Task.isCancelled { throw CancellationError() }
    }

    // MARK: The Put

    private func sendThePut(_ file: inout BlastSearchFile) async throws {
        let isTheLastTry = file.state == .sendUnknown
        let form = try await savedForm()
        guard try await countThisPost(&file) else { return }
        let answer = try await service.sendPut(form, maxConcurrentSubmissions: request.maxConcurrentSubmissions)
        let now = clock.now()
        var copy = file.copies[0]
        if case .accepted(let submission) = answer {
            copy.rid = submission.rid
            copy.rtoe = submission.rtoe
            copy.postAt = now
            copy.state = .live
            copy.failedInARow = 0
            copy.nextCheckAt = now.addingTimeInterval(max(Double(submission.rtoe), BlastSearchPolicy.firstCheckFloor))
            file.copies[0] = copy
            file.state = .waiting
            try await persist(file)
            logger.info("BLAST search accepted, RID=\(submission.rid, privacy: .public) RTOE=\(submission.rtoe, privacy: .public)s")
            progress(0.20, BlastSearchWords.sent(rid: submission.rid))
            progress(0.20, BlastSearchWords.waiting(rid: submission.rid))
            return
        }
        copy.failedContacts += 1
        if isTheLastTry {
            copy.state = .notSent
            file.copies[0] = copy
            try await end(&file, as: .notSent, words: BlastSearchWords.stillNotConfirmed)
            return
        }
        switch answer {
        case .accepted:
            return
        case .notReached(let reason):
            logger.info("A BLAST Put reached nothing: \(reason, privacy: .public)")
            copy.postReserved = true
            copy.failedInARow += 1
            let next = nextTick(after: now, in: file)
            copy.nextCheckAt = next
            file.copies[0] = copy
            try await persist(file)
            progress(0.15, BlastSearchWords.noConnection(nextTry: next, now: now))
        case .busy(let status, _):
            copy.busyAnswers += 1
            guard copy.busyAnswers <= BlastSearchPolicy.busyPutWaits.count else {
                copy.state = .notSent
                file.copies[0] = copy
                try await end(&file, as: .notSent, words: BlastSearchWords.refused(code: status, times: copy.busyAnswers))
                return
            }
            copy.nextCheckAt = now.addingTimeInterval(BlastSearchPolicy.busyPutWaits[copy.busyAnswers - 1])
            file.copies[0] = copy
            try await persist(file)
            logger.info("NCBI answered a BLAST Put with \(status, privacy: .public), try \(copy.busyAnswers, privacy: .public)")
        case .refused(let status, _):
            copy.state = .notSent
            file.copies[0] = copy
            try await end(&file, as: .notSent, words: BlastSearchWords.refused(code: status, times: 1))
        case .noRID(let page):
            copy.state = .notSent
            copy.words = String(decoding: Data(page.utf8).prefix(BlastSearchPolicy.wordsLimit), as: UTF8.self)
            file.copies[0] = copy
            try await end(&file, as: .notSent, words: BlastSearchWords.noRequestID(page: BlastSearchWords.plainWords(ofPage: page)))
        case .lostAfterSending(let reason):
            logger.info("The reply to a BLAST Put was lost: \(reason, privacy: .public)")
            let next = now.addingTimeInterval(BlastSearchPolicy.lostPutWait)
            copy.nextCheckAt = next
            file.copies[0] = copy
            file.state = .sendUnknown
            try await persist(file)
            progress(0.15, BlastSearchWords.notConfirmed(nextTry: next, now: now))
        }
    }

    /// Counts this POST against LGE's own limit, as what it repeats. It returns false when the limit holds the POST,
    /// which stays due and never ends the search. The count is spent on disk before the POST goes, so a crash here makes
    /// the next POST count again and never leaves one uncounted.
    private func countThisPost(_ file: inout BlastSearchFile) async throws -> Bool {
        var copy = file.copies[0]
        if !copy.postReserved {
            do {
                try await service.reservePost(sequenceCount: request.sequences.count, kind: copy.kind, at: clock.now())
            } catch BlastServiceError.rateLimitExceeded(let refusal) {
                let due = refusal.fitsAt ?? nextTick(after: clock.now(), in: file)
                copy.nextCheckAt = due
                file.copies[0] = copy
                try await persist(file)
                logger.info("LGE's own limit holds a BLAST send until \(due, privacy: .public)")
                return false
            }
        }
        copy.postReserved = false
        file.copies[0] = copy
        try await persist(file)
        return true
    }

    /// The Put body as first saved. A file that has gone is built again from the same query and options.
    private func savedForm() async throws -> Data {
        if let saved = try? store.loadForm() { return saved }
        return try await service.putForm(for: request)
    }

    // MARK: The check

    private func checkTheStatus(_ file: inout BlastSearchFile) async throws {
        var copy = file.copies[0]
        guard let rid = copy.rid else {
            // A file that says waiting and names no RID holds nothing to check, so the search goes back to its send.
            copy.state = .sending
            copy.nextCheckAt = clock.now()
            file.copies[0] = copy
            file.state = .sending
            return
        }
        var answer: BlastSearchStatusAnswer?
        do {
            answer = try await service.statusOnce(rid: rid)
        } catch {
            try rethrowIfCancelled(error)
            logger.info("A BLAST status check brought no news: \(error.localizedDescription, privacy: .public)")
        }
        let now = clock.now()
        copy.nextCheckAt = nextTick(after: now, in: file)
        switch answer?.status {
        case .none, .noStatusLine:
            copy.failedContacts += 1
            copy.failedInARow += 1
        case .waiting:
            copy.lastCheckAt = now
            copy.failedInARow = 0
            copy.unknownInARow = 0
        case .unknown:
            copy.lastCheckAt = now
            copy.failedInARow = 0
            if now.timeIntervalSince(copy.postAt ?? file.createdAt) < BlastSearchPolicy.unknownGrace {
                copy.failedContacts += 1
            } else {
                copy.unknownInARow += 1
                if copy.unknownInARow >= BlastSearchPolicy.unknownReadsThatEndASend {
                    copy.state = .expired
                    file.copies[0] = copy
                    try await end(&file, as: .expired, words: BlastSearchWords.expired(rid: rid))
                    return
                }
            }
        case .error(let message):
            let onThePage = BlastSearchWords.plainWords(ofPage: answer?.page ?? "")
            let words = onThePage.isEmpty ? message : onThePage
            copy.state = .failed
            copy.lastCheckAt = now
            copy.words = words
            file.copies[0] = copy
            try await end(&file, as: .ncbiFailed, words: BlastSearchWords.failed(rid: rid, words: words))
            return
        case .ready(let thereAreHits):
            copy.state = .ready
            copy.lastCheckAt = now
            copy.readyAt = now
            copy.thereAreHits = thereAreHits
            copy.nextCheckAt = now
            file.copies[0] = copy
            file.winnerOrdinal = copy.ordinal
            file.state = .fetching
            try await persist(file)
            return
        }
        file.copies[0] = copy
        try await persist(file)
        progress(waitingFraction(of: file), waitingWords(copy, rid: rid, now: now))
    }

    private func waitingWords(_ copy: BlastSearchFile.Copy, rid: String, now: Date) -> String {
        if copy.failedInARow >= BlastSearchPolicy.failedChecksThatAreSaid, let next = copy.nextCheckAt {
            return BlastSearchWords.notReached(rid: rid, failedInARow: copy.failedInARow, nextCheck: next, now: now)
        }
        guard let lastChecked = copy.lastCheckAt else { return BlastSearchWords.waiting(rid: rid) }
        return BlastSearchWords.waiting(rid: rid, lastChecked: lastChecked, now: now)
    }

    // MARK: The reply

    /// Moves a READY search on by one contact, or by none when its reply is already on disk. Returns an outcome when
    /// this pass is over and nil when the next tick goes on.
    private func fetchTheReply(_ file: inout BlastSearchFile) async throws -> BlastSearchOutcome? {
        let index = winnerIndex(in: file)
        var copy = file.copies[index]
        let rid = copy.rid ?? ""
        let reply: Data
        if !copy.replyUnreadable, let name = copy.replyFile, let saved = store.loadReply(named: name) {
            reply = saved
        } else {
            do {
                reply = try await service.fetchOnce(rid: rid)
                copy.fetchTries += 1
                copy.replyFile = try store.saveReply(reply, rid: rid)
            } catch {
                try rethrowIfCancelled(error)
                logger.info("A BLAST fetch brought no reply: \(error.localizedDescription, privacy: .public)")
                copy.failedContacts += 1
                copy.nextCheckAt = nextTick(after: clock.now(), in: file)
                file.copies[index] = copy
                try await persist(file)
                return nil
            }
            copy.replyUnreadable = false
            file.copies[index] = copy
            try await persist(file)
        }

        progress(0.90, "Parsing BLAST results...")
        let result: BlastVerificationResult
        do {
            result = try service.buildVerificationResult(
                request: request,
                searchResults: try await service.parseReply(reply),
                rid: rid,
                submittedAt: file.createdAt,
                completedAt: clock.now()
            )
        } catch {
            try rethrowIfCancelled(error)
            logger.info("A BLAST reply could not be read: \(error.localizedDescription, privacy: .public)")
            copy.replyUnreadable = true
            let now = clock.now()
            let next = now.addingTimeInterval(BlastSearchPolicy.fetchWait)
            copy.nextCheckAt = next
            file.copies[index] = copy
            try await persist(file)
            guard copy.fetchTries < BlastSearchPolicy.fetchTries else {
                return .needsAPerson(words: BlastSearchWords.replyUnreadableLastTry)
            }
            progress(0.90, BlastSearchWords.replyUnreadable(nextTry: next, now: now))
            return nil
        }

        do {
            try await publish(result)
        } catch let refusal as BlastSearchRefusal {
            return .needsAPerson(words: refusal.words)
        } catch {
            try rethrowIfCancelled(error)
            let now = clock.now()
            let next = nextTick(after: now, in: file)
            copy.failedContacts += 1
            copy.nextCheckAt = next
            file.copies[index] = copy
            try await persist(file)
            progress(0.90, BlastSearchWords.recordNotWritten(
                folder: store.folder.path, reason: error.localizedDescription, nextTry: next, now: now
            ))
            return nil
        }

        file.copies[index] = copy
        try await end(&file, as: .done, words: "The result is saved.")
        store.removeReplies()
        progress(1.0, "BLAST verification complete")
        return .done(result)
    }
}
