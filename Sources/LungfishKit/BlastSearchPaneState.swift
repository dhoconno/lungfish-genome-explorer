// BlastSearchPaneState.swift - What the BLAST pane says and offers for a search with no result to show
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

/// What the BLAST pane says and offers for a search with no result to show, in the words of UX-BLAST-WORDS Q1 and Q3.
///
/// It is made from the search file alone, so a pane reads the same before and after a relaunch. A waiting search is
/// never failed, and no words give a time to come. A person reads `send`.
public struct BlastSearchPaneState: Sendable, Equatable {
    /// What a person can press.
    public enum Action: String, Sendable, CaseIterable {
        case checkNow, sendAgain, stop, resume
    }

    /// One button of the pane. A grey button says why.
    public struct Button: Sendable, Equatable {
        public var action: Action
        public var title: String
        public var isEnabled: Bool
        public var reason: String?
    }

    /// The search's result folder.
    public var folder: URL
    public var heading: String
    public var body: String
    /// Every request ID so far, as selectable text under the body.
    public var requestIDs: [String]
    /// From row 5 on the pane holds still, with a clock in place of a moving bar, so it does not look hung.
    public var holdsStill: Bool
    public var buttons: [Button]
    /// The word on the action bar's BLAST Results button.
    public var barWord: String
    /// When a grey Check Now can be pressed again.
    public var checkAgainAt: Date?
    /// The line that names the sample the search is about, when the row it is shown for has one (W-21).
    public var subjectLine: String?

    /// `Sample SRR1`, the line that names a sample, or nil when there is no sample to name.
    public static func sampleLine(_ sample: String?) -> String? {
        guard let sample, !sample.isEmpty else { return nil }
        return "Sample \(sample)"
    }

    /// A result that came back for a source since replaced, which stays off the rows.
    package static func sourceReplaced(folder: URL) -> BlastSearchPaneState {
        BlastSearchPaneState(
            folder: folder,
            heading: "This search came back and is saved",
            body: "This search came back, but the result it was sent from has changed, so it is not shown on these rows. "
                + "It is saved in \(folder.path).",
            requestIDs: [],
            holdsStill: true,
            buttons: [],
            barWord: "BLAST Results"
        )
    }

