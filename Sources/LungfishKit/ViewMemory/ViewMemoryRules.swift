// ViewMemoryRules.swift - The shared rules that decide what a remembered view may bring back
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - Locus

/// One sequence of a bundle, by name and length.
public struct ViewMemorySequence: Sendable, Equatable {
    public var name: String
    public var length: Int

    public init(name: String, length: Int) {
        self.name = name
        self.length = length
    }
}

/// The place a view showed, with the length of the sequence it was drawn on.
///
/// The length travels with the locus so a later visit can tell a sequence that kept its name
/// and changed its content from the one the person left (VS B2).
public struct ViewMemoryLocus: Codable, Sendable, Equatable {
    public var sequenceName: String
    public var sequenceLength: Int
    public var start: Double
    public var end: Double

    public init(sequenceName: String, sequenceLength: Int, start: Double, end: Double) {
        self.sequenceName = sequenceName
        self.sequenceLength = sequenceLength
        self.start = start
        self.end = end
    }
}

// MARK: - Outcomes

/// What a rule did with one saved field.
///
/// `dropped` and `absent` differ because only a field that was saved and then refused earns a
/// phrase in the line that says what was not kept (VS U2). A field nobody saved earns none.
public enum ViewMemoryFieldOutcome<Value: Sendable>: Sendable {
    case kept(Value)
    case dropped
    case absent

    public var value: Value? {
        if case .kept(let value) = self { return value }
        return nil
    }

    public var wasDropped: Bool {
        if case .dropped = self { return true }
        return false
    }
}

extension ViewMemoryFieldOutcome: Equatable where Value: Equatable {}

/// The identities of a saved row selection that still exist (VS B4).
public struct ViewMemoryIdentityRestore: Sendable, Equatable {
    /// The identities that still exist, in the order they were saved.
    public let kept: [String]
    /// How many saved identities no longer exist.
    public let droppedCount: Int

    public init(kept: [String], droppedCount: Int) {
        self.kept = kept
        self.droppedCount = droppedCount
    }

    /// True when nothing is left. The table then shows no selection and never row 0.
    public var isEmpty: Bool { kept.isEmpty }
    /// True when part or all of the saved selection is gone.
    public var lostAny: Bool { droppedCount > 0 }
}

/// The sample choice that results from a saved choice and the samples that exist now (VS B5).
public struct ViewMemorySampleRestore: Sendable, Equatable {
    /// The samples to select. Never an empty set while any sample exists.
    public let selected: Set<String>
    /// How many saved samples no longer exist.
    public let droppedCount: Int
    /// True when no saved sample exists any more, so every sample is selected instead.
    public let fellBackToAll: Bool
    /// True when the choice leaves out a current sample, so the picker acts as a filter and
    /// the viewport must show it as one (word 5).
    public let isSubset: Bool

    public init(selected: Set<String>, droppedCount: Int, fellBackToAll: Bool, isSubset: Bool) {
        self.selected = selected
        self.droppedCount = droppedCount
        self.fellBackToAll = fellBackToAll
        self.isSubset = isSubset
    }
}

/// What the selection cap did with a selection (VS A9).
public enum ViewMemorySelectionCap: Sendable, Equatable {
    /// The whole selection fits and is kept.
    case kept([String])
    /// The selection passes a cap and is dropped whole, never cut short, so word 4 applies.
    case tooLarge
    /// Nothing was selected.
    case empty
}

// MARK: - Rules

/// The pure rules that every adopter shares. Nothing here reads a file, a store or a view, so a
/// caller may run them on any thread.
public enum ViewMemoryRules {
    /// A selection holds at most this many identities (VS A9).
    public static let selectionIdentityLimit = 1_000
    /// A selection holds at most this many bytes once encoded as JSON (VS A9).
    public static let selectionEncodedByteLimit = 32 * 1_024

    // MARK: Locus (VS B2)

    /// What a saved locus becomes on the current sequences.
    public enum LocusOutcome: Sendable, Equatable {
        /// The sequence exists with the same name and length. The coordinates are clamped, and
        /// `wasClamped` says whether clamping moved either end. A clamp alone earns no line.
        case restored(ViewMemoryLocus, wasClamped: Bool)
        /// The sequence is gone or has another length. The view opens at the first sequence and
        /// every coordinate field is dropped, so "your place" was not kept.
        case reset
    }

