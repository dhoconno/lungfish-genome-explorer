// BlastSearchFile+Steps.swift - What a BLAST search does next, read from its file alone
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

extension BlastSearchFile {
    /// One thing a search can do next.
    package enum Step: Sendable, Equatable {
        /// POST the form for this place in ``BlastSearchFile/copies``.
        case put(copy: Int)
        /// Ask NCBI how this send stands.
        case check(copy: Int)
        /// Fetch or read again the winner's reply.
        case fetch(copy: Int)
        /// Make the next of LGE's own sends.
        case newCopy
        /// Every send LGE makes on its own has been out long enough.
        case spend
        /// A file that says waiting and holds no send still alive.
        case noneLive
        /// A folder that may not POST has nothing it may do.
        case nothing
    }

    /// The winner's place in ``copies``, or the first when none has won.
    package var winnerIndex: Int {
        copies.firstIndex { $0.ordinal == winnerOrdinal } ?? 0
    }

    /// Whether any send can still bring an answer.
    package var hasAliveCopy: Bool {
        copies.contains { $0.state.isAlive }
    }

    /// When the last send NCBI took went out.
    package var lastPostAt: Date? {
        copies.compactMap(\.postAt).max()
    }

    private var hasACopyOnItsWay: Bool {
        copies.contains { $0.state == .sending || $0.state == .sendUnknown }
    }

    /// When LGE's next own send is due, or nil when none will come.
    ///
    /// A copy is due at search age k x ``BlastSearchPolicy/resendInterval``, and never sooner than that long after the
    /// last send, so a first send NCBI took late, a wake from sleep and the end of a hold each bring one POST and not
    /// all at once. A FAILED from NCBI brings no more, since the query may be at fault, and a hold moves the time on.
    package func nextCopyDue() -> Date? {
        guard route == .ncbi, state == .waiting, winnerOrdinal == nil, copies.count < BlastSearchPolicy.maxCopies,
              !hasACopyOnItsWay, copies.contains(where: { $0.state == .live }),
              !copies.contains(where: { $0.state == .failed })
        else { return nil }
        var due = createdAt.addingTimeInterval(BlastSearchPolicy.resendInterval * Double(copies.count))
        if let lastPostAt { due = max(due, lastPostAt.addingTimeInterval(BlastSearchPolicy.resendInterval)) }
        if let copyHold { due = max(due, copyHold.until) }
        return due
    }

    /// When this search has done all it does on its own, or nil when it has, or when another send is still to come.
    package func spendDue() -> Date? {
        guard state == .waiting, spentAt == nil, !hasACopyOnItsWay, nextCopyDue() == nil, let lastPostAt else { return nil }
        return lastPostAt.addingTimeInterval(BlastSearchPolicy.resendInterval)
    }

    /// Whether this search counts as stuck for the guard. Its third send went out and NCBI has not answered with a
    /// failure, and it has not struck before, so a resume cannot strike twice.
    package var strikesTheGuard: Bool {
        !guardStruck && copies.count >= BlastSearchPolicy.maxCopies && copies.last?.postAt != nil
            && !copies.contains { $0.state == .failed }
    }

    /// What this search does next and when. Of what is due now the earlier POST goes first, so of two sends READY at one
    /// tick the earlier wins (BIO-BLAST-TIES item 12), and any check goes before a new POST, which a READY can save.
    ///
    /// With `mayPost` false, as for a copied project, it only checks and fetches and strikes no guard (item 19).
    package func nextStep(now: Date, mayPost: Bool = true) -> (step: Step, due: Date) {
        switch state {
        case .fetching:
            return (.fetch(copy: winnerIndex), copies[winnerIndex].nextCheckAt ?? now)
        case .sending, .sendUnknown:
            guard mayPost else { return (.nothing, .distantFuture) }
            return (.put(copy: 0), copies[0].nextCheckAt ?? now)
        case .waiting, .done, .expired, .ncbiFailed, .notSent, .stopped:
            break
        }
        var steps: [(step: Step, due: Date, place: Int)] = []
        for (index, copy) in copies.enumerated() {
            if copy.state == .sending || copy.state == .sendUnknown {
                guard mayPost else { continue }
                steps.append((.put(copy: index), copy.nextCheckAt ?? now, index))
            } else if copy.state == .live {
                steps.append((.check(copy: index), copy.nextCheckAt ?? now, index))
            }
        }
        if mayPost, let due = nextCopyDue() { steps.append((.newCopy, due, copies.count)) }
        if mayPost, let due = spendDue() { steps.append((.spend, due, copies.count + 1)) }
        let next = steps.min { first, second in
            let (firstDue, secondDue) = (max(first.due, now), max(second.due, now))
            return firstDue == secondDue ? first.place < second.place : firstDue < secondDue
        }
        guard let next else { return mayPost ? (.noneLive, now) : (.nothing, .distantFuture) }
        return (next.step, next.due)
    }

    /// A person's Check Now. Every send still out is due at once, unless it was checked inside the last minute, and a
    /// reply LGE is still fetching is due at once.
    package mutating func checkNow(at now: Date) {
        for index in copies.indices where copies[index].state == .live {
            let floor = copies[index].lastCheckAt?.addingTimeInterval(BlastSearchPolicy.checkFloor) ?? now
            copies[index].nextCheckAt = max(now, floor)
        }
        if state == .fetching { copies[winnerIndex].nextCheckAt = now }
    }

    /// A person's Resume of a search they stopped. It goes back to where its sends stand, with their due times as they
    /// are, which read as due now once they have passed.
    package mutating func takeUp() {
        ending = nil
        if winnerOrdinal != nil {
            state = .fetching
        } else if copies.contains(where: { $0.state == .live }) {
            state = .waiting
        } else {
            state = copies[0].state == .sendUnknown ? .sendUnknown : .sending
        }
    }
}
