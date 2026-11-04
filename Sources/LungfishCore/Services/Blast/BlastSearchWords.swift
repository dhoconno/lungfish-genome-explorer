// BlastSearchWords.swift - The words a person reads about a BLAST search
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The words of UX-BLAST-WORDS Q1 that the search itself says, each number from ``BlastSearchPolicy``.
///
/// A waiting search is never failed, and no words give a time to come. A clock time appears only for LGE's own next
/// contact, and durations only for what has happened.
package enum BlastSearchWords {
    /// `<n> <noun>`, in the singular for one. `noun` is `reads`, `contigs` or `sequences`.
    private static func counted(_ count: Int, _ noun: String) -> String {
        guard count == 1, noun.hasSuffix("s") else { return "\(count) \(noun)" }
        return "1 \(noun.dropLast())"
    }

    /// `<T>`, a local clock time, with the day when it is not today.
    package static func time(_ date: Date, now: Date) -> String {
        if Calendar.current.isDate(date, inSameDayAs: now) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    // MARK: Q1 rows

    package static func sending(_ count: Int, noun: String) -> String {
        "Sending \(counted(count, noun)) to NCBI"
    }

    package static func sent(rid: String) -> String {
        "NCBI has the search, request ID \(rid)"
    }

    package static func waiting(rid: String) -> String {
        "Waiting for NCBI, request ID \(rid)"
    }

    package static func waiting(rid: String, lastChecked: Date, now: Date) -> String {
        "\(waiting(rid: rid)). Last checked \(time(lastChecked, now: now))"
    }

    /// Rows R1 and 5, a check that has not reached NCBI from the third in a row.
    package static func notReached(rid: String, failedInARow: Int, nextCheck: Date, now: Date) -> String {
        "Waiting for NCBI, request ID \(rid), next check about \(time(nextCheck, now: now)). "
            + "LGE could not reach NCBI at the last \(failedInARow) checks and keeps trying. Look at this Mac's network if this goes on."
    }

    /// Row 8.
    package static func expired(rid: String) -> String {
        "NCBI no longer holds this search, request ID \(rid). No result. Choose Send Again"
    }

    /// Row 9.
    package static func failed(rid: String, words: String) -> String {
        "NCBI could not finish this search, request ID \(rid): \(words)"
    }

    /// Row R2, with the search still on its way, since nothing was sent and the search goes on (section 5).
    package static func noConnection(nextTry: Date, now: Date) -> String {
        "Not sent yet. This Mac could not reach NCBI, so nothing went out. LGE tries again at \(time(nextTry, now: now)). "
            + "Look at this Mac's network if this goes on."
    }

    /// Row R3.
    package static func refused(code: Int, times: Int) -> String {
        "Not sent. NCBI answered with error \(code) \(times) \(times == 1 ? "time" : "times"), so LGE stopped trying. "
            + "Nothing is waiting at NCBI. Choose Send Again later"
    }

    /// Row R4.
    package static func notConfirmed(nextTry: Date, now: Date) -> String {
        "NCBI did not confirm it got this search. LGE sends it once more at \(time(nextTry, now: now))"
    }

    /// Row R4's second miss, which ends the send.
    package static let stillNotConfirmed =
        "Not sent. NCBI did not confirm it got this search, so LGE stopped trying. Choose Send Again later"

    /// A 200 page with no request ID.
    package static func noRequestID(page: String) -> String {
        let shown = page.isEmpty ? "" : " NCBI said: \(page)"
        return "Not sent. NCBI answered without a request ID, so nothing is waiting at NCBI. Choose Send Again later.\(shown)"
    }

    /// Row R5, while LGE tries again.
    package static func replyUnreadable(nextTry: Date, now: Date) -> String {
        "NCBI finished this search, but its reply could not be read. LGE kept the reply and tries again at \(time(nextTry, now: now))"
    }

    /// Row R5, after the last try.
    package static let replyUnreadableLastTry =
        "NCBI finished this search, but its reply could not be read. LGE kept the reply. Choose Try Again, or Send Again to search afresh"

    /// Section 5's row on a record that cannot be written. The words name the folder.
    package static func recordNotWritten(folder: String, reason: String, nextTry: Date, now: Date) -> String {
        "NCBI finished this search, but LGE could not save the result in \(folder): \(reason). "
            + "LGE kept the reply and tries again at \(time(nextTry, now: now))"
    }

    /// Section 1's row on a replaced file. No record claims another query.
    package static func queryReplaced(folder: String) -> String {
        "NCBI finished this search, but \(BlastSubmissionRecord.queryFileName) in \(folder) is no longer the file LGE sent, "
            + "so LGE saved no result and kept the reply. Put the file back and choose Try Again, or choose Send Again to search afresh"
    }

    /// A file of the search that cannot be written, which holds the search up until it can.
    package static func fileNotWritten(folder: String, reason: String) -> String {
        "LGE could not save this search in \(folder): \(reason). LGE keeps trying. Check that the folder can be written."
    }

    /// Q5, LGE's own limit. NCBI was not contacted, and the words say so. The time is when the search fits.
    package static func limitRefusal(_ refusal: BlastLimitRefusal) -> String {
        let limit = "LGE's own limit stopped this search, and NCBI was not contacted. LGE sends at most \(refusal.limit) reads an hour"
        guard let fitsAt = refusal.fitsAt else {
            return "\(limit), so \(refusal.count) reads cannot go as one search. Send \(refusal.limit) or fewer."
        }
        let gone = "\(refusal.used) \(refusal.used == 1 ? "has" : "have") gone in the last hour"
        let fits = "This search of \(counted(refusal.count, "reads")) fits at \(time(fitsAt, now: refusal.refusedAt)). Try again then"
        let free = refusal.limit - refusal.used
        return "\(limit), and \(gone). \(fits)\(free > 0 ? ", or send \(free) or fewer reads now" : "")."
    }

    // MARK: A search that outlives its process

    /// Q3, `blast submit` and `blast resume` on SIGTERM with a request ID.
    package static func leftAtNCBI(rid: String, folder: String) -> String {
        "LGE stopped checking. The search stays at NCBI as request ID \(rid). To collect it, run: lungfish-cli blast resume --output \(folder)"
    }

    /// Q3, the same before any request ID.
    package static let stoppedBeforeAnAnswer = "Stopped before NCBI answered, so no search is known to be waiting."

    /// Row 10.
    package static let stopped = "Stopped. LGE no longer checks this search. Choose Resume to check it again"

    /// Q3, Stop with the result already in.
    package static let nothingToStop = "This search had already come back, so there was nothing to stop."

    /// A Stop that a leaf at work did not let go of within its wait.
    package static let stopNotTaken =
        "Another LGE process is working on this search and did not let go of it, so LGE did not stop it. Try Stop again."

    /// A pass that found another process at work on the search.
    package static let alreadyRunning = "Another LGE process is already working on this search, so this one left it alone."

    /// Q3, Check Now pressed while LGE's own pass is checking the search (CHECK-NOW-MONITOR-PASS). The pass tells the pane
    /// what it finds, so this names no time to come.
    package static let checkAlreadyUnderWay = "LGE is already checking this search. What NCBI says will show here when that check ends."

    /// Every route, moved project.
    package static func folderMissing(path: String, rid: String?) -> String {
        let stays = rid.map { "The search stays at NCBI as request ID \($0)." } ?? "No search is known to be waiting at NCBI."
        return "LGE cannot find the folder this search saves into: \(path). \(stays) Open the project from where it is now."
    }

    /// Every route, copied project.
    package static func fromAnotherCopy(rid: String?) -> String {
        let sent = rid.map { ", request ID \($0)" } ?? ""
        return "This search was sent from another copy of this project\(sent). Choose Check Now to collect it here."
    }

    /// The row of a search a project's opening took up, until its first pass.
    package static func adopted(rid: String?) -> String {
        rid.map { waiting(rid: $0) } ?? sending
    }

    private static let sending = "Sending to NCBI"

    /// A READY search whose reply is not yet a record.
    package static func collecting(rid: String?) -> String {
        rid.map { "NCBI finished this search, request ID \($0). LGE is collecting the result" } ?? "LGE is collecting the result"
    }

    // MARK: Q1 rows of a search sent again

    /// A duration of what has happened, as `4 min 12 s` or `5 h 3 min`.
    package static func duration(_ seconds: TimeInterval) -> String {
        let whole = max(0, Int(seconds.rounded()))
        switch whole {
        case ..<60:
            return "\(whole) s"
        case ..<3600:
            return whole % 60 == 0 ? "\(whole / 60) min" : "\(whole / 60) min \(whole % 60) s"
        default:
            let minutes = whole / 60 % 60
            return minutes == 0 ? "\(whole / 3600) h" : "\(whole / 3600) h \(minutes) min"
        }
    }

    /// What row 7 says after the counts, with the sends left out at one (UX-BLAST-WORDS Q1). The word is collected, never took.
    package static func collected(after seconds: TimeInterval, sends: Int) -> String {
        "Collected \(duration(seconds)) after the first send" + (sends > 1 ? ", \(sends) sends" : "")
    }

    /// Row 7's ending for a search that has come back, or nil for one that has not.
    package static func collected(in file: BlastSearchFile) -> String? {
        guard file.state == .done, let ending = file.ending else { return nil }
        return collected(after: ending.at.timeIntervalSince(file.copies.first?.postAt ?? file.createdAt), sends: file.copies.filter { $0.rid != nil }.count)
    }

    /// What the pane says under the summary of a search that has come back (UX-BLAST-WORDS Q7), or nil for one that has not.
    package static func collectedOnThePane(in file: BlastSearchFile) -> String? {
        guard file.state == .done, let ending = file.ending,
              let rid = file.copies.first(where: { $0.ordinal == file.winnerOrdinal })?.rid else { return nil }
        let sends = file.copies.filter { $0.rid != nil }.count
        return "Collected \(duration(ending.at.timeIntervalSince(file.copies.first?.postAt ?? file.createdAt))) after the first send. "
            + "\(counted(sends, "sends")), answered by request ID \(rid)."
    }

    /// The log line of a search that a launch of LGE found (UX-BLAST-WORDS Q2).
    package static func relaunched(at: Date, now: Date) -> String {
        "LGE opened at \(time(at, now: now)) and checked this search again."
    }

    /// What `blast export-table` says of a folder whose search has not come back (UX-BLAST-WORDS, Every route).
    package static func noTableWhileWaiting(folder: String) -> String {
        "This folder holds a search still waiting at NCBI, so there is no table yet. Run lungfish-cli blast resume --output \(folder)."
    }

    /// Row 4.
    package static func sentAgain(sends: Int, lastChecked: Date?, now: Date) -> String {
        let row = "Waiting for NCBI, \(sends) sends so far"
        return lastChecked.map { "\(row). Last checked \(time($0, now: now))" } ?? row
    }

    /// Row 5.
    package static func everySendWaiting(since: Date, sends: Int, lastChecked: Date?, nextCheck: Date?, now: Date) -> String {
        let row = "Waiting at NCBI since \(time(since, now: now)), \(counted(sends, "sends"))"
        let checked = lastChecked.map { "Last checked \(time($0, now: now))" }
        let next = nextCheck.map { "next check about \(time($0, now: now))" }
        let rest = [checked, next].compactMap { $0 }.joined(separator: ", ")
        return rest.isEmpty ? row : "\(row). \(rest.prefix(1).uppercased())\(rest.dropFirst())"
    }

    /// Row 6.
    package static func guardHoldsLaterSends(since: Date, sends: Int, until: Date, nextCheck: Date?, now: Date) -> String {
        let row = "Waiting at NCBI since \(time(since, now: now)), \(counted(sends, "sends")). LGE sends nothing again before \(time(until, now: now))"
        return nextCheck.map { "\(row). Next check about \(time($0, now: now))" } ?? row
    }

    // MARK: Q2 log lines

    /// The number of sends in all, as the words say it.
    /// Q4, the line a person reads before `noun` leaves this Mac. `noun` is `reads`, `contigs` or `sequences`.
    package static func consentLine(noun: String, database: String) -> String {
        "Sends the selected \(noun) to NCBI BLASTN \(database), so they leave this Mac and LGE cannot call them back. "
            + "If NCBI is slow, LGE sends the same \(noun) again, at most \(sendsInAll) sends in all. The record lists every send."
    }

    /// Q4, the help of a BLAST leaf. `stays` says where its search waits, as `in --output`.
    package static func commandLineConsent(stays: String) -> String {
        "The sequences go to NCBI and leave this Mac, and LGE cannot call them back. If NCBI is slow, the same sequences are sent again, "
            + "at most \(sendsInAll) sends in all, and the record lists every send. "
            + "A search still waiting stays \(stays), and lungfish-cli blast resume --output <folder> collects it later."
    }

    /// ``BlastSearchPolicy/maxCopies`` as a person reads it.
    package static var sendsInAll: String {
        let names = [1: "one", 2: "two", 3: "three", 4: "four", 5: "five"]
        return names[BlastSearchPolicy.maxCopies] ?? String(BlastSearchPolicy.maxCopies)
    }

    package static func firstSendLine(count: Int, noun: String, rid: String) -> String {
        "Sent \(counted(count, noun)) to NCBI, request ID \(rid). LGE may send \(count == 1 ? "it" : "them") again, at most \(sendsInAll) sends in all."
    }

    package static func laterSendLine(after seconds: TimeInterval, noun: String, rid: String, send: Int) -> String {
        "NCBI has not answered after \(duration(seconds)), so LGE sent the same \(noun) again, request ID \(rid), "
            + "send \(send) of \(BlastSearchPolicy.maxCopies). The first answer counts."
    }

    package static func allWaitingLine(sends: Int, after seconds: TimeInterval, nextCheck: Date?, now: Date) -> String {
        let waiting = sends == 1
            ? "The send still out is waiting at NCBI after \(duration(seconds))"
            : "All \(sends) sends are still waiting at NCBI after \(duration(seconds))"
        let next = nextCheck.map { " Next check about \(time($0, now: now))." } ?? ""
        return "\(waiting). LGE keeps checking.\(next)"
    }

    package static func heldByTheGuardLine(until: Date, now: Date) -> String {
        "LGE did not send this search again, because the last \(BlastSearchPolicy.spentInARowThatPause) searches got stuck at NCBI. "
            + "It sends nothing again before \(time(until, now: now))."
    }

    package static func heldByTheLimitLine(until: Date, now: Date) -> String {
        "LGE did not send this search again, because LGE's hourly limit is full. It can send again at \(time(until, now: now)). NCBI was not contacted."
    }

    package static let heldByTheDayCountLine =
        "LGE did not send this search again, because this Mac is past NCBI's \(BlastSearchPolicy.postsADayBeforeNoCopies) searches in 24 hours. NCBI moves a user past that number to a slower queue, and only in extreme cases blocks one."

    /// Q2, a person's send.
    package static func personSentLine(noun: String, rid: String, sends: Int) -> String {
        "You sent the same \(noun) again, request ID \(rid). \(sends) sends so far."
    }

    package static func winLine(rid: String, after seconds: TimeInterval, send: Int, sends: Int) -> String {
        "Request ID \(rid) came back, \(duration(seconds)) after the first send, on send \(send) of \(sends). LGE no longer checks the others."
    }

    /// A later send NCBI did not take, while another send is still waiting, so the row stays as it is.
    package static func laterSendNotTakenLine(send: Int) -> String {
        "NCBI did not take send \(send) of \(BlastSearchPolicy.maxCopies), so LGE goes on with the sends it has. The search is unchanged."
    }

    /// A send NCBI no longer holds, while another send is still waiting.
    package static func sendExpiredLine(rid: String, send: Int) -> String {
        "NCBI no longer holds send \(send), request ID \(rid). LGE goes on with the sends it has."
    }

    /// A send NCBI could not finish, while another send is still waiting. LGE sends nothing more on its own.
    package static func sendEndedLine(rid: String, send: Int, words: String) -> String {
        "NCBI could not finish send \(send), request ID \(rid): \(words). LGE goes on with the sends it has and sends no more on its own."
    }

    /// The text of an NCBI page without its info blocks and markup, cut to what a file keeps.
    package static func plainWords(ofPage page: String) -> String {
        var text = page.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "<[^>]*>", with: " ", options: .regularExpression)
        text = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard text.utf8.count > BlastSearchPolicy.wordsLimit else { return text }
        return String(decoding: text.utf8.prefix(BlastSearchPolicy.wordsLimit), as: UTF8.self)
    }
}
