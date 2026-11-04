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
/// (ARCH-BLAST-RESILIENCE section 5). A search NCBI holds is sent again as ``BlastSearchPolicy`` sets, and the first
/// READY wins. Every due time is wall clock in the file, so a sleep, a quit and a restart all
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
            let index = file.winnerIndex
            file.copies[index].replyUnreadable = false
            if file.copies[index].fetchTries >= BlastSearchPolicy.fetchTries { file.copies[index].fetchTries = 0 }
        }
        sayWhereItStands(file)
        while true {
            try Task.checkCancellation()
            if file.state.isEnding {
                return .ended(file.state, words: file.ending?.words ?? "")
            }
            let next = file.nextStep(now: clock.now())
            let wait = next.due.timeIntervalSince(clock.now())
            if wait > 0 { try await clock.sleep(wait) }
            try Task.checkCancellation()
            switch next.step {
            case .put(let index):
                try await sendThePut(&file, at: index)
            case .check(let index):
                try await checkTheStatus(&file, at: index)
            case .fetch:
                if let outcome = try await fetchTheReply(&file) { return outcome }
            case .newCopy:
                try await sendACopy(&file)
            case .spend:
                try await markSpent(&file)
            case .noneLive:
                try await endWithNoneLive(&file)
            }
        }
    }

    private func sayWhereItStands(_ file: BlastSearchFile) {
        switch file.state {
        case .sending, .sendUnknown:
            progress(0.15, BlastSearchWords.sending(request.sequences.count, noun: noun))
        case .waiting:
            guard let rid = file.copies[0].rid else { return }
            let words = file.copies.count > 1 ? waitingWords(file, now: clock.now()) : BlastSearchWords.waiting(rid: rid)
            progress(waitingFraction(of: file), words)
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

    private func end(_ file: inout BlastSearchFile, as state: BlastSearchFile.State, words: String, replyBytes: Int? = nil) async throws {
        let now = clock.now()
        file.state = state
        file.ending = BlastSearchFile.Ending(state: state, at: now, words: words)
        try await persist(file)
        await logLine(file, at: now, ending: state.rawValue, replyBytes: replyBytes)
    }

    private func logLine(_ file: BlastSearchFile, at now: Date, ending: String?, replyBytes: Int? = nil) async {
        await service.searchShared.searchLog?.append(BlastSearchLog.line(for: file, at: now, ending: ending, replyBytes: replyBytes))
    }

    private func rethrowIfCancelled(_ error: any Error) throws {
        if error is CancellationError || Task.isCancelled { throw CancellationError() }
    }

    // MARK: A send's ending

    /// A log line for a change the row does not show, with the row's own words after it, so the row reads as before.
    private func say(_ line: String, about file: BlastSearchFile, now: Date) {
        progress(waitingFraction(of: file), line)
        progress(waitingFraction(of: file), waitingWords(file, now: now))
    }

    /// One send came to NCBI's ending. Beside another send still alive the search goes on and the log says so, and
    /// with none alive this ending is the search's (UX-BLAST-WORDS Q1).
    private func sendEnded(
        _ file: inout BlastSearchFile,
        as state: BlastSearchFile.State,
        words: String,
        line: String
    ) async throws {
        guard file.hasAliveCopy else {
            try await end(&file, as: state, words: words)
            return
        }
        try await persist(file)
        say(line, about: file, now: clock.now())
    }

    /// NCBI took nothing from this Put. For the first send that ends the search, and for a later one only that send.
    private func sendNotTaken(_ file: inout BlastSearchFile, at index: Int, words: String) async throws {
        file.copies[index].state = .notSent
        let copy = file.copies[index]
        if copy.kind == .first {
            try await end(&file, as: .notSent, words: words)
        } else if file.hasAliveCopy {
            try await persist(file)
            say(BlastSearchWords.laterSendNotTakenLine(send: copy.ordinal), about: file, now: clock.now())
        } else {
            try await endWithNoneLive(&file)
        }
    }

    /// No send is alive, so the last one NCBI answered names the ending.
    private func endWithNoneLive(_ file: inout BlastSearchFile) async throws {
        let answered = file.copies.last { $0.state == .failed || $0.state == .expired }
        guard let answered, let rid = answered.rid else {
            try await end(&file, as: .notSent, words: BlastSearchWords.stillNotConfirmed)
            return
        }
        if answered.state == .failed {
            try await end(&file, as: .ncbiFailed, words: BlastSearchWords.failed(rid: rid, words: answered.words ?? ""))
        } else {
            try await end(&file, as: .expired, words: BlastSearchWords.expired(rid: rid))
        }
    }

    // MARK: A copy

    /// Makes LGE's next own send, or holds it, as the day's count, the guard or the hour's limit says. The guard takes
    /// the copy first and the ledger counts it after, and the guard gets it back on a refusal, so no two locks are ever
    /// held at once. A copy held stays due and never ends the search (ARCH-BLAST-RESILIENCE items 6 and 7).
    private func sendACopy(_ file: inout BlastSearchFile) async throws {
        let now = clock.now()
        if await service.postsInTheLastDay(at: now) > BlastSearchPolicy.postsADayBeforeNoCopies {
            try await holdTheCopy(&file, .dayCount, until: nextTick(after: now, in: file), now: now)
            return
        }
        let copyGuard = service.searchShared.copyGuard
        switch await copyGuard.takeCopy(at: now) {
        case .paused(let until):
            try await holdTheCopy(&file, .guardPause, until: until, now: now)
            return
        case .capFull(let until):
            try await holdTheCopy(&file, .copyCap, until: until, now: now)
            return
        case .granted:
            break
        }
        do {
            try await service.reservePost(sequenceCount: request.sequences.count, kind: .copy, at: now)
        } catch BlastServiceError.rateLimitExceeded(let refusal) {
            await copyGuard.giveBack(takenAt: now)
            try await holdTheCopy(&file, .hourlyLimit, until: refusal.fitsAt ?? nextTick(after: now, in: file), now: now)
            return
        }
        var copy = BlastSearchFile.Copy(ordinal: file.copies.count + 1, kind: .copy, nextCheckAt: now)
        copy.postReserved = true
        file.copies.append(copy)
        file.copyHold = nil
        try await persist(file)
        try await sendThePut(&file, at: file.copies.count - 1)
    }

    /// Words say a hold once for each change of reason, so a hold of hours adds one line and the row stays as it is,
    /// but for the guard's, which has its own row.
    private func holdTheCopy(
        _ file: inout BlastSearchFile,
        _ reason: BlastSearchFile.CopyHold.Reason,
        until: Date,
        now: Date
    ) async throws {
        let isNews = file.copyHold?.reason != reason
        file.copyHold = BlastSearchFile.CopyHold(reason: reason, until: until)
        try await persist(file)
        guard isNews else { return }
        switch reason {
        case .guardPause:
            say(BlastSearchWords.heldByTheGuardLine(until: until, now: now), about: file, now: now)
        case .copyCap, .hourlyLimit:
            say(BlastSearchWords.heldByTheLimitLine(until: until, now: now), about: file, now: now)
        case .dayCount:
            say(BlastSearchWords.heldByTheDayCountLine, about: file, now: now)
        }
    }

    /// Every send LGE makes on its own has been out long enough. The search goes on, and it says so once. The file says
    /// it struck before the guard hears, so a crash loses a strike and a resume can never strike twice.
    private func markSpent(_ file: inout BlastSearchFile) async throws {
        let now = clock.now()
        let strikes = file.strikesTheGuard
        file.spentAt = now
        if strikes { file.guardStruck = true }
        try await persist(file)
        if strikes { await service.searchShared.copyGuard.searchWasSpent(at: now) }
        let live = file.copies.filter { $0.state == .live }
        say(
            BlastSearchWords.allWaitingLine(
                sends: live.count, after: now.timeIntervalSince(file.createdAt),
                nextCheck: live.compactMap(\.nextCheckAt).min(), now: now
            ),
            about: file, now: now
        )
    }

    // MARK: The Put

    private func sendThePut(_ file: inout BlastSearchFile, at index: Int) async throws {
        let isTheLastTry = file.copies[index].state == .sendUnknown
        let form = try await savedForm(of: file)
        guard try await countThisPost(&file, at: index) else { return }
        let answer = try await service.sendPut(form, maxConcurrentSubmissions: request.maxConcurrentSubmissions)
        let now = clock.now()
        var copy = file.copies[index]
        if case .accepted(let submission) = answer {
            copy.rid = submission.rid
            copy.rtoe = submission.rtoe
            copy.postAt = now
            copy.state = .live
            copy.failedInARow = 0
            copy.nextCheckAt = now.addingTimeInterval(max(Double(submission.rtoe), BlastSearchPolicy.firstCheckFloor))
            file.copies[index] = copy
            file.state = .waiting
            try await persist(file)
            logger.info("BLAST search accepted, RID=\(submission.rid, privacy: .public) RTOE=\(submission.rtoe, privacy: .public)s")
            if copy.kind == .first {
                await logLine(file, at: now, ending: nil)
                progress(0.20, BlastSearchWords.firstSendLine(count: request.sequences.count, noun: noun, rid: submission.rid))
                progress(0.20, BlastSearchWords.sent(rid: submission.rid))
                progress(0.20, BlastSearchWords.waiting(rid: submission.rid))
            } else {
                say(
                    BlastSearchWords.laterSendLine(after: now.timeIntervalSince(file.createdAt), noun: noun, rid: submission.rid, send: copy.ordinal),
                    about: file, now: now
                )
            }
            return
        }
        copy.failedContacts += 1
        file.copies[index] = copy
        if isTheLastTry {
            try await sendNotTaken(&file, at: index, words: BlastSearchWords.stillNotConfirmed)
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
            file.copies[index] = copy
            try await persist(file)
            if copy.kind == .first { progress(0.15, BlastSearchWords.noConnection(nextTry: next, now: now)) }
        case .busy(let status, _):
            copy.busyAnswers += 1
            file.copies[index] = copy
            guard copy.busyAnswers <= BlastSearchPolicy.busyPutWaits.count else {
                try await sendNotTaken(&file, at: index, words: BlastSearchWords.refused(code: status, times: copy.busyAnswers))
                return
            }
            file.copies[index].nextCheckAt = now.addingTimeInterval(BlastSearchPolicy.busyPutWaits[copy.busyAnswers - 1])
            try await persist(file)
            logger.info("NCBI answered a BLAST Put with \(status, privacy: .public), try \(copy.busyAnswers, privacy: .public)")
        case .refused(let status, _):
            try await sendNotTaken(&file, at: index, words: BlastSearchWords.refused(code: status, times: 1))
        case .noRID(let page):
            file.copies[index].words = String(decoding: Data(page.utf8).prefix(BlastSearchPolicy.wordsLimit), as: UTF8.self)
            try await sendNotTaken(&file, at: index, words: BlastSearchWords.noRequestID(page: BlastSearchWords.plainWords(ofPage: page)))
        case .lostAfterSending(let reason):
            logger.info("The reply to a BLAST Put was lost: \(reason, privacy: .public)")
            let next = now.addingTimeInterval(BlastSearchPolicy.lostPutWait)
            copy.state = .sendUnknown
            copy.nextCheckAt = next
            file.copies[index] = copy
            if copy.kind == .first { file.state = .sendUnknown }
            try await persist(file)
            if copy.kind == .first { progress(0.15, BlastSearchWords.notConfirmed(nextTry: next, now: now)) }
        }
    }

    /// Counts this POST against LGE's own limit, as what it repeats. It returns false when the limit holds the POST,
    /// which stays due and never ends the search. The count is spent on disk before the POST goes, so a crash here makes
    /// the next POST count again and never leaves one uncounted.
    private func countThisPost(_ file: inout BlastSearchFile, at index: Int) async throws -> Bool {
        var copy = file.copies[index]
        if !copy.postReserved {
            do {
                try await service.reservePost(sequenceCount: request.sequences.count, kind: copy.kind, at: clock.now())
            } catch BlastServiceError.rateLimitExceeded(let refusal) {
                let now = clock.now()
                let due = refusal.fitsAt ?? nextTick(after: now, in: file)
                copy.nextCheckAt = due
                file.copies[index] = copy
                try await persist(file)
                logger.info("LGE's own limit holds a BLAST send until \(due, privacy: .public)")
                if copy.kind == .copy { say(BlastSearchWords.heldByTheLimitLine(until: due, now: now), about: file, now: now) }
                return false
            }
        }
        copy.postReserved = false
        file.copies[index] = copy
        try await persist(file)
        return true
    }

    /// The Put body as first saved, which every send repeats byte for byte. A file that has gone or changed is built
    /// again from the same query and options.
    private func savedForm(of file: BlastSearchFile) async throws -> Data {
        if let saved = try? store.loadForm(), BlastSearchStore.digest(of: saved) == file.formSHA256 { return saved }
        logger.warning("The saved BLAST form has gone or changed, so LGE builds it again from the query")
        return try await service.putForm(for: request)
    }

    // MARK: The check

    private func checkTheStatus(_ file: inout BlastSearchFile, at index: Int) async throws {
        var copy = file.copies[index]
        guard let rid = copy.rid else {
            // A file that says waiting and names no RID holds nothing to check, so that send goes back to its Put.
            copy.state = .sending
            copy.nextCheckAt = clock.now()
            file.copies[index] = copy
            if copy.kind == .first { file.state = .sending }
            return
        }
        var answer: BlastSearchStatusAnswer?
        do {
            answer = try await service.statusOnce(rid: rid)
        } catch {
            try rethrowIfCancelled(error)
            logger.info("A BLAST status check brought no news: \(error.localizedDescription, privacy: .private)")
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
                    file.copies[index] = copy
                    try await sendEnded(
                        &file, as: .expired, words: BlastSearchWords.expired(rid: rid),
                        line: BlastSearchWords.sendExpiredLine(rid: rid, send: copy.ordinal)
                    )
                    return
                }
            }
        case .error(let message):
            let onThePage = BlastSearchWords.plainWords(ofPage: answer?.page ?? "")
            let words = onThePage.isEmpty ? message : onThePage
            copy.state = .failed
            copy.lastCheckAt = now
            copy.words = words
            file.copies[index] = copy
            try await sendEnded(
                &file, as: .ncbiFailed, words: BlastSearchWords.failed(rid: rid, words: words),
                line: BlastSearchWords.sendEndedLine(rid: rid, send: copy.ordinal, words: words)
            )
            return
        case .ready(let thereAreHits):
            copy.state = .ready
            copy.lastCheckAt = now
            copy.readyAt = now
            copy.thereAreHits = thereAreHits
            copy.nextCheckAt = now
            file.copies[index] = copy
            file.winnerOrdinal = copy.ordinal
            file.state = .fetching
            try await persist(file)
            let age = now.timeIntervalSince(file.createdAt)
            if age < BlastSearchPolicy.cameBackInTimeAge { await service.searchShared.copyGuard.searchCameBackInTime() }
            let sends = file.copies.filter { $0.rid != nil }.count
            if sends > 1 {
                progress(waitingFraction(of: file), BlastSearchWords.winLine(rid: rid, after: age, send: copy.ordinal, sends: sends))
            }
            return
        }
        file.copies[index] = copy
        try await persist(file)
        progress(waitingFraction(of: file), waitingWords(file, now: now))
    }

    /// The row's words while NCBI holds the search, the Q1 row its sends and hold make it.
    private func waitingWords(_ file: BlastSearchFile, now: Date) -> String {
        let sends = file.copies.filter { $0.rid != nil }
        let live = file.copies.filter { $0.state == .live }
        let nextCheck = live.compactMap(\.nextCheckAt).min()
        let lastChecked = sends.compactMap(\.lastCheckAt).max()
        let since = sends.first?.postAt ?? file.createdAt
        if let failing = live.first(where: { $0.failedInARow >= BlastSearchPolicy.failedChecksThatAreSaid }),
           let rid = failing.rid, let nextCheck {
            return BlastSearchWords.notReached(rid: rid, failedInARow: failing.failedInARow, nextCheck: nextCheck, now: now)
        }
        if let hold = file.copyHold, hold.reason == .guardPause, hold.until > now {
            return BlastSearchWords.guardHoldsLaterSends(since: since, sends: sends.count, until: hold.until, nextCheck: nextCheck, now: now)
        }
        if file.spentAt != nil {
            return BlastSearchWords.everySendWaiting(since: since, sends: sends.count, lastChecked: lastChecked, nextCheck: nextCheck, now: now)
        }
        if sends.count > 1 {
            return BlastSearchWords.sentAgain(sends: sends.count, lastChecked: lastChecked, now: now)
        }
        guard let rid = sends.first?.rid else { return BlastSearchWords.sending(request.sequences.count, noun: noun) }
        guard let lastChecked else { return BlastSearchWords.waiting(rid: rid) }
        return BlastSearchWords.waiting(rid: rid, lastChecked: lastChecked, now: now)
    }

    // MARK: The reply

    /// Moves a READY search on by one contact, or by none when its reply is already on disk. Returns an outcome when
    /// this pass is over and nil when the next tick goes on.
    private func fetchTheReply(_ file: inout BlastSearchFile) async throws -> BlastSearchOutcome? {
        let index = file.winnerIndex
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
                logger.info("A BLAST fetch brought no reply: \(error.localizedDescription, privacy: .private)")
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
                await logLine(file, at: now, ending: nil, replyBytes: reply.count)
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
        try await end(&file, as: .done, words: "The result is saved.", replyBytes: reply.count)
        store.removeReplies()
        progress(1.0, "BLAST verification complete")
        return .done(result)
    }
}
