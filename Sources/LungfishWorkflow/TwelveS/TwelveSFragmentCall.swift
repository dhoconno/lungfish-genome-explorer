// TwelveSFragmentCall.swift - One call for the two mates of an unmerged 12S pair
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Why the two mates of an unmerged pair gave different calls, so the pair
/// was left out of every abundance figure (owner decision of 2026-10-05).
public enum TwelveSPairDiscordance: String, CaseIterable, Codable, Sendable {
    /// Both mates matched a target exactly, and the targets differ.
    case differentTargets = "different_targets"
    /// Both mates matched more than one target, and the candidate sets differ.
    case differentCandidates = "different_candidates"
    /// One mate gave a call and the other matched nothing.
    case oneMateUnresolved = "one_mate_unresolved"
    /// One mate matched one target and the other matched several.
    case oneMateAmbiguous = "one_mate_ambiguous"

    public var displayName: String {
        switch self {
        case .differentTargets: return "different targets"
        case .differentCandidates: return "different candidates"
        case .oneMateUnresolved: return "one mate unresolved"
        case .oneMateAmbiguous: return "one mate ambiguous"
        }
    }

    /// `1 pair with different targets`, `2 pairs with one mate unresolved`,
    /// for the CLI's line and the viewport alike. `reasonName` is a
    /// ``displayName``, or a reason this version does not know, in words.
    public static func countPhrase(_ count: Int, reasonName: String) -> String {
        "\(count) \(count == 1 ? "pair" : "pairs") with \(reasonName)"
    }
}

/// The call of one fragment made from the calls of its two mates.
public enum TwelveSFragmentCall: Equatable, Sendable {
    /// Both mates gave the identical call, which the fragment takes.
    case concordant(TwelveSReadClassification)
    /// The mates disagree, so the fragment counts nowhere and is tallied.
    case discordant(TwelveSPairDiscordance)

    /// Joins the calls of R1 and of the reverse complement of R2. A pair is
    /// concordant only when both mates name the same target, the same
    /// candidate set, or nothing at all. An exact match beside an ambiguous
    /// one is discordant even when the target is among the candidates.
    public static func join(r1: TwelveSReadClassification, r2: TwelveSReadClassification) -> TwelveSFragmentCall {
        switch (r1, r2) {
        case let (.exact(first, _), .exact(second, _)):
            return first == second ? .concordant(r1) : .discordant(.differentTargets)
        case let (.ambiguous(first), .ambiguous(second)):
            return first.sorted() == second.sorted()
                ? .concordant(.ambiguous(targetIDs: first.sorted()))
                : .discordant(.differentCandidates)
        case (.unresolved, .unresolved):
            return .concordant(.unresolved)
        case (.exact, .unresolved), (.unresolved, .exact), (.ambiguous, .unresolved), (.unresolved, .ambiguous):
            return .discordant(.oneMateUnresolved)
        case (.exact, .ambiguous), (.ambiguous, .exact):
            return .discordant(.oneMateAmbiguous)
        }
    }
}
