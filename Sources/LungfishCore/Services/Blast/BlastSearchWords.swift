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

    /// The text of an NCBI page without its info blocks and markup, cut to what a file keeps.
    package static func plainWords(ofPage page: String) -> String {
        var text = page.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "<[^>]*>", with: " ", options: .regularExpression)
        text = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard text.utf8.count > BlastSearchPolicy.wordsLimit else { return text }
        return String(decoding: text.utf8.prefix(BlastSearchPolicy.wordsLimit), as: UTF8.self)
    }
}