    /// Restores a locus only to a sequence of the same name and length.
    ///
    /// A sequence of the same name and another length counts as gone, since the coordinates
    /// belong to other bases. The start clamps to `[0, length - 1]` and the end to
    /// `(start, length]`. A coordinate that is not finite resets the locus.
    public static func resolveLocus(
        _ saved: ViewMemoryLocus,
        in sequences: [ViewMemorySequence]
    ) -> LocusOutcome {
        guard saved.start.isFinite,
              saved.end.isFinite,
              saved.sequenceLength > 0,
              let match = sequences.first(where: { $0.name == saved.sequenceName }),
              match.length == saved.sequenceLength
        else {
            return .reset
        }
        let range = clampedRange(start: saved.start, end: saved.end, length: match.length)
        var locus = saved
        locus.start = range.start
        locus.end = range.end
        return .restored(locus, wasClamped: range.start != saved.start || range.end != saved.end)
    }

    /// The start clamped to `[0, length - 1]` and the end to `(start, length]`. Both must be finite.
    public static func clampedRange(
        start: Double,
        end: Double,
        length: Int
    ) -> (start: Double, end: Double) {
        let upper = Double(max(length, 1))
        let clampedStart = min(max(start, 0), upper - 1)
        let clampedEnd = min(max(end, clampedStart + 1), upper)
        return (clampedStart, clampedEnd)
    }

    // MARK: Coordinate selection (VS B3)

    /// Keeps a coordinate selection only on an equal data key and drops it otherwise.
    ///
    /// The selection is never clamped, since a clamped region is another input to Extract. A key
    /// with a part that was not read yet never matches, so the selection is dropped then too.
    public static func coordinateSelection<Value: Sendable>(
        _ saved: Value?,
        savedKey: ViewMemoryDataKey?,
        currentKey: ViewMemoryDataKey
    ) -> ViewMemoryFieldOutcome<Value> {
        guard let saved else { return .absent }
        guard let savedKey, savedKey.matches(currentKey) else { return .dropped }
        return .kept(saved)
    }

    // MARK: Row identities (VS B4)

    /// Keeps the saved identities that still exist.
    ///
    /// Matching is by the whole identity string. A batch identity carries the result and the
    /// sample, so the same taxon in another sample is another identity and never matches. An
    /// empty result means no selection, never row 0.
    public static func keepIdentities(
        _ saved: [String],
        existing: Set<String>
    ) -> ViewMemoryIdentityRestore {
        var seen = Set<String>()
        var kept: [String] = []
        var dropped = 0
        for identity in saved {
            guard !identity.isEmpty, existing.contains(identity) else {
                dropped += 1
                continue
            }
            if seen.insert(identity).inserted {
                kept.append(identity)
            }
        }
        return ViewMemoryIdentityRestore(kept: kept, droppedCount: dropped)
    }

    // MARK: Samples (VS B5)

    /// Intersects a saved sample choice with the samples that exist now.
    ///
    /// A choice that was every sample, or an empty one, restores every current sample. An empty
    /// intersection falls back to every sample too, never to an empty set that NVD refuses.
    public static func restoreSamples(
        saved: [String],
        savedWasAllSamples: Bool,
        current: Set<String>
    ) -> ViewMemorySampleRestore {
        if current.isEmpty {
            return ViewMemorySampleRestore(selected: [], droppedCount: 0, fellBackToAll: false, isSubset: false)
        }
        if savedWasAllSamples || saved.isEmpty {
            return ViewMemorySampleRestore(selected: current, droppedCount: 0, fellBackToAll: false, isSubset: false)
        }
        let savedSet = Set(saved)
        let kept = savedSet.intersection(current)
        if kept.isEmpty {
            return ViewMemorySampleRestore(
                selected: current,
                droppedCount: savedSet.count,
                fellBackToAll: true,
                isSubset: false
            )
        }
        return ViewMemorySampleRestore(
            selected: kept,
            droppedCount: savedSet.count - kept.count,
            fellBackToAll: false,
            isSubset: kept.count < current.count
        )
    }

    // MARK: Selection cap (VS A9)

    /// Keeps a selection whole or drops it whole.
    ///
    /// More than `maxIdentities` identities, or more than `maxEncodedBytes` once encoded as
    /// JSON, drops the selection. It is never cut to a shorter list, since a part of a
    /// selection is another selection. The caps are parameters so a test can inject small ones.
    public static func capSelection(
        _ identities: [String],
        maxIdentities: Int = selectionIdentityLimit,
        maxEncodedBytes: Int = selectionEncodedByteLimit
    ) -> ViewMemorySelectionCap {
        guard !identities.isEmpty else { return .empty }
        guard identities.count <= maxIdentities else { return .tooLarge }
        guard let encoded = try? JSONEncoder().encode(identities),
              encoded.count <= maxEncodedBytes
        else {
            return .tooLarge
        }
        return .kept(identities)
    }
}