    /// The state of `search`, nil once it has its record. `home` is the folder the search's line names, which tells a copied
    /// project's folder from the one that sent the search (UX-BLAST-WORDS, Every route).
    package static func make(_ search: BlastLiveSearch, noun: String, now: Date, home: String? = nil) -> BlastSearchPaneState? {
        let file = search.file
        let rids = file.copies.compactMap(\.rid)
        let rid = rids.last ?? ""
        let sends = rids.count
        let lastChecked = file.copies.compactMap(\.lastCheckAt).max()
        let nextCheck = file.copies.filter(\.state.isAlive).compactMap(\.nextCheckAt).min()
        let unreached = file.copies.map(\.failedInARow).max() ?? 0
        let time = { (date: Date) in BlastSearchWords.time(date, now: now) }

        let check = checkButton(lastChecked: lastChecked, now: now)
        let checkAgainAt = check.isEnabled ? nil : lastChecked?.addingTimeInterval(BlastSearchPolicy.checkFloor)
        let stop = Button(action: .stop, title: "Stop", isEnabled: true, reason: nil)
        let sendAgain = Button(action: .sendAgain, title: "Send Again", isEnabled: true, reason: nil)
        var greySendAgain = sendAgain
        greySendAgain.isEnabled = false
        greySendAgain.reason = "LGE sends this search again on its own for now. You can send it yourself once LGE's own sends are done."
        let resume = Button(action: .resume, title: "Resume", isEnabled: true, reason: nil)

        func state(
            _ heading: String, _ body: String, still: Bool = false, buttons: [Button], bar: String = "BLAST: waiting"
        ) -> BlastSearchPaneState {
            BlastSearchPaneState(
                folder: search.folder, heading: heading, body: body, requestIDs: rids, holdsStill: still,
                buttons: buttons, barWord: bar, checkAgainAt: checkAgainAt
            )
        }

        if let home, home != search.folder.standardizedFileURL.path, !file.state.isEnding, FileManager.default.fileExists(atPath: home) {
            return state("Sent from another copy of this project", BlastSearchWords.fromAnotherCopy(rid: rids.last), buttons: [check])
        }

        switch file.state {
        case .done:
            return nil
        case .sending:
            let body = BlastSearchWords.busySend(of: file, now: now).map { "\($0). You can keep working." } ?? "You can keep working."
            return state("Sending \(noun) to NCBI", body, buttons: [stop], bar: "BLAST Results")
        case .sendUnknown:
            let body = nextCheck.map { BlastSearchWords.notConfirmed(nextTry: $0, now: now) } ?? "You can keep working."
            return state("Sending \(noun) to NCBI", body, buttons: [stop])
        case .waiting:
            if let hold = file.copyHold, hold.reason == .guardPause {
                let body = "The last \(BlastSearchPolicy.spentInARowThatPause) searches got stuck at NCBI, so LGE sends nothing again "
                    + "before \(time(hold.until)), to add no load to a stuck service. This search stays at NCBI and comes back on this "
                    + "row on its own. You can send it again yourself or stop it."
                return state("Still waiting at NCBI", body + checkedLine(lastChecked, time), still: true, buttons: [check, sendAgain, stop])
            }
            if file.spentAt != nil {
                var body = "NCBI has not finished this search. It is not lost: LGE keeps every request ID and keeps checking, and "
                    + "either the result or NCBI's own answer comes back on this row. You can quit LGE. The search stays at NCBI, and "
                    + "LGE checks it again when you next open LGE. NCBI sets how long this takes, and some searches have taken hours. "
                    + "You can keep working, send it again or stop it."
                if unreached >= BlastSearchPolicy.failedChecksThatAreSaid {
                    body += " LGE could not reach NCBI at the last \(unreached) checks and keeps trying. Look at this Mac's network if this goes on."
                }
                return state("Still waiting at NCBI", body + checkedLine(lastChecked, time), still: true, buttons: [check, sendAgain, stop])
            }
            if sends >= 2 {
                let body = "NCBI has not answered yet, so LGE sent the same \(noun) again. The first answer counts. "
                    + "\(sends) sends so far. You can keep working."
                return state("Waiting for NCBI", body + checkedLine(lastChecked, time), buttons: [check, greySendAgain, stop])
            }
            let body = "NCBI has the search, request ID \(rid). You can keep working, and the result comes back here."
            return state("Waiting for NCBI", body + checkedLine(lastChecked, time), buttons: [check, greySendAgain, stop])
        case .fetching:
            let winner = file.winner
            if winner.replyUnreadable, winner.fetchTries >= BlastSearchPolicy.fetchTries {
                var tryAgain = check
                tryAgain.title = "Try Again"
                return state("Result not read", BlastSearchWords.replyUnreadableLastTry + ".", still: true, buttons: [tryAgain, sendAgain, stop])
            }
            if winner.replyUnreadable, let next = winner.nextCheckAt {
                return state("Result not read yet", BlastSearchWords.replyUnreadable(nextTry: next, now: now) + ".", still: true, buttons: [check, sendAgain, stop])
            }
            return state("Collecting the result", BlastSearchWords.collecting(rid: winner.rid) + ".", buttons: [check, greySendAgain, stop])
        case .expired:
            let body = "NCBI keeps a search for a limited time, and it no longer has request ID \(rid). No result was saved and no badge "
                + "was given. LGE kept the \(noun), so Send Again searches them afresh."
            return state("NCBI no longer holds this search", body, still: true, buttons: [sendAgain], bar: "BLAST: no result")
        case .ncbiFailed:
            let said = file.copies.compactMap(\.words).last ?? file.ending?.words ?? ""
            let body = "NCBI said: \(said). Request ID \(rid). No result was saved and no badge was given. Choose Send Again. "
                + "If NCBI says the same again, its message is about this search, so check the \(noun) or the database."
            return state("NCBI could not finish this search", body, still: true, buttons: [sendAgain], bar: "BLAST: no result")
        case .notSent:
            let words = file.ending?.words ?? "Not sent. Nothing is waiting at NCBI. Choose Send Again later"
            let said = words.hasPrefix("Not sent. ") ? String(words.dropFirst("Not sent. ".count)) : words
            return state("Not sent", said.hasSuffix(".") ? said : said + ".", still: true, buttons: [sendAgain], bar: "BLAST: no result")
        case .stopped:
            let body = "LGE no longer checks it, and NCBI may still finish it. Choose Resume to check it again, or Send Again to "
                + "send the same \(noun) afresh. No result is saved until one comes back."
            return state("You stopped this search", body, still: true, buttons: [resume, sendAgain], bar: "BLAST: stopped")
        }
    }

    private static func checkedLine(_ lastChecked: Date?, _ time: (Date) -> String) -> String {
        lastChecked.map { " Last checked \(time($0))." } ?? ""
    }

    /// Check Now, grey with its reason inside NCBI's one check a minute.
    private static func checkButton(lastChecked: Date?, now: Date) -> Button {
        guard let lastChecked, now.timeIntervalSince(lastChecked) < BlastSearchPolicy.checkFloor else {
            return Button(action: .checkNow, title: "Check Now", isEnabled: true, reason: nil)
        }
        let again = lastChecked.addingTimeInterval(BlastSearchPolicy.checkFloor)
        let reason = "LGE checked at \(BlastSearchWords.time(lastChecked, now: now)). NCBI asks for no more than one check a minute, "
            + "so you can check again at \(BlastSearchWords.time(again, now: now))."
        return Button(action: .checkNow, title: "Check Now", isEnabled: false, reason: reason)
    }
}

/// Where the pane's buttons go. The App's monitor answers them, so a pane names no App type (layering rule 1).
@MainActor
public enum BlastSearchPaneActions {
    public static var perform: (@MainActor (BlastSearchPaneState.Action, URL) -> Void)?
    /// Whether a viewer's own run holds `folder`. The monitor leaves such a folder alone, so Check Now says so.
    public static var isAtWork: (@MainActor (URL) -> Bool)?
    /// The folder the line of a search names, which tells a copied project's folder from the one that sent the search.
    public static var homeFolder: (@MainActor (UUID) -> String?)?
    /// The name a pane hears a press's answer under, with the search's folder as its object.
    public static let saidNotification = Notification.Name("BlastSearchPaneActions.said")
    /// The key of the words in ``saidNotification``.
    public static let saidWordsKey = "words"

    /// Says what a press came to when the row's next refresh would take the words away, such as a Send Again that LGE's
    /// own limit refused (UX 8).
    public static func say(_ words: String, about folder: URL) {
        NotificationCenter.default.post(name: saidNotification, object: folder, userInfo: [saidWordsKey: words])
    }
}
